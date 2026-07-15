@preconcurrency import AVFoundation
import Foundation
import os
import Speech

actor AppleSpeechTranscriptionEngine: TranscriptionEngine {
    nonisolated let provider = TranscriptionProvider.appleSpeech

    func availability(localeIdentifier: String) async -> TranscriptionEngineAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("Apple Speech transcription isn’t available on this Mac.")
        }
        let requested = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            return .unavailable(TranscriptionEngineError.localeUnsupported(localeIdentifier).localizedDescription)
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .supported, .downloading: return .requiresDownload
        case .unsupported: return .unavailable(TranscriptionEngineError.localeUnsupported(localeIdentifier).localizedDescription)
        @unknown default: return .unavailable("Apple Speech model status is unavailable.")
        }
    }

    func prepare(
        localeIdentifier: String,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws {
        let locale = try await resolvedLocale(localeIdentifier)
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let status = await AssetInventory.status(forModules: [module])
        guard status != .unsupported else {
            throw TranscriptionEngineError.localeUnsupported(localeIdentifier)
        }

        if status != .installed {
            progress(.init(phase: .downloadingModel, fractionCompleted: nil, detail: "Downloading Apple’s (locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) speech model"))
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let observer = AppleSpeechProgressObserver(request: request, callback: progress)
                try await request.downloadAndInstall()
                _ = observer
            }
        }
        _ = try await AssetInventory.reserve(locale: locale)
        progress(.init(phase: .preparing, fractionCompleted: 1, detail: "Apple Speech is ready"))
    }

    func transcribe(
        _ request: TranscriptionTrackRequest,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> TranscriptTrack {
        try await prepare(localeIdentifier: request.localeIdentifier, progress: progress)
        let locale = try await resolvedLocale(request.localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )

        progress(.init(phase: .readingAudio, fractionCompleted: 0, detail: request.name))
        let audioURL = try await TranscriptionAudioReader.temporaryPCMTrack(
            mediaURL: request.mediaURL,
            sourceTrackID: request.sourceTrackID
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audioFile = try AVAudioFile(forReading: audioURL)
        progress(.init(phase: .readingAudio, fractionCompleted: 1, detail: request.name))

        let accumulator = AppleSpeechResultAccumulator(
            role: request.role,
            update: nil
        )
        let resultTask = Task {
            for try await result in transcriber.results {
                await accumulator.accept(result)
            }
        }

        do {
            progress(.init(phase: .transcribing, fractionCompleted: nil, detail: request.name))
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            progress(.init(phase: .finalizing, fractionCompleted: nil, detail: request.name))
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await resultTask.value
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let segments = await accumulator.finalizedSegments
        guard !segments.isEmpty else { throw TranscriptionEngineError.noSpeechRecognized }
        return TranscriptTrack(
            sourceTrackID: request.sourceTrackID,
            role: request.role,
            name: request.name,
            provider: provider,
            localeIdentifier: locale.identifier,
            modelIdentifier: "apple-speech-\(locale.identifier)",
            segments: segments
        )
    }

    func makeLiveSession(
        role: TranscriptTrackRole,
        name: String,
        localeIdentifier: String,
        update: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> any LiveTranscriptionSession {
        try await prepare(localeIdentifier: localeIdentifier) { _ in }
        let locale = try await resolvedLocale(localeIdentifier)
        return try await AppleSpeechLiveSession(
            role: role,
            name: name,
            locale: locale,
            update: update
        )
    }

    private func resolvedLocale(_ identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionEngineError.providerUnavailable("Apple Speech transcription isn’t available on this Mac.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw TranscriptionEngineError.localeUnsupported(identifier)
        }
        return locale
    }
}

private nonisolated final class AppleSpeechProgressObserver: @unchecked Sendable {
    private let observation: NSKeyValueObservation

    init(
        request: AssetInstallationRequest,
        callback: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) {
        observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            callback(.init(
                phase: .downloadingModel,
                fractionCompleted: progress.fractionCompleted,
                detail: "Downloading Apple Speech model"
            ))
        }
    }
}

private actor AppleSpeechResultAccumulator {
    let role: TranscriptTrackRole
    private let update: (@Sendable (LiveTranscriptUpdate) -> Void)?
    private(set) var finalizedSegments: [TranscriptSegment] = []
    private var volatileSegments: [TranscriptSegment] = []

    init(role: TranscriptTrackRole, update: (@Sendable (LiveTranscriptUpdate) -> Void)?) {
        self.role = role
        self.update = update
    }

    func accept(_ result: SpeechTranscriber.Result) {
        let segment = Self.segment(from: result)
        if result.isFinal {
            volatileSegments.removeAll { Self.overlaps($0, segment) }
            // SpeechTranscriber final results are immutable timeline additions. They
            // can touch (or slightly cross) phrase boundaries, so deleting every
            // intersecting final result drops already-confirmed words. Only replace
            // a result for the same revision window; later finalized phrases append.
            finalizedSegments.removeAll { Self.isSameRevisionWindow($0, segment) }
            finalizedSegments.append(segment)
            finalizedSegments.sort { $0.sourceStart < $1.sourceStart }
        } else {
            volatileSegments.removeAll { Self.overlaps($0, segment) }
            volatileSegments.append(segment)
            volatileSegments.sort { $0.sourceStart < $1.sourceStart }
        }
        update?(.init(
            role: role,
            finalizedSegments: finalizedSegments,
            volatileSegments: volatileSegments
        ))
    }

    private static func segment(from result: SpeechTranscriber.Result) -> TranscriptSegment {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = result.text.runs.compactMap { run -> TranscriptWord? in
            let word = String(result.text[run.range].characters)
            guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let timeRange = run.audioTimeRange ?? result.range
            return TranscriptWord(
                text: word,
                sourceStart: max(0, timeRange.start.seconds),
                duration: max(0, timeRange.duration.seconds),
                confidence: run.transcriptionConfidence
            )
        }
        let confidences = words.compactMap(\.confidence)
        return TranscriptSegment(
            text: text,
            sourceStart: max(0, result.range.start.seconds),
            duration: max(0, result.range.duration.seconds),
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            alternatives: result.alternatives.map { String($0.characters) },
            words: words
        )
    }

    private static func overlaps(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        lhs.sourceStart < rhs.sourceEnd && rhs.sourceStart < lhs.sourceEnd
    }

    private static func isSameRevisionWindow(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        let startTolerance = 0.05
        let durationTolerance = max(0.1, max(lhs.duration, rhs.duration) * 0.1)
        return abs(lhs.sourceStart - rhs.sourceStart) <= startTolerance
            && abs(lhs.duration - rhs.duration) <= durationTolerance
    }
}

private actor AppleSpeechLiveSession: LiveTranscriptionSession {
    nonisolated let role: TranscriptTrackRole
    private let name: String
    private let locale: Locale
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let analysisTask: Task<Void, Error>
    private let resultTask: Task<Void, Error>
    private let accumulator: AppleSpeechResultAccumulator
    private let converter = AppleSpeechBufferConverter()
    private var isFinished = false

    init(
        role: TranscriptTrackRole,
        name: String,
        locale: Locale,
        update: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws {
        self.role = role
        self.name = name
        self.locale = locale
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionEngineError.cannotConvertAudio
        }
        self.format = format
        let accumulator = AppleSpeechResultAccumulator(role: role, update: update)
        self.accumulator = accumulator

        var capturedContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation!
        let stream = AsyncThrowingStream<AnalyzerInput, Error>(bufferingPolicy: .bufferingNewest(128)) {
            capturedContinuation = $0
        }
        self.continuation = capturedContinuation

        try await analyzer.prepareToAnalyze(in: format)
        self.resultTask = Task {
            for try await result in transcriber.results {
                await accumulator.accept(result)
            }
        }
        self.analysisTask = Task {
            _ = try await analyzer.analyzeSequence(stream)
        }
    }

    func ingest(_ packet: TimedAudioBuffer) {
        guard !isFinished else { return }
        do {
            let converted = try converter.convert(packet.buffer, to: format)
            continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: packet.startTime))
        } catch {
            // Capture remains authoritative. A failed transcription conversion is isolated to this session.
        }
    }

    func finish(sourceTrackID: Int32) async throws -> TranscriptTrack {
        guard !isFinished else { throw CancellationError() }
        isFinished = true
        continuation.finish()
        try await analysisTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultTask.value
        return TranscriptTrack(
            sourceTrackID: sourceTrackID,
            role: role,
            name: name,
            provider: .appleSpeech,
            localeIdentifier: locale.identifier,
            modelIdentifier: "apple-speech-\(locale.identifier)",
            segments: await accumulator.finalizedSegments
        )
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish(throwing: CancellationError())
        analysisTask.cancel()
        resultTask.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// macOS 26's SpeechAnalyzer API requires callers to convert live buffers to
/// `bestAvailableAudioFormat`. This is the conversion pattern from Apple's
/// WWDC25 SpeechAnalyzer code-along; the framework-provided
/// `AnalyzerInputConverter` arrives in macOS 27 and is intentionally not used by
/// this macOS 26-only target.
private nonisolated final class AppleSpeechBufferConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw TranscriptionEngineError.cannotConvertAudio }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(1, capacity)
        ) else { throw TranscriptionEngineError.cannotConvertAudio }

        var conversionError: NSError?
        let inputState = OSAllocatedUnfairLock(initialState: false)
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            let shouldSupply = inputState.withLock { suppliedInput in
                if suppliedInput { return false }
                suppliedInput = true
                return true
            }
            inputStatus.pointee = shouldSupply ? .haveData : .noDataNow
            return shouldSupply ? buffer : nil
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? TranscriptionEngineError.cannotConvertAudio
        }
        return output
    }
}
