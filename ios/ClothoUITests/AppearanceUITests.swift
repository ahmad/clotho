import XCTest

/// Light and dark against the Mac's clothod: the terminal takes the palette of the app's appearance (the
/// System/Light/Dark choice in Settings), checked by sampling the pane's background in screenshots.
final class AppearanceUITests: XCTestCase {
    func testTerminalFollowsTheChosenAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        // Through Settings, as the user would (a launch argument would pin the value for the whole run).
        app.showTab("Settings")
        app.buttons["appearancePicker"].tap()
        app.buttons["Light"].tapWhenSettled()
        attach(app, "settings light")
        app.showTab("Machines")
        attach(app, "machines light")
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        attach(app, "machine light")
        newWorkspace.tap()
        let actions = app.buttons["Pane actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(2)
        app.typeText("clear; for i in 0 1 2 3 4 5 6 7; do printf '\\033[3%dm color%d \\033[9%dm bright%d\\033[0m\\n' $i $i $i $i; done\n")
        sleep(2)
        let light = background(app)
        attach(app, "pane light")
        XCTAssertGreaterThan(light, 0.9, "the light terminal isn't light (#F7F7F5)")
        // And apps that ask the terminal its background (OSC 11, as Claude Code's "auto" theme and vim do) hear
        // the light one: the pane told the daemon its colours (client.colors, clothod 0.1.20).
        XCTAssertEqual(askBackground(app), "rgb:f7/f7/f5", "OSC 11 in a light pane")

        // Switch to Dark from the pane's menu; the open terminal changes with it.
        actions.tap()
        app.buttons["Appearance"].tapWhenSettled()
        let darkChoice = app.buttons["Dark"]
        XCTAssertTrue(darkChoice.waitForExistence(timeout: 3))
        darkChoice.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(1)
        let dark = background(app)
        attach(app, "pane dark")
        XCTAssertLessThan(dark, 0.2, "the dark terminal isn't dark (#1D2022)")
        XCTAssertEqual(askBackground(app), "rgb:1d/20/22", "OSC 11 after switching to dark")

        // Back to the system's appearance for later tests, then close what the test made.
        actions.tap()
        app.buttons["Appearance"].tapWhenSettled()
        app.buttons["System"].tap()
        sleep(1)
        actions.tap()
        app.buttons["Close tab"].tapWhenSettled()
    }

    /// Asks the pane's terminal for its background colour (OSC 11) from its shell, the way an app does, and
    /// returns the reply's colour ("rgb:f7/f7/f5"). The shell writes it to a file on the Mac, where the daemon
    /// and the simulator both are; the terminal's own text isn't readable from a UI test.
    private func askBackground(_ app: XCUIApplication) -> String? {
        let file = "/tmp/cki-ios-osc11"
        try? FileManager.default.removeItem(atPath: file)
        defer { try? FileManager.default.removeItem(atPath: file) }
        // Echo and line buffering off so `read` sees the reply as it comes; it ends at the reply's ESC \.
        app.typeText("clear; stty -echo -icanon; printf '\\033]11;?\\033\\\\'; read -r -t 3 -d '\\' r; stty sane; "
                     + "printf '%s' \"${r#*;}\" | tr -d '\\033' > \(file).tmp && mv \(file).tmp \(file)\n")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let reply = try? String(contentsOfFile: file, encoding: .utf8) { return Self.shortRGB(reply) }
            usleep(200_000)
        }
        return nil
    }

    /// "rgb:f7f7/f7f7/f5f5" (xterm's 4-digit form, which clothod answers with) or "rgb:f7/f7/f5" as
    /// "rgb:f7/f7/f5": the first two hex digits of each channel. Anything else is returned as it came.
    static func shortRGB(_ reply: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("rgb:") else { return text }
        let channels = text.dropFirst(4).split(separator: "/")
        guard channels.count == 3, channels.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isHexDigit) }) else { return text }
        return "rgb:" + channels.map { $0.prefix(2).lowercased() }.joined(separator: "/")
    }

    /// The brightness (0…1) of the pane's background, sampled in its lower part, below any text.
    private func background(_ app: XCUIApplication) -> Double {
        let shot = app.windows.firstMatch.screenshot().image
        guard let cg = shot.cgImage else { return -1 }
        let x = cg.width / 2, y = Int(Double(cg.height) * 0.55)
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - y), width: cg.width, height: cg.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
