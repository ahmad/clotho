import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// A pane whose agent waits on a permission request the daemon can answer shows it in a bar at its
/// bottom, with Deny and Allow; ⌘↩ and ⌘. answer it from that pane's terminal. The bar takes rows while
/// it shows and gives them back.
@MainActor
final class AskBarTests: XCTestCase {
    private var window: NSWindow!
    private var backend: FakeBackend!
    private var store: ModelStore!
    private let git = PaneGit(repo: "clotho", root: "/p/clotho", branch: "main", head: "a1b2c3d")

    private var settleDelay: TimeInterval = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        // No wait between one request and the next, except where a test is about it.
        settleDelay = AskBar.settleDelay
        AskBar.settleDelay = 0
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        backend = FakeBackend(extraFeatures: ["agent.decide"])
        store = ModelStore(backend: backend)
        try await store.start()
    }

    override func tearDown() async throws {
        AskBar.settleDelay = settleDelay
        store.stop()
        window.close()
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func host(frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 400)) async throws -> (PaneHostView, PaneID) {
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        try await waitFor("the pane") { store.state.pane(created.pane) != nil }
        let host = PaneHostView(pane: store.state.pane(created.pane)!, store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.frame = frame
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return (host, created.pane)
    }

    /// What a sync gives the host, from the model.
    private func sync(_ host: PaneHostView, _ pane: PaneID, canDecide: Bool? = nil) {
        host.chrome = PaneChrome(agent: store.state.pane(pane)?.agent, command: store.state.pane(pane)?.command, cwd: "/p/clotho", home: nil,
                                 canDecide: canDecide ?? store.features.contains(.agentDecide))
        host.layoutSubtreeIfNeeded()
    }

    /// Puts an agent that waits on `requests` in the pane through the fake daemon, then syncs the host.
    private func ask(_ requests: [PermissionRequest]?, kind: String = "claude", in host: PaneHostView, _ pane: PaneID,
                     canDecide: Bool? = nil) async throws {
        let token = UUID().uuidString
        backend.setAgent(pane, AgentInfo(kind: kind, state: .waiting, source: "hook", session: token, requests: requests))
        try await waitFor("the agent") { store.state.pane(pane)?.agent?.session == token }
        sync(host, pane, canDecide: canDecide)
    }

    private func key(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags, isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: keyCode)!
    }

    private let npmTest = PermissionRequest(id: "r1", tool: "Bash", summary: "npm test")

    func testNoBarWithoutARequestItCanAnswer() async throws {
        let (host, pane) = try await host()
        XCTAssertNil(host.askBar, "a shell has none")
        try await ask(nil, in: host, pane)
        XCTAssertNil(host.askBar, "an agent that waits on no request")
        try await ask([], in: host, pane)
        XCTAssertNil(host.askBar)
        try await ask(nil, kind: "codex", in: host, pane)
        XCTAssertNil(host.askBar, "Codex sends none")
        try await ask([npmTest], in: host, pane, canDecide: false)
        XCTAssertNil(host.askBar, "a daemon without agent.decide can't answer it")
        XCTAssertEqual(host.askBarHeight, 0)
        try await ask([npmTest], in: host, pane)
        XCTAssertNotNil(host.askBar)
    }

    func testShowsTheRequestTakesRowsAndGivesThemBack() async throws {
        let (host, pane) = try await host()
        host.git = git
        host.isFocusedPane = true
        host.layoutSubtreeIfNeeded()
        let before = host.fittedSize()
        try await waitFor("the pane's first size") { store.state.pane(pane)?.rows == before.rows }

        try await ask([npmTest], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        XCTAssertEqual(bar.label.stringValue, "Allow Bash: npm test", "no question mark beside the buttons")
        XCTAssertEqual(bar.label.font?.isFixedPitch, true, "monospaced")
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(bar.label.frame.width, bar.label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).width,
                                    "with room to spare the request shows whole")
        XCTAssertTrue(bar.more.isHidden)
        XCTAssertEqual(bar.deny.title, "Deny")
        XCTAssertEqual(bar.deny.toolTip, "Deny (⌘.)")
        XCTAssertEqual(bar.allow.title, "Allow ⌘↩", "the key, on the focused pane")
        XCTAssertNotNil(bar.allow.bezelColor, "Allow is the prominent one")
        XCTAssertEqual(bar.allow.keyEquivalent, "", "no key equivalent: two panes can each have a bar")
        XCTAssertEqual(bar.deny.keyEquivalent, "")
        host.isFocusedPane = false
        XCTAssertEqual(bar.allow.title, "Allow", "only the focused pane's key works")
        host.isFocusedPane = true
        host.layoutSubtreeIfNeeded()

        // Above the git strip, 8 pt in from the sides and from the strip.
        let strip = try XCTUnwrap(host.gitStrip)
        XCTAssertEqual(bar.frame.minX, AskBar.margin, accuracy: 0.5)
        XCTAssertEqual(host.bounds.maxX - bar.frame.maxX, AskBar.margin, accuracy: 0.5)
        XCTAssertEqual(strip.frame.minY - bar.frame.maxY, AskBar.margin, accuracy: 0.5)
        XCTAssertFalse(bar.frame.intersects(strip.frame), "nothing overlaps the git strip")
        XCTAssertFalse(bar.frame.intersects(host.header.frame))

        // The terminal loses the bar's rows, and the daemon hears the new viewport.
        let with = host.fittedSize()
        XCTAssertLessThan(with.rows, before.rows, "rows for the bar")
        XCTAssertEqual(with.cols, before.cols)
        try await waitFor("the viewport with the bar") { store.state.pane(pane)?.rows == with.rows && host.paneSize.rows == with.rows }
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.terminal.frame.maxY, bar.frame.minY + 0.5, "the terminal ends above the bar")

        // A long command: "Allow " and the tail go, the tool and the command's start stay; the tooltip has it all.
        let command = "cd /a/very/long/path && " + (1...40).map { "step-\($0)" }.joined(separator: " && ")
        try await ask([PermissionRequest(id: "r2", tool: "Bash", summary: command)], in: host, pane)
        XCTAssertTrue(host.askBar === bar, "the same bar")
        XCTAssertEqual(bar.label.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(bar.label.stringValue, "Bash: \(command)", "the button says Allow")
        XCTAssertLessThan(bar.label.frame.width, bar.label.intrinsicContentSize.width, "truncated")
        XCTAssertEqual(bar.label.toolTip, "Allow Bash: \(command)")
        XCTAssertLessThanOrEqual(bar.label.frame.maxX, bar.deny.frame.minX, "never under the buttons")

        // Answered (here or anywhere): the bar goes and the rows come back.
        try await ask(nil, in: host, pane)
        XCTAssertNil(host.askBar)
        XCTAssertNil(bar.superview)
        XCTAssertEqual(host.fittedSize(), before)
        try await waitFor("the viewport without the bar") { store.state.pane(pane)?.rows == before.rows }
    }

    func testAllowAndDenyClicksDecideOnce() async throws {
        let (host, pane) = try await host()
        host.onDecide = { [backend] request, decision in
            Task { try? await backend!.decide(pane: pane, request: request, decision: decision, message: nil) }
        }
        try await ask([npmTest, PermissionRequest(id: "r2", tool: "Edit", summary: "main.swift")], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        XCTAssertEqual(bar.label.stringValue, "Allow Bash: npm test", "the oldest")
        XCTAssertEqual(bar.more.stringValue, "+1 more")
        XCTAssertFalse(bar.more.isHidden)
        XCTAssertLessThanOrEqual(bar.label.frame.maxX, bar.more.frame.minX)
        XCTAssertLessThanOrEqual(bar.more.frame.maxX, bar.deny.frame.minX)

        bar.allow.performClick(nil)
        XCTAssertFalse(bar.allow.isEnabled, "off until the request leaves the model")
        XCTAssertFalse(bar.deny.isEnabled)
        bar.allow.performClick(nil)
        bar.deny.performClick(nil)
        bar.decide(.deny)
        try await waitFor("the decision") { backend.decisions.count >= 1 }
        try await waitFor("the request leaving the model") { store.state.pane(pane)?.agent?.pendingRequests.map(\.id) == ["r2"] }
        XCTAssertEqual(backend.decisions.map(\.request), ["r1"], "sent once")
        XCTAssertEqual(backend.decisions.first?.decision, .allow)

        // The next one takes its place, with the buttons back on.
        sync(host, pane)
        XCTAssertTrue(host.askBar === bar)
        XCTAssertEqual(bar.label.stringValue, "Allow Edit: main.swift")
        XCTAssertTrue(bar.more.isHidden)
        XCTAssertTrue(bar.allow.isEnabled && bar.deny.isEnabled)
        bar.deny.performClick(nil)
        try await waitFor("the second decision") { backend.decisions.count == 2 }
        XCTAssertEqual(backend.decisions.last?.request, "r2")
        XCTAssertEqual(backend.decisions.last?.decision, .deny)
        try await waitFor("no requests") { store.state.pane(pane)?.agent?.pendingRequests.isEmpty == true }
        sync(host, pane)
        XCTAssertNil(host.askBar)
    }

    /// A decide that failed leaves the request in the model: the buttons come back after a moment.
    func testButtonsComeBackWhenTheRequestStays() async throws {
        let delay = AskBar.retryDelay
        AskBar.retryDelay = 0.2
        defer { AskBar.retryDelay = delay }
        let (host, pane) = try await host()
        var asked: [String] = []
        host.onDecide = { request, _ in asked.append(request) }
        try await ask([npmTest], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        bar.allow.performClick(nil)
        XCTAssertFalse(bar.isEnabled)
        sync(host, pane)
        XCTAssertFalse(bar.allow.isEnabled, "the same request, still off")
        try await waitFor("the buttons again") { bar.allow.isEnabled && bar.deny.isEnabled }
        bar.deny.performClick(nil)
        XCTAssertEqual(asked, ["r1", "r1"])
    }

    /// ⌘↩ and ⌘. are the ask's only while the keyboard is in that pane's terminal and a request shows there.
    func testKeysDecideOnlyFromThePanesOwnTerminal() async throws {
        let (asking, askingPane) = try await host(frame: NSRect(x: 0, y: 0, width: 440, height: 400))
        let (other, _) = try await host(frame: NSRect(x: 450, y: 0, width: 440, height: 400))
        let field = NSTextField(frame: NSRect(x: 0, y: 420, width: 200, height: 24))
        window.contentView!.addSubview(field)
        var decided: [String] = []
        asking.onDecide = { request, decision in decided.append("\(request) \(decision.rawValue)") }
        other.onDecide = { request, decision in decided.append("other \(request) \(decision.rawValue)") }
        try await ask([npmTest], in: asking, askingPane)
        XCTAssertNotNil(asking.askBar)
        XCTAssertNil(other.askBar)

        let allow = key(36, "\r", .command), deny = key(47, ".", .command)
        func handled(_ event: NSEvent) -> Bool { PaneHostView.handleAskKey(event, firstResponder: window.firstResponder) }

        // Another pane, a field (the command bar's, a name being edited) or the window itself has the keyboard.
        XCTAssertTrue(window.makeFirstResponder(other.terminal))
        XCTAssertFalse(handled(allow))
        XCTAssertFalse(handled(deny), "⌘. goes on to that terminal")
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(handled(allow), "⌘↩ stays the field's")
        XCTAssertFalse(handled(deny))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(handled(allow))
        XCTAssertFalse(handled(deny))
        XCTAssertEqual(decided, [])

        // In the asking pane: only the two keys, with Command alone.
        XCTAssertTrue(window.makeFirstResponder(asking.terminal))
        XCTAssertFalse(handled(key(36, "\r", [])), "plain Return is the terminal's")
        XCTAssertFalse(handled(key(36, "\r", [.command, .shift])), "⇧⌘↩ is Maximize Pane")
        XCTAssertFalse(handled(key(36, "\r", .control)), "⌃↩ renames the workspace")
        XCTAssertFalse(handled(key(47, ".", [])))
        XCTAssertFalse(handled(key(47, ".", [.command, .option])))
        XCTAssertFalse(handled(key(0, "a", .command)))
        XCTAssertEqual(decided, [])
        XCTAssertTrue(handled(deny))
        XCTAssertEqual(decided, ["r1 deny"])
        // Sent: more presses are swallowed, never sent twice (and never typed into the agent).
        XCTAssertTrue(handled(allow))
        XCTAssertTrue(handled(deny))
        XCTAssertEqual(decided, ["r1 deny"])

        try await ask([PermissionRequest(id: "r2", tool: "Edit", summary: "main.swift")], in: asking, askingPane)
        XCTAssertTrue(handled(allow))
        XCTAssertEqual(decided, ["r1 deny", "r2 allow"])
        try await ask([PermissionRequest(id: "r3", tool: "Bash", summary: "ls")], in: asking, askingPane)
        XCTAssertTrue(handled(key(76, "\u{3}", [.command, .numericPad])), "the keypad's Enter too")
        XCTAssertEqual(decided, ["r1 deny", "r2 allow", "r3 allow"])

        // No request showing: the keys go on untouched.
        try await ask(nil, in: asking, askingPane)
        XCTAssertNil(asking.askBar)
        XCTAssertFalse(handled(allow))
        XCTAssertFalse(handled(deny), "⌘. reaches the terminal as before")
        XCTAssertEqual(decided.count, 3)
    }

    func testFitsANarrowPane() async throws {
        let (host, pane) = try await host(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        host.git = git
        host.isFocusedPane = true
        try await ask([PermissionRequest(id: "r1", tool: "Bash", summary: "npm run build -- --production --verbose"),
                       PermissionRequest(id: "r2", tool: "Edit", summary: "main.swift")], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        // The request keeps the room: no "Allow " before it, no key on the button, no "+1 more".
        XCTAssertEqual(bar.label.stringValue, "Bash: npm run build -- --production --verbose")
        XCTAssertEqual(bar.label.lineBreakMode, .byTruncatingTail, "the tool and the command's start show")
        XCTAssertEqual(bar.allow.title, "Allow")
        XCTAssertTrue(bar.more.isHidden)
        XCTAssertEqual(bar.label.toolTip, "Allow Bash: npm run build -- --production --verbose")
        let character = ("M" as NSString).size(withAttributes: [.font: bar.label.font!]).width
        XCTAssertGreaterThanOrEqual(bar.label.frame.width, character * 9, "room for the tool and a word of the command")
        XCTAssertTrue(host.bounds.contains(bar.frame), "\(bar.frame)")
        for view in [bar.label, bar.deny, bar.allow] as [NSView] {
            XCTAssertTrue(bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.frame), "\(view.frame) in \(bar.bounds)")
        }
        XCTAssertGreaterThanOrEqual(bar.allow.frame.width, bar.allow.fittingSize.width - 0.5, "the buttons keep their titles")
        XCTAssertGreaterThanOrEqual(bar.deny.frame.width, bar.deny.fittingSize.width - 0.5)
        XCTAssertLessThanOrEqual(bar.deny.frame.maxX, bar.allow.frame.minX)
        XCTAssertLessThanOrEqual(bar.label.frame.maxX, bar.deny.frame.minX)
        XCTAssertGreaterThan(bar.label.frame.width, 0)
        if !bar.more.isHidden {
            XCTAssertLessThanOrEqual(bar.label.frame.maxX, bar.more.frame.minX)
            XCTAssertLessThanOrEqual(bar.more.frame.maxX, bar.deny.frame.minX)
        }
        XCTAssertFalse(bar.frame.intersects(try XCTUnwrap(host.gitStrip).frame))
        XCTAssertFalse(bar.frame.intersects(host.header.frame))

        // Wider: the key comes back first with the short text, then the whole of it.
        host.frame.size.width = 600
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.allow.title, "Allow ⌘↩")
        XCTAssertEqual(bar.label.stringValue, "Allow Bash: npm run build -- --production --verbose")
        XCTAssertFalse(bar.more.isHidden)
    }

    /// The label at the widths of ordinary split panes: the tool and the start of the command, never its end alone.
    func testANarrowLabelKeepsTheToolAndTheStartOfTheCommand() async throws {
        let (host, pane) = try await host(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let request = PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test -p clothod --test e2e holder_survives_a_server_restart")
        XCTAssertEqual(request.askSubject, "Bash: cargo test -p clothod --test e2e holder_survives_a_server_restart")
        XCTAssertEqual(PermissionRequest(id: "r2", tool: "Edit").askSubject, "Edit")
        try await ask([request], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        let character = ("M" as NSString).size(withAttributes: [.font: bar.label.font!]).width
        for width in [380, 320, 260, 220] as [CGFloat] {
            host.frame.size.width = width
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(bar.label.stringValue, request.askSubject, "at \(width)")
            XCTAssertGreaterThanOrEqual(bar.label.frame.width, character * 9, "\"Bash: ca…\" at the least, at \(width)")
            XCTAssertLessThanOrEqual(bar.label.frame.maxX, bar.deny.frame.minX)
        }
        // A short request shows whole where it fits, "Allow " and all.
        host.frame.size.width = 320
        try await ask([npmTest], in: host, pane)
        XCTAssertEqual(bar.label.stringValue, "Allow Bash: npm test")
        XCTAssertGreaterThanOrEqual(bar.label.frame.width, bar.label.textSize.width)
    }

    /// A held ⌘↩ (or ⌘.) answers one request: its repeats are swallowed, also once the next request shows.
    func testAHeldKeyAnswersOnlyTheRequestItWasPressedFor() async throws {
        let (host, pane) = try await host()
        var decided: [String] = []
        host.onDecide = { request, decision in decided.append("\(request) \(decision.rawValue)") }
        let second = PermissionRequest(id: "r2", tool: "Bash", summary: "rm -rf build")
        func handled(_ event: NSEvent) -> Bool { PaneHostView.handleAskKey(event, firstResponder: window.firstResponder) }
        for (keyCode, characters, decision) in [(36, "\r", "allow"), (47, ".", "deny")] as [(UInt16, String, String)] {
            decided = []
            try await ask([npmTest, second], in: host, pane)
            XCTAssertTrue(window.makeFirstResponder(host.terminal))
            XCTAssertTrue(handled(key(keyCode, characters, .command)))
            XCTAssertTrue(handled(key(keyCode, characters, .command, isARepeat: true)), "swallowed while the first is sent")
            XCTAssertEqual(decided, ["r1 \(decision)"])
            // The daemon drops the first; the second takes its place, with the buttons on (no settle delay here).
            try await ask([second], in: host, pane)
            let bar = try XCTUnwrap(host.askBar)
            XCTAssertEqual(bar.request.id, "r2")
            XCTAssertTrue(bar.isEnabled)
            for _ in 0..<5 {
                XCTAssertTrue(handled(key(keyCode, characters, .command, isARepeat: true)), "a repeat never reaches the terminal")
            }
            XCTAssertEqual(decided, ["r1 \(decision)"], "the held key didn't answer the request the user never read")
            // A new press does.
            XCTAssertTrue(handled(key(keyCode, characters, .command)))
            XCTAssertEqual(decided, ["r1 \(decision)", "r2 \(decision)"])
            try await ask(nil, in: host, pane)
            XCTAssertNil(host.askBar)
        }
    }

    /// A request that takes another's place can't be answered for a moment: a double tap, or a click
    /// aimed at the one before, doesn't answer it.
    func testANewRequestSettlesBeforeItCanBeAnswered() async throws {
        AskBar.settleDelay = 0.3
        let (host, pane) = try await host()
        var decided: [String] = []
        host.onDecide = { request, decision in decided.append("\(request) \(decision.rawValue)") }
        let second = PermissionRequest(id: "r2", tool: "Bash", summary: "rm -rf build")
        try await ask([npmTest, second], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        // The first request in the pane starts off too: a ⌘. meant as the agent's ESC, a ⌘↩ or a click
        // can be on its way as it arrives.
        XCTAssertFalse(bar.allow.isEnabled, "the first request in a pane settles like any other")
        XCTAssertFalse(bar.deny.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(host.terminal))
        let allow = key(36, "\r", .command)
        XCTAssertTrue(PaneHostView.handleAskKey(allow, firstResponder: window.firstResponder), "swallowed")
        XCTAssertTrue(PaneHostView.handleAskKey(key(47, ".", .command), firstResponder: window.firstResponder), "⌘. too: not typed into the agent")
        bar.allow.performClick(nil)
        bar.deny.performClick(nil)
        XCTAssertEqual(decided, [], "nothing answers a request the user never saw")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(bar.allow.isEnabled && bar.deny.isEnabled)
        XCTAssertTrue(PaneHostView.handleAskKey(allow, firstResponder: window.firstResponder))
        XCTAssertEqual(decided, ["r1 allow"])

        try await ask([second], in: host, pane)
        XCTAssertEqual(bar.label.stringValue, "Allow Bash: rm -rf build")
        XCTAssertFalse(bar.allow.isEnabled, "off while the new request settles")
        XCTAssertFalse(bar.deny.isEnabled)
        XCTAssertTrue(PaneHostView.handleAskKey(allow, firstResponder: window.firstResponder), "the second tap is swallowed")
        bar.allow.performClick(nil)
        bar.decide(.deny)
        sync(host, pane)
        XCTAssertFalse(bar.isEnabled, "a sync of the same request doesn't cut the wait short")
        XCTAssertEqual(decided, ["r1 allow"])

        try await waitFor("the buttons") { bar.allow.isEnabled && bar.deny.isEnabled }
        XCTAssertTrue(PaneHostView.handleAskKey(key(47, ".", .command), firstResponder: window.firstResponder))
        XCTAssertEqual(decided, ["r1 allow", "r2 deny"])

        // Answered elsewhere while it showed: the one after it settles too.
        try await ask([PermissionRequest(id: "r3", tool: "Edit", summary: "main.swift")], in: host, pane)
        XCTAssertFalse(bar.isEnabled)
        try await waitFor("the buttons again") { bar.isEnabled }
    }

    /// The agent has no request for an instant between two: the bar goes and a new one comes. The second
    /// tap of a double ⌘↩ (or a ⌘., or a click) meant for the first request doesn't answer the second.
    func testARequestRightAfterTheBarWentSettlesToo() async throws {
        // Long enough for the fake daemon's round trip between the bar going and the next request.
        AskBar.settleDelay = 0.6
        let (host, pane) = try await host()
        var decided: [String] = []
        host.onDecide = { request, decision in decided.append("\(request) \(decision.rawValue)") }
        let allow = key(36, "\r", .command), deny = key(47, ".", .command)
        func handled(_ event: NSEvent) -> Bool { PaneHostView.handleAskKey(event, firstResponder: window.firstResponder) }

        try await ask([npmTest], in: host, pane)
        XCTAssertEqual(host.askBar?.isEnabled, false, "every new bar starts off")
        XCTAssertTrue(window.makeFirstResponder(host.terminal))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(host.askBar?.isEnabled, true)
        XCTAssertTrue(handled(allow))
        XCTAssertEqual(decided, ["r1 allow"])
        // Allowed: the agent has no request, then asks for the next thing.
        try await ask([], in: host, pane)
        XCTAssertNil(host.askBar)
        try await ask([PermissionRequest(id: "r2", tool: "Bash", summary: "rm -rf build")], in: host, pane)
        let bar = try XCTUnwrap(host.askBar)
        XCTAssertEqual(bar.label.stringValue, "Allow Bash: rm -rf build")
        XCTAssertFalse(bar.allow.isEnabled, "a new bar right after the last one starts off")
        XCTAssertFalse(bar.deny.isEnabled)
        XCTAssertTrue(handled(allow), "the second tap is swallowed")
        XCTAssertTrue(handled(deny))
        bar.allow.performClick(nil)
        bar.deny.performClick(nil)
        sync(host, pane)
        XCTAssertTrue(host.askBar === bar)
        XCTAssertFalse(bar.isEnabled, "a sync doesn't cut the wait short")
        XCTAssertEqual(decided, ["r1 allow"], "nothing answered the request the user never read")

        // After the delay each of them answers.
        try await waitFor("the buttons") { bar.allow.isEnabled && bar.deny.isEnabled }
        XCTAssertTrue(handled(allow))
        XCTAssertEqual(decided, ["r1 allow", "r2 allow"])
        let answers: [(String, (AskBar) -> Void)] = [("deny", { _ in _ = handled(deny) }), ("allow", { $0.allow.performClick(nil) }),
                                                     ("deny", { $0.deny.performClick(nil) })]
        for (index, (decision, answer)) in answers.enumerated() {
            let id = "r\(index + 3)"
            try await ask([], in: host, pane)
            try await ask([PermissionRequest(id: id, tool: "Bash", summary: "ls")], in: host, pane)
            let next = try XCTUnwrap(host.askBar)
            XCTAssertFalse(next.isEnabled)
            answer(next)
            XCTAssertEqual(decided.count, index + 2, "refused while \(id) settles")
            try await waitFor("the buttons for \(id)") { next.allow.isEnabled && next.deny.isEnabled }
            answer(next)
            XCTAssertEqual(decided.last, "\(id) \(decision)")
        }

        // A bar long gone: the next request waits all the same (the pane rebuilt, or a request out of nowhere).
        try await ask([], in: host, pane)
        try await Task.sleep(nanoseconds: 800_000_000)
        try await ask([PermissionRequest(id: "r9", tool: "Edit", summary: "main.swift")], in: host, pane)
        let last = try XCTUnwrap(host.askBar)
        XCTAssertFalse(last.isEnabled)
        XCTAssertTrue(handled(deny), "swallowed")
        XCTAssertEqual(decided.count, 5)
        try await waitFor("the last bar's buttons") { last.isEnabled }
    }

    /// ⌘↩ and ⌘. wait again when they come to mean a bar that already shows: its pane took the keyboard
    /// (the user's click, another device's focus, a pane that exited), or its window became key. The
    /// buttons stay on: a click's target is the request under it.
    func testTheKeysWaitWhenTheyComeToMeanThisBar() async throws {
        AskBar.settleDelay = 0.3
        let (asking, askingPane) = try await host(frame: NSRect(x: 0, y: 0, width: 440, height: 400))
        let (other, _) = try await host(frame: NSRect(x: 450, y: 0, width: 440, height: 400))
        var decided: [String] = []
        asking.onDecide = { request, decision in decided.append("\(request) \(decision.rawValue)") }
        let allow = key(36, "\r", .command), deny = key(47, ".", .command)
        func handled(_ event: NSEvent) -> Bool { PaneHostView.handleAskKey(event, firstResponder: window.firstResponder) }

        XCTAssertTrue(window.makeFirstResponder(other.terminal))
        try await ask([npmTest], in: asking, askingPane)
        let bar = try XCTUnwrap(asking.askBar)
        try await waitFor("the buttons") { bar.isEnabled }
        // The keyboard comes to the asking pane: the request has shown for long, but not as the keys' target.
        XCTAssertTrue(window.makeFirstResponder(asking.terminal))
        XCTAssertTrue(bar.allow.isEnabled && bar.deny.isEnabled, "the buttons stay on")
        XCTAssertTrue(handled(allow), "swallowed")
        XCTAssertTrue(handled(deny))
        XCTAssertEqual(decided, [], "a press on its way to the other pane answers nothing here")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(handled(allow))
        XCTAssertEqual(decided, ["r1 allow"])

        // The window becomes key with the keyboard already in the pane.
        try await ask([PermissionRequest(id: "r2", tool: "Bash", summary: "rm -rf build")], in: asking, askingPane)
        try await waitFor("the buttons for r2") { bar.isEnabled }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(handled(allow))
        XCTAssertTrue(handled(deny))
        XCTAssertEqual(decided, ["r1 allow"])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(handled(deny))
        XCTAssertEqual(decided, ["r1 allow", "r2 deny"])

        // A click on Allow is the user's own, on the request under it: no wait for it.
        try await ask([PermissionRequest(id: "r3", tool: "Edit", summary: "main.swift")], in: asking, askingPane)
        try await waitFor("the buttons for r3") { bar.isEnabled }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        bar.allow.performClick(nil)
        XCTAssertEqual(decided, ["r1 allow", "r2 deny", "r3 allow"])
    }
}
