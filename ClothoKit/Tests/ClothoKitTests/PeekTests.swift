@testable import ClothoKit
import ClothoFake
import XCTest

extension FakeBackendTests.Collector {
    /// Every `peek` event's lines for a pane, in order.
    func peeks(of pane: PaneID) -> [[String]] {
        all.compactMap { event -> [String]? in
            if case let .peek(p, lines) = event, p == pane { return lines }
            return nil
        }
    }

    var peekCount: Int { all.filter { if case .peek = $0 { return true }; return false }.count }
}

/// `PeekLines.pick` on rows as agents' and shells' screens end (measured from real panes).
final class PeekLinesTests: XCTestCase {
    let rule = String(repeating: "─", count: 60)

    func testCutsTheRuledInputBoxAndItsHints() {
        let lines = ["● Bash(cargo test)", "⎿  Waiting for permission…", rule, ">", rule, "? for shortcuts"]
        XCTAssertEqual(PeekLines.pick(lines), ["● Bash(cargo test)", "⎿  Waiting for permission…"])
        XCTAssertEqual(PeekLines.pick(lines, count: 1), ["⎿  Waiting for permission…"])
        // Something typed, on two rows, is still the input box.
        XCTAssertEqual(PeekLines.pick(["● Done", rule, "> fix the", "  other test", rule, "? for shortcuts"]), ["● Done"])
    }

    func testOnlyAnInputBoxLeavesNothing() {
        XCTAssertEqual(PeekLines.pick(["╭───╮", "│ >   │", "╰───╯", "⏵⏵ accept edits on"]), [])
        XCTAssertEqual(PeekLines.pick(["● Read 3 files", "╭──────────╮", "│ > hello  │", "╰──────────╯"]), ["● Read 3 files"])
    }

    func testPlainShellOutputIsUntouched() {
        XCTAssertEqual(PeekLines.pick(["Compiling clothod v0.1.32", "Finished in 4.2s", "$"]), ["Finished in 4.2s", "$"])
        XCTAssertEqual(PeekLines.pick(["a", "b", "c"], count: 3), ["a", "b", "c"])
        XCTAssertEqual(PeekLines.pick(["ahmad@box ~ % ls", "> not a prompt, a quote", "done"]), ["> not a prompt, a quote", "done"])
        // Rules that hold no prompt are output: a table stays.
        let table = ["┌──────┬─────┐", "│ name │ n   │", "└──────┴─────┘", "2 rows"]
        XCTAssertEqual(PeekLines.pick(table, count: 4), table)
        XCTAssertEqual(PeekLines.pick(["title", rule, "body", rule, "end"], count: 5), ["title", rule, "body", rule, "end"])
    }

    func testABoxFarFromTheEndStays() {
        var lines = [rule, ">", rule]
        lines += (1 ... 5).map { "row \($0)" }
        XCTAssertEqual(PeekLines.pick(lines, count: 8), lines)
    }

    func testTrailingChromeAndEmptyPromptsGo() {
        XCTAssertEqual(PeekLines.pick(["working", rule]), ["working"])
        XCTAssertEqual(PeekLines.pick(["working", "❯"]), ["working"])
        XCTAssertEqual(PeekLines.pick(["working", "│ ›  │", "  ", "╰────"]), ["working"])
        XCTAssertEqual(PeekLines.pick(["one", "> typed"]), ["one", "> typed"], "a prompt with text is kept")
    }

    func testFewerRowsThanCountAndNothingLeft() {
        XCTAssertEqual(PeekLines.pick(["only"]), ["only"])
        XCTAssertEqual(PeekLines.pick([]), [])
        XCTAssertEqual(PeekLines.pick([rule, "│   │", ">", "──"]), [], "all chrome")
        XCTAssertEqual(PeekLines.pick(["a", "b"], count: 0), [])
    }

    func testTextIsNotSanitised() {
        XCTAssertEqual(PeekLines.pick(["a\u{202E}b"]), ["a\u{202E}b"], "callers draw through DiffText.display")
        XCTAssertEqual(PeekLines.requested, 8)
    }
}

/// FakeBackend's peek, which the apps' tests and renders are built on, and ModelStore's `onPeek`.
final class FakePeekTests: XCTestCase {
    private func started(_ features: [String] = ["peek"]) async throws
        -> (fake: FakeBackend, collector: FakeBackendTests.Collector, reader: Task<Void, Never>, panes: [PaneID]) {
        let fake = FakeBackend(extraFeatures: features)
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in fake.events { collector.add(event) } }
        try await fake.start()
        let first = try await fake.createWorkspace(name: "one", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        let second = try await fake.createWorkspace(name: "two", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        return (fake, collector, reader, [first.pane, second.pane])
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSubscribeReturnsAndYieldsTheCurrentLines() async throws {
        let (fake, collector, reader, panes) = try await started()
        defer { fake.stop(); reader.cancel() }
        let session: SessionBackend = fake
        fake.setPeek(panes[0], lines: ["a", "b", "c"])
        XCTAssertEqual(collector.peekCount, 0, "nothing before a subscription")

        let peeks = try await session.peekSubscribe(panes: [panes[0], 9999], lines: 2)
        XCTAssertEqual(peeks, [PanePeek(pane: panes[0], lines: ["b", "c"])], "the last two lines; the unknown id is skipped")
        try await waitFor("the reply's lines as an event") { collector.peeks(of: panes[0]) == [["b", "c"]] }
        XCTAssertEqual(fake.peekCalls, [.subscribe(panes: [panes[0], 9999], lines: 2)])

        // Every pane, and `lines` brought into 1...8.
        let all = try await session.peekSubscribe(panes: nil, lines: 99)
        XCTAssertEqual(Set(all.map(\.pane)), Set(panes))
        XCTAssertEqual(all.first { $0.pane == panes[0] }?.lines, ["a", "b", "c"])
        XCTAssertEqual(all.first { $0.pane == panes[1] }?.lines, [])
        let one = try await session.peekSubscribe(panes: [panes[0]], lines: 0)
        XCTAssertEqual(one.first?.lines, ["c"])
    }

    func testSetPeekYieldsOnlyForWantedPanesAndChanges() async throws {
        let (fake, collector, reader, panes) = try await started()
        defer { fake.stop(); reader.cancel() }
        _ = try await fake.peekSubscribe(panes: [panes[0]], lines: 2)
        fake.setPeek(panes[1], lines: ["not wanted"])
        fake.setPeek(panes[0], lines: ["one"])
        fake.setPeek(panes[0], lines: ["one"])
        fake.setPeek(panes[0], lines: ["one", "two", "three"])
        try await waitFor("the changes") { collector.peeks(of: panes[0]).count >= 3 }
        XCTAssertEqual(collector.peeks(of: panes[0]), [[], ["one"], ["two", "three"]], "the reply, then each change once")
        XCTAssertEqual(collector.peeks(of: panes[1]), [])

        // Replacing the set: the other pane's lines come with the reply.
        _ = try await fake.peekSubscribe(panes: [panes[1]], lines: 2)
        fake.setPeek(panes[0], lines: ["no longer wanted"])
        try await waitFor("the second pane") { collector.peeks(of: panes[1]) == [["not wanted"]] }
        XCTAssertEqual(collector.peeks(of: panes[0]).count, 3)
    }

    func testUnsubscribeStopsEvents() async throws {
        let (fake, collector, reader, panes) = try await started()
        defer { fake.stop(); reader.cancel() }
        _ = try await fake.peekSubscribe(panes: nil, lines: 2)
        try await waitFor("the reply's events") { collector.peekCount == 2 }
        try await fake.peekUnsubscribe()
        try await fake.peekUnsubscribe()
        fake.setPeek(panes[0], lines: ["after"])
        // Events are yielded under the fake's lock, in order: a later event would follow a peek.
        fake.setAgent(panes[0], AgentInfo(kind: "claude", state: .running))
        try await waitFor("the marker") { collector.all.contains { if case .agent = $0 { return true }; return false } }
        XCTAssertEqual(collector.peekCount, 2)
        XCTAssertEqual(fake.peekCalls, [.subscribe(panes: nil, lines: 2), .unsubscribe, .unsubscribe])
    }

    func testWithoutTheFeatureItIsUnknown() async throws {
        let (fake, collector, reader, panes) = try await started([])
        defer { fake.stop(); reader.cancel() }
        let hello = collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil }.first
        XCTAssertEqual(hello?.features.contains(.peek), false)
        do {
            _ = try await fake.peekSubscribe(panes: nil, lines: 2)
            XCTFail("subscribed without the feature")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, "unknown_method")
        }
        fake.setPeek(panes[0], lines: ["x"])
        XCTAssertEqual(collector.peekCount, 0)
        XCTAssertEqual(fake.peekCalls.count, 1, "refused calls are recorded too")
    }

    func testHelloHasTheFeatureWhenAsked() async throws {
        let (fake, collector, reader, _) = try await started()
        defer { fake.stop(); reader.cancel() }
        try await waitFor("hello") { collector.all.contains { if case .connected = $0 { return true }; return false } }
        let hello = collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil }.first
        XCTAssertEqual(hello?.features.contains(.peek), true)
    }

    @MainActor
    func testModelStoreOnPeekFiresWithoutOnChange() async throws {
        let fake = FakeBackend(extraFeatures: ["peek"])
        let store = ModelStore(backend: fake)
        defer { store.stop() }
        try await store.start()
        let created = try await fake.createWorkspace(name: "one", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        var deadline = Date().addingTimeInterval(5)
        while store.state.pane(created.pane) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(store.state.pane(created.pane))

        // Directly: a peek is no model change.
        var peeks: [(PaneID, [String])] = []
        var changes = 0
        let before = store.state
        store.onPeek = { peeks.append(($0, $1)) }
        store.onChange = { changes += 1 }
        store.apply(.peek(created.pane, lines: ["x", "y"]))
        XCTAssertEqual(peeks.map(\.0), [created.pane])
        XCTAssertEqual(peeks.map(\.1), [["x", "y"]])
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.state, before)

        // Through the backend's events.
        fake.setPeek(created.pane, lines: ["one", "two"])
        _ = try await fake.peekSubscribe(panes: [created.pane], lines: 2)
        fake.setPeek(created.pane, lines: ["two", "three"])
        deadline = Date().addingTimeInterval(5)
        while peeks.count < 3, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(peeks.map(\.1), [["x", "y"], ["one", "two"], ["two", "three"]])
    }
}

/// ClothodBackend's side of peek against a scripted daemon (it answers {} to everything): what goes
/// out, and when.
final class PeekRequestTests: XCTestCase {
    private func subscribes(_ daemon: ScriptedDaemon) -> [ScriptedDaemon.Call] {
        daemon.calls.filter { $0.method == "peek.subscribe" }
    }

    func testNothingIsSentWithoutTheFeature() async throws {
        let daemon = ScriptedDaemon(features: ["pane.keys"])
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        let session: SessionBackend = backend
        do {
            _ = try await session.peekSubscribe(panes: nil, lines: 2)
            XCTFail("subscribed before any hello")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, "unknown_method")
        }
        try await backend.start()
        try await daemon.waitFor { $0.contains { $0.method == "events.subscribe" } }
        do {
            _ = try await session.peekSubscribe(panes: [1], lines: 2)
            XCTFail("subscribed without the feature")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, "unknown_method")
        }
        try await session.peekUnsubscribe()
        // Nothing was kept either: a reconnect sends none.
        backend.reconnectNow()
        try await daemon.waitFor { $0.filter { $0.method == "events.subscribe" }.count >= 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(daemon.calls.contains { $0.method.hasPrefix("peek.") })
    }

    func testLinesAreClampedAndTheSubscriptionIsSentAgain() async throws {
        let daemon = ScriptedDaemon(features: ["peek"])
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        let session: SessionBackend = backend
        try await backend.start()
        try await daemon.waitFor { $0.contains { $0.method == "events.subscribe" } }

        let none = try await session.peekSubscribe(panes: nil, lines: 0)
        XCTAssertEqual(none, [], "a reply without peeks is no peeks")
        _ = try await session.peekSubscribe(panes: [3, 5], lines: 9)
        var sent = subscribes(daemon)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].params?["lines"] as? Int, 1)
        XCTAssertNil(sent[0].params?["panes"], "every pane: `panes` left out")
        XCTAssertEqual(sent[1].params?["lines"] as? Int, 8)
        XCTAssertEqual((sent[1].params?["panes"] as? [NSNumber])?.map(\.uint64Value), [3, 5])

        // A new connection: the latest subscription goes out again, after events.subscribe.
        backend.reconnectNow()
        try await daemon.waitFor { calls in calls.filter { $0.method == "peek.subscribe" }.count >= 3 }
        sent = subscribes(daemon)
        XCTAssertEqual(sent[2].params?["lines"] as? Int, 8)
        XCTAssertEqual((sent[2].params?["panes"] as? [NSNumber])?.map(\.uint64Value), [3, 5])
        let calls = daemon.calls
        let events = try XCTUnwrap(calls.lastIndex { $0.method == "events.subscribe" })
        XCTAssertLessThan(events, try XCTUnwrap(calls.lastIndex { $0.method == "peek.subscribe" }))

        // Ended: forgotten, so the next connection sends none. Twice is harmless.
        try await session.peekUnsubscribe()
        try await session.peekUnsubscribe()
        XCTAssertEqual(daemon.calls.filter { $0.method == "peek.unsubscribe" }.count, 2)
        backend.reconnectNow()
        try await daemon.waitFor { $0.filter { $0.method == "events.subscribe" }.count >= 3 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(subscribes(daemon).count, 3)
    }

    func testAFailedSendKeepsTheSubscription() async throws {
        let daemon = ScriptedDaemon(features: ["peek"])
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        try await backend.start()
        try await daemon.waitFor { $0.contains { $0.method == "events.subscribe" } }
        backend.stop()
        do {
            _ = try await backend.peekSubscribe(panes: [7], lines: 4)
            XCTFail("sent while stopped")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, "disconnected")
        }
        try await backend.start()
        try await daemon.waitFor { $0.contains { $0.method == "peek.subscribe" } }
        let sent = subscribes(daemon)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].params?["lines"] as? Int, 4)
        XCTAssertEqual((sent[0].params?["panes"] as? [NSNumber])?.map(\.uint64Value), [7])
    }
}
