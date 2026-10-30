import ClothoKit
import SwiftTerm
import UIKit

// One pane: a SwiftTerm TerminalView fed by the backend's stream for that pane, following
// mac/Sources/Clotho/PaneView.swift.
//
// The PTY size belongs to the daemon. The host sends the size it has room for as the pane's viewport,
// and only ever resizes its terminal to the pane's actual size (from the subscribe reply, a snapshot or
// `resized`). With clothod 0.1.28 the pane takes the viewport of the client that focused it last, so the
// host reports focus (noteFocus) when the pane gets the user's attention; typing doesn't resize. A pane
// larger than the screen (sized by another client) is scaled down to fit; a smaller one sits top-left.

final class PaneTerminalView: TerminalView {
    // Set around every feed. SwiftTerm parses synchronously inside feed, so whatever the emulator sends
    // meanwhile is an automatic reply to a query (DA, DSR, colors), which the daemon answers itself.
    // Keys, paste, and mouse and focus reports come from event handlers, outside feed.
    nonisolated(unsafe) var isFeeding = false
    /// Showing a saved screen (the machine isn't live yet): nothing typed goes anywhere, and the keyboard
    /// doesn't come up. Scrolling and selecting still work.
    nonisolated(unsafe) var readOnly = false

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if isFeeding || readOnly { return }
        super.send(source: source, data: data)
    }

    override var canBecomeFirstResponder: Bool { !readOnly && super.canBecomeFirstResponder }

    /// The terminal took the keyboard (or was asked to again): the pane has the user's attention.
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// Paste with an image and no text on the clipboard; the host uploads it and pastes its path.
    var onImagePaste: ((Data) -> Void)?

    var kittyKeyboard: Bool { !keyboardEnhancementFlags.isEmpty }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let kitty = kittyKeyboard
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, let bytes = EditingKeys.bytes(keyCode: key.keyCode, modifiers: key.modifierFlags, kitty: kitty) {
                // SwiftTerm never sees the press; its pressesEnded only reports releases of presses it reported.
                send(bytes)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    /// An image alone on the clipboard can't go through a terminal paste, and the agent reading it runs on
    /// another machine; the host saves it there and pastes the path (ImagePaste). Text still wins.
    override func paste(_ sender: Any?) {
        if readOnly { return }
        let board = UIPasteboard.general
        if let onImagePaste, ImagePaste.shouldPasteImage(hasText: board.hasStrings, hasImage: board.hasImages) {
            guard let png = ImagePaste.png(from: board) else { return }
            onImagePaste(png)
            return
        }
        super.paste(sender)
    }

    func feedFromBackend(_ bytes: Data) {
        isFeeding = true
        bytes.withUnsafeBytes { raw in feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self))) }
        isFeeding = false
    }

    /// Resizes to the pane's size. Whatever the emulator emits meanwhile (an in-band resize report, say)
    /// is an automatic reply too, so it's dropped the same way.
    func resizeFromBackend(cols: Int, rows: Int) {
        isFeeding = true
        resize(cols: cols, rows: rows)
        isFeeding = false
    }
}

final class PaneHostView: UIView, PaneDataSink, TerminalViewDelegate {
    static let padding: CGFloat = 4

    let paneID: PaneID
    let terminal: PaneTerminalView
    private let store: ModelStore
    private var backend: SessionBackend { store.backend }
    private let keyBar: KeyBar

    /// The seq this view's terminal has applied up to; nil until the first snapshot.
    private(set) var haveSeq: UInt64?
    /// The PTY size, which the terminal always matches.
    private(set) var paneSize: Size
    /// How the last subscribe resumed (live, replay or snapshot), shown briefly for checking resume.
    private(set) var lastMode: Subscription.Mode?
    var onModeChange: ((Subscription.Mode) -> Void)?
    /// Called after the pane put text on the clipboard, for the "Copied" confirmation.
    var onCopy: (() -> Void)?
    /// After output or a snapshot reached the terminal, and after it scrolled (find in pane).
    var onOutput: (() -> Void)?
    var onScroll: (() -> Void)?
    /// When the pane leaves the screen, so its last screen can be saved first.
    var onLeave: ((PaneHostView) -> Void)?
    /// A two-finger swipe across the pane: +1 for the next tab (swiped left), -1 for the previous.
    var onSwipeTab: ((Int) -> Void)?
    /// A pinch ended: the font size it asks for (the pane is resized once, then).
    var onZoom: ((CGFloat) -> Void)?
    private var pinchStartSize: CGFloat = Theme.fontSize
    /// Read-only while the machine shows its saved model.
    var readOnly = false {
        didSet {
            guard readOnly != oldValue else { return }
            terminal.readOnly = readOnly
            // Live again on screen: the keyboard comes back, as when the pane opens.
            if readOnly { _ = terminal.resignFirstResponder() } else if window != nil { _ = terminal.becomeFirstResponder() }
            setNeedsLayout()
        }
    }
    /// Where pane copies go; tests swap in their own.
    var pasteboard: PaneClipboard.Target = PaneClipboard.general
    private var sentViewport: Size?
    /// A pending `focusPane`: focus actions within `focusDelay` of each other send one call, after the
    /// keyboard has settled the viewport.
    private var focusWork: DispatchWorkItem?
    static let focusDelay: TimeInterval = 0.3
    /// Each `focusPane` sent, for tests.
    var onFocusSent: (() -> Void)?
    private var subscribed = false
    private var wantsSubscription = false
    // Output arriving within one run loop turn is fed in one call.
    private var pending = Data()
    private var flushScheduled = false

    init(pane: Pane, store: ModelStore) {
        paneID = pane.id
        self.store = store
        paneSize = Size(cols: pane.cols, rows: pane.rows)
        terminal = PaneTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        keyBar = KeyBar(frame: CGRect(x: 0, y: 0, width: 320, height: KeyBar.height))
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = Theme.background

        terminal.terminalDelegate = self
        terminal.font = Theme.font
        applyPalette()
        terminal.optionAsMetaKey = true
        keyBar.terminal = terminal
        terminal.inputAccessoryView = keyBar
        terminal.resizeFromBackend(cols: pane.cols, rows: pane.rows)
        addSubview(terminal)
        // A text beam over the terminal with a trackpad or mouse (iPad), as over any text.
        terminal.addInteraction(UIPointerInteraction(delegate: self))
        // Light and dark (the system's, or the app's own choice) each have their own palette.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: PaneHostView, _: UITraitCollection) in
            self.applyPalette()
        }
        store.register(self, for: pane.id)
        addGestures()
        terminal.onFocus = { [weak self] in self?.noteFocus() }
        // Back in front (or the window active again) with this pane showing.
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func becameActive() {
        if window != nil { noteFocus() }
    }

    /// Shows the palette for the current appearance, and tells the machine, so apps that ask the terminal
    /// its colours (Claude Code's "auto" theme, vim's background) match a light pane (`client.colors`,
    /// clothod 0.1.20; the backend sends it only to a daemon that has it, and only when it changes).
    private func applyPalette() {
        let palette = TerminalPalette.current(traitCollection)
        palette.apply(to: terminal)
        backend.setTerminalColors(TerminalColors(palette))
    }

    // MARK: Gestures

    /// Two-finger swipes switch tabs and a pinch zooms the text. Two fingers, so the terminal's own one-finger
    /// drags (scrolling, selecting, mouse mode) and the screen-edge back swipe keep working.
    private func addGestures() {
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        UISelectionFeedbackGenerator().selectionChanged()
        onSwipeTab?(swipe.direction == .left ? 1 : -1)
    }

    /// While pinching, the text scales as a preview; at the end the font changes once (so the PTY resizes once).
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchStartSize = terminal.font.pointSize
        case .changed:
            let scale = min(max(pinch.scale, Self.minFont / pinchStartSize), Self.maxFont / pinchStartSize)
            terminal.transform = CGAffineTransform(scaleX: scale, y: scale)
        case .ended:
            let size = Self.zoomedSize(from: pinchStartSize, scale: pinch.scale)
            setNeedsLayout()
            if size != pinchStartSize {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onZoom?(size)
            }
        default:
            setNeedsLayout()
        }
    }

    static let minFont: CGFloat = 7
    static let maxFont: CGFloat = 28

    /// The font a pinch asks for: the start size times the pinch, in whole points, within 7–28.
    static func zoomedSize(from start: CGFloat, scale: CGFloat) -> CGFloat {
        min(max((start * scale).rounded(), minFont), maxFont)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Subscription

    // Panes subscribe while they're on screen and resume from their last seq when they come back.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            subscribe()
        } else {
            onLeave?(self)
            unsubscribe()
        }
    }

    // MARK: Saved screens

    /// Shows a saved screen until the pane's own data arrives: only before any, and the daemon's snapshot
    /// (which starts with a full reset) then draws over it in place.
    func showSaved(_ screen: SavedScreen) {
        guard haveSeq == nil, screen.cols > 0, screen.rows > 0 else { return }
        applySize(Size(cols: screen.cols, rows: screen.rows))
        terminal.feedFromBackend(ScreenCapture.replay(screen))
    }

    /// The live screen, for saving; nil until the pane has had data of its own.
    func capture() -> SavedScreen? {
        guard haveSeq != nil, let emulator = terminal.swiftTermTerminal else { return nil }
        flush()
        return ScreenCapture.capture(emulator)
    }

    // Subscribing waits for the first layout, so the subscribe carries a viewport.
    func subscribe() {
        guard !subscribed else { return }
        guard bounds.width > 0, bounds.height > 0 else {
            wantsSubscription = true
            setNeedsLayout()
            return
        }
        wantsSubscription = false
        subscribed = true
        // Read-only (a saved model) has no keyboard, so its room is taller than the live pane's will be: the
        // pane keeps its size until it's live, instead of growing now and shrinking when the keyboard comes.
        let id = paneID, have = haveSeq, viewport: Size? = readOnly ? nil : fittedSize()
        sentViewport = viewport
        Task { [backend] in
            do {
                try await backend.subscribe(id, haveSeq: have, scrollback: 1000, viewport: viewport)
            } catch {
                log("subscribe pane \(id) failed: \(error)")
            }
        }
    }

    func unsubscribe() {
        wantsSubscription = false
        guard subscribed else { return }
        subscribed = false
        flush()
        let id = paneID
        Task { [backend] in try? await backend.unsubscribe(id) }
    }

    /// Called when the pane leaves the model for good.
    func detach() {
        store.unregister(paneID)
        subscribed = false
        removeFromSuperview()
    }

    // MARK: PaneDataSink

    func paneSubscribed(_ subscription: Subscription) {
        flush()
        log("pane \(paneID) subscribed: \(subscription.mode) at \(subscription.seq) (had \(haveSeq.map(String.init) ?? "nothing"))")
        lastMode = subscription.mode
        onModeChange?(subscription.mode)
        applySize(Size(cols: subscription.cols, rows: subscription.rows))
    }

    func paneOutput(seq: UInt64, bytes: Data) {
        // A gap means a stream restarted under us (another subscribe); the snapshot or replay that follows fixes it.
        if let have = haveSeq, seq != have + UInt64(pending.count) {
            log("pane \(paneID): output at \(seq), expected \(have + UInt64(pending.count))")
        }
        if haveSeq == nil { haveSeq = seq }
        pending.append(bytes)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    func paneSnapshot(seq: UInt64, cols: Int, rows: Int, bytes: Data) {
        pending.removeAll()
        applySize(Size(cols: cols, rows: rows))
        // The snapshot starts with a full reset, so earlier state doesn't matter.
        terminal.feedFromBackend(bytes)
        haveSeq = seq
        onOutput?()
    }

    func paneResized(cols: Int, rows: Int, seq: UInt64) {
        flush()
        applySize(Size(cols: cols, rows: rows))
    }

    /// A copy from the pane (`pane.clipboard`); sent only to the pane's subscribers, so only to panes on screen.
    func paneClipboard(text: String, selection: Bool) {
        copyFromPane(text, selection: selection)
    }

    func paneResync() {
        pending.removeAll()
    }

    func paneReset() {
        pending.removeAll()
        haveSeq = nil
        terminal.feedFromBackend(Data([0x1b, 0x63]))
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let bytes = pending
        pending = Data()
        terminal.feedFromBackend(bytes)
        haveSeq = (haveSeq ?? 0) + UInt64(bytes.count)
        onOutput?()
    }

    // MARK: Size

    /// One cell, measured from the terminal's own frame calculation.
    var cellSize: CGSize {
        let optimal = terminal.getOptimalFrameSize()
        return CGSize(width: max(1, optimal.width / CGFloat(max(1, paneSize.cols))),
                      height: max(1, optimal.height / CGFloat(max(1, paneSize.rows))))
    }

    /// How many cells fit in this view, given the current font.
    func fittedSize() -> Size {
        let cell = cellSize
        let width = bounds.width - Self.padding * 2
        let height = bounds.height - Self.padding * 2
        return Size(cols: max(2, Int(width / cell.width)), rows: max(1, Int(height / cell.height)))
    }

    private func applySize(_ size: Size) {
        let current = terminal.terminalDimensions
        guard size != paneSize || current.cols != size.cols || current.rows != size.rows else { return }
        paneSize = size
        terminal.resizeFromBackend(cols: size.cols, rows: size.rows)
        setNeedsLayout()
    }

    func setFont(_ font: UIFont) {
        terminal.font = font
        terminal.resizeFromBackend(cols: paneSize.cols, rows: paneSize.rows)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Sized to exactly the pane's cells (plus a little slack so rounding never loses a column), so
        // SwiftTerm's bounds-driven resize keeps the terminal at the pane's size.
        let optimal = terminal.getOptimalFrameSize()
        let size = CGSize(width: optimal.width + 0.5, height: optimal.height + 0.5)
        let room = CGSize(width: bounds.width - Self.padding * 2, height: bounds.height - Self.padding * 2)
        let scale = min(1, room.width / max(1, size.width), room.height / max(1, size.height))
        if terminal.bounds.size != size { terminal.bounds = CGRect(origin: .zero, size: size) }
        terminal.transform = scale < 1 ? CGAffineTransform(scaleX: scale, y: scale) : .identity
        // Anchored top-left, so a pane sized by another client lines up like a normal terminal.
        terminal.center = CGPoint(x: Self.padding + size.width * scale / 2, y: Self.padding + size.height * scale / 2)
        if wantsSubscription, bounds.width > 0, bounds.height > 0 { subscribe() }
        sendViewportIfNeeded()
    }

    // Sent at once, not debounced: a late resize (0.3 s after the keyboard hides for a menu) changed the model
    // while the Pane actions menu was open and closed its submenu.
    private func sendViewportIfNeeded() {
        guard subscribed, !readOnly, bounds.width > 0, bounds.height > 0 else { return }
        let viewport = fittedSize()
        guard viewport != sentViewport else { return }
        sentViewport = viewport
        let id = paneID
        Task { [backend] in try? await backend.setViewport(id, viewport) }
    }

    // MARK: Focus

    /// The pane got the user's attention: it came on screen, its terminal took the keyboard, or the app came
    /// back to the front with it showing. The machine then sizes the pane to this phone's viewport
    /// (`pane.focus`, clothod 0.1.28); typing no longer does. Debounced, and the viewport goes first, so the
    /// machine has the size the pane has room for once the keyboard is up.
    func noteFocus() {
        guard window != nil, !readOnly else { return }
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendFocus() }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusDelay, execute: work)
    }

    private func sendFocus() {
        focusWork = nil
        guard subscribed, !readOnly, window != nil, UIApplication.shared.applicationState == .active,
              bounds.width > 0, bounds.height > 0 else { return }
        let id = paneID, viewport = fittedSize(), resend = viewport != sentViewport
        sentViewport = viewport
        onFocusSent?()
        Task { [store] in
            if resend { try? await store.backend.setViewport(id, viewport) }
            do { try await store.focusPane(id) } catch { log("focus pane \(id) failed: \(error)") }
        }
    }

    // Taps in the padding focus the terminal too.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        _ = terminal.becomeFirstResponder()
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        backend.sendInput(paneID, Data(data))
    }

    // The terminal follows the pane's size; its own size changes are never sent anywhere.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    // Titles and folders come from the daemon's model.
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) { onScroll?() }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // The daemon reports bells as events.
    func bell(source: TerminalView) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        UIApplication.shared.open(url)
    }

    // OSC 52 seen by SwiftTerm in OUTPUT. A daemon with `pane.clipboard` sends each copy as an event
    // instead (paneClipboard), and acting on the raw bytes too would copy twice, and again on every
    // replay. Only older daemons rely on this path.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard store.hello?.features.contains(.paneClipboard) != true,
              let text = String(data: content, encoding: .utf8) else { return }
        copyFromPane(text, selection: false)
    }

    /// The pane asked to set the clipboard (OSC 52; how Claude Code and Codex copy). Only the pane on
    /// screen, with the app in front, may: a pane the user isn't looking at writing the phone's
    /// clipboard would be a surprise, and they couldn't see what it copied.
    func copyFromPane(_ text: String, selection: Bool) {
        let foreground = UIApplication.shared.applicationState != .background
        guard PaneClipboard.copy(text, selection: selection, visible: foreground && window != nil && subscribed,
                                 to: pasteboard) else { return }
        onCopy?()
    }
}

/// Clipboard writes coming from a pane (OSC 52, docs/protocol.md "Clipboard"). Writes only: a pane can
/// never read the clipboard (SwiftTerm's clipboardRead stays at its default, which refuses).
enum PaneClipboard {
    typealias Target = (String) -> Void
    static let general: Target = { UIPasteboard.general.string = $0 }

    /// Writes `text` if it's for the clipboard (not X11's primary selection, which iOS doesn't have), the
    /// pane is visible and the text isn't empty; returns whether it did.
    @discardableResult
    static func copy(_ text: String, selection: Bool, visible: Bool, to pasteboard: Target) -> Bool {
        guard !selection, visible, !text.isEmpty else { return false }
        pasteboard(text)
        return true
    }
}

enum Theme {
    /// The terminal's background and foreground in the current appearance (TerminalPalette).
    static let background = UIColor { UIColor(hex: TerminalPalette.current($0).background) }
    static let foreground = UIColor { UIColor(hex: TerminalPalette.current($0).foreground) }
    /// The caret and the key bar's latched Ctrl: #6C96B4, or #3F6E8F in light.
    static let accent = UIColor { UIColor(hex: TerminalPalette.current($0).caret) }
    /// The selected pane, tab and workspace, as on the Mac (#6C96B4).
    static let selection = UIColor(red: 0x6c / 255, green: 0x96 / 255, blue: 0xb4 / 255, alpha: 1)

    static var fontSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "FontSize")
        return saved > 0 ? saved : (UIDevice.current.userInterfaceIdiom == .pad ? 14 : 11)
    }

    static var font: UIFont { UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
}

extension PaneHostView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: terminal.font.lineHeight))
    }
}

extension PaneHostView: UIGestureRecognizerDelegate {
    /// Alongside the terminal's own recognizers (its scroll view's pan, selection).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
