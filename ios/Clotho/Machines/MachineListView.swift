import ClothoKit
import SwiftUI

struct MachineListView: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @State private var editing: Machine?
    @EnvironmentObject private var navigator: Navigator

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
                AgentsSection(rows: connections.agentRows, connections: connections) { row in open(row) }
                Section(connections.agentRows.isEmpty ? "" : "Machines") {
                ForEach(machines.all) { machine in
                    NavigationLink(value: Route.machine(machine.id)) {
                        MachineRow(machine: machine, connection: connections.existing(machine.id))
                    }
                    .swipeActions {
                        if machine.kind == .ssh {
                            Button(role: .destructive) {
                                connections.forget(machine.id)
                                machines.delete(machine.id)
                            } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = machine } label: { Label("Edit", systemImage: "pencil") }
                        }
                    }
                    .contextMenu {
                        if machine.kind == .ssh {
                            Button { editing = machine } label: { Label("Edit", systemImage: "pencil") }
                        }
                        if machine.kind == .ssh {
                            Button { connections.disconnect(machine) } label: {
                                Label(machine.devDirs == true ? "Disconnect and remove test clothod" : "Disconnect",
                                      systemImage: "bolt.horizontal.circle")
                            }
                        }
                    }
                }
                }
            }
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
            .navigationTitle("Machines")
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
                MachineEditor(machine: machine) { saved in
                    machines.save(saved)
                }
            }
        }
    }

    /// Opening an agent never resolves it: it leaves the top of the list only when it starts working again or
    /// the user taps Resolve.
    private func open(_ row: AgentRow) {
        navigator.open(.pane(row.machineID, row.tab, row.pane))
    }
}

private struct MachineRow: View {
    let machine: Machine
    let connection: MachineConnection?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: machine.kind == .localSocket ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.displayName).font(.body.weight(.medium))
                Text(machine.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let connection { ConnectionDot(connection: connection) }
        }
        .padding(.vertical, 2)
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
        if connection.suspended { return .gray }
        switch store.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .idle: return .gray
        }
    }
}
