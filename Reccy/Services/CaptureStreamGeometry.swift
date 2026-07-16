import CoreGraphics
import Foundation

/// Resolves every approved source into one canonical capture rectangle.
/// Stream output sizing, live preview, screenshots, saved media, and spatial
/// effects all consume this same geometry.
///
/// A display-dependent application filter still produces a display-sized
/// stream unless the visible app-window envelope is applied explicitly as a
/// display-local `sourceRect`. Single-window filters are the exception:
/// ScreenCaptureKit always captures the complete window and ignores
/// `sourceRect` for that filter style.
nonisolated struct CaptureStreamGeometry: Equatable, Sendable {
    let contentRect: CGRect
    let sourceRect: CGRect?
    /// The encoded source rectangle expressed in WindowServer global points.
    /// Live effects use this same coordinate space as the delivered pixels.
    let globalRect: CGRect

    static func resolve(
        kind: CaptureSourceKind,
        filterContentRect: CGRect,
        displayFrames: [CGRect],
        selectedSourceRect: CGRect?,
        applicationWindowFrames: [CGRect] = []
    ) -> CaptureStreamGeometry {
        let applicationBounds = union(of: applicationWindowFrames)
        let displayFrame = displayFrame(
            containing: applicationBounds ?? filterContentRect,
            preferredRects: applicationWindowFrames,
            from: displayFrames
        )
        let fallbackSize = displayFrame?.size ?? CGSize(width: 2, height: 2)
        let filterRect = valid(filterContentRect)
            ? filterContentRect.standardized
            : CGRect(origin: .zero, size: fallbackSize)

        switch kind {
        case .display:
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: filterRect.size),
                sourceRect: nil,
                globalRect: filterRect
            )

        case .region:
            let requested = selectedSourceRect
                .flatMap { valid($0) ? $0.standardized : nil }
                ?? filterRect
            let sourceRect = clippedToDisplay(requested, displayFrame: displayFrame) ?? requested
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: sourceRect.size),
                sourceRect: sourceRect,
                globalRect: globalRect(sourceRect, displayFrame: displayFrame)
            )

        case .application:
            let visibleApplicationRects = applicationWindowFrames.compactMap {
                clippedToGlobalDisplay($0, displayFrame: displayFrame)
            }
            let globalApplicationRect = union(of: visibleApplicationRects)
                ?? applicationBounds
                ?? filterRect
            let displayLocal = displayLocalRect(
                globalApplicationRect.integral,
                displayFrame: displayFrame
            )
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: displayLocal.size),
                sourceRect: displayLocal,
                globalRect: globalRect(displayLocal, displayFrame: displayFrame)
            )

        case .window:
            return CaptureStreamGeometry(
                contentRect: CGRect(origin: .zero, size: filterRect.size),
                sourceRect: nil,
                globalRect: filterRect
            )
        }
    }

    /// Picker-created application filters can expose more than one display.
    /// Source rectangles are display-local, so prefer the display containing
    /// the largest share of the selected application's screen-space bounds.
    private static func displayFrame(
        containing contentRect: CGRect,
        preferredRects: [CGRect],
        from displayFrames: [CGRect]
    ) -> CGRect? {
        let validFrames = displayFrames.filter(valid)
        let preferredRects = preferredRects.filter(valid)
        if !preferredRects.isEmpty {
            return validFrames.max { lhs, rhs in
                preferredRects.reduce(0) { $0 + intersectionArea($1, lhs) }
                    < preferredRects.reduce(0) { $0 + intersectionArea($1, rhs) }
            }
        }
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

    private static func union(of rects: [CGRect]) -> CGRect? {
        let rects = rects.filter(valid).map(\.standardized)
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    private static func displayLocalRect(_ rect: CGRect, displayFrame: CGRect?) -> CGRect {
        guard let displayFrame, valid(displayFrame) else { return rect }
        let local = rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        return clippedToDisplay(local, displayFrame: CGRect(origin: .zero, size: displayFrame.size))
            ?? local
    }

    private static func globalRect(_ rect: CGRect, displayFrame: CGRect?) -> CGRect {
        guard let displayFrame, valid(displayFrame) else { return rect }
        return rect.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
    }

    private static func clippedToGlobalDisplay(
        _ rect: CGRect,
        displayFrame: CGRect?
    ) -> CGRect? {
        guard let displayFrame, valid(displayFrame) else {
            return valid(rect) ? rect : nil
        }
        let intersection = rect.intersection(displayFrame)
        return valid(intersection) ? intersection : nil
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

/// WindowServer discovery runs only while resolving a selected source, never
/// on the sample callback. It supplies the current, minimal application
/// envelope without adding another capture stream or copying frame pixels.
nonisolated enum CaptureWindowGeometry {
    static func visibleApplicationFrames(processIDs: Set<pid_t>) -> [CGRect] {
        guard !processIDs.isEmpty,
              let descriptions = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]]
        else { return [] }

        return descriptions.compactMap { description in
            guard let processIdentifier = description[kCGWindowOwnerPID as String] as? Int,
                  processIDs.contains(pid_t(processIdentifier)),
                  (description[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let dictionary = description[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 2,
                  bounds.height >= 2
            else { return nil }
            return bounds.standardized
        }
    }
}
