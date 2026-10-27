import XCTest

/// The Agents list on fake agent states (`-FakeAgents YES`) against the Mac's clothod: agents appear on the
/// home screen, waiting first, and tapping one opens its pane.
final class AgentsUITests: XCTestCase {
    func testAgentsListOpensPane() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Split right"].tap()
        sleep(1)
        actions.tap()
        app.buttons["Split down"].tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.staticTexts["Agents"].waitForExistence(timeout: 5))
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Waiting'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        attach(app, "agents")
        first.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        attach(app, "opened")
        actions.tap()
        app.buttons["Close tab"].tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
