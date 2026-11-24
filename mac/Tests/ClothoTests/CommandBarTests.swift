import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// ⌘P, the command bar: with nothing typed a tree (Needs you, then this machine's workspaces with the
/// current one open; → expands, ← collapses and climbs to the machine list; arrows preview tabs; Esc goes
/// back); typing searches every machine flat (best names first, workspaces leading); Tab/⇧Tab leave the
/// search; ⌘⌫ closes, ⌥↩ opens a new tab (or allows an agent's permission request), ⌘1–9 pick a row, and ⌘P
/// again closes the bar. A state word ("needs", "working", "done") lists the agents in that state first.
@MainActor
final class CommandBarTests: XCTestCase {
    private var window: NSWindow!
    private var bar: QuickOpenOverlay!
    private var opened: [String] = []
    private var previewed: [String] = []
    private var restored = 0
    private var dismissed = 0

    private var settleDelay: TimeInterval = 0

    override func setUp() {
        _ = NSApplication.shared
        // No wait before ⌥↩ allows the request under the selection, except where a test is about it.
        settleDelay = AskBar.settleDelay
        AskBar.settleDelay = 0
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    }

    override func tearDown() {
        AskBar.settleDelay = settleDelay
        window.close()
    }

    private func tab(_ title: String, machine: String, workspace: String, tier: Int, panes: Int = 1, mark: AgentMark? = nil, detail: String? = nil,
                     id: String? = nil) -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .tab, title: title, subtitle: "\(machine) · \(workspace)", id: id ?? "tab|\(machine)|\(title)"),
                        tier: tier, mark: mark, detail: detail, panes: panes, path: "\(machine) › \(workspace)")
    }

    /// This Mac ("local", MacBook) with "Platform" (current: api 11, web 12, docs 13) and "Notes" (notes
    /// 21); devbox ("bb") with "Infra" (api-gateway 31) and an agent waiting on its pane 7.
    private var current: [CommandBarEntry] {
        [tab("api", machine: "MacBook", workspace: "Platform", tier: 1, id: "tab|local|11"),
         tab("web", machine: "MacBook", workspace: "Platform", tier: 1, panes: 2, id: "tab|local|12"),
         tab("docs", machine: "MacBook", workspace: "Platform", tier: 1, mark: .needsYou, detail: "waiting: Allow Bash?", id: "tab|local|13")]
    }

    private var all: [CommandBarEntry] {
        [CommandBarEntry(item: QuickOpenItem(kind: .agent, title: "Claude Code: deploy api", subtitle: "devbox · Infra › deploy", id: "agent|bb|7"),
                         tier: 0, mark: .needsYou, detail: "waiting: Allow Bash?", path: "devbox › Infra › deploy"),
         CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "Platform", subtitle: "MacBook", id: "ws|local|1"), tier: 1, path: "MacBook")]
            + current
            + [CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "Notes", subtitle: "MacBook", id: "ws|local|2"), tier: 2, path: "MacBook"),
               tab("notes", machine: "MacBook", workspace: "Notes", tier: 2, id: "tab|local|21"),
               CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "Infra", subtitle: "devbox", id: "ws|bb|3"), tier: 2, path: "devbox"),
               tab("api-gateway", machine: "devbox", workspace: "Infra", tier: 2, id: "tab|bb|31"),
               CommandBarEntry(item: QuickOpenItem(kind: .machine, title: "MacBook", subtitle: "Connected", id: "machine|local"), tier: 2, path: "Connected"),
               CommandBarEntry(item: QuickOpenItem(kind: .machine, title: "devbox", subtitle: "Connected", id: "machine|bb"), tier: 2, path: "Connected")]
    }

    private var outline: CommandTree.Outline {
        CommandTree.Outline(machines: [.init(key: "local", workspaces: [.init(id: 1, tabs: [11, 12, 13]), .init(id: 2, tabs: [21])]),
                                       .init(key: "bb", workspaces: [.init(id: 3, tabs: [31])])],
                            needsYou: [(machine: "bb", pane: 7)])
    }

    private var closed: [String] = []
    private var newTabs: [String] = []

    /// Opens the bar as ⌘P does with "web" (12) current in Platform.
    private func open(tab current: TabID = 12, all entries: [CommandBarEntry]? = nil, outline: CommandTree.Outline? = nil) {
        bar = QuickOpenOverlay(all: entries ?? all, tree: CommandTree(outline: outline ?? self.outline, machine: "local", workspace: 1, tab: current))
        bar.frame = window.contentView!.bounds
        window.contentView!.addSubview(bar)
        bar.onOpen = { [weak self] in self?.opened.append($0.item.id) }
        bar.onPreview = { [weak self] in self?.previewed.append($0.item.id) }
        bar.onRestore = { [weak self] in self?.restored += 1 }
        bar.onDismiss = { [weak self] in self?.dismissed += 1 }
        bar.onClose = { [weak self] in self?.closed.append($0.item.id) }
        bar.onNewTab = { [weak self] in self?.newTabs.append($0.item.id) }
        bar.focusField()
    }

    private var titles: [String] { bar.rows.map(\.entry.item.title) }
    private var selectedTitle: String? { bar.selectedEntry?.item.title }

    @discardableResult
    private func command(_ selector: Selector) -> Bool {
        let field = bar.fieldForTesting
        let editor = field.currentEditor() as? NSTextView ?? NSTextView()
        return bar.control(field, textView: editor, doCommandBy: selector)
    }

    private func key(_ characters: String, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func testEmptyViewIsThisMachineWithTheCurrentWorkspaceOpen() {
        open()
        XCTAssertEqual(titles, ["Claude Code: deploy api", "Platform", "api", "web", "docs", "Notes"],
                       "Needs you on top, then this machine only: Platform open to its tabs, Notes collapsed")
        XCTAssertEqual(selectedTitle, "web", "the current tab is selected")
        XCTAssertEqual(bar.rows.map { $0.row?.depth ?? -1 }, [0, 0, 1, 1, 1, 0])
        XCTAssertEqual(bar.rows.first?.row?.section, .needsYou)
        XCTAssertFalse(titles.contains("api-gateway"), "other machines stay out of the empty view")
    }

    func testArrowsPreviewTabsOnly() {
        open()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(selectedTitle, "Notes")
        XCTAssertEqual(previewed, ["tab|local|13"], "docs previews; the Notes workspace row only highlights")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened, ["ws|local|2"], "Return on a workspace opens it (at its last tab)")
    }

    func testRightExpandsLeftCollapsesAndGoesUpToTheMachines() {
        open()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))  // Notes
        XCTAssertTrue(command(#selector(NSResponder.moveRight(_:))))
        XCTAssertEqual(titles.suffix(2), ["Notes", "notes"], "→ shows its tabs")
        command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(titles.last, "Notes", "← collapses")
        command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(titles, ["Claude Code: deploy api", "MacBook", "devbox"], "← again: the machine list")
        XCTAssertEqual(selectedTitle, "MacBook")
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(titles, ["Claude Code: deploy api", "MacBook", "devbox", "Infra"], "Return on a machine expands it")
        XCTAssertTrue(opened.isEmpty)
        // Tab and ⇧Tab act as → and ← with nothing typed.
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(titles.last, "api-gateway")
        command(#selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(titles.last, "Infra")
    }

    func testReturnOpensTabsAndAgents() {
        open()
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened, ["tab|local|12"])
        open()
        for _ in 0..<3 { command(#selector(NSResponder.moveUp(_:))) }
        XCTAssertEqual(selectedTitle, "Claude Code: deploy api")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened.last, "agent|bb|7", "Needs you jumps to the agent's pane")
    }

    func testEscRestoresAndCloses() {
        open()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(restored, 1, "back to the tab that was current")
        XCTAssertEqual(dismissed, 1)
        XCTAssertNil(bar.superview)
        XCTAssertTrue(opened.isEmpty)
    }

    func testEscWithoutMovingRestoresNothing() {
        open()
        command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(dismissed, 1)
    }

    func testTypingSearchesFlatAndClearingReturnsToTheTree() {
        open()
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveRight(_:)))  // Notes open
        bar.setQuery("api")
        XCTAssertTrue(titles.contains("api-gateway"), "every machine")
        XCTAssertTrue(bar.rows.allSatisfy { $0.row == nil }, "flat")
        XCTAssertEqual(bar.rows.first { $0.entry.item.title == "api-gateway" }?.entry.path, "devbox › Infra")
        XCTAssertFalse(command(#selector(NSResponder.moveLeft(_:))), "← and → edit the text")
        XCTAssertFalse(command(#selector(NSResponder.moveRight(_:))))
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(previewed, ["tab|local|13"], "no previews while searching")
        bar.setQuery("")
        XCTAssertEqual(selectedTitle, "Notes", "back where you were")
        XCTAssertEqual(titles.suffix(2), ["Notes", "notes"])
    }

    func testTabLeavesSearchAtTheRowAndShiftTabAtItsParent() {
        open()
        bar.setQuery("gateway")
        XCTAssertEqual(selectedTitle, "api-gateway")
        command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(bar.query, "")
        XCTAssertEqual(selectedTitle, "api-gateway", "the tree, at that tab")
        XCTAssertTrue(titles.contains("Infra"))
        open()
        bar.setQuery("gateway")
        command(#selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(selectedTitle, "Infra", "⇧Tab: its workspace")
    }

    func testRowKeys() {
        open()
        XCTAssertTrue(bar.performKeyEquivalent(with: key("\u{7f}", keyCode: 51)))
        XCTAssertEqual(closed, ["tab|local|12"], "⌘⌫ closes the selected tab (the app asks first)")
        command(#selector(NSResponder.moveUp(_:)))
        command(#selector(NSResponder.moveUp(_:)))
        bar.performKeyEquivalent(with: key("\u{7f}", keyCode: 51))
        XCTAssertEqual(closed.last, "ws|local|1", "or workspace")
        command(#selector(NSResponder.moveUp(_:)))
        bar.performKeyEquivalent(with: key("\u{7f}", keyCode: 51))
        XCTAssertEqual(closed.count, 2, "an agent row has nothing to close")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        XCTAssertEqual(newTabs, ["ws|local|1"], "⌥↩ opens a new tab there")
        bar.setQuery("gate")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(newTabs.last, "tab|bb|31", "on a search result too")
    }

    private var ran: [(String, String?, String?)] = []
    private var beside: [String] = []

    /// The bar with ">" commands wired as the app does: a context from the selected row.
    private func openWithCommands() {
        open()
        bar.commandContext = { node in
            switch node {
            case let .tab(_, id)?:
                return CommandContext(machine: "local", machineName: "MacBook", workspace: 1, workspaceName: "Platform", tab: id,
                                      tabName: id == 12 ? "web" : "\(id)", canOpenBeside: id != 12)
            case let .workspace(_, id)?:
                return CommandContext(machine: "local", machineName: "MacBook", workspace: id, workspaceName: id == 1 ? "Platform" : "Notes")
            default:
                return CommandContext(machine: "local", machineName: "MacBook")
            }
        }
        bar.onCommand = { [weak self] item, subject, target in self?.ran.append((item.id.rawValue, subject?.entryID, target?.entryID)) }
        bar.onOpenBeside = { [weak self] in self?.beside.append($0.item.id) }
    }

    func testGreaterThanListsCommandsForTheSelectedRow() {
        openWithCommands()
        bar.setQuery(">")
        XCTAssertTrue(bar.isCommandMode)
        XCTAssertEqual(titles.first, "New Tab in Platform")
        XCTAssertTrue(titles.contains("Rename Tab “web”"), "for the selected tab")
        XCTAssertTrue(titles.contains("Close Tab “web”"))
        XCTAssertFalse(titles.contains { $0.hasPrefix("Close Workspace") })
        bar.setQuery(">split d")
        XCTAssertEqual(titles.first, "Split Down")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(ran.first?.0, "splitDown")
        XCTAssertEqual(ran.first?.1, "tab|local|12", "on the selected row")
        XCTAssertTrue(previewed.isEmpty)
    }

    func testMoveTabPicksTheWorkspaceInTheTree() {
        openWithCommands()
        bar.setQuery(">move")
        XCTAssertEqual(titles.first, "Move Tab “web” to…")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertNotNil(bar.picking, "now pick where to")
        XCTAssertEqual(bar.query, "")
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(titles, ["Claude Code: deploy api", "Platform", "Notes"], "workspaces only, no tab rows")
        XCTAssertEqual(selectedTitle, "Notes", "starting on the first workspace other than the tab's own")
        XCTAssertTrue(bar.isDimmedForPick(.workspace(machine: "local", 1)), "its own workspace is dimmed")
        XCTAssertTrue(bar.isDimmedForPick(.workspace(machine: "bb", 3)), "and other machines'")
        XCTAssertFalse(bar.isDimmedForPick(.machine("local")))
        XCTAssertFalse(command(#selector(NSResponder.moveRight(_:))) && titles.count > 3, "workspaces don't open into tabs")
        command(#selector(NSResponder.moveUp(_:)))  // Platform, the current one
        XCTAssertTrue(previewed.isEmpty, "no previews while picking")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(ran.isEmpty, "Return on the current workspace does nothing")
        XCTAssertNotNil(bar.picking)
        command(#selector(NSResponder.moveDown(_:)))  // Notes
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(ran.first?.0, "moveTab")
        XCTAssertEqual(ran.first?.1, "tab|local|12")
        XCTAssertEqual(ran.first?.2, "ws|local|2")
        // Esc while picking cancels the pick, not the bar.
        openWithCommands()
        bar.setQuery(">move")
        command(#selector(NSResponder.insertNewline(_:)))
        command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(bar.picking)
        XCTAssertNotNil(bar.superview, "still open")
        XCTAssertTrue(titles.contains("web"), "the tree has its tabs again")
    }

    func testCommandReturnOpensATabBeside() {
        openWithCommands()
        command(#selector(NSResponder.moveUp(_:)))  // api
        XCTAssertTrue(bar.performKeyEquivalent(with: key("\r", keyCode: 36)))
        XCTAssertEqual(beside, ["tab|local|11"])
        command(#selector(NSResponder.moveUp(_:)))  // Platform
        bar.performKeyEquivalent(with: key("\r", keyCode: 36))
        XCTAssertEqual(beside.count, 1, "only tabs open beside")
        bar.setQuery(">beside")
        XCTAssertTrue(titles.isEmpty || !titles.contains { $0.contains("Beside") }, "the workspace row has no Open Beside")
    }

    func testOnlyTheRowsInViewAreDrawn() {
        var entries = all
        var workspaces: [CommandTree.Outline.Workspace] = []
        for w in 0..<300 {
            entries.append(CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "W\(w)", id: "ws|local|\(1000 + w)"), tier: 2))
            workspaces.append(.init(id: WorkspaceID(1000 + w), tabs: []))
        }
        let big = CommandTree.Outline(machines: [.init(key: "local", workspaces: workspaces)], needsYou: [])
        bar = QuickOpenOverlay(all: entries, tree: CommandTree(outline: big, machine: "local", workspace: nil, tab: nil))
        window.contentView!.addSubview(bar)
        bar.focusField()
        XCTAssertEqual(bar.rows.count, 300)
        let start = Date()
        for _ in 0..<40 { command(#selector(NSResponder.moveDown(_:))) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "40 moves through 300 workspaces")
        XCTAssertEqual(selectedTitle, "W40")
        XCTAssertGreaterThan(bar.windowStart, 0, "the view follows the selection")
        XCTAssertLessThanOrEqual(40 - bar.windowStart, QuickOpenOverlay.visibleRows - 1)
    }

    func testNeedsYouIsWaitingOrErrorNotMuted() {
        XCTAssertTrue(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .waiting, attention: true)))
        XCTAssertTrue(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .error, attention: true)))
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .done, attention: true)), "finished isn't waiting")
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .running, attention: true)))
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .waiting, attention: true, muted: true)), "muted")
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .waiting, attention: false)), "already seen")
        // clothod 0.1.31's needs_user: a finished turn that asks something is listed, one that only finished isn't.
        XCTAssertTrue(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .done, attention: true, needsUser: true)))
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .done, attention: true, needsUser: false)))
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .done, attention: false, needsUser: true)), "already seen")
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .done, attention: true, needsUser: true, settling: true)), "settling")
        XCTAssertFalse(AppDelegate.needsYou(AgentInfo(kind: "claude", state: .done, attention: false, settling: true)), "settling")
    }

    func testAgentDetailAndTheMostUrgent() {
        let asks = AgentInfo(kind: "claude", state: .done, attention: true, prompt: "fix the login bug", summary: "Should I push it?", needsUser: true)
        let plain = AgentInfo(kind: "claude", state: .done, attention: true, summary: "Tests pass", needsUser: false)
        XCTAssertEqual(AppDelegate.agentDetail(asks), "needs you: Should I push it?")
        XCTAssertEqual(AppDelegate.agentDetail(plain), "done: Tests pass")
        let running = AgentInfo(kind: "claude", state: .running)
        XCTAssertEqual(AppDelegate.mostUrgent([running, plain, asks]), asks)
        XCTAssertEqual(AppDelegate.mostUrgent([plain, asks, AgentInfo(kind: "claude", state: .error, attention: true)])?.state, .error)
        XCTAssertEqual(AppDelegate.mostUrgent([running, AgentInfo(kind: "codex", state: .waiting, attention: false)]), running, "else the first")
    }

    func testNodeIDsRoundTrip() {
        for node: CommandTree.Node in [.agent(machine: "bb", pane: 7), .machine("local"), .workspace(machine: "x-y", 3), .tab(machine: "bb", 31)] {
            XCTAssertEqual(CommandTree.Node(entryID: node.entryID), node)
        }
        XCTAssertNil(CommandTree.Node(entryID: "tab|bb|api"))
    }

    func testAQueryFiltersAcrossMachines() {
        open()
        bar.setQuery("api")
        XCTAssertTrue(titles.contains("api"))
        XCTAssertTrue(titles.contains("api-gateway"), "devbox's tab too")
        XCTAssertFalse(titles.contains("web"))
        XCTAssertFalse(titles.contains("notes"))
        XCTAssertEqual(bar.selected, 0, "a search starts at the top")
        let api = bar.results.first { $0.entry.item.title == "api" }!
        XCTAssertEqual(api.indices, [0, 1, 2], "the matched letters, for highlighting")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(previewed.isEmpty, "no preview while searching")
    }

    /// Typing ranks by how well the name matches; among matches as good, workspaces lead, then waiting
    /// agents, then the current workspace, then the rest.
    func testRankingFollowsMatchQuality() {
        open()
        bar.setQuery("api")
        XCTAssertEqual(titles, ["api", "api-gateway", "Claude Code: deploy api"],
                       "names that start with it, then the agent whose name only contains it as a word")
        XCTAssertEqual(bar.results.map(\.entry.tier), [1, 2, 0])
        let ranked = CommandBar.results(all: all, current: current, query: "plat")
        XCTAssertEqual(ranked.first?.entry.item.title, "Platform", "the workspace by name before its tabs (by subtitle)")
        XCTAssertEqual(Array(ranked.dropFirst().map(\.entry.item.title).prefix(3)), ["api", "web", "docs"])
    }

    private func workspace(_ name: String, machine: String = "devbox") -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: name, subtitle: machine, id: "ws|\(machine)|\(name)"), tier: 2)
    }

    /// The user's case: a workspace "api" beats a tab "api-tests", even one in the current workspace.
    func testAWorkspaceBeatsATabThatMatchesAsWell() {
        let entries = all + [tab("api-tests", machine: "MacBook", workspace: "Platform", tier: 1), workspace("api")]
        let ranked = CommandBar.results(all: entries, current: current, query: "api")
        XCTAssertEqual(ranked.first?.entry.item.id, "ws|devbox|api")
        // A longer workspace name that starts with it still leads an exact tab name.
        let longer = all + [workspace("api-platform-services")]
        XCTAssertEqual(CommandBar.results(all: longer, current: current, query: "api").first?.entry.item.title, "api-platform-services")
        // Case doesn't matter.
        XCTAssertEqual(CommandBar.results(all: entries, current: current, query: "API").first?.entry.item.id, "ws|devbox|api")
    }

    /// A workspace whose name starts with the query beats a tab that only matches fuzzily, even when
    /// FuzzyMatch scores the tab higher (word starts in a short name against a long one).
    func testPrefixBeatsFuzzy() {
        let fuzzyTab = tab("a.p.i", machine: "imac", workspace: "Scratch", tier: 1)
        let longName = workspace("apiary-of-very-long-names-for-bees-and-more")
        XCTAssertGreaterThan(FuzzyMatch.match("api", in: "a.p.i")!.score,
                             FuzzyMatch.match("api", in: longName.item.title)!.score, "the raw scores favour the tab")
        let ranked = CommandBar.results(all: [fuzzyTab, longName], current: [], query: "api")
        XCTAssertEqual(ranked.map(\.entry.item.title), [longName.item.title, "a.p.i"])
        // But a tab that starts with it beats a workspace that only matches fuzzily: quality comes first.
        let fuzzyWorkspace = workspace("a-p-i")
        let prefixTab = tab("api-tests", machine: "imac", workspace: "Scratch", tier: 2)
        XCTAssertEqual(CommandBar.results(all: [fuzzyWorkspace, prefixTab], current: [], query: "api").map(\.entry.item.title),
                       ["api-tests", "a-p-i"])
    }

    func testMatchBands() {
        XCTAssertEqual(CommandBar.band(title: "api", query: "api", inTitle: true), 0)
        XCTAssertEqual(CommandBar.band(title: "API-tests", query: "api", inTitle: true), 0)
        XCTAssertEqual(CommandBar.band(title: "deploy api", query: "api", inTitle: true), 1)
        XCTAssertEqual(CommandBar.band(title: "deployApi", query: "api", inTitle: true), 1, "a camelCase word")
        XCTAssertEqual(CommandBar.band(title: "rapid", query: "api", inTitle: true), 2, "inside a word")
        XCTAssertEqual(CommandBar.band(title: "a-p-i", query: "api", inTitle: true), 2)
        XCTAssertEqual(CommandBar.band(title: "zsh", query: "bb", inTitle: false), 3, "through the subtitle")
        XCTAssertEqual(CommandBar.band(title: "ap", query: "api", inTitle: false), 3, "shorter than the query")
    }

    /// Among matches as good that aren't workspaces, a waiting agent still comes first.
    func testWaitingAgentsLeadTheirBand() {
        let entries = [tab("deploy api", machine: "MacBook", workspace: "Platform", tier: 1), all[0]]
        XCTAssertEqual(CommandBar.results(all: entries, current: [], query: "api").map(\.entry.item.id),
                       ["agent|bb|7", "tab|MacBook|deploy api"])
    }

    func testCommandNumbersPickARow() {
        open()
        XCTAssertTrue(bar.performKeyEquivalent(with: key("5")))
        XCTAssertEqual(opened, ["tab|local|13"], "⌘5: the fifth row, docs")
        bar.setQuery("zzz")
        XCTAssertTrue(bar.results.isEmpty)
        XCTAssertTrue(bar.performKeyEquivalent(with: key("1")), "taken, even with nothing to pick")
        XCTAssertEqual(opened.count, 1)
    }

    func testCommandPCloses() {
        open()
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(bar.performKeyEquivalent(with: key("p")))
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(restored, 1, "⌘P closes as Esc does")
    }

    /// A few hundred tabs across machines still rank in a few milliseconds per keystroke.
    func testSearchIsFastWithManyTabs() {
        var many: [CommandBarEntry] = []
        for machine in ["MacBook", "devbox", "imac"] {
            for w in 0..<20 {
                for t in 0..<10 {
                    many.append(tab("service-\(w)-tab-\(t) zsh", machine: machine, workspace: "Workspace \(w)", tier: 2))
                }
            }
        }
        let start = Date()
        for query in ["s", "se", "ser", "serv", "svc", "tab 9", "w12"] {
            _ = CommandBar.results(all: many, current: [], query: query)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start) / 7, 0.05, "under 50 ms a keystroke for 600 tabs")
    }

    // MARK: State words, marks and branches, ⌥↩ Allow

    private func agent(_ title: String, pane: Int, mark: AgentMark?, since: Double? = nil, request: PermissionRequest? = nil,
                       branch: String? = nil, detail: String? = nil, machine: String = "bb") -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .agent, title: "Claude Code: \(title)", subtitle: "devbox · Infra › \(title)", id: "agent|\(machine)|\(pane)"),
                        tier: mark == .working || mark == nil ? 2 : 0, mark: mark, detail: request?.askText ?? detail,
                        path: "devbox › Infra › \(title)", branch: branch, since: since, request: request)
    }

    private let cargoTest = PermissionRequest(id: "r7", tool: "Bash", summary: "cargo test -p clothod")

    /// The fixture's rows plus agents in every state: three that need the user (a wait on a request, a
    /// failure and a finished turn that asks), two finished, two working, and one with no mark.
    private var withAgents: [CommandBarEntry] {
        Array(all.dropFirst()) + [
            agent("deploy api", pane: 7, mark: .needsYou, since: 300, request: cargoTest, branch: "release/2026-11-with-a-very-long-branch-name-indeed"),
            agent("migrate db", pane: 8, mark: .error, since: 100, branch: "main", detail: "error: migration failed"),
            agent("api review", pane: 9, mark: .needsYou, since: 200, detail: "needs you: Should I push?"),
            agent("lint", pane: 10, mark: .done, since: 150, detail: "done: Lint is clean"),
            agent("api docs", pane: 11, mark: .done, since: 250, detail: "done: Docs written"),
            agent("refactor", pane: 12, mark: .working, since: 50, detail: "running: split the module"),
            agent("bench", pane: 13, mark: .working, since: 60, detail: "running"),
            agent("idle one", pane: 14, mark: nil, detail: "idle"),
            tab("done", machine: "MacBook", workspace: "Notes", tier: 2, id: "tab|local|22"),
            tab("needs-review", machine: "MacBook", workspace: "Notes", tier: 2, id: "tab|local|23"),
        ]
    }

    private var agentsOutline: CommandTree.Outline {
        CommandTree.Outline(machines: [.init(key: "local", workspaces: [.init(id: 1, tabs: [11, 12, 13]), .init(id: 2, tabs: [21, 22, 23])]),
                                       .init(key: "bb", workspaces: [.init(id: 3, tabs: [31])])],
                            needsYou: [(machine: "bb", pane: 7), (machine: "bb", pane: 8), (machine: "bb", pane: 9)])
    }

    func testStateFilterParsing() {
        func check(_ query: String, _ marks: Set<AgentMark>, _ rest: String, line: UInt = #line) {
            let filter = CommandBar.stateFilter(query)
            XCTAssertEqual(filter.marks, marks, query, line: line)
            XCTAssertEqual(filter.rest, rest, query, line: line)
        }
        check("needs", [.needsYou, .error], "")
        check("Needs you api", [.needsYou, .error], "api")
        check("NEEDS YOU", [.needsYou, .error], "")
        check("working", [.working], "")
        check("done x", [.done], "x")
        check("api done", [.done], "api")
        check("api", [], "api")
        check("needsy", [], "needsy")
        check("undone", [], "undone")
        check("you", [], "you")
        check("needs api you", [.needsYou, .error], "api you")
    }

    func testNeedsListsTheAgentsThatNeedYouOldestFirst() {
        let found = CommandBar.search(all: withAgents, current: [], query: "needs")
        XCTAssertEqual(found.lead, 3)
        XCTAssertEqual(found.marks, [.needsYou, .error])
        XCTAssertEqual(found.rows.prefix(3).map(\.entry.item.id), ["agent|bb|8", "agent|bb|9", "agent|bb|7"],
                       "the failed one, the one that asks and the one that waits, the longest wait first")
        XCTAssertEqual(found.rows.dropFirst(3).map(\.entry.item.title), ["needs-review"], "then only names that start with it")
        XCTAssertEqual(CommandBar.results(all: withAgents, current: [], query: "Needs You").map(\.entry.item.id),
                       ["agent|bb|8", "agent|bb|9", "agent|bb|7"])
        // An agent with no time is last.
        let untimed = withAgents + [agent("no time", pane: 20, mark: .needsYou)]
        XCTAssertEqual(CommandBar.search(all: untimed, current: [], query: "needs").rows.prefix(4).last?.entry.item.id, "agent|bb|20")
    }

    func testAStateWordWithMoreNarrowsItsAgents() {
        let found = CommandBar.search(all: withAgents, current: [], query: "needs api")
        XCTAssertEqual(found.lead, 2)
        XCTAssertEqual(Set(found.rows.map(\.entry.item.id)), ["agent|bb|7", "agent|bb|9"], "deploy api and api review, no other agent or tab")
        XCTAssertFalse(found.rows[0].indices.isEmpty, "the matched letters of the rest")
    }

    func testDoneShowsDoneAgentsThenATabNamedDone() {
        let found = CommandBar.search(all: withAgents, current: [], query: "done")
        XCTAssertEqual(found.rows.map(\.entry.item.id), ["agent|bb|11", "agent|bb|10", "tab|local|22"],
                       "finished agents, the most recent first, then the tab really named done")
        XCTAssertEqual(found.lead, 2)
        let working = CommandBar.search(all: withAgents, current: [], query: "working")
        XCTAssertEqual(working.rows.map(\.entry.item.id), ["agent|bb|13", "agent|bb|12"])
    }

    func testAStateWordWithNoSuchAgentsStillMatchesNames() {
        let found = CommandBar.search(all: all + [tab("done", machine: "MacBook", workspace: "Notes", tier: 2, id: "tab|local|22")], current: [], query: "done")
        XCTAssertEqual(found.lead, 0)
        XCTAssertEqual(found.rows.map(\.entry.item.id), ["tab|local|22"])
        XCTAssertTrue(CommandBar.search(all: all, current: [], query: "working").rows.isEmpty)
        // Without a state word nothing changes: every match, in today's order.
        XCTAssertEqual(CommandBar.search(all: all, current: [], query: "api").rows.map(\.entry.item.title),
                       ["api", "api-gateway", "Claude Code: deploy api"])
        XCTAssertEqual(CommandBar.search(all: all, current: [], query: "api").lead, 0)
    }

    func testTheLimitHoldsWithAStateWord() {
        let many = (0..<30).map { agent("job \($0)", pane: 100 + $0, mark: .working, since: Double($0)) }
        let found = CommandBar.search(all: many + withAgents, current: [], query: "working")
        XCTAssertEqual(found.rows.count, CommandBar.limit)
        XCTAssertEqual(found.lead, CommandBar.limit)
    }

    func testAStateWordDrawsItsHeaders() {
        open(all: withAgents, outline: agentsOutline)
        XCTAssertEqual(bar.headings.first, "NEEDS YOU", "the tree's own header")
        bar.setQuery("needs")
        XCTAssertEqual(bar.headings, ["NEEDS YOU  3", "MATCHES"])
        XCTAssertEqual(bar.stateLead.count, 3)
        bar.setQuery("done")
        XCTAssertEqual(bar.headings, ["DONE  2", "MATCHES"])
        bar.setQuery("working")
        XCTAssertEqual(bar.headings, ["WORKING  2"], "no Matches header with nothing under it")
        bar.setQuery("api")
        XCTAssertTrue(bar.headings.isEmpty, "a plain search has none")
    }

    private func row(_ entry: CommandBarEntry, showPath: Bool = true, width: CGFloat = 600) -> QuickOpenRow {
        let row = QuickOpenRow(entry: entry, indices: [], selected: false, shortcut: 1, showPath: showPath) {}
        row.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        window.contentView!.addSubview(row)
        row.layoutSubtreeIfNeeded()
        return row
    }

    func testARowDrawsTheMarkTheSubtitleAndTheBranch() throws {
        let asking = withAgents.first { $0.item.id == "agent|bb|7" }!
        let shown = row(asking)
        XCTAssertEqual(shown.markView?.mark, .needsYou, "the mark every other surface draws")
        XCTAssertEqual(shown.subtitle?.stringValue, "Allow Bash: cargo test -p clothod · devbox › Infra › deploy api",
                       "the request first, so it is the last thing cut")
        XCTAssertEqual(row(withAgents.first { $0.item.id == "agent|bb|9" }!).subtitle?.stringValue,
                       "devbox › Infra › api review · needs you: Should I push?", "otherwise where it is, then what it says")
        let branch = try XCTUnwrap(shown.branchView)
        XCTAssertEqual(shown.branchLabel?.stringValue, asking.branch)
        XCTAssertEqual(shown.branchLabel?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertLessThanOrEqual(branch.frame.width, QuickOpenRow.branchWidthBesideRequest + 0.5, "a long branch is cut in the middle, shorter beside a request")
        XCTAssertGreaterThan(branch.frame.width, 60, "and still shows")
        var noRequest = asking
        noRequest.request = nil
        let wide = try XCTUnwrap(row(noRequest).branchView).frame.width
        XCTAssertLessThanOrEqual(wide, QuickOpenRow.branchMaxWidth + 0.5, "at most 160 pt")
        XCTAssertGreaterThan(wide, QuickOpenRow.branchWidthBesideRequest)
        XCTAssertTrue(shown.trailing.arrangedSubviews.first === branch, "in the trailing group, before the ⌘ number")
        XCTAssertEqual(shown.trailing.arrangedSubviews.count, 2)
        let frame = branch.convert(branch.bounds, to: shown)
        XCTAssertGreaterThan(frame.minX, shown.bounds.midX, "at the trailing side")
        XCTAssertEqual(shown.bounds.maxX - shown.trailing.convert(shown.trailing.bounds, to: shown).maxX, 10, accuracy: 1, "the group ends at the row's inset")
        XCTAssertEqual(shown.accessibilityLabel(), "Claude Code: deploy api, Needs you, devbox › Infra › deploy api, branch \(asking.branch!)")

        // A tree row shows no path: the detail alone. No mark: the kind's icon. No branch: only the number.
        let plain = row(tab("web", machine: "MacBook", workspace: "Platform", tier: 1, panes: 2, detail: "running"), showPath: false)
        XCTAssertNil(plain.markView)
        XCTAssertEqual(plain.subtitle?.stringValue, "running")
        XCTAssertNil(plain.branchView)
        XCTAssertEqual(plain.trailing.arrangedSubviews.count, 1)
        XCTAssertEqual(plain.accessibilityLabel(), "web, MacBook › Platform")
        XCTAssertNil(row(tab("zsh", machine: "MacBook", workspace: "Platform", tier: 1), showPath: false).subtitle)

        // Narrow: nothing leaves the row.
        let narrow = row(asking, width: 300)
        XCTAssertLessThanOrEqual(narrow.trailing.convert(narrow.trailing.bounds, to: narrow).maxX, narrow.bounds.maxX + 0.5)
        XCTAssertEqual(narrow.fittingSize.height, shown.fittingSize.height, accuracy: 0.5)
        // In the 620 pt card's row (608 pt) the whole request shows.
        let inCard = try XCTUnwrap(row(asking, width: 608).subtitle)
        let request = NSAttributedString(string: "Allow Bash: cargo test -p clothod", attributes: [.font: inCard.font!]).size().width
        XCTAssertGreaterThanOrEqual(inCard.frame.width, request, "the request isn't cut in the card")
    }

    /// A row in a repository shows how much changed there after its branch; a row with a permission
    /// request keeps the room for the request, and VoiceOver says the count either way.
    func testARowShowsTheChangeCountAfterTheBranch() throws {
        let both = PaneGit.Changes(uncommitted: .init(files: 2, added: 14, removed: 5), branch: .init(base: "main", commits: 4, files: 4, added: 114, removed: 27))
        var entry = tab("web", machine: "MacBook", workspace: "Platform", tier: 1)
        entry.branch = "fix-login"
        entry.changes = both
        let shown = row(entry)
        let count = try XCTUnwrap(shown.changesLabel)
        XCTAssertEqual(count.attributedStringValue.string, "+128 \u{2212}32")
        XCTAssertEqual(shown.trailing.arrangedSubviews.count, 3, "the branch, the count, the ⌘ number")
        XCTAssertTrue(shown.trailing.arrangedSubviews[0] === shown.branchView)
        XCTAssertTrue(shown.trailing.arrangedSubviews[1] === count, "after the branch")
        XCTAssertGreaterThanOrEqual(count.frame.width, count.intrinsicContentSize.width - 0.5, "whole")
        XCTAssertEqual(shown.accessibilityLabel(), "web, MacBook › Platform, branch fix-login, 128 lines added, 32 removed, in 6 files")
        // Narrow: the count stays whole inside the row.
        let narrow = row(entry, width: 300)
        XCTAssertLessThanOrEqual(narrow.trailing.convert(narrow.trailing.bounds, to: narrow).maxX, narrow.bounds.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(narrow.changesLabel).frame.width, count.intrinsicContentSize.width - 0.5)

        entry.changes = PaneGit.Changes(uncommitted: .init(files: 6))
        XCTAssertEqual(row(entry).changesLabel?.attributedStringValue.string, "6 files", "the lines weren't counted")
        entry.changes = PaneGit.Changes(uncommitted: .init(files: 0, added: 0, removed: 0))
        XCTAssertNil(row(entry).changesLabel, "nothing changed")
        entry.changes = nil
        XCTAssertNil(row(entry).changesLabel, "a machine that doesn't count")
        XCTAssertEqual(row(entry).trailing.arrangedSubviews.count, 2)

        var asking = withAgents.first { $0.item.id == "agent|bb|7" }!
        asking.changes = both
        let ask = row(asking, width: 608)
        XCTAssertNil(ask.changesLabel, "the request keeps the room")
        XCTAssertTrue(ask.accessibilityLabel()?.hasSuffix("128 lines added, 32 removed, in 6 files") == true)
        let request = NSAttributedString(string: "Allow Bash: cargo test -p clothod", attributes: [.font: ask.subtitle!.font!]).size().width
        XCTAssertGreaterThanOrEqual(ask.subtitle!.frame.width, request, "and shows whole")
    }

    /// New Tab in a Worktree… is the Mac's own command: listed right after New Tab where the row's pane is
    /// in a repository on a machine that makes worktrees, found by "worktree" and "branch", and Return
    /// turns the bar into its prompt.
    func testTheWorktreeCommandIsListedOnlyWhereItWorks() {
        openWithCommands()
        bar.setQuery(">")
        XCTAssertFalse(titles.contains("New Tab in a Worktree…"), "no repository, or no `worktree`: not offered")
        let subject = WorktreeSubject(machine: "local", machineName: "MacBook", workspace: 1, pane: 5, cwd: "/p/clotho",
                                      git: PaneGit(repo: "clotho", root: "/p/clotho", branch: "main", head: "a1b2c3d"))
        bar.worktreeSubject = { node in
            guard case .tab? = node else { return nil }
            return subject
        }
        bar.setQuery(">")
        XCTAssertEqual(Array(titles.prefix(2)), ["New Tab in Platform", "New Tab in a Worktree…"], "right after New Tab")
        XCTAssertEqual(bar.rows[1].entry.symbol, "arrow.triangle.branch")
        bar.setQuery(">worktree")
        XCTAssertEqual(titles, ["New Tab in a Worktree…"])
        bar.setQuery(">branch")
        XCTAssertEqual(titles, ["New Tab in a Worktree…"], "by a keyword")
        bar.setQuery(">new tab")
        XCTAssertEqual(Array(titles.prefix(2)), ["New Tab in Platform", "New Tab in a Worktree…"], "ranked with the shared ones")
        bar.setQuery(">worktree")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(bar.naming, subject, "the bar asks for the name")
        XCTAssertTrue(ran.isEmpty, "no shared command ran")
        XCTAssertFalse(bar.isCommandMode)
        // Esc goes back to the commands, as from picking a workspace.
        command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(bar.naming)
        XCTAssertTrue(bar.isCommandMode)
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(titles.contains("New Tab in a Worktree…"))
    }

    /// The second tap of a double ⌥↩ on the last request's row: the selection has moved on to a row with
    /// no request, where ⌥↩ would open a New Tab. It opens none for the settle delay after the allow.
    func testADoubleTapOnTheLastRequestOpensNoTab() {
        AskBar.settleDelay = 0.3
        open(all: withAgents, outline: agentsOutline)
        var allowed: [String] = []
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        bar.setQuery("needs")
        while bar.selectedEntry?.request?.id != "r7" { command(#selector(NSResponder.moveDown(_:))) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])
        XCTAssertNil(bar.selectedEntry?.request, "the selection moved on to a row with no request")
        XCTAssertTrue(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), "the second tap is swallowed")
        XCTAssertTrue(newTabs.isEmpty, "and opens no tab")
        XCTAssertEqual(allowed, ["r7"])
        XCTAssertEqual(dismissed, 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(newTabs.count, 1, "after the settle delay ⌥↩ on that row opens a tab again")
        // A row with no request and no allow before it: at once, as ever.
        open(all: withAgents, outline: agentsOutline)
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(newTabs.count, 2)
    }

    func testTheFooterShowsThreeHintsAndAllowOnAnAskRow() {
        open(all: withAgents, outline: agentsOutline)
        XCTAssertEqual(bar.footerText, "↩ Open   ⌘↩ Open beside   ⌥↩ New tab")
        XCTAssertTrue(bar.footerShowsEsc, "esc at the trailing edge")
        bar.setQuery("needs")
        XCTAssertNil(bar.selectedEntry?.request, "the failed agent leads")
        XCTAssertEqual(bar.footerText, "↩ Open   ⌘↩ Open beside   ⌥↩ New tab")
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7")
        XCTAssertEqual(bar.footerText, "↩ Open   ⌘↩ Open beside   ⌥↩ Allow")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(bar.footerText, "↩ Open   ⌘↩ Open beside   ⌥↩ New tab")
        bar.setQuery(">")
        XCTAssertEqual(bar.footerText, "↑↓ move    ↩ run    esc back", "command mode keeps its own line")
        XCTAssertFalse(bar.footerShowsEsc)
    }

    func testOptionReturnAllowsOnlyOnAnAskRow() {
        open(all: withAgents, outline: agentsOutline)
        var allowed: [String] = []
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        bar.setQuery("needs")
        XCTAssertTrue(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        XCTAssertEqual(newTabs, ["agent|bb|8"], "an agent with no request: a new tab, as before")
        XCTAssertTrue(allowed.isEmpty)
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])
        XCTAssertEqual(newTabs.count, 1)
        XCTAssertNotNil(bar.superview, "the bar stays open")
        XCTAssertEqual(dismissed, 0)
        XCTAssertEqual(bar.selected, 3, "on the next row")
        XCTAssertEqual(selectedTitle, "needs-review")
        // Not in command mode.
        bar.setQuery(">")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed.count, 1)
        XCTAssertEqual(newTabs.count, 1)
        // The same request again, before the model caught up: not sent twice.
        bar.setQuery("needs")
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])
        XCTAssertEqual(newTabs.count, 1)
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7", "and the selection stays")
        // In the tree (the bar opened again): the selection moves on without previewing the tab it lands on.
        open(all: withAgents, outline: agentsOutline)
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        bar.setQuery("")
        while bar.selectedEntry?.request == nil { command(#selector(NSResponder.moveUp(_:))) }
        let before = previewed.count
        let index = bar.selected
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7", "r7"])
        XCTAssertEqual(bar.selected, index + 1)
        XCTAssertEqual(previewed.count, before, "no preview")
        XCTAssertNotNil(bar.superview)
    }

    /// A held ⌥↩ repeats like fresh presses: it must not allow the next rows, nor open a tab once the
    /// selection reaches a row with no request.
    func testAHeldOptionReturnAllowsOnceAndOpensNoTab() {
        AskBar.settleDelay = 0.3
        let second = PermissionRequest(id: "r9", tool: "Bash", summary: "npm test")
        let entries = withAgents.map { $0.item.id == "agent|bb|9" ? agent("api review", pane: 9, mark: .needsYou, since: 200, request: second) : $0 }
        open(all: entries, outline: agentsOutline)
        var allowed: [String] = []
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        var held = false
        bar.isKeyRepeat = { held }
        bar.setQuery("needs")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r9", "two agents wait, one under the other")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r9"])
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7", "on the next request")
        held = true
        for _ in 0..<5 { XCTAssertTrue(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), "swallowed") }
        XCTAssertEqual(allowed, ["r9"], "the repeats allow nothing")
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7", "and move nothing")
        held = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r9", "r7"], "a fresh press allows the next, once it has shown selected for the settle delay")
        XCTAssertNil(bar.selectedEntry?.request, "now on a row with no request")
        held = true
        for _ in 0..<5 { command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))) }
        XCTAssertEqual(allowed.count, 2)
        XCTAssertTrue(newTabs.isEmpty, "no new tab from a held key")
        XCTAssertEqual(dismissed, 0)
        XCTAssertNotNil(bar.superview, "the bar stays open")
        // A held key on a row with no request from the start opens nothing either.
        open()
        bar.isKeyRepeat = { true }
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertTrue(newTabs.isEmpty)
    }

    /// Two agents wait, one under the other. ⌥↩ allows the first and the selection moves on to the second:
    /// the second tap of a double ⌥↩ doesn't allow that one ("npm test", then "rm -rf build" unread).
    func testASecondPressRightAfterAnAllowWaitsOnTheNextRow() {
        AskBar.settleDelay = 0.3
        let second = PermissionRequest(id: "r9", tool: "Bash", summary: "rm -rf build")
        let entries = withAgents.map { $0.item.id == "agent|bb|9" ? agent("api review", pane: 9, mark: .needsYou, since: 400, request: second) : $0 }
        var allowed: [String] = []
        // Searching ("needs": the failed agent, then r7, then r9), then in the tree's Needs you rows.
        for searching in [true, false] {
            open(all: entries, outline: CommandTree.Outline(machines: agentsOutline.machines, needsYou: [(machine: "bb", pane: 7), (machine: "bb", pane: 9)]))
            bar.onAllow = { allowed.append($0.request?.id ?? "none") }
            allowed = []
            if searching { bar.setQuery("needs") }
            while bar.selectedEntry?.request?.id != "r7" { command(#selector(NSResponder.moveUp(_:))) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(bar.allowHintDimmed)
            command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
            XCTAssertEqual(allowed, ["r7"])
            XCTAssertEqual(bar.selectedEntry?.request?.id, "r9", "the selection moved on to the next request")
            XCTAssertEqual(bar.footerText, QuickOpenOverlay.allowHints)
            XCTAssertTrue(bar.allowHintDimmed, "⌥↩ Allow is dimmed: the request only just came under the selection")
            XCTAssertTrue(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), "the second tap is swallowed")
            XCTAssertEqual(allowed, ["r7"], "and allows nothing, searching: \(searching)")
            XCTAssertEqual(bar.selectedEntry?.request?.id, "r9", "nor moves the selection")
            XCTAssertTrue(newTabs.isEmpty)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(bar.allowHintDimmed, "back after the settle delay")
            command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
            XCTAssertEqual(allowed, ["r7", "r9"], "a press after the settle delay allows it")
        }
    }

    /// Whatever brings a request under the selection, ⌥↩ waits the settle delay from then: typing,
    /// a state word, an arrow key, leaving the commands, a model change, the window coming forward.
    func testEveryWayARequestComesUnderTheSelectionWaits() {
        AskBar.settleDelay = 0.3
        var allowed: [String] = []
        /// The request now selected is refused at once and allowed after the delay.
        func check(_ how: String, _ id: String = "r7", line: UInt = #line) {
            XCTAssertEqual(bar.selectedEntry?.request?.id, id, how, line: line)
            XCTAssertTrue(bar.allowHintDimmed, how, line: line)
            let before = allowed
            command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
            XCTAssertEqual(allowed, before, "refused: \(how)", line: line)
            XCTAssertTrue(newTabs.isEmpty, how, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(bar.allowHintDimmed, how, line: line)
        }
        func reopen(_ outline: CommandTree.Outline? = nil) {
            open(all: withAgents, outline: outline ?? agentsOutline)
            bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        }
        // Typing: the only result. Then the same request after the commands (">") and back.
        reopen()
        bar.setQuery("deploy")
        check("typed")
        bar.setQuery(">")
        XCTAssertFalse(bar.allowHintDimmed)
        bar.setQuery("deploy")
        check("back from the commands")
        // The window comes forward with the bar open.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        check("the window became key")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        XCTAssertFalse(bar.allowHintDimmed, "another window's doesn't count")
        // A state word, then the user's own arrow keys: treated the same.
        bar.setQuery("needs")
        XCTAssertNil(bar.selectedEntry?.request)
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveDown(_:)))
        check("an arrow key")
        // The tree: an arrow key onto the Needs you row, and a model change that puts a request on the selected row.
        reopen()
        while bar.selectedEntry?.request == nil { command(#selector(NSResponder.moveUp(_:))) }
        check("an arrow key in the tree")
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.moveUp(_:)))
        check("away and back")
        let next = PermissionRequest(id: "r7b", tool: "Edit", summary: "src/main.rs")
        bar.apply(all: withAgents.map { $0.item.id == "agent|bb|7" ? agent("deploy api", pane: 7, mark: .needsYou, since: 300, request: next) : $0 },
                  outline: agentsOutline)
        check("the model put another request on the row", "r7b")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7b"], "after the wait one press allows it")
    }

    /// One agent with two requests on the last row: the selection stays on it, and its next request can't
    /// be allowed until it has shown for the ask bar's settle delay.
    func testARequestThatJustTookAnothersPlaceIsNotAllowedYet() {
        let settleDelay = AskBar.settleDelay
        AskBar.settleDelay = 0.3
        defer { AskBar.settleDelay = settleDelay }
        open(all: withAgents, outline: agentsOutline)
        var allowed: [String] = []
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        bar.setQuery("deploy")
        XCTAssertEqual(bar.results.count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7", "the only row keeps the selection")
        // The model catches up: the row carries the agent's next request.
        let next = PermissionRequest(id: "r7b", tool: "Edit", summary: "src/main.rs")
        let entries = withAgents.map { $0.item.id == "agent|bb|7" ? agent("deploy api", pane: 7, mark: .needsYou, since: 300, request: next) : $0 }
        bar.apply(all: entries, outline: agentsOutline)
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7b")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"], "unread: not allowed")
        XCTAssertTrue(newTabs.isEmpty)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7", "r7b"], "after the settle delay, one press allows it")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed.count, 2, "once")
    }

    /// The selected ask row leaves (answered on the phone or in the terminal) and the selection lands on
    /// another agent's request: a ⌥↩ on its way was for the one that left, so this one settles first.
    func testARequestTheSelectionLandedOnByItselfIsNotAllowedYet() {
        let settleDelay = AskBar.settleDelay
        AskBar.settleDelay = 0.3
        defer { AskBar.settleDelay = settleDelay }
        let second = PermissionRequest(id: "r9", tool: "Bash", summary: "npm test")
        let entries = withAgents.map { $0.item.id == "agent|bb|9" ? agent("api review", pane: 9, mark: .needsYou, since: 200, request: second) : $0 }
        open(all: entries, outline: agentsOutline)
        var allowed: [String] = []
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        bar.setQuery("needs")
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r9", "the user's own move")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed, "it has shown selected for the settle delay")
        // r9 is answered elsewhere: its agent works again and its row leaves the results.
        let after = withAgents.map { $0.item.id == "agent|bb|9" ? agent("api review", pane: 9, mark: .working, since: 400, detail: "running") : $0 }
        bar.apply(all: after, outline: agentsOutline)
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7", "the selection landed on the next request")
        XCTAssertEqual(bar.footerText, QuickOpenOverlay.allowHints)
        XCTAssertTrue(bar.allowHintDimmed, "⌥↩ Allow is dimmed while a press would be refused")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, [], "the press on its way doesn't allow a request the user wasn't looking at")
        XCTAssertTrue(newTabs.isEmpty)
        // The same rows again (any model change): the wait isn't cut short, nor started over.
        bar.apply(all: after, outline: agentsOutline)
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed, "back when the wait is over")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])

        // The same in the tree: the row now at the place of the one that left.
        func outline(_ panes: [PaneID]) -> CommandTree.Outline {
            CommandTree.Outline(machines: agentsOutline.machines, needsYou: panes.map { (machine: "bb", pane: $0) })
        }
        open(all: entries, outline: outline([7, 9, 8]))
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        allowed = []
        while bar.selectedEntry?.request?.id != "r7" { command(#selector(NSResponder.moveUp(_:))) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed)
        let answered = entries.map { $0.item.id == "agent|bb|7" ? agent("deploy api", pane: 7, mark: .working, since: 400, detail: "running") : $0 }
        bar.apply(all: answered, outline: outline([9, 8]))
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r9")
        XCTAssertTrue(bar.allowHintDimmed)
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, [])
        XCTAssertTrue(newTabs.isEmpty)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed)
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r9"])
    }

    /// The footer's "⌥↩ Allow" dims while a press would be refused (the request just took another's
    /// place, or was just allowed and the model hasn't caught up), like the ask bar's buttons going off.
    func testTheAllowHintDimsWhileAPressWouldBeRefused() {
        let settleDelay = AskBar.settleDelay, retryDelay = AskBar.retryDelay
        AskBar.settleDelay = 0.3
        AskBar.retryDelay = 0.3
        defer {
            AskBar.settleDelay = settleDelay
            AskBar.retryDelay = retryDelay
        }
        open(all: withAgents, outline: agentsOutline)
        var allowed: [String] = []
        bar.onAllow = { allowed.append($0.request?.id ?? "none") }
        bar.setQuery("deploy")
        XCTAssertEqual(bar.footerText, QuickOpenOverlay.allowHints)
        XCTAssertTrue(bar.allowHintDimmed, "the request only just came under the selection")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed, "a request that has shown selected for the settle delay")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])
        XCTAssertEqual(bar.selectedEntry?.request?.id, "r7")
        XCTAssertTrue(bar.allowHintDimmed, "sent: another press would do nothing")
        XCTAssertEqual(bar.footerText, QuickOpenOverlay.allowHints, "the words stay")
        // The decide failed (the request stays): the hint comes back by itself after the retry delay.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed)
        // The agent's next request takes its place: dimmed while it settles.
        let next = PermissionRequest(id: "r7b", tool: "Edit", summary: "src/main.rs")
        let entries = withAgents.map { $0.item.id == "agent|bb|7" ? agent("deploy api", pane: 7, mark: .needsYou, since: 300, request: next) : $0 }
        bar.apply(all: entries, outline: agentsOutline)
        XCTAssertTrue(bar.allowHintDimmed)
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        XCTAssertEqual(allowed, ["r7"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(bar.allowHintDimmed)
        // Never on a row with no request, nor in command mode.
        bar.setQuery("web")
        XCTAssertEqual(bar.footerText, QuickOpenOverlay.openHints)
        XCTAssertFalse(bar.allowHintDimmed)
        bar.setQuery(">")
        XCTAssertFalse(bar.allowHintDimmed)
    }

    func testTheCardFitsANarrowWindow() {
        open()
        bar.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        bar.setQuery("api")
        bar.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(bar.card.frame.width, 500 - 32 + 0.5, "never wider than the overlay less 32 pt")
        XCTAssertGreaterThanOrEqual(bar.card.frame.minX, 16 - 0.5)
        XCTAssertLessThanOrEqual(bar.card.frame.maxX, 500 - 16 + 0.5)
        bar.frame = NSRect(x: 0, y: 0, width: 1140, height: 600)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.card.frame.width, 620, accuracy: 0.5, "620 pt where there is room")
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The app's own model and wiring against a fake daemon with `agent.decide`: rows carry the mark, the
    /// branch and the request; ⌥↩ allows it and the bar stays open on the next row.
    func testTheAppsRowsCarryMarkBranchAndRequestAndOptionReturnAllows() async throws {
        let app = AppDelegate()
        let fake = FakeBackend(extraFeatures: ["agent.decide"])
        let connection = MachineConnection(machine: .local, backend: fake)
        let key = AppDelegate.localKey
        app.connections[key] = connection
        let store = connection.store
        try await store.start()
        defer { store.stop() }
        let first = try await fake.createWorkspace(name: "clothod", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        let second = try await fake.createWorkspace(name: "relay", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        try await waitFor("the panes") { store.state.pane(first.pane) != nil && store.state.pane(second.pane) != nil }
        fake.setGit(first.pane, PaneGit(repo: "clotho", root: "/p/clotho", branch: "fix-login", head: "a1b2c3d"))
        fake.setAgent(first.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", since: 100, attention: true,
                                            requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test -p clothod"),
                                                       PermissionRequest(id: "r1b", tool: "Edit", summary: "src/main.rs")]))
        fake.setAgent(second.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", since: 200, attention: true,
                                             requests: [PermissionRequest(id: "r2", tool: "Bash", summary: "npm test")]))
        try await waitFor("the agents and git") {
            store.state.pane(first.pane)?.agent?.pendingRequests.count == 2 && store.state.pane(second.pane)?.agent != nil
                && store.state.pane(first.pane)?.git != nil
        }

        var model = app.commandBarModel()
        let firstID = "agent|\(key)|\(first.pane)", secondID = "agent|\(key)|\(second.pane)"
        let asking = try XCTUnwrap(model.all.first { $0.item.id == firstID })
        XCTAssertEqual(asking.mark, .needsYou)
        XCTAssertEqual(asking.branch, "fix-login")
        XCTAssertEqual(asking.since, 100)
        XCTAssertEqual(asking.request?.id, "r1", "the oldest request")
        XCTAssertEqual(asking.detail, "Allow Bash: cargo test -p clothod", "the exact tool and command")
        let other = try XCTUnwrap(model.all.first { $0.item.id == secondID })
        XCTAssertNil(other.branch, "outside a repo")
        XCTAssertEqual(other.detail, "Allow Bash: npm test")
        let tabRow = try XCTUnwrap(model.all.first { $0.item.id == "tab|\(key)|\(first.tab)" })
        XCTAssertEqual(tabRow.mark, .needsYou)
        XCTAssertEqual(tabRow.branch, "fix-login")
        XCTAssertNil(tabRow.request, "only the agent's own row allows")
        let workspaceRow = try XCTUnwrap(model.all.first { $0.item.id == "ws|\(key)|\(first.workspace)" })
        XCTAssertEqual(workspaceRow.mark, .needsYou)
        XCTAssertEqual(workspaceRow.branch, "fix-login", "its active tab's")

        bar = QuickOpenOverlay(all: model.all, tree: CommandTree(outline: model.outline, machine: model.machine, workspace: model.workspace, tab: model.tab))
        bar.frame = window.contentView!.bounds
        window.contentView!.addSubview(bar)
        bar.onAllow = { app.commandBarAllow($0) }
        bar.onNewTab = { [weak self] in self?.newTabs.append($0.item.id) }
        bar.onDismiss = { [weak self] in self?.dismissed += 1 }
        bar.focusField()

        // Searching: the longest wait is on top; ⌥↩ allows its request and moves to the next row.
        bar.setQuery("needs")
        XCTAssertEqual(bar.results.prefix(2).map(\.entry.item.id), [firstID, secondID])
        XCTAssertEqual(bar.footerText, QuickOpenOverlay.allowHints)
        XCTAssertTrue(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        try await waitFor("the decision") { fake.decisions.count == 1 }
        XCTAssertEqual(fake.decisions.first?.pane, first.pane)
        XCTAssertEqual(fake.decisions.first?.request, "r1")
        XCTAssertEqual(fake.decisions.first?.decision, .allow)
        XCTAssertTrue(bar.superview === window.contentView, "still open")
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(newTabs.isEmpty)
        XCTAssertEqual(bar.selectedEntry?.item.id, secondID, "on the next row")

        // The model catches up: the first agent's next request shows, and the selection stays where it is.
        try await waitFor("the request leaving the model") { store.state.pane(first.pane)?.agent?.pendingRequests.map(\.id) == ["r1b"] }
        model = app.commandBarModel()
        bar.apply(all: model.all, outline: model.outline)
        XCTAssertEqual(bar.selectedEntry?.item.id, secondID, "kept by id")
        XCTAssertEqual(bar.results.first?.entry.detail, "Allow Edit: src/main.rs")
        command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        try await waitFor("the second decision") { fake.decisions.count == 2 }
        XCTAssertEqual(fake.decisions.last?.request, "r2")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.decisions.count, 2, "one allow a press")

        // A daemon without agent.decide: no request on the row, so ⌥↩ is New Tab there.
        let plain = AppDelegate()
        let old = FakeBackend()
        let oldConnection = MachineConnection(machine: .local, backend: old)
        plain.connections[key] = oldConnection
        try await oldConnection.store.start()
        defer { oldConnection.store.stop() }
        let pane = try await old.createWorkspace(name: "one", spawn: SpawnOptions(command: ["/bin/sleep", "30"])).pane
        old.setAgent(pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", attention: true,
                                     requests: [PermissionRequest(id: "r9", tool: "Bash", summary: "ls")]))
        try await waitFor("the agent") { oldConnection.store.state.pane(pane)?.agent != nil }
        let row = try XCTUnwrap(plain.commandBarModel().all.first { $0.item.id == "agent|\(key)|\(pane)" })
        XCTAssertNil(row.request)
        XCTAssertNotEqual(row.detail, "Allow Bash: ls")
    }

    /// Review images of the bar as the app draws it, with an agent in Needs you, light and dark. Runs
    /// only with CLOTHO_SNAPSHOT_DIR set (CLOTHO_SNAPSHOT_DIR=/tmp/orch-ui-shots swift test --filter …).
    func testSnapshotsForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved; Theme.followAppAppearance() }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            Theme.followAppAppearance()
            window.appearance = NSApp.appearance
            open(tab: 12)
            bar.layoutSubtreeIfNeeded()
            let card = bar.card
            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return XCTFail("no image") }
            card.cacheDisplay(in: card.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/u-cmdp-needs-you-\(name).png"))
            bar.removeFromSuperview()
            // Filtered by "needs", in a narrow and a wide window: the whole overlay, so the card's margins show.
            for width in [500, 1140] {
                window.setContentSize(NSSize(width: width, height: 600))
                open(all: withAgents, outline: agentsOutline)
                bar.setQuery("needs")
                command(#selector(NSResponder.moveDown(_:)))
                command(#selector(NSResponder.moveDown(_:)))
                bar.layoutSubtreeIfNeeded()
                guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return XCTFail("no image") }
                bar.cacheDisplay(in: bar.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/u-cmdp-needs-filter-\(name)-\(width).png"))
                bar.removeFromSuperview()
            }
            window.setContentSize(NSSize(width: 900, height: 600))
        }
    }
}
