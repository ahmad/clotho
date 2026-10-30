import XCTest

/// A pane in a git worktree on the Mac's dev clothod shows "repo · branch · worktree" in a strip under the
/// terminal; outside a repo there's none. (Pull requests need GitHub; GitStripTests renders those.)
final class GitStripUITests: XCTestCase {
    func testPaneInAWorktreeShowsTheStrip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(2)
        let strip = app.descendants(matching: .any)["gitStrip"]
        app.typeText("cd /tmp && clear\n")
        sleep(2)
        XCTAssertFalse(strip.exists, "no strip outside a repo")

        // A repo with a linked worktree, made here and removed at the end.
        app.typeText("rm -rf /tmp/cki-ios-git /tmp/cki-ios-git-wt; git init -q -b main /tmp/cki-ios-git && cd /tmp/cki-ios-git"
                     + " && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init"
                     + " && git worktree add -q -b ios/strip-test /tmp/cki-ios-git-wt && cd /tmp/cki-ios-git-wt && clear\n")
        XCTAssertTrue(strip.waitForExistence(timeout: 30), "no strip in the worktree")
        let summary = app.staticTexts["gitSummary"]
        XCTAssertEqual(summary.label, "cki-ios-git · ios/strip-test · cki-ios-git-wt")
        XCTAssertFalse(app.buttons["gitPullRequest"].exists, "no PR without GitHub")
        attach(app, "git strip in a worktree")

        // Leaving the repo takes it away.
        app.typeText("cd /tmp && rm -rf /tmp/cki-ios-git /tmp/cki-ios-git-wt && clear\n")
        XCTAssertTrue(strip.waitForNonExistence(timeout: 30), "the strip stayed outside the repo")
        app.buttons["Pane actions"].tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
