import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Settings: one window with General and Machines tabs (no separate Machines window), opened on the
/// right tab by ⌘, and the sidebar's buttons, with the system's standard window buttons.
@MainActor
final class SettingsWindowTests: XCTestCase {
    private var suite = ""
    private var saved: UserDefaults!
    private var app: AppDelegate!

    override func setUp() {
        _ = NSApplication.shared
        suite = TestDefaults.name("settings")
        saved = Machine.store
        Machine.store = UserDefaults(suiteName: suite)!
        app = AppDelegate()
    }

    override func tearDown() {
        app.settingsWindow?.window?.close()
        TestDefaults.remove(suite)
        Machine.store = saved
    }

    func testSidebarButtonsOpenTheirTab() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        app.wireSettingsButtons(sidebar)

        sidebar.footer.machinesButton.performClick(nil)
        let settings = try XCTUnwrap(app.settingsWindow)
        XCTAssertEqual(settings.selectedTab, .machines)
        XCTAssertEqual(settings.window?.title, "Machines", "the title follows the tab")

        sidebar.footer.settingsButton.performClick(nil)
        XCTAssertTrue(app.settingsWindow === settings, "the same window, not a second one")
        XCTAssertEqual(settings.selectedTab, .general)
        XCTAssertEqual(settings.window?.title, "General")

        // ⌘, (Settings…) opens General; Manage Machines… opens Machines.
        app.showMachineManager(nil)
        XCTAssertEqual(settings.selectedTab, .machines)
        app.showSettings(nil)
        XCTAssertEqual(settings.selectedTab, .general)
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.title == "Machines" && $0 !== settings.window }.count, 0,
                       "no separate Machines window")
    }

    func testTwoToolbarTabsWithSymbols() throws {
        app.showSettings(nil)
        let settings = try XCTUnwrap(app.settingsWindow)
        XCTAssertEqual(settings.tabs.tabStyle, .toolbar)
        XCTAssertEqual(settings.window?.toolbarStyle, .preference)
        XCTAssertEqual(settings.tabs.tabViewItems.map(\.label), ["General", "Machines"])
        XCTAssertTrue(settings.tabs.tabViewItems.allSatisfy { $0.image != nil }, "each tab has its SF Symbol")
        XCTAssertFalse(settings.window?.styleMask.contains(.resizable) ?? true, "a fixed size per tab")
    }

    func testGeneralFitsWithoutScrolling() throws {
        app.showSettings(nil)
        let settings = try XCTUnwrap(app.settingsWindow)
        let general = settings.general.view
        XCTAssertNil(general.firstDescendant(of: NSScrollView.self), "General is a fixed form, not a scrolling page")
        XCTAssertEqual(settings.window?.contentLayoutRect.height ?? 0, general.fittingSize.height, accuracy: 1,
                       "the window is exactly as tall as its contents")
        XCTAssertEqual(settings.general.appearanceControl?.segmentCount, 3, "System, Light, Dark")
        XCTAssertEqual(general.descendants(of: NSSwitch.self).count, 4, "three notification switches and automatic updates")
    }

    func testMachinesListsThisMacFirstWithSwitchesAndStatus() throws {
        let imac = Machine.add(label: "imac", target: "macbook@imac")
        _ = Machine.add(label: "devbox", target: "ahmad@devbox")
        Machine.setEnabled(try XCTUnwrap(imac.id), false)
        app.showMachineManager(nil)
        let machines = try XCTUnwrap(app.settingsWindow?.machines)
        XCTAssertEqual(machines.machines.map(\.label), [Machine.local.label, "imac", "devbox"], "every saved machine, off ones too")
        XCTAssertEqual(machines.status(of: machines.machines[0]), .thisMac)
        XCTAssertEqual(machines.status(of: machines.machines[1]), .off)
        XCTAssertEqual(machines.status(of: machines.machines[2]), .notConnected)

        let row = try XCTUnwrap(machines.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let toggle = try XCTUnwrap(row.firstDescendant(of: NSSwitch.self))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertNil(machines.table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.firstDescendant(of: NSSwitch.self),
                     "this Mac can't be switched off")

        // +/−: − needs a removable selection.
        XCTAssertEqual(machines.addRemove.segmentCount, 2)
        machines.table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertFalse(machines.addRemove.isEnabled(forSegment: 1), "this Mac can't be removed")
        machines.table.selectRowIndexes([2], byExtendingSelection: false)
        XCTAssertTrue(machines.addRemove.isEnabled(forSegment: 1))
        XCTAssertEqual(machines.detailMachine.label, "devbox", "the details follow the selection")
    }

    func testRowStatus() {
        typealias S = MachineRowStatus
        XCTAssertEqual(S.of(isLocal: true, isEnabled: true, connected: true, paused: false, check: nil), .thisMac)
        XCTAssertEqual(S.of(isLocal: false, isEnabled: false, connected: true, paused: false, check: nil), .off)
        XCTAssertEqual(S.of(isLocal: false, isEnabled: true, connected: true, paused: false, check: nil), .connected)
        XCTAssertEqual(S.of(isLocal: false, isEnabled: true, connected: false, paused: false, check: nil), .connecting)
        XCTAssertEqual(S.of(isLocal: false, isEnabled: true, connected: false, paused: true, check: nil), .unreachable)
        XCTAssertEqual(S.of(isLocal: false, isEnabled: true, connected: nil, paused: false, check: .unreachable("no route")), .unreachable)
        XCTAssertEqual(S.of(isLocal: false, isEnabled: true, connected: nil, paused: false, check: .reachable), .notConnected)
        XCTAssertNil(S.off.color, "off is a hollow ring")
    }
}

/// The window buttons: the system's 14 pt buttons, 9 pt from the left edge, in every window.
@MainActor
final class WindowChromeTests: XCTestCase {
    private func geometry(_ window: NSWindow) throws -> (size: NSSize, left: CGFloat, centerFromTop: CGFloat) {
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = close.convert(close.bounds, to: nil)
        return (frame.size, frame.minX, window.frame.height - frame.midY)
    }

    func testMainWindowButtonsMatchATitledWindow() throws {
        _ = NSApplication.shared
        let titled = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        let standard = try geometry(titled)
        // The main window's own copies, in a corner as tall as the tab bar.
        let buttons = WindowButtons(target: self, close: #selector(NSObject.description), minimize: #selector(NSObject.description),
                                    fullScreen: #selector(NSObject.description))
        buttons.frame = NSRect(x: 0, y: 0, width: WindowButtons.width, height: TabBarView.height)
        buttons.layoutSubtreeIfNeeded()
        let copies = buttons.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(copies.count, 3)
        for (index, button) in copies.enumerated() {
            XCTAssertEqual(button.frame.size, standard.size, "the standard size")
            XCTAssertEqual(button.frame.minX, standard.left + CGFloat(index) * 20, "the standard inset and spacing")
            XCTAssertEqual(button.frame.midY, TabBarView.height / 2, accuracy: 0.5, "centred on the tab bar")
        }
    }

    func testSettingsAndPanelsUseTheStandardButtons() throws {
        _ = NSApplication.shared
        let titled = try geometry(NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                           styleMask: [.titled, .closable], backing: .buffered, defer: true))
        let app = AppDelegate()
        app.showSettings(nil)
        defer { app.settingsWindow?.window?.close() }
        let settings = try geometry(try XCTUnwrap(app.settingsWindow?.window))
        XCTAssertEqual(settings.size, titled.size)
        XCTAssertEqual(settings.left, titled.left)
        XCTAssertEqual(settings.centerFromTop, titled.centerFromTop, accuracy: 0.5)
        // Agent history: a regular panel, not a utility one (whose buttons are smaller).
        let history = AgentHistoryWindowController(app: app, key: PaneKey(machine: AppDelegate.localKey, pane: PaneID(1)), title: "History")
        let panel = try XCTUnwrap(history.window)
        XCTAssertFalse(panel.styleMask.contains(.utilityWindow))
        XCTAssertEqual(try geometry(panel).size, titled.size)
    }
}

extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in ((view as? T).map { [$0] } ?? []) + view.descendants(of: type) }
    }

    func firstDescendant<T: NSView>(of type: T.Type) -> T? { descendants(of: type).first }
}
