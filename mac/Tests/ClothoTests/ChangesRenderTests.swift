import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Review images of Changes (the app launched in this process on the fake backend, as in
/// UIRefreshRenderTests): the inspector on Changes with both groups and an inline diff, every empty and
/// error state, Files and Activity, the side-by-side diff in the centre, the pane strip with its count,
/// ⌘P with counts, and the worktree prompt (empty, with its preview, creating, and with an error). Each
/// in light and dark, in a narrow window (760×520, the sidebar at 150, the inspector at its least
/// width, 220) and a wide one (1280×800).
///
/// Runs only with CLOTHO_SNAPSHOT_DIR set. Everything is drawn from its layers, never the screen.
@MainActor
final class ChangesRenderTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func tearDown() { ChangesFixture.restore(saved) }

    func testSnapshotsForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        saved = ChangesFixture.prepare(features: "git.changes,worktree,agent.history,agent.decide,agent.mute")
        let savedAppearance = NSApp.appearance
        let app = ChangesFixture.launch()
        defer {
            ChangesFixture.quit(app)
            NSApp.appearance = savedAppearance
            Theme.followAppAppearance()
        }
        try await ChangesFixture.wait("a workspace") { app.store.focusedWorkspace != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        let first = app.store.state.workspaces.map(\.id)

        // "clotho" › "alerts": an agent at work in a repository with changes; "zsh": a plain shell.
        let now = Date().timeIntervalSince1970
        let created = try await fake.createWorkspace(name: "clotho", spawn: SpawnOptions(command: ["/bin/zsh", "-f"], cwd: "/tmp"))
        for id in first { try await fake.closeWorkspace(id) }
        try await fake.renameTab(created.tab, title: "alerts")
        let pane = created.pane
        let zsh = try await fake.createTab(in: created.workspace, spawn: SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp"))
        try await fake.renameTab(zsh.tab, title: "zsh")
        fake.setGit(zsh.pane, PaneGit(repo: "clotho", root: "/tmp/clotho-docs", branch: "docs", head: "c3d4e5f",
                                      changes: .init(uncommitted: .init(files: 3), branch: nil)))
        fake.setAgent(pane, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Editing clothod/src/daemon.rs", since: now - 95))
        fake.setAgentHistory(pane, [
            AgentHistoryEntry(at: now - 900, event: "state", kind: "claude", state: "running", message: "Reading the alert code", source: "hook"),
            AgentHistoryEntry(at: now - 420, event: "attention", kind: "claude", state: "waiting",
                              message: "Claude needs your permission to use Bash: cargo test -p clothod", source: "hook", attention: true),
            AgentHistoryEntry(at: now - 400, event: "attention", kind: "claude", state: "running", source: "hook", attention: false),
            AgentHistoryEntry(at: now - 95, event: "state", kind: "claude", state: "running", from: "waiting", message: "Editing clothod/src/daemon.rs", source: "hook"),
        ])
        ChangesFixture.fill(fake, pane)
        try await fake.focus(.pane(pane))
        try await ChangesFixture.wait("the pane in its repository") { app.store.focusedPane?.id == pane && app.store.focusedPane?.git?.changes != nil }

        let files = try XCTUnwrap(app.fileSidebar)
        let model = app.changesModel
        func settle() async throws {
            try await Task.sleep(nanoseconds: 150_000_000)
            app.window.contentView?.layoutSubtreeIfNeeded()
            app.window.displayIfNeeded()
        }
        func loaded() -> Bool { if case .loaded = model.list { true } else { false } }
        func diffed() -> Bool { if case .loaded = model.diff { true } else { false } }

        for (size, sidebar, inspector, width, height) in [("narrow", 150, 220, 760, 520), ("wide", 236, 320, 1280, 800)]
            as [(String, CGFloat, CGFloat, CGFloat, CGFloat)] {
            app.window.setContentSize(NSSize(width: width, height: height))
            app.sidebarWidth.constant = sidebar
            for mode in [Theme.Mode.light, .dark] {
                let name = "\(size)-\(mode.rawValue)"
                app.setAppearance(mode)
                try await settle()
                app.appearanceChanged()
                app.showInspector(.changes, takeKeyboard: false)
                files.onResize?(inspector)
                try await settle()

                // Changes: both groups, a file selected, its diff under the list. The strip has the count.
                ChangesFixture.fill(fake, pane)
                model.refresh()
                try await ChangesFixture.wait("the list, \(name)") { loaded() }
                model.select(ChangesFixture.daemon, group: .uncommitted)
                try await ChangesFixture.wait("the diff, \(name)") { diffed() }
                try await settle()
                XCTAssertFalse(files.changesView.list.isHiddenOrHasHiddenAncestor)
                XCTAssertGreaterThan(files.changesView.diffArea.table.items.count, 5)
                let strip = try XCTUnwrap(app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: pane)]?.gitStrip)
                XCTAssertNotEqual(strip.countForm, .hidden, "the strip's count, \(name)")
                saveSnapshot(of: app.container, to: "\(folder)/changes-\(name).png")

                // The diff's own states, in the inspector alone.
                for (state, file) in [("truncated", ChangesFixture.branchDaemon), ("binary", ChangesFixture.logo), ("renamed", ChangesFixture.moved),
                                      ("undiffable", ChangesFixture.odd), ("diff-error", ChangesFixture.push)] {
                    model.select(file, group: .branch)
                    try await ChangesFixture.wait("\(state), \(name)") { model.diff != .loading }
                    try await settle()
                    saveSnapshot(of: files, to: "\(folder)/inspector-\(state)-\(name).png")
                }

                // The full diff, side by side, over the panes.
                model.select(ChangesFixture.daemon, group: .uncommitted)
                try await ChangesFixture.wait("the diff again, \(name)") { diffed() }
                app.openChangesDiff()
                try await ChangesFixture.wait("the side-by-side rows, \(name)") { app.changesDiff.diffArea.table.items.count > 5 }
                try await settle()
                XCTAssertEqual(app.changesDiff.list.isHidden, size == "narrow", "its own list only where there is room")
                saveSnapshot(of: app.container, to: "\(folder)/diff-\(name).png")
                app.closeChangesDiff()
                model.select(nil, group: .uncommitted)
                // Nothing selected again: the list has the whole inspector, with no line where the diff began.
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-no-selection-\(name).png")

                // The list's states: no repository, still reading, a reason, nothing changed, an error.
                fake.setGit(pane, nil)
                try await ChangesFixture.wait("not a repo, \(name)") { model.list == .notARepo }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-not-a-repo-\(name).png")
                fake.setGit(pane, ChangesFixture.git(nil, reason: "pending"))
                try await ChangesFixture.wait("pending, \(name)") { model.list == .unknown(GitText.readingChanges, pending: true) }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-pending-\(name).png")
                fake.setGit(pane, ChangesFixture.git(nil, reason: "partial_clone"))
                try await ChangesFixture.wait("a reason, \(name)") { if case .unknown(_, pending: false) = model.list { true } else { false } }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-reason-\(name).png")
                fake.setGit(pane, ChangesFixture.git(PaneGit.Changes(uncommitted: .init(files: 0, added: 0, removed: 0))))
                try await ChangesFixture.wait("no changes, \(name)") { model.list == .empty }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-no-changes-\(name).png")
                fake.setChanges(pane, .failure(BackendError(code: "timeout", message: "git took too long")))
                fake.setGit(pane, ChangesFixture.git(ChangesFixture.changes.summary))
                try await ChangesFixture.wait("a list error, \(name)") { if case .failed = model.list { true } else { false } }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-list-error-\(name).png")
                ChangesFixture.fill(fake, pane)
                model.refresh()
                try await ChangesFixture.wait("the list back, \(name)") { loaded() }

                // Files and Activity.
                app.showInspector(.files, takeKeyboard: false)
                try await ChangesFixture.wait("the pane's folder, \(name)") { files.pane.path == "/tmp" || files.pane.path == "/private/tmp" }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-files-\(name).png")
                app.showInspector(.activity, takeKeyboard: false)
                try await ChangesFixture.wait("the history, \(name)") { files.activityView.entries.count == 4 }
                try await settle()
                saveSnapshot(of: files, to: "\(folder)/inspector-activity-\(name).png")
                app.showInspector(.changes, takeKeyboard: false)

                // ⌘P: the rows carry the branch and, after it, the count.
                app.showQuickOpen(nil)
                let bar = try XCTUnwrap(app.quickOpen)
                try await settle()
                XCTAssertNotNil(bar.rows.first { $0.entry.changes != nil }, "a row with a count, \(name)")
                saveSnapshot(of: app.container, to: "\(folder)/cmdp-\(name).png")
                bar.setQuery(">new")
                try await settle()
                saveSnapshot(of: bar.card, to: "\(folder)/cmdp-commands-\(name).png")
                bar.cancel()
                try await ChangesFixture.wait("the command bar closed, \(name)") { app.quickOpen == nil }
                try await fake.focus(.pane(pane))
                try await ChangesFixture.wait("the pane focused again, \(name)") { app.store.focusedPane?.id == pane }

                // New Tab in a Worktree…: empty, with its preview, creating, and with an error.
                app.newWorktreeTab(nil)
                let prompt = try XCTUnwrap(app.quickOpen)
                XCTAssertNotNil(prompt.naming)
                try await settle()
                saveSnapshot(of: prompt.card, to: "\(folder)/worktree-empty-\(name).png")
                prompt.setWorktreeName("fix/login", base: "origin/main")
                try await settle()
                saveSnapshot(of: app.container, to: "\(folder)/worktree-\(name).png")
                fake.worktreeDelay = 0.8
                fake.worktreeError = BackendError(code: "worktree_exists", message: "/tmp/clotho-fix-login")
                prompt.submitWorktree()
                XCTAssertTrue(prompt.isCreating)
                try await settle()
                saveSnapshot(of: app.container, to: "\(folder)/worktree-creating-\(name).png")
                try await ChangesFixture.wait("the error, \(name)") { prompt.namingError != nil }
                try await settle()
                saveSnapshot(of: prompt.card, to: "\(folder)/worktree-error-\(name).png")
                // The longest words there are: the worktree was made, its Tab wasn't.
                prompt.showWorktreeError(GitText.worktreeError(BackendError(code: "spawn_failed", message:
                    "no such command (the worktree /tmp/clotho-fix-login on the new branch fix/login was created and is still there)")))
                try await settle()
                saveSnapshot(of: prompt.card, to: "\(folder)/worktree-left-behind-\(name).png")
                prompt.dismiss()
                fake.worktreeDelay = 0
                fake.worktreeError = nil
            }
        }
    }
}
