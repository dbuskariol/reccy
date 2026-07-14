import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import SwiftUI

struct CapturePreviewView: NSViewRepresentable {
    let pipeline: CapturePreviewPipeline

    func makeCoordinator() -> Coordinator {
        Coordinator(pipeline: pipeline)
    }

    func makeNSView(context: Context) -> CaptureSurfacePreviewNSView {
        let view = CaptureSurfacePreviewNSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: CaptureSurfacePreviewNSView, context: Context) {
        context.coordinator.attach(to: view)
    }

    static func dismantleNSView(_ view: CaptureSurfacePreviewNSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private let pipeline: CapturePreviewPipeline
        private var attachmentID: UUID?
        private weak var attachedView: CaptureSurfacePreviewNSView?

        init(pipeline: CapturePreviewPipeline) {
            self.pipeline = pipeline
        }

        @MainActor
        func attach(to view: CaptureSurfacePreviewNSView) {
            guard attachedView !== view else { return }
            detach()
            attachedView = view
            attachmentID = pipeline.attach { [weak view] sampleBuffer in
                view?.display(sampleBuffer)
            }
        }

        func detach() {
            guard let attachmentID else { return }
            self.attachmentID = nil
            attachedView = nil
            pipeline.detach(attachmentID)
        }
    }
}

final class CaptureSurfacePreviewNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.masksToBounds = true
        layer = displayLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isReadyForDisplay: Bool { displayLayer.isReadyForDisplay }
    var rendererError: Error? { displayLayer.sampleBufferRenderer.error }

    @MainActor
    func display(_ sampleBuffer: CMSampleBuffer?) {
        let renderer = displayLayer.sampleBufferRenderer
        guard let sampleBuffer else {
            renderer.flush(removingDisplayedImage: true)
            return
        }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        // The renderer can report backpressure before its first frame. The
        // pipeline already bounds delivery to one newest frame, and Apple
        // explicitly permits enqueueing while this value is false, so do not
        // prevent the renderer from bootstrapping its display queue.
        renderer.enqueue(sampleBuffer)
    }
}
