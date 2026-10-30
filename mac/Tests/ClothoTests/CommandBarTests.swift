import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// ⌘P, the command bar: with nothing typed a tree (Needs you, then this machine's workspaces with the
/// current one open; → expands, ← collapses and climbs to the machine list; arrows preview tabs; Esc goes
/// back); typing searches every machine flat (best names first, workspaces leading); Tab/⇧Tab leave the
/// search; ⌘⌫ closes, ⌥↩ opens a new tab, ⌘1–9 pick a row, and ⌘P again closes the bar.
@MainActor
final class CommandBarTests: XCTestCase {
    private var window: NSWindow!
    private var bar: QuickOpenOverlay!
    private var opened: [String] = []
    private var previewed: [String] = []
    private var restored = 0
    private var dismissed = 0

    override func setUp() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    }

    override func tearDown() {
        window.close()
    }

    private func tab(_ title: String, machine: String, workspace: String, tier: Int, panes: Int = 1, dot: NSColor? = nil, detail: String? = nil,
                     id: String? = nil) -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .tab, title: title, subtitle: "\(machine) · \(workspace)", id: id ?? "tab|\(machine)|\(title)"),
                        tier: tier, dot: dot, detail: detail, panes: panes, path: "\(machine) › \(workspace)")
    }

    /// This Mac ("local", MacBook) with "Platform" (current: api 11, web 12, docs 13) and "Notes" (notes
    /// 21); devbox ("bb") with "Infra" (api-gateway 31) and an agent waiting on its pane 7.
    private var current: [CommandBarEntry] {
        [tab("api", machine: "MacBook", workspace: "Platform", tier: 1, id: "tab|local|11"),
         tab("web", machine: "MacBook", workspace: "Platform", tier: 1, panes: 2, id: "tab|local|12"),
         tab("docs", machine: "MacBook", workspace: "Platform", tier: 1, dot: .systemOrange, detail: "waiting: Allow Bash?", id: "tab|local|13")]
    }

    private var all: [CommandBarEntry] {
        [CommandBarEntry(item: QuickOpenItem(kind: .agent, title: "Claude Code: deploy api", subtitle: "devbox · Infra › deploy", id: "agent|bb|7"),
                         tier: 0, dot: .systemOrange, detail: "waiting: Allow Bash?", path: "devbox › Infra › deploy"),
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
    private func open(tab current: TabID = 12) {
        bar = QuickOpenOverlay(all: all, tree: CommandTree(outline: outline, machine: "local", workspace: 1, tab: current))
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
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(previewed.isEmpty, "no previews while picking")
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
        }
    }
}
