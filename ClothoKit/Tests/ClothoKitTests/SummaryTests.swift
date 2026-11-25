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
        // No settle window (clothod 0.1.31): this is about the text, and the rise must come while the
        // fake still sleeps.
        daemonEnvironment["CLOTHOD_TEST_SETTLE_MS"] = "0"

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

/// Text from an agent with `source: "osc"` (clothod 0.1.33, feature `agent.osc`): any program's output,
/// plain by contract. It is shown as typed, never read as Markdown; a hook agent's still is.
final class OscTextTests: XCTestCase {
    static let message = "**bold** [x](http://example.invalid)"

    func testPlainLine() {
        XCTAssertEqual(AgentNotice.plainLine(Self.message), Self.message, "no Markdown, no links")
        XCTAssertEqual(AgentNotice.plainLine("  Build \t finished\n\nin  3 s \n"), "Build finished in 3 s")
        XCTAssertEqual(AgentNotice.plainLine("a\u{1b}[31mb\u{07}c\u{0}d\u{7f}\u{9b}"), "a[31mbcd", "control characters dropped")
        XCTAssertEqual(AgentNotice.plainLine("# Title\n- `one`\n- _two_"), "# Title - `one` - _two_")
        XCTAssertEqual(AgentNotice.plainLine("<b>x</b> & https://example.invalid"), "<b>x</b> & https://example.invalid")
        XCTAssertEqual(AgentNotice.plainLine(" \n\t "), "")
        XCTAssertEqual(AgentNotice.plainLine(""), "")
    }

    func testAnOscAgentsTextStaysAsTyped() {
        // 0.1.33 sends a Markdown-stripped `summary` for an osc agent; the message is what was printed.
        let osc = AgentInfo(kind: "other", state: .waiting, source: "osc", message: Self.message, attention: true,
                            summary: "bold x", needsUser: true)
        XCTAssertEqual(osc.headline, Self.message)
        XCTAssertEqual(osc.result, Self.message)
        let notice = AgentNotice(info: osc, machine: "devbox", workspace: "Platform")
        XCTAssertEqual(notice.body, Self.message)
        XCTAssertEqual(notice.title, "Platform · Agent needs you")

        // Without a message, the summary, as typed too; then the fallback.
        var only = osc
        only.message = nil
        only.summary = "*done*  `x`"
        XCTAssertEqual(only.headline, "*done* `x`")
        XCTAssertEqual(AgentNotice(info: only, machine: "devbox").body, "*done* `x`")
        only.summary = nil
        XCTAssertNil(only.headline)
        XCTAssertNil(only.result)
        XCTAssertEqual(AgentNotice(info: only, machine: "devbox").body, "")

        // Never a permission ask, whatever the words: nothing an osc program prints is one.
        var asking = osc
        asking.message = "Need permission to deploy"
        asking.tool = "Bash"
        asking.toolInput = "rm -rf /"
        XCTAssertEqual(asking.headline, "Need permission to deploy")
        XCTAssertEqual(AgentNotice(info: asking, machine: "devbox").body, "Need permission to deploy")

        // A long one is cut like any body, and whitespace and control characters go.
        var long = osc
        long.message = String(repeating: "word ", count: 100) + "\u{1b}]8;;http://example.invalid\u{07}"
        XCTAssertLessThanOrEqual(AgentNotice(info: long, machine: "devbox").body.count, AgentNotice.bodyLimit)
        XCTAssertFalse(long.headline?.unicodeScalars.contains { $0.properties.generalCategory == .control } ?? true)
    }

    func testTheInitsPlainTextFlag() {
        func body(plain: Bool, result: String? = nil, summary: String? = nil, fallback: String? = nil) -> String {
            AgentNotice(kind: "other", state: "waiting", machine: "devbox", workspace: nil, project: nil, duration: nil,
                        result: result, tool: nil, toolInput: nil, fallback: fallback, summary: summary, needsUser: true,
                        plainText: plain).body
        }
        XCTAssertEqual(body(plain: true, result: Self.message, summary: "bold x"), Self.message, "the result before the summary")
        XCTAssertEqual(body(plain: true, summary: "**s**"), "**s**")
        XCTAssertEqual(body(plain: true, fallback: "`f`\n"), "`f`")
        XCTAssertEqual(body(plain: false, result: Self.message, summary: "bold x"), "bold x", "as before: the summary first")
        XCTAssertEqual(body(plain: false, result: Self.message), AgentNotice.clip(PlainText.oneLine(Self.message), to: AgentNotice.bodyLimit),
                       "as before: Markdown is read")
    }

    func testAHookAgentsIsStillConverted() {
        let hook = AgentInfo(kind: "claude", state: .done, source: "hook", message: Self.message, attention: true)
        func flat(_ text: String?) -> String? { text.map { AgentNotice.clip($0, to: AgentNotice.bodyLimit) } }
        let converted = AgentNotice.clip(PlainText.oneLine(Self.message), to: AgentNotice.bodyLimit)
        XCTAssertNotEqual(converted, Self.message)
        XCTAssertFalse(converted.contains("**") || converted.contains("]("), converted)
        XCTAssertTrue(converted.contains("bold"), converted)
        XCTAssertEqual(flat(hook.headline), converted)
        XCTAssertEqual(flat(hook.result), converted)
        XCTAssertEqual(AgentNotice(info: hook, machine: "devbox").body, converted)
        // A detected agent's too (no source, or "detected").
        var detected = hook
        detected.source = nil
        XCTAssertEqual(flat(detected.headline), converted)
        detected.source = "detected"
        XCTAssertEqual(AgentNotice(info: detected, machine: "devbox").body, converted)
    }
}
