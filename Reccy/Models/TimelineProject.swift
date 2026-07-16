import AVFoundation
import CoreGraphics
import Foundation

enum TimelineLaneKind: String, Codable, CaseIterable, Sendable {
    case video
    case camera
    case systemAudio
    case microphone
    case voiceover

    var title: String {
        switch self {
        case .video: "Screen"
        case .camera: "Camera"
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        case .voiceover: "Voiceover"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .camera: "web.camera"
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic"
        case .voiceover: "waveform.badge.mic"
        }
    }

    var mediaType: AVMediaType {
        isVideo ? .video : .audio
    }

    nonisolated var isVideo: Bool { self == .video || self == .camera }
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

    func clamped(minimumSize: Double = 0.08) -> TimelineVideoLayout {
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

    var timelineEnd: TimeInterval { timelineStart + duration }

    func contains(_ time: TimeInterval) -> Bool {
        time > timelineStart + 0.001 && time < timelineEnd - 0.001
    }

    func split(at time: TimeInterval) -> (TimelineClip, TimelineClip)? {
        guard contains(time) else { return nil }
        let leftDuration = time - timelineStart
        let rightDuration = duration - leftDuration

        var left = self
        left.id = UUID()
        left.duration = leftDuration

        var right = self
        right.id = UUID()
        right.sourceStart += leftDuration
        right.timelineStart = time
        right.duration = rightDuration
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

struct TimelineProject: Identifiable, Codable, Equatable, Sendable {
    static let currentFormatVersion = 5

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

    init(
        name: String,
        frameRate: Double = 30,
        lanes: [TimelineLane],
        videoGaps: [TimelineGapSegment] = [],
        mouseFollowZoomTrack: MouseFollowZoomTrack? = nil,
        captionTrack: TimelineCaptionTrack? = nil
    ) {
        self.name = name
        self.frameRate = max(frameRate, 1)
        self.lanes = lanes
        self.videoGaps = videoGaps
        self.mouseFollowZoomTrack = mouseFollowZoomTrack
        self.captionTrack = captionTrack
        reconcileVideoGaps()
    }

    var duration: TimeInterval {
        lanes.flatMap(\.clips).map(\.timelineEnd).max() ?? 0
    }

    var frameDuration: TimeInterval { 1 / max(frameRate, 1) }

    func clip(id: UUID) -> TimelineClip? {
        lanes.lazy.flatMap(\.clips).first(where: { $0.id == id })
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
                    let sourceBound = candidate.timelineStart - candidate.sourceStart
                    let neighbourBound = stationary
                        .filter { $0.timelineEnd <= candidate.timelineStart + 0.001 }
                        .map(\.timelineEnd)
                        .max() ?? 0
                    let lowerBound = max(0, max(sourceBound, neighbourBound))
                    let upperBound = candidate.timelineEnd - minimumDuration
                    let finalTime = min(max(proposed, lowerBound), upperBound)
                    let delta = finalTime - candidate.timelineStart
                    lanes[laneIndex].clips[clipIndex].timelineStart = finalTime
                    lanes[laneIndex].clips[clipIndex].sourceStart += delta
                    lanes[laneIndex].clips[clipIndex].duration -= delta
                    if candidate.id == selected.id { selectedResult = finalTime }

                case .trailing:
                    let sourceBound = candidate.timelineStart + max(0, sourceDuration - candidate.sourceStart)
                    let neighbourBound = stationary
                        .filter { $0.timelineStart >= candidate.timelineEnd - 0.001 }
                        .map(\.timelineStart)
                        .min() ?? sourceBound
                    let lowerBound = candidate.timelineStart + minimumDuration
                    let upperBound = min(sourceBound, neighbourBound)
                    let finalTime = min(max(proposed, lowerBound), upperBound)
                    lanes[laneIndex].clips[clipIndex].duration = finalTime - candidate.timelineStart
                    if candidate.id == selected.id { selectedResult = finalTime }
                }
            }
            lanes[laneIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        }
        reconcileVideoGaps()
        modifiedAt = Date()
        return selectedResult
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
            zoomScale: min(max(zoomScale, 1.25), 4),
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
        track.segments[index].zoomScale = min(max(scale, 1.25), 4)
        mouseFollowZoomTrack = track
        modifiedAt = Date()
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
            let anchor = originalOrder[affectedLower...affectedUpper].map(\.timelineStart).min() ?? 0
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
