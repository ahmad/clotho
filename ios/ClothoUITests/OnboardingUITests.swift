import CryptoKit
import XCTest

/// The welcome guide from a clean app state (`-CleanState YES`: no machines, keys or trusted host keys), against
/// the local test sshd (scripts/ssh-test-server.sh) on this Mac, with the test install dirs. Runs a key the
/// server doesn't know yet first, to see the readable error, then adds it to the sshd's authorized_keys the way
/// the user would run the copied command.
final class OnboardingUITests: XCTestCase {
    private let sshd = "/tmp/clotho-ios-sshtest"

    override func tearDownWithError() throws {
        // Back to the integration tests' own key only.
        let client = sshd + "/client.pub"
        if FileManager.default.fileExists(atPath: client) {
            try? FileManager.default.removeItem(atPath: sshd + "/authorized_keys")
            try? FileManager.default.copyItem(atPath: client, toPath: sshd + "/authorized_keys")
        }
    }

    private func read(_ name: String) -> String? {
        (try? String(contentsOfFile: "\(sshd)/\(name)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits for what a launch or a step brings, generously: a busy build host (other agents' builds and tests)
    /// can take many seconds to launch the app, and that shouldn't fail these tests.
    private let launch: TimeInterval = 30

    func testGuideSetsUpAMachineFromCleanState() throws {
        guard let user = read("user"), let hostKey = read("host_ed25519.pub") else { throw XCTSkip("no SSH test server") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-CleanState", "YES"]
        app.launch()

        // Screen 1: the machine, and the key (made silently: a clean state has none).
        XCTAssertTrue(guideShows(app), "no guide on a clean start")
        let host = app.textFields["Host"]
        XCTAssertTrue(host.waitForExistence(timeout: launch))
        let next = app.buttons["Continue"]
        XCTAssertFalse(next.isEnabled, "continues without a host")
        let publicKey = app.staticTexts["publicKey"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: launch), "no key made")
        XCTAssertTrue(publicKey.label.hasPrefix("ssh-ed25519 "), publicKey.label)
        XCTAssertTrue(app.buttons["Copy Command"].exists)
        host.tap(); host.typeText("127.0.0.1")
        app.textFields["User"].tap(); app.textFields["User"].typeText(user)
        let port = app.textFields["Port"]
        port.tap(); port.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "2222")
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Guide test")
        attach(app, "add a machine")
        next.tap()

        // Screen 2: the host key, shown before it's trusted, matches the sshd's.
        XCTAssertTrue(app.descendants(matching: .any)["checkList"].waitForExistence(timeout: launch))
        let fingerprint = app.staticTexts["hostKeyFingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: launch), "no host key")
        XCTAssertEqual(fingerprint.label, Self.fingerprint(hostKey))
        attach(app, "host key")
        app.buttons["trustHostKey"].tap()

        // The server doesn't know the key yet: a readable error, with the key to add again.
        let error = app.descendants(matching: .any)["onboardingError"]
        XCTAssertTrue(error.waitForExistence(timeout: launch), "no login error")
        XCTAssertTrue(error.label.contains("didn't accept the key"), error.label)
        attach(app, "key rejected")
        let line = app.staticTexts["publicKey"].label
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: sshd + "/authorized_keys"))
        handle.seekToEndOfFile()
        handle.write(Data("\n\(line)\n".utf8))
        try handle.close()
        app.buttons["Try Again"].tap()
        // Logging in and installing go on by themselves once each works (each shows its check briefly), so
        // the next stop is screen 3. An error on the way would stop there instead.
        let open = app.buttons["openMachine"]
        let stopped = app.descendants(matching: .any)["onboardingError"]
        XCTAssertTrue(open.waitForExistence(timeout: 120), stopped.exists ? "stopped: \(stopped.label)" : "never reached the end")
        attach(app, "ready")
        open.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        attach(app, "machine open")

        // Seen once: a relaunch goes straight to the machines, and the ? button reopens the guide.
        app.terminate()
        app.launchArguments = ["-UITesting", "-CleanState", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: launch))
        XCTAssertTrue(app.staticTexts["Guide test"].waitForExistence(timeout: launch), "the machine wasn't saved")
        XCTAssertFalse(app.staticTexts["Welcome to Clotho"].exists)
        app.buttons["Welcome Guide"].tap()
        XCTAssertTrue(app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: launch))
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: launch))

        // Remove the test clothod from this Mac (cleanup-dev.sh would too).
        // On Home, the machine's header menu has Disconnect.
        app.buttons["Guide test menu"].tap()
        app.buttons["Disconnect and remove test clothod"].tapWhenSettled()
        // The removal runs on after the connection closes; give it time before the next test's clean start.
        sleep(3)
    }

    func testSkipLeavesTheMachinesList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-CleanState", "YES"]
        app.launch()
        XCTAssertTrue(guideShows(app), "no guide on a clean start")
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: launch))
        app.terminate()
        app.launchArguments = ["-UITesting", "-CleanState", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: launch))
        // The guide would show as the app comes up; give it the moment it would take.
        XCTAssertFalse(app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: 3), "the skipped guide came back")
    }

    /// As ssh-keygen -l prints it.
    static func fingerprint(_ openSSH: String) -> String {
        let blob = Data(base64Encoded: String(openSSH.split(separator: " ")[1]))!
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Whether the guide comes up after a clean launch; if not, what the app shows instead, for the report.
    private func guideShows(_ app: XCUIApplication) -> Bool {
        if app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: launch) { return true }
        attach(app, "no guide")
        let tree = XCTAttachment(string: "state \(app.state.rawValue)\n" + app.debugDescription)
        tree.name = "no guide: hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        return false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
