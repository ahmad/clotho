import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Every menu bar action must reach the app, not something AppKit puts earlier in the responder chain.
/// macOS 26's NSWindow implements toggleSidebar: (for split view sidebars), so View ▸ Toggle Sidebar
/// named that way stopped at the window: greyed out, and ⌘/ did nothing (1.0.9).
@MainActor
final class MenuTargetTests: XCTestCase {
    /// What AppKit asks, in order, for a menu item with no target: the focused view and its superviews,
    /// the window, its delegate, the app, the app's delegate. The first that implements the action wins.
    private func target(for action: Selector, from view: NSView, app: AppDelegate) -> AnyObject? {
        var responder: NSResponder? = view
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = view.window?.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        return app.responds(to: action) ? app : nil
    }

    func testEveryMenuActionReachesTheApp() {
        _ = NSApplication.shared
        let app = AppDelegate()
        // The window the app makes: borderless, with the app as its delegate and a view focused in it.
        let window = FramelessWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                     styleMask: [.borderless, .resizable, .miniaturizable, .closable], backing: .buffered, defer: true)
        window.delegate = app
        let focused = NSView()
        window.contentView?.addSubview(focused)
        // Actions AppKit's own responders are meant to handle (text editing, window commands).
        let system: Set<Selector> = [#selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
                                     #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.toggleFullScreen(_:)),
                                     #selector(NSApplication.terminate(_:)), #selector(NSApplication.hide(_:)),
                                     #selector(NSApplication.hideOtherApplications(_:)), #selector(NSApplication.unhideAllApplications(_:)),
                                     #selector(NSApplication.arrangeInFront(_:)), #selector(NSWindow.performZoom(_:))]
        var wrong: [String] = []
        for shortcut in AppDelegate.shortcuts where app.responds(to: shortcut.action) && !system.contains(shortcut.action) {
            let found = target(for: shortcut.action, from: focused, app: app)
            if found !== app {
                wrong.append("\(shortcut.menu) ▸ \(shortcut.title) (\(NSStringFromSelector(shortcut.action))) → \(found.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
        }
        XCTAssertEqual(wrong, [], "these menu items would go to AppKit's responder, not the app")
    }

    func testToggleSidebarIsEnabledAndReachesTheApp() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        let window = FramelessWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                     styleMask: [.borderless, .resizable], backing: .buffered, defer: true)
        window.delegate = app
        let focused = NSView()
        window.contentView?.addSubview(focused)
        let view = try XCTUnwrap(AppDelegate.makeMainMenu().items.first { $0.submenu?.title == "View" }?.submenu)
        let item = try XCTUnwrap(view.items.first { $0.title == "Toggle Sidebar" && !$0.isHidden })
        XCTAssertEqual(item.keyEquivalent, "/")
        let handler = try XCTUnwrap(target(for: try XCTUnwrap(item.action), from: focused, app: app))
        XCTAssertTrue(handler === app, "Toggle Sidebar goes to \(type(of: handler)), not the app")
        // Nothing on the way validates it off: the app has no validator that disables it.
        if let validator = handler as? NSMenuItemValidation { XCTAssertTrue(validator.validateMenuItem(item)) }
    }

    /// ⌘/ toggles the sidebar and ⌥⌘/ shows the shortcuts: real key events, as a US keyboard reports them
    /// (⌥/ types ÷), through the focused terminal view and then the menu bar, as AppKit routes them.
    func testCommandSlashTogglesTheSidebarAndOptionCommandSlashShowsShortcuts() async throws {
        _ = NSApplication.shared
        let menu = AppDelegate.makeMainMenu()
        let recorder = KeyRecorder()
        let watched = [#selector(AppDelegate.showOrHideSidebar(_:)), #selector(AppDelegate.showShortcuts(_:))]
        for item in menu.items.compactMap(\.submenu).flatMap(\.items) where watched.contains(where: { $0 == item.action }) {
            item.target = recorder
        }
        // A focused terminal, as in the app.
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        let deadline = Date().addingTimeInterval(5)
        while store.state.pane(created.pane) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let host = PaneHostView(pane: try XCTUnwrap(store.state.pane(created.pane)), store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        func press(_ modifiers: NSEvent.ModifierFlags, typing characters: String) throws -> [String] {
            recorder.fired = []
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                       windowNumber: 0, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
            // The window offers key equivalents to its views first; the terminal must let these through.
            XCTAssertFalse(host.terminal.performKeyEquivalent(with: event), "the terminal kept \(modifiers) /")
            _ = menu.performKeyEquivalent(with: event)
            return recorder.fired
        }
        XCTAssertEqual(try press(.command, typing: "/"), ["sidebar"], "⌘/ toggles the sidebar")
        XCTAssertEqual(try press([.command, .option], typing: "÷"), ["shortcuts"], "⌥⌘/ shows the shortcuts")
    }
}

/// Records which of the two "/" actions a key press reached.
final class KeyRecorder: NSObject {
    var fired: [String] = []
    @objc func showOrHideSidebar(_ sender: Any?) { fired.append("sidebar") }
    @objc func showShortcuts(_ sender: Any?) { fired.append("shortcuts") }
}
