import AppKit
import ClothoFake
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
        XCTAssertEqual(general.descendants(of: NSSwitch.self).count, 5, "three notification switches, the Agents panel, automatic updates")
    }

    func testMachinesListsThisMacFirstWithSwitchesAndStatus() throws {
        let imac = Machine.add(label: "imac", target: "user@imac")
        _ = Machine.add(label: "devbox", target: "user@devbox")
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

/// Settings › Machines › "Summarize agent messages" says when the rewrite doesn't work on a machine
/// (clothod 0.1.31, feature `alerts`), in a caption that never grows past two lines.
@MainActor
final class RewriteHealthTests: XCTestCase {
    private typealias Health = DaemonSettings.RewriteHealth
    private static let plain = "Claude Haiku writes one line for notifications; off shows the message itself"
    private static let longReason = "exit 1: Not logged in · Please run /login, then try again: the saved credentials for this account expired on this machine"

    override func setUp() { _ = NSApplication.shared }

    func testCaptionForEachState() {
        let caption = MachinesSettingsController.rewriteCaption
        XCTAssertEqual(caption(Health(state: .failing, reason: "exit 1: Not logged in"), true).text, "Not working: exit 1: Not logged in")
        XCTAssertTrue(caption(Health(state: .failing, reason: "exit 1"), true).failing)
        XCTAssertEqual(caption(Health(state: .failing, reason: "two\nlines  here"), true).text, "Not working: two lines here")
        XCTAssertEqual(caption(Health(state: .failing), true).text, "Not working")
        XCTAssertEqual(caption(Health(state: .failing, reason: " "), true).text, "Not working")
        let missing = caption(Health(state: .unavailable), true)
        XCTAssertEqual(missing.text, "Claude Code wasn't found on this machine")
        XCTAssertFalse(missing.failing)
        for state in [Health.State.ok, .unknown, .off] {
            XCTAssertEqual(caption(Health(state: state, reason: "ignored"), true).text, Self.plain, "\(state)")
            XCTAssertFalse(caption(Health(state: state), true).failing)
        }
        XCTAssertEqual(caption(nil, true).text, Self.plain)
        // Without `alerts`, as before, whatever a daemon sends.
        XCTAssertEqual(caption(Health(state: .failing, reason: "exit 1"), false).text, Self.plain)
        XCTAssertFalse(caption(Health(state: .failing, reason: "exit 1"), false).failing)
    }

    private func group(caption: String, lines: Int?) -> (FormGroup, FormRow) {
        let row = FormRow("Summarize agent messages", caption: caption, captionColor: .systemRed, captionLines: lines, control: NSSwitch())
        let group = FormGroup([row])
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: SettingsStyle.width - 2 * SettingsStyle.margin).isActive = true
        group.layoutSubtreeIfNeeded()
        return (group, row)
    }

    func testALongReasonStaysWithinTwoLines() throws {
        let text = MachinesSettingsController.rewriteCaption(health: Health(state: .failing, reason: Self.longReason), alerts: true).text
        XCTAssertGreaterThan(text.count, 120)
        let (one, _) = group(caption: "Short", lines: 2)
        let (long, row) = group(caption: text, lines: 2)
        let (free, _) = group(caption: text + " " + text, lines: nil)
        let lineHeight = try XCTUnwrap(row.captionLabel).font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 14
        XCTAssertLessThanOrEqual(long.fittingSize.height, one.fittingSize.height + lineHeight + 2, "at most one line more than a short caption")
        XCTAssertGreaterThan(free.fittingSize.height, long.fittingSize.height, "uncapped, the same text would grow the row")
        XCTAssertEqual(row.captionLabel?.maximumNumberOfLines, 2)
        XCTAssertEqual(row.toolTip, text, "all of it on hover")
        XCTAssertLessThanOrEqual(try XCTUnwrap(row.captionLabel).frame.maxX, try XCTUnwrap(row.control).frame.minX, "never under the switch")
    }

    /// The Machines tab of the real window, on a fake machine whose rewrite is failing: the caption, the
    /// window as tall as its contents, nothing scrolling but the machine list. Writes review images with
    /// CLOTHO_SNAPSHOT_DIR set.
    func testMachinesTabWithAFailingMachine() async throws {
        let keys = ["Backend", "AgentNotifications", OnboardingController.doneKey, "LaunchInBackground", "FakeRewriteHealth"]
        var saved: [String: Any] = [:]
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        let suite = TestDefaults.name("rewrite-health"), machines = Machine.store
        Machine.store = UserDefaults(suiteName: suite)!
        let appearance = NSApp.appearance
        defer {
            for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
            TestDefaults.remove(suite)
            Machine.store = machines
            NSApp.appearance = appearance
            Theme.followAppAppearance()
        }
        UserDefaults.standard.set("fake", forKey: "Backend")
        UserDefaults.standard.set(false, forKey: "AgentNotifications")
        UserDefaults.standard.set(true, forKey: OnboardingController.doneKey)
        UserDefaults.standard.set(true, forKey: "LaunchInBackground")

        // The fake then says hello with what a 0.1.31 daemon has (settings, summary, alerts), and reports
        // a health no run has decided yet.
        UserDefaults.standard.set("unknown", forKey: "FakeRewriteHealth")

        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            app.settingsWindow?.window?.close()
            app.window?.orderOut(nil)
            app.connections.values.forEach { $0.store.stop() }
            UserPresence.shared?.stop()
        }
        func wait(_ what: String, _ done: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !done() {
                guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await wait("the fake's hello") { app.store.hello?.features.contains(.alerts) == true }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        app.showMachineManager(nil)
        let settings = try XCTUnwrap(app.settingsWindow), tab = settings.machines.view
        func row() -> FormRow? { tab.descendants(of: FormRow.self).first { $0.titleLabel.stringValue == "Summarize agent messages" } }
        try await wait("the machine's settings") { row() != nil }
        XCTAssertEqual(row()?.captionLabel?.stringValue, Self.plain, "not known yet: the plain caption")
        tab.layoutSubtreeIfNeeded()
        let plainHeight = tab.fittingSize.height

        for (name, health) in [("failing", Health(state: .failing, reason: Self.longReason)), ("unavailable", Health(state: .unavailable))] {
            fake.setRewriteHealth(health)
            let expected = MachinesSettingsController.rewriteCaption(health: health, alerts: true).text
            try await wait("the \(name) caption") { row()?.captionLabel?.stringValue == expected }
            let shown = try XCTUnwrap(row())
            XCTAssertEqual(shown.captionLabel?.textColor, name == "failing" ? .systemRed : .secondaryLabelColor)
            XCTAssertEqual((shown.control as? NSSwitch)?.isEnabled, true, "the switch still works")
            tab.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(tab.fittingSize.height, plainHeight + 16, "one caption line more at most")
            XCTAssertEqual(tab.descendants(of: NSScrollView.self).count, 1, "only the machine list scrolls")
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(settings.window?.contentLayoutRect.height ?? 0, tab.fittingSize.height, accuracy: 1,
                           "the window is exactly as tall as its contents")
            guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { continue }
            for (mode, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                NSApp.appearance = NSAppearance(named: look)
                settings.window?.appearance = NSApp.appearance
                tab.layoutSubtreeIfNeeded()
                tab.displayIfNeeded()
                guard let rep = tab.bitmapImageRepForCachingDisplay(in: tab.bounds) else { return XCTFail("no image") }
                // The tab draws no background of its own: the window's goes in first.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                tab.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: tab.bounds.size).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                tab.cacheDisplay(in: tab.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/alerts-settings-\(name)-\(mode).png"))
            }
        }
        // Working again: the plain caption is back.
        fake.setRewriteHealth(Health(state: .ok, at: 1))
        try await wait("the plain caption") { row()?.captionLabel?.stringValue == Self.plain }
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
