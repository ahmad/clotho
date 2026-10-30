import XCTest

/// Phase 5: pinching the terminal changes the text size once, at the end of the pinch (the pane's menu shows it).
/// Two-finger swipes between tabs can't be driven from XCUITest (it has no multi-finger swipe); that's a device check.
final class TerminalGesturesUITests: XCTestCase {
    func testPinchZoomsTheText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(2)
        app.typeText("printf 'zoom test %s\\n' $((6*7))\n")
        sleep(1)

        let before = try size(app, actions)
        // Pinch out over the terminal (the middle of the window), keyboard down so it lands on the text.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        app.windows.firstMatch.pinch(withScale: 1.8, velocity: 1)
        sleep(1)
        attach(app, "after pinch")
        let after = try size(app, actions)
        XCTAssertGreaterThan(after, before, "a pinch out didn't make the text bigger")

        // Back to the size other tests expect.
        // Back to the size other tests expect, reading it each time (a tap can miss while a menu animates).
        var current = after
        for _ in 0..<30 where current != before {
            actions.tap()
            let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Text size'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tapWhenSettled()
            let step = app.buttons[current > before ? "Smaller" : "Larger"]
            if step.waitForExistence(timeout: 3) { step.tap() }
            sleep(1)
            current = try size(app, actions)
        }
        XCTAssertEqual(current, before)

        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    /// The size in the pane menu's "Text size · 13 pt", read with the menu open, then closed again.
    private func size(_ app: XCUIApplication, _ actions: XCUIElement) throws -> Int {
        actions.tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Text size'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        let digits = item.label.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
        // Close the menu without choosing anything: a tap on the terminal left of the menu. (Not near the bottom: since
        // iOS 27 a tap on the software keyboard types there and leaves the menu open.)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45)).tap()
        sleep(1)
        return try XCTUnwrap(digits, "no size in \"\(item.label)\"")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
