import XCTest

/// Apps that take the mouse (Claude Code, Codex turn on mouse reporting): the long-press menu still opens,
/// selecting and copying still work, and none of it reaches the app as mouse events. Against the Mac's
/// clothod; the pane records what the app receives (`cat -v` in raw mode) in a file this test reads.
final class MouseModeUITests: XCTestCase {
    private let dir = "/tmp/clotho-ios-mouse"
    private var out: String { dir + "/out" }

    override func setUpWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private var received: String { (try? String(contentsOfFile: out, encoding: .utf8)) ?? "" }

    func testLongPressMenuAndSelectionWithMouseReporting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))
        sleep(2)
        // Some text to select, then mouse reporting on (SGR, button and drag tracking, as the agents use) and
        // every byte the app gets from here on into the file.
        app.typeText("clear; echo marker-$((6*7)); printf '\\033[?1000h\\033[?1002h\\033[?1006h'; stty raw -echo; cat -u -v > \(out)\n")
        let started = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.out) }, evaluatedWith: nil)
        wait(for: [started], timeout: 10)
        sleep(1)
        let before = received

        let pane = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        pane.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "no long-press menu with mouse reporting on")
        attach(app, "long-press menu")
        XCTAssertEqual(received, before, "the long press reached the app: \(received.debugDescription)")

        selectAll.tap()
        // Select All doesn't reopen the menu (SwiftTerm, with or without mouse reporting); a long press does.
        pane.press(forDuration: 1.2)
        let copy = app.menuItems["Copy"].exists ? app.menuItems["Copy"] : app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "no Copy after Select All")
        attach(app, "selected")
        copy.tap()
        sleep(1)

        pane.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3), "no Paste in the long-press menu")
        paste.tap()
        let pasted = expectation(for: NSPredicate { _, _ in self.received.contains("marker-42") }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [pasted], timeout: 5), .completed, "the paste didn't arrive: \(received.debugDescription)")
        XCTAssertFalse(received.contains("[<"), "mouse events reached the app: \(received.debugDescription)")
        attach(app, "pasted")
        app.typeText("\u{03}") // ^C ends cat
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
