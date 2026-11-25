import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Review images for agent status from any program (clothod 0.1.33), from the app launched in this process
/// on the fake backend: the sidebar's inbox and the Overview with each of the eight named kinds, "other"
/// and an unknown kind; an agent from a terminal notification with a long plain-text message; progress on
/// a Tab, a pane header, a row and a card in each state; and the agent status sheet with four agents.
/// Light and dark, narrow and wide, and every View zoom step.
///
/// Runs only with CLOTHO_SNAPSHOT_DIR set. The window is drawn from its layers, never the screen.
@MainActor
final class AgentStatusRenderTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func tearDown() { ChangesFixture.restore(saved) }

    static let long = "Deploy 4 of 12 to eu-west finished with **warnings**: see [the log](http://example.invalid/log) and run `make verify` "
        + "before the next one. Three hosts were skipped because their agents did not answer in time, and two reported a newer build "
        + "than the one being rolled out; nothing was rolled back. This text is a program's own, shown as it was sent."

    func testSnapshotsForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        XCTAssertGreaterThanOrEqual(Self.long.count, 300)
        saved = ChangesFixture.prepare(features: "git.changes,agent.decide,agent.mute,peek")
        let savedAppearance = NSApp.appearance
        let savedMotion = AgentMarkView.reducesMotion
        let savedExpanded = UserDefaults.standard.object(forKey: SidebarView.workingExpandedKey)
        UserDefaults.standard.set(true, forKey: SidebarView.workingExpandedKey)
        // Still images: the indeterminate bar and the working ring stand still.
        AgentMarkView.reducesMotion = { true }
        let app = ChangesFixture.launch()
        let savedScale = UIScale.factor, savedScaleDefault = UserDefaults.standard.object(forKey: UIScale.defaultsKey)
        defer {
            app.setUIScale(savedScale)
            UserDefaults.standard.set(savedScaleDefault, forKey: UIScale.defaultsKey)
            UserDefaults.standard.set(savedExpanded, forKey: SidebarView.workingExpandedKey)
            AgentMarkView.reducesMotion = savedMotion
            ChangesFixture.quit(app)
            NSApp.appearance = savedAppearance
            Theme.followAppAppearance()
        }
        try await ChangesFixture.wait("a workspace") { app.store.focusedWorkspace != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        let first = app.store.state.workspaces.map(\.id)
        let now = Date().timeIntervalSince1970
        let sleep = SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp")
        let local = AppDelegate.localKey

        // One Tab per kind in "agents", with every state among them and progress in each of its states.
        typealias Spec = (kind: String, tab: String, state: AgentInfo.State, source: String, message: String, needsUser: Bool?, progress: PaneProgress?)
        let specs: [Spec] = [
            ("claude", "api", .waiting, "hook", "Which of the two migrations should run first?", nil, PaneProgress(state: .running, percent: 40)),
            ("codex", "relay", .running, "hook", "Updating the protocol doc.", nil, PaneProgress(state: .indeterminate)),
            ("opencode", "site", .done, "hook", "Both pages build.", false, nil),
            ("gemini", "tests", .running, "hook", "Running the iPhone UI suite.", nil, PaneProgress(state: .running, percent: 85)),
            ("copilot", "review", .done, "hook", "Asks whether to squash the three commits.", true, nil),
            ("aider", "refactor", .error, "hook", "The API rate limit was reached.", nil, PaneProgress(state: .error, percent: 55)),
            ("amp", "search", .running, "hook", "Indexing the repository.", nil, PaneProgress(state: .paused, percent: 70)),
            ("cursor", "ui", .done, "hook", "Renamed the module.", false, nil),
            ("other", "build", .waiting, "osc", Self.long, true, PaneProgress(state: .running, percent: 100)),
            ("deploy", "deploy", .waiting, "hook", "Deploy needs approval", nil, nil),
        ]
        let created = try await fake.createWorkspace(name: "agents", spawn: SpawnOptions(command: ["/bin/zsh", "-f"], cwd: "/tmp"))
        for id in first { try await fake.closeWorkspace(id) }
        var panes: [PaneID] = [created.pane]
        var tabs: [TabID] = [created.tab]
        for _ in specs.dropFirst() {
            let tab = try await fake.createTab(in: created.workspace, spawn: sleep)
            panes.append(tab.pane)
            tabs.append(tab.tab)
        }
        for (index, spec) in specs.enumerated() {
            try await fake.renameTab(tabs[index], title: spec.tab)
            fake.setAgent(panes[index], AgentInfo(kind: spec.kind, state: spec.state, source: spec.source, message: spec.message,
                                                  since: now - Double(120 + index * 95), attention: spec.state != .running, needsUser: spec.needsUser))
            fake.setProgress(spec.progress, for: panes[index])
            fake.setPeek(panes[index], lines: ["$ \(spec.tab)", "  \(spec.kind) at work"])
        }
        try await fake.focus(.pane(panes[0]))
        try await ChangesFixture.wait("the agents and their progress") {
            panes.indices.allSatisfy { app.store.state.pane(panes[$0])?.agent?.kind == specs[$0].kind && app.store.state.pane(panes[$0])?.progress == specs[$0].progress }
                && app.store.focusedPane?.id == panes[0]
        }
        let overview: OverviewView = app.overview
        func settle() async throws {
            try await Task.sleep(nanoseconds: 150_000_000)
            app.window.contentView?.layoutSubtreeIfNeeded()
            app.window.displayIfNeeded()
        }
        func key(_ index: Int) -> PaneKey { PaneKey(machine: local, pane: panes[index]) }

        /// Nothing of a row, a card or a tab is outside it or cut short, whatever the size and zoom.
        func check(_ what: String) throws {
            let rows = app.sidebar.agentRows
            XCTAssertEqual(rows.count, specs.count, "every kind has a row, \(what)")
            for row in rows {
                XCTAssertTrue(row.bounds.contains(row.kindGlyph.frame), "the glyph is inside its row, \(what)")
                XCTAssertNotNil(row.kindGlyph.image, what)
                XCTAssertEqual(row.kindGlyph.isHidden, row.bounds.width < AgentRow.glyphLeastRow, "the glyph only where the row has room, \(what)")
                XCTAssertLessThanOrEqual(row.summary.frame.maxX, row.kindGlyph.frame.minX + 2.5, what)
                XCTAssertGreaterThanOrEqual(row.label.frame.height + 0.5, row.label.cell?.cellSize.height ?? .infinity, "the row's title has its height, \(what)")
                if !row.summary.isHidden {
                    XCTAssertGreaterThanOrEqual(row.summary.frame.height + 0.5, row.summary.cell?.cellSize.height ?? .infinity, "the row's text has its height, \(what)")
                }
                XCTAssertTrue(row.bounds.contains(row.progressBar.frame), what)
            }
            XCTAssertEqual(rows.filter { !$0.progressBar.isHidden }.count, specs.filter { $0.progress != nil }.count, "a bar on each row whose pane has progress, \(what)")
            for (id, bar) in app.tabBar.progressBars {
                let item = try XCTUnwrap(bar.superview as? ChromeItem)
                XCTAssertTrue(item.bounds.contains(bar.frame), "tab \(id), \(what)")
                XCTAssertFalse(bar.frame.intersects(item.label.frame), "tab \(id): the bar is clear of the title, \(what)")
            }
            let header = try XCTUnwrap(app.paneHosts[key(0)]?.header)
            XCTAssertTrue(header.bounds.contains(header.progressBar.frame), what)
            XCTAssertTrue(header.bounds.contains(header.chip.frame), what)
        }

        func checkCards(_ what: String) throws {
            XCTAssertEqual(overview.cardViews.count, specs.count, "every kind has a card, \(what)")
            for (index, spec) in specs.enumerated() {
                let view = try XCTUnwrap(overview.cardViews[key(index)], "\(spec.kind), \(what)")
                XCTAssertEqual(view.sub.stringValue.contains(AgentKind.of(spec.kind).shortName), true, "\(spec.kind), \(what)")
                XCTAssertNotNil(view.kindGlyph.image, "\(spec.kind), \(what)")
                XCTAssertEqual(view.progress, spec.progress, "\(spec.kind), \(what)")
                for part in [view.place, view.age, view.message, view.sub, view.branch, view.counts] as [NSView] + [view.kindGlyph, view.progressBar] {
                    let frame = part.superview === view.footer ? view.footer.convert(part.frame, to: view.body) : part.frame
                    XCTAssertTrue(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(type(of: part)) of \(spec.kind) is inside its card, \(what)")
                }
                for label in [view.place, view.age, view.sub] {
                    XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, label.cell?.cellSize.height ?? .infinity,
                                                "\u{201C}\(label.stringValue)\u{201D} has its height, \(spec.kind), \(what)")
                }
                XCTAssertLessThanOrEqual(view.kindGlyph.frame.maxX, view.sub.frame.minX, what)
            }
            // The long plain text: as it came, on at most two lines, cut with an ellipsis and never drawn outside.
            let long = try XCTUnwrap(overview.cardViews[key(8)])
            XCTAssertEqual(long.message.stringValue, AgentNotice.plainLine(Self.long))
            XCTAssertTrue(long.message.stringValue.contains("**warnings**"), "no Markdown read")
            XCTAssertLessThanOrEqual(long.message.frame.maxY, long.sub.frame.minY + 0.5, what)
        }

        for (size, sidebar, width, height) in [("narrow", 150, 760, 520), ("wide", 260, 1280, 800)] as [(String, CGFloat, CGFloat, CGFloat)] {
            app.window.setContentSize(NSSize(width: width, height: height))
            app.sidebarWidth.constant = sidebar
            for mode in [Theme.Mode.light, .dark] {
                app.setAppearance(mode)
                try await settle()
                app.appearanceChanged()
                try await settle()
                try check("\(size) \(mode.rawValue)")
                saveSnapshot(of: app.container, to: "\(folder)/agent-status-inbox-\(size)-\(mode.rawValue).png")
                app.showOverview()
                try await ChangesFixture.wait("the cards, \(size) \(mode.rawValue)") { overview.cardViews.count == specs.count && overview.cardViews[key(0)]?.progress != nil }
                try await settle()
                try checkCards("\(size) \(mode.rawValue)")
                saveSnapshot(of: app.container, to: "\(folder)/agent-status-overview-\(size)-\(mode.rawValue).png")
                app.closeOverview()
            }
        }

        // The pane header with its bar in each state (the focused Tab's), light and dark.
        app.window.setContentSize(NSSize(width: 1280, height: 800))
        app.sidebarWidth.constant = 260
        for mode in [Theme.Mode.light, .dark] {
            app.setAppearance(mode)
            try await settle()
            app.appearanceChanged()
            for (index, spec) in specs.enumerated() where [0, 1, 5, 6].contains(index) {
                try await fake.focus(.pane(panes[index]))
                try await ChangesFixture.wait("\(spec.tab) in front") { app.store.focusedPane?.id == panes[index] && app.paneHosts[key(index)]?.header.progressBar.progress == spec.progress }
                try await settle()
                let header = try XCTUnwrap(app.paneHosts[key(index)]?.header)
                XCTAssertEqual(header.chip.symbol, AgentKind.of(spec.kind).symbolName)
                XCTAssertEqual(header.progressBar.accessibilityValue() as? String, spec.progress.map(ProgressBarView.spokenValue))
                saveSnapshot(of: app.container, to: "\(folder)/agent-status-header-\(spec.progress!.state.rawValue)-\(mode.rawValue).png")
            }
        }
        try await fake.focus(.pane(panes[0]))
        try await ChangesFixture.wait("the first tab again") { app.store.focusedPane?.id == panes[0] }

        // View > Zoom, every step, narrow and wide: nothing new is cut at any of them.
        app.setAppearance(.light)
        for (size, sidebar, width, height) in [("narrow", 150, 760, 520), ("wide", 260, 1280, 800)] as [(String, CGFloat, CGFloat, CGFloat)] {
            app.window.setContentSize(NSSize(width: width, height: height))
            for percent in stride(from: 80, through: 160, by: 10) {
                app.setUIScale(CGFloat(percent) / 100)
                app.sidebarWidth.constant = sidebar
                try await settle()
                app.appearanceChanged()
                try await settle()
                try check("\(size) at \(percent) %")
                saveSnapshot(of: app.container, to: "\(folder)/agent-status-scale-inbox-\(size)-\(percent).png")
                app.showOverview()
                try await ChangesFixture.wait("the cards, \(size) at \(percent) %") { overview.cardViews.count == specs.count && overview.cardViews[key(0)]?.progress != nil }
                try await settle()
                try checkCards("\(size) at \(percent) %")
                saveSnapshot(of: app.container, to: "\(folder)/agent-status-scale-overview-\(size)-\(percent).png")
                app.closeOverview()
            }
        }
        app.setUIScale(savedScale)
        try await settle()

        // The agent status sheet with four agents, each in a different state, light and dark.
        app.agentHooks.runner = { _, _ in
            RemoteCommandResult(status: 0, stdout: "claude: installed\ncodex: installed (chained)\ngemini: outdated\ncopilot: not installed\n", stderr: "")
        }
        for mode in [Theme.Mode.light, .dark] {
            app.setAppearance(mode)
            try await settle()
            app.setUpAgentHooks(on: local)
            let sheet = try XCTUnwrap(app.window.attachedSheet as? AgentHooksSheet)
            try await ChangesFixture.wait("the status") { sheet.list.rows.count == 4 && sheet.list.rows[3].installButton != nil }
            sheet.contentView?.layoutSubtreeIfNeeded()
            sheet.displayIfNeeded()
            XCTAssertEqual(sheet.list.rows.map(\.captionLabel.stringValue), ["Installed", "Installed (chained)", "Update available", "Not installed"])
            let content = try XCTUnwrap(sheet.contentView)
            for row in sheet.list.rows {
                XCTAssertTrue(content.bounds.contains(row.convert(row.bounds, to: content)), "the row is inside the sheet")
            }
            saveSnapshot(of: content, to: "\(folder)/agent-status-sheet-\(mode.rawValue).png")
            app.window.endSheet(sheet)
            try await settle()
        }
    }
}
