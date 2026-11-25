@testable import ClothoKit
import Darwin
import XCTest

/// clothod 0.1.33's agent status against a real daemon, each test with its own ephemeral one: a
/// notification from any program (`source: "osc"`), a script's report under a kind of its own, what an
/// ack does to each, and a pane's progress. Skipped when clothod isn't built, and each test when hello
/// lacks its feature. (The change token's test is at the end, with GitChangesDaemonTests' repository.)
final class AgentStatusDaemonTests: XCTestCase {
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

    typealias Collector = FakeBackendTests.Collector

    func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The pane as its latest `pane` event has it.
    static func latestPane(_ pane: PaneID, in collector: Collector) -> Pane? {
        for event in collector.all.reversed() {
            if case let .pane(found, _) = event, found.id == pane { return found }
        }
        return nil
    }

    /// The pane's agent as the latest event that says so has it (an `agent` event, a `pane` event or a
    /// whole `state`): `.some(nil)` when that says there is none, nil when nothing said anything yet.
    static func agent(_ pane: PaneID, in collector: Collector) -> AgentInfo?? {
        for event in collector.all.reversed() {
            if case let .agent(id, info) = event, id == pane { return .some(info) }
            if case let .pane(found, _) = event, found.id == pane { return .some(found.agent) }
            if case let .state(state) = event, let found = state.pane(pane) { return .some(found.agent) }
        }
        return nil
    }

    /// Whether the latest word on the pane's agent is that there is none.
    static func hasNoAgent(_ pane: PaneID, in collector: Collector) -> Bool {
        guard let said = agent(pane, in: collector) else { return false }
        return said == nil
    }

    /// A backend on the test's own ephemeral daemon, connected, with a Workspace whose pane is an
    /// interactive `/bin/sh`, subscribed (so its output can be read). Skips when this clothod's hello
    /// lacks `feature`. The rise bucket refills fast and the settle window is short, as in
    /// ClothodBackendTests.
    func connect(needing feature: Hello.Feature) async throws -> (backend: ClothodBackend, collector: Collector, reader: Task<Void, Never>, pane: PaneID) {
        let clothod = clothod!, dir = runtimeDir!
        let backend = ClothodBackend(configuration: .init(
            socketPath: ClothodBackend.defaultSocketPath(runtimeDir: dir), clientName: "clothokit-agent-status-tests",
            startDaemon: {
                // A private runtime dir needs an ephemeral instance, with its own config.
                _ = try TestClothod.run(clothod, ["start"], runtimeDir: dir, environment: [
                    "CLOTHOD_EPHEMERAL": "60", "CLOTHOD_CONFIG": dir + "/config.toml",
                    "CLOTHOD_TEST_SETTLE_MS": "300", "CLOTHOD_TEST_OSC_REFILL_MS": "200",
                ])
            }))
        let collector = Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        do {
            try await backend.start()
            guard let hello = backend.locked({ backend.lastHello }), hello.features.contains(feature) else {
                throw XCTSkip("this clothod predates \(feature.rawValue)")
            }
            let created = try await backend.createWorkspace(name: "status", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
            _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 100, rows: 24))
            return (backend, collector, reader, created.pane)
        } catch {
            backend.stop()
            reader.cancel()
            throw error
        }
    }

    /// Types a line into the pane's shell (or into the program reading there).
    func typeLine(_ line: String, into pane: PaneID, of backend: ClothodBackend) {
        backend.sendInput(pane, Data((line + "\n").utf8))
    }

    // MARK: Tests

    /// (1) `printf '\033]9;Build finished\007'`: a notification from any program is an agent of kind
    /// `other`, source `osc`, waiting, with attention, that needs the user. Its text is plain.
    func testANotificationFromAnyProgram() async throws {
        let (backend, collector, reader, pane) = try await connect(needing: .agentOsc)
        defer { backend.stop(); reader.cancel() }

        typeLine(#"printf '\033]9;Build finished\007'"#, into: pane, of: backend)
        try await waitFor("the notification's agent") { Self.agent(pane, in: collector).flatMap { $0 }?.needsAttention == true }
        let agent = try XCTUnwrap(Self.agent(pane, in: collector).flatMap { $0 })
        XCTAssertEqual(agent.kind, "other")
        XCTAssertEqual(agent.source, "osc")
        XCTAssertTrue(agent.isOscSourced)
        XCTAssertEqual(agent.state, .waiting)
        XCTAssertEqual(agent.attention, true)
        XCTAssertEqual(agent.needsUser, true)
        XCTAssertEqual(agent.message, "Build finished")
        XCTAssertFalse(agent.isSummaryPending, "no model rewrites a program's output")
        // What the apps show for it.
        XCTAssertEqual(agent.headline, "Build finished")
        XCTAssertEqual(agent.kindName, "Agent")
        XCTAssertEqual(agent.kindSymbolName, AgentKind.genericSymbol)
        XCTAssertFalse(agent.acceptsReplies)
        let notice = AgentNotice(info: agent, machine: "devbox", workspace: "status")
        XCTAssertEqual(notice.title, "status · Agent needs you")
        XCTAssertEqual(notice.body, "Build finished")
        // The model has it too.
        let state = try await backend.getState()
        XCTAssertEqual(state.pane(pane)?.agent?.source, "osc")
        XCTAssertEqual(state.pane(pane)?.agent?.attention, true)
    }

    /// (2) `clothod report --kind deploy --state waiting --message …` typed at the prompt: an agent of
    /// kind `deploy` with attention. The reporter has ended, so an ack removes it.
    func testAScriptsReportUnderItsOwnKindIsRemovedByAnAck() async throws {
        let (backend, collector, reader, pane) = try await connect(needing: .agentKinds)
        defer { backend.stop(); reader.cancel() }

        // The runtime dir is named in the line too, so this report can only ever reach the test's daemon.
        typeLine("CLOTHOD_RUNTIME_DIR='\(runtimeDir!)' \"\(clothod!)\" report --kind deploy --state waiting --message 'Deploy needs approval'",
             into: pane, of: backend)
        try await waitFor("the report's agent") { Self.agent(pane, in: collector).flatMap { $0 }?.needsAttention == true }
        let agent = try XCTUnwrap(Self.agent(pane, in: collector).flatMap { $0 })
        XCTAssertEqual(agent.kind, "deploy", "a name of its own is kept")
        XCTAssertEqual(agent.state, .waiting)
        XCTAssertEqual(agent.attention, true)
        XCTAssertEqual(agent.message, "Deploy needs approval")
        XCTAssertFalse(agent.isOscSourced)
        XCTAssertEqual(agent.kindName, "deploy", "shown by its name")
        XCTAssertEqual(agent.kindSymbolName, AgentKind.genericSymbol)
        XCTAssertFalse(AgentKind.of(agent.kind).isKnown)
        XCTAssertFalse(agent.acceptsReplies, "a script has nobody to answer")

        // At the prompt again (the reporter was the whole job): the ack takes it out of the list.
        try await backend.ackAgent(pane)
        try await waitFor("the agent to be removed") { Self.hasNoAgent(pane, in: collector) }
        let state = try await backend.getState()
        XCTAssertNotNil(state.pane(pane), "the pane stays")
        XCTAssertNil(state.pane(pane)?.agent, "an ack removes a pane-bound agent whose program has ended")
    }

    /// (3) A notification acknowledged while its program still runs: the agent stays, without
    /// attention, and is gone once the program has ended.
    func testAnAckWhileTheProgramRunsKeepsTheAgentUntilItEnds() async throws {
        let (backend, collector, reader, pane) = try await connect(needing: .agentOsc)
        defer { backend.stop(); reader.cancel() }

        typeLine(#"sh -c 'printf "\033]9;hi\007"; sleep 20'"#, into: pane, of: backend)
        try await waitFor("the notification's agent") { Self.agent(pane, in: collector).flatMap { $0 }?.needsAttention == true }
        XCTAssertEqual(Self.agent(pane, in: collector).flatMap { $0 }?.message, "hi")

        try await backend.ackAgent(pane)
        // The next `pane` event after the ack: the agent, with attention false.
        try await waitFor("a pane event without attention") {
            guard let found = Self.latestPane(pane, in: collector) else { return false }
            return found.agent == nil || found.agent?.attention != true
        }
        let acked = try XCTUnwrap(Self.latestPane(pane, in: collector))
        let kept = try XCTUnwrap(acked.agent, "it stays listed while its program runs")
        XCTAssertNotEqual(kept.attention, true)
        XCTAssertFalse(kept.needsAttention)
        XCTAssertEqual(kept.source, "osc")
        XCTAssertEqual(kept.state, .waiting)
        XCTAssertEqual(kept.message, "hi")
        // Still there a moment later: sleep runs on.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertFalse(Self.hasNoAgent(pane, in: collector), "not removed while its program runs")

        // Ctrl-C ends the program; the agent goes with it (the daemon looks once a second).
        backend.sendInput(pane, Data([0x03]))
        try await waitFor("the agent to go with its program", timeout: 15) { Self.hasNoAgent(pane, in: collector) }
        let state = try await backend.getState()
        XCTAssertNil(state.pane(pane)?.agent)
    }

    /// (4) OSC 9;4: the pane's progress appears with each state and clears, and never makes an agent.
    func testProgressAppearsWithEachStateAndClears() async throws {
        let (backend, collector, reader, pane) = try await connect(needing: .paneProgress)
        defer { backend.stop(); reader.cancel() }

        // A program that prints each line typed to it as an OSC sequence, and stays: a progress lasts
        // only while a program is behind it (one printed at the prompt is gone within 2 s).
        typeLine(#"sh -c 'echo printer-""ready; while IFS= read -r s; do printf "\033]%s\007" "$s"; done'"#, into: pane, of: backend)
        try await waitFor("the printer") { collector.output(of: pane).contains("printer-ready") }

        let steps: [(osc: String, progress: PaneProgress)] = [
            ("9;4;1;40", PaneProgress(state: .running, percent: 40)),
            ("9;4;2;55", PaneProgress(state: .error, percent: 55)),
            ("9;4;3", PaneProgress(state: .indeterminate)),
            ("9;4;4;70", PaneProgress(state: .paused, percent: 70)),
        ]
        for step in steps {
            typeLine(step.osc, into: pane, of: backend)
            try await waitFor("progress \(step.osc)") { Self.latestPane(pane, in: collector)?.progress == step.progress }
            XCTAssertEqual(Self.latestPane(pane, in: collector)?.progress, step.progress, step.osc)
            let state = try await backend.getState()
            XCTAssertEqual(state.pane(pane)?.progress, step.progress, "state.get has it too: \(step.osc)")
        }
        typeLine("9;4;0", into: pane, of: backend)
        try await waitFor("the clear") {
            guard let found = Self.latestPane(pane, in: collector) else { return false }
            return found.progress == nil
        }
        let cleared = try await backend.getState()
        XCTAssertNotNil(cleared.pane(pane))
        XCTAssertNil(cleared.pane(pane)?.progress)

        // Through all of it: no agent, in no event.
        for event in collector.all {
            switch event {
            case let .agent(id, info) where id == pane: XCTFail("progress sent an agent event: \(String(describing: info))")
            case let .pane(found, _) where found.id == pane: XCTAssertNil(found.agent, "progress made an agent")
            default: break
            }
        }
        XCTAssertNil(cleared.pane(pane)?.agent)
        // Ctrl-D ends the printer.
        backend.sendInput(pane, Data([0x04]))
    }
}

extension GitChangesDaemonTests {
    /// (5) The change token (feature `git.changes.token`, clothod 0.1.33): the pane's `changes.token` is
    /// the `git.changes` reply's, and it moves when a changed file is rewritten with every count left
    /// as it was.
    func testTheChangeTokenMovesWhenTheCountsStay() async throws {
        let (backend, collector, reader, created) = try await connect()
        defer { backend.stop(); reader.cancel() }
        try XCTSkipUnless(backend.locked({ backend.lastHello })?.features.contains(.gitChangesToken) == true,
                          "this clothod predates git.changes.token")
        let pane = created.pane
        let shown = { Self.latestPane(pane, in: collector)?.git?.changes }

        try await waitFor("the pane's changes", timeout: 20) { shown() != nil }
        let first = try await backend.gitChanges(pane, limit: nil)
        let token = try XCTUnwrap(first.token, "the reply carries a token")
        XCTAssertEqual(token.count, 16)
        // The pane's is the same (a summary run that ended meanwhile brings it within moments).
        try await waitFor("the pane's token to be the reply's") { shown()?.token == token }
        let before = try XCTUnwrap(shown())
        XCTAssertEqual(before.token, token, "the pane's token is the list's")
        XCTAssertEqual(before.uncommitted, PaneGit.Changes.Count(files: 4, added: 3, removed: 1))
        XCTAssertEqual(first.summary, before, "token included")

        // a.txt, already changed (+2 −1), rewritten: still +2 −1. Printing in the pane has the daemon
        // look again soon; an edit from elsewhere shows within 15 s either way.
        try write("a.txt", "one\nTWO\nthree\nfour\n")
        backend.sendInput(pane, Data("echo edited\n".utf8))
        try await waitFor("the token to move", timeout: 20) { shown().map { $0.token != token } == true }
        let after = try XCTUnwrap(shown())
        XCTAssertNotNil(after.token)
        XCTAssertNotEqual(after.token, token, "an edit that leaves the counts moves the token")
        XCTAssertEqual(after.counts, before.counts, "every count as it was")
        XCTAssertNotEqual(after, before, "so the two differ only by the token")

        // The list asked for now carries the new token, and the diff the new text.
        let second = try await backend.gitChanges(pane, limit: nil)
        XCTAssertNotEqual(second.token, token)
        try await waitFor("the pane's token to be the new reply's") { shown()?.token == second.token }
        XCTAssertEqual(second.uncommitted.total, first.uncommitted.total)
        XCTAssertEqual(second.uncommitted.added, first.uncommitted.added)
        XCTAssertEqual(second.uncommitted.removed, first.uncommitted.removed)
        let diff = try await backend.gitDiff(pane, path: "a.txt", group: .uncommitted, oldPath: nil, context: nil)
        XCTAssertTrue(diff.hunks.flatMap(\.lines).contains { $0.text == "TWO" })
    }
}
