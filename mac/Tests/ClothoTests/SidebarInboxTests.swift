import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The sidebar's inbox: above the machines, the agents that need the user, the finished ones and (closed
/// unless opened) the working ones, each on one line. With no agent to show, the sidebar is the workspace
/// list alone.
@MainActor
final class SidebarInboxTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarView!
    private var savedExpanded: Any?
    private var savedCollapsed: Any?

    override func setUp() {
        _ = NSApplication.shared
        savedExpanded = UserDefaults.standard.object(forKey: SidebarView.workingExpandedKey)
        savedCollapsed = UserDefaults.standard.object(forKey: "CollapsedMachines")
        UserDefaults.standard.removeObject(forKey: SidebarView.workingExpandedKey)
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        make(width: 236)
    }

    override func tearDown() {
        Pointer.simulation = .off
        window.close()
        UserDefaults.standard.set(savedExpanded, forKey: SidebarView.workingExpandedKey)
        UserDefaults.standard.set(savedCollapsed, forKey: "CollapsedMachines")
    }

    private func make(width: CGFloat, appearance: NSAppearance? = nil) {
        window?.close()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = appearance }
        sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
    }

    private func entry(_ pane: PaneID, _ state: AgentInfo.State, attention: Bool? = true, needsUser: Bool? = nil,
                       settling: Bool? = nil, muted: Bool? = nil, message: String? = nil, since: Double = 100,
                       requests: [PermissionRequest]? = nil, workspace: String = "clotho", tab: String = "alerts",
                       canMute: Bool = true) -> AgentEntry {
        var entry = AgentEntry(machine: "local", machineName: "devbox", pane: pane,
                               workspace: Workspace(id: 1, name: workspace, tabs: []), tab: nil, paneTitle: nil, tabTitle: tab,
                               info: AgentInfo(kind: "claude", state: state, source: "hook", message: message, since: since,
                                               attention: attention, muted: muted, requests: requests, needsUser: needsUser,
                                               settling: settling),
                               canReply: false)
        entry.canMute = canMute
        return entry
    }

    /// "clotho" (1) with three tabs, selected, and "docs" (2) with one.
    private func group(marks: [WorkspaceID: AgentMarkCount] = [:]) -> SidebarGroup {
        let tab = { (id: UInt64) in Tab(id: TabID(id), activePane: PaneID(id * 10), layout: .pane(PaneID(id * 10))) }
        return SidebarGroup(key: "local", title: "devbox", status: (nil, nil),
                            workspaces: [Workspace(id: 1, name: "clotho", tabs: [tab(10), tab(11), tab(12)]),
                                         Workspace(id: 2, name: "docs", tabs: [tab(20)])],
                            selected: 1, isConnected: true, isLocal: true, marks: marks)
    }

    private func update(_ agents: [AgentEntry], group: SidebarGroup? = nil) {
        sidebar.update(agents: agents, groups: [group ?? self.group()])
        sidebar.layoutSubtreeIfNeeded()
    }

    private func all<T: NSView>(_ type: T.Type) -> [T] {
        func find(_ view: NSView) -> [T] { view.subviews.flatMap { ($0 as? T).map { [$0] } ?? find($0) } }
        return find(sidebar).sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
    }

    private var headers: [String] { all(SectionHeader.self).map { [$0.title.stringValue, $0.count.isHidden ? nil : $0.count.stringValue].compactMap { $0 }.joined(separator: " ") } }
    private var agentRows: [AgentRow] { all(AgentRow.self) }

    /// One of each: two that need the user (a wait and a failure), one finished turn that asks, one plain
    /// finished turn, and two working.
    private var mixed: [AgentEntry] {
        [
            entry(1, .running, attention: nil, message: "Editing Sources/Model.swift", since: 400, workspace: "infra", tab: "deploy"),
            entry(2, .done, needsUser: false, message: "All 212 tests pass.", since: 300, workspace: "web", tab: "tests"),
            entry(3, .waiting, needsUser: true, since: 250, requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test")]),
            entry(4, .error, needsUser: true, message: "The build failed.", since: 200, workspace: "api", tab: "build"),
            entry(5, .done, needsUser: true, message: "Should I push it?", since: 100, workspace: "api", tab: "fix"),
            entry(6, .starting, attention: nil, since: 500, workspace: "infra", tab: "plan"),
        ]
    }

    private func press(_ code: UInt16) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "",
                                                   charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        sidebar.keyDown(with: event)
    }

    private func click(_ view: NSView) throws {
        view.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                              clickCount: 1, pressure: 1)))
    }

    // MARK: Sections

    func testNoAgentsNoInbox() {
        update([])
        XCTAssertTrue(headers.isEmpty, "no inbox titles and no Workspaces title")
        XCTAssertTrue(agentRows.isEmpty)
        XCTAssertTrue(all(DisclosureRow.self).isEmpty)
        XCTAssertEqual(all(SidebarRow.self).map(\.label.stringValue), ["clotho", "docs"], "the workspace list as before")
        XCTAssertEqual(sidebar.order, [.workspace("local", 1), .workspace("local", 2)])
    }

    func testEachSectionOnlyWhenItHasRows() {
        update([entry(1, .waiting, needsUser: true)])
        XCTAssertEqual(headers, ["NEEDS YOU 1", "WORKSPACES"])
        XCTAssertTrue(all(DisclosureRow.self).isEmpty)

        update([entry(1, .done, needsUser: false)])
        XCTAssertEqual(headers, ["DONE 1", "WORKSPACES"])

        update([entry(1, .running, attention: nil)])
        XCTAssertEqual(headers, ["WORKSPACES"], "Working is a disclosure row, not a title")
        XCTAssertEqual(all(DisclosureRow.self).map(\.label.stringValue), ["Working"])

        update(mixed)
        XCTAssertEqual(headers, ["NEEDS YOU 3", "DONE 1", "WORKSPACES"])
        // The inbox is above the first machine.
        let machine = all(MachineHeader.self)[0], workspaces = all(SectionHeader.self).last!
        let y = { (view: NSView) in view.convert(NSPoint.zero, to: nil).y }
        XCTAssertGreaterThan(y(workspaces), y(machine))
        XCTAssertTrue(agentRows.allSatisfy { y($0) > y(workspaces) })
    }

    func testNeedsYouHoldsWaitsErrorsAndTurnsThatAskOldestFirst() {
        update(mixed)
        XCTAssertEqual(sidebar.order.prefix(4), [.agent("local", 5), .agent("local", 4), .agent("local", 3), .agent("local", 2)],
                       "the longest wait first, then Done")
        XCTAssertEqual(agentRows.prefix(3).map(\.mark.mark), [.needsYou, .error, .needsYou])
        XCTAssertEqual(agentRows.prefix(3).map(\.summary.stringValue), ["Should I push it?", "The build failed.", "Allow Bash: cargo test"])
    }

    func testDoneHoldsPlainFinishedTurnsWithAttention() {
        update([entry(1, .done, needsUser: false, message: "All 212 tests pass."), entry(2, .done, attention: false, needsUser: false),
                entry(3, .done)])
        XCTAssertEqual(headers, ["DONE 2", "WORKSPACES"], "a resolved one is gone; an older daemon's done counts")
        XCTAssertEqual(Set(agentRows.map(\.mark.mark)), [.done])
    }

    func testWorkingIsClosedWithItsCountAndOpensOnClick() throws {
        update(mixed)
        let section = try XCTUnwrap(all(DisclosureRow.self).first)
        XCTAssertEqual(section.label.stringValue, "Working")
        XCTAssertEqual(section.accessibilityLabel(), "Working, 2 agents")
        XCTAssertFalse(section.chevron.isExpanded, "closed unless opened")
        XCTAssertEqual(agentRows.count, 4, "its rows aren't listed")
        XCTAssertFalse(sidebar.order.contains(.agent("local", 1)))

        try click(section)
        let deadline = Date().addingTimeInterval(3)
        while agentRows.count != 6, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SidebarView.workingExpandedKey), "remembered")
        XCTAssertEqual(agentRows.count, 6)
        XCTAssertEqual(sidebar.order.prefix(6).suffix(2), [.agent("local", 6), .agent("local", 1)], "the most recent first")
        XCTAssertEqual(agentRows.suffix(2).map(\.mark.mark), [.working, .working])
        XCTAssertTrue(agentRows.suffix(2).allSatisfy { $0.actions == nil }, "nothing to resolve on a working agent")
        XCTAssertTrue(try XCTUnwrap(all(DisclosureRow.self).first).chevron.isExpanded)
    }

    func testSettlingAndMutedAgentsAreInNoSection() {
        update([entry(1, .done, attention: false, settling: true), entry(2, .waiting, needsUser: true, muted: true),
                entry(3, .waiting, attention: false), entry(4, .done, attention: false)])
        XCTAssertTrue(headers.isEmpty, "nor idle and resolved ones: no inbox at all")
        XCTAssertTrue(agentRows.isEmpty)
        XCTAssertTrue(all(DisclosureRow.self).isEmpty)
    }

    func testInboxTitlesHaveTheNotificationSwitches() throws {
        let menu = NSMenu()
        menu.addItem(withTitle: "Notify When Done", action: nil, keyEquivalent: "")
        sidebar.agentsMenu = { menu }
        UserDefaults.standard.set(true, forKey: SidebarView.workingExpandedKey)
        update(mixed)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = all(SectionHeader.self)
        XCTAssertTrue(titles[0].menu(for: event) === menu)
        XCTAssertTrue(titles[1].menu(for: event) === menu)
        XCTAssertNil(titles[2].menu(for: event), "Workspaces has none")
        XCTAssertTrue(try XCTUnwrap(all(DisclosureRow.self).first).menu(for: event) === menu)
    }

    // MARK: Rows

    func testRowsAreOneLineWithNoButtonsOutsideTheHoverOverlay() throws {
        UserDefaults.standard.set(true, forKey: SidebarView.workingExpandedKey)
        update(mixed)
        XCTAssertEqual(agentRows.count, 6)
        for row in agentRows {
            XCTAssertEqual(row.frame.height, 26, accuracy: 0.5)
            XCTAssertEqual(row.label.stringValue.components(separatedBy: " › ").count, 2, "workspace › tab, no machine")
            XCTAssertEqual(row.label.textColor, Theme.foreground)
            XCTAssertEqual(row.summary.textColor, Theme.dimText)
            XCTAssertEqual(row.summary.maximumNumberOfLines, 1)
            XCTAssertEqual(row.label.frame.midY, row.summary.frame.midY, accuracy: 1.5, "one line")
            let labels = row.subviews.compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.count, 2, "the title and what it says: no machine name, no time")
            XCTAssertTrue(row.subviews.compactMap { $0 as? NSButton }.isEmpty, "no buttons in the row itself")
            XCTAssertEqual(row.subviews.compactMap { $0 as? NSImageView }, [row.kindGlyph], "the mark, and the kind's small glyph at the end")
            XCTAssertNotNil(row.kindGlyph.image)
        }
        // The mark, then the title where workspace names start, then the text to the row's end.
        let row = agentRows[2]
        XCTAssertLessThan(row.mark.frame.maxX, row.label.frame.minX)
        XCTAssertEqual(row.label.alignmentRect(forFrame: row.label.frame).minX, MachineHeader.nameInset, accuracy: 1)
        XCTAssertLessThan(row.label.frame.maxX, row.summary.frame.minX + 1)
        XCTAssertLessThanOrEqual(row.summary.frame.maxX, row.bounds.maxX)
        XCTAssertGreaterThan(row.summary.frame.width, 40, "it takes the rest")
    }

    func testALongTitleLeavesRoomForTheText() {
        update([entry(1, .waiting, needsUser: true, message: "Allow running the whole suite again?",
                      workspace: "a workspace with a very long name indeed", tab: "and a tab whose title goes on and on")])
        let row = agentRows[0]
        XCTAssertLessThanOrEqual(row.label.alignmentRect(forFrame: row.label.frame).maxX, row.bounds.width * AgentRow.titleShare + 0.5,
                                 "the title ends within its share of the row")
        XCTAssertGreaterThan(row.label.frame.width, 40, "and still shows")
        XCTAssertGreaterThan(row.summary.frame.width, 40, "so the text always shows")
        // An agent that said nothing: the title has the row.
        update([entry(1, .done, needsUser: false, workspace: "a workspace with a very long name indeed", tab: "and a tab whose title goes on and on")])
        XCTAssertTrue(agentRows[0].summary.isHidden)
        XCTAssertGreaterThan(agentRows[0].label.frame.maxX, agentRows[0].bounds.width * AgentRow.titleShare)
        XCTAssertLessThanOrEqual(agentRows[0].label.frame.maxX, agentRows[0].bounds.maxX)
    }

    func testTooltipAndAccessibilityLabelSayEverything() {
        UserDefaults.standard.set(true, forKey: SidebarView.workingExpandedKey)
        update(mixed)
        let waiting = agentRows[2]
        XCTAssertEqual(waiting.accessibilityLabel(), "Needs you: Claude Code, clotho › alerts on devbox. Allow Bash: cargo test")
        XCTAssertEqual(waiting.toolTip, waiting.accessibilityLabel())
        XCTAssertEqual(agentRows[1].accessibilityLabel(), "Error: Claude Code, api › build on devbox. The build failed.")
        XCTAssertEqual(agentRows[3].accessibilityLabel(), "Done: Claude Code, web › tests on devbox. All 212 tests pass.")
        XCTAssertEqual(agentRows[4].accessibilityLabel(), "Working: Claude Code, infra › plan on devbox", "nothing said: no text")
        XCTAssertTrue(agentRows.allSatisfy { $0.isAccessibilityElement() })
        XCTAssertEqual(all(SectionHeader.self).map { $0.accessibilityLabel() }, ["Needs you, 3 agents", "Done, 1 agent", "Workspaces"])
        XCTAssertEqual(agentRows[0].mark.accessibilityLabel(), "Needs you")
    }

    func testHoverShowsMuteAndResolveAndMovesNothing() throws {
        var resolved: [PaneID] = [], muted: [PaneID] = []
        sidebar.onResolveAgent = { resolved.append($1) }
        sidebar.onMuteAgent = { muted.append($1) }
        update(mixed)
        let row = agentRows[0]
        let actions = try XCTUnwrap(row.actions)
        XCTAssertEqual(actions.alphaValue, 0, "hidden at rest")
        let before = (row.label.frame, row.summary.frame, row.mark.frame, actions.frame)
        row.setHovering(true)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(actions.alphaValue, 1)
        XCTAssertEqual(row.label.frame, before.0)
        XCTAssertEqual(row.summary.frame, before.1)
        XCTAssertEqual(row.mark.frame, before.2)
        XCTAssertEqual(actions.frame, before.3)
        XCTAssertTrue(row.bounds.contains(actions.frame), "inside the row")
        let mute = try XCTUnwrap(row.mute), resolve = try XCTUnwrap(row.resolve)
        XCTAssertEqual([mute.accessibilityLabel(), resolve.accessibilityLabel()], ["Mute", "Resolve"])
        XCTAssertLessThan(mute.convert(NSPoint.zero, to: row).x, resolve.convert(NSPoint.zero, to: row).x, "Mute is left of Resolve")
        resolve.performClick(nil)
        mute.performClick(nil)
        XCTAssertEqual(resolved, [5])
        XCTAssertEqual(muted, [5])
        row.setHovering(false)
        XCTAssertEqual(actions.alphaValue, 0)
        // Done rows have them too; a daemon that can't mute offers Resolve alone.
        XCTAssertNotNil(agentRows[3].actions)
        update([entry(1, .waiting, needsUser: true, canMute: false)])
        XCTAssertNil(agentRows[0].mute)
        XCTAssertNotNil(agentRows[0].resolve)
    }

    func testRightClickAndClick() throws {
        var asked: [(MachineKey, PaneID, Bool)] = [], opened: [PaneID] = []
        let menu = NSMenu()
        for title in ["Open Pane", "Resolve", "Mute"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        sidebar.agentRowMenu = { asked.append(($0, $1, $2)); return menu }
        sidebar.onOpenAgent = { opened.append($1) }
        update(mixed)
        let shown = try XCTUnwrap(agentRows[0].contextMenu?())
        XCTAssertEqual(shown.items.map(\.title), ["Open Pane", "Resolve", "Mute"])
        XCTAssertEqual(asked.map(\.1), [5])
        try click(agentRows[1])
        XCTAssertEqual(opened, [4], "a click opens the agent's pane")
    }

    /// The app's own menu for a row: Resolve and Mute among its items.
    func testTheAgentMenuHasResolveAndMute() async throws {
        let app = AppDelegate()
        let fake = FakeBackend(extraFeatures: ["agent.mute"])
        let connection = MachineConnection(machine: .local, backend: fake)
        app.connections[AppDelegate.localKey] = connection
        try await connection.store.start()
        defer { connection.store.stop() }
        let pane = try await fake.createWorkspace(name: "clotho", spawn: SpawnOptions(command: ["/bin/sleep", "30"])).pane
        fake.setAgent(pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", attention: true, needsUser: true))
        let deadline = Date().addingTimeInterval(5)
        while connection.store.state.pane(pane)?.agent == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let titles = app.agentMenu(machine: AppDelegate.localKey, pane: pane, canReply: false).items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(3)), ["Open Pane", "Resolve", "Mute"])
    }

    // MARK: Keyboard

    func testArrowsReachInboxRowsAndReturnOpens() throws {
        update(mixed)
        var selected: [WorkspaceID] = [], opened: [PaneID] = []
        sidebar.onSelect = { selected.append($1) }
        sidebar.onOpenAgent = { opened.append($1) }
        sidebar.takeKeyboard()
        XCTAssertEqual(sidebar.cursor, .workspace("local", 1), "it starts on the selected workspace, not in the inbox")
        try press(126)  // ↑ to the last inbox row (Done)
        XCTAssertEqual(sidebar.cursor, .agent("local", 2))
        XCTAssertTrue(agentRows[3].showsCursor)
        XCTAssertTrue(selected.isEmpty, "an agent's row only takes the cursor")
        XCTAssertTrue(opened.isEmpty, "and nothing opens until Return")
        try press(126)  // ↑ into Needs you
        XCTAssertEqual(sidebar.cursor, .agent("local", 3))
        try press(36)   // Return
        XCTAssertEqual(opened, [3])
        try press(125)  // ↓
        try press(125)  // ↓ back on the workspace: selected as the cursor reaches it
        XCTAssertEqual(sidebar.cursor, .workspace("local", 1))
        XCTAssertEqual(selected, [1])
        try press(125)
        XCTAssertEqual(selected, [1, 2])
        // Return on a workspace still renames it.
        try press(36)
        XCTAssertTrue(sidebar.isEditing)
        XCTAssertEqual(opened, [3])
        all(SidebarRow.self).forEach { $0.endEditing(commit: false) }
    }

    func testOnlyInboxRowsStillStartsOnAWorkspace() {
        var group = self.group()
        group = SidebarGroup(key: group.key, title: group.title, status: (nil, nil), workspaces: group.workspaces, selected: nil,
                             isConnected: true, isLocal: true)
        update(mixed, group: group)
        sidebar.takeKeyboard()
        XCTAssertEqual(sidebar.cursor, .workspace("local", 1), "nothing selected here: the first workspace")
    }

    // MARK: Narrow

    func testAtTheNarrowestSidebarEveryLabelIsInsideItsRow() {
        make(width: 150)
        UserDefaults.standard.set(true, forKey: SidebarView.workingExpandedKey)
        update(mixed, group: group(marks: [1: AgentMarkCount(mark: .needsYou, count: 12), 2: AgentMarkCount(mark: .done, count: 1)]))
        XCTAssertEqual(agentRows.count, 6)
        func check(_ row: NSView, _ name: String) {
            XCTAssertEqual(row.frame.width, 150 - 16, accuracy: 0.5, name)
            func walk(_ view: NSView) {
                for sub in view.subviews where !sub.isHidden {
                    if sub is NSTextField || sub is AgentMarkView || sub is AgentChip {
                        let frame = row.convert(sub.bounds, from: sub)
                        XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name): \(type(of: sub)) at \(frame)")
                        XCTAssertGreaterThan(frame.width, 0, "\(name): \(type(of: sub)) has no room")
                    }
                    walk(sub)
                }
            }
            walk(row)
        }
        for row in agentRows {
            check(row, row.label.stringValue)
            XCTAssertGreaterThan(row.label.frame.width, 20)
            if !row.summary.isHidden { XCTAssertGreaterThan(row.summary.frame.width, 20, row.label.stringValue) }
        }
        for row in all(SidebarRow.self) {
            check(row, row.label.stringValue)
            XCTAssertLessThanOrEqual(row.label.frame.maxX, row.badge.frame.minX)
            XCTAssertLessThanOrEqual(row.badge.frame.maxX, row.tabCount.frame.minX)
        }
        all(SectionHeader.self).forEach { check($0, $0.title.stringValue) }
        all(DisclosureRow.self).forEach { check($0, "Working") }
    }

    // MARK: Review images

    /// The sidebar with all three sections, light and dark, at 150 and 236 pt, Working open and closed.
    /// Runs only with CLOTHO_SNAPSHOT_DIR set.
    func testSnapshotsForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        let saved = NSApp.appearance
        defer {
            NSApp.appearance = saved
            Theme.followAppAppearance()
        }
        let marks: [WorkspaceID: AgentMarkCount] = [1: AgentMarkCount(mark: .needsYou, count: 2), 2: AgentMarkCount(mark: .working, count: 1)]
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            Theme.followAppAppearance()
            for width in [150, 236] as [CGFloat] {
                for open in [false, true] {
                    UserDefaults.standard.set(open, forKey: SidebarView.workingExpandedKey)
                    make(width: width, appearance: NSApp.appearance)
                    update(mixed, group: group(marks: marks))
                    guard let rep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) else { return XCTFail("no image") }
                    sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
                    let file = "\(folder)/sidebar-inbox-\(name)-\(Int(width))-working-\(open ? "open" : "closed").png"
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                }
            }
        }
    }
}
