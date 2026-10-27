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
        app.launchArguments = ["-UITesting", "-PushSelfTest", "YES"]
        app.launch()
        // The notification permission prompt, the first time.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        // The relay's generic text, never anything from the alert itself.
        let banner = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "An agent needs you")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no alert through the dev relay")
        XCTAssertFalse(springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow push self test?")).firstMatch.exists)
    }
}
