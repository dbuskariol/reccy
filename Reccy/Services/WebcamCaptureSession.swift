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

/// A truthful snapshot of Apple's system-owned camera effects. Reccy never
/// segments or replaces the background itself; the same native effects that the
/// user chooses in macOS are applied by AVFoundation to preview and recorded
/// camera samples before they enter Reccy's independent camera track.
nonisolated struct WebcamVideoEffectsState: Equatable, Sendable {
    var supportsPortrait = false
    var isPortraitActive = false
    var supportsBackgroundReplacement = false
    var isBackgroundReplacementActive = false

    var activeTitles: [String] {
        [
            isPortraitActive ? "Portrait" : nil,
            isBackgroundReplacementActive ? "Background" : nil,
        ].compactMap { $0 }
    }

    var supportsAnyEffect: Bool {
        supportsPortrait || supportsBackgroundReplacement
    }

    static func snapshot(for device: AVCaptureDevice) -> WebcamVideoEffectsState {
        WebcamVideoEffectsState(
            supportsPortrait: device.activeFormat.isPortraitEffectSupported,
            isPortraitActive: device.isPortraitEffectActive,
            supportsBackgroundReplacement: device.activeFormat.isBackgroundReplacementSupported,
            isBackgroundReplacementActive: device.isBackgroundReplacementActive
        )
    }
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
    typealias EffectsHandler = @Sendable (WebcamVideoEffectsState) -> Void

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
    private let effectsHandler: EffectsHandler?
    private let logger = Logger(subsystem: "com.reccy.mac", category: "Camera")
    private let sampleStateLock = NSLock()
    private var isConfigured = false
    private var deviceIdentity: (id: String, name: String)?
    private var deliveredFormat: WebcamCaptureFormat?
    private var deliversSamples = false
    private var acceptsSamples = true
    private var effectsObservations: [NSKeyValueObservation] = []

    init(
        deliveryQueue: DispatchQueue,
        sampleHandler: @escaping SampleHandler,
        effectsHandler: EffectsHandler? = nil
    ) {
        self.deliveryQueue = deliveryQueue
        self.sampleHandler = sampleHandler
        self.effectsHandler = effectsHandler
        super.init()
    }

    func prepare(deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configure(deviceID: deviceID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Starts hardware and resolves the camera track from the first delivered
    /// pixel buffer. External cameras can advertise writer recommendations
    /// whose aspect ratio differs from the negotiated output; the actual
    /// buffer is the authoritative format that AVAssetWriter must preserve.
    func start() async throws -> WebcamCaptureFormat {
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
        while true {
            try Task.checkCancellation()
            if let format = withSampleStateLock({ deliveredFormat }) {
                return format
            }
            guard ContinuousClock.now < deadline else {
                throw WebcamCaptureError.failedToStart
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func beginDelivery() {
        withSampleStateLock { deliversSamples = true }
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

    private func configure(deviceID: String?) throws {
        if isConfigured { return }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        let device = deviceID.flatMap { id in devices.first(where: { $0.uniqueID == id }) }
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw WebcamCaptureError.deviceUnavailable }

        session.beginConfiguration()
        do {
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
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }

        withSampleStateLock {
            deviceIdentity = (device.uniqueID, device.localizedName)
        }
        observeVideoEffects(on: device)
        isConfigured = true
    }

    private func observeVideoEffects(on device: AVCaptureDevice) {
        let publish: @Sendable () -> Void = { [weak self, weak device] in
            guard let self, let device else { return }
            effectsHandler?(WebcamVideoEffectsState.snapshot(for: device))
        }
        effectsObservations = [
            device.observe(\.isPortraitEffectActive, options: [.initial, .new]) { _, _ in publish() },
            device.observe(\.isBackgroundReplacementActive, options: [.initial, .new]) { _, _ in publish() },
            device.observe(\.activeFormat, options: [.new]) { _, _ in publish() },
        ]
    }

    static func captureFormat(
        deviceID: String,
        deviceName: String,
        pixelBuffer: CVPixelBuffer
    ) -> WebcamCaptureFormat? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        return WebcamCaptureFormat(
            deviceID: deviceID,
            deviceName: deviceName,
            width: width,
            height: height
        )
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
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let identity = withSampleStateLock({ deviceIdentity }),
              let format = Self.captureFormat(
                  deviceID: identity.id,
                  deviceName: identity.name,
                  pixelBuffer: pixelBuffer
              )
        else { return }
        let shouldDeliver = withSampleStateLock {
            deliveredFormat = deliveredFormat ?? format
            return deliversSamples
        }
        guard shouldDeliver, let converted = sampleInHostTime(sampleBuffer) else { return }
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
