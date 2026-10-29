import XCTest
@testable import Clotho

/// The offer to restart shells that run outside the login session says what's wrong, and the confirmation
/// says the shells end and the layout and agents come back.
@MainActor
final class ShellRestartTests: XCTestCase {
    func testNoticeNamesTheMachines() {
        XCTAssertEqual(AppDelegate.shellRestartNotice(["macbook"]),
                       "Shells on macbook can't reach some system services (DNS, the keychain). Restarting them fixes it; your workspaces and agents come back.")
        XCTAssertTrue(AppDelegate.shellRestartNotice(["devbox", "macbook", "imac"]).hasPrefix("Shells on devbox, macbook and imac "))
    }

    func testConfirmationSaysWhatEndsAndWhatComesBack() {
        let one = AppDelegate.shellRestartConfirmation(["macbook"])
        XCTAssertEqual(one.title, "Restart the shells on macbook?")
        XCTAssertTrue(one.text.contains("Every shell and program running in Clotho on macbook ends"))
        XCTAssertTrue(one.text.contains("workspaces, tabs and panes come back"))
        XCTAssertTrue(one.text.contains("Claude Code and Codex conversations resume"))
        XCTAssertTrue(one.text.contains("Scrollback"), "says what doesn't come back")
        XCTAssertEqual(AppDelegate.shellRestartConfirmation(["a", "b"]).title, "Restart the shells on 2 machines?")
    }
}
