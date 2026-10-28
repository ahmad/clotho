import XCTest

/// Phase 1, saved state, against the Mac's dev clothod: show a pane live, quit, relaunch with connections
/// held back, and the pane opens at once from the saved copy (dimmed, read-only, its last screen), then goes
/// live in place when the connection is let through.
final class SavedStateUITests: XCTestCase {
    func testRelaunchShowsTheSavedPaneThenGoesLive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"]
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(2)
        // A working directory to find the tab by after the relaunch (its row shows it; the shell's prompt
        // would overwrite a title), and colourful output to see in the saved screen.
        app.typeText("mkdir -p /tmp/saved-state-test && cd /tmp/saved-state-test && clear; printf '\\033[1;32msaved screen\\033[0m %s\\n' $((6*7))\n")
        sleep(2)
        attach(app, "live before quitting")
        // Leaving the pane saves its screen; the model is saved a moment after it changes.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(3)
        app.terminate()

        // Relaunch with the connection held for a while: everything comes from the saved copy.
        app.launchArguments = ["-UITesting", "-HoldConnections", "20"]
        app.launch()
        let machine = app.staticTexts["Local Mac (dev)"].firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: 5))
        machine.tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "saved-state-test")).firstMatch
        for _ in 0..<4 where !row.waitForExistence(timeout: 1) || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, "the saved model lists the tab before the machine connects")
        XCTAssertFalse(app.buttons["New Workspace"].isEnabled, "still the saved model")
        row.tap()

        let badge = app.staticTexts["savedBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 3), "the pane opens at once, marked as saved")
        XCTAssertTrue(badge.label.hasPrefix("Last seen"), badge.label)
        XCTAssertFalse(app.staticTexts["noPreview"].exists, "its last screen was saved")
        XCTAssertFalse(app.buttons["Pane actions"].isEnabled, "read-only until live")
        attach(app, "saved")

        // Let through: the badge goes, the pane's own snapshot replaces the saved screen, and actions work.
        XCTAssertTrue(badge.waitForNonExistence(timeout: 30), "never went live")
        let actions = app.buttons["Pane actions"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: actions)], timeout: 10)
        sleep(1)
        attach(app, "live again")

        // Close what the test made.
        app.typeText("cd; rmdir /tmp/saved-state-test\n")
        actions.tap()
        let close = app.buttons["Close tab"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
