import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The Overview in the real main window, on the fake backend, with a second machine that has neither
/// `peek` nor `agent.mute`: showing and closing it, its keys, the peeks it asks the daemons for, and the
/// rule for what it covers (nothing under it takes the keyboard, a click, a drop or VoiceOver).
@MainActor
final class OverviewTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private var beeps = 0

    override func setUp() {
        beeps = 0
        OverviewView.beep = { [weak self] in self?.beeps += 1 }
        AppDelegate.openingAgentBringsAppForward = false
    }

    override func tearDown() {
        ChangesFixture.restore(saved)
        OverviewView.beep = { NSSound.beep() }
        AppDelegate.openingAgentBringsAppForward = true
    }

    private static let devbox = "devbox"

    /// What the tests work on: "clotho" with the Tabs "alerts" (an agent that asks, in the focused pane),
    /// "build" (one at work) and "site" (one that finished); and on the machine "devbox" one at work.
    @MainActor
    private struct World {
        let app: AppDelegate
        let fake: FakeBackend
        let remote: FakeBackend
        let asking: PaneID
        let working: PaneID
        let done: PaneID
        let far: PaneID
        var overview: OverviewView { app.overview }
        func key(_ pane: PaneID, on machine: MachineKey = AppDelegate.localKey) -> PaneKey { PaneKey(machine: machine, pane: pane) }
        func host(_ pane: PaneID) -> PaneHostView? { app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: pane)] }
        func card(_ pane: PaneID, on machine: MachineKey = AppDelegate.localKey) -> OverviewCardView? { overview.cardViews[key(pane, on: machine)] }
    }

    private func launch(agents: Bool = true, remoteFeatures: [String] = []) async throws -> World {
        saved = ChangesFixture.prepare(features: "git.changes,worktree,agent.mute,peek")
        let app = ChangesFixture.launch()
        try await ChangesFixture.wait("a pane with a folder") { app.store.focusedPane?.cwd != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        let first = app.store.state.workspaces.map(\.id)
        let sleep = SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp")
        let clotho = try await fake.createWorkspace(name: "clotho", spawn: SpawnOptions(command: ["/bin/zsh", "-f"], cwd: "/tmp"))
        for id in first { try await fake.closeWorkspace(id) }
        try await fake.renameTab(clotho.tab, title: "alerts")
        let build = try await fake.createTab(in: clotho.workspace, spawn: sleep)
        try await fake.renameTab(build.tab, title: "build")
        let site = try await fake.createTab(in: clotho.workspace, spawn: sleep)
        try await fake.renameTab(site.tab, title: "site")
        try await fake.focus(.pane(clotho.pane))

        // A second machine, as an older clothod: no peek, no mute.
        let remote = FakeBackend(extraFeatures: remoteFeatures)
        let connection = MachineConnection(machine: Machine(id: Self.devbox, label: Self.devbox, target: "devbox.example"), backend: remote)
        app.addSession(connection)
        try await connection.store.start()
        let before = try await remote.getState().workspaces.map(\.id)
        let ios = try await remote.createWorkspace(name: "ios", spawn: sleep)
        for id in before { try await remote.closeWorkspace(id) }
        try await remote.renameTab(ios.tab, title: "agents-tab")
        let far = ios.pane
        try await ChangesFixture.wait("the second machine's pane") { connection.store.state.pane(far) != nil && connection.store.hello != nil }

        if agents {
            let now = Date().timeIntervalSince1970
            fake.setAgent(clotho.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Claude needs your permission to use Bash",
                                                 since: now - 130, requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test -p clothod")]))
            fake.setAgent(build.pane, AgentInfo(kind: "codex", state: .running, source: "hook", message: "Running the test suite", since: now - 380))
            fake.setAgent(site.pane, AgentInfo(kind: "claude", state: .done, source: "hook", message: "Both pages build.", since: now - 1400,
                                               needsUser: false))
            fake.setGit(clotho.pane, PaneGit(repo: "clotho", root: "/tmp", branch: "clear-alerts", head: "a1b2c3d",
                                             changes: .init(uncommitted: .init(files: 6, added: 128, removed: 32), branch: nil)))
            remote.setAgent(far, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Running the iPhone UI suite", since: now - 840))
            try await ChangesFixture.wait("the agents") {
                [clotho.pane, build.pane, site.pane].allSatisfy { app.store.state.pane($0)?.agent != nil }
                    && connection.store.state.pane(far)?.agent != nil && app.store.state.pane(clotho.pane)?.git?.branch == "clear-alerts"
            }
        }
        try await ChangesFixture.wait("the focused pane's terminal with the keyboard") {
            app.store.focusedPane?.id == clotho.pane && app.window.firstResponder === app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: clotho.pane)]?.terminal
        }
        return World(app: app, fake: fake, remote: remote, asking: clotho.pane, working: build.pane, done: site.pane, far: far)
    }

    private func event(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = [], in app: AppDelegate) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: app.window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// Whether the machine's peek subscription is now of these panes, eight lines each (so two are left
    /// once an input box is cut).
    private func subscribed(_ backend: FakeBackend, _ panes: [PaneID]) -> Bool {
        backend.peekCalls.last == .subscribe(panes: panes, lines: 8)
    }

    // MARK: Showing and closing

    func testToggleShowsAndHidesAndTheKeyboardGoesBack() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        let terminal = try XCTUnwrap(world.host(world.asking)?.terminal)
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertFalse(overview.isTicking)

        app.toggleOverview(nil)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertTrue(app.window.firstResponder === overview, "the grid has the keyboard")
        XCTAssertTrue(overview.isTicking, "the ages move on while it shows")
        XCTAssertEqual(overview.title, "Overview · 4 agents on 2 machines")
        XCTAssertEqual(overview.filterField.placeholderString, "Filter")
        XCTAssertEqual(overview.backButton.toolTip, "Back to the window (esc)")
        XCTAssertEqual(app.store.focusedPane?.id, world.asking, "nothing under it moved")
        // The window buttons stay, above it, where they were.
        let content = try XCTUnwrap(app.window.contentView)
        content.layoutSubtreeIfNeeded()
        let buttons = try XCTUnwrap(app.container.subviews.first { $0 is WindowButtons })
        let order = app.container.subviews
        XCTAssertGreaterThan(try XCTUnwrap(order.firstIndex(of: buttons)), try XCTUnwrap(order.firstIndex(of: overview)))
        XCTAssertEqual(buttons.frame.width, WindowButtons.width)
        XCTAssertEqual(buttons.frame.minX, 0)
        XCTAssertEqual(overview.frame, content.bounds, "all of the window's content")
        XCTAssertGreaterThanOrEqual(overview.titleLabel.frame.minX, buttons.frame.maxX, "the title starts after the buttons")

        // The key again.
        app.toggleOverview(nil)
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertFalse(overview.isTicking)
        XCTAssertTrue(app.window.firstResponder === terminal, "back in the terminal it came from")

        // Esc in the grid, as a key and as the command.
        app.toggleOverview(nil)
        overview.keyDown(with: try event(53, "\u{1b}", in: app))
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertTrue(app.window.firstResponder === terminal)
        app.showOverview()
        overview.cancelOperation(nil)
        XCTAssertFalse(app.isOverviewShown)

        // Esc in the filter: with text it clears the filter and goes back to the grid; empty, it closes.
        app.showOverview()
        overview.keyDown(with: try event(44, "/", in: app))
        XCTAssertTrue(overview.hasKeyboard)
        XCTAssertFalse(app.window.firstResponder === overview, "the filter has the keyboard")
        overview.query = "build"
        XCTAssertEqual(overview.shownCards.map(\.key.pane), [world.working])
        let editor = try XCTUnwrap(app.window.firstResponder as? NSTextView)
        XCTAssertTrue(overview.control(overview.filterField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(overview.query, "")
        XCTAssertEqual(overview.shownCards.count, 4)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertTrue(app.window.firstResponder === overview, "back in the grid")
        overview.focusFilter()
        // The down arrow and Return go to the grid.
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:))] {
            overview.focusFilter()
            let editor = try XCTUnwrap(app.window.firstResponder as? NSTextView)
            XCTAssertTrue(overview.control(overview.filterField, textView: editor, doCommandBy: command))
            XCTAssertTrue(app.window.firstResponder === overview)
        }
        overview.focusFilter()
        let empty = try XCTUnwrap(app.window.firstResponder as? NSTextView)
        XCTAssertTrue(overview.control(overview.filterField, textView: empty, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(app.isOverviewShown, "Esc in an empty filter closes")
        XCTAssertTrue(app.window.firstResponder === terminal)

        // ⌘W closes only the Overview.
        app.showOverview()
        app.closePane(nil)
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertNil(app.window.attachedSheet, "and not the pane")
    }

    func testClosingGivesTheKeyboardBackToTheCentreDiff() async throws {
        let world = try await launch()
        let app = world.app
        defer { ChangesFixture.quit(app) }
        let list = try XCTUnwrap(app.fileSidebar).changesView.list
        ChangesFixture.fill(world.fake, world.asking)
        try await ChangesFixture.wait("the summary on the pane") { app.store.focusedPane?.git?.branch == "clothod/clear-alerts" }
        app.showInspector(.changes, takeKeyboard: true)
        try await ChangesFixture.wait("the list") { list.rows.count > 2 }
        list.takeKeyboard()
        app.openChangesDiff()
        XCTAssertTrue(app.window.firstResponder === app.changesDiff)

        app.toggleOverview(nil)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertTrue(app.isChangesDiffShown, "the diff stays up underneath")
        XCTAssertTrue(app.window.firstResponder === app.overview)
        XCTAssertTrue(app.changesDiff.isAccessibilityHidden(), "and is covered")
        app.overview.cancelOperation(nil)
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertTrue(app.isChangesDiffShown)
        XCTAssertTrue(app.window.firstResponder === app.changesDiff, "the keyboard goes back to the diff")
        XCTAssertFalse(app.changesDiff.isAccessibilityHidden())
        // ⌘W then closes the diff: one cover at a time, the top one first.
        app.showOverview()
        app.closePane(nil)
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertTrue(app.isChangesDiffShown)
        app.closePane(nil)
        XCTAssertFalse(app.isChangesDiffShown)
        XCTAssertNil(app.window.attachedSheet)
    }

    // MARK: Keys

    func testReturnOnTheFocusedPanesOwnCardClosesTheOverview() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        let terminal = try XCTUnwrap(world.host(world.asking)?.terminal)
        app.showOverview()
        XCTAssertEqual(overview.selected, world.key(world.asking), "the first card: the one that needs you")
        overview.keyDown(with: try event(36, "\r", in: app))
        XCTAssertFalse(app.isOverviewShown, "nothing moved, and it still closed")
        XCTAssertTrue(app.window.firstResponder === terminal)
        XCTAssertEqual(app.store.focusedPane?.id, world.asking)

        // Another card: its pane is focused and takes the keyboard.
        app.showOverview()
        overview.select(world.key(world.working))
        overview.keyDown(with: try event(36, "\r", in: app))
        XCTAssertFalse(app.isOverviewShown)
        try await ChangesFixture.wait("the working agent's pane") {
            app.store.focusedPane?.id == world.working && app.window.firstResponder === world.host(world.working)?.terminal
        }
        // A double-click opens too; one click selects and takes the keyboard.
        app.showOverview()
        _ = app.window.makeFirstResponder(overview.filterField)
        let card = try XCTUnwrap(world.card(world.done))
        card.onClick?(1)
        XCTAssertEqual(overview.selected, world.key(world.done))
        XCTAssertTrue(card.showsRing)
        XCTAssertEqual(world.card(world.asking)?.showsRing, false)
        XCTAssertTrue(app.window.firstResponder === overview)
        XCTAssertTrue(app.isOverviewShown)
        card.onClick?(2)
        XCTAssertFalse(app.isOverviewShown)
        try await ChangesFixture.wait("the finished agent's pane") { app.store.focusedPane?.id == world.done }
    }

    func testArrowsMoveOverTheGrid() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        app.window.setContentSize(NSSize(width: 1280, height: 800))
        app.showOverview()
        app.window.contentView?.layoutSubtreeIfNeeded()
        // Needs you: asking. Working: build, then devbox's (the most recent first). Done: site.
        XCTAssertEqual(overview.shownCards.map(\.key), [world.key(world.asking), world.key(world.working), world.key(world.far, on: Self.devbox), world.key(world.done)])
        XCTAssertEqual(overview.selected, world.key(world.asking))
        overview.keyDown(with: try event(125, in: app))
        XCTAssertEqual(overview.selected, world.key(world.working), "down, into the next lane")
        overview.keyDown(with: try event(124, in: app))
        XCTAssertEqual(overview.selected, world.key(world.far, on: Self.devbox))
        overview.keyDown(with: try event(125, in: app))
        XCTAssertEqual(overview.selected, world.key(world.done), "the row below is shorter: its last card")
        overview.keyDown(with: try event(125, in: app))
        XCTAssertEqual(overview.selected, world.key(world.done), "at the edge it stays")
        overview.keyDown(with: try event(126, in: app))
        overview.keyDown(with: try event(123, in: app))
        overview.keyDown(with: try event(123, in: app))
        XCTAssertEqual(overview.selected, world.key(world.asking), "left walks back over the lanes")
        XCTAssertEqual(overview.cardViews.values.filter(\.showsRing).count, 1)
        XCTAssertTrue(app.isOverviewShown)
        // Typing anything else does nothing and reaches no pane.
        var input: [Data] = []
        PaneHostView.inputTap = { _, bytes in input.append(bytes) }
        defer { PaneHostView.inputTap = nil }
        overview.keyDown(with: try event(0, "a", in: app))
        overview.keyDown(with: try event(49, " ", in: app))
        XCTAssertEqual(input, [])
        XCTAssertEqual(beeps, 0)
    }

    func testResolveAndMuteReachTheDaemon() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        app.showOverview()
        // M on the working agent: muted in its daemon, and M again unmutes.
        overview.select(world.key(world.working))
        overview.keyDown(with: try event(46, "m", in: app))
        try await ChangesFixture.wait("the mute") { app.store.state.pane(world.working)?.agent?.isMuted == true }
        try await ChangesFixture.wait("the card says so") { world.card(world.working)?.sub.stringValue.hasSuffix("· muted") == true }
        XCTAssertEqual(overview.selected, world.key(world.working))
        overview.keyDown(with: try event(46, "M", .shift, in: app))
        try await ChangesFixture.wait("the unmute") { app.store.state.pane(world.working)?.agent?.isMuted == false }
        XCTAssertEqual(beeps, 0)
        // R on it: nothing to resolve.
        overview.keyDown(with: try event(15, "r", in: app))
        XCTAssertEqual(beeps, 1, "a beep: its attention isn't raised")
        // M on a machine that can't mute.
        overview.select(world.key(world.far, on: Self.devbox))
        overview.keyDown(with: try event(46, "m", in: app))
        XCTAssertEqual(beeps, 2, "a beep: no agent.mute there")
        XCTAssertNil(app.connections[Self.devbox]?.store.state.pane(world.far)?.agent?.muted)

        // R on the finished agent: its attention is cleared in the daemon, and its card leaves.
        overview.select(world.key(world.done))
        overview.keyDown(with: try event(15, "r", in: app))
        try await ChangesFixture.wait("the ack") { app.store.state.pane(world.done)?.agent?.needsAttention == false }
        try await ChangesFixture.wait("the card gone") { world.card(world.done) == nil }
        XCTAssertEqual(overview.shownLanes.map(\.lane), [.needsYou, .working], "Done is empty: no lane")
        XCTAssertNil(overview.laneViews[.done])
        XCTAssertEqual(beeps, 2)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertNotNil(overview.selected, "the selection goes to the nearest card")

        // The card's menu: Open, Open Beside, Resolve where there is something to resolve, Mute where
        // the machine mutes. No Allow, no Deny, though the agent waits on a permission request.
        XCTAssertEqual(overview.menu(for: world.key(world.asking))?.items.map(\.title), ["Open", "Open Beside", "Resolve", "Mute"])
        XCTAssertEqual(overview.menu(for: world.key(world.working))?.items.map(\.title), ["Open", "Open Beside", "Mute"])
        XCTAssertEqual(overview.menu(for: world.key(world.far, on: Self.devbox))?.items.map(\.title), ["Open", "Open Beside"])
    }

    func testOpenBesideWorksWithinOneMachine() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        app.showOverview()
        let commandReturn = try event(36, "\r", .command, in: app)

        // Another machine: a beep, a line saying why, and the Overview stays.
        overview.select(world.key(world.far, on: Self.devbox))
        XCTAssertTrue(overview.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(beeps, 1)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertEqual(overview.note, "Open Beside works within one machine")
        XCTAssertEqual(app.focusedMachine, AppDelegate.localKey)
        // The Tab the focus is in.
        overview.select(world.key(world.asking))
        XCTAssertTrue(overview.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(beeps, 2)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertEqual(overview.note, "Already in this Tab")
        // The next key clears the line.
        overview.keyDown(with: try event(125, in: app))
        XCTAssertNil(overview.note)
        // With the keyboard in the filter ⌘↩ isn't the grid's.
        overview.focusFilter()
        XCTAssertFalse(overview.performKeyEquivalent(with: commandReturn))
        overview.focusGrid()
        // ⇧⌘↩ is Maximize Pane's, not this.
        XCTAssertFalse(overview.performKeyEquivalent(with: try event(36, "\r", [.command, .shift], in: app)))
        XCTAssertTrue(app.isOverviewShown)

        // Another Tab on this machine: the whole Tab moves beside the pane that was focused.
        overview.select(world.key(world.working))
        XCTAssertTrue(overview.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(beeps, 2)
        XCTAssertFalse(app.isOverviewShown, "the panes are in view")
        try await ChangesFixture.wait("the agent's pane beside the focused one") {
            app.store.focusedTab?.layout.panes.contains(world.asking) == true && app.store.focusedTab?.layout.panes.contains(world.working) == true
        }
    }

    // MARK: Peeks

    func testPeeksFollowTheCardsOnScreen() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview, fake = world.fake
        defer { ChangesFixture.quit(app) }
        XCTAssertEqual(fake.peekCalls, [], "nothing is asked before it shows")
        world.fake.setPeek(world.working, lines: ["✓ agent object: needs_user", "◦ settings: rewrite health"])

        app.showOverview()
        let all = [world.asking, world.working, world.done].sorted()
        try await ChangesFixture.wait("the subscription") { self.subscribed(fake, all) }
        XCTAssertEqual(fake.peekCalls.count, 1)
        try await ChangesFixture.wait("the working agent's rows") { world.card(world.working)?.peekRows.map(\.stringValue) == ["✓ agent object: needs_user", "◦ settings: rewrite health"] }
        XCTAssertEqual(world.card(world.working)?.peek.isHidden, false)

        // A machine without `peek` is never asked, and its cards have no peek block.
        XCTAssertEqual(world.remote.peekCalls, [])
        XCTAssertEqual(world.card(world.far, on: Self.devbox)?.peek.isHidden, true)
        XCTAssertEqual(world.card(world.far, on: Self.devbox)?.card.hasPeek, false)

        // A change updates only that card: its two labels.
        let before = world.card(world.working)?.peekLines
        fake.setPeek(world.asking, lines: ["● Bash(cargo test -p clothod)", "  ⎿  Waiting for permission…"])
        try await ChangesFixture.wait("the asking agent's rows") { world.card(world.asking)?.peekRows.map(\.stringValue) == ["● Bash(cargo test -p clothod)", "  ⎿  Waiting for permission…"] }
        XCTAssertEqual(world.card(world.working)?.peekLines, before)
        XCTAssertEqual(world.card(world.done)?.peekRows.map(\.stringValue), ["", ""], "exactly two rows, empty until something comes")
        XCTAssertEqual(fake.peekCalls.count, 1, "a peek asks nothing more")

        // A line with a bidi override shows as what it is, on one line.
        fake.setPeek(world.done, lines: ["abc\u{202E}def"])
        try await ChangesFixture.wait("the override shown") { world.card(world.done)?.peekRows.first?.stringValue == "abc<U+202E>def" }
        XCTAssertEqual(world.card(world.done)?.peekRows.last?.stringValue, "")
        for row in world.card(world.done)?.peekRows ?? [] {
            XCTAssertTrue(row.usesSingleLineMode)
            XCTAssertEqual(row.lineBreakMode, .byTruncatingTail)
        }
        // The input box an agent's screen ends with, and its hints, aren't shown.
        fake.setPeek(world.done, lines: ["  Both pages build. Nothing else", "  needs changing.", "", "╭──────────────────────────────╮",
                                         "│ > Try \"fix the lint errors\"   │", "╰──────────────────────────────╯", "  ? for shortcuts"])
        try await ChangesFixture.wait("the rows above the input box") { world.card(world.done)?.peekRows.first?.stringValue == "  Both pages build. Nothing else" }
        XCTAssertEqual(world.card(world.done)?.peekRows.last?.stringValue, "  needs changing.")

        // A filter change replaces the subscription with the cards it leaves.
        overview.query = "working"
        XCTAssertEqual(overview.shownCards.map(\.key.pane), [world.working, world.far])
        try await ChangesFixture.wait("the subscription for the filter") { self.subscribed(fake, [world.working]) }
        // A filter that leaves none of this machine's cards ends it.
        overview.query = "devbox"
        XCTAssertEqual(overview.shownCards.map(\.key), [world.key(world.far, on: Self.devbox)])
        try await ChangesFixture.wait("the unsubscription") { fake.peekCalls.last == .unsubscribe }
        overview.query = ""
        try await ChangesFixture.wait("the subscription again") { self.subscribed(fake, all) }
        try await ChangesFixture.wait("the rows again") { world.card(world.asking)?.peekRows.first?.stringValue == "● Bash(cargo test -p clothod)" }

        // A new card: the subscription names its pane too.
        let extra = try await fake.createTab(in: try XCTUnwrap(app.store.focusedWorkspace?.id), spawn: SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp"))
        try await fake.focus(.pane(world.asking))
        let count = fake.peekCalls.count
        fake.setAgent(extra.pane, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Starting", since: Date().timeIntervalSince1970))
        try await ChangesFixture.wait("the subscription with the new card") { self.subscribed(fake, (all + [extra.pane]).sorted()) }
        XCTAssertEqual(fake.peekCalls.count, count + 1, "one request for the change")
        // Output and other model changes ask nothing.
        world.host(world.asking)?.terminal.feedFromBackend(Data("hello\r\n".utf8))
        try await fake.renameTab(extra.tab, title: "extra")
        try await ChangesFixture.wait("the card's new place") { world.card(extra.pane)?.place.stringValue == "clotho › extra" }
        XCTAssertEqual(fake.peekCalls.count, count + 1)

        // Closing ends it, and a peek that comes late changes nothing.
        app.closeOverview()
        try await ChangesFixture.wait("the unsubscription on close") { fake.peekCalls.last == .unsubscribe }
        XCTAssertEqual(app.overviewPeeks.count, 0)
        XCTAssertEqual(app.overviewPeekLines.count, 0)
        app.overviewPeek(machine: AppDelegate.localKey, pane: world.asking, lines: ["late"])
        XCTAssertEqual(app.overviewPeekLines.count, 0)
        XCTAssertEqual(world.remote.peekCalls, [])
    }

    // MARK: The covered rule

    func testNothingUnderTheOverviewTakesTheKeyboard() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        let host = try XCTUnwrap(world.host(world.asking))
        func assertTheOverviewHasTheKeyboard(_ after: String, line: UInt = #line) {
            XCTAssertTrue(app.isOverviewShown, "the Overview stays up after \(after)", line: line)
            XCTAssertTrue(app.window.firstResponder === overview, "the Overview has the keyboard after \(after)", line: line)
        }
        // A find bar left open in the pane, then the Overview over it.
        app.findInPane(nil)
        let search = try XCTUnwrap(host.search)
        app.showOverview()
        assertTheOverviewHasTheKeyboard("opening it over a find bar")
        search.focusField()
        assertTheOverviewHasTheKeyboard("the covered find field asking for the keyboard")
        host.hideFind()
        assertTheOverviewHasTheKeyboard("the covered find bar closing")

        _ = app.window.makeFirstResponder(host.terminal)
        assertTheOverviewHasTheKeyboard("makeFirstResponder(terminal)")
        app.sidebar.takeKeyboard()
        assertTheOverviewHasTheKeyboard("the sidebar asking for the keyboard")
        XCTAssertFalse(app.sidebar.hasKeyboard)
        app.tabBar.beginRename(try XCTUnwrap(app.store.focusedTab?.id))
        assertTheOverviewHasTheKeyboard("a tab's name field asking for the keyboard")
        _ = app.window.makeFirstResponder(app.fileSidebar.pane.table)
        assertTheOverviewHasTheKeyboard("the inspector's list asking for the keyboard")
        if let toggle = app.sidebarToggle {
            _ = app.window.makeFirstResponder(toggle)
            assertTheOverviewHasTheKeyboard("the sidebar's toggle asking for the keyboard")
        }
        // A model change gives the terminal nothing either.
        try await world.fake.renameTab(try XCTUnwrap(app.store.focusedTab?.id), title: "alerts 2")
        try await ChangesFixture.wait("the retitle") { app.store.focusedTab?.title == "alerts 2" }
        assertTheOverviewHasTheKeyboard("a sync")

        // Its own filter takes it.
        overview.focusFilter()
        XCTAssertTrue(overview.hasKeyboard)
        XCTAssertFalse(app.window.firstResponder === overview)
        overview.focusGrid()

        // The command bar opens over it, keeps the keyboard, and gives it back to the Overview.
        app.showQuickOpen(nil)
        let bar = try XCTUnwrap(app.quickOpen)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertFalse(overview.hasKeyboard, "the command bar has the keyboard")
        XCTAssertTrue((app.window.firstResponder as? NSView)?.isDescendant(of: bar) == true)
        bar.cancel()
        XCTAssertNil(app.quickOpen)
        assertTheOverviewHasTheKeyboard("the command bar closing")
        // The shortcuts card and the file browser too.
        app.showShortcuts(nil)
        XCTAssertTrue(app.window.firstResponder === app.shortcutsOverlay)
        app.shortcutsOverlay?.dismiss()
        assertTheOverviewHasTheKeyboard("the shortcuts card closing")
        app.showFileBrowser(nil)
        XCTAssertFalse(overview.hasKeyboard, "the file browser has the keyboard")
        app.fileBrowser?.dismiss()
        assertTheOverviewHasTheKeyboard("the file browser closing")

        // No terminal is in the responder chain: typing, Paste, ⌃V and the ask bar's ⌘↩ and ⌘. reach none.
        var responder: NSResponder? = app.window.firstResponder
        while let next = responder {
            XCTAssertFalse(next is PaneTerminalView || next is PaneHostView)
            responder = next.nextResponder
        }
        // The mouse: a click anywhere on a pane, the sidebar, the tab bar or the inspector lands on the
        // Overview; only the window buttons are above it.
        let content = try XCTUnwrap(app.window.contentView)
        content.layoutSubtreeIfNeeded()
        func hit(_ view: NSView, _ point: NSPoint) throws -> NSView {
            let inWindow = view.convert(point, to: nil)
            return try XCTUnwrap(content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow))
        }
        for (name, view) in [("the pane", host), ("the sidebar", app.sidebar), ("the tab bar", app.tabBar)] as [(String, NSView)] {
            let found = try hit(view, NSPoint(x: view.bounds.maxX - 14, y: view.bounds.midY))
            XCTAssertTrue(found === overview || found.isDescendant(of: overview), "a click on \(name) lands on the Overview, not \(type(of: found))")
        }
        let buttons = try XCTUnwrap(app.container.subviews.first { $0 is WindowButtons })
        let onButtons = try hit(buttons, NSPoint(x: 16, y: buttons.bounds.midY))
        XCTAssertTrue(onButtons === buttons || onButtons.isDescendant(of: buttons), "the window buttons stay")
        // Drags stop at it and are refused.
        for type in [NSPasteboard.PasteboardType.fileURL, ChromeDrag.type] {
            XCTAssertTrue(overview.registeredDraggedTypes.contains(type), "\(type.rawValue) stops at the Overview")
        }
        XCTAssertEqual(host.terminal.isCovered?(), true, "a covered terminal takes no drop and reports no mouse")

        app.closeOverview()
        XCTAssertEqual(host.terminal.isCovered?(), false)
        XCTAssertTrue(app.window.firstResponder === host.terminal)
        _ = app.window.makeFirstResponder(nil)
        XCTAssertTrue(app.window.makeFirstResponder(host.terminal))
        XCTAssertTrue(app.window.firstResponder === host.terminal, "and takes the keyboard as before")
    }

    /// "> Show Overview" in the command bar shows it, with the keyboard; a row opened from the bar over it
    /// (a commit, not a preview) closes it.
    func testTheCommandBarShowsItAndOpeningARowClosesIt() async throws {
        let world = try await launch()
        let app = world.app
        defer { ChangesFixture.quit(app) }
        app.showQuickOpen(nil)
        var bar = try XCTUnwrap(app.quickOpen)
        bar.setQuery(">show overview")
        XCTAssertEqual(bar.selectedEntry?.item.title, "Show Overview")
        bar.open()
        XCTAssertNil(app.quickOpen)
        XCTAssertTrue(app.isOverviewShown)
        XCTAssertTrue(app.window.firstResponder === app.overview)

        // The bar over the Overview: moving the selection previews under it and leaves it up; Return opens
        // the row for real, in view.
        app.showQuickOpen(nil)
        bar = try XCTUnwrap(app.quickOpen)
        bar.onPreview?(try XCTUnwrap(bar.rows.first { $0.entry.item.title == "build" }?.entry))
        XCTAssertTrue(app.isOverviewShown, "a preview leaves it up")
        bar.onOpen?(try XCTUnwrap(bar.rows.first { $0.entry.item.title == "build" }?.entry))
        XCTAssertNil(app.quickOpen)
        XCTAssertFalse(app.isOverviewShown, "opening a Tab closes it")
        try await ChangesFixture.wait("the Tab opened") {
            app.store.focusedPane?.id == world.working && app.window.firstResponder === world.host(world.working)?.terminal
        }
        // A notification's click (`openAgent`) closes it too.
        app.showOverview()
        app.openAgent(machine: AppDelegate.localKey, pane: world.done)
        XCTAssertFalse(app.isOverviewShown)
        try await ChangesFixture.wait("the agent's pane") { app.store.focusedPane?.id == world.done }
    }

    func testACoveredTerminalReportsNoMouse() async throws {
        let world = try await launch()
        let app = world.app
        var input: [Data] = []
        PaneHostView.inputTap = { _, bytes in input.append(bytes) }
        defer {
            PaneHostView.inputTap = nil
            ChangesFixture.quit(app)
        }
        app.window.contentView?.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(world.host(world.asking)?.terminal)
        var step: CGFloat = 0
        func move() throws {
            step = step >= 5 ? 0 : step + 1
            let point = terminal.convert(NSPoint(x: terminal.bounds.midX + step * 24, y: terminal.bounds.midY + step * 18), to: nil)
            terminal.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        terminal.feedFromBackend(Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))
        try await ChangesFixture.wait("a report from the pane in view") {
            try? move()
            return !input.isEmpty
        }
        app.showOverview()
        try await Task.sleep(nanoseconds: 200_000_000)
        input = []
        for _ in 0..<6 { try move() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(input, [], "nothing while the Overview covers the pane")
        app.closeOverview()
        try await ChangesFixture.wait("a report again") {
            try? move()
            return !input.isEmpty
        }
    }

    /// The views reachable through the accessibility tree from `root`.
    private func accessibilityViews(from root: Any) -> [NSView] {
        var found: [NSView] = []
        var queue: [Any] = [root]
        var seen = Set<ObjectIdentifier>()
        while let next = queue.popLast(), seen.count < 20000 {
            let object = next as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let view = object as? NSView { found.append(view) } else if let view = (object as? NSCell)?.controlView { found.append(view) }
            if let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren() { queue.append(contentsOf: children) }
        }
        return found
    }

    func testWhatIsCoveredLeavesTheAccessibilityTreeAndEachCardIsOneElement() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        app.showInspector(.files, takeKeyboard: false)
        app.showNotice("clothod was updated", detail: nil, action: "Restart", then: {})
        app.window.contentView?.layoutSubtreeIfNeeded()
        var covered: [(String, NSView)] = [("the pane area", app.splitView), ("the sidebar", app.sidebar), ("the tab bar", app.tabBar), ("the inspector", app.fileSidebar)]
        covered += [("the empty state", app.emptyState), ("the notice", try XCTUnwrap(app.noticeBar)),
                    ("the sidebar's toggle", try XCTUnwrap(app.sidebarToggle)), ("the inspector's toggle", try XCTUnwrap(app.fileSidebarToggle))]
        func under() -> [NSView] {
            accessibilityViews(from: app.window!).filter { view in covered.contains { view !== $0.1 && view.isDescendant(of: $0.1) } }
        }
        XCTAssertFalse(under().isEmpty, "in the tree before")

        app.showOverview()
        for (name, view) in covered {
            XCTAssertEqual((view as NSAccessibilityProtocol).accessibilityChildren()?.count, 0, "\(name) has no children")
            XCTAssertTrue(view.isAccessibilityHidden(), name)
            if view !== app.emptyState { XCTAssertFalse(view.isHidden, "\(name) isn't hidden: that is its own state") }
        }
        XCTAssertEqual(under().map { "\(type(of: $0))" }, [], "nothing of what is covered")

        // Each card is one element: a button whose label is the whole card.
        let asking = try XCTUnwrap(world.card(world.asking))
        XCTAssertTrue(asking.isAccessibilityElement())
        XCTAssertEqual(asking.accessibilityRole(), .button)
        XCTAssertEqual(asking.accessibilityChildren()?.count, 0)
        XCTAssertEqual(asking.accessibilityLabel(), "Needs you: clotho › alerts. Allow Bash: cargo test -p clothod. \(app.connections[AppDelegate.localKey]!.title), Claude. Waiting 2 min. Branch clear-alerts. 128 lines added, 32 removed, in 6 files.")
        XCTAssertTrue(asking.isAccessibilitySelected())
        XCTAssertEqual(asking.accessibilityCustomActions()?.map(\.name), ["Open Beside", "Resolve", "Mute"])
        let far = try XCTUnwrap(world.card(world.far, on: Self.devbox))
        XCTAssertFalse(far.isAccessibilitySelected())
        XCTAssertTrue(far.accessibilityLabel()?.hasPrefix("Working: ") == true)
        XCTAssertTrue(far.accessibilityLabel()?.contains("devbox, Claude. Working 14 min. No repo.") == true, far.accessibilityLabel() ?? "")
        XCTAssertEqual(far.accessibilityCustomActions()?.map(\.name), ["Open Beside"])
        let inTheGrid = accessibilityViews(from: overview.document)
        XCTAssertEqual(inTheGrid.filter { $0 is OverviewCardView }.count, 4)
        XCTAssertEqual(inTheGrid.filter { view in overview.cardViews.values.contains { view !== $0 && view.isDescendant(of: $0) } }.count, 0, "nothing inside a card is its own element")
        // Lanes are groups.
        XCTAssertEqual(overview.laneViews[.needsYou]?.accessibilityLabel(), "Needs you, 1")
        XCTAssertEqual(overview.laneViews[.working]?.accessibilityLabel(), "Working, 2")
        XCTAssertEqual(overview.laneViews[.needsYou]?.accessibilityRole(), .group)
        XCTAssertEqual(overview.filterField.accessibilityLabel(), "Filter agents")
        XCTAssertEqual(overview.backButton.accessibilityLabel(), "Back to the window")
        // The key loop: the filter, the grid, Back.
        XCTAssertTrue(overview.filterField.nextKeyView === overview)
        XCTAssertTrue(overview.nextKeyView === overview.backButton)
        XCTAssertTrue(overview.backButton.nextKeyView === overview.filterField)
        // Pressing a card opens it.
        XCTAssertTrue(far.accessibilityPerformPress())
        XCTAssertFalse(app.isOverviewShown)
        XCTAssertEqual(app.focusedMachine, Self.devbox)

        for (name, view) in covered where view !== app.emptyState {
            XCTAssertFalse(view.isAccessibilityHidden(), "\(name) is back")
        }
        XCTAssertFalse(app.emptyState.isCoveredForAccessibility)
    }

    // MARK: Lanes and the empty state

    func testLanesAndTheEmptyState() async throws {
        let world = try await launch()
        let app = world.app, overview = world.overview
        defer { ChangesFixture.quit(app) }
        app.showOverview()
        app.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(overview.shownLanes.map(\.lane), [.needsYou, .working, .done])
        XCTAssertEqual(overview.shownLanes.compactMap { overview.laneViews[$0.lane]?.title }, ["Needs you · 1", "Working · 2", "Done · 1"])
        XCTAssertEqual(overview.document.subviews.compactMap { ($0 as? OverviewLaneView)?.lane }, [.needsYou, .working, .done], "top to bottom")
        XCTAssertTrue(overview.emptyTitle.isHidden)

        // The card's words.
        let asking = try XCTUnwrap(world.card(world.asking))
        XCTAssertEqual(asking.place.stringValue, "clotho › alerts")
        XCTAssertEqual(asking.age.stringValue, "2 min")
        XCTAssertEqual(asking.message.stringValue, "Allow Bash: cargo test -p clothod")
        XCTAssertEqual(asking.message.toolTip, "Allow Bash: cargo test -p clothod")
        XCTAssertEqual(asking.message.maximumNumberOfLines, 2)
        XCTAssertEqual(asking.branch.stringValue, "⎇ clear-alerts")
        XCTAssertEqual(asking.counts.stringValue, "+128 \u{2212}32")
        XCTAssertEqual(asking.markView.mark, .needsYou)
        let done = try XCTUnwrap(world.card(world.done))
        XCTAssertEqual(done.age.stringValue, "23 min ago")
        XCTAssertEqual(done.branch.stringValue, "no repo")
        XCTAssertEqual(done.counts.stringValue, "")
        // Cards are the layout's: the same size, in the window.
        let sizes = Set(overview.cardViews.values.map { "\($0.frame.size)" })
        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(asking.frame.height, OverviewCardView.height)
        XCTAssertGreaterThanOrEqual(asking.message.frame.maxY, asking.message.frame.minY)
        XCTAssertLessThanOrEqual(asking.sub.frame.maxY, asking.peek.frame.minY, "the words end above the peek")

        // The filter: a state word, then a name; and what matches nothing.
        overview.query = "needs"
        XCTAssertEqual(overview.shownLanes.map(\.lane), [.needsYou])
        XCTAssertEqual(overview.title, "Overview · 4 agents on 2 machines", "the title counts every card")
        overview.query = "zzz"
        XCTAssertEqual(overview.shownCards.count, 0)
        XCTAssertFalse(overview.emptyTitle.isHidden)
        XCTAssertEqual(overview.emptyTitle.stringValue, "No agents match \u{201C}zzz\u{201D}")
        XCTAssertTrue(overview.emptyLine.isHidden)
        overview.keyDown(with: try event(36, "\r", in: app))
        XCTAssertEqual(beeps, 1, "Return with no card")
        XCTAssertTrue(app.isOverviewShown)
        overview.query = ""
        XCTAssertTrue(overview.emptyTitle.isHidden)

        // No agents at all.
        for pane in [world.asking, world.working, world.done] { world.fake.setAgent(pane, nil) }
        world.remote.setAgent(world.far, nil)
        try await ChangesFixture.wait("no cards") { overview.cardViews.isEmpty }
        XCTAssertEqual(overview.title, "Overview · no agents")
        XCTAssertFalse(overview.emptyTitle.isHidden)
        XCTAssertEqual(overview.emptyTitle.stringValue, "No agents")
        XCTAssertFalse(overview.emptyLine.isHidden)
        XCTAssertEqual(overview.emptyLine.stringValue, "Agents running in any Tab show here.")
        XCTAssertTrue(overview.laneViews.isEmpty)
        try await ChangesFixture.wait("the peeks ended") { world.fake.peekCalls.last == .unsubscribe }
    }

    /// The Overview is of every machine: one whose agents aren't monitored (no inbox rows, no
    /// notifications) still has its cards.
    func testAMachineThatIsNotMonitoredStillHasItsCards() async throws {
        let world = try await launch()
        let app = world.app
        defer {
            UserDefaults.standard.removeObject(forKey: "MonitorAgents.\(Self.devbox)")
            ChangesFixture.quit(app)
        }
        app.setMonitorsAgents(Self.devbox, false)
        XCTAssertFalse(app.agentEntries().contains { $0.machine == Self.devbox })
        XCTAssertTrue(app.agentEntries(monitoredOnly: false).contains { $0.machine == Self.devbox })
        app.showOverview()
        XCTAssertNotNil(world.card(world.far, on: Self.devbox))
    }
}
