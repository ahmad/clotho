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
        XCTAssertTrue(host.terminal.frame.contains(close.frame), "wholly inside the terminal, not over its edge")
        let right = min(host.terminal.frame.maxX, host.bounds.maxX - PaneHostView.padding)
        XCTAssertEqual(right - close.frame.maxX, PaneHostView.closeMargin, accuracy: 0.5, "a margin from the visible right edge")
        XCTAssertEqual(close.frame.minY - host.terminal.frame.minY, PaneHostView.closeMargin, accuracy: 0.5)
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
        // [ New Tab (⌘T) ]: the shortcut inside the button, in parentheses, dimmer.
        let title = view.button.attributedTitle
        XCTAssertEqual(title.string, "New Tab (⌘T)")
        let open = (title.string as NSString).range(of: "(").location
        XCTAssertEqual((title.attribute(.foregroundColor, at: open, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 0, 0.6, accuracy: 0.01,
                       "the parentheses are dim too")
        XCTAssertEqual(view.shortcut, "⌘T")
        let label = title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let key = title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(label?.alphaComponent, 1)
        XCTAssertEqual(key?.alphaComponent ?? 0, 0.6, accuracy: 0.01)
        XCTAssertEqual(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, title.attribute(.font, at: title.length - 1, effectiveRange: nil) as? NSFont,
                       "the same text")
        XCTAssertEqual(view.button.accessibilityLabel(), "New Tab (⌘T)")
        XCTAssertGreaterThanOrEqual(view.button.frame.width, title.size().width + 30, "room for both")
        let frame = view.button.convert(view.button.bounds, to: view)
        XCTAssertEqual(frame.midY, view.bounds.midY, accuracy: 120, "near the middle")
        view.button.performClick(nil)
        XCTAssertEqual(opened, 1)
    }

    func testUnreachableMachineOffersReconnect() throws {
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        var asked: [MachineKey] = []
        sidebar.onReconnect = { asked.append($0) }
        func texts(_ text: String) -> [NSTextField] {
            func all(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap(all) }
            return all(sidebar).filter { $0.stringValue == text }
        }
        func buttons() -> [NSButton] {
            func all(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap(all) }
            return all(sidebar).filter { $0.title.trimmingCharacters(in: .whitespaces) == "Reconnect" }
        }
        let group = { (paused: String?) in
            SidebarGroup(key: "devbox", title: "devbox", status: paused == nil ? (nil, "Checking devbox…") : AppDelegate.pausedStatus("devbox"),
                         workspaces: [], selected: nil, isConnected: true, isLocal: false, badges: [:], retryPaused: paused)
        }
        sidebar.update(agents: [], unreachable: [], groups: [group(nil)])
        XCTAssertTrue(buttons().isEmpty, "no button while it's still trying")
        sidebar.update(agents: [], unreachable: [("devbox", "Can't resolve devbox")], groups: [group("Can't resolve devbox")])
        XCTAssertTrue(texts("New Workspace").isEmpty, "no New Workspace on a machine it can't reach")
        let note = try XCTUnwrap(texts("devbox is unreachable, so its agents aren't shown").first)
        XCTAssertEqual(note.textColor, Theme.dimText, "muted, not red")
        let button = try XCTUnwrap(buttons().first)
        XCTAssertEqual(AppDelegate.pausedStatus("devbox").1, "Can't reach devbox")
        XCTAssertTrue(button.toolTip?.contains("Can't resolve devbox") == true, "the reason, on hover")
        button.performClick(nil)
        XCTAssertEqual(asked, ["devbox"])
    }
}
