import XCTest

/// A machine's settings against the Mac's test clothod (its own config file in /tmp/cki-ios, see build.sh):
/// changing scrollback writes that daemon's config, and Start at login stays off-limits for a test install.
/// Needs a clothod with the `settings` and `service` features (0.1.7); skipped against older ones.
final class SettingsUITests: XCTestCase {
    func testScrollbackAndLoginItem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        // Files and Settings are in the machine's menu on Home, once it's connected.
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        app.buttons["Local Mac (dev) menu"].tap()
        let settings = app.buttons["machineSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let picker = app.buttons["scrollbackPicker"]
        if !picker.waitForExistence(timeout: 10) {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Update clothod'")).firstMatch.exists)
            throw XCTSkip("this clothod has no settings")
        }
        attach(app, "settings")
        picker.tap()
        app.buttons["5,000 lines"].tap()
        let config = "/tmp/cki-ios/config.toml"
        let written = expectation(for: NSPredicate { _, _ in
            ((try? String(contentsOfFile: config, encoding: .utf8)) ?? "").contains("5000")
        }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [written], timeout: 10), .completed, "scrollback_lines = 5000 not in \(config)")

        let login = app.switches["startAtLogin"]
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        XCTAssertFalse(login.isEnabled, "a test install must never become a login item")
        attach(app, "changed")
    }

    /// The rewrite's health under the machine's "Summarize agent messages" switch (clothod 0.1.32, feature
    /// `alerts`). The dev clothod's fake summarizer (scripts/fake-summarizer.sh) exits 1 for anything without
    /// "summary-test", so this test's own waiting report makes the rewrite fail; it never counts on what another
    /// test left (SummaryUITests leaves a rewrite that worked).
    func testSummarizeSwitchSaysWhyTheRewriteIsNotWorking() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 30))
        sleep(2)

        // The reporter stays in the foreground (the daemon follows the pane's foreground process as the agent).
        app.typeText("sh -c '/tmp/cki-ios-bin/clothod report waiting --agent claude --session ios-health-test --message health-test; sleep 120'\n")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.showTab("Settings")

        // The banner for that wait says first that the user is needed, then where. (It comes once the rewrite has
        // failed. The app's own banner names the Tab as the list shows it; a push for the same wait replaces it, and
        // names only a Tab the user titled, so the Tab may or may not be there.)
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'NotificationShortLookView' AND label CONTAINS 'health-test'")).firstMatch
        if banner.waitForExistence(timeout: 25) {
            XCTAssertTrue(banner.label.contains("Needs you · Workspace "), banner.label)
        }

        let name = "Local Mac (dev)"
        var skip: String?
        if !app.switches["summarize-\(name)"].waitForExistence(timeout: 15) {
            skip = "this clothod has no summaries"
        } else {
            let caption = app.staticTexts["summarizeHealth-\(name)"]
            let failing = expectation(for: NSPredicate(format: "exists == true AND label BEGINSWITH 'Not working: exit 1'"), evaluatedWith: caption)
            if XCTWaiter().wait(for: [failing], timeout: 45) == .completed {
                attach(app, "rewrite not working")
            } else {
                attach(app, "no health caption")
                // Nothing under the switch at all: a clothod before 0.1.32 reports no health.
                if caption.exists { XCTFail("the caption reads '\(caption.label)', not 'Not working: exit 1'") } else { skip = "no health caption (a clothod before 0.1.32 reports none)" }
            }
        }

        // Close the tab the test made: its row in Agents opens the pane.
        app.showTab("Agents")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'health-test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no agent row for the test's pane")
        row.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
        if let skip { throw XCTSkip(skip) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
