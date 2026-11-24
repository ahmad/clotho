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
        let (attention, others) = AgentEntry.split(entries)
        XCTAssertEqual(attention.map(\.pane).prefix(3), [6, 5, 3], "waiting, failed, then the finished turn that asks something")
        XCTAssertEqual(Set(attention.map(\.pane).suffix(2)), [1, 7], "then the ones that only finished")
        XCTAssertEqual(others.map(\.pane), [2, 4], "a settling agent sits below, after the running one")
    }

    func testAFinishedTurnShowsNeedsYouOrDone() {
        let asks = agent(.done, needsUser: true), plain = agent(.done, needsUser: false), old = agent(.done)
        XCTAssertEqual(asks.shownState.label, "Needs you")
        XCTAssertEqual(asks.shownState.symbol, AgentInfo.State.waiting.symbol, "the hand, so the icon tells it from Done")
        XCTAssertEqual(asks.badgeColor, Theme.warning)
        XCTAssertEqual(plain.shownState.label, "Done")
        XCTAssertEqual(plain.shownState.symbol, AgentInfo.State.done.symbol)
        XCTAssertEqual(plain.badgeColor, Theme.success)
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
        XCTAssertNil(settling.badgeColor, "no badge")
        XCTAssertFalse(settling.needsAttention)
        // Even if a daemon sent attention with it: never listed, badged or counted while it settles.
        let odd = agent(.done, attention: true, needsUser: true, settling: true)
        XCTAssertFalse(odd.needsAttention)
        XCTAssertNil(odd.badgeColor)
        XCTAssertEqual(odd.shownState.label, "Done")
        XCTAssertFalse(AppDelegate.needsYou(odd))
        XCTAssertFalse(odd.notifiesRise(from: agent(.running, attention: nil)), "no notification")
        let entries = [entry(1, settling), entry(2, odd), entry(3, agent(.done, needsUser: false))]
        XCTAssertEqual(AgentEntry.split(entries).attention.map(\.pane), [3])
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

    /// Review images of the Agents panel with a Needs you, a Done and a settling agent, light and dark.
    /// Runs only with CLOTHO_SNAPSHOT_DIR set.
    func testSnapshotsForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        let saved = NSApp.appearance, expanded = UserDefaults.standard.object(forKey: "AgentsOthersExpanded")
        let height = UserDefaults.standard.object(forKey: "AgentsPanelHeight")
        defer {
            NSApp.appearance = saved
            Theme.followAppAppearance()
            UserDefaults.standard.set(expanded, forKey: "AgentsOthersExpanded")
            UserDefaults.standard.set(height, forKey: "AgentsPanelHeight")
        }
        UserDefaults.standard.set(true, forKey: "AgentsOthersExpanded")
        // Tall enough for all five rows and the Quiet header.
        UserDefaults.standard.set(290.0, forKey: "AgentsPanelHeight")
        let now = Date().timeIntervalSince1970
        let agents = AgentEntry.sorted([
            entry(1, agent(.waiting, needsUser: true, message: "Allow running `swift test`?", since: now - 30), workspace: "Platform"),
            entry(2, agent(.done, needsUser: true, message: "The fix is committed. Should I push it?", since: now - 95), workspace: "api"),
            entry(3, agent(.done, needsUser: false, message: "All 212 tests pass.", since: now - 200), workspace: "web"),
            entry(4, agent(.done, attention: false, settling: true, message: "Renamed the module.", since: now - 5), workspace: "docs"),
            entry(5, agent(.running, attention: nil, message: "Editing Sources/Model.swift", since: now - 400), workspace: "infra"),
        ])
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            Theme.followAppAppearance()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSApp.appearance
            defer { window.close() }
            let sidebar = SidebarView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(sidebar)
            sidebar.update(agents: agents, unreachable: [], groups: [])
            sidebar.layoutSubtreeIfNeeded()
            guard let rep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) else { return XCTFail("no image") }
            sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/alerts-agents-panel-\(name).png"))
        }
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
