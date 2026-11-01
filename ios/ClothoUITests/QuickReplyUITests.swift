import XCTest

/// Quick reply to a real agent on the Mac's dev clothod. /tmp/clotho-ios-claude/ui-reply says what to send:
/// "key:<1|2|3|Enter|Esc>" taps a choice, "text:<message>" types and sends. Skipped without it.
final class QuickReplyUITests: XCTestCase {
    func testReplyFromAgentsList() throws {
        guard let spec = try? String(contentsOfFile: "/tmp/clotho-ios-claude/ui-reply", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { throw XCTSkip("no reply configured") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        // Every machine connects at launch; give the local one a moment to report its agents.
        sleep(2)
        app.showTab("Agents")

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude' AND label CONTAINS 'Needs you'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no waiting Claude in the Agents list")
        row.press(forDuration: 1)
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "no Reply action (daemon without pane.keys?)")
        reply.tap()
        XCTAssertTrue(app.navigationBars["Reply to Claude"].waitForExistence(timeout: 5))
        attach(app, "sheet")
        if spec.hasPrefix("key:") {
            app.buttons[String(spec.dropFirst(4))].tap()
        } else {
            let field = app.textFields["Message"]
            field.tap()
            field.typeText(String(spec.dropFirst(5)))
            app.buttons["Send"].tap()
        }
        sleep(1)
        attach(app, "sent")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
