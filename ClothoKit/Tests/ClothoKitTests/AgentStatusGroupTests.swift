import XCTest
@testable import ClothoKit

/// The agent wording both clients share: the three groups, the rewrite's problem caption, and the
/// notification title that says where.
final class AgentStatusGroupTests: XCTestCase {
    private func agent(_ state: AgentInfo.State, attention: Bool? = true, needsUser: Bool? = nil, muted: Bool? = nil,
                       settling: Bool? = nil) -> AgentInfo {
        AgentInfo(kind: "claude", state: state, attention: attention, muted: muted, needsUser: needsUser, settling: settling)
    }

    func testTitles() {
        XCTAssertEqual(AgentStatusGroup.allCases.map(\.title), ["Needs you", "Done", "Working"])
    }

    // MARK: The groups

    func testAttentionGroup() {
        XCTAssertEqual(agent(.waiting, needsUser: true).attentionGroup, .needsYou)
        XCTAssertEqual(agent(.waiting).attentionGroup, .needsYou, "an older daemon's wait")
        XCTAssertEqual(agent(.error, needsUser: true).attentionGroup, .needsYou)
        XCTAssertEqual(agent(.error, needsUser: false).attentionGroup, .needsYou)
        XCTAssertEqual(agent(.done, needsUser: true).attentionGroup, .needsYou, "a finished turn that asks something")
        XCTAssertEqual(agent(.done, needsUser: false).attentionGroup, .done)
        XCTAssertEqual(agent(.done).attentionGroup, .done, "an older daemon's done")
        XCTAssertEqual(agent(.running).attentionGroup, .needsYou, "a bell while it runs")
        // Without attention, settling or muted: in neither.
        XCTAssertNil(agent(.done, attention: false, needsUser: true).attentionGroup, "resolved")
        XCTAssertNil(agent(.waiting, attention: nil).attentionGroup)
        XCTAssertNil(agent(.done, attention: true, needsUser: true, settling: true).attentionGroup, "settling")
        XCTAssertNil(agent(.done, attention: false, settling: true).attentionGroup, "settling")
        XCTAssertNil(agent(.waiting, needsUser: true, muted: true).attentionGroup, "muted")
        XCTAssertNil(agent(.done, needsUser: false, muted: true).attentionGroup, "muted")
    }

    /// Over every state, `needsUser`, attention, mute and settle: the list rule puts everything outside
    /// the attention groups in Working, the active rule only what runs or starts.
    func testTheThreeRulesOverTheTable() {
        let states: [AgentInfo.State] = [.waiting, .running, .starting, .done, .error, .unknown]
        var checked = 0
        for state in states {
            for needsUser in [true, false, nil] as [Bool?] {
                for attention in [true, false, nil] as [Bool?] {
                    for muted in [true, nil] as [Bool?] {
                        for settling in [true, nil] as [Bool?] {
                            let info = agent(state, attention: attention, needsUser: needsUser, muted: muted, settling: settling)
                            let name = "\(state) needsUser \(String(describing: needsUser)) attention \(String(describing: attention)) muted \(muted == true) settling \(settling == true)"
                            let raised = attention == true && muted != true && settling != true
                            let attentionGroup: AgentStatusGroup? = !raised ? nil : (state == .done && needsUser != true ? .done : .needsYou)
                            XCTAssertEqual(info.attentionGroup, attentionGroup, name)
                            XCTAssertEqual(info.statusGroup, attentionGroup ?? .working, name)
                            let runs = state == .running || state == .starting
                            XCTAssertEqual(info.activeStatusGroup, attentionGroup ?? (runs ? .working : nil), name)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 6 * 3 * 3 * 2 * 2)
    }

    func testSettlingAndMutedAgents() {
        let settling = agent(.done, attention: true, needsUser: true, settling: true)
        XCTAssertEqual(settling.statusGroup, .working, "the iOS list keeps it under Working")
        XCTAssertNil(settling.activeStatusGroup, "the Mac's inbox doesn't show it")
        let mutedIdle = agent(.waiting, needsUser: true, muted: true)
        XCTAssertEqual(mutedIdle.statusGroup, .working)
        XCTAssertNil(mutedIdle.activeStatusGroup)
        let mutedRunning = agent(.running, attention: nil, muted: true)
        XCTAssertEqual(mutedRunning.statusGroup, .working)
        XCTAssertEqual(mutedRunning.activeStatusGroup, .working, "a muted agent that runs still shows as working")
    }

    // MARK: The rewrite's caption

    func testProblemCaption() {
        func caption(_ state: RewriteHealth.State, _ reason: String? = nil) -> (text: String, failing: Bool)? {
            RewriteHealth(state: state, reason: reason).problemCaption
        }
        XCTAssertNil(caption(.ok))
        XCTAssertNil(caption(.off))
        XCTAssertNil(caption(.unknown))
        XCTAssertNil(caption(.ok, "a stale reason"), "only a failing state shows its reason")

        let missing = caption(.unavailable)
        XCTAssertEqual(missing?.text, "Claude Code wasn't found on this machine")
        XCTAssertEqual(missing?.failing, false)

        let failing = caption(.failing, "claude exited 1")
        XCTAssertEqual(failing?.text, "Not working: claude exited 1")
        XCTAssertEqual(failing?.failing, true)

        XCTAssertEqual(caption(.failing, "claude exited 1:\n  not logged in\t(run  claude)\n")?.text,
                       "Not working: claude exited 1: not logged in (run claude)", "on one line")
        for empty in [nil, "", " \n "] as [String?] {
            let bare = caption(.failing, empty)
            XCTAssertEqual(bare?.text, "Not working")
            XCTAssertEqual(bare?.failing, true)
        }
    }

    // MARK: The title that says where

    func testPlaceTitle() {
        func title(_ state: String, _ needsUser: Bool?, workspace: String? = "Platform", tab: String? = "cargo test") -> String? {
            AgentNotice.placeTitle(state: state, needsUser: needsUser, workspace: workspace, tab: tab)
        }
        // Needs you: the daemon says so, or the agent waits or failed.
        XCTAssertEqual(title("done", true), "Needs you · Platform › cargo test")
        XCTAssertEqual(title("running", true), "Needs you · Platform › cargo test")
        XCTAssertEqual(title("waiting", false), "Needs you · Platform › cargo test")
        XCTAssertEqual(title("error", false), "Needs you · Platform › cargo test")
        // Done: a turn that only finished.
        XCTAssertEqual(title("done", false), "Done · Platform › cargo test")
        // No tab.
        XCTAssertEqual(title("done", true, tab: nil), "Needs you · Platform")
        XCTAssertEqual(title("done", false, tab: ""), "Done · Platform")
        // An older daemon: no such title.
        XCTAssertNil(title("done", nil))
        XCTAssertNil(title("waiting", nil))
        // No workspace.
        XCTAssertNil(title("done", true, workspace: nil))
        XCTAssertNil(title("done", true, workspace: ""))
        // Neither needs the user nor finished.
        XCTAssertNil(title("running", false))
        XCTAssertNil(title("starting", false))
        XCTAssertNil(title("something-new", false))
    }

    func testNoticeWithATab() {
        func notice(_ state: AgentInfo.State, _ needsUser: Bool?, workspace: String? = "Platform", tab: String?) -> AgentNotice {
            AgentNotice(info: AgentInfo(kind: "claude", state: state, message: "Fixed it.", attention: true, needsUser: needsUser),
                        machine: "devbox", workspace: workspace, cwd: "/home/me/api-server", tab: tab)
        }
        XCTAssertEqual(notice(.done, true, tab: "cargo test").title, "Needs you · Platform › cargo test")
        XCTAssertEqual(notice(.waiting, true, tab: "cargo test").title, "Needs you · Platform › cargo test")
        XCTAssertEqual(notice(.done, false, tab: "cargo test").title, "Done · Platform › cargo test")
        // Without a tab: the title as it was.
        XCTAssertEqual(notice(.done, true, tab: nil).title, "Platform · Claude needs you")
        XCTAssertEqual(notice(.done, false, tab: nil).title, "Platform · Claude is done")
        // Where placeTitle has none, a tab changes nothing.
        XCTAssertEqual(notice(.done, nil, tab: "cargo test").title, "Platform · Claude finished", "an older daemon")
        XCTAssertEqual(notice(.done, true, workspace: nil, tab: "cargo test").title, "Claude needs you on devbox", "no workspace")
        XCTAssertEqual(notice(.running, false, tab: "cargo test").title, "Platform · Claude is working")
        // An empty tab name still takes the place's title, without the tab.
        XCTAssertEqual(notice(.done, true, tab: "").title, "Needs you · Platform")
        // Only the title differs.
        for (state, needsUser) in [(.done, true), (.done, false), (.waiting, true), (.done, nil)] as [(AgentInfo.State, Bool?)] {
            let with = notice(state, needsUser, tab: "cargo test"), without = notice(state, needsUser, tab: nil)
            XCTAssertEqual(with.subtitle, without.subtitle)
            XCTAssertEqual(with.body, without.body)
        }
    }

    /// The init from plain fields (a push record's) gives the same as the one from an agent.
    func testThePlainInitWithATab() {
        func plain(tab: String?) -> AgentNotice {
            AgentNotice(kind: "claude", state: "done", machine: "devbox", workspace: "Platform", project: "api-server", duration: 240,
                        result: "Fixed it.", tool: nil, toolInput: nil, needsUser: false, tab: tab)
        }
        XCTAssertEqual(plain(tab: "cargo test").title, "Done · Platform › cargo test")
        XCTAssertEqual(plain(tab: nil).title, "Platform · Claude is done")
        XCTAssertEqual(plain(tab: "cargo test").subtitle, "devbox · api-server · 4m")
        XCTAssertEqual(plain(tab: "cargo test").body, plain(tab: nil).body)
    }
}
