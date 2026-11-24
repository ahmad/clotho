import AppKit
import ClothoKit

// "New Tab in a Worktree…" (⌘P's ">" commands, File › New Tab in a Worktree…, ⌥⌘T): a new git worktree
// on a new branch, beside the repository the focused pane is in, with a new Tab in it. For starting an
// agent on its own checkout, so two never edit the same files. It needs clothod 0.1.32 (feature
// `worktree`) on the pane's machine; without it, or outside a repository, the command isn't offered.
//
// The command bar asks for the branch's name and, optionally, where it starts (QuickOpen.swift). The
// daemon answers when the checkout is done, which can take two minutes in a big repository: the bar
// shows it working and the tab bar a small spinner, and the window stays usable (Esc puts the bar away
// and the work goes on). One worktree is made at a time. Errors are said in plain words, under the
// fields or in a notice when the bar is away. Two of them leave the worktree behind (the Tab couldn't
// be opened in it): the words say so and name the folder, and there is no retry, which would only find
// the folder already there. Clotho never removes a worktree.

/// Where a worktree would be made: the Workspace the Tab goes in, and a pane in the repository.
struct WorktreeSubject: Equatable {
    var machine: MachineKey
    var machineName: String
    var workspace: WorkspaceID
    var pane: PaneID
    /// The pane's folder: it names the repository to the daemon.
    var cwd: String
    var git: PaneGit

    /// The repository's name, which the new folder's name starts with.
    var repo: String { git.repo }
}

/// A worktree being made.
struct WorktreeCreation: Equatable {
    var subject: WorktreeSubject
    var name: String
    var base: String?

    /// The folder's name, as the daemon makes it: "<repo>-<name with / as ->".
    var folder: String { "\(subject.repo)-\(name.replacingOccurrences(of: "/", with: "-"))" }
}

extension AppDelegate {
    /// Where the command would work for a row of the command bar (nil: for the focused pane): the
    /// selected Tab's active pane, an agent's pane, a Workspace's active Tab's pane, else the pane
    /// focused when the bar opened. Nil outside a repository and on a machine without `worktree`.
    func worktreeSubject(for node: CommandTree.Node?, origin: (machine: MachineKey, pane: PaneID?, tab: TabID?)?) -> WorktreeSubject? {
        let key = node?.machine ?? origin?.machine ?? focusedMachine
        guard let session = connections[key], session.store.isConnected, session.store.features.contains(.worktree) else { return nil }
        let state = session.store.state
        var pane: PaneID?
        switch node {
        case let .tab(_, id)?: pane = state.tab(id)?.activePane
        case let .agent(_, id)?: pane = id
        case let .workspace(_, id)?:
            let workspace = state.workspaces.first { $0.id == id }
            pane = (workspace?.tabs.first { $0.id == workspace?.activeTab } ?? workspace?.tabs.first)?.activePane
        case .machine?, nil: pane = key == origin?.machine ? origin?.pane : nil
        }
        guard let pane = pane ?? session.store.focusedPane?.id, let found = state.pane(pane), found.exited == nil,
              let cwd = found.cwd, !cwd.isEmpty, let git = git(pane, in: session.store),
              let workspace = state.location(of: pane)?.workspace.id else { return nil }
        return WorktreeSubject(machine: key, machineName: session.title, workspace: workspace, pane: pane, cwd: cwd, git: git)
    }

    /// File › New Tab in a Worktree… (⌥⌘T): the command bar, straight at its prompt.
    @objc func newWorktreeTab(_ sender: Any?) {
        // The new Tab is made where the focus is: in view, not under the Overview.
        uncoverWindow()
        guard let subject = worktreeSubject(for: nil, origin: nil) else { return NSSound.beep() }
        promptForWorktree(subject, name: "", base: "")
    }

    /// Opens the prompt for `subject`, prefilled. While a worktree is being made it shows that one, at
    /// work: there is one at a time.
    func promptForWorktree(_ subject: WorktreeSubject, name: String, base: String) {
        if quickOpen == nil { showQuickOpen(nil) }
        guard let quickOpen else { return }
        if let running = worktreeCreation {
            quickOpen.beginNaming(running.subject, direct: true, name: running.name, base: running.base ?? "")
            quickOpen.setCreating(true)
        } else {
            quickOpen.beginNaming(subject, direct: true, name: name, base: base)
        }
    }

    /// Whether the menu item applies now: the focused pane is in a repository, on a machine that makes
    /// worktrees.
    var canMakeWorktreeTab: Bool { worktreeSubject(for: nil, origin: nil) != nil }

    /// Makes the worktree and its Tab. The daemon focuses the new Tab when it's there.
    func createWorktreeTab(_ subject: WorktreeSubject, name: String, base: String?) {
        guard worktreeCreation == nil else {
            // The prompt that started the one under way keeps showing it; another prompt is told.
            if quickOpen?.isCreating != true { quickOpen?.showWorktreeError("A worktree is already being created.") }
            return
        }
        guard let store = connections[subject.machine]?.store else {
            quickOpen?.showWorktreeError("Not connected to \(subject.machineName).")
            return
        }
        let creation = WorktreeCreation(subject: subject, name: name, base: base)
        worktreeCreation = creation
        quickOpen?.setCreating(true)
        tabBar.busyText = "Creating worktree \(DiffText.display(creation.folder))…"
        log("worktree: creating \(creation.folder) on \(subject.machine)")
        let backend = store.backend
        let options = spawnOptions(cwd: subject.cwd)
        Task { @MainActor [weak self] in
            let result: Result<CreatedTab, Error>
            do {
                result = .success(try await backend.createTab(in: subject.workspace, spawn: options, worktree: WorktreeRequest(name: name, base: base)))
            } catch { result = .failure(error) }
            self?.worktreeFinished(creation, result)
        }
    }

    /// The words for a failed create. A dropped connection is its own case: the daemon may have gone on.
    static func worktreeWords(_ error: Error, machine: String) -> String {
        if (error as? BackendError)?.code == "disconnected", !error.worktreeLeftBehind {
            return "The connection to \(machine) dropped. The worktree may still have been created."
        }
        return GitText.worktreeError(error, machine: machine)
    }

    private func worktreeFinished(_ creation: WorktreeCreation, _ result: Result<CreatedTab, Error>) {
        worktreeCreation = nil
        tabBar.busyText = nil
        // The bar is still up, showing this worktree at work.
        let watching = quickOpen?.isCreating == true
        switch result {
        case let .success(created):
            log("worktree: \(created.worktree?.path ?? creation.folder) on \(created.worktree?.branch ?? creation.name), tab \(created.tab)")
            if watching { quickOpen?.dismiss() }
        case let .failure(error):
            let words = Self.worktreeWords(error, machine: creation.subject.machineName)
            log("worktree: \(creation.folder) failed: \(error)")
            if watching {
                quickOpen?.showWorktreeError(words)
                return
            }
            // The bar is away. A worktree that was made, or may have been, isn't offered again: a second
            // try would only find the folder there.
            let retry = !error.worktreeLeftBehind && (error as? BackendError)?.code != "disconnected"
            showNotice(words, detail: nil, action: retry ? "Edit…" : nil) { [weak self] in
                guard let self else { return }
                hideNotice()
                promptForWorktree(creation.subject, name: creation.name, base: creation.base ?? "")
            }
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Items that apply only sometimes; everything else is always on, as before.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newWorktreeTab(_:)): return canMakeWorktreeTab
        case #selector(showInspectorChanges(_:)), #selector(showInspectorActivity(_:)): return store.features.contains(.gitChanges)
        default: return true
        }
    }
}
