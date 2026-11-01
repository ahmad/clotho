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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
