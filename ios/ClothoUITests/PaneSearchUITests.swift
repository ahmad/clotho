import XCTest

/// Find in pane and agent history against the Mac's dev clothod (0.1.11 or later: `pane.search`,
/// `agent.history`). Skipped against an older clothod.
final class PaneSearchUITests: XCTestCase {
    private func openPane(_ app: XCUIApplication) -> XCUIElement {
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(2)
        return actions
    }

    func testFindInScrollback() throws {
        let app = XCUIApplication()
        let actions = openPane(app)
        // An old match far up the scrollback, 300 lines, and a new one on screen.
        // (Split as nee""dle, so the command line itself isn't a match.)
        app.typeText("clear; echo nee\"\"dle-old; for i in $(seq 1 300); do echo line-$i; done; echo nee\"\"dle-new\n")
        sleep(2)
        actions.tap()
        app.buttons["Find…"].tap()
        let field = app.textFields["findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Update clothod'")).firstMatch.exists {
            throw XCTSkip("this clothod has no pane.search")
        }
        field.typeText("needle")
        let status = app.staticTexts["findStatus"]
        XCTAssertTrue(status.wait(for: \.label, toEqual: "1 of 2", timeout: 10), "status: \(status.label)")
        attach(app, "newest match")
        app.buttons["Older Match"].tap()
        XCTAssertEqual(status.label, "2 of 2")
        sleep(1)
        attach(app, "older match, scrolled up")
        app.buttons["Older Match"].tap()
        XCTAssertEqual(status.label, "1 of 2", "wraps around to the newest")

        // A regular expression: line-100 … line-199.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "^line-1[0-9]{2}$")
        app.buttons["Regular Expression"].tap()
        XCTAssertTrue(status.wait(for: \.label, toEqual: "1 of 100", timeout: 10), "status: \(status.label)")
        field.typeText("(")
        XCTAssertTrue(status.wait(for: \.label, toEqual: "Not a valid pattern", timeout: 10), "status: \(status.label)")
        app.buttons["Done"].tap()
        XCTAssertFalse(field.exists)
        actions.tap()
        app.buttons["Close tab"].tap()
    }

    func testAgentHistory() throws {
        let app = XCUIApplication()
        let actions = openPane(app)
        // A long-lived process reports as an agent's hooks would.
        app.typeText(#"sh -c 'r() { /tmp/cki-ios-bin/clothod report "$1" --agent claude --session ios-history-test --message "$2"; }; r waiting "Allow history test?"; sleep 2; r done "history test done"; sleep 60'"# + "\n")
        sleep(4)
        actions.tap()
        let history = app.buttons["Agent History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Update clothod'")).firstMatch.waitForExistence(timeout: 2) {
            throw XCTSkip("this clothod has no agent.history")
        }
        let asked = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Allow history test?'")).firstMatch
        XCTAssertTrue(asked.waitForExistence(timeout: 10), "no waiting entry")
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'history test done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no done entry")
        // Newest first.
        XCTAssertLessThan(done.frame.minY, asked.frame.minY)
        attach(app, "history")
        app.buttons["Done"].tap()
        app.typeText("\u{03}")
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
