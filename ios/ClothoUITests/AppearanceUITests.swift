import XCTest

/// Light and dark against the Mac's clothod: the terminal takes the palette of the app's appearance (the
/// System/Light/Dark choice in the Machines toolbar), checked by sampling the pane's background in screenshots.
final class AppearanceUITests: XCTestCase {
    func testTerminalFollowsTheChosenAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting"]
        app.launch()
        // Through Home's Display menu, as the user would (a launch argument would pin the value for the whole run).
        app.buttons["Display"].tap()
        app.buttons["Light"].tap()
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

        // Switch to Dark from the pane's menu; the open terminal changes with it.
        actions.tap()
        app.buttons["Appearance"].tap()
        let darkChoice = app.buttons["Dark"]
        XCTAssertTrue(darkChoice.waitForExistence(timeout: 3))
        darkChoice.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        sleep(1)
        let dark = background(app)
        attach(app, "pane dark")
        XCTAssertLessThan(dark, 0.2, "the dark terminal isn't dark (#1D2022)")

        // Back to the system's appearance for later tests, then close what the test made.
        actions.tap()
        app.buttons["Appearance"].tap()
        app.buttons["System"].tap()
        sleep(1)
        actions.tap()
        app.buttons["Close tab"].tap()
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
