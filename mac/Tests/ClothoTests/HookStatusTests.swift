@testable import Clotho
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

    func testIgnoresOtherLines() {
        let (installed, _) = AppDelegate.parseHookStatus("opencode: installed\nwarning: something\n\ncodex:installed")
        XCTAssertEqual(installed, ["codex": true])
    }
}
