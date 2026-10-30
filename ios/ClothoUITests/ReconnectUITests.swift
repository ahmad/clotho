import XCTest

/// A machine nothing answers on (`-UnreachableMachine`: SSH to 127.0.0.1 port 9): after three quick tries the
/// app stops, says "Can't reach", and offers Reconnect, which tries three times more and stops again.
final class ReconnectUITests: XCTestCase {
    func testUnreachableMachineStopsRetryingAndOffersReconnect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UnreachableMachine", "YES"]
        app.launch()

        let cantReach = app.descendants(matching: .any)["cantReach"].firstMatch
        XCTAssertTrue(cantReach.waitForExistence(timeout: 30), "never gave up retrying")
        XCTAssertTrue(app.staticTexts["Can't reach Away (test)"].exists)
        XCTAssertTrue(app.staticTexts["can't reach"].exists, "the machine's header says so")
        XCTAssertTrue(app.staticTexts["Local Mac (dev)"].exists)
        attach(app, "home can't reach")

        // Reconnect tries again (the row goes while it does), then gives up again.
        app.buttons["reconnect"].firstMatch.tap()
        XCTAssertTrue(cantReach.waitForNonExistence(timeout: 5), "Reconnect didn't try again")
        XCTAssertTrue(cantReach.waitForExistence(timeout: 30), "didn't stop after the second round")

        attach(app, "home can't reach again")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
