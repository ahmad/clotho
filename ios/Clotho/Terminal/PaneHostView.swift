import ClothoKit
import SwiftTerm
import UIKit

// One pane: a SwiftTerm TerminalView fed by the backend's stream for that pane, following
// mac/Sources/Clotho/PaneView.swift.
//
// The PTY size belongs to the daemon. The host sends the size it has room for as the pane's viewport,
// and only ever resizes its terminal to the pane's actual size (from the subscribe reply, a snapshot or
// `resized`). A pane larger than the screen (sized by another client) is scaled down to fit; a smaller
// one sits top-left.

final class PaneTerminalView: TerminalView {
    // Set around every feed. SwiftTerm parses synchronously inside feed, so whatever the emulator sends
    // meanwhile is an automatic reply to a query (DA, DSR, colors), which the daemon answers itself.
    // Keys, paste, and mouse and focus reports come from event handlers, outside feed.
    nonisolated(unsafe) var isFeeding = false

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if isFeeding { return }
        super.send(source: source, data: data)
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
    /// Where pane copies go; tests swap in their own.
    var pasteboard: PaneClipboard.Target = PaneClipboard.general
    private var sentViewport: Size?
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
        terminal.nativeBackgroundColor = Theme.background
        terminal.nativeForegroundColor = Theme.foreground
        terminal.caretColor = Theme.accent
        terminal.optionAsMetaKey = true
        terminal.keyboardAppearance = .dark
        keyBar.terminal = terminal
        terminal.inputAccessoryView = keyBar
        terminal.resizeFromBackend(cols: pane.cols, rows: pane.rows)
        addSubview(terminal)
        store.register(self, for: pane.id)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Subscription

    // Panes subscribe while they're on screen and resume from their last seq when they come back.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { subscribe() } else { unsubscribe() }
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
        let id = paneID, have = haveSeq, viewport = fittedSize()
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

    private func sendViewportIfNeeded() {
        guard subscribed, bounds.width > 0, bounds.height > 0 else { return }
        let viewport = fittedSize()
        guard viewport != sentViewport else { return }
        sentViewport = viewport
        let id = paneID
        Task { [backend] in try? await backend.setViewport(id, viewport) }
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
    func scrolled(source: TerminalView, position: Double) {}
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
    static let background = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
    static let foreground = UIColor(white: 0.9, alpha: 1)
    static let accent = UIColor(red: 0.55, green: 0.75, blue: 1, alpha: 1)
    /// The selected pane, tab and workspace, as on the Mac (#6C96B4).
    static let selection = UIColor(red: 0x6c / 255, green: 0x96 / 255, blue: 0xb4 / 255, alpha: 1)

    static var fontSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "FontSize")
        return saved > 0 ? saved : (UIDevice.current.userInterfaceIdiom == .pad ? 14 : 11)
    }

    static var font: UIFont { UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
}
