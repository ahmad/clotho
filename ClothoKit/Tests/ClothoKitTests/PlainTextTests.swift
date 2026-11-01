import XCTest
@testable import ClothoKit

/// Agents' Markdown as plain text for notifications, the Live Activity and one-line rows.
final class PlainTextTests: XCTestCase {
    func testAClaudeReplyWithBoldCodeAndBullets() {
        let reply = """
        Done. I fixed the **flaky test** in `api/tests/test_auth.py`:

        - The `token_expiry` fixture now uses a *frozen* clock
        - Added a retry to `wait_for_db()`
        * Removed the old __helper__

        All **42 tests** pass.
        """
        XCTAssertEqual(PlainText.fromMarkdown(reply), """
        Done. I fixed the flaky test in api/tests/test_auth.py:
        • The token_expiry fixture now uses a frozen clock
        • Added a retry to wait_for_db()
        • Removed the old helper
        All 42 tests pass.
        """)
        XCTAssertEqual(PlainText.oneLine(reply),
                       "Done. I fixed the flaky test in api/tests/test_auth.py: • The token_expiry fixture now uses a frozen clock • Added a retry to wait_for_db() • Removed the old helper All 42 tests pass.")
    }

    func testACodeFenceKeepsTheCode() {
        let reply = """
        Run this to reproduce it:

        ```bash
        npm test -- --grep "auth **flow**"
        ```

        Then check `logs/app.log`.
        """
        XCTAssertEqual(PlainText.fromMarkdown(reply), """
        Run this to reproduce it:
        npm test -- --grep "auth **flow**"
        Then check logs/app.log.
        """, "the code is as written, emphasis marks and all")
        XCTAssertEqual(PlainText.oneLine("~~~\nmake\n~~~"), "make")
        XCTAssertEqual(PlainText.oneLine("Use ``a `tick` here``."), "Use a `tick` here.")
    }

    func testLinksHeadingsQuotesAndRules() {
        let reply = """
        ## Summary

        I opened [PR #128](https://github.com/ahmad/clotho/pull/128 "the fix") and updated ![diagram](docs/flow.png).
        See <https://clotho.app/docs> and [the plan][plan].

        > Note: the **staging** deploy is still pending.
        > > nested

        ---
        1. Review it
        2) Merge it
        - [x] tests
        - [ ] docs
        """
        XCTAssertEqual(PlainText.fromMarkdown(reply), """
        Summary
        I opened PR #128 and updated diagram.
        See https://clotho.app/docs and the plan.
        Note: the staging deploy is still pending.
        nested
        1. Review it
        2. Merge it
        • tests
        • docs
        """)
    }

    func testEntitiesWhitespaceAndWhatStays() {
        XCTAssertEqual(PlainText.oneLine("Tom &amp; Jerry &lt;3 &quot;it&quot; &#39;works&#39; &#x2014; ok&nbsp;now &bogus;"),
                       "Tom & Jerry <3 \"it\" 'works' — ok now &bogus;")
        XCTAssertEqual(PlainText.fromMarkdown("  lots   of\tspace  \n\n\n\nand  lines  "), "lots of space\nand lines")
        XCTAssertEqual(PlainText.oneLine("snake_case_name and 2*3*4 stay; \\*literal\\* too"), "snake_case_name and 2*3*4 stay; *literal* too")
        XCTAssertEqual(PlainText.oneLine("a<br>b <b>bold</b>"), "a b bold")
        XCTAssertEqual(PlainText.oneLine("| File | Change |\n|---|:---:|\n| a.swift | fix |"), "File · Change a.swift · fix")
        XCTAssertEqual(PlainText.oneLine("#hashtag and # Title"), "#hashtag and # Title", "a # mid-line isn't a heading")
        XCTAssertEqual(PlainText.fromMarkdown(""), "")
        XCTAssertEqual(PlainText.fromMarkdown("Plain words."), "Plain words.")
    }

    /// The notice: the summary first, else the plain message; a permission ask always names the command.
    func testNoticesUseTheSummaryAndKeepTheAsk() {
        let markdown = "Done. The **build** passes and `make test` is green."
        let plain = AgentNotice(kind: "claude", state: "done", machine: "m", workspace: "W", project: nil, duration: nil,
                                result: markdown, tool: nil, toolInput: nil)
        XCTAssertEqual(plain.body, "Done. The build passes and make test is green.")
        let summarized = AgentNotice(kind: "claude", state: "done", machine: "m", workspace: "W", project: nil, duration: nil,
                                     result: markdown, tool: nil, toolInput: nil, summary: "Build fixed; tests green.")
        XCTAssertEqual(summarized.body, "Build fixed; tests green.")

        let ask = AgentNotice(kind: "claude", state: "waiting", machine: "m", workspace: "W", project: nil, duration: nil,
                              result: "Claude needs your permission to use Bash", tool: "Bash", toolInput: "rm -rf build/ && npm   test",
                              summary: "Wants to clean and rerun the tests.")
        XCTAssertEqual(ask.body, "Allow Bash: rm -rf build/ && npm test? Wants to clean and rerun the tests.")
        // A long command is never cut; the summary gets what room is left, or none.
        let long = String(repeating: "x", count: 235)
        let crowded = AgentNotice(kind: "claude", state: "waiting", machine: "m", workspace: nil, project: nil, duration: nil,
                                  result: nil, tool: "Bash", toolInput: long, summary: "Builds it.")
        XCTAssertEqual(crowded.body, "Allow Bash: \(long)?")

        // From the model: AgentInfo's summary, and the one-line headline rows show.
        var info = AgentInfo(kind: "claude", state: .done, message: "## Done\n- **one**\n- two", summary: nil)
        XCTAssertEqual(AgentNotice(info: info, machine: "m").body, "Done • one • two")
        XCTAssertEqual(info.headline, "Done • one • two")
        info.summary = "Two things done."
        XCTAssertEqual(AgentNotice(info: info, machine: "m").body, "Two things done.")
        XCTAssertEqual(info.headline, "Two things done.")
        let waiting = AgentInfo(kind: "claude", state: .waiting, message: "Claude needs your permission to use Bash", tool: "Bash",
                                toolInput: "npm test", summary: "Runs the tests.")
        XCTAssertEqual(waiting.headline, "Allow Bash: npm test?")
        // The prompt fallback is plain too.
        let prompted = AgentNotice(kind: "claude", state: "done", machine: "m", workspace: nil, project: nil, duration: nil,
                                   result: nil, tool: nil, toolInput: nil, fallback: "fix `auth` **now**")
        XCTAssertEqual(prompted.body, "fix auth now")
    }

    func testTheWireCarriesTheSummary() throws {
        let json = #"{"kind":"claude","state":"done","message":"**ok**","summary":"All good."}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.summary, "All good.")
        let old = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"kind":"claude","state":"done"}"#.utf8))
        XCTAssertNil(old.summary)
    }
}
