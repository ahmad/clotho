import ClothoKit
import XCTest
@testable import Clotho

final class AgentPanelTests: XCTestCase {
    private func entry(_ pane: PaneID, _ state: AgentInfo.State, attention: Bool?, since: Double) -> AgentEntry {
        AgentEntry(machine: "local", machineName: "Mac", pane: pane, workspace: nil, tab: nil, paneTitle: nil, tabTitle: nil,
                   info: AgentInfo(kind: "claude", state: state, since: since, attention: attention), canReply: false)
    }

    func testAttentionOnTopEverythingElseBelow() {
        let entries = [
            entry(1, .running, attention: nil, since: 100),
            entry(2, .done, attention: true, since: 200),
            entry(3, .waiting, attention: true, since: 50),
            entry(4, .done, attention: false, since: 300),     // resolved
            entry(5, .error, attention: true, since: 10),
            entry(6, .waiting, attention: false, since: 400),  // quiet: idle, not asking
            entry(7, .starting, attention: nil, since: 500),
            entry(8, .done, attention: true, since: 250),
        ]
        let (attention, others) = AgentEntry.split(entries)
        // Waiting, then error, then done (newest first).
        XCTAssertEqual(attention.map(\.pane), [3, 5, 8, 2])
        // Running and starting (newest first), then idle and resolved (newest first).
        XCTAssertEqual(others.map(\.pane), [7, 1, 6, 4])
    }

    func testResolvingMovesAnAgentDown() {
        var entries = [entry(1, .done, attention: true, since: 1), entry(2, .running, attention: nil, since: 2)]
        XCTAssertEqual(AgentEntry.split(entries).attention.map(\.pane), [1])
        entries[0] = entry(1, .done, attention: false, since: 1)
        XCTAssertEqual(AgentEntry.split(entries).attention.map(\.pane), [])
        XCTAssertEqual(AgentEntry.split(entries).others.map(\.pane), [2, 1])
        // Raised again (a new done or a bell): back on top.
        entries[0] = entry(1, .waiting, attention: true, since: 3)
        XCTAssertEqual(AgentEntry.split(entries).attention.map(\.pane), [1])
    }

    func testEmpty() {
        let (attention, others) = AgentEntry.split([])
        XCTAssertTrue(attention.isEmpty && others.isEmpty)
    }
}
