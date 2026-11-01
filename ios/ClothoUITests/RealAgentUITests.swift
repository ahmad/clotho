import XCTest

/// A real agent from clothod (no fakes): pane 1 of the Mac's dev clothod reports `waiting` through
/// `clothod report`. The row shows its message, and opening it acknowledges it. Set up by
/// scripts/fake-agent.py; skipped if nothing reports.
final class RealAgentUITests: XCTestCase {
    func testWaitingAgentShowsAndOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        // Every machine connects at launch; give the local one a moment to report its agents.
        sleep(2)
        app.showTab("Agents")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Allow cargo test --release?'")).firstMatch
        guard row.waitForExistence(timeout: 10) else { throw XCTSkip("no agent reported on the dev clothod") }
        XCTAssertTrue(row.label.contains("Needs you"), row.label)
        attach(app, "real agent")
        row.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "opened")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
