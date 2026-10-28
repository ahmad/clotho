import XCTest

/// Live `pane` events reach the model: a pane's cwd changes after it exists, which the daemon sends only as
/// a `pane` event (never in the initial state or a request's reply). ClothoKit 44d9daf dropped every such
/// event; this would have caught it.
final class PaneEventsUITests: XCTestCase {
    func testPaneEventUpdatesTheTabRow() throws {
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
        let dir = "clotho-pane-event-\(Int.random(in: 1000...9999))"
        app.typeText("mkdir -p /tmp/\(dir) && cd /tmp/\(dir)\n")
        sleep(1)
        attach(app, "typed")

        // Back on the machine screen, the tab's row shows the new cwd.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", dir)).firstMatch
        var found = false
        for _ in 0..<6 {
            if row.waitForExistence(timeout: 2) { found = true; break }
            app.swipeUp()
        }
        attach(app, "machine screen")
        XCTAssertTrue(found, "the tab row never showed the pane's new cwd: live pane events aren't applied")

        // Close what the test made.
        guard found else { return }
        row.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(1)
        app.typeText("cd; rmdir /tmp/\(dir)\n")
        app.buttons["Pane actions"].tap()
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
