import XCTest
@testable import ClothoKit

/// The daemon's notification text (feature `summary`, clothod 0.1.29), with a fake summarizer: the rise
/// carries the cleaned message as `summary` with `summary_pending`, then a `pane` event brings the
/// rewrite. AgentNotice shows each.
extension ClothodBackendTests {
    func testTheRiseThenTheRewrite() async throws {
        // The fake: reads the prompt, takes a moment, answers with Markdown (which the daemon cleans).
        try FileManager.default.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fake = runtimeDir + "/summarizer.sh"
        try "#!/bin/sh\ncat > /dev/null\nsleep 1\necho 'Fixed the **auth** bug; tests pass.'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        daemonEnvironment["CLOTHOD_SUMMARIZER"] = fake

        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        try XCTSkipUnless(backend.lastHello?.features.contains(.summary) == true, "this clothod predates summary")

        let created = try await backend.createWorkspace(name: "agents", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        _ = try await backend.request("agent.report", ["pane": created.pane, "state": "running", "kind": "claude", "prompt": "fix auth"])
        let message = "**Done.** I fixed the `auth` bug:\n\n- token refresh\n- [docs](https://x.y/z)\n"
        _ = try await backend.request("agent.report", ["pane": created.pane, "state": "done", "kind": "claude", "message": message])

        func agents() -> [AgentInfo] {
            collector.all.compactMap { event -> AgentInfo? in
                switch event {
                case let .agent(p, info) where p == created.pane: return info
                case let .pane(pane, _) where pane.id == created.pane: return pane.agent
                default: return nil
                }
            }
        }
        try await waitFor("the rise") { agents().contains { $0.state == .done && $0.needsAttention } }
        let rise = try XCTUnwrap(agents().first { $0.state == .done && $0.needsAttention })
        XCTAssertEqual(rise.message, message, "message stays as the agent said it")
        XCTAssertTrue(rise.isSummaryPending, "a rewrite is on its way")
        let cleaned = try XCTUnwrap(rise.summary)
        XCTAssertFalse(cleaned.contains("**") || cleaned.contains("`") || cleaned.contains("]("), cleaned)
        XCTAssertEqual(AgentNotice(info: rise, machine: "m").body, PlainText.oneLine(cleaned))

        try await waitFor("the rewrite", timeout: 15) { agents().contains { $0.summary?.contains("tests pass") == true && !$0.isSummaryPending } }
        let rewritten = try XCTUnwrap(agents().last { !$0.isSummaryPending })
        XCTAssertEqual(rewritten.summary, "Fixed the auth bug; tests pass.", "cleaned by the daemon too")
        XCTAssertEqual(AgentNotice(info: rewritten, machine: "m").body, "Fixed the auth bug; tests pass.")
        XCTAssertEqual(rewritten.headline, "Fixed the auth bug; tests pass.")

        // The switch: off, and the next rise has no rewrite.
        let settings = try await backend.setSettings(.init(notificationRewrite: false))
        XCTAssertEqual(settings.notificationRewrite, false)
        let got = try await backend.getSettings()
        XCTAssertEqual(got.notificationRewrite, false)
    }
}
