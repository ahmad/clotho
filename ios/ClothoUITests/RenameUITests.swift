import XCTest

/// Renaming in place against the Mac's dev clothod: the tab from the pane's title (title menu › Rename),
/// then the tab and its workspace from the machine screen's rows.
final class RenameUITests: XCTestCase {
    func testRenameInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"]
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))

        // The tab, from the title: its menu has Rename, which edits the title itself.
        let bar = app.navigationBars.firstMatch
        let title = bar.buttons.element(boundBy: 1)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        let rename = app.buttons["Rename"]
        guard rename.waitForExistence(timeout: 5) else { return XCTFail("no Rename in the title menu:\n\(app.debugDescription)") }
        rename.tap()
        let field = bar.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "from-title\n")
        XCTAssertTrue(app.navigationBars.staticTexts["from-title"].waitForExistence(timeout: 10)
                      || app.navigationBars.buttons["from-title"].waitForExistence(timeout: 1), "tab not renamed from the title")

        // Back on the machine screen: the tab row's context menu edits the row in place.
        bar.buttons.element(boundBy: 0).tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "from-title")).firstMatch
        // The new workspace is last; earlier tests' workspaces may push it below the screen.
        // Hittable isn't enough: a row clipped by the bottom edge takes the press near the home indicator,
        // which opens no menu. Scroll until the whole row is well inside the window.
        let bottom = app.windows.firstMatch.frame.maxY - 60
        for _ in 0..<8 where !row.waitForExistence(timeout: 2) || !row.isHittable || row.frame.maxY > bottom { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        app.buttons["Rename"].tap()
        let inline = app.textFields["renameField"]
        XCTAssertTrue(inline.waitForExistence(timeout: 5))
        inline.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "from-row\n")
        let renamedRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "from-row")).firstMatch
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 10), "tab not renamed from its row")

        // Close what the test made.
        renamedRow.swipeLeft()
        app.buttons["Close"].tap()
    }
}
