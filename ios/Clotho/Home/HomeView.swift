import ClothoKit
import SwiftUI

/// The iPhone's one screen (docs/ios-redesign.md, phase 2): agents that need the user pinned on top, then every
/// machine's workspaces. Each machine's header says whether it's live ("connected", "last seen 3m ago",
/// "connecting…") and holds its New Workspace button and a menu with its files, settings and the rest. A
/// workspace row opens its last tab. Machines show their saved model at once (phase 1), dimmed until live.
struct HomeView: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @EnvironmentObject private var navigator: Navigator
    @State private var editing: Machine?

    /// Debug builds default new machines to the test install dirs, so trying things out never touches the
    /// daemon a machine already runs.
    #if DEBUG
    static let defaultDevDirs = true
    #else
    static let defaultDevDirs = false
    #endif

    var body: some View {
        NavigationStack(path: $navigator.path) {
            List {
                AgentsSection(rows: connections.agentRows, connections: connections) { row in
                    navigator.open(.pane(row.machineID, row.tab, row.pane))
                }
                ForEach(machines.all) { machine in
                    HomeMachineSection(machine: machine, connection: connections.connection(for: machine), editing: $editing)
                }
            }
            .listStyle(.insetGrouped)
            // Pull to refresh: connect to every machine so its agents show up.
            .refreshable { await connections.refresh(machines.all) }
            .overlay {
                if machines.all.isEmpty {
                    ContentUnavailableView {
                        Label("No machines", systemImage: "desktopcomputer")
                    } description: {
                        Text("Add a Mac or Linux machine you can reach over SSH.")
                    } actions: {
                        Button("Add a Machine") { navigator.guide = .addMachine }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Clotho")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { navigator.quickOpen = true } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                    Button { navigator.guide = .addMachine } label: { Label("Add machine", systemImage: "plus") }
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { navigator.guide = .firstRun } label: { Label("Welcome Guide", systemImage: "questionmark.circle") }
                    AppearanceMenu()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .machine(let id):
                    // Kept for old links (a notification for a machine): Home shows every machine already.
                    if let machine = machines.machine(id) {
                        MachineView(connection: connections.connection(for: machine))
                    }
                case .pane(let id, let tab, let pane):
                    if let machine = machines.machine(id) {
                        PaneScreen(connection: connections.connection(for: machine), initialTab: tab, initialPane: pane)
                    }
                }
            }
            .sheet(item: $editing) { machine in
                MachineEditor(machine: machine) { machines.save($0) }
            }
        }
    }
}

/// One machine on Home: its header, any offer to update its clothod, and its workspaces.
private struct HomeMachineSection: View {
    let machine: Machine
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @Binding var editing: Machine?
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @EnvironmentObject private var navigator: Navigator
    @State private var renaming: WorkspaceID?
    @State private var showingFiles = false
    @State private var showingSettings = false
    @State private var confirmingUpdate = false
    @State private var confirmingRestart = false

    init(machine: Machine, connection: MachineConnection, editing: Binding<Machine?>) {
        self.machine = machine
        self.connection = connection
        store = connection.store
        _editing = editing
    }

    var body: some View {
        Section {
            offers
            if store.state.workspaces.isEmpty {
                Text(store.isConnected ? "No workspaces yet. Tap + to start one." : connection.connectionLabel)
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.state.workspaces) { workspace in
                if renaming == workspace.id {
                    InlineRename(initial: workspace.name, placeholder: "Workspace name") { name in
                        renaming = nil
                        if let name, !name.isEmpty { connection.run("Rename workspace") { try await $0.renameWorkspace(workspace.id, name: name) } }
                    }
                } else {
                    workspaceRow(workspace)
                }
            }
            // The saved model, until the machine is live.
            .opacity(store.isSaved ? 0.6 : 1)
        } header: {
            header
        }
        .onAppear { connection.connect() }
        .sheet(isPresented: $showingFiles) {
            NavigationStack {
                FileBrowserView(connection: connection, path: FileBrowserView.startPath(connection))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingFiles = false } } }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                MachineSettingsView(connection: connection)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingSettings = false } } }
            }
        }
        .alert("Clotho", isPresented: Binding(get: { connection.lastError != nil }, set: { if !$0 { connection.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(connection.lastError ?? "")
        }
        .confirmationDialog("Update clothod on \(machine.displayName)?", isPresented: $confirmingUpdate, titleVisibility: .visible) {
            Button("Update") { connection.updateClothod() }
        } message: {
            Text("Installs this app's clothod and switches to it. Shells keep running; if anything fails, the machine keeps its current version.")
        }
        .confirmationDialog("Restart clothod on \(machine.displayName)?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("End all shells and restart", role: .destructive) { connection.restartSessions() }
        } message: {
            Text("Every shell on this machine ends, including ones open on your other devices. Running programs are stopped.")
        }
        .alert("Host key changed", isPresented: Binding(get: { connection.hostKeyChange != nil },
                                                        set: { if !$0 { connection.hostKeyChange = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Trust new key", role: .destructive) { connection.trustPresentedHostKey() }
        } message: {
            if let change = connection.hostKeyChange {
                Text("\(machine.displayName) presented a different host key than before.\n\nWas: \(HostKeys.fingerprint(change.trusted) ?? "?")\nNow: \(HostKeys.fingerprint(change.presented) ?? "?")\n\nThis happens after reinstalling the machine, or when someone intercepts the connection. Only trust it if you know why it changed.")
            }
        }
    }

    // MARK: Header

    private var status: String {
        if store.isSaved { return connection.lastSeen.map { "last seen \(MachineConnection.ago($0))" } ?? "connecting…" }
        if connection.suspended { return "paused" }
        switch store.connection {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .reconnecting: return connection.lastSeen.map { "last seen \(MachineConnection.ago($0))" } ?? "reconnecting…"
        case .idle: return "not connected"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(machine.displayName)
                .font(.headline).foregroundStyle(.primary).textCase(nil)
            ConnectionDot(connection: connection)
            Text(status)
                .font(.caption).foregroundStyle(.secondary).textCase(nil).lineLimit(1)
                .accessibilityIdentifier("machineStatus")
            Spacer()
            Button(action: newWorkspace) {
                Label("New Workspace", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 36)
            }
            .disabled(!store.isConnected)
            Menu {
                Button { showingFiles = true } label: { Label("Files", systemImage: "folder") }
                    .disabled(!store.isConnected)
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                if machine.kind == .ssh {
                    Divider()
                    Button { editing = machine } label: { Label("Edit", systemImage: "pencil") }
                    Button { connections.disconnect(machine) } label: {
                        Label(machine.devDirs == true ? "Disconnect and remove test clothod" : "Disconnect",
                              systemImage: "bolt.horizontal.circle")
                    }
                    Button(role: .destructive) {
                        connections.forget(machine.id)
                        machines.delete(machine.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
            }
            .accessibilityLabel("\(machine.displayName) menu")
        }
        .padding(.bottom, 2)
    }

    private func newWorkspace() {
        // Named like the Mac's: "Workspace N".
        let name = "Workspace \(store.state.workspaces.count + 1)"
        let id = machine.id
        connection.run("New workspace") { backend in
            let created = try await backend.createWorkspace(name: name)
            await MainActor.run { navigator.open(.pane(id, created.tab, created.pane)) }
        }
    }

    // MARK: Offers

    @ViewBuilder private var offers: some View {
        if connection.updateAvailable {
            Button(connection.updating ? "Updating clothod…" : "Update clothod on \(machine.displayName)") { confirmingUpdate = true }
                .disabled(connection.updating)
        }
        if case .appOutdated(let running) = connection.shownVersionStatus {
            Label("\(machine.displayName) runs clothod \(running), newer than this app's. Update the app to stay in step.",
                  systemImage: "arrow.up.circle")
                .font(.callout)
        }
        if connection.holderOutdated {
            Button(connection.restarting ? "Restarting clothod…" : "Restart clothod…", role: .destructive) { confirmingRestart = true }
                .disabled(connection.restarting)
        }
    }

    // MARK: Workspaces

    private func workspaceRow(_ workspace: Workspace) -> some View {
        let tab = workspace.tabs.first { $0.id == workspace.activeTab } ?? workspace.tabs.first
        return Button {
            if let tab { navigator.open(.pane(machine.id, tab.id, tab.activePane)) }
        } label: {
            WorkspaceRow(store: store, workspace: workspace)
        }
        .tint(.primary)
        .swipeActions {
            Button(role: .destructive) {
                connection.run("Close workspace") { try await $0.closeWorkspace(workspace.id) }
            } label: { Label("Close", systemImage: "xmark") }
        }
        .contextMenu {
            ForEach(workspace.tabs) { tab in
                Button { navigator.open(.pane(machine.id, tab.id, tab.activePane)) } label: {
                    Label(store.displayTitle(of: tab), systemImage: tab.layout.panes.count > 1 ? "rectangle.split.2x1" : "terminal")
                }
            }
            Button {
                connection.run("New tab") { backend in
                    let created = try await backend.createTab(in: workspace.id)
                    await MainActor.run { navigator.open(.pane(machine.id, created.tab, created.pane)) }
                }
            } label: { Label("New Tab", systemImage: "plus") }
                .disabled(!store.isConnected)
            Button { renaming = workspace.id } label: { Label("Rename", systemImage: "pencil") }
                .disabled(!store.isConnected)
            Button(role: .destructive) {
                connection.run("Close workspace") { try await $0.closeWorkspace(workspace.id) }
            } label: { Label("Close workspace", systemImage: "xmark") }
                .disabled(!store.isConnected)
        }
    }
}

/// A workspace on Home, read like the Mac's rows: its name, a dot right after it when an agent there needs
/// the user, and its tab count on the trailing edge. Under the name, the last tab's title and folder.
struct WorkspaceRow: View {
    @ObservedObject var store: ModelStore
    let workspace: Workspace

    private var tab: ClothoKit.Tab? { workspace.tabs.first { $0.id == workspace.activeTab } ?? workspace.tabs.first }

    /// Whether an agent in this workspace needs the user.
    var needsYou: Bool {
        let panes = Set(workspace.tabs.flatMap(\.layout.panes))
        return store.state.panes.contains { panes.contains($0.id) && $0.agent?.needsAttention == true }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(workspace.name).font(.body.weight(.medium)).lineLimit(1)
                    if needsYou {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                            .accessibilityLabel("needs you")
                    }
                }
                if let tab {
                    let cwd = store.state.pane(tab.activePane)?.cwd
                    Text([store.displayTitle(of: tab), cwd].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text("\(workspace.tabs.count)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("\(workspace.tabs.count) \(workspace.tabs.count == 1 ? "tab" : "tabs")")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionDot: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore

    init(connection: MachineConnection) {
        self.connection = connection
        store = connection.store
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(connection.connectionLabel)
    }

    private var color: Color {
        if connection.suspended || store.isSaved { return .gray }
        switch store.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .idle: return .gray
        }
    }
}
