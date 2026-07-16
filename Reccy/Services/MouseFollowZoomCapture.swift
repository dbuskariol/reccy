import AppKit
import CoreGraphics
import Foundation

/// Maps the global pointer into the exact source coordinate space without
/// requesting Accessibility or Input Monitoring permission. Display and
/// Portion mappings use Core Graphics display bounds; app/window mappings
/// periodically refresh their WindowServer bounds so moved windows stay aligned.
@MainActor
struct MouseFollowZoomSourceMapper {
    private let source: CaptureSourceDescriptor
    private var cachedBounds: CGRect?
    private var lastWindowRefresh = Date.distantPast

    init(source: CaptureSourceDescriptor) {
        self.source = source
        cachedBounds = Self.sourceBounds(for: source)
    }

    mutating func currentPosition(now: Date = Date()) -> CGPoint {
        if source.kind == .application || source.kind == .window,
           now.timeIntervalSince(lastWindowRefresh) >= 0.5
        {
            cachedBounds = Self.sourceBounds(for: source) ?? cachedBounds
            lastWindowRefresh = now
        }
        guard let bounds = cachedBounds,
              bounds.width > 0,
              bounds.height > 0,
              let pointer = CGEvent(source: nil)?.location
        else { return CGPoint(x: 0.5, y: 0.5) }
        return Self.normalizedPosition(pointer: pointer, sourceBounds: bounds)
    }

    nonisolated static func normalizedPosition(
        pointer: CGPoint,
        sourceBounds: CGRect
    ) -> CGPoint {
        guard sourceBounds.width > 0, sourceBounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: min(max((pointer.x - sourceBounds.minX) / sourceBounds.width, 0), 1),
            y: min(max((pointer.y - sourceBounds.minY) / sourceBounds.height, 0), 1)
        )
    }

    private static func sourceBounds(for source: CaptureSourceDescriptor) -> CGRect? {
        if let displayID = source.displayID {
            let displayBounds = CGDisplayBounds(displayID)
            if let region = source.region?.cgRect {
                return CGRect(
                    x: displayBounds.minX + region.minX,
                    y: displayBounds.minY + region.minY,
                    width: region.width,
                    height: region.height
                )
            }
            return displayBounds
        }

        let windowBounds: [CGRect]
        if source.kind == .application,
           let bundleIdentifier = source.applicationBundleIdentifier
        {
            windowBounds = boundsForApplication(bundleIdentifier: bundleIdentifier)
        } else {
            windowBounds = source.windowIDs.compactMap(boundsForWindow)
        }
        guard var union = windowBounds.first else { return nil }
        for bounds in windowBounds.dropFirst() {
            union = union.union(bounds)
        }
        return union
    }

    private static func boundsForApplication(bundleIdentifier: String) -> [CGRect] {
        let processIdentifiers = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .map(\.processIdentifier)
        )
        guard !processIdentifiers.isEmpty,
              let descriptions = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]]
        else { return [] }

        return descriptions.compactMap { description in
            guard let processIdentifier = description[kCGWindowOwnerPID as String] as? Int,
                  processIdentifiers.contains(pid_t(processIdentifier)),
                  (description[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let dictionary = description[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width > 0,
                  bounds.height > 0
            else { return nil }
            return bounds
        }
    }

    private static func boundsForWindow(_ windowID: UInt32) -> CGRect? {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            CGWindowID(windowID)
        ) as? [[String: Any]],
        let description = descriptions.first,
        let dictionary = description[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        bounds.width > 0,
        bounds.height > 0
        else { return nil }
        return bounds
    }
}
