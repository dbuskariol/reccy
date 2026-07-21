import AVFoundation
import CoreGraphics
import Foundation

enum TimelineLaneKind: String, Codable, CaseIterable, Sendable {
    case video
    case camera
    case importedVideo
    case systemAudio
    case microphone
    case voiceover
    case importedAudio

    var title: String {
        switch self {
        case .video: "Screen"
        case .camera: "Camera"
        case .importedVideo: "Imported Video"
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        case .voiceover: "Voiceover"
        case .importedAudio: "Imported Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .camera: "web.camera"
        case .importedVideo: "rectangle.on.rectangle"
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic"
        case .voiceover: "waveform.badge.mic"
        case .importedAudio: "waveform.badge.plus"
        }
    }

    var mediaType: AVMediaType {
        isVideo ? .video : .audio
    }

    nonisolated var isVideo: Bool { self == .video || isOverlayVideo }
    nonisolated var isOverlayVideo: Bool { self == .camera || self == .importedVideo }
    nonisolated var isAudio: Bool { !isVideo }
}

/// A render-canvas-relative box for a secondary video clip. Coordinates are
/// normalized so camera placement survives source-resolution and export changes.
struct TimelineVideoLayout: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let defaultCamera = TimelineVideoLayout(x: 0.69, y: 0.69, width: 0.28, height: 0.28)

    nonisolated static func defaultImportedVideo(
        canvasSize: CGSize,
        sourceSize: CGSize
    ) -> TimelineVideoLayout {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              sourceSize.width > 0,
              sourceSize.height > 0
        else { return TimelineVideoLayout(x: 0.2, y: 0.2, width: 0.6, height: 0.6) }
        let width = 0.6
        let sourceAspect = sourceSize.width / sourceSize.height
        let height = min(
            0.8,
            width * Double(canvasSize.width / canvasSize.height) / Double(sourceAspect)
        )
        return TimelineVideoLayout(
            x: (1 - width) / 2,
            y: (1 - height) / 2,
            width: width,
            height: height
        ).clamped()
    }

    static func defaultCamera(canvasSize: CGSize, sourceSize: CGSize) -> TimelineVideoLayout {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              sourceSize.width > 0,
              sourceSize.height > 0
        else { return defaultCamera }
        let width = 0.28
        let sourceAspect = sourceSize.width / sourceSize.height
        let height = min(
            0.5,
            width * Double(canvasSize.width / canvasSize.height) / Double(sourceAspect)
        )
        let margin = 0.03
        return TimelineVideoLayout(
            x: 1 - width - margin,
            y: 1 - height - margin,
            width: width,
            height: height
        ).clamped()
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated func clamped(minimumSize: Double = 0.08) -> TimelineVideoLayout {
        let width = min(max(self.width, minimumSize), 1)
        let height = min(max(self.height, minimumSize), 1)
        return TimelineVideoLayout(
            x: min(max(x, 0), 1 - width),
            y: min(max(y, 0), 1 - height),
            width: width,
            height: height
        )
    }

    /// Applies a normalized canvas offset while preserving the overlay size.
    /// This is shared by direct manipulation and non-pointer editor commands.
    func movedBy(x deltaX: Double, y deltaY: Double) -> TimelineVideoLayout {
        let original = clamped()
        return TimelineVideoLayout(
            x: original.x + deltaX,
            y: original.y + deltaY,
            width: original.width,
            height: original.height
        ).clamped()
    }

    /// Resizes around the overlay center without changing its aspect ratio.
    /// If the requested size reaches a canvas edge, the box moves only as much
    /// as needed to remain fully visible.
    func scaledBy(_ requestedScale: Double, minimumSize: Double = 0.08) -> TimelineVideoLayout {
        let original = clamped(minimumSize: minimumSize)
        guard requestedScale.isFinite, requestedScale > 0 else { return original }

        let minimumScale = max(
            minimumSize / original.width,
            minimumSize / original.height
        )
        let maximumScale = min(
            1 / original.width,
            1 / original.height
        )
        let scale = min(max(requestedScale, minimumScale), maximumScale)
        let width = original.width * scale
        let height = original.height * scale
        let centerX = original.x + original.width / 2
        let centerY = original.y + original.height / 2

        return TimelineVideoLayout(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        ).clamped(minimumSize: minimumSize)
    }
}

/// A canvas-relative center point for the live camera overlay. Capture stores
/// position independently from size so a saved placement remains correct when
/// the selected camera or capture canvas has a different aspect ratio. The
/// recording manifest resolves this point against its concrete camera layout,
/// which is then shared by Editor, Library preview, and export.
nonisolated struct CameraOverlayPosition: Codable, Hashable, Sendable {
    var centerX: Double
    var centerY: Double

    init(centerX: Double, centerY: Double) {
        self.centerX = centerX
        self.centerY = centerY
    }

    init(layout: TimelineVideoLayout) {
        let layout = layout.clamped()
        centerX = layout.x + layout.width / 2
        centerY = layout.y + layout.height / 2
    }

    nonisolated func applying(to proposedLayout: TimelineVideoLayout) -> TimelineVideoLayout {
        let layout = proposedLayout.clamped()
        return TimelineVideoLayout(
            x: centerX - layout.width / 2,
            y: centerY - layout.height / 2,
            width: layout.width,
            height: layout.height
        ).clamped()
    }
}

enum TimelinePlaybackDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case forward
    case reverse

    var id: Self { self }

    var title: String {
        switch self {
        case .forward: "Forward"
        case .reverse: "Reverse"
        }
    }
}

/// Persisted, non-destructive temporal and transition parameters for a clip.
/// Source media is never rewritten; the composition builder applies the same
/// mapping for editor preview, Library playback, and rendered export.
struct TimelineClipEffects: Codable, Hashable, Sendable {
    nonisolated static let supportedPlaybackRates: [Double] = [0.25, 0.5, 1, 2, 4]

    var playbackRate: Double = 1
    var direction: TimelinePlaybackDirection = .forward
    var fadeInDuration: TimeInterval = 0
    var fadeOutDuration: TimeInterval = 0

    nonisolated func clamped(to clipDuration: TimeInterval) -> TimelineClipEffects {
        var result = self
        result.playbackRate = Self.supportedPlaybackRates.min {
            abs($0 - playbackRate) < abs($1 - playbackRate)
        } ?? 1
        result.fadeInDuration = min(max(fadeInDuration, 0), max(clipDuration, 0))
        result.fadeOutDuration = min(max(fadeOutDuration, 0), max(clipDuration, 0))
        let combined = result.fadeInDuration + result.fadeOutDuration
        if combined > clipDuration, combined > 0 {
            let scale = max(clipDuration, 0) / combined
            result.fadeInDuration *= scale
            result.fadeOutDuration *= scale
        }
        return result
    }

    nonisolated var isIdentity: Bool {
        playbackRate == 1
            && direction == .forward
            && fadeInDuration == 0
            && fadeOutDuration == 0
    }
}

/// Source-relative crop edges plus a centered output scale. Values are stored
/// independently of source and render dimensions so projects remain portable
/// across preview and export sizes.
struct TimelineVideoAdjustment: Codable, Hashable, Sendable {
    var cropTop: Double = 0
    var cropLeading: Double = 0
    var cropBottom: Double = 0
    var cropTrailing: Double = 0
    var scale: Double = 1

    nonisolated func clamped() -> TimelineVideoAdjustment {
        var result = self
        result.cropTop = min(max(cropTop, 0), 0.9)
        result.cropLeading = min(max(cropLeading, 0), 0.9)
        result.cropBottom = min(max(cropBottom, 0), 0.9)
        result.cropTrailing = min(max(cropTrailing, 0), 0.9)
        result.scale = min(max(scale.isFinite ? scale : 1, 0.25), 4)

        let vertical = result.cropTop + result.cropBottom
        if vertical > 0.9 {
            let factor = 0.9 / vertical
            result.cropTop *= factor
            result.cropBottom *= factor
        }
        let horizontal = result.cropLeading + result.cropTrailing
        if horizontal > 0.9 {
            let factor = 0.9 / horizontal
            result.cropLeading *= factor
            result.cropTrailing *= factor
        }
        return result
    }

    nonisolated var isIdentity: Bool {
        cropTop == 0
            && cropLeading == 0
            && cropBottom == 0
            && cropTrailing == 0
            && scale == 1
    }
}

enum TimelineCaptionPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom
    case top

    var id: Self { self }

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        }
    }
}

enum TimelineCaptionSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case large

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .large: "Large"
        }
    }

    var renderScale: Double {
        switch self {
        case .standard: 0.046
        case .large: 0.058
        }
    }
}

struct TimelineCaptionStyle: Codable, Hashable, Sendable {
    var placement: TimelineCaptionPlacement = .bottom
    var size: TimelineCaptionSize = .standard
}

enum TimelineCaptionOrigin: String, Codable, Sendable {
    case transcript
    case manual
}

struct TimelineCaptionCue: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var origin: TimelineCaptionOrigin = .manual

    nonisolated var timelineEnd: TimeInterval { timelineStart + duration }

    nonisolated func contains(_ time: TimeInterval) -> Bool {
        timelineStart <= time && time < timelineEnd
    }
}

struct TimelineCaptionTrack: Codable, Hashable, Sendable {
    var isVisible = true
    var style = TimelineCaptionStyle()
    var cues: [TimelineCaptionCue]

    nonisolated func activeCue(at time: TimeInterval) -> TimelineCaptionCue? {
        let ordered = cues.sorted { $0.timelineStart < $1.timelineStart }
        guard let index = ordered.lastIndex(where: { $0.timelineStart <= time }) else {
            return nil
        }
        let nextStart = ordered.indices.contains(index + 1)
            ? ordered[index + 1].timelineStart
            : .greatestFiniteMagnitude
        return time < nextStart ? ordered[index] : nil
    }

    /// Returns non-overlapping cues whose visible ranges meet exactly at the
    /// next detected caption. This is the single timing policy used by editor
    /// preview, Library playback, and offline export.
    nonisolated func presentationCues(through projectDuration: TimeInterval) -> [TimelineCaptionCue] {
        let endOfProject = max(0, projectDuration)
        let ordered = cues.sorted { $0.timelineStart < $1.timelineStart }

        return ordered.indices.compactMap { index in
            var cue = ordered[index]
            cue.timelineStart = max(0, cue.timelineStart)
            guard cue.timelineStart < endOfProject else { return nil }

            let nextStart = ordered.indices.contains(index + 1)
                ? max(cue.timelineStart, ordered[index + 1].timelineStart)
                : endOfProject
            let presentationEnd = min(endOfProject, nextStart)
            guard presentationEnd > cue.timelineStart else { return nil }
            cue.duration = presentationEnd - cue.timelineStart
            return cue
        }
    }

    /// Moves one caption boundary without allowing cues to cross. Caption
    /// durations are then normalized to the next boundary so preview, timeline,
    /// and export continue to share exactly the same presentation ranges.
    @discardableResult
    nonisolated mutating func moveCue(
        id: UUID,
        to proposedStart: TimeInterval,
        frameDuration: TimeInterval,
        projectDuration: TimeInterval
    ) -> TimeInterval? {
        let ordered = cues.sorted { $0.timelineStart < $1.timelineStart }
        guard let orderedIndex = ordered.firstIndex(where: { $0.id == id }),
              let storageIndex = cues.firstIndex(where: { $0.id == id })
        else { return nil }

        let spacing = max(frameDuration, 1 / 600)
        let lowerBound = orderedIndex > 0
            ? ordered[orderedIndex - 1].timelineStart + spacing
            : 0
        let upperBound = ordered.indices.contains(orderedIndex + 1)
            ? ordered[orderedIndex + 1].timelineStart - spacing
            : max(0, projectDuration - spacing)
        guard lowerBound <= upperBound else { return nil }

        let start = min(max(proposedStart, lowerBound), upperBound)
        cues[storageIndex].timelineStart = start
        cues = presentationCues(through: projectDuration)
        return start
    }
}

struct TimelineClip: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceURL: URL
    var sourceTrackID: Int32
    var sourceStart: TimeInterval
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var name: String
    var linkedGroupID: UUID?
    var videoLayout: TimelineVideoLayout? = nil
    /// Optional for backward-compatible decoding of format 3–6 projects.
    var effects: TimelineClipEffects? = nil
    /// Video-only source crop and centered sizing. Audio clips leave this nil.
    var videoAdjustment: TimelineVideoAdjustment? = nil
    /// The project-owned original image for a generated single-frame proxy.
    /// Presence distinguishes an indefinitely trimmable still from a movie.
    var stillImageOriginalURL: URL? = nil

    var timelineEnd: TimeInterval { timelineStart + duration }
    nonisolated var effectiveEffects: TimelineClipEffects {
        (effects ?? TimelineClipEffects()).clamped(to: duration)
    }
    nonisolated var effectiveVideoAdjustment: TimelineVideoAdjustment {
        (videoAdjustment ?? TimelineVideoAdjustment()).clamped()
    }
    nonisolated var sourceSpanDuration: TimeInterval { duration * effectiveEffects.playbackRate }
    nonisolated var sourceEnd: TimeInterval { sourceStart + sourceSpanDuration }

    nonisolated func sourceTime(atTimelineOffset requestedOffset: TimeInterval) -> TimeInterval {
        let effects = effectiveEffects
        let offset = min(max(requestedOffset, 0), duration) * effects.playbackRate
        switch effects.direction {
        case .forward:
            return min(sourceEnd, sourceStart + offset)
        case .reverse:
            return max(sourceStart, sourceEnd - offset)
        }
    }

    func contains(_ time: TimeInterval) -> Bool {
        time > timelineStart + 0.001 && time < timelineEnd - 0.001
    }

    func split(at time: TimeInterval) -> (TimelineClip, TimelineClip)? {
        guard contains(time) else { return nil }
        let leftDuration = time - timelineStart
        let rightDuration = duration - leftDuration

        let effects = effectiveEffects
        var left = self
        left.id = UUID()
        left.duration = leftDuration
        if effects.direction == .reverse {
            left.sourceStart += rightDuration * effects.playbackRate
        }
        var leftEffects = effects
        leftEffects.fadeOutDuration = 0
        left.effects = leftEffects.clamped(to: leftDuration).isIdentity
            ? nil
            : leftEffects.clamped(to: leftDuration)

        var right = self
        right.id = UUID()
        if effects.direction == .forward {
            right.sourceStart += leftDuration * effects.playbackRate
        }
        right.timelineStart = time
        right.duration = rightDuration
        var rightEffects = effects
        rightEffects.fadeInDuration = 0
        right.effects = rightEffects.clamped(to: rightDuration).isIdentity
            ? nil
            : rightEffects.clamped(to: rightDuration)
        return (left, right)
    }
}

enum TimelineTrimEdge: Equatable, Sendable {
    case leading
    case trailing
}

enum TimelineGapFillMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case black
    case holdPrevious
    case holdNext

    var id: Self { self }

    var title: String {
        switch self {
        case .black: "Black"
        case .holdPrevious: "Hold Previous"
        case .holdNext: "Hold Next"
        }
    }

    var systemImage: String {
        switch self {
        case .black: "square.fill"
        case .holdPrevious: "backward.end.fill"
        case .holdNext: "forward.end.fill"
        }
    }
}

struct TimelineGapSegment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var fillMode: TimelineGapFillMode = .black

    var timelineEnd: TimeInterval { timelineStart + duration }

    func contains(_ time: TimeInterval) -> Bool {
        time >= timelineStart && time <= timelineEnd
    }
}

struct TimelineLane: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: TimelineLaneKind
    var name: String
    var isMuted = false
    var volume: Double = 1
    var clips: [TimelineClip]
}

enum TimelineClipSelectionIntent: Equatable, Sendable {
    case replace
    case toggle
    case extend(additive: Bool)
}

/// The editor's Mac-style clip selection state. Keeping the anchor separate
/// from the primary clip preserves conventional Shift-click behavior after a
/// discontiguous Command-click selection.
struct TimelineClipSelection: Equatable, Sendable {
    var selectedIDs: Set<UUID> = []
    var primaryID: UUID?
    var anchorID: UUID?

    mutating func select(
        _ id: UUID,
        from orderedIDs: [UUID],
        intent: TimelineClipSelectionIntent
    ) {
        guard let targetIndex = orderedIDs.firstIndex(of: id) else { return }

        switch intent {
        case .replace:
            selectedIDs = [id]
            primaryID = id
            anchorID = id

        case .toggle:
            if selectedIDs.remove(id) != nil {
                if primaryID == id {
                    primaryID = orderedIDs.first(where: selectedIDs.contains)
                }
                if selectedIDs.isEmpty {
                    anchorID = nil
                } else if anchorID == id {
                    anchorID = primaryID
                }
            } else {
                selectedIDs.insert(id)
                primaryID = id
                anchorID = id
            }

        case .extend(let additive):
            let anchorIndex = anchorID.flatMap { orderedIDs.firstIndex(of: $0) }
                ?? primaryID.flatMap { orderedIDs.firstIndex(of: $0) }
                ?? targetIndex
            let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            let rangeIDs = Set(orderedIDs[bounds])
            selectedIDs = additive ? selectedIDs.union(rangeIDs) : rangeIDs
            primaryID = id
            anchorID = orderedIDs[anchorIndex]
        }
    }

    mutating func selectAll(_ orderedIDs: [UUID]) {
        selectedIDs = Set(orderedIDs)
        guard !orderedIDs.isEmpty else {
            primaryID = nil
            anchorID = nil
            return
        }
        if let primaryID, selectedIDs.contains(primaryID) {
            anchorID = primaryID
        } else {
            primaryID = orderedIDs[0]
            anchorID = orderedIDs[0]
        }
    }

    mutating func reconcile(with orderedIDs: [UUID]) {
        let validIDs = Set(orderedIDs)
        selectedIDs.formIntersection(validIDs)
        if let primaryID, !validIDs.contains(primaryID) {
            self.primaryID = orderedIDs.first(where: selectedIDs.contains)
        }
        if let anchorID, !validIDs.contains(anchorID) {
            self.anchorID = primaryID
        }
        if selectedIDs.isEmpty {
            primaryID = nil
            anchorID = nil
        }
    }

    mutating func clear() {
        selectedIDs.removeAll()
        primaryID = nil
        anchorID = nil
    }
}

enum TimelineViewportPolicy {
    static let maximumPixelsPerSecond: Double = 220
    static let fallbackMinimumPixelsPerSecond: Double = 4

    /// Returns the exact scale at which the project endpoint fits inside the
    /// clip viewport. Long projects may legitimately need less than one point
    /// per second; the slider remains precise instead of imposing an arbitrary
    /// lower zoom bound.
    static func minimumPixelsPerSecond(
        duration: TimeInterval,
        viewportWidth: CGFloat
    ) -> Double {
        guard duration.isFinite,
              duration > 0,
              viewportWidth.isFinite,
              viewportWidth > 0
        else { return fallbackMinimumPixelsPerSecond }
        return min(
            maximumPixelsPerSecond,
            max(Double(viewportWidth) / duration, 0.01)
        )
    }

    static func rulerInterval(pixelsPerSecond: Double) -> TimeInterval {
        let candidates: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1_800, 3_600]
        let scale = max(pixelsPerSecond, 0.01)
        return candidates.first(where: { $0 * scale >= 64 }) ?? candidates[candidates.count - 1]
    }
}

enum TimelinePlaybackFollowPolicy {
    /// Returns a direction-aware scroll target only after the playhead enters
    /// the viewport's edge comfort zone. Callers own paused/manual-navigation
    /// suppression so this remains deterministic and independently testable.
    static func targetOffset(
        previousTime: TimeInterval,
        currentTime: TimeInterval,
        pixelsPerSecond: Double,
        viewportOffset: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat? {
        guard pixelsPerSecond.isFinite,
              pixelsPerSecond > 0,
              viewportOffset.isFinite,
              viewportWidth.isFinite,
              viewportWidth > 0
        else { return nil }
        let playheadX = CGFloat(currentTime * pixelsPerSecond)
        let trailing = viewportOffset + viewportWidth
        let margin = min(max(viewportWidth * 0.12, 32), 96)
        if currentTime < previousTime, playheadX < viewportOffset + margin {
            return playheadX - viewportWidth * 0.28
        }
        if currentTime >= previousTime, playheadX > trailing - margin {
            return playheadX - viewportWidth * 0.72
        }
        if playheadX < viewportOffset || playheadX > trailing {
            return playheadX - viewportWidth / 2
        }
        return nil
    }
}

struct TimelineProject: Identifiable, Codable, Equatable, Sendable {
    static let currentFormatVersion = 7

    var formatVersion = currentFormatVersion
    var id = UUID()
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var frameRate: Double
    var lanes: [TimelineLane]
    var videoGaps: [TimelineGapSegment]
    var mouseFollowZoomTrack: MouseFollowZoomTrack?
    var captionTrack: TimelineCaptionTrack?
    var posterFrameTime: TimeInterval?

    init(
        name: String,
        frameRate: Double = 30,
        lanes: [TimelineLane],
        videoGaps: [TimelineGapSegment] = [],
        mouseFollowZoomTrack: MouseFollowZoomTrack? = nil,
        captionTrack: TimelineCaptionTrack? = nil,
        posterFrameTime: TimeInterval? = nil
    ) {
        self.name = name
        self.frameRate = max(frameRate, 1)
        self.lanes = lanes
        self.videoGaps = videoGaps
        self.mouseFollowZoomTrack = mouseFollowZoomTrack
        self.captionTrack = captionTrack
        self.posterFrameTime = posterFrameTime
        normalizeTimelineBounds()
        reconcileVideoGaps()
    }

    var duration: TimeInterval {
        lanes.flatMap(\.clips).map(\.timelineEnd).max() ?? 0
    }

    var frameDuration: TimeInterval { 1 / max(frameRate, 1) }

    var effectivePosterFrameTime: TimeInterval {
        min(max(posterFrameTime ?? 0, 0), max(0, duration - frameDuration))
    }

    /// Repairs lane-local time bounds without changing source in-points. Clips
    /// in one lane are non-overlapping by contract, so this also prevents a
    /// malformed or older imported clip from rendering before time zero or
    /// crossing its preceding neighbour when the project is reopened.
    @discardableResult
    mutating func normalizeTimelineBounds() -> Bool {
        var changed = false
        for laneIndex in lanes.indices {
            var clips = lanes[laneIndex].clips.sorted {
                if abs($0.timelineStart - $1.timelineStart) < 0.000_1 {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.timelineStart < $1.timelineStart
            }
            var earliestAvailableStart: TimeInterval = 0
            for clipIndex in clips.indices {
                let requestedStart = clips[clipIndex].timelineStart
                let finiteStart = requestedStart.isFinite ? requestedStart : earliestAvailableStart
                let normalizedStart = max(max(earliestAvailableStart, finiteStart), 0)
                if abs(normalizedStart - requestedStart) > 0.000_1 || !requestedStart.isFinite {
                    clips[clipIndex].timelineStart = normalizedStart
                    changed = true
                }
                earliestAvailableStart = clips[clipIndex].timelineEnd
            }
            if clips != lanes[laneIndex].clips {
                lanes[laneIndex].clips = clips
                changed = true
            }
        }
        if changed {
            modifiedAt = Date()
        }
        return changed
    }

    mutating func setPosterFrame(at time: TimeInterval) {
        let clamped = min(max(time, 0), max(0, duration - frameDuration))
        guard abs((posterFrameTime ?? 0) - clamped) > 0.000_1 else { return }
        posterFrameTime = clamped
        modifiedAt = Date()
    }

    func clip(id: UUID) -> TimelineClip? {
        lanes.lazy.flatMap(\.clips).first(where: { $0.id == id })
    }

    /// Visual reading order for native range selection: time first, followed
    /// by the stable top-to-bottom lane order for clips sharing a boundary.
    var orderedClipIDs: [UUID] {
        lanes.enumerated()
            .flatMap { laneIndex, lane in
                lane.clips.map { (clip: $0, laneIndex: laneIndex) }
            }
            .sorted { lhs, rhs in
                if abs(lhs.clip.timelineStart - rhs.clip.timelineStart) > 0.000_1 {
                    return lhs.clip.timelineStart < rhs.clip.timelineStart
                }
                if lhs.laneIndex != rhs.laneIndex {
                    return lhs.laneIndex < rhs.laneIndex
                }
                return lhs.clip.id.uuidString < rhs.clip.id.uuidString
            }
            .map(\.clip.id)
    }

    func videoGap(id: UUID) -> TimelineGapSegment? {
        videoGaps.first(where: { $0.id == id })
    }

    func mouseFollowZoomSegment(id: UUID) -> MouseFollowZoomSegment? {
        mouseFollowZoomTrack?.segments.first(where: { $0.id == id })
    }

    mutating func setGapFillMode(_ mode: TimelineGapFillMode, gapID: UUID) {
        guard let index = videoGaps.firstIndex(where: { $0.id == gapID }) else { return }
        videoGaps[index].fillMode = mode
        modifiedAt = Date()
    }

    mutating func splitAll(at time: TimeInterval) {
        for laneIndex in lanes.indices {
            var updated: [TimelineClip] = []
            for clip in lanes[laneIndex].clips {
                if let (left, right) = clip.split(at: time) {
                    updated.append(contentsOf: [left, right])
                } else {
                    updated.append(clip)
                }
            }
            lanes[laneIndex].clips = updated.sorted { $0.timelineStart < $1.timelineStart }
        }
        if var track = mouseFollowZoomTrack {
            track.split(at: time, minimumDuration: frameDuration)
            mouseFollowZoomTrack = track
        }
        reconcileVideoGaps()
        modifiedAt = Date()
    }

    @discardableResult
    mutating func splitClip(id: UUID, at time: TimeInterval) -> UUID? {
        for laneIndex in lanes.indices {
            guard let clipIndex = lanes[laneIndex].clips.firstIndex(where: { $0.id == id }) else {
                continue
            }
            guard let (left, right) = lanes[laneIndex].clips[clipIndex].split(at: time) else {
                return nil
            }
            lanes[laneIndex].clips.replaceSubrange(clipIndex...clipIndex, with: [left, right])
            reconcileVideoGaps()
            modifiedAt = Date()
            return right.id
        }
        return nil
    }

    mutating func deleteClip(id: UUID) {
        for laneIndex in lanes.indices {
            lanes[laneIndex].clips.removeAll { $0.id == id }
        }
        reconcileVideoGaps()
        modifiedAt = Date()
    }

    mutating func deleteClips(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for laneIndex in lanes.indices {
            lanes[laneIndex].clips.removeAll { ids.contains($0.id) }
        }
        reconcileVideoGaps()
        modifiedAt = Date()
    }

    /// Moves a discontiguous selection as one rigid group. The shared delta is
    /// clamped against time zero and the nearest stationary clip in every
    /// affected lane, so clips never drift relative to one another or overlap.
    @discardableResult
    mutating func moveClips(
        ids requestedIDs: Set<UUID>,
        anchorID: UUID,
        to desiredAnchorStart: TimeInterval,
        includeLinked: Bool = false,
        snapTargets: [TimeInterval] = [],
        snapTolerance: TimeInterval = 0
    ) -> TimeInterval? {
        normalizeTimelineBounds()
        guard let anchor = clip(id: anchorID), requestedIDs.contains(anchorID) else { return nil }

        var movingIDs = requestedIDs
        if includeLinked {
            for id in requestedIDs {
                if let selected = clip(id: id) {
                    movingIDs.formUnion(linkedClipIDs(matching: selected))
                }
            }
        }
        let movingClips = lanes.flatMap(\.clips).filter { movingIDs.contains($0.id) }
        guard !movingClips.isEmpty else { return nil }

        var delta = desiredAnchorStart - anchor.timelineStart
        let stationary = lanes.flatMap(\.clips).filter { !movingIDs.contains($0.id) }
        if snapTolerance > 0 {
            let groupStart = movingClips.map(\.timelineStart).min() ?? anchor.timelineStart
            let groupEnd = movingClips.map(\.timelineEnd).max() ?? anchor.timelineEnd
            let targets = [0] + snapTargets + stationary.flatMap { [$0.timelineStart, $0.timelineEnd] }
            let corrections = targets.flatMap { [$0 - (groupStart + delta), $0 - (groupEnd + delta)] }
            if let correction = corrections.min(by: { abs($0) < abs($1) }),
               abs(correction) <= snapTolerance
            {
                delta += correction
            }
        }

        var lowerDelta = -(movingClips.map(\.timelineStart).min() ?? 0)
        var upperDelta = TimeInterval.greatestFiniteMagnitude
        for lane in lanes {
            let laneMoving = lane.clips.filter { movingIDs.contains($0.id) }
            let laneStationary = lane.clips.filter { !movingIDs.contains($0.id) }
            for moving in laneMoving {
                if let previousEnd = laneStationary
                    .filter({ $0.timelineEnd <= moving.timelineStart + 0.000_1 })
                    .map(\.timelineEnd)
                    .max()
                {
                    lowerDelta = max(lowerDelta, previousEnd - moving.timelineStart)
                }
                if let nextStart = laneStationary
                    .filter({ $0.timelineStart >= moving.timelineEnd - 0.000_1 })
                    .map(\.timelineStart)
                    .min()
                {
                    upperDelta = min(upperDelta, nextStart - moving.timelineEnd)
                }
            }
        }
        delta = min(max(delta, lowerDelta), upperDelta)

        for laneIndex in lanes.indices {
            for clipIndex in lanes[laneIndex].clips.indices
                where movingIDs.contains(lanes[laneIndex].clips[clipIndex].id)
            {
                lanes[laneIndex].clips[clipIndex].timelineStart += delta
            }
            lanes[laneIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        }
        reconcileVideoGaps()
        modifiedAt = Date()
        return anchor.timelineStart + delta
    }

    /// Moves one clip by default. Linked A/V movement is an explicit editing
    /// mode so audio can be slipped independently from picture. Crossing a
    /// neighbouring clip uses magnetic insertion order instead of blocking the
    /// drag at the collision boundary.
    @discardableResult
    mutating func moveClip(
        id: UUID,
        to desiredTimelineStart: TimeInterval,
        includeLinked: Bool = false,
        snapTargets: [TimeInterval] = [],
        snapTolerance: TimeInterval = 0
    ) -> TimeInterval? {
        normalizeTimelineBounds()
        guard let selected = clip(id: id) else { return nil }

        let movingIDs = includeLinked ? linkedClipIDs(matching: selected) : [selected.id]
        let requestedDelta = desiredTimelineStart - selected.timelineStart
        var selectedResult = selected.timelineStart

        for laneIndex in lanes.indices {
            let laneMovingIDs = movingIDs.intersection(Set(lanes[laneIndex].clips.map(\.id)))
            guard !laneMovingIDs.isEmpty else { continue }

            // A linked group contributes at most one matching clip per lane.
            // Keeping this lane-local also means magnetic insertion never
            // disturbs clips on unrelated audio tracks.
            for movingID in laneMovingIDs {
                guard let moving = lanes[laneIndex].clips.first(where: { $0.id == movingID }) else {
                    continue
                }
                let proposed = moving.timelineStart + requestedDelta
                let finalStart = moveClipInLane(
                    laneIndex: laneIndex,
                    id: movingID,
                    to: proposed,
                    snapTargets: snapTargets,
                    snapTolerance: snapTolerance
                )
                if movingID == selected.id {
                    selectedResult = finalStart
                }
            }
        }
        reconcileVideoGaps()
        modifiedAt = Date()
        return selectedResult
    }

    /// Trims a clip without changing playback speed. A leading trim moves both
    /// its timeline and source in-points; a trailing trim changes only the out-
    /// point. Expanding is bounded by the source asset and neighbouring clips.
    @discardableResult
    mutating func trimClip(
        id: UUID,
        edge: TimelineTrimEdge,
        to desiredTimelineTime: TimeInterval,
        sourceDuration: TimeInterval,
        includeLinked: Bool = false,
        minimumDuration: TimeInterval = 1 / 30,
        snapTargets: [TimeInterval] = [],
        snapTolerance: TimeInterval = 0
    ) -> TimeInterval? {
        guard let selected = clip(id: id) else { return nil }
        let trimmingIDs = includeLinked ? linkedClipIDs(matching: selected) : [selected.id]
        let selectedBoundary = edge == .leading ? selected.timelineStart : selected.timelineEnd
        let requestedDelta = desiredTimelineTime - selectedBoundary
        var selectedResult = selectedBoundary

        for laneIndex in lanes.indices {
            for clipIndex in lanes[laneIndex].clips.indices {
                let candidate = lanes[laneIndex].clips[clipIndex]
                guard trimmingIDs.contains(candidate.id) else { continue }

                let stationary = lanes[laneIndex].clips.filter { !trimmingIDs.contains($0.id) }
                var proposed = (edge == .leading ? candidate.timelineStart : candidate.timelineEnd) + requestedDelta
                if snapTolerance > 0 {
                    let targets = [0] + snapTargets + stationary.flatMap { [$0.timelineStart, $0.timelineEnd] }
                    if let target = targets.min(by: { abs($0 - proposed) < abs($1 - proposed) }),
                       abs(target - proposed) <= snapTolerance
                    {
                        proposed = target
                    }
                }

                switch edge {
                case .leading:
                    let effects = candidate.effectiveEffects
                    let sourceExpansion = effects.direction == .forward
                        ? candidate.sourceStart / effects.playbackRate
                        : max(0, sourceDuration - candidate.sourceEnd) / effects.playbackRate
                    let sourceBound = candidate.timelineStart - sourceExpansion
                    let neighbourBound = stationary
                        .filter { $0.timelineEnd <= candidate.timelineStart + 0.001 }
                        .map(\.timelineEnd)
                        .max() ?? 0
                    let lowerBound = max(0, max(sourceBound, neighbourBound))
                    let upperBound = candidate.timelineEnd - minimumDuration
                    let finalTime = min(max(proposed, lowerBound), upperBound)
                    let delta = finalTime - candidate.timelineStart
                    lanes[laneIndex].clips[clipIndex].timelineStart = finalTime
                    if effects.direction == .forward {
                        lanes[laneIndex].clips[clipIndex].sourceStart += delta * effects.playbackRate
                    }
                    lanes[laneIndex].clips[clipIndex].duration -= delta
                    normalizeEffects(laneIndex: laneIndex, clipIndex: clipIndex)
                    if candidate.id == selected.id { selectedResult = finalTime }

                case .trailing:
                    let effects = candidate.effectiveEffects
                    let maximumDuration = effects.direction == .forward
                        ? max(0, sourceDuration - candidate.sourceStart) / effects.playbackRate
                        : candidate.sourceEnd / effects.playbackRate
                    let sourceBound = candidate.timelineStart + maximumDuration
                    let neighbourBound = stationary
                        .filter { $0.timelineStart >= candidate.timelineEnd - 0.001 }
                        .map(\.timelineStart)
                        .min() ?? sourceBound
                    let lowerBound = candidate.timelineStart + minimumDuration
                    let upperBound = min(sourceBound, neighbourBound)
                    let finalTime = min(max(proposed, lowerBound), upperBound)
                    let finalDuration = finalTime - candidate.timelineStart
                    if effects.direction == .reverse {
                        lanes[laneIndex].clips[clipIndex].sourceStart = candidate.sourceEnd
                            - finalDuration * effects.playbackRate
                    }
                    lanes[laneIndex].clips[clipIndex].duration = finalDuration
                    normalizeEffects(laneIndex: laneIndex, clipIndex: clipIndex)
                    if candidate.id == selected.id { selectedResult = finalTime }
                }
            }
            lanes[laneIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        }
        reconcileVideoGaps()
        modifiedAt = Date()
        return selectedResult
    }

    /// Changes speed without changing the selected source range. Lane-local
    /// ripple preserves every following gap and linked A/V remains aligned when
    /// the caller expands the selection through `includeLinked`.
    mutating func setPlaybackRate(
        _ requestedRate: Double,
        clipIDs requestedIDs: Set<UUID>,
        includeLinked: Bool = true
    ) {
        guard !requestedIDs.isEmpty else { return }
        let rate = TimelineClipEffects.supportedPlaybackRates.min {
            abs($0 - requestedRate) < abs($1 - requestedRate)
        } ?? 1
        let editingIDs = expandedClipIDs(requestedIDs, includeLinked: includeLinked)
        let canonicalEdits = playbackTimeWarpEdits(
            rate: rate,
            editingIDs: editingIDs
        )

        for laneIndex in lanes.indices {
            var accumulatedShift: TimeInterval = 0
            let ordered = lanes[laneIndex].clips.sorted { $0.timelineStart < $1.timelineStart }
            var updated: [TimelineClip] = []
            for var clip in ordered {
                clip.timelineStart += accumulatedShift
                if editingIDs.contains(clip.id) {
                    let oldDuration = clip.duration
                    var effects = clip.effectiveEffects
                    let sourceSpan = clip.sourceSpanDuration
                    effects.playbackRate = rate
                    clip.duration = sourceSpan / rate
                    clip.effects = effects.clamped(to: clip.duration).isIdentity
                        ? nil
                        : effects.clamped(to: clip.duration)
                    accumulatedShift += clip.duration - oldDuration
                }
                updated.append(clip)
            }
            lanes[laneIndex].clips = updated
        }
        applyPlaybackTimeWarp(canonicalEdits)
        reconcileVideoGaps()
        modifiedAt = Date()
    }

    mutating func setPlaybackDirection(
        _ direction: TimelinePlaybackDirection,
        clipIDs requestedIDs: Set<UUID>,
        includeLinked: Bool = true
    ) {
        let editingIDs = expandedClipIDs(requestedIDs, includeLinked: includeLinked)
        guard !editingIDs.isEmpty else { return }
        for laneIndex in lanes.indices {
            for clipIndex in lanes[laneIndex].clips.indices
                where editingIDs.contains(lanes[laneIndex].clips[clipIndex].id)
            {
                var effects = lanes[laneIndex].clips[clipIndex].effectiveEffects
                effects.direction = direction
                lanes[laneIndex].clips[clipIndex].effects = effects.isIdentity ? nil : effects
            }
        }
        modifiedAt = Date()
    }

    mutating func setFadeDurations(
        fadeIn: TimeInterval? = nil,
        fadeOut: TimeInterval? = nil,
        clipIDs requestedIDs: Set<UUID>,
        includeLinked: Bool = true
    ) {
        let editingIDs = expandedClipIDs(requestedIDs, includeLinked: includeLinked)
        guard !editingIDs.isEmpty else { return }
        for laneIndex in lanes.indices {
            for clipIndex in lanes[laneIndex].clips.indices
                where editingIDs.contains(lanes[laneIndex].clips[clipIndex].id)
            {
                let duration = lanes[laneIndex].clips[clipIndex].duration
                var effects = lanes[laneIndex].clips[clipIndex].effectiveEffects
                if let fadeIn { effects.fadeInDuration = fadeIn }
                if let fadeOut { effects.fadeOutDuration = fadeOut }
                effects = effects.clamped(to: duration)
                lanes[laneIndex].clips[clipIndex].effects = effects.isIdentity ? nil : effects
            }
        }
        modifiedAt = Date()
    }

    mutating func setVideoAdjustment(
        _ adjustment: TimelineVideoAdjustment,
        clipIDs requestedIDs: Set<UUID>
    ) {
        let normalized = adjustment.clamped()
        for laneIndex in lanes.indices where lanes[laneIndex].kind.isVideo {
            for clipIndex in lanes[laneIndex].clips.indices
                where requestedIDs.contains(lanes[laneIndex].clips[clipIndex].id)
            {
                lanes[laneIndex].clips[clipIndex].videoAdjustment = normalized.isIdentity
                    ? nil
                    : normalized
            }
        }
        modifiedAt = Date()
    }

    mutating func rippleDelete(timeRange: Range<TimeInterval>) {
        guard timeRange.lowerBound >= 0, timeRange.upperBound > timeRange.lowerBound else { return }
        splitAll(at: timeRange.lowerBound)
        splitAll(at: timeRange.upperBound)
        let removedDuration = timeRange.upperBound - timeRange.lowerBound

        for laneIndex in lanes.indices {
            lanes[laneIndex].clips.removeAll {
                $0.timelineStart >= timeRange.lowerBound - 0.001
                    && $0.timelineEnd <= timeRange.upperBound + 0.001
            }
            for clipIndex in lanes[laneIndex].clips.indices
                where lanes[laneIndex].clips[clipIndex].timelineStart >= timeRange.upperBound - 0.001
            {
                lanes[laneIndex].clips[clipIndex].timelineStart -= removedDuration
            }
        }
        if var track = mouseFollowZoomTrack {
            let projectDuration = duration
            let minimumDuration = frameDuration
            track.rippleDelete(
                timeRange: timeRange,
                projectDuration: projectDuration,
                minimumDuration: minimumDuration
            )
            mouseFollowZoomTrack = track
        }
        if mouseFollowZoomTrack?.segments.isEmpty == true {
            mouseFollowZoomTrack = nil
        }
        reconcileVideoGaps()
        modifiedAt = Date()
    }

    @discardableResult
    mutating func addMouseFollowZoomSegment(
        at start: TimeInterval,
        duration requestedDuration: TimeInterval = 2,
        zoomScale: Double = 2,
        position: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> UUID? {
        let start = min(max(start, 0), max(0, duration - frameDuration))
        let end = min(duration, start + max(requestedDuration, frameDuration))
        guard end - start >= frameDuration else { return nil }

        let existing = mouseFollowZoomTrack?.segments ?? []
        guard !existing.contains(where: {
            start >= $0.timelineStart - 0.000_1
                && start < $0.timelineEnd - 0.000_1
        }) else { return nil }
        let nextStart = existing
            .filter { $0.timelineStart > start }
            .map(\.timelineStart)
            .min() ?? duration
        let previousEnd = existing
            .filter { $0.timelineEnd <= start }
            .map(\.timelineEnd)
            .max() ?? 0
        guard start >= previousEnd - 0.000_1 else { return nil }
        let finalEnd = min(end, nextStart)
        guard finalEnd - start >= frameDuration else { return nil }

        let segment = MouseFollowZoomSegment(
            timelineStart: start,
            duration: finalEnd - start,
            zoomScale: MouseFollowZoomScale.clamped(zoomScale),
            points: [
                MouseFollowZoomPoint(timelineTime: start, position: position),
                MouseFollowZoomPoint(timelineTime: finalEnd, position: position),
            ]
        )
        var track = mouseFollowZoomTrack ?? MouseFollowZoomTrack(segments: [])
        track.segments.append(segment)
        track.normalize(projectDuration: duration, minimumDuration: frameDuration)
        mouseFollowZoomTrack = track
        modifiedAt = Date()
        return segment.id
    }

    mutating func deleteMouseFollowZoomSegment(id: UUID) {
        guard var track = mouseFollowZoomTrack else { return }
        track.segments.removeAll { $0.id == id }
        mouseFollowZoomTrack = track.segments.isEmpty ? nil : track
        modifiedAt = Date()
    }

    mutating func setMouseFollowZoomScale(_ scale: Double, segmentID: UUID) {
        guard var track = mouseFollowZoomTrack,
              let index = track.segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        track.segments[index].zoomScale = MouseFollowZoomScale.clamped(scale)
        mouseFollowZoomTrack = track
        modifiedAt = Date()
    }

    /// Moves an effect as one unit while preserving its captured pointer path.
    /// Mouse-follow effects share one lane, so movement is bounded by time zero,
    /// the neighbouring effects, and the end of the underlying media project.
    @discardableResult
    mutating func moveMouseFollowZoomSegment(
        id: UUID,
        to proposedStart: TimeInterval
    ) -> TimeInterval? {
        guard var track = mouseFollowZoomTrack else { return nil }
        track.segments.sort { $0.timelineStart < $1.timelineStart }
        guard let index = track.segments.firstIndex(where: { $0.id == id }) else { return nil }

        let segment = track.segments[index]
        let previousEnd = index > 0 ? track.segments[index - 1].timelineEnd : 0
        let nextStart = track.segments.indices.contains(index + 1)
            ? track.segments[index + 1].timelineStart
            : duration
        let latestStart = max(previousEnd, nextStart - segment.duration)
        let finiteStart = proposedStart.isFinite ? proposedStart : segment.timelineStart
        let finalStart = min(max(finiteStart, previousEnd), latestStart)

        track.segments[index] = segment.shifted(by: finalStart - segment.timelineStart)
        mouseFollowZoomTrack = track
        modifiedAt = Date()
        return finalStart
    }

    @discardableResult
    mutating func trimMouseFollowZoomSegment(
        id: UUID,
        edge: TimelineTrimEdge,
        to proposedTime: TimeInterval
    ) -> TimeInterval? {
        guard var track = mouseFollowZoomTrack,
              let index = track.segments.firstIndex(where: { $0.id == id })
        else { return nil }
        let segment = track.segments[index]
        let previousEnd = index > 0 ? track.segments[index - 1].timelineEnd : 0
        let nextStart = track.segments.indices.contains(index + 1)
            ? track.segments[index + 1].timelineStart
            : duration

        let range: Range<TimeInterval>
        let boundary: TimeInterval
        switch edge {
        case .leading:
            boundary = min(
                max(proposedTime, previousEnd),
                segment.timelineEnd - frameDuration
            )
            range = boundary..<segment.timelineEnd
        case .trailing:
            boundary = min(
                max(proposedTime, segment.timelineStart + frameDuration),
                nextStart
            )
            range = segment.timelineStart..<boundary
        }
        guard let trimmed = segment.resized(to: range, minimumDuration: frameDuration) else {
            return nil
        }
        track.segments[index] = trimmed
        mouseFollowZoomTrack = track
        modifiedAt = Date()
        return boundary
    }

    /// Rebuilds visual gap segments from the video layout. Existing fill
    /// choices follow the same gap as its boundaries move; newly created gaps
    /// start as black.
    mutating func reconcileVideoGaps() {
        let previousGaps = videoGaps
        let videoClips = lanes
            .first(where: { $0.kind == .video })?
            .clips
            .sorted(by: { $0.timelineStart < $1.timelineStart }) ?? []
        let projectDuration = duration
        var ranges: [Range<TimeInterval>] = []
        var cursor: TimeInterval = 0

        for clip in videoClips {
            if clip.timelineStart > cursor + 0.000_1 {
                ranges.append(cursor..<clip.timelineStart)
            }
            cursor = max(cursor, clip.timelineEnd)
        }
        if projectDuration > cursor + 0.000_1 {
            ranges.append(cursor..<projectDuration)
        }

        var available = previousGaps
        videoGaps = ranges.map { range in
            let bestIndex = available.indices.max { lhs, rhs in
                overlap(of: range, with: available[lhs]) < overlap(of: range, with: available[rhs])
            }
            guard
                let bestIndex,
                overlap(of: range, with: available[bestIndex]) > 0.000_1
            else {
                return TimelineGapSegment(
                    timelineStart: range.lowerBound,
                    duration: range.upperBound - range.lowerBound
                )
            }

            var preserved = available.remove(at: bestIndex)
            preserved.timelineStart = range.lowerBound
            preserved.duration = range.upperBound - range.lowerBound
            return preserved
        }
        if var track = mouseFollowZoomTrack {
            let minimumDuration = frameDuration
            track.normalize(
                projectDuration: projectDuration,
                minimumDuration: minimumDuration
            )
            mouseFollowZoomTrack = track
        }
        if mouseFollowZoomTrack?.segments.isEmpty == true {
            mouseFollowZoomTrack = nil
        }
    }

    private func overlap(
        of range: Range<TimeInterval>,
        with gap: TimelineGapSegment
    ) -> TimeInterval {
        max(0, min(range.upperBound, gap.timelineEnd) - max(range.lowerBound, gap.timelineStart))
    }

    private func expandedClipIDs(
        _ requestedIDs: Set<UUID>,
        includeLinked: Bool
    ) -> Set<UUID> {
        guard includeLinked else { return requestedIDs }
        var result = requestedIDs
        for id in requestedIDs {
            if let clip = clip(id: id) {
                result.formUnion(linkedClipIDs(matching: clip))
            }
        }
        return result
    }

    private func playbackTimeWarpEdits(
        rate: Double,
        editingIDs: Set<UUID>
    ) -> [TimelinePlaybackTimeWarpEdit] {
        guard let lane = lanes.first(where: { $0.kind == .video }) else { return [] }
        var accumulatedShift: TimeInterval = 0
        return lane.clips
            .sorted { $0.timelineStart < $1.timelineStart }
            .compactMap { clip in
                let newStart = clip.timelineStart + accumulatedShift
                guard editingIDs.contains(clip.id) else { return nil }
                let newDuration = clip.sourceSpanDuration / rate
                let edit = TimelinePlaybackTimeWarpEdit(
                    oldRange: clip.timelineStart..<clip.timelineEnd,
                    newRange: newStart..<(newStart + newDuration)
                )
                accumulatedShift += newDuration - clip.duration
                return edit
            }
    }

    private mutating func applyPlaybackTimeWarp(_ edits: [TimelinePlaybackTimeWarpEdit]) {
        guard !edits.isEmpty else { return }
        if var track = captionTrack {
            track.cues = track.cues.compactMap { cue in
                var cue = cue
                let start = TimelinePlaybackTimeWarpEdit.map(cue.timelineStart, through: edits)
                let end = TimelinePlaybackTimeWarpEdit.map(cue.timelineEnd, through: edits)
                guard end - start >= frameDuration else { return nil }
                cue.timelineStart = start
                cue.duration = end - start
                return cue
            }
            captionTrack = track
        }
        if var track = mouseFollowZoomTrack {
            track.segments = track.segments.compactMap { segment in
                var segment = segment
                let start = TimelinePlaybackTimeWarpEdit.map(segment.timelineStart, through: edits)
                let end = TimelinePlaybackTimeWarpEdit.map(segment.timelineEnd, through: edits)
                guard end - start >= frameDuration else { return nil }
                segment.timelineStart = start
                segment.duration = end - start
                segment.points = segment.points.map {
                    MouseFollowZoomPoint(
                        timelineTime: TimelinePlaybackTimeWarpEdit.map(
                            $0.timelineTime,
                            through: edits
                        ),
                        position: $0.position
                    )
                }
                return segment
            }
            mouseFollowZoomTrack = track
        }
        if let posterFrameTime {
            self.posterFrameTime = TimelinePlaybackTimeWarpEdit.map(
                posterFrameTime,
                through: edits
            )
        }
    }

    private mutating func normalizeEffects(laneIndex: Int, clipIndex: Int) {
        let duration = lanes[laneIndex].clips[clipIndex].duration
        let effects = lanes[laneIndex].clips[clipIndex].effectiveEffects.clamped(to: duration)
        lanes[laneIndex].clips[clipIndex].effects = effects.isIdentity ? nil : effects
    }

    private func linkedClipIDs(matching selected: TimelineClip) -> Set<UUID> {
        guard let groupID = selected.linkedGroupID else { return [selected.id] }
        let tolerance = 0.002
        var matches: Set<UUID> = []
        for lane in lanes {
            for clip in lane.clips {
                let hasSameSourceRange = abs(clip.sourceStart - selected.sourceStart) < tolerance
                    && abs(clip.duration - selected.duration) < tolerance
                let hasSameTimelineRange = abs(clip.timelineStart - selected.timelineStart) < tolerance
                if clip.linkedGroupID == groupID, hasSameSourceRange, hasSameTimelineRange {
                    matches.insert(clip.id)
                }
            }
        }
        return matches
    }

    private mutating func moveClipInLane(
        laneIndex: Int,
        id: UUID,
        to desiredTimelineStart: TimeInterval,
        snapTargets: [TimeInterval],
        snapTolerance: TimeInterval
    ) -> TimeInterval {
        let originalOrder = lanes[laneIndex].clips.sorted {
            if abs($0.timelineStart - $1.timelineStart) < 0.000_1 {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timelineStart < $1.timelineStart
        }
        guard
            let originalIndex = originalOrder.firstIndex(where: { $0.id == id }),
            let moving = originalOrder.first(where: { $0.id == id })
        else { return desiredTimelineStart }

        let stationary = originalOrder.filter { $0.id != id }
        var proposedStart = max(0, desiredTimelineStart)
        if snapTolerance > 0 {
            let targets = [0] + snapTargets + stationary.flatMap { [$0.timelineStart, $0.timelineEnd] }
            let proposedEnd = proposedStart + moving.duration
            let corrections = targets.flatMap { [$0 - proposedStart, $0 - proposedEnd] }
            if let correction = corrections.min(by: { abs($0) < abs($1) }),
               abs(correction) <= snapTolerance
            {
                proposedStart = max(0, proposedStart + correction)
            }
        }

        let proposedCenter = proposedStart + moving.duration / 2
        let insertionIndex = stationary.firstIndex {
            proposedCenter < $0.timelineStart + $0.duration / 2
        } ?? stationary.endIndex

        if insertionIndex != originalIndex {
            var reordered = stationary
            reordered.insert(moving, at: insertionIndex)
            let affectedLower = min(originalIndex, insertionIndex)
            let affectedUpper = max(originalIndex, insertionIndex)
            let anchor = max(
                0,
                originalOrder[affectedLower...affectedUpper].map(\.timelineStart).min() ?? 0
            )
            var cursor = anchor
            for index in affectedLower...affectedUpper {
                reordered[index].timelineStart = cursor
                cursor += reordered[index].duration
            }
            lanes[laneIndex].clips = reordered.sorted { $0.timelineStart < $1.timelineStart }
            return reordered.first(where: { $0.id == id })?.timelineStart ?? proposedStart
        }

        let previousEnd = insertionIndex > 0 ? stationary[insertionIndex - 1].timelineEnd : 0
        let nextStart = insertionIndex < stationary.count
            ? stationary[insertionIndex].timelineStart
            : TimeInterval.greatestFiniteMagnitude
        let availableUpper = nextStart - moving.duration
        let finalStart: TimeInterval
        if availableUpper >= previousEnd {
            finalStart = min(max(proposedStart, previousEnd), availableUpper)
        } else {
            finalStart = previousEnd
        }

        var moved = moving
        moved.timelineStart = finalStart
        var updated = stationary
        updated.insert(moved, at: insertionIndex)
        lanes[laneIndex].clips = updated.sorted { $0.timelineStart < $1.timelineStart }
        return finalStart
    }
}

private struct TimelinePlaybackTimeWarpEdit {
    let oldRange: Range<TimeInterval>
    let newRange: Range<TimeInterval>

    static func map(
        _ time: TimeInterval,
        through edits: [TimelinePlaybackTimeWarpEdit]
    ) -> TimeInterval {
        var accumulatedShift: TimeInterval = 0
        for edit in edits {
            if time < edit.oldRange.lowerBound {
                return max(0, time + accumulatedShift)
            }
            if time <= edit.oldRange.upperBound {
                let oldDuration = edit.oldRange.upperBound - edit.oldRange.lowerBound
                let newDuration = edit.newRange.upperBound - edit.newRange.lowerBound
                let progress = oldDuration > 0
                    ? (time - edit.oldRange.lowerBound) / oldDuration
                    : 0
                return max(0, edit.newRange.lowerBound + progress * newDuration)
            }
            accumulatedShift += (edit.newRange.upperBound - edit.newRange.lowerBound)
                - (edit.oldRange.upperBound - edit.oldRange.lowerBound)
        }
        return max(0, time + accumulatedShift)
    }
}
