import ClothoKit
import SwiftTerm
import SwiftUI
import UIKit

/// Find in a pane's scrollback (protocol.md "Searching scrollback"). The machine searches its own copy of the
/// pane, so the search reaches all the history it keeps; the phone scrolls to each match and outlines it.
/// Matches run newest first, as the daemon returns them, so "older" walks up the scrollback.
@MainActor
final class PaneFind: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { schedule(delay: 0.3) } } }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { schedule(delay: 0) } } }
    @Published var regex = false { didSet { if regex != oldValue { schedule(delay: 0) } } }
    @Published private(set) var matches: [PaneSearchMatch] = []
    /// Index into `matches` of the match shown, 0 being the newest.
    @Published private(set) var current: Int?
    /// More matches above the ones loaded (the daemon pages them).
    @Published private(set) var more = false
    @Published private(set) var error: String?
    @Published private(set) var searching = false
    /// The current match is older than the history this device holds, so it can't be shown in the pane.
    @Published private(set) var offScreen = false

    private let store: ModelStore
    private(set) var pane: PaneID
    private weak var host: PaneHostView?
    private var next: CellPosition?
    private var seq: UInt64?
    private var task: Task<Void, Never>?
    private let overlay = SearchHighlightView()

    init(store: ModelStore) {
        self.store = store
        pane = 0
    }

    var supported: Bool { store.hello?.features.contains(.paneSearch) == true }

    /// Follows the pane on screen; a new pane searches again.
    func attach(_ host: PaneHostView) {
        guard host !== self.host else { return }
        self.host?.onOutput = nil
        overlay.removeFromSuperview()
        self.host = host
        pane = host.paneID
        host.terminal.addSubview(overlay)
        // Lines shift as output arrives, so search again a moment after it does.
        host.onOutput = { [weak self] in self?.schedule(delay: 0.4, keepPosition: true) }
        host.onScroll = { [weak self] in self?.redraw() }
        schedule(delay: 0)
    }

    func close() {
        task?.cancel()
        host?.onOutput = nil
        host?.onScroll = nil
        overlay.removeFromSuperview()
        host = nil
        matches = []
        current = nil
    }

    var status: String {
        if !supported { return "" }
        if let error { return error }
        if query.isEmpty { return "" }
        if searching && matches.isEmpty { return "…" }
        guard let current, !matches.isEmpty else { return "No matches" }
        return "\(current + 1) of \(matches.count)\(more ? "+" : "")"
    }

    /// The match shown, as its whole line (for one beyond this device's history).
    var currentLine: String? { current.flatMap { matches.indices.contains($0) ? matches[$0].lineText : nil } }

    /// Up the scrollback.
    func older() {
        guard let current else { return }
        if current + 1 < matches.count {
            show(current + 1)
        } else if more {
            Task { await loadMore(); if current + 1 < matches.count { show(current + 1) } }
        } else if !matches.isEmpty {
            show(0)
        }
    }

    /// Down toward the screen.
    func newer() {
        guard let current else { return }
        show(current > 0 ? current - 1 : matches.count - 1)
    }

    private func schedule(delay: TimeInterval, keepPosition: Bool = false) {
        task?.cancel()
        guard host != nil else { return }
        let keep = keepPosition ? current.flatMap { matches.indices.contains($0) ? matches[$0] : nil } : nil
        task = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await search(keeping: keep)
        }
    }

    private func search(keeping kept: PaneSearchMatch?) async {
        error = nil
        let text = query
        guard !text.isEmpty, supported else {
            matches = []
            current = nil
            more = false
            redraw()
            return
        }
        searching = true
        defer { searching = false }
        do {
            let result = try await store.backend.searchPane(pane, query: text, options: options(before: nil))
            guard text == query, !Task.isCancelled else { return }
            apply(result, replacing: true)
            // After new output, stay on the same text if it's still there (its line moved up).
            if let kept, let same = matches.firstIndex(where: { $0.text == kept.text && $0.lineText == kept.lineText }) {
                show(same, scroll: false)
            } else {
                show(matches.isEmpty ? nil : 0)
            }
        } catch {
            matches = []
            current = nil
            self.error = (error as? BackendError)?.code == "bad_request" ? "Not a valid pattern" : error.localizedDescription
            redraw()
        }
    }

    private func loadMore() async {
        guard let next, let seq else { return }
        do {
            let result = try await store.backend.searchPane(pane, query: query, options: options(before: next))
            // The pane moved on since the first page: positions changed, so start over.
            guard result.seq == seq else { return schedule(delay: 0) }
            apply(result, replacing: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func options(before: CellPosition?) -> PaneSearchOptions {
        PaneSearchOptions(regex: regex, caseSensitive: caseSensitive, limit: 200, before: before)
    }

    private func apply(_ result: PaneSearchResult, replacing: Bool) {
        matches = replacing ? result.matches : matches + result.matches
        next = result.next
        more = result.next != nil
        seq = result.seq
    }

    private func show(_ index: Int?, scroll: Bool = true) {
        current = index
        offScreen = false
        if let index, scroll, let host, let geometry = host.terminal.bufferGeometry {
            if let row = geometry.row(forLine: matches[index].start.line) {
                // A third of the way down, so the lines around it show too.
                host.terminal.scrollTo(row: max(0, row - geometry.rows / 3))
            } else {
                offScreen = true
            }
        }
        redraw()
    }

    func redraw() {
        guard let host else { return }
        overlay.update(matches: matches, current: current, host: host)
    }
}

// MARK: - Where lines are

/// Where the terminal's lines are: SwiftTerm's buffer holds scrollback and screen, the screen being its last
/// `rows` lines (the same reckoning as the Mac's PaneSearch).
struct BufferGeometry: Equatable {
    var lineCount: Int
    var rows: Int
    var cols: Int

    var base: Int { max(0, lineCount - rows) }

    /// The buffer row of a daemon line (0 = the top screen row, negative = scrollback), or nil if this device
    /// doesn't hold that much history.
    func row(forLine line: Int) -> Int? {
        let row = base + line
        return row >= 0 && row < lineCount ? row : nil
    }
}

extension TerminalView {
    /// SwiftTerm's Terminal behind the view (internal in 1.99.1, so read by reflection, as on the Mac).
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
        // Rows run from totalLinesTrimmed up; find the last one there is.
        let first = terminal.buffer.totalLinesTrimmed
        var low = first, high = first + max(1, terminal.rows)
        while terminal.getScrollInvariantLine(row: high) != nil { low = high; high = first + (high - first) * 2 }
        while high - low > 1 {
            let mid = (low + high) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { low = mid } else { high = mid }
        }
        let count = terminal.getScrollInvariantLine(row: low) == nil ? 0 : low - first + 1
        return BufferGeometry(lineCount: count, rows: terminal.rows, cols: terminal.cols)
    }
}

// MARK: - Highlights

/// Outlines the matches, in the terminal's scroll view (content coordinates: row × cell height), so they move
/// with the text. Never takes touches.
final class SearchHighlightView: UIView {
    private var rects: [(CGRect, Bool)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "searchHighlights"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(matches: [PaneSearchMatch], current: Int?, host: PaneHostView) {
        guard let terminal = superview as? TerminalView, let geometry = terminal.bufferGeometry, !matches.isEmpty else {
            rects = []
            setNeedsDisplay()
            return
        }
        let cell = host.cellSize
        frame = CGRect(x: 0, y: 0, width: max(terminal.contentSize.width, terminal.bounds.width),
                       height: max(terminal.contentSize.height, CGFloat(geometry.lineCount) * cell.height))
        var found: [(CGRect, Bool)] = []
        for (index, match) in matches.enumerated() {
            guard let startRow = geometry.row(forLine: match.start.line), let endRow = geometry.row(forLine: match.end.line) else { continue }
            // Over a soft wrap: to the end of the first line, then from the start of the next.
            for row in startRow...endRow {
                let first = row == startRow ? match.start.col : 0
                let last = row == endRow ? match.end.col : geometry.cols - 1
                found.append((CGRect(x: CGFloat(first) * cell.width, y: CGFloat(row) * cell.height,
                                     width: CGFloat(last - first + 1) * cell.width, height: cell.height), index == current))
            }
        }
        rects = found
        terminal.bringSubviewToFront(self)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        for (box, isCurrent) in rects where box.intersects(rect) {
            let path = UIBezierPath(roundedRect: box.insetBy(dx: -0.5, dy: 0.5), cornerRadius: 2)
            if isCurrent {
                UIColor.systemOrange.withAlphaComponent(0.4).setFill()
                path.fill()
            }
            UIColor.systemOrange.setStroke()
            path.lineWidth = isCurrent ? 1.5 : 1
            path.stroke()
        }
    }
}

// MARK: - The bar

/// Above the pane while finding: the query, match count, older and newer, case and regex, Done.
struct FindBar: View {
    @ObservedObject var find: PaneFind
    let machine: String
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in pane", text: $find.query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { find.older(); focused = true }
                        .accessibilityIdentifier("findField")
                    Text(find.status)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(find.error == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .accessibilityIdentifier("findStatus")
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                toggle("Aa", on: $find.caseSensitive, label: "Match Case")
                toggle(".*", on: $find.regex, label: "Regular Expression")
                Button { find.older() } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Older Match")
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(find.matches.isEmpty)
                Button { find.newer() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Newer Match")
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(find.matches.isEmpty)
                Button("Done", action: close)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            if !find.supported {
                Text("Update clothod on \(machine) to search its scrollback.").font(.caption).foregroundStyle(.secondary)
            } else if find.offScreen, let line = find.currentLine {
                // Older than the history this device keeps: show the line instead.
                Text(line).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("findOffScreenLine")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true }
    }

    private func toggle(_ title: String, on: Binding<Bool>, label: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(title).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(on.wrappedValue ? Color.selection.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }
}
