import ClothoKit
import SwiftUI

/// The iPhone's (and any narrow window's) three tabs: Agents, Machines and Settings. Agents and Machines each
/// keep their own stack, so a pane opened from an agent goes Back to Agents. Agents carries a badge with the
/// number of agents that need the user.
struct PhoneTabs: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @EnvironmentObject private var navigator: Navigator

    private var needingYou: Int { connections.agentRows.filter(\.wantsAttention).count }

    var body: some View {
        TabView(selection: $navigator.tab) {
            AgentsTab()
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(AppTab.agents)
                .badge(needingYou)
            HomeView()
                .tabItem { Label("Machines", systemImage: "server.rack") }
                .tag(AppTab.machines)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        // Every machine connects at launch, whichever tab shows first, so its agents (and the badge) are there.
        .onAppear { machines.all.forEach { connections.connection(for: $0).connect() } }
        .onChange(of: needingYou, initial: true) { _, count in navigator.launchTab(needingYou: count) }
        .task {
            // The launch's choice is made only while the agents first come in.
            try? await Task.sleep(for: .seconds(8))
            navigator.launchSettled()
        }
    }
}

/// The Agents tab: agents that need the user, then the rest, on every machine. A row opens its pane on this
/// tab's own stack.
struct AgentsTab: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @EnvironmentObject private var navigator: Navigator
    @State private var replying: AgentRow?
    @State private var history: AgentRow?

    var body: some View {
        NavigationStack(path: $navigator.agentsPath) {
            List {
                AgentsSection(rows: connections.agentRows, connections: connections, open: { row in
                    navigator.open(.pane(row.machineID, row.tab, row.pane))
                }, replying: $replying, history: $history)
            }
            .agentSheets(replying: $replying, history: $history, connections: connections)
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await connections.refresh(machines.all) }
            .overlay {
                if connections.agentRows.isEmpty {
                    ContentUnavailableView {
                        Label("No agents", systemImage: "sparkles")
                    } description: {
                        Text(machines.all.isEmpty
                             ? "Add a machine, then run Claude Code or Codex in one of its panes."
                             : "Claude Code and Codex show here while they run in a pane, and come to the top when they need you.")
                    }
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { navigator.quickOpen = true } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                }
            }
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
    }
}

/// A machine or a pane, pushed on the Agents or Machines stack.
struct RouteDestination: View {
    let route: Route
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections

    var body: some View {
        switch route {
        case .machine(let id):
            // Kept for old links (a notification for a machine): Machines shows every machine already.
            if let machine = machines.machine(id) {
                MachineView(connection: connections.connection(for: machine))
            }
        case .pane(let id, let tab, let pane):
            if let machine = machines.machine(id) {
                // One pane full screen: the tab bar goes while it shows, and comes back with Back.
                PaneScreen(connection: connections.connection(for: machine), initialTab: tab, initialPane: pane)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }
}
