import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Review images of the Overview (the app launched in this process on the fake backend, as in
/// UIRefreshRenderTests), with the mockup's agents on this Mac and on a second machine: all three lanes,
/// a selected card, the filter in use, both empty states, and a machine that sends no peek. Each in light
/// and dark, in a narrow window (760×520) and a wide one (1280×800).
///
/// Runs only with CLOTHO_SNAPSHOT_DIR set. The window is drawn from its layers, never the screen.
@MainActor
final class OverviewRenderTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func tearDown() { ChangesFixture.restore(saved) }

    func testSnapshotsForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        saved = ChangesFixture.prepare(features: "git.changes,agent.decide,agent.mute,peek")
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
        let now = Date().timeIntervalSince1970
        let sleep = SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp")
        func git(_ branch: String, _ added: Int, _ removed: Int) -> PaneGit {
            PaneGit(repo: "clotho", root: "/tmp", branch: branch, head: "a1b2c3d",
                    changes: .init(uncommitted: .init(files: 6, added: added, removed: removed), branch: nil))
        }

        // This Mac: "clotho" with "alerts" (asks for a permission) and "release" (at work), "notes" with
        // "plan" (finished, and asks), "clotho.app" with "hero" (finished).
        let clotho = try await fake.createWorkspace(name: "clotho", spawn: SpawnOptions(command: ["/bin/zsh", "-f"], cwd: "/tmp"))
        for id in first { try await fake.closeWorkspace(id) }
        try await fake.renameTab(clotho.tab, title: "alerts")
        fake.setAgent(clotho.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Claude needs your permission to use Bash",
                                             since: now - 130, requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test -p clothod")]))
        fake.setGit(clotho.pane, git("clear-alerts", 128, 32))
        fake.setPeek(clotho.pane, lines: ["● Bash(cargo test -p clothod)", "  ⎿  Waiting for permission…"])
        let release = try await fake.createTab(in: clotho.workspace, spawn: sleep)
        try await fake.renameTab(release.tab, title: "release")
        fake.setAgent(release.pane, AgentInfo(kind: "codex", state: .running, source: "hook", message: "Updating the protocol doc.", since: now - 380))
        fake.setGit(release.pane, git("clear-alerts", 41, 3))
        // The input box and its hints under the output aren't shown.
        fake.setPeek(release.pane, lines: ["✓ agent object: needs_user", "◦ settings: rewrite health", "", "╭──────────────────────────────────────╮",
                                           "│ > Try \"how does the daemon start?\"    │", "╰──────────────────────────────────────╯", "  ? for shortcuts"])
        let notes = try await fake.createWorkspace(name: "notes", spawn: sleep)
        try await fake.renameTab(notes.tab, title: "plan")
        fake.setAgent(notes.pane, AgentInfo(kind: "claude", state: .done, source: "hook",
                                            message: "Asks which option to build, A or B: A replaces the old flow and B keeps it and adds a switch in Settings.",
                                            since: now - 680, needsUser: true))
        fake.setPeek(notes.pane, lines: ["  B keeps the old flow and adds a", "  switch. Which should I build?"])
        let site = try await fake.createWorkspace(name: "clotho.app", spawn: sleep)
        try await fake.renameTab(site.tab, title: "hero")
        fake.setAgent(site.pane, AgentInfo(kind: "claude", state: .done, source: "hook", message: "Rewrote the headline and tightened the hero spacing.",
                                           since: now - 1400, turnStarted: now - 1880, needsUser: false))
        fake.setGit(site.pane, git("main", 18, 22))
        fake.setPeek(site.pane, lines: ["  Both pages build. Nothing else", "  needs changing."])
        try await fake.focus(.pane(clotho.pane))

        // A second machine, with peeks: two agents at work in "ios".
        let devbox = FakeBackend(extraFeatures: ["peek", "git.changes", "agent.mute"])
        let connection = MachineConnection(machine: Machine(id: "devbox", label: "devbox", target: "devbox.example"), backend: devbox)
        app.addSession(connection)
        try await connection.store.start()
        let before = try await devbox.getState().workspaces.map(\.id)
        let ios = try await devbox.createWorkspace(name: "ios", spawn: sleep)
        for id in before { try await devbox.closeWorkspace(id) }
        try await devbox.renameTab(ios.tab, title: "agents-tab")
        devbox.setAgent(ios.pane, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Running the iPhone UI suite.", since: now - 840))
        devbox.setGit(ios.pane, git("ios/labels", 212, 67))
        devbox.setPeek(ios.pane, lines: ["Test Case 'testPinnedAgents' passed", "Test Case 'testMuteSwipe' started"])
        let relay = try await devbox.createTab(in: ios.workspace, spawn: sleep)
        try await devbox.renameTab(relay.tab, title: "relay")
        devbox.setAgent(relay.pane, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Adding the silent flag to the relay.", since: now - 70))
        devbox.setGit(relay.pane, git("ios/labels", 9, 0))
        devbox.setPeek(relay.pane, lines: ["● Edit(ios/relay/src/relay.js)", "  ⎿  Updated with 9 additions"])

        try await ChangesFixture.wait("the agents") {
            [clotho.pane, release.pane, notes.pane, site.pane].allSatisfy { app.store.state.pane($0)?.agent != nil }
                && app.store.state.pane(site.pane)?.git != nil
                && [ios.pane, relay.pane].allSatisfy { connection.store.state.pane($0)?.agent != nil && connection.store.state.pane($0)?.git != nil }
        }
        let overview = try XCTUnwrap(app.overview)
        func card(_ pane: PaneID, on machine: MachineKey = AppDelegate.localKey) -> OverviewCardView? {
            overview.cardViews[PaneKey(machine: machine, pane: pane)]
        }
        func settle() async throws {
            try await Task.sleep(nanoseconds: 150_000_000)
            app.window.contentView?.layoutSubtreeIfNeeded()
            app.window.displayIfNeeded()
        }

        for (size, width, height) in [("narrow", 760, 520), ("wide", 1280, 800)] as [(String, CGFloat, CGFloat)] {
            app.window.setContentSize(NSSize(width: width, height: height))
            for mode in [Theme.Mode.light, .dark] {
                let name = "\(folder)/overview-\(size)-\(mode.rawValue)"
                app.setAppearance(mode)
                try await settle()
                app.appearanceChanged()
                app.showOverview()
                try await ChangesFixture.wait("the peeks, \(size) \(mode.rawValue)") {
                    card(clotho.pane)?.peekRows.first?.stringValue == "● Bash(cargo test -p clothod)"
                        && card(relay.pane, on: "devbox")?.peekRows.last?.stringValue == "  ⎿  Updated with 9 additions"
                        && card(site.pane)?.peekRows.last?.stringValue == "  needs changing."
                }
                try await settle()

                // All three lanes; the first card (the longest wait) is selected: the ring outside the amber outline.
                XCTAssertEqual(overview.title, "Overview · 6 agents on 2 machines")
                XCTAssertEqual(overview.shownLanes.map(\.lane), [.needsYou, .working, .done])
                XCTAssertEqual(overview.shownLanes.map(\.cards.count), [2, 3, 1])
                XCTAssertEqual(overview.selected, PaneKey(machine: AppDelegate.localKey, pane: notes.pane), "the longest wait first")
                XCTAssertEqual(card(release.pane)?.peekRows.map(\.stringValue), ["✓ agent object: needs_user", "◦ settings: rewrite health"], "no input box")
                XCTAssertEqual(card(site.pane)?.sub.stringValue.hasSuffix("· Claude · took 8 min"), true)
                // Nothing of a card is outside it, and no card is outside the window.
                for view in overview.cardViews.values {
                    XCTAssertGreaterThanOrEqual(view.frame.width, 200, "\(size)")
                    for part in [view.place, view.age, view.message, view.sub, view.branch, view.counts] {
                        XCTAssertTrue(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(part.frame), "\(part.stringValue) is inside its card, \(size)")
                    }
                    let inWindow = view.convert(view.bounds, to: overview)
                    XCTAssertGreaterThanOrEqual(inWindow.minX, 0)
                    XCTAssertLessThanOrEqual(inWindow.maxX, overview.bounds.width)
                }
                saveSnapshot(of: app.container, to: "\(name).png")

                // A card at work selected.
                overview.select(PaneKey(machine: "devbox", pane: ios.pane))
                try await settle()
                XCTAssertEqual(overview.cardViews.values.filter(\.showsRing).count, 1)
                saveSnapshot(of: app.container, to: "\(name)-selected.png")

                // The filter in use, with the keyboard in it; then one that matches nothing.
                overview.focusFilter()
                overview.query = "devbox"
                XCTAssertEqual(overview.shownCards.count, 2)
                try await settle()
                saveSnapshot(of: app.container, to: "\(name)-filter.png")
                overview.query = "needs"
                XCTAssertEqual(overview.shownLanes.map(\.lane), [.needsYou])
                try await settle()
                saveSnapshot(of: app.container, to: "\(name)-filter-needs.png")
                overview.query = "staging"
                try await settle()
                XCTAssertEqual(overview.emptyTitle.stringValue, "No agents match \u{201C}staging\u{201D}")
                saveSnapshot(of: app.container, to: "\(name)-no-match.png")
                overview.query = ""
                overview.focusGrid()

                // Open Beside refused: the line in the title row.
                overview.select(PaneKey(machine: "devbox", pane: relay.pane))
                let beep = OverviewView.beep
                OverviewView.beep = {}
                overview.openSelectedBeside()
                OverviewView.beep = beep
                XCTAssertEqual(overview.note, "Open Beside works within one machine")
                try await settle()
                XCTAssertLessThanOrEqual(overview.noteLabel.frame.maxX, overview.filterField.frame.minX, "the line ends before the filter")
                saveSnapshot(of: app.container, to: "\(name)-beside-refused.png")
                overview.showNote(nil)

                // No agents anywhere: the view as it is with nothing to show.
                overview.update(lanes: [])
                try await settle()
                XCTAssertEqual(overview.emptyTitle.stringValue, "No agents")
                saveSnapshot(of: app.container, to: "\(name)-empty.png")
                app.updateOverview(agents: app.agentEntries(monitoredOnly: false))
                app.closeOverview()
            }
        }

        // A machine whose clothod sends no peek (older than 0.1.32): its cards have no peek block.
        let old = FakeBackend()
        let oldConnection = MachineConnection(machine: Machine(id: "macbook", label: "macbook", target: "macbook.example"), backend: old)
        app.addSession(oldConnection)
        try await oldConnection.store.start()
        let oldBefore = try await old.getState().workspaces.map(\.id)
        let web = try await old.createWorkspace(name: "website", spawn: sleep)
        for id in oldBefore { try await old.closeWorkspace(id) }
        try await old.renameTab(web.tab, title: "deploy")
        old.setAgent(web.pane, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Deploying the preview.", since: now - 200))
        old.setGit(web.pane, PaneGit(repo: "website", root: "/tmp", branch: "preview", head: "c3d4e5f"))
        try await ChangesFixture.wait("the old machine's agent") { oldConnection.store.state.pane(web.pane)?.agent != nil && oldConnection.store.state.pane(web.pane)?.git != nil }
        for (size, width, height) in [("narrow", 760, 520), ("wide", 1280, 800)] as [(String, CGFloat, CGFloat)] {
            app.window.setContentSize(NSSize(width: width, height: height))
            for mode in [Theme.Mode.light, .dark] {
                app.setAppearance(mode)
                try await settle()
                app.appearanceChanged()
                app.showOverview()
                try await ChangesFixture.wait("the peeks") { card(clotho.pane)?.peekRows.first?.stringValue == "● Bash(cargo test -p clothod)" }
                overview.select(PaneKey(machine: "macbook", pane: web.pane))
                try await settle()
                XCTAssertEqual(overview.title, "Overview · 7 agents on 3 machines")
                XCTAssertEqual(card(web.pane, on: "macbook")?.peek.isHidden, true)
                XCTAssertEqual(card(web.pane, on: "macbook")?.branch.stringValue, "⎇ preview")
                XCTAssertEqual(old.peekCalls, [], "never asked")
                saveSnapshot(of: app.container, to: "\(folder)/overview-\(size)-\(mode.rawValue)-no-peek.png")
                app.closeOverview()
            }
        }
    }
}
