import ClothoKit
import XCTest
@testable import Clotho

/// The Agents list's three groups (AgentGroup): which group an agent is in, the order inside each, and what a
/// row's caption and VoiceOver text say.
@MainActor
final class AgentGroupsTests: XCTestCase {
    private let machine = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func row(_ pane: PaneID, _ state: AgentInfo.State, attention: Bool? = true, needsUser: Bool? = nil, muted: Bool? = nil,
                     settling: Bool? = nil, since: Double? = nil, message: String? = nil, changes: PaneGit.Changes? = nil) -> AgentRow {
        AgentRow(machineID: machine, machineName: "devbox", pane: pane, tab: 1, workspace: "Platform", title: "api-server",
                 info: AgentInfo(kind: "claude", state: state, source: "hook", message: message, since: since, attention: attention,
                                 muted: muted, needsUser: needsUser, settling: settling),
                 changes: changes)
    }

    func testGroupByStateAndNeedsUser() {
        // With the daemon's attention: only a finished turn that needs nothing is Done.
        for needsUser in [true, false, nil] as [Bool?] {
            let said = needsUser.map { "\($0)" } ?? "nil"
            XCTAssertEqual(row(1, .waiting, needsUser: needsUser).group, .needsYou, "waiting, needs_user \(said)")
            XCTAssertEqual(row(1, .error, needsUser: needsUser).group, .needsYou, "error, needs_user \(said)")
            XCTAssertEqual(row(1, .running, attention: nil, needsUser: needsUser).group, .working, "running, needs_user \(said)")
            XCTAssertEqual(row(1, .starting, attention: nil, needsUser: needsUser).group, .working, "starting, needs_user \(said)")
            XCTAssertEqual(row(1, .unknown, attention: nil, needsUser: needsUser).group, .working, "unknown, needs_user \(said)")
        }
        XCTAssertEqual(row(1, .done, needsUser: true).group, .needsYou, "a finished turn that ends in a question")
        XCTAssertEqual(row(1, .done, needsUser: false).group, .done)
        XCTAssertEqual(row(1, .done, needsUser: nil).group, .done, "an older daemon doesn't say: finished is Done")

        // Without attention (resolved, or a detected agent gone quiet), whatever needs_user says.
        for state in AgentInfo.State.allCases {
            for needsUser in [true, false, nil] as [Bool?] {
                XCTAssertEqual(row(1, state, attention: false, needsUser: needsUser).group, .working, "\(state) without attention")
                XCTAssertEqual(row(1, state, attention: nil, needsUser: needsUser).group, .working, "\(state) with no attention sent")
            }
        }
    }

    func testSettlingAndMutedAreWorking() {
        // A settling turn reads Done but hasn't asked for the user yet, whatever else the daemon sent with it.
        for needsUser in [true, false, nil] as [Bool?] {
            for attention in [true, false, nil] as [Bool?] {
                let settling = row(1, .done, attention: attention, needsUser: needsUser, settling: true)
                XCTAssertEqual(settling.group, .working)
                XCTAssertEqual(settling.status, "Done")
            }
        }
        for state in [AgentInfo.State.waiting, .done, .error] {
            let muted = row(1, state, needsUser: true, muted: true)
            XCTAssertEqual(muted.group, .working, "a muted \(state) agent")
        }
        XCTAssertEqual(row(1, .waiting, needsUser: true, muted: true).status, "Waiting")
    }

    func testStatusNamesTheGroup() {
        XCTAssertEqual(row(1, .waiting, needsUser: true).status, "Needs you")
        XCTAssertEqual(row(1, .error, needsUser: true).status, "Needs you")
        XCTAssertEqual(row(1, .done, needsUser: true).status, "Needs you")
        XCTAssertEqual(row(1, .done, needsUser: false).status, "Done")
        XCTAssertEqual(row(1, .done).status, "Done")
        XCTAssertEqual(row(1, .running, attention: nil).status, "Running")
        XCTAssertEqual(row(1, .error, attention: false).status, "Error", "a resolved error")
        XCTAssertEqual(AgentGroup.allCases.map(\.title), ["Needs you", "Done", "Working"])
    }

    func testOrderInsideEachGroup() {
        let rows = [
            row(1, .waiting, needsUser: true, since: 300), row(2, .error, needsUser: true, since: 100),
            row(3, .done, needsUser: true, since: 200),
            row(4, .done, needsUser: false, since: 150), row(5, .done, since: 400), row(6, .done, needsUser: false, since: 250),
            row(7, .running, attention: nil, since: 500), row(8, .done, attention: false, since: 600),
            row(9, .waiting, attention: nil, since: 50), row(10, .done, attention: false, settling: true, since: 700),
            row(11, .starting, attention: nil, since: 10),
        ]
        let groups = AgentRow.groups(rows.shuffled())
        XCTAssertEqual(groups.needsYou.map(\.pane), [2, 3, 1], "the longest wait first, whatever the state")
        XCTAssertEqual(groups.done.map(\.pane), [5, 6, 4], "the newest first")
        XCTAssertEqual(groups.working.map(\.pane), [9, 7, 11, 10, 8], "idle, running, starting, then finished ones, newest first")
        XCTAssertEqual(groups.needsYou.count + groups.done.count + groups.working.count, rows.count, "every agent is in one group")
        // The badge's count (needsAttention) is Needs you plus Done.
        XCTAssertEqual(rows.filter(\.wantsAttention).count, groups.needsYou.count + groups.done.count)
    }

    func testCaptionWithAndWithoutChanges() {
        let now = Date(timeIntervalSince1970: 10_000)
        let changes = PaneGit.Changes(uncommitted: .init(files: 6, added: 128, removed: 32))
        XCTAssertEqual(AgentRowView.caption(row(1, .waiting, since: 10_000 - 240, changes: changes), now: now),
                       "devbox · Claude · 4m · +128 \u{2212}32 · 6 files")
        XCTAssertEqual(AgentRowView.caption(row(1, .waiting, since: 10_000 - 240), now: now), "devbox · Claude · 4m")
        XCTAssertEqual(AgentRowView.caption(row(1, .waiting, changes: changes), now: now), "devbox · Claude · +128 \u{2212}32 · 6 files",
                       "no age without a time")
        let uncounted = PaneGit.Changes(uncommitted: .init(files: 1))
        XCTAssertEqual(AgentRowView.caption(row(1, .done, since: 10_000 - 7200, changes: uncounted), now: now), "devbox · Claude · 2h · 1 file")
        let clean = PaneGit.Changes(uncommitted: .init(files: 0, added: 0, removed: 0))
        XCTAssertEqual(AgentRowView.caption(row(1, .done, since: 10_000, changes: clean), now: now), "devbox · Claude · now",
                       "nothing changed: nothing said")
    }

    func testChangesOnlyFromADaemonThatCountsThem() {
        let changes = PaneGit.Changes(uncommitted: .init(files: 6, added: 128, removed: 32))
        let git = PaneGit(repo: "clotho", branch: "main", changes: changes)
        XCTAssertEqual(AgentRow.changes(of: git, features: [.gitChanges]), changes)
        XCTAssertNil(AgentRow.changes(of: git, features: []), "no git.changes feature")
        XCTAssertNil(AgentRow.changes(of: git, features: [.agentMute]))
        XCTAssertNil(AgentRow.changes(of: git, features: nil), "no hello yet")
        XCTAssertNil(AgentRow.changes(of: nil, features: [.gitChanges]), "not a repository")
        XCTAssertNil(AgentRow.changes(of: PaneGit(repo: "clotho", branch: "main", changesReason: "pending"), features: [.gitChanges]))
        // Without the feature the caption is as before.
        let now = Date(timeIntervalSince1970: 10_000)
        let plain = row(1, .waiting, since: 10_000 - 60, changes: AgentRow.changes(of: git, features: []))
        XCTAssertEqual(AgentRowView.caption(plain, now: now), "devbox · Claude · 1m")
        // A row is redrawn when its counts change.
        XCTAssertNotEqual(row(1, .waiting, changes: changes), row(1, .waiting))
        XCTAssertEqual(row(1, .waiting, changes: changes), row(1, .waiting, changes: changes))
    }

    func testSpokenText() {
        let changes = PaneGit.Changes(uncommitted: .init(files: 6, added: 128, removed: 32))
        let asking = row(1, .waiting, needsUser: true, message: "Which database should I use?", changes: changes)
        XCTAssertEqual(AgentRowView.accessibilityText(asking),
                       "Platform › api-server, Which database should I use?, devbox · Claude · Needs you, 128 lines added, 32 removed, in 6 files")
        let finished = row(2, .done, needsUser: false, message: "All tests pass")
        XCTAssertEqual(AgentRowView.accessibilityText(finished, pinned: true),
                       "Platform › api-server, All tests pass, devbox · Claude · Done, Pinned")
        let failed = row(3, .error, needsUser: true, changes: PaneGit.Changes(uncommitted: .init(files: 1)))
        XCTAssertEqual(AgentRowView.accessibilityText(failed), "Platform › api-server, devbox · Claude · Needs you, Error, 1 file changed",
                       "an error that needs the user says both")
        let resolved = row(4, .error, attention: false)
        XCTAssertEqual(AgentRowView.accessibilityText(resolved), "Platform › api-server, devbox · Claude · Error")
        let muted = row(5, .running, attention: nil, muted: true)
        XCTAssertEqual(AgentRowView.accessibilityText(muted), "Platform › api-server, devbox · Claude · Running, Muted")

        XCTAssertEqual(AgentsSection.workingLabel(count: 1), "Working, 1 agent")
        XCTAssertEqual(AgentsSection.workingLabel(count: 12), "Working, 12 agents")
    }
}
