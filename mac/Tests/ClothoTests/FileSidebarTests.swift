import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The file sidebar in the real main window (the in-process fake backend, this Mac's files): it slides
/// at its own width (never squeezed to 0), the toggle stays at the title row's right end either way
/// with the tabs clear of it, it lists the focused pane's folder and follows it until the user browses
/// away, and its width is clamped and remembered.
@MainActor
final class FileSidebarTests: XCTestCase {
    private let keys = ["Backend", "AgentNotifications", "HideSidebar", "Appearance", OnboardingController.doneKey, "LaunchInBackground",
                        AppDelegate.showFileSidebarKey, "FileSidebarWidth", "OpenFilesInApps"]
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
        defaults.set(false, forKey: "OpenFilesInApps")
        defaults.removeObject(forKey: AppDelegate.showFileSidebarKey)
        defaults.removeObject(forKey: "FileSidebarWidth")
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

    func testItSlidesFollowsThePaneAndResizes() async throws {
        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            app.window?.orderOut(nil)
            app.connections.values.forEach { $0.store.stop() }
        }
        try await wait("a pane with a folder") { app.store.focusedPane?.cwd != nil }
        let layout = { app.window.contentView?.layoutSubtreeIfNeeded() }
        let width = app.container.bounds.width
        let toggle = try XCTUnwrap(app.fileSidebarToggle)
        let files = try XCTUnwrap(app.fileSidebar)

        // Hidden at first: slid out past the right edge at its full width; the tabs stop before the toggle.
        layout()
        XCTAssertFalse(app.isFileSidebarShown)
        XCTAssertTrue(files.isHidden)
        XCTAssertEqual(files.frame.width, AppDelegate.fileSidebarDefaultWidth, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(files.frame.minX, width - 0.5)
        XCTAssertEqual(toggle.frame.maxX, width - s(8), accuracy: 0.5, "at the title row's right end")
        XCTAssertEqual(toggle.frame.midY, app.sidebarToggle!.frame.midY, accuracy: 0.5, "in line with the left toggle")
        XCTAssertLessThanOrEqual(app.tabBar.frame.maxX, toggle.frame.minX, "the tabs make room for it")
        XCTAssertEqual(app.splitView.frame.maxX, width, accuracy: 0.5, "the terminals reach the edge")

        // Shown: at the right edge, the terminals and tabs end where it starts, the toggle on its band.
        app.showOrHideFileSidebar(nil)
        layout()
        XCTAssertTrue(app.isFileSidebarShown)
        XCTAssertFalse(files.isHidden)
        XCTAssertEqual(files.frame.maxX, width, accuracy: 0.5)
        XCTAssertEqual(app.splitView.frame.maxX, files.frame.minX, accuracy: 0.5)
        XCTAssertEqual(app.tabBar.frame.maxX, files.frame.minX, accuracy: 0.5)
        XCTAssertEqual(toggle.frame.maxX, width - s(8), accuracy: 0.5, "it stays put")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppDelegate.showFileSidebarKey), "remembered")
        XCTAssertNotNil(AppDelegate.makeMainMenu().items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(AppDelegate.showOrHideFileSidebar(_:)) && $0.keyEquivalent == "b"
                && $0.keyEquivalentModifierMask == [.command, .option] }, "View ▸ Toggle File Sidebar, ⌥⌘B")

        // It lists the focused pane's folder.
        let cwd = try XCTUnwrap(app.store.focusedPane?.cwd)
        try await wait("the pane's folder") { files.pane.path == cwd }
        XCTAssertTrue(files.following)
        XCTAssertTrue(files.followButton.isHidden)
        XCTAssertEqual(files.title.stringValue, ComputerName.current)

        // Browsing away stops following, and the button offers the way back.
        let away = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        // As a breadcrumb click or a folder's double-click does.
        files.pane.onUserNavigate?()
        files.pane.load(away)
        try await wait("the other folder") { files.pane.path == away }
        XCTAssertFalse(files.following)
        XCTAssertFalse(files.followButton.isHidden, "↩ Follow Pane")
        // While browsing, the pane's moves don't pull it back.
        files.follow(machine: .local, folder: "/")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(files.pane.path, away)
        files.followAgain()
        try await wait("back at the pane's folder") { files.pane.path == "/" }
        XCTAssertTrue(files.following)
        XCTAssertTrue(files.followButton.isHidden)
        files.follow(machine: .local, folder: cwd)
        try await wait("following the pane again") { files.pane.path == cwd }

        // Resizing: clamped, remembered at the end of the drag.
        files.onResize?(480)
        layout()
        XCTAssertEqual(files.frame.width, 480, accuracy: 0.5)
        XCTAssertEqual(app.splitView.frame.maxX, width - 480, accuracy: 0.5)
        files.onResize?(40)
        XCTAssertEqual(app.fileSidebarWidth.constant, AppDelegate.fileSidebarWidthRange.lowerBound)
        files.onResize?(420)
        files.onResizeEnd?()
        XCTAssertEqual(UserDefaults.standard.double(forKey: "FileSidebarWidth"), 420)

        // Hidden again: slid out at its width, not squeezed.
        app.showOrHideFileSidebar(nil)
        layout()
        app.window.displayIfNeeded()
        XCTAssertTrue(files.isHidden)
        XCTAssertEqual(files.frame.width, 420, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(files.frame.minX, width - 0.5)
        XCTAssertLessThanOrEqual(app.tabBar.frame.maxX, toggle.frame.minX)
    }

    /// The narrow Modified column: the time today, the day this year, the full date before.
    func testCompactDates() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 5)))
        let thisYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let old = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 7)))
        XCTAssertEqual(FilePane.compactFormat(earlier, now: now), FilePane.timeFormatter.string(from: earlier))
        XCTAssertEqual(FilePane.compactFormat(thisYear, now: now), FilePane.shortDayFormatter.string(from: thisYear))
        XCTAssertFalse(FilePane.compactFormat(thisYear, now: now).contains("2026"))
        XCTAssertTrue(FilePane.compactFormat(old, now: now).contains("2024"))
    }

    /// A file on this Mac opens in place, with no copy.
    func testALocalFileOpensInPlace() throws {
        let app = AppDelegate()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmac-open-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        app.openFile(Location(machine: .local, path: file.path), size: 1)
        XCTAssertNil(app.remoteEditsStore, "nothing downloaded, nothing to sync")
        XCTAssertNil(app.fileBadge(Location(machine: .local, path: file.path)))
    }
}
