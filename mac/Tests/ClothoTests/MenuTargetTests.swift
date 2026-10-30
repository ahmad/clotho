import AppKit
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
}
