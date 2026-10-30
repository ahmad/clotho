import AppKit
import ClothoKit
import SwiftTerm

// Find in a pane (⌘F): a bar at the pane's top right, with Return or ⌘G for the next older match and
// ⇧Return or ⇧⌘G for the next newer one, plus case and regex toggles. Matches come from the daemon's
// `pane.search`, which covers all the history it keeps for the pane. Every visible match is outlined, and the
// current one is filled in. A daemon without `pane.search` gets SwiftTerm's own search of this
// view's buffer instead, which selects the match.

/// The search state of one pane, with its bar and highlights. Owned by the pane's PaneHostView.
@MainActor
final class PaneSearchController: NSObject, NSSearchFieldDelegate {
    private weak var host: PaneHostView?
    private let store: ModelStore
    let bar = PaneFindBar()
    let highlights = SearchHighlightView()
    private(set) var matches: [PaneSearchMatch] = []
    /// Index into `matches`, newest first; nil before the first jump.
    private(set) var current: Int?
    private(set) var resultSeq: UInt64?
    private(set) var truncated = false
    private var pendingSearch: DispatchWorkItem?
    private var generation = 0
    var onClose: (() -> Void)?

    static let maxMatches = 1000

    init(host: PaneHostView, store: ModelStore) {
        self.host = host
        self.store = store
        super.init()
        bar.field.delegate = self
        bar.onNext = { [weak self] in self?.step(older: true) }
        bar.onPrevious = { [weak self] in self?.step(older: false) }
        bar.onClose = { [weak self] in self?.onClose?() }
        bar.onOptionsChanged = { [weak self] in self?.search(now: true) }
    }

    var usesDaemon: Bool { store.hello?.features.contains(.paneSearch) == true }
    var query: String { bar.field.stringValue }

    func focusField() {
        bar.window?.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectAll(nil)
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { search(now: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            step(older: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    /// Runs the search again, after a pause while typing (or `now`).
    func search(now: Bool) {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.15), execute: work)
    }

    /// New output moved the lines; the positions are refreshed (quietly, keeping the current match's place).
    func outputArrived() {
        guard usesDaemon, !query.isEmpty, pendingSearch == nil || pendingSearch!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in self?.runSearch(keepPlace: true) }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func runSearch(keepPlace: Bool = false) {
        pendingSearch = nil
        guard let host else { return }
        let text = query
        generation += 1
        let mine = generation
        guard !text.isEmpty else {
            matches = []
            current = nil
            host.terminal.clearSearch()
            render()
            return
        }
        guard usesDaemon else {
            matches = []
            current = nil
            render()
            return
        }
        let options = bar.options
        let pane = host.paneID
        let previous = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        Task { @MainActor in
            var found: [PaneSearchMatch] = []
            var before: CellPosition?
            var seq: UInt64?
            do {
                // Pages from the bottom up, while seq holds still, up to maxMatches.
                repeat {
                    let page = try await store.backend.searchPane(pane, query: text, options: PaneSearchOptions(
                        regex: options.regex, caseSensitive: options.caseSensitive,
                        limit: min(1000, Self.maxMatches - found.count), before: before))
                    if let seq, page.seq != seq { break }
                    seq = page.seq
                    found += page.matches
                    before = page.next
                } while before != nil && found.count < Self.maxMatches && mine == generation
            } catch {
                guard mine == generation else { return }
                matches = []
                current = nil
                bar.setStatus((error as? BackendError)?.code == "bad_request" ? "Invalid pattern" : "Can't search", error: true)
                highlights.update(matches: [], current: nil, host: host)
                log("pane \(pane): search failed: \(error)")
                return
            }
            guard mine == generation else { return }
            matches = found
            resultSeq = seq
            truncated = before != nil
            if keepPlace, let previous {
                // The same text nearest the old spot (lines move up as output arrives).
                current = found.indices.min { abs(found[$0].start.line - previous.start.line) < abs(found[$1].start.line - previous.start.line) }
            } else {
                current = found.isEmpty ? nil : 0
                if !found.isEmpty { reveal() }
            }
            render()
            if UserDefaults.standard.bool(forKey: "LogSearch") {
                log("pane \(pane): search \"\(text)\" → \(found.count) matches at seq \(seq ?? 0)"
                    + (found.first.map { ", newest at line \($0.start.line) col \($0.start.col): \($0.text)" } ?? ""))
            }
        }
    }

    /// The next older (up) or newer (down) match, wrapping around.
    func step(older: Bool) {
        guard let host, !query.isEmpty else { return }
        guard usesDaemon else {
            let options = SearchOptions(caseSensitive: bar.options.caseSensitive, regex: bar.options.regex)
            let found = older ? host.terminal.findPrevious(query, options: options) : host.terminal.findNext(query, options: options)
            let summary = host.terminal.searchMatchSummary(query, options: options)
            bar.setStatus(found ? "\(summary.index) of \(summary.total)" : "No matches", error: !found)
            return
        }
        guard !matches.isEmpty else { return }
        let index = current ?? -1
        current = older ? (index + 1) % matches.count : (index - 1 + matches.count) % matches.count
        reveal()
        render()
    }

    /// Scrolls so the current match sits a third of the way down the pane.
    private func reveal() {
        guard let host, let current, matches.indices.contains(current) else { return }
        guard let geometry = host.terminal.bufferGeometry, let row = geometry.row(forLine: matches[current].start.line) else { return }
        host.terminal.scrollTo(row: max(0, row - geometry.rows / 3))
    }

    func render() {
        guard let host else { return }
        if query.isEmpty {
            bar.setStatus("", error: false)
        } else if usesDaemon {
            if matches.isEmpty {
                bar.setStatus("No matches", error: true)
            } else {
                let more = truncated ? "+" : ""
                bar.setStatus(current.map { "\($0 + 1) of \(matches.count)\(more)" } ?? "\(matches.count)\(more) matches", error: false)
            }
        }
        highlights.update(matches: usesDaemon ? matches : [], current: current, host: host)
    }

}

/// Where things are in a terminal's buffer, from SwiftTerm's public API (1.99.1 keeps the buffer's
/// base and line array internal). Rows count from the oldest line this view holds.
struct BufferGeometry {
    /// Lines in the buffer, scrollback and screen.
    var lineCount: Int
    var rows: Int
    var cols: Int
    /// The first row shown.
    var top: Int

    /// The top screen row: the screen is always the buffer's last `rows` lines.
    var base: Int { max(0, lineCount - rows) }

    /// Where a daemon line (0 = the top screen row, negative = scrollback) is, or nil if this view doesn't
    /// hold that much history.
    func row(forLine line: Int) -> Int? {
        let row = base + line
        return row >= 0 && row < lineCount ? row : nil
    }
}

extension PaneTerminalView {
    /// SwiftTerm's Terminal behind the view (an internal property in 1.99.1, read by reflection).
    var swiftTermTerminal: Terminal? {
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror {
            for child in current.children where child.label == "terminal" {
                if let terminal = child.value as? Terminal { return terminal }
                if let optional = child.value as? Terminal?, let terminal = optional { return terminal }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    var bufferGeometry: BufferGeometry? {
        guard let terminal = swiftTermTerminal else { return nil }
        // Line count: absolute rows run from totalLinesTrimmed up; find the last valid one.
        let first = terminal.buffer.totalLinesTrimmed
        var low = first, high = first + max(1, terminal.rows)
        while terminal.getScrollInvariantLine(row: high) != nil { low = high; high = first + (high - first) * 2 }
        while high - low > 1 {
            let mid = (low + high) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { low = mid } else { high = mid }
        }
        let count = terminal.getScrollInvariantLine(row: low) == nil ? 0 : low - first + 1
        return BufferGeometry(lineCount: count, rows: terminal.rows, cols: terminal.cols, top: terminal.getTopVisibleRow())
    }
}

// MARK: Highlights

/// Draws the matches visible in the pane over the terminal, without taking clicks.
final class SearchHighlightView: NSView {
    private var rects: [(NSRect, Bool)] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(matches: [PaneSearchMatch], current: Int?, host: PaneHostView) {
        var rects: [(NSRect, Bool)] = []
        defer {
            self.rects = rects
            needsDisplay = true
        }
        guard !matches.isEmpty, let geometry = host.terminal.bufferGeometry else { return }
        let cell = host.cellSize
        let top = geometry.top, rows = geometry.rows, cols = geometry.cols
        for (index, match) in matches.enumerated() {
            guard let startRow = geometry.row(forLine: match.start.line),
                  let endRow = geometry.row(forLine: match.end.line) else { continue }
            // A match over a soft wrap is two pieces: to the end of its first line, then from the start of the next.
            for row in startRow ... endRow where row >= top && row < top + rows {
                let first = row == startRow ? match.start.col : 0
                let last = row == endRow ? match.end.col : cols - 1
                let rect = NSRect(x: CGFloat(first) * cell.width, y: CGFloat(row - top) * cell.height,
                                  width: CGFloat(last - first + 1) * cell.width, height: cell.height)
                rects.append((rect, index == current))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (rect, isCurrent) in rects {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            if isCurrent {
                Theme.warning.withAlphaComponent(0.45).setFill()
                path.fill()
            }
            Theme.warning.setStroke()
            path.lineWidth = isCurrent ? 1.5 : 1
            path.stroke()
        }
    }
}

// MARK: The bar

final class PaneFindBar: NSView {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let regexButton = NSButton(title: ".*", target: nil, action: nil)
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onOptionsChanged: (() -> Void)?

    struct Options { var caseSensitive = false; var regex = false }
    var options: Options { Options(caseSensitive: caseButton.state == .on, regex: regexButton.state == .on) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        applyColors()
        field.placeholderString = "Find"
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = Theme.dimText
        status.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        for (button, tip) in [(caseButton, "Match Case"), (regexButton, "Regular Expression")] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            button.toolTip = tip
            button.target = self
            button.action = #selector(optionsChanged)
        }
        let previous = Self.iconButton("chevron.down", tip: "Next Newer Match (⇧⌘G)", target: self, action: #selector(previousTapped))
        let next = Self.iconButton("chevron.up", tip: "Next Older Match (⌘G)", target: self, action: #selector(nextTapped))
        let close = Self.iconButton("xmark", tip: "Close (Esc)", target: self, action: #selector(closeTapped))
        let stack = NSStackView(views: [field, status, caseButton, regexButton, next, previous, close])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func iconButton(_ symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.contentTintColor = Theme.dimText
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    func setStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? Theme.danger : Theme.dimText
    }

    private func applyColors() {
        withAppearance {
            layer?.backgroundColor = Theme.raised.cgColor
            layer?.borderColor = Theme.border.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func optionsChanged() { onOptionsChanged?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func closeTapped() { onClose?() }
}

// MARK: Opening and closing

extension PaneHostView {
    /// Shows the find bar (or focuses it again), seeded with the terminal's selection if there is one.
    func showFind() {
        if search == nil {
            let controller = PaneSearchController(host: self, store: store)
            controller.onClose = { [weak self] in self?.hideFind() }
            search = controller
            showRestored(nil)
            controller.highlights.frame = terminal.frame
            addSubview(controller.highlights)
            controller.bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(controller.bar)
            NSLayoutConstraint.activate([
                controller.bar.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding + 2),
                controller.bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.padding + PaneCloseButton.size + 10)),
            ])
            if let selected = terminal.getSelection(), !selected.isEmpty, !selected.contains("\n") {
                controller.bar.field.stringValue = selected
                controller.search(now: true)
            }
        }
        search?.focusField()
    }

    func hideFind() {
        guard let controller = search else { return }
        search = nil
        controller.bar.removeFromSuperview()
        controller.highlights.removeFromSuperview()
        terminal.clearSearch()
        showRestored(dismissedRestore ? nil : restored)
        window?.makeFirstResponder(terminal)
    }

    /// Keeps the highlights over the terminal as it moves, scrolls or gets output.
    func searchLayoutChanged() {
        guard let search else { return }
        search.highlights.frame = terminal.frame
        search.render()
    }
}

extension AppDelegate {
    var focusedPaneHost: PaneHostView? {
        guard let pane = focusedPaneID else { return nil }
        return paneHosts[PaneKey(machine: focusedMachine, pane: pane)]
    }

    @objc func findInPane(_ sender: Any?) { focusedPaneHost?.showFind() }

    @objc func findNextInPane(_ sender: Any?) {
        guard let host = focusedPaneHost else { return }
        guard let search = host.search else { return host.showFind() }
        search.step(older: true)
    }

    @objc func findPreviousInPane(_ sender: Any?) {
        guard let host = focusedPaneHost else { return }
        guard let search = host.search else { return host.showFind() }
        search.step(older: false)
    }
}
