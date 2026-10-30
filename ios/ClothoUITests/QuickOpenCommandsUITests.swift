import XCTest

/// Quick open's ">" commands (the Mac's ⌘P phase 2), against the Mac's clothod: a row's long press offers
/// its commands; Rename asks for a name; Move Tab picks a workspace in the tree; Appearance switches the app.
final class QuickOpenCommandsUITests: XCTestCase {
    func testRenameMoveAndAppearance() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's Home") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()

        // Two workspaces of our own; the second (with its tab) is the current one.
        newWorkspace(app)
        newWorkspace(app)

        // Rename the current tab, from its row's long press.
        openQuickOpen(app)
        let tabRow = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND value == 'tab'")).firstMatch
        XCTAssertTrue(tabRow.waitForExistence(timeout: 10), "the current tab isn't in the tree")
        let from = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND value == 'workspace' AND label ENDSWITH ', expanded'")).firstMatch.label
            .replacingOccurrences(of: ", expanded", with: "")
        tabRow.press(forDuration: 1.0)
        app.buttons["Commands…"].tapWhenSettled()
        let field = app.textFields["quickOpenField"]
        field.typeAtEnd("rename")
        let rename = app.buttons.matching(NSPredicate(format: "identifier == 'command' AND label BEGINSWITH 'Rename Tab'")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename Tab command")
        attach(app, "commands")
        rename.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Rename didn't ask for a name")
        let name = alert.textFields.firstMatch
        name.clearAndType("cmd-test-tab")
        alert.buttons["Rename"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "quick open didn't close after renaming")

        // Move it to another workspace: pick one in the tree.
        openQuickOpen(app)
        let renamed = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND label == 'cmd-test-tab'")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "the rename didn't reach the tree")
        renamed.press(forDuration: 1.0)
        app.buttons["Commands…"].tapWhenSettled()
        field.typeAtEnd("move")
        let move = app.buttons.matching(NSPredicate(format: "identifier == 'command' AND label BEGINSWITH 'Move Tab'")).firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 5), "no Move Tab command")
        move.tap()
        XCTAssertTrue(app.buttons["cancelPick"].waitForExistence(timeout: 5), "no workspace pick")
        attach(app, "pick a workspace")
        let target = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND value == 'workspace' AND NOT (label BEGINSWITH %@)", from + ",")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let to = target.label.components(separatedBy: ",")[0]
        target.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "picking a workspace didn't move the tab")

        // Search finds it in its new workspace.
        openQuickOpen(app)
        field.typeText("cmd-test-tab")
        let found = app.staticTexts["Local Mac (dev) › \(to)"]
        XCTAssertTrue(found.waitForExistence(timeout: 10), "the tab isn't in \(to)")
        field.clearAndType("")

        // Appearance: Dark, then back to the system's.
        app.buttons["commands"].tap()
        field.typeAtEnd("dark")
        app.buttons.matching(NSPredicate(format: "identifier == 'command' AND label == 'Appearance: Dark'")).firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        openQuickOpen(app)
        sleep(1)
        attach(app, "tree in dark")
        app.buttons["commands"].tap()
        attach(app, "commands in dark")
        field.typeAtEnd("system")
        app.buttons.matching(NSPredicate(format: "identifier == 'command' AND label BEGINSWITH 'Appearance: Match'")).firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        // Close what the test made: the moved tab (its search result opens it).
        openQuickOpen(app)
        field.typeText("cmd-test-tab")
        app.staticTexts["Local Mac (dev) › \(to)"].tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    private func newWorkspace(_ app: XCUIApplication) {
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 30))
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func openQuickOpen(_ app: XCUIApplication) {
        app.buttons["Quick Open"].firstMatch.tap()
        XCTAssertTrue(app.textFields["quickOpenField"].waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCUIElement {
    /// Types after what the field holds (">" from the Commands button), focusing it first if needed.
    func typeAtEnd(_ text: String) {
        if !hasKeyboardFocus { tap() }
        typeText(text)
    }

    private var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }

    /// Replaces a text field's text.
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty, value != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        if !text.isEmpty { typeText(text) }
    }
}
