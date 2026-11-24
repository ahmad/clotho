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

    /// The list holds the keyboard against the terminal only where the focus was when it took it: a new
    /// Tab's shell gets the keys, whether the list took the keyboard from the strip's count or by a click.
    func testAnotherTabTakesTheKeyboardFromTheList() async throws {
        let (app, fake, pane) = try await launch("git.changes,worktree")
        defer { ChangesFixture.quit(app) }
        let files = try XCTUnwrap(app.fileSidebar)
        let list = files.changesView.list
        ChangesFixture.fill(fake, pane)
        try await ChangesFixture.wait("the summary on the pane") { app.store.focusedPane?.git?.changes != nil }
        app.showInspector(.changes, takeKeyboard: true)
        try await ChangesFixture.wait("the list") { list.rows.count > 2 }
        app.sync()
        XCTAssertTrue(app.window.firstResponder === list.table, "the focus didn't move: the list keeps the keyboard")

        // ⌘T: the new Tab's terminal has the keyboard.
        let first = try XCTUnwrap(app.store.focusedTab?.id)
        app.newTab(nil)
        try await ChangesFixture.wait("the new Tab") { app.store.focusedTab.map { $0.id != first } == true }
        try await ChangesFixture.wait("its terminal has the keyboard") {
            app.activeTerminal != nil && app.window.firstResponder === app.activeTerminal
        }
        XCTAssertFalse(files.hasKeyboard)

        // A click on a row takes the keyboard without a sync in between; the next Tab still gets it.
        XCTAssertTrue(app.window.makeFirstResponder(list.table))
        let second = try XCTUnwrap(app.store.focusedTab?.id)
        app.newTab(nil)
        try await ChangesFixture.wait("the third Tab") { app.store.focusedTab.map { $0.id != second } == true }
        try await ChangesFixture.wait("its terminal has the keyboard") {
            app.activeTerminal != nil && app.window.firstResponder === app.activeTerminal
        }
        // Back in the list, on this Tab now, syncs leave it there.
        XCTAssertTrue(app.window.makeFirstResponder(list.table))
        app.sync()
        app.sync()
        XCTAssertTrue(app.window.firstResponder === list.table)
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

        // Whatever takes the keyboard while the diff is up gives it back to the diff, never to the
        // terminal under it: the next Esc must close the diff, not reach the pane's program.
        let terminal = try XCTUnwrap(app.activeTerminal)
        func assertTheDiffHasTheKeyboard(_ after: String, line: UInt = #line) {
            XCTAssertTrue(app.isChangesDiffShown, "the diff stays up after \(after)", line: line)
            XCTAssertTrue(app.window.firstResponder === app.changesDiff, "the diff has the keyboard after \(after)", line: line)
            XCTAssertFalse(app.window.firstResponder === terminal, "not the covered terminal, after \(after)", line: line)
        }
        app.showQuickOpen(nil)
        let bar = try XCTUnwrap(app.quickOpen)
        XCTAssertFalse(app.window.firstResponder === app.changesDiff, "the command bar is typed in")
        bar.cancel()
        XCTAssertNil(app.quickOpen)
        assertTheDiffHasTheKeyboard("⌘P then Esc")
        app.showShortcuts(nil)
        try XCTUnwrap(app.shortcutsOverlay).cancelOperation(nil)
        XCTAssertNil(app.shortcutsOverlay)
        assertTheDiffHasTheKeyboard("the shortcuts card then Esc")
        // Esc in the inspector's list (in a narrow window it drives the diff).
        list.takeKeyboard()
        XCTAssertTrue(app.window.firstResponder === list.table)
        list.table.cancelOperation(nil)
        assertTheDiffHasTheKeyboard("Esc in the inspector's list")
        // The inspector hidden with the keyboard in its list.
        list.takeKeyboard()
        app.showOrHideFileSidebar(nil)
        XCTAssertFalse(app.isFileSidebarShown)
        assertTheDiffHasTheKeyboard("hiding the inspector")
        app.showOrHideFileSidebar(nil)
        XCTAssertTrue(app.isFileSidebarShown)
        // A name edited inline ends with the keyboard nowhere: the diff takes it.
        app.window.makeFirstResponder(nil)
        app.focusTerminalAfterEdit()
        assertTheDiffHasTheKeyboard("a rename")
        XCTAssertEqual(app.changesModel.selection?.path, ChangesFixture.daemon.path)

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

    // MARK: Nothing acts on the pane under the centre diff

    /// The app with the centre diff up over the focused pane, on the fixture's first file.
    private func launchWithTheDiffUp() async throws -> (AppDelegate, PaneHostView) {
        let (app, fake, pane) = try await launch("git.changes,worktree")
        let list = try XCTUnwrap(app.fileSidebar).changesView.list
        ChangesFixture.fill(fake, pane)
        try await ChangesFixture.wait("the summary on the pane") { app.store.focusedPane?.git?.changes != nil }
        app.showInspector(.changes, takeKeyboard: true)
        try await ChangesFixture.wait("the list") { list.rows.count > 2 }
        list.takeKeyboard()
        XCTAssertEqual(app.changesModel.selection?.path, ChangesFixture.daemon.path)
        app.openChangesDiff()
        XCTAssertTrue(app.isChangesDiffShown)
        return (app, try XCTUnwrap(app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: pane)]))
    }

    private func assertTheDiffHasTheKeyboard(_ app: AppDelegate, _ after: String, line: UInt = #line) {
        XCTAssertTrue(app.isChangesDiffShown, "the diff stays up after \(after)", line: line)
        XCTAssertTrue(app.window.firstResponder === app.changesDiff, "the diff has the keyboard after \(after)", line: line)
        XCTAssertFalse(app.window.firstResponder is PaneTerminalView, "not a covered terminal, after \(after)", line: line)
    }

    /// The menu commands that act on the focused pane. With the centre diff up each one closes it first,
    /// so it runs in a pane in view (⌘W closes the diff and nothing else).
    private static let paneCommands: Set<Selector> = [
        #selector(AppDelegate.findInPane(_:)), #selector(AppDelegate.findNextInPane(_:)), #selector(AppDelegate.findPreviousInPane(_:)),
        #selector(AppDelegate.clearActivePane(_:)), #selector(AppDelegate.splitPane(_:)), #selector(AppDelegate.closePane(_:)),
        #selector(AppDelegate.maximizePane(_:)), #selector(AppDelegate.focusPane(_:)), #selector(AppDelegate.resizePane(_:)),
    ]

    /// Every other menu command: none acts on a pane. Copy, Paste and Select All go to whatever has the
    /// keyboard, which under the diff is never a terminal; New Tab, New Tab in a Worktree and Upload Files
    /// only read the focused pane's folder; the rest are for the app, the window, a Workspace or a Tab.
    private static let otherCommands: Set<Selector> = [
        #selector(AppDelegate.checkForUpdates(_:)), #selector(AppDelegate.showSettings(_:)), #selector(NSApplication.hide(_:)),
        #selector(NSApplication.terminate(_:)), #selector(AppDelegate.newWorktreeTab(_:)), #selector(AppDelegate.chooseFilesToUpload(_:)),
        #selector(AppDelegate.showMachineManager(_:)), #selector(AppDelegate.addMachine(_:)),
        #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
        #selector(AppDelegate.resetZoom(_:)), #selector(AppDelegate.zoomIn(_:)), #selector(AppDelegate.zoomOut(_:)),
        #selector(AppDelegate.terminalZoomIn(_:)), #selector(AppDelegate.terminalZoomOut(_:)), #selector(AppDelegate.terminalActualSize(_:)),
        #selector(AppDelegate.showOrHideSidebar(_:)), #selector(AppDelegate.showOrHideFileSidebar(_:)),
        #selector(AppDelegate.showInspectorChanges(_:)), #selector(AppDelegate.showInspectorFiles(_:)),
        #selector(AppDelegate.showInspectorActivity(_:)), #selector(AppDelegate.focusSidebar(_:)),
        #selector(AppDelegate.newWorkspace(_:)), #selector(AppDelegate.closeActiveWorkspace(_:)), #selector(AppDelegate.renameActiveWorkspace(_:)),
        #selector(AppDelegate.previousWorkspace(_:)), #selector(AppDelegate.nextWorkspace(_:)),
        #selector(AppDelegate.newTab(_:)), #selector(AppDelegate.closeActiveTab(_:)), #selector(AppDelegate.renameTab(_:)),
        #selector(AppDelegate.previousTab(_:)), #selector(AppDelegate.nextTab(_:)), #selector(AppDelegate.goToTab(_:)),
        #selector(AppDelegate.minimizeWindow(_:)), #selector(AppDelegate.zoomWindow(_:)), #selector(AppDelegate.toggleFullScreen(_:)),
        #selector(AppDelegate.showQuickOpen(_:)), #selector(AppDelegate.showFileBrowser(_:)),
        #selector(AppDelegate.showOnboarding(_:)), #selector(AppDelegate.showShortcuts(_:)),
    ]

    /// Every command in the menus is one or the other, so a new one has to be put in its place here; and
    /// each pane command, run with the diff up, has closed the diff by the time it returns.
    func testEveryPaneCommandClosesTheCentreDiffFirst() async throws {
        for shortcut in AppDelegate.shortcuts {
            XCTAssertTrue(Self.paneCommands.contains(shortcut.action) != Self.otherCommands.contains(shortcut.action),
                          "\(shortcut.menu) › \(shortcut.title) is a pane command or it isn't: say which")
        }
        let (app, host) = try await launchWithTheDiffUp()
        defer { ChangesFixture.quit(app) }
        // No await from here to the end of the loop: the model doesn't move between the commands.
        for shortcut in AppDelegate.shortcuts where Self.paneCommands.contains(shortcut.action) {
            let name = "\(shortcut.menu) › \(shortcut.title)"
            app.openChangesDiff()
            assertTheDiffHasTheKeyboard(app, "opening it for \(name)")
            let item = NSMenuItem(title: shortcut.title, action: shortcut.action, keyEquivalent: "")
            item.tag = shortcut.tag
            _ = app.perform(shortcut.action, with: item)
            XCTAssertFalse(app.isChangesDiffShown, "\(name) closes the diff first")
            XCTAssertFalse(app.window.firstResponder === app.changesDiff)
        }
        XCTAssertNil(app.window.attachedSheet, "⌘W closed the diff, not the pane")
        XCTAssertNotNil(host.search, "Find opened its bar, in the pane in view")

        // The pane's own menu (a right-click can't reach a covered pane; the menu still uncovers it), and
        // the command bar's Split.
        app.openChangesDiff()
        XCTAssertNotNil(app.paneMenu(for: PaneKey(machine: AppDelegate.localKey, pane: host.paneID)))
        XCTAssertFalse(app.isChangesDiffShown, "the pane's menu is for a pane in view")
        XCTAssertTrue(app.window.firstResponder === host.terminal)
        app.openChangesDiff()
        let tab = try XCTUnwrap(app.store.focusedTab?.id)
        app.commandBarRun(CommandListItem(id: .splitRight, title: "", keywords: []), subject: .tab(machine: AppDelegate.localKey, tab),
                          target: nil, origin: (machine: AppDelegate.localKey, pane: host.paneID, tab: tab))
        XCTAssertFalse(app.isChangesDiffShown, "> Split Right closes the diff first")
    }

    /// The keyboard never goes under the diff: not to the covered terminal, not to its find field,
    /// whoever asks the window. Esc in a find bar left open under the diff gives the keyboard to the diff.
    func testNothingUnderTheCentreDiffTakesTheKeyboard() async throws {
        let (app, host) = try await launchWithTheDiffUp()
        defer { ChangesFixture.quit(app) }
        assertTheDiffHasTheKeyboard(app, "opening it")

        // ⌘F: the diff closes and the bar opens in the pane in view. The diff again, over the open bar.
        app.findInPane(nil)
        XCTAssertFalse(app.isChangesDiffShown, "⌘F closes the diff first")
        let search = try XCTUnwrap(host.search)
        app.openChangesDiff()
        assertTheDiffHasTheKeyboard(app, "opening it over a find bar")
        // The covered find field can't take the keyboard, and Esc there (the bar closing) gives it to the diff.
        search.focusField()
        assertTheDiffHasTheKeyboard(app, "the covered find field asking for the keyboard")
        host.hideFind()
        XCTAssertNil(host.search)
        assertTheDiffHasTheKeyboard(app, "Esc in the covered pane's find bar")

        // Anything that asks the window for the covered terminal gets the diff.
        _ = app.window.makeFirstResponder(host.terminal)
        assertTheDiffHasTheKeyboard(app, "makeFirstResponder(terminal)")
        _ = app.window.makeFirstResponder(nil)
        _ = app.window.makeFirstResponder(host)
        XCTAssertFalse(app.window.firstResponder is PaneTerminalView)
        _ = app.window.makeFirstResponder(app.changesDiff)

        // Esc in the sidebar's list.
        app.focusSidebar(nil)
        XCTAssertTrue(app.sidebar.hasKeyboard)
        app.sidebar.onFocusTerminal?()
        assertTheDiffHasTheKeyboard(app, "Esc in the sidebar")
        // The file browser, closed.
        app.showFileBrowser(nil)
        let browser = try XCTUnwrap(app.fileBrowser)
        XCTAssertFalse(app.window.firstResponder === app.changesDiff, "the file browser has the keyboard")
        browser.dismiss()
        XCTAssertNil(app.fileBrowser)
        assertTheDiffHasTheKeyboard(app, "closing the file browser")

        // With the keyboard in the diff no terminal is in the responder chain: typing, Copy, Paste, Select
        // All, ⌃V and the ask bar's ⌘↩ and ⌘. (all for the terminal that has the keyboard) reach no pane.
        var responder: NSResponder? = app.window.firstResponder
        while let next = responder {
            XCTAssertFalse(next is PaneTerminalView || next is PaneHostView)
            responder = next.nextResponder
        }
        // The mouse: the whole pane area is the diff's (the header, the ×, the ask bar, the strip, a
        // right-click), and a covered terminal takes no dropped file.
        let content = try XCTUnwrap(app.window.contentView)
        content.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: host.bounds.midX, y: host.bounds.midY), NSPoint(x: host.bounds.maxX - 12, y: 12), NSPoint(x: 12, y: host.bounds.maxY - 12)] {
            let inWindow = host.convert(point, to: nil)
            let hit = try XCTUnwrap(content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow))
            XCTAssertTrue(hit === app.changesDiff || hit.isDescendant(of: app.changesDiff), "a click at \(point) of the pane lands on the diff")
        }
        XCTAssertTrue(app.changesDiff.registeredDraggedTypes.contains(.fileURL), "the diff takes the drag, and refuses it")

        // Back to the panes: the terminal takes the keyboard as before.
        app.changesDiff.cancelOperation(nil)
        XCTAssertTrue(app.window.firstResponder === host.terminal)
        _ = app.window.makeFirstResponder(nil)
        XCTAssertTrue(app.window.makeFirstResponder(host.terminal))
        XCTAssertTrue(app.window.firstResponder === host.terminal)
    }

    /// A click on empty space in the Changes list empties the selection; not while the centre diff is of
    /// that file, which would then say the file has no changes any more.
    func testTheCentreDiffKeepsItsFileWhenTheListIsClickedOnEmptySpace() async throws {
        let (app, _) = try await launchWithTheDiffUp()
        defer { ChangesFixture.quit(app) }
        let files = try XCTUnwrap(app.fileSidebar)
        try await ChangesFixture.wait("the side-by-side rows") { app.changesDiff.diffArea.table.items.count > 5 }
        for (name, list) in [("the inspector's list", files.changesView.list), ("the diff's own list", app.changesDiff.list)] {
            list.table.deselectAll(nil)
            XCTAssertEqual(app.changesModel.selection?.path, ChangesFixture.daemon.path, "the diff stays on its file, after a click on empty space in \(name)")
            XCTAssertGreaterThanOrEqual(files.changesView.list.table.selectedRow, 0, "and the row stays marked")
            XCTAssertGreaterThanOrEqual(app.changesDiff.list.table.selectedRow, 0)
            XCTAssertNotEqual(app.changesDiff.diffArea.message.label.stringValue, "This file has no changes any more.")
            XCTAssertGreaterThan(app.changesDiff.diffArea.table.items.count, 5)
        }
        // Without the centre diff the click empties the selection, as before.
        app.closeChangesDiff()
        files.changesView.list.table.deselectAll(nil)
        XCTAssertNil(app.changesModel.selection)
    }
}
