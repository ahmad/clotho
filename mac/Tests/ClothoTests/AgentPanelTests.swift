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

/// The hover actions (Mute, Resolve) float over the row's right end only while it's hovered; the time
/// stays pinned to the right edge and nothing reflows.
@MainActor
final class ResolveHoverTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func row(resolvable: Bool, muted: Bool = false) -> AgentRow {
        var entry = AgentEntry(machine: "local", machineName: "Mac", pane: 1, workspace: nil, tab: nil, paneTitle: nil,
                               tabTitle: "A long tab title that will certainly be cut off before the time",
                               info: AgentInfo(kind: "claude", state: .done, since: Date().timeIntervalSince1970 - 600,
                                               attention: !muted, muted: muted ? true : nil), canReply: false)
        entry.canMute = true
        let row = AgentRow(entry, onResolve: resolvable ? {} : nil, onMute: resolvable ? {} : nil)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        row.layoutSubtreeIfNeeded()
        return row
    }

    func testHiddenUntilHovered() throws {
        let row = row(resolvable: true)
        let actions = try XCTUnwrap(row.actions)
        XCTAssertNotNil(row.resolve)
        XCTAssertNotNil(row.mute)
        XCTAssertEqual(actions.alphaValue, 0, "hidden by default")
        XCTAssertFalse(actions.isHidden, "only transparent, so it stays reachable")
        row.setHovering(true)
        XCTAssertEqual(actions.alphaValue, 1, "Mute and Resolve fade in together")
        row.setHovering(false)
        XCTAssertEqual(actions.alphaValue, 0)
    }

    func testTimeIsPinnedRightWithOrWithoutActions() {
        let with = row(resolvable: true), without = row(resolvable: false)
        XCTAssertEqual(with.elapsedLabel.frame.maxX, without.elapsedLabel.frame.maxX)
        // Constraints place the label's alignment rect; its frame adds the text field's own padding.
        let time = with.elapsedLabel
        XCTAssertEqual(time.alignmentRect(forFrame: time.frame).maxX, 260 - AgentRow.timeInset)
        XCTAssertLessThanOrEqual(with.label.frame.maxX, with.elapsedLabel.frame.minX, "the title stops before the time")
    }

    func testActionsCoverTheTimeOnHover() throws {
        let row = row(resolvable: true)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        let actions = try XCTUnwrap(row.actions)
        XCTAssertTrue(actions.frame.intersects(row.elapsedLabel.frame), "the actions float over the time")
        XCTAssertLessThan(try XCTUnwrap(row.mute).convert(NSPoint.zero, to: row).x,
                          try XCTUnwrap(row.resolve).convert(NSPoint.zero, to: row).x, "Mute is left of Resolve")
    }

    func testHoverMovesNothing() {
        let row = row(resolvable: true)
        let before = (row.elapsedLabel.frame, row.label.frame, row.actions?.frame)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.elapsedLabel.frame, before.0)
        XCTAssertEqual(row.label.frame, before.1)
        XCTAssertEqual(row.actions?.frame, before.2)
    }

    func testQuietRowsHaveNoActionsAndMutedOnesAMarker() {
        let quiet = row(resolvable: false)
        XCTAssertNil(quiet.actions)
        XCTAssertNil(quiet.mutedMarker)
        let muted = row(resolvable: false, muted: true)
        XCTAssertNotNil(muted.mutedMarker)
        XCTAssertLessThanOrEqual(muted.mutedMarker!.frame.maxX, muted.elapsedLabel.frame.minX)
        XCTAssertLessThanOrEqual(muted.label.frame.maxX, muted.mutedMarker!.frame.minX, "the title stops before the marker")
    }

    func testNoPointerOutsideAWindow() {
        XCTAssertFalse(row(resolvable: true).pointerIsOver())
    }
}

final class MutedAgentTests: XCTestCase {
    func testMutedAgentsNeverNeedAttention() {
        let info = AgentInfo(kind: "claude", state: .waiting, source: "hook", attention: true, muted: true)
        XCTAssertFalse(info.needsAttention, "a muted agent never needs the user, whatever attention says")
        let entry = AgentEntry(machine: "m", machineName: "M", pane: 1, workspace: nil, tab: nil, paneTitle: nil, tabTitle: nil,
                               info: info, canReply: false)
        let (attention, others) = AgentEntry.split([entry])
        XCTAssertTrue(attention.isEmpty)
        XCTAssertEqual(others.map(\.pane), [1])
    }

    func testDecodesMuted() throws {
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"claude","state":"done","attention":false,"muted":true}"#.utf8))
        XCTAssertTrue(info.isMuted)
        let plain = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"claude","state":"done"}"#.utf8))
        XCTAssertFalse(plain.isMuted)
    }
}
