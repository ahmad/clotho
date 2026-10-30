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
}
