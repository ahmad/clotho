import AppKit
import ClothoKit

// The inspector's Activity view: the history of the focused pane's agent (`agent.history`: its state
// changes, when it needed the user, its messages), newest first, in rows narrow enough for the
// inspector: what happened and when on one line, the message wrapping under it. It reads the same
// entries as the agent's History… window, which stays as it is.

@MainActor
final class ActivityView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var app: AppDelegate?
    let table = NSTableView()
    let scroll = NSScrollView()
    let message = ChangesMessageView()
    private(set) var entries: [AgentHistoryEntry] = []
    /// The pane shown, and whether it has an agent.
    private(set) var target: (key: PaneKey, hasAgent: Bool, canList: Bool)?
    private var loading = false
    private var again = false
    private var epoch = 0
    /// Only fetches while it shows.
    var isVisible = false {
        didSet { if isVisible, !oldValue { refresh() } }
    }

    static let noAgentWords = "No agent in this pane"
    static let noHistoryWords = "No history yet"

    init(app: AppDelegate?) {
        self.app = app
        super.init(frame: .zero)
        setAccessibilityLabel("Activity")
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Agent activity")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        for view in [scroll, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        show()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The focused pane now (every sync; cheap when nothing moved).
    func follow(machine: MachineKey, pane: PaneID?, hasAgent: Bool, canList: Bool) {
        let new = pane.map { (key: PaneKey(machine: machine, pane: $0), hasAgent: hasAgent, canList: canList) }
        let moved = new?.key != target?.key
        let changed = moved || new?.hasAgent != target?.hasAgent || new?.canList != target?.canList
        target = new
        guard changed else { return }
        if moved {
            epoch += 1
            entries = []
        }
        show()
        refresh()
    }

    /// The pane's agent did something: the list is read again.
    func agentChanged(machine: MachineKey, pane: PaneID) {
        guard target?.key == PaneKey(machine: machine, pane: pane) else { return }
        refresh()
    }

    func refresh() {
        guard isVisible, let target, target.canList, target.hasAgent || !entries.isEmpty,
              let backend = app?.connections[target.key.machine]?.store.backend else { return }
        guard !loading else { return again = true }
        loading = true
        let asked = epoch
        Task { @MainActor [weak self] in
            let result: Result<AgentHistory, Error>
            do { result = .success(try await backend.agentHistory(target.key.pane, limit: nil, since: nil)) } catch { result = .failure(error) }
            guard let self else { return }
            loading = false
            if asked == epoch {
                switch result {
                case let .success(history):
                    entries = history.entries.reversed()
                    failure = nil
                case let .failure(error):
                    failure = "Couldn't load the activity: \(PlainText.oneLine((error as? BackendError)?.message ?? error.localizedDescription))"
                }
                show()
            }
            if again || asked != epoch {
                again = false
                refresh()
            }
        }
    }

    private var failure: String?

    /// The words in place of the list. Nil: there are entries.
    var words: String? {
        guard let target else { return "No pane is focused." }
        if !target.canList { return "Activity needs a newer clothod on this machine." }
        if !entries.isEmpty { return nil }
        if let failure { return failure }
        return target.hasAgent ? Self.noHistoryWords : Self.noAgentWords
    }

    private func show() {
        if let words {
            scroll.isHidden = true
            message.show(words, busy: false)
        } else {
            message.isHidden = true
            scroll.isHidden = false
        }
        table.reloadData()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        Self.cell(for: entries[row])
    }

    /// One entry: its symbol and what happened, the time at the trailing edge, the detail under them.
    static func cell(for entry: AgentHistoryEntry) -> NSView {
        let described = AgentHistoryWindowController.describe(entry)
        let icon = NSImageView(image: NSImage(systemSymbolName: described.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s(10), weight: .medium)) ?? NSImage())
        icon.contentTintColor = described.color
        let what = NSTextField(labelWithString: described.what)
        what.font = .systemFont(ofSize: s(11.5), weight: .medium)
        what.textColor = Theme.foreground
        what.lineBreakMode = .byTruncatingTail
        what.toolTip = described.what
        what.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let time = NSTextField(labelWithString: AgentHistoryWindowController.time(entry.date))
        time.font = .monospacedDigitSystemFont(ofSize: s(10.5), weight: .regular)
        time.textColor = Theme.dimText
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detail = NSTextField(wrappingLabelWithString: described.detail)
        detail.font = .systemFont(ofSize: s(11))
        detail.textColor = Theme.secondaryText
        detail.isSelectable = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.isHidden = described.detail.isEmpty
        let cell = NSView()
        for view in [icon, what, time, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: s(10)),
            icon.widthAnchor.constraint(equalToConstant: s(14)),
            icon.centerYAnchor.constraint(equalTo: what.centerYAnchor),
            what.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: s(6)),
            what.topAnchor.constraint(equalTo: cell.topAnchor, constant: s(6)),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: what.trailingAnchor, constant: s(6)),
            time.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -s(10)),
            time.firstBaselineAnchor.constraint(equalTo: what.firstBaselineAnchor),
            detail.leadingAnchor.constraint(equalTo: what.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -s(10)),
        ])
        if described.detail.isEmpty {
            cell.bottomAnchor.constraint(equalTo: what.bottomAnchor, constant: s(6)).isActive = true
        } else {
            NSLayoutConstraint.activate([
                detail.topAnchor.constraint(equalTo: what.bottomAnchor, constant: s(2)),
                cell.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: s(6)),
            ])
        }
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel([described.what, AgentHistoryWindowController.time(entry.date), described.detail]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }
}
