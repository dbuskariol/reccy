@preconcurrency import CoreMedia
import CoreVideo
import Foundation

/// Routes the recorder's existing ScreenCaptureKit sample buffers to the live
/// monitor without starting another stream or copying frame pixels. Delivery
/// is coalesced to the newest buffer so UI backpressure can never create an
/// unbounded queue of full-resolution frames.
nonisolated final class CapturePreviewPipeline: @unchecked Sendable {
    typealias FrameHandler = @MainActor @Sendable (CMSampleBuffer?) -> Void

    private let lock = NSLock()
    private var attachmentID: UUID?
    private var frameHandler: FrameHandler?
    private var latestSampleBuffer: CMSampleBuffer?
    private var generation: UInt64 = 0
    private var deliveryScheduled = false

    @discardableResult
    func attach(_ frameHandler: @escaping FrameHandler) -> UUID {
        let id = UUID()
        let shouldSchedule = withLock {
            attachmentID = id
            self.frameHandler = frameHandler
            guard latestSampleBuffer != nil, !deliveryScheduled else { return false }
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
            latestSampleBuffer = nil
            generation &+= 1
            deliveryScheduled = false
            return handler
        }
        if let handler {
            Task { @MainActor in handler(nil) }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let displayBuffer = Self.displayBuffer(from: sampleBuffer) else { return }
        let shouldSchedule = withLock {
            latestSampleBuffer = displayBuffer
            generation &+= 1
            guard frameHandler != nil, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
    }

    func clear() {
        let handler = withLock { () -> FrameHandler? in
            latestSampleBuffer = nil
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

    /// AVSampleBufferVideoRenderer otherwise interprets ScreenCaptureKit's
    /// host-clock timestamp as a scheduled playback deadline. The buffer is
    /// already a few milliseconds old when the main actor receives it, so a
    /// live monitor must explicitly request immediate display. This copies
    /// only the sample metadata; the IOSurface-backed frame remains shared.
    static func displayBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pixelBuffer(from: sampleBuffer) != nil else { return nil }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        ) == noErr, let copy,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                copy,
                createIfNecessary: true
              ), CFArrayGetCount(attachments) > 0
        else { return nil }

        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
        return copy
    }

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            self?.deliverLatestFrame()
        }
    }

    @MainActor
    private func deliverLatestFrame() {
        let delivery = withLock { () -> (FrameHandler, CMSampleBuffer, UInt64)? in
            guard let frameHandler, let latestSampleBuffer else {
                deliveryScheduled = false
                return nil
            }
            return (frameHandler, latestSampleBuffer, generation)
        }
        guard let (handler, sampleBuffer, deliveredGeneration) = delivery else { return }
        handler(sampleBuffer)

        let needsAnotherDelivery = withLock {
            guard generation != deliveredGeneration, latestSampleBuffer != nil, frameHandler != nil else {
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
