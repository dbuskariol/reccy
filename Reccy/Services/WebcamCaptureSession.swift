@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OSLog

nonisolated struct WebcamCaptureFormat: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let width: Int
    let height: Int
}

nonisolated enum WebcamCaptureError: LocalizedError {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
    case formatUnavailable
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            "The selected camera is no longer available. Choose another camera and try again."
        case .cannotAddInput:
            "Reccy couldn’t connect the selected camera to a native capture session."
        case .cannotAddOutput:
            "Reccy couldn’t configure camera video output."
        case .formatUnavailable:
            "The selected camera doesn’t expose a format compatible with this recording."
        case .failedToStart:
            "The selected camera couldn’t start. It may already be in use by another app."
        }
    }
}

/// Owns one native camera session for the complete screen-recording lifecycle.
/// Camera callbacks stay on a dedicated lightweight queue and are handed to the
/// recorder's serial delivery queue, so framework shutdown never waits behind
/// screen/audio writer work while all writer mutations remain deterministic.
nonisolated final class WebcamCaptureSession: NSObject, @unchecked Sendable {
    typealias SampleHandler = @Sendable (CMSampleBuffer) -> Void

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.reccy.capture.webcam.session",
        qos: .userInitiated
    )
    private let captureQueue = DispatchQueue(
        label: "com.reccy.capture.webcam.samples",
        qos: .userInteractive
    )
    private let deliveryQueue: DispatchQueue
    private let sampleHandler: SampleHandler
    private let logger = Logger(subsystem: "com.reccy.mac", category: "Camera")
    private let sampleStateLock = NSLock()
    private var isConfigured = false
    private var format: WebcamCaptureFormat?
    private var hasDeliveredSample = false
    private var acceptsSamples = true

    init(deliveryQueue: DispatchQueue, sampleHandler: @escaping SampleHandler) {
        self.deliveryQueue = deliveryQueue
        self.sampleHandler = sampleHandler
        super.init()
    }

    func prepare(deviceID: String?, fileType: AVFileType) async throws -> WebcamCaptureFormat {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    let format = try configure(deviceID: deviceID, fileType: fileType)
                    continuation.resume(returning: format)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard isConfigured else {
                    continuation.resume(throwing: WebcamCaptureError.formatUnavailable)
                    return
                }
                session.startRunning()
                if session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WebcamCaptureError.failedToStart)
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !withSampleStateLock({ hasDeliveredSample }) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw WebcamCaptureError.failedToStart
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Ends the recorder-facing half of capture without making asset writer
    /// finalization depend on AVCaptureSession's synchronous hardware teardown.
    ///
    /// Setting the output delegate to nil prevents new callbacks. Draining the
    /// callback queue and then the recorder queue guarantees every sample that
    /// was already in flight has finished before this method returns. The
    /// session remains retained by its serial queue until stopRunning returns.
    func stop() async {
        logger.info("Stopping camera sample delivery")
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                withSampleStateLock { acceptsSamples = false }
                output.setSampleBufferDelegate(nil, queue: nil)

                // The capture queue is serial by AVFoundation contract. Once
                // it drains, all accepted callbacks have enqueued their writer
                // work, so the nested delivery barrier is a safe cutoff.
                captureQueue.async {
                    self.deliveryQueue.async {
                        continuation.resume()
                    }
                }

                let hardwareStopStart = ContinuousClock.now
                logger.info("Stopping native camera session")
                if session.isRunning {
                    session.stopRunning()
                }
                let elapsed = hardwareStopStart.duration(to: .now)
                logger.info(
                    "Stopped native camera session in \(String(describing: elapsed), privacy: .public)"
                )
            }
        }
        logger.info("Camera samples drained from recorder")
    }

    private func configure(deviceID: String?, fileType: AVFileType) throws -> WebcamCaptureFormat {
        if let format, isConfigured { return format }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        let device = deviceID.flatMap { id in devices.first(where: { $0.uniqueID == id }) }
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw WebcamCaptureError.deviceUnavailable }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw WebcamCaptureError.cannotAddInput }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        guard session.canAddOutput(output) else { throw WebcamCaptureError.cannotAddOutput }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard let recommended = output.recommendedVideoSettingsForAssetWriter(writingTo: fileType),
              let width = Self.integer(recommended[AVVideoWidthKey]),
              let height = Self.integer(recommended[AVVideoHeightKey]),
              width > 0,
              height > 0
        else { throw WebcamCaptureError.formatUnavailable }

        let format = WebcamCaptureFormat(
            deviceID: device.uniqueID,
            deviceName: device.localizedName,
            width: width,
            height: height
        )
        self.format = format
        isConfigured = true
        return format
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func withSampleStateLock<Value>(_ body: () -> Value) -> Value {
        sampleStateLock.lock()
        defer { sampleStateLock.unlock() }
        return body()
    }

    /// AVCaptureVideoDataOutput timestamps use the session synchronization
    /// clock. ScreenCaptureKit uses host time, so convert camera timing once at
    /// this boundary before both sources enter the shared pause timeline.
    private func sampleInHostTime(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let clock = session.synchronizationClock else { return sampleBuffer }
        let hostClock = CMClockGetHostTimeClock()
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
                timing[index].presentationTimeStamp = CMSyncConvertTime(
                    timing[index].presentationTimeStamp,
                    from: clock,
                    to: hostClock
                )
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMSyncConvertTime(
                    timing[index].decodeTimeStamp,
                    from: clock,
                    to: hostClock
                )
            }
        }

        var converted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &converted
        )
        return status == noErr ? converted : nil
    }
}

nonisolated extension WebcamCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard withSampleStateLock({ acceptsSamples }),
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let converted = sampleInHostTime(sampleBuffer)
        else { return }
        withSampleStateLock { hasDeliveredSample = true }
        let retained = WebcamRetainedSampleBuffer(converted)
        deliveryQueue.async { [sampleHandler] in
            sampleHandler(retained.value)
        }
    }
}

private nonisolated final class WebcamRetainedSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}
