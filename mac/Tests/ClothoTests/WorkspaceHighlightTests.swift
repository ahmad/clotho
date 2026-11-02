import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Workspace highlights: kept per machine and workspace, cleared with None, dropped when the workspace
/// closes; a faint tint under the row that the selection's tint covers; the menu's checkmark.
@MainActor
final class WorkspaceHighlightTests: XCTestCase {
    private var suite: String!

    override func setUp() {
        _ = NSApplication.shared
        suite = TestDefaults.name("highlights")
        WorkspaceHighlights.store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        WorkspaceHighlights.store = .standard
        TestDefaults.remove(suite)
    }

    func testPersistClearAndDropOnClose() {
        WorkspaceHighlights.set(.green, "local", 3)
        WorkspaceHighlights.set(.purple, "local", 5)
        WorkspaceHighlights.set(.red, "bb", 3)
        // Another launch reads the same defaults.
        let again = UserDefaults(suiteName: suite)!
        XCTAssertEqual(again.dictionary(forKey: WorkspaceHighlights.defaultsKey) as? [String: String],
                       ["local/3": "green", "local/5": "purple", "bb/3": "red"])
        XCTAssertEqual(WorkspaceHighlights.get("local", 3), .green)
        XCTAssertEqual(WorkspaceHighlights.get("bb", 3), .red, "by machine and workspace")
        XCTAssertNil(WorkspaceHighlights.get("local", 4))

        WorkspaceHighlights.set(nil, "local", 5)
        XCTAssertNil(WorkspaceHighlights.get("local", 5), "None clears it")

        // Workspace 3 closed on this Mac: its highlight goes, devbox's workspace 3 keeps its own.
        XCTAssertEqual(WorkspaceHighlights.prune("local", keeping: [1, 2]), 1)
        XCTAssertNil(WorkspaceHighlights.get("local", 3))
        XCTAssertEqual(WorkspaceHighlights.get("bb", 3), .red)
        XCTAssertEqual(WorkspaceHighlights.prune("local", keeping: []), 0, "nothing left to drop")
        WorkspaceHighlights.set(nil, "bb", 3)
        XCTAssertNil(UserDefaults(suiteName: suite)!.object(forKey: WorkspaceHighlights.defaultsKey), "empty leaves nothing behind")
    }

    func testTheMenuChecksTheCurrentColour() throws {
        var chosen: [WorkspaceHighlight?] = []
        let item = NSMenu.highlightItem(current: .blue) { chosen.append($0) }
        let menu = try XCTUnwrap(item.submenu)
        XCTAssertEqual(item.title, "Highlight")
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "None"])
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Blue"])
        XCTAssertTrue(menu.items.prefix(7).allSatisfy { $0.image != nil }, "colour dots")
        let red = menu.items[0]
        _ = (red.target as? NSObject)?.perform(red.action, with: red)
        let none = try XCTUnwrap(menu.items.last)
        _ = (none.target as? NSObject)?.perform(none.action, with: none)
        XCTAssertEqual(chosen, [.red, nil])
        let plain = try XCTUnwrap(NSMenu.highlightItem(current: nil) { _ in }.submenu)
        XCTAssertEqual(plain.items.filter { $0.state == .on }.map(\.title), ["None"])
    }

    /// The tint under a highlighted row, in light and dark: faint at rest, a bit stronger on hover.
    /// Selected, the colour stays (stronger) and the selection shows as on every row: the bar and the
    /// bold title.
    func testTheRowTintAndTheSelectionOnTop() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let dark = name == .darkAqua
            let row = WorkspaceRow()
            row.appearance = appearance
            row.label.stringValue = "api"
            let plain = WorkspaceRow()
            plain.appearance = appearance
            plain.selectionStyle = .row
            row.selectionStyle = .row
            row.highlight = WorkspaceHighlight.purple.color
            func fill(_ view: NSView) -> NSColor? { view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
            let resting = try XCTUnwrap(fill(row))
            XCTAssertEqual(resting.alphaComponent, WorkspaceHighlights.alpha(dark: dark, hovering: false), accuracy: 0.01, "\(name)")
            XCTAssertGreaterThan(resting.alphaComponent, 0.1, "visible")
            XCTAssertLessThan(resting.alphaComponent, 0.3, "subtle")
            XCTAssertEqual(fill(plain)?.alphaComponent ?? 0, 0, accuracy: 0.01, "an unhighlighted row stays clear")

            row.isSelected = true
            plain.isSelected = true
            let selected = try XCTUnwrap(fill(row))
            XCTAssertEqual(selected.alphaComponent, resting.alphaComponent + WorkspaceHighlights.selectedBoost, accuracy: 0.01,
                           "selected keeps its colour, stronger (\(name))")
            XCTAssertEqual(selected.usingColorSpace(.sRGB)?.redComponent ?? 0, resting.usingColorSpace(.sRGB)?.redComponent ?? 1, accuracy: 0.01)
            XCTAssertNotEqual(fill(row), fill(plain), "not the plain selection tint")
            XCTAssertEqual(row.label.textColor, plain.label.textColor, "the same text colour as any selected row")
            XCTAssertEqual(row.label.font, plain.label.font, "and the same bold title")
            let bar = { (item: ChromeItem) in item.subviews.first { $0.layer?.cornerRadius == s(1.5) } }
            XCTAssertEqual(bar(row)?.isHidden, false, "the selection bar shows")
            XCTAssertEqual(bar(row)?.layer?.backgroundColor, bar(plain)?.layer?.backgroundColor, "in the selection's colour")

            row.isSelected = false
            XCTAssertEqual(fill(row), resting, "back to the highlight")
            row.highlight = nil
            XCTAssertEqual(fill(row)?.alphaComponent ?? 0, 0, accuracy: 0.01, "cleared")
        }
        XCTAssertGreaterThan(WorkspaceHighlights.alpha(dark: false, hovering: true), WorkspaceHighlights.alpha(dark: false, hovering: false))
    }

    /// In the real window (the fake backend): the sidebar row shows its highlight, and closing the
    /// workspace drops it while the other keeps its own.
    func testClosingAWorkspaceDropsItsHighlight() async throws {
        let keys = ["Backend", "AgentNotifications", OnboardingController.doneKey, "LaunchInBackground"]
        var saved: [String: Any] = [:]
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        defer { for key in keys { UserDefaults.standard.set(saved[key], forKey: key) } }
        UserDefaults.standard.set("fake", forKey: "Backend")
        UserDefaults.standard.set(false, forKey: "AgentNotifications")
        UserDefaults.standard.set(true, forKey: OnboardingController.doneKey)
        UserDefaults.standard.set(true, forKey: "LaunchInBackground")

        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            app.window?.orderOut(nil)
            app.connections.values.forEach { $0.store.stop() }
        }
        func wait(_ what: String, _ done: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !done() {
                guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await wait("a workspace") { app.store.focusedWorkspace != nil }
        let first = try XCTUnwrap(app.store.focusedWorkspace?.id)
        let second = try await app.store.backend.createWorkspace(name: "Two", spawn: SpawnOptions(command: ["/bin/sleep", "30"])).workspace
        try await wait("the second workspace") { app.store.state.workspaces.count == 2 }
        WorkspaceHighlights.set(.orange, AppDelegate.localKey, first)
        WorkspaceHighlights.set(.blue, AppDelegate.localKey, second)
        app.sync()
        let rows = app.sidebar.subviewsOfType(WorkspaceRow.self)
        XCTAssertEqual(Set(rows.compactMap(\.highlight)), [WorkspaceHighlight.orange.color, WorkspaceHighlight.blue.color], "both rows tinted")

        try await app.store.backend.closeWorkspace(second)
        try await wait("the highlight of the closed workspace dropped") { WorkspaceHighlights.get(AppDelegate.localKey, second) == nil }
        XCTAssertEqual(WorkspaceHighlights.get(AppDelegate.localKey, first), .orange, "the other keeps its own")
    }
}

private extension NSView {
    func subviewsOfType<T: NSView>(_ type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.subviewsOfType(type) }
    }
}
