import AppKit

/// A borderless symbol button that rests dim and brightens under the pointer, like the machine headers'
/// quiet + (New Workspace).
final class QuietButton: NSButton, HoverRefreshing {
    private let handler: () -> Void
    private var hovering = false { didSet { updateTint() } }

    /// While the Overview covers the window: not in the accessibility tree, as it takes no click and no
    /// keyboard there (the rule is in ChangesDiffView.swift). Not `isHidden`: that is the view's own state.
    var isCoveredForAccessibility = false {
        didSet {
            guard isCoveredForAccessibility != oldValue else { return }
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        isCoveredForAccessibility ? [] : super.accessibilityChildren()
    }

    override func isAccessibilityHidden() -> Bool {
        isCoveredForAccessibility || super.isAccessibilityHidden()
    }

    override func isAccessibilityElement() -> Bool {
        !isCoveredForAccessibility && super.isAccessibilityElement()
    }

    init(symbol: String, label: String, pointSize: CGFloat, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        isBordered = false
        target = self
        action = #selector(run)
        setAccessibilityLabel(label)
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Hover from where the pointer is now (see ChromeItem.refreshHover).
    func refreshHover() { hovering = Pointer.isOver(self) }

    /// For tests and screenshots: as if the pointer came over it or left.
    func setHovering(_ on: Bool) { hovering = on }

    var isBright: Bool { hovering }
    var isHovering: Bool { hovering }

    private func updateTint() {
        contentTintColor = hovering ? Theme.foreground : Theme.dimText.withAlphaComponent(0.7)
    }
}

/// A view whose hover look the sidebar recomputes from the pointer (rows, toggles, quiet buttons).
@MainActor
protocol HoverRefreshing: NSView {
    func refreshHover()
    var isHovering: Bool { get }
}
