import AppKit
import ScreenCaptureKit

struct RegionSelection: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
}

@MainActor
final class RegionSelectionController {
    private var panels: [RegionSelectionPanel] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?

    /// Presents one coordinated overlay per connected display. A selection is
    /// intentionally constrained to one display because ScreenCaptureKit's
    /// source rectangle is expressed in a single display's coordinate space.
    func selectRegion(across displays: [SCDisplay]) async -> RegionSelection? {
        let availableDisplays = displays.compactMap { display -> (SCDisplay, NSScreen)? in
            guard let screen = NSScreen.screen(displayID: display.displayID) else { return nil }
            return (display, screen)
        }.map { display, screen in
            RegionSelectionDisplay(
                displayID: display.displayID,
                screen: screen,
                pixelWidth: CGFloat(display.width)
            )
        }
        return await selectRegion(across: availableDisplays)
    }

#if DEBUG
    func selectRegionForVisualQA() async -> RegionSelection? {
        let displays = NSScreen.screens.compactMap { screen -> RegionSelectionDisplay? in
            guard let displayID = screen.displayID else { return nil }
            return RegionSelectionDisplay(
                displayID: displayID,
                screen: screen,
                pixelWidth: screen.frame.width * screen.backingScaleFactor
            )
        }
        return await selectRegion(across: displays)
    }
#endif

    private func selectRegion(across displays: [RegionSelectionDisplay]) async -> RegionSelection? {
        finish(with: nil)
        let availableDisplays = displays.filter { $0.screen.frame.width > 0 && $0.screen.frame.height > 0 }
        guard !availableDisplays.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.panels = availableDisplays.map { display in
                self.makePanel(for: display)
            }
            for panel in self.panels { panel.orderFrontRegardless() }
            if let panel = self.panels.first,
               let selectionView = panel.contentView as? RegionSelectionView {
                panel.makeKey()
                panel.makeFirstResponder(selectionView)
            }
            NSCursor.crosshair.set()
        }
    }

    static func sourceRect(from appKitRect: CGRect, screenSize: CGSize) -> CGRect {
        CGRect(
            x: appKitRect.minX,
            y: screenSize.height - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        ).integral
    }

    private func makePanel(for display: RegionSelectionDisplay) -> RegionSelectionPanel {
        let screen = display.screen
        let panel = RegionSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false

        let pointPixelScale = screen.frame.width > 0
            ? display.pixelWidth / screen.frame.width
            : 1
        let selectionView = RegionSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            pointPixelScale: pointPixelScale
        )
        selectionView.onComplete = { [weak self] selection in
            guard let selection else {
                self?.finish(with: nil)
                return
            }
            self?.finish(with: RegionSelection(
                displayID: display.displayID,
                sourceRect: Self.sourceRect(
                    from: selection,
                    screenSize: screen.frame.size
                )
            ))
        }
        panel.contentView = selectionView
        return panel
    }

    private func finish(with selection: RegionSelection?) {
        guard let continuation else {
            closePanels()
            return
        }
        self.continuation = nil
        closePanels()
        NSCursor.arrow.set()
        continuation.resume(returning: selection)
    }

    private func closePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}

private struct RegionSelectionDisplay {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let pixelWidth: CGFloat
}

private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?

    private let pointPixelScale: CGFloat
    private let instructions = NSTextField(labelWithString: "Drag to select a recording area")
    private let dimensions = NSTextField(labelWithString: "")
    private let useButton = NSButton(title: "Use Area", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var selection: CGRect?
    private var dragMode: DragMode?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(frame frameRect: NSRect, pointPixelScale: CGFloat) {
        self.pointPixelScale = max(pointPixelScale, 1)
        super.init(frame: frameRect)
        wantsLayer = true

        instructions.font = .systemFont(ofSize: 14, weight: .semibold)
        instructions.textColor = .labelColor
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dimensions.textColor = .secondaryLabelColor

        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.isEnabled = false
        useButton.target = self
        useButton.action = #selector(acceptSelection)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)

        let labels = NSStackView(views: [instructions, dimensions])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let buttons = NSStackView(views: [cancelButton, useButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let controls = NSStackView(views: [labels, buttons])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 24
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)

        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        material.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(controls)
        addSubview(material)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            material.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            controls.topAnchor.constraint(equalTo: material.topAnchor),
            controls.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()

        guard let selection else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        NSBezierPath(rect: selection).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: selection.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        outline.lineWidth = 2
        outline.stroke()

        NSColor.white.setFill()
        for point in handlePoints(for: selection) {
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let selection else {
            dragMode = .create(origin: point)
            self.selection = CGRect(origin: point, size: .zero)
            updateControls()
            needsDisplay = true
            return
        }

        if let edges = resizeEdges(at: point, in: selection), !edges.isEmpty {
            dragMode = .resize(original: selection, origin: point, edges: edges)
        } else if selection.contains(point) {
            dragMode = .move(original: selection, origin: point)
        } else {
            dragMode = .create(origin: point)
            self.selection = CGRect(origin: point, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode else { return }
        let point = bounded(convert(event.locationInWindow, from: nil))

        switch dragMode {
        case .create(let origin):
            selection = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )

        case .move(let original, let origin):
            let offset = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            var moved = original.offsetBy(dx: offset.x, dy: offset.y)
            if moved.minX < bounds.minX { moved.origin.x = bounds.minX }
            if moved.maxX > bounds.maxX { moved.origin.x = bounds.maxX - moved.width }
            if moved.minY < bounds.minY { moved.origin.y = bounds.minY }
            if moved.maxY > bounds.maxY { moved.origin.y = bounds.maxY - moved.height }
            selection = moved

        case .resize(let original, let origin, let edges):
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            var minX = original.minX
            var maxX = original.maxX
            var minY = original.minY
            var maxY = original.maxY
            if edges.contains(.left) { minX = min(original.maxX - 64, original.minX + dx) }
            if edges.contains(.right) { maxX = max(original.minX + 64, original.maxX + dx) }
            if edges.contains(.bottom) { minY = min(original.maxY - 64, original.minY + dy) }
            if edges.contains(.top) { maxY = max(original.minY + 64, original.maxY + dy) }
            selection = CGRect(
                x: max(bounds.minX, minX),
                y: max(bounds.minY, minY),
                width: min(bounds.maxX, maxX) - max(bounds.minX, minX),
                height: min(bounds.maxY, maxY) - max(bounds.minY, minY)
            )
        }
        updateControls()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        if let selection {
            self.selection = selection.integral
        }
        updateControls()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            acceptSelection()
        case 53:
            cancelSelection()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func acceptSelection() {
        guard let selection, selection.width >= 64, selection.height >= 64 else { return }
        onComplete?(selection.integral)
    }

    @objc private func cancelSelection() {
        onComplete?(nil)
    }

    private func updateControls() {
        guard let selection else {
            instructions.stringValue = "Drag to select a recording area"
            dimensions.stringValue = ""
            useButton.isEnabled = false
            return
        }
        instructions.stringValue = "Drag to move or resize the area"
        let pixelWidth = Int((selection.width * pointPixelScale).rounded())
        let pixelHeight = Int((selection.height * pointPixelScale).rounded())
        dimensions.stringValue = "\(pixelWidth) × \(pixelHeight) px"
        useButton.isEnabled = selection.width >= 64 && selection.height >= 64
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func resizeEdges(at point: CGPoint, in rect: CGRect) -> ResizeEdges? {
        let tolerance: CGFloat = 10
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        var edges: ResizeEdges = []
        if abs(point.x - rect.minX) <= tolerance { edges.insert(.left) }
        if abs(point.x - rect.maxX) <= tolerance { edges.insert(.right) }
        if abs(point.y - rect.minY) <= tolerance { edges.insert(.bottom) }
        if abs(point.y - rect.maxY) <= tolerance { edges.insert(.top) }
        return edges
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }
}

private enum DragMode {
    case create(origin: CGPoint)
    case move(original: CGRect, origin: CGPoint)
    case resize(original: CGRect, origin: CGPoint, edges: ResizeEdges)
}

private struct ResizeEdges: OptionSet {
    let rawValue: Int

    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let bottom = ResizeEdges(rawValue: 1 << 2)
    static let top = ResizeEdges(rawValue: 1 << 3)
}

extension NSScreen {
    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == displayID
        }
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
