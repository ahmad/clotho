import AppKit
import ClothoKit

// A pane whose agent waits on a permission request the daemon can answer (`agent.decide`) shows the
// request in a bar at its bottom, above the git strip: "Allow Bash: npm test", then Deny and Allow. With
// the keyboard in that pane, ⌘↩ allows and ⌘. denies. The bar takes rows from the terminal while it
// shows and gives them back when the request is answered, here or anywhere else.

final class AskBar: NSView {
    static var height: CGFloat { max(28, s(30)) }
    /// From the pane's sides, and from its bottom (or the git strip).
    static var margin: CGFloat { s(8) }
    /// How long the buttons stay off after a press whose request didn't leave the model (a failed decide).
    static var retryDelay: TimeInterval = 3

    let label = NSTextField(labelWithString: "")
    /// "+1 more", when other requests wait behind this one.
    let more = NSTextField(labelWithString: "")
    let deny = NSButton(title: "Deny", target: nil, action: nil)
    let allow = NSButton(title: "Allow", target: nil, action: nil)
    private(set) var request: PermissionRequest
    var onDecide: ((PermissionRequest, PermissionDecision) -> Void)?
    /// The pane is the focused one: only there do ⌘↩ and ⌘. work, so only there is ⌘↩ shown.
    var isFocused = false {
        didSet { if isFocused != oldValue { updateAllowTitle() } }
    }
    /// The request a press answered, until it leaves the model or `retryDelay` passes.
    private(set) var sent: String?

    override var isFlipped: Bool { true }

    init(_ request: PermissionRequest) {
        self.request = request
        super.init(frame: .zero)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = Theme.foreground
        more.textColor = Theme.secondaryText
        more.lineBreakMode = .byClipping
        for (button, action) in [(deny, #selector(denyTapped)), (allow, #selector(allowTapped))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.action = action
            // A click on a button leaves the keyboard in the terminal.
            button.refusesFirstResponder = true
        }
        allow.bezelColor = .controlAccentColor
        deny.toolTip = "Deny (⌘.)"
        allow.toolTip = "Allow (⌘↩)"
        for view in [label, more, deny, allow] as [NSView] { addSubview(view) }
        applyScale()
        show(request, more: 0)
        updateAllowTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fonts at the current zoom.
    func applyScale() {
        label.font = .monospacedSystemFont(ofSize: s(11.5), weight: .regular)
        more.font = .systemFont(ofSize: s(11))
        needsLayout = true
    }

    /// Shows the oldest request and how many wait behind it.
    func show(_ request: PermissionRequest, more count: Int) {
        if request.id != self.request.id, sent != nil {
            // The one that was answered is gone: this is another.
            sent = nil
            setEnabled(true)
        }
        self.request = request
        label.stringValue = request.askText
        label.toolTip = request.askText
        more.stringValue = count > 0 ? "+\(count) more" : ""
        allow.setAccessibilityLabel(request.askText)
        deny.setAccessibilityLabel("Deny \(request.tool)")
        needsLayout = true
    }

    var isEnabled: Bool { sent == nil }

    private func setEnabled(_ on: Bool) {
        allow.isEnabled = on
        deny.isEnabled = on
    }

    private func updateAllowTitle() {
        allow.title = isFocused ? "Allow ⌘↩" : "Allow"
        needsLayout = true
    }

    @objc private func allowTapped() { decide(.allow) }
    @objc private func denyTapped() { decide(.deny) }

    /// Answers the request shown, once: the buttons stay off until it leaves the model, or come back
    /// after `retryDelay` when it didn't (the decide failed).
    func decide(_ decision: PermissionDecision) {
        guard sent == nil else { return }
        let id = request.id
        sent = id
        setEnabled(false)
        onDecide?(request, decision)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, sent == id else { return }
            sent = nil
            setEnabled(true)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Amber over the terminal's background, opaque: the terminal can still have rows under the bar
        // until the daemon has resized it.
        let appearance: ClothoPalette.Appearance = effectiveAppearance.isDark ? .dark : .light
        let background = NSColor(hex: Theme.palette(for: effectiveAppearance).background)
        let amber = NSColor(hex: AgentMark.needsYou.hex(for: appearance))
        layer?.backgroundColor = (background.blended(withFraction: AgentMark.tintAlpha(for: appearance), of: amber) ?? background).cgColor
        layer?.borderColor = amber.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// By hand, from the trailing end: Allow, Deny, "+N more" when there's room for it, and the request
    /// in what is left.
    override func layout() {
        super.layout()
        func place(_ view: NSView, x: CGFloat, size: NSSize) {
            let frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: max(0, size.width), height: size.height)
            if view.frame != frame { view.frame = frame }
        }
        let inset = s(6), gap = s(6), leading = s(10)
        var right = bounds.width - inset
        for button in [allow, deny] {
            let size = button.fittingSize
            right -= size.width
            place(button, x: right, size: size)
            right -= gap
        }
        let moreSize = more.textSize
        let showsMore = !more.stringValue.isEmpty && right - leading - moreSize.width - gap >= s(72)
        more.isHidden = !showsMore
        if showsMore {
            right -= moreSize.width
            place(more, x: right, size: moreSize)
            right -= gap
        }
        let labelSize = label.textSize
        place(label, x: leading, size: NSSize(width: min(labelSize.width.rounded(.up), right - leading), height: labelSize.height))
    }

    // Clicks on the bar (outside its buttons) stay here, not the terminal under the pane.
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

extension PaneHostView {
    /// Shows, updates or removes the bar for `chrome`: the oldest request the daemon can answer.
    func updateAskBar() {
        let asks = chrome.asks
        guard let first = asks.first else {
            guard let bar = askBar else { return }
            bar.removeFromSuperview()
            askBar = nil
            // The terminal gets its rows back (layout sends the viewport).
            needsLayout = true
            return
        }
        let bar = askBar ?? {
            let bar = AskBar(first)
            bar.onDecide = { [weak self] request, decision in self?.onDecide?(request.id, decision) }
            addSubview(bar)
            askBar = bar
            needsLayout = true
            return bar
        }()
        bar.show(first, more: asks.count - 1)
        bar.isFocused = isFocusedPane
    }

    /// Room the bar takes above the git strip (or the pane's bottom), with its margin.
    var askBarHeight: CGFloat { askBar == nil ? 0 : AskBar.height + AskBar.margin }

    /// Where the bar goes (flipped).
    var askBarFrame: NSRect {
        NSRect(x: AskBar.margin, y: bounds.height - gitStripHeight - AskBar.margin - AskBar.height,
               width: max(0, bounds.width - AskBar.margin * 2), height: AskBar.height)
    }

    /// ⌘↩ allows and ⌘. denies the request shown in the pane whose terminal has the keyboard. True when
    /// the key was that (the caller drops the event); anything else goes on untouched, so ⌘. still
    /// reaches the terminal as ESC when no request shows.
    static func handleAskKey(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        guard let terminal = firstResponder as? PaneTerminalView, let host = terminal.superview as? PaneHostView,
              let bar = host.askBar,
              event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command else { return false }
        if [36, 76].contains(event.keyCode) {
            bar.decide(.allow)
            return true
        }
        if event.charactersIgnoringModifiers == "." {
            bar.decide(.deny)
            return true
        }
        return false
    }
}
