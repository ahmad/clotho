import ClothoKit
import SwiftUI

/// Quick open's commands, typed after ">" (the Mac's ⌘P phase 2): ClothoKit's CommandList for the row
/// selected in the tree, run here. The phone leaves out what it doesn't have: a Settings window, a sidebar
/// to toggle, and (until the machine switch comes to iOS) turning machines on and off.
@MainActor
enum QuickOpenCommands {
    static let supported: Set<CommandListItem.ID> = [
        .newTab, .newWorkspace, .closeTab, .closeWorkspace, .splitRight, .splitDown,
        .claudeHere, .codexHere, .resumeClaude, .rename, .moveTab, .openBeside,
        .files, .machines, .appearanceSystem, .appearanceLight, .appearanceDark, .reconnect,
    ]

    /// Where Open Beside puts a tab: the pane on screen when quick open opened.
    struct Origin: Equatable {
        var machine: UUID
        var tab: TabID
        var pane: PaneID
    }

    /// The pane on screen: the focused tab's active pane.
    static func origin(machine: UUID?, tab: TabID?, connections: Connections) -> Origin? {
        guard let machine, let tab, let store = connections.existing(machine)?.store,
              let shown = store.state.workspaces.flatMap(\.tabs).first(where: { $0.id == tab }) else { return nil }
        return Origin(machine: machine, tab: tab, pane: shown.activePane)
    }

    /// A row's workspace and tab: a tab's own, an agent's, a workspace's (no tab); a machine's current workspace.
    static func place(_ node: CommandTree.Node?, connections: Connections) -> (workspace: WorkspaceID?, tab: TabID?) {
        guard let node, let id = UUID(uuidString: node.machine), let store = connections.existing(id)?.store else { return (nil, nil) }
        return place(node, state: store.state, focusedWorkspace: store.focusedWorkspace?.id)
    }

    nonisolated static func place(_ node: CommandTree.Node, state: ModelState, focusedWorkspace: WorkspaceID?) -> (workspace: WorkspaceID?, tab: TabID?) {
        switch node {
        case let .tab(_, id): return (state.workspaces.first { $0.tabs.contains { $0.id == id } }?.id, id)
        case let .workspace(_, id): return (id, nil)
        case let .agent(_, pane):
            let workspace = state.workspaces.first { $0.tabs.contains { $0.layout.panes.contains(pane) } }
            return (workspace?.id, workspace?.tabs.first { $0.layout.panes.contains(pane) }?.id)
        case .machine: return (focusedWorkspace, nil)
        }
    }

    /// The commands' context for the selected row (none selected: the first machine).
    static func context(for node: CommandTree.Node?, machines: [Machine], connections: Connections, origin: Origin?) -> CommandContext {
        guard let key = node?.machine ?? machines.first.map({ QuickOpenTree.key($0.id) }),
              let machine = machines.first(where: { QuickOpenTree.key($0.id) == key }) else { return CommandContext(connected: false) }
        let connection = connections.existing(machine.id)
        let store = connection?.store
        var context = CommandContext(machine: key, machineName: machine.displayName, connected: store?.isConnected == true,
                                     enabled: true, isLocal: machine.kind == .localSocket,
                                     unreachable: connection?.cantReach == true)
        let (workspace, tab) = place(node, connections: connections)
        if let workspace, let found = store?.state.workspaces.first(where: { $0.id == workspace }) {
            context.workspace = workspace
            context.workspaceName = found.name
            if let tab, let shown = found.tabs.first(where: { $0.id == tab }), let store {
                context.tab = tab
                context.tabName = store.displayTitle(of: shown)
                context.canOpenBeside = origin?.machine == machine.id && tab != origin?.tab && store.features.contains(.paneMove)
            }
        }
        return context
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

    /// What quick open does after a command.
    enum Outcome {
        /// Close, then go there.
        case open(Route)
        /// Close; the command runs on (its result shows where it is).
        case close
        /// Close and show the machine list (Home).
        case home
        /// Pick a workspace in the tree for Move Tab.
        case pickWorkspace
        /// Ask for a new name, then `apply` it.
        case rename(current: String, apply: (String) -> Void)
        /// Browse the machine's files from this folder (inside quick open).
        case files(MachineConnection, path: String)
        /// Nothing to do (the row went away, say).
        case nothing
    }

    /// Runs `item` for the selected row. Commands that make something go to it; the rest close quick open.
    static func run(_ item: CommandListItem, subject: CommandTree.Node?, machines: [Machine], connections: Connections,
                    origin: Origin?, open: @escaping (Route) -> Void) -> Outcome {
        guard let key = subject?.machine ?? machines.first.map({ QuickOpenTree.key($0.id) }),
              let machine = machines.first(where: { QuickOpenTree.key($0.id) == key }) else { return .nothing }
        let connection = connections.connection(for: machine)
        let store = connection.store
        let (workspace, tab) = place(subject, connections: connections)
        let id = machine.id
        log("quick open: run \(item.id.rawValue) on \(subject.map { "\($0)" } ?? "nothing")")
        switch item.id {
        case .newTab:
            guard let workspace else { return run(CommandListItem(id: .newWorkspace, title: ""), subject: subject, machines: machines,
                                                  connections: connections, origin: origin, open: open) }
            connection.run("New tab") { backend in
                let created = try await backend.createTab(in: workspace)
                await MainActor.run { open(.pane(id, created.tab, created.pane)) }
            }
            return .close
        case .newWorkspace:
            let name = "Workspace \(store.state.workspaces.count + 1)"
            connection.run("New workspace") { backend in
                let created = try await backend.createWorkspace(name: name)
                await MainActor.run { open(.pane(id, created.tab, created.pane)) }
            }
            return .close
        case .closeTab:
            guard let tab else { return .nothing }
            connection.run("Close tab") { try await $0.closeTab(tab) }
            return .close
        case .closeWorkspace:
            guard let workspace else { return .nothing }
            connection.run("Close workspace") { try await $0.closeWorkspace(workspace) }
            return .close
        case .splitRight, .splitDown:
            guard let tab, let shown = store.state.workspaces.flatMap(\.tabs).first(where: { $0.id == tab }) else { return .nothing }
            let direction: Direction = item.id == .splitRight ? .right : .down
            connection.run("Split") { backend in
                let created = try await backend.split(shown.activePane, direction: direction)
                await MainActor.run { open(.pane(id, tab, created.pane)) }
            }
            return .close
        case .claudeHere, .codexHere, .resumeClaude:
            guard let workspace else { return .nothing }
            let command = item.id == .claudeHere ? "claude" : item.id == .codexHere ? "codex" : "claude --continue"
            // In the row's folder: the selected tab's, else the workspace's last active tab's.
            let shown = store.state.workspaces.first { $0.id == workspace }
            let source = shown?.tabs.first { $0.id == tab } ?? shown?.tabs.first { $0.id == shown?.activeTab } ?? shown?.tabs.first
            let cwd = source.flatMap { store.state.pane($0.activePane)?.cwd }
            connection.run(command) { backend in
                let created = try await backend.createTab(in: workspace, spawn: SpawnOptions(cwd: cwd))
                backend.sendInput(created.pane, Data((command + "\r").utf8))
                await MainActor.run { open(.pane(id, created.tab, created.pane)) }
            }
            return .close
        case .rename:
            if let tab, let shown = store.state.workspaces.flatMap(\.tabs).first(where: { $0.id == tab }) {
                return .rename(current: store.displayTitle(of: shown)) { name in
                    connection.run("Rename tab") { try await $0.renameTab(tab, title: name.isEmpty ? nil : name) }
                }
            }
            if let workspace, let shown = store.state.workspaces.first(where: { $0.id == workspace }) {
                return .rename(current: shown.name) { name in
                    guard !name.isEmpty else { return }
                    connection.run("Rename workspace") { try await $0.renameWorkspace(workspace, name: name) }
                }
            }
            return .nothing
        case .moveTab:
            return tab == nil ? .nothing : .pickWorkspace
        case .openBeside:
            guard let tab, let origin, origin.machine == id else { return .nothing }
            Task { @MainActor in
                do {
                    try await store.move(.tabJoin(tab, beside: origin.pane, direction: .right, ratio: nil, focus: true))
                    open(.pane(id, origin.tab, origin.pane))
                } catch {
                    log("[\(machine.displayName)] open beside failed: \(error.localizedDescription)")
                    connection.lastError = "Open beside failed: \(error.localizedDescription)"
                }
            }
            return .close
        case .files:
            let pane = tab.flatMap { tab in store.state.workspaces.flatMap(\.tabs).first { $0.id == tab } }.flatMap { store.state.pane($0.activePane) }
            return .files(connection, path: pane?.cwd ?? "~")
        case .machines:
            return .home
        case .appearanceSystem, .appearanceLight, .appearanceDark:
            let choice: AppearanceChoice = item.id == .appearanceLight ? .light : item.id == .appearanceDark ? .dark : .system
            UserDefaults.standard.set(choice.rawValue, forKey: AppearanceChoice.storageKey)
            AppearanceChoice.applyToAllWindows()
            return .close
        case .reconnect:
            connection.connect()
            connection.reconnect()
            return .close
        case .settings, .toggleSidebar, .machineOn, .machineOff:
            return .nothing
        }
    }

    /// Move Tab, once a workspace is picked: to the end of that workspace (on the tab's own machine).
    static func move(tab subject: CommandTree.Node, to target: CommandTree.Node, connections: Connections) -> Bool {
        guard case let .workspace(key, destination) = target, key == subject.machine,
              let id = UUID(uuidString: key), let connection = connections.existing(id) else { return false }
        let (from, tab) = place(subject, connections: connections)
        guard let tab, from != destination else { return false }
        let store = connection.store
        let index = store.state.workspaces.first { $0.id == destination }?.tabs.count ?? 0
        Task { @MainActor in
            do {
                try await store.move(.tab(tab, workspace: destination, index: index, focus: false))
            } catch {
                log("[\(connection.machine.displayName)] move tab failed: \(error.localizedDescription)")
                connection.lastError = "Move tab failed: \(error.localizedDescription)"
            }
        }
        return true
    }
}
