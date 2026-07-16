import CoreGraphics
import Foundation

enum MouseFollowZoomLevel: Double, CaseIterable, Identifiable, Codable, Sendable {
    case subtle = 1.5
    case standard = 2
    case close = 2.5
    case closer = 3
    case detail = 4

    var id: Self { self }
    var title: String { rawValue.formatted(.number.precision(.fractionLength(rawValue == floor(rawValue) ? 0 : 1))) + "×" }
}

nonisolated struct MouseFollowZoomPoint: Codable, Hashable, Sendable {
    var timelineTime: TimeInterval
    var x: Double
    var y: Double

    init(timelineTime: TimeInterval, position: CGPoint) {
        self.timelineTime = max(0, timelineTime)
        x = min(max(position.x, 0), 1)
        y = min(max(position.y, 0), 1)
    }

    var position: CGPoint {
        CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

nonisolated struct MouseFollowZoomSegment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var zoomScale: Double
    var points: [MouseFollowZoomPoint]

    init(
        id: UUID = UUID(),
        timelineStart: TimeInterval,
        duration: TimeInterval,
        zoomScale: Double,
        points: [MouseFollowZoomPoint]
    ) {
        self.id = id
        self.timelineStart = max(0, timelineStart)
        self.duration = max(0, duration)
        self.zoomScale = min(max(zoomScale, 1.25), 4)
        self.points = points.deduplicatedMouseZoomPoints()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timelineStart
        case duration
        case zoomScale
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            timelineStart: try container.decode(TimeInterval.self, forKey: .timelineStart),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            zoomScale: try container.decode(Double.self, forKey: .zoomScale),
            points: try container.decodeIfPresent(
                [MouseFollowZoomPoint].self,
                forKey: .points
            ) ?? []
        )
    }

    var timelineEnd: TimeInterval { timelineStart + duration }

    func contains(_ time: TimeInterval) -> Bool {
        time >= timelineStart && time < timelineEnd
    }

    func focus(at time: TimeInterval) -> CGPoint {
        // Points are normalized into timeline order when capture/edit operations
        // create a segment. Playback calls this once per rendered frame, so use
        // binary search rather than sorting and scanning the full pointer path.
        guard let first = points.first else { return CGPoint(x: 0.5, y: 0.5) }
        guard time > first.timelineTime else { return first.position }
        guard let last = points.last else { return first.position }
        guard time < last.timelineTime else { return last.position }

        var lowerBound = 1
        var upperBound = points.count - 1
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if points[midpoint].timelineTime < time {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        let lower = points[lowerBound - 1]
        let upper = points[lowerBound]
        let span = upper.timelineTime - lower.timelineTime
        guard span > 0.000_1 else { return upper.position }
        let progress = min(max((time - lower.timelineTime) / span, 0), 1)
        return CGPoint(
            x: lower.x + (upper.x - lower.x) * progress,
            y: lower.y + (upper.y - lower.y) * progress
        )
    }

    func trimmed(to range: Range<TimeInterval>, minimumDuration: TimeInterval) -> MouseFollowZoomSegment? {
        let start = max(timelineStart, range.lowerBound)
        let end = min(timelineEnd, range.upperBound)
        guard end - start >= minimumDuration else { return nil }

        var result = self
        result.timelineStart = start
        result.duration = end - start
        result.points = points.filter { $0.timelineTime >= start && $0.timelineTime <= end }
        result.points.insert(
            MouseFollowZoomPoint(timelineTime: start, position: focus(at: start)),
            at: 0
        )
        result.points.append(MouseFollowZoomPoint(timelineTime: end, position: focus(at: end)))
        result.points = result.points.deduplicatedMouseZoomPoints()
        return result
    }

    /// Changes an effect boundary without inventing pointer motion. Extending
    /// holds the nearest captured focus point; shortening interpolates an exact
    /// boundary point so subsequent edits and exports remain deterministic.
    func resized(to range: Range<TimeInterval>, minimumDuration: TimeInterval) -> MouseFollowZoomSegment? {
        guard range.lowerBound >= 0,
              range.upperBound - range.lowerBound >= minimumDuration
        else { return nil }
        var result = self
        result.timelineStart = range.lowerBound
        result.duration = range.upperBound - range.lowerBound
        result.points = points.filter {
            $0.timelineTime >= range.lowerBound && $0.timelineTime <= range.upperBound
        }
        result.points.insert(
            MouseFollowZoomPoint(
                timelineTime: range.lowerBound,
                position: focus(at: range.lowerBound)
            ),
            at: 0
        )
        result.points.append(
            MouseFollowZoomPoint(
                timelineTime: range.upperBound,
                position: focus(at: range.upperBound)
            )
        )
        result.points = result.points.deduplicatedMouseZoomPoints()
        return result
    }

    func shifted(by offset: TimeInterval) -> MouseFollowZoomSegment {
        var result = self
        result.timelineStart = max(0, timelineStart + offset)
        result.points = points.map {
            MouseFollowZoomPoint(
                timelineTime: max(0, $0.timelineTime + offset),
                position: $0.position
            )
        }
        return result
    }
}

nonisolated struct MouseFollowZoomTrack: Codable, Hashable, Sendable {
    var segments: [MouseFollowZoomSegment]

    func activeSegment(at time: TimeInterval) -> MouseFollowZoomSegment? {
        segments.first(where: { $0.contains(time) })
    }

    mutating func normalize(projectDuration: TimeInterval, minimumDuration: TimeInterval) {
        let projectRange = 0..<max(0, projectDuration)
        segments = segments
            .compactMap { segment in
                segment.trimmed(to: projectRange, minimumDuration: minimumDuration)
            }
            .sorted { $0.timelineStart < $1.timelineStart }
        if segments.isEmpty { return }

        var normalized: [MouseFollowZoomSegment] = []
        for segment in segments {
            let lowerBound = normalized.last?.timelineEnd ?? 0
            guard lowerBound < projectRange.upperBound else { break }
            guard let clamped = segment.trimmed(
                to: lowerBound..<projectRange.upperBound,
                minimumDuration: minimumDuration
            ) else { continue }
            normalized.append(clamped)
        }
        segments = normalized
    }

    mutating func split(at time: TimeInterval, minimumDuration: TimeInterval) {
        guard let index = segments.firstIndex(where: { $0.contains(time) }) else { return }
        let segment = segments[index]
        guard
            let left = segment.trimmed(
                to: segment.timelineStart..<time,
                minimumDuration: minimumDuration
            ),
            var right = segment.trimmed(
                to: time..<segment.timelineEnd,
                minimumDuration: minimumDuration
            )
        else { return }
        right.id = UUID()
        segments.replaceSubrange(index...index, with: [left, right])
    }

    mutating func rippleDelete(
        timeRange: Range<TimeInterval>,
        projectDuration: TimeInterval,
        minimumDuration: TimeInterval
    ) {
        let removedDuration = timeRange.upperBound - timeRange.lowerBound
        guard removedDuration > 0 else { return }

        var updated: [MouseFollowZoomSegment] = []
        for segment in segments {
            if segment.timelineEnd <= timeRange.lowerBound {
                updated.append(segment)
                continue
            }
            if segment.timelineStart >= timeRange.upperBound {
                updated.append(segment.shifted(by: -removedDuration))
                continue
            }
            if let before = segment.trimmed(
                to: segment.timelineStart..<timeRange.lowerBound,
                minimumDuration: minimumDuration
            ) {
                updated.append(before)
            }
            if let after = segment.trimmed(
                to: timeRange.upperBound..<segment.timelineEnd,
                minimumDuration: minimumDuration
            ) {
                var shifted = after.shifted(by: -removedDuration)
                shifted.id = UUID()
                updated.append(shifted)
            }
        }
        segments = updated
        normalize(projectDuration: projectDuration, minimumDuration: minimumDuration)
    }
}

/// Captures only timeline metadata. The full-resolution source remains intact;
/// Monitor, Editor, Library, and export all render this same non-destructive track.
nonisolated struct MouseFollowZoomCaptureSession: Sendable {
    private(set) var completedSegments: [MouseFollowZoomSegment] = []
    private(set) var activeSegment: MouseFollowZoomSegment?
    private var smoothedPosition: CGPoint?

    var isActive: Bool { activeSegment != nil }
    var currentPosition: CGPoint? { smoothedPosition ?? activeSegment?.points.last?.position }
    var currentScale: Double? { activeSegment?.zoomScale }

    mutating func begin(
        at timelineTime: TimeInterval,
        zoomScale: Double,
        position: CGPoint
    ) {
        guard activeSegment == nil else { return }
        let time = max(0, timelineTime)
        let position = clamped(position)
        smoothedPosition = position
        activeSegment = MouseFollowZoomSegment(
            timelineStart: time,
            duration: 0,
            zoomScale: min(max(zoomScale, 1.25), 4),
            points: [MouseFollowZoomPoint(timelineTime: time, position: position)]
        )
    }

    mutating func sample(at timelineTime: TimeInterval, position: CGPoint) {
        guard var segment = activeSegment else { return }
        let time = max(segment.timelineStart, timelineTime)
        let target = clamped(position)
        let previous = smoothedPosition ?? target
        let smoothing = 0.32
        let smoothed = CGPoint(
            x: previous.x + (target.x - previous.x) * smoothing,
            y: previous.y + (target.y - previous.y) * smoothing
        )
        smoothedPosition = smoothed

        if let last = segment.points.last {
            let elapsed = time - last.timelineTime
            let movement = hypot(smoothed.x - last.x, smoothed.y - last.y)
            // Cap capture at 15 Hz even if UI telemetry becomes faster. While
            // stationary, retain a point every quarter-second so the next
            // movement does not interpolate backward across a long pause.
            if elapsed < 1 / 15 || (movement < 0.002 && elapsed < 0.25) {
                activeSegment = segment
                return
            }
        }
        segment.points.append(MouseFollowZoomPoint(timelineTime: time, position: smoothed))
        segment.duration = max(0, time - segment.timelineStart)
        activeSegment = segment
    }

    mutating func end(at timelineTime: TimeInterval, minimumDuration: TimeInterval = 1 / 30) {
        guard var segment = activeSegment else { return }
        let end = max(segment.timelineStart, timelineTime)
        segment.duration = end - segment.timelineStart
        let position = smoothedPosition ?? segment.points.last?.position ?? CGPoint(x: 0.5, y: 0.5)
        segment.points.append(MouseFollowZoomPoint(timelineTime: end, position: position))
        if segment.duration >= minimumDuration {
            segment.points = segment.points.deduplicatedMouseZoomPoints()
            completedSegments.append(segment)
        }
        activeSegment = nil
        smoothedPosition = nil
    }

    mutating func toggle(
        at timelineTime: TimeInterval,
        zoomScale: Double,
        position: CGPoint
    ) {
        if isActive {
            end(at: timelineTime)
        } else {
            begin(at: timelineTime, zoomScale: zoomScale, position: position)
        }
    }

    mutating func finish(at timelineTime: TimeInterval) -> MouseFollowZoomTrack? {
        end(at: timelineTime)
        guard !completedSegments.isEmpty else { return nil }
        return MouseFollowZoomTrack(segments: completedSegments)
    }

    private func clamped(_ position: CGPoint) -> CGPoint {
        CGPoint(x: min(max(position.x, 0), 1), y: min(max(position.y, 0), 1))
    }
}

private extension Array where Element == MouseFollowZoomPoint {
    nonisolated func deduplicatedMouseZoomPoints() -> [MouseFollowZoomPoint] {
        sorted { $0.timelineTime < $1.timelineTime }.reduce(into: []) { result, point in
            if let last = result.last, abs(last.timelineTime - point.timelineTime) < 0.000_1 {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
    }
}
