import ClothoKit
import XCTest
@testable import Clotho

/// Quick open's tree on iOS: the outline it builds from the machines' models, and where each row goes.
/// (The tree's own rules are ClothoKit's CommandTreeTests.)
final class QuickOpenTreeTests: XCTestCase {
    private let mac = UUID()
    private let away = UUID()

    private func tab(_ id: TabID, panes: [PaneID], active: PaneID? = nil) -> Tab {
        let layout = panes.dropFirst().reduce(Layout.pane(panes[0])) { .split(id: SplitID($1), axis: .horizontal, ratio: 0.5, a: $0, b: .pane($1)) }
        return Tab(id: id, activePane: active ?? panes[0], layout: layout)
    }

    private var state: ModelState {
        ModelState(workspaces: [
            Workspace(id: 1, name: "api", tabs: [tab(10, panes: [100]), tab(11, panes: [110, 111], active: 111)], activeTab: 11),
            Workspace(id: 2, name: "web", tabs: [tab(20, panes: [200])]),
        ])
    }

    private func agent(_ machine: UUID, pane: PaneID, _ state: AgentInfo.State, attention: Bool?) -> AgentRow {
        AgentRow(machineID: machine, machineName: "m", pane: pane, tab: 10, workspace: "api", title: "t",
                 info: AgentInfo(kind: "claude", state: state, source: "hook", attention: attention))
    }

    func testOutlineKeepsTheOrderAndLeavesOfflineMachinesEmpty() {
        let outline = QuickOpenTree.outline([(mac, state), (away, nil)], agents: [])
        XCTAssertEqual(outline.machines.map(\.key), [mac.uuidString, away.uuidString])
        XCTAssertEqual(outline.machines[0].workspaces?.map(\.id), [1, 2])
        XCTAssertEqual(outline.machines[0].workspaces?[0].tabs, [10, 11])
        XCTAssertNil(outline.machines[1].workspaces, "a machine that isn't connected has nothing yet; a tap connects it")
    }

    func testNeedsYouIsWaitingOrErrorWithAttention() {
        let agents = [agent(mac, pane: 100, .waiting, attention: true), agent(mac, pane: 110, .error, attention: true),
                      agent(mac, pane: 111, .waiting, attention: false), agent(mac, pane: 200, .done, attention: true),
                      agent(UUID(), pane: 5, .waiting, attention: true)]
        let outline = QuickOpenTree.outline([(mac, state)], agents: agents)
        XCTAssertEqual(outline.needsYou.map(\.pane), [100, 110], "answered, finished and unknown machines' agents stay out")
        XCTAssertEqual(outline.needsYou.map(\.machine), [mac.uuidString, mac.uuidString])
    }

    func testRoutes() {
        let key = mac.uuidString
        XCTAssertEqual(QuickOpenTree.route(.tab(machine: key, 11), state: state), .pane(mac, 11, 111), "a tab at its active pane")
        XCTAssertEqual(QuickOpenTree.route(.workspace(machine: key, 1), state: state), .pane(mac, 11, 111), "a workspace at its last active tab")
        XCTAssertEqual(QuickOpenTree.route(.workspace(machine: key, 2), state: state), .pane(mac, 20, 200), "no active tab: its first")
        XCTAssertEqual(QuickOpenTree.route(.agent(machine: key, pane: 110), state: state), .pane(mac, 11, 110), "an agent's own pane")
        XCTAssertEqual(QuickOpenTree.route(.machine(key), state: state), .machine(mac))
        XCTAssertNil(QuickOpenTree.route(.tab(machine: key, 99), state: state), "a tab that closed meanwhile")
        XCTAssertNil(QuickOpenTree.route(.tab(machine: "not a uuid", 10), state: state))
    }

    /// The whole path from models to rows: the tree opens on the current workspace, and a tap on a workspace
    /// goes where the Mac would.
    func testTreeFromTheOutline() {
        let outline = QuickOpenTree.outline([(mac, state), (away, nil)], agents: [agent(mac, pane: 200, .waiting, attention: true)])
        var tree = CommandTree(outline: outline, machine: mac.uuidString, workspace: 1, tab: 11)
        XCTAssertEqual(tree.rows.map(\.node), [.agent(machine: mac.uuidString, pane: 200), .workspace(machine: mac.uuidString, 1),
                                               .tab(machine: mac.uuidString, 10), .tab(machine: mac.uuidString, 11),
                                               .workspace(machine: mac.uuidString, 2)])
        tree.showMachines()
        XCTAssertEqual(tree.rows.filter { $0.section == .tree }.map(\.node), [.machine(mac.uuidString), .machine(away.uuidString)])
        tree.select(2)
        XCTAssertEqual(tree.activate(), .connect(away.uuidString))
    }
}
