import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ScreenCaptureKit

/// Immutable presentation data for a complete native capture frame.
/// `IOSurface` keeps both ScreenCaptureKit and AVCaptureVideoDataOutput previews
/// GPU-shared with the exact pixels already owned by their recording inputs.
nonisolated struct CapturePreviewFrame: @unchecked Sendable {
    let surface: IOSurface
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
}

/// Routes existing native capture sample buffers to the live monitor without
/// starting another stream or copying frame pixels. Delivery is coalesced to
/// the newest frame so UI backpressure can never create an unbounded queue of
/// full-resolution frames.
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

    /// Mirrors Apple's native sample-buffer presentation path: validate the
    /// frame, retrieve its IOSurface, and retain ScreenCaptureKit content
    /// metadata when present. Camera frames use their complete pixel extent.
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

        let contentRect = contentRect(
            from: attachments?[.contentRect],
            fallback: pixelSize
        )

        return CapturePreviewFrame(
            surface: surface,
            contentRect: contentRect,
            contentScale: attachments?[.contentScale] as? CGFloat ?? 1,
            scaleFactor: attachments?[.scaleFactor] as? CGFloat ?? 1
        )
    }

    /// ScreenCaptureKit currently supplies a Core Graphics dictionary for
    /// `.contentRect`, but capture attachments cross an Objective-C boundary
    /// and therefore arrive as `Any`. Treat malformed or future attachment
    /// values as absent instead of allowing an invalid bridge to crash the
    /// recording stream.
    static func contentRect(from attachment: Any?, fallback: CGRect) -> CGRect {
        guard let dictionary = attachment as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary),
              rect.width > 0,
              rect.height > 0
        else { return fallback }
        return rect
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
