import ClothoKit
import XCTest
@testable import Clotho

/// clothod 0.1.31 (`alerts`): a finished turn reads "Needs you" or "Done" by `needs_user`, and a settling
/// one is a quiet done until its attention rises.
@MainActor
final class ClearerAlertsTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func agent(_ state: AgentInfo.State, attention: Bool? = true, needsUser: Bool? = nil, settling: Bool? = nil,
                       source: String? = "hook", message: String? = nil, since: Double = 100) -> AgentInfo {
        AgentInfo(kind: "claude", state: state, source: source, message: message, since: since, attention: attention,
                  needsUser: needsUser, settling: settling)
    }

    private func entry(_ pane: PaneID, _ info: AgentInfo, workspace: String? = nil) -> AgentEntry {
        AgentEntry(machine: "local", machineName: "Mac", pane: pane, workspace: workspace.map { Workspace(id: WorkspaceID(pane), name: $0, tabs: []) },
                   tab: nil, paneTitle: nil, tabTitle: nil, info: info, canReply: false)
    }

    func testOrder() {
        let entries = [
            entry(1, agent(.done, needsUser: false)),
            entry(2, agent(.running, attention: nil)),
            entry(3, agent(.done, needsUser: true)),
            entry(4, agent(.done, attention: false, settling: true)),
            entry(5, agent(.error, needsUser: true)),
            entry(6, agent(.waiting, needsUser: true)),
            entry(7, agent(.done)),                              // an older daemon: no needs_user
        ]
        XCTAssertEqual(entries.map(\.rank), [3, 4, 2, 5, 1, 0, 3])
        XCTAssertEqual(AgentEntry.sorted(entries).map(\.pane).prefix(3), [6, 5, 3], "waiting, failed, then the finished turn that asks something")
        let inbox = AgentInbox.sections(entries)
        XCTAssertEqual(Set(inbox.needsYou.map(\.pane)), [6, 5, 3], "all three need the user")
        XCTAssertEqual(Set(inbox.done.map(\.pane)), [1, 7], "the ones that only finished")
        XCTAssertEqual(inbox.working.map(\.pane), [2], "a settling agent is in no section")
    }

    func testAFinishedTurnShowsNeedsYouOrDone() {
        let asks = agent(.done, needsUser: true), plain = agent(.done, needsUser: false), old = agent(.done)
        XCTAssertEqual(asks.shownState.label, "Needs you")
        XCTAssertEqual(asks.shownState.symbol, AgentInfo.State.waiting.symbol, "the hand, so the icon tells it from Done")
        XCTAssertEqual(asks.mark?.color, Theme.caution)
        XCTAssertEqual(plain.shownState.label, "Done")
        XCTAssertEqual(plain.shownState.symbol, AgentInfo.State.done.symbol)
        XCTAssertEqual(plain.mark?.color, Theme.success)
        XCTAssertEqual(old.shownState.label, "Done", "without needs_user, as before")
        XCTAssertEqual(old.shownState.symbol, AgentInfo.State.done.symbol)
        // Seen (resolved, or answered): a done like any other.
        XCTAssertEqual(agent(.done, attention: false, needsUser: true).shownState.label, "Done")
        // Waiting and error keep their own words.
        XCTAssertEqual(agent(.waiting, needsUser: true).shownState.label, "Waiting for you")
        XCTAssertEqual(agent(.error, needsUser: true).shownState.label, "Error")
    }

    func testASettlingAgentIsAQuietDone() {
        let settling = agent(.done, attention: false, settling: true)
        XCTAssertEqual(settling.shownState.label, "Done")
        XCTAssertNil(settling.mark, "no mark")
        XCTAssertFalse(settling.needsAttention)
        // Even if a daemon sent attention with it: never listed, badged or counted while it settles.
        let odd = agent(.done, attention: true, needsUser: true, settling: true)
        XCTAssertFalse(odd.needsAttention)
        XCTAssertNil(odd.mark)
        XCTAssertEqual(odd.shownState.label, "Done")
        XCTAssertFalse(AppDelegate.needsYou(odd))
        XCTAssertFalse(odd.notifiesRise(from: agent(.running, attention: nil)), "no notification")
        let entries = [entry(1, settling), entry(2, odd), entry(3, agent(.done, needsUser: false))]
        let inbox = AgentInbox.sections(entries)
        XCTAssertEqual((inbox.needsYou + inbox.done + inbox.working).map(\.pane), [3])
        XCTAssertEqual(entries.filter(\.info.needsAttention).count, 1, "what the dock badge counts")
        // The rise at the end of the settle window (an `agent` event whose `from` is the state) notifies.
        XCTAssertTrue(agent(.done, needsUser: false, settling: false).notifiesRise(from: settling))
    }

    func testWhichSwitchANoticeFollows() {
        XCTAssertEqual(agent(.done, needsUser: true).notifySwitch, .waiting, "a finished turn that asks: Notify When Waiting for You")
        XCTAssertEqual(agent(.done, needsUser: false).notifySwitch, .done)
        XCTAssertEqual(agent(.done).notifySwitch, .done)
        XCTAssertEqual(agent(.waiting, needsUser: true).notifySwitch, .waiting)
        XCTAssertEqual(agent(.error, needsUser: true).notifySwitch, .error)
    }

    func testOnlyAPlainDoneIsSilent() {
        XCTAssertFalse(agent(.done, needsUser: false).playsSound)
        XCTAssertTrue(agent(.done, needsUser: true).playsSound)
        XCTAssertTrue(agent(.done).playsSound, "an older daemon's done sounds as before")
        XCTAssertTrue(agent(.waiting, needsUser: true).playsSound)
        XCTAssertTrue(agent(.error, needsUser: true).playsSound)
    }

    /// The minute's throttle is for detected agents, whose state flickers. A hook-reported agent that
    /// finishes again 40 s later is announced again.
    func testOnlyDetectedAgentsAreThrottled() {
        let now = Date()
        let last = (state: AgentInfo.State.done, date: now.addingTimeInterval(-40))
        XCTAssertFalse(AppDelegate.throttlesNotice(agent(.done, needsUser: false), last: last, now: now), "hook-reported")
        XCTAssertTrue(AppDelegate.throttlesNotice(agent(.done, source: nil), last: last, now: now), "detected, same state, within the minute")
        XCTAssertFalse(AppDelegate.throttlesNotice(agent(.waiting, source: nil), last: last, now: now), "another state")
        XCTAssertFalse(AppDelegate.throttlesNotice(agent(.done, source: nil), last: (.done, now.addingTimeInterval(-61)), now: now))
        XCTAssertFalse(AppDelegate.throttlesNotice(agent(.done, source: nil), last: nil, now: now))
    }

    func testNoticeWords() {
        XCTAssertEqual(AgentNotice(info: agent(.done, needsUser: true), machine: "Mac", workspace: "Platform").title, "Platform · Claude needs you")
        XCTAssertEqual(AgentNotice(info: agent(.done, needsUser: false), machine: "Mac", workspace: "Platform").title, "Platform · Claude is done")
        XCTAssertEqual(AgentNotice(info: agent(.done), machine: "Mac", workspace: "Platform").title, "Platform · Claude finished", "as before")
    }
}

/// The hover actions (Mute, Resolve) float over the one-line row's trailing end only while it's hovered,
/// covering the end of its text; nothing reflows.
@MainActor
final class ResolveHoverTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func row(resolvable: Bool, canMute: Bool = true) -> AgentRow {
        var entry = AgentEntry(machine: "local", machineName: "Mac", pane: 1, workspace: Workspace(id: 1, name: "Platform", tabs: []),
                               tab: nil, paneTitle: nil, tabTitle: "alerts",
                               info: AgentInfo(kind: "claude", state: .done, message: "A long reply that will certainly be cut off before the end of the row",
                                               since: Date().timeIntervalSince1970 - 600, attention: true), canReply: false)
        entry.canMute = canMute
        let row = AgentRow(entry, onResolve: resolvable ? {} : nil, onMute: resolvable && canMute ? {} : nil)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: AgentRow.height)
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

    func testTheTextRunsToTheRowsEndWithOrWithoutActions() {
        let with = row(resolvable: true), without = row(resolvable: false)
        XCTAssertEqual(with.summary.frame, without.summary.frame)
        XCTAssertEqual(with.label.frame, without.label.frame)
        // Constraints place the label's alignment rect; its frame adds the text field's own padding.
        XCTAssertEqual(with.summary.alignmentRect(forFrame: with.summary.frame).maxX, 260 - s(8), accuracy: 0.5)
        XCTAssertLessThanOrEqual(with.label.alignmentRect(forFrame: with.label.frame).maxX,
                                 with.summary.alignmentRect(forFrame: with.summary.frame).minX, "the title stops before the text")
    }

    func testActionsCoverTheTextsEndOnHover() throws {
        let row = row(resolvable: true)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        let actions = try XCTUnwrap(row.actions)
        XCTAssertTrue(actions.frame.intersects(row.summary.frame), "the actions float over the end of the text")
        XCTAssertFalse(actions.frame.intersects(row.label.frame), "not over the title")
        XCTAssertTrue(row.bounds.contains(actions.frame), "inside the one-line row")
        XCTAssertLessThan(try XCTUnwrap(row.mute).convert(NSPoint.zero, to: row).x,
                          try XCTUnwrap(row.resolve).convert(NSPoint.zero, to: row).x, "Mute is left of Resolve")
    }

    func testHoverMovesNothing() {
        let row = row(resolvable: true)
        let before = (row.summary.frame, row.label.frame, row.actions?.frame)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.summary.frame, before.0)
        XCTAssertEqual(row.label.frame, before.1)
        XCTAssertEqual(row.actions?.frame, before.2)
    }

    func testWorkingRowsHaveNoActionsAndResolveStandsAloneWithoutMute() {
        XCTAssertNil(row(resolvable: false).actions)
        let plain = row(resolvable: true, canMute: false)
        XCTAssertNil(plain.mute)
        XCTAssertNotNil(plain.resolve)
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
        let inbox = AgentInbox.sections([entry])
        XCTAssertTrue(inbox.needsYou.isEmpty && inbox.done.isEmpty && inbox.working.isEmpty, "in no section of the inbox")
    }

    func testDecodesMuted() throws {
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"claude","state":"done","attention":false,"muted":true}"#.utf8))
        XCTAssertTrue(info.isMuted)
        let plain = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"claude","state":"done"}"#.utf8))
        XCTAssertFalse(plain.isMuted)
    }
}
