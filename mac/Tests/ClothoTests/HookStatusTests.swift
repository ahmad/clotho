@testable import Clotho
import ClothoKit
import XCTest

/// `clothod hooks status` lines, as refreshHookStatus reads them.
final class HookStatusTests: XCTestCase {
    func testPlainStatuses() {
        let (installed, outdated) = AppDelegate.parseHookStatus("claude: installed\ncodex: not installed\n")
        XCTAssertEqual(installed, ["claude": true, "codex": false])
        XCTAssertEqual(outdated, [])
    }

    func testOutdatedIsNotInstalled() {
        let (installed, outdated) = AppDelegate.parseHookStatus("claude: outdated\ncodex: installed")
        XCTAssertEqual(installed, ["claude": false, "codex": true])
        XCTAssertEqual(outdated, ["claude"])
    }

    /// clothod 0.1.17: Codex Computer Use took over `notify` and calls clotho's hook, which still runs.
    func testChainedCountsAsItsStatus() {
        var (installed, outdated) = AppDelegate.parseHookStatus("claude: installed\ncodex: installed (chained)\n")
        XCTAssertEqual(installed, ["claude": true, "codex": true])
        XCTAssertEqual(outdated, [])
        (installed, outdated) = AppDelegate.parseHookStatus("claude: installed\ncodex: outdated (chained)\n")
        XCTAssertEqual(installed["codex"], false)
        XCTAssertEqual(outdated, ["codex"])
    }

    /// Only `<valid name>: <status>` lines count: the name later goes to a command line.
    func testIgnoresLinesThatAreNotAnAgentAndItsStatus() {
        let forty = String(repeating: "a", count: 40)
        let lines = AppDelegate.parseHookLines("""
            warning: something
            my agent: installed
            ../x: installed
            -rf: installed
            \(forty): installed
            Claude: installed

            codex:installed
            gemini: installed; rm -rf
            """)
        XCTAssertEqual(lines.map(\.agent), ["codex"], "a status is exactly one of clothod's words")
        XCTAssertEqual(lines.map(\.state), [.installed])
    }

    /// clothod 0.1.33 prints four agents; they keep its order, each with its own state.
    func testFourLinesInOrder() {
        let lines = AppDelegate.parseHookLines("claude: installed\ncodex: installed (chained)\ngemini: not installed\ncopilot: outdated\n")
        XCTAssertEqual(lines, [
            HookLine(agent: "claude", state: .installed),
            HookLine(agent: "codex", state: .installed, chained: true),
            HookLine(agent: "gemini", state: .notInstalled),
            HookLine(agent: "copilot", state: .outdated),
        ])
        XCTAssertEqual(lines.map(\.caption), ["Installed", "Installed (chained)", "Not installed", "Update available"])
        XCTAssertEqual(AppDelegate.parseHookLines("codex: outdated (chained)"), [HookLine(agent: "codex", state: .outdated, chained: true)])
    }

    /// A later clothod's fifth agent is kept, and an older one's two lines are two rows.
    func testMoreAndFewerAgents() {
        XCTAssertEqual(AppDelegate.parseHookLines("claude: installed\ncodex: installed\ngemini: installed\ncopilot: installed\nopencode: not installed").map(\.agent),
                       ["claude", "codex", "gemini", "copilot", "opencode"])
        XCTAssertEqual(AppDelegate.parseHookLines("claude: installed\ncodex: not installed\n").count, 2)
        XCTAssertEqual(AppDelegate.parseHookLines("claude: installed\nclaude: outdated").count, 1, "an agent is listed once")
    }

    /// The machine menu's item: what there is to do.
    func testTheMenuTitle() {
        let none = [HookLine(agent: "claude", state: .notInstalled), HookLine(agent: "gemini", state: .notInstalled)]
        XCTAssertEqual(AppDelegate.hooksMenuTitle(lines: nil, seenHookAgent: false), "Set Up Agent Status\u{2026}")
        XCTAssertEqual(AppDelegate.hooksMenuTitle(lines: none, seenHookAgent: false), "Set Up Agent Status\u{2026}")
        XCTAssertEqual(AppDelegate.hooksMenuTitle(lines: none, seenHookAgent: true), "Agent Status\u{2026}", "a coding agent already reports through hooks")
        XCTAssertEqual(AppDelegate.hooksMenuTitle(lines: [HookLine(agent: "claude", state: .installed)] + none, seenHookAgent: false), "Agent Status\u{2026}")
        XCTAssertEqual(AppDelegate.hooksMenuTitle(lines: [HookLine(agent: "claude", state: .installed), HookLine(agent: "codex", state: .outdated)],
                                                  seenHookAgent: true), "Update Agent Status\u{2026}")
    }

    /// A script's `clothod report --kind deploy` is hook-sourced, and says nothing of hooks being set up.
    func testOnlyACodingAgentsHooksCount() {
        XCTAssertTrue(AppDelegate.showsHooksAreSetUp(AgentInfo(kind: "claude", state: .running, source: "hook")))
        XCTAssertTrue(AppDelegate.showsHooksAreSetUp(AgentInfo(kind: "gemini", state: .running, source: "hook")))
        XCTAssertFalse(AppDelegate.showsHooksAreSetUp(AgentInfo(kind: "deploy", state: .waiting, source: "hook")))
        XCTAssertFalse(AppDelegate.showsHooksAreSetUp(AgentInfo(kind: "other", state: .waiting, source: "osc")))
        XCTAssertFalse(AppDelegate.showsHooksAreSetUp(AgentInfo(kind: "claude", state: .running, source: "detected")))
    }

    func testThePreviewLeadNamesEachAgentsFile() {
        XCTAssertTrue(AppDelegate.hooksPreviewLead("gemini").contains("~/.gemini/settings.json"))
        XCTAssertTrue(AppDelegate.hooksPreviewLead("copilot").contains("~/.copilot/hooks/clotho.json, a file of Clotho\u{2019}s own"))
        XCTAssertEqual(AppDelegate.hooksPreviewLead("opencode"), "`clothod hooks install opencode` makes these changes:")
    }

    func testOnboardingNamesTheInstalledAgents() {
        XCTAssertEqual(OnboardingController.hooksLine([]), "")
        XCTAssertEqual(OnboardingController.hooksLine(["Claude Code"]), "\u{2713}  Set up for Claude Code")
        XCTAssertEqual(OnboardingController.hooksLine(["Claude Code", "Gemini CLI"]), "\u{2713}  Set up for Claude Code and Gemini CLI")
        XCTAssertEqual(OnboardingController.hooksLine(["Claude Code", "Codex", "Gemini CLI"]), "\u{2713}  Set up for Claude Code, Codex and Gemini CLI")
    }
}
