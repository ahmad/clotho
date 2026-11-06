import ClothoFake
@testable import ClothoKit
import XCTest

final class ModelTests: XCTestCase {
    // The example from docs/protocol.md ("Model"), plus an unknown field that must be ignored.
    static let stateJSON = """
    {
      "rev": 42,
      "focus": {"workspace": 1, "tab": 2, "pane": 3},
      "workspaces": [
        {"id": 1, "name": "main", "tabs": [
          {"id": 2, "title": null, "active_pane": 3,
           "layout": {"type": "split", "id": 9, "axis": "horizontal", "ratio": 0.5,
                      "a": {"type": "pane", "pane": 3},
                      "b": {"type": "pane", "pane": 4}}}
        ]}
      ],
      "panes": [
        {"id": 3, "cols": 120, "rows": 40, "pid": 9811, "command": ["/bin/zsh", "-l"],
         "title": "vim notes.md", "cwd": "/Users/user/notes", "seq": 183230, "exited": null, "future": 1},
        {"id": 4, "cols": 80, "rows": 24, "title": null, "cwd": null, "seq": 0, "exited": {"signal": 9}}
      ]
    }
    """

    func testDecodesProtocolState() throws {
        let state = try JSONDecoder().decode(ModelState.self, from: Data(Self.stateJSON.utf8))
        XCTAssertEqual(state.rev, 42)
        XCTAssertEqual(state.focus, Focus(workspace: 1, tab: 2, pane: 3))
        let tab = try XCTUnwrap(state.workspaces.first?.tabs.first)
        XCTAssertNil(tab.title)
        XCTAssertEqual(tab.activePane, 3)
        XCTAssertEqual(tab.layout, .split(id: 9, axis: .horizontal, ratio: 0.5, a: .pane(3), b: .pane(4)))
        XCTAssertEqual(state.pane(3)?.title, "vim notes.md")
        XCTAssertEqual(state.pane(4)?.exited, PaneExit(signal: 9))
        XCTAssertEqual(state.location(of: 4)?.tab.id, 2)
    }

    func testLayoutRoundTrips() throws {
        let layout = Layout.split(id: 1, axis: .vertical, ratio: 0.3, a: .pane(2),
                                  b: .split(id: 3, axis: .horizontal, ratio: 0.5, a: .pane(4), b: .pane(5)))
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: data), layout)
        XCTAssertEqual(layout.panes, [2, 4, 5])
    }
}

final class GeometryTests: XCTestCase {
    // 2 | 4
    // --+--
    //   5
    let layout = Layout.split(id: 1, axis: .vertical, ratio: 0.5,
                              a: .split(id: 3, axis: .horizontal, ratio: 0.5, a: .pane(2), b: .pane(4)),
                              b: .pane(5))

    func testFramesAndDividers() {
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 101, height: 101), divider: 1)
        XCTAssertEqual(frames.panes[2], CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(frames.panes[4], CGRect(x: 51, y: 0, width: 50, height: 50))
        XCTAssertEqual(frames.panes[5], CGRect(x: 0, y: 51, width: 101, height: 50))
        XCTAssertEqual(frames.dividers.map(\.split), [1, 3])
    }

    func testNeighbors() {
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 101, height: 101), divider: 1).panes
        XCTAssertEqual(Layout.neighbor(of: 2, toward: .right, in: frames), 4)
        XCTAssertEqual(Layout.neighbor(of: 4, toward: .left, in: frames), 2)
        XCTAssertEqual(Layout.neighbor(of: 4, toward: .down, in: frames), 5)
        XCTAssertNil(Layout.neighbor(of: 2, toward: .up, in: frames))
        XCTAssertNotNil(Layout.neighbor(of: 5, toward: .up, in: frames))
    }

    func testNearestSplit() {
        XCTAssertEqual(layout.nearestSplit(of: 4, axis: .horizontal)?.id, 3)
        XCTAssertEqual(layout.nearestSplit(of: 4, axis: .vertical)?.id, 1)
        XCTAssertNil(layout.nearestSplit(of: 5, axis: .horizontal))
    }

    func testRatioAtPoint() {
        let container = CGRect(x: 10, y: 0, width: 101, height: 50)
        XCTAssertEqual(Layout.ratio(at: CGPoint(x: 60.5, y: 0), in: container, axis: .horizontal, divider: 1), 0.5, accuracy: 0.001)
        XCTAssertEqual(Layout.ratio(at: CGPoint(x: 0, y: 0), in: container, axis: .horizontal, divider: 1), 0.05)
    }
}

/// Drives FakeBackend with real shells.
final class FakeBackendTests: XCTestCase {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SessionEvent] = []
        func add(_ event: SessionEvent) { lock.withLock { events.append(event) } }
        var all: [SessionEvent] { lock.withLock { events } }

        func output(of pane: PaneID) -> String {
            var bytes = Data()
            for event in all {
                if case let .output(p, _, b) = event, p == pane { bytes.append(b) }
                if case let .snapshot(p, _, _, _, b) = event, p == pane { bytes = b }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        var lastState: ModelState? {
            for event in all.reversed() { if case .state(let s) = event { return s } }
            return nil
        }
    }

    func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testShellLifecycle() async throws {
        let backend = FakeBackend()
        let collector = Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }

        try await backend.start()
        // A known prompt marks the moment the shell has finished printing and is idle.
        let created = try await backend.createWorkspace(name: "test", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp", env: ["PS1": "READY> "]))
        let first = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: nil, viewport: Size(cols: 100, rows: 30))
        XCTAssertEqual(first.mode, .snapshot)
        XCTAssertEqual(first.cols, 100)

        backend.sendInput(created.pane, Data("echo hel''lo-clotho\n".utf8))
        try await waitFor("echo output and the next prompt") {
            let output = collector.output(of: created.pane)
            return output.contains("hello-clotho") && output.hasSuffix("READY> ")
        }

        // Resuming from the current seq is live; from an earlier seq, a replay of exactly the gap.
        let seq = try XCTUnwrap(collector.all.compactMap { e -> UInt64? in
            if case let .output(p, s, b) = e, p == created.pane { return s + UInt64(b.count) }
            return nil
        }.last)
        let live = try await backend.subscribe(created.pane, haveSeq: seq, scrollback: nil, viewport: nil)
        XCTAssertEqual(live.mode, .live)
        let replay = try await backend.subscribe(created.pane, haveSeq: 0, scrollback: nil, viewport: nil)
        XCTAssertEqual(replay.mode, .replay)
        XCTAssertEqual(replay.seq, 0)
        let future = try await backend.subscribe(created.pane, haveSeq: seq + 1000, scrollback: nil, viewport: nil)
        XCTAssertEqual(future.mode, .snapshot)

        // Split right, then the new pane's exit removes it and collapses the split.
        let split = try await backend.split(created.pane, direction: .right, ratio: nil, spawn: SpawnOptions(command: ["/bin/sh"]))
        // Events arrive on the reader task, which may not have caught up when a command returns.
        try await waitFor("split state") {
            collector.lastState?.workspaces.first?.tabs.first?.layout
                == .split(id: split.split, axis: .horizontal, ratio: 0.5, a: .pane(created.pane), b: .pane(split.pane))
        }
        XCTAssertEqual(collector.lastState?.focus.pane, split.pane)
        backend.sendInput(split.pane, Data("exit 3\n".utf8))
        try await waitFor("pane removal") {
            collector.lastState?.workspaces.first?.tabs.first?.layout == .pane(created.pane)
        }
        XCTAssertTrue(collector.all.contains { e in
            if case let .pane(p, _) = e { return p.id == split.pane && p.exited == PaneExit(code: 3) }
            return false
        })
        XCTAssertEqual(collector.lastState?.focus.pane, created.pane)

        // Closing the last pane closes the tab but keeps the workspace.
        try await backend.closePane(created.pane)
        try await waitFor("last pane closed") { collector.lastState?.workspaces.first?.tabs.isEmpty == true }
        XCTAssertEqual(collector.lastState?.workspaces.count, 1)
        XCTAssertEqual(collector.lastState?.workspaces.first?.tabs.count, 0)
    }

    /// OSC 52 copies become clipboard events for the subscribed client; reads get nothing.
    func testClipboardFromOSC52() async throws {
        let backend = FakeBackend()
        let collector = Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }

        try await backend.start()
        // "hello clip" in base64, then a read, then a second copy with ST instead of BEL.
        let script = "printf '\\033]52;c;aGVsbG8gY2xpcA==\\007'; printf '\\033]52;c;?\\007'; printf 'done-''-printing\\n'; sleep 5"
        let created = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(command: ["/bin/sh", "-c", script]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: nil, viewport: nil)
        try await waitFor("output") { collector.output(of: created.pane).contains("done--printing") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let clips = collector.all.compactMap { e -> String? in
            if case let .clipboard(p, text, selection) = e, p == created.pane, !selection { return text }
            return nil
        }
        XCTAssertEqual(clips, ["hello clip"])
    }

    /// Attention, as in clothod 0.1.9: input (keys, a reply) leaves it; only ack or running clears it.
    func testAttentionClearsOnlyOnAckOrRunning() async throws {
        let backend = FakeBackend()
        let collector = Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        let created = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(command: ["/bin/sh"]))
        let attention = { try await backend.getState().pane(created.pane)?.agent?.attention }

        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook"))
        var now = try await attention()
        XCTAssertEqual(now, true)
        try await backend.sendKeys(created.pane, text: "yes", keys: ["enter"])
        backend.sendInput(created.pane, Data("\u{1b}[I".utf8))
        now = try await attention()
        XCTAssertEqual(now, true, "typing or replying doesn't resolve")
        try await backend.ackAgent(created.pane)
        now = try await attention()
        XCTAssertEqual(now, false, "the checkmark does")

        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .done, source: "hook"))
        now = try await attention()
        XCTAssertEqual(now, true)
        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .running, source: "hook"))
        now = try await attention()
        XCTAssertNotEqual(now, true, "working again clears it")
    }

    /// A muted agent stays quiet through new done/waiting/error until unmuted; a new agent starts unmuted.
    func testMutedAgentsStayQuiet() async throws {
        let backend = FakeBackend()
        defer { backend.stop() }
        try await backend.start()
        let created = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(command: ["/bin/sh"]))
        let agent = { try await backend.getState().pane(created.pane)?.agent }

        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook"))
        var now = try await agent()
        XCTAssertEqual(now?.needsAttention, true)
        try await backend.muteAgent(created.pane, muted: true)
        now = try await agent()
        XCTAssertEqual(now?.isMuted, true)
        XCTAssertEqual(now?.needsAttention, false, "muting clears it")
        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .done, source: "hook"))
        now = try await agent()
        XCTAssertEqual(now?.needsAttention, false, "a new done doesn't bring it back")
        XCTAssertEqual(now?.isMuted, true)

        try await backend.muteAgent(created.pane, muted: false)
        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .error, source: "hook"))
        now = try await agent()
        XCTAssertEqual(now?.needsAttention, true, "unmuted, the next raise counts")

        try await backend.muteAgent(created.pane, muted: true)
        backend.setAgent(created.pane, AgentInfo(kind: "codex", state: .waiting))
        now = try await agent()
        XCTAssertEqual(now?.isMuted, false, "a new agent session starts unmuted")
        XCTAssertEqual(now?.needsAttention, true)
    }

    func testTerminalQueriesAreAnsweredByTheBackend() async throws {
        let backend = FakeBackend()
        let collector = Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }

        try await backend.start()
        // Ask for the cursor position (DSR 6) and print whatever comes back as hex.
        let script = "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -tx1; stty sane"
        let created = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(command: ["/bin/sh", "-c", script + "; sleep 5"]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: nil, viewport: nil)
        // ESC [ 1 ; 1 R
        try await waitFor("DSR reply") {
            collector.output(of: created.pane).split(separator: " ").joined(separator: " ").contains("1b 5b 31 3b 31 52")
        }
    }
}

final class FakeResizeTests: XCTestCase {
    func testResizeReachesThePTY() async throws {
        let backend = FakeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        let created = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(command: ["/bin/sh"]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: nil, viewport: Size(cols: 100, rows: 30))
        for size in [Size(cols: 71, rows: 19), Size(cols: 133, rows: 41)] {
            try await backend.setViewport(created.pane, size)
            backend.sendInput(created.pane, Data("stty size\n".utf8))
            let expected = "\(size.rows) \(size.cols)"
            let deadline = Date().addingTimeInterval(5)
            while !collector.output(of: created.pane).contains(expected) {
                if Date() > deadline { return XCTFail("PTY never reported \(expected)") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

final class PushModelTests: XCTestCase {
    func testDecodesPushList() throws {
        let json = #"[{"device": "d1", "label": "mac", "relay": "https://r", "env": "sandbox", "created": 1761512345.5, "last_error": "410"}]"#
        let devices = try JSONDecoder().decode([PushDevice].self, from: Data(json.utf8))
        XCTAssertEqual(devices, [PushDevice(device: "d1", label: "mac", relay: "https://r", env: "sandbox", created: 1761512345.5, lastError: "410")])
        XCTAssertEqual(Hello.Feature(rawValue: "push"), .push)
    }

    func testDecodesPushActivities() throws {
        let json = #"[{"pane": 7, "device": "d1", "created": 1761512345.5, "last_error": null}, {"pane": 9, "device": "d2", "created": 1761512346, "last_error": "relay: 429"}]"#
        let activities = try JSONDecoder().decode([PushActivity].self, from: Data(json.utf8))
        XCTAssertEqual(activities, [PushActivity(pane: 7, device: "d1", created: 1761512345.5),
                                    PushActivity(pane: 9, device: "d2", created: 1761512346, lastError: "relay: 429")])
        XCTAssertEqual(Hello.Feature(rawValue: "push.activity"), .pushActivity)
    }
}

final class DisplayTitleTests: XCTestCase {
    func testStripsOnlyALeadingStatusGlyph() {
        XCTAssertEqual(Pane.displayTitle("✳ SSH status on this machine", cwd: "/x"), "SSH status on this machine")
        XCTAssertEqual(Pane.displayTitle("⠐ Fixing tests", cwd: "/x"), "Fixing tests")
        XCTAssertEqual(Pane.displayTitle("✶  Thinking", cwd: nil), "Thinking")
        XCTAssertEqual(Pane.displayTitle("✳ Claude Code", cwd: "/Users/a/macbook-analytics-app"), "macbook-analytics-app")
        XCTAssertEqual(Pane.displayTitle("Claude Code", cwd: nil), "Claude Code")
        // Left alone: no symbol, a symbol not followed by a space, or ordinary punctuation.
        XCTAssertEqual(Pane.displayTitle("vim notes.md", cwd: "/x"), "vim notes.md")
        XCTAssertEqual(Pane.displayTitle("✳notes", cwd: nil), "✳notes")
        XCTAssertEqual(Pane.displayTitle("#1 build", cwd: nil), "#1 build")
        XCTAssertEqual(Pane.displayTitle("(main) repo", cwd: nil), "(main) repo")
        XCTAssertEqual(Pane.displayTitle("user@mac: ~", cwd: nil), "user@mac: ~")
        XCTAssertNil(Pane.displayTitle("✳ ", cwd: nil))
        XCTAssertNil(Pane.displayTitle(nil, cwd: "/x"))
    }
}

/// ModelStore hands clipboard events to the pane's sink, and only to it.
@MainActor
final class ClipboardRoutingTests: XCTestCase {
    final class Sink: PaneDataSink {
        var clips: [(String, Bool)] = []
        func paneSubscribed(_ subscription: Subscription) {}
        func paneOutput(seq: UInt64, bytes: Data) {}
        func paneSnapshot(seq: UInt64, cols: Int, rows: Int, bytes: Data) {}
        func paneResized(cols: Int, rows: Int, seq: UInt64) {}
        func paneResync() {}
        func paneReset() {}
        func paneClipboard(text: String, selection: Bool) { clips.append((text, selection)) }
    }

    /// A sink written before paneClipboard existed still conforms.
    final class OldSink: PaneDataSink {
        func paneSubscribed(_ subscription: Subscription) {}
        func paneOutput(seq: UInt64, bytes: Data) {}
        func paneSnapshot(seq: UInt64, cols: Int, rows: Int, bytes: Data) {}
        func paneResized(cols: Int, rows: Int, seq: UInt64) {}
        func paneResync() {}
        func paneReset() {}
    }

    func testRoutesToThePanesSink() {
        let store = ModelStore(backend: FakeBackend())
        let sink = Sink(), other = Sink(), old = OldSink()
        store.register(sink, for: 1)
        store.register(other, for: 2)
        store.register(old, for: 3)
        store.apply(.clipboard(1, text: "copied", selection: false))
        store.apply(.clipboard(1, text: "primary", selection: true))
        store.apply(.clipboard(3, text: "ignored", selection: false))
        store.apply(.clipboard(4, text: "no sink", selection: false))
        XCTAssertEqual(sink.clips.map(\.0), ["copied", "primary"])
        XCTAssertEqual(sink.clips.map(\.1), [false, true])
        XCTAssertTrue(other.clips.isEmpty)
    }
}

/// `quiet` (agent.quiet): a rise of attention while the user was at the pane is badged but not announced.
final class QuietRiseTests: XCTestCase {
    private func decode(_ json: String) throws -> AgentInfo {
        try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    }

    func testDecodesQuietAndTreatsMissingAsFalse() throws {
        let quiet = try decode(#"{"kind":"claude","state":"done","attention":true,"quiet":true}"#)
        XCTAssertEqual(quiet.quietRise, true)
        XCTAssertTrue(quiet.isQuietRise)
        XCTAssertTrue(quiet.needsAttention, "still attention: badged and shown")
        let older = try decode(#"{"kind":"claude","state":"done","attention":true}"#)
        XCTAssertNil(older.quietRise)
        XCTAssertFalse(older.isQuietRise)
        let loud = try decode(#"{"kind":"claude","state":"done","attention":true,"quiet":false}"#)
        XCTAssertFalse(loud.isQuietRise)
    }

    func testEncodesAsQuiet() throws {
        let info = AgentInfo(kind: "claude", state: .done, attention: true, quietRise: true)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(info), encoding: .utf8))
        XCTAssertTrue(json.contains(#""quiet":true"#), json)
        XCTAssertEqual(try decode(json), info)
    }

    func testNotifiesOnlyOnLoudRises() {
        let running = AgentInfo(kind: "claude", state: .running, attention: false)
        let done = AgentInfo(kind: "claude", state: .done, attention: true)
        XCTAssertTrue(done.notifiesRise(from: running))
        XCTAssertTrue(done.notifiesRise(from: nil))
        var quiet = done
        quiet.quietRise = true
        XCTAssertFalse(quiet.notifiesRise(from: running), "the user was at the pane")
        XCTAssertFalse(done.notifiesRise(from: done), "no rise: attention was already up")
        var muted = done
        muted.muted = true
        XCTAssertFalse(muted.notifiesRise(from: running))
        XCTAssertFalse(AgentInfo(kind: "claude", state: .running, attention: true).notifiesRise(from: nil))
        XCTAssertTrue(AgentInfo(kind: "claude", state: .waiting, attention: true, quietRise: false).notifiesRise(from: running))
    }
}

/// Notification text, shared by the Mac and iOS: "Platform · Claude finished" / "devbox · api-server · 4m" / result.
final class AgentNoticeTests: XCTestCase {
    func testDecodesTheDetailFields() throws {
        let json = #"{"kind":"claude","state":"waiting","attention":true,"message":"Claude needs your permission to use Bash","#
            + #""prompt":"run the tests","tool":"Bash","tool_input":"npm test","turn_started":1000.5,"since":1240.5}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.prompt, "run the tests")
        XCTAssertEqual(info.tool, "Bash")
        XCTAssertEqual(info.toolInput, "npm test")
        XCTAssertEqual(info.turnStarted, 1000.5)
        XCTAssertEqual(try JSONDecoder().decode(AgentInfo.self, from: JSONEncoder().encode(info)), info, "round trip")
        let old = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"claude","state":"done"}"#.utf8))
        XCTAssertNil(old.prompt)
        XCTAssertNil(old.tool)
        XCTAssertNil(old.turnDuration)
    }

    func testFinished() {
        let info = AgentInfo(kind: "claude", state: .done, message: "All 42 tests pass. I also fixed the flaky retry test.",
                             since: 1240, attention: true, turnStarted: 1000)
        let notice = AgentNotice(info: info, machine: "devbox", workspace: "Platform", cwd: "/home/user/api-server/")
        XCTAssertEqual(notice.title, "Platform · Claude finished")
        XCTAssertEqual(notice.subtitle, "devbox · api-server · 4m")
        XCTAssertEqual(notice.body, "All 42 tests pass. I also fixed the flaky retry test.")
    }

    func testPermissionWait() {
        let info = AgentInfo(kind: "claude", state: .waiting, message: "Claude needs your permission to use Bash",
                             since: 1240, attention: true, tool: "Bash", toolInput: "npm test", turnStarted: 1000)
        let notice = AgentNotice(info: info, machine: "devbox", workspace: "Platform", cwd: "/srv/api-server")
        XCTAssertEqual(notice.title, "Platform · Claude is waiting")
        XCTAssertEqual(notice.subtitle, "devbox · api-server", "no time while the turn is still going")
        XCTAssertEqual(notice.body, "Allow Bash: npm test?")
        // Waiting for an answer, not a permission: the agent's own words.
        var question = info
        question.message = "Claude is waiting for your input"
        XCTAssertEqual(AgentNotice(info: question, machine: "m").body, "Claude is waiting for your input")
    }

    func testOlderDaemonKeepsTodaysTitle() {
        let info = AgentInfo(kind: "codex", state: .error, message: "rate limited", attention: true)
        let notice = AgentNotice(info: info, machine: "imac")
        XCTAssertEqual(notice.title, "Codex hit an error on imac")
        XCTAssertEqual(notice.subtitle, "")
        XCTAssertEqual(notice.body, "rate limited")
        let finished = AgentNotice(info: AgentInfo(kind: "claude", state: .done), machine: "devbox", cwd: "/srv/api")
        XCTAssertEqual(finished.title, "Claude finished on devbox")
        XCTAssertEqual(finished.subtitle, "api", "no machine in the subtitle when it's in the title")
    }

    func testPermissionOnlyForPermissionWaits() {
        func body(_ state: String, _ message: String?, _ tool: String? = "Bash", _ input: String? = "ls -la") -> String {
            AgentNotice(kind: "claude", state: state, machine: "m", workspace: "W", project: nil, duration: nil,
                        result: message, tool: tool, toolInput: input).body
        }
        XCTAssertEqual(body("waiting", "Claude needs your permission to use Bash"), "Allow Bash: ls -la?")
        XCTAssertEqual(body("waiting", nil), "Allow Bash: ls -la?", "no message: a permission wait")
        XCTAssertEqual(body("waiting", "", "Bash", nil), "Allow Bash?")
        XCTAssertEqual(body("waiting", nil, "Bash", "npm\n  test"), "Allow Bash: npm test?", "input on one line")
        XCTAssertEqual(body("waiting", "Which database should I use?"), "Which database should I use?",
                       "a question, though the turn's last tool was Bash")
        XCTAssertEqual(body("waiting", "Claude is waiting for your input", nil, nil), "Claude is waiting for your input")
        XCTAssertEqual(body("done", nil), "", "a done turn never says Allow")
        XCTAssertEqual(body("done", "Shipped it."), "Shipped it.")
    }

    func testFieldInitMatchesInfoInit() {
        let info = AgentInfo(kind: "claude", state: .done, message: "Done.", since: 1240, attention: true,
                             prompt: "fix it", turnStarted: 1000)
        let fromInfo = AgentNotice(info: info, machine: "devbox", workspace: "Platform", cwd: "/x/api-server")
        let fromRecord = AgentNotice(kind: "claude", state: "done", machine: "devbox", workspace: "Platform", project: "api-server",
                                     duration: 240, result: "Done.", tool: nil, toolInput: nil)
        XCTAssertEqual(fromInfo, fromRecord)
        XCTAssertEqual(AgentNotice(kind: "claude", state: "napping", machine: "", workspace: nil, project: nil, duration: nil,
                                   result: nil, tool: nil, toolInput: nil, fallback: "Tab 2").title, "Claude changed")
        // No result: the prompt.
        var quietTurn = info
        quietTurn.message = nil
        XCTAssertEqual(AgentNotice(info: quietTurn, machine: "b").body, "fix it")
    }

    func testPartsAndLimits() {
        XCTAssertEqual(AgentNotice.duration(0.4), nil)
        XCTAssertEqual(AgentNotice.duration(12), "12s")
        XCTAssertEqual(AgentNotice.duration(3600), "1h")
        XCTAssertEqual(AgentNotice.duration(3900), "1h 5m")
        XCTAssertEqual(AgentNotice.project("/"), nil)
        XCTAssertEqual(AgentNotice.project("~"), nil)
        XCTAssertEqual(AgentNotice.project("~/code/web"), "web")
        let long = String(repeating: "word ", count: 100)
        let clipped = AgentNotice.clip(long, to: 40)
        XCTAssertLessThanOrEqual(clipped.count, 40)
        XCTAssertTrue(clipped.hasSuffix("word…"), clipped)
        XCTAssertEqual(AgentNotice.clip("two\n  lines", to: 40), "two lines")
    }
}

/// A saved model shows until the daemon's arrives, which replaces it whole.
@MainActor
final class SavedStateTests: XCTestCase {
    private func model(_ name: String, agent: AgentInfo? = nil) -> ModelState {
        ModelState(rev: 7, focus: Focus(), workspaces: [Workspace(id: 1, name: name, tabs: [Tab(id: 2, activePane: 3, layout: .pane(3))])],
                   panes: [Pane(id: 3, cols: 80, rows: 24, cwd: "/srv/api", agent: agent)])
    }

    private func hello(_ instance: String, features: [String] = []) -> Hello {
        var hello = Hello(protocol: 1, daemon: "clothod", version: "0.1.13", instance: instance)
        hello.featureNames = features
        return hello
    }

    func testRestoreThenLiveReplacesWhole() throws {
        let store = ModelStore(backend: FakeBackend())
        let waiting = AgentInfo(kind: "claude", state: .waiting, attention: true)
        let cached = CachedMachineState(state: model("Saved", agent: waiting), lastSeen: Date(timeIntervalSince1970: 100),
                                        daemonVersion: "0.1.12", instance: "a", featureNames: ["pane.keys", "agent.mute"])
        store.restore(cached)
        XCTAssertEqual(store.phase, .saved)
        XCTAssertEqual(store.state.workspaces.first?.name, "Saved")
        XCTAssertTrue(store.features.contains(.paneKeys), "saved features gate the UI before hello")
        XCTAssertEqual(store.cacheSnapshot(), cached, "a saved model saves back unchanged")

        var changes: [PaneID] = []
        store.onAgentChange = { pane, _, _ in changes.append(pane) }
        store.apply(.agent(3, AgentInfo(kind: "claude", state: .done, attention: true)))
        XCTAssertEqual(store.state.pane(3)?.agent, waiting, "events for the saved model are ignored")
        store.apply(.connected(hello("a")))
        XCTAssertEqual(store.phase, .saved, "still saved until the state arrives")
        XCTAssertTrue(store.features.isEmpty, "live features once connected")

        store.apply(.state(ModelState(rev: 9, focus: Focus(), workspaces: [], panes: [])))
        XCTAssertEqual(store.phase, .live)
        XCTAssertNil(store.saved)
        XCTAssertTrue(store.state.workspaces.isEmpty, "replaced, not merged")
        XCTAssertTrue(changes.isEmpty, "no agent callbacks for the swap")
        store.restore(cached)
        XCTAssertEqual(store.phase, .live, "a cache never replaces live data")
    }

    func testSnapshotOfLiveModel() throws {
        let store = ModelStore(backend: FakeBackend())
        store.apply(.connected(hello("b", features: ["agent.history"])))
        store.apply(.state(model("Live")))
        let now = Date(timeIntervalSince1970: 500)
        let snapshot = store.cacheSnapshot(now: now)
        XCTAssertEqual(snapshot.lastSeen, now)
        XCTAssertEqual(snapshot.instance, "b")
        XCTAssertEqual(snapshot.daemonVersion, "0.1.13")
        XCTAssertEqual(snapshot.features, [.agentHistory])
        XCTAssertEqual(snapshot.state, store.state)
        // Disconnected: lastSeen is when it dropped, not now.
        store.apply(.disconnected("gone"))
        XCTAssertLessThan(store.cacheSnapshot(now: Date().addingTimeInterval(3600)).lastSeen, Date().addingTimeInterval(60))
        // Round trip through JSON, as the app stores it.
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(CachedMachineState.self, from: data), snapshot)
    }

    /// Regression (44d9daf): `case .pane, .agent where phase == .saved` applied the `where` to `.agent`
    /// only, so every live `.pane` event was dropped. Live pane events must update the model and report
    /// agent changes.
    func testLivePaneEventsApply() throws {
        let store = ModelStore(backend: FakeBackend())
        store.apply(.connected(hello("live")))
        store.apply(.state(model("Live")))
        var changes: [(PaneID, AgentInfo?, AgentInfo?)] = []
        var notified = 0
        store.onAgentChange = { changes.append(($0, $1, $2)) }
        store.onChange = { notified += 1 }

        var pane = try XCTUnwrap(store.state.pane(3))
        pane.title = "vim"
        pane.cwd = "/srv/web"
        let waiting = AgentInfo(kind: "claude", state: .waiting, attention: true)
        pane.agent = waiting
        store.apply(.pane(pane, rev: 8))
        XCTAssertEqual(store.state.pane(3)?.title, "vim")
        XCTAssertEqual(store.state.pane(3)?.cwd, "/srv/web")
        XCTAssertEqual(store.state.rev, 8)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, 3)
        XCTAssertNil(changes.first?.1)
        XCTAssertEqual(changes.first?.2, waiting)
        XCTAssertEqual(notified, 1)

        // A pane the model doesn't have yet is added.
        store.apply(.pane(Pane(id: 4, cols: 80, rows: 24), rev: 9))
        XCTAssertNotNil(store.state.pane(4))
        // And .agent events apply live too.
        store.apply(.agent(3, nil))
        XCTAssertNil(store.state.pane(3)?.agent)
        XCTAssertEqual(changes.count, 2)
    }

    func testPaneEventsWhileSavedAreIgnored() throws {
        let store = ModelStore(backend: FakeBackend())
        store.restore(CachedMachineState(state: model("Saved"), lastSeen: Date()))
        var changes = 0
        store.onAgentChange = { _, _, _ in changes += 1 }
        var pane = try XCTUnwrap(store.state.pane(3))
        pane.title = "live title"
        pane.agent = AgentInfo(kind: "claude", state: .done, attention: true)
        store.apply(.pane(pane, rev: 50))
        store.apply(.pane(Pane(id: 9, cols: 80, rows: 24), rev: 51))
        XCTAssertNil(store.state.pane(3)?.title, "the saved model is untouched")
        XCTAssertNil(store.state.pane(9))
        XCTAssertEqual(store.state.rev, 7)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.phase, .saved)
    }

    func testOtherFormatsAreIgnored() {
        let store = ModelStore(backend: FakeBackend())
        store.restore(CachedMachineState(state: model("Old"), lastSeen: Date(), format: 99))
        XCTAssertEqual(store.phase, .live)
        XCTAssertTrue(store.state.workspaces.isEmpty)
    }

    func testNewInstanceResetsSavedPanes() {
        final class Sink: PaneDataSink {
            var resets = 0
            func paneSubscribed(_ subscription: Subscription) {}
            func paneOutput(seq: UInt64, bytes: Data) {}
            func paneSnapshot(seq: UInt64, cols: Int, rows: Int, bytes: Data) {}
            func paneResized(cols: Int, rows: Int, seq: UInt64) {}
            func paneResync() {}
            func paneReset() { resets += 1 }
        }
        let store = ModelStore(backend: FakeBackend())
        store.restore(CachedMachineState(state: model("S"), lastSeen: Date(), instance: "old"))
        let sink = Sink()
        store.register(sink, for: 3)
        store.apply(.connected(hello("new")))
        XCTAssertEqual(sink.resets, 1, "the saved panes belonged to another holder")
    }
}

/// Permission requests (`requests`, `agent.decide`): each answered once, then stale.
final class PermissionRequestTests: XCTestCase {
    func testDecodes() throws {
        let json = #"{"kind":"claude","state":"waiting","requests":[{"id":"r1","tool":"Bash","summary":"npm  test"},{"id":"r2","tool":"Edit","summary":null}]}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.pendingRequests.map(\.id), ["r1", "r2"])
        XCTAssertEqual(info.pendingRequests[0].question, "Allow Bash: npm test?")
        XCTAssertEqual(info.pendingRequests[1].question, "Allow Edit?")
        XCTAssertEqual(try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"codex","state":"done"}"#.utf8)).pendingRequests, [])
        XCTAssertEqual(Hello.Feature(rawValue: "agent.decide"), .agentDecide)
        XCTAssertTrue(BackendError(code: "stale", message: "").isStale)
        // The notification asks about the oldest request.
        let notice = AgentNotice(info: AgentInfo(kind: "claude", state: .waiting, message: "Claude needs your permission to use Bash",
                                                 tool: "Read", toolInput: "x", requests: info.requests), machine: "m", workspace: "W")
        XCTAssertEqual(notice.body, "Allow Bash: npm test?")
    }

    func testDecideOnceThenStale() async throws {
        let backend = FakeBackend()
        defer { backend.stop() }
        try await backend.start()
        let created = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(command: ["/bin/sh"]))
        backend.setAgent(created.pane, AgentInfo(kind: "claude", state: .waiting, source: "hook", attention: true,
                                                 requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "ls")]))
        try await backend.decide(pane: created.pane, request: "r1", decision: .allow, message: nil)
        let agent = try await backend.getState().pane(created.pane)?.agent
        XCTAssertEqual(agent?.pendingRequests, [])
        XCTAssertEqual(agent?.state, .running)
        do {
            try await backend.decide(pane: created.pane, request: "r1", decision: .deny, message: "no")
            XCTFail("a second answer is stale")
        } catch let error as BackendError {
            XCTAssertTrue(error.isStale)
        }
        XCTAssertEqual(backend.decisions.count, 1)
    }
}
