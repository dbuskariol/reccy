import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ScreenCaptureKit

/// The immutable presentation data Apple exposes for a complete
/// ScreenCaptureKit video frame. `IOSurface` keeps the preview GPU-native and
/// shares the exact pixels already owned by the recording stream.
nonisolated struct CapturePreviewFrame: @unchecked Sendable {
    let surface: IOSurface
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
}

/// Routes the recorder's existing ScreenCaptureKit sample buffers to the live
/// monitor without starting another stream or copying frame pixels. Delivery
/// is coalesced to the newest frame so UI backpressure can never create an
/// unbounded queue of full-resolution frames.
nonisolated final class CapturePreviewPipeline: @unchecked Sendable {
    typealias FrameHandler = @MainActor @Sendable (CapturePreviewFrame?) -> Void

    private let lock = NSLock()
    private var frameHandlers: [UUID: FrameHandler] = [:]
    private var latestFrame: CapturePreviewFrame?
    private var generation: UInt64 = 0
    private var deliveryScheduled = false

    @discardableResult
    func attach(_ frameHandler: @escaping FrameHandler) -> UUID {
        let id = UUID()
        let shouldSchedule = withLock {
            frameHandlers[id] = frameHandler
            guard latestFrame != nil, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
        return id
    }

    func detach(_ id: UUID) {
        let handler = withLock { () -> FrameHandler? in
            guard let handler = frameHandlers.removeValue(forKey: id) else { return nil }
            if frameHandlers.isEmpty {
                latestFrame = nil
                generation &+= 1
            }
            return handler
        }
        if let handler {
            Task { @MainActor in handler(nil) }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let frame = Self.frame(from: sampleBuffer) else { return }
        let shouldSchedule = withLock {
            latestFrame = frame
            generation &+= 1
            guard !frameHandlers.isEmpty, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
    }

    func clear() {
        let handlers = withLock { () -> [FrameHandler] in
            latestFrame = nil
            generation &+= 1
            return Array(frameHandlers.values)
        }
        if !handlers.isEmpty {
            Task { @MainActor in
                for handler in handlers { handler(nil) }
            }
        }
    }

    /// Mirrors Apple's ScreenCaptureKit sample: validate the complete frame,
    /// retrieve its IOSurface, and retain the metadata that describes the
    /// content within that surface.
    static func frame(from sampleBuffer: CMSampleBuffer) -> CapturePreviewFrame? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surfaceReference = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return nil }

        let surface = unsafeBitCast(surfaceReference, to: IOSurface.self)
        let pixelSize = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let attachments = (
            CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]]
        )?.first

        if let rawStatus = attachments?[.status] as? Int,
           SCFrameStatus(rawValue: rawStatus) != .complete
        {
            return nil
        }

        let contentRect: CGRect
        if let value = attachments?[.contentRect],
           let rect = CGRect(dictionaryRepresentation: value as! CFDictionary)
        {
            contentRect = rect
        } else {
            contentRect = pixelSize
        }

        return CapturePreviewFrame(
            surface: surface,
            contentRect: contentRect,
            contentScale: attachments?[.contentScale] as? CGFloat ?? 1,
            scaleFactor: attachments?[.scaleFactor] as? CGFloat ?? 1
        )
    }

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            self?.deliverLatestFrame()
        }
    }

    @MainActor
    private func deliverLatestFrame() {
        let delivery = withLock { () -> ([(UUID, FrameHandler)], CapturePreviewFrame, UInt64)? in
            guard !frameHandlers.isEmpty, let latestFrame else {
                deliveryScheduled = false
                return nil
            }
            return (Array(frameHandlers), latestFrame, generation)
        }
        guard let (handlers, frame, deliveredGeneration) = delivery else { return }
        for (id, handler) in handlers {
            let isStillAttached = withLock { frameHandlers[id] != nil }
            if isStillAttached { handler(frame) }
        }

        let needsAnotherDelivery = withLock {
            guard generation != deliveredGeneration, latestFrame != nil, !frameHandlers.isEmpty else {
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
