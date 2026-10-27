import XCTest

/// I3/I4 from the UI: add a machine (host from /tmp/clotho-ios-sshtest/ui-host, e.g. devbox), generate a key,
/// use the test install dirs, connect, and run a command in a remote pane. Skipped without that file.
final class RemoteUITests: XCTestCase {
    func testAddMachineAndRunRemotePane() throws {
        guard let spec = try? String(contentsOfFile: "/tmp/clotho-ios-sshtest/ui-host", encoding: .utf8) else {
            throw XCTSkip("no remote host configured")
        }
        let parts = spec.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@").map(String.init)
        let (user, host) = (parts[0], parts[1])
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()

        // Reuse the machine from an earlier run.
        if !app.staticTexts["\(user)@\(host)"].exists {
            app.buttons["Add machine"].tap()
            let fields = app.textFields
            fields["Host"].tap(); fields["Host"].typeText(host)
            fields["User"].tap(); fields["User"].typeText(user)
            app.buttons["Generate new key"].tap()
            app.buttons["Ed25519"].tap()
            XCTAssertTrue(app.buttons["Copy public key"].waitForExistence(timeout: 5))
            app.buttons["Save"].tap()
        }
        app.staticTexts["\(user)@\(host)"].firstMatch.tap()

        let newWorkspace = app.buttons["New Workspace"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 60)
        attach(app, "connected")
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 15))
        sleep(2)
        app.typeText("echo remote-$((6*7)) $(uname -s)\n")
        sleep(2)
        attach(app, "remote pane")
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        let mode = app.staticTexts["resumeMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30), "no resubscribe after returning")
        XCTAssertTrue(["live", "replay"].contains(mode.label), "resumed with \(mode.label)")
        attach(app, "resumed")
        app.buttons["Pane actions"].tap()
        app.buttons["Close tab"].tap()

        // Disconnecting removes the test clothod from the machine (scripts/cleanup-dev.sh checks).
        sleep(1)
        // Closing the tab already leaves the pane screen; go back until the machine list shows.
        for _ in 0..<3 where !app.navigationBars["Machines"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        let row = app.buttons.containing(.staticText, identifier: "\(user)@\(host)").firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: row)], timeout: 10)
        row.press(forDuration: 1)
        attach(app, "machine menu")
        let disconnect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Disconnect'")).firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        XCTAssertEqual(disconnect.label, "Disconnect and remove test clothod")
        disconnect.tap()
        sleep(4)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
