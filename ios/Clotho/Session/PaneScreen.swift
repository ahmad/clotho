import ClothoKit
import SwiftUI

/// One pane full screen. A strip above it switches between the tab's panes (tap or swipe), the title menu
/// jumps to any tab, and every action is a backend call.
struct PaneScreen: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var tabID: TabID
    @State private var paneID: PaneID?
    @State private var mode: Subscription.Mode?
    @State private var renaming: RenameTarget?
    @AppStorage("FontSize") private var fontSize: Double = Double(Theme.fontSize)

    init(connection: MachineConnection, initialTab: TabID, initialPane: PaneID? = nil) {
        self.connection = connection
        store = connection.store
        _tabID = State(initialValue: initialTab)
        _paneID = State(initialValue: initialPane)
    }

    private var tab: ClothoKit.Tab? { store.state.tab(tabID) }
    private var workspace: Workspace? { store.state.workspace(containing: tabID) }
    private var panes: [PaneID] { tab?.layout.panes ?? [] }
    private var pane: Pane? { store.state.pane(currentPane) }

    /// The pane shown: the one picked here if it's still in the tab, else the tab's active pane.
    private var currentPane: PaneID? {
        if let paneID, panes.contains(paneID) { return paneID }
        return tab?.activePane ?? panes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if panes.count > 1 { paneStrip }
            ZStack(alignment: .topTrailing) {
                if let pane {
                    TerminalContainer(host: connection.terminal(for: pane), onMode: { mode = $0 })
                        .id(pane.id)
                } else {
                    Color(Theme.background)
                }
                statusBadge
            }
        }
        .background(Color(Theme.background))
        .navigationTitle(tab.map(store.displayTitle(of:)) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { tabMenu }
            ToolbarItem(placement: .primaryAction) { actionsMenu }
        }
        .background { ShortcutButtons(screen: self) }
        .onChange(of: tab == nil) { _, gone in
            if gone { dismiss() }
        }
        .onChange(of: fontSize) { _, size in
            connection.setFont(UIFont.monospacedSystemFont(ofSize: size, weight: .regular))
        }
        .renameAlert($renaming, connection: connection)
    }

    // MARK: Pieces

    private var paneStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(panes.enumerated()), id: \.element) { index, id in
                    let selected = id == currentPane
                    Button { select(pane: id) } label: {
                        Text("\(index + 1) \(paneTitle(id))")
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            step(pane: value.translation.width < 0 ? 1 : -1)
        })
    }

    @ViewBuilder private var statusBadge: some View {
        if connection.suspended || !store.isConnected {
            Text(connection.connectionLabel)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.orange.opacity(0.85), in: Capsule())
                .padding(8)
        } else if let mode {
            // How the last (re)subscribe resumed, briefly: live or replay means no reload happened.
            Text(mode.rawValue)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.secondary)
                .padding(6)
                .accessibilityIdentifier("resumeMode")
                .task(id: mode) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.mode = nil
                }
        }
    }

    private var tabMenu: some View {
        Menu {
            ForEach(store.state.workspaces) { workspace in
                Section(workspace.name) {
                    ForEach(workspace.tabs) { tab in
                        Button {
                            select(tab: tab.id)
                        } label: {
                            if tab.id == tabID {
                                Label(store.displayTitle(of: tab), systemImage: "checkmark")
                            } else {
                                Text(store.displayTitle(of: tab))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(tab.map(store.displayTitle(of:)) ?? "").font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button { newTab() } label: { Label("New tab", systemImage: "plus.square") }
            Button { split(.right) } label: { Label("Split right", systemImage: "rectangle.split.2x1") }
            Button { split(.down) } label: { Label("Split down", systemImage: "rectangle.split.1x2") }
            Divider()
            Button { renaming = .tab(tabID, tab.map(store.displayTitle(of:)) ?? "") } label: {
                Label("Rename tab", systemImage: "pencil")
            }
            Menu("Text size") {
                Button("Larger") { fontSize = min(fontSize + 1, 28) }
                Button("Smaller") { fontSize = max(fontSize - 1, 7) }
            }
            Divider()
            Button(role: .destructive) { closePane() } label: { Label("Close pane", systemImage: "xmark.square") }
            Button(role: .destructive) { closeTab() } label: { Label("Close tab", systemImage: "xmark.rectangle") }
        } label: {
            Label("Pane actions", systemImage: "ellipsis.circle")
        }
    }

    private func paneTitle(_ id: PaneID) -> String {
        let pane = store.state.pane(id)
        if let title = pane?.displayTitle { return title }
        if let cwd = pane?.cwd { return (cwd as NSString).lastPathComponent }
        return "Shell"
    }

    // MARK: Actions

    func select(pane id: PaneID) {
        paneID = id
        connection.run("Focus") { try await $0.focus(.pane(id)) }
    }

    func select(tab id: TabID) {
        tabID = id
        paneID = nil
        connection.run("Focus") { try await $0.focus(.tab(id)) }
    }

    func step(pane delta: Int) {
        guard let current = currentPane, let index = panes.firstIndex(of: current), panes.count > 1 else { return }
        select(pane: panes[(index + delta + panes.count) % panes.count])
    }

    func step(tab delta: Int) {
        guard let tabs = workspace?.tabs, let index = tabs.firstIndex(where: { $0.id == tabID }), tabs.count > 1 else { return }
        select(tab: tabs[(index + delta + tabs.count) % tabs.count].id)
    }

    func selectTab(number: Int) {
        guard let tabs = workspace?.tabs, number >= 1, number <= tabs.count else { return }
        select(tab: tabs[number - 1].id)
    }

    func newTab() {
        guard let workspace else { return }
        connection.run("New tab") { backend in
            let created = try await backend.createTab(in: workspace.id)
            await MainActor.run {
                tabID = created.tab
                paneID = created.pane
            }
        }
    }

    func split(_ direction: Direction) {
        guard let current = currentPane else { return }
        let size = connection.terminal(for: store.state.pane(current)!).fittedSize()
        connection.run("Split") { backend in
            let created = try await backend.split(current, direction: direction,
                                                  spawn: SpawnOptions(cwd: nil, cols: size.cols, rows: size.rows))
            await MainActor.run { paneID = created.pane }
        }
    }

    func closePane() {
        guard let current = currentPane else { return }
        connection.run("Close pane") { try await $0.closePane(current) }
    }

    func closeTab() {
        let id = tabID
        connection.run("Close tab") { try await $0.closeTab(id) }
    }

    func changeFont(_ delta: Double) {
        fontSize = min(max(fontSize + delta, 7), 28)
    }
}

/// Hardware keyboard shortcuts, as invisible buttons so they work while the terminal has focus.
private struct ShortcutButtons: View {
    let screen: PaneScreen

    var body: some View {
        Group {
            Button("New Tab") { screen.newTab() }.keyboardShortcut("t", modifiers: .command)
            Button("Split Right") { screen.split(.right) }.keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { screen.split(.down) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Close Pane") { screen.closePane() }.keyboardShortcut("w", modifiers: .command)
            Button("Next Pane") { screen.step(pane: 1) }.keyboardShortcut("]", modifiers: .command)
            Button("Previous Pane") { screen.step(pane: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next Tab") { screen.step(tab: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { screen.step(tab: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Bigger Text") { screen.changeFont(1) }.keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { screen.changeFont(-1) }.keyboardShortcut("-", modifiers: .command)
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { screen.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Hosts the pane's long-lived terminal view. Swapping panes swaps the hosted view; the terminal itself
/// (and the seq it reached) lives on in the connection.
struct TerminalContainer: UIViewRepresentable {
    let host: PaneHostView
    var onMode: (Subscription.Mode) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.background
        install(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if host.superview !== container { install(in: container) }
        host.onModeChange = onMode
    }

    private func install(in container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.onModeChange = onMode
        container.addSubview(host)
        DispatchQueue.main.async { _ = host.terminal.becomeFirstResponder() }
    }
}
