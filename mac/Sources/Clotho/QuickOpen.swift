import AppKit
import ClothoKit

// ⌘P, the command bar: a floating panel over the window, Spotlight-like.
//
// With nothing typed it's a tree (ClothoKit's CommandTree): "Needs you" on top (agents waiting or in
// error on any machine), then this machine's workspaces, the current one open to its tabs. → expands,
// ← collapses and from a workspace goes up to the machine list; ↑/↓ preview tabs live (other rows only
// highlight); Return opens a tab, a workspace at its last active tab, or an agent's pane, and expands a
// machine. Esc goes back to where you were.
//
// Typing searches every connected machine's workspaces, tabs and agents, flat, from the models in memory:
// by how well the name matches, workspaces first among matches as good (see `CommandBar.band`), each with
// a dim "machine › workspace" path. Clearing the text returns to the tree as it was; Tab leaves the search
// at the selected row (expanded), ⇧Tab at its parent. Row keys: ⌘⌫ closes the selected tab or workspace
// (asking first), ⌥↩ opens a new tab there, ⌘1–9 pick a row, ⌘P closes. Only the rows in view are drawn,
// so it stays instant with many machines. Matching is ClothoKit's FuzzyMatch, as on iOS.

/// One row of the command bar.
struct CommandBarEntry {
    /// What's matched (title, then subtitle) and its id.
    var item: QuickOpenItem
    /// Breaks ties while searching, after match quality and kind: 0 an agent waiting for you, 1 the
    /// current workspace, 2 the rest.
    var tier: Int
    /// The agent dot (the tab's or workspace's most urgent agent).
    var dot: NSColor?
    /// The agent's state, such as "waiting: Allow Bash?".
    var detail: String?
    /// Panes in the tab, shown when more than one.
    var panes = 1
    /// Where it is, shown dim: "machine › workspace" (nil shows the subtitle).
    var path: String? = nil
    /// An icon in place of the kind's (commands).
    var symbol: String? = nil
}

extension CommandTree.Node {
    /// The command bar entry id for this node ("tab|machine|id" and so on).
    var entryID: String {
        switch self {
        case let .agent(machine, pane): return "agent|\(machine)|\(pane)"
        case let .machine(machine): return "machine|\(machine)"
        case let .workspace(machine, id): return "ws|\(machine)|\(id)"
        case let .tab(machine, id): return "tab|\(machine)|\(id)"
        }
    }

    init?(entryID: String) {
        let parts = entryID.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("machine", 2): self = .machine(parts[1])
        case ("agent", 3): guard let id = PaneID(parts[2]) else { return nil }; self = .agent(machine: parts[1], pane: id)
        case ("ws", 3): guard let id = WorkspaceID(parts[2]) else { return nil }; self = .workspace(machine: parts[1], id)
        case ("tab", 3): guard let id = TabID(parts[2]) else { return nil }; self = .tab(machine: parts[1], id)
        default: return nil
        }
    }
}

/// What the command bar shows: every entry (for search and for drawing tree rows), the tree's outline,
/// and what going to each entry does (the instant local focus).
struct CommandBarModel {
    var all: [CommandBarEntry]
    var outline: CommandTree.Outline
    var machine: MachineKey
    var workspace: WorkspaceID?
    var tab: TabID?
    var actions: [String: () -> Void]
}

enum CommandBar {
    /// Rows shown at most.
    static let limit = 12

    /// What the bar lists for `query`: with nothing typed, the current workspace's tabs in order. Otherwise
    /// every match, by how well its name matches (`band`); among matches as good, workspaces first, then by
    /// tier (waiting agents, the current workspace, the rest), then by FuzzyMatch's score. So a workspace
    /// whose name starts with the query leads every tab that only contains it. Returns each entry with the
    /// matched positions in its title.
    static func results(all: [CommandBarEntry], current: [CommandBarEntry], query: String) -> [(entry: CommandBarEntry, indices: [Int])] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return current.prefix(limit).map { ($0, []) } }
        var byID: [String: CommandBarEntry] = [:]
        for entry in all { byID[entry.item.id] = entry }
        let ranked = QuickOpen.rank(all.map(\.item), query: query, limit: all.count)
        let letters = query.filter { !$0.isWhitespace }.count
        let matched = ranked.enumerated().compactMap { order, result in
            byID[result.item.id].map { entry in
                (entry: entry, indices: result.titleIndices, order: order,
                 key: [band(title: entry.item.title, query: query, inTitle: result.titleIndices.count == letters),
                       entry.item.kind == .workspace ? 0 : 1, entry.tier])
            }
        }
        // A stable sort keeps FuzzyMatch's order among equals.
        let sorted = matched.sorted { $0.key != $1.key ? $0.key.lexicographicallyPrecedes($1.key) : $0.order < $1.order }
        return sorted.prefix(limit).map { ($0.entry, $0.indices) }
    }

    /// How well `query` matches a row's title, best first: 0 the title starts with it ("api" for "api" or
    /// "api-tests"), 1 a word in it does ("deploy api"), 2 its letters are in the title in order ("a-p-i"),
    /// 3 only with the subtitle's help ("bb api" for devbox's api). Case doesn't matter.
    static func band(title: String, query: String, inTitle: Bool) -> Int {
        let text = Array(title.lowercased())
        let needle = Array(query.lowercased())
        guard !needle.isEmpty, needle.count <= text.count else { return inTitle ? 2 : 3 }
        if Array(text.prefix(needle.count)) == needle { return 0 }
        let original = Array(title)
        let separators: Set<Character> = [" ", "-", "_", "/", ".", ":", "@", "(", "[", "›", "·"]
        for start in stride(from: 1, through: text.count - needle.count, by: 1) where Array(text[start..<start + needle.count]) == needle {
            // A word starts after a separator or at a lower-to-upper case change, as in FuzzyMatch.
            let atWord = separators.contains(text[start - 1])
                || (text.count == original.count && original[start - 1].isLowercase && original[start].isUppercase)
            if atWord { return 1 }
        }
        return inTitle ? 2 : 3
    }
}

extension AppDelegate {
    /// ⌘P: opens the command bar, or closes it (as Esc does) when it's open.
    @objc func showQuickOpen(_ sender: Any?) {
        if let quickOpen {
            quickOpen.cancel()
            return
        }
        var model = commandBarModel()
        let tree = CommandTree(outline: model.outline, machine: model.machine, workspace: model.workspace, tab: model.tab)
        let overlay = QuickOpenOverlay(all: model.all, tree: tree)
        let original = tree.selection?.entryID
        let originalAction = original.flatMap { model.actions[$0] }
        overlay.onPreview = { entry in
            log("command bar: preview \(entry.item.title)")
            model.actions[entry.item.id]?()
        }
        overlay.onRestore = { originalAction?() }
        overlay.onOpen = { [weak self] entry in
            log("command bar: \(entry.item.kind) \(entry.item.title)")
            model.actions[entry.item.id]?()
            self?.quickOpen?.dismiss()
        }
        overlay.onClose = { [weak self] entry in self?.commandBarClose(entry) }
        // "Beside the current pane" means the one focused when ⌘P opened, not a tab it previewed since.
        let origin = (machine: focusedMachine, pane: store.focusedPane?.id, tab: store.focusedTab?.id)
        overlay.commandContext = { [weak self] node in self?.commandBarContext(node, origin: origin) ?? CommandContext() }
        overlay.onCommand = { [weak self] item, subject, target in
            originalAction?()
            self?.quickOpen?.dismiss()
            self?.commandBarRun(item, subject: subject, target: target, origin: origin)
        }
        overlay.onOpenBeside = { [weak self] entry in
            guard let self, let node = CommandTree.Node(entryID: entry.item.id),
                  commandBarContext(node, origin: origin).canOpenBeside else { return NSSound.beep() }
            originalAction?()
            quickOpen?.dismiss()
            commandBarRun(CommandListItem(id: .openBeside, title: "", keywords: []), subject: node, target: nil, origin: origin)
        }
        overlay.onNewTab = { [weak self] entry in
            self?.commandBarNewTab(entry)
            self?.quickOpen?.dismiss()
        }
        overlay.reload = { [weak self] in
            guard let self else { return nil }
            model = commandBarModel()
            return (model.all, model.outline)
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

    /// The selected row's machine, workspace and tab, for the ">" commands.
    func commandBarContext(_ node: CommandTree.Node?, origin: (machine: MachineKey, pane: PaneID?, tab: TabID?)) -> CommandContext {
        let key = node?.machine ?? focusedMachine
        let machine = ([Machine.local] + Machine.all().filter { !$0.isLocal }).first { $0.key == key }
        let session = connections[key]
        let state = session?.store.state
        var context = CommandContext(machine: key, machineName: machine.map { $0.isLocal ? ComputerName.current : $0.label },
                                     connected: session?.store.isConnected == true, enabled: machine?.isEnabled ?? true,
                                     isLocal: key == Self.localKey,
                                     unreachable: session?.store.retryPaused == true || machine?.id.flatMap { machineStatus[$0] }.map { if case .unreachable = $0 { true } else { false } } == true)
        let (workspace, tab) = commandBarPlace(node)
        if let workspace, let found = state?.workspaces.first(where: { $0.id == workspace }) {
            context.workspace = workspace
            context.workspaceName = found.name
            if let tab, let found = found.tabs.first(where: { $0.id == tab }), let store = session?.store {
                context.tab = tab
                context.tabName = store.displayTitle(of: found)
                context.canOpenBeside = key == origin.machine && origin.pane != nil && tab != origin.tab
                    && store.hello?.features.contains(.paneMove) == true
            }
        }
        return context
    }

    /// A row's workspace and tab: a tab's own, an agent's, a workspace's (no tab); a machine's focused
    /// workspace.
    func commandBarPlace(_ node: CommandTree.Node?) -> (workspace: WorkspaceID?, tab: TabID?) {
        guard let node, let store = connections[node.machine]?.store else { return (nil, nil) }
        switch node {
        case let .tab(_, id): return (store.state.workspaces.first { $0.tabs.contains { $0.id == id } }?.id, id)
        case let .workspace(_, id): return (id, nil)
        case let .agent(_, pane):
            let workspace = store.state.workspaces.first { $0.tabs.contains { $0.layout.panes.contains(pane) } }
            return (workspace?.id, workspace?.tabs.first { $0.layout.panes.contains(pane) }?.id)
        case .machine: return (store.focusedWorkspace?.id, nil)
        }
    }

    /// Runs a ">" command (or ⌘↩) for the selected row; `target` is the workspace picked for Move Tab.
    func commandBarRun(_ item: CommandListItem, subject: CommandTree.Node?, target: CommandTree.Node?,
                       origin: (machine: MachineKey, pane: PaneID?, tab: TabID?)) {
        let key = subject?.machine ?? focusedMachine
        let store = connections[key]?.store
        let (workspace, tab) = commandBarPlace(subject)
        let machine = Machine.all().first { $0.key == key }
        log("command bar: run \(item.id.rawValue) on \(subject.map { "\($0)" } ?? "nothing")")
        switch item.id {
        case .newTab:
            if let workspace { newTab(in: workspace, on: key) } else { newWorkspace(on: key) }
        case .newWorkspace:
            newWorkspace(on: key)
        case .closeTab:
            if let tab { closeTab(tab, on: key) }
        case .closeWorkspace:
            if let workspace { closeWorkspace(workspace, on: key) }
        case .splitRight, .splitDown:
            guard let tab else { return }
            focusNow(.tab(tab), on: key, trace: "command bar")
            if let pane = self.store.focusedPane { split(pane, item.id == .splitRight ? .right : .down) }
        case .claudeHere, .codexHere, .resumeClaude:
            guard let workspace, let store else { return }
            let command = item.id == .claudeHere ? "claude" : item.id == .codexHere ? "codex" : "claude --continue"
            agentTab(command, in: workspace, tab: tab, on: key, store: store)
        case .rename:
            if let tab {
                focusNow(.tab(tab), on: key, trace: "command bar")
                DispatchQueue.main.async { self.renameTab(withID: tab) }
            } else if let workspace {
                focusNow(.workspace(workspace), on: key, trace: "command bar")
                DispatchQueue.main.async { self.renameWorkspace(workspace) }
            }
        case .moveTab:
            // Tabs move within one machine: each daemon only knows its own.
            guard let tab, case let .workspace(targetKey, destination)? = target else { return }
            guard targetKey == key, let store else {
                log("command bar: a tab can't move to another machine")
                return NSSound.beep()
            }
            let index = store.state.workspaces.first { $0.id == destination }?.tabs.count ?? 0
            move(.tab(tab, workspace: destination, index: index, focus: false), on: key)
        case .openBeside:
            guard let tab, let store, key == origin.machine, let pane = origin.pane else { return NSSound.beep() }
            Task { @MainActor in
                do {
                    try await store.move(.tabJoin(tab, beside: pane, direction: .right, ratio: nil, focus: true))
                } catch {
                    log("command bar: open beside failed: \(error)")
                    NSSound.beep()
                }
            }
        case .files: showFileBrowser(nil)
        case .settings: showSettings(nil)
        case .machines: showMachineManager(nil)
        case .toggleSidebar: showOrHideSidebar(nil)
        case .appearanceSystem: setAppearance(.system)
        case .appearanceLight: setAppearance(.light)
        case .appearanceDark: setAppearance(.dark)
        case .machineOn, .machineOff:
            if let machine { setMachineEnabled(machine, item.id == .machineOn) }
        case .reconnect:
            reconnect(key)
        }
    }

    /// Claude Here, Codex Here, Resume Last Claude: a new tab in the row's workspace, in its folder (the
    /// selected tab's, else the workspace's last active tab's), with a shell that starts the agent.
    func agentTab(_ command: String, in workspace: WorkspaceID, tab: TabID?, on key: MachineKey, store: ModelStore) {
        let shown = store.state.workspaces.first { $0.id == workspace }
        let source = shown?.tabs.first { $0.id == tab } ?? shown?.tabs.first { $0.id == shown?.activeTab } ?? shown?.tabs.first
        let cwd = source.flatMap { store.state.pane($0.activePane)?.cwd }
        let options = spawnOptions(cwd: cwd)
        let backend = store.backend
        Task { @MainActor in
            do {
                let created = try await backend.createTab(in: workspace, spawn: options)
                backend.sendInput(created.pane, Data((command + "\r").utf8))
            } catch {
                log("command bar: \(command) in workspace \(workspace) on \(key) failed: \(error)")
            }
        }
    }

    /// ⌘⌫ on a row: closes that tab or workspace, asking first as the menu does.
    func commandBarClose(_ entry: CommandBarEntry) {
        switch CommandTree.Node(entryID: entry.item.id) {
        case let .tab(machine, id): closeTab(id, on: machine)
        case let .workspace(machine, id): closeWorkspace(id, on: machine)
        default: NSSound.beep()
        }
    }

    /// ⌥↩ on a row: a new tab in that workspace (a tab's or an agent's workspace; a machine's current one,
    /// or a new workspace when it has none).
    func commandBarNewTab(_ entry: CommandBarEntry) {
        guard let node = CommandTree.Node(entryID: entry.item.id) else { return }
        let key = node.machine
        guard let store = connections[key]?.store else { return NSSound.beep() }
        let workspace: WorkspaceID? = switch node {
        case let .workspace(_, id): id
        case let .tab(_, id): store.state.workspaces.first { $0.tabs.contains { $0.id == id } }?.id
        case let .agent(_, pane): store.state.workspaces.first { $0.tabs.contains { $0.layout.panes.contains(pane) } }?.id
        case .machine: store.focusedWorkspace?.id
        }
        log("command bar: new tab in \(entry.item.title)")
        if let workspace { newTab(in: workspace, on: key) } else { newWorkspace(on: key) }
    }

    /// Closes a tab on any machine, asking first (see confirmClose).
    func closeTab(_ id: TabID, on key: MachineKey) {
        guard let backend = connections[key]?.store.backend else { return }
        confirmClose("Tab", info: "This closes all of its panes and stops anything running in them.") {
            Task { @MainActor in
                do { try await backend.closeTab(id) } catch { log("close tab \(id) on \(key) failed: \(error)") }
            }
        }
    }

    /// Closes a workspace on any machine, always asking first.
    func closeWorkspace(_ id: WorkspaceID, on key: MachineKey) {
        guard let backend = connections[key]?.store.backend else { return }
        confirmClose("Workspace", info: "This closes all of its tabs and panes, and stops anything running in them.", allowSkipping: false) {
            Task { @MainActor in
                do { try await backend.closeWorkspace(id) } catch { log("close workspace \(id) on \(key) failed: \(error)") }
            }
        }
    }

    /// Everything the command bar can go to, the tree's outline, where the focus is, and what going to
    /// each entry does.
    func commandBarModel() -> CommandBarModel {
        var all: [CommandBarEntry] = []
        var actions: [String: () -> Void] = [:]
        var needsYou: [(machine: String, pane: PaneID)] = []
        let focusedStore = connections[focusedMachine]?.store
        let currentWorkspace = focusedStore?.focusedWorkspace?.id

        // Agents: the waiting ones lead any search, and those waiting or in error are "Needs you".
        for entry in AgentEntry.sorted(agentEntries()) {
            let title = "\(entry.info.kindName): \(entry.paneTitle ?? entry.tabTitle ?? "agent")"
            let place = [entry.workspace?.name, entry.tabTitle].compactMap { $0 }.joined(separator: " › ")
            let id = "agent|\(entry.machine)|\(entry.pane)"
            let here = entry.machine == focusedMachine && entry.workspace?.id == currentWorkspace
            all.append(CommandBarEntry(item: QuickOpenItem(kind: .agent, title: title, subtitle: "\(entry.machineName) · \(place)", id: id),
                                       tier: entry.info.needsAttention ? 0 : here ? 1 : 2,
                                       dot: entry.info.badgeColor, detail: Self.agentDetail(entry.info),
                                       path: ([entry.machineName] + [entry.workspace?.name, entry.tabTitle].compactMap { $0 }).joined(separator: " › ")))
            actions[id] = { [weak self] in self?.openAgent(machine: entry.machine, pane: entry.pane) }
            if Self.needsYou(entry.info) { needsYou.append((entry.machine, entry.pane)) }
        }

        // Machines in sidebar order (enabled ones), each with its workspaces and tabs when connected.
        var machines: [CommandTree.Outline.Machine] = []
        for machine in [Machine.local] + remoteMachines {
            let key = machine.key
            let session = connections[key]
            let name = machine.isLocal ? ComputerName.current : machine.label
            let machineID = "machine|\(key)"
            // The same words as Settings › Machines.
            let status = MachineRowStatus.of(isLocal: false, isEnabled: true, connected: session.map(\.store.isConnected),
                                             paused: session?.store.retryPaused ?? false,
                                             check: machine.id.flatMap { machineStatus[$0] }).text
            all.append(CommandBarEntry(item: QuickOpenItem(kind: .machine, title: name, subtitle: session != nil ? "Connected" : "Connect", id: machineID),
                                       tier: 2, path: status))
            actions[machineID] = { [weak self] in
                guard let self else { return }
                if connections[key] != nil { focus(machine: key) } else { connect(machine, show: true) }
            }
            guard let session else {
                machines.append(.init(key: key, workspaces: nil))
                continue
            }
            let store = session.store
            let state = store.state
            var workspaces: [CommandTree.Outline.Workspace] = []
            for workspace in state.workspaces {
                workspaces.append(.init(id: workspace.id, tabs: workspace.tabs.map(\.id)))
                let here = key == focusedMachine && workspace.id == currentWorkspace
                let workspaceID = "ws|\(key)|\(workspace.id)"
                // Git (feature `git`): the active tab's branch on the workspace's row, and each tab's branch,
                // worktree and PR number on its own, all searchable ("#42" or "42" finds the PR's tab).
                let activeTab = workspace.tabs.first { $0.id == workspace.activeTab } ?? workspace.tabs.first
                let workspaceGit = activeTab.flatMap { git(of: $0, in: store) }
                all.append(CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: workspace.name,
                                                               subtitle: [session.title, workspaceGit?.place].compactMap { $0 }.joined(separator: " · "),
                                                               id: workspaceID),
                                           tier: here ? 1 : 2,
                                           dot: agentBadge(machine: key, panes: workspace.tabs.flatMap(\.layout.panes)),
                                           detail: workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs",
                                           path: session.title))
                // Its last active tab, by the model's rules (LocalFocus), as a sidebar click.
                actions[workspaceID] = { [weak self] in self?.focusNow(.workspace(workspace.id), on: key, trace: "command bar") }
                for tab in workspace.tabs {
                    let id = "tab|\(key)|\(tab.id)"
                    let panes = tab.layout.panes
                    let agent = Self.mostUrgent(panes.compactMap { state.pane($0)?.agent })
                    all.append(CommandBarEntry(item: QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab),
                                                                   subtitle: ([session.title, workspace.name] + [git(of: tab, in: store)?.searchText].compactMap { $0 }).joined(separator: " · "), id: id),
                                               tier: here ? 1 : 2, dot: agentBadge(machine: key, panes: panes),
                                               detail: agent.map(Self.agentDetail), panes: panes.count,
                                               path: "\(session.title) › \(workspace.name)"))
                    actions[id] = { [weak self] in self?.focusNow(.tab(tab.id), on: key, trace: "command bar") }
                }
            }
            machines.append(.init(key: key, workspaces: workspaces))
        }
        return CommandBarModel(all: all, outline: CommandTree.Outline(machines: machines, needsYou: needsYou),
                               machine: focusedMachine, workspace: currentWorkspace, tab: focusedStore?.focusedTab?.id, actions: actions)
    }

    /// An agent in ⌘P's "Needs you": waiting for you or in error, and not muted or already seen.
    static func needsYou(_ info: AgentInfo) -> Bool {
        info.needsAttention && [.waiting, .error].contains(info.state)
    }

    /// "waiting: Allow Bash?", "running", "done: Tests pass".
    static func agentDetail(_ info: AgentInfo) -> String {
        let state = info.shownState.label.lowercased()
        guard let what = info.prompt ?? info.headline, !what.isEmpty else { return state }
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
    /// The selection moved to a tab with nothing typed: switch to it as a preview.
    var onPreview: ((CommandBarEntry) -> Void)?
    /// Esc (or ⌘P) after a preview: back to where you were.
    var onRestore: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// ⌘⌫ on a tab or workspace row.
    var onClose: ((CommandBarEntry) -> Void)?
    /// ⌥↩ on a row.
    var onNewTab: ((CommandBarEntry) -> Void)?
    /// ⌘↩ on a tab: its panes beside the current pane.
    var onOpenBeside: ((CommandBarEntry) -> Void)?
    /// A ">" command for the selected row (`subject`), with the picked `target` for one that needs it.
    var onCommand: ((CommandListItem, _ subject: CommandTree.Node?, _ target: CommandTree.Node?) -> Void)?
    /// What the commands apply to, for the selected row.
    var commandContext: ((CommandTree.Node?) -> CommandContext)?
    /// The model now, after a change (a tab closed, an agent started waiting).
    var reload: (() -> (all: [CommandBarEntry], outline: CommandTree.Outline)?)?

    let card = NSView()
    private let field = NSTextField()
    private let list = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No matches")
    private(set) var all: [CommandBarEntry]
    private var byID: [String: CommandBarEntry] = [:]
    private(set) var tree: CommandTree
    private let initialSelection: CommandTree.Node?
    /// Search results while something is typed.
    private(set) var results: [(entry: CommandBarEntry, indices: [Int])] = []
    private var searchSelected = 0
    /// The first row drawn: only `visibleRows` rows are, around the selection.
    private(set) var windowStart = 0
    static let visibleRows = 14
    /// A preview moved away from where you were.
    private var previewed = false
    private var reloadScheduled = false

    init(all: [CommandBarEntry], tree: CommandTree) {
        self.all = all
        self.tree = tree
        initialSelection = tree.selection
        super.init(frame: .zero)
        index()

        field.placeholderString = Self.placeholder
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

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: s(6), left: s(6), bottom: s(6), right: s(6))
        empty.textColor = Theme.dimText
        empty.font = .systemFont(ofSize: s(13))

        footer.font = .systemFont(ofSize: s(11))
        footer.textColor = Theme.faintText
        footer.lineBreakMode = .byTruncatingTail
        let footerRow = NSStackView(views: [footer])
        footerRow.edgeInsets = NSEdgeInsets(top: s(7), left: s(16), bottom: s(8), right: s(16))

        let stack = NSStackView(views: [top, Self.rule(), list, Self.rule(), footerRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

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
            card.widthAnchor.constraint(equalToConstant: s(620)),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func rule() -> NSView {
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.divider
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func index() {
        byID = Dictionary(all.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func focusField() { window?.makeFirstResponder(field) }

    /// Closes it, leaving whatever it switched to.
    func dismiss() {
        removeFromSuperview()
        onDismiss?()
    }

    /// Esc or ⌘P: back to where you were, and close.
    func cancel() {
        if picking != nil {
            endPick()
            field.stringValue = ""
            field.placeholderString = Self.placeholder
            return update()
        }
        if previewed { onRestore?() }
        dismiss()
    }

    static let placeholder = "Search workspaces, tabs and agents, or > for commands"

    private func endPick() {
        picking = nil
        pickSource = nil
        if let treeBeforePick { tree = treeBeforePick }
        treeBeforePick = nil
    }

    /// While picking where a tab goes: its own workspace, and workspaces on other machines.
    func isDimmedForPick(_ node: CommandTree.Node) -> Bool {
        guard let pickSource else { return false }
        switch node {
        case let .workspace(machine, id): return machine != pickSource.machine || id == pickSource.workspace
        case let .machine(machine): return machine != pickSource.machine
        default: return true
        }
    }

    // MARK: State

    var query: String { field.stringValue }
    /// ">" typed: the commands for the selected row.
    var isCommandMode: Bool { picking == nil && CommandList.commandQuery(query) != nil }
    var isSearching: Bool { !isCommandMode && !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// A command that needs a target (Move Tab) waits for a workspace to be picked in the tree.
    private(set) var picking: (item: CommandListItem, subject: CommandTree.Node)?
    /// The tree as it was before picking, to come back to.
    private var treeBeforePick: CommandTree?
    /// While picking: the tab's own workspace ("current") and machine (others are dimmed: a tab can't
    /// move between machines).
    private var pickSource: (machine: String, workspace: WorkspaceID?)?
    private(set) var commands: [CommandListItem] = []
    private var commandSelected = 0
    /// The search field (tests and TypeText).
    var fieldForTesting: NSTextField { field }

    /// Every row as it would be drawn (searching: the results; otherwise the tree), with the tree row.
    var rows: [(entry: CommandBarEntry, indices: [Int], row: CommandTree.Row?)] {
        if isCommandMode { return commands.map { (Self.entry(for: $0), [], nil) } }
        if isSearching { return results.map { ($0.entry, $0.indices, nil) } }
        return tree.rows.map { row in (entry(for: row.node), [], row) }
    }

    /// The selected row's index in `rows`.
    var selected: Int { isCommandMode ? commandSelected : isSearching ? searchSelected : tree.selectedIndex ?? 0 }

    static func entry(for command: CommandListItem) -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .agent, title: command.title, id: "cmd|\(command.id.rawValue)"), tier: 2,
                        symbol: symbol(for: command.id))
    }

    static func symbol(for id: CommandListItem.ID) -> String {
        switch id {
        case .newTab: return "plus.rectangle"
        case .newWorkspace: return "plus.rectangle.on.rectangle"
        case .closeTab, .closeWorkspace: return "xmark.rectangle"
        case .splitRight: return "rectangle.split.2x1"
        case .splitDown: return "rectangle.split.1x2"
        case .claudeHere, .codexHere: return "sparkles"
        case .resumeClaude: return "arrow.uturn.backward"
        case .rename: return "pencil"
        case .moveTab: return "arrow.right.square"
        case .openBeside: return "rectangle.righthalf.inset.filled"
        case .files: return "folder"
        case .settings: return "gearshape"
        case .machines: return "server.rack"
        case .toggleSidebar: return "sidebar.left"
        case .appearanceSystem, .appearanceLight, .appearanceDark: return "circle.lefthalf.filled"
        case .machineOn, .machineOff: return "power"
        case .reconnect: return "arrow.clockwise"
        }
    }

    var selectedEntry: CommandBarEntry? {
        let rows = rows
        return rows.indices.contains(selected) ? rows[selected].entry : nil
    }

    private func entry(for node: CommandTree.Node) -> CommandBarEntry {
        byID[node.entryID] ?? CommandBarEntry(item: QuickOpenItem(kind: .tab, title: "…", id: node.entryID), tier: 2)
    }

    /// Testing aid and typing: sets the query and ranks again.
    func setQuery(_ text: String) {
        field.stringValue = text
        update()
    }

    /// The model changed: picks it up once, on the next pass of the run loop.
    func setNeedsReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, reloadScheduled else { return }
            reloadScheduled = false
            guard superview != nil, let model = reload?() else { return }
            apply(all: model.all, outline: model.outline)
        }
    }

    /// New model contents, keeping the place (and the selected search result, by id).
    func apply(all: [CommandBarEntry], outline: CommandTree.Outline) {
        let selectedID = isSearching ? selectedEntry?.item.id : nil
        self.all = all
        index()
        tree.update(outline)
        if isSearching {
            results = CommandBar.results(all: all, current: [], query: query)
            searchSelected = selectedID.flatMap { id in results.firstIndex { $0.entry.item.id == id } } ?? min(searchSelected, max(0, results.count - 1))
        }
        render()
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)): move(1)
        case #selector(moveUp(_:)): move(-1)
        // With text, ← and → edit it; Tab and ⇧Tab leave the search at the selected row or its parent.
        case #selector(moveRight(_:)):
            guard !isSearching else { return false }
            expand()
        case #selector(moveLeft(_:)):
            guard !isSearching else { return false }
            collapse()
        case #selector(insertTab(_:)): isSearching ? leaveSearch(atParent: false) : expand()
        case #selector(insertBacktab(_:)): isSearching ? leaveSearch(atParent: true) : collapse()
        case #selector(insertNewline(_:)): open()
        // ⌥↩
        case #selector(insertNewlineIgnoringFieldEditor(_:)): newTab()
        case #selector(cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    /// ⌘1–9 pick a row in view; ⌘⌫ closes the selected tab or workspace; ⌘P closes the bar (it would
    /// otherwise reach the menu, which does the same).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        if key == "p" {
            cancel()
            return true
        }
        if key == "\r" {
            openBeside()
            return true
        }
        if key == "\u{7f}" || event.keyCode == 51 {
            closeSelected()
            return true
        }
        if let digit = Int(key), (1...9).contains(digit) {
            pick(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Return: a search result opens; in the tree, a tab, workspace or agent opens and a machine expands
    /// (or connects).
    func open() {
        if isCommandMode {
            guard commands.indices.contains(commandSelected) else { return }
            let command = commands[commandSelected]
            let subject = tree.selection
            if command.target != nil, let subject {
                // Move Tab: pick the workspace in the tree, then it moves.
                picking = (command, subject)
                treeBeforePick = tree
                let source: WorkspaceID? = if case let .tab(machine, tab) = subject { tree.workspace(containing: tab, on: machine) } else { nil }
                pickSource = (subject.machine, source)
                tree.workspacesOnly = true
                tree.selectFirstWorkspace(on: subject.machine, except: source)
                field.stringValue = ""
                field.placeholderString = command.title.replacingOccurrences(of: " to…", with: " to which workspace?")
                return update()
            }
            return onCommand?(command, subject, nil) ?? ()
        }
        if let picking {
            // The picked row's workspace: a workspace row (or result); a machine row expands as usual.
            let node = isSearching ? selectedEntry.flatMap { CommandTree.Node(entryID: $0.item.id) } : tree.selection
            if let node, case .workspace = node {
                // The tab's own workspace and other machines' workspaces aren't targets.
                guard !isDimmedForPick(node) else { return }
                endPick()
                return onCommand?(picking.item, picking.subject, node) ?? ()
            }
            if !isSearching, case .machine = node, tree.activate() == .expanded { return render() }
        }
        if isSearching {
            if let entry = selectedEntry { onOpen?(entry) }
            return
        }
        switch tree.activate() {
        case let .open(node): onOpen?(entry(for: node))
        case let .connect(key): onOpen?(entry(for: .machine(key)))
        case .expanded: render()
        case .nothing: break
        }
    }

    /// Picks row `index` among those in view (⌘1 is the first) and opens it.
    func pick(_ index: Int) {
        let absolute = windowStart + index
        guard rows.indices.contains(absolute), index < Self.visibleRows else { return }
        if isCommandMode { commandSelected = absolute } else if isSearching { searchSelected = absolute } else { tree.select(absolute) }
        open()
    }

    func closeSelected() {
        guard let entry = selectedEntry, [.tab, .workspace].contains(entry.item.kind) else { return NSSound.beep() }
        onClose?(entry)
    }

    func newTab() {
        guard !isCommandMode, picking == nil, let entry = selectedEntry else { return }
        onNewTab?(entry)
    }

    /// ⌘↩: the selected tab's panes beside the current pane (the app checks it can).
    func openBeside() {
        guard !isCommandMode, picking == nil, let entry = selectedEntry, entry.item.kind == .tab else { return NSSound.beep() }
        onOpenBeside?(entry)
    }

    private func move(_ by: Int) {
        if isCommandMode {
            guard !commands.isEmpty else { return }
            commandSelected = (commandSelected + by + commands.count) % commands.count
            return render()
        }
        if isSearching {
            guard !results.isEmpty else { return }
            searchSelected = (searchSelected + by + results.count) % results.count
            return render()
        }
        guard let node = tree.move(by) else { return }
        render()
        // Tabs show as they're selected; workspace, machine and agent rows only highlight.
        if picking == nil, case .tab = node {
            previewed = previewed || node != initialSelection
            onPreview?(entry(for: node))
        }
    }

    private func expand() {
        if tree.expand() { render() }
    }

    private func collapse() {
        if tree.collapse() { render() }
    }

    /// Tab (or ⇧Tab) with text: clears it and shows the tree at the selected result (or its parent).
    private func leaveSearch(atParent: Bool) {
        guard let entry = selectedEntry, let node = CommandTree.Node(entryID: entry.item.id) else { return }
        if atParent { tree.revealParent(of: node) } else { tree.reveal(node) }
        field.stringValue = ""
        update()
    }

    private func update() {
        results = isSearching ? CommandBar.results(all: picking == nil ? all : all.filter { $0.item.kind == .workspace }, current: [], query: query) : []
        searchSelected = 0
        if isCommandMode, let text = CommandList.commandQuery(query) {
            let context = commandContext?(tree.selection) ?? CommandContext()
            commands = CommandList.matching(CommandList.items(for: context), query: text)
        } else {
            commands = []
        }
        commandSelected = 0
        render()
    }

    // MARK: Drawing

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footer.stringValue = isCommandMode ? "↑↓ move    ↩ run    esc back"
            : picking != nil ? "↑↓ move    → expand    ↩ move here    esc cancel"
            : isSearching ? "↑↓ move    ↩ open    ⌘↩ beside    tab expand    ⇧tab up    ⌥↩ new tab    ⌘⌫ close    esc back"
            : "↑↓ move    → expand    ← back    ↩ open    ⌘↩ beside    ⌥↩ new tab    ⌘⌫ close    esc back"
        let rows = rows
        if rows.isEmpty {
            empty.stringValue = isCommandMode ? "No commands" : isSearching ? "No matches" : "No workspaces"
            list.addArrangedSubview(empty)
            return
        }
        // Only the rows in view are drawn, keeping the selection inside it.
        let selected = selected
        let limit = Self.visibleRows
        if selected < windowStart { windowStart = selected }
        if selected >= windowStart + limit { windowStart = selected - limit + 1 }
        windowStart = max(0, min(windowStart, max(0, rows.count - limit)))
        var lastSection: CommandTree.Section?
        for index in windowStart..<min(rows.count, windowStart + limit) {
            let shown = rows[index]
            if let row = shown.row, row.section != lastSection {
                let heading = header(for: row.section)
                list.addArrangedSubview(heading)
                heading.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -s(12)).isActive = true
                lastSection = row.section
            }
            let number = index - windowStart
            var entry = shown.entry
            let node = CommandTree.Node(entryID: entry.item.id)
            let dimmed = node.map(isDimmedForPick) ?? false
            if let pickSource, case let .workspace(machine, id)? = node, machine == pickSource.machine, id == pickSource.workspace {
                entry.detail = "current"
            }
            let rowView = QuickOpenRow(entry: entry, indices: shown.indices, selected: index == selected,
                                       shortcut: number < 9 ? number + 1 : nil, depth: shown.row?.depth ?? 0,
                                       disclosure: shown.row.flatMap { $0.expandable ? $0.expanded : nil },
                                       showPath: shown.row == nil || shown.row?.section == .needsYou || shown.entry.item.kind == .machine) { [weak self] in
                self?.pick(number)
            }
            // A highlighted workspace keeps its tint here too, under the selection's.
            if index != selected, case let .workspace(machine, id)? = node, let highlight = WorkspaceHighlights.get(machine, id) {
                rowView.withAppearance {
                    let alpha = WorkspaceHighlights.alpha(dark: rowView.effectiveAppearance.isDark, hovering: false)
                    rowView.layer?.backgroundColor = highlight.color.withAlphaComponent(alpha).cgColor
                }
            }
            // Dimmed rows aren't targets while picking (machines stay expandable).
            if dimmed, case .workspace? = node { rowView.alphaValue = 0.4 } else if dimmed { rowView.alphaValue = 0.6 }
            list.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -s(12)).isActive = true
        }
        if rows.count > limit {
            let more = NSTextField(labelWithString: "\(rows.count - limit) more")
            more.font = .systemFont(ofSize: s(11))
            more.textColor = Theme.faintText
            list.addArrangedSubview(more)
        }
    }

    /// "NEEDS YOU", the machine's name over its workspaces, or "MACHINES".
    private func header(for section: CommandTree.Section) -> NSView {
        let text: String
        var hint: String?
        if section == .needsYou {
            text = "Needs you"
        } else if case let .machine(key) = tree.scope {
            text = byID["machine|\(key)"]?.item.title ?? key
            hint = "← all machines"
        } else {
            text = "Machines"
        }
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: s(10.5), weight: .semibold)
        label.textColor = section == .needsYou ? Theme.accent : Theme.dimText
        var views: [NSView] = [label]
        if let hint {
            let right = NSTextField(labelWithString: hint)
            right.font = .systemFont(ofSize: s(10.5))
            right.textColor = Theme.faintText
            views += [NSView(), right]
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: s(8), left: s(10), bottom: s(3), right: s(10))
        return row
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

    /// `depth` indents a tree row; `disclosure` draws its chevron (nil: none, false: collapsed, true:
    /// expanded); `showPath` adds where it is (search results, Needs you, machines' status).
    init(entry: CommandBarEntry, indices: [Int], selected: Bool, shortcut: Int?, depth: Int = 0, disclosure: Bool? = nil,
         showPath: Bool = true, action: @escaping () -> Void) {
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
            let kindSymbol = switch entry.item.kind {
            case .agent: "sparkles"
            case .workspace: "macwindow.on.rectangle"
            case .tab: "rectangle.topthird.inset.filled"
            case .machine: entry.item.id == "machine|\(AppDelegate.localKey)" ? "laptopcomputer" : "server.rack"
            }
            let symbol = entry.symbol ?? kindSymbol
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = Theme.dimText
            lead = icon
        }
        lead.widthAnchor.constraint(equalToConstant: s(18)).isActive = true
        // The tree's indent and chevron (an empty slot keeps rows without one aligned).
        let chevron = NSImageView()
        if let disclosure {
            chevron.image = NSImage(systemSymbolName: disclosure ? "chevron.down" : "chevron.right", accessibilityDescription: disclosure ? "Expanded" : "Collapsed")?
                .withSymbolConfiguration(.init(pointSize: s(9), weight: .semibold))
            chevron.contentTintColor = Theme.dimText
        }
        chevron.widthAnchor.constraint(equalToConstant: s(10)).isActive = true
        let indent = NSView()
        indent.widthAnchor.constraint(equalToConstant: s(16) * CGFloat(depth)).isActive = true

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = Self.highlighted(entry.item.title, indices)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = (depth > 0 ? [indent] : []) + [chevron, lead, title]
        if let detail = entry.detail {
            views.append(Self.dim(detail, compression: .defaultLow - 2))
        }
        if entry.panes > 1 {
            let panes = Self.dim("\(entry.panes) panes", compression: .required)
            views.append(panes)
        }
        views.append(NSView())
        if showPath { views.append(Self.dim(entry.path ?? entry.item.subtitle, compression: .defaultLow - 1, head: true)) }
        // Rows past the ninth keep an empty slot, so every row is the same height.
        let key = Self.dim(shortcut.map { "⌘\($0)" } ?? "", compression: .required)
        key.font = .monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        key.widthAnchor.constraint(greaterThanOrEqualToConstant: s(22)).isActive = true
        views.append(key)

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
