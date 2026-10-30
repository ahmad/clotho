import XCTest

/// The restored-pane note over the terminal's top right (`-PreviewRestored` marks every pane, as a pane
/// clothod brought back after a restart would be): it says what came back, and × dismisses it.
final class RestoredNoteUITests: XCTestCase {
    func testRestoredNoteShowsAndDismisses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-PreviewRestored", "continued"]
        app.launch()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 10)
        newWorkspace.tap()
        XCTAssertTrue(app.buttons["Pane actions"].waitForExistence(timeout: 10))

        let note = app.descendants(matching: .any)["restoredNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["restoredText"].label, "Continued the latest conversation in this folder")
        sleep(1)
        attach(app, "restored note continued")

        app.buttons["dismissRestored"].tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 3), "× didn't dismiss it")
        attach(app, "restored note dismissed")
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
