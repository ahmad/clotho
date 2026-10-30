import XCTest

/// A machine nothing answers on (`-UnreachableMachine`: SSH to 127.0.0.1 port 9): after three quick tries the
/// app stops, says "Can't reach", and offers Reconnect, which tries three times more and stops again.
final class ReconnectUITests: XCTestCase {
    func testUnreachableMachineStopsRetryingAndOffersReconnect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UnreachableMachine", "YES"]
        app.launch()

        // Earlier tests leave workspaces on the dev machine, so this machine may be below the fold; the list only
        // builds (and connects) the sections on screen.
        let header = app.staticTexts["Away (test)"].firstMatch
        for _ in 0..<12 where !(header.exists && header.isHittable) { app.swipeUp() }
        let cantReach = app.descendants(matching: .any)["cantReach"].firstMatch
        XCTAssertTrue(cantReach.waitForExistence(timeout: 30), "never gave up retrying")
        let reconnect = app.buttons["reconnect"].firstMatch
        for _ in 0..<3 where !reconnect.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'machineStatus' AND label == %@", "can't reach")).firstMatch.exists,
                      "the machine's header says so")
        XCTAssertTrue(app.staticTexts["Can't reach Away (test)"].exists)
        attach(app, "home can't reach")

        // Reconnect tries again (the row goes while it does), then gives up again.
        reconnect.tap()
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
