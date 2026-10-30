import ClothoKit
import XCTest
@testable import Clotho

/// Quick open's ">" commands on iOS: which ones the phone offers, and the row each one acts on.
@MainActor
final class QuickOpenCommandsTests: XCTestCase {
    private let key = UUID().uuidString

    private var state: ModelState {
        ModelState(workspaces: [
            Workspace(id: 1, name: "api", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100)),
                                                 Tab(id: 11, activePane: 110, layout: .split(id: 1, axis: .horizontal, ratio: 0.5, a: .pane(110), b: .pane(111)))]),
            Workspace(id: 2, name: "web", tabs: []),
        ])
    }

    func testPlaceOfEachRow() {
        XCTAssertEqual(place(.tab(machine: key, 11)).workspace, 1)
        XCTAssertEqual(place(.tab(machine: key, 11)).tab, 11)
        XCTAssertEqual(place(.workspace(machine: key, 2)).workspace, 2)
        XCTAssertNil(place(.workspace(machine: key, 2)).tab, "a workspace row has no tab")
        XCTAssertEqual(place(.agent(machine: key, pane: 111)).tab, 11, "an agent's own tab")
        XCTAssertEqual(place(.agent(machine: key, pane: 111)).workspace, 1)
        XCTAssertEqual(place(.machine(key)).workspace, 2, "a machine: its current workspace")
        XCTAssertNil(place(.tab(machine: key, 99)).workspace, "a tab that went away")
    }

    private func place(_ node: CommandTree.Node) -> (workspace: WorkspaceID?, tab: TabID?) {
        QuickOpenCommands.place(node, state: state, focusedWorkspace: 2)
    }

    /// The phone has no Settings window or sidebar to toggle, and no machine switch yet.
    func testThePhoneLeavesOutWhatItDoesntHave() {
        let context = CommandContext(machine: key, machineName: "devbox", workspace: 1, workspaceName: "api", tab: 10, tabName: "zsh",
                                     connected: true, enabled: true, isLocal: false, unreachable: true, canOpenBeside: true)
        let ids = Set(CommandList.items(for: context, supported: QuickOpenCommands.supported).map(\.id))
        XCTAssertTrue(ids.isDisjoint(with: [.settings, .toggleSidebar, .machineOn, .machineOff]))
        XCTAssertTrue(ids.isSuperset(of: [.newTab, .rename, .moveTab, .openBeside, .closeTab, .claudeHere, .files, .reconnect]))
    }

    func testEveryCommandHasASymbol() {
        for id in CommandListItem.ID.allCases {
            XCTAssertNotNil(UIImage(systemName: QuickOpenCommands.symbol(for: id)), id.rawValue)
        }
    }
}
