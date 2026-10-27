import ClothoKit
import SwiftUI

/// A machine's workspaces and their tabs, straight from the daemon's model.
struct MachineView: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @State private var openTab: TabID?
    @State private var renaming: RenameTarget?
    @State private var confirmingUpdate = false
    @State private var confirmingRestart = false

    init(connection: MachineConnection) {
        self.connection = connection
        store = connection.store
    }

    var body: some View {
        List {
            Section {
                HStack {
                    ConnectionDot(connection: connection)
                    Text(connection.connectionLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let hello = store.hello {
                        Text("\(hello.machine?.hostname ?? "") · clothod \(hello.version)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if connection.updateAvailable {
                Section {
                    Button(connection.updating ? "Updating clothod…" : "Update clothod on \(connection.machine.displayName)") {
                        confirmingUpdate = true
                    }
                    .disabled(connection.updating)
                } footer: {
                    Text("This app has a newer clothod than the machine runs. Updating restarts clothod there; your shells keep running.")
                }
            }
            if case .appOutdated(let running) = connection.shownVersionStatus {
                Section {
                    Label("Update the app", systemImage: "arrow.up.circle")
                } footer: {
                    Text("\(connection.machine.displayName) runs clothod \(running), newer than this app's. Clotho keeps using it; update the app to stay in step.")
                }
            }
            if connection.holderOutdated {
                Section {
                    Button(connection.restarting ? "Restarting sessions…" : "Restart sessions…", role: .destructive) {
                        confirmingRestart = true
                    }
                    .disabled(connection.restarting)
                } footer: {
                    Text("The sessions on \(connection.machine.displayName) run under an older clothod that can't be updated in place. A one-time restart finishes the update, and it ends every shell there.")
                }
            }
            if connection.supportsPush, connection.alertsOn, PushRegistrar.shared.handle != nil {
                Section {
                    Button("Send test alert") { connection.sendTestAlert() }
                } footer: {
                    Text("\(connection.machine.displayName) sends this iPhone an encrypted alert through the relay, the way it does when an agent needs you while Clotho is closed.")
                }
            }
            // In the list rather than over it, so it never covers the rows above.
            if store.state.workspaces.isEmpty {
                Section {
                    if store.isConnected {
                        ContentUnavailableView("No workspaces", systemImage: "rectangle.stack",
                                               description: Text("Create one to start a shell."))
                    } else {
                        ProgressView(connection.connectionLabel).frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.state.workspaces) { workspace in
                Section {
                    ForEach(workspace.tabs) { tab in
                        Button { openTab = tab.id } label: { TabRow(store: store, tab: tab) }
                            .tint(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    connection.run("Close tab") { try await $0.closeTab(tab.id) }
                                } label: { Label("Close", systemImage: "xmark") }
                            }
                            .contextMenu {
                                Button("Rename") { renaming = .tab(tab.id, store.displayTitle(of: tab)) }
                                Button("Close", role: .destructive) {
                                    connection.run("Close tab") { try await $0.closeTab(tab.id) }
                                }
                            }
                    }
                    Button {
                        connection.run("New tab") { backend in
                            let created = try await backend.createTab(in: workspace.id)
                            await MainActor.run { openTab = created.tab }
                        }
                    } label: {
                        Label("New tab", systemImage: "plus").font(.callout)
                    }
                } header: {
                    HStack {
                        Text(workspace.name)
                        Spacer()
                        Menu {
                            Button("Rename") { renaming = .workspace(workspace.id, workspace.name) }
                            Button("Close workspace", role: .destructive) {
                                connection.run("Close workspace") { try await $0.closeWorkspace(workspace.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle(connection.machine.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    connection.run("New workspace") { backend in
                        let created = try await backend.createWorkspace(name: nil)
                        await MainActor.run { openTab = created.tab }
                    }
                } label: {
                    Label("New workspace", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(!store.isConnected)
            }
        }
        .navigationDestination(item: $openTab) { tab in
            PaneScreen(connection: connection, initialTab: tab)
        }
        .onAppear { connection.connect() }
        .alert("Clotho", isPresented: Binding(get: { connection.lastError != nil }, set: { if !$0 { connection.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(connection.lastError ?? "")
        }
        .renameAlert($renaming, connection: connection)
        .confirmationDialog("Update clothod on \(connection.machine.displayName)?", isPresented: $confirmingUpdate,
                            titleVisibility: .visible) {
            Button("Update") { connection.updateClothod() }
        } message: {
            Text("Installs this app's clothod and switches to it. Sessions stay open; if anything fails, the machine keeps its current version.")
        }
        .confirmationDialog("Restart every session on \(connection.machine.displayName)?", isPresented: $confirmingRestart,
                            titleVisibility: .visible) {
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
                Text("\(connection.machine.displayName) presented a different host key than before.\n\nWas: \(HostKeys.fingerprint(change.trusted) ?? "?")\nNow: \(HostKeys.fingerprint(change.presented) ?? "?")\n\nThis happens after reinstalling the machine, or when someone intercepts the connection. Only trust it if you know why it changed.")
            }
        }
    }
}

private struct TabRow: View {
    @ObservedObject var store: ModelStore
    let tab: ClothoKit.Tab

    var body: some View {
        let panes = tab.layout.panes.compactMap { store.state.pane($0) }
        HStack {
            Image(systemName: panes.count > 1 ? "rectangle.split.2x1" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayTitle(of: tab)).foregroundStyle(.primary).lineLimit(1)
                if let cwd = store.state.pane(tab.activePane)?.cwd {
                    Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            if panes.count > 1 {
                Text("\(panes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if store.state.focus.tab == tab.id {
                Image(systemName: "smallcircle.filled.circle").font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
    }
}

enum RenameTarget: Identifiable {
    case workspace(WorkspaceID, String)
    case tab(TabID, String)

    var id: String {
        switch self {
        case .workspace(let id, _): return "w\(id)"
        case .tab(let id, _): return "t\(id)"
        }
    }
}

extension View {
    func renameAlert(_ target: Binding<RenameTarget?>, connection: MachineConnection) -> some View {
        modifier(RenameAlert(target: target, connection: connection))
    }
}

private struct RenameAlert: ViewModifier {
    @Binding var target: RenameTarget?
    let connection: MachineConnection
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                TextField("Name", text: $text)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = text.trimmingCharacters(in: .whitespaces)
                    switch target {
                    case .workspace(let id, _):
                        connection.run("Rename workspace") { try await $0.renameWorkspace(id, name: name) }
                    case .tab(let id, _):
                        connection.run("Rename tab") { try await $0.renameTab(id, title: name.isEmpty ? nil : name) }
                    case nil: break
                    }
                }
            }
            .onChange(of: target?.id) { _, _ in
                switch target {
                case .workspace(_, let name), .tab(_, let name): text = name
                case nil: break
                }
            }
    }
}
