import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// ⌘P, the command bar: the current workspace's tabs with nothing typed (arrows preview each, Esc goes
/// back), a search across every machine's workspaces, tabs and agents (best names first, workspaces leading), Return or
/// ⌘1–9 to go, and ⌘P again to close.
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

    private func tab(_ title: String, machine: String, workspace: String, tier: Int, panes: Int = 1, dot: NSColor? = nil, detail: String? = nil) -> CommandBarEntry {
        CommandBarEntry(item: QuickOpenItem(kind: .tab, title: title, subtitle: "\(machine) · \(workspace)", id: "tab|\(machine)|\(title)"),
                        tier: tier, dot: dot, detail: detail, panes: panes)
    }

    /// This Mac's "Platform" (current: api, web, docs), its "Notes", and devbox's "Infra" (api-gateway), with
    /// a waiting agent on devbox.
    private var current: [CommandBarEntry] {
        [tab("api", machine: "MacBook", workspace: "Platform", tier: 1),
         tab("web", machine: "MacBook", workspace: "Platform", tier: 1, panes: 2),
         tab("docs", machine: "MacBook", workspace: "Platform", tier: 1, dot: .systemOrange, detail: "waiting: Allow Bash?")]
    }

    private var all: [CommandBarEntry] {
        [CommandBarEntry(item: QuickOpenItem(kind: .agent, title: "Claude Code: deploy api", subtitle: "devbox · Infra › deploy", id: "agent|devbox|7"),
                         tier: 0, dot: .systemOrange, detail: "waiting: Allow Bash?"),
         CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "Platform", subtitle: "MacBook", id: "ws|MacBook|1"), tier: 1)]
            + current
            + [CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "Notes", subtitle: "MacBook", id: "ws|MacBook|2"), tier: 2),
               tab("notes", machine: "MacBook", workspace: "Notes", tier: 2),
               CommandBarEntry(item: QuickOpenItem(kind: .workspace, title: "Infra", subtitle: "devbox", id: "ws|devbox|3"), tier: 2),
               tab("api-gateway", machine: "devbox", workspace: "Infra", tier: 2)]
    }

    private func open(selected: Int? = 1) {
        bar = QuickOpenOverlay(all: all, current: current, selected: selected)
        bar.frame = window.contentView!.bounds
        window.contentView!.addSubview(bar)
        bar.onOpen = { [weak self] in self?.opened.append($0.item.id) }
        bar.onPreview = { [weak self] in self?.previewed.append($0.item.id) }
        bar.onRestore = { [weak self] in self?.restored += 1 }
        bar.onDismiss = { [weak self] in self?.dismissed += 1 }
        bar.focusField()
    }

    private var titles: [String] { bar.results.map(\.entry.item.title) }

    private func command(_ selector: Selector) {
        let field = bar.fieldForTesting
        let editor = field.currentEditor() as? NSTextView ?? NSTextView()
        XCTAssertTrue(bar.control(field, textView: editor, doCommandBy: selector))
    }

    private func key(_ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    func testEmptyQueryListsTheCurrentWorkspacesTabs() {
        open(selected: 1)
        XCTAssertEqual(titles, ["api", "web", "docs"], "the current workspace's tabs, in order")
        XCTAssertEqual(bar.selected, 1, "the current tab is selected")
        XCTAssertEqual(bar.results[1].entry.panes, 2)
        XCTAssertEqual(bar.results[2].entry.detail, "waiting: Allow Bash?")
    }

    func testArrowsPreviewAndReturnSwitches() {
        open(selected: 0)
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertTab(_:)))  // Tab works as ↓
        XCTAssertEqual(previewed, ["tab|MacBook|web", "tab|MacBook|docs"], "each tab shows as it's selected")
        command(#selector(NSResponder.insertBacktab(_:)))  // ⇧Tab as ↑
        XCTAssertEqual(bar.selected, 1)
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened, ["tab|MacBook|web"])
        XCTAssertEqual(restored, 0)
    }

    func testEscRestoresAndCloses() {
        open(selected: 0)
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
        XCTAssertEqual(ranked.dropFirst().map(\.entry.item.title), ["api", "web", "docs"])
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
                       ["agent|devbox|7", "tab|MacBook|deploy api"])
    }

    func testCommandNumbersPickARow() {
        open()
        XCTAssertTrue(bar.performKeyEquivalent(with: key("3")))
        XCTAssertEqual(opened, ["tab|MacBook|docs"])
        bar.setQuery("zzz")
        XCTAssertTrue(bar.results.isEmpty)
        XCTAssertTrue(bar.performKeyEquivalent(with: key("1")), "taken, even with nothing to pick")
        XCTAssertEqual(opened.count, 1)
    }

    func testCommandPCloses() {
        open(selected: 0)
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
}
