import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The real main window (the app launched in this process with the in-process fake backend): an empty
/// workspace, dark, the sidebar hidden, then forced layout and drawing, as a window capture does. 1.0.13's
/// first build crashed here: hiding squeezed the sidebar to width 0, its wrapping labels sent AutoLayout
/// round in circles, and AppKit threw "too many Update Constraints passes". Now the sidebar slides out at
/// its own width.
@MainActor
final class SidebarLayoutTests: XCTestCase {
    private let keys = ["Backend", "AgentNotifications", "HideSidebar", "Appearance", OnboardingController.doneKey, "LaunchInBackground"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        _ = NSApplication.shared
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        let defaults = UserDefaults.standard
        defaults.set("fake", forKey: "Backend")
        defaults.set(false, forKey: "AgentNotifications")
        defaults.set(false, forKey: "HideSidebar")
        defaults.set(true, forKey: OnboardingController.doneKey)
        defaults.set(true, forKey: "LaunchInBackground")
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    private func wait(_ what: String, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testEmptyWorkspaceDarkHiddenSidebarSurvivesForcedLayout() async throws {
        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            app.window?.orderOut(nil)
            app.connections.values.forEach { $0.store.stop() }
        }
        try await wait("a workspace") { app.store.focusedWorkspace != nil }
        // An empty workspace.
        for tab in app.store.focusedWorkspace?.tabs ?? [] { try await app.store.backend.closeTab(tab.id) }
        try await wait("the empty state") { app.store.focusedWorkspace?.tabs.isEmpty == true && app.emptyState.isHidden == false }
        app.setAppearance(.dark)
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("cmac-layout-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: shot) }
        saveSnapshot(of: app.container, to: shot)

        app.showOrHideSidebar(nil)
        XCTAssertTrue(app.isSidebarHidden)
        for _ in 0..<5 {
            app.window.contentView?.layoutSubtreeIfNeeded()
            app.window.displayIfNeeded()
            saveSnapshot(of: app.container, to: shot)
        }
        // Slid out at its own width, never squeezed; the toggle after the window buttons; tabs after it.
        XCTAssertEqual(app.sidebar.frame.width, app.savedSidebarWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(app.sidebar.frame.maxX, 0.5)
        let toggle = try XCTUnwrap(app.sidebarToggle)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, WindowButtons.width)
        XCTAssertGreaterThanOrEqual(app.tabBar.frame.minX, toggle.frame.maxX)

        app.showOrHideSidebar(nil)
        app.window.contentView?.layoutSubtreeIfNeeded()
        saveSnapshot(of: app.container, to: shot)
        XCTAssertFalse(app.isSidebarHidden)
        XCTAssertEqual(app.sidebar.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(toggle.frame.maxX, app.sidebar.frame.maxX - s(8), accuracy: 0.5, "back at the sidebar's edge")
    }
}
