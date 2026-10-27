import ClothoKit
import SwiftUI

struct MachineListView: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @State private var editing: Machine?
    @State private var path: [Route] = []

    /// Debug builds default new machines to the test install dirs, so trying things out never touches the
    /// daemon a machine already runs.
    #if DEBUG
    static let defaultDevDirs = true
    #else
    static let defaultDevDirs = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
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
                    ContentUnavailableView("No machines", systemImage: "desktopcomputer",
                                           description: Text("Add a machine you can reach over SSH."))
                }
            }
            .navigationTitle("Machines")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Machine(name: "", devDirs: Self.defaultDevDirs) } label: { Label("Add machine", systemImage: "plus") }
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
            .onAppear {
                AgentNotifier.shared.onOpen = { machine, pane in openPane(machine: machine, pane: pane) }
                AgentNotifier.shared.isLive = { [connections] id in connections.existing(id)?.store.isConnected == true }
            }
            .sheet(item: $editing) { machine in
                MachineEditor(machine: machine) { saved in
                    machines.save(saved)
                }
            }
        }
    }

    private func open(_ row: AgentRow) {
        connections.existing(row.machineID)?.ackAgent(row.pane)
        path = [.pane(row.machineID, row.tab, row.pane)]
    }

    /// From a notification: the machine may not be connected yet, so wait for its model.
    private func openPane(machine id: UUID, pane: PaneID) {
        guard let machine = machines.machine(id) else { return }
        let connection = connections.connection(for: machine)
        connection.connect()
        Task {
            for _ in 0..<50 {
                if let tab = connection.store.state.location(of: pane)?.tab {
                    connection.ackAgent(pane)
                    path = [.pane(id, tab.id, pane)]
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

enum Route: Hashable {
    case machine(UUID)
    case pane(UUID, TabID, PaneID)
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
