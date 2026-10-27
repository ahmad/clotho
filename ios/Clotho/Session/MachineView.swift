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

    private func workspaceSection(_ workspace: Workspace) -> some View {
        Section {
            ForEach(workspace.tabs) { tab in
                Group {
                    if renaming?.id == RenameTarget.tab(tab.id, "").id {
                        InlineRename(initial: store.displayTitle(of: tab), placeholder: "Tab name") { name in
                            renaming = nil
                            if let name { connection.run("Rename tab") { try await $0.renameTab(tab.id, title: name.isEmpty ? nil : name) } }
                        }
                    } else {
                        Button { openTab = tab.id } label: { TabRow(store: store, tab: tab) }
                            .tint(.primary)
                    }
                }
                    .listRowBackground(SelectionBackground(selected: store.state.focus.tab == tab.id))
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
                Label("New Tab", systemImage: "plus").font(.callout)
            }
        } header: {
            HStack {
                if renaming?.id == RenameTarget.workspace(workspace.id, "").id {
                    InlineRename(initial: workspace.name, placeholder: "Workspace name") { name in
                        renaming = nil
                        if let name, !name.isEmpty { connection.run("Rename workspace") { try await $0.renameWorkspace(workspace.id, name: name) } }
                    }
                    .textCase(nil)
                } else if workspace.id == store.focusedWorkspace?.id {
                    // The current workspace: in the selection colour, with a leading bar (as on the Mac).
                    HStack(spacing: 6) {
                        Capsule().fill(Color.selection).frame(width: 3, height: 13)
                        Text(workspace.name).foregroundStyle(Color.selection).fontWeight(.semibold)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(workspace.name), current")
                } else {
                    Text(workspace.name)
                }
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

    var body: some View {
        List {
            Section {
                HStack {
                    ConnectionDot(connection: connection)
                    Text(connection.connectionLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let hello = store.hello {
                        Text("clothod \(hello.version)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Section {
                NavigationLink {
                    FileBrowserView(connection: connection, path: FileBrowserView.startPath(connection))
                } label: {
                    Label("Files", systemImage: "folder")
                }
                NavigationLink {
                    MachineSettingsView(connection: connection)
                } label: {
                    Label("Settings", systemImage: "gearshape")
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
                    Button(connection.restarting ? "Restarting clothod…" : "Restart clothod…", role: .destructive) {
                        confirmingRestart = true
                    }
                    .disabled(connection.restarting)
                } footer: {
                    Text("\(connection.machine.displayName) runs an older clothod that can't be updated in place. Restarting it finishes the update and ends every shell on \(connection.machine.displayName).")
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
                        ContentUnavailableView("No workspaces on \(connection.machine.displayName)", systemImage: "rectangle.stack",
                                               description: Text("Tap the New Workspace button to start one."))
                    } else {
                        ProgressView(connection.connectionLabel).frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.state.workspaces) { workspace in workspaceSection(workspace) }
        }
        .navigationTitle(connection.machine.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Named like the Mac's: "Workspace N".
                    let name = "Workspace \(store.state.workspaces.count + 1)"
                    connection.run("New workspace") { backend in
                        let created = try await backend.createWorkspace(name: name)
                        await MainActor.run { openTab = created.tab }
                    }
                } label: {
                    Label("New Workspace", systemImage: "plus.rectangle.on.rectangle")
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
        .confirmationDialog("Update clothod on \(connection.machine.displayName)?", isPresented: $confirmingUpdate,
                            titleVisibility: .visible) {
            Button("Update") { connection.updateClothod() }
        } message: {
            Text("Installs this app's clothod and switches to it. Shells keep running; if anything fails, the machine keeps its current version.")
        }
        .confirmationDialog("Restart clothod on \(connection.machine.displayName)?", isPresented: $confirmingRestart,
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
                .foregroundStyle(store.state.focus.tab == tab.id ? Color.selection : Color.secondary)
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
        }
        .accessibilityAddTraits(store.state.focus.tab == tab.id ? .isSelected : [])
    }
}

/// A list row's background, tinted with a leading bar when it's the selected tab.
struct SelectionBackground: View {
    let selected: Bool

    var body: some View {
        if selected {
            ZStack(alignment: .leading) {
                Color(.secondarySystemGroupedBackground)
                Color.selection.opacity(0.18)
                Rectangle().fill(Color.selection).frame(width: 4)
            }
        } else {
            Color(.secondarySystemGroupedBackground)
        }
    }
}

extension Color {
    /// The selected pane, tab and workspace (#6C96B4, as on the Mac).
    static let selection = Color(Theme.selection)
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

/// A name edited in place: Return saves (with the text), and leaving the field cancels (nil).
struct InlineRename: View {
    let initial: String
    var placeholder = "Name"
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var finished = false
    @State private var hadFocus = false

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .onSubmit { finish(text.trimmingCharacters(in: .whitespaces)) }
            .onAppear {
                text = initial
                // After the swipe or context menu that opened it has gone, or that takes the focus back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused { hadFocus = true } else if hadFocus { finish(nil) }
            }
            .accessibilityIdentifier("renameField")
    }

    private func finish(_ name: String?) {
        guard !finished else { return }
        finished = true
        done(name == initial ? nil : name)
    }
}
