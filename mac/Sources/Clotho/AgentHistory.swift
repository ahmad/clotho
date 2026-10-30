import AppKit
import ClothoKit

// An agent's history (the Agents row's menu › History…): every state change, attention raised and
// cleared, mutes and messages the daemon recorded for the pane (`agent.history`, its last 200), newest
// at the top, with times. It stays current while open.

@MainActor
final class AgentHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var app: AppDelegate?
    let key: PaneKey
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var entries: [AgentHistoryEntry] = []
    private var loading = false

    init(app: AppDelegate, key: PaneKey, title: String) {
        self.app = app
        self.key = key
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.minSize = NSSize(width: 420, height: 240)
        panel.isFloatingPanel = false
        super.init(window: panel)
        panel.delegate = self

        for (id, name, width) in [("time", "Time", 120.0), ("what", "What", 150.0), ("message", "Message", 260.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = name
            column.width = width
            column.resizingMask = id == "message" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.usesAutomaticRowHeights = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let content = NSView()
        for view in [summary, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// Fetches what's new since the last entry (all of it the first time).
    func refresh() {
        guard !loading, let store = app?.connections[key.machine]?.store else { return }
        loading = true
        let since = entries.first?.at
        Task { @MainActor in
            defer { loading = false }
            do {
                let history = try await store.backend.agentHistory(key.pane, limit: nil, since: since)
                // `since` is inclusive of entries at that second; skip what's already listed.
                let known = Set(entries.map { "\($0.at)|\($0.eventName)|\($0.stateName ?? "")|\($0.message ?? "")" })
                let fresh = history.entries.filter { !known.contains("\($0.at)|\($0.eventName)|\($0.stateName ?? "")|\($0.message ?? "")") }
                entries = fresh.reversed() + entries
                summary.stringValue = entries.isEmpty
                    ? "Nothing recorded for this pane's agent yet."
                    : "\(entries.count) events, newest first. clothod keeps the last \(history.max) per pane."
                table.reloadData()
                log("agent history \(key.machine)/\(key.pane): \(entries.count) entries"
                    + (fresh.last.map { ", newest \(Self.describe($0).what)" } ?? ""))
            } catch {
                summary.stringValue = "Couldn't load the history: \((error as? BackendError)?.message ?? error.localizedDescription)"
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let described = Self.describe(entry)
        switch tableColumn?.identifier.rawValue {
        case "time":
            let label = NSTextField(labelWithString: Self.time(entry.date))
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            return label
        case "what":
            let icon = NSImageView(image: NSImage(systemSymbolName: described.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = described.color
            let label = NSTextField(labelWithString: described.what)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            let stack = NSStackView(views: [icon, label])
            stack.spacing = 5
            return stack
        default:
            let label = NSTextField(wrappingLabelWithString: described.detail)
            label.font = .systemFont(ofSize: 12)
            label.isSelectable = true
            return label
        }
    }

    /// Today's entries show the time; older ones the date too.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    /// How an entry reads: an icon, a few words, and the detail (its message, and what reported it).
    static func describe(_ entry: AgentHistoryEntry) -> (symbol: String, color: NSColor, what: String, detail: String) {
        let state = entry.state ?? .unknown
        var detail = entry.message ?? ""
        let origin = entry.guess == true ? "detected from output" : entry.source.map { "from \($0)" }
        if let origin { detail += detail.isEmpty ? origin.capitalizedFirst : " (\(origin))" }
        switch entry.event {
        case .state:
            let from = entry.from.map { "\($0.label) → " } ?? ""
            return (state.symbol, state.color, from + state.label, detail)
        case .attention:
            return entry.attention == true
                ? ("bell.fill", Theme.warning, "Needs you", detail)
                : ("checkmark", Theme.success, "Resolved", detail)
        case .update:
            return ("text.bubble", Theme.dimText, "Update", detail)
        case .mute:
            return ("bell.slash", Theme.dimText, "Muted", detail)
        case .unmute:
            return ("bell", Theme.dimText, "Unmuted", detail)
        case .gone:
            return ("xmark.circle", Theme.dimText, "Ended", detail)
        case .unknown:
            return ("questionmark.circle", Theme.dimText, entry.eventName, detail)
        }
    }

    func windowWillClose(_ notification: Notification) {
        app?.agentHistoryWindows[key] = nil
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension AppDelegate {
    func showAgentHistory(machine: MachineKey, pane: PaneID) {
        let key = PaneKey(machine: machine, pane: pane)
        if let open = agentHistoryWindows[key] { return open.show() }
        guard let session = connections[machine] else { return }
        let info = session.store.state.pane(pane)?.agent
        let place = session.store.state.location(of: pane).map { "\($0.workspace.name) › \(session.store.displayTitle(of: $0.tab))" }
        let title = [info?.kindName ?? "Agent", place, session.title].compactMap { $0 }.joined(separator: " · ")
        let controller = AgentHistoryWindowController(app: self, key: key, title: "\(title) — History")
        agentHistoryWindows[key] = controller
        controller.show()
    }
}
