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

    func testGuideSetsUpAMachineFromCleanState() throws {
        guard let user = read("user"), let hostKey = read("host_ed25519.pub") else { throw XCTSkip("no SSH test server") }
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-CleanState", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: 10), "no guide on a clean start")
        attach(app, "welcome")
        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.staticTexts["Workspaces, Tabs and Panes"].waitForExistence(timeout: 5))
        attach(app, "concepts")
        app.buttons["Add a Machine"].tap()

        let host = app.textFields["Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        let next = app.buttons["Continue"]
        XCTAssertFalse(next.isEnabled, "continues without a host")
        host.tap(); host.typeText("127.0.0.1")
        app.textFields["User"].tap(); app.textFields["User"].typeText(user)
        let port = app.textFields["Port"]
        port.tap(); port.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "2222")
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Guide test")
        attach(app, "machine")
        next.tap()

        app.buttons["generateKey"].tap()
        let publicKey = app.staticTexts["publicKey"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: 5))
        XCTAssertTrue(publicKey.label.hasPrefix("ssh-ed25519 "), publicKey.label)
        XCTAssertTrue(app.buttons["Copy Command"].exists)
        attach(app, "key")
        app.buttons["I've Added the Key"].tap()

        // The host key, shown before it's trusted, matches the sshd's.
        let fingerprint = app.staticTexts["hostKeyFingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15), "no host key")
        XCTAssertEqual(fingerprint.label, Self.fingerprint(hostKey))
        attach(app, "host key")
        app.buttons["trustHostKey"].tap()

        // The server doesn't know the key yet: a readable error, with the key to add again.
        let error = app.descendants(matching: .any)["onboardingError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "no login error")
        XCTAssertTrue(error.label.contains("didn't accept the key"), error.label)
        attach(app, "key rejected")
        let line = app.staticTexts["publicKey"].label
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: sshd + "/authorized_keys"))
        handle.seekToEndOfFile()
        handle.write(Data("\n\(line)\n".utf8))
        try handle.close()
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["loggedIn"].waitForExistence(timeout: 15), "no login after adding the key")
        attach(app, "logged in")

        app.buttons["Install clothod"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["clothodRunning"].waitForExistence(timeout: 120), "clothod didn't start")
        attach(app, "installed")
        app.buttons["Continue"].tap()

        // Notifications: asked here only if this simulator hasn't answered before.
        let allow = app.buttons["allowNotifications"]
        if allow.waitForExistence(timeout: 3) {
            attach(app, "notifications")
            allow.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let system = springboard.buttons["Allow"]
            if system.waitForExistence(timeout: 5) { system.tap() }
        }
        // A test install never starts at login.
        XCTAssertTrue(app.descendants(matching: .any)["loginUnavailable"].waitForExistence(timeout: 10))
        attach(app, "login")
        app.buttons["Continue"].tap()

        let open = app.buttons["openMachine"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 30)
        attach(app, "machine open")

        // Seen once: a relaunch goes straight to the machines, and the ? button reopens the guide.
        app.terminate()
        app.launchArguments = ["-UITesting", "-CleanState", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Welcome to Clotho"].exists)
        XCTAssertTrue(app.staticTexts["Guide test"].exists, "the machine wasn't saved")
        app.buttons["Welcome Guide"].tap()
        XCTAssertTrue(app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: 5))
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: 5))

        // Remove the test clothod from this Mac (cleanup-dev.sh would too).
        // On Home, the machine's header menu has Disconnect.
        app.buttons["Guide test menu"].tap()
        app.buttons["Disconnect and remove test clothod"].tap()
        sleep(3)
    }

    func testSkipLeavesTheMachinesList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-CleanState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: 10))
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-UITesting", "-CleanState", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clotho"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Welcome to Clotho"].exists, "the skipped guide came back")
    }

    /// As ssh-keygen -l prints it.
    static func fingerprint(_ openSSH: String) -> String {
        let blob = Data(base64Encoded: String(openSSH.split(separator: " ")[1]))!
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
