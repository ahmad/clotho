import XCTest

/// Agents of any kind, a program's notification and a pane's progress (clothod 0.1.33), against the Mac's dev
/// clothod: the made-up kinds (`-FakeAgents YES -FakeAgentKinds YES`) for the screenshots, and a real
/// notification and progress typed into a pane (OSC 9 and OSC 9;4), with no fakes.
final class AgentKindsUITests: XCTestCase {
    /// What `-FakeAgentKinds YES` cycles through, as a row's caption names them: the other coding agents by their
    /// short names, and a reporter's own kind as it gave it.
    private static let kindNames = ["Gemini", "OpenCode", "Copilot", "Aider", "Amp", "Cursor", "deploy"]
    /// The made-up notification's text. It reads as typed: no Markdown is taken out of it.
    private static let fakeNotification = "**Build** finished: see [log](http://x)"
    private static let rowIDs = "identifier IN {'needsYouAgent', 'doneAgent', 'quietAgent'}"

    /// Every kind's row, the notification's row with its text as typed and no Reply, and a row with progress.
    /// Screenshots of the list's top and of Working, in light, in dark and at a large text size.
    func testKindsAndProgressScreenshots() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's Agents tab") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES", "-FakeAgentKinds", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 30), "UI tests start on Machines")
        // Three launches and ten panes: more than the default allowance.
        executionTimeAllowance = 480
        // Ten panes in a row, in two tabs. The kinds cycle through eight by pane id, so each shows at least
        // once; a running agent is every fifth pane and every other of those is at 40 percent, so one is.
        let actions = app.buttons["Pane actions"]
        for _ in 0..<2 {
            let newWorkspace = app.buttons["New Workspace"].firstMatch
            XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
            wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
            newWorkspace.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 30))
            sleep(2)
            for direction in ["Split right", "Split down", "Split right", "Split down"] {
                XCTAssertTrue(actions.waitForExistence(timeout: 10))
                actions.tap()
                app.buttons[direction].tapWhenSettled()
                sleep(1)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let newest = newestWorkspace(app)
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: Self.rowIDs))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no agents")
        top(app)
        attach(app, "kinds light")

        // Working open: running and starting agents are in it, whatever their kind.
        app.setWorkingAgents(expanded: true)
        for name in Self.kindNames {
            let row = rows.matching(NSPredicate(format: "label CONTAINS %@", "· \(name) ·")).firstMatch
            app.revealAgent(row)
            XCTAssertTrue(row.exists, "no row says \(name)")
        }

        // A program's notification: its text as typed, under the generic name, and nothing to reply to.
        let notified = NSPredicate(format: "label CONTAINS %@", Self.fakeNotification)
        var notification = rows.matching(notified).firstMatch
        app.revealAgent(notification)
        XCTAssertTrue(notification.exists, "no row shows the notification's text as typed")
        XCTAssertTrue(notification.label.contains("· Agent ·"), notification.label)
        // One that has the daemon's attention when there is one: only those rows could offer Reply at all.
        let raised = app.buttons.matching(NSPredicate(format: "identifier IN {'needsYouAgent', 'doneAgent'}")).matching(notified).firstMatch
        app.revealAgent(raised, swipes: 6)
        if raised.exists { notification = raised } else { app.revealAgent(notification) }
        assertNoReply(app, on: notification)
        attach(app, "kinds notification row")

        // A pane's progress, said on its agent's row.
        let progress = app.buttons.matching(NSPredicate(format: "identifier == 'quietAgent' AND label CONTAINS 'Progress 40 percent'")).firstMatch
        app.revealAgent(progress)
        XCTAssertTrue(progress.exists, "no row says Progress 40 percent")
        XCTAssertTrue(progress.label.contains("Running"), progress.label)
        attach(app, "kinds working light")

        // Dark from Settings (and back to the system's, for later tests).
        app.showTab("Settings")
        choose(app, "Dark")
        app.showTab("Agents")
        top(app)
        attach(app, "kinds dark")
        app.revealAgent(progress)
        attach(app, "kinds working dark")
        app.showTab("Settings")
        choose(app, "System")

        // At a large accessibility text size: the caption, with the kind's symbol in it, wraps.
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        app.showTab("Agents")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "no agents at the large size")
        sleep(1)
        attach(app, "kinds large")
        app.revealAgent(progress, swipes: 20)
        XCTAssertTrue(progress.exists, "no row with progress at the large size")
        attach(app, "kinds working large")

        // Clean up at the usual size: close the two tabs, each from one of its rows, and fold Working again.
        app.terminate()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES", "-FakeAgentKinds", "YES"]
        app.launch()
        app.showTab("Agents")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        app.setWorkingAgents(expanded: true)
        let number = Int(newest.split(separator: " ").last ?? "") ?? 0
        for name in (0..<2).map({ "Workspace \(number - $0)" }) {
            let row = rows.matching(NSPredicate(format: "label BEGINSWITH %@", name + " ›")).firstMatch
            app.revealAgent(row)
            guard row.exists else { continue }
            row.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 10))
            actions.tap()
            app.buttons["Close tab"].tapWhenSettled()
            XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        }
        app.setWorkingAgents(expanded: false)
    }

    /// The iPad's sidebar in landscape: the Agents section with the made-up kinds, and a Tab row with the progress
    /// its pane's program reports (a real OSC 9;4: only agents are made up).
    func testIPadSidebarKinds() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("needs an iPad simulator") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES", "-FakeAgentKinds", "YES"]
        app.launch()

        let overview = app.buttons.containing(.staticText, identifier: "Overview").firstMatch
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        let actions = app.buttons["Pane actions"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 30), "no Overview in the sidebar")
        hideKeyboard(app)
        scrollSidebar(app, to: overview)
        overview.tap()
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 15), "Overview didn't show the machine")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        XCTAssertTrue(actions.waitForNonExistence(timeout: 10), "a pane is still showing beside the Overview")
        newWorkspace.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 30), "the new tab didn't open beside the sidebar")
        sleep(2)
        // The first pane's program says how far it is and keeps running; closing the Tab ends it.
        app.typeText("sh -c 'printf \"\\033]9;4;1;40\\007\"; sleep 300'\n")
        // Five panes, so five of the kinds are in the sidebar.
        for (index, direction) in ["Split right", "Split down", "Split right", "Split down"].enumerated() {
            split(app, direction, panes: index + 2)
        }
        hideKeyboard(app)

        // The Tab's row says its progress (the first pane's).
        let tabRow = app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Progress 40 percent'")).firstMatch
        scrollSidebar(app, to: tabRow, swipes: 12)
        XCTAssertTrue(tabRow.waitForExistence(timeout: 15), "no Tab row with the pane's progress in the sidebar")
        attach(app, "sidebar tab progress")

        // The Agents section: rows of the new kinds.
        let names = Self.kindNames + ["Agent"]
        let kinds = NSCompoundPredicate(orPredicateWithSubpredicates: names.map { NSPredicate(format: "label CONTAINS %@", "· \($0) ·") })
        let kindRow = app.buttons.matching(NSPredicate(format: Self.rowIDs)).matching(kinds).firstMatch
        scrollSidebar(app, to: kindRow, up: false, swipes: 12)
        XCTAssertTrue(kindRow.waitForExistence(timeout: 10), "no agent of the new kinds in the sidebar")
        attach(app, "sidebar kinds")
        let needsYou = app.staticTexts["Needs you"].firstMatch
        scrollSidebar(app, to: needsYou, up: false, swipes: 12)
        attach(app, "sidebar kinds, from Needs you")

        // The tab is still in the detail column: close it, and its agents and progress leave the sidebar.
        for _ in 1...3 {
            openMenu(app, item: "Close tab")
            if actions.waitForNonExistence(timeout: 10) { break }
        }
        XCTAssertFalse(actions.exists, "Close tab didn't close the tab")
        XCTAssertTrue(tabRow.waitForNonExistence(timeout: 10), "the closed Tab's progress is still in the sidebar")
        XCUIDevice.shared.orientation = .portrait
    }

    /// No fakes: a program in a pane reports progress (OSC 9;4) and sends a notification (OSC 9), then keeps
    /// running. The pane screen draws the progress under its navigation bar; the Agents list has a row with the
    /// notification's text as typed and the progress, and no Reply. Resolve takes its attention, and the row
    /// stays, under Working, while the program runs.
    func testRealOscAgentAndProgress() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's Agents tab") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30))
        sleep(2)
        // One program (sh) sends both and keeps running: the progress and the alert are its own, so they last
        // while it runs. (Typed at the prompt, printf would be the shell's, and Resolve would remove the alert.)
        app.typeText("sh -c 'printf \"\\033]9;4;1;40\\007\\033]9;Build **finished**\\007\"; sleep 300'\n")

        // The Tab's progress, right under the navigation bar.
        let strip = app.descendants(matching: .any).matching(identifier: "tabProgress").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "no progress strip on the pane screen (a clothod before 0.1.33?)")
        wait(for: [expectation(for: NSPredicate(format: "value == '40 percent'"), evaluatedWith: strip)], timeout: 10)
        XCTAssertEqual(strip.label, "Progress")
        attach(app, "pane progress")

        // The app's own banner for the notification covers the navigation bar for a moment: let it go.
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'NotificationShortLookView'")).firstMatch
        if banner.waitForExistence(timeout: 4) { _ = banner.waitForNonExistence(timeout: 15) }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.showTab("Agents")
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))

        // Its row is on top, with the text as typed (the asterisks stay) and the progress.
        let text = NSPredicate(format: "label CONTAINS 'Build **finished**'")
        let row = app.buttons.matching(identifier: "needsYouAgent").matching(text).firstMatch
        app.revealAgent(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for the program's notification under Needs you")
        XCTAssertTrue(row.label.contains("· Agent · Needs you"), row.label)
        XCTAssertTrue(row.label.contains("Progress 40 percent"), row.label)
        attach(app, "real notification row")

        // Nobody reads a reply there: no Reply in its menu or in either swipe.
        assertNoReply(app, on: row)

        // Resolve by swiping: the daemon keeps the agent while its program runs, without attention.
        // (Not while Resolve already shows: a second swipe would carry the first one out.)
        for _ in 0..<3 where !app.buttons["Resolve"].exists {
            row.swipeLeft()
            _ = app.buttons["Resolve"].waitForExistence(timeout: 2)
        }
        XCTAssertFalse(app.buttons["Reply"].exists, "Reply beside Resolve on a program's notification")
        app.buttons["Resolve"].tapWhenSettled()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the resolved notification still asks for attention")
        app.setWorkingAgents(expanded: true)
        let resolved = app.buttons.matching(identifier: "quietAgent").matching(text).firstMatch
        app.revealAgent(resolved)
        XCTAssertTrue(resolved.waitForExistence(timeout: 10), "the resolved row left the list while its program runs")
        // The daemon looks at a pane's program once a second: still there after a few looks, and still not on top.
        sleep(4)
        XCTAssertTrue(resolved.exists, "the resolved row left the list while its program runs")
        XCTAssertFalse(row.exists, "the resolved row came back to the top")
        XCTAssertFalse(resolved.label.contains("Needs you"), resolved.label)
        XCTAssertTrue(resolved.label.contains("Progress 40 percent"), resolved.label)
        attach(app, "real notification resolved")

        // Close the Tab (which ends the program), and fold Working again for later tests.
        resolved.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        XCTAssertTrue(resolved.waitForNonExistence(timeout: 10), "the closed Tab's row is still listed")
        app.setWorkingAgents(expanded: false)
    }

    // MARK: Reply

    /// No Reply on the row: for a row that has the daemon's attention not in its long-press menu, and for any row
    /// not in the swipe from its leading edge (where Reply goes, beside Pin). The swipe's actions may still show
    /// after: the next scroll or swipe puts them away.
    private func assertNoReply(_ app: XCUIApplication, on row: XCUIElement) {
        let reply = app.buttons["Reply"]
        if row.identifier != "quietAgent" {
            let before = row.frame
            row.press(forDuration: 1.2)
            let resolve = app.buttons["Resolve"]
            XCTAssertTrue(resolve.waitForExistence(timeout: 3), "no menu on the row")
            XCTAssertFalse(reply.exists, "Reply in the menu of a row nobody reads replies on")
            // Close the menu without choosing: a tap on the dimmed screen, as far above or below the menu and the
            // row as it gets.
            let window = app.windows.firstMatch.frame
            var taken = [before, resolve.frame]
            for name in ["Pin", "Unpin", "Mute", "History"] where app.buttons[name].exists { taken.append(app.buttons[name].frame) }
            let gap = { (y: CGFloat) -> CGFloat in
                taken.map { y < $0.minY ? $0.minY - y : (y > $0.maxY ? y - $0.maxY : 0) }.min() ?? 0
            }
            let heights = stride(from: 0.06, through: 0.94, by: 0.04).map { window.minY + window.height * CGFloat($0) }
            for y in heights.sorted(by: { gap($0) > gap($1) }).prefix(3) where resolve.exists {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: y)).tap()
                _ = resolve.waitForNonExistence(timeout: 3)
            }
            XCTAssertFalse(resolve.exists, "the row's menu is still open")
            sleep(1)
        }
        row.swipeRight()
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 3), "the swipe showed no actions")
        XCTAssertFalse(reply.exists, "Reply in the swipe of \(row.label)")
        // Back the way it came, which puts the actions away.
        row.swipeLeft()
        _ = app.buttons["Pin"].waitForNonExistence(timeout: 2)
    }

    // MARK: The iPhone's list

    /// The last "Workspace N" on Machines' list: the one this test made last. Ends on the Agents tab.
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

    /// Back to the top of the list, for a screenshot.
    private func top(_ app: XCUIApplication) {
        for _ in 0..<6 { app.swipeDown() }
        sleep(1)
    }

    private func choose(_ app: XCUIApplication, _ appearance: String) {
        app.buttons["appearancePicker"].tap()
        app.buttons[appearance].tapWhenSettled()
        sleep(1)
    }

    // MARK: The iPad's sidebar (as IPadUITests does it)

    /// Splits the pane on screen and waits for the tab's strip to count `panes`; a menu tap that didn't take is
    /// tried again.
    private func split(_ app: XCUIApplication, _ direction: String, panes: Int) {
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(panes) ")).firstMatch
        for _ in 1...3 {
            openMenu(app, item: direction)
            if chip.waitForExistence(timeout: 10) { return }
        }
        XCTFail("\(direction) didn't make pane \(panes)")
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

    /// Puts the software keyboard away, if it is up (KeyBar's "key.hideKeyboard").
    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons.matching(identifier: "key.hideKeyboard").firstMatch
        guard hide.exists, hide.isHittable else { return }
        hide.tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
    }

    /// Swipes the sidebar until the element is there to tap (rows off screen aren't in the list), first one way
    /// and then back the other.
    private func scrollSidebar(_ app: XCUIApplication, to element: XCUIElement, up: Bool = true, swipes: Int = 4) {
        for (direction, count) in [(up, swipes), (!up, 2 * swipes)] {
            for _ in 0..<count {
                if element.exists && element.isHittable { return }
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: direction ? 0.7 : 0.3))
                let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: direction ? 0.3 : 0.7))
                from.press(forDuration: 0.05, thenDragTo: to)
            }
        }
    }

    /// The whole screen, upright in landscape too (`attachScreen`, ScreenShots.swift).
    private func attach(_ app: XCUIApplication, _ name: String) { attachScreen(name) }
}
