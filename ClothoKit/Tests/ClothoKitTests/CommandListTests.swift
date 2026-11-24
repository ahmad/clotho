import XCTest
@testable import ClothoKit

/// ⌘P's ">" commands: which apply to the selected row, which need a target, and how typing finds them.
final class CommandListTests: XCTestCase {
    private func ids(_ items: [CommandListItem]) -> [CommandListItem.ID] { items.map(\.id) }

    func testATabRowOffersTabCommands() {
        let context = CommandContext(machine: "bb", machineName: "devbox", workspace: 3, workspaceName: "api", tab: 31, tabName: "zsh",
                                     isLocal: false, canOpenBeside: true)
        let items = CommandList.items(for: context)
        XCTAssertEqual(items.first?.title, "New Tab in api")
        for id: CommandListItem.ID in [.newTab, .newWorkspace, .splitRight, .splitDown, .claudeHere, .codexHere, .resumeClaude,
                                       .rename, .moveTab, .openBeside, .closeTab, .machineOff] {
            XCTAssertTrue(ids(items).contains(id), "\(id)")
        }
        XCTAssertFalse(ids(items).contains(.closeWorkspace), "a tab row closes the tab")
        XCTAssertFalse(ids(items).contains(.reconnect), "connected")
        XCTAssertEqual(items.first { $0.id == .moveTab }?.target, .workspace, "moving a tab picks where to")
        XCTAssertEqual(items.first { $0.id == .closeTab }?.title, "Close Tab “zsh”")
        XCTAssertNil(items.first { $0.id == .newTab }?.target)
    }

    func testAWorkspaceRowAndAMachineThatIsOff() {
        let workspace = CommandList.items(for: CommandContext(machine: "local", machineName: "MacBook", workspace: 1, workspaceName: "Platform"))
        XCTAssertTrue(ids(workspace).contains(.closeWorkspace))
        XCTAssertFalse(ids(workspace).contains(.closeTab))
        XCTAssertFalse(ids(workspace).contains(.splitRight), "splits need a tab")
        XCTAssertFalse(ids(workspace).contains(.openBeside))
        XCTAssertFalse(ids(workspace).contains(.machineOff), "this Mac can't be switched off")

        let off = CommandList.items(for: CommandContext(machine: "imac", machineName: "imac", connected: false, enabled: false, isLocal: false))
        XCTAssertTrue(ids(off).contains(.machineOn))
        XCTAssertFalse(ids(off).contains(.newTab), "nothing runs on a machine that's off")
        XCTAssertFalse(ids(off).contains(.reconnect))
        let unreachable = CommandList.items(for: CommandContext(machine: "imac", machineName: "imac", connected: false, isLocal: false, unreachable: true))
        XCTAssertTrue(ids(unreachable).contains(.reconnect))
    }

    func testAnAppLeavesOutWhatItDoesntHave() {
        let phone = Set(CommandListItem.ID.allCases).subtracting([.toggleSidebar, .files])
        let items = CommandList.items(for: CommandContext(machine: "local", workspace: 1, workspaceName: "w"), supported: phone)
        XCTAssertFalse(ids(items).contains(.toggleSidebar))
        XCTAssertFalse(ids(items).contains(.files))
        XCTAssertTrue(ids(items).contains(.settings))
    }

    func testTypingFindsByTitleAndKeywords() {
        let items = CommandList.items(for: CommandContext(machine: "local", machineName: "MacBook", workspace: 1, workspaceName: "api", tab: 1, tabName: "zsh"))
        XCTAssertEqual(CommandList.matching(items, query: "split d").first?.id, .splitDown)
        XCTAssertEqual(CommandList.matching(items, query: "dark").first?.id, .appearanceDark)
        XCTAssertTrue(CommandList.matching(items, query: "terminal").contains { $0.id == .newTab }, "by a keyword")
        XCTAssertEqual(CommandList.matching(items, query: "").count, items.count)
        XCTAssertEqual(CommandList.commandQuery(">split"), "split")
        XCTAssertEqual(CommandList.commandQuery("  > new"), " new")
        XCTAssertNil(CommandList.commandQuery("api"))
    }

    /// Words, not scattered letters: ">rename" finds Rename only, not "New Workspace on Local Mac (dev)",
    /// whose letters r-e-n-a-m-e appear in order across it.
    func testMatchesWordPrefixesNotScatteredLetters() {
        let items = CommandList.items(for: CommandContext(machine: "local", machineName: "Local Mac (dev)", workspace: 1, workspaceName: "api",
                                                          tab: 1, tabName: "zsh"))
        XCTAssertEqual(CommandList.matching(items, query: "rename").map(\.id), [.rename])
        XCTAssertEqual(CommandList.matching(items, query: "ren").map(\.id), [.rename])
        XCTAssertEqual(CommandList.matching(items, query: "cla").map(\.id), [.claudeHere, .resumeClaude], "Claude in the title; Close doesn't start with cla")
        XCTAssertEqual(CommandList.matching(items, query: "new tab").first?.id, .newTab)
        XCTAssertFalse(CommandList.matching(items, query: "new tab").contains { $0.id == .newWorkspace }, "every word has to match")
        XCTAssertEqual(CommandList.matching(items, query: "ZSH").first?.id, .rename, "case aside, inside quotes")
        // Title words lead keyword-only matches; the list order breaks ties.
        let ai = CommandList.matching(items, query: "agent").map(\.id)
        XCTAssertEqual(ai, [.claudeHere, .codexHere, .resumeClaude], "all through keywords, in list order")
        let theme = CommandList.matching(items, query: "appearance").map(\.id)
        XCTAssertEqual(theme, [.appearanceSystem, .appearanceLight, .appearanceDark])
        XCTAssertTrue(CommandList.matching(items, query: "xyz").isEmpty)
    }

    /// The generic match (any rows with a title and keywords) ranks exactly as the commands' own, so an
    /// app's local command sorts among the shared ones.
    func testTheGenericMatchRanksTheSame() {
        struct Row: Equatable {
            var title: String
            var keywords: [String]
        }
        let items = CommandList.items(for: CommandContext(machine: "local", machineName: "Local Mac (dev)", workspace: 1, workspaceName: "api",
                                                          tab: 1, tabName: "zsh"))
        let rows = items.map { Row(title: $0.title, keywords: $0.keywords) }
        for query in ["", "  ", "rename", "ren", "cla", "new tab", "ZSH", "agent", "appearance", "split d", "terminal", "xyz", "é", "mode dark"] {
            let expected = CommandList.matching(items, query: query).map(\.title)
            let got = CommandList.matching(rows, query: query, title: { $0.title }, keywords: { $0.keywords }).map(\.title)
            XCTAssertEqual(got, expected, "query “\(query)”")
        }

        // A local row among the shared ones: by its title first, then by a keyword, in list order.
        var mixed = rows
        mixed.insert(Row(title: "New Worktree Tab…", keywords: ["branch", "git", "agent"]), at: 1)
        let titled = CommandList.matching(mixed, query: "worktree", title: { $0.title }, keywords: { $0.keywords })
        XCTAssertEqual(titled.map(\.title), ["New Worktree Tab…"])
        let new = CommandList.matching(mixed, query: "new", title: { $0.title }, keywords: { $0.keywords }).map(\.title)
        XCTAssertEqual(Array(new.prefix(3)), ["New Tab in api", "New Worktree Tab…", "New Workspace on Local Mac (dev)"])
        let agents = CommandList.matching(mixed, query: "agent", title: { $0.title }, keywords: { $0.keywords }).map(\.title)
        XCTAssertEqual(agents.first, "New Worktree Tab…", "keyword-only matches keep the list's order")
        XCTAssertEqual(agents.count, 4)
    }
}
