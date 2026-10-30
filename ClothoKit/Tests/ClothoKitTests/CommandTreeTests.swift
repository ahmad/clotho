import XCTest
@testable import ClothoKit

/// ⌘P's tree: what shows with nothing typed, and what →, ←, Return and leaving search do.
final class CommandTreeTests: XCTestCase {
    typealias Node = CommandTree.Node

    /// This Mac ("local") with workspaces 1 (tabs 10, 11) and 2 (tab 20); devbox with workspace 5
    /// (tab 50); imac not connected. An agent waits on devbox's pane 500.
    private func outline(needsYou: Bool = true) -> CommandTree.Outline {
        CommandTree.Outline(machines: [
            .init(key: "local", workspaces: [.init(id: 1, tabs: [10, 11]), .init(id: 2, tabs: [20])]),
            .init(key: "bb", workspaces: [.init(id: 5, tabs: [50])]),
            .init(key: "imac", workspaces: nil),
        ], needsYou: needsYou ? [(machine: "bb", pane: 500)] : [])
    }

    private func nodes(_ tree: CommandTree) -> [Node] { tree.rows.map(\.node) }

    func testOpensOnThisMachineWithTheCurrentWorkspaceExpanded() {
        let tree = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 11)
        XCTAssertEqual(nodes(tree), [.agent(machine: "bb", pane: 500),
                                     .workspace(machine: "local", 1), .tab(machine: "local", 10), .tab(machine: "local", 11),
                                     .workspace(machine: "local", 2)],
                       "Needs you on top, then this machine only: the current workspace open, the other collapsed")
        XCTAssertEqual(tree.rows.first?.section, .needsYou)
        XCTAssertEqual(tree.selection, .tab(machine: "local", 11), "the current tab")
        XCTAssertEqual(tree.rows.map(\.depth), [0, 0, 1, 1, 0])
    }

    func testRightExpandsThenEntersAndLeftCollapses() {
        var tree = CommandTree(outline: outline(needsYou: false), machine: "local", workspace: 1, tab: 10)
        tree.move(2) // tab 10 → tab 11 → workspace 2
        XCTAssertEqual(tree.selection, .workspace(machine: "local", 2))
        XCTAssertTrue(tree.expand())
        XCTAssertEqual(nodes(tree).suffix(2), [.workspace(machine: "local", 2), .tab(machine: "local", 20)], "→ shows its tabs")
        XCTAssertEqual(tree.selection, .workspace(machine: "local", 2), "and keeps the workspace selected")
        XCTAssertTrue(tree.expand())
        XCTAssertEqual(tree.selection, .tab(machine: "local", 20), "→ again enters it")
        XCTAssertFalse(tree.expand(), "a tab has nothing to expand")

        XCTAssertTrue(tree.collapse())
        XCTAssertEqual(tree.selection, .workspace(machine: "local", 2), "← from a tab: its workspace, collapsed")
        XCTAssertFalse(nodes(tree).contains(.tab(machine: "local", 20)))
    }

    func testLeftFromACollapsedWorkspaceGoesUpToTheMachines() {
        var tree = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 10)
        tree.collapse() // tab → workspace 1, collapsed
        XCTAssertEqual(tree.selection, .workspace(machine: "local", 1))
        XCTAssertTrue(tree.collapse())
        XCTAssertEqual(tree.scope, .machines)
        XCTAssertEqual(tree.selection, .machine("local"))
        XCTAssertEqual(nodes(tree), [.agent(machine: "bb", pane: 500), .machine("local"), .machine("bb"), .machine("imac")],
                       "every machine, Needs you still on top")
        XCTAssertEqual(tree.rows.map(\.expandable), [false, true, true, false], "imac isn't connected")

        // → on devbox shows its workspaces, → again on its workspace its tabs; ← climbs back.
        tree.move(1)
        XCTAssertEqual(tree.selection, .machine("bb"))
        tree.expand()
        tree.expand()
        XCTAssertEqual(tree.selection, .workspace(machine: "bb", 5))
        tree.expand()
        XCTAssertEqual(nodes(tree).suffix(3), [.workspace(machine: "bb", 5), .tab(machine: "bb", 50), .machine("imac")])
        XCTAssertEqual(tree.rows.first { $0.node == .tab(machine: "bb", 50) }?.depth, 2)
        tree.collapse()
        tree.collapse()
        XCTAssertEqual(tree.selection, .machine("bb"), "← from a collapsed workspace in the machine list: its machine")
        XCTAssertFalse(tree.collapse(), "nothing above the machines")
    }

    func testReturn() {
        var tree = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 10)
        XCTAssertEqual(tree.activate(), .open(.tab(machine: "local", 10)))
        tree.collapse()
        XCTAssertEqual(tree.activate(), .open(.workspace(machine: "local", 1)), "a workspace opens (its last tab)")
        tree.move(-1)
        XCTAssertEqual(tree.activate(), .open(.agent(machine: "bb", pane: 500)), "Needs you jumps to the pane")
        tree.move(1)
        tree.collapse()
        XCTAssertEqual(tree.activate(), .expanded, "a machine expands")
        XCTAssertTrue(nodes(tree).contains(.workspace(machine: "local", 2)))
        tree.select(nodes(tree).firstIndex(of: .machine("imac"))!)
        XCTAssertEqual(tree.activate(), .connect("imac"), "one that isn't connected connects")

        // A connected machine with no workspaces has nothing to expand: Return goes to it.
        var empty = CommandTree(outline: .init(machines: [.init(key: "local", workspaces: [.init(id: 1, tabs: [10])]),
                                                          .init(key: "bb", workspaces: [])], needsYou: []),
                                machine: "local", workspace: 1, tab: 10)
        empty.collapse()
        empty.collapse()
        empty.move(1)
        XCTAssertEqual(empty.selection, .machine("bb"))
        XCTAssertEqual(empty.rows.last?.expandable, false)
        XCTAssertFalse(empty.expand())
        XCTAssertEqual(empty.activate(), .open(.machine("bb")))
    }

    func testLeavingSearch() {
        var tree = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 10)
        // Tab on devbox's tab 50: the tree, inside devbox's workspace.
        tree.reveal(.tab(machine: "bb", 50))
        XCTAssertEqual(tree.selection, .tab(machine: "bb", 50))
        XCTAssertTrue(nodes(tree).contains(.workspace(machine: "bb", 5)))
        // Tab on a collapsed workspace expands it.
        var other = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 10)
        other.reveal(.workspace(machine: "local", 2))
        XCTAssertEqual(nodes(other).suffix(2), [.workspace(machine: "local", 2), .tab(machine: "local", 20)])
        // ⇧Tab: the parent.
        var up = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 10)
        up.revealParent(of: .tab(machine: "local", 20))
        XCTAssertEqual(up.selection, .workspace(machine: "local", 2))
        up.revealParent(of: .workspace(machine: "bb", 5))
        XCTAssertEqual(up.scope, .machines)
        XCTAssertEqual(up.selection, .machine("bb"))
    }

    func testModelChangesKeepThePlace() {
        var tree = CommandTree(outline: outline(), machine: "local", workspace: 1, tab: 11)
        // Tab 11 closes: its workspace takes the selection.
        tree.update(CommandTree.Outline(machines: [
            .init(key: "local", workspaces: [.init(id: 1, tabs: [10]), .init(id: 2, tabs: [20])]),
            .init(key: "bb", workspaces: [.init(id: 5, tabs: [50])]),
        ], needsYou: []))
        XCTAssertEqual(tree.selection, .workspace(machine: "local", 1))
        XCTAssertEqual(nodes(tree).first, .workspace(machine: "local", 1), "the agent stopped waiting")
    }

    func testManyMachinesStayFast() {
        // 30 machines × 40 workspaces × 10 tabs: building rows and moving must stay instant.
        var machines: [CommandTree.Outline.Machine] = []
        for m in 0..<30 {
            var workspaces: [CommandTree.Outline.Workspace] = []
            for w in 0..<40 {
                let tabs: [TabID] = (0..<10).map { TabID(m * 100_000 + w * 100 + $0) }
                workspaces.append(CommandTree.Outline.Workspace(id: WorkspaceID(m * 1000 + w), tabs: tabs))
            }
            machines.append(CommandTree.Outline.Machine(key: "m\(m)", workspaces: workspaces))
        }
        var tree = CommandTree(outline: .init(machines: machines, needsYou: []), machine: "m0", workspace: 0, tab: 0)
        tree.collapse()
        tree.collapse()
        // Every machine open, so the list is 30 + 1,200 rows long.
        for index in stride(from: 29, through: 0, by: -1) {
            tree.select(index)
            tree.expand()
        }
        XCTAssertEqual(tree.rows.count, 30 + 30 * 40)
        let start = Date()
        for _ in 0..<200 { tree.move(1); _ = tree.rows }
        tree.expand()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
