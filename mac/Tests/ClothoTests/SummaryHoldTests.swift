import ClothoKit
import XCTest
@testable import Clotho

/// A notification waits for the daemon's summary: once, with the summary, or after the wait with
/// whatever there is; never for an agent that moved on.
@MainActor
final class SummaryHoldTests: XCTestCase {
    private let key = PaneKey(machine: AppDelegate.localKey, pane: 4)

    private func agent(_ state: AgentInfo.State = .done, summary: String?, pending: Bool, attention: Bool = true) -> AgentInfo {
        AgentInfo(kind: "claude", state: state, message: "**Done.** Fixed `auth`.", attention: attention, summary: summary, summaryPending: pending)
    }

    func testPostsOnceWhenTheSummaryLands() {
        var now = agent(summary: "Done. Fixed auth.", pending: true)
        var posted: [String] = []
        let hold = SummaryHold(current: { _ in now }) { _, info in posted.append(AgentNotice(info: info, machine: "m").body) }
        hold.wait = 30
        hold.hold(key, state: .done)
        XCTAssertTrue(hold.isHolding(key))
        // Other changes while pending (a tool, the same pending summary) don't release it.
        hold.agentChanged(key, to: now)
        XCTAssertEqual(posted, [])
        now = agent(summary: "Fixed the auth bug.", pending: false)
        hold.agentChanged(key, to: now)
        XCTAssertEqual(posted, ["Fixed the auth bug."])
        XCTAssertFalse(hold.isHolding)
        hold.agentChanged(key, to: now)
        hold.release(key)
        XCTAssertEqual(posted.count, 1, "never twice")
    }

    /// The small model decides `needs_user` with the summary: the notice goes out with the final word and
    /// sound, not the ones the rise came with.
    func testPostsWithTheFinalNeedsUser() {
        var now = agent(summary: "Done. Fixed auth.", pending: true)
        now.needsUser = false
        var posted: [(title: String, sound: Bool, key: AgentInfo.State)] = []
        let hold = SummaryHold(current: { _ in now }) { _, info in
            posted.append((AgentNotice(info: info, machine: "m", workspace: "Platform", tab: "cargo test").title, info.playsSound, info.notifySwitch))
        }
        hold.wait = 30
        hold.hold(key, state: .done)
        now = agent(summary: "Fixed auth. Should I push?", pending: false)
        now.needsUser = true
        hold.agentChanged(key, to: now)
        XCTAssertEqual(posted.map(\.title), ["Needs you · Platform › cargo test"])
        XCTAssertEqual(posted.map(\.sound), [true])
        XCTAssertEqual(posted.map(\.key), [.waiting], "and it follows the Waiting for You switch")
    }

    func testPostsAfterTheWaitWithWhatThereIs() async throws {
        let now = agent(summary: "Done. Fixed auth.", pending: true)
        var posted: [String] = []
        let hold = SummaryHold(current: { _ in now }) { _, info in posted.append(AgentNotice(info: info, machine: "m").body) }
        hold.wait = 0.1
        hold.hold(key, state: .done)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(posted, ["Done. Fixed auth."], "the cleaned message the daemon put in summary")
        XCTAssertFalse(hold.isHolding)
    }

    func testDropsItWhenTheAgentMovedOn() {
        var now: AgentInfo? = agent(summary: nil, pending: true)
        var posted = 0, dropped = 0
        let hold = SummaryHold(current: { _ in now }) { _, _ in posted += 1 }
        hold.dropped = { _ in dropped += 1 }
        hold.wait = 30
        // Answered meanwhile: attention cleared.
        hold.hold(key, state: .done)
        now = agent(summary: "Fixed.", pending: false, attention: false)
        hold.agentChanged(key, to: now)
        // Working again: another state.
        hold.hold(key, state: .waiting)
        now = agent(.running, summary: nil, pending: false)
        hold.agentChanged(key, to: now)
        // Gone.
        hold.hold(key, state: .done)
        now = nil
        hold.agentChanged(key, to: nil)
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(dropped, 3)
    }
}
