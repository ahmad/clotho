import XCTest

/// I1 against the Mac's clothod (simulator only): open the local machine, make a workspace, type,
/// background the app, come back, and check the pane resumed (live or replay) instead of reloading.
/// Start the daemon first: `clothod start --runtime-dir /tmp/cki-ios`.
final class ResumeUITests: XCTestCase {
    func testTypeBackgroundAndResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()

        let newWorkspace = app.buttons["New Workspace"]
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)
        wait(for: [enabled], timeout: 10)
        newWorkspace.tap()

        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(2)
        app.typeText("echo ios-$((6*7))\n")
        sleep(1)
        attach(app, "typed")

        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        let mode = app.staticTexts["resumeMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "no resubscribe after returning")
        XCTAssertTrue(["live", "replay"].contains(mode.label), "resumed with \(mode.label)")
        app.typeText("echo back-$((6*7))\n")
        sleep(1)
        attach(app, "resumed")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
