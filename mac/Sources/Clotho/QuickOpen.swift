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
// (asking first), ⌥↩ opens a new tab there (or allows, on an agent's row with a permission request), ⌘1–9
// pick a row, ⌘P closes. Only the rows in view are drawn, so it stays instant with many machines. Matching
// is ClothoKit's FuzzyMatch, as on iOS.
//
// A state word in the search ("needs", "needs you", "working", "done") puts the agents in that state on
// top, under their own header (see `CommandBar.stateFilter`).
//
// Rows in a repository show their branch and, after it, how much changed there ("+128 −32": clothod
// 0.1.32's `git.changes`). "New Tab in a Worktree…" among the ">" commands turns the bar into a small
// prompt for the new branch's name (Worktree.swift).

/// One row of the command bar.
struct CommandBarEntry {
    /// What's matched (title, then subtitle) and its id.
    var item: QuickOpenItem
    /// Breaks ties while searching, after match quality and kind: 0 an agent waiting for you, 1 the
    /// current workspace, 2 the rest.
    var tier: Int
    /// The agent's mark (a tab's or workspace's most urgent agent's), as every other surface draws it.
    var mark: AgentMark?
    /// The agent's state, such as "waiting for you: fix the login bug"; for a row with a `request`, the
    /// request itself ("Allow Bash: npm test").
    var detail: String?
    /// Panes in the tab, shown when more than one.
    var panes = 1
    /// Where it is, shown dim: "machine › workspace" (nil shows the subtitle).
    var path: String? = nil
    /// An icon in place of the kind's (commands).
    var symbol: String? = nil
    /// The git branch there (an agent's pane's, a tab's, a workspace's active tab's), shown at the trailing
    /// side.
    var branch: String? = nil
    /// Agent rows: when its state last changed, for the order under a state word.
    var since: Double? = nil
    /// Agent rows: the oldest permission request it waits on, when its machine can answer it
    /// (`agent.decide`). ⌥↩ allows it.
    var request: PermissionRequest? = nil
    /// How much changed in the work tree there (the same pane as `branch`), on a machine that counts
    /// it (`git.changes`): shown after the branch.
    var changes: PaneGit.Changes? = nil
}

/// A ">" command as the bar lists it: one of the shared ones (ClothoKit's CommandList, as on iOS), or
/// the Mac's own.
enum BarCommand: Equatable {
    case shared(CommandListItem)
    /// New Tab in a Worktree…: the bar asks for the branch's name.
    case newWorktreeTab

    var title: String {
        switch self {
        case let .shared(item): return item.title
        case .newWorktreeTab: return "New Tab in a Worktree…"
        }
    }

    var keywords: [String] {
        switch self {
        case let .shared(item): return item.keywords
        case .newWorktreeTab: return ["git", "branch", "agent", "checkout"]
        }
    }

    var symbol: String {
        switch self {
        case let .shared(item): return QuickOpenOverlay.symbol(for: item.id)
        case .newWorktreeTab: return "arrow.triangle.branch"
        }
    }

    /// The row's id in the bar.
    var entryID: String {
        switch self {
        case let .shared(item): return "cmd|\(item.id.rawValue)"
        case .newWorktreeTab: return "cmd|newWorktreeTab"
        }
    }
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
    ///
    /// With a state word ("needs", "working", "done": see `stateFilter`) the agents in that state lead, and
    /// only the best plain matches follow (see `search`).
    static func results(all: [CommandBarEntry], current: [CommandBarEntry], query: String) -> [(entry: CommandBarEntry, indices: [Int])] {
        search(all: all, current: current, query: query).rows
    }

    /// `results`, with what leads them: `marks` is the state filter (empty without a state word) and
    /// `lead` how many rows on top are agents in that state. Those are ranked by the rest of the query, or
    /// in the inbox's order when there is none (Needs you: the longest wait first). After them come the
    /// whole query's matches as without a state word, but only those whose title starts with it or has a
    /// word that does, so a tab really named "done" is still found. `stateWords: false` reads no state
    /// word (picking a workspace).
    static func search(all: [CommandBarEntry], current: [CommandBarEntry], query: String, stateWords: Bool = true)
        -> (rows: [(entry: CommandBarEntry, indices: [Int])], marks: Set<AgentMark>, lead: Int) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return (current.prefix(limit).map { ($0, []) }, [], 0) }
        let filter: (marks: Set<AgentMark>, rest: String) = stateWords ? stateFilter(query) : ([], query)
        guard !filter.marks.isEmpty else { return (ranked(all, query: query).prefix(limit).map { ($0.entry, $0.indices) }, [], 0) }
        let agents = all.filter { entry in entry.item.kind == .agent && entry.mark.map(filter.marks.contains) == true }
        var lead: [(entry: CommandBarEntry, indices: [Int])]
        if filter.rest.isEmpty {
            lead = inboxOrder(agents).map { ($0, []) }
        } else {
            let byID = Dictionary(agents.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
            lead = QuickOpen.rank(agents.map(\.item), query: filter.rest, limit: agents.count).compactMap { result in
                byID[result.item.id].map { ($0, result.titleIndices) }
            }
        }
        lead = Array(lead.prefix(limit))
        let leading = Set(lead.map(\.entry.item.id))
        let plain = ranked(all, query: query).filter { $0.band <= 1 && !leading.contains($0.entry.item.id) }
        return (lead + plain.prefix(limit - lead.count).map { ($0.entry, $0.indices) }, filter.marks, lead.count)
    }

    /// The state words in a query, as whole words in any case: "needs" (with or without "you" after it)
    /// means the agents that need the user and the ones that failed, "working" the working ones, "done"
    /// the finished ones. `rest` is the query without them.
    static func stateFilter(_ query: String) -> (marks: Set<AgentMark>, rest: String) {
        var marks: Set<AgentMark> = []
        var rest: [Substring] = []
        var afterNeeds = false
        for word in query.split(whereSeparator: \.isWhitespace) {
            let wasAfterNeeds = afterNeeds
            afterNeeds = false
            switch word.lowercased() {
            case "needs":
                marks.formUnion([.needsYou, .error])
                afterNeeds = true
            case "you" where wasAfterNeeds: break
            case "working": marks.insert(.working)
            case "done": marks.insert(.done)
            default: rest.append(word)
            }
        }
        return marks.isEmpty ? ([], query) : (marks, rest.joined(separator: " "))
    }

    /// Agent rows as the sidebar's inbox orders them (`AgentInbox.sections`): those that need the user or
    /// failed, the longest wait first (one with no time last); then the finished and the working, the most
    /// recent first.
    static func inboxOrder(_ agents: [CommandBarEntry]) -> [CommandBarEntry] {
        func recent(_ mark: AgentMark) -> [CommandBarEntry] {
            agents.filter { $0.mark == mark }.sorted { ($0.since ?? 0) > ($1.since ?? 0) }
        }
        let needsYou = agents.filter { $0.mark == .needsYou || $0.mark == .error }
            .sorted { ($0.since ?? .infinity) < ($1.since ?? .infinity) }
        return needsYou + recent(.done) + recent(.working)
    }

    /// The header over the agents a state word lists: "Needs you", "Done", "Working" (failed agents are
    /// under Needs you, as in the inbox).
    static func stateTitle(_ marks: Set<AgentMark>) -> String {
        [AgentMark.needsYou, .done, .working].filter(marks.contains).map(\.label).joined(separator: ", ")
    }

    /// Every match for `query`, best first, with its `band`.
    private static func ranked(_ all: [CommandBarEntry], query: String) -> [(entry: CommandBarEntry, indices: [Int], band: Int)] {
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
        return sorted.map { ($0.entry, $0.indices, $0.key[0]) }
    }

    /// How well `query` matches a row's title, best first: 0 the title starts with it ("api" for "api" or
    /// "api-tests"), 1 a word in it does ("deploy api"), 2 its letters are in the title in order ("a-p-i"),
    /// 3 only with the subtitle's help ("dev api" for devbox's api). Case doesn't matter.
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
        overlay.onAllow = { [weak self] entry in self?.commandBarAllow(entry) }
        overlay.worktreeSubject = { [weak self] node in self?.worktreeSubject(for: node, origin: origin) }
        overlay.onCreateWorktree = { [weak self] subject, name, base in self?.createWorktreeTab(subject, name: name, base: base) }
        overlay.reload = { [weak self] in
            guard let self else { return nil }
            model = commandBarModel()
            return (model.all, model.outline)
        }
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            quickOpen = nil
            returnKeyboardToPanes()
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
            uncoverPanes()
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

    /// ⌥↩ on an agent's row with a permission request: allows that request. The bar stays open.
    func commandBarAllow(_ entry: CommandBarEntry) {
        guard case let .agent(machine, pane)? = CommandTree.Node(entryID: entry.item.id), let request = entry.request else { return NSSound.beep() }
        log("command bar: allow \(entry.item.title)")
        decide(machine: machine, pane: pane, request: request.id, .allow)
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

        // Agents: the waiting ones lead any search, and those waiting, in error or asking are "Needs you".
        for entry in AgentEntry.sorted(agentEntries()) {
            let title = "\(entry.info.kindName): \(entry.paneTitle ?? entry.tabTitle ?? "agent")"
            let place = [entry.workspace?.name, entry.tabTitle].compactMap { $0 }.joined(separator: " › ")
            let id = "agent|\(entry.machine)|\(entry.pane)"
            let here = entry.machine == focusedMachine && entry.workspace?.id == currentWorkspace
            let store = connections[entry.machine]?.store
            // The request ⌥↩ allows: the oldest, as the pane's ask bar shows, when the daemon can answer it.
            let request = store?.features.contains(.agentDecide) == true ? entry.info.pendingRequests.first : nil
            all.append(CommandBarEntry(item: QuickOpenItem(kind: .agent, title: title, subtitle: "\(entry.machineName) · \(place)", id: id),
                                       tier: entry.info.needsAttention ? 0 : here ? 1 : 2,
                                       mark: entry.info.mark, detail: request?.askText ?? Self.agentDetail(entry.info),
                                       path: ([entry.machineName] + [entry.workspace?.name, entry.tabTitle].compactMap { $0 }).joined(separator: " › "),
                                       branch: store.flatMap { git(entry.pane, in: $0) }?.branch, since: entry.info.since, request: request,
                                       changes: store.flatMap { changes(entry.pane, in: $0) }))
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
                                           mark: agentMark(machine: key, panes: workspace.tabs.flatMap(\.layout.panes))?.mark,
                                           detail: workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs",
                                           path: session.title, branch: workspaceGit?.branch,
                                           changes: activeTab.flatMap { changes($0.activePane, in: store) }))
                // Its last active tab, by the model's rules (LocalFocus), as a sidebar click.
                actions[workspaceID] = { [weak self] in self?.focusNow(.workspace(workspace.id), on: key, trace: "command bar") }
                for tab in workspace.tabs {
                    let id = "tab|\(key)|\(tab.id)"
                    let panes = tab.layout.panes
                    let agent = Self.mostUrgent(panes.compactMap { state.pane($0)?.agent })
                    let tabGit = git(of: tab, in: store)
                    all.append(CommandBarEntry(item: QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab),
                                                                   subtitle: ([session.title, workspace.name] + [tabGit?.searchText].compactMap { $0 }).joined(separator: " · "), id: id),
                                               tier: here ? 1 : 2, mark: agentMark(machine: key, panes: panes)?.mark,
                                               detail: agent.map(Self.agentDetail), panes: panes.count,
                                               path: "\(session.title) › \(workspace.name)", branch: tabGit?.branch,
                                               changes: changes(tab.activePane, in: store)))
                    actions[id] = { [weak self] in self?.focusNow(.tab(tab.id), on: key, trace: "command bar") }
                }
            }
            machines.append(.init(key: key, workspaces: workspaces))
        }
        return CommandBarModel(all: all, outline: CommandTree.Outline(machines: machines, needsYou: needsYou),
                               machine: focusedMachine, workspace: currentWorkspace, tab: focusedStore?.focusedTab?.id, actions: actions)
    }

    /// A pane's change count, on a machine whose daemon counts changes.
    func changes(_ pane: PaneID, in store: ModelStore) -> PaneGit.Changes? {
        guard store.features.contains(.gitChanges) else { return nil }
        return git(pane, in: store)?.changes
    }

    /// An agent in ⌘P's "Needs you": waiting for you, in error, or finished with a question for you
    /// (`needs_user`), and not muted or already seen. A turn that only finished isn't, nor one still
    /// settling.
    static func needsYou(_ info: AgentInfo) -> Bool {
        info.needsAttention && ([.waiting, .error].contains(info.state) || info.asksUser)
    }

    /// "waiting for you: Allow Bash?", "running", "needs you: Should I push?", "done: Tests pass".
    static func agentDetail(_ info: AgentInfo) -> String {
        let state = info.shownState.label.lowercased()
        // What it asks, for a finished turn with a question; else what it was asked to do.
        guard let what = info.asksUser ? info.headline ?? info.prompt : info.prompt ?? info.headline, !what.isEmpty else { return state }
        return "\(state): \(what)"
    }

    /// The agent that most needs the user (waiting, then error, then a finished turn that asks
    /// something, then one that only finished), else the first.
    static func mostUrgent(_ agents: [AgentInfo]) -> AgentInfo? {
        func rank(_ info: AgentInfo) -> Int { info.needsAttention ? info.urgency : 4 }
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
    /// ⌥↩ on an agent's row that waits on a permission request: allow it. The bar stays open.
    var onAllow: ((CommandBarEntry) -> Void)?
    /// ⌘↩ on a tab: its panes beside the current pane.
    var onOpenBeside: ((CommandBarEntry) -> Void)?
    /// A ">" command for the selected row (`subject`), with the picked `target` for one that needs it.
    var onCommand: ((CommandListItem, _ subject: CommandTree.Node?, _ target: CommandTree.Node?) -> Void)?
    /// What the commands apply to, for the selected row.
    var commandContext: ((CommandTree.Node?) -> CommandContext)?
    /// The model now, after a change (a tab closed, an agent started waiting).
    var reload: (() -> (all: [CommandBarEntry], outline: CommandTree.Outline)?)?
    /// Where "New Tab in a Worktree…" would work for the selected row; nil when it can't (no repository
    /// there, or a daemon without `worktree`), and the command isn't listed.
    var worktreeSubject: ((CommandTree.Node?) -> WorktreeSubject?)?
    /// Return in the worktree prompt: the name and the base (nil: the branch's HEAD).
    var onCreateWorktree: ((WorktreeSubject, _ name: String, _ base: String?) -> Void)?

    let card = NSView()
    private let field = NSTextField()
    private let list = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private let footerEsc = NSTextField(labelWithString: "esc")
    private let empty = NSTextField(labelWithString: "No matches")
    private let fieldIcon = NSImageView()
    /// The worktree prompt's own part, in the list's place while it's up.
    let baseField = NSTextField()
    let namingPreview = NSTextField(wrappingLabelWithString: "")
    let namingStatus = NSTextField(wrappingLabelWithString: "")
    let namingSpinner = NSProgressIndicator()
    private let namingBox = NSStackView()
    /// The last ⌥↩ that allowed a request here: for `AskBar.settleDelay` after it, ⌥↩ on a row with no
    /// request opens no tab (the second tap of a double tap, once the last request's row is gone).
    private var lastAllowAt: Date?
    private(set) var all: [CommandBarEntry]
    private var byID: [String: CommandBarEntry] = [:]
    private(set) var tree: CommandTree
    private let initialSelection: CommandTree.Node?
    /// Search results while something is typed.
    private(set) var results: [(entry: CommandBarEntry, indices: [Int])] = []
    private var searchSelected = 0
    /// With a state word typed: the states it lists and how many rows on top are agents in them.
    private(set) var stateLead: (marks: Set<AgentMark>, count: Int) = ([], 0)
    /// The headers drawn over the rows, top to bottom, as shown ("NEEDS YOU  2", "MATCHES").
    private(set) var headings: [String] = []
    /// The first row drawn: only `visibleRows` rows are, around the selection.
    private(set) var windowStart = 0
    static let visibleRows = 14
    /// A preview moved away from where you were.
    private var previewed = false
    private var reloadScheduled = false
    /// Whether the key being handled is a held key's repeat. ⌥↩ never acts on one.
    var isKeyRepeat: () -> Bool = {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }
    /// The request under the selection, the one ⌥↩ would allow, and since when. `render` keeps it, so it
    /// starts over however that request got there: the bar opened on it, the user moved or typed, the
    /// model changed, the selection moved on after an allow, the window became key. ⌥↩ leaves it alone
    /// for `AskBar.settleDelay` from then.
    private var target: (id: String, since: Date)?
    /// The one pending footer refresh, for when "⌥↩ Allow" comes back.
    private var footerRefresh: DispatchWorkItem?
    /// Requests ⌥↩ allowed here, and when: not sent again while the model catches up (`AskBar.retryDelay`).
    private var allowed: [String: Date] = [:]

    init(all: [CommandBarEntry], tree: CommandTree) {
        self.all = all
        self.tree = tree
        initialSelection = tree.selection
        super.init(frame: .zero)
        index()
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)

        field.placeholderString = Self.placeholder
        field.font = .systemFont(ofSize: s(16))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.foreground
        field.delegate = self
        let icon = fieldIcon
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = Theme.dimText
        buildNamingBox()
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
        // The hints give way in a narrow card; "esc" stays at the trailing edge.
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerEsc.font = footer.font
        footerEsc.textColor = Theme.faintText
        footerEsc.setContentCompressionResistancePriority(.required, for: .horizontal)
        footerEsc.setContentHuggingPriority(.required, for: .horizontal)
        let footerRow = NSStackView(views: [footer, NSView(), footerEsc])
        footerRow.orientation = .horizontal
        footerRow.spacing = s(8)
        footerRow.edgeInsets = NSEdgeInsets(top: s(7), left: s(16), bottom: s(8), right: s(16))

        let stack = NSStackView(views: [top, Self.rule(), list, namingBox, Self.rule(), footerRow])
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
            // Never wider than the window leaves room for, so it doesn't clip in a narrow one.
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Self.sideMargin * 2),
        ])
        let width = card.widthAnchor.constraint(equalToConstant: Self.cardWidth)
        width.priority = .defaultHigh
        width.isActive = true
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

    /// The window was in the back: a ⌥↩ pressed as it comes forward wasn't for the request selected here.
    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window, notification.object as AnyObject? === window, let id = target?.id else { return }
        target = (id, Date())
        updateFooter()
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
        if naming != nil {
            // While the worktree is being made, Esc only puts the bar away: the work goes on.
            if isCreating || namingDirect { return dismiss() }
            endNaming()
            field.stringValue = ">"
            return update()
        }
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
    /// The card's width where the window has room, and the least it keeps clear on each side.
    static var cardWidth: CGFloat { s(620) }
    static var sideMargin: CGFloat { s(16) }
    static let openHints = "↩ Open   ⌘↩ Open beside   ⌥↩ New tab"
    static let allowHint = "⌥↩ Allow"
    static let allowHints = "↩ Open   ⌘↩ Open beside   " + allowHint
    /// Whether the footer's "⌥↩ Allow" is dimmed: a press now would be refused (the request just showed
    /// up, or was just allowed).
    private(set) var allowHintDimmed = false
    /// The footer's hints (tests).
    var footerText: String { footer.stringValue }
    /// Whether "esc" shows at the footer's trailing edge (command mode and picking say it in their own line).
    var footerShowsEsc: Bool { !footerEsc.isHidden }

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
    var isCommandMode: Bool { picking == nil && naming == nil && CommandList.commandQuery(query) != nil }
    var isSearching: Bool { naming == nil && !isCommandMode && !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// A command that needs a target (Move Tab) waits for a workspace to be picked in the tree.
    private(set) var picking: (item: CommandListItem, subject: CommandTree.Node)?
    /// The tree as it was before picking, to come back to.
    private var treeBeforePick: CommandTree?
    /// While picking: the tab's own workspace ("current") and machine (others are dimmed: a tab can't
    /// move between machines).
    private var pickSource: (machine: String, workspace: WorkspaceID?)?
    private(set) var commands: [BarCommand] = []
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

    static func entry(for command: BarCommand) -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .agent, title: command.title, id: command.entryID), tier: 2, symbol: command.symbol)
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
            rank()
            searchSelected = selectedID.flatMap { id in results.firstIndex { $0.entry.item.id == id } } ?? min(searchSelected, max(0, results.count - 1))
        }
        render()
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) {
        if naming != nil { return renderNaming() }
        update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if naming != nil { return namingCommand(control, selector) }
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
        case #selector(insertNewlineIgnoringFieldEditor(_:)): allowOrNewTab()
        case #selector(cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    // While a worktree is being made the prompt's fields are off, and a field that is off gives the
    // keyboard up to the window. The overlay takes it instead, so Esc still puts the bar away.
    override var acceptsFirstResponder: Bool { isCreating }

    override func cancelOperation(_ sender: Any?) { cancel() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return cancel() }
        // Nothing else means anything while the fields are off; no beep for a stray key.
        if !isCreating { super.keyDown(with: event) }
    }

    /// ⌘1–9 pick a row in view; ⌘⌫ closes the selected tab or workspace; ⌘P closes the bar (it would
    /// otherwise reach the menu, which does the same).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        if key == "p" {
            // From the worktree prompt too, ⌘P closes the bar (Esc there goes back to the commands).
            if naming != nil { dismiss() } else { cancel() }
            return true
        }
        // The row keys mean nothing in the worktree prompt.
        guard naming == nil else { return super.performKeyEquivalent(with: event) }
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
            let subject = tree.selection
            guard case let .shared(command) = commands[commandSelected] else {
                // New Tab in a Worktree…: the bar becomes its prompt.
                guard let place = worktreeSubject?(subject) else { return NSSound.beep() }
                return beginNaming(place, direct: false)
            }
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

    /// ⌥↩: on an agent's row that waits on a permission request, allows it; the bar stays open and the
    /// selection moves to the next row, ready for the next request. On any other row, a new tab there.
    ///
    /// One press answers one request the user has read: a held key does nothing (its repeats would allow
    /// the next rows, or open a tab once the selection reaches a row with no request), a request that
    /// came under the selection a moment ago isn't allowed yet (the one the selection moves on to here
    /// too: a double tap allows one), and one already allowed isn't sent twice.
    func allowOrNewTab() {
        guard !isKeyRepeat() else { return }
        guard !isCommandMode, picking == nil, let entry = selectedEntry else { return }
        let now = Date()
        guard let request = entry.request else {
            // The second tap of a double ⌥↩ on the last request's row lands here once the row is gone.
            if let lastAllowAt, now.timeIntervalSince(lastAllowAt) < AskBar.settleDelay { return }
            return newTab()
        }
        guard allowRefusedUntil(request.id, now: now) == nil else { return }
        allowed[request.id] = now
        lastAllowAt = now
        onAllow?(entry)
        if isSearching {
            // The row leaves when the model catches up; `apply` keeps the selection on this next one by id.
            searchSelected = min(searchSelected + 1, max(0, results.count - 1))
        } else {
            // No preview: the selection only moves on, the tab on screen stays.
            _ = tree.move(1)
        }
        render()
    }

    /// Until when ⌥↩ leaves `request` alone: it came under the selection a moment ago
    /// (`AskBar.settleDelay`), or was just allowed here (`AskBar.retryDelay`). Nil when a press allows it.
    private func allowRefusedUntil(_ request: String, now: Date = Date()) -> Date? {
        let since = target.flatMap { $0.id == request ? $0.since : nil } ?? now
        let until = max(since.addingTimeInterval(AskBar.settleDelay), allowed[request]?.addingTimeInterval(AskBar.retryDelay) ?? .distantPast)
        return until > now ? until : nil
    }

    /// The footer's hints. "⌥↩ Allow" dims while a press would be refused, the way the pane's ask bar
    /// turns its buttons off, and comes back when the wait is over.
    private func updateFooter() {
        footer.stringValue = naming != nil
            ? (isCreating ? "esc hide (the worktree is still being made)" : "↩ create    ⇥ base    esc \(namingDirect ? "close" : "back")")
            : isCommandMode ? "↑↓ move    ↩ run    esc back"
            : picking != nil ? "↑↓ move    → expand    ↩ move here    esc cancel"
            : selectedEntry?.request != nil ? Self.allowHints : Self.openHints
        allowHintDimmed = false
        footerRefresh?.cancel()
        footerRefresh = nil
        guard naming == nil, !isCommandMode, picking == nil, let request = selectedEntry?.request, let until = allowRefusedUntil(request.id) else { return }
        allowHintDimmed = true
        let text = NSMutableAttributedString(string: Self.allowHints, attributes: [.font: footer.font as Any, .foregroundColor: Theme.faintText])
        text.addAttribute(.foregroundColor, value: Theme.faintText.withAlphaComponent(0.35), range: (Self.allowHints as NSString).range(of: Self.allowHint))
        footer.attributedStringValue = text
        // One timer, however often the rows are drawn while it's dimmed.
        let refresh = DispatchWorkItem { [weak self] in
            guard let self, superview != nil else { return }
            updateFooter()
        }
        footerRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 0.01, execute: refresh)
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

    /// Ranks the search again. Picking a workspace lists workspaces only and reads no state word.
    private func rank() {
        guard isSearching else {
            results = []
            stateLead = ([], 0)
            return
        }
        let found = picking == nil ? CommandBar.search(all: all, current: [], query: query)
            : CommandBar.search(all: all.filter { $0.item.kind == .workspace }, current: [], query: query, stateWords: false)
        results = found.rows
        stateLead = (found.marks, found.lead)
    }

    private func update() {
        rank()
        searchSelected = 0
        if isCommandMode, let text = CommandList.commandQuery(query) {
            let context = commandContext?(tree.selection) ?? CommandContext()
            var listed = CommandList.items(for: context).map(BarCommand.shared)
            if worktreeSubject?(tree.selection) != nil {
                // Right after New Tab, which it is a kind of.
                let newTab = listed.firstIndex { if case let .shared(item) = $0 { item.id == .newTab } else { false } }
                listed.insert(.newWorktreeTab, at: newTab.map { $0 + 1 } ?? 0)
            }
            commands = CommandList.matching(listed, query: text, title: \.title, keywords: \.keywords)
        } else {
            commands = []
        }
        commandSelected = 0
        render()
    }

    // MARK: The worktree prompt (New Tab in a Worktree…)

    /// The prompt's subject while the bar is asking for a worktree's name.
    private(set) var naming: WorktreeSubject?
    /// Opened straight into the prompt (the menu, ⌥⌘T): Esc closes the bar, there's no list to go back to.
    private var namingDirect = false
    /// The worktree is being made: the fields are off until it's done.
    private(set) var isCreating = false
    /// The error under the fields, when the last try failed.
    private(set) var namingError: String?

    static let namePlaceholder = "Branch name for the new worktree"
    static let creatingWords = "Creating the worktree… A big repository can take a couple of minutes."

    private func buildNamingBox() {
        baseField.placeholderString = "HEAD"
        baseField.font = .systemFont(ofSize: s(13))
        baseField.delegate = self
        baseField.setAccessibilityLabel("Base, optional: a branch, tag or commit")
        baseField.lineBreakMode = .byTruncatingTail
        baseField.cell?.usesSingleLineMode = true
        let baseLabel = NSTextField(labelWithString: "Base (optional)")
        baseLabel.font = .systemFont(ofSize: s(12))
        baseLabel.textColor = Theme.dimText
        baseLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        baseLabel.setContentHuggingPriority(.required, for: .horizontal)
        let baseRow = NSStackView(views: [baseLabel, baseField])
        baseRow.orientation = .horizontal
        baseRow.spacing = s(8)
        namingPreview.font = .systemFont(ofSize: s(12))
        namingPreview.textColor = Theme.secondaryText
        namingPreview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        namingStatus.font = .systemFont(ofSize: s(12))
        namingStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        namingSpinner.style = .spinning
        namingSpinner.controlSize = .small
        namingSpinner.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [namingSpinner, namingStatus])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = s(8)
        namingBox.orientation = .vertical
        namingBox.alignment = .leading
        namingBox.spacing = s(8)
        namingBox.edgeInsets = NSEdgeInsets(top: s(12), left: s(16), bottom: s(12), right: s(16))
        for view in [baseRow, namingPreview, statusRow] as [NSView] {
            namingBox.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: namingBox.widthAnchor, constant: -s(32)).isActive = true
        }
        namingBox.isHidden = true
    }

    /// Turns the bar into the prompt for a worktree's name. `name` and `base` prefill it (Edit… after a
    /// failed try).
    func beginNaming(_ subject: WorktreeSubject, direct: Bool, name: String = "", base: String = "") {
        endPick()
        naming = subject
        namingDirect = direct
        namingError = nil
        field.stringValue = name
        field.placeholderString = Self.namePlaceholder
        field.setAccessibilityLabel("Worktree branch name")
        baseField.stringValue = base
        baseField.placeholderString = "HEAD of \(subject.git.place)"
        fieldIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        list.isHidden = true
        namingBox.isHidden = false
        // The base is reached with Tab from the name, and the name with Tab from the base.
        field.nextKeyView = baseField
        baseField.nextKeyView = field
        renderNaming()
        window?.makeFirstResponder(field)
    }

    private func endNaming() {
        naming = nil
        namingDirect = false
        namingError = nil
        isCreating = false
        field.isEnabled = true
        baseField.isEnabled = true
        field.placeholderString = Self.placeholder
        field.setAccessibilityLabel(nil)
        fieldIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        namingBox.isHidden = true
        list.isHidden = false
        window?.makeFirstResponder(field)
    }

    /// The name and the base as typed (the base nil when left empty).
    var worktreeEntry: (name: String, base: String?) {
        let base = baseField.stringValue.trimmingCharacters(in: .whitespaces)
        return (field.stringValue.trimmingCharacters(in: .whitespaces), base.isEmpty ? nil : base)
    }

    /// Types a name into the prompt (tests and TypeText).
    func setWorktreeName(_ name: String, base: String = "") {
        guard naming != nil else { return }
        field.stringValue = name
        baseField.stringValue = base
        renderNaming()
    }

    /// "Creates ../clotho-fix-login on the new branch fix/login, from HEAD of main."
    static func worktreePreview(_ subject: WorktreeSubject, name: String, base: String?) -> String {
        guard !name.isEmpty else { return "Creates a folder beside \(DiffText.display(subject.repo)) on a new branch, and opens a Tab in it." }
        let folder = "\(subject.repo)-\(name.replacingOccurrences(of: "/", with: "-"))"
        let from = base.map { DiffText.display($0) } ?? "HEAD of \(DiffText.display(subject.git.place))"
        return "Creates ../\(DiffText.display(folder)) on the new branch \(DiffText.display(name)), from \(from)."
    }

    private func renderNaming() {
        guard let naming else { return }
        let entry = worktreeEntry
        namingPreview.stringValue = Self.worktreePreview(naming, name: entry.name, base: entry.base)
        if isCreating {
            namingStatus.stringValue = Self.creatingWords
            namingStatus.textColor = Theme.secondaryText
            namingSpinner.startAnimation(nil)
        } else {
            namingStatus.stringValue = namingError ?? ""
            namingStatus.textColor = Theme.danger
            namingSpinner.stopAnimation(nil)
        }
        namingSpinner.isHidden = !isCreating
        namingStatus.isHidden = namingStatus.stringValue.isEmpty
        namingStatus.setAccessibilityLabel(namingStatus.stringValue)
        field.isEnabled = !isCreating
        baseField.isEnabled = !isCreating
        // The fields just gave the keyboard up: the overlay holds it for Esc (see `keyDown`).
        if isCreating, let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        updateFooter()
        footerEsc.isHidden = true
    }

    /// Keys in the prompt's two fields.
    private func namingCommand(_ control: NSControl, _ selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)): submitWorktree()
        case #selector(cancelOperation(_:)): cancel()
        case #selector(insertTab(_:)), #selector(insertBacktab(_:)):
            window?.makeFirstResponder(control === field ? baseField : field)
        default: return false
        }
        return true
    }

    /// Return: asks the app to make it. An empty name does nothing; the rest is the daemon's to judge.
    func submitWorktree() {
        guard let naming, !isCreating else { return }
        let entry = worktreeEntry
        guard !entry.name.isEmpty else { return NSSound.beep() }
        onCreateWorktree?(naming, entry.name, entry.base)
    }

    /// The app started making the worktree (or finished without closing the bar).
    func setCreating(_ on: Bool) {
        guard naming != nil else { return }
        isCreating = on
        if on { namingError = nil }
        renderNaming()
        if !on { window?.makeFirstResponder(field) }
    }

    /// The try failed: the words under the fields, which are on again with what was typed.
    func showWorktreeError(_ words: String) {
        guard naming != nil else { return }
        isCreating = false
        namingError = words
        renderNaming()
        window?.makeFirstResponder(field)
    }

    // MARK: Drawing

    private func render() {
        if naming != nil { return renderNaming() }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headings = []
        // Command mode and picking keep their own lines; otherwise three hints, and "esc" at the far side.
        let ownLine = isCommandMode || picking != nil
        // Every change of the selection, the rows or the model is drawn here: the one place the request
        // under the selection can change.
        let request = selectedEntry?.request?.id
        if request != target?.id { target = request.map { ($0, Date()) } }
        updateFooter()
        footerEsc.isHidden = ownLine
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
            // A state word: its agents under their own header, the plain matches under another.
            if shown.row == nil, isSearching, stateLead.count > 0, index == 0 || index == stateLead.count {
                let heading = index == 0 ? heading(CommandBar.stateTitle(stateLead.marks), count: stateLead.count, color: Theme.accent)
                    : heading("Matches", color: Theme.dimText)
                list.addArrangedSubview(heading)
                heading.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -s(12)).isActive = true
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
        return heading(text, color: section == .needsYou ? Theme.accent : Theme.dimText, hint: hint)
    }

    /// A header over some rows: its name in capitals, how many rows it has (when given), and a hint at the
    /// trailing side.
    private func heading(_ text: String, count: Int? = nil, color: NSColor, hint: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: s(10.5), weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [label]
        headings.append(text.uppercased() + (count.map { "  \($0)" } ?? ""))
        if let count {
            let number = NSTextField(labelWithString: "\(count)")
            number.font = .monospacedDigitSystemFont(ofSize: s(10.5), weight: .regular)
            number.textColor = Theme.dimText
            views.append(number)
            if hint == nil { views.append(NSView()) }
        }
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

/// One row: the agent's mark (or the kind's icon), the title with the matched letters in the accent colour,
/// one dim line (where it is and the agent's state; a permission request comes first), the pane count, and at the trailing side
/// the git branch and the row's ⌘ number.
final class QuickOpenRow: NSView {
    private let action: () -> Void
    /// The agent's mark at the row's lead, when it has one.
    private(set) var markView: AgentMarkView?
    /// The dim line after the title, when there is something to say.
    private(set) var subtitle: NSTextField?
    /// The trailing group: the branch, then the ⌘ number. More goes in before the number (a change count).
    let trailing = NSStackView()
    /// The branch (its symbol and name) in the trailing group, when the row has one.
    private(set) var branchView: NSStackView?
    private(set) var branchLabel: NSTextField?
    /// The change count after the branch ("+128 −32", or "6 files" when the lines weren't counted).
    private(set) var changesLabel: NSTextField?
    static var branchMaxWidth: CGFloat { s(160) }
    /// On a row with a permission request the branch gets less, so the request shows whole in the card.
    static var branchWidthBesideRequest: CGFloat { s(96) }

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
        if let mark = entry.mark {
            let view = AgentMarkView(mark)
            let holder = NSView()
            holder.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: AgentMarkView.side),
                view.heightAnchor.constraint(equalToConstant: AgentMarkView.side),
            ])
            markView = view
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
        // One dim line: where it is, then what it says. It gives way first, then the branch, then the title.
        // A permission request leads its line, so what ⌥↩ would allow is the last thing cut, and the branch
        // beside it is kept short.
        let place = showPath ? entry.path ?? entry.item.subtitle : nil
        let parts = entry.request != nil ? [entry.detail, place] : [place, entry.detail]
        let line = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !line.isEmpty {
            let label = Self.dim(line, compression: .defaultLow - 2)
            label.toolTip = line
            subtitle = label
            views.append(label)
        }
        if entry.panes > 1 {
            let panes = Self.dim("\(entry.panes) panes", compression: .required)
            views.append(panes)
        }
        views.append(NSView())

        trailing.orientation = .horizontal
        trailing.spacing = s(8)
        trailing.setHuggingPriority(.required, for: .horizontal)
        if let branch = entry.branch, !branch.isEmpty {
            let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?
                .withSymbolConfiguration(.init(pointSize: s(10), weight: .regular)) ?? NSImage())
            icon.contentTintColor = Theme.dimText
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            let name = Self.dim(branch, compression: .defaultLow - 1)
            name.lineBreakMode = .byTruncatingMiddle
            name.toolTip = branch
            let group = NSStackView(views: [icon, name])
            group.orientation = .horizontal
            group.spacing = s(4)
            group.setHuggingPriority(.required, for: .horizontal)
            group.widthAnchor.constraint(lessThanOrEqualToConstant: entry.request != nil ? Self.branchWidthBesideRequest : Self.branchMaxWidth).isActive = true
            trailing.addArrangedSubview(group)
            branchView = group
            branchLabel = name
        }
        // How much changed there, after the branch. Not on a row with a permission request: what ⌥↩ would
        // allow needs the room, and the card is as wide as it gets (VoiceOver still says the count).
        if entry.request == nil, let title = Self.changesTitle(entry.changes) {
            let count = NSTextField(labelWithAttributedString: title)
            count.setContentCompressionResistancePriority(.required, for: .horizontal)
            count.setContentHuggingPriority(.required, for: .horizontal)
            count.toolTip = ChangeCountText.spoken(entry.changes)
            trailing.addArrangedSubview(count)
            changesLabel = count
        }
        // Rows past the ninth keep an empty slot, so every row is the same height.
        let key = Self.dim(shortcut.map { "⌘\($0)" } ?? "", compression: .required)
        key.font = .monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        key.widthAnchor.constraint(greaterThanOrEqualToConstant: s(22)).isActive = true
        trailing.addArrangedSubview(key)
        views.append(trailing)

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

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.accessibilityLabel(entry, place: entry.path ?? entry.item.subtitle))
    }

    /// What VoiceOver says for a row: its title, the agent's state, where it is, and the branch.
    static func accessibilityLabel(_ entry: CommandBarEntry, place: String?) -> String {
        [entry.item.title, entry.mark?.label, place, entry.branch.map { "branch \($0)" }, ChangeCountText.spoken(entry.changes)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "+128" in green and "−32" in red, or "6 files" dim when the lines weren't counted. Nil when
    /// nothing changed or nothing is known.
    static func changesTitle(_ changes: PaneGit.Changes?) -> NSAttributedString? {
        guard let total = changes?.total, total.files > 0 else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: s(11), weight: .regular)
        guard let added = total.added, let removed = total.removed else {
            return NSAttributedString(string: ChangeCountText.files(total.files), attributes: [.font: font, .foregroundColor: Theme.dimText])
        }
        let title = NSMutableAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.success])
        title.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: [.font: font, .foregroundColor: Theme.danger]))
        return title
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func dim(_ text: String, compression: NSLayoutConstraint.Priority) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: s(12))
        label.textColor = Theme.dimText
        label.lineBreakMode = .byTruncatingTail
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
