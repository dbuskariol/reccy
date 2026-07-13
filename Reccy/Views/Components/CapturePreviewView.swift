import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct CapturePreviewView: NSViewRepresentable {
    let pipeline: CapturePreviewPipeline

    func makeCoordinator() -> Coordinator {
        Coordinator(pipeline: pipeline)
    }

    func makeNSView(context: Context) -> SampleBufferPreviewNSView {
        let view = SampleBufferPreviewNSView()
        pipeline.attach(view.displayLayer.sampleBufferRenderer)
        return view
    }

    func updateNSView(_ view: SampleBufferPreviewNSView, context: Context) {
        pipeline.attach(view.displayLayer.sampleBufferRenderer)
    }

    static func dismantleNSView(_ view: SampleBufferPreviewNSView, coordinator: Coordinator) {
        coordinator.pipeline.detach(view.displayLayer.sampleBufferRenderer)
    }

    final class Coordinator {
        let pipeline: CapturePreviewPipeline

        init(pipeline: CapturePreviewPipeline) {
            self.pipeline = pipeline
        }
    }
}

final class SampleBufferPreviewNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}
