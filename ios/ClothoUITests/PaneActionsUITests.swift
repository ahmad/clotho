import XCTest

/// I2 against the Mac's clothod: split, switch panes from the strip, type in the new pane, new tab, close.
final class PaneActionsUITests: XCTestCase {
    func testSplitSwitchAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()

        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Split down"].tapWhenSettled()

        // Two panes: the strip appears and the new (second) pane is shown.
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '2 '")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        // The shown pane is marked selected in the strip (#6C96B4 fill and underline).
        XCTAssertTrue(second.isSelected, "the shown pane isn't marked selected")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 '")).firstMatch.isSelected)
        sleep(2)
        app.typeText("echo split-$((6*7))\n")
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 '")).firstMatch.tap()
        sleep(1)
        app.typeText("echo first-$((6*7))\n")
        sleep(1)
        attach(app, "split")

        // Back on Home, the new workspace (the last row) opens its tab again, with its two panes.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let workspaces = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Workspace '"))
        XCTAssertTrue(workspaces.firstMatch.waitForExistence(timeout: 10), "no workspace rows on Home")
        let row = workspaces.element(boundBy: workspaces.count - 1)
        // Earlier tests' workspaces may push it below the screen.
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        attach(app, "home")
        row.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))

        actions.tap()
        app.buttons["Close pane"].tapWhenSettled()
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))

        actions.tap()
        // The open menu's item; the machine screen behind has a "New Tab" row too.
        // Settled first: since iOS 27 a tap on an item still animating in is lost (MenuTaps).
        let newTab = app.buttons.matching(identifier: "New Tab")
        _ = newTab.firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        newTab.allElementsBoundByIndex.last { $0.isHittable }?.tapWhenSettled()
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "no pane after New Tab")
        sleep(2)
        attach(app, "new tab")
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
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
