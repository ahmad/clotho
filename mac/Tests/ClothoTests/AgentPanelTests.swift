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
        // As the Mac posts them: with the pane's tab.
        func title(_ info: AgentInfo) -> String { AgentNotice(info: info, machine: "Mac", workspace: "Platform", tab: "cargo test").title }
        XCTAssertEqual(title(agent(.done, needsUser: true)), "Needs you · Platform › cargo test")
        XCTAssertEqual(title(agent(.done, needsUser: false)), "Done · Platform › cargo test")
        XCTAssertEqual(title(agent(.done)), "Platform · Claude finished", "an older daemon's, as before")
    }

    /// The mark follows ClothoKit's `activeStatusGroup` (shared with iOS) and must stay what the Mac's own
    /// rule gave, for every state, `needsUser`, attention, mute and settle; an older daemon's nil
    /// `needsUser` included.
    func testTheMarkAgreesWithTheMacRule() {
        func macRule(_ info: AgentInfo) -> AgentMark? {
            if info.needsAttention {
                if info.state == .error { return .error }
                return info.state != .done || info.asksUser ? .needsYou : .done
            }
            return info.state == .running || info.state == .starting ? .working : nil
        }
        var checked = 0
        for state in [.waiting, .running, .starting, .done, .error, .unknown] as [AgentInfo.State] {
            for needsUser in [true, false, nil] as [Bool?] {
                for attention in [true, false, nil] as [Bool?] {
                    for muted in [true, nil] as [Bool?] {
                        for settling in [true, nil] as [Bool?] {
                            let info = AgentInfo(kind: "claude", state: state, attention: attention, muted: muted,
                                                 needsUser: needsUser, settling: settling)
                            let name = "\(state) needsUser \(String(describing: needsUser)) attention \(String(describing: attention)) muted \(muted == true) settling \(settling == true)"
                            XCTAssertEqual(info.mark, macRule(info), name)
                            XCTAssertEqual(info.asksUser, info.state == .done && info.attentionGroup == .needsYou, name)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 6 * 3 * 3 * 2 * 2)
        XCTAssertEqual(AgentMark.needsYou.label, "Needs you")
        XCTAssertEqual(AgentMark.done.label, "Done")
        XCTAssertEqual(AgentMark.working.label, "Working")
    }
}

/// The hover actions (Mute, Resolve) float over the one-line row's trailing end only while it's hovered,
/// covering the end of its text; nothing reflows.
@MainActor
final class ResolveHoverTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func row(resolvable: Bool, canMute: Bool = true, width: CGFloat = 260) -> AgentRow {
        var entry = AgentEntry(machine: "local", machineName: "Mac", pane: 1, workspace: Workspace(id: 1, name: "Platform", tabs: []),
                               tab: nil, paneTitle: nil, tabTitle: "alerts",
                               info: AgentInfo(kind: "claude", state: .done, message: "A long reply that will certainly be cut off before the end of the row",
                                               since: Date().timeIntervalSince1970 - 600, attention: true), canReply: false)
        entry.canMute = canMute
        let row = AgentRow(entry, onResolve: resolvable ? {} : nil, onMute: resolvable && canMute ? {} : nil)
        row.frame = NSRect(x: 0, y: 0, width: width, height: AgentRow.height)
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

    /// The text ends at the same place with or without the hover actions: before the kind's glyph at the
    /// row's end, or at the row's end itself in a sidebar too narrow for the glyph.
    func testTheTextRunsToTheKindGlyphWithOrWithoutActions() {
        let with = row(resolvable: true), without = row(resolvable: false)
        XCTAssertEqual(with.summary.frame, without.summary.frame)
        XCTAssertEqual(with.label.frame, without.label.frame)
        // Constraints place the label's alignment rect; its frame adds the text field's own padding.
        XCTAssertFalse(with.kindGlyph.isHidden)
        XCTAssertEqual(with.kindGlyph.frame.maxX, 260 - s(8), accuracy: 0.5, "the glyph is what ends the row")
        XCTAssertEqual(with.summary.alignmentRect(forFrame: with.summary.frame).maxX, 260 - s(8) - AgentRow.glyphSlot - s(4), accuracy: 0.5)
        XCTAssertEqual(with.summary.alignmentRect(forFrame: with.summary.frame).maxX, with.kindGlyph.frame.minX - s(4), accuracy: 0.5)
        let narrowWidth = AgentRow.glyphLeastRow - 10
        let narrow = row(resolvable: true, width: narrowWidth)
        XCTAssertTrue(narrow.kindGlyph.isHidden, "no room for the glyph")
        XCTAssertEqual(narrow.summary.alignmentRect(forFrame: narrow.summary.frame).maxX, narrowWidth - s(8), accuracy: 0.5,
                       "and the text has the row to its end")
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
