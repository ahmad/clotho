// ⌘P with nothing typed: a tree to walk with the arrow keys, shared by the Mac and (later) iOS. It holds
// only structure and the keyboard's rules; each app draws the rows and does the jumping.
//
//   Scope .machine(m), where ⌘P starts: "Needs you" (agents waiting or erroring, any machine), then m's
//   workspaces, the current one expanded to its tabs, the others collapsed.
//   Scope .machines, after ← from a collapsed workspace: "Needs you", then every machine; → on a
//   machine shows its workspaces, → on a workspace its tabs.
//
// → expands the selected row (or, when it's already expanded, moves to its first child); ← collapses it,
// moves from a child to its parent, and from a collapsed workspace in a machine's scope goes up to the
// machine list. Return opens a tab, a workspace (the app picks its last active tab) or an agent, and on
// a machine expands it (connects to one that isn't connected, goes to one with no workspaces). Typing leaves the tree alone, so clearing the text comes back to it as it was.

public struct CommandTree: Sendable, Equatable {
    public enum Node: Hashable, Sendable {
        case agent(machine: String, pane: PaneID)
        case machine(String)
        case workspace(machine: String, WorkspaceID)
        case tab(machine: String, TabID)

        public var machine: String {
            switch self {
            case let .agent(machine, _), let .machine(machine), let .workspace(machine, _), let .tab(machine, _): return machine
            }
        }
    }

    /// What the tree is made of: the machines in sidebar order, each with its workspaces and their tabs
    /// (nil for a machine that isn't connected), and the agents that need you, most urgent first.
    public struct Outline: Sendable, Equatable {
        public struct Workspace: Sendable, Equatable {
            public var id: WorkspaceID
            public var tabs: [TabID]
            public init(id: WorkspaceID, tabs: [TabID]) {
                self.id = id
                self.tabs = tabs
            }
        }

        public struct Machine: Sendable, Equatable {
            public var key: String
            public var workspaces: [Workspace]?
            public init(key: String, workspaces: [Workspace]?) {
                self.key = key
                self.workspaces = workspaces
            }
        }

        public var machines: [Machine]
        /// Agents waiting or in error, on any machine.
        public var needsYou: [(machine: String, pane: PaneID)]

        public init(machines: [Machine], needsYou: [(machine: String, pane: PaneID)]) {
            self.machines = machines
            self.needsYou = needsYou
        }

        public static func == (a: Outline, b: Outline) -> Bool {
            a.machines == b.machines && a.needsYou.map(\.machine) == b.needsYou.map(\.machine)
                && a.needsYou.map(\.pane) == b.needsYou.map(\.pane)
        }

        func machine(_ key: String) -> Machine? { machines.first { $0.key == key } }

        func workspace(_ id: WorkspaceID, on key: String) -> Workspace? {
            machine(key)?.workspaces?.first { $0.id == id }
        }

        /// The workspace a tab is in.
        func workspace(of tab: TabID, on key: String) -> Workspace? {
            machine(key)?.workspaces?.first { $0.tabs.contains(tab) }
        }
    }

    public enum Scope: Hashable, Sendable {
        /// One machine's workspaces (where ⌘P starts).
        case machine(String)
        /// Every machine.
        case machines
    }

    public enum Section: Sendable { case needsYou, tree }

    public struct Row: Hashable, Sendable {
        public var node: Node
        public var depth: Int
        public var section: Section
        /// It has children to show (a connected machine, a workspace with tabs).
        public var expandable: Bool
        public var expanded: Bool
    }

    public private(set) var outline: Outline
    public private(set) var scope: Scope
    public private(set) var expanded: Set<Node>
    public private(set) var selection: Node?
    /// Picking a workspace (Move Tab to…): workspaces only, without their tabs and not expandable. A
    /// selected tab gives way to its workspace.
    public var workspacesOnly = false {
        didSet {
            if workspacesOnly, case let .tab(machine, tab) = selection, let workspace = outline.workspace(of: tab, on: machine) {
                selection = .workspace(machine: machine, workspace.id)
            }
            fixSelection()
        }
    }

    /// The tree as ⌘P opens: the focused machine's workspaces with the current one expanded, and the
    /// current tab (else the current workspace) selected.
    public init(outline: Outline, machine: String, workspace: WorkspaceID?, tab: TabID?) {
        self.outline = outline
        scope = .machine(machine)
        expanded = []
        if let workspace { expanded.insert(.workspace(machine: machine, workspace)) }
        if let tab, outline.workspace(of: tab, on: machine) != nil {
            selection = .tab(machine: machine, tab)
        } else if let workspace {
            selection = .workspace(machine: machine, workspace)
        } else {
            selection = nil
        }
        fixSelection()
    }

    // MARK: Rows

    public var rows: [Row] {
        var rows = outline.needsYou.map { Row(node: .agent(machine: $0.machine, pane: $0.pane), depth: 0, section: .needsYou,
                                              expandable: false, expanded: false) }
        func addWorkspaces(of machine: Outline.Machine, depth: Int) {
            for workspace in machine.workspaces ?? [] {
                let node = Node.workspace(machine: machine.key, workspace.id)
                let hasTabs = !workspace.tabs.isEmpty && !workspacesOnly
                let open = expanded.contains(node) && hasTabs
                rows.append(Row(node: node, depth: depth, section: .tree, expandable: hasTabs, expanded: open))
                guard open else { continue }
                for tab in workspace.tabs {
                    rows.append(Row(node: .tab(machine: machine.key, tab), depth: depth + 1, section: .tree, expandable: false, expanded: false))
                }
            }
        }
        switch scope {
        case let .machine(key):
            if let machine = outline.machine(key) { addWorkspaces(of: machine, depth: 0) }
        case .machines:
            for machine in outline.machines {
                let node = Node.machine(machine.key)
                let hasWorkspaces = machine.workspaces?.isEmpty == false
                let open = expanded.contains(node) && hasWorkspaces
                rows.append(Row(node: node, depth: 0, section: .tree, expandable: hasWorkspaces, expanded: open))
                if open { addWorkspaces(of: machine, depth: 1) }
            }
        }
        return rows
    }

    public var selectedIndex: Int? { selection.flatMap { node in rows.firstIndex { $0.node == node } } }

    // MARK: Keys

    /// ↑/↓: the next row, wrapping. Returns the newly selected node.
    @discardableResult
    public mutating func move(_ by: Int) -> Node? {
        let rows = rows
        guard !rows.isEmpty else { return nil }
        let from = selectedIndex ?? (by > 0 ? -1 : rows.count)
        selection = rows[((from + by) % rows.count + rows.count) % rows.count].node
        return selection
    }

    /// The workspace `tab` is in, on `machine`.
    public func workspace(containing tab: TabID, on machine: String) -> WorkspaceID? {
        outline.workspace(of: tab, on: machine)?.id
    }

    /// Selects the first workspace on `machine` other than `except` (else `except` itself), for picking
    /// where a tab goes.
    public mutating func selectFirstWorkspace(on machine: String, except: WorkspaceID?) {
        let workspaces = outline.machine(machine)?.workspaces ?? []
        if let other = workspaces.first(where: { $0.id != except }) {
            selection = .workspace(machine: machine, other.id)
        } else if let except {
            selection = .workspace(machine: machine, except)
        }
        fixSelection()
    }

    /// Selects row `index` (clicks, ⌘1–9).
    public mutating func select(_ index: Int) {
        let rows = rows
        guard rows.indices.contains(index) else { return }
        selection = rows[index].node
    }

    /// →: expands the selected row; when it's already expanded, moves to its first child. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func expand() -> Bool {
        guard let selection, let row = rows.first(where: { $0.node == selection }), row.expandable else { return false }
        if !row.expanded {
            expanded.insert(selection)
            return true
        }
        let rows = rows
        if let index = rows.firstIndex(where: { $0.node == selection }), rows.indices.contains(index + 1),
           rows[index + 1].depth > row.depth {
            self.selection = rows[index + 1].node
            return true
        }
        return false
    }

    /// ←: collapses the selected row, else moves to its parent, else (a workspace in one machine's
    /// scope) goes up to the machine list with that machine selected. Returns whether anything changed.
    @discardableResult
    public mutating func collapse() -> Bool {
        guard let selection else { return false }
        if expanded.contains(selection), rows.first(where: { $0.node == selection })?.expanded == true {
            expanded.remove(selection)
            return true
        }
        switch selection {
        case let .tab(machine, tab):
            guard let workspace = outline.workspace(of: tab, on: machine) else { return false }
            let parent = Node.workspace(machine: machine, workspace.id)
            expanded.remove(parent)
            self.selection = parent
            return true
        case let .workspace(machine, _):
            if scope == .machines {
                expanded.remove(.machine(machine))
            } else {
                scope = .machines
            }
            self.selection = .machine(machine)
            return true
        case .machine, .agent:
            return false
        }
    }

    /// What Return does with the selected row.
    public enum Activation: Equatable, Sendable {
        /// Go there: a tab, a workspace (its last active tab) or an agent's pane.
        case open(Node)
        /// A connected machine expanded to its workspaces.
        case expanded
        /// A machine that isn't connected: the app connects to it.
        case connect(String)
        case nothing
    }

    /// Return.
    public mutating func activate() -> Activation {
        guard let selection else { return .nothing }
        guard case let .machine(key) = selection else { return .open(selection) }
        guard let workspaces = outline.machine(key)?.workspaces else { return .connect(key) }
        // A machine with no workspaces has nothing to expand: go to it (the app shows it).
        guard !workspaces.isEmpty else { return .open(selection) }
        if !expanded.contains(selection) { expanded.insert(selection) }
        return .expanded
    }

    /// Straight to the machine list (a touch UI's "All machines"), with the machine whose workspaces were
    /// showing selected, and the rest of the tree's state kept.
    public mutating func showMachines() {
        guard scope != .machines else { return }
        let machine: String? = if case let .machine(key) = scope { key } else { nil }
        scope = .machines
        selection = machine.map { .machine($0) }
        fixSelection()
    }

    // MARK: Leaving search

    /// Tab on a search result: the tree, at that row, expanded. A tab shows inside its expanded workspace.
    public mutating func reveal(_ node: Node) {
        show(node)
        switch node {
        case .machine, .workspace: expanded.insert(node)
        case .tab, .agent: break
        }
        selection = node
        fixSelection()
    }

    /// ⇧Tab on a search result: the tree, at that row's parent (a tab's workspace, a workspace's machine).
    public mutating func revealParent(of node: Node) {
        switch node {
        case let .tab(machine, tab):
            if let workspace = outline.workspace(of: tab, on: machine) {
                let parent = Node.workspace(machine: machine, workspace.id)
                show(parent)
                selection = parent
            }
        case let .workspace(machine, _):
            scope = .machines
            selection = .machine(machine)
        case .machine, .agent:
            scope = .machines
            selection = node
        }
        fixSelection()
    }

    /// Makes `node` a visible row: switches scope as needed and expands its ancestors.
    private mutating func show(_ node: Node) {
        switch node {
        case let .tab(machine, tab):
            if let workspace = outline.workspace(of: tab, on: machine) {
                show(.workspace(machine: machine, workspace.id))
                expanded.insert(.workspace(machine: machine, workspace.id))
            }
        case let .workspace(machine, _):
            if scope != .machine(machine) {
                if scope == .machines { expanded.insert(.machine(machine)) } else { scope = .machine(machine) }
            }
        case .machine:
            scope = .machines
        case .agent:
            break
        }
    }

    // MARK: Changes

    /// The model changed (a tab closed, a machine connected): keep the place, else the nearest row.
    public mutating func update(_ outline: Outline) {
        guard outline != self.outline else { return }
        let old = self.outline
        let at = selectedIndex
        self.outline = outline
        if case let .machine(key) = scope, outline.machine(key) == nil { scope = .machines }
        if let selection, rows.contains(where: { $0.node == selection }) { return }
        // The selected row went away: a closed tab's workspace if that's still there, else the row now
        // at its place.
        if case let .tab(machine, tab) = selection, let workspace = old.workspace(of: tab, on: machine) {
            let parent = Node.workspace(machine: machine, workspace.id)
            if rows.contains(where: { $0.node == parent }) {
                selection = parent
                return
            }
        }
        let rows = rows
        selection = rows.isEmpty ? nil : rows[min(at ?? 0, rows.count - 1)].node
    }

    private mutating func fixSelection() {
        let rows = rows
        if let selection, rows.contains(where: { $0.node == selection }) { return }
        selection = rows.first(where: { $0.section == .tree })?.node ?? rows.first?.node
    }
}
