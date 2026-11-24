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
            guard let letter = shortcut.key.first, letter.isLetter || "[]/".contains(letter) else { continue }
            let event = try XCTUnwrap(event(for: shortcut))
            recorder.fired = []
            _ = menu.performKeyEquivalent(with: event)
            XCTAssertEqual(recorder.fired, [shortcut.title], "\(shortcut.displayKeys) should be \(shortcut.title)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    /// The inspector keeps the file sidebar's key, and the worktree command's key is nobody else's.
    func testInspectorAndWorktreeKeys() {
        let inspector = AppDelegate.shortcuts.first { $0.title == "Toggle Inspector" }!
        XCTAssertEqual(inspector.displayKeys, "⌥⌘B", "unchanged")
        XCTAssertFalse(AppDelegate.shortcuts.contains { $0.title == "Toggle File Sidebar" })
        let worktree = AppDelegate.shortcuts.first { $0.title == "New Tab in a Worktree…" }!
        XCTAssertEqual(worktree.menu, "File")
        XCTAssertEqual(worktree.displayKeys, "⌥⌘T")
        // No two items share a key.
        let keyed = AppDelegate.shortcuts.filter { !$0.key.isEmpty }.map { "\($0.modifiers.rawValue)|\($0.key)" }
        XCTAssertEqual(Set(keyed).count, keyed.count, "every key equivalent is its own")
        for view in ["Changes", "Files", "Activity"] {
            let item = AppDelegate.shortcuts.first { $0.menu == "View" && $0.title == view }
            XCTAssertEqual(item?.key, "", "\(view) has no key of its own")
            XCTAssertEqual(item?.listed, false)
        }
        // Every key from before is still where it was.
        let before = ["⌘T": "New Tab", "⌥⌘W": "Close Tab", "⌘W": "Close Pane", "⌘P": "Quick Open…", "⇧⌘O": "File Browser", "⌘/": "Toggle Sidebar",
                      "⌥⌘S": "Move Focus to Sidebar", "⌘D": "Split Right", "⌥⌘D": "Split Left", "⇧⌘U": "Upload Files…", "⌘N": "New Workspace"]
        for (keys, title) in before {
            XCTAssertEqual(AppDelegate.shortcuts.first { $0.displayKeys == keys && !$0.hiddenInMenu }?.title, title, keys)
        }
    }

    /// The Overview is ⇧⌘0, in the View menu; ⌘0 stays Actual Size and ⌥⌘0 the terminal's. A key press of
    /// ⇧⌘0 reports ")", which is how AppKit finds the item.
    func testTheOverviewKey() throws {
        _ = NSApplication.shared
        let overview = try XCTUnwrap(AppDelegate.shortcuts.first { $0.title == "Overview" })
        XCTAssertEqual(overview.menu, "View")
        XCTAssertEqual(overview.displayKeys, "⇧⌘0")
        XCTAssertEqual(Shortcut.overviewKeys, "⇧⌘0")
        XCTAssertEqual(overview.action, #selector(AppDelegate.toggleOverview(_:)))
        XCTAssertEqual(overview.menuKey.0, ")")
        XCTAssertEqual(overview.menuKey.1, .command)
        XCTAssertEqual(AppDelegate.shortcuts.first { $0.displayKeys == "⌘0" }?.title, "Actual Size", "unchanged")
        XCTAssertEqual(AppDelegate.shortcuts.first { $0.displayKeys == "⌥⌘0" }?.title, "Actual Terminal Text Size", "unchanged")
        let keyed = AppDelegate.shortcuts.filter { !$0.key.isEmpty }.map { "\($0.modifiers.rawValue)|\($0.key)" }
        XCTAssertEqual(Set(keyed).count, keyed.count, "no two items share a key")
        let menuKeys = AppDelegate.shortcuts.filter { !$0.key.isEmpty }.map { "\($0.menuKey.1.rawValue)|\($0.menuKey.0)" }
        XCTAssertEqual(Set(menuKeys).count, menuKeys.count, "nor a key equivalent")

        let menu = AppDelegate.makeMainMenu()
        let view = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "View" })
        XCTAssertTrue(view.items.contains { $0.title == "Overview" && $0.action == #selector(AppDelegate.toggleOverview(_:)) })
        let recorder = Recorder()
        for item in menu.items.compactMap(\.submenu).flatMap(\.items) where item.action != nil {
            item.action = #selector(Recorder.hit(_:))
            item.target = recorder
        }
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> [String] {
            recorder.fired = []
            _ = menu.performKeyEquivalent(with: try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 29)))
            return recorder.fired
        }
        XCTAssertEqual(try press(")", [.command, .shift]), ["Overview"])
        XCTAssertEqual(try press("0", .command), ["Actual Size"])
    }

    func testSlashKeys() {
        let sidebar = AppDelegate.shortcuts.first { $0.title == "Toggle Sidebar" && !$0.hiddenInMenu }!
        XCTAssertEqual(sidebar.displayKeys, "⌘/")
        let help = AppDelegate.shortcuts.first { $0.title == "Keyboard Shortcuts" }!
        XCTAssertEqual(help.displayKeys, "⌥⌘/", "⇧⌘/ is macOS's Show Help Menu")
        XCTAssertTrue(AppDelegate.shortcuts.contains { $0.title == "Toggle Sidebar" && $0.displayKeys == "⌃⌘S" }, "the old key still works")
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
