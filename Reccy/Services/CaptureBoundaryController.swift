import AppKit
import ScreenCaptureKit

enum CaptureBoundaryTarget: Hashable, Sendable {
    case display(UInt32)
    case region(UInt32, CaptureRegion)
    case windows([UInt32])
    case application(String)
}

@MainActor
final class CaptureBoundaryController {
    private var target: CaptureBoundaryTarget?
    private var sourceName = "Selected source"
    private var isRecording = false
    private var isPaused = false
    private var duration: TimeInterval = 0
    private var panels: [NSPanel] = []
    private var refreshTask: Task<Void, Never>?

    func show(target: CaptureBoundaryTarget, sourceName: String) {
        hide()
        self.target = target
        self.sourceName = sourceName
        isRecording = false
        isPaused = false
        duration = 0
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                await refreshFrames()
                guard target.needsPolling, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(400))
            } while !Task.isCancelled
        }
    }

    func setRecording(
        _ isRecording: Bool,
        isPaused: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.duration = duration
        updatePanelAppearance()
    }

    func hide() {
        refreshTask?.cancel()
        refreshTask = nil
        target = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    private func refreshFrames() async {
        guard let target else { return }
        let frames: [CGRect]
        switch target {
        case .display(let displayID):
            frames = NSScreen.screen(displayID: displayID).map { [$0.frame] } ?? []

        case .region(let displayID, let region):
            guard let screen = NSScreen.screen(displayID: displayID) else {
                frames = []
                break
            }
            let rect = region.cgRect
            frames = [CGRect(
                x: screen.frame.minX + rect.minX,
                y: screen.frame.maxY - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )]

        case .windows(let windowIDs):
            frames = await windowFrames(windowIDs: Set(windowIDs), bundleIdentifier: nil)

        case .application(let bundleIdentifier):
            frames = await windowFrames(windowIDs: nil, bundleIdentifier: bundleIdentifier)
        }
        display(frames: frames)
    }

    private func windowFrames(
        windowIDs: Set<UInt32>?,
        bundleIdentifier: String?
    ) async -> [CGRect] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return [] }

        return content.windows.compactMap { window in
            if let windowIDs, !windowIDs.contains(window.windowID) { return nil }
            if let bundleIdentifier,
               window.owningApplication?.bundleIdentifier != bundleIdentifier
            {
                return nil
            }
            guard window.frame.width >= 2, window.frame.height >= 2 else { return nil }
            return Self.appKitFrame(
                captureFrame: window.frame,
                displays: content.displays
            )
        }
    }

    static func appKitFrame(captureFrame: CGRect, displays: [SCDisplay]) -> CGRect? {
        let center = CGPoint(x: captureFrame.midX, y: captureFrame.midY)
        guard
            let display = displays.first(where: { $0.frame.contains(center) }),
            let screen = NSScreen.screen(displayID: display.displayID)
        else { return nil }

        return CGRect(
            x: screen.frame.minX + captureFrame.minX - display.frame.minX,
            y: screen.frame.maxY - (captureFrame.minY - display.frame.minY) - captureFrame.height,
            width: captureFrame.width,
            height: captureFrame.height
        )
    }

    private func display(frames: [CGRect]) {
        let visibleFrames = frames.filter { $0.width >= 2 && $0.height >= 2 }
        while panels.count < visibleFrames.count {
            panels.append(makePanel())
        }
        while panels.count > visibleFrames.count {
            panels.removeLast().orderOut(nil)
        }

        for (index, frame) in visibleFrames.enumerated() {
            let panel = panels[index]
            panel.setFrame(frame, display: false)
            if let view = panel.contentView as? CaptureBoundaryView {
                view.showsLabel = index == 0
            }
            panel.orderFrontRegardless()
        }
        updatePanelAppearance()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = CaptureBoundaryView(frame: .zero)
        return panel
    }

    private func updatePanelAppearance() {
        for panel in panels {
            guard let view = panel.contentView as? CaptureBoundaryView else { continue }
            view.sourceName = sourceName
            view.isRecording = isRecording
            view.isPaused = isPaused
            view.duration = duration
            view.needsDisplay = true
        }
    }
}

private extension CaptureBoundaryTarget {
    var needsPolling: Bool {
        switch self {
        case .windows, .application: true
        case .display, .region: false
        }
    }
}

private final class CaptureBoundaryView: NSView {
    var sourceName = "Selected source"
    var isRecording = false
    var isPaused = false
    var duration: TimeInterval = 0
    var showsLabel = true

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = isPaused
            ? NSColor.systemOrange
            : (isRecording ? NSColor.systemRed : NSColor.controlAccentColor)
        color.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8)
        border.lineWidth = 5
        border.stroke()

        guard showsLabel, bounds.width >= 90, bounds.height >= 38 else { return }
        let status: String
        if isPaused {
            status = "Ⅱ PAUSED \(formattedDuration)"
        } else if isRecording {
            status = "● REC \(formattedDuration)"
        } else {
            status = "SELECTED"
        }
        let text = "  \(status)  ·  \(sourceName)  "
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let width = min(textSize.width + 2, max(80, bounds.width - 18))
        let pillRect = CGRect(x: 9, y: bounds.height - 31, width: width, height: 24)
        color.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: pillRect).addClip()
        attributed.draw(at: CGPoint(x: pillRect.minX + 1, y: pillRect.minY + 5))
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private var formattedDuration: String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
