import AVFoundation
import CoreMedia
import Foundation

nonisolated enum TranscriptionEngineAvailability: Equatable, Sendable {
    case ready
    case requiresDownload
    case unavailable(String)
}

/// One canonical readiness state for capture-time transcription. Recording
/// surfaces use this to explain cold model loading and to avoid starting a
/// live-transcription session before its on-device engine is usable.
nonisolated enum CaptureTranscriptionReadiness: Equatable, Sendable {
    case disabled
    case preparing(TranscriptionProgressUpdate)
    case ready
    case unavailable(String)

    var isReady: Bool { self == .ready }

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }
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

nonisolated struct LiveTranscriptUpdate: Equatable, Sendable {
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

nonisolated struct TranscriptionTrackFailure: Equatable, Sendable {
    let role: TranscriptTrackRole
    let name: String
    let message: String
}

nonisolated struct TranscriptionBatchResult: Sendable {
    let tracks: [TranscriptTrack]
    let failures: [TranscriptionTrackFailure]

    var failureMessage: String {
        guard failures.count > 1 else {
            return failures.first?.message
                ?? TranscriptionEngineError.noSpeechRecognized.localizedDescription
        }
        let names = failures.map(\.name).joined(separator: " and ")
        return "Reccy couldn’t transcribe \(names). \(failures[0].message)"
    }
}

/// Runs each independently recorded source as an independent transcription
/// attempt. Silence or a provider error on one lane must never discard usable
/// speech from another lane in the same recording.
nonisolated enum TranscriptionBatchProcessor {
    static func transcribe(
        _ requests: [TranscriptionTrackRequest],
        with engine: any TranscriptionEngine,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> TranscriptionBatchResult {
        var tracks: [TranscriptTrack] = []
        var failures: [TranscriptionTrackFailure] = []
        for request in requests {
            try Task.checkCancellation()
            do {
                tracks.append(try await engine.transcribe(request, progress: progress))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(TranscriptionTrackFailure(
                    role: request.role,
                    name: request.name,
                    message: error.localizedDescription
                ))
            }
        }
        return TranscriptionBatchResult(tracks: tracks, failures: failures)
    }
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
