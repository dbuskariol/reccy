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

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput: "The video encoder couldn’t be configured for this recording."
        case .cannotAddSystemAudioInput: "The system-audio encoder couldn’t be configured."
        case .cannotAddMicrophoneInput: "The microphone encoder couldn’t be configured."
        case let .writerCouldNotStart(error): error?.localizedDescription ?? "The recording file couldn’t be started."
        case let .writerFailed(error): error?.localizedDescription ?? "The recording file couldn’t be finished."
        case .noVideoFrames: "No complete video frames were received from the selected source."
        }
    }
}

nonisolated final class MultitrackRecorder: NSObject, @unchecked Sendable {
    var onStarted: (@Sendable () -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    private let sampleQueue = DispatchQueue(
        label: "com.reccy.capture.samples",
        qos: .userInteractive
    )

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var pendingSystemAudio: [CMSampleBuffer] = []
    private var pendingMicrophone: [CMSampleBuffer] = []
    private var sessionStartTime: CMTime?
    private var latestPresentationTime: CMTime = .invalid
    private var outputURL: URL?
    private var hasNotifiedFailure = false

    var metrics: (duration: TimeInterval, fileSize: Int64) {
        sampleQueue.sync {
            let duration: TimeInterval
            if let sessionStartTime, latestPresentationTime.isValid {
                duration = max(0, CMTimeSubtract(latestPresentationTime, sessionStartTime).seconds)
            } else {
                duration = 0
            }
            let size = outputURL
                .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                .map(Int64.init) ?? 0
            return (duration, size)
        }
    }

    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputURL: URL,
        options: MultitrackRecordingOptions
    ) async throws {
        try configureWriter(outputURL: outputURL, options: options)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if options.includesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if options.includesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream else {
            throw MultitrackRecorderError.noVideoFrames
        }
        try await stream.stopCapture()
        self.stream = nil
        try await finishWriting()
    }

    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
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
        hasNotifiedFailure = false
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

        switch type {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            startSessionIfNeeded(at: presentationTime)
            append(sampleBuffer, to: videoInput)
        case .audio:
            handleAudio(sampleBuffer, pending: &pendingSystemAudio, input: systemAudioInput)
        case .microphone:
            handleAudio(sampleBuffer, pending: &pendingMicrophone, input: microphoneInput)
        @unknown default:
            break
        }

        if latestPresentationTime.isValid {
            if CMTimeCompare(presentationTime, latestPresentationTime) > 0 {
                latestPresentationTime = presentationTime
            }
        } else {
            latestPresentationTime = presentationTime
        }

        if writer?.status == .failed {
            notifyFailure(MultitrackRecorderError.writerFailed(writer?.error))
        }
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
