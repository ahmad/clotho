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

        // Screen 1: the machine, and the key (made silently: a clean state has none).
        XCTAssertTrue(app.staticTexts["Welcome to Clotho"].waitForExistence(timeout: 10), "no guide on a clean start")
        let host = app.textFields["Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        let next = app.buttons["Continue"]
        XCTAssertFalse(next.isEnabled, "continues without a host")
        let publicKey = app.staticTexts["publicKey"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: 5), "no key made")
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
        XCTAssertTrue(app.descendants(matching: .any)["checkList"].waitForExistence(timeout: 5))
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
