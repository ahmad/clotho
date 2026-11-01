import XCTest

/// The iPhone's three tabs against the Mac's dev clothod, with several agents: five fake ones in one tab's
/// panes (`-FakeAgents YES`: waiting, done, error, running, starting) and a real permission request from
/// Claude Code's hook in another. Agents (light and dark), Machines and Settings are attached as screenshots.
final class TabsUITests: XCTestCase {
    func testTabsAndAgentRows() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's tabs") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 30), "UI tests start on Machines")
        for name in ["Agents", "Machines", "Settings"] { XCTAssertTrue(app.tabBars.buttons[name].exists, "no \(name) tab") }

        // A permission request, from the hook as Claude Code runs it (see PermissionUITests).
        let actions = app.buttons["Pane actions"]
        newWorkspace(app)
        let payload = #"{"hook_event_name":"PermissionRequest","session_id":"ios-tabs-test","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false"},"cwd":"/tmp"}"#
        app.typeText("clear; printf '%s\\n' '\(payload)' > /tmp/cki-ios/tabs-perm.json; /tmp/cki-ios-bin/clothod report --claude-permission < /tmp/cki-ios/tabs-perm.json; echo; echo hook-done\n")
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Five fake agents, one per pane.
        newWorkspace(app)
        for direction in ["Split right", "Split down", "Split right", "Split down"] {
            XCTAssertTrue(actions.waitForExistence(timeout: 10))
            actions.tap()
            app.buttons[direction].tapWhenSettled()
            sleep(1)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Agents: the permission ask on top with its exact command and Allow/Deny, four lines a row.
        app.showTab("Agents")
        let asking = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Allow Bash: npm test -- --watch=false?'")).firstMatch
        XCTAssertTrue(asking.waitForExistence(timeout: 15), "no permission row")
        XCTAssertTrue(asking.label.contains("Local Mac (dev)"), asking.label)
        XCTAssertTrue(asking.label.contains("Claude"), asking.label)
        XCTAssertTrue(asking.label.contains("Needs you"), asking.label)
        XCTAssertTrue(app.buttons["allowRequest"].exists)
        XCTAssertTrue(app.buttons["denyRequest"].exists)
        XCTAssertFalse(app.buttons["Resolve"].exists, "a Resolve button shows on the row")
        let badge = app.tabBars.buttons["Agents"].value as? String ?? ""
        XCTAssertFalse(badge.isEmpty, "no badge on Agents")
        // One muted agent for the screenshots: its bell is crossed out, and it moves under Quiet.
        let erring = app.buttons.matching(NSPredicate(format: "identifier == 'needsYouAgent' AND label CONTAINS 'Error'")).firstMatch
        XCTAssertTrue(erring.waitForExistence(timeout: 5))
        erring.press(forDuration: 1.2)
        app.buttons["Mute"].tapWhenSettled()
        // Under Quiet, which may be below the screen when earlier tests left agents (rows exist once shown).
        let muted = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Muted'")).firstMatch
        let unmute = app.buttons.matching(NSPredicate(format: "identifier == 'muteToggle' AND label == 'Unmute agent'")).firstMatch
        sleep(1)
        reveal(muted, in: app)
        XCTAssertTrue(muted.exists, "no muted row")
        XCTAssertTrue(unmute.exists, "no crossed-out bell on the muted row")
        for _ in 0..<8 where !asking.isHittable { app.swipeDown() }
        sleep(1)
        attach(app, "agents light")

        // Dark, from Settings.
        app.showTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Summarize Agent Messages"].exists || app.staticTexts["SUMMARIZE AGENT MESSAGES"].exists)
        attach(app, "settings light")
        choose(app, "Dark")
        attach(app, "settings dark")
        app.showTab("Agents")
        sleep(1)
        attach(app, "agents dark")
        app.showTab("Machines")
        attach(app, "machines dark")
        app.showTab("Settings")
        choose(app, "System")
        app.showTab("Machines")
        sleep(1)
        attach(app, "machines light")

        // Clean up: unmute, answer the request (the hook ends), then close both tabs from their agents' rows (a pane
        // without a real agent shows a fake one).
        app.showTab("Agents")
        let place = asking.label.components(separatedBy: ", ").first ?? ""
        reveal(unmute, in: app)
        unmute.tap()
        XCTAssertTrue(muted.waitForNonExistence(timeout: 5))
        for _ in 0..<8 where !app.buttons["denyRequest"].isHittable { app.swipeDown() }
        app.buttons["denyRequest"].tap()
        XCTAssertTrue(app.buttons["denyRequest"].waitForNonExistence(timeout: 10))
        // The fake agents' workspace was made right after the permission one: "Workspace N+1".
        let number = Int(place.split(separator: " ").dropFirst().first ?? "") ?? 0
        let running = "Workspace \(number + 1) ›"
        let rows = app.buttons.matching(NSPredicate(format: "identifier IN {'needsYouAgent', 'quietAgent'}"))
        for predicate in [NSPredicate(format: "label CONTAINS 'Running' AND label BEGINSWITH %@", running),
                          NSPredicate(format: "label BEGINSWITH %@", place)] {
            let row = rows.matching(predicate).firstMatch
            reveal(row, in: app)
            guard row.exists else { continue }
            row.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 10))
            actions.tap()
            app.buttons["Close tab"].tapWhenSettled()
            XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        }
    }

    /// Scrolls down, then up, until `element` is on screen (a List builds rows only once they're on screen).
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<20 where !(element.exists && element.isHittable) { app.swipeDown() }
    }

    private func newWorkspace(_ app: XCUIApplication) {
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 30))
        sleep(2)
    }

    private func choose(_ app: XCUIApplication, _ appearance: String) {
        app.buttons["appearancePicker"].tap()
        app.buttons[appearance].tapWhenSettled()
        sleep(1)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
