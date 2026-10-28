import XCTest

/// Push alerts through the local dev relay (`node relay/dev.js`, which delivers with `simctl push`): the app
/// encrypts an alert to its own key (`-PushSelfTest YES`), registers at the relay and sends it, and the
/// notification arrives. Simulated pushes skip notification service extensions, so it shows the relay's
/// generic text; decryption is covered by PushTests, and end to end needs real sandbox APNs. Skipped when
/// the dev relay isn't running.
final class PushUITests: XCTestCase {
    func testSelfTestAlertArrivesThroughDevRelay() throws {
        guard (try? String(contentsOf: URL(string: "http://127.0.0.1:8787/v1/health")!, encoding: .utf8))?.contains("ok") == true else {
            throw XCTSkip("dev relay not running (node relay/dev.js)")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-PushSelfTest", "YES", "-PushRelay", "http://127.0.0.1:8787"]
        app.launch()
        // The notification permission prompt, the first time.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        // The relay's generic text, never anything from the alert itself.
        let banner = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "An agent needs you")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no alert through the dev relay")
        XCTAssertFalse(springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow push self test?")).firstMatch.exists)
    }

    /// The real path: the deployed relay, APNs's sandbox, and the notification service extension decrypting
    /// the alert in the simulator. Needs the network and Apple, so it runs only when asked
    /// (`touch /tmp/clotho-ios-push-e2e`).
    func testRealSandboxPushIsDecrypted() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/clotho-ios-push-e2e") else {
            throw XCTSkip("real push test not requested (touch /tmp/clotho-ios-push-e2e)")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-PushSelfTest", "YES"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        // Decrypted by the extension; the relay's own text would be "An agent needs you".
        let title = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Claude is waiting on Self test")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "no decrypted alert:\n\(springboard.debugDescription)")
        XCTAssertTrue(springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow push self test?")).firstMatch.exists)
    }

    /// The whole path, run on request with a driver outside the simulator (see README, "Push alerts"):
    /// the app registers with the dev clothod (0.1.4+, `push`) and goes to the background; the driver then
    /// starts an agent that reports `waiting`, and clothod's alert must arrive through the deployed relay and
    /// APNs, decrypted by the extension.
    func testAgentAlertFromClothod() throws {
        let marker = "/tmp/clotho-ios-push-e2e/ready"
        guard FileManager.default.fileExists(atPath: "/tmp/clotho-ios-push-e2e/agent") else {
            throw XCTSkip("agent push test not requested (mkdir -p /tmp/clotho-ios-push-e2e && touch /tmp/clotho-ios-push-e2e/agent)")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        sleep(3) // push.register after hello
        XCUIDevice.shared.press(.home)
        FileManager.default.createFile(atPath: marker, contents: nil)
        let title = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Claude is waiting on Local Mac (dev)")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "no alert from clothod:\n\(springboard.debugDescription)")
        XCTAssertTrue(springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow cargo test --release?")).firstMatch.exists)
    }
}
