@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Routes the recorder's existing ScreenCaptureKit video buffers to any
/// attached monitor surface. AVSampleBufferVideoRenderer is specifically
/// designed for background-thread enqueuing, so this path does not copy
/// full-resolution frames through SwiftUI or start a second capture stream.
nonisolated final class CapturePreviewPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private weak var renderer: AVSampleBufferVideoRenderer?

    func attach(_ renderer: AVSampleBufferVideoRenderer) {
        let previous = withRendererLock {
            let previous = self.renderer
            self.renderer = renderer
            return previous
        }
        if previous !== renderer {
            previous?.flush(removingDisplayedImage: true, completionHandler: nil)
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    func detach(_ renderer: AVSampleBufferVideoRenderer) {
        let detached = withRendererLock {
            guard self.renderer === renderer else { return false }
            self.renderer = nil
            return true
        }
        if detached {
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let renderer = withRendererLock({ renderer }) else { return }
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sampleBuffer)
    }

    func clear() {
        withRendererLock { renderer }?
            .flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func withRendererLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
