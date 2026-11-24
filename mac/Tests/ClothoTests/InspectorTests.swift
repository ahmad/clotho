import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The inspector in the real main window, on the fake backend: its three views against a daemon that
/// lists changes and the plain file sidebar against one that doesn't; the Changes list keeping the
/// keyboard through the model's updates; the centre diff, which creates nothing on the daemon and goes
/// back with Esc, ⌘W, or when the focus moves.
@MainActor
final class InspectorTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func tearDown() { ChangesFixture.restore(saved) }

    private func launch(_ features: String) async throws -> (AppDelegate, FakeBackend, PaneID) {
        saved = ChangesFixture.prepare(features: features)
        let app = ChangesFixture.launch()
        try await ChangesFixture.wait("a pane with a folder") { app.store.focusedPane?.cwd != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        return (app, fake, try XCTUnwrap(app.store.focusedPane?.id))
    }

    private func menuItem(_ action: Selector) -> NSMenuItem? {
        AppDelegate.makeMainMenu().items.compactMap(\.submenu).flatMap(\.items).first { $0.action == action }
    }

    func testWithoutTheFeatureItIsTheFileSidebarAsBefore() async throws {
        let (app, fake, pane) = try await launch("")
        defer { ChangesFixture.quit(app) }
        // The view picked on another machine is kept, not shown.
        UserDefaults.standard.set("activity", forKey: FileSidebarView.kindKey)
        let files = try XCTUnwrap(app.fileSidebar)
        fake.setGit(pane, ChangesFixture.git(nil))
        try await ChangesFixture.wait("git on the pane") { app.store.focusedPane?.git != nil }
        app.showOrHideFileSidebar(nil)
        app.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(files.available)
        XCTAssertEqual(files.shown, .files)
        XCTAssertTrue(files.segmented.isHidden, "no segmented control")
        XCTAssertFalse(files.pane.isHidden)
        XCTAssertTrue(files.changesView.isHidden)
        XCTAssertTrue(files.activityView.isHidden)
        XCTAssertEqual(files.title.frame.midY, files.bounds.maxY - FileSidebarView.bandHeight / 2, accuracy: 1.5, "the machine's name in the band, as before")
        XCTAssertEqual(files.pane.frame.height, files.bounds.height - FileSidebarView.bandHeight, accuracy: 0.5, "the list right under the band")
        XCTAssertEqual(files.accessibilityLabel(), "Files")
        XCTAssertEqual(UserDefaults.standard.string(forKey: FileSidebarView.kindKey), "activity", "not overwritten")
        // View › Changes can't show there, and the strip has no count.
        XCTAssertFalse(app.validateMenuItem(try XCTUnwrap(menuItem(#selector(AppDelegate.showInspectorChanges(_:))))))
        XCTAssertTrue(app.validateMenuItem(try XCTUnwrap(menuItem(#selector(AppDelegate.showInspectorFiles(_:))))))
        app.showInspector(.changes, takeKeyboard: false)
        XCTAssertEqual(files.shown, .files, "asked for Changes: Files, the only view there")
        let strip = try XCTUnwrap(app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: pane)]?.gitStrip)
        XCTAssertTrue(strip.changeCount.isHidden)
        // No worktree command either.
        XCTAssertFalse(app.canMakeWorktreeTab)
        XCTAssertFalse(app.validateMenuItem(try XCTUnwrap(menuItem(#selector(AppDelegate.newWorktreeTab(_:))))))
        app.showQuickOpen(nil)
        let bar = try XCTUnwrap(app.quickOpen)
        bar.setQuery(">")
        XCTAssertFalse(bar.rows.map(\.entry.item.title).contains("New Tab in a Worktree…"))
        XCTAssertNil(bar.rows.first { $0.entry.changes != nil })
        bar.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fake.gitChangesCalls.isEmpty, "nothing was asked of a daemon that can't answer")
    }

    func testThreeViewsRememberedAndFittingTheLeastWidth() async throws {
        let (app, fake, pane) = try await launch("git.changes,worktree,agent.history")
        defer { ChangesFixture.quit(app) }
        let files = try XCTUnwrap(app.fileSidebar)
        let layout = { app.window.contentView?.layoutSubtreeIfNeeded() }
        ChangesFixture.fill(fake, pane)
        app.showOrHideFileSidebar(nil)
        layout()
        XCTAssertTrue(files.available)
        XCTAssertFalse(files.segmented.isHidden)
        XCTAssertEqual(files.segmented.segmentCount, 3)
        XCTAssertEqual((0..<3).map { files.segmented.label(forSegment: $0) }, ["Changes", "Files", "Activity"])
        XCTAssertEqual(files.segmented.accessibilityLabel(), "Inspector view")
        XCTAssertEqual(files.shown, .changes, "Changes first")
        XCTAssertEqual(files.segmented.selectedSegment, 0)
        XCTAssertFalse(files.changesView.isHidden)
        XCTAssertTrue(files.pane.isHidden)
        XCTAssertEqual(files.accessibilityLabel(), "Inspector")
        XCTAssertEqual(menuItem(#selector(AppDelegate.showOrHideFileSidebar(_:)))?.title, "Toggle Inspector")
        XCTAssertEqual(app.fileSidebarToggle?.toolTip, "Show/Hide Inspector (⌥⌘B)")
        XCTAssertTrue(app.validateMenuItem(try XCTUnwrap(menuItem(#selector(AppDelegate.showInspectorChanges(_:))))))

        // At the least width the control fits beside the toggle, whole.
        files.onResize?(AppDelegate.fileSidebarWidthRange.lowerBound)
        layout()
        let toggle = try XCTUnwrap(app.fileSidebarToggle)
        XCTAssertEqual(files.frame.width, 220, accuracy: 0.5)
        let control = files.segmented.convert(files.segmented.bounds, to: app.container)
        XCTAssertGreaterThanOrEqual(control.minX, files.frame.minX)
        XCTAssertLessThanOrEqual(control.maxX, toggle.frame.minX, "clear of the toggle")
        let labels = FileSidebarView.segmentLabelWidths(font: files.segmented.font)
        for (index, label) in labels.enumerated() {
            XCTAssertGreaterThanOrEqual(files.segmented.width(forSegment: index), label + FileSidebarView.segmentMinPadding, "segment \(index) reads whole")
        }
        XCTAssertLessThanOrEqual((0..<3).map { files.segmented.width(forSegment: $0) }.reduce(0, +), files.segmented.frame.width, "and all three fit the control")
        try await ChangesFixture.wait("the list") { files.changesView.list.rows.count > 2 }
        layout()
        XCTAssertEqual(files.changesView.summary.stringValue, "21 files vs main")
        XCTAssertEqual(files.changesView.counts.attributedStringValue.string, "+127 \u{2212}63")
        XCTAssertLessThanOrEqual(files.changesView.refreshButton.frame.maxX, files.changesView.bounds.maxX, "the summary row fits at 220 pt")
        XCTAssertGreaterThanOrEqual(files.changesView.counts.frame.width, files.changesView.counts.intrinsicContentSize.width - 0.5)

        // Files: its own line moves under the band; nothing else about it changes.
        files.segmented.selectedSegment = 1
        files.segmented.sendAction(files.segmented.action, to: files.segmented.target)
        layout()
        XCTAssertEqual(files.shown, .files)
        XCTAssertFalse(files.pane.isHidden)
        XCTAssertTrue(files.changesView.isHidden)
        XCTAssertEqual(files.pane.frame.height, files.bounds.height - FileSidebarView.bandHeight - FileSidebarView.filesRowHeight, accuracy: 0.5)
        XCTAssertEqual(files.title.stringValue, ComputerName.current)
        let cwd = try XCTUnwrap(app.store.focusedPane?.cwd)
        try await ChangesFixture.wait("the pane's folder") { files.pane.path == cwd }

        // Activity is remembered through hiding and showing, and through a machine without the views.
        app.showInspector(.activity, takeKeyboard: false)
        XCTAssertEqual(files.shown, .activity)
        XCTAssertEqual(UserDefaults.standard.string(forKey: FileSidebarView.kindKey), "activity")
        XCTAssertEqual(files.activityView.message.label.stringValue, "No agent in this pane")
        app.showOrHideFileSidebar(nil)
        app.showOrHideFileSidebar(nil)
        XCTAssertEqual(files.shown, .activity)
        files.setAvailable(false)
        XCTAssertEqual(files.shown, .files)
        files.setAvailable(true)
        XCTAssertEqual(files.shown, .activity)
        XCTAssertEqual(files.segmented.selectedSegment, 2)

        // An agent's history shows, newest first.
        let now = Date().timeIntervalSince1970
        fake.setAgentHistory(pane, [AgentHistoryEntry(at: now - 60, event: "state", kind: "claude", state: "running", message: "Editing daemon.rs"),
                                    AgentHistoryEntry(at: now - 5, event: "attention", kind: "claude", state: "waiting", message: "Allow Bash?", attention: true)])
        fake.setAgent(pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Allow Bash?", since: now - 5))
        try await ChangesFixture.wait("the history") { files.activityView.entries.count == 2 }
        XCTAssertEqual(files.activityView.entries.first?.eventName, "attention", "newest first")
        XCTAssertNil(files.activityView.words)

        // It shows with the left sidebar closed, as the file sidebar did.
        app.showOrHideSidebar(nil)
        layout()
        XCTAssertTrue(app.isSidebarHidden)
        XCTAssertFalse(files.isHidden)
        XCTAssertEqual(files.frame.maxX, app.container.bounds.width, accuracy: 0.5)
        app.showOrHideSidebar(nil)
    }

    func testTheListKeepsTheKeyboardAndTheCentreDiffCreatesNothing() async throws {
        let (app, fake, pane) = try await launch("git.changes,worktree")
        defer { ChangesFixture.quit(app) }
        let files = try XCTUnwrap(app.fileSidebar)
        let list = files.changesView.list
        ChangesFixture.fill(fake, pane)
        try await ChangesFixture.wait("the summary on the pane") { app.store.focusedPane?.git?.changes != nil }

        // The strip's count opens the inspector on Changes, with the keyboard in its list.
        let host = try XCTUnwrap(app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: pane)])
        let strip = try XCTUnwrap(host.gitStrip)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.changeCount.attributedTitle.string.hasPrefix("+127 \u{2212}63"), true)
        XCTAssertFalse(app.isFileSidebarShown)
        strip.changeCount.performClick(nil)
        XCTAssertTrue(app.isFileSidebarShown)
        XCTAssertEqual(files.shown, .changes)
        XCTAssertTrue(files.hasKeyboard)
        XCTAssertTrue(app.window.firstResponder === list.table)
        try await ChangesFixture.wait("the list") { list.rows.count > 2 }
        XCTAssertEqual(fake.gitChangesCalls, [pane], "one read")

        // Model changes (a pane event, a sync) leave the keyboard in the list.
        try await fake.renameTab(try XCTUnwrap(app.store.focusedTab?.id), title: "alerts")
        var newer = ChangesFixture.git(ChangesFixture.changes.summary)
        newer.prReason = "none"
        fake.setGit(pane, newer)
        try await ChangesFixture.wait("the rename") { app.store.focusedTab?.title == "alerts" }
        app.sync()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(app.window.firstResponder === list.table, "the terminal didn't take the keyboard back")

        // A file selected: its diff shows under the list.
        list.takeKeyboard()
        XCTAssertEqual(app.changesModel.selection?.path, ChangesFixture.daemon.path)
        try await ChangesFixture.wait("the inline diff") { files.changesView.diffArea.table.items.count > 5 }
        XCTAssertFalse(files.changesView.diffArea.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(fake.gitDiffRequests.first?.path, ChangesFixture.daemon.path)

        // Return: the side-by-side diff over the panes. Nothing is made on the daemon.
        let before = app.store.state
        let splitFrame = app.splitView.frame
        list.openSelected()
        XCTAssertTrue(app.isChangesDiffShown)
        XCTAssertTrue(app.window.firstResponder === app.changesDiff)
        app.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(app.changesDiff.frame, app.splitView.frame, "over the pane area")
        XCTAssertEqual(app.splitView.frame, splitFrame, "which keeps its size")
        XCTAssertEqual(app.changesDiff.backButton.title, "‹ alerts")
        XCTAssertEqual(app.changesDiff.path.stringValue, ChangesFixture.daemon.path)
        XCTAssertEqual(app.changesDiff.leftTitle.stringValue, "HEAD")
        XCTAssertEqual(app.changesDiff.rightTitle.stringValue, "working tree")
        try await ChangesFixture.wait("the side-by-side rows") { app.changesDiff.diffArea.table.items.count > 5 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(app.store.state.workspaces, before.workspaces, "no Tab, no pane")
        XCTAssertEqual(app.store.state.panes.map(\.id), before.panes.map(\.id))
        app.sync()
        XCTAssertTrue(app.window.firstResponder === app.changesDiff, "a sync leaves the keyboard there")

        // Copy Path and Open in Editor use the root and the path, joined.
        var copied: [String] = []
        app.changesDiff.copy = { copied.append($0) }
        app.changesDiff.copyButton.performClick(nil)
        XCTAssertEqual(copied, ["/tmp/clotho/clothod/src/daemon.rs"])
        XCTAssertTrue(app.changesDiff.openButton.isEnabled)
        var opened: [String] = []
        app.changesDiff.onOpenInEditor = { opened.append("\($0):\($1)") }
        app.changesDiff.openButton.performClick(nil)
        XCTAssertEqual(opened, ["\(AppDelegate.localKey):/tmp/clotho/clothod/src/daemon.rs"])

        // ↓ steps through the files; a deleted one can't be opened, one without an exact name not even copied.
        app.changesModel.select(ChangesFixture.gone, group: .branch)
        XCTAssertFalse(app.changesDiff.openButton.isEnabled)
        XCTAssertTrue(app.changesDiff.copyButton.isEnabled)
        XCTAssertEqual(app.changesDiff.leftTitle.stringValue, "main")
        XCTAssertEqual(app.changesDiff.rightTitle.stringValue, "clothod/clear-alerts")
        app.changesModel.select(ChangesFixture.odd, group: .branch)
        XCTAssertFalse(app.changesDiff.copyButton.isEnabled)
        XCTAssertEqual(app.changesDiff.diffArea.message.label.stringValue, DiffAreaView.undiffableWords)
        app.changesModel.select(ChangesFixture.logo, group: .branch)
        try await ChangesFixture.wait("the binary file's words") { app.changesDiff.diffArea.message.label.stringValue == DiffAreaView.binaryWords }

        // Esc goes back, and the terminal has the keyboard again.
        app.changesDiff.cancelOperation(nil)
        XCTAssertFalse(app.isChangesDiffShown)
        XCTAssertTrue(app.window.firstResponder === app.activeTerminal)
        // ⌘W closes the diff, not the pane: nothing asks to close anything.
        app.openChangesDiff()
        XCTAssertTrue(app.isChangesDiffShown)
        app.closePane(nil)
        XCTAssertFalse(app.isChangesDiffShown)
        XCTAssertNil(app.window.attachedSheet, "no Close Pane question")
        XCTAssertEqual(app.store.state.panes.map(\.id), before.panes.map(\.id))
        // Another Tab closes it.
        app.openChangesDiff()
        let workspace = try XCTUnwrap(app.store.focusedWorkspace?.id)
        let other = try await fake.createTab(in: workspace, spawn: SpawnOptions(command: ["/bin/sleep", "60"], cwd: "/tmp"))
        try await ChangesFixture.wait("the new Tab focused") { app.store.focusedTab?.id == other.tab }
        try await ChangesFixture.wait("the diff closed") { !app.isChangesDiffShown }
        // The list stayed on its work tree (a file is selected), and offers the way back.
        XCTAssertEqual(app.changesModel.target?.pane, pane)
        XCTAssertFalse(app.changesModel.following)
        try await ChangesFixture.wait("Follow Pane") { !files.changesView.followButton.isHiddenOrHasHiddenAncestor }
        files.changesView.followButton.performClick(nil)
        XCTAssertTrue(app.changesModel.following)
        XCTAssertEqual(files.changesView.message.label.stringValue, "This pane isn't in a git repository.")
        XCTAssertTrue(files.changesView.followButton.isHiddenOrHasHiddenAncestor)
    }
}
