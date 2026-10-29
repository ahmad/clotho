import AppKit
import XCTest
@testable import Clotho

/// Every shortcut, pressed as a real keyboard sends it, reaches its own menu item through AppKit's
/// key-equivalent matching. The bug this pins: shifted letters registered as lowercase + ⇧ fired on
/// the plain letter, so ⌘R (Rename Tab) renamed the workspace and ⇧⌘R did nothing.
@MainActor
final class MenuShortcutTests: XCTestCase {
    final class Recorder: NSObject {
        var fired: [String] = []
        @objc func hit(_ sender: NSMenuItem) { fired.append(sender.title) }
    }

    /// The characters a real key press reports: Shift turns a letter into its capital, and [ ] into { }.
    private func event(for shortcut: Shortcut) -> NSEvent? {
        let shifted = ["[": "{", "]": "}"]
        var chars = shortcut.key
        if shortcut.modifiers.contains(.shift) {
            chars = shifted[chars] ?? chars.uppercased()
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.modifiers, timestamp: 0, windowNumber: 0,
                                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)
    }

    func testEveryShortcutFiresItsOwnItem() throws {
        _ = NSApplication.shared
        let menu = AppDelegate.makeMainMenu()
        let recorder = Recorder()
        func retarget(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { retarget(sub) } else if item.action != nil {
                    item.action = #selector(Recorder.hit(_:))
                    item.target = recorder
                }
            }
        }
        retarget(menu)
        var checked = 0
        for shortcut in AppDelegate.shortcuts where shortcut.key.count == 1 && shortcut.modifiers.contains(.command) {
            guard let letter = shortcut.key.first, letter.isLetter || "[]".contains(letter) else { continue }
            let event = try XCTUnwrap(event(for: shortcut))
            recorder.fired = []
            _ = menu.performKeyEquivalent(with: event)
            XCTAssertEqual(recorder.fired, [shortcut.title], "\(shortcut.displayKeys) should be \(shortcut.title)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testRenameKeys() {
        let tab = AppDelegate.shortcuts.first { $0.title == "Rename Tab" }!
        let workspace = AppDelegate.shortcuts.first { $0.title == "Rename Workspace" }!
        XCTAssertEqual(tab.menuKey.0, "r")
        XCTAssertEqual(workspace.menuKey.0, "R", "Shift is the capital")
        XCTAssertEqual(workspace.menuKey.1, .command)
        XCTAssertEqual(workspace.displayKeys, "⇧⌘R", "the menu and shortcuts window still show ⇧⌘R")
    }
}
