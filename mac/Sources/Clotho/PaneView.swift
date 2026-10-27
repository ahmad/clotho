import AppKit
import ClothoKit
import SwiftTerm

// One pane: a plain SwiftTerm TerminalView fed by the backend's stream for that pane.
//
// The PTY size belongs to the daemon. The host sends the size it has room for as the pane's viewport,
// and only ever resizes its terminal to the pane's actual size (from the subscribe reply, a snapshot or
// `resized`), anchored top-left when the two differ.

final class PaneTerminalView: TerminalView {
    // Set around every feed. SwiftTerm parses synchronously inside feed, so whatever the emulator sends
    // meanwhile is an automatic reply to a query (DA, DSR, colors), which the daemon answers itself.
    // Keys, paste, and mouse and focus reports come from event handlers, outside feed.
    nonisolated(unsafe) var isFeeding = false
    var paneID: PaneID = 0
    var machine: MachineKey = AppDelegate.localKey
    /// The right-click menu, when the program running here isn't taking mouse events.
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    // Files dropped on the terminal upload to the pane's folder; holding ⌥ types their paths instead.
    var onDropFiles: (([URL]) -> Void)?

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if isFeeding { return }
        super.send(source: source, data: data)
    }

    func feedFromBackend(_ bytes: Data) {
        withoutReplies { bytes.withUnsafeBytes { raw in feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self))) } }
    }

    /// Runs something that may make the emulator answer on its own (a feed, or a resize, which sends an
    /// in-band size report when the app asked for one with ?2048), dropping those answers.
    func withoutReplies(_ body: () -> Void) {
        isFeeding = true
        body()
        isFeeding = false
    }

    func enableFileDrops() { registerForDraggedTypes([.fileURL]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        if NSEvent.modifierFlags.contains(.option) {
            let quoted = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            send(txt: quoted.joined(separator: " ") + " ")
        } else {
            onDropFiles?(urls)
        }
        return true
    }
}

final class PaneHostView: NSView, PaneDataSink, TerminalViewDelegate {
    static let padding: CGFloat = 6

    // Top-left coordinates, for anchoring the terminal.
    override var isFlipped: Bool { true }

    let paneID: PaneID
    let terminal: PaneTerminalView
    private let store: ModelStore
    private var backend: SessionBackend { store.backend }

    /// The seq this view's terminal has applied up to; nil until the first snapshot.
    private(set) var haveSeq: UInt64?
    /// The PTY size, which the terminal always matches.
    private(set) var paneSize: Size
    private var sentViewport: Size?
    private var subscribed = false
    // Output arriving within one run loop turn is fed in one call.
    private var pending = Data()
    private var flushScheduled = false

    var isFocusedPane = false {
        didSet { updateBorder() }
    }
    var showsFocusRing = false {
        didSet { updateBorder() }
    }

    init(pane: Pane, store: ModelStore, font: NSFont) {
        paneID = pane.id
        self.store = store
        paneSize = Size(cols: pane.cols, rows: pane.rows)
        terminal = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        updateBorder()

        terminal.paneID = pane.id
        terminal.terminalDelegate = self
        terminal.font = font
        terminal.lineSpacing = 1.2
        terminal.nativeBackgroundColor = Theme.background
        terminal.nativeForegroundColor = Theme.foreground
        terminal.caretColor = Theme.accent
        terminal.installColors(Theme.terminalColors)
        terminal.optionAsMetaKey = true
        terminal.enableFileDrops()
        terminal.withoutReplies { terminal.resize(cols: pane.cols, rows: pane.rows) }
        addSubview(terminal)
        store.register(self, for: pane.id)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Subscription

    // Panes subscribe while they're on screen and resume from their last seq when they come back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { subscribe() } else { unsubscribe() }
    }

    // Subscribing waits for the first layout, so the subscribe carries a viewport: until someone types,
    // the most recent subscriber *with a viewport* decides the PTY size.
    private var wantsSubscription = false

    func subscribe() {
        guard !subscribed else { return }
        guard bounds.width > 0, bounds.height > 0 else {
            wantsSubscription = true
            needsLayout = true
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
        let reserve = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return CGSize(width: max(1, (optimal.width - reserve) / CGFloat(max(1, paneSize.cols))),
                      height: max(1, optimal.height / CGFloat(max(1, paneSize.rows))))
    }

    /// How many cells fit in this view, given the current font.
    func fittedSize(in size: CGSize? = nil) -> Size {
        let bounds = size ?? self.bounds.size
        let cell = cellSize
        let reserve = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let width = bounds.width - Self.padding * 2 - reserve
        let height = bounds.height - Self.padding * 2
        return Size(cols: max(2, Int(width / cell.width)), rows: max(1, Int(height / cell.height)))
    }

    private func applySize(_ size: Size) {
        let current = terminal.terminalDimensions
        guard size != paneSize || current.cols != size.cols || current.rows != size.rows else { return }
        if UserDefaults.standard.bool(forKey: "LogModel") { log("pane \(paneID) terminal → \(size.cols)x\(size.rows)") }
        paneSize = size
        terminal.withoutReplies { terminal.resize(cols: size.cols, rows: size.rows) }
        needsLayout = true
    }

    /// Re-measures after a font change, keeping the terminal at the pane's size.
    func fontChanged(_ font: NSFont) {
        terminal.font = font
        terminal.withoutReplies { terminal.resize(cols: paneSize.cols, rows: paneSize.rows) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Sized to exactly the pane's cells (plus a little slack so rounding never loses a column),
        // so SwiftTerm's own frame-driven resize keeps the terminal at the pane's size.
        let optimal = terminal.getOptimalFrameSize()
        let size = CGSize(width: optimal.width + 0.5, height: optimal.height + 0.5)
        // Anchored top-left, so a pane sized by another client lines up like a normal terminal.
        let frame = NSRect(origin: CGPoint(x: Self.padding, y: Self.padding), size: size)
        if terminal.frame != frame { terminal.frame = frame }
        if wantsSubscription, bounds.width > 0, bounds.height > 0 { subscribe() }
        sendViewportIfNeeded()
    }

    private func sendViewportIfNeeded() {
        guard subscribed, bounds.width > 0, bounds.height > 0 else { return }
        let viewport = fittedSize()
        guard viewport != sentViewport else { return }
        sentViewport = viewport
        if UserDefaults.standard.bool(forKey: "LogModel") { log("pane \(paneID) viewport \(viewport.cols)x\(viewport.rows)") }
        let id = paneID
        Task { [backend] in try? await backend.setViewport(id, viewport) }
    }

    private func updateBorder() {
        layer?.borderColor = (isFocusedPane && showsFocusRing ? Theme.accent.withAlphaComponent(0.7) : NSColor.clear).cgColor
    }

    // Right-clicks in the padding get the terminal's menu.
    override func menu(for event: NSEvent) -> NSMenu? { terminal.contextMenu?() }

    // Clicks in the padding focus the terminal too.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        auditInput(data)
        backend.sendInput(paneID, Data(data))
    }

    /// Input with no key, mouse or paste event behind it, which should never happen during reconnect,
    /// resubscribe or snapshot apply. Focus reports when the window activates also land here.
    static var unattributedInputCount = 0

    private func auditInput(_ data: ArraySlice<UInt8>) {
        let userTypes: Set<NSEvent.EventType> = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                  .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
                                                  .mouseMoved, .otherMouseDragged, .rightMouseDragged]
        let event = NSApp.currentEvent
        if let event, userTypes.contains(event.type), ProcessInfo.processInfo.systemUptime - event.timestamp < 1 { return }
        Self.unattributedInputCount += 1
        let hex = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        log("INPUT pane \(paneID) with no user event behind it (#\(Self.unattributedInputCount), current event \(event.map { "\($0.type.rawValue)" } ?? "none")): \(data.count) bytes \(hex)")
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
}
