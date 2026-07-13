import CoreMedia
import CoreVideo
import Foundation

/// Routes the recorder's existing ScreenCaptureKit pixel buffers to the live
/// monitor without starting another stream or copying frame pixels. Delivery
/// is coalesced to the newest IOSurface-backed buffer so UI backpressure can
/// never create an unbounded queue of full-resolution frames.
nonisolated final class CapturePreviewPipeline: @unchecked Sendable {
    typealias FrameHandler = @MainActor @Sendable (CVPixelBuffer?) -> Void

    private let lock = NSLock()
    private var attachmentID: UUID?
    private var frameHandler: FrameHandler?
    private var latestPixelBuffer: CVPixelBuffer?
    private var generation: UInt64 = 0
    private var deliveryScheduled = false

    @discardableResult
    func attach(_ frameHandler: @escaping FrameHandler) -> UUID {
        let id = UUID()
        let shouldSchedule = withLock {
            attachmentID = id
            self.frameHandler = frameHandler
            guard latestPixelBuffer != nil, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
        return id
    }

    func detach(_ id: UUID) {
        let handler = withLock { () -> FrameHandler? in
            guard attachmentID == id else { return nil }
            let handler = frameHandler
            attachmentID = nil
            frameHandler = nil
            latestPixelBuffer = nil
            generation &+= 1
            deliveryScheduled = false
            return handler
        }
        if let handler {
            Task { @MainActor in handler(nil) }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = Self.pixelBuffer(from: sampleBuffer) else { return }
        let shouldSchedule = withLock {
            latestPixelBuffer = pixelBuffer
            generation &+= 1
            guard frameHandler != nil, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
    }

    func clear() {
        let handler = withLock { () -> FrameHandler? in
            latestPixelBuffer = nil
            generation &+= 1
            return frameHandler
        }
        if let handler {
            Task { @MainActor in handler(nil) }
        }
    }

    static func pixelBuffer(from sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        CMSampleBufferGetImageBuffer(sampleBuffer)
    }

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            self?.deliverLatestFrame()
        }
    }

    @MainActor
    private func deliverLatestFrame() {
        let delivery = withLock { () -> (FrameHandler, CVPixelBuffer, UInt64)? in
            guard let frameHandler, let latestPixelBuffer else {
                deliveryScheduled = false
                return nil
            }
            return (frameHandler, latestPixelBuffer, generation)
        }
        guard let (handler, pixelBuffer, deliveredGeneration) = delivery else { return }
        handler(pixelBuffer)

        let needsAnotherDelivery = withLock {
            guard generation != deliveredGeneration, latestPixelBuffer != nil, frameHandler != nil else {
                deliveryScheduled = false
                return false
            }
            return true
        }
        if needsAnotherDelivery { scheduleDelivery() }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
