import AppKit
import ClothoKit

// Keeps the window in step with the daemons' models: the sidebar (every machine), the tab bar, pane views
// and keyboard focus (the focused machine) all redraw on every change. User actions go to the focused
// machine's backend, and their effects come back as model events.
extension AppDelegate {
    var backend: SessionBackend { store.backend }

    /// Runs a backend command, logging failures (the effect of a command arrives as a model change).
    func run(_ name: String = #function, _ command: @escaping (SessionBackend) async throws -> Void) {
        let backend = backend
        Task { @MainActor in
            do {
                try await command(backend)
            } catch {
                log("\(name) failed: \(error)")
            }
        }
    }

    var activeTerminal: PaneTerminalView? {
        store.focusedPane.flatMap { paneHosts[PaneKey(machine: focusedMachine, pane: $0.id)]?.terminal }
    }

    // MARK: Model → views

    func sync() {
        let state = store.state
        if UserDefaults.standard.bool(forKey: "LogModel") {
            log("\(focusedMachine) state rev \(state.rev) focus \(state.focus) layouts \(state.workspaces.flatMap(\.tabs).map(\.layout))")
        }
        let workspace = store.focusedWorkspace
        let tab = store.focusedTab

        let agents = agentEntries()
        sidebar.update(agents: agents, unreachable: unreachableMonitoredMachines(), groups: sidebarGroups())
        updateDockBadge(agents)
        let tabs = (workspace?.tabs ?? []).map {
            (id: $0.id, title: store.displayTitle(of: $0), maximized: maximized[tabKey($0.id)] != nil,
             badge: agentBadge(machine: focusedMachine, panes: $0.layout.panes))
        }
        tabBar.update(tabs: tabs, selected: tab?.id)

        // One view per pane on every connected machine, kept while the pane exists so its screen survives
        // tab and machine switches.
        var live = Set<PaneKey>()
        for (key, session) in sessions {
            for pane in session.store.state.panes where pane.exited == nil { live.insert(PaneKey(machine: key, pane: pane.id)) }
        }
        for (key, host) in paneHosts where !live.contains(key) {
            host.detach()
            paneHosts[key] = nil
        }
        maximized = maximized.filter { key, pane in sessions[key.machine]?.store.state.tab(key.tab)?.layout.contains(pane) == true }

        var shown: [PaneID: PaneHostView] = [:]
        for id in tab?.layout.panes ?? [] {
            let key = PaneKey(machine: focusedMachine, pane: id)
            guard let pane = state.pane(id), live.contains(key) else { continue }
            shown[id] = paneHosts[key] ?? makeHost(for: pane, on: focusedSession)
        }
        let maximizedPane = tab.flatMap { maximized[tabKey($0.id)] }
        splitView.show(tab?.layout, hosts: shown, maximized: maximizedPane)

        let focusedPane = store.focusedPane?.id
        for (id, host) in shown {
            host.isFocusedPane = id == focusedPane
            host.showsFocusRing = shown.count > 1 && maximizedPane == nil
        }

        let machineName = focusedSession.title
        if !store.isConnected && store.state.workspaces.isEmpty {
            emptyLabel.stringValue = "Connecting to \(machineName)…"
        } else if workspace == nil {
            emptyLabel.stringValue = "No sessions on \(machineName). Press ⌘N to start one."
        } else if tab == nil {
            emptyLabel.stringValue = "No tabs in \(workspace!.name). Press ⌘T to open one."
        } else {
            emptyLabel.stringValue = ""
        }
        let place = focusedMachine == Self.localKey ? workspace?.name : workspace.map { "\($0.name) on \(machineName)" }
        window.title = tab.map { "\(store.displayTitle(of: $0)) — \(place ?? "")" } ?? "Clotho"

        // Keyboard focus follows the daemon's focus, unless an overlay or sheet has it.
        if let focusedPane, let host = shown[focusedPane], shortcutsOverlay == nil, fileBrowser == nil,
           window.attachedSheet == nil, window.firstResponder !== host.terminal {
            window.makeFirstResponder(host.terminal)
        }
    }

    private func makeHost(for pane: Pane, on session: MachineSession) -> PaneHostView {
        let key = PaneKey(machine: session.key, pane: pane.id)
        let host = PaneHostView(pane: pane, store: session.store, font: Self.terminalFont(size: fontSize))
        host.terminal.machine = session.key
        host.terminal.onDropFiles = { [weak self] urls in self?.upload(urls, toPane: key) }
        host.terminal.contextMenu = { [weak self] in self?.paneMenu(for: key) }
        paneHosts[key] = host
        return host
    }

    // Clicking into a pane focuses it in its daemon, which every client shares.
    func firstResponderChanged() {
        guard let terminal = window.firstResponder as? PaneTerminalView, let session = sessions[terminal.machine],
              session.store.state.focus.pane != terminal.paneID, session.store.state.pane(terminal.paneID) != nil else { return }
        focus(machine: terminal.machine)
        let pane = terminal.paneID
        run { try await $0.focus(.pane(pane)) }
    }

    func bell(_ pane: PaneID) {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Spawning

    /// New panes start at the size they'll be shown at, so the shell doesn't draw its first prompt at 80×24.
    func spawnOptions(cwd: String? = nil, size: CGSize? = nil) -> SpawnOptions {
        var options = SpawnOptions(cwd: cwd)
        if let host = paneHosts.values.first(where: { $0.window != nil }) ?? paneHosts.values.first {
            let fitted = host.fittedSize(in: size ?? splitView.bounds.size)
            options.cols = fitted.cols
            options.rows = fitted.rows
        }
        return options
    }

    // MARK: Prompts

    func prompt(_ title: String, value: String, placeholder: String, then done: @escaping (String) -> Void) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            done(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    func renameWorkspace(_ id: WorkspaceID) {
        guard let workspace = store.state.workspace(id) else { return }
        prompt("Rename Session", value: workspace.name, placeholder: "Session name") { [weak self] name in
            guard !name.isEmpty else { return }
            self?.run { try await $0.renameWorkspace(id, name: name) }
        }
    }

    func renameTab(withID id: TabID) {
        guard let tab = store.state.tab(id) else { return }
        prompt("Rename Tab", value: tab.title ?? "", placeholder: "Leave empty to show the pane's title") { [weak self] title in
            self?.run { try await $0.renameTab(id, title: title.isEmpty ? nil : title) }
        }
    }

    // MARK: Closing (each asks first; see confirmClose)

    func closeWorkspace(_ id: WorkspaceID) {
        confirmClose("Session", info: "This closes all of its tabs and panes, and stops anything running in them.",
                     allowSkipping: false) { [weak self] in self?.run { try await $0.closeWorkspace(id) } }
    }

    func closeTab(_ id: TabID) {
        confirmClose("Tab", info: "This closes all of its panes and stops anything running in them.") { [weak self] in
            self?.run { try await $0.closeTab(id) }
        }
    }
}

extension AppDelegate {
    /// Shows a notice under the tab bar, replacing any earlier one. It never blocks the window.
    func showNotice(_ message: String, detail: String?, action: String?, then onAction: (() -> Void)?) {
        hideNotice()
        let bar = NoticeBar(message: message, detail: detail, action: action, onAction: onAction) { [weak self] in self?.hideNotice() }
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar, positioned: .above, relativeTo: splitView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
        ])
        noticeBar = bar
        container.layoutSubtreeIfNeeded()
        splitTop.constant = bar.fittingSize.height
    }

    func hideNotice() {
        noticeBar?.removeFromSuperview()
        noticeBar = nil
        splitTop?.constant = 0
    }
}
