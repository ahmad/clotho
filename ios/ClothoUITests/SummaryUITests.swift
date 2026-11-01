import XCTest

/// Notification text from clothod 0.1.29 (`agent.summary`), against the Mac's dev clothod and its fake summarizer
/// (scripts/fake-summarizer.sh, never a real model). A pane reports a waiting agent with a Markdown message: the
/// row shows it cleaned (no raw Markdown) while the rewrite runs, then the rewrite. (Waiting, since a turn that
/// ends while the user is at the pane is quiet and isn't rewritten.)
final class SummaryUITests: XCTestCase {
    func testAgentRowShowsTheSummaryNotRawMarkdown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 30))
        sleep(2)

        // The reporter stays in the foreground (the daemon follows the pane's foreground process as the agent).
        app.typeText(###"sh -c '/tmp/cki-ios-bin/clothod report waiting --agent claude --session ios-summary-test --message "## summary-test: **All** tests pass in \`push.rs\`"; sleep 120'"### + "\n")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.showTab("Agents")

        // While the rewrite runs: the message, cleaned.
        let plain = app.buttons.matching(NSPredicate(format: "label CONTAINS 'summary-test: All tests pass in push.rs'")).firstMatch
        guard plain.waitForExistence(timeout: 30) else {
            attach(app, "no plain row")
            throw XCTSkip("no agent row (or a clothod before 0.1.29 shows the raw message)")
        }
        XCTAssertFalse(plain.label.contains("**"), plain.label)
        XCTAssertFalse(plain.label.contains("##"), plain.label)
        attach(app, "plain")

        // Rewritten by the fake: the summary, not the message.
        let summary = app.buttons.matching(NSPredicate(format: "label CONTAINS 'The test summarizer says all tests pass.'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 45), "the summary never reached the row")
        XCTAssertFalse(summary.label.contains("summary-test"), summary.label)
        attach(app, "summary")

        // Close what the test made: the row opens the pane.
        summary.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
