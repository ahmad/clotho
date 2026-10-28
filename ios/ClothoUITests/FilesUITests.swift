import XCTest

/// The file browser against the Mac's dev clothod (0.1.3+, simulator only), in a scratch folder that the
/// simulator and the daemon both see as /tmp/clotho-ios-files: browse, edit and save a file, make a
/// folder, rename and delete.
final class FilesUITests: XCTestCase {
    let root = "/tmp/clotho-ios-files"
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        try? fm.removeItem(atPath: root)
        try fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        try "hello from the mac\n".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        try "a".write(toFile: root + "/sub/a.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
    }

    func testBrowseEditAndManage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-FilesStart", root]
        app.launch()
        // Files and Settings are in the machine's menu on Home, once it's connected.
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newWorkspace)], timeout: 15)
        app.buttons["Local Mac (dev) menu"].tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()

        let notes = app.buttons["file:notes.txt"].firstMatch
        guard notes.waitForExistence(timeout: 15) else {
            return XCTFail("folder didn't list:\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.buttons["file:sub"].exists)

        // Edit and save.
        notes.tap()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").contains("hello from the mac"))
        // In a sheet the first tap can land while it's still settling: tap until the keyboard is up.
        text.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { text.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the editor never took the focus")
        text.typeText("edited on ios")
        app.buttons["Save"].tap()
        let saved = expectation(for: NSPredicate { _, _ in
            (try? String(contentsOfFile: self.root + "/notes.txt", encoding: .utf8))?.contains("edited on ios") == true
        }, evaluatedWith: nil)
        wait(for: [saved], timeout: 10)
        XCTAssertTrue(app.buttons["File actions"].waitForExistence(timeout: 5), "still shows unsaved edits")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // New folder from the folder menu.
        XCTAssertTrue(app.buttons["Folder actions"].waitForExistence(timeout: 5))
        app.buttons["Folder actions"].tap()
        app.buttons["New folder"].tap()
        app.textFields["Name"].typeText("made-on-ios")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["file:made-on-ios"].waitForExistence(timeout: 10))
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: root + "/made-on-ios", isDirectory: &isDir) && isDir.boolValue)

        // Rename and delete from the row's swipe actions.
        app.buttons["file:made-on-ios"].swipeLeft()
        app.buttons["Rename"].tap()
        // Edited in place in the row; Return saves.
        let name = app.textFields["renameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "renamed\n")
        XCTAssertTrue(app.buttons["file:renamed"].waitForExistence(timeout: 10))
        XCTAssertTrue(fm.fileExists(atPath: root + "/renamed"))

        app.buttons["file:sub"].swipeLeft()
        app.buttons["Delete"].tap()
        // The confirmation; on iOS 26 a popover whose button repeats the label.
        app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.last?.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["file:sub"])
        wait(for: [gone], timeout: 10)
        XCTAssertFalse(fm.fileExists(atPath: root + "/sub"))
    }
}
