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
    ///
    /// Every step waits for what it changed (the pane count, the detail column), not for a fixed time, and the
    /// keyboard is put away before the sidebar is used: with it up, the lower sidebar rows are under it.
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
        for round in 1...2 {
            XCTAssertTrue(overview.waitForExistence(timeout: 30), "no Overview in the sidebar")
            hideKeyboard(app)
            scrollSidebar(app, to: overview)
            overview.tap()
            // The machine's overview has no pane, so a Pane actions button after this is the new tab's.
            XCTAssertTrue(newWorkspace.waitForExistence(timeout: 15), "round \(round): Overview didn't show the machine")
            wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
            XCTAssertTrue(actions.waitForNonExistence(timeout: 10), "round \(round): a pane is still showing beside the Overview")
            newWorkspace.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 30), "round \(round): the new tab didn't open beside the sidebar")
            for (index, direction) in ["Split right", "Split down", "Split right", "Split down"].enumerated() {
                split(app, direction, panes: index + 2, note: "round \(round)")
            }
        }

        // The keyboard away, so the sidebar has its whole height, and the sidebar back at its top.
        hideKeyboard(app)

        // The headers, down the sidebar: Needs you, Done, Working.
        let needsYou = app.staticTexts["Needs you"].firstMatch
        let done = app.staticTexts["Done"].firstMatch
        let working = app.buttons["workingGroup"]
        scrollSidebar(app, to: needsYou, up: false)
        XCTAssertTrue(needsYou.waitForExistence(timeout: 10), "no Needs you group in the sidebar")
        attach(app, "sidebar groups")
        scrollSidebar(app, to: done)
        XCTAssertTrue(done.exists, "no Done group below Needs you")
        if needsYou.exists { XCTAssertLessThan(needsYou.frame.minY, done.frame.minY, "Done is above Needs you") }
        scrollSidebar(app, to: working)
        XCTAssertTrue(working.exists && working.isHittable, "no Working group below Done")
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
            scrollSidebar(app, to: working, up: false)
            working.tap()
            wait(for: [expectation(for: NSPredicate(format: "value == 'collapsed'"), evaluatedWith: working)], timeout: 5)
        }

        // Close both tabs: each has one waiting agent, whose row opens its pane. From the Overview each time, which
        // has no pane: the Pane actions button that then shows is the opened tab's, and it goes when the tab closes.
        let waiting = app.buttons.matching(NSPredicate(format: "identifier == 'needsYouAgent' AND label CONTAINS 'cargo test --release'"))
        for round in 1...2 {
            hideKeyboard(app)
            scrollSidebar(app, to: overview)
            overview.tap()
            XCTAssertTrue(actions.waitForNonExistence(timeout: 10), "close \(round): a pane is still showing beside the Overview")
            let row = waiting.firstMatch
            scrollSidebar(app, to: row, up: false)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "close \(round): no waiting agent in the sidebar")
            let label = row.label
            row.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 15), "close \(round): the agent's row didn't open its pane")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '5 '")).firstMatch.waitForExistence(timeout: 10),
                          "close \(round): the opened tab doesn't have five panes")
            for attempt in 1...3 {
                openMenu(app, item: "Close tab")
                if actions.waitForNonExistence(timeout: 10) { break }
                attach(app, "close \(round), attempt \(attempt): tab still open")
            }
            XCTAssertFalse(actions.exists, "close \(round): Close tab didn't close the tab")
            // The tab's agents leave the sidebar with it.
            let gone = NSPredicate(format: "identifier == 'needsYouAgent' AND label == %@", label)
            XCTAssertTrue(app.buttons.matching(gone).firstMatch.waitForNonExistence(timeout: 10), "close \(round): \(label) is still listed")
        }
        hideKeyboard(app)
        XCTAssertFalse(waiting.firstMatch.exists, "a fake agent's tab is still open")
        XCTAssertFalse(needsYou.exists, "agents are still listed after both tabs closed")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Splits the pane on screen and waits for the tab's strip to count `panes`. A menu tap that didn't take (the
    /// menu was still opening, or closed again) is tried again; a split is only ever asked for while the strip is
    /// one short.
    private func split(_ app: XCUIApplication, _ direction: String, panes: Int, note: String) {
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(panes) ")).firstMatch
        for attempt in 1...3 {
            openMenu(app, item: direction)
            if chip.waitForExistence(timeout: 10) { return }
            attach(app, "\(note), \(direction), attempt \(attempt): still under \(panes) panes")
        }
        XCTFail("\(note): \(direction) didn't make pane \(panes)")
    }

    /// Opens the Pane actions menu and taps one of its items.
    private func openMenu(_ app: XCUIApplication, item name: String) {
        let actions = app.buttons["Pane actions"].firstMatch
        let item = app.buttons[name].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 15), "no Pane actions button for \(name)")
        actions.tap()
        // The first tap can be lost while the pane is still coming in.
        if !item.waitForExistence(timeout: 5) { actions.tap() }
        item.tapWhenSettled()
    }

    /// Puts the software keyboard away, if it is up.
    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["keyboard.chevron.compact.down"].firstMatch
        guard hide.exists, hide.isHittable else { return }
        hide.tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
    }

    /// Swipes the sidebar until the element is there to tap (rows off screen aren't in the list), first one way
    /// and then back the other.
    private func scrollSidebar(_ app: XCUIApplication, to element: XCUIElement, up: Bool = true) {
        for direction in [up, !up] {
            for _ in 0..<4 {
                if element.exists && element.isHittable { return }
                swipeSidebar(app, up: direction)
            }
        }
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
