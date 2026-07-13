import AppKit
import CoreVideo
import IOSurface
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
            attachmentID = pipeline.attach { [weak view] pixelBuffer in
                view?.display(pixelBuffer)
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @MainActor
    func display(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer,
              let surfaceReference = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else {
            layer?.contents = nil
            return
        }
        let surface = unsafeBitCast(surfaceReference, to: IOSurface.self)
        layer?.contents = surface
    }
}
