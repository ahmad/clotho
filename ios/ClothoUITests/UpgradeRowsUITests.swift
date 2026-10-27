import XCTest

/// A look at the upgrade rows and their confirmations (Debug's -PreviewVersionRows forces the states on the
/// local dev machine; every dialog is cancelled).
final class UpgradeRowsUITests: XCTestCase {
    func testUpdateOfferAndRestart() throws {
        let app = launch("update")
        let update = app.buttons["Update clothod on Local Mac (dev)"]
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        attach(app, "update offer and restart rows")
        update.tap()
        XCTAssertTrue(app.buttons["Update"].waitForExistence(timeout: 5))
        attach(app, "update confirmation")
        dismissPopover(app)

        app.buttons["Restart clothod…"].tap()
        XCTAssertTrue(app.buttons["End all shells and restart"].waitForExistence(timeout: 5))
        attach(app, "restart confirmation")
        dismissPopover(app)
        XCTAssertFalse(app.buttons["End all shells and restart"].exists)
        attach(app, "after cancel")
    }

    /// iOS 26 shows confirmation dialogs as popovers without a Cancel button; tapping outside cancels.
    private func dismissPopover(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        sleep(1)
    }

    func testAppOutdatedNote() throws {
        let app = launch("app")
        XCTAssertTrue(app.staticTexts["Update the app"].waitForExistence(timeout: 10))
        attach(app, "app outdated note")
    }

    private func launch(_ rows: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-PreviewVersionRows", rows]
        app.launch()
        app.staticTexts["Local Mac (dev)"].firstMatch.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
