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

    /// Focuses a workspace, tab or pane on a machine: shown at once, from the local model, then sent to
    /// the daemon (ModelStore.showFocus / sendFocus). The machine switches after the local focus is in
    /// place, so switching shows the clicked workspace rather than the machine's previous one first.
    /// FocusWaitsForDaemon=YES restores the old way (nothing changes until the daemon's state arrives),
    /// to compare timings with TraceClicks.
    func focusNow(_ target: FocusTarget, on key: MachineKey, trace: String) {
        guard let store = connections[key]?.store else { return }
        ClickTrace.begin("\(trace) @\(key == Self.localKey ? "local" : "remote")", machine: key, tab: store.state.focusing(target)?.focus.tab)
        if UserDefaults.standard.bool(forKey: "FocusWaitsForDaemon") {
            focus(machine: key)
            let backend = store.backend
            Task { @MainActor in try? await backend.focus(target) }
            return
        }
        let switching = connections[key] != nil && focusedMachine != key
        if switching { focusedMachine = key }
        let before = store.state
        store.showFocus(target)
        if switching && store.state == before { sync() }
        Task { @MainActor in
            do {
                try await store.sendFocus(target)
            } catch {
                log("focus \(target) on \(key) failed: \(error)")
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

        settingsWindow?.refreshIfNeeded()
        followFocusedPaneInFileSidebar()
        closeChangesDiffIfMoved()
        pruneWorkspaceHighlights()
        // An open command bar picks up the change once, after this pass.
        quickOpen?.setNeedsReload()
        let agents = agentEntries()
        ClickTrace.measure("sidebar update") {
            sidebar.update(agents: agents, groups: sidebarGroups())
        }
        updateDockBadge(agents)
        let tabs = (workspace?.tabs ?? []).map {
            (id: $0.id, title: store.displayTitle(of: $0), custom: $0.title, maximized: maximized[tabKey($0.id)] != nil,
             mark: agentMark(machine: focusedMachine, panes: $0.layout.panes)?.mark)
        }
        tabBar.machine = focusedMachine
        tabBar.workspace = workspace?.id
        tabBar.breadcrumb = workspace.flatMap { workspace in
            tab.map { (machine: focusedConnection.title, workspace: workspace.name, tab: store.displayTitle(of: $0)) }
        }
        tabBar.update(tabs: tabs, selected: tab?.id)

        // One view per pane on every connected machine, kept while the pane exists so its screen survives
        // tab and machine switches.
        var live = Set<PaneKey>()
        for (key, session) in connections {
            for pane in session.store.state.panes where pane.exited == nil { live.insert(PaneKey(machine: key, pane: pane.id)) }
        }
        for (key, host) in paneHosts where !live.contains(key) {
            host.detach()
            paneHosts[key] = nil
        }
        maximized = maximized.filter { key, pane in connections[key.machine]?.store.state.tab(key.tab)?.layout.contains(pane) == true }

        var shown: [PaneID: PaneHostView] = [:]
        for id in tab?.layout.panes ?? [] {
            let key = PaneKey(machine: focusedMachine, pane: id)
            guard let pane = state.pane(id), live.contains(key) else { continue }
            shown[id] = paneHosts[key] ?? makeHost(for: pane, on: focusedConnection)
        }
        let maximizedPane = tab.flatMap { maximized[tabKey($0.id)] }
        splitView.show(tab?.layout, hosts: shown, maximized: maximizedPane)
        if let target = ClickTrace.target, target.machine == focusedMachine, let id = target.tab, tab?.id == id {
            ClickTrace.mark("selected")
            if tab?.layout.panes.allSatisfy({ shown[$0] != nil }) == true { ClickTrace.mark("shown") }
            DispatchQueue.main.async { ClickTrace.mark("painted") }
        }

        let focusedPane = store.focusedPane?.id
        for (id, host) in shown {
            host.isFocusedPane = id == focusedPane
            host.showsFocusRing = shown.count > 1 && maximizedPane == nil
            host.restored = state.pane(id)?.restored
            host.git = git(id, in: store)
            // The header, the outline and the ask bar. An agent on a machine whose agents aren't watched
            // shows nowhere, so not here either.
            let pane = state.pane(id)
            host.chrome = PaneChrome(agent: monitorsAgents(focusedMachine) ? pane?.agent : nil, command: pane?.command, cwd: pane?.cwd,
                                     home: store.hello?.machine?.home, canDecide: store.features.contains(.agentDecide))
            // The 30 s clock (`agentClock`) lands here, so the header's time moves on.
            host.refreshElapsed()
        }

        let machineName = focusedConnection.title
        emptyLabel.stringValue = ""
        if !store.isConnected && store.state.workspaces.isEmpty {
            emptyState.isHidden = true
            emptyLabel.stringValue = "Connecting to \(machineName)…"
        } else if workspace == nil {
            emptyState.show(symbol: "square.stack.3d.up", title: machineName, line: "No workspaces on this machine yet.",
                            action: "New Workspace", shortcut: "⌘N") { [weak self] in self?.newWorkspace(nil) }
        } else if let workspace, tab == nil {
            emptyState.show(symbol: "terminal", title: workspace.name, line: "This workspace has no tabs open.",
                            action: "New Tab", shortcut: "⌘T") { [weak self] in self?.newTab(nil) }
        } else {
            emptyState.isHidden = true
        }
        let place = focusedMachine == Self.localKey ? workspace?.name : workspace.map { "\($0.name) on \(machineName)" }
        window.title = tab.map { "\(store.displayTitle(of: $0)) — \(place ?? "")" } ?? "Clotho"

        // Keyboard focus follows the daemon's focus, unless an overlay (the command bar previews tabs while
        // keeping the keyboard), a sheet, the sidebar, the inspector's Changes or Activity list, the centre
        // diff (every reply to `git.changes` comes with a `pane` event, so without this the arrow keys in
        // the list lost the keyboard mid-use), or a name being edited has it: in the sidebar (the
        // rename that follows New Workspace starts before the workspace's focus lands), in the tab bar, or
        // any other field being typed in. A sync runs on every retitle and output, so without this a busy
        // pane took the cursor out of a tab's name mid-rename.
        if let focusedPane, let host = shown[focusedPane], shortcutsOverlay == nil, fileBrowser == nil, quickOpen == nil,
           window.attachedSheet == nil, window.firstResponder !== host.terminal, !sidebar.hasKeyboard, !sidebar.isEditing,
           !tabBar.isEditing, !Self.isTypingInAField(window), !inspectorHoldsKeyboard, !isChangesDiffShown {
            if UserAction.isRecentOrCameForward(within: Self.userFocusWindow) {
                window.makeFirstResponder(host.terminal)
            } else {
                // Nothing the user did moved the focus here (another device focused the pane, a pane exited):
                // the pane takes the keyboard, but the daemon must not hear the user is at it. So no
                // `pane.focus` (PaneFocus.swift), and the terminal's focus-in report (ESC [ I, when the
                // pane's app has mode 1004 on) is held back rather than sent as input. Both are owed until the
                // user next does something in the window, and paid together then.
                if UserDefaults.standard.bool(forKey: "LogModel") || UserDefaults.standard.bool(forKey: "TraceFocus") {
                    log("pane \(focusedPane) on \(focusedMachine) takes the keyboard with no user action behind it: no pane.focus, no focus report")
                }
                let terminal = host.terminal
                let take = { terminal.takeKeyboardQuietly(in: self.window) }
                if let reporter = paneFocusReporter {
                    reporter.quietly(take) { [weak terminal] in terminal?.payFocusIn() }
                } else {
                    take()
                }
            }
        }
    }

    /// A focus change this long after a key or mouse event (or after the app came forward) is the user's:
    /// long enough for the round trip to a remote daemon after a tab click.
    static let userFocusWindow: TimeInterval = 2

    private func makeHost(for pane: Pane, on session: MachineConnection) -> PaneHostView {
        let key = PaneKey(machine: session.key, pane: pane.id)
        let host = PaneHostView(pane: pane, store: session.store, font: Self.terminalFont(size: terminalFontSize))
        host.terminal.machine = session.key
        host.terminal.onDropFiles = { [weak self] urls in self?.dropFiles(urls, on: key) }
        host.terminal.onPaste = { [weak self] terminal in self?.pasteImage(into: terminal, key: .command) ?? false }
        host.terminal.contextMenu = { [weak self] in self?.paneMenu(for: key) }
        host.onDecide = { [weak self] request, decision in
            self?.decide(machine: key.machine, pane: key.pane, request: request, decision)
        }
        host.agentMenu = { [weak self, weak session] in
            guard let self else { return nil }
            // The quick replies only when the agent itself says it waits for the user, as in the inbox.
            let agent = session?.store.state.pane(key.pane)?.agent
            let canReply = session?.store.hello?.features.contains(.paneKeys) == true && agent?.state == .waiting
                && agent?.needsAttention == true && agent?.isHookSourced == true
            return agentMenu(machine: key.machine, pane: key.pane, canReply: canReply)
        }
        host.onClose = { [weak self] in
            guard let self, focusedMachine == key.machine else { return }
            close(pane: key.pane)
        }
        host.onShowChanges = { [weak self] in self?.showInspector(.changes, takeKeyboard: true) }
        paneHosts[key] = host
        return host
    }

    // Clicking into a pane focuses it in its daemon, which every client shares.
    func firstResponderChanged() {
        // TraceFocus=YES logs who gave a terminal the keyboard (KVO runs inside makeFirstResponder), for
        // chasing focus taken from a field.
        if UserDefaults.standard.bool(forKey: "TraceFocus"), let terminal = window.firstResponder as? PaneTerminalView {
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(14).compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count > 3 ? String(parts[3]) : nil
            }
            log("focus: pane \(terminal.paneID) took the keyboard: \(frames.joined(separator: " < "))")
        }
        if window.firstResponder is PaneTerminalView { paneFocusReporter?.note("pane took the keyboard") }
        guard let terminal = window.firstResponder as? PaneTerminalView, let session = connections[terminal.machine],
              session.store.state.focus.pane != terminal.paneID, session.store.state.pane(terminal.paneID) != nil else { return }
        focusNow(.pane(terminal.paneID), on: terminal.machine, trace: "pane \(terminal.paneID)")
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

    // MARK: Renaming (in place, in the sidebar and the tab bar)

    /// A dropped workspace or tab: shown at once, then made on the daemon; a refused move goes back.
    func move(_ request: MoveRequest, on key: MachineKey) {
        guard let store = connections[key]?.store, let id = store.showMove(request) else { return }
        log("move \(request) on \(key)")
        Task { @MainActor in
            do { try await store.sendMove(request, id: id) } catch { log("move \(request) on \(key) failed: \(error)") }
        }
    }

    func renameWorkspace(_ id: WorkspaceID) {
        sidebar.beginRename(focusedMachine, id)
    }

    /// Whether the window's keyboard is in a text field being edited (its field editor has it).
    static func isTypingInAField(_ window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    func renameTab(withID id: TabID) {
        tabBar.beginRename(id)
    }

    /// The terminal takes the keyboard back after an inline rename, unless the click that ended it
    /// went to something else that takes typing.
    func focusTerminalAfterEdit() {
        guard window.firstResponder == nil || window.firstResponder === window else { return }
        window.makeFirstResponder(activeTerminal)
    }

    /// Keys the window handles before the terminal sees them. ⌘↩ and ⌘. answer a pane's permission
    /// request while its ask bar shows. Mac editing keys in a pane (Shift-Return,
    /// ⌘←, ⌘→, ⌘⌫) go out the way other Mac terminals send them; see `sendEditingKey`. Ctrl-Return
    /// renames the current workspace in place (Finder's rename is Return on a selected item; the
    /// terminal needs plain Return, so the sidebar takes it with Control).
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            // Typing in a pane that took the keyboard without the user (see `sync`) is the user at it.
            paneFocusReporter?.userActed()
            if let terminal = window.firstResponder as? PaneTerminalView {
                // ⌘↩ allows and ⌘. denies the permission request shown in this pane (AskBar.swift). Only
                // then: with no request showing, ⌘. reaches the terminal as before.
                if PaneHostView.handleAskKey(event, firstResponder: terminal) { return nil }
                if terminal.sendEditingKey(event) { return nil }
                // ⌃V with an image, for an agent on another machine (see ImagePaste).
                if event.charactersIgnoringModifiers?.lowercased() == "v", event.modifierFlags.intersection([.shift, .control, .option, .command]) == .control,
                   pasteImage(into: terminal, key: .control) { return nil }
            }
            guard [36, 76].contains(event.keyCode), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                  !(window.firstResponder is NSText) else { return event }
            renameActiveWorkspace(nil)
            return nil
        }
    }

    // MARK: Closing (each asks first; see confirmClose)

    func closeWorkspace(_ id: WorkspaceID) {
        confirmClose("Workspace", info: "This closes all of its tabs and panes, and stops anything running in them.",
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
