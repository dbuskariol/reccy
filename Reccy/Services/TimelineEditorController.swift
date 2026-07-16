import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers

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
    @Published private(set) var isImportingMedia = false
    @Published private(set) var previewRenderSize: CGSize = .zero
    @Published var selectedClipID: UUID?
    @Published var selectedGapID: UUID?
    @Published var selectedCaptionID: UUID?
    @Published var selectedMouseFollowZoomSegmentID: UUID?
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
    private var interactionOriginalSnapshot: EditorProjectSnapshot?
    private var mouseZoomInteractionOriginalProject: TimelineProject?
    private var mouseZoomInteractionOriginalSegment: MouseFollowZoomSegment?
    private var mouseZoomInteractionOriginalSnapshot: EditorProjectSnapshot?
    private var mouseZoomInteractionKind: MouseZoomInteractionKind?
    private var rebuildGeneration: UInt = 0
    private var unsupportedProjectRecovery: UnsupportedProjectRecovery?
    private weak var undoManager: UndoManager?
    private let mediaImporter = TimelineMediaImporter()

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
    var selectedMouseFollowZoomSegment: MouseFollowZoomSegment? {
        guard let selectedMouseFollowZoomSegmentID else { return nil }
        return project?.mouseFollowZoomSegment(id: selectedMouseFollowZoomSegmentID)
    }
    var canSplitSelection: Bool { selectedClip?.contains(playhead) == true }
    var canSplitAll: Bool {
        project?.lanes.flatMap(\.clips).contains(where: { $0.contains(playhead) }) == true
    }
    var selectedGapFillMode: TimelineGapFillMode { selectedGap?.fillMode ?? .black }
    var selectedClipIsOverlayVideo: Bool {
        guard let selectedClipID else { return false }
        return project?.lanes.contains(where: {
            $0.kind.isOverlayVideo && $0.clips.contains(where: { $0.id == selectedClipID })
        }) == true
    }
    var activeOverlayVideoClips: [TimelineClip] {
        project?.lanes
            .filter { $0.kind.isOverlayVideo }
            .flatMap(\.clips)
            .filter {
                $0.timelineStart <= playhead + 0.000_1
                    && playhead < $0.timelineEnd - 0.000_1
            } ?? []
    }
    var selectedVoiceoverInputName: String {
        guard let selectedVoiceoverInputID else { return "System Default" }
        return voiceoverInputDevices.first(where: { $0.id == selectedVoiceoverInputID })?.name
            ?? "Unavailable Input"
    }

    func refreshVoiceoverInputDevices() {
        voiceoverInputDevices = AudioInputDevice.discoverAvailable()
    }

    func connectUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
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
            selectedMouseFollowZoomSegmentID: selectedMouseFollowZoomSegmentID,
            playhead: playhead
        )

        project = loaded.project
        projectPackageURL = packageURL
        sourceDurations = loaded.sourceDurations
        playhead = loaded.project.effectivePosterFrameTime
        selectedClipID = loaded.project.lanes.flatMap(\.clips).first?.id
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = nil

        do {
            try await rebuildComposition()
            if loaded.needsInitialSave {
                try save()
            }
            undoManager?.removeAllActions(withTarget: self)
        } catch {
            project = previous.project
            projectPackageURL = previous.projectPackageURL
            sourceDurations = previous.sourceDurations
            selectedClipID = previous.selectedClipID
            selectedGapID = previous.selectedGapID
            selectedCaptionID = previous.selectedCaptionID
            selectedMouseFollowZoomSegmentID = previous.selectedMouseFollowZoomSegmentID
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
        let undoSnapshot = currentSnapshot()
        guard var project else { return }
        project.splitAll(at: playhead)
        self.project = project
        selectedClipID = project.lanes
            .flatMap(\.clips)
            .first(where: { abs($0.timelineStart - playhead) < 0.002 })?.id
        registerUndo(undoSnapshot, actionName: "Split All Tracks")
        rebuildAndSave()
    }

    func splitSelectionAtPlayhead() {
        let undoSnapshot = currentSnapshot()
        guard var project, let selectedClipID else { return }
        guard let rightClipID = project.splitClip(id: selectedClipID, at: playhead) else { return }
        self.project = project
        self.selectedClipID = rightClipID
        registerUndo(undoSnapshot, actionName: "Split Clip")
        rebuildAndSave()
    }

    func deleteSelection() {
        let undoSnapshot = currentSnapshot()
        guard var project else { return }
        if let selectedMouseFollowZoomSegmentID {
            project.deleteMouseFollowZoomSegment(id: selectedMouseFollowZoomSegmentID)
            self.project = project
            self.selectedMouseFollowZoomSegmentID = nil
            registerUndo(undoSnapshot, actionName: "Delete Mouse Zoom")
            rebuildAndSave()
            return
        }
        guard let selectedClipID else { return }
        project.deleteClip(id: selectedClipID)
        self.project = project
        self.selectedClipID = nil
        registerUndo(undoSnapshot, actionName: "Delete Clip")
        rebuildAndSave()
    }

    func rippleDeleteSelection() {
        let undoSnapshot = currentSnapshot()
        guard
            var project,
            let selectedClipID,
            let selected = project.lanes.flatMap(\.clips).first(where: { $0.id == selectedClipID })
        else { return }

        project.rippleDelete(timeRange: selected.timelineStart..<selected.timelineEnd)
        self.project = project
        self.selectedClipID = nil
        playhead = min(playhead, project.duration)
        registerUndo(undoSnapshot, actionName: "Close Gap")
        rebuildAndSave()
    }

    func select(_ clip: TimelineClip, at time: TimeInterval? = nil) {
        selectedClipID = clip.id
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = nil
        seek(to: time ?? clip.timelineStart)
    }

    func select(_ gap: TimelineGapSegment, at time: TimeInterval? = nil) {
        selectedClipID = nil
        selectedGapID = gap.id
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = nil
        seek(to: time ?? gap.timelineStart)
    }

    func select(_ segment: MouseFollowZoomSegment, at time: TimeInterval? = nil) {
        selectedClipID = nil
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = segment.id
        seek(to: time ?? segment.timelineStart)
    }

    @discardableResult
    func addMouseFollowZoom(at time: TimeInterval, zoomScale: Double = 2) -> UUID? {
        let undoSnapshot = currentSnapshot()
        guard var project,
              let id = project.addMouseFollowZoomSegment(at: time, zoomScale: zoomScale)
        else {
            errorMessage = "There isn’t enough empty effect-track space at the playhead. Move the playhead or resize the neighbouring mouse zoom."
            return nil
        }
        self.project = project
        selectedClipID = nil
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = id
        registerUndo(undoSnapshot, actionName: "Add Mouse Zoom")
        rebuildAndSave()
        return id
    }

    func setMouseFollowZoomScale(_ scale: Double, segmentID: UUID) {
        let undoSnapshot = currentSnapshot()
        guard var project,
              project.mouseFollowZoomSegment(id: segmentID)?.zoomScale != scale
        else { return }
        project.setMouseFollowZoomScale(scale, segmentID: segmentID)
        self.project = project
        selectedMouseFollowZoomSegmentID = segmentID
        registerUndo(undoSnapshot, actionName: "Change Mouse Zoom")
        rebuildAndSave()
    }

    func trimMouseFollowZoomSegment(
        id: UUID,
        edge: TimelineTrimEdge,
        to timelineTime: TimeInterval
    ) {
        let undoSnapshot = currentSnapshot()
        guard var project,
              let boundary = project.trimMouseFollowZoomSegment(
                  id: id,
                  edge: edge,
                  to: timelineTime
              )
        else { return }
        self.project = project
        selectedMouseFollowZoomSegmentID = id
        playhead = boundary
        registerUndo(undoSnapshot, actionName: "Resize Mouse Zoom")
        rebuildAndSave()
    }

    func nudgeMouseFollowZoomBoundary(
        id: UUID,
        edge: TimelineTrimEdge,
        byFrames frames: Int
    ) {
        guard frames != 0,
              let segment = project?.mouseFollowZoomSegment(id: id)
        else { return }
        let boundary = edge == .leading ? segment.timelineStart : segment.timelineEnd
        trimMouseFollowZoomSegment(
            id: id,
            edge: edge,
            to: boundary + Double(frames) * frameDuration
        )
    }

    func beginMouseFollowZoomMove(id: UUID) {
        guard interactionKind == nil,
              mouseZoomInteractionKind == nil,
              let project,
              let segment = project.mouseFollowZoomSegment(id: id)
        else { return }

        player.pause()
        mouseZoomInteractionOriginalSnapshot = currentSnapshot()
        mouseZoomInteractionOriginalProject = project
        mouseZoomInteractionOriginalSegment = segment
        mouseZoomInteractionKind = .move(id)
        selectedClipID = nil
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = id
        playhead = segment.timelineStart
    }

    func updateMouseFollowZoomMove(id: UUID, by translation: TimeInterval) {
        guard mouseZoomInteractionKind == .move(id),
              var draft = mouseZoomInteractionOriginalProject,
              let original = mouseZoomInteractionOriginalSegment,
              let finalStart = draft.moveMouseFollowZoomSegment(
                  id: id,
                  to: original.timelineStart + translation
              )
        else { return }

        project = draft
        selectedMouseFollowZoomSegmentID = id
        playhead = finalStart
    }

    func endMouseFollowZoomMove(id: UUID) {
        guard mouseZoomInteractionKind == .move(id) else { return }
        finishMouseZoomInteraction(actionName: "Move Mouse Zoom")
    }

    func beginMouseFollowZoomTrim(id: UUID, edge: TimelineTrimEdge) {
        guard interactionKind == nil,
              mouseZoomInteractionKind == nil,
              let project,
              let segment = project.mouseFollowZoomSegment(id: id)
        else { return }

        player.pause()
        mouseZoomInteractionOriginalSnapshot = currentSnapshot()
        mouseZoomInteractionOriginalProject = project
        mouseZoomInteractionOriginalSegment = segment
        mouseZoomInteractionKind = .trim(id, edge)
        selectedClipID = nil
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = id
    }

    func updateMouseFollowZoomTrim(
        id: UUID,
        edge: TimelineTrimEdge,
        by translation: TimeInterval
    ) {
        guard mouseZoomInteractionKind == .trim(id, edge),
              var draft = mouseZoomInteractionOriginalProject,
              let original = mouseZoomInteractionOriginalSegment
        else { return }

        let originalBoundary = edge == .leading
            ? original.timelineStart
            : original.timelineEnd
        guard let boundary = draft.trimMouseFollowZoomSegment(
            id: id,
            edge: edge,
            to: originalBoundary + translation
        ) else { return }

        project = draft
        selectedMouseFollowZoomSegmentID = id
        playhead = boundary
    }

    func endMouseFollowZoomTrim(id: UUID, edge: TimelineTrimEdge) {
        guard mouseZoomInteractionKind == .trim(id, edge) else { return }
        finishMouseZoomInteraction(actionName: "Resize Mouse Zoom")
    }

    func nudgeMouseFollowZoomSegment(id: UUID, byFrames frames: Int) {
        let undoSnapshot = currentSnapshot()
        guard frames != 0,
              var project,
              let segment = project.mouseFollowZoomSegment(id: id),
              let finalStart = project.moveMouseFollowZoomSegment(
                  id: id,
                  to: segment.timelineStart + Double(frames) * frameDuration
              )
        else { return }

        self.project = project
        selectedClipID = nil
        selectedGapID = nil
        selectedCaptionID = nil
        selectedMouseFollowZoomSegmentID = id
        playhead = finalStart
        registerUndo(undoSnapshot, actionName: "Move Mouse Zoom")
        rebuildAndSave()
    }

    private func finishMouseZoomInteraction(actionName: String) {
        let changed = project != mouseZoomInteractionOriginalProject
        let undoSnapshot = mouseZoomInteractionOriginalSnapshot
        mouseZoomInteractionOriginalProject = nil
        mouseZoomInteractionOriginalSegment = nil
        mouseZoomInteractionOriginalSnapshot = nil
        mouseZoomInteractionKind = nil

        guard changed else { return }
        if let undoSnapshot {
            registerUndo(undoSnapshot, actionName: actionName)
        }
        rebuildAndSave()
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
        let undoSnapshot = currentSnapshot()
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
        selectedMouseFollowZoomSegmentID = nil
        playhead = finalStart
        registerUndo(undoSnapshot, actionName: "Move Clip")
        rebuildAndSave()
    }

    func nudgeClipTrim(id: UUID, edge: TimelineTrimEdge, byFrames frameCount: Int) {
        let undoSnapshot = currentSnapshot()
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
        selectedMouseFollowZoomSegmentID = nil
        playhead = finalBoundary
        registerUndo(undoSnapshot, actionName: "Trim Clip")
        rebuildAndSave()
    }

    func setSelectedGapFillMode(_ mode: TimelineGapFillMode) {
        let undoSnapshot = currentSnapshot()
        guard var project, let selectedGapID, selectedGap?.fillMode != mode else { return }
        project.setGapFillMode(mode, gapID: selectedGapID)
        self.project = project
        registerUndo(undoSnapshot, actionName: "Change Gap Fill")
        rebuildAndSave()
    }

    func toggleMute(laneID: UUID) {
        let undoSnapshot = currentSnapshot()
        guard var project, let index = project.lanes.firstIndex(where: { $0.id == laneID }) else { return }
        project.lanes[index].isMuted.toggle()
        project.modifiedAt = Date()
        self.project = project
        registerUndo(undoSnapshot, actionName: "Change Track Mute")
        rebuildAndSave()
    }

    func setVolume(_ volume: Double, laneID: UUID) {
        let undoSnapshot = currentSnapshot()
        guard var project, let index = project.lanes.firstIndex(where: { $0.id == laneID }) else { return }
        let clampedVolume = min(max(volume, 0), 2)
        guard project.lanes[index].volume != clampedVolume else { return }
        project.lanes[index].volume = clampedVolume
        project.modifiedAt = Date()
        self.project = project
        registerUndo(undoSnapshot, actionName: "Change Track Volume")
        rebuildAndSave()
    }

    func setVideoLayout(_ layout: TimelineVideoLayout, clipID: UUID) {
        let undoSnapshot = currentSnapshot()
        guard var project,
              let laneIndex = project.lanes.firstIndex(where: {
                  $0.kind.isOverlayVideo && $0.clips.contains(where: { $0.id == clipID })
              }),
              let clipIndex = project.lanes[laneIndex].clips.firstIndex(where: { $0.id == clipID })
        else { return }
        project.lanes[laneIndex].clips[clipIndex].videoLayout = layout.clamped()
        project.modifiedAt = Date()
        self.project = project
        selectedClipID = clipID
        selectedGapID = nil
        selectedMouseFollowZoomSegmentID = nil
        registerUndo(undoSnapshot, actionName: "Move Video Overlay")
        rebuildAndSave()
    }

    func replaceCaptions(with cues: [TimelineCaptionCue]) {
        updateProjectWithoutRebuild(actionName: "Replace Captions") { project in
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
        updateProjectWithoutRebuild(actionName: "Add Caption") { project in
            project.captionTrack = track
            selectedCaptionID = cue.id
        }
        return cue.id
    }

    func updateCaptionText(_ text: String, cueID: UUID) {
        updateProjectWithoutRebuild(actionName: "Edit Caption") { project in
            guard var track = project.captionTrack,
                  let index = track.cues.firstIndex(where: { $0.id == cueID })
            else { return }
            track.cues[index].text = text
            project.captionTrack = track
        }
    }

    func deleteCaption(_ cueID: UUID) {
        updateProjectWithoutRebuild(actionName: "Delete Caption") { project in
            guard var track = project.captionTrack else { return }
            track.cues.removeAll { $0.id == cueID }
            project.captionTrack = track.cues.isEmpty ? nil : track
            if selectedCaptionID == cueID { selectedCaptionID = nil }
        }
    }

    func setCaptionsVisible(_ isVisible: Bool) {
        updateProjectWithoutRebuild(actionName: isVisible ? "Show Captions" : "Hide Captions") { project in
            guard var track = project.captionTrack else { return }
            track.isVisible = isVisible
            project.captionTrack = track
        }
    }

    func setCaptionPlacement(_ placement: TimelineCaptionPlacement) {
        updateProjectWithoutRebuild(actionName: "Change Caption Placement") { project in
            guard var track = project.captionTrack else { return }
            track.style.placement = placement
            project.captionTrack = track
        }
    }

    func setCaptionSize(_ size: TimelineCaptionSize) {
        updateProjectWithoutRebuild(actionName: "Change Caption Size") { project in
            guard var track = project.captionTrack else { return }
            track.style.size = size
            project.captionTrack = track
        }
    }

    func selectCaption(_ cue: TimelineCaptionCue) {
        selectedCaptionID = cue.id
        selectedClipID = nil
        selectedGapID = nil
        selectedMouseFollowZoomSegmentID = nil
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

        updateProjectWithoutRebuild(actionName: "Move Caption") { project in
            project.captionTrack = track
        }
        selectedCaptionID = cueID
        selectedClipID = nil
        selectedGapID = nil
        selectedMouseFollowZoomSegmentID = nil
        seek(to: start)
    }

    func nudgeCaption(_ cueID: UUID, byFrames frames: Int) {
        guard frames != 0,
              let cue = project?.captionTrack?.cues.first(where: { $0.id == cueID })
        else { return }
        moveCaption(cueID, to: cue.timelineStart + Double(frames) * frameDuration)
    }

    func resetVideoLayout(clipID: UUID) {
        guard let project,
              let lane = project.lanes.first(where: { $0.clips.contains(where: { $0.id == clipID }) }),
              let clip = lane.clips.first(where: { $0.id == clipID })
        else { return }
        let current = (clip.videoLayout ?? .defaultCamera).clamped()
        let width = lane.kind == .camera ? 0.28 : 0.6
        let height = min(
            lane.kind == .camera ? 0.5 : 0.8,
            width * current.height / max(current.width, 0.001)
        )
        let margin = 0.03
        let x = lane.kind == .camera ? 1 - width - margin : (1 - width) / 2
        let y = lane.kind == .camera ? 1 - height - margin : (1 - height) / 2
        setVideoLayout(
            TimelineVideoLayout(
                x: x,
                y: y,
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
    }

    func toggleVoiceover() {
        if isVoiceoverRecording {
            stopVoiceover()
        } else {
            Task { await startVoiceover() }
        }
    }

    func chooseMediaToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.prompt = "Import"
        panel.message = "Choose video, audio, or images to add as independent timeline tracks."
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        Task { await importMedia(from: panel.urls) }
    }

    func importMedia(from urls: [URL]) async {
        guard !urls.isEmpty, let project, let packageURL = projectPackageURL else {
            errorMessage = TimelineEditorError.noProject.localizedDescription
            return
        }
        guard !isImportingMedia else { return }
        player.pause()
        isImportingMedia = true
        defer { isImportingMedia = false }

        let snapshot = currentSnapshot()
        var createdFiles: [URL] = []
        do {
            let canvasSize = previewRenderSize.width > 0 && previewRenderSize.height > 0
                ? previewRenderSize
                : CGSize(width: 1920, height: 1080)
            let result = try await mediaImporter.prepare(
                urls: urls,
                packageURL: packageURL,
                timelineStart: playhead,
                canvasSize: canvasSize,
                frameRate: project.frameRate
            )
            createdFiles = result.createdFiles

            var updated = project
            updated.lanes.append(contentsOf: result.lanes)
            updated.modifiedAt = Date()
            self.project = updated
            for (url, duration) in result.sourceDurations {
                sourceDurations[url] = duration
            }
            selectedClipID = result.lanes.first?.clips.first?.id
            selectedGapID = nil
            selectedMouseFollowZoomSegmentID = nil
            try await rebuildComposition()
            try save()
            registerUndo(snapshot, actionName: "Import Media")
        } catch {
            self.project = snapshot.project
            projectPackageURL = snapshot.projectPackageURL
            sourceDurations = snapshot.sourceDurations
            selectedClipID = snapshot.selectedClipID
            selectedGapID = snapshot.selectedGapID
            selectedCaptionID = snapshot.selectedCaptionID
            selectedMouseFollowZoomSegmentID = snapshot.selectedMouseFollowZoomSegmentID
            playhead = snapshot.playhead
            for url in createdFiles.reversed() {
                try? FileManager.default.removeItem(at: url)
            }
            try? await rebuildComposition()
            errorMessage = error.localizedDescription
        }
    }

    func save() throws {
        guard let project, let packageURL = projectPackageURL else {
            throw TimelineEditorError.noProject
        }
        try RecordingTimelineProjectLoader.save(project, packageURL: packageURL)
    }

    func saveProject() {
        do {
            try save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useCurrentFrameAsPoster() {
        updateProjectWithoutRebuild(actionName: "Set Poster Frame") { project in
            project.setPosterFrame(at: playhead)
        }
    }

    var sourceRecordingURL: URL? {
        project?.lanes.first(where: { $0.kind == .video })?.clips.first?.sourceURL
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

    private func updateProjectWithoutRebuild(
        actionName: String,
        _ update: (inout TimelineProject) -> Void
    ) {
        guard var project else { return }
        let undoSnapshot = currentSnapshot()
        let original = project
        update(&project)
        guard project != original else { return }
        project.modifiedAt = Date()
        self.project = project
        registerUndo(undoSnapshot, actionName: actionName)
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

    private func currentSnapshot() -> EditorProjectSnapshot {
        EditorProjectSnapshot(
            project: project,
            projectPackageURL: projectPackageURL,
            sourceDurations: sourceDurations,
            selectedClipID: selectedClipID,
            selectedGapID: selectedGapID,
            selectedCaptionID: selectedCaptionID,
            selectedMouseFollowZoomSegmentID: selectedMouseFollowZoomSegmentID,
            playhead: playhead
        )
    }

    private func registerUndo(_ snapshot: EditorProjectSnapshot, actionName: String) {
        guard snapshot.project != project, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ snapshot: EditorProjectSnapshot, actionName: String) {
        let inverse = currentSnapshot()
        player.pause()
        project = snapshot.project
        projectPackageURL = snapshot.projectPackageURL
        sourceDurations = snapshot.sourceDurations
        selectedClipID = snapshot.selectedClipID
        selectedGapID = snapshot.selectedGapID
        selectedCaptionID = snapshot.selectedCaptionID
        selectedMouseFollowZoomSegmentID = snapshot.selectedMouseFollowZoomSegmentID
        playhead = min(max(snapshot.playhead, 0), duration)
        registerUndo(inverse, actionName: actionName)
        rebuildAndSave()
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
                let undoSnapshot = currentSnapshot()
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
                registerUndo(undoSnapshot, actionName: "Record Voiceover")
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
        interactionOriginalSnapshot = currentSnapshot()
        interactionOriginalProject = project
        interactionOriginalClip = clip
        interactionKind = kind
        interactionAnchorTime = min(max(anchorTime, 0), clip.duration)
        interactionSnapTime = playhead
        interactionPreviewVideoID = previewVideoClipID(for: clip, in: project)
        selectedClipID = id
        selectedGapID = nil
        selectedMouseFollowZoomSegmentID = nil

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
        let undoSnapshot = interactionOriginalSnapshot
        let actionName = switch interactionKind {
        case .move: "Move Clip"
        case .trim: "Trim Clip"
        case nil: "Edit Clip"
        }
        interactionOriginalSnapshot = nil
        interactionOriginalProject = nil
        interactionOriginalClip = nil
        interactionKind = nil
        interactionPreviewVideoID = nil
        interactionAnchorTime = 0
        interactionSnapTime = 0

        if changed || usedSourcePreview {
            if changed, let undoSnapshot {
                registerUndo(undoSnapshot, actionName: actionName)
            }
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
    let selectedMouseFollowZoomSegmentID: UUID?
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

private enum MouseZoomInteractionKind: Equatable {
    case move(UUID)
    case trim(UUID, TimelineTrimEdge)
}
