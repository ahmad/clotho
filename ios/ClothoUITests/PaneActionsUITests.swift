import XCTest

/// I2 against the Mac's clothod: split, switch panes from the strip, type in the new pane, new tab, close.
final class PaneActionsUITests: XCTestCase {
    func testSplitSwitchAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New workspace"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()

        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Split down"].tap()

        // Two panes: the strip appears and the new (second) pane is shown.
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '2 '")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        sleep(2)
        app.typeText("echo split-$((6*7))\n")
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 '")).firstMatch.tap()
        sleep(1)
        app.typeText("echo first-$((6*7))\n")
        sleep(1)
        attach(app, "split")

        actions.tap()
        app.buttons["Close pane"].tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))

        actions.tap()
        app.buttons["New tab"].tap()
        sleep(2)
        attach(app, "new tab")
        actions.tap()
        app.buttons["Close tab"].tap()
        sleep(2)
        attach(app, "closed tab")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
