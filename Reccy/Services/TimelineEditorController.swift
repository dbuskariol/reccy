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
    @Published var selectedCaptionID: UUID?
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
        try await RecordingTimelineProjectLoader.load(
            for: item,
            packageURL: packageURL
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
            selectedCaptionID: selectedCaptionID,
            playhead: playhead
        )

        project = loaded.project
        projectPackageURL = packageURL
        sourceDurations = loaded.sourceDurations
        playhead = 0
        selectedClipID = loaded.project.lanes.flatMap(\.clips).first?.id
        selectedGapID = nil
        selectedCaptionID = nil

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
            selectedCaptionID = previous.selectedCaptionID
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
        selectedCaptionID = nil
        seek(to: time ?? clip.timelineStart)
    }

    func select(_ gap: TimelineGapSegment, at time: TimeInterval? = nil) {
        selectedClipID = nil
        selectedGapID = gap.id
        selectedCaptionID = nil
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

    func replaceCaptions(with cues: [TimelineCaptionCue]) {
        updateProjectWithoutRebuild { project in
            let existingTrack = project.captionTrack
            project.captionTrack = TimelineCaptionTrack(
                isVisible: existingTrack?.isVisible ?? true,
                style: existingTrack?.style ?? TimelineCaptionStyle(),
                cues: cues
            )
            selectedCaptionID = cues.first?.id
        }
    }

    @discardableResult
    func addCaption(at time: TimeInterval) -> UUID? {
        guard let project else { return nil }
        var track = project.captionTrack ?? TimelineCaptionTrack(cues: [])
        let existingCues = track.cues.sorted { $0.timelineStart < $1.timelineStart }
        let start = min(max(time, 0), max(0, project.duration - project.frameDuration))
        guard !existingCues.contains(where: {
            abs($0.timelineStart - start) < project.frameDuration
        }) else {
            errorMessage = "There is already a caption boundary at the playhead. Select that cue to edit it."
            return nil
        }
        let nextStart = existingCues.first(where: { $0.timelineStart > start + 0.000_1 })?
            .timelineStart ?? project.duration
        let duration = min(nextStart - start, project.duration - start)
        guard duration >= project.frameDuration else {
            errorMessage = "There isn’t enough room to add another caption boundary at the playhead."
            return nil
        }
        let cue = TimelineCaptionCue(
            text: "New caption",
            timelineStart: start,
            duration: duration,
            origin: .manual
        )
        track.cues.append(cue)
        track.cues = track.presentationCues(through: project.duration)
        updateProjectWithoutRebuild { project in
            project.captionTrack = track
            selectedCaptionID = cue.id
        }
        return cue.id
    }

    func updateCaptionText(_ text: String, cueID: UUID) {
        updateProjectWithoutRebuild { project in
            guard var track = project.captionTrack,
                  let index = track.cues.firstIndex(where: { $0.id == cueID })
            else { return }
            track.cues[index].text = text
            project.captionTrack = track
        }
    }

    func deleteCaption(_ cueID: UUID) {
        updateProjectWithoutRebuild { project in
            guard var track = project.captionTrack else { return }
            track.cues.removeAll { $0.id == cueID }
            project.captionTrack = track.cues.isEmpty ? nil : track
            if selectedCaptionID == cueID { selectedCaptionID = nil }
        }
    }

    func setCaptionsVisible(_ isVisible: Bool) {
        updateProjectWithoutRebuild { project in
            guard var track = project.captionTrack else { return }
            track.isVisible = isVisible
            project.captionTrack = track
        }
    }

    func setCaptionPlacement(_ placement: TimelineCaptionPlacement) {
        updateProjectWithoutRebuild { project in
            guard var track = project.captionTrack else { return }
            track.style.placement = placement
            project.captionTrack = track
        }
    }

    func setCaptionSize(_ size: TimelineCaptionSize) {
        updateProjectWithoutRebuild { project in
            guard var track = project.captionTrack else { return }
            track.style.size = size
            project.captionTrack = track
        }
    }

    func selectCaption(_ cue: TimelineCaptionCue) {
        selectedCaptionID = cue.id
        selectedClipID = nil
        selectedGapID = nil
        seek(to: cue.timelineStart)
    }

    func moveCaption(_ cueID: UUID, to proposedStart: TimeInterval) {
        guard let project, var track = project.captionTrack,
              let start = track.moveCue(
                  id: cueID,
                  to: proposedStart,
                  frameDuration: project.frameDuration,
                  projectDuration: project.duration
              )
        else { return }

        updateProjectWithoutRebuild { project in
            project.captionTrack = track
        }
        selectedCaptionID = cueID
        selectedClipID = nil
        selectedGapID = nil
        seek(to: start)
    }

    func nudgeCaption(_ cueID: UUID, byFrames frames: Int) {
        guard frames != 0,
              let cue = project?.captionTrack?.cues.first(where: { $0.id == cueID })
        else { return }
        moveCaption(cueID, to: cue.timelineStart + Double(frames) * frameDuration)
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
        return ExportSource(
            name: project.name,
            asset: composition,
            videoComposition: TimelineCaptionVideoRenderer.applying(
                project.captionTrack,
                to: compositionVideoComposition,
                projectDuration: project.duration
            ),
            audioMix: compositionAudioMix
        )
    }

    private func updateProjectWithoutRebuild(_ update: (inout TimelineProject) -> Void) {
        guard var project else { return }
        let original = project
        update(&project)
        guard project != original else { return }
        project.modifiedAt = Date()
        self.project = project
        do {
            try save()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        let item = build.makePlayerItem()

        // A prior edit may still be assembling while the user makes a newer
        // one. Never let the older composition overwrite the current project.
        guard generation == rebuildGeneration, self.project == project else { return }

        composition = build.composition
        compositionVideoComposition = build.videoComposition
        compositionAudioMix = build.audioMix
        previewRenderSize = build.renderSize ?? .zero
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

private struct EditorProjectSnapshot {
    let project: TimelineProject?
    let projectPackageURL: URL?
    let sourceDurations: [URL: TimeInterval]
    let selectedClipID: UUID?
    let selectedGapID: UUID?
    let selectedCaptionID: UUID?
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
