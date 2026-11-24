import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// One focus action sends one `pane.focus`, however many of its signals fire (first responder, window
/// key, app active, a click), and only for a pane that really has the user's focus.
@MainActor
final class PaneFocusTests: XCTestCase {
    func testOneActionSendsOneFocus() {
        var current: PaneKey? = PaneKey(machine: AppDelegate.localKey, pane: 7)
        var sent: [(PaneID, String)] = []
        var clock = Date(timeIntervalSince1970: 1000)
        let reporter = PaneFocusReporter(current: { current }) { key, reason in sent.append((key.pane, reason)) }
        reporter.now = { clock }

        // A click that activates the app: active, key, first responder, the click itself.
        for reason in ["app became active", "window became key", "pane took the keyboard", "click"] { reporter.note(reason) }
        reporter.flush()
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7], "one call for the whole action")
        XCTAssertEqual(sent.first?.1, "app became active", "named for what started it")

        // The same pane again right away is the same action.
        clock += 0.1
        reporter.note("click")
        reporter.flush()
        XCTAssertEqual(sent.count, 1)

        // Another pane (a tab switch) goes out at once.
        current = PaneKey(machine: AppDelegate.localKey, pane: 8)
        reporter.note("pane took the keyboard")
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7, 8])

        // Back in the same pane later (from the phone): a click sends again.
        clock += 5
        reporter.note("click")
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7, 8, 8])

        // Leaving and coming back quickly is still a new action.
        clock += 0.05
        reporter.forget()
        reporter.note("app became active")
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7, 8, 8, 8])

        // Nothing focused (another window is key, a field has the keyboard): nothing sent.
        current = nil
        clock += 5
        reporter.note("window became key")
        reporter.flush()
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(reporter.sent, 4)
    }

    func testNotesCoalesceOnTheRunLoop() async throws {
        var sent = 0
        let reporter = PaneFocusReporter(current: { PaneKey(machine: AppDelegate.localKey, pane: 1) }) { _, _ in sent += 1 }
        for _ in 0..<20 { reporter.note("storm") }
        XCTAssertEqual(sent, 0, "not sent inside the action")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sent, 1)
    }

    /// A focus change the user didn't make sends nothing, and the pane gets its `pane.focus` when the
    /// user next acts.
    func testAQuietChangeSendsNothingUntilTheUserActs() {
        var sent: [PaneID] = []
        let reporter = PaneFocusReporter(current: { PaneKey(machine: AppDelegate.localKey, pane: 3) }) { key, _ in sent.append(key.pane) }

        reporter.quietly { reporter.note("pane took the keyboard") }
        reporter.flush()
        XCTAssertEqual(sent, [], "nothing for a change the user didn't make")
        XCTAssertTrue(reporter.owed)

        // Notes work again after it, and the user's next key pays what's owed, once.
        reporter.userActed()
        reporter.flush()
        XCTAssertEqual(sent, [3])
        XCTAssertFalse(reporter.owed)
        reporter.userActed()
        reporter.flush()
        XCTAssertEqual(sent, [3], "nothing owed, nothing sent")

        // The user's own focus right after a quiet one settles it, and leaving drops it.
        reporter.quietly {}
        reporter.note("click")
        XCTAssertFalse(reporter.owed)
        reporter.quietly {}
        reporter.forget()
        XCTAssertFalse(reporter.owed)
    }
}

/// The keyboard follows the daemon's focus, but only the user's own focus is reported: a change with no
/// key or mouse event behind it (another device focused a pane, a pane exited) sends no `pane.focus` and
/// no focus-in report as input. clothod (0.1.31) reads both as the user being at the Mac and would hold a
/// phone push back for someone who isn't there.
///
/// A test's window is never key and the app never active, so `PaneTerminalView.assumesKeyWindow` stands
/// in for the key window (SwiftTerm then reports focus as it does in the app) and the reporter's
/// `current` for the user's pane.
@MainActor
final class QuietFocusTests: XCTestCase {
    private var input: [(pane: PaneID, bytes: Data)] = []
    private static let focusIn = Data("\u{1b}[I".utf8)
    private static let focusOut = Data("\u{1b}[O".utf8)
    /// A program that asks for focus reports (mode 1004) and then waits.
    private static let wantsFocusReports = SpawnOptions(command: ["/bin/sh", "-c", "printf '\\033[?1004h'; exec sleep 120"])

    override func setUp() async throws {
        _ = NSApplication.shared
        input = []
        PaneHostView.inputTap = { [weak self] pane, bytes in self?.input.append((pane, bytes)) }
        PaneTerminalView.assumesKeyWindow = true
    }

    override func tearDown() async throws {
        PaneHostView.inputTap = nil
        PaneTerminalView.assumesKeyWindow = false
        UserAction.recentOverride = nil
    }

    private func wait(_ what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private func sent(_ bytes: Data, from pane: PaneID) -> Int {
        input.filter { $0.pane == pane && $0.bytes == bytes }.count
    }

    /// Turns mode 1004 on in the hosts' terminals, once their first snapshot (which resets the terminal)
    /// is in. The panes' program asks for it too; this doesn't wait for its output.
    private func turnOnFocusReports(_ hosts: [PaneHostView]) async throws {
        let deadline = Date().addingTimeInterval(3)
        while hosts.contains(where: { $0.haveSeq == nil }), Date() < deadline { try await pause(0.02) }
        try await pause(0.3)
        for host in hosts { host.terminal.feedFromBackend(Data("\u{1b}[?1004h".utf8)) }
        // What a terminal sends reaches its host on the next turn of the main queue.
        try await pause(0.1)
    }

    /// The mechanism alone: a terminal taking the keyboard sends focus-in as the pane's input, and inside
    /// `withoutReplies` it doesn't. `withoutReplies` nests.
    func testATerminalTakingTheKeyboardReportsFocusUnlessRepliesAreOff() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        try await store.start()
        defer {
            store.stop()
            window.close()
        }
        let first = try await backend.createWorkspace(name: "One", spawn: Self.wantsFocusReports).pane
        let second = try await backend.split(first, direction: .right, ratio: nil, spawn: Self.wantsFocusReports).pane
        try await wait("the panes") { store.state.pane(first) != nil && store.state.pane(second) != nil }
        let hosts = [first, second].enumerated().map { index, pane in
            let host = PaneHostView(pane: store.state.pane(pane)!, store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
            host.frame = NSRect(x: CGFloat(index) * 450, y: 0, width: 450, height: 400)
            window.contentView!.addSubview(host)
            host.layoutSubtreeIfNeeded()
            return host
        }
        try await turnOnFocusReports(hosts)
        XCTAssertEqual(input.count, 0, "turning the mode on reports the focus inside a feed, which is dropped: \(input)")
        UserAction.recentOverride = false
        let unattributed = PaneHostView.unattributedInputCount

        // As the app did it for every focus change: focus-in goes out as the pane's input.
        XCTAssertTrue(window.makeFirstResponder(hosts[0].terminal))
        try await wait("focus-in from the terminal that took the keyboard") { !input.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(sent(Self.focusIn, from: first), 1, "a terminal taking the keyboard reports focus-in: \(input)")
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(PaneHostView.unattributedInputCount, unattributed + 1, "with no user event behind it")

        // With replies off, nothing from the terminal that takes the keyboard (the one losing it says so).
        let terminal = hosts[1].terminal
        terminal.withoutReplies { _ = window.makeFirstResponder(terminal) }
        XCTAssertTrue(window.firstResponder === terminal)
        try await wait("focus-out from the terminal that lost the keyboard") { sent(Self.focusOut, from: first) == 1 }
        try await pause(0.2)
        XCTAssertEqual(input.filter { $0.pane == second }.count, 0, "dropped: \(input)")
        XCTAssertEqual(input.count, 2, "\(input)")

        // A call inside another (a resize during a feed) leaves replies off until the outer one ends.
        XCTAssertFalse(terminal.isFeeding)
        terminal.withoutReplies {
            terminal.withoutReplies {}
            XCTAssertTrue(terminal.isFeeding, "the inner call restores, it doesn't clear")
        }
        XCTAssertFalse(terminal.isFeeding)
    }

    /// In the real window (the fake backend), with focus reports on in a pane: a focus change from the
    /// daemon's side sends `pane.focus` and focus-in when the user is behind it, and neither when not.
    func testADaemonFocusChangeIsOnlyReportedWithTheUserBehindIt() async throws {
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
            UserPresence.shared?.stop()
        }
        try await wait("a pane") { app.store.focusedPane != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        let reporter = try XCTUnwrap(app.paneFocusReporter)
        func host(_ pane: PaneID) -> PaneHostView? { app.paneHosts[PaneKey(machine: AppDelegate.localKey, pane: pane)] }

        // Two panes side by side: the first is the shell, the second asks for focus reports.
        let a = try XCTUnwrap(app.store.focusedPane?.id)
        let b = try await fake.split(a, direction: .right, ratio: nil, spawn: Self.wantsFocusReports).pane
        try await wait("the panes' views") { host(a)?.window != nil && host(b)?.window != nil }
        let hostA = try XCTUnwrap(host(a)), hostB = try XCTUnwrap(host(b))
        try await turnOnFocusReports([hostB])

        // The app isn't active under xctest and its window isn't key: the reporter takes the terminal with
        // the keyboard as the user's pane, so only the path under test decides what's sent.
        reporter.current = { [weak app] in
            (app?.window.firstResponder as? PaneTerminalView).map { PaneKey(machine: $0.machine, pane: $0.paneID) }
        }
        // Start from the first pane.
        UserAction.recentOverride = false
        try await fake.focus(.pane(a))
        try await wait("the keyboard on the first pane") { app.window.firstResponder === hostA.terminal }
        try await pause(0.4)
        input = []
        var focused = fake.focusedPanes

        // With the user behind it (a tab click, a shortcut): one pane.focus, and focus-in as input.
        UserAction.recentOverride = true
        try await fake.focus(.pane(b))
        try await wait("pane.focus for the pane the user focused") { fake.focusedPanes.count > focused.count }
        try await pause(0.4)
        XCTAssertEqual(fake.focusedPanes, focused + [b], "one pane.focus")
        XCTAssertTrue(app.window.firstResponder === hostB.terminal)
        XCTAssertEqual(sent(Self.focusIn, from: b), 1, "focus-in went out as the pane's input: \(input)")
        XCTAssertFalse(reporter.owed)

        // And back, the same way: the pane hears it lost the focus.
        try await fake.focus(.pane(a))
        try await wait("pane.focus for the first pane") { fake.focusedPanes.count > focused.count + 1 }
        try await pause(0.4)
        XCTAssertEqual(fake.focusedPanes, focused + [b, a])
        XCTAssertEqual(sent(Self.focusOut, from: b), 1, "\(input)")

        // The same change with no user event behind it (another device focused the pane): the keyboard
        // still follows, and the daemon hears nothing.
        UserAction.recentOverride = false
        input = []
        focused = fake.focusedPanes
        let unattributed = PaneHostView.unattributedInputCount
        try await fake.focus(.pane(b))
        try await wait("the keyboard on the pane the daemon focused") { app.window.firstResponder === hostB.terminal }
        try await pause(0.5)
        XCTAssertEqual(fake.focusedPanes, focused, "no pane.focus")
        XCTAssertEqual(input.filter { $0.pane == b }.count, 0, "no input for the pane, so no focus-in: \(input)")
        // (The shell in the first pane would say it lost the focus, if the user's shell asks for reports.)
        XCTAssertEqual(PaneHostView.unattributedInputCount, unattributed + input.count, "nothing sent with no user event behind it")
        XCTAssertTrue(reporter.owed)
        XCTAssertTrue(hostB.terminal.owesFocusIn, "the pane's app hasn't heard it has the focus")
        XCTAssertEqual(sent(Self.focusIn, from: b), 0, "\(input)")

        // The user's next key in the window gives the pane its pane.focus (and this Mac's size), and its
        // app the focus-in report that was held back: once.
        reporter.userActed()
        try await wait("the owed pane.focus") { fake.focusedPanes.count > focused.count }
        try await wait("the owed focus-in") { sent(Self.focusIn, from: b) > 0 }
        XCTAssertEqual(fake.focusedPanes, focused + [b])
        XCTAssertFalse(hostB.terminal.owesFocusIn)
        reporter.userActed()
        reporter.note("click")
        try await pause(0.4)
        XCTAssertEqual(sent(Self.focusIn, from: b), 1, "exactly one focus-in: \(input)")
        XCTAssertEqual(sent(Self.focusOut, from: b), 0, "\(input)")

        // Owed again, but the user goes to the other pane instead: the first one's report is dropped (it
        // hears focus-out, as any terminal losing the keyboard), not sent late.
        try await fake.focus(.pane(a))
        try await wait("the keyboard back on the first pane") { app.window.firstResponder === hostA.terminal }
        try await pause(0.4)
        input = []
        try await fake.focus(.pane(b))
        try await wait("the keyboard on the second pane again") { app.window.firstResponder === hostB.terminal }
        XCTAssertTrue(hostB.terminal.owesFocusIn)
        UserAction.recentOverride = true
        XCTAssertTrue(app.window.makeFirstResponder(hostA.terminal))
        try await pause(0.4)
        XCTAssertFalse(hostB.terminal.owesFocusIn)
        XCTAssertFalse(reporter.owed)
        XCTAssertEqual(sent(Self.focusIn, from: b), 0, "\(input)")
    }
}
