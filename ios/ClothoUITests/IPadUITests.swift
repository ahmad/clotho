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

    /// The sidebar's agents, with fake ones (`-FakeAgents YES`): the same three groups as the iPhone's Agents tab,
    /// in order, with Working folded until its header is tapped.
    /// (Named to run after testSidebarDetailAndQuickOpen, which counts the sidebar's workspaces: closing a tab
    /// leaves its empty workspace there.)
    func testSidebarShowsAgentGroups() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("needs an iPad simulator") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()

        // Ten fake agents in two tabs: every state twice, and the two finished ones on an even and an odd pane, so
        // one is under Done and one under Needs you.
        let overview = app.buttons.containing(.staticText, identifier: "Overview").firstMatch
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        let actions = app.buttons["Pane actions"].firstMatch
        for _ in 0..<2 {
            XCTAssertTrue(overview.waitForExistence(timeout: 30), "no Overview in the sidebar")
            overview.tap()
            wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
            newWorkspace.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 10), "the new tab didn't open beside the sidebar")
            sleep(2)
            for direction in ["Split right", "Split down", "Split right", "Split down"] {
                XCTAssertTrue(actions.waitForExistence(timeout: 10))
                actions.tap()
                app.buttons[direction].tapWhenSettled()
                sleep(1)
            }
        }

        // The keyboard away, so the sidebar has its whole height.
        let hide = app.buttons["keyboard.chevron.compact.down"].firstMatch
        if hide.exists { hide.tap(); sleep(1) }

        // The headers, down the sidebar: Needs you, Done, Working.
        let needsYou = app.staticTexts["Needs you"].firstMatch
        let done = app.staticTexts["Done"].firstMatch
        let working = app.buttons["workingGroup"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 10), "no Needs you group in the sidebar")
        attach(app, "sidebar groups")
        for _ in 0..<3 where !done.exists { swipeSidebar(app, up: true) }
        XCTAssertTrue(done.exists, "no Done group below Needs you")
        if needsYou.exists { XCTAssertLessThan(needsYou.frame.minY, done.frame.minY, "Done is above Needs you") }
        for _ in 0..<3 where !(working.exists && working.isHittable) { swipeSidebar(app, up: true) }
        XCTAssertTrue(working.exists, "no Working group below Done")
        if done.exists { XCTAssertLessThan(done.frame.minY, working.frame.minY, "Working is above Done") }

        // Working opens and folds from its header, here too.
        let before = working.value as? String
        XCTAssertTrue(["collapsed", "expanded"].contains(before ?? ""), "the Working header says \(before ?? "nothing")")
        XCTAssertTrue(working.label.hasPrefix("Working, "), working.label)
        XCTAssertGreaterThanOrEqual(working.frame.height, 43.5, "the Working header is too small to tap")
        attach(app, "sidebar working \(before ?? "")")
        working.tap()
        let other = before == "collapsed" ? "expanded" : "collapsed"
        wait(for: [expectation(for: NSPredicate(format: "value == %@", other), evaluatedWith: working)], timeout: 5)
        attach(app, "sidebar working \(other)")
        if other == "expanded" {
            working.tap()
            wait(for: [expectation(for: NSPredicate(format: "value == 'collapsed'"), evaluatedWith: working)], timeout: 5)
        }
        for _ in 0..<3 where !needsYou.exists { swipeSidebar(app, up: false) }

        // Close both tabs: each has one waiting agent, whose row opens its pane.
        let waiting = app.buttons.matching(NSPredicate(format: "identifier == 'needsYouAgent' AND label CONTAINS 'cargo test --release'"))
        for _ in 0..<2 {
            let row = waiting.firstMatch
            guard row.waitForExistence(timeout: 5) else { break }
            row.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 10), "the agent's row didn't open its pane")
            sleep(1)
            actions.tap()
            app.buttons["Close tab"].tapWhenSettled()
            sleep(2)
        }
        XCTAssertFalse(waiting.firstMatch.exists, "a fake agent's tab is still open")
        XCUIDevice.shared.orientation = .portrait
    }

    /// A swipe inside the sidebar, which is the window's leading quarter in landscape.
    private func swipeSidebar(_ app: XCUIApplication, up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: up ? 0.7 : 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: up ? 0.3 : 0.7))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
