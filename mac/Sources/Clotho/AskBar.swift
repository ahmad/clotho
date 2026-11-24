import AppKit
import ClothoKit

// A pane whose agent waits on a permission request the daemon can answer (`agent.decide`) shows the
// request in a bar at its bottom, above the git strip: "Allow Bash: npm test", then Deny and Allow. With
// the keyboard in that pane, ⌘↩ allows and ⌘. denies. The bar takes rows from the terminal while it
// shows and gives them back when the request is answered, here or anywhere else.
//
// In a narrow pane the tool and the start of the command stay readable: the label drops its "Allow "
// (the button says it) and loses its tail, and the Allow button drops its ⌘↩.
//
// One rule: a request can be answered only once it has been the target of Allow and Deny, in view, for
// `settleDelay`. So every request starts off: the first one in a pane (a ⌘. meant as the agent's ESC, or
// a ⌘↩, can be on its way as it arrives) and each one that takes another's place (a double tap). ⌘↩ and
// ⌘. wait again when they come to mean this bar: its pane took the keyboard, or its window became key.
// A held key never answers.

final class AskBar: NSView {
    static var height: CGFloat { max(28, s(30)) }
    /// From the pane's sides, and from its bottom (or the git strip).
    static var margin: CGFloat { s(8) }
    /// How long the buttons stay off after a press whose request didn't leave the model (a failed decide).
    static var retryDelay: TimeInterval = 3
    /// How long a request shows before it can be answered: the buttons and keys stay off that long after
    /// the bar shows a request, and the keys after they come to mean this bar.
    static var settleDelay: TimeInterval = 0.5

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
    /// The request that just showed, until `settleDelay` passes.
    private(set) var settling: String?
    /// Counts the settles and the presses: a timer acts only when none came after the one that set it, so
    /// a request that shows (or is answered) again inside the delay isn't switched on early by the older timer.
    private var settleGeneration: UInt = 0
    private var sentGeneration: UInt = 0
    /// From when ⌘↩ and ⌘. answer: `settleDelay` after they came to mean this bar.
    private var keysFrom = Date.distantPast

    override var isFlipped: Bool { true }

    init(_ request: PermissionRequest) {
        self.request = request
        super.init(frame: .zero)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
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
        settle()
        updateAllowTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        if let window, notification.object as AnyObject? === window { becameKeyTarget() }
    }

    /// ⌘↩ and ⌘. now mean this bar (its pane's terminal took the keyboard, or its window became key),
    /// whoever moved the keyboard: a press on its way was for something else. The buttons stay on: a
    /// click's target is the request under it.
    func becameKeyTarget() {
        keysFrom = Date().addingTimeInterval(Self.settleDelay)
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
        if request.id != self.request.id {
            // The one that showed is gone (answered here or elsewhere): this is another, and the user
            // hasn't read it yet.
            sent = nil
            self.request = request
            settle()
        }
        self.request = request
        // Layout picks the text that fits: all of it, or without its "Allow ".
        label.stringValue = request.askText
        label.toolTip = request.askText
        label.setAccessibilityLabel(request.askText)
        more.stringValue = count > 0 ? "+\(count) more" : ""
        allow.setAccessibilityLabel(request.askText)
        deny.setAccessibilityLabel("Deny \(request.tool)")
        needsLayout = true
    }

    /// Turns the buttons and keys off for `settleDelay`: the user hasn't read the request shown yet.
    private func settle() {
        settleGeneration &+= 1
        let generation = settleGeneration
        if Self.settleDelay > 0 {
            settling = request.id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
                guard let self, settleGeneration == generation else { return }
                settling = nil
                updateEnabled()
            }
        } else {
            settling = nil
        }
        updateEnabled()
    }

    var isEnabled: Bool { sent == nil && settling == nil }

    private func updateEnabled() {
        allow.isEnabled = isEnabled
        deny.isEnabled = isEnabled
    }

    /// Allow's title with room for it: with its key on the focused pane.
    private var allowTitle: String { isFocused ? "Allow ⌘↩" : "Allow" }

    private func updateAllowTitle() {
        allow.title = allowTitle
        needsLayout = true
    }

    @objc private func allowTapped() { decide(.allow) }
    @objc private func denyTapped() { decide(.deny) }

    /// Answers the request shown, once: the buttons stay off until it leaves the model, or come back
    /// after `retryDelay` when it didn't (the decide failed). `byKey`: ⌘↩ or ⌘., which also wait for
    /// `keysFrom`.
    func decide(_ decision: PermissionDecision, byKey: Bool = false) {
        guard isEnabled, !byKey || Date() >= keysFrom else { return }
        sentGeneration &+= 1
        let generation = sentGeneration
        sent = request.id
        updateEnabled()
        onDecide?(request, decision)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, sentGeneration == generation, sent != nil else { return }
            sent = nil
            updateEnabled()
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
    /// in what is left. When the request doesn't fit it loses its "Allow " and then its tail, and Allow
    /// its ⌘↩, so the tool and the start of the command stay readable.
    override func layout() {
        super.layout()
        func place(_ view: NSView, x: CGFloat, size: NSSize) {
            let frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: max(0, size.width), height: size.height)
            if view.frame != frame { view.frame = frame }
        }
        func set(_ text: String) -> CGFloat {
            if label.stringValue != text { label.stringValue = text }
            return label.textSize.width
        }
        func title(_ title: String) {
            if allow.title != title { allow.title = title }
        }
        let inset = s(6), gap = s(6), leading = s(10)
        /// What the label gets with no "+N more".
        func room() -> CGFloat { bounds.width - inset - allow.fittingSize.width - gap - deny.fittingSize.width - gap - leading }
        title(allowTitle)
        if set(request.askText) > room(), set(request.askSubject) > room() {
            title("Allow")
        }
        var right = bounds.width - inset
        for button in [allow, deny] {
            let size = button.fittingSize
            right -= size.width
            place(button, x: right, size: size)
            right -= gap
        }
        let moreSize = more.textSize
        // The request comes first: "+N more" shows beside it whole, or when plenty of it shows anyway.
        let withMore = right - leading - moreSize.width - gap
        let showsMore = !more.stringValue.isEmpty && withMore >= min(label.textSize.width, s(160))
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
            // Every new bar starts off (`AskBar.settleDelay`): the user hasn't read its request yet.
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
        let decision: PermissionDecision
        if [36, 76].contains(event.keyCode) {
            decision = .allow
        } else if event.charactersIgnoringModifiers == "." {
            decision = .deny
        } else {
            return false
        }
        // A held key is swallowed and never answers: its repeats can arrive after the next request has
        // taken this one's place.
        if !event.isARepeat { bar.decide(decision, byKey: true) }
        return true
    }
}

extension PermissionRequest {
    /// "Bash: npm test": the request without its "Allow ", for beside an Allow button with little room.
    var askSubject: String {
        let text = askText
        return text.hasPrefix("Allow ") ? String(text.dropFirst("Allow ".count)) : text
    }
}
