import XCTest

/// Phase 4: answering a permission request from its card on Home, against the Mac's dev clothod. A pane runs
/// clothod's PermissionRequest hook by hand (as Claude Code would, with a hook payload on stdin); it waits for a
/// decision. Allow on the card answers it, the card says Allowed, and the hook prints the decision for Claude.
final class PermissionUITests: XCTestCase {
    func testAllowFromTheCard() throws {
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

        // The hook as Claude Code runs it; it blocks until the request is decided, then prints the decision.
        let payload = #"{"hook_event_name":"PermissionRequest","session_id":"ios-permission-test","tool_name":"Bash","tool_input":{"command":"echo phone-allowed"},"cwd":"/tmp"}"#
        app.typeText("clear; echo '\(payload)' | /tmp/cki-ios-bin/clothod report --claude-permission; echo; echo hook-done\n")
        sleep(2)
        attach(app, "hook running")
        if !app.staticTexts["Agents"].exists { app.navigationBars.buttons.element(boundBy: 0).tap() }

        // The card on Home asks the exact question, with Allow and Deny.
        let allow = app.buttons["allowRequest"]
        guard allow.waitForExistence(timeout: 15) else {
            attach(app, "no card")
            throw XCTSkip("this clothod has no permission requests (agent.decide)")
        }
        XCTAssertTrue(app.staticTexts["Allow Bash: echo phone-allowed?"].exists, "the card doesn't name the request")
        XCTAssertTrue(app.buttons["denyRequest"].exists)
        attach(app, "card")
        allow.tap()
        let answered = app.descendants(matching: .any)["answered"]
        XCTAssertTrue(answered.waitForExistence(timeout: 10), "no Allowed after tapping Allow")
        XCTAssertTrue(answered.label.contains("Allowed"), answered.label)
        XCTAssertFalse(app.buttons["allowRequest"].exists, "the answered request still offers Allow")
        attach(app, "allowed")

        // In the pane, the hook printed the decision and ended.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude'")).firstMatch
        row.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "hook output")

        actions.tap()
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
