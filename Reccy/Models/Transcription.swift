import Foundation

nonisolated enum TranscriptionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech
    case whisperKit

    var id: Self { self }

    var title: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisperKit: "WhisperKit"
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech:
            "Native, private, and optimized by macOS. Language models are managed by the system."
        case .whisperKit:
            "OpenAI Whisper running locally through Core ML. Reccy manages the selected model."
        }
    }

    var systemImage: String {
        switch self {
        case .appleSpeech: "apple.intelligence"
        case .whisperKit: "waveform.badge.magnifyingglass"
        }
    }
}

nonisolated enum TranscriptTrackRole: String, Codable, CaseIterable, Sendable {
    case systemAudio
    case microphone
    case voiceover
    case unknown

    var title: String {
        switch self {
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        case .voiceover: "Voiceover"
        case .unknown: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic"
        case .voiceover: "waveform.badge.mic"
        case .unknown: "waveform"
        }
    }

    init(laneKind: TimelineLaneKind) {
        switch laneKind {
        case .systemAudio: self = .systemAudio
        case .microphone: self = .microphone
        case .voiceover: self = .voiceover
        case .video: self = .unknown
        }
    }
}

nonisolated struct TranscriptWord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var sourceStart: TimeInterval
    var duration: TimeInterval
    var confidence: Double?

    var sourceEnd: TimeInterval { sourceStart + duration }
}

nonisolated struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var correctedText: String?
    var sourceStart: TimeInterval
    var duration: TimeInterval
    var confidence: Double?
    var alternatives: [String] = []
    var words: [TranscriptWord]

    var sourceEnd: TimeInterval { sourceStart + duration }
    var displayText: String {
        let correction = correctedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return correction?.isEmpty == false ? correction! : text
    }
}

nonisolated struct TranscriptTrack: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceTrackID: Int32
    var role: TranscriptTrackRole
    var name: String
    var provider: TranscriptionProvider
    var localeIdentifier: String
    var modelIdentifier: String
    var generatedAt = Date()
    var segments: [TranscriptSegment]

    var text: String {
        segments
            .map(\.displayText)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct TranscriptDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = currentFormatVersion
    var mediaFileName: String
    var modifiedAt = Date()
    var tracks: [TranscriptTrack]

    mutating func replace(_ track: TranscriptTrack) {
        tracks.removeAll { $0.sourceTrackID == track.sourceTrackID && $0.role == track.role }
        tracks.append(track)
        tracks.sort {
            if $0.role == $1.role { return $0.sourceTrackID < $1.sourceTrackID }
            return $0.role.sortOrder < $1.role.sortOrder
        }
        modifiedAt = Date()
    }

    func track(sourceTrackID: Int32, role: TranscriptTrackRole? = nil) -> TranscriptTrack? {
        tracks.first {
            $0.sourceTrackID == sourceTrackID && (role == nil || $0.role == role)
        }
    }

    var searchableText: String {
        tracks.map(\.text).joined(separator: " ")
    }
}

nonisolated struct ProjectedTranscriptSegment: Identifiable, Hashable, Sendable {
    let id: String
    let sourceSegmentID: UUID
    let clipID: UUID
    let laneID: UUID
    let role: TranscriptTrackRole
    let text: String
    let timelineStart: TimeInterval
    let duration: TimeInterval

    var timelineEnd: TimeInterval { timelineStart + duration }
}

nonisolated enum TranscriptProjection {
    static func project(
        project: TimelineProject,
        documentsByMediaURL: [URL: TranscriptDocument]
    ) -> [ProjectedTranscriptSegment] {
        var projected: [ProjectedTranscriptSegment] = []

        for lane in project.lanes where lane.kind != .video {
            let role = TranscriptTrackRole(laneKind: lane.kind)
            for clip in lane.clips {
                guard
                    let document = documentsByMediaURL[clip.sourceURL],
                    let track = document.track(sourceTrackID: clip.sourceTrackID, role: role)
                        ?? document.track(sourceTrackID: clip.sourceTrackID)
                else { continue }

                let clipSourceEnd = clip.sourceStart + clip.duration
                for segment in track.segments {
                    let intersectionStart = max(segment.sourceStart, clip.sourceStart)
                    let intersectionEnd = min(segment.sourceEnd, clipSourceEnd)
                    guard intersectionEnd - intersectionStart > 0.001 else { continue }

                    let words = segment.words.filter {
                        $0.sourceEnd > clip.sourceStart + 0.001
                            && $0.sourceStart < clipSourceEnd - 0.001
                    }
                    let text = words.isEmpty
                        ? segment.displayText
                        : words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let timelineStart = clip.timelineStart + (intersectionStart - clip.sourceStart)
                    projected.append(ProjectedTranscriptSegment(
                        id: "\(clip.id.uuidString):\(segment.id.uuidString)",
                        sourceSegmentID: segment.id,
                        clipID: clip.id,
                        laneID: lane.id,
                        role: role,
                        text: text,
                        timelineStart: timelineStart,
                        duration: intersectionEnd - intersectionStart
                    ))
                }
            }
        }

        return projected.sorted {
            if abs($0.timelineStart - $1.timelineStart) > 0.001 {
                return $0.timelineStart < $1.timelineStart
            }
            return $0.role.sortOrder < $1.role.sortOrder
        }
    }
}

nonisolated extension TranscriptTrackRole {
    fileprivate var sortOrder: Int {
        switch self {
        case .systemAudio: 0
        case .microphone: 1
        case .voiceover: 2
        case .unknown: 3
        }
    }
}

nonisolated enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case srt
    case webVTT

    var id: Self { self }

    var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .srt: "SubRip (.srt)"
        case .webVTT: "WebVTT (.vtt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .srt: "srt"
        case .webVTT: "vtt"
        }
    }
}

nonisolated enum TranscriptExportFormatter {
    static func string(
        segments: [ProjectedTranscriptSegment],
        format: TranscriptExportFormat
    ) -> String {
        switch format {
        case .plainText:
            return segments.map(\.text).joined(separator: "\n")
        case .srt:
            return segments.enumerated().map { index, segment in
                """
                \(index + 1)
                \(timestamp(segment.timelineStart, separator: ",")) --> \(timestamp(segment.timelineEnd, separator: ","))
                \(segment.text)
                """
            }.joined(separator: "\n\n")
        case .webVTT:
            let cues = segments.map { segment in
                """
                \(timestamp(segment.timelineStart, separator: ".")) --> \(timestamp(segment.timelineEnd, separator: "."))
                \(segment.text)
                """
            }.joined(separator: "\n\n")
            return "WEBVTT\n\n\(cues)"
        }
    }

    private static func timestamp(_ time: TimeInterval, separator: Character) -> String {
        let milliseconds = max(0, Int((time * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, String(separator), remainder)
    }
}
