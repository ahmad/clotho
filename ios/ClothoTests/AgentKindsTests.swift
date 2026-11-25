import ClothoKit
import XCTest
@testable import Clotho

/// What the Agents list says for each kind of agent (ClothoKit's AgentKind table), for a script's own kind and
/// for a program's notification (source "osc"), and what a row with progress draws and says.
@MainActor
final class AgentKindsTests: XCTestCase {
    private let machine = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 10_000)

    private func row(_ kind: String, _ state: AgentInfo.State = .waiting, source: String? = "hook", message: String? = nil,
                     summary: String? = nil, changes: PaneGit.Changes? = nil, progress: PaneProgress? = nil) -> AgentRow {
        AgentRow(machineID: machine, machineName: "devbox", pane: 1, tab: 1, workspace: "Platform", title: "api-server",
                 info: AgentInfo(kind: kind, state: state, source: source, message: message, since: 10_000 - 240, attention: true,
                                 summary: summary, needsUser: true),
                 changes: changes, progress: progress)
    }

    private func entry(_ kind: String?, source: String? = "hook", message: String? = nil) -> AgentHistoryEntry {
        AgentHistoryEntry(at: 1, event: "state", kind: kind, state: "done", from: "running", message: message, source: source)
    }

    func testKnownKindsShowTheirShortNameAndSymbol() {
        let names = ["opencode": "OpenCode", "gemini": "Gemini", "copilot": "Copilot", "aider": "Aider", "amp": "Amp", "cursor": "Cursor"]
        for (kind, name) in names {
            let row = row(kind)
            XCTAssertEqual(AgentRowView.caption(row, now: now), "devbox · \(name) · 4m", kind)
            XCTAssertEqual(AgentRowView.captionTail(row, now: now), "\(name) · 4m", kind)
            XCTAssertEqual(AgentRowView.accessibilityText(row), "Platform › api-server, devbox · \(name) · Needs you", kind)
            XCTAssertEqual(row.info.shortKindName, name, "the quick reply's title, Reply to \(name)")
            XCTAssertEqual(AgentHistoryRow.headline(entry(kind)), "\(name): Running → Done", kind)
            XCTAssertEqual(row.info.kindSymbolName, AgentKind.of(kind).symbolName, kind)
            XCTAssertNotEqual(row.info.kindSymbolName, AgentKind.genericSymbol, "\(kind) has its own symbol")
            XCTAssertTrue(row.acceptsReply, "\(kind) reports through its hook and is waiting")
        }
    }

    func testAnUnknownKindShowsAsItsOwnText() {
        for kind in ["deploy", "node.js"] {
            let row = row(kind)
            XCTAssertEqual(AgentRowView.caption(row, now: now), "devbox · \(kind) · 4m", "verbatim, not capitalised")
            XCTAssertEqual(AgentRowView.accessibilityText(row), "Platform › api-server, devbox · \(kind) · Needs you")
            XCTAssertEqual(row.info.shortKindName, kind)
            XCTAssertEqual(AgentHistoryRow.headline(entry(kind)), "\(kind): Running → Done")
            XCTAssertEqual(row.info.kindSymbolName, AgentKind.genericSymbol, "a kind's text never names a symbol")
            XCTAssertFalse(row.acceptsReply, "a script's report takes no reply")
        }
        // A kind that would read as a symbol's name is still only text.
        XCTAssertEqual(row("sparkles").info.kindSymbolName, AgentKind.genericSymbol)
        XCTAssertEqual(row("../x").info.kindSymbolName, AgentKind.genericSymbol)
    }

    func testOtherAndNoKindReadAgent() {
        XCTAssertEqual(AgentRowView.caption(row("other"), now: now), "devbox · Agent · 4m")
        XCTAssertEqual(AgentRowView.accessibilityText(row("other")), "Platform › api-server, devbox · Agent · Needs you")
        XCTAssertEqual(row("other").info.kindSymbolName, AgentKind.genericSymbol)
        XCTAssertEqual(row("").info.shortKindName, "Agent")
        XCTAssertEqual(AgentHistoryRow.headline(entry("other")), "Agent: Running → Done")
        XCTAssertEqual(AgentHistoryRow.headline(entry(nil)), "Agent: Running → Done")
        XCTAssertEqual(AgentHistoryRow.headline(AgentHistoryEntry(at: 1, event: "gone", kind: "gemini")), "Gemini exited")
        // Claude and Codex read as before.
        XCTAssertEqual(AgentHistoryRow.headline(entry("claude")), "Claude: Running → Done")
        XCTAssertEqual(AgentHistoryRow.headline(entry("codex")), "Codex: Running → Done")
    }

    func testAnOscRowIsPlainText() {
        let typed = "**Build**  finished:\n see [log](http://x)"
        let osc = row("other", source: "osc", message: typed, summary: "Build finished: see log")
        XCTAssertEqual(osc.summary, "**Build** finished: see [log](http://x)", "as typed, on one line; the message before the summary")
        XCTAssertEqual(AgentRowView.accessibilityText(osc),
                       "Platform › api-server, **Build** finished: see [log](http://x), devbox · Agent · Needs you")
        XCTAssertFalse(osc.acceptsReply)
        // The same text from a coding agent is Markdown.
        XCTAssertEqual(row("claude", message: "**Build** finished: see [log](http://x)").summary, "Build finished: see log")
    }

    func testAnOscHistoryEntryIsPlainText() {
        let typed = "**Build**  finished:\n see [log](http://x)"
        XCTAssertEqual(AgentHistoryRow.message(entry("other", source: "osc", message: typed)), "**Build** finished: see [log](http://x)")
        XCTAssertEqual(AgentHistoryRow.message(entry("claude", message: typed)), PlainText.fromMarkdown(typed))
        XCTAssertFalse(AgentHistoryRow.message(entry("claude", message: typed))?.contains("**") ?? true)
        XCTAssertNil(AgentHistoryRow.message(entry("other", source: "osc", message: " \n ")), "nothing to draw")
        XCTAssertNil(AgentHistoryRow.message(entry("claude", message: "")))
        XCTAssertNil(AgentHistoryRow.message(entry("claude")))
    }

    func testProgressIsDrawnAndSpoken() {
        let forty = PaneProgress(state: .running, percent: 40)
        let plain = row("claude", .running)
        let progressing = row("claude", .running, progress: forty)
        XCTAssertNotEqual(progressing, plain, "the row redraws when progress comes")
        XCTAssertEqual(progressing, row("claude", .running, progress: forty))
        XCTAssertNotEqual(progressing, row("claude", .running, progress: PaneProgress(state: .running, percent: 41)))
        XCTAssertTrue(AgentRowView.accessibilityText(progressing).contains("Progress 40 percent"))
        XCTAssertFalse(AgentRowView.accessibilityText(plain).contains("Progress"))
        XCTAssertEqual(AgentRowView.accessibilityText(row("claude", .running, progress: PaneProgress(state: .indeterminate)), pinned: true),
                       "Platform › api-server, devbox · Claude · Needs you, Progress, in progress, Pinned")
        // Only drawn and spoken: the caption, the order and the badge don't read it.
        XCTAssertEqual(AgentRowView.caption(progressing, now: now), AgentRowView.caption(plain, now: now))
        XCTAssertEqual(progressing.group, plain.group)
        XCTAssertEqual(AgentRow.needsYouCount([progressing]), AgentRow.needsYouCount([plain]))
    }

    func testProgressOnlyFromALiveMachineThatReportsIt() {
        let forty = PaneProgress(state: .running, percent: 40)
        XCTAssertEqual(AgentRow.progress(of: forty, features: [.paneProgress], live: true), forty)
        XCTAssertNil(AgentRow.progress(of: forty, features: [.paneProgress], live: false), "a saved model, or not connected")
        XCTAssertNil(AgentRow.progress(of: forty, features: [.gitChanges], live: true), "no pane.progress feature")
        XCTAssertNil(AgentRow.progress(of: nil, features: [.paneProgress], live: true))
    }

    func testChangeTokenAloneIsNoChange() {
        let counts = PaneGit.Changes.Count(files: 6, added: 128, removed: 32)
        let one = row("claude", changes: PaneGit.Changes(uncommitted: counts, token: "a"))
        let two = row("claude", changes: PaneGit.Changes(uncommitted: counts, token: "b"))
        XCTAssertEqual(one, two, "the same counts under another token: nothing to redraw")
        XCTAssertEqual(one, row("claude", changes: PaneGit.Changes(uncommitted: counts)))
        let more = row("claude", changes: PaneGit.Changes(uncommitted: .init(files: 7, added: 128, removed: 32), token: "a"))
        XCTAssertNotEqual(one, more, "a count changed")
        XCTAssertNotEqual(one, row("claude"), "the counts went")
    }

    /// `-FakeAgentKinds YES`: every other kind, a script's and an osc one, and the three progress shapes.
    func testMadeUpKindsAndProgress() {
        let made = (0..<8).map { FakeAgents.kind(for: PaneID($0)) }
        XCTAssertEqual(Set(made.map(\.kind)), ["gemini", "opencode", "copilot", "aider", "amp", "cursor", "deploy", "other"])
        let osc = made.filter { $0.source == "osc" }
        XCTAssertEqual(osc.map(\.kind), ["other"])
        XCTAssertEqual(osc.first?.message, "**Build** finished: see [log](http://x)")
        XCTAssertTrue(made.filter { $0.source != "osc" }.allSatisfy { $0.source == "hook" && $0.message == nil })

        let running = AgentInfo(kind: "gemini", state: .running, source: "hook")
        // The running fakes are panes 2, 7, 12, 17.
        XCTAssertEqual(FakeAgents.progress(running, pane: 2, kinds: true), PaneProgress(state: .running, percent: 40))
        XCTAssertEqual(FakeAgents.progress(running, pane: 7, kinds: true), PaneProgress(state: .indeterminate))
        XCTAssertEqual(FakeAgents.progress(running, pane: 12, kinds: true), PaneProgress(state: .running, percent: 40))
        XCTAssertEqual(FakeAgents.progress(running, pane: 17, kinds: true), PaneProgress(state: .error, percent: 55))
        XCTAssertNil(FakeAgents.progress(running, pane: 2, kinds: false), "the plain fakes are as before")
        XCTAssertNil(FakeAgents.progress(AgentInfo(kind: "gemini", state: .waiting, source: "hook"), pane: 2, kinds: true))
    }
}
