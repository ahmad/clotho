@testable import ClothoKit
import Darwin
import XCTest

/// Peek against a real clothod (0.1.32 or later), each test with its own ephemeral daemon. Skipped
/// when clothod isn't built or lacks `peek`.
final class PeekDaemonTests: XCTestCase {
    var clothod: String!
    var runtimeDir: String!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["CLOTHOD_BIN"]
            ?? package.deletingLastPathComponent().appendingPathComponent("clothod/target/debug/clothod").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary), "clothod isn't built")
        // Assigned only once nothing can skip any more, so tearDown has a daemon to stop exactly when
        // one could have been started.
        clothod = binary
        let prefix = ProcessInfo.processInfo.environment["CLOTHOKIT_RUNTIME_PREFIX"] ?? "/tmp/ckt-"
        runtimeDir = "\(prefix)\(getpid())-\(UUID().uuidString.prefix(6))"
    }

    override func tearDown() {
        if let clothod, let runtimeDir {
            TestClothod.shutdown(clothod, runtimeDir: runtimeDir)
            try? FileManager.default.removeItem(atPath: runtimeDir)
        }
    }

    // MARK: Helpers

    func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func hellos(_ collector: FakeBackendTests.Collector) -> [Hello] {
        collector.all.compactMap { event -> Hello? in if case .connected(let hello) = event { return hello }; return nil }
    }

    /// Whether any peek of the pane has a line containing `text`.
    static func peeked(_ text: String, _ pane: PaneID, in collector: FakeBackendTests.Collector) -> Bool {
        collector.peeks(of: pane).contains { $0.contains { $0.contains(text) } }
    }

    /// A backend on the test's own ephemeral daemon, connected, with a Workspace whose pane is a shell
    /// with a known prompt. Skips when this clothod has no `peek`.
    func connect() async throws -> (backend: ClothodBackend, collector: FakeBackendTests.Collector, reader: Task<Void, Never>, pane: PaneID) {
        let clothod = clothod!, dir = runtimeDir!
        let backend = ClothodBackend(configuration: .init(
            socketPath: ClothodBackend.defaultSocketPath(runtimeDir: dir), clientName: "clothokit-peek-tests",
            startDaemon: {
                // A private runtime dir needs an ephemeral instance, with its own config.
                _ = try TestClothod.run(clothod, ["start"], runtimeDir: dir,
                                        environment: ["CLOTHOD_EPHEMERAL": "60", "CLOTHOD_CONFIG": dir + "/config.toml"])
            }))
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        do {
            try await backend.start()
            guard let hello = backend.locked({ backend.lastHello }), hello.features.contains(.peek) else {
                throw XCTSkip("this clothod predates peek")
            }
            let created = try await backend.createWorkspace(
                name: "peek", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp", env: ["PS1": "READY> "], cols: 80, rows: 24))
            return (backend, collector, reader, created.pane)
        } catch {
            backend.stop()
            reader.cancel()
            throw error
        }
    }

    // MARK: Tests

    func testSubscribeSkipsUnknownPanesAndOutputArrives() async throws {
        let (backend, collector, reader, pane) = try await connect()
        defer { backend.stop(); reader.cancel() }
        let session: SessionBackend = backend
        XCTAssertEqual(Self.hellos(collector).first?.features.contains(.peek), true)

        let peeks = try await session.peekSubscribe(panes: [pane, 999_999], lines: PeekLines.requested)
        XCTAssertEqual(peeks.map(\.pane), [pane], "the id that names no pane is skipped")
        XCTAssertLessThanOrEqual(peeks[0].lines.count, 8)
        // The reply's lines are an event too, ahead of any change.
        try await waitFor("the reply as an event") { !collector.peeks(of: pane).isEmpty }
        XCTAssertEqual(collector.peeks(of: pane).first, peeks[0].lines)
        XCTAssertTrue(collector.peeks(of: 999_999).isEmpty)

        backend.sendInput(pane, Data("echo peek-''-one\n".utf8))
        try await waitFor("the printed line as a peek") { Self.peeked("peek--one", pane, in: collector) }
        let last = try XCTUnwrap(collector.peeks(of: pane).last)
        XCTAssertLessThanOrEqual(last.count, 8)
        XCTAssertFalse(last.contains(""), "only non-empty rows")
    }

    /// 0 and 9 would be `bad_request`; the backend brings them into 1...8 before sending.
    func testLinesOutOfRangeAreClamped() async throws {
        let (backend, collector, reader, pane) = try await connect()
        defer { backend.stop(); reader.cancel() }
        _ = try await backend.peekSubscribe(panes: [pane], lines: PeekLines.requested)
        backend.sendInput(pane, Data("for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo row-''-$i; done\n".utf8))
        try await waitFor("the rows") { Self.peeked("row--12", pane, in: collector) }

        let most = try await backend.peekSubscribe(panes: [pane], lines: 9)
        XCTAssertEqual(most.first?.lines.count, 8, "9 lines asked, 8 sent for")
        let least = try await backend.peekSubscribe(panes: [pane], lines: 0)
        XCTAssertEqual(least.first?.lines.count, 1, "0 lines asked, 1 sent for")
        let below = try await backend.peekSubscribe(panes: nil, lines: -3)
        XCTAssertEqual(below.first { $0.pane == pane }?.lines.count, 1)
    }

    func testUnsubscribeTwiceThenNoEvent() async throws {
        let (backend, collector, reader, pane) = try await connect()
        defer { backend.stop(); reader.cancel() }
        _ = try await backend.peekSubscribe(panes: [pane], lines: 2)
        backend.sendInput(pane, Data("echo before-''-end\n".utf8))
        try await waitFor("a peek while subscribed") { Self.peeked("before--end", pane, in: collector) }

        try await backend.peekUnsubscribe()
        try await backend.peekUnsubscribe()
        let count = collector.peekCount
        backend.sendInput(pane, Data("echo after-''-end\n".utf8))
        // The daemon looks once a second: three of its looks.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(collector.peekCount, count, "no peek after unsubscribing")
        // The connection is fine, and a new subscription has what was printed meanwhile.
        let again = try await backend.peekSubscribe(panes: [pane], lines: 4)
        XCTAssertTrue(again.first?.lines.contains { $0.contains("after--end") } == true, "\(again)")
    }

    /// The daemon's logic process dies; the holder keeps the shell. The backend reconnects and sends
    /// the subscription again by itself, and its lines come as events.
    func testSubscriptionSurvivesAReconnect() async throws {
        let (backend, collector, reader, pane) = try await connect()
        defer { backend.stop(); reader.cancel() }
        _ = try await backend.peekSubscribe(panes: [pane], lines: 4)
        backend.sendInput(pane, Data("echo first-''-life\n".utf8))
        try await waitFor("a peek before") { Self.peeked("first--life", pane, in: collector) }

        let pid = try XCTUnwrap(Self.hellos(collector).first?.pid)
        kill(pid, SIGKILL)
        try await waitFor("reconnect", timeout: 15) { Self.hellos(collector).count >= 2 }
        /// The peeks that came after the second hello.
        let after = { () -> [[String]] in
            let events = collector.all
            guard let second = events.indices.filter({ if case .connected = events[$0] { return true }; return false }).dropFirst().first else { return [] }
            return events[second...].compactMap { event -> [String]? in
                if case let .peek(p, lines) = event, p == pane { return lines }
                return nil
            }
        }
        try await waitFor("the subscription's reply after the reconnect", timeout: 15) { !after().isEmpty }
        XCTAssertTrue(after().first?.contains { $0.contains("first--life") } == true, "the lines as they are: \(after())")

        backend.sendInput(pane, Data("echo second-''-life\n".utf8))
        try await waitFor("a peek after the reconnect", timeout: 15) { after().contains { $0.contains { $0.contains("second--life") } } }
    }
}
