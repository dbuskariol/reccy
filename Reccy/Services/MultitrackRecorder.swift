@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

nonisolated struct MultitrackRecordingOptions: Sendable {
    let width: Int
    let height: Int
    let frameRate: Int
    let preset: RecordingPreset
    let includesSystemAudio: Bool
    let includesMicrophone: Bool
    let isHDR: Bool

    var targetVideoBitRate: Int {
        let pixelsPerSecond = Double(width * height * frameRate)
        let bitsPerPixel: Double
        switch preset {
        case .efficient: bitsPerPixel = 0.065
        case .compatible: bitsPerPixel = 0.11
        case .hevcMaster: bitsPerPixel = 0.12
        }
        return min(max(Int(pixelsPerSecond * bitsPerPixel), 2_000_000), 60_000_000)
    }
}

enum MultitrackRecorderError: LocalizedError {
    case cannotAddVideoInput
    case cannotAddSystemAudioInput
    case cannotAddMicrophoneInput
    case writerCouldNotStart(Error?)
    case writerFailed(Error?)
    case noVideoFrames
    case couldNotRetimeSample

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput: "The video encoder couldn’t be configured for this recording."
        case .cannotAddSystemAudioInput: "The system-audio encoder couldn’t be configured."
        case .cannotAddMicrophoneInput: "The microphone encoder couldn’t be configured."
        case let .writerCouldNotStart(error): error?.localizedDescription ?? "The recording file couldn’t be started."
        case let .writerFailed(error): error?.localizedDescription ?? "The recording file couldn’t be finished."
        case .noVideoFrames: "No complete video frames were received from the selected source."
        case .couldNotRetimeSample: "The recorder couldn’t close the paused section of the media timeline."
        }
    }
}

/// Maps the capture clock onto a continuous media clock while recording is
/// paused. Resuming is anchored by the next video frame so every audio lane
/// uses the same cut point and no silent or frozen wall-clock gap is written.
nonisolated struct RecordingPauseTimeline: Sendable {
    private(set) var cumulativeOffset = CMTime.zero
    private(set) var isPaused = false
    private var pausedAt: CMTime?
    private var resumeRequested = false
    private var resumeFloor: CMTime?

    mutating func pause(at sourceTime: CMTime) {
        guard sourceTime.isValid, !isPaused else { return }
        pausedAt = sourceTime
        resumeRequested = false
        isPaused = true
    }

    mutating func requestResume() {
        guard isPaused else { return }
        resumeRequested = true
    }

    /// Returns the source-time offset to remove, or `nil` when the sample must
    /// remain monitoring-only and must not reach the asset writer.
    mutating func offset(for sourceTime: CMTime, isVideo: Bool) -> CMTime? {
        guard sourceTime.isValid else { return nil }

        if isPaused {
            guard resumeRequested, isVideo, let pausedAt else { return nil }
            let pausedDuration = CMTimeSubtract(sourceTime, pausedAt)
            if pausedDuration.isValid, CMTimeCompare(pausedDuration, .zero) > 0 {
                cumulativeOffset = CMTimeAdd(cumulativeOffset, pausedDuration)
            }
            resumeFloor = sourceTime
            self.pausedAt = nil
            resumeRequested = false
            isPaused = false
        }

        if let resumeFloor, CMTimeCompare(sourceTime, resumeFloor) < 0 {
            return nil
        }
        return cumulativeOffset
    }

    mutating func reset() {
        self = RecordingPauseTimeline()
    }
}

nonisolated final class MultitrackRecorder: NSObject, @unchecked Sendable {
    var onStarted: (@Sendable () -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?
    var onVideoFrame: (@Sendable (CMSampleBuffer) -> Void)?

    private let sampleQueue = DispatchQueue(
        label: "com.reccy.capture.samples",
        qos: .userInteractive
    )
    private let streamLifecycleLock = NSLock()

    private var stream: SCStream?
    private var isStreamStartInFlight = false
    private var isStreamCancellationRequested = false
    private var streamStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var pendingSystemAudio: [CMSampleBuffer] = []
    private var pendingMicrophone: [CMSampleBuffer] = []
    private var sessionStartTime: CMTime?
    private var latestPresentationTime: CMTime = .invalid
    private var latestSourcePresentationTime: CMTime = .invalid
    private var pauseTimeline = RecordingPauseTimeline()
    private var outputURL: URL?
    private var hasNotifiedFailure = false
    private var systemAudioLevel: Double = 0
    private var microphoneAudioLevel: Double = 0

    var metrics: (
        duration: TimeInterval,
        fileSize: Int64,
        systemAudioLevel: Double,
        microphoneLevel: Double
    ) {
        sampleQueue.sync {
            let duration: TimeInterval
            if let sessionStartTime, latestPresentationTime.isValid {
                duration = max(0, CMTimeSubtract(latestPresentationTime, sessionStartTime).seconds)
            } else {
                duration = 0
            }
            let size = outputURL.map(Self.currentFileSize) ?? 0
            return (duration, size, systemAudioLevel, microphoneAudioLevel)
        }
    }

    /// File URL resource values may be cached while AVAssetWriter is actively
    /// extending the same file. FileManager performs a fresh stat so monitor
    /// telemetry reflects each committed movie fragment.
    static func currentFileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputURL: URL,
        options: MultitrackRecordingOptions
    ) async throws {
        try Task.checkCancellation()
        try configureWriter(outputURL: outputURL, options: options)
        var startingStream: SCStream?
        do {
            try Task.checkCancellation()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            startingStream = stream
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if options.includesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if options.includesMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            guard installStartingStream(stream) else { throw CancellationError() }

            try Task.checkCancellation()
            try await stream.startCapture()
            let mustStop = completeStreamStart(stream)
            if mustStop {
                try? await stream.stopCapture()
                completeCancelledStreamStart(stream)
                throw CancellationError()
            }
        } catch {
            if let startingStream {
                completeFailedStreamStart(startingStream)
            }
            cancelWriter()
            throw error
        }
    }

    func stop() async throws {
        let request = requestStreamStop()
        guard let stream = request.stream else {
            throw MultitrackRecorderError.noVideoFrames
        }
        if request.startWasInFlight {
            try? await stream.stopCapture()
            await waitForStreamStartToSettle()
            try await finishWriting()
            return
        }
        do {
            try await stream.stopCapture()
            clearStreamIfOwned(stream)
            try await finishWriting()
        } catch {
            clearStreamIfOwned(stream)
            throw error
        }
    }

    func pause() {
        sampleQueue.sync {
            pauseTimeline.pause(at: latestSourcePresentationTime)
        }
    }

    func resume() {
        sampleQueue.sync {
            pauseTimeline.requestResume()
        }
    }

    func cancel() async {
        let cancellation = requestStreamCancellation()
        try? await cancellation.stream?.stopCapture()
        if !cancellation.startWasInFlight, let stream = cancellation.stream {
            clearStreamIfOwned(stream)
        }
        cancelWriter()
    }

    /// Installs the stream without losing a cancellation that arrived between
    /// coordinator task cancellation and stream construction.
    private func installStartingStream(_ stream: SCStream) -> Bool {
        streamLifecycleLock.lock()
        guard !isStreamCancellationRequested else {
            streamLifecycleLock.unlock()
            return false
        }
        self.stream = stream
        isStreamStartInFlight = true
        streamStartWaiters.removeAll(keepingCapacity: true)
        streamLifecycleLock.unlock()
        return true
    }

    /// Returns true when cancellation arrived while `startCapture()` was
    /// suspended. The starter remains responsible for the final stop so a
    /// failed early `stopCapture()` cannot leave a late-starting stream alive.
    private func completeStreamStart(_ stream: SCStream) -> Bool {
        streamLifecycleLock.lock()
        guard self.stream === stream else {
            streamLifecycleLock.unlock()
            return true
        }
        if isStreamCancellationRequested {
            streamLifecycleLock.unlock()
            return true
        }
        isStreamStartInFlight = false
        let waiters = streamStartWaiters
        streamStartWaiters.removeAll(keepingCapacity: true)
        streamLifecycleLock.unlock()
        waiters.forEach { $0.resume() }
        return false
    }

    private func completeFailedStreamStart(_ stream: SCStream) {
        streamLifecycleLock.lock()
        guard self.stream === stream else {
            streamLifecycleLock.unlock()
            return
        }
        self.stream = nil
        isStreamStartInFlight = false
        isStreamCancellationRequested = false
        let waiters = streamStartWaiters
        streamStartWaiters.removeAll(keepingCapacity: true)
        streamLifecycleLock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func completeCancelledStreamStart(_ stream: SCStream) {
        completeFailedStreamStart(stream)
    }

    private func requestStreamStop() -> (stream: SCStream?, startWasInFlight: Bool) {
        streamLifecycleLock.lock()
        defer { streamLifecycleLock.unlock() }
        isStreamCancellationRequested = true
        return (stream, isStreamStartInFlight)
    }

    private func requestStreamCancellation() -> (stream: SCStream?, startWasInFlight: Bool) {
        streamLifecycleLock.lock()
        defer { streamLifecycleLock.unlock() }
        isStreamCancellationRequested = true
        return (stream, isStreamStartInFlight)
    }

    private func clearStreamIfOwned(_ stream: SCStream) {
        streamLifecycleLock.lock()
        guard self.stream === stream else {
            streamLifecycleLock.unlock()
            return
        }
        self.stream = nil
        isStreamStartInFlight = false
        isStreamCancellationRequested = false
        let waiters = streamStartWaiters
        streamStartWaiters.removeAll(keepingCapacity: true)
        streamLifecycleLock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func waitForStreamStartToSettle() async {
        await withCheckedContinuation { continuation in
            streamLifecycleLock.lock()
            if isStreamStartInFlight {
                streamStartWaiters.append(continuation)
                streamLifecycleLock.unlock()
            } else {
                streamLifecycleLock.unlock()
                continuation.resume()
            }
        }
    }

    private func cancelWriter() {
        sampleQueue.sync {
            writer?.cancelWriting()
            resetWriterState()
        }
    }

    private func configureWriter(
        outputURL: URL,
        options: MultitrackRecordingOptions
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: options.preset.fileType)
        writer.shouldOptimizeForNetworkUse = options.preset.fileType == .mp4
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(options: options)
        )
        videoInput.expectsMediaDataInRealTime = true
        videoInput.mediaTimeScale = CMTimeScale(max(600, options.frameRate * 100))
        videoInput.metadata = [Self.trackTitle("Screen")]
        guard writer.canAdd(videoInput) else {
            throw MultitrackRecorderError.cannotAddVideoInput
        }
        writer.add(videoInput)

        var systemAudioInput: AVAssetWriterInput?
        if options.includesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioSettings(channels: 2, bitRate: 192_000)
            )
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackTitle("System Audio")]
            guard writer.canAdd(input) else {
                throw MultitrackRecorderError.cannotAddSystemAudioInput
            }
            writer.add(input)
            systemAudioInput = input
        }

        var microphoneInput: AVAssetWriterInput?
        if options.includesMicrophone {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioSettings(channels: 1, bitRate: 128_000)
            )
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackTitle("Microphone")]
            guard writer.canAdd(input) else {
                throw MultitrackRecorderError.cannotAddMicrophoneInput
            }
            writer.add(input)
            microphoneInput = input
        }

        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        self.outputURL = outputURL
        pendingSystemAudio.removeAll(keepingCapacity: true)
        pendingMicrophone.removeAll(keepingCapacity: true)
        sessionStartTime = nil
        latestPresentationTime = .invalid
        latestSourcePresentationTime = .invalid
        pauseTimeline.reset()
        hasNotifiedFailure = false
        systemAudioLevel = 0
        microphoneAudioLevel = 0
    }

    private static func videoSettings(options: MultitrackRecordingOptions) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.targetVideoBitRate,
            AVVideoExpectedSourceFrameRateKey: options.frameRate,
            AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        var settings: [String: Any] = [
            AVVideoCodecKey: options.isHDR ? AVVideoCodecType.hevc : options.preset.codec,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
        ]

        if options.isHDR {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
                kVTHDRMetadataInsertionMode_RequestSDRRangePreservation
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    private static func audioSettings(channels: Int, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    private static func trackTitle(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataTitle
        item.value = title as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private func handle(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let presentationTime = sampleBuffer.presentationTimeStamp
        guard presentationTime.isValid else { return }

        if latestSourcePresentationTime.isValid {
            if CMTimeCompare(presentationTime, latestSourcePresentationTime) > 0 {
                latestSourcePresentationTime = presentationTime
            }
        } else {
            latestSourcePresentationTime = presentationTime
        }

        switch type {
        case .screen:
            guard Self.isCompleteVideoFrame(sampleBuffer) else { return }
            onVideoFrame?(sampleBuffer)
        case .audio:
            systemAudioLevel = Self.smoothedLevel(
                current: systemAudioLevel,
                sample: Self.normalizedAudioLevel(from: sampleBuffer)
            )
        case .microphone:
            microphoneAudioLevel = Self.smoothedLevel(
                current: microphoneAudioLevel,
                sample: Self.normalizedAudioLevel(from: sampleBuffer)
            )
        @unknown default:
            return
        }

        guard let offset = pauseTimeline.offset(for: presentationTime, isVideo: type == .screen) else {
            return
        }
        guard let writerBuffer = Self.retimed(sampleBuffer, subtracting: offset) else {
            notifyFailure(MultitrackRecorderError.couldNotRetimeSample)
            return
        }
        let writerPresentationTime = writerBuffer.presentationTimeStamp

        switch type {
        case .screen:
            startSessionIfNeeded(at: writerPresentationTime)
            append(writerBuffer, to: videoInput)
        case .audio:
            handleAudio(writerBuffer, pending: &pendingSystemAudio, input: systemAudioInput)
        case .microphone:
            handleAudio(writerBuffer, pending: &pendingMicrophone, input: microphoneInput)
        @unknown default:
            return
        }

        if latestPresentationTime.isValid {
            if CMTimeCompare(writerPresentationTime, latestPresentationTime) > 0 {
                latestPresentationTime = writerPresentationTime
            }
        } else {
            latestPresentationTime = writerPresentationTime
        }

        if writer?.status == .failed {
            notifyFailure(MultitrackRecorderError.writerFailed(writer?.error))
        }
    }

    /// ScreenCaptureKit also emits idle, blank, suspended, and stopped status
    /// buffers. They are stream state, not recordable video frames.
    static func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    private func startSessionIfNeeded(at time: CMTime) {
        guard sessionStartTime == nil, let writer else { return }
        guard writer.startWriting() else {
            notifyFailure(MultitrackRecorderError.writerCouldNotStart(writer.error))
            return
        }
        writer.startSession(atSourceTime: time)
        sessionStartTime = time

        flush(&pendingSystemAudio, to: systemAudioInput, startingAt: time)
        flush(&pendingMicrophone, to: microphoneInput, startingAt: time)
        onStarted?()
    }

    private func handleAudio(
        _ sampleBuffer: CMSampleBuffer,
        pending: inout [CMSampleBuffer],
        input: AVAssetWriterInput?
    ) {
        guard let sessionStartTime else {
            pending.append(sampleBuffer)
            if pending.count > 240 {
                pending.removeFirst(pending.count - 240)
            }
            return
        }
        guard CMTimeCompare(sampleBuffer.presentationTimeStamp, sessionStartTime) >= 0 else { return }
        append(sampleBuffer, to: input)
    }

    private func flush(
        _ buffers: inout [CMSampleBuffer],
        to input: AVAssetWriterInput?,
        startingAt startTime: CMTime
    ) {
        for sample in buffers where CMTimeCompare(sample.presentationTimeStamp, startTime) >= 0 {
            append(sample, to: input)
        }
        buffers.removeAll(keepingCapacity: true)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer), writer?.status == .failed {
            notifyFailure(MultitrackRecorderError.writerFailed(writer?.error))
        }
    }

    private static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        subtracting offset: CMTime
    ) -> CMSampleBuffer? {
        guard offset.isValid, CMTimeCompare(offset, .zero) > 0 else { return sampleBuffer }

        var timingCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        ) == noErr, timingCount > 0 else { return nil }

        var timing = Array(repeating: CMSampleTimingInfo(), count: timingCount)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingCount,
            arrayToFill: &timing,
            entriesNeededOut: &timingCount
        ) == noErr else { return nil }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(
                    timing[index].presentationTimeStamp,
                    offset
                )
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp,
                    offset
                )
            }
        }

        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &result
        )
        return status == noErr ? result : nil
    }

    private static func smoothedLevel(current: Double, sample: Double) -> Double {
        let response = sample > current ? 0.38 : 0.14
        return current + (sample - current) * response
    }

    private static func normalizedAudioLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return 0 }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return 0 }

        let description = streamDescription.pointee
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let rawPointer = UnsafeRawPointer(dataPointer)
        let meanSquare: Double

        if isFloat, description.mBitsPerChannel == 32 {
            let count = totalLength / MemoryLayout<Float>.size
            guard count > 0 else { return 0 }
            let samples = rawPointer.bindMemory(to: Float.self, capacity: count)
            let stride = max(1, count / 2_048)
            var sum = 0.0
            var sampledCount = 0
            for index in Swift.stride(from: 0, to: count, by: stride) {
                let value = Double(samples[index])
                sum += value * value
                sampledCount += 1
            }
            meanSquare = sum / Double(sampledCount)
        } else if isSignedInteger, description.mBitsPerChannel == 16 {
            let count = totalLength / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            let samples = rawPointer.bindMemory(to: Int16.self, capacity: count)
            let stride = max(1, count / 2_048)
            var sum = 0.0
            var sampledCount = 0
            for index in Swift.stride(from: 0, to: count, by: stride) {
                let value = Double(samples[index]) / Double(Int16.max)
                sum += value * value
                sampledCount += 1
            }
            meanSquare = sum / Double(sampledCount)
        } else {
            return 0
        }

        let rms = sqrt(meanSquare)
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    private func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sampleQueue.async { [self] in
                guard let writer, sessionStartTime != nil else {
                    writer?.cancelWriting()
                    resetWriterState()
                    continuation.resume(throwing: MultitrackRecorderError.noVideoFrames)
                    return
                }

                videoInput?.markAsFinished()
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                writer.finishWriting { [self] in
                    sampleQueue.async { [self] in
                        let status = self.writer?.status
                        let error = self.writer?.error
                        resetWriterState(keepOutputURL: true)
                        if status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: MultitrackRecorderError.writerFailed(error))
                        }
                    }
                }
            }
        }
    }

    private func notifyFailure(_ error: Error) {
        guard !hasNotifiedFailure else { return }
        hasNotifiedFailure = true
        writer?.cancelWriting()
        onFailure?(error)
    }

    private func resetWriterState(keepOutputURL: Bool = false) {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        pendingSystemAudio.removeAll()
        pendingMicrophone.removeAll()
        sessionStartTime = nil
        latestPresentationTime = .invalid
        latestSourcePresentationTime = .invalid
        pauseTimeline.reset()
        systemAudioLevel = 0
        microphoneAudioLevel = 0
        if !keepOutputURL {
            outputURL = nil
        }
    }
}

nonisolated extension MultitrackRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        handle(sampleBuffer, type: type)
    }
}

nonisolated extension MultitrackRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        notifyFailure(error)
    }
}
