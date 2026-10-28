import XCTest

/// The Agents list on fake agent states (`-FakeAgents YES`) against the Mac's clothod: agents appear on the
/// home screen, waiting first, and tapping one opens its pane.
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
            actions.tap()
            app.buttons[direction].tap()
            sleep(1)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.staticTexts["Agents"].waitForExistence(timeout: 5))
        // Waiting, done and error need the user; running and starting have no attention, so they start under Quiet.
        let waiting = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Waiting'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        let quiet = app.descendants(matching: .any).matching(identifier: "quietAgents").firstMatch
        XCTAssertTrue(quiet.waitForExistence(timeout: 5), "no Quiet group")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Running'")).firstMatch.exists, "Quiet starts folded")
        attach(app, "agents")

        // Resolve the lowest agent on top (a finished one): it leaves the top for Quiet. Other tests' panes may
        // be fake agents too, so count relative to what's there.
        let resolveButtons = app.buttons.matching(identifier: "Resolve")
        let onTop = resolveButtons.count
        XCTAssertGreaterThanOrEqual(onTop, 2, "waiting and done need the user")
        let doneOnTop = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Done'")).count
        resolveButtons.element(boundBy: onTop - 1).tap()
        let resolved = expectation(for: NSPredicate(format: "count == %d", onTop - 1), evaluatedWith: resolveButtons)
        wait(for: [resolved], timeout: 5)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Done'")).count, doneOnTop - 1)
        quiet.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Done'")).firstMatch.waitForExistence(timeout: 5),
                      "the resolved agent isn't under Quiet")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Running'")).firstMatch.exists)
        attach(app, "resolved")

        // Mute the waiting agent: it leaves the top for Quiet, marked muted. Unmute takes the mark away.
        let topBeforeMute = resolveButtons.count
        waiting.press(forDuration: 1.2)
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 3), "no Mute in the agent's menu")
        mute.tap()
        wait(for: [expectation(for: NSPredicate(format: "count == %d", topBeforeMute - 1), evaluatedWith: resolveButtons)], timeout: 5)
        let muted = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Muted'")).firstMatch
        XCTAssertTrue(muted.waitForExistence(timeout: 5), "the muted agent isn't marked under Quiet")
        attach(app, "muted")
        muted.press(forDuration: 1.2)
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 3), "no Unmute on a muted agent")
        unmute.tap()
        XCTAssertTrue(muted.waitForNonExistence(timeout: 5), "still marked muted after Unmute")

        // Opening an agent never resolves it: back on the list it's still on top with its Resolve.
        let stillOnTop = resolveButtons.count
        waiting.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        attach(app, "opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the opened agent left the top")
        sleep(1)
        XCTAssertEqual(resolveButtons.count, stillOnTop, "opening an agent resolved it")
        waiting.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
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
