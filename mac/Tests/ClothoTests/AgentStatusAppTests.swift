import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// In the real main window on the fake backend: what Resolve does to an agent whose ack leaves it in place
/// or removes it (clothod 0.1.33), and the agent status sheet with its per-agent Install and Remove.
@MainActor
final class AgentStatusAppTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func setUp() { AppDelegate.openingAgentBringsAppForward = false }

    override func tearDown() {
        ChangesFixture.restore(saved)
        AppDelegate.openingAgentBringsAppForward = true
    }

    private func launch() async throws -> (app: AppDelegate, fake: FakeBackend) {
        saved = ChangesFixture.prepare(features: "agent.mute,peek")
        let app = ChangesFixture.launch()
        try await ChangesFixture.wait("a pane") { app.store.focusedPane != nil }
        return (app, try XCTUnwrap(app.store.backend as? FakeBackend))
    }

    /// Resolve only ever sends `agent.ack`; the row goes or stays by what the events after it say.
    func testResolveShowsWhatTheEventsCarry() async throws {
        let (app, fake) = try await launch()
        defer { ChangesFixture.quit(app) }
        let local = AppDelegate.localKey
        let workspace = try XCTUnwrap(app.store.focusedWorkspace?.id)
        let first = try XCTUnwrap(app.store.focusedPane?.id)
        let sleep = SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp")
        let second = try await fake.createTab(in: workspace, spawn: sleep).pane
        let third = try await fake.createTab(in: workspace, spawn: sleep).pane
        try await fake.focus(.pane(first))
        // A program's notification whose program still runs, a script's report whose program is gone, and
        // a coding agent.
        fake.setAgent(first, AgentInfo(kind: "other", state: .waiting, source: "osc", message: "Build finished", since: 100, attention: true, needsUser: true))
        fake.setAgent(second, AgentInfo(kind: "deploy", state: .waiting, source: "hook", message: "Deploy needs approval", since: 90, attention: true))
        fake.setAgent(third, AgentInfo(kind: "gemini", state: .done, source: "hook", message: "All done.", since: 80, attention: true, needsUser: false))
        fake.ackOutcomes = [first: .staysWithoutAgentEvent, second: .removes]
        func agent(_ pane: PaneID) -> AgentInfo? { app.store.state.pane(pane)?.agent }
        func rows() -> [AgentRow] { app.sidebar.agentRows }
        try await ChangesFixture.wait("three rows") { rows().count == 3 && app.store.focusedPane?.id == first }
        let chip = try XCTUnwrap(app.paneHosts[PaneKey(machine: local, pane: first)]?.header.chip)
        XCTAssertEqual(chip.attributedTitle.string, "Agent \u{00B7} Needs you")
        XCTAssertFalse(chip.isHidden)

        // The inbox row's checkmark, on the agent that stays: nothing goes before the daemon says so.
        let row = try XCTUnwrap(rows().first { $0.summary.stringValue == "Build finished" })
        try XCTUnwrap(row.resolve).performClick(nil)
        XCTAssertEqual(rows().count, 3, "not removed locally")
        XCTAssertEqual(agent(first)?.attention, true, "and not assumed")
        try await ChangesFixture.wait("the ack's pane event") { agent(first)?.attention == false }
        try await ChangesFixture.wait("its row gone") { rows().count == 2 }
        XCTAssertNotNil(agent(first), "the agent stays while its program runs")
        XCTAssertFalse(chip.isHidden, "and so does its chip")
        XCTAssertEqual(chip.attributedTitle.string, "Agent \u{00B7} Idle")
        XCTAssertNil(chip.mark)

        // The row's menu, on the agent the ack removes.
        let menu = app.agentMenu(machine: local, pane: second, canReply: true)
        XCTAssertFalse(menu.items.contains { $0.title == "Reply\u{2026}" }, "nobody to reply to in a script")
        let resolve = try XCTUnwrap(menu.items.firstIndex { $0.title == "Resolve" })
        menu.performActionForItem(at: resolve)
        XCTAssertNotNil(agent(second), "not removed locally")
        try await ChangesFixture.wait("the agent removed by the daemon") { agent(second) == nil }
        try await ChangesFixture.wait("its row gone") { rows().count == 1 }

        // The Overview's R, on a coding agent: it stays, with nothing to show.
        app.showOverview()
        let key = PaneKey(machine: local, pane: third)
        try await ChangesFixture.wait("the card") { app.overview.cardViews[key] != nil }
        XCTAssertNil(app.overview.cardViews[PaneKey(machine: local, pane: first)], "the resolved agent has no card")
        app.overview.select(key)
        app.overview.resolveSelected()
        XCTAssertNotNil(app.overview.cardViews[key], "not removed locally")
        try await ChangesFixture.wait("the card gone") { app.overview.cardViews[key] == nil }
        XCTAssertEqual(agent(third)?.attention, false)
        XCTAssertNotNil(agent(third))
        app.closeOverview()
        try await ChangesFixture.wait("an empty inbox") { rows().isEmpty }
    }

    /// Progress reaches the Tab, the pane header, the row and the card from the model, and only on a
    /// machine with the feature; it raises nothing.
    func testProgressShowsOnTheTabTheHeaderTheRowAndTheCard() async throws {
        let (app, fake) = try await launch()
        defer { ChangesFixture.quit(app) }
        let local = AppDelegate.localKey
        let pane = try XCTUnwrap(app.store.focusedPane?.id)
        let tab = try XCTUnwrap(app.store.focusedTab?.id)
        let key = PaneKey(machine: local, pane: pane)
        let header = try XCTUnwrap(app.paneHosts[key]?.header)
        fake.setProgress(PaneProgress(state: .running, percent: 40), for: pane)
        try await ChangesFixture.wait("the bar on the tab and the header") {
            app.tabBar.progressBars[tab]?.progress?.percent == 40 && header.progressBar.progress?.percent == 40
        }
        XCTAssertTrue(app.sidebar.agentRows.isEmpty, "no agent: no row, and nothing in the inbox")
        XCTAssertNil(NSApp.dockTile.badgeLabel, "never a badge")
        XCTAssertNil(app.store.state.pane(pane)?.agent, "and never an agent")

        fake.setAgent(pane, AgentInfo(kind: "aider", state: .waiting, source: "hook", message: "Which file?", since: 100, attention: true))
        try await ChangesFixture.wait("the row with its bar") { app.sidebar.agentRows.first?.progressBar.progress?.percent == 40 }
        let row = try XCTUnwrap(app.sidebar.agentRows.first)
        let tabItem = try XCTUnwrap(app.tabBar.progressBars[tab]?.superview)
        fake.setProgress(PaneProgress(state: .error, percent: 55), for: pane)
        try await ChangesFixture.wait("the error") { row.progressBar.progress?.state == .error }
        XCTAssertTrue(app.sidebar.agentRows.first === row, "the same row")
        XCTAssertTrue(app.tabBar.progressBars[tab]?.superview === tabItem, "the same tab")
        XCTAssertEqual(header.progressBar.progress, PaneProgress(state: .error, percent: 55))

        app.showOverview()
        try await ChangesFixture.wait("the card with its bar") { app.overview.cardViews[key]?.progress?.percent == 55 }
        let card = try XCTUnwrap(app.overview.cardViews[key])
        fake.setProgress(PaneProgress(state: .paused, percent: 70), for: pane)
        try await ChangesFixture.wait("paused on the card") { card.progress?.state == .paused }
        XCTAssertTrue(app.overview.cardViews[key] === card, "the same card")
        app.closeOverview()

        // The machine goes away: the model still holds the pane's progress, and no bar stands still for it.
        app.showOverview()
        try await ChangesFixture.wait("the card again") { app.overview.cardViews[key]?.progress?.percent == 70 }
        func bars() -> (tab: PaneProgress?, header: PaneProgress?, row: PaneProgress?, card: PaneProgress?) {
            let tabBar = app.tabBar.progressBars[tab], rowBar = app.sidebar.agentRows.first?.progressBar
            return (tabBar?.isHidden == false ? tabBar?.progress : nil, header.progressBar.isHidden ? nil : header.progressBar.progress,
                    rowBar?.isHidden == false ? rowBar?.progress : nil, app.overview.cardViews[key]?.progress)
        }
        let paused = PaneProgress(state: .paused, percent: 70)
        XCTAssertEqual(bars().tab, paused)
        XCTAssertEqual(bars().header, paused)
        XCTAssertEqual(bars().row, paused)
        XCTAssertEqual(bars().card, paused)
        fake.dropConnection()
        try await ChangesFixture.wait("disconnected") { !app.store.isConnected }
        try await ChangesFixture.wait("no bar on the tab, the header, the row or the card") {
            bars().tab == nil && bars().header == nil && bars().row == nil && bars().card == nil
        }
        XCTAssertEqual(app.store.state.pane(pane)?.progress, paused, "the model keeps the last progress it heard")
        XCTAssertEqual(app.sidebar.agentRows.count, 1, "the agent's row is still there, without its bar")
        XCTAssertNotNil(app.overview.cardViews[key], "and so is its card")
        XCTAssertNotNil(app.tabBar.progressBars[tab], "and the tab")
        XCTAssertFalse(app.showsProgress(app.store))
        fake.restoreConnection()
        try await ChangesFixture.wait("connected again") { app.store.isConnected }
        try await ChangesFixture.wait("the bars are back") {
            bars().tab == paused && bars().header == paused && bars().row == paused && bars().card == paused
        }
        app.closeOverview()

        fake.setProgress(nil, for: pane)
        try await ChangesFixture.wait("cleared everywhere") {
            header.progressBar.isHidden && app.sidebar.agentRows.first?.progressBar.isHidden == true && app.tabBar.progressBars[tab]?.isHidden == true
        }
    }

    // MARK: The agent status sheet

    /// A clothod for the sheet: it records every command and keeps which agents are installed.
    private final class FakeClothod: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        private var states = ["claude": "installed", "codex": "outdated (chained)", "gemini": "not installed", "copilot": "not installed"]
        var calls: [[String]] { lock.withLock { all } }
        func run(_ arguments: [String]) -> RemoteCommandResult {
            lock.withLock {
                all.append(arguments)
                switch arguments.dropFirst().first {
                case "status":
                    let out = ["claude", "codex", "gemini", "copilot"].map { "\($0): \(states[$0]!)" }.joined(separator: "\n")
                    return RemoteCommandResult(status: 0, stdout: out + "\n", stderr: "")
                case "print": return RemoteCommandResult(status: 0, stdout: "{ \"hooks\": \"for \(arguments.last ?? "")\" }", stderr: "")
                case "install":
                    states[arguments.last ?? ""] = "installed"
                    return RemoteCommandResult(status: 0, stdout: "installed", stderr: "")
                case "uninstall":
                    states[arguments.last ?? ""] = "not installed"
                    return RemoteCommandResult(status: 0, stdout: "removed", stderr: "")
                default: return RemoteCommandResult(status: 1, stdout: "", stderr: "unknown")
                }
            }
        }
    }

    private func changing(_ calls: [[String]]) -> [[String]] { calls.filter { $0.contains("install") || $0.contains("uninstall") } }

    func testEveryAgentHasItsOwnInstallAndNothingRunsBeforeTheConfirmingClick() async throws {
        let (app, _) = try await launch()
        defer { ChangesFixture.quit(app) }
        let clothod = FakeClothod()
        app.agentHooks.runner = { _, arguments in clothod.run(arguments) }
        let local = AppDelegate.localKey
        XCTAssertEqual(app.hooksMenuTitle(local), "Set Up Agent Status\u{2026}", "before clothod answered")

        app.setUpAgentHooks(on: local)
        let sheet = try XCTUnwrap(app.window.attachedSheet as? AgentHooksSheet)
        defer { app.window.endSheet(sheet) }
        XCTAssertEqual(sheet.heading.stringValue, "Agent status on \(app.connections[local]?.title ?? "")")
        XCTAssertEqual(sheet.list.rows.map(\.captionLabel.stringValue), Array(repeating: "Checking\u{2026}", count: 4), "nothing to press before the status is known")
        XCTAssertTrue(sheet.list.rows.allSatisfy { $0.installButton == nil && $0.removeButton == nil })
        try await ChangesFixture.wait("the status") { sheet.list.rows.first?.removeButton != nil }

        var rows = sheet.list.rows
        XCTAssertEqual(rows.map(\.titleLabel.stringValue), ["Claude Code", "Codex", "Gemini CLI", "GitHub Copilot CLI"])
        XCTAssertEqual(rows.map(\.captionLabel.stringValue), ["Installed", "Update available", "Not installed", "Not installed"])
        XCTAssertEqual(rows.map { $0.installButton?.title }, [nil, "Update", "Install", "Install"])
        XCTAssertEqual(rows.map { $0.removeButton?.title }, ["Remove", "Remove", nil, nil])
        XCTAssertTrue(rows.allSatisfy { $0.icon.image != nil })
        XCTAssertEqual(rows[3].noteLabel?.stringValue,
                       "The GitHub Copilot CLI hook format was checked against GitHub\u{2019}s documentation, not yet against a running Copilot CLI.")
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.noteLabel == nil })
        XCTAssertEqual(rows[2].installButton?.accessibilityLabel(), "Install status hooks for Gemini CLI")
        XCTAssertEqual(rows[1].installButton?.accessibilityLabel(), "Update status hooks for Codex")
        XCTAssertEqual(rows[0].removeButton?.accessibilityLabel(), "Remove status hooks for Claude Code")
        XCTAssertEqual(rows[2].accessibilityLabel(), "Gemini CLI, Not installed")
        XCTAssertEqual(app.hooksMenuTitle(local), "Update Agent Status\u{2026}")
        // Nothing is cut: every label has the room its words need, inside the sheet.
        sheet.contentView?.layoutSubtreeIfNeeded()
        for row in rows {
            for label in [row.titleLabel, row.captionLabel, row.noteLabel].compactMap({ $0 }) {
                let needs = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)) ?? .zero
                XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, needs.height, "\(label.stringValue) has its height")
                XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, min(needs.width, AgentHookRow.textWidth), "\(label.stringValue) has its width")
                XCTAssertTrue(row.bounds.contains(label.convert(label.bounds, to: row)), "\(label.stringValue) is inside its row")
            }
            for button in [row.installButton, row.removeButton].compactMap({ $0 }) {
                XCTAssertTrue(row.bounds.contains(button.convert(button.bounds, to: row)), "\(button.title) is inside its row")
                XCTAssertTrue(button.isEnabled)
                XCTAssertEqual(button.bezelStyle, .rounded, "a native push button")
            }
        }
        XCTAssertTrue(sheet.defaultButtonCell === sheet.doneButton.cell, "Return is Done")

        // Install for Gemini CLI: clothod is asked what would change, and that is all until the click.
        try XCTUnwrap(rows[2].installButton).performClick(nil)
        try await ChangesFixture.wait("the confirmation") { sheet.attachedSheet != nil }
        XCTAssertTrue(clothod.calls.contains(["hooks", "print", "gemini"]))
        XCTAssertEqual(changing(clothod.calls), [], "nothing installed before the confirming click")
        sheet.endSheet(try XCTUnwrap(sheet.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(changing(clothod.calls), [], "Cancel installs nothing")

        try XCTUnwrap(sheet.list.rows[2].installButton).performClick(nil)
        try await ChangesFixture.wait("the confirmation again") { sheet.attachedSheet != nil }
        sheet.endSheet(try XCTUnwrap(sheet.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await ChangesFixture.wait("the install") { changing(clothod.calls) == [["hooks", "install", "gemini"]] }
        try await ChangesFixture.wait("the row says so") { sheet.list.rows[2].captionLabel.stringValue == "Installed" && sheet.list.rows[2].removeButton != nil }
        XCTAssertEqual(changing(clothod.calls), [["hooks", "install", "gemini"]], "one click, one agent")

        // Remove for Claude Code asks first too.
        rows = sheet.list.rows
        try XCTUnwrap(rows[0].removeButton).performClick(nil)
        try await ChangesFixture.wait("the question") { sheet.attachedSheet != nil }
        XCTAssertEqual(changing(clothod.calls).count, 1, "nothing removed before the confirming click")
        sheet.endSheet(try XCTUnwrap(sheet.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await ChangesFixture.wait("the removal") { changing(clothod.calls).last == ["hooks", "uninstall", "claude"] }
        try await ChangesFixture.wait("the row says so") { sheet.list.rows[0].captionLabel.stringValue == "Not installed" }
        XCTAssertEqual(changing(clothod.calls).count, 2)
    }

    /// A later clothod's fifth agent gets a row by its own name with the generic symbol, and an older
    /// one's two lines are two rows.
    func testTheListShowsWhateverClothodNames() async throws {
        let (app, _) = try await launch()
        defer { ChangesFixture.quit(app) }
        let local = AppDelegate.localKey
        app.agentHooks.lines[local] = AppDelegate.parseHookLines("claude: installed\ncodex: not installed\nopencode: not installed\nnewagent: installed")
        let list = AgentHooksListView(app: app, key: local)
        XCTAssertEqual(list.rows.map(\.titleLabel.stringValue), ["Claude Code", "Codex", "OpenCode", "newagent"])
        XCTAssertEqual(list.rows[3].removeButton?.accessibilityLabel(), "Remove status hooks for newagent")
        XCTAssertNotNil(list.rows[3].icon.image)
        app.agentHooks.lines[local] = AppDelegate.parseHookLines("claude: installed\ncodex: installed")
        app.agentHooks.announce(local)
        XCTAssertEqual(list.rows.map(\.titleLabel.stringValue), ["Claude Code", "Codex"], "it follows the status on its own")
        // A clothod that can't say (an old one): the rows say so, with nothing to press.
        app.agentHooks.lines[local] = nil
        app.agentHooks.runner = { _, _ in RemoteCommandResult(status: 2, stdout: "", stderr: "unknown command") }
        app.refreshHookStatus(local)
        try await ChangesFixture.wait("the answer that it can't say") { list.rows.first?.captionLabel.stringValue == AgentHookRow.unanswered }
        XCTAssertEqual(list.rows.count, 4)
        XCTAssertTrue(list.rows.allSatisfy { $0.installButton == nil && $0.removeButton == nil })
        // An answer that exits 0 with no line the app can read says as little: not "Checking…" for good.
        app.agentHooks.unanswered.remove(local)
        app.agentHooks.announce(local)
        XCTAssertEqual(list.rows.first?.captionLabel.stringValue, AgentHookRow.checking)
        app.agentHooks.runner = { _, _ in RemoteCommandResult(status: 0, stdout: "no agents here\n\n", stderr: "") }
        app.refreshHookStatus(local)
        try await ChangesFixture.wait("the answer with nothing in it") { list.rows.first?.captionLabel.stringValue == AgentHookRow.unanswered }
        XCTAssertNil(app.agentHooks.lines[local])
        XCTAssertEqual(list.rows.count, 4)
        XCTAssertTrue(list.rows.allSatisfy { $0.installButton == nil && $0.removeButton == nil })
        XCTAssertEqual(MachinesSettingsController.hooksSummary(lines: app.agentHooks.lines[local], unanswered: app.agentHooks.unanswered.contains(local)), AgentHookRow.unanswered)
        // A real answer after it clears that.
        app.agentHooks.runner = { _, _ in RemoteCommandResult(status: 0, stdout: "claude: installed\ncodex: not installed\n", stderr: "") }
        app.refreshHookStatus(local)
        try await ChangesFixture.wait("the real answer") { list.rows.first?.captionLabel.stringValue == "Installed" }
        XCTAssertFalse(app.agentHooks.unanswered.contains(local))
        app.agentHooks.lines[local] = nil
        app.agentHooks.runner = nil
        // A name that isn't a kind's never reaches a command line.
        app.installHooks(agent: "x; rm -rf ~", on: local, in: app.window)
        app.removeHooks(agent: "-rf", on: local, in: app.window)
        XCTAssertNil(app.window.attachedSheet)
    }
}
