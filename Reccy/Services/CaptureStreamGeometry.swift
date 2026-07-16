import CoreGraphics
import Foundation

/// Resolves ScreenCaptureKit's screen-space filter geometry into the
/// display-local crop expected by `SCStreamConfiguration.sourceRect`.
///
/// A display-dependent application filter still produces a display-sized
/// stream unless its content rectangle is applied explicitly. Single-window
/// filters are the exception: ScreenCaptureKit always captures the complete
/// window and ignores `sourceRect` for that filter style.
nonisolated struct CaptureStreamGeometry: Equatable, Sendable {
    let contentRect: CGRect
    let sourceRect: CGRect?

    static func resolve(
        kind: CaptureSourceKind,
        filterContentRect: CGRect,
        displayFrames: [CGRect],
        selectedSourceRect: CGRect?
    ) -> CaptureStreamGeometry {
        let displayFrame = displayFrame(containing: filterContentRect, from: displayFrames)
        let fallbackSize = displayFrame?.size ?? CGSize(width: 2, height: 2)
        let filterRect = valid(filterContentRect)
            ? filterContentRect.standardized
            : CGRect(origin: .zero, size: fallbackSize)

        switch kind {
        case .display:
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: filterRect.size),
                sourceRect: nil
            )

        case .region:
            let requested = selectedSourceRect
                .flatMap { valid($0) ? $0.standardized : nil }
                ?? filterRect
            let sourceRect = clippedToDisplay(requested, displayFrame: displayFrame) ?? requested
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: sourceRect.size),
                sourceRect: sourceRect
            )

        case .application:
            let displayLocal = displayLocalRect(filterRect, displayFrame: displayFrame)
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: displayLocal.size),
                sourceRect: displayLocal
            )

        case .window:
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: filterRect.size),
                sourceRect: nil
            )
        }
    }

    /// Picker-created application filters can expose more than one display.
    /// Source rectangles are display-local, so prefer the display containing
    /// the largest share of the selected application's screen-space bounds.
    private static func displayFrame(
        containing contentRect: CGRect,
        from displayFrames: [CGRect]
    ) -> CGRect? {
        let validFrames = displayFrames.filter(valid)
        guard valid(contentRect) else { return validFrames.first }
        return validFrames.max { lhs, rhs in
            intersectionArea(contentRect, lhs) < intersectionArea(contentRect, rhs)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard valid(intersection) else { return 0 }
        return intersection.width * intersection.height
    }

    private static func displayLocalRect(_ rect: CGRect, displayFrame: CGRect?) -> CGRect {
        guard let displayFrame, valid(displayFrame) else { return rect }
        let local = rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        return clippedToDisplay(local, displayFrame: CGRect(origin: .zero, size: displayFrame.size))
            ?? local
    }

    private static func clippedToDisplay(_ rect: CGRect, displayFrame: CGRect?) -> CGRect? {
        guard let displayFrame, valid(displayFrame) else { return nil }
        let bounds = CGRect(origin: .zero, size: displayFrame.size)
        let intersection = rect.intersection(bounds)
        return valid(intersection) ? intersection : nil
    }

    private static func valid(_ rect: CGRect?) -> Bool {
        guard let rect else { return false }
        return rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}
