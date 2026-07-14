import AVFoundation
import CoreMedia
import Foundation

nonisolated enum TranscriptionEngineAvailability: Equatable, Sendable {
    case ready
    case requiresDownload
    case unavailable(String)
}

nonisolated struct TranscriptionTrackRequest: Sendable {
    let mediaURL: URL
    let sourceTrackID: Int32
    let role: TranscriptTrackRole
    let name: String
    let localeIdentifier: String
}

nonisolated struct TranscriptionProgressUpdate: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case downloadingModel
        case readingAudio
        case transcribing
        case finalizing
    }

    let phase: Phase
    let fractionCompleted: Double?
    let detail: String?
}

nonisolated struct LiveTranscriptUpdate: Sendable {
    let role: TranscriptTrackRole
    let finalizedSegments: [TranscriptSegment]
    let volatileSegments: [TranscriptSegment]
}

nonisolated struct TimedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let startTime: CMTime
}

nonisolated protocol LiveTranscriptionSession: Actor {
    var role: TranscriptTrackRole { get }
    func ingest(_ packet: TimedAudioBuffer) async
    func finish(sourceTrackID: Int32) async throws -> TranscriptTrack
    func cancel() async
}

nonisolated protocol TranscriptionEngine: Actor {
    var provider: TranscriptionProvider { get }
    func availability(localeIdentifier: String) async -> TranscriptionEngineAvailability
    func prepare(
        localeIdentifier: String,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws
    func transcribe(
        _ request: TranscriptionTrackRequest,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> TranscriptTrack
    func makeLiveSession(
        role: TranscriptTrackRole,
        name: String,
        localeIdentifier: String,
        update: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> any LiveTranscriptionSession
}

nonisolated enum TranscriptionEngineError: LocalizedError {
    case providerUnavailable(String)
    case localeUnsupported(String)
    case sourceTrackMissing(Int32)
    case cannotReadAudio
    case cannotConvertAudio
    case modelNotInstalled(String)
    case noSpeechRecognized

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let reason): reason
        case .localeUnsupported(let locale):
            "Transcription isn’t available for \(Locale.current.localizedString(forIdentifier: locale) ?? locale)."
        case .sourceTrackMissing(let trackID):
            "Audio track \(trackID) is no longer available in this recording."
        case .cannotReadAudio:
            "Reccy couldn’t read this recording’s audio for transcription."
        case .cannotConvertAudio:
            "Reccy couldn’t convert this audio into the transcription engine’s native format."
        case .modelNotInstalled(let model):
            "Download the \(model) WhisperKit model in Settings before using it."
        case .noSpeechRecognized:
            "No speech was recognized in this audio track."
        }
    }
}
