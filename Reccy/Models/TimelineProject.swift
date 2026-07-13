import AVFoundation
import Foundation

enum TimelineLaneKind: String, Codable, CaseIterable, Sendable {
    case video
    case systemAudio
    case microphone
    case voiceover

    var title: String {
        switch self {
        case .video: "Screen"
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        case .voiceover: "Voiceover"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic"
        case .voiceover: "waveform.badge.mic"
        }
    }

    var mediaType: AVMediaType {
        self == .video ? .video : .audio
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

struct TimelineLane: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: TimelineLaneKind
    var name: String
    var isMuted = false
    var volume: Double = 1
    var clips: [TimelineClip]
}

struct TimelineProject: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var lanes: [TimelineLane]

    var duration: TimeInterval {
        lanes.flatMap(\.clips).map(\.timelineEnd).max() ?? 0
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
            modifiedAt = Date()
            return right.id
        }
        return nil
    }

    mutating func deleteClip(id: UUID) {
        for laneIndex in lanes.indices {
            lanes[laneIndex].clips.removeAll { $0.id == id }
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
        modifiedAt = Date()
    }
}
