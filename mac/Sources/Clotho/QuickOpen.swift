import AppKit
import ClothoKit

// ⌘P, the command bar: a floating panel over the window, Spotlight-like. With nothing typed it lists the
// current workspace's tabs with the current one selected; ↑/↓ (or Tab/⇧Tab) switch to each as a live
// preview, Return keeps it and Esc goes back. Typing searches every connected machine's workspaces, tabs
// and agents, from the models already in memory: agents waiting for you first, then the current workspace,
// then the rest. Return goes there, ⌘1–9 pick a row, and ⌘P again closes it. Matching is ClothoKit's
// FuzzyMatch, as on iOS.

/// One row of the command bar.
struct CommandBarEntry {
    /// What's matched (title, then subtitle) and its id.
    var item: QuickOpenItem
    /// The ranking group while searching: 0 an agent waiting for you, 1 the current workspace, 2 the rest.
    var tier: Int
    /// The agent dot (the tab's or workspace's most urgent agent).
    var dot: NSColor?
    /// The agent's state, such as "waiting: Allow Bash?".
    var detail: String?
    /// Panes in the tab, shown when more than one.
    var panes = 1
}

enum CommandBar {
    /// Rows shown at most.
    static let limit = 12

    /// What the bar lists for `query`: with nothing typed, the current workspace's tabs in order; otherwise
    /// every match, by tier (waiting agents, the current workspace, the rest), best match first within
    /// each. Returns each entry with the matched positions in its title.
    static func results(all: [CommandBarEntry], current: [CommandBarEntry], query: String) -> [(entry: CommandBarEntry, indices: [Int])] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return current.prefix(limit).map { ($0, []) } }
        var byID: [String: CommandBarEntry] = [:]
        for entry in all { byID[entry.item.id] = entry }
        let ranked = QuickOpen.rank(all.map(\.item), query: query, limit: all.count)
        let matched = ranked.enumerated().compactMap { order, result in
            byID[result.item.id].map { (entry: $0, indices: result.titleIndices, order: order) }
        }
        // A stable sort by tier keeps the match order within each.
        let sorted = matched.sorted { $0.entry.tier != $1.entry.tier ? $0.entry.tier < $1.entry.tier : $0.order < $1.order }
        return sorted.prefix(limit).map { ($0.entry, $0.indices) }
    }
}

extension AppDelegate {
    /// ⌘P: opens the command bar, or closes it (as Esc does) when it's open.
    @objc func showQuickOpen(_ sender: Any?) {
        if let quickOpen {
            quickOpen.cancel()
            return
        }
        let model = commandBarModel()
        let overlay = QuickOpenOverlay(all: model.all, current: model.current, selected: model.selected)
        let original = model.selected.flatMap { model.current.indices.contains($0) ? model.current[$0].item.id : nil }
        overlay.onPreview = { entry in
            log("command bar: preview \(entry.item.title)")
            model.actions[entry.item.id]?()
        }
        overlay.onRestore = {
            guard let original else { return }
            model.actions[original]?()
        }
        overlay.onOpen = { [weak self] entry in
            log("command bar: \(entry.item.kind) \(entry.item.title)")
            model.actions[entry.item.id]?()
            self?.quickOpen?.dismiss()
        }
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            quickOpen = nil
            window.makeFirstResponder(activeTerminal)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        quickOpen = overlay
        overlay.focusField()
    }

    /// Everything the command bar can go to, the current workspace's tabs, the current tab's index among
    /// them, and what going to each does (the instant local focus).
    func commandBarModel() -> (all: [CommandBarEntry], current: [CommandBarEntry], selected: Int?, actions: [String: () -> Void]) {
        var all: [CommandBarEntry] = []
        var current: [CommandBarEntry] = []
        var actions: [String: () -> Void] = [:]
        let focusedStore = connections[focusedMachine]?.store
        let currentWorkspace = focusedStore?.focusedWorkspace?.id
        let currentTab = focusedStore?.focusedTab?.id

        // Agents: the waiting ones lead any search.
        for entry in AgentEntry.sorted(agentEntries()) {
            let title = "\(entry.info.kindName): \(entry.paneTitle ?? entry.tabTitle ?? "agent")"
            let place = [entry.workspace?.name, entry.tabTitle].compactMap { $0 }.joined(separator: " › ")
            let id = "agent|\(entry.machine)|\(entry.pane)"
            let here = entry.machine == focusedMachine && entry.workspace?.id == currentWorkspace
            all.append(CommandBarEntry(item: QuickOpenItem(kind: .agent, title: title, subtitle: "\(entry.machineName) · \(place)", id: id),
                                       tier: entry.info.needsAttention ? 0 : here ? 1 : 2,
                                       dot: entry.info.badgeColor, detail: Self.agentDetail(entry.info)))
            actions[id] = { [weak self] in self?.openAgent(machine: entry.machine, pane: entry.pane) }
        }

        // Workspaces and tabs: the focused machine first, then the others in sidebar order.
        let keys = [focusedMachine] + ([Self.localKey] + remoteMachines.map(\.key)).filter { $0 != focusedMachine }
        for key in keys {
            guard let session = connections[key] else { continue }
            let store = session.store
            let state = store.state
            for workspace in state.workspaces {
                let here = key == focusedMachine && workspace.id == currentWorkspace
                let workspaceID = "ws|\(key)|\(workspace.id)"
                all.append(CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: workspace.name, subtitle: session.title, id: workspaceID),
                                           tier: here ? 1 : 2,
                                           dot: agentBadge(machine: key, panes: workspace.tabs.flatMap(\.layout.panes))))
                actions[workspaceID] = { [weak self] in self?.focusNow(.workspace(workspace.id), on: key, trace: "command bar") }
                for tab in workspace.tabs {
                    let id = "tab|\(key)|\(tab.id)"
                    let panes = tab.layout.panes
                    let agent = Self.mostUrgent(panes.compactMap { state.pane($0)?.agent })
                    let entry = CommandBarEntry(item: QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab),
                                                                    subtitle: "\(session.title) · \(workspace.name)", id: id),
                                                tier: here ? 1 : 2, dot: agentBadge(machine: key, panes: panes),
                                                detail: agent.map(Self.agentDetail), panes: panes.count)
                    all.append(entry)
                    if here { current.append(entry) }
                    actions[id] = { [weak self] in self?.focusNow(.tab(tab.id), on: key, trace: "command bar") }
                }
            }
        }

        // Machines last: connect to one, or show it.
        for machine in [Machine.local] + remoteMachines {
            let connected = connections[machine.key] != nil
            let name = machine.isLocal ? ComputerName.current : machine.label
            let id = "machine|\(machine.key)"
            all.append(CommandBarEntry(item: QuickOpenItem(kind: .machine, title: name, subtitle: connected ? "Connected" : "Connect", id: id),
                                       tier: 2))
            actions[id] = { [weak self] in
                guard let self else { return }
                if connections[machine.key] != nil { focus(machine: machine.key) } else { connect(machine, show: true) }
            }
        }
        let selected = currentTab.flatMap { tab in current.firstIndex { $0.item.id == "tab|\(focusedMachine)|\(tab)" } }
        return (all, current, selected, actions)
    }

    /// "waiting: Allow Bash?", "running", "done: Tests pass".
    static func agentDetail(_ info: AgentInfo) -> String {
        let state = info.shownState.label.lowercased()
        guard let what = info.prompt ?? info.message, !what.isEmpty else { return state }
        return "\(state): \(what)"
    }

    /// The agent that most needs the user (waiting, then error), else the first.
    static func mostUrgent(_ agents: [AgentInfo]) -> AgentInfo? {
        func rank(_ info: AgentInfo) -> Int { !info.needsAttention ? 3 : info.state == .waiting ? 0 : info.state == .error ? 1 : 2 }
        return agents.min { rank($0) < rank($1) }
    }
}

/// The command bar's panel, floating over the window.
final class QuickOpenOverlay: NSView, NSTextFieldDelegate {
    var onOpen: ((CommandBarEntry) -> Void)?
    /// The selection moved with nothing typed: switch to that tab as a preview.
    var onPreview: ((CommandBarEntry) -> Void)?
    /// Esc (or ⌘P) after a preview: back to the tab that was current.
    var onRestore: (() -> Void)?
    var onDismiss: (() -> Void)?
    let card = NSView()
    private let field = NSTextField()
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No matches")
    private let all: [CommandBarEntry]
    private let current: [CommandBarEntry]
    private let initial: Int?
    private(set) var results: [(entry: CommandBarEntry, indices: [Int])] = []
    private(set) var selected = 0
    /// A preview moved away from the current tab.
    private var previewed = false

    init(all: [CommandBarEntry], current: [CommandBarEntry], selected: Int?) {
        self.all = all
        self.current = current
        initial = selected
        super.init(frame: .zero)

        field.placeholderString = "Search workspaces, tabs and agents"
        field.font = .systemFont(ofSize: s(16))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.foreground
        field.delegate = self
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.dimText
        let top = NSStackView(views: [icon, field])
        top.orientation = .horizontal
        top.spacing = s(10)
        top.edgeInsets = NSEdgeInsets(top: s(14), left: s(16), bottom: s(12), right: s(16))
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.divider
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: s(6), left: s(6), bottom: s(6), right: s(6))
        empty.textColor = Theme.dimText
        empty.font = .systemFont(ofSize: s(13))

        let stack = NSStackView(views: [top, rule, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for view in [top, rule, list] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.background.cgColor
        card.layer?.cornerRadius = s(12)
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.divider.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 24
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: s(90)),
            card.widthAnchor.constraint(equalToConstant: s(600)),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusField() { window?.makeFirstResponder(field) }

    /// Closes it, leaving whatever it switched to.
    func dismiss() {
        removeFromSuperview()
        onDismiss?()
    }

    /// Esc or ⌘P: back to the tab that was current, and close.
    func cancel() {
        if previewed { onRestore?() }
        dismiss()
    }

    /// Testing aid and typing: sets the query and ranks again.
    func setQuery(_ text: String) {
        field.stringValue = text
        update()
    }

    var query: String { field.stringValue }
    /// The search field (tests and TypeText).
    var fieldForTesting: NSTextField { field }

    func controlTextDidChange(_ obj: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)), #selector(insertTab(_:)): move(1)
        case #selector(moveUp(_:)), #selector(insertBacktab(_:)): move(-1)
        case #selector(insertNewline(_:)): open()
        case #selector(cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    /// ⌘1–9 pick a row; ⌘P closes (it would otherwise reach the menu, which does the same).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        if key == "p" {
            cancel()
            return true
        }
        if let digit = Int(key), (1...9).contains(digit) {
            pick(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func open() {
        guard results.indices.contains(selected) else { return }
        onOpen?(results[selected].entry)
    }

    /// Opens row `index` (⌘1 is the first).
    func pick(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
        open()
    }

    private func move(_ by: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + by + results.count) % results.count
        render()
        // With nothing typed the rows are the current workspace's tabs: show each as it's selected.
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            previewed = selected != initial || previewed
            onPreview?(results[selected].entry)
        }
    }

    private func update() {
        results = CommandBar.results(all: all, current: current, query: query)
        let browsing = query.trimmingCharacters(in: .whitespaces).isEmpty
        selected = browsing ? min(initial ?? 0, max(0, results.count - 1)) : 0
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if results.isEmpty {
            empty.stringValue = query.isEmpty ? "No tabs in this workspace" : "No matches"
            list.addArrangedSubview(empty)
            return
        }
        for (index, result) in results.enumerated() {
            let row = QuickOpenRow(entry: result.entry, indices: result.indices, selected: index == selected,
                                   shortcut: index < 9 ? index + 1 : nil) { [weak self] in
                self?.pick(index)
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -s(12)).isActive = true
        }
    }

    // A click outside the panel closes it; nothing reaches the terminal behind.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { cancel() }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// One row: the agent dot (or the kind's icon), the title with the matched letters in the accent colour,
/// the agent's state and the pane count, where it is, and its ⌘ number.
final class QuickOpenRow: NSView {
    private let action: () -> Void

    init(entry: CommandBarEntry, indices: [Int], selected: Bool, shortcut: Int?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = s(6)
        layer?.backgroundColor = selected ? Theme.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor

        let lead: NSView
        if let dot = entry.dot {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = dot.cgColor
            view.layer?.cornerRadius = s(3.5)
            let holder = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: s(7)),
                view.heightAnchor.constraint(equalToConstant: s(7)),
            ])
            lead = holder
        } else {
            let symbol = switch entry.item.kind {
            case .agent: "sparkles"
            case .workspace: "square.stack"
            case .tab: "rectangle.topthird.inset.filled"
            case .machine: "server.rack"
            }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = Theme.dimText
            lead = icon
        }
        lead.widthAnchor.constraint(equalToConstant: s(18)).isActive = true

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = Self.highlighted(entry.item.title, indices)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [lead, title]
        if let detail = entry.detail {
            views.append(Self.dim(detail, compression: .defaultLow - 2))
        }
        if entry.panes > 1 {
            let panes = Self.dim("\(entry.panes) panes", compression: .required)
            views.append(panes)
        }
        views.append(NSView())
        views.append(Self.dim(entry.item.subtitle, compression: .defaultLow - 1, head: true))
        if let shortcut {
            let key = Self.dim("⌘\(shortcut)", compression: .required)
            key.font = .monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
            views.append(key)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = s(8)
        row.edgeInsets = NSEdgeInsets(top: s(7), left: s(10), bottom: s(7), right: s(10))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func dim(_ text: String, compression: NSLayoutConstraint.Priority, head: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: s(12))
        label.textColor = Theme.dimText
        label.lineBreakMode = head ? .byTruncatingHead : .byTruncatingTail
        label.setContentCompressionResistancePriority(compression, for: .horizontal)
        return label
    }

    static func highlighted(_ text: String, _ indices: [Int]) -> NSAttributedString {
        let marked = Set(indices)
        let result = NSMutableAttributedString()
        for (offset, character) in text.enumerated() {
            let hit = marked.contains(offset)
            result.append(NSAttributedString(string: String(character), attributes: [
                .font: NSFont.systemFont(ofSize: s(14), weight: hit ? .semibold : .regular),
                .foregroundColor: hit ? Theme.accent : Theme.foreground,
            ]))
        }
        return result
    }

    override func mouseDown(with event: NSEvent) { action() }
}
