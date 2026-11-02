import XCTest

/// Pinning agents on the Agents tab, with fake agents (`-FakeAgents YES`) against the Mac's dev clothod: Pin moves an
/// agent into a "Pinned" section on top (not repeated below), a relaunch keeps it, Unpin puts it back, and closing
/// the agent's tab drops the pin.
final class PinUITests: XCTestCase {
    func testPinUnpinRelaunchAndClose() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's Agents tab") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()

        // A new tab: its one pane gets a fake agent.
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30))
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.showTab("Agents")

        // Our agent is the newest row of the newest workspace; find it by its workspace.
        let workspace = newestWorkspace(app)
        let rowButtons = app.buttons.matching(NSPredicate(format: "identifier IN {'needsYouAgent', 'quietAgent'}"))
        let ours = rowButtons.matching(NSPredicate(format: "label BEGINSWITH %@", workspace + " ›")).firstMatch
        reveal(ours, in: app)
        XCTAssertTrue(ours.exists, "no agent row for \(workspace)")
        XCTAssertFalse(ours.label.contains("Pinned"))

        // Pin from the long-press menu: it's in the Pinned section, once, on top.
        ours.press(forDuration: 1.2)
        app.buttons["Pin"].tapWhenSettled()
        let pinned = rowButtons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'Pinned'", workspace + " ›")).firstMatch
        for _ in 0..<10 where !app.staticTexts["Pinned"].exists { app.swipeDown() }
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "the row isn't marked pinned")
        XCTAssertTrue(app.staticTexts["Pinned"].exists, "no Pinned section")
        // (A list row shows up twice in the tree, the cell and its button; the button has the row's identifier.)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier IN {'needsYouAgent', 'quietAgent'} AND label BEGINSWITH %@", workspace + " ›")).count, 1,
                       "a pinned agent shows twice")
        XCTAssertLessThan(app.staticTexts["Pinned"].frame.minY, pinned.frame.minY)
        attach(app, "pinned")

        // A relaunch keeps it.
        app.terminate()
        app.launch()
        app.showTab("Agents")
        XCTAssertTrue(pinned.waitForExistence(timeout: 30), "the pin didn't survive a relaunch")
        XCTAssertTrue(app.staticTexts["Pinned"].exists)

        // Unpin by swiping: back to its own section, no Pinned section left (if nothing else is pinned).
        pinned.swipeRight()
        app.buttons["Unpin"].tapWhenSettled()
        XCTAssertTrue(pinned.waitForNonExistence(timeout: 5), "still pinned after Unpin")
        reveal(ours, in: app)
        XCTAssertTrue(ours.exists)

        // Pin again, then close the tab: the pin goes with it, so a new agent in a reused pane id isn't pinned.
        ours.press(forDuration: 1.2)
        app.buttons["Pin"].tapWhenSettled()
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        pinned.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        XCTAssertTrue(pinned.waitForNonExistence(timeout: 10), "the closed tab's agent is still pinned")
        // The drop is saved: after a relaunch, nothing is pinned for that pane.
        app.terminate()
        app.launch()
        app.showTab("Agents")
        sleep(3)
        XCTAssertFalse(pinned.exists)
        attach(app, "after close")
    }

    /// The last "Workspace N" on Machines' list: the one this test made.
    private func newestWorkspace(_ app: XCUIApplication) -> String {
        app.showTab("Machines")
        // The list is in creation order and builds rows only once shown: scroll to its end first.
        for _ in 0..<12 { app.swipeUp() }
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Workspace '"))
        let names = rows.allElementsBoundByIndex.map { $0.label.components(separatedBy: ",")[0] }
        let newest = names.max { (Int($0.split(separator: " ").last ?? "") ?? 0) < (Int($1.split(separator: " ").last ?? "") ?? 0) } ?? ""
        app.showTab("Agents")
        return newest
    }

    /// Scrolls down, then up, until `element` is on screen (a List builds rows only once they're shown).
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<20 where !(element.exists && element.isHittable) { app.swipeDown() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
