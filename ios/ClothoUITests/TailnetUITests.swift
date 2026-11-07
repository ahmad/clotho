#if CLOTHO_TAILNET
import XCTest

/// The debug Tailnet Test screen against the offline test tailnet (ios/scripts/tailnet-test-net.sh, started by
/// CLOTHO_TAILNET=1 ./build.sh test); skipped without it. Nothing here reaches Tailscale.
final class TailnetUITests: XCTestCase {
    private func read(_ name: String) throws -> String {
        guard let text = try? String(contentsOfFile: "/tmp/cki-tailnet/\(name)", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw XCTSkip("no test tailnet (scripts/tailnet-test-net.sh start)")
        }
        return text
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-CleanState", "YES", "-TailnetTest", "YES"] + arguments
        app.launch()
        return app
    }

    private func waitForState(_ app: XCUIApplication, _ label: String, timeout: TimeInterval) -> Bool {
        // LabeledContent reads as "State, <value>".
        let state = app.descendants(matching: .any)["tailnet.state"]
        let matched = expectation(for: NSPredicate(format: "label == %@ OR label ENDSWITH %@", label, ", " + label), evaluatedWith: state)
        return XCTWaiter().wait(for: [matched], timeout: timeout) == .completed
    }

    /// Scrolls the form until `element` is on screen.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Waits for `element` to match `format`, scrolling down now and then: the Form only creates its on-screen
    /// rows, so a row that appears below the fold isn't there until scrolled to.
    private func waitRevealing(_ element: XCUIElement, _ format: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: format)
        let deadline = Date().addingTimeInterval(timeout)
        var tries = 0
        while Date() < deadline {
            if element.exists, predicate.evaluate(with: element) { return true }
            if !element.exists, tries < 6 { app.swipeUp(); tries += 1 }
            _ = element.waitForExistence(timeout: 1)
        }
        return element.exists && predicate.evaluate(with: element)
    }

    /// A node that needs a login: Sign In opens testctl's login page in the web sheet, which signs the node in
    /// (as Tailscale's page does after a login), and the app closes the sheet once the node runs.
    func testSignIn() throws {
        let control = try read("auth_control_url")
        let app = launch(["-TailnetControlURL", control, "-TailnetDir", "/tmp/cki-tailnet/ui-signin", "-TailnetHostname", "cki-ios-ui-signin"])
        let start = app.buttons["tailnet.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        XCTAssertTrue(waitForState(app, "Needs sign-in", timeout: 30), app.descendants(matching: .any)["tailnet.state"].label)
        let signIn = app.buttons["tailnet.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        XCTAssertTrue(waitForState(app, "Running", timeout: 30), app.descendants(matching: .any)["tailnet.state"].label)
        // The sheet closed itself: the screen is usable again.
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable)
        XCTAssertFalse(app.staticTexts["tailnet.error"].exists, app.staticTexts["tailnet.error"].label)
        start.tap()
        XCTAssertTrue(waitForState(app, "Stopped", timeout: 10))
    }

    /// Autostart, a dial to the test peer, then a trip to the background with the node forced dead: on return it's
    /// recreated and the probe dials again.
    func testForegroundRecreate() throws {
        let control = try read("control_url")
        let peer = try read("peer_ip")
        let app = launch(["-TailnetControlURL", control, "-TailnetDir", "/tmp/cki-tailnet/ui-foreground",
                          "-TailnetHostname", "cki-ios-ui-foreground", "-TailnetAutoStart", "YES",
                          "-TailnetProbe", "\(peer):22", "-TailnetForceRecreate", "YES"])
        XCTAssertTrue(waitForState(app, "Running", timeout: 30), app.descendants(matching: .any)["tailnet.state"].label)

        let host = app.textFields["tailnet.dialHost"]
        reveal(host, in: app)
        host.tap()
        // Return closes the keyboard, which would otherwise cover the result row.
        host.typeText(peer + "\n")
        let dial = app.buttons["tailnet.dial"]
        reveal(dial, in: app)
        dial.tap()
        let result = app.staticTexts["tailnet.dialResult"]
        XCTAssertTrue(waitRevealing(result, "label CONTAINS 'SSH-2.0'", in: app, timeout: 20), result.exists ? result.label : "no dial result")

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let timing = app.descendants(matching: .any)["tailnet.lastTiming"]
        XCTAssertTrue(waitRevealing(timing, "label CONTAINS 'recreated' AND label CONTAINS 'dial in'", in: app, timeout: 30),
                      "no recreate timing: \(timing.exists ? timing.label : "none")")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "foreground timing"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
