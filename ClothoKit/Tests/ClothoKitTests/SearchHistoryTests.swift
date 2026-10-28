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
}
