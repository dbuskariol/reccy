import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog

enum TimelineEditorError: LocalizedError {
    case noMedia
    case noProject
    case microphonePermissionDenied
    case voiceoverCouldNotStart
    case exportUnsupported
    case projectFormatUnsupported

    var errorDescription: String? {
        switch self {
        case .noMedia: "The recording doesn’t contain editable video or audio tracks."
        case .noProject: "Open a recording in the editor first."
        case .microphonePermissionDenied: "Microphone access is required to record a voiceover."
        case .voiceoverCouldNotStart: "The voiceover recorder couldn’t start."
        case .exportUnsupported: "That export format isn’t compatible with this project."
        case .projectFormatUnsupported: "This timeline was created by an incompatible development build. Reset its non-destructive edits to reopen it; the source recording stays untouched."
        }
    }
}

@MainActor
final class TimelineEditorController: ObservableObject {
    private let logger = Logger(subsystem: "com.reccy.mac", category: "TimelineEditor")
    @Published private(set) var project: TimelineProject?
    @Published private(set) var isLoading = false
    @Published private(set) var isRebuilding = false
    @Published private(set) var isVoiceoverRecording = false
    @Published private(set) var previewRenderSize: CGSize = .zero
    @Published var selectedClipID: UUID?
    @Published var selectedGapID: UUID?
    @Published var playhead: TimeInterval = 0
    @Published var pixelsPerSecond: Double = 72
    @Published var errorMessage: String?
    @Published private(set) var canResetUnsupportedProject = false
    @Published var moveLinkedClips = false
    @Published private(set) var voiceoverInputDevices: [AudioInputDevice] = []
    @Published var selectedVoiceoverInputID: String? = UserDefaults.standard.string(
        forKey: "voiceover-input-device-id"
    ) {
        didSet {
            if let selectedVoiceoverInputID {
                UserDefaults.standard.set(selectedVoiceoverInputID, forKey: "voiceover-input-device-id")
            } else {
                UserDefaults.standard.removeObject(forKey: "voiceover-input-device-id")
            }
        }
    }

    /// Construct playback only when the editor is first used, not at app launch.
    lazy var player = AVPlayer()

    private var composition: AVMutableComposition?
    private var compositionVideoComposition: AVVideoComposition?
    private var compositionAudioMix: AVAudioMix?
    private var voiceoverRecorder: VoiceoverRecorder?
    private var voiceoverStartTime: TimeInterval = 0
    private var projectPackageURL: URL?
    private var sourceDurations: [URL: TimeInterval] = [:]
    private var interactionOriginalProject: TimelineProject?
    private var interactionOriginalClip: TimelineClip?
    private var interactionKind: TimelineInteractionKind?
    private var interactionAnchorTime: TimeInterval = 0
    private var interactionSnapTime: TimeInterval = 0
    private var interactionPreviewVideoID: UUID?
    private var rebuildGeneration: UInt = 0
    private var unsupportedProjectRecovery: UnsupportedProjectRecovery?

    init() {
        refreshVoiceoverInputDevices()
    }

    var duration: TimeInterval { max(project?.duration ?? 0, 0.01) }
    var frameDuration: TimeInterval { project?.frameDuration ?? 1 / 30 }
    var hasProject: Bool { project != nil }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        return project?.clip(id: selectedClipID)
    }
    var selectedGap: TimelineGapSegment? {
        guard let selectedGapID else { return nil }
        return project?.videoGap(id: selectedGapID)
    }
    var canSplitSelection: Bool { selectedClip?.contains(playhead) == true }
    var canSplitAll: Bool {
        project?.lanes.flatMap(\.clips).contains(where: { $0.contains(playhead) }) == true
    }
    var selectedGapFillMode: TimelineGapFillMode { selectedGap?.fillMode ?? .black }
    var selectedClipIsCamera: Bool {
        guard let selectedClipID else { return false }
        return project?.lanes.contains(where: {
            $0.kind == .camera && $0.clips.contains(where: { $0.id == selectedClipID })
        }) == true
    }
    var activeCameraClip: TimelineClip? {
        project?.lanes
            .first(where: { $0.kind == .camera })?
            .clips
            .first(where: {
                $0.timelineStart <= playhead + 0.000_1
                    && playhead < $0.timelineEnd - 0.000_1
            })
    }
    var selectedVoiceoverInputName: String {
        guard let selectedVoiceoverInputID else { return "System Default" }
        return voiceoverInputDevices.first(where: { $0.id == selectedVoiceoverInputID })?.name
            ?? "Unavailable Input"
    }

    func refreshVoiceoverInputDevices() {
        voiceoverInputDevices = AudioInputDevice.discoverAvailable()
    }

    func open(_ item: RecordingItem) async {
        isLoading = true
        dismissError()
        defer { isLoading = false }

        let packageURL = item.artifacts.projectPackageURL
        do {
            let loaded = try await loadProject(for: item, packageURL: packageURL)
            try await installLoadedProject(loaded, packageURL: packageURL)
        } catch TimelineEditorError.projectFormatUnsupported {
            unsupportedProjectRecovery = UnsupportedProjectRecovery(
                item: item,
                packageURL: packageURL
            )
            canResetUnsupportedProject = true
            errorMessage = TimelineEditorError.projectFormatUnsupported.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
        canResetUnsupportedProject = false
        unsupportedProjectRecovery = nil
    }

    func resetUnsupportedProject() async {
        guard let recovery = unsupportedProjectRecovery else { return }
        dismissError()

        do {
            if FileManager.default.fileExists(atPath: recovery.packageURL.path) {
                try FileManager.default.removeItem(at: recovery.packageURL)
            }
            await open(recovery.item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadProject(
        for item: RecordingItem,
        packageURL: URL
    ) async throws -> LoadedTimelineProject {
        let savedProjectURL = packageURL.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: savedProjectURL.path) {
            let data = try Data(contentsOf: savedProjectURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(TimelineProjectHeader.self, from: data)
            guard header.formatVersion == TimelineProject.currentFormatVersion else {
                throw TimelineEditorError.projectFormatUnsupported
            }
            let savedProject = try decoder.decode(TimelineProject.self, from: data)
            var durations: [URL: TimeInterval] = [:]
            for url in Set(savedProject.lanes.flatMap(\.clips).map(\.sourceURL)) {
                let sourceAsset = AVURLAsset(url: url)
                durations[url] = try await sourceAsset.load(.duration).seconds
            }
            return LoadedTimelineProject(
                project: savedProject,
                sourceDurations: durations,
                needsInitialSave: false
            )
        }

        let asset = AVURLAsset(url: item.url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw TimelineEditorError.noMedia
        }

        let linkedGroupID = UUID()
        var lanes: [TimelineLane] = []
        if let videoTrack = videoTracks.first {
            lanes.append(
                TimelineLane(
                    kind: .video,
                    name: "Screen",
                    clips: [
                        TimelineClip(
                            sourceURL: item.url,
                            sourceTrackID: videoTrack.trackID,
                            sourceStart: 0,
                            timelineStart: 0,
                            duration: duration,
                            name: item.name,
                            linkedGroupID: linkedGroupID
                        ),
                    ]
                )
            )
        }

        if let camera = item.manifest.camera,
           videoTracks.indices.contains(1)
        {
            let cameraTrack = videoTracks[1]
            let cameraTimeRange = try await cameraTrack.load(.timeRange)
            let sourceStart = max(0, cameraTimeRange.start.seconds)
            let cameraDuration = min(duration, max(0, cameraTimeRange.duration.seconds))
            if cameraDuration > 0 {
                let layout = TimelineVideoLayout.defaultCamera(
                    canvasSize: CGSize(
                        width: CGFloat(item.manifest.width),
                        height: CGFloat(item.manifest.height)
                    ),
                    sourceSize: CGSize(
                        width: CGFloat(camera.width),
                        height: CGFloat(camera.height)
                    )
                )
                lanes.append(
                    TimelineLane(
                        kind: .camera,
                        name: camera.name,
                        clips: [
                            TimelineClip(
                                sourceURL: item.url,
                                sourceTrackID: cameraTrack.trackID,
                                sourceStart: sourceStart,
                                timelineStart: sourceStart,
                                duration: cameraDuration,
                                name: camera.name,
                                linkedGroupID: linkedGroupID,
                                videoLayout: layout
                            ),
                        ]
                    )
                )
            }
        }

        var audioLaneDescriptions: [(kind: TimelineLaneKind, name: String)] = []
        if item.manifest.includesSystemAudio {
            audioLaneDescriptions.append((.systemAudio, "System Audio"))
        }
        if item.manifest.includesMicrophone {
            audioLaneDescriptions.append((
                .microphone,
                item.manifest.microphoneName ?? "Microphone"
            ))
        }

        for (track, description) in zip(audioTracks, audioLaneDescriptions) {
            lanes.append(
                TimelineLane(
                    kind: description.kind,
                    name: description.name,
                    clips: [
                        TimelineClip(
                            sourceURL: item.url,
                            sourceTrackID: track.trackID,
                            sourceStart: 0,
                            timelineStart: 0,
                            duration: duration,
                            name: description.name,
                            linkedGroupID: linkedGroupID
                        ),
                    ]
                )
            )
        }

        return LoadedTimelineProject(
            project: TimelineProject(
                name: item.name,
                frameRate: Double(item.manifest.frameRate),
                lanes: lanes
            ),
            sourceDurations: [item.url: duration],
            needsInitialSave: true
        )
    }

    private func installLoadedProject(
        _ loaded: LoadedTimelineProject,
        packageURL: URL
    ) async throws {
        let previous = EditorProjectSnapshot(
            project: project,
            projectPackageURL: projectPackageURL,
            sourceDurations: sourceDurations,
            selectedClipID: selectedClipID,
            selectedGapID: selectedGapID,
            playhead: playhead
        )

        project = loaded.project
        projectPackageURL = packageURL
        sourceDurations = loaded.sourceDurations
        playhead = 0
        selectedClipID = loaded.project.lanes.flatMap(\.clips).first?.id
        selectedGapID = nil

        do {
            try await rebuildComposition()
            if loaded.needsInitialSave {
                try save()
            }
        } catch {
            project = previous.project
            projectPackageURL = previous.projectPackageURL
            sourceDurations = previous.sourceDurations
            selectedClipID = previous.selectedClipID
            selectedGapID = previous.selectedGapID
            playhead = previous.playhead

            if previous.project != nil {
                try? await rebuildComposition()
            } else {
                rebuildGeneration &+= 1
                composition = nil
                compositionVideoComposition = nil
                compositionAudioMix = nil
                player.replaceCurrentItem(with: nil)
            }
            throw error
        }
    }

    func splitAllAtPlayhead() {
        guard var project else { return }
        project.splitAll(at: playhead)
        self.project = project
        selectedClipID = project.lanes
            .flatMap(\.clips)
            .first(where: { abs($0.timelineStart - playhead) < 0.002 })?.id
        rebuildAndSave()
    }

    func splitSelectionAtPlayhead() {
        guard var project, let selectedClipID else { return }
        guard let rightClipID = project.splitClip(id: selectedClipID, at: playhead) else { return }
        self.project = project
        self.selectedClipID = rightClipID
        rebuildAndSave()
    }

    func deleteSelection() {
        guard var project, let selectedClipID else { return }
        project.deleteClip(id: selectedClipID)
        self.project = project
        self.selectedClipID = nil
        rebuildAndSave()
    }

    func rippleDeleteSelection() {
        guard
            var project,
            let selectedClipID,
            let selected = project.lanes.flatMap(\.clips).first(where: { $0.id == selectedClipID })
        else { return }

        project.rippleDelete(timeRange: selected.timelineStart..<selected.timelineEnd)
        self.project = project
        self.selectedClipID = nil
        playhead = min(playhead, project.duration)
        rebuildAndSave()
    }

    func select(_ clip: TimelineClip, at time: TimeInterval? = nil) {
        selectedClipID = clip.id
        selectedGapID = nil
        seek(to: time ?? clip.timelineStart)
    }

    func select(_ gap: TimelineGapSegment, at time: TimeInterval? = nil) {
        selectedClipID = nil
        selectedGapID = gap.id
        seek(to: time ?? gap.timelineStart)
    }

    func beginClipMove(id: UUID, anchorTime: TimeInterval) {
        beginTimelineInteraction(.move(id), anchorTime: anchorTime)
    }

    func updateClipMove(id: UUID, by translation: TimeInterval) {
        guard
            case .move(id) = interactionKind,
            var draft = interactionOriginalProject,
            let original = interactionOriginalClip
        else { return }

        _ = draft.moveClip(
            id: id,
            to: original.timelineStart + translation,
            includeLinked: moveLinkedClips,
            snapTargets: [interactionSnapTime],
            snapTolerance: 8 / max(pixelsPerSecond, 1)
        )
        project = draft
        selectedClipID = id
        updateInteractionPreview(in: draft)
    }

    func endClipMove(id: UUID) {
        guard case .move(id) = interactionKind else { return }
        finishTimelineInteraction()
    }

    func beginClipTrim(id: UUID, edge: TimelineTrimEdge) {
        beginTimelineInteraction(.trim(id, edge), anchorTime: 0)
    }

    func updateClipTrim(id: UUID, edge: TimelineTrimEdge, by translation: TimeInterval) {
        guard
            case .trim(id, edge) = interactionKind,
            var draft = interactionOriginalProject,
            let original = interactionOriginalClip
        else { return }

        let originalBoundary = edge == .leading ? original.timelineStart : original.timelineEnd
        let sourceDuration = sourceDurations[original.sourceURL]
            ?? max(original.sourceStart + original.duration, 1 / 30)
        _ = draft.trimClip(
            id: id,
            edge: edge,
            to: originalBoundary + translation,
            sourceDuration: sourceDuration,
            includeLinked: moveLinkedClips,
            snapTargets: [interactionSnapTime],
            snapTolerance: 8 / max(pixelsPerSecond, 1)
        )
        project = draft
        selectedClipID = id
        updateInteractionPreview(in: draft)
    }

    func endClipTrim(id: UUID, edge: TimelineTrimEdge) {
        guard case .trim(id, edge) = interactionKind else { return }
        finishTimelineInteraction()
    }

    /// Frame-accurate, atomic movement for keyboard and assistive-technology
    /// actions. Pointer drags keep their live interaction preview; discrete
    /// actions edit the canonical project directly and save once.
    func nudgeClip(id: UUID, byFrames frameCount: Int) {
        let delta = TimeInterval(frameCount) * frameDuration
        guard delta.isFinite, delta != 0, var project, let clip = project.clip(id: id) else { return }
        guard let finalStart = project.moveClip(
            id: id,
            to: clip.timelineStart + delta,
            includeLinked: moveLinkedClips
        ) else { return }
        self.project = project
        selectedClipID = id
        selectedGapID = nil
        playhead = finalStart
        rebuildAndSave()
    }

    func nudgeClipTrim(id: UUID, edge: TimelineTrimEdge, byFrames frameCount: Int) {
        let delta = TimeInterval(frameCount) * frameDuration
        guard delta.isFinite, delta != 0, var project, let clip = project.clip(id: id) else { return }
        let boundary = edge == .leading ? clip.timelineStart : clip.timelineEnd
        let sourceDuration = sourceDurations[clip.sourceURL]
            ?? max(clip.sourceStart + clip.duration, 1 / 30)
        guard let finalBoundary = project.trimClip(
            id: id,
            edge: edge,
            to: boundary + delta,
            sourceDuration: sourceDuration,
            includeLinked: moveLinkedClips
        ) else { return }
        self.project = project
        selectedClipID = id
        selectedGapID = nil
        playhead = finalBoundary
        rebuildAndSave()
    }

    func setSelectedGapFillMode(_ mode: TimelineGapFillMode) {
        guard var project, let selectedGapID, selectedGap?.fillMode != mode else { return }
        project.setGapFillMode(mode, gapID: selectedGapID)
        self.project = project
        rebuildAndSave()
    }

    func toggleMute(laneID: UUID) {
        guard var project, let index = project.lanes.firstIndex(where: { $0.id == laneID }) else { return }
        project.lanes[index].isMuted.toggle()
        project.modifiedAt = Date()
        self.project = project
        rebuildAndSave()
    }

    func setVolume(_ volume: Double, laneID: UUID) {
        guard var project, let index = project.lanes.firstIndex(where: { $0.id == laneID }) else { return }
        project.lanes[index].volume = min(max(volume, 0), 2)
        project.modifiedAt = Date()
        self.project = project
        rebuildAndSave()
    }

    func setVideoLayout(_ layout: TimelineVideoLayout, clipID: UUID) {
        guard var project,
              let laneIndex = project.lanes.firstIndex(where: {
                  $0.kind == .camera && $0.clips.contains(where: { $0.id == clipID })
              }),
              let clipIndex = project.lanes[laneIndex].clips.firstIndex(where: { $0.id == clipID })
        else { return }
        project.lanes[laneIndex].clips[clipIndex].videoLayout = layout.clamped()
        project.modifiedAt = Date()
        self.project = project
        selectedClipID = clipID
        selectedGapID = nil
        rebuildAndSave()
    }

    func resetVideoLayout(clipID: UUID) {
        guard let clip = project?.clip(id: clipID) else { return }
        let current = (clip.videoLayout ?? .defaultCamera).clamped()
        let width = 0.28
        let height = min(0.5, width * current.height / max(current.width, 0.001))
        let margin = 0.03
        setVideoLayout(
            TimelineVideoLayout(
                x: 1 - width - margin,
                y: 1 - height - margin,
                width: width,
                height: height
            ),
            clipID: clipID
        )
    }

    func playPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if playhead >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
        objectWillChange.send()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekBy(_ seconds: TimeInterval) {
        seek(to: playhead + seconds)
    }

    func stepFrames(_ frameCount: Int) {
        player.pause()
        seekBy(TimeInterval(frameCount) * frameDuration)
        objectWillChange.send()
    }

    func syncPlayheadFromPlayer() {
        guard player.timeControlStatus == .playing else { return }
        let current = player.currentTime().seconds
        if current.isFinite {
            playhead = min(max(current, 0), duration)
        }
        objectWillChange.send()
    }

    func toggleVoiceover() {
        if isVoiceoverRecording {
            stopVoiceover()
        } else {
            Task { await startVoiceover() }
        }
    }

    func save() throws {
        guard let project, let packageURL = projectPackageURL else {
            throw TimelineEditorError.noProject
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.reccy.encode(project)
        try data.write(to: packageURL.appendingPathComponent("project.json"), options: .atomic)
    }

    func makeExportSource() throws -> ExportSource {
        guard let project, let composition else { throw TimelineEditorError.noProject }
        guard let snapshot = composition.copy() as? AVComposition else {
            throw TimelineEditorError.noProject
        }
        return ExportSource(
            name: project.name,
            asset: snapshot,
            videoComposition: compositionVideoComposition,
            audioMix: compositionAudioMix
        )
    }

    private func rebuildAndSave() {
        Task {
            do {
                try await rebuildComposition()
                try save()
            } catch {
                logRebuildError(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rebuildComposition() async throws {
        guard let project else { throw TimelineEditorError.noProject }
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        isRebuilding = true
        defer {
            if generation == rebuildGeneration {
                isRebuilding = false
            }
        }

        let build = try await TimelineCompositionBuilder.build(project)
        let snapshot = (build.composition.copy() as? AVComposition) ?? build.composition
        let item = AVPlayerItem(asset: snapshot)
        item.videoComposition = build.videoComposition
        item.audioMix = build.audioMix

        // A prior edit may still be assembling while the user makes a newer
        // one. Never let the older composition overwrite the current project.
        guard generation == rebuildGeneration, self.project == project else { return }

        composition = build.composition
        compositionVideoComposition = build.videoComposition
        compositionAudioMix = build.audioMix
        previewRenderSize = build.renderSize ?? .zero
        item.seekingWaitsForVideoCompositionRendering = true
        player.replaceCurrentItem(with: item)
        let target = min(playhead, project.duration)
        playhead = target
        item.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak item] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.objectWillChange.send()
            }
        }
    }

    private func logRebuildError(_ error: Error) {
        let nsError = error as NSError
        let underlying = (error as? TimelineCompositionBuildError)?.underlyingError as NSError?
        let underlyingDomain = underlying?.domain ?? "none"
        let underlyingCode = underlying?.code ?? 0
        let underlyingInfo = String(describing: underlying?.userInfo)
        let detail = "Timeline rebuild failed domain=\(nsError.domain) "
            + "code=\(nsError.code) description=\(nsError.localizedDescription) "
            + "underlyingDomain=\(underlyingDomain) underlyingCode=\(underlyingCode) "
            + "underlyingInfo=\(underlyingInfo)"
        logger.error("\(detail, privacy: .public)")
    }

    private func startVoiceover() async {
        do {
            guard project != nil else { throw TimelineEditorError.noProject }
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                granted = true
            case .notDetermined:
                granted = await AVCaptureDevice.requestAccess(for: .audio)
            default:
                granted = false
            }
            guard granted else { throw TimelineEditorError.microphonePermissionDenied }
            guard let packageURL = projectPackageURL else { throw TimelineEditorError.noProject }

            let mediaDirectory = packageURL.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let url = mediaDirectory
                .appendingPathComponent("Voiceover \(UUID().uuidString)")
                .appendingPathExtension("m4a")
            refreshVoiceoverInputDevices()
            let recorder = VoiceoverRecorder()
            try await recorder.start(to: url, deviceID: selectedVoiceoverInputID)

            voiceoverRecorder = recorder
            voiceoverStartTime = playhead
            isVoiceoverRecording = true
            player.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopVoiceover() {
        guard let recorder = voiceoverRecorder else { return }
        player.pause()
        voiceoverRecorder = nil
        isVoiceoverRecording = false

        Task {
            do {
                let recording = try await recorder.stop()
                guard recording.duration > 0.05 else {
                    try? FileManager.default.removeItem(at: recording.url)
                    return
                }

                let asset = AVURLAsset(url: recording.url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw TimelineEditorError.noMedia
                }
                guard var project else { throw TimelineEditorError.noProject }
                let clip = TimelineClip(
                    sourceURL: recording.url,
                    sourceTrackID: track.trackID,
                    sourceStart: 0,
                    timelineStart: voiceoverStartTime,
                    duration: recording.duration,
                    name: "Voiceover · \(selectedVoiceoverInputName)",
                    linkedGroupID: nil
                )
                if let laneIndex = project.lanes.firstIndex(where: { $0.kind == .voiceover }) {
                    project.lanes[laneIndex].clips.append(clip)
                } else {
                    project.lanes.append(
                        TimelineLane(kind: .voiceover, name: "Voiceover", clips: [clip])
                    )
                }
                project.modifiedAt = Date()
                sourceDurations[recording.url] = recording.duration
                self.project = project
                selectedClipID = clip.id
                try await rebuildComposition()
                try save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func beginTimelineInteraction(
        _ kind: TimelineInteractionKind,
        anchorTime: TimeInterval
    ) {
        guard interactionKind == nil, let project else { return }
        let id = kind.clipID
        guard let clip = project.clip(id: id) else { return }

        player.pause()
        interactionOriginalProject = project
        interactionOriginalClip = clip
        interactionKind = kind
        interactionAnchorTime = min(max(anchorTime, 0), clip.duration)
        interactionSnapTime = playhead
        interactionPreviewVideoID = previewVideoClipID(for: clip, in: project)
        selectedClipID = id
        selectedGapID = nil

        if let previewID = interactionPreviewVideoID,
           let videoClip = project.clip(id: previewID)
        {
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: videoClip.sourceURL)))
            updateInteractionPreview(in: project)
        }
    }

    private func updateInteractionPreview(in project: TimelineProject) {
        guard
            let interactionKind,
            let previewID = interactionPreviewVideoID,
            let videoClip = project.clip(id: previewID)
        else { return }

        let sourceTime: TimeInterval
        switch interactionKind {
        case .move:
            let localTime = min(interactionAnchorTime, max(0, videoClip.duration - 1 / 60))
            playhead = videoClip.timelineStart + localTime
            sourceTime = videoClip.sourceStart + localTime
        case .trim(_, let edge):
            switch edge {
            case .leading:
                playhead = videoClip.timelineStart
                sourceTime = videoClip.sourceStart
            case .trailing:
                playhead = videoClip.timelineEnd
                sourceTime = videoClip.sourceStart + max(0, videoClip.duration - 1 / 60)
            }
        }
        player.seek(
            to: CMTime(seconds: sourceTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func finishTimelineInteraction() {
        let changed = project != interactionOriginalProject
        let usedSourcePreview = interactionPreviewVideoID != nil
        interactionOriginalProject = nil
        interactionOriginalClip = nil
        interactionKind = nil
        interactionPreviewVideoID = nil
        interactionAnchorTime = 0
        interactionSnapTime = 0

        if changed || usedSourcePreview {
            rebuildAndSave()
        }
    }

    private func previewVideoClipID(
        for selected: TimelineClip,
        in project: TimelineProject
    ) -> UUID? {
        if project.lanes.contains(where: {
            $0.kind == .video && $0.clips.contains(where: { $0.id == selected.id })
        }) {
            return selected.id
        }
        guard moveLinkedClips, let groupID = selected.linkedGroupID else { return nil }
        let tolerance = 0.002
        return project.lanes
            .first(where: { $0.kind == .video })?
            .clips
            .first(where: {
                $0.linkedGroupID == groupID
                    && abs($0.sourceStart - selected.sourceStart) < tolerance
                    && abs($0.timelineStart - selected.timelineStart) < tolerance
                    && abs($0.duration - selected.duration) < tolerance
            })?
            .id
    }
}

private struct TimelineProjectHeader: Decodable {
    let formatVersion: Int
}

private struct LoadedTimelineProject {
    let project: TimelineProject
    let sourceDurations: [URL: TimeInterval]
    let needsInitialSave: Bool
}

private struct EditorProjectSnapshot {
    let project: TimelineProject?
    let projectPackageURL: URL?
    let sourceDurations: [URL: TimeInterval]
    let selectedClipID: UUID?
    let selectedGapID: UUID?
    let playhead: TimeInterval
}

private struct UnsupportedProjectRecovery {
    let item: RecordingItem
    let packageURL: URL
}

private enum TimelineInteractionKind: Equatable {
    case move(UUID)
    case trim(UUID, TimelineTrimEdge)

    var clipID: UUID {
        switch self {
        case .move(let id), .trim(let id, _): id
        }
    }
}

private extension JSONEncoder {
    static var reccy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
