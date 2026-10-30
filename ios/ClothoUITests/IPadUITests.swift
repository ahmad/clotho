import XCTest

/// The regular-width layout on an iPad simulator, against the Mac's clothod: the sidebar lists the machine and
/// its tabs, the detail shows the selection, and quick open jumps to a workspace. Skipped on an iPhone.
final class IPadUITests: XCTestCase {
    func testSidebarDetailAndQuickOpen() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("needs an iPad simulator") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()

        let overview = app.buttons.containing(.staticText, identifier: "Overview").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10), "no sidebar")
        XCTAssertTrue(app.staticTexts["Choose a tab"].exists, "no empty detail")
        attach(app, "sidebar")
        overview.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        let current = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ', current'"))
        let before = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Workspace '")).count
        newWorkspace.tap()

        // The new tab opens in the detail column, next to the sidebar.
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the new tab didn't open beside the sidebar")
        XCTAssertTrue(overview.isHittable, "the sidebar went away")
        sleep(2)
        app.typeText("echo ipad-$((6*7))\n")
        sleep(1)
        attach(app, "tab beside sidebar")
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Workspace '")).count, before - 1)
        let name = current.firstMatch.label.replacingOccurrences(of: ", current", with: "")
        XCTAssertTrue(name.hasPrefix("Workspace "), "current workspace: \(name)")

        // Back to the overview, then quick open finds the workspace by name.
        overview.tap()
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 5))
        app.buttons["Quick Open"].firstMatch.tap()
        let search = app.textFields["quickOpenField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(name)
        let hit = app.buttons.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "quick open didn't find \(name)")
        attach(app, "quick open")
        search.typeText("\n")
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "Return didn't open the workspace")

        actions.tap()
        let close = app.buttons["Close tab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        attach(app, "pane menu")
        close.tapWhenSettled()
        sleep(1)
        attach(app, "after close tab")
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10), "closing the tab didn't go back to the machine")
        XCUIDevice.shared.orientation = .portrait
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
