import ClothoKit
import SwiftUI

/// One thing quick open can jump to: ClothoKit's item (matched and ranked the same way as on the Mac) plus
/// where it goes and how it looks here.
struct QuickOpenEntry: Identifiable {
    var item: QuickOpenItem
    var symbol: String
    var route: Route
    /// The same place in ⌘P's tree (Tab leaves the search there).
    var node: CommandTree.Node
    var id: String { item.id }

    /// In the Mac's order, which an empty query keeps: agents that need the user, then the focused machine's
    /// workspaces and tabs, then other machines' workspaces and tabs, then the machines.
    @MainActor static func all(machines: [Machine], connections: Connections, focused: UUID?) -> [QuickOpenEntry] {
        var entries: [QuickOpenEntry] = []
        for row in connections.agentRows where row.wantsAttention {
            entries.append(QuickOpenEntry(
                item: QuickOpenItem(kind: .agent, title: row.title,
                                    subtitle: "\(row.info.state.rawValue.capitalized) · \(row.machineName) › \(row.workspace)",
                                    id: "a\(row.machineID)-\(row.pane)"),
                symbol: "sparkles", route: .pane(row.machineID, row.tab, row.pane),
                node: .agent(machine: QuickOpenTree.key(row.machineID), pane: row.pane)))
        }
        let ordered = machines.filter { $0.id == focused } + machines.filter { $0.id != focused }
        var tabs: [QuickOpenEntry] = []
        for machine in ordered {
            guard let store = connections.existing(machine.id)?.store else { continue }
            for workspace in store.state.workspaces {
                if let first = workspace.tabs.first {
                    entries.append(QuickOpenEntry(
                        item: QuickOpenItem(kind: .workspace, title: workspace.name, subtitle: machine.displayName,
                                            id: "w\(machine.id)-\(workspace.id)"),
                        symbol: "folder", route: .pane(machine.id, first.id, first.activePane),
                        node: .workspace(machine: QuickOpenTree.key(machine.id), workspace.id)))
                }
                for tab in workspace.tabs {
                    tabs.append(QuickOpenEntry(
                        item: QuickOpenItem(kind: .tab, title: store.displayTitle(of: tab),
                                            subtitle: "\(machine.displayName) › \(workspace.name)",
                                            id: "t\(machine.id)-\(tab.id)"),
                        symbol: tab.layout.panes.count > 1 ? "rectangle.split.2x1" : "terminal",
                        route: .pane(machine.id, tab.id, tab.activePane),
                        node: .tab(machine: QuickOpenTree.key(machine.id), tab.id)))
                }
            }
            // Each machine's workspaces, then its tabs, before the next machine's.
            entries += tabs
            tabs = []
        }
        for machine in machines {
            entries.append(QuickOpenEntry(
                item: QuickOpenItem(kind: .machine, title: machine.displayName, subtitle: machine.subtitle, id: "m\(machine.id)"),
                symbol: machine.kind == .localSocket ? "laptopcomputer" : "server.rack", route: .machine(machine.id),
                node: .machine(QuickOpenTree.key(machine.id))))
        }
        return entries
    }

    /// The matches for `query`, best first, with the matched letters of each title.
    static func ranked(_ entries: [QuickOpenEntry], query: String) -> [(entry: QuickOpenEntry, indices: [Int])] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return QuickOpen.rank(entries.map(\.item), query: query).compactMap { result in
            byID[result.item.id].map { ($0, result.titleIndices) }
        }
    }

    /// The title with the matched letters in bold.
    static func highlighted(_ title: String, _ indices: [Int]) -> AttributedString {
        var text = AttributedString()
        let marked = Set(indices)
        for (offset, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(offset) {
                piece.font = .body.bold()
                piece.foregroundColor = .selection
            }
            text += piece
        }
        return text
    }
}

/// ⌘P, or the search button. With nothing typed, the tree (QuickOpenTree.swift); typing finds any tab,
/// workspace, machine or waiting agent by name, flat, each with where it is.
struct QuickOpenView: View {
    /// The machine on screen, whose workspaces and tabs come first.
    var focusedMachine: UUID?
    /// The tab on screen, selected in the tree.
    var focusedTab: TabID?
    let open: (Route) -> Void
    /// Open Machines: back to the machine list.
    var home: () -> Void = {}
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @State private var tree: CommandTree?
    /// A machine a tap is connecting: it opens to its workspaces once they arrive.
    @State private var connecting: String?
    /// ">" typed: the commands for the row selected in the tree.
    @State private var commandSelected = 0
    /// Move Tab waits for a workspace picked in the tree.
    @State private var picking: (item: CommandListItem, subject: CommandTree.Node)?
    @State private var renaming: Renaming?
    @State private var newName = ""
    @State private var files: FilesTarget?
    /// The pane on screen as quick open opened (Open Beside puts tabs next to it).
    @State private var origin: QuickOpenCommands.Origin?

    struct Renaming { var current: String; var apply: (String) -> Void }
    struct FilesTarget: Hashable {
        let machine: UUID
        let path: String
    }

    private var commandText: String? { picking == nil ? CommandList.commandQuery(query) : nil }

    var body: some View {
        let commands = commandText.map { CommandList.matching(commandItems, query: $0) } ?? []
        let results = query.isEmpty || commandText != nil ? [] : QuickOpenEntry.ranked(QuickOpenEntry.all(machines: machines.all, connections: connections, focused: focusedMachine), query: query)
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let picking {
                        pickHeader(picking)
                        treeSections
                    } else if commandText != nil {
                        commandRows(commands)
                    } else if query.isEmpty {
                        treeSections
                    } else {
                        searchRows(results)
                    }
                }
                .onChange(of: tree?.selection) { _, node in
                    if let node, query.isEmpty { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(node, anchor: nil) } }
                }
            }
            .overlay {
                if commandText != nil, commands.isEmpty {
                    ContentUnavailableView("No Commands", systemImage: "command")
                } else if commandText == nil, !query.isEmpty, results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    QuickOpenField(text: $query) { key(key: $0, results: results, commands: commands) }
                        .frame(height: 22)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .onChange(of: query) { highlighted = 0; commandSelected = 0 }
            .navigationTitle("Quick Open")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    // The touch way to ">": the commands for the selected row.
                    Button { picking = nil; query = ">" } label: { Label("Commands", systemImage: "command") }
                        .accessibilityIdentifier("commands")
                }
            }
            .navigationDestination(item: $files) { target in
                if let connection = connections.existing(target.machine) {
                    FileBrowserView(connection: connection, path: target.path)
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                    .accessibilityIdentifier("renameField")
                Button("Rename") {
                    let apply = renaming?.apply
                    renaming = nil
                    apply?(newName)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .onAppear {
            if tree == nil { startTree() }
            origin = QuickOpenCommands.origin(machine: focusedMachine, tab: focusedTab, connections: connections)
        }
        .onReceive(connections.modelChanged) { updateTree() }
        .task {
            await connections.refresh(machines.all)
            updateTree()
        }
    }

    // MARK: Tree

    @ViewBuilder private var treeSections: some View {
        if let tree {
            let rows = tree.rows
            let needsYou = rows.indices.filter { rows[$0].section == .needsYou }
            let rest = rows.indices.filter { rows[$0].section == .tree }
            if !needsYou.isEmpty {
                Section("Needs you") {
                    ForEach(needsYou, id: \.self) { treeRow(rows, $0) }
                }
            }
            Section {
                ForEach(rest, id: \.self) { treeRow(rows, $0) }
                if rest.isEmpty, case .machine = tree.scope {
                    Text("No workspaces").foregroundStyle(.secondary)
                }
            } header: {
                scopeHeader(tree.scope)
            }
        }
    }

    private func treeRow(_ rows: [CommandTree.Row], _ index: Int) -> some View {
        let row = rows[index]
        let selected = index == tree?.selectedIndex
        return QuickOpenTreeRow(row: row, display: QuickOpenTree.display(row.node, machines: machines.all, connections: connections),
                                selected: selected,
                                activate: { activate(index) },
                                toggle: { toggle(index) })
            .id(row.node)
            .opacity(picking.map { canTake(row.node, $0.subject) } == false ? 0.4 : 1)
            .listRowBackground(selected ? Color.selection.opacity(0.22) : nil)
            .swipeActions(allowsFullSwipe: false) { rowActions(row.node) }
            .contextMenu {
                rowActions(row.node)
                // The touch way to the ">" commands for a row other than the selected one.
                Button { commands(for: index) } label: { Label("Commands…", systemImage: "command") }
            }
    }

    @ViewBuilder private func scopeHeader(_ scope: CommandTree.Scope) -> some View {
        switch scope {
        case .machine(let key):
            HStack {
                // Only with somewhere to go: with one machine, its workspaces are everything.
                if machines.all.count > 1 {
                    Button { tree?.showMachines() } label: {
                        Label("All machines", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .font(.subheadline)
                    .textCase(nil)
                    .accessibilityIdentifier("allMachines")
                }
                Spacer()
                Text(machines.all.first { QuickOpenTree.key($0.id) == key }?.displayName ?? "")
            }
        case .machines:
            Text("Machines")
        }
    }

    /// Close and New Tab on a row, by swipe or a long press (closing takes a deliberate tap, as on Home).
    @ViewBuilder private func rowActions(_ node: CommandTree.Node) -> some View {
        if let id = UUID(uuidString: node.machine), let connection = connections.existing(id), connection.store.isConnected {
            switch node {
            case let .tab(_, tab):
                Button(role: .destructive) { connection.run("Close tab") { try await $0.closeTab(tab) } } label: {
                    Label("Close Tab", systemImage: "xmark")
                }
            case let .workspace(_, workspace):
                Button(role: .destructive) { connection.run("Close workspace") { try await $0.closeWorkspace(workspace) } } label: {
                    Label("Close Workspace", systemImage: "xmark")
                }
                Button { newTab(on: connection, in: workspace) } label: { Label("New Tab", systemImage: "plus") }
                    .tint(.selection)
            case .machine:
                if let workspace = connection.store.focusedWorkspace?.id {
                    Button { newTab(on: connection, in: workspace) } label: { Label("New Tab", systemImage: "plus") }
                        .tint(.selection)
                }
            case .agent:
                EmptyView()
            }
        }
    }

    private func newTab(on connection: MachineConnection, in workspace: WorkspaceID) {
        let id = connection.machine.id
        connection.run("New tab") { backend in
            let created = try await backend.createTab(in: workspace)
            await MainActor.run { open(.pane(id, created.tab, created.pane)) }
        }
    }

    private func startTree() {
        tree = QuickOpenTree.start(machines: machines.all, connections: connections, focused: focusedMachine, tab: focusedTab)
    }

    private func updateTree() {
        guard var current = tree else { return startTree() }
        current.update(QuickOpenTree.outline(machines: machines.all, connections: connections))
        // A machine a tap connected opens to its workspaces as they arrive.
        if let key = connecting, let index = current.rows.firstIndex(where: { $0.node == .machine(key) }),
           current.rows[index].expandable || connections.existing(UUID(uuidString: key) ?? UUID())?.store.isConnected == true {
            connecting = nil
            current.select(index)
            if case .open(let node) = current.activate() { go(node) }
        }
        if current != tree { tree = current }
    }

    private func activate(_ index: Int) {
        guard var current = tree else { return }
        if let picking, current.rows.indices.contains(index) {
            let node = current.rows[index].node
            if case .workspace = node {
                guard QuickOpenCommands.move(tab: picking.subject, to: node, connections: connections) else { return }
                self.picking = nil
                return dismiss()
            }
            // A machine opens to its workspaces; anything else can't take the tab.
            guard case .machine = node else { return }
        }
        current.select(index)
        let result = current.activate()
        tree = current
        switch result {
        case .open(let node): go(node)
        case .connect(let key):
            guard let machine = machines.all.first(where: { QuickOpenTree.key($0.id) == key }) else { return }
            connecting = key
            connections.connection(for: machine).connect()
        case .expanded, .nothing: break
        }
    }

    private func toggle(_ index: Int) {
        guard var current = tree, current.rows.indices.contains(index) else { return }
        let row = current.rows[index]
        current.select(index)
        if row.expanded { current.collapse() } else { current.expand() }
        tree = current
    }

    private func go(_ node: CommandTree.Node) {
        if let route = QuickOpenTree.route(node, connections: connections) { open(route) }
    }

    // MARK: Commands

    private var commandItems: [CommandListItem] {
        let context = QuickOpenCommands.context(for: tree?.selection, machines: machines.all, connections: connections, origin: origin)
        return CommandList.items(for: context, supported: QuickOpenCommands.supported)
    }

    @ViewBuilder private func commandRows(_ commands: [CommandListItem]) -> some View {
        Section {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, item in
                Button { run(item) } label: {
                    Label(item.title, systemImage: QuickOpenCommands.symbol(for: item.id))
                }
                .tint(.primary)
                .listRowBackground(index == commandSelected ? Color.selection.opacity(0.22) : nil)
                .accessibilityAddTraits(index == commandSelected ? .isSelected : [])
                .accessibilityIdentifier("command")
            }
        } header: {
            if let node = tree?.selection {
                Text("For \(QuickOpenTree.display(node, machines: machines.all, connections: connections).title)").textCase(nil)
            }
        }
    }

    private func pickHeader(_ picking: (item: CommandListItem, subject: CommandTree.Node)) -> some View {
        Section {
            HStack {
                Label("Pick a workspace on the same machine", systemImage: "arrow.right.square").font(.callout)
                Spacer()
                Button("Cancel") { self.picking = nil }.buttonStyle(.borderless).accessibilityIdentifier("cancelPick")
            }
        } header: {
            Text(picking.item.title).textCase(nil)
        }
    }

    /// While picking where a tab goes: another workspace on its machine, or its machine (to open it).
    private func canTake(_ node: CommandTree.Node, _ subject: CommandTree.Node) -> Bool {
        switch node {
        case let .workspace(machine, id):
            return machine == subject.machine && QuickOpenCommands.place(subject, connections: connections).workspace != id
        case let .machine(machine): return machine == subject.machine
        case .tab, .agent: return false
        }
    }

    /// ">" for row `index`: selects it and lists its commands.
    private func commands(for index: Int) {
        guard var current = tree else { return }
        current.select(index)
        tree = current
        picking = nil
        query = ">"
    }

    private func run(_ item: CommandListItem) {
        let subject = tree?.selection
        switch QuickOpenCommands.run(item, subject: subject, machines: machines.all, connections: connections, origin: origin, open: open) {
        case .open(let route): open(route)
        case .close: dismiss()
        case .home: home()
        case .pickWorkspace:
            guard let subject else { return }
            query = ""
            picking = (item, subject)
        case .rename(let current, let apply):
            newName = current
            renaming = Renaming(current: current, apply: apply)
        case .files(let connection, let path):
            files = FilesTarget(machine: connection.machine.id, path: path)
        case .nothing:
            break
        }
    }

    // MARK: Search

    @ViewBuilder private func searchRows(_ results: [(entry: QuickOpenEntry, indices: [Int])]) -> some View {
        ForEach(Array(results.enumerated()), id: \.element.entry.id) { index, result in
            let entry = result.entry
            Button { open(entry.route) } label: {
                HStack(spacing: 12) {
                    Image(systemName: entry.symbol).foregroundStyle(Color.selection).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(QuickOpenEntry.highlighted(entry.item.title, result.indices)).lineLimit(1)
                        Text(entry.item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .tint(.primary)
            .listRowBackground(index == highlighted ? Color.selection.opacity(0.22) : nil)
            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
        }
    }

    // MARK: Keys

    private func key(key: QuickOpenKey, results: [(entry: QuickOpenEntry, indices: [Int])], commands: [CommandListItem]) {
        if key == .escape {
            // Back out of a pick or the commands first.
            if picking != nil { picking = nil; return }
            if commandText != nil { query = ""; return }
            return dismiss()
        }
        if key == .openBeside {
            guard let item = commandItems.first(where: { $0.id == .openBeside }) else { return }
            return run(item)
        }
        if commandText != nil {
            switch key {
            case .move(let by): commandSelected = min(max(commandSelected + by, 0), max(commands.count - 1, 0))
            case .activate: if commands.indices.contains(commandSelected) { run(commands[commandSelected]) }
            case .number(let n): if commands.indices.contains(n - 1) { run(commands[n - 1]) }
            default: break
            }
            return
        }
        if query.isEmpty {
            guard var current = tree else { return }
            switch key {
            case .move(let by): current.move(by)
            case .expand, .tab: current.expand()
            case .collapse, .backTab: current.collapse()
            case .activate:
                tree = current
                if let index = current.selectedIndex { activate(index) }
                return
            case .number(let n):
                tree = current
                if current.rows.indices.contains(n - 1) { activate(n - 1) }
                return
            case .escape, .openBeside: break
            }
            tree = current
            return
        }
        switch key {
        case .move(let by): highlighted = min(max(highlighted + by, 0), max(results.count - 1, 0))
        case .activate: if results.indices.contains(highlighted) { open(results[highlighted].entry.route) }
        case .number(let n): if results.indices.contains(n - 1) { open(results[n - 1].entry.route) }
        case .tab, .backTab:
            // Leave the search at that row in the tree (Tab), or at its parent (⇧Tab).
            guard results.indices.contains(highlighted), var current = tree else { return }
            let node = results[highlighted].entry.node
            if key == .tab { current.reveal(node) } else { current.revealParent(of: node) }
            tree = current
            query = ""
        case .expand, .collapse, .escape, .openBeside: break
        }
    }
}
