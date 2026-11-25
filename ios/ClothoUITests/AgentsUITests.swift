import XCTest

/// The Agents tab on fake agent states (`-FakeAgents YES`) against the Mac's clothod: three groups, agents that
/// need you on top, then the finished ones under Done, the rest under Working, which is folded until opened;
/// Resolve and Mute from a swipe and the long-press menu; a row opens its pane, and Back returns to Agents.
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

        // Waiting and error need the user ("Needs you", on top); a finished agent is under Done, or on top when its
        // turn ended in a question (the fakes: odd panes); running and starting are under Working. No checkmark
        // buttons on the rows: Resolve is a swipe or the long-press menu.
        let onTop = app.buttons.matching(identifier: "needsYouAgent")
        let quietRows = app.buttons.matching(identifier: "quietAgent")
        let anyWaiting = onTop.matching(NSPredicate(format: "label CONTAINS 'cargo test --release'")).firstMatch
        XCTAssertTrue(anyWaiting.waitForExistence(timeout: 5))
        // The same row from here on, whichever others come and go (other tests' panes may be fake agents too).
        let waitingLabel = anyWaiting.label
        let waiting = onTop.matching(NSPredicate(format: "label == %@", waitingLabel)).firstMatch
        XCTAssertTrue(waitingLabel.contains("Needs you"), waitingLabel)
        XCTAssertFalse(app.buttons["Resolve"].exists, "a Resolve button shows on the row")
        // Line 4 names the machine and the agent, and says how much the pane's work tree changed.
        XCTAssertTrue(waitingLabel.contains("Local Mac (dev)"), waitingLabel)
        XCTAssertTrue(waitingLabel.contains("128 lines added, 32 removed, in 6 files"), waitingLabel)
        attach(app, "agents")

        // Working is folded until opened; running is in it.
        app.setWorkingAgents(expanded: true)
        let running = quietRows.matching(NSPredicate(format: "label CONTAINS 'Running'")).firstMatch
        app.revealAgent(running)
        XCTAssertTrue(running.exists, "running isn't under Working")
        let workingBefore = try XCTUnwrap(app.workingAgentCount(), "no Working group")

        // Resolve a finished agent by swiping (under Done, or on top when it asked something): it leaves for Working.
        let attention = app.buttons.matching(NSPredicate(format: "identifier IN {'needsYouAgent', 'doneAgent'}"))
        let finished = attention.matching(NSPredicate(format: "label CONTAINS 'Finished: 3 files changed'")).firstMatch
        app.revealAgent(finished)
        XCTAssertTrue(finished.exists, "no finished agent under Needs you or Done")
        let finishedLabel = finished.label
        XCTAssertTrue(finishedLabel.contains(finished.identifier == "doneAgent" ? "· Done" : "· Needs you"), finishedLabel)
        finished.swipeLeft()
        app.buttons["Resolve"].tapWhenSettled()
        let resolved = attention.matching(NSPredicate(format: "label == %@", finishedLabel)).firstMatch
        XCTAssertTrue(resolved.waitForNonExistence(timeout: 5), "the resolved agent still asks for attention")
        XCTAssertEqual(app.workingAgentCount(), workingBefore + 1, "the resolved agent isn't under Working")
        attach(app, "resolved")

        // Mute the waiting agent from its menu: it leaves the top for Working, marked muted. Unmute takes the mark away.
        app.revealAgent(waiting)
        waiting.press(forDuration: 1.2)
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 3), "no Mute in the agent's menu")
        XCTAssertTrue(app.buttons["Resolve"].exists, "no Resolve in the agent's menu")
        mute.tapWhenSettled()
        XCTAssertTrue(waiting.waitForNonExistence(timeout: 5), "the muted agent is still on top")
        let muted = quietRows.matching(NSPredicate(format: "label CONTAINS 'Muted'")).firstMatch
        app.revealAgent(muted)
        XCTAssertTrue(muted.waitForExistence(timeout: 5), "the muted agent isn't marked under Working")
        attach(app, "muted")
        muted.press(forDuration: 1.2)
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 3), "no Unmute on a muted agent")
        unmute.tapWhenSettled()
        XCTAssertTrue(muted.waitForNonExistence(timeout: 5), "still marked muted after Unmute")

        // Opening an agent never resolves it, and Back returns to Agents with it still on top.
        app.revealAgent(waiting)
        XCTAssertTrue(waiting.exists, "the unmuted agent didn't come back to the top")
        waiting.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        attach(app, "opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "Back didn't return to Agents")
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the opened agent left the top")
        sleep(1)
        XCTAssertTrue(waiting.exists, "opening an agent resolved it")
        waiting.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
        // Folded again, as later tests (and a new install) find it.
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        app.setWorkingAgents(expanded: false)
    }

    /// The three groups in order, with Working folded and counted until its header is tapped, and a row's change
    /// counts. Screenshots in light, in dark and at a large text size.
    func testThreeGroups() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the iPhone's Agents tab") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 30), "UI tests start on Machines")
        // Ten fake agents in two tabs: every state twice, and the two finished ones on an even and an odd pane, so
        // one is under Done and one (whose turn ended in a question) under Needs you.
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

        // The headers, down the list: Needs you, Done, Working.
        let needsYou = app.staticTexts["Needs you"].firstMatch
        let done = app.staticTexts["Done"].firstMatch
        let working = app.buttons["workingGroup"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 10), "no Needs you group")
        for _ in 0..<12 where !done.exists { app.swipeUp() }
        XCTAssertTrue(done.exists, "no Done group below Needs you")
        if needsYou.exists { XCTAssertLessThan(needsYou.frame.minY, done.frame.minY, "Done is above Needs you") }
        for _ in 0..<12 where !working.exists { app.swipeUp() }
        XCTAssertTrue(working.exists, "no Working group below Done")
        if done.exists { XCTAssertLessThan(done.frame.minY, working.frame.minY, "Working is above Done") }

        // Working is folded (an earlier test may have left it open: fold it), says how many it holds, and shows
        // no rows until its header is tapped. The header is a full touch target.
        app.setWorkingAgents(expanded: false)
        XCTAssertEqual(working.value as? String, "collapsed")
        let count = try XCTUnwrap(app.workingAgentCount(), "no count on Working")
        XCTAssertGreaterThanOrEqual(count, 4, "two running and two starting agents")
        XCTAssertEqual(working.label, "Working, \(count) agents")
        XCTAssertGreaterThanOrEqual(working.frame.height, 43.5, "the Working header is too small to tap")
        let unpinnedWorking = app.buttons.matching(NSPredicate(format: "identifier == 'quietAgent' AND NOT (label CONTAINS 'Pinned')"))
        XCTAssertEqual(unpinnedWorking.count, 0, "a folded group shows its rows")
        attach(app, "working collapsed")
        working.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'expanded'"), evaluatedWith: working)], timeout: 5)
        XCTAssertTrue(unpinnedWorking.firstMatch.waitForExistence(timeout: 5), "the open group shows no rows")
        attach(app, "working expanded")
        app.setWorkingAgents(expanded: false)

        // A finished agent under Done, with its change counts; one that asked something on top.
        let doneRow = app.buttons.matching(identifier: "doneAgent").firstMatch
        app.revealAgent(doneRow, swipes: 6)
        XCTAssertTrue(doneRow.exists, "no row under Done")
        XCTAssertTrue(doneRow.label.contains("· Done"), doneRow.label)
        XCTAssertTrue(doneRow.label.contains("41 lines added, 7 removed, in 3 files"), doneRow.label)
        let asked = app.buttons.matching(NSPredicate(format: "identifier == 'needsYouAgent' AND label CONTAINS 'Finished: 3 files changed'")).firstMatch
        app.revealAgent(asked, swipes: 6)
        XCTAssertTrue(asked.exists, "a finished agent that needs the user isn't under Needs you")
        XCTAssertTrue(asked.label.contains("· Needs you"), asked.label)

        // Light, then dark from Settings (and back to the system's, for later tests).
        top(app)
        attach(app, "groups light")

        // The tab's badge counts Needs you only (its header's count, plus pinned rows that need the user, which
        // show under Pinned): the finished agents under Done aren't in it.
        XCTAssertTrue(needsYou.waitForExistence(timeout: 5), "Needs you isn't at the top of the list")
        let badge = app.tabBars.buttons["Agents"].value as? String ?? ""
        let badged = try XCTUnwrap(Int(badge.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? ""),
                                   "no count in the Agents tab's badge: \(badge)")
        let counts = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+'")).allElementsBoundByIndex
        let header = needsYou.frame
        let needing = try XCTUnwrap(counts.first { abs($0.frame.midY - header.midY) < 8 && $0.frame.minX >= header.maxX - 1 }.flatMap { Int($0.label) },
                                  "no count beside the Needs you header")
        let pinnedOnTop = app.buttons.matching(NSPredicate(format: "identifier == 'needsYouAgent' AND label CONTAINS 'Pinned'")).count
        XCTAssertEqual(badged, needing + pinnedOnTop, "the badge counts more than Needs you (Done?): \(badge)")
        app.showTab("Settings")
        choose(app, "Dark")
        app.showTab("Agents")
        top(app)
        attach(app, "groups dark")
        app.showTab("Settings")
        choose(app, "System")

        // At a large accessibility text size: the caption wraps instead of losing its end.
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        app.showTab("Agents")
        XCTAssertTrue(app.buttons.matching(identifier: "needsYouAgent").firstMatch.waitForExistence(timeout: 30), "no agents at the large size")
        sleep(1)
        attach(app, "groups large")
        for _ in 0..<12 where !working.exists { app.swipeUp() }
        XCTAssertTrue(working.exists, "no Working group at the large size")
        attach(app, "groups large, further down")

        // Clean up at the usual size: close both tabs from their waiting agents' rows.
        app.terminate()
        app.launchArguments = ["-UITesting", "-FakeAgents", "YES"]
        app.launch()
        app.showTab("Agents")
        XCTAssertTrue(needsYou.waitForExistence(timeout: 30))
        let number = Int(newest.split(separator: " ").last ?? "") ?? 0
        for name in ["Workspace \(number - 1)", newest] {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'needsYouAgent' AND label BEGINSWITH %@", name + " ›")).firstMatch
            app.revealAgent(row)
            guard row.exists else { continue }
            row.tap()
            XCTAssertTrue(actions.waitForExistence(timeout: 10))
            actions.tap()
            app.buttons["Close tab"].tapWhenSettled()
            XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        }
    }

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
        for _ in 0..<4 { app.swipeDown() }
        sleep(1)
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

/// The Agents list's Working group in UI tests. It is folded by default and the app keeps the choice
/// (`agentsWorkingExpanded`), so a test that looks for a running, starting, resolved or muted agent
/// (`quietAgent`) opens it first, whatever an earlier test left.
extension XCUIApplication {
    /// Scrolls the list down, then back up, until `element` is on screen (a List builds rows only once shown).
    func revealAgent(_ element: XCUIElement, swipes: Int = 10) {
        for _ in 0..<swipes where !(element.exists && element.isHittable) { swipeUp() }
        for _ in 0..<(2 * swipes) where !(element.exists && element.isHittable) { swipeDown() }
    }

    /// Opens or folds the Working group from its header. Does nothing when no agent is in it.
    func setWorkingAgents(expanded: Bool) {
        let header = buttons["workingGroup"]
        revealAgent(header)
        guard header.exists else { return }
        let want = expanded ? "expanded" : "collapsed"
        if header.value as? String != want { header.tap() }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", want), object: header)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 5), .completed, "the Working group isn't \(want)")
    }

    /// The count in the Working header ("Working, 3 agents"); nil when no agent is in the group.
    func workingAgentCount() -> Int? {
        let header = buttons["workingGroup"]
        revealAgent(header)
        guard header.exists else { return nil }
        return header.label.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }
}
