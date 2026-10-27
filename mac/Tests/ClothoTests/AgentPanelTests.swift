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

/// The Resolve checkmark shows only while its row is hovered, and never moves anything.
@MainActor
final class ResolveHoverTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func row(resolvable: Bool) -> AgentRow {
        let entry = AgentEntry(machine: "local", machineName: "Mac", pane: 1, workspace: nil, tab: nil, paneTitle: nil,
                               tabTitle: "A long tab title that will be cut off",
                               info: AgentInfo(kind: "claude", state: .done, since: 1, attention: true), canReply: false)
        let row = AgentRow(entry, onResolve: resolvable ? {} : nil)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        row.layoutSubtreeIfNeeded()
        return row
    }

    func testHiddenUntilHovered() throws {
        let row = row(resolvable: true)
        let button = try XCTUnwrap(row.resolve)
        XCTAssertEqual(button.alphaValue, 0, "hidden by default")
        XCTAssertFalse(button.isHidden, "only transparent, so it keeps its place and stays clickable")
        row.setHovering(true)
        XCTAssertEqual(button.alphaValue, 1)
        row.setHovering(false)
        XCTAssertEqual(button.alphaValue, 0)
    }

    func testHoverMovesNothing() throws {
        let row = row(resolvable: true)
        let button = try XCTUnwrap(row.resolve)
        let before = (button.frame, row.label.frame)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.frame, before.0)
        XCTAssertEqual(row.label.frame, before.1)
    }

    func testRowsWithoutResolveHaveNoCheckmark() {
        let row = row(resolvable: false)
        XCTAssertNil(row.resolve)
        row.setHovering(true)
        XCTAssertNil(row.resolve)
    }

    func testNoPointerOutsideAWindow() {
        XCTAssertFalse(row(resolvable: true).pointerIsOver())
    }
}
