@preconcurrency import AVFoundation
import CoreML
import Foundation
import os
@preconcurrency import WhisperKit

actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    nonisolated let provider = TranscriptionProvider.whisperKit
    private let logger = Logger(subsystem: "com.reccy.mac", category: "WhisperKit")
    private let modelManager: WhisperModelManager
    private let modelIdentifier: String
    private var whisperKit: WhisperKit?
    private var isPreparing = false
    private var preparationWaiters: [CheckedContinuation<Void, any Error>] = []

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
        if isPreparing {
            progress(.init(
                phase: .preparing,
                fractionCompleted: nil,
                detail: "Loading \(Self.displayName(modelIdentifier))"
            ))
            try await withCheckedThrowingContinuation { continuation in
                preparationWaiters.append(continuation)
            }
            return
        }
        isPreparing = true
        let preparationStart = ContinuousClock.now
        logger.info("Loading model \(self.modelIdentifier, privacy: .public)")
        progress(.init(phase: .preparing, fractionCompleted: nil, detail: "Loading \(Self.displayName(modelIdentifier))"))
        do {
            try await modelManager.load()
            guard let folder = await modelManager.installedModelURL(for: modelIdentifier) else {
                throw TranscriptionEngineError.modelNotInstalled(Self.displayName(modelIdentifier))
            }
            let config = WhisperKitConfig(
                model: modelIdentifier,
                downloadBase: folder.deletingLastPathComponent(),
                modelFolder: folder.path,
                verbose: false,
                logLevel: .none,
                // WhisperKit's prewarm pass intentionally doubles cold-start
                // time. Loading directly keeps the model reusable while making
                // first-run live and post-recording transcription responsive.
                prewarm: false,
                load: true,
                download: false,
                useBackgroundDownloadSession: true
            )
            whisperKit = try await WhisperKit(config)
            completePreparation()
            let elapsed = preparationStart.duration(to: .now)
            logger.info(
                "Loaded model \(self.modelIdentifier, privacy: .public) in \(String(describing: elapsed), privacy: .public)"
            )
            progress(.init(phase: .preparing, fractionCompleted: 1, detail: "WhisperKit is ready"))
        } catch {
            completePreparation(throwing: error)
            logger.error(
                "Model load failed model=\(self.modelIdentifier, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
#else
        throw TranscriptionEngineError.providerUnavailable("WhisperKit requires an Apple silicon Mac.")
#endif
    }

    private func completePreparation(throwing error: (any Error)? = nil) {
        isPreparing = false
        let waiters = preparationWaiters
        preparationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
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
        guard let whisperKit else { throw TranscriptionEngineError.modelNotInstalled(modelIdentifier) }
        if role == .microphone {
            let components = try WhisperKitLiveComponents(whisperKit)
            let session = try WhisperKitNativeLiveSession(
                role: role,
                name: name,
                localeIdentifier: localeIdentifier,
                modelIdentifier: modelIdentifier,
                components: components,
                update: update
            )
            try await session.start()
            return session
        }
        return WhisperKitExternalLiveSession(
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
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return WhisperKitSegmentMapper.transcriptSegments(results.flatMap(\.segments), offset: offset)
    }

    fileprivate nonisolated static func normalized(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted { $0.sourceStart < $1.sourceStart }.reduce(into: []) { result, segment in
            if let last = result.last,
               last.displayText.caseInsensitiveCompare(segment.displayText) == .orderedSame,
               abs(last.sourceStart - segment.sourceStart) < 1.5 { return }
            result.append(segment)
        }
    }

    nonisolated static func displayName(_ identifier: String) -> String {
        let variant = identifier
            .replacingOccurrences(of: "openai_whisper-", with: "Whisper ")
            .replacingOccurrences(of: #"-v\d{8}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"_\d+(?:MB|GB)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return variant
            .split(separator: " ")
            .map { word in
                let value = String(word)
                return value.range(of: #"^v\d+$"#, options: .regularExpression) == nil
                    ? value.localizedCapitalized
                    : value
            }
            .joined(separator: " ")
    }
}

/// Argmax's model components are immutable after WhisperKit finishes loading.
/// The SDK exposes them as protocol existentials that have not yet adopted
/// `Sendable`, so this package-boundary value explicitly carries that lifecycle
/// guarantee into `AudioStreamTranscriber`'s actor initializer.
private struct WhisperKitLiveComponents: @unchecked Sendable {
    nonisolated(unsafe) let audioEncoder: any AudioEncoding
    nonisolated(unsafe) let featureExtractor: any FeatureExtracting
    nonisolated(unsafe) let segmentSeeker: any SegmentSeeking
    nonisolated(unsafe) let textDecoder: any TextDecoding
    nonisolated(unsafe) let tokenizer: any WhisperTokenizer

    nonisolated init(_ whisperKit: WhisperKit) throws {
        guard let tokenizer = whisperKit.tokenizer else {
            throw TranscriptionEngineError.providerUnavailable("WhisperKit’s tokenizer is unavailable.")
        }
        audioEncoder = whisperKit.audioEncoder
        featureExtractor = whisperKit.featureExtractor
        segmentSeeker = whisperKit.segmentSeeker
        textDecoder = whisperKit.textDecoder
        self.tokenizer = tokenizer
    }
}

private nonisolated enum WhisperKitSegmentMapper {
    static func transcriptSegments(
        _ segments: [TranscriptionSegment],
        offset: TimeInterval = 0
    ) -> [TranscriptSegment] {
        segments.compactMap { segment in
            guard segment.noSpeechProb < 0.85 else { return nil }
            let words = (segment.words ?? []).map { word in
                TranscriptWord(
                    text: word.word,
                    sourceStart: offset + TimeInterval(word.start),
                    duration: max(0, TimeInterval(word.end - word.start)),
                    confidence: Double(word.probability)
                )
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                text: text,
                sourceStart: offset + TimeInterval(segment.start),
                duration: max(0, TimeInterval(segment.end - segment.start)),
                confidence: exp(Double(segment.avgLogprob)),
                words: words
            )
        }
    }
}

/// WhisperKit's public AudioStreamTranscriber owns the streaming decode cadence,
/// VAD, and confirmed/unconfirmed segment state. This adapter supplies Reccy's
/// already-authorized, pause-corrected microphone PCM instead of opening a second
/// AVAudioEngine capture path.
private actor WhisperKitNativeLiveSession: LiveTranscriptionSession {
    nonisolated let role: TranscriptTrackRole
    private let name: String
    private let localeIdentifier: String
    private let modelIdentifier: String
    private let processor: ReccyWhisperAudioProcessor
    private let transcriber: AudioStreamTranscriber
    private let accumulator: WhisperKitNativeResultAccumulator
    private var streamTask: Task<Void, Error>?
    private var isFinished = false

    init(
        role: TranscriptTrackRole,
        name: String,
        localeIdentifier: String,
        modelIdentifier: String,
        components: WhisperKitLiveComponents,
        update: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) throws {
        self.role = role
        self.name = name
        self.localeIdentifier = localeIdentifier
        self.modelIdentifier = modelIdentifier
        let processor = ReccyWhisperAudioProcessor()
        self.processor = processor
        let accumulator = WhisperKitNativeResultAccumulator(role: role, update: update)
        self.accumulator = accumulator
        let locale = Locale(identifier: localeIdentifier)
        let language = locale.language.languageCode?.identifier
        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        self.transcriber = AudioStreamTranscriber(
            audioEncoder: components.audioEncoder,
            featureExtractor: components.featureExtractor,
            segmentSeeker: components.segmentSeeker,
            textDecoder: components.textDecoder,
            tokenizer: components.tokenizer,
            audioProcessor: processor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            useVAD: true
        ) { _, state in
            let finalized = WhisperKitSegmentMapper.transcriptSegments(state.confirmedSegments)
            let volatile = WhisperKitSegmentMapper.transcriptSegments(state.unconfirmedSegments)
            Task { await accumulator.accept(finalized: finalized, volatile: volatile) }
        }
    }

    func start() async throws {
        guard streamTask == nil else { return }
        let processor = processor
        let transcriber = transcriber
        let task = Task {
            do {
                try await transcriber.startStreamTranscription()
                processor.completeRecordingStartup(started: false)
            } catch {
                processor.completeRecordingStartup(started: false)
                throw error
            }
        }
        streamTask = task
        let started = await processor.waitUntilRecordingStarts()
        guard started else {
            streamTask = nil
            try await task.value
            throw TranscriptionEngineError.providerUnavailable(
                "WhisperKit couldn’t start live microphone transcription. Check microphone access in Settings."
            )
        }
    }

    func ingest(_ packet: TimedAudioBuffer) {
        guard !isFinished, let samples = try? TranscriptionAudioReader.monoFloatSamples(from: packet) else {
            return
        }
        processor.append(samples)
    }

    func finish(sourceTrackID: Int32) async throws -> TranscriptTrack {
        guard !isFinished else { throw CancellationError() }
        isFinished = true
        await transcriber.stopStreamTranscription()
        try await streamTask?.value
        let segments = await accumulator.allSegments
        guard !segments.isEmpty else { throw TranscriptionEngineError.noSpeechRecognized }
        return TranscriptTrack(
            sourceTrackID: sourceTrackID,
            role: role,
            name: name,
            provider: .whisperKit,
            localeIdentifier: localeIdentifier,
            modelIdentifier: modelIdentifier,
            segments: segments
        )
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        await transcriber.stopStreamTranscription()
        streamTask?.cancel()
        streamTask = nil
        processor.stopRecording()
    }
}

private actor WhisperKitNativeResultAccumulator {
    private let role: TranscriptTrackRole
    private let update: @Sendable (LiveTranscriptUpdate) -> Void
    private var finalized: [TranscriptSegment] = []
    private var volatile: [TranscriptSegment] = []

    init(role: TranscriptTrackRole, update: @escaping @Sendable (LiveTranscriptUpdate) -> Void) {
        self.role = role
        self.update = update
    }

    func accept(finalized: [TranscriptSegment], volatile: [TranscriptSegment]) {
        self.finalized = finalized
        self.volatile = volatile
        update(.init(role: role, finalizedSegments: finalized, volatileSegments: volatile))
    }

    var allSegments: [TranscriptSegment] {
        WhisperKitTranscriptionEngine.normalized(finalized + volatile)
    }

}

private nonisolated final class ReccyWhisperAudioProcessor: AudioProcessing, @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let callback: ([Float]) -> Void

        init(_ callback: @escaping ([Float]) -> Void) {
            self.callback = callback
        }
    }

    private struct State: @unchecked Sendable {
        var samples: ContiguousArray<Float> = []
        var relativeEnergy: [Float] = []
        var averageEnergy: [Float] = []
        var pendingEnergySamples: [Float] = []
        var callback: CallbackBox?
        var isRecording = false
        var isPaused = false
        var relativeEnergyWindow = 20
        var startupResult: Bool?
        var startupWaiters: [CheckedContinuation<Bool, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    static func loadAudio(
        fromPath audioFilePath: String,
        channelMode: ChannelMode,
        startTime: Double?,
        endTime: Double?,
        maxReadFrameSize: AVAudioFrameCount?
    ) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(
            fromPath: audioFilePath,
            channelMode: channelMode,
            startTime: startTime,
            endTime: endTime,
            maxReadFrameSize: maxReadFrameSize
        )
    }

    static func loadAudio(
        at audioPaths: [String],
        channelMode: ChannelMode
    ) async -> [Result<[Float], Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int,
        saveSegment: Bool
    ) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: saveSegment
        )
    }

    var audioSamples: ContiguousArray<Float> {
        state.withLock { $0.samples }
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        state.withLock { value in
            guard value.samples.count > keep else { return }
            value.samples.removeFirst(value.samples.count - keep)
        }
    }

    var relativeEnergy: [Float] {
        state.withLock { $0.relativeEnergy }
    }

    var relativeEnergyWindow: Int {
        get { state.withLock { $0.relativeEnergyWindow } }
        set { state.withLock { $0.relativeEnergyWindow = max(1, newValue) } }
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) {
        let callbackBox = callback.map(CallbackBox.init)
        let waiters = state.withLock { value -> [CheckedContinuation<Bool, Never>] in
            value.callback = callbackBox
            value.isRecording = true
            value.isPaused = false
            guard value.startupResult == nil else { return [] }
            value.startupResult = true
            let waiters = value.startupWaiters
            value.startupWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitUntilRecordingStarts() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = state.withLock { value -> Bool? in
                if let result = value.startupResult { return result }
                value.startupWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    func completeRecordingStartup(started: Bool) {
        let waiters = state.withLock { value -> [CheckedContinuation<Bool, Never>] in
            guard value.startupResult == nil else { return [] }
            value.startupResult = started
            let waiters = value.startupWaiters
            value.startupWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume(returning: started) }
    }

    func startStreamingRecordingLive(
        inputDeviceID: DeviceID?
    ) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        let pair = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
        startRecordingLive(inputDeviceID: inputDeviceID) { pair.continuation.yield($0) }
        return pair
    }

    func pauseRecording() {
        state.withLock { $0.isPaused = true }
    }

    func stopRecording() {
        state.withLock { value in
            value.isRecording = false
            value.isPaused = false
            value.callback = nil
        }
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) {
        let callbackBox = callback.map(CallbackBox.init)
        state.withLock { value in
            value.isRecording = true
            value.isPaused = false
            if let callbackBox { value.callback = callbackBox }
        }
    }

    func padOrTrim(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int
    ) -> (any AudioProcessorOutputType)? {
        Self.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: false
        )
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let callback = state.withLock { value -> CallbackBox? in
            guard value.isRecording, !value.isPaused else { return nil }
            value.samples.append(contentsOf: samples)
            value.pendingEnergySamples.append(contentsOf: samples)
            while value.pendingEnergySamples.count >= 1_600 {
                let energyWindow = Array(value.pendingEnergySamples.prefix(1_600))
                value.pendingEnergySamples.removeFirst(1_600)
                let baseline = value.averageEnergy.suffix(value.relativeEnergyWindow).min()
                let signal = AudioProcessor.calculateEnergy(of: energyWindow)
                value.averageEnergy.append(signal.avg)
                value.relativeEnergy.append(AudioProcessor.calculateRelativeEnergy(
                    of: energyWindow,
                    relativeTo: baseline
                ))
            }
            let maximumEnergyHistory = max(100, value.relativeEnergyWindow * 8)
            if value.relativeEnergy.count > maximumEnergyHistory {
                value.relativeEnergy.removeFirst(value.relativeEnergy.count - maximumEnergyHistory)
                value.averageEnergy.removeFirst(value.averageEnergy.count - maximumEnergyHistory)
            }
            return value.callback
        }
        callback?.callback(samples)
    }
}

private actor WhisperKitExternalLiveSession: LiveTranscriptionSession {
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
        // Match WhisperKit's native streaming cadence: begin after one second of
        // new audio, then coalesce while inference is active. Capture continues to
        // feed the bounded buffer without ever waiting on the model.
        guard samples.count - lastDecodedSampleCount >= 16_000, decodeTask == nil else { return }
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
