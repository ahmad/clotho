import ClothoKit
import SwiftUI

/// What one window shows. On a narrow width (iPhone, Slide Over, a narrow Split View) it's a stack of screens;
/// on a regular width (iPad full screen or a wide split) a sidebar of machines, workspaces and agents next to
/// the selected machine or tab. Both layouts read the same state, so resizing the window keeps the place.
@MainActor
final class Navigator: ObservableObject {
    /// The stack on narrow widths.
    @Published var path: [Route] = []
    /// The sidebar's selection on regular widths.
    @Published var selection: SidebarItem?
    /// The pane to show first when a tab opens (from an agent or a notification).
    var initialPane: PaneID?
    /// The welcome guide, or only its machine setup (the + button).
    @Published var guide: OnboardingView.Mode?
    /// Quick open (⌘P, or the search button).
    @Published var quickOpen = false
    var regular = false

    /// The machine on screen, if any.
    var focusedMachine: UUID? {
        if regular {
            switch selection {
            case .machine(let id), .tab(let id, _): return id
            case nil: return nil
            }
        }
        switch path.last {
        case .machine(let id), .pane(let id, _, _): return id
        case nil: return nil
        }
    }

    /// The tab on screen, if any.
    var focusedTab: TabID? {
        if regular {
            if case .tab(_, let tab) = selection { return tab }
            return nil
        }
        if case .pane(_, let tab, _) = path.last { return tab }
        return nil
    }

    func open(_ route: Route) {
        switch route {
        case .machine(let id):
            initialPane = nil
            if regular { selection = .machine(id) } else { path = [route] }
        case .pane(let id, let tab, let pane):
            initialPane = pane
            if regular { selection = .tab(id, tab) } else { path = [route] }
        }
    }

    /// Carries the place over when the width class changes (rotation, Split View, Stage Manager).
    func switchLayout(regular: Bool) {
        guard regular != self.regular else { return }
        self.regular = regular
        if regular {
            switch path.last {
            case .machine(let id): selection = .machine(id)
            case .pane(let id, let tab, let pane): initialPane = pane; selection = .tab(id, tab)
            case nil: break
            }
        } else {
            switch selection {
            case .machine(let id): path = [.machine(id)]
            case .tab(let id, let tab): path = [.pane(id, tab, initialPane ?? 0)]
            case nil: path = []
            }
        }
    }
}

enum SidebarItem: Hashable {
    case machine(UUID)
    case tab(UUID, TabID)
}

enum Route: Hashable {
    case machine(UUID)
    case pane(UUID, TabID, PaneID)
}

extension OnboardingView.Mode: Identifiable {
    var id: Self { self }
}

struct RootView: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var navigator = Navigator()

    var body: some View {
        Group {
            if sizeClass == .regular { SplitRootView() } else { HomeView() }
        }
        .environmentObject(navigator)
        .onAppear { navigator.switchLayout(regular: sizeClass == .regular) }
        .onChange(of: sizeClass) { _, size in navigator.switchLayout(regular: size == .regular) }
        .onAppear {
            AgentNotifier.shared.onOpen = { machine, pane in openPane(machine: machine, pane: pane) }
            AgentNotifier.shared.isLive = { [connections] id in connections.existing(id)?.store.isConnected == true }
            AgentNotifier.shared.onAction = { [machines, connections] action in
                await AlertActionRunner.run(action, machines: machines, connections: connections)
            }
        }
        .fullScreenCover(item: $navigator.guide) { mode in
            OnboardingView(mode: mode) { opened in
                navigator.guide = nil
                AgentNotifier.shared.deferPrompt = false
                // The guide no longer asks: right after it, with a machine set up, is the moment.
                AgentNotifier.shared.promptIfUndecided()
                // On the iPad the sidebar selects it; on the iPhone, Home already shows it.
                if let opened, navigator.regular { navigator.open(.machine(opened)) }
            }
            .environmentObject(machines)
            .environmentObject(connections)
            .onAppear { AgentNotifier.shared.deferPrompt = true }
        }
        .sheet(isPresented: $navigator.quickOpen) {
            QuickOpenView(focusedMachine: navigator.focusedMachine, focusedTab: navigator.focusedTab, open: { route in
                navigator.quickOpen = false
                navigator.open(route)
            }, home: {
                navigator.quickOpen = false
                if navigator.regular {
                    if let machine = navigator.focusedMachine { navigator.selection = .machine(machine) }
                } else {
                    navigator.path = []
                }
            })
            .environmentObject(machines)
            .environmentObject(connections)
        }
        .background {
            // ⌘P anywhere in the window.
            Button("Quick Open") { navigator.quickOpen = true }
                .keyboardShortcut("p", modifiers: .command)
                .hidden()
        }
        // From the widget: clotho://pane/<machine>/<pane> opens that pane; anything else, Home.
        .onOpenURL { url in
            let parts = url.pathComponents.filter { $0 != "/" }
            if url.host == "pane", parts.count == 2, let machine = UUID(uuidString: parts[0]), let pane = PaneID(parts[1]) {
                openPane(machine: machine, pane: pane)
            } else {
                navigator.path = []
            }
        }
        .task {
            if navigator.guide == nil, Onboarding.showsAtLaunch(savedMachines: machines.machines.count) {
                AgentNotifier.shared.deferPrompt = true
                navigator.guide = .firstRun
            }
        }
    }

    /// From a notification: the machine may not be connected yet, so wait for its model. Opening doesn't
    /// resolve the agent.
    private func openPane(machine id: UUID, pane: PaneID) {
        guard let machine = machines.machine(id) else { return }
        let connection = connections.connection(for: machine)
        connection.connect()
        Task {
            for _ in 0..<50 {
                if let tab = connection.store.state.location(of: pane)?.tab {
                    navigator.open(.pane(id, tab.id, pane))
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// The regular-width layout: machines with their workspaces and tabs (and the agents) in a sidebar, the
/// selected machine or tab beside it.
struct SplitRootView: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @EnvironmentObject private var navigator: Navigator
    @State private var editing: Machine?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $navigator.selection) {
                AgentsSection(rows: connections.agentRows, connections: connections) { row in
                    navigator.open(.pane(row.machineID, row.tab, row.pane))
                }
                ForEach(machines.all) { machine in
                    SidebarMachine(machine: machine, connection: connections.connection(for: machine), editing: $editing)
                }
            }
            .listStyle(.sidebar)
            .refreshable { await connections.refresh(machines.all) }
            .navigationTitle("Clotho")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { navigator.quickOpen = true } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                    Button { navigator.guide = .addMachine } label: { Label("Add machine", systemImage: "plus") }
                }
                // One menu, so the sidebar's title keeps its room.
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { navigator.guide = .firstRun } label: { Label("Welcome Guide", systemImage: "questionmark.circle") }
                        AppearancePicker()
                        KeepPreviewsToggle()
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            NavigationStack {
                detail
            }
            .id(navigator.selection)
        }
        .sheet(item: $editing) { machine in
            MachineEditor(machine: machine) { machines.save($0) }
        }
        .background {
            Button("Toggle Sidebar") {
                withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .hidden()
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigator.selection {
        case .machine(let id):
            if let machine = machines.machine(id) {
                MachineView(connection: connections.connection(for: machine)) { tab in
                    navigator.open(.pane(id, tab, 0))
                }
            }
        case .tab(let id, let tab):
            if let machine = machines.machine(id) {
                let connection = connections.connection(for: machine)
                PaneScreen(connection: connection, initialTab: tab, initialPane: navigator.initialPane,
                           onTabChange: { navigator.initialPane = nil; navigator.selection = .tab(id, $0) },
                           onTabGone: { navigator.selection = .machine(id) })
                    .onAppear { connection.connect() }
            }
        case nil:
            ContentUnavailableView {
                Label("Choose a tab", systemImage: "sidebar.left")
            } description: {
                Text(machines.all.isEmpty ? "Add a machine to start." : "Pick a machine or one of its tabs in the sidebar, or press ⌘P to find one.")
            } actions: {
                if machines.all.isEmpty { Button("Add a Machine") { navigator.guide = .addMachine }.buttonStyle(.borderedProminent) }
            }
        }
    }
}

/// One machine in the sidebar: its row (selects the machine), then each workspace's tabs once connected.
private struct SidebarMachine: View {
    let machine: Machine
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @Binding var editing: Machine?
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @SceneStorage private var expanded: Bool

    init(machine: Machine, connection: MachineConnection, editing: Binding<Machine?>) {
        self.machine = machine
        self.connection = connection
        store = connection.store
        _editing = editing
        _expanded = SceneStorage(wrappedValue: true, "SidebarExpanded-\(machine.id)")
    }

    var body: some View {
        Section(isExpanded: $expanded) {
            NavigationLink(value: SidebarItem.machine(machine.id)) {
                Label {
                    HStack {
                        Text("Overview")
                        Spacer()
                        ConnectionDot(connection: connection)
                    }
                } icon: {
                    Image(systemName: machine.kind == .localSocket ? "laptopcomputer" : "server.rack")
                }
            }
            .contextMenu { machineMenu }
            ForEach(store.state.workspaces) { workspace in
                let current = workspace.id == store.focusedWorkspace?.id
                Text(workspace.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(current ? Color.selection : .secondary)
                    .padding(.top, 4)
                    .selectionDisabled()
                    .accessibilityLabel(current ? "\(workspace.name), current" : workspace.name)
                ForEach(workspace.tabs) { tab in
                    NavigationLink(value: SidebarItem.tab(machine.id, tab.id)) {
                        Label(store.displayTitle(of: tab),
                              systemImage: tab.layout.panes.count > 1 ? "rectangle.split.2x1" : "terminal")
                            .lineLimit(1)
                    }
                    .contextMenu {
                        Button(role: .destructive) { connection.run("Close tab") { try await $0.closeTab(tab.id) } } label: {
                            Label("Close Tab", systemImage: "xmark")
                        }
                    }
                }
            }
        } header: {
            Text(machine.displayName)
                .contextMenu { machineMenu }
        }
        .onAppear { connection.connect() }
    }

    @ViewBuilder private var machineMenu: some View {
        if machine.kind == .ssh {
            Button { editing = machine } label: { Label("Edit", systemImage: "pencil") }
            Button { connections.disconnect(machine) } label: {
                Label(machine.devDirs == true ? "Disconnect and remove test clothod" : "Disconnect", systemImage: "bolt.horizontal.circle")
            }
            Button(role: .destructive) {
                connections.forget(machine.id)
                machines.delete(machine.id)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
