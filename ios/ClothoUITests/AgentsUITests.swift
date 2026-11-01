import XCTest

/// The Agents tab on fake agent states (`-FakeAgents YES`) against the Mac's clothod: agents that need you on
/// top, the rest under Quiet; Resolve and Mute from a swipe and the long-press menu; a row opens its pane, and
/// Back returns to Agents.
final class AgentsUITests: XCTestCase {
    func testAgentsListOpensPane() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        // Five panes in a row: fake agent states cycle through five by pane id, so every state shows,
        // whichever ids earlier tests used up.
        for direction in ["Split right", "Split down", "Split right", "Split down"] {
            XCTAssertTrue(actions.waitForExistence(timeout: 10))
            actions.tap()
            app.buttons[direction].tapWhenSettled()
            sleep(1)
        }
        // Back to Machines, then the Agents tab.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.showTab("Agents")
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))

        // Waiting, done and error need the user ("Needs you", on top); running and starting have no attention,
        // so they're under Quiet. No checkmark buttons on the rows: Resolve is a swipe or the long-press menu.
        let onTop = app.buttons.matching(identifier: "needsYouAgent")
        let quietRows = app.buttons.matching(identifier: "quietAgent")
        let waiting = onTop.matching(NSPredicate(format: "label CONTAINS 'Needs you'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertTrue(quietRows.matching(NSPredicate(format: "label CONTAINS 'Running'")).firstMatch.exists, "running isn't under Quiet")
        XCTAssertFalse(app.buttons["Resolve"].exists, "a Resolve button shows on the row")
        // Line 4 names the machine and the agent.
        XCTAssertTrue(waiting.label.contains("Local Mac (dev)"), waiting.label)
        attach(app, "agents")

        // Resolve the lowest agent on top (a finished one) by swiping: it leaves the top for Quiet. Other tests'
        // panes may be fake agents too, so count relative to what's there.
        let count = onTop.count
        XCTAssertGreaterThanOrEqual(count, 2, "waiting and done need the user")
        let doneOnTop = onTop.matching(NSPredicate(format: "label CONTAINS 'Done'")).count
        let doneQuiet = quietRows.matching(NSPredicate(format: "label CONTAINS 'Done'")).count
        onTop.element(boundBy: count - 1).swipeLeft()
        app.buttons["Resolve"].tapWhenSettled()
        wait(for: [expectation(for: NSPredicate(format: "count == %d", count - 1), evaluatedWith: onTop)], timeout: 5)
        XCTAssertEqual(onTop.matching(NSPredicate(format: "label CONTAINS 'Done'")).count, doneOnTop - 1)
        XCTAssertEqual(quietRows.matching(NSPredicate(format: "label CONTAINS 'Done'")).count, doneQuiet + 1,
                       "the resolved agent isn't under Quiet")
        attach(app, "resolved")

        // Mute the waiting agent from its menu: it leaves the top for Quiet, marked muted. Unmute takes the mark away.
        let topBeforeMute = onTop.count
        waiting.press(forDuration: 1.2)
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 3), "no Mute in the agent's menu")
        XCTAssertTrue(app.buttons["Resolve"].exists, "no Resolve in the agent's menu")
        mute.tapWhenSettled()
        wait(for: [expectation(for: NSPredicate(format: "count == %d", topBeforeMute - 1), evaluatedWith: onTop)], timeout: 5)
        let muted = quietRows.matching(NSPredicate(format: "label CONTAINS 'Muted'")).firstMatch
        XCTAssertTrue(muted.waitForExistence(timeout: 5), "the muted agent isn't marked under Quiet")
        attach(app, "muted")
        muted.press(forDuration: 1.2)
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 3), "no Unmute on a muted agent")
        unmute.tapWhenSettled()
        XCTAssertTrue(muted.waitForNonExistence(timeout: 5), "still marked muted after Unmute")

        // Opening an agent never resolves it, and Back returns to Agents with it still on top.
        let stillOnTop = onTop.count
        waiting.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        attach(app, "opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "Back didn't return to Agents")
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the opened agent left the top")
        sleep(1)
        XCTAssertEqual(onTop.count, stillOnTop, "opening an agent resolved it")
        waiting.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
