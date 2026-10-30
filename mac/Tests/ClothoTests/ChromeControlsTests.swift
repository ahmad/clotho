import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The sidebar's bottom bar (Machines, Settings, light or dark), the pane's hover ×, and the empty
/// workspace's New Tab.
@MainActor
final class ChromeControlsTests: XCTestCase {
    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: Theme.Mode.defaultsKey)
    }

    override func tearDown() { UserDefaults.standard.removeObject(forKey: Theme.Mode.defaultsKey) }

    func testBottomBarButtons() throws {
        let footer = SidebarFooter(frame: NSRect(x: 0, y: 0, width: 220, height: SidebarFooter.height))
        var machines = 0, settings = 0
        var chosen: [Theme.Mode] = []
        footer.onMachines = { machines += 1 }
        footer.onSettings = { settings += 1 }
        footer.onSetAppearance = { chosen.append($0) }
        footer.machinesButton.performClick(nil)
        footer.settingsButton.performClick(nil)
        XCTAssertEqual([machines, settings], [1, 1])
        XCTAssertEqual(footer.machinesButton.accessibilityLabel(), "Machines")
        XCTAssertNotNil(footer.machinesButton.toolTip)
        XCTAssertNotNil(footer.settingsButton.toolTip)

        // A click flips what's shown; the menu offers all three, the current one checked.
        footer.appearance = NSAppearance(named: .darkAqua)
        footer.appearanceButton.performClick(nil)
        footer.appearance = NSAppearance(named: .aqua)
        footer.appearanceButton.performClick(nil)
        XCTAssertEqual(chosen, [.light, .dark])
        UserDefaults.standard.set("dark", forKey: Theme.Mode.defaultsKey)
        footer.updateAppearanceButton()
        let menu = try XCTUnwrap(footer.appearanceButton.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Match System", "Light", "Dark"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .off, .on])
        let system = menu.items[0]
        _ = (system.target as? NSObject)?.perform(system.action, with: system)
        XCTAssertEqual(chosen.last, .system, "the way back to the system's choice")
    }

    func testPaneCloseShowsOnHoverAndCloses() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        let deadline = Date().addingTimeInterval(5)
        while store.state.pane(created.pane) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let host = PaneHostView(pane: try XCTUnwrap(store.state.pane(created.pane)), store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let size = host.fittedSize()

        host.setCornerHover(true)
        XCTAssertNil(host.closeButton, "no × without a close action")
        var closed = 0
        host.onClose = { closed += 1 }
        XCTAssertTrue(host.closeCorner.maxX == host.bounds.maxX && host.closeCorner.minY == 0, "the top-right corner (flipped)")
        host.setCornerHover(true)
        host.layoutSubtreeIfNeeded()
        let close = try XCTUnwrap(host.closeButton)
        XCTAssertTrue(host.closeCorner.contains(close.frame), "inside the corner it shows for")
        XCTAssertEqual(host.fittedSize(), size, "it takes no rows")
        close.button.performClick(nil)
        XCTAssertEqual(closed, 1)
        host.setCornerHover(false)
        XCTAssertNil(host.closeButton)
    }

    func testEmptyWorkspaceOffersNewTab() {
        let view = EmptyStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        var opened = 0
        view.show(symbol: "terminal", title: "Workspace 4", line: "This workspace has no tabs open.", action: "New Tab", shortcut: "⌘T") { opened += 1 }
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.title.stringValue, "Workspace 4")
        XCTAssertEqual(view.button.title, "New Tab")
        XCTAssertEqual(view.shortcut.stringValue, "⌘T")
        let frame = view.button.convert(view.button.bounds, to: view)
        XCTAssertEqual(frame.midY, view.bounds.midY, accuracy: 120, "near the middle")
        view.button.performClick(nil)
        XCTAssertEqual(opened, 1)
    }
}
