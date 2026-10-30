import XCTest

/// What agent prompts get from the phone, against the Mac's clothod: the key bar's newline, and an image
/// pasted as a file on the machine. The pane records every
/// byte it receives (`cat -u -v` in raw mode) in a file this test reads.
final class AgentInputUITests: XCTestCase {
    private let dir = "/tmp/clotho-ios-input"
    private var out: String { dir + "/out" }
    private var received: String { (try? String(contentsOfFile: out, encoding: .utf8)) ?? "" }

    override func setUpWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func recordingPane() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(2)
        app.typeText("stty raw -echo; cat -u -v > \(out)\n")
        wait(for: [expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.out) }, evaluatedWith: nil)], timeout: 10)
        sleep(1)
        return app
    }

    private func waitFor(_ text: String, _ why: String) {
        let arrived = expectation(for: NSPredicate { _, _ in self.received.contains(text) }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [arrived], timeout: 10), .completed, "\(why): got \(received.debugDescription)")
    }

    /// The key bar's newline reaches the pane as ESC CR. (Hardware Shift-Return and the ⌘ keys go through
    /// PaneTerminalView.pressesBegan with EditingKeys, unit-tested in ClothoTests: XCUITest's typeKey doesn't
    /// reliably deliver hardware key events to the simulator while the software keyboard is up.)
    func testNewlineKeyReachesThePane() throws {
        let app = recordingPane()
        // cat -v shows ESC as ^[ and CR as ^M.
        app.typeText("a")
        // The key is at the scrolling bar's far end. Scroll there and let it settle first: since iOS 27 a tap that
        // XCUITest makes while the bar is still scrolling only stops the scroll.
        let newline = app.buttons["Newline"]
        for _ in 0..<3 where !newline.isHittable { app.buttons["esc"].firstMatch.swipeLeft(); sleep(1) }
        newline.tap()
        app.typeText("b")
        waitFor("a^[^Mb", "the key bar's newline")
        app.typeText("\u{03}")
        closeTab(app)
    }

    func testPastedImageArrivesAsAFile() throws {
        let app = recordingPane()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        UIPasteboard.general.setData(png, forPasteboardType: "public.png")
        XCTAssertFalse(UIPasteboard.general.hasStrings)

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        waitFor(".png", "the uploaded image's path")
        attach(app, "pasted image")

        // The path as typed (shell-escaped), on this Mac: the pane's machine.
        guard let range = received.range(of: #"/\S*\.cache/clotho/paste/\d{8}-\d{6}-[0-9a-f]{6}\.png"#, options: .regularExpression) else {
            return XCTFail("no paste path in \(received.debugDescription)")
        }
        let path = String(received[range]).replacingOccurrences(of: "\\", with: "")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let saved = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(saved, png, "the file on the machine is the clipboard's PNG")
        app.typeText("\u{03}")
        closeTab(app)
    }

    /// Closes what the test made, so later tests' rows stay on screen.
    private func closeTab(_ app: XCUIApplication) {
        sleep(1)
        app.buttons["Pane actions"].tap()
        app.buttons["Close tab"].tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
