@preconcurrency import AVFoundation
import Foundation
import WhisperKit

actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    nonisolated let provider = TranscriptionProvider.whisperKit
    private let modelManager: WhisperModelManager
    private let modelIdentifier: String
    private var whisperKit: WhisperKit?

    init(modelManager: WhisperModelManager, modelIdentifier: String) {
        self.modelManager = modelManager
        self.modelIdentifier = modelIdentifier
    }

    func availability(localeIdentifier: String) async -> TranscriptionEngineAvailability {
#if arch(arm64)
        do {
            try await modelManager.load()
            return await modelManager.installedModelURL(for: modelIdentifier) == nil ? .requiresDownload : .ready
        } catch {
            return .unavailable(error.localizedDescription)
        }
#else
        return .unavailable("WhisperKit requires an Apple silicon Mac.")
#endif
    }

    func prepare(
        localeIdentifier: String,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws {
#if arch(arm64)
        guard whisperKit == nil else { return }
        try await modelManager.load()
        guard let folder = await modelManager.installedModelURL(for: modelIdentifier) else {
            throw TranscriptionEngineError.modelNotInstalled(Self.displayName(modelIdentifier))
        }
        progress(.init(phase: .preparing, fractionCompleted: nil, detail: "Loading (Self.displayName(modelIdentifier))"))
        let config = WhisperKitConfig(
            model: modelIdentifier,
            downloadBase: folder.deletingLastPathComponent(),
            modelFolder: folder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false,
            useBackgroundDownloadSession: true
        )
        whisperKit = try await WhisperKit(config)
        progress(.init(phase: .preparing, fractionCompleted: 1, detail: "WhisperKit is ready"))
#else
        throw TranscriptionEngineError.providerUnavailable("WhisperKit requires an Apple silicon Mac.")
#endif
    }

    func transcribe(
        _ request: TranscriptionTrackRequest,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> TranscriptTrack {
        try await prepare(localeIdentifier: request.localeIdentifier, progress: progress)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let packets = try await TranscriptionAudioReader.stream(
            mediaURL: request.mediaURL,
            sourceTrackID: request.sourceTrackID,
            outputFormat: format
        )
        let duration = try await AVURLAsset(url: request.mediaURL).load(.duration).seconds
        let chunkSamples = 16_000 * 300
        let chunkStepSamples = 16_000 * 298
        var samples: [Float] = []
        samples.reserveCapacity(chunkSamples)
        var offset: TimeInterval = 0
        var segments: [TranscriptSegment] = []

        for try await packet in packets {
            samples.append(contentsOf: try TranscriptionAudioReader.monoFloatSamples(from: packet))
            progress(.init(
                phase: .readingAudio,
                fractionCompleted: duration.isFinite && duration > 0 ? min(1, packet.startTime.seconds / duration) : nil,
                detail: request.name
            ))
            while samples.count >= chunkSamples {
                let chunk = Array(samples.prefix(chunkSamples))
                samples.removeFirst(chunkStepSamples)
                segments.append(contentsOf: try await decode(chunk, offset: offset, localeIdentifier: request.localeIdentifier, progress: progress))
                offset += 298
            }
        }
        if !samples.isEmpty {
            segments.append(contentsOf: try await decode(samples, offset: offset, localeIdentifier: request.localeIdentifier, progress: progress))
        }
        segments = Self.normalized(segments)
        guard !segments.isEmpty else { throw TranscriptionEngineError.noSpeechRecognized }
        return TranscriptTrack(
            sourceTrackID: request.sourceTrackID,
            role: request.role,
            name: request.name,
            provider: provider,
            localeIdentifier: request.localeIdentifier,
            modelIdentifier: modelIdentifier,
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
        return WhisperKitLiveSession(
            role: role,
            name: name,
            localeIdentifier: localeIdentifier,
            modelIdentifier: modelIdentifier,
            engine: self,
            update: update
        )
    }

    fileprivate func decode(
        _ samples: [Float],
        offset: TimeInterval,
        localeIdentifier: String,
        progress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let whisperKit else { throw TranscriptionEngineError.modelNotInstalled(modelIdentifier) }
        progress(.init(phase: .transcribing, fractionCompleted: nil, detail: Self.displayName(modelIdentifier)))
        let locale = Locale(identifier: localeIdentifier)
        let language = locale.language.languageCode?.identifier
        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).compactMap { segment in
            guard segment.noSpeechProb < 0.85 else { return nil }
            let words = (segment.words ?? []).map { word in
                TranscriptWord(
                    text: word.word,
                    sourceStart: offset + TimeInterval(word.start),
                    duration: max(0, TimeInterval(word.end - word.start)),
                    confidence: Double(word.probability)
                )
            }
            return TranscriptSegment(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceStart: offset + TimeInterval(segment.start),
                duration: max(0, TimeInterval(segment.end - segment.start)),
                confidence: exp(Double(segment.avgLogprob)),
                words: words
            )
        }.filter { !$0.text.isEmpty }
    }

    private nonisolated static func normalized(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted { $0.sourceStart < $1.sourceStart }.reduce(into: []) { result, segment in
            if let last = result.last,
               last.displayText.caseInsensitiveCompare(segment.displayText) == .orderedSame,
               abs(last.sourceStart - segment.sourceStart) < 1.5 { return }
            result.append(segment)
        }
    }

    nonisolated static func displayName(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "openai_whisper-", with: "Whisper ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

private actor WhisperKitLiveSession: LiveTranscriptionSession {
    nonisolated let role: TranscriptTrackRole
    private let name: String
    private let localeIdentifier: String
    private let modelIdentifier: String
    private let engine: WhisperKitTranscriptionEngine
    private let update: @Sendable (LiveTranscriptUpdate) -> Void
    private var samples: [Float] = []
    private var bufferStart: TimeInterval = 0
    private var finalized: [TranscriptSegment] = []
    private var volatile: [TranscriptSegment] = []
    private var decodeTask: Task<Void, Never>?
    private var lastDecodedSampleCount = 0
    private var isFinished = false

    init(
        role: TranscriptTrackRole,
        name: String,
        localeIdentifier: String,
        modelIdentifier: String,
        engine: WhisperKitTranscriptionEngine,
        update: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) {
        self.role = role
        self.name = name
        self.localeIdentifier = localeIdentifier
        self.modelIdentifier = modelIdentifier
        self.engine = engine
        self.update = update
    }

    func ingest(_ packet: TimedAudioBuffer) {
        guard !isFinished, let converted = try? TranscriptionAudioReader.monoFloatSamples(from: packet) else { return }
        samples.append(contentsOf: converted)
        let maximumRollingSamples = 16_000 * 35
        let retainedSamples = 16_000 * 30
        if samples.count > maximumRollingSamples {
            let removalCount = samples.count - retainedSamples
            samples.removeFirst(removalCount)
            bufferStart += Double(removalCount) / 16_000
            lastDecodedSampleCount = max(0, lastDecodedSampleCount - removalCount)
        }
        guard samples.count - lastDecodedSampleCount >= 48_000, decodeTask == nil else { return }
        let snapshot = samples
        let snapshotStart = bufferStart
        lastDecodedSampleCount = samples.count
        decodeTask = Task { [weak self] in
            await self?.decode(snapshot, offset: snapshotStart, final: false)
        }
    }

    func finish(sourceTrackID: Int32) async throws -> TranscriptTrack {
        guard !isFinished else { throw CancellationError() }
        isFinished = true
        await decodeTask?.value
        decodeTask = nil
        await decode(samples, offset: bufferStart, final: true)
        return TranscriptTrack(
            sourceTrackID: sourceTrackID,
            role: role,
            name: name,
            provider: .whisperKit,
            localeIdentifier: localeIdentifier,
            modelIdentifier: modelIdentifier,
            segments: finalized
        )
    }

    func cancel() {
        isFinished = true
        decodeTask?.cancel()
        decodeTask = nil
        samples.removeAll(keepingCapacity: false)
    }

    private func decode(_ snapshot: [Float], offset: TimeInterval, final: Bool) async {
        guard !Task.isCancelled else { return }
        let decoded = try? await engine.decode(
            snapshot,
            offset: offset,
            localeIdentifier: localeIdentifier
        ) { _ in }
        guard let decoded, !Task.isCancelled else {
            decodeTask = nil
            return
        }
        if final {
            finalized.removeAll { $0.sourceStart >= offset }
            finalized.append(contentsOf: decoded)
            finalized.sort { $0.sourceStart < $1.sourceStart }
            volatile = []
        } else {
            let confirmationBoundary = max(offset, offset + Double(snapshot.count) / 16_000 - 2.5)
            finalized.removeAll { $0.sourceStart >= offset }
            finalized.append(contentsOf: decoded.filter { $0.sourceEnd <= confirmationBoundary })
            finalized.sort { $0.sourceStart < $1.sourceStart }
            volatile = decoded.filter { $0.sourceEnd > confirmationBoundary }
        }
        update(.init(role: role, finalizedSegments: finalized, volatileSegments: volatile))
        decodeTask = nil
    }
}
