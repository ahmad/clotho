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
}
