import ClothoKit
import PhotosUI
import SwiftUI
import UIKit

/// One pane full screen. A strip above it switches between the tab's panes (tap or swipe), the title menu
/// jumps to any tab, and every action is a backend call.
struct PaneScreen: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var tabID: TabID
    @State private var paneID: PaneID?
    @State private var browsingFiles: String?
    /// The short "Copied" and resume notes. Not observed here: a note coming or going must not redraw this
    /// view's toolbar, which would close an open Pane actions menu.
    @State private var notes = PaneNotes()
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @AppStorage("FontSize") private var fontSize: Double = Double(Theme.fontSize)
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system
    @StateObject private var find: PaneFind
    @State private var finding = false
    @State private var showingHistory: PaneID?

    /// In the iPad's detail column: switching tabs here moves the sidebar's selection, and a closed tab
    /// goes back to the machine (instead of popping the stack).
    private let onTabChange: ((TabID) -> Void)?
    private let onTabGone: (() -> Void)?

    init(connection: MachineConnection, initialTab: TabID, initialPane: PaneID? = nil,
         onTabChange: ((TabID) -> Void)? = nil, onTabGone: (() -> Void)? = nil) {
        self.connection = connection
        store = connection.store
        _tabID = State(initialValue: initialTab)
        _paneID = State(initialValue: initialPane)
        _find = StateObject(wrappedValue: PaneFind(store: connection.store))
        self.onTabChange = onTabChange
        self.onTabGone = onTabGone
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
            if finding {
                FindBar(find: find, machine: connection.machine.displayName) { stopFinding() }
            }
            // Saved or not connected: a slim bar of its own, never over the pane's text.
            statusBar
            ZStack(alignment: .topTrailing) {
                if let pane {
                    TerminalContainer(host: connection.terminal(for: pane), onMode: { [notes] in notes.mode = $0 }, onCopy: { [notes] in notes.copies += 1 })
                        .id(pane.id)
                        // Zero-size: the notes draw nothing over the pane (see PaneNotesView).
                        .background(PaneNotesView(notes: notes))
                        // The saved screen, dimmed until the machine is live; it then draws over in place.
                        .opacity(store.isSaved ? 0.5 : 1)
                        .animation(.easeOut(duration: 0.25), value: store.isSaved)
                        .overlay {
                            if store.isSaved && !connection.hasSavedScreen(pane.id) {
                                Text("No preview yet").font(.callout).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("noPreview")
                            }
                        }
                } else {
                    Color(Theme.background)
                }
            }
            // Uploads for pasted images and photos: progress, and any failure (nothing is pasted then).
            TransferBar(machine: connection.machine.id)
        }
        .background(Color(Theme.background))
        // Tap the title for the other tabs, or Rename to edit this one's title in place.
        .navigationTitle(titleBinding)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbarTitleMenu { tabMenu }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionsMenu.disabled(store.isSaved) }
            // In the navigation bar, so it doesn't resize the pane for the two seconds it shows.
            // Short notes on the leading side, so the actions button never moves while they come and go.
        }
        .background { ShortcutButtons(screen: self) }
        // The find bar follows the pane on screen.
        .onChange(of: currentPane) { if finding { attachFind() } }
        .sheet(item: Binding(get: { showingHistory.map(HistoryTarget.init) }, set: { showingHistory = $0?.pane })) { target in
            AgentHistoryView(connection: connection, pane: target.pane)
        }
        .onChange(of: tab == nil) { _, gone in
            guard gone else { return }
            if let onTabGone { onTabGone() } else { dismiss() }
        }
        .onChange(of: appearance) { AppearanceChoice.applyToAllWindows() }
        .onChange(of: fontSize) { _, size in
            connection.setFont(UIFont.monospacedSystemFont(ofSize: size, weight: .regular))
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .any(of: [.images, .screenshots]))
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            pastePhoto(item)
        }
        .sheet(item: Binding(get: { browsingFiles.map(FilesStart.init) }, set: { browsingFiles = $0?.path })) { start in
            NavigationStack {
                FileBrowserView(connection: connection, path: start.path)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { browsingFiles = nil } } }
            }
        }
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
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Color.selection.opacity(0.35) : Color.primary.opacity(0.08), in: Capsule())
                            // The selected pane is underlined too, so it reads at a glance (as on the Mac).
                            .overlay(alignment: .bottom) {
                                if selected {
                                    Capsule().fill(Color.selection).frame(height: 2.5).padding(.horizontal, 8).offset(y: 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// The pane's connection when it isn't live. Rare changes, so its own room in the layout is fine.
    @ViewBuilder private var statusBar: some View {
        if store.isSaved || connection.suspended || !store.isConnected {
            let saved = store.isSaved
            HStack(spacing: 6) {
                Image(systemName: saved ? "clock.arrow.circlepath" : "bolt.horizontal.circle").accessibilityHidden(true)
                Text(saved ? connection.savedLabel : connection.connectionLabel).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(saved ? Color.secondary : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(saved ? AnyShapeStyle(.bar) : AnyShapeStyle(Color.orange.opacity(0.25)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(saved ? "savedBadge" : "connectionBar")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// How the last (re)subscribe resumed, briefly: live or replay means no reload happened.

    /// The tab's title; setting it (from the title's Rename) renames the tab on the machine.
    private var titleBinding: Binding<String> {
        Binding(get: { tab.map(store.displayTitle(of:)) ?? "" }, set: { name in
            let name = name.trimmingCharacters(in: .whitespaces), id = tabID
            guard name != tab.map(store.displayTitle(of:)) else { return }
            connection.run("Rename tab") { try await $0.renameTab(id, title: name.isEmpty ? nil : name) }
        })
    }

    @ViewBuilder private var tabMenu: some View {
        RenameButton()
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
    }

    private var actionsMenu: some View {
        Menu {
            Button { newTab() } label: { Label("New Tab", systemImage: "plus.square") }
            Button { split(.right) } label: { Label("Split right", systemImage: "rectangle.split.2x1") }
            Button { split(.down) } label: { Label("Split down", systemImage: "rectangle.split.1x2") }
            Divider()
            Menu("Text size") {
                Button("Larger") { fontSize = min(fontSize + 1, 28) }
                Button("Smaller") { fontSize = max(fontSize - 1, 7) }
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Button { startFinding() } label: { Label("Find…", systemImage: "magnifyingglass") }
            if let pane, pane.agent != nil || store.hello?.features.contains(.agentHistory) == true {
                Button { showingHistory = pane.id } label: { Label("Agent History", systemImage: "clock.arrow.circlepath") }
            }
            Button { browsingFiles = pane?.cwd ?? "~" } label: { Label("Files here", systemImage: "folder") }
            Button { pickingPhoto = true } label: { Label("Paste Photo…", systemImage: "photo.on.rectangle") }
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
        onTabChange?(id)
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
                onTabChange?(created.tab)
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

    /// Saves a photo or screenshot on the machine and pastes its path into the pane, for an agent to attach.
    private func pastePhoto(_ item: PhotosPickerItem) {
        guard let pane else { return }
        let host = connection.terminal(for: pane)
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let png = ImagePaste.png(data) else {
                TransferCenter.shared.fail("Paste photo", on: connection, "The photo couldn't be read.")
                return
            }
            connection.pasteImage(png, into: host)
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

    func startFinding() {
        finding = true
        attachFind()
    }

    private func attachFind() {
        guard let pane else { return }
        // After the terminal is in its container.
        DispatchQueue.main.async { find.attach(connection.terminal(for: pane)) }
    }

    private func stopFinding() {
        finding = false
        find.close()
        if let pane { _ = connection.terminal(for: pane).terminal.becomeFirstResponder() }
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
            Button("Find") { screen.startFinding() }.keyboardShortcut("f", modifiers: .command)
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
    var onCopy: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.background
        install(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // Back from another container, unless another window shows this pane now (one terminal view per pane:
        // the window that opened it last keeps it, instead of the two trading it on every update).
        if host.superview !== container, host.window == nil || host.window === container.window { install(in: container) }
        host.onModeChange = onMode
        host.onCopy = onCopy
    }

    private func install(in container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.onModeChange = onMode
        host.onCopy = onCopy
        container.addSubview(host)
        DispatchQueue.main.async { _ = host.terminal.becomeFirstResponder() }
    }
}

private struct HistoryTarget: Identifiable {
    var pane: PaneID
    var id: PaneID { pane }
}

private struct FilesStart: Identifiable {
    var path: String
    var id: String { path }
}

/// What PaneNotesView shows; set by the pane, read only by that view.
@MainActor
final class PaneNotes: ObservableObject {
    /// How the last (re)subscribe resumed, shown for two seconds: live or replay means no reload happened.
    @Published var mode: Subscription.Mode?
    /// Bumped each time the pane copies to the clipboard, which shows "Copied" briefly.
    @Published var copies = 0
}

/// The pane's short notes, which never draw over its text or change the toolbar (that closed an open Pane
/// actions menu): "Copied" is a success haptic and a VoiceOver announcement; how the last subscribe resumed is
/// an accessibility element only (tests check that a return resumes instead of reloading).
struct PaneNotesView: View {
    @ObservedObject var notes: PaneNotes

    var body: some View {
        Text(notes.mode?.rawValue ?? "")
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(notes.mode == nil)
            .accessibilityIdentifier("resumeMode")
            .task(id: notes.mode) {
                guard notes.mode != nil else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                notes.mode = nil
            }
            .onChange(of: notes.copies) { _, copies in
                guard copies > 0 else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: "Copied")
                notes.copies = 0
            }
    }
}
