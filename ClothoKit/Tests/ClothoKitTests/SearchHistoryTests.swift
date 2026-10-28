@testable import ClothoKit
import XCTest

/// The `pane.search` and `agent.history` replies decode as protocol.md shows them.
final class SearchHistoryDecodingTests: XCTestCase {
    func testSearchResult() throws {
        let json: [String: Any] = [
            "seq": 1234, "cols": 80, "rows": 24, "history": 2000,
            "matches": [
                ["start": ["line": -3, "col": 4], "end": ["line": -3, "col": 8], "text": "error", "line_text": "an error here"],
                ["start": ["line": -10, "col": 78], "end": ["line": -9, "col": 2], "text": "wrapped", "line_text": "…wrapped"],
            ],
            "next": ["line": -10, "col": 78],
        ]
        let result = try ClothodBackend.decode(PaneSearchResult.self, from: json)
        XCTAssertEqual(result.seq, 1234)
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.matches[0].lineText, "an error here")
        XCTAssertEqual(result.matches[1].end, CellPosition(line: -9, col: 2))
        XCTAssertEqual(result.next, CellPosition(line: -10, col: 78))
        let last = try ClothodBackend.decode(PaneSearchResult.self, from: json.merging(["next": NSNull()]) { $1 })
        XCTAssertNil(last.next)
    }

    func testHistory() throws {
        let json: [String: Any] = [
            "pane": 7, "max": 200,
            "entries": [
                ["at": 1_761_600_000.5, "event": "state", "kind": "claude", "state": "running", "from": "starting",
                 "message": NSNull(), "session": "s1", "pid": 4242, "source": "hook", "guess": false, "attention": false, "muted": false],
                ["at": 1_761_600_010, "event": "attention", "kind": "claude", "state": "waiting", "attention": true,
                 "message": "Allow running `swift test`?"],
                ["at": 1_761_600_020, "event": "gone", "kind": "claude", "state": NSNull()],
                ["at": 1_761_600_030, "event": "something-new", "kind": "claude", "state": "sleeping"],
            ],
        ]
        let history = try ClothodBackend.decode(AgentHistory.self, from: json)
        XCTAssertEqual(history.pane, 7)
        XCTAssertEqual(history.max, 200)
        XCTAssertEqual(history.entries.map(\.event), [.state, .attention, .gone, .unknown])
        XCTAssertEqual(history.entries[0].from, .starting)
        XCTAssertEqual(history.entries[0].state, .running)
        XCTAssertEqual(history.entries[0].pid, 4242)
        XCTAssertEqual(history.entries[1].message, "Allow running `swift test`?")
        XCTAssertNil(history.entries[2].state)
        // Names this client doesn't know don't fail the decode.
        XCTAssertEqual(history.entries[3].state, .unknown)
    }
}

extension ClothodBackendTests {
    /// pane.search finds lines in a real pane's scrollback, newest first, pages with `before`, and refuses
    /// a bad regex; agent.history answers for a pane with no agent.
    func testPaneText() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        try await waitFor("hello") { collector.all.contains { if case .connected = $0 { return true }; return false } }
        let created = try await backend.createWorkspace(name: "text", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp", cols: 60, rows: 12))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 0, viewport: Size(cols: 60, rows: 12))
        backend.sendInput(created.pane, Data("echo \"pre\"\"view-ok\"\n".utf8))
        try await waitFor("output") { collector.output(of: created.pane).contains("preview-ok") }
        let text = try await backend.paneText(created.pane)
        XCTAssertEqual(text.cols, 60)
        XCTAssertEqual(text.rows, 12)
        XCTAssertEqual(text.lines.count, 12)
        XCTAssertTrue(text.lines.contains("preview-ok"), "\(text.lines)")
        XCTAssertTrue((0..<12).contains(text.cursorRow))
        XCTAssertGreaterThan(text.seq, 0)
        XCTAssertFalse(text.text.hasSuffix("\n"))
    }

    /// push.activity and push.activity_end against a real daemon: a token for a registered device shows in
    /// push.list's activities (never the token), and ending it removes it. The relay is never reached: the
    /// pane runs no agent, so nothing is sent.
    func testPushActivity() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        try await waitFor("hello") { collector.all.contains { if case .connected = $0 { return true }; return false } }
        guard let hello = backend.locked({ backend.lastHello }), hello.features.contains(.pushActivity) else {
            throw XCTSkip("this clothod predates push.activity")
        }
        let created = try await backend.createWorkspace(name: "activity", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        let token = String(repeating: "ab", count: 32)
        do {
            try await backend.pushActivity(pane: created.pane, device: "cki-phone", token: token, env: nil)
            XCTFail("an unregistered device is accepted")
        } catch let error as BackendError {
            XCTAssertEqual(error.code, "not_found")
        }
        let key = Data(repeating: 9, count: 32).base64EncodedString()
        try await backend.pushRegister(PushRegistration(device: "cki-phone", handle: "h", key: key, label: "test",
                                                        relay: "http://127.0.0.1:9", env: "sandbox"))
        do {
            try await backend.pushActivity(pane: created.pane, device: "cki-phone", token: "not-hex", env: nil)
            XCTFail("a bad token is accepted")
        } catch let error as BackendError {
            XCTAssertEqual(error.code, "bad_request")
        }
        try await backend.pushActivity(pane: created.pane, device: "cki-phone", token: token, env: "production")
        let activities = try await backend.pushActivities()
        XCTAssertEqual(activities.map(\.pane), [created.pane])
        XCTAssertEqual(activities.first?.device, "cki-phone")
        XCTAssertNotNil(activities.first?.created)
        let devices = try await backend.pushList()
        XCTAssertEqual(devices.map(\.device), ["cki-phone"], "push.list's devices still decode")
        try await backend.pushActivityEnd(pane: created.pane, device: "cki-phone")
        let after = try await backend.pushActivities()
        XCTAssertEqual(after, [])
        try await backend.pushUnregister(device: "cki-phone")
    }

    func testPaneTextDecodes() throws {
        let json = #"{"lines":["$ ls","a  b",""],"cursor":[2,1],"cols":80,"rows":3,"seq":42,"modes":{"bracketed_paste":true}}"#
        let text = try JSONDecoder().decode(PaneText.self, from: Data(json.utf8))
        XCTAssertEqual(text, PaneText(lines: ["$ ls", "a  b", ""], cursorCol: 2, cursorRow: 1, cols: 80, rows: 3, seq: 42))
        XCTAssertEqual(text.text, "$ ls\na  b")
        XCTAssertEqual(try JSONDecoder().decode(PaneText.self, from: JSONEncoder().encode(text)), text)
    }

    func testSearchAndHistory() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        try await waitFor("hello") { collector.all.contains { if case .connected = $0 { return true }; return false } }
        guard let hello = backend.locked({ backend.lastHello }), hello.features.contains(.paneSearch) else {
            throw XCTSkip("this clothod predates pane.search")
        }

        let created = try await backend.createWorkspace(name: "search", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 80, rows: 10))
        // 60 numbered lines, so most are in scrollback; the split word keeps the typed command itself from matching.
        backend.sendInput(created.pane, Data("i=1; while [ $i -le 60 ]; do echo \"nee\"\"dle-$i\"; i=$((i+1)); done\n".utf8))
        try await waitFor("output") { collector.output(of: created.pane).contains("needle-60") }

        let all = try await backend.searchPane(created.pane, query: "needle-", options: PaneSearchOptions())
        XCTAssertEqual(all.matches.count, 60)
        XCTAssertEqual(all.matches.first?.lineText, "needle-60", "newest first")
        XCTAssertEqual(all.matches.last?.lineText, "needle-1")
        XCTAssertLessThan(all.matches.last!.start.line, 0, "old lines are in scrollback")
        XCTAssertNil(all.next)

        let page = try await backend.searchPane(created.pane, query: "needle-", options: PaneSearchOptions(limit: 25))
        XCTAssertEqual(page.matches.count, 25)
        let next = try XCTUnwrap(page.next)
        let rest = try await backend.searchPane(created.pane, query: "needle-", options: PaneSearchOptions(limit: 100, before: next))
        XCTAssertEqual(rest.matches.count, 35)
        XCTAssertEqual(rest.matches.first?.lineText, "needle-35")

        let regex = try await backend.searchPane(created.pane, query: "^needle-5[0-9]$", options: PaneSearchOptions(regex: true))
        XCTAssertEqual(regex.matches.count, 10)
        let cased = try await backend.searchPane(created.pane, query: "NEEDLE-", options: PaneSearchOptions(caseSensitive: true))
        XCTAssertEqual(cased.matches.count, 0)
        do {
            _ = try await backend.searchPane(created.pane, query: "(", options: PaneSearchOptions(regex: true))
            XCTFail("a bad regex was accepted")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, "bad_request")
        }

        if hello.features.contains(.agentHistory) {
            let history = try await backend.agentHistory(created.pane, limit: nil, since: nil)
            XCTAssertEqual(history.pane, created.pane)
            XCTAssertEqual(history.entries, [])
            XCTAssertGreaterThan(history.max, 0)
        }
    }

    /// ModelState.focusing mirrors clothod's model.rs focus_pane / focus_tab / focus_workspace. This runs
    /// one sequence of focus changes through both and checks every step agrees: the focus, each
    /// workspace's active tab and each tab's active pane.
    func testLocalFocusMatchesTheDaemon() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        let sh = SpawnOptions(command: ["/bin/sh"], cwd: "/tmp")
        let one = try await backend.createWorkspace(name: "one", spawn: sh)
        let second = try await backend.createTab(in: one.workspace, spawn: sh)
        let split = try await backend.split(second.pane, direction: .right, spawn: sh)
        let two = try await backend.createWorkspace(name: "two", spawn: sh)
        let empty = try await backend.createWorkspace(name: "empty", spawn: sh)
        try await backend.closePane(empty.pane)
        let targets: [FocusTarget] = [
            .workspace(one.workspace), .tab(second.tab), .pane(second.pane), .workspace(two.workspace),
            .workspace(one.workspace), .pane(split.pane), .tab(one.tab), .workspace(one.workspace),
            .tab(second.tab), .pane(one.pane), .workspace(two.workspace), .tab(two.tab), .workspace(one.workspace),
        ]
        func shape(_ state: ModelState) -> String {
            "focus \(state.focus.workspace.map(String.init) ?? "-")/\(state.focus.tab.map(String.init) ?? "-")/\(state.focus.pane.map(String.init) ?? "-") "
                + state.workspaces.map { w in "w\(w.id):\(w.activeTab.map(String.init) ?? "-")[" + w.tabs.map { "t\($0.id):\($0.activePane)" }.joined(separator: ",") + "]" }
                    .joined(separator: " ")
        }
        var state = try await backend.getState()
        for target in targets {
            let local = try XCTUnwrap(state.focusing(target), "\(target)")
            try await backend.focus(target)
            state = try await backend.getState()
            XCTAssertEqual(shape(local), shape(state), "after \(target)")
        }
        if let gone = try await backend.getState().workspace(empty.workspace) {
            // A workspace whose last tab closed, if the daemon keeps it: focusing it has no tab.
            XCTAssertEqual(state.focusing(.workspace(gone.id))?.focus.tab, nil)
        }
    }
}
