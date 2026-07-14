import AppKit
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
            attachmentID = pipeline.attach { [weak view] frame in
                view?.display(frame)
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
    private let contentLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentLayer.backgroundColor = NSColor.black.cgColor
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.masksToBounds = true
        // A layer-hosting AppKit view must receive its backing layer before
        // enabling layer hosting. This order is required by Apple's current
        // ScreenCaptureKit sample and keeps IOSurface contents presentable.
        layer = contentLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isReadyForDisplay: Bool { contentLayer.contents != nil }
    var rendererError: Error? { nil }

    @MainActor
    func display(_ frame: CapturePreviewFrame?) {
        contentLayer.contents = frame?.surface
    }
}
