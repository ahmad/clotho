import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Renaming a tab keeps the keyboard while the pane behind it retitles and prints: the tab bar holds
/// its rebuilds until the edit ends, and the window's focus-follow sees the edit and leaves it alone
/// (it used to hand the keyboard back to the terminal on every sync).
@MainActor
final class TabRenameFocusTests: XCTestCase {
    private var window: NSWindow!
    private var bar: TabBarView!
    private var renamed: [(TabID, String)] = []

    override func setUp() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        bar = TabBarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(bar)
        bar.onRename = { [weak self] in self?.renamed.append(($0, $1)) }
    }

    override func tearDown() {
        window.close()
    }

    private func show(_ titles: [String]) {
        bar.update(tabs: titles.enumerated().map { (TabID($0.offset + 1), $0.element, nil, false, nil) }, selected: 1)
        bar.layoutSubtreeIfNeeded()
    }

    private var editor: NSTextView? { window.firstResponder as? NSTextView }

    func testAnEditSurvivesRetitlesAndIsSeenByTheFocusGuard() throws {
        show(["zsh", "zsh"])
        XCTAssertFalse(bar.isEditing)
        XCTAssertFalse(AppDelegate.isTypingInAField(window))

        bar.beginRename(1)
        XCTAssertTrue(bar.isEditing)
        XCTAssertTrue(AppDelegate.isTypingInAField(window), "the field editor has the keyboard")
        let field = try XCTUnwrap(editor)
        field.insertText("my long name", replacementRange: field.selectedRange())

        // The pane retitles every 200 ms while the user types: no rebuild, the same field keeps the keyboard.
        for n in 0..<5 {
            show(["✳ build \(n)", "zsh"])
            XCTAssertTrue(bar.isEditing)
            XCTAssertTrue(window.firstResponder === field, "retitle \(n) didn't take the keyboard")
        }
        field.insertText(" here", replacementRange: field.selectedRange())
        XCTAssertEqual(field.string, "my long name here")

        // Return commits, and the held retitle shows after.
        field.insertNewline(nil)
        XCTAssertFalse(bar.isEditing)
        XCTAssertEqual(renamed.first?.0, 1)
        XCTAssertEqual(renamed.first?.1, "my long name here")
        XCTAssertFalse(AppDelegate.isTypingInAField(window))
    }

    /// The guard is about text fields, not any text view: a pane's terminal isn't one.
    func testOnlyFieldEditorsCount() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView!.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertFalse(AppDelegate.isTypingInAField(window), "a plain text view (like a terminal) isn't a field being edited")
    }
}
