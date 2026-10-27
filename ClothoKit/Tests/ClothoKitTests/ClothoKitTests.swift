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
         "title": "vim notes.md", "cwd": "/Users/ahmad/notes", "seq": 183230, "exited": null, "future": 1},
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
        XCTAssertEqual(Pane.displayTitle("ahmad@mac: ~", cwd: nil), "ahmad@mac: ~")
        XCTAssertNil(Pane.displayTitle("✳ ", cwd: nil))
        XCTAssertNil(Pane.displayTitle(nil, cwd: "/x"))
    }
}
