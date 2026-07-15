import AppKit
import SwiftUI

enum ReccySplitAxis {
    case horizontal
    case vertical
}

/// A native AppKit split view with durable pane sizing and a forgiving divider.
/// NSSplitViewController retains the platform's resizing, cursor, keyboard,
/// accessibility, and restoration behavior. Its divider reserves a forgiving
/// target while drawing only a centered one-point separator.
struct ReccySplitView<FirstContent: View, SecondContent: View>: NSViewControllerRepresentable {
    let axis: ReccySplitAxis
    let autosaveName: String
    let initialFraction: CGFloat
    let firstMinimum: CGFloat
    let firstMaximum: CGFloat?
    let secondMinimum: CGFloat
    let secondMaximum: CGFloat?
    let firstPaneName: String
    let secondPaneName: String
    let firstContent: FirstContent
    let secondContent: SecondContent

    init(
        axis: ReccySplitAxis,
        autosaveName: String,
        initialFraction: CGFloat,
        firstMinimum: CGFloat,
        firstMaximum: CGFloat? = nil,
        secondMinimum: CGFloat,
        secondMaximum: CGFloat? = nil,
        firstPaneName: String,
        secondPaneName: String,
        @ViewBuilder first: () -> FirstContent,
        @ViewBuilder second: () -> SecondContent
    ) {
        self.axis = axis
        self.autosaveName = autosaveName
        self.initialFraction = initialFraction
        self.firstMinimum = firstMinimum
        self.firstMaximum = firstMaximum
        self.secondMinimum = secondMinimum
        self.secondMaximum = secondMaximum
        self.firstPaneName = firstPaneName
        self.secondPaneName = secondPaneName
        firstContent = first()
        secondContent = second()
    }

    func makeNSViewController(context: Context) -> ReccyNativeSplitViewController {
        let controller = ReccyNativeSplitViewController(
            axis: axis,
            autosaveName: autosaveName,
            initialFraction: initialFraction,
            firstPaneName: firstPaneName,
            secondPaneName: secondPaneName
        )
        controller.install(
            first: AnyView(firstContent),
            second: AnyView(secondContent),
            firstMinimum: firstMinimum,
            firstMaximum: firstMaximum,
            secondMinimum: secondMinimum,
            secondMaximum: secondMaximum
        )
        return controller
    }

    func updateNSViewController(
        _ controller: ReccyNativeSplitViewController,
        context: Context
    ) {
        controller.update(first: AnyView(firstContent), second: AnyView(secondContent))
        controller.updateConstraints(
            firstMinimum: firstMinimum,
            firstMaximum: firstMaximum,
            secondMinimum: secondMinimum,
            secondMaximum: secondMaximum
        )
    }
}

@MainActor
final class ReccyNativeSplitViewController: NSSplitViewController {
    private let initialFraction: CGFloat
    private let initialPositionKey: String
    private var appliedInitialPosition = false
    private var firstHost: NSHostingController<AnyView>?
    private var secondHost: NSHostingController<AnyView>?

    init(
        axis: ReccySplitAxis,
        autosaveName: String,
        initialFraction: CGFloat,
        firstPaneName: String,
        secondPaneName: String
    ) {
        self.initialFraction = min(max(initialFraction, 0), 1)
        initialPositionKey = "reccy.split.\(autosaveName).initialized"
        super.init(nibName: nil, bundle: nil)

        let splitView = ReccyNativeSplitView()
        splitView.isVertical = axis == .horizontal
        splitView.dividerStyle = .thin
        splitView.autosaveName = "com.reccy.split.\(autosaveName)"
        splitView.setAccessibilityLabel(
            "Resizable workspace for \(firstPaneName) and \(secondPaneName)"
        )
        self.splitView = splitView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(
        first: AnyView,
        second: AnyView,
        firstMinimum: CGFloat,
        firstMaximum: CGFloat?,
        secondMinimum: CGFloat,
        secondMaximum: CGFloat?
    ) {
        let firstHost = NSHostingController(rootView: first)
        let secondHost = NSHostingController(rootView: second)
        // NSSplitViewItem owns the pane constraints. Prevent NSHostingController
        // from synthesizing competing intrinsic-size constraints from content.
        firstHost.sizingOptions = []
        secondHost.sizingOptions = []
        let layoutOrientation: NSLayoutConstraint.Orientation = splitView.isVertical
            ? .horizontal
            : .vertical
        for host in [firstHost, secondHost] {
            host.view.setContentHuggingPriority(.defaultLow, for: layoutOrientation)
            host.view.setContentCompressionResistancePriority(.defaultLow, for: layoutOrientation)
        }
        self.firstHost = firstHost
        self.secondHost = secondHost

        let firstItem = NSSplitViewItem(viewController: firstHost)
        let secondItem = NSSplitViewItem(viewController: secondHost)
        configure(
            firstItem,
            minimum: firstMinimum,
            maximum: firstMaximum,
            preferredFraction: initialFraction,
            holdingPriority: NSLayoutConstraint.Priority(rawValue: 251)
        )
        configure(
            secondItem,
            minimum: secondMinimum,
            maximum: secondMaximum,
            preferredFraction: 1 - initialFraction,
            holdingPriority: .defaultLow
        )
        addSplitViewItem(firstItem)
        addSplitViewItem(secondItem)
    }

    func update(first: AnyView, second: AnyView) {
        firstHost?.rootView = first
        secondHost?.rootView = second
    }

    func updateConstraints(
        firstMinimum: CGFloat,
        firstMaximum: CGFloat?,
        secondMinimum: CGFloat,
        secondMaximum: CGFloat?
    ) {
        guard splitViewItems.count == 2 else { return }
        splitViewItems[0].minimumThickness = firstMinimum
        splitViewItems[0].maximumThickness = firstMaximum ?? NSSplitViewItem.unspecifiedDimension
        splitViewItems[1].minimumThickness = secondMinimum
        splitViewItems[1].maximumThickness = secondMaximum ?? NSSplitViewItem.unspecifiedDimension
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialPositionIfNeeded()
    }

    private func configure(
        _ item: NSSplitViewItem,
        minimum: CGFloat,
        maximum: CGFloat?,
        preferredFraction: CGFloat,
        holdingPriority: NSLayoutConstraint.Priority
    ) {
        item.canCollapse = false
        item.minimumThickness = minimum
        item.maximumThickness = maximum ?? NSSplitViewItem.unspecifiedDimension
        item.preferredThicknessFraction = preferredFraction
        item.holdingPriority = holdingPriority
    }

    private func applyInitialPositionIfNeeded() {
        guard !appliedInitialPosition, splitView.subviews.count == 2 else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: initialPositionKey) else {
            appliedInitialPosition = true
            return
        }

        let available = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard available > 0 else { return }
        splitView.setPosition(available * initialFraction, ofDividerAt: 0)
        defaults.set(true, forKey: initialPositionKey)
        appliedInitialPosition = true
    }
}

@MainActor
final class ReccyNativeSplitView: NSSplitView {
    private static let targetThickness: CGFloat = 14
    private static let separatorThickness: CGFloat = 1

    override var dividerThickness: CGFloat { Self.targetThickness }

    override func drawDivider(in rect: NSRect) {
        let separatorRect: NSRect
        if isVertical {
            separatorRect = NSRect(
                x: rect.midX - Self.separatorThickness / 2,
                y: rect.minY,
                width: Self.separatorThickness,
                height: rect.height
            )
        } else {
            separatorRect = NSRect(
                x: rect.minX,
                y: rect.midY - Self.separatorThickness / 2,
                width: rect.width,
                height: Self.separatorThickness
            )
        }

        NSColor.separatorColor.setFill()
        NSBezierPath(rect: separatorRect).fill()
    }
}
