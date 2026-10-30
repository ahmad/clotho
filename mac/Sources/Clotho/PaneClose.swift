import AppKit

// Hovering near a pane's top-right corner shows a small × that closes the pane, the same as ⌘W on it:
// it asks first (unless "Don't ask again" was chosen), and closing a tab's last pane closes the tab. It
// floats over the terminal and takes no rows, so the shell's size never changes.

/// The round × button.
final class PaneCloseButton: NSView {
    static var size: CGFloat { 20 }
    let button = NSButton()
    private let background = Tile(fill: Theme.pill.withAlphaComponent(0.94), radius: 10)
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = Theme.secondaryText
        button.target = self
        button.action = #selector(closeTapped)
        button.setAccessibilityLabel("Close Pane")
        button.toolTip = "Close Pane (⌘W)"
        for view in [background, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Clicks on it stay on it, not the terminal under it.
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

extension PaneHostView {
    /// The corner the pointer has to be in for the × to show (flipped: the top right).
    var closeCorner: NSRect {
        let width = min(bounds.width, 72), height = min(bounds.height, 44)
        return NSRect(x: bounds.maxX - width, y: 0, width: width, height: height)
    }

    /// Shows or hides the × (the pointer came into the corner or left it; tests and screenshots too).
    func setCornerHover(_ on: Bool) {
        guard on, onClose != nil else {
            closeButton?.removeFromSuperview()
            closeButton = nil
            return
        }
        guard closeButton == nil else { return }
        let close = PaneCloseButton()
        close.onClose = { [weak self] in self?.onClose?() }
        addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
        closeButton = close
    }

    func updateCornerTracking() {
        if let cornerTracking { removeTrackingArea(cornerTracking) }
        let area = NSTrackingArea(rect: closeCorner, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self,
                                  userInfo: ["corner": true])
        addTrackingArea(area)
        cornerTracking = area
        // The pane moved or resized under a still pointer.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setCornerHover(closeCorner.contains(point) && window.isKeyWindow)
        }
    }
}
