import AppKit
import SwiftUI

private struct ReccyTooltipModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .accessibilityHint(Text(text))
            .background(ReccyTooltipAnchor(text: text))
    }
}

extension View {
    func reccyTooltip(_ text: String) -> some View {
        modifier(ReccyTooltipModifier(text: text))
    }
}

private struct ReccyTooltipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ReccyTooltipTrackingView {
        let view = ReccyTooltipTrackingView()
        view.tooltipText = text
        return view
    }

    func updateNSView(_ view: ReccyTooltipTrackingView, context: Context) {
        view.tooltipText = text
    }

    static func dismantleNSView(_ view: ReccyTooltipTrackingView, coordinator: Void) {
        ReccyTooltipPresenter.shared.hide(owner: ObjectIdentifier(view))
    }
}

private final class ReccyTooltipTrackingView: NSView {
    var tooltipText = ""

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window, !tooltipText.isEmpty else { return }
        let windowRect = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        ReccyTooltipPresenter.shared.schedule(
            text: tooltipText,
            anchor: screenRect,
            owner: ObjectIdentifier(self)
        )
    }

    override func mouseExited(with event: NSEvent) {
        ReccyTooltipPresenter.shared.hide(owner: ObjectIdentifier(self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class ReccyTooltipPresenter {
    static let shared = ReccyTooltipPresenter()

    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?
    private var activeOwner: ObjectIdentifier?

    func schedule(text: String, anchor: CGRect, owner: ObjectIdentifier) {
        showTask?.cancel()
        panel?.orderOut(nil)
        activeOwner = owner

        showTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.activeOwner == owner else { return }
            self.show(text: text, anchor: anchor)
        }
    }

    func hide(owner: ObjectIdentifier) {
        guard activeOwner == owner else { return }
        showTask?.cancel()
        showTask = nil
        panel?.orderOut(nil)
        panel = nil
        activeOwner = nil
    }

    private func show(text: String, anchor: CGRect) {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let textBounds = (text as NSString).boundingRect(
            with: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let size = CGSize(
            width: min(300, max(56, ceil(textBounds.width) + 22)),
            height: max(28, ceil(textBounds.height) + 14)
        )
        let hostingView = NSHostingView(rootView: ReccyTooltipBubble(text: text))
        hostingView.frame = CGRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level.popUpMenu
        panel.collectionBehavior = NSWindow.CollectionBehavior([
            .transient,
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ])

        let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        var origin = CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY + 8
        )
        if origin.y + size.height > visibleFrame.maxY {
            origin.y = anchor.minY - size.height - 8
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct ReccyTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 0.5)
            }
    }
}
