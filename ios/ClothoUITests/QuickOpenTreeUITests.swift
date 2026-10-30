import XCTest

/// Quick open with nothing typed is a tree (as the Mac's ⌘P): from Home, with two machines, it opens on the
/// machine list; a machine's chevron shows its workspaces, the current one open to its tabs; a tap on a
/// workspace opens its tab; a swipe closes a tab. Against the Mac's clothod, plus a machine nothing answers on.
final class QuickOpenTreeUITests: XCTestCase {
    func testTreeOpensClosesAndGoes() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's Home") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UnreachableMachine", "YES"]
        app.launch()

        // A workspace of our own, which becomes the machine's current one.
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(2)
        app.typeText("echo tree-$((6*7))\n")
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // From Home, with two machines: the machine list.
        app.buttons["Quick Open"].firstMatch.tap()
        let local = row(app, "Local Mac (dev)")
        XCTAssertTrue(local.waitForExistence(timeout: 10), "no machine list")
        XCTAssertTrue(row(app, "Away (test)").exists)
        XCTAssertTrue(app.staticTexts["Machines"].exists)
        attach(app, "machines")

        // The chevron shows its workspaces; the current one (ours) is open to its tab.
        app.buttons["Expand Local Mac (dev)"].tap()
        let current = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND label BEGINSWITH 'Workspace ' AND label ENDSWITH ', expanded'")).firstMatch
        // Earlier tests' workspaces may push it below the screen (the list only builds the rows in view).
        scroll(app, to: current)
        XCTAssertTrue(current.waitForExistence(timeout: 5), "the current workspace isn't open")
        let name = current.label.replacingOccurrences(of: ", expanded", with: "")
        attach(app, "machine open")

        // Its chevron closes it and opens it again.
        scroll(app, to: app.buttons["Collapse \(name)"])
        app.buttons["Collapse \(name)"].tap()
        XCTAssertTrue(row(app, "\(name), collapsed").waitForExistence(timeout: 3))
        app.buttons["Expand \(name)"].tap()
        XCTAssertTrue(row(app, "\(name), expanded").waitForExistence(timeout: 3))

        // A tap on the workspace opens its tab.
        row(app, "\(name), expanded").tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the workspace's tab didn't open")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A swipe on its tab closes it (and with it the workspace).
        app.buttons["Quick Open"].firstMatch.tap()
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        local.tap()
        let workspace = row(app, "\(name), expanded")
        scroll(app, to: workspace)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "a tap on the machine didn't open it")
        // Only the current workspace is open, so the one tab row is its tab.
        let tabRow = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND value == 'tab'")).firstMatch
        scroll(app, to: tabRow)
        tabRow.swipeLeft()
        app.buttons["Close Tab"].tapWhenSettled()
        XCTAssertTrue(workspace.waitForNonExistence(timeout: 10), "closing its only tab didn't close the workspace")
        attach(app, "after close")
        app.buttons["Cancel"].tap()
    }

    /// With a keyboard (the iPad's, here): ← closes the current workspace and goes up to the machine list, →
    /// opens a machine, ↓ moves, Return opens.
    func testArrowKeysWalkTheTree() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("needs an iPad simulator (a hardware keyboard)") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UnreachableMachine", "YES"]
        app.launch()
        let overview = app.buttons.containing(.staticText, identifier: "Overview").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        overview.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))

        // On a tab, quick open starts at it: its workspace open, the tab selected.
        app.buttons["Quick Open"].firstMatch.tap()
        let field = app.textFields["quickOpenField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let current = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND label BEGINSWITH 'Workspace ' AND label ENDSWITH ', expanded'")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5), "the current workspace isn't open")
        let name = current.label.replacingOccurrences(of: ", expanded", with: "")
        let selected = app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND selected == true")).firstMatch
        attach(app, "keys start")

        // ← from the tab: its workspace, closed.
        field.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(row(app, "\(name), collapsed").waitForExistence(timeout: 3), "← didn't close the workspace")
        XCTAssertEqual(selected.label, "\(name), collapsed")
        // ← again: up to the machines, this one selected.
        field.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Machines"].waitForExistence(timeout: 3), "← didn't go up to the machines")
        XCTAssertTrue(selected.label.hasPrefix("Local Mac (dev)"))
        // →: the machine opens; ↓ moves to its first workspace; Return opens it.
        field.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(row(app, "Local Mac (dev), expanded").waitForExistence(timeout: 3), "→ didn't open the machine")
        attach(app, "keys machines")
        field.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(selected.label.hasPrefix("Workspace "), "↓ didn't move to a workspace: \(selected.label)")
        // Earlier tests leave workspaces before ours: ↓ on to it.
        for _ in 0..<12 where !selected.label.hasPrefix(name + ",") { field.typeKey(.downArrow, modifierFlags: []) }
        XCTAssertTrue(selected.label.hasPrefix(name + ","), "↓ never reached \(name): \(selected.label)")
        // Return as typed text: XCUITest's typeKey(.return) reaches neither key commands nor the field.
        field.typeText("\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Return didn't open the workspace")
        // The sheet goes first, then the tab shows.
        sleep(2)
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the workspace's tab didn't show")

        // Typing searches; Tab leaves the search at that row, in the tree.
        app.buttons["Quick Open"].firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        field.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(row(app, "\(name), expanded").waitForExistence(timeout: 3), "Tab didn't leave the search at the workspace")
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "Tab clears the search")
        // (Esc closes it too, but XCUITest's typeKey(.escape) doesn't reach the app, like its .return.)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    /// Scrolls the list (not the keyboard) up until `element` is on screen.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            list.swipeUp(velocity: .slow)
        }
    }

    private func row(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'treeRow' AND (label == %@ OR label BEGINSWITH %@)", label, label + ",")).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
