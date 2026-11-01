import ClothoKit
import SwiftUI

/// The iPhone's tabs: the agents (and their panes), the machines (and theirs), and the app's settings.
enum AppTab: String, Hashable, CaseIterable {
    case agents, machines, settings
}

/// What one window shows. On a narrow width (iPhone, Slide Over, a narrow Split View) three tabs, Agents,
/// Machines and Settings, the first two each a stack of screens; on a regular width (iPad full screen or a wide
/// split) a sidebar of machines, workspaces and agents next to the selected machine or tab. Both layouts read
/// the same state, so resizing the window keeps the place.
@MainActor
final class Navigator: ObservableObject {
    /// The tab shown on narrow widths, and each list tab's own stack: a pane opened from Agents goes back to Agents.
    @Published var tab: AppTab = .machines {
        didSet { if tab != oldValue { tabChosen = true; UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey) } }
    }
    @Published var agentsPath: [Route] = []
    @Published var machinesPath: [Route] = []
    /// The stack of the tab on screen (Machines' while Settings shows).
    var path: [Route] {
        get { tab == .agents ? agentsPath : machinesPath }
        set {
            if tab == .settings, !newValue.isEmpty { tab = .machines }
            if tab == .agents { agentsPath = newValue } else { machinesPath = newValue }
        }
    }
    static let lastTabKey = "LastTab"
    private var launchDone = false

    /// The agents have had their moment to come in: later ones don't change the tab.
    func launchSettled() { launchDone = true }
    /// Set once the user (or the app) picked a tab, so the launch's choice doesn't override it.
    private(set) var tabChosen = false

    /// The tab a launch starts on: the last one used. Agents instead when an agent needs the user (`launchTab`).
    /// UI tests start on Machines (or `-StartTab agents`), and only `-AutoAgentsTab YES` switches at launch.
    init() {
        let defaults = UserDefaults.standard
        if Self.uiTesting {
            tab = defaults.string(forKey: "StartTab").flatMap(AppTab.init) ?? .machines
        } else {
            tab = defaults.string(forKey: Self.lastTabKey).flatMap(AppTab.init) ?? .machines
        }
    }

    private static var uiTesting: Bool { ProcessInfo.processInfo.arguments.contains("-UITesting") }

    /// At launch, once the machines' agents are known: Agents when any needs the user, unless a tab or a pane
    /// was opened meanwhile.
    func launchTab(needingYou: Int) {
        guard !launchDone, !tabChosen, agentsPath.isEmpty, machinesPath.isEmpty, needingYou > 0 else { return }
        if Self.uiTesting, !UserDefaults.standard.bool(forKey: "AutoAgentsTab") { return }
        tab = .agents
    }
    /// The sidebar's selection on regular widths.
    @Published var selection: SidebarItem?
    /// The pane to show first when a tab opens (from an agent or a notification).
    var initialPane: PaneID?
    /// The welcome guide, or only its machine setup (the + button).
    @Published var guide: OnboardingView.Mode?
    /// The welcome guide on first launch. It is the window's content, not a presentation: a full-screen cover
    /// asked for while a slow launch was still bringing the window up was sometimes dropped, leaving Home.
    @Published var firstRun = false
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
            // On the iPhone, onto the stack of the tab it's opened from (Machines from Settings).
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
            if navigator.firstRun {
                guide(.firstRun)
            } else if sizeClass == .regular { SplitRootView() } else { PhoneTabs() }
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
        .fullScreenCover(item: $navigator.guide) { mode in guide(mode) }
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
            log("launch: guide done \(Onboarding.isDone), \(machines.machines.count) saved machines")
            if navigator.guide == nil, Onboarding.showsAtLaunch(savedMachines: machines.machines.count) {
                AgentNotifier.shared.deferPrompt = true
                navigator.firstRun = true
            }
        }
    }

    /// The guide, in place on first launch or as a cover from the Machines screen.
    private func guide(_ mode: OnboardingView.Mode) -> some View {
        OnboardingView(mode: mode) { opened in
            navigator.guide = nil
            navigator.firstRun = false
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
    @State private var replying: AgentRow?
    @State private var history: AgentRow?
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $navigator.selection) {
                AgentsSection(rows: connections.agentRows, connections: connections, open: { row in
                    navigator.open(.pane(row.machineID, row.tab, row.pane))
                }, replying: $replying, history: $history)
                ForEach(machines.all) { machine in
                    SidebarMachine(machine: machine, connection: connections.connection(for: machine), editing: $editing)
                }
            }
            .listStyle(.sidebar)
            .agentSheets(replying: $replying, history: $history, connections: connections)
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
                        Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
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
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } }
            }
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
