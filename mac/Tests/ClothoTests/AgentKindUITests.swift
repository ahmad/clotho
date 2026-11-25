import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Every kind of agent (clothod 0.1.33: six more names, and any name a reporter gives) wherever an agent
/// shows: its name and symbol in the inbox row, the pane header's chip, a Tab's tooltip and an Overview
/// card. And an agent from a terminal notification (`source: "osc"`): plain text, a notification each
/// time, nobody to reply to.
@MainActor
final class AgentKindUITests: XCTestCase {
    static let named: [(kind: String, name: String, short: String)] = [
        ("claude", "Claude Code", "Claude"), ("codex", "Codex", "Codex"), ("opencode", "OpenCode", "OpenCode"),
        ("gemini", "Gemini CLI", "Gemini"), ("copilot", "GitHub Copilot CLI", "Copilot"), ("aider", "Aider", "Aider"),
        ("amp", "Amp", "Amp"), ("cursor", "Cursor Agent", "Cursor"), ("other", "Agent", "Agent"), ("deploy", "deploy", "deploy"),
    ]

    override func setUp() { _ = NSApplication.shared }

    private func entry(_ kind: String, source: String = "hook", state: AgentInfo.State = .waiting, message: String? = "Deploy needs approval",
                       summary: String? = nil) -> AgentEntry {
        AgentEntry(machine: "local", machineName: "devbox", pane: 1, workspace: Workspace(id: 1, name: "clotho", tabs: []),
                   tab: Tab(id: 10, activePane: 1, layout: .pane(1)), paneTitle: "zsh", tabTitle: "alerts",
                   info: AgentInfo(kind: kind, state: state, source: source, message: message, since: 100, attention: true, summary: summary),
                   canReply: true)
    }

    func testEveryKindHasARealSymbolAndItsName() throws {
        for (kind, name, short) in Self.named {
            let info = entry(kind).info
            XCTAssertEqual(info.kindName, name)
            XCTAssertEqual(info.shortKindName, short)
            // The symbol's name is one of the table's literals, and the system has it.
            XCTAssertNotNil(NSImage(systemSymbolName: info.kindSymbolName, accessibilityDescription: nil), "\(kind): \(info.kindSymbolName)")
            let image = try XCTUnwrap(info.kindImage(pointSize: 10), kind)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertFalse(info.kindSymbolName.contains("deploy"), "never made from the kind")
        }
        XCTAssertEqual(entry("deploy").info.kindSymbolName, AgentKind.genericSymbol)
        XCTAssertEqual(entry("../../x\u{202E}y\nz").info.kindSymbolName, AgentKind.genericSymbol, "a hostile kind gets the generic symbol")
        XCTAssertEqual(entry("../../x\u{202E}y\nz").info.kindName, "../../xyz", "and shows as text with nothing hidden in it")
    }

    func testTheNameShowsInTheRowTheChipTheCardAndTheTab() throws {
        for (kind, name, short) in Self.named {
            let entry = entry(kind)
            XCTAssertEqual(AgentRow.description(entry), "Needs you: \(name), clotho \u{203A} alerts on devbox. Deploy needs approval")
            let row = AgentRow(entry)
            XCTAssertNotNil(row.kindGlyph.image, kind)
            XCTAssertEqual(row.kindGlyph.isAccessibilityElement(), false, "decorative: the label names it")
            XCTAssertEqual(PaneChrome(agent: entry.info).chipTitle, "\(short) \u{00B7} Needs you")
            XCTAssertEqual(PaneChrome(agent: entry.info).spokenAgent(now: Date(timeIntervalSince1970: 100)), "\(short): Needs you, waiting less than a minute")
            let card = try XCTUnwrap(OverviewCard(entry))
            XCTAssertEqual(card.sub, "devbox \u{00B7} \(short)")
            XCTAssertEqual(card.agentFullName, name)
            XCTAssertEqual(card.agentSymbol, entry.info.kindSymbolName)
            XCTAssertNotNil(OverviewCardView(card: card).kindGlyph.image)
            XCTAssertEqual(TabBarView.spokenName(title: "alerts", mark: .needsYou, agent: name), "alerts, Needs you (\(name))")
        }
        XCTAssertEqual(TabBarView.spokenName(title: "alerts", mark: nil, agent: "Gemini CLI"), "alerts", "no mark, nothing to say")
        XCTAssertEqual(TabBarView.spokenName(title: "alerts", mark: .done, agent: nil), "alerts, Done")
    }

    func testTheChipLeadsWithTheKindsSymbol() {
        let header = PaneHeader()
        header.show(PaneChrome(agent: entry("gemini").info))
        XCTAssertEqual(header.chip.symbol, "sparkles")
        XCTAssertNotNil(header.chip.image)
        header.show(PaneChrome(agent: entry("deploy").info))
        XCTAssertEqual(header.chip.symbol, AgentKind.genericSymbol)
        XCTAssertEqual(header.chip.attributedTitle.string, "deploy \u{00B7} Needs you")
    }

    /// A terminal notification's text is a program's output: shown as it came, never read as Markdown.
    func testAnOscAgentsTextStaysPlain() throws {
        let text = "Build **finished**, see [the log](http://example.invalid/log) and `make test`"
        let osc = entry("other", source: "osc", message: text, summary: "Build finished, see the log and make test")
        XCTAssertEqual(osc.info.inboxText, text)
        let row = AgentRow(osc)
        XCTAssertEqual(row.summary.stringValue, text)
        XCTAssertEqual(row.summary.lineBreakMode, .byTruncatingTail, "a long one truncates on its one line")
        XCTAssertEqual(row.summary.maximumNumberOfLines, 1)
        XCTAssertFalse(row.summary.allowsEditingTextAttributes, "no links")
        XCTAssertEqual(try XCTUnwrap(OverviewCard(osc)).message, text)
        XCTAssertEqual(osc.info.plainMessage, text, "the Reply sheet and history too")
        // The same text from a coding agent's hooks is Markdown, as ever.
        let hook = entry("claude", message: text)
        XCTAssertEqual(hook.info.inboxText, "Build finished, see the log and make test")

        let notice = AgentNotice(info: osc.info, machine: "devbox", workspace: "clotho", cwd: "/tmp", tab: "alerts")
        XCTAssertEqual(notice.body, text)

        let history = AgentHistoryWindowController.describe(try decode(#"{"at": 1, "event": "state", "state": "waiting", "source": "osc", "message": "**bold** [x](http://example.invalid)"}"#))
        XCTAssertEqual(history.detail, "**bold** [x](http://example.invalid) (from a terminal notification)")
        let hooked = AgentHistoryWindowController.describe(try decode(#"{"at": 1, "event": "state", "state": "waiting", "source": "hook", "message": "**bold**"}"#))
        XCTAssertEqual(hooked.detail, "bold (from hook)")
    }

    private func decode(_ json: String) throws -> AgentHistoryEntry {
        try JSONDecoder().decode(AgentHistoryEntry.self, from: Data(json.utf8))
    }

    /// Only a detected agent's state flickers. A program's notification is one it sent each time.
    func testOnlyDetectedAgentsAreThrottled() {
        let now = Date()
        let last = (state: AgentInfo.State.waiting, date: now.addingTimeInterval(-5))
        XCTAssertFalse(AppDelegate.throttlesNotice(entry("claude").info, last: last, now: now))
        XCTAssertFalse(AppDelegate.throttlesNotice(entry("other", source: "osc").info, last: last, now: now), "two notifications 5 s apart both show")
        XCTAssertFalse(AppDelegate.throttlesNotice(entry("deploy").info, last: last, now: now))
        XCTAssertTrue(AppDelegate.throttlesNotice(entry("claude", source: "detected").info, last: last, now: now))
        XCTAssertTrue(AppDelegate.throttlesNotice(AgentInfo(kind: "claude", state: .waiting), last: last, now: now), "no source: detected")
    }

    /// Reply buttons only where somebody reads a reply: a coding agent.
    func testNobodyRepliesToAProgramOrAScript() {
        let osc = entry("other", source: "osc"), script = entry("deploy"), claude = entry("claude"), gemini = entry("gemini")
        XCTAssertFalse(osc.offersReplies)
        XCTAssertFalse(script.offersReplies)
        XCTAssertTrue(claude.offersReplies)
        XCTAssertTrue(gemini.offersReplies)
        XCTAssertFalse(entry("claude", source: "detected").offersReplies, "as before")

        XCTAssertNil(AppDelegate.noticeCategory(for: osc.info, canReply: true, hasRequest: false))
        XCTAssertNil(AppDelegate.noticeCategory(for: script.info, canReply: true, hasRequest: false))
        XCTAssertEqual(AppDelegate.noticeCategory(for: claude.info, canReply: true, hasRequest: false), AppDelegate.waitingCategory)
        XCTAssertEqual(AppDelegate.noticeCategory(for: entry("gemini", state: .done).info, canReply: true, hasRequest: false), AppDelegate.finishedCategory)
        XCTAssertEqual(AppDelegate.noticeCategory(for: entry("claude", source: "detected").info, canReply: true, hasRequest: false),
                       AppDelegate.waitingCategory, "a detected Claude keeps what it had")
        XCTAssertNil(AppDelegate.noticeCategory(for: claude.info, canReply: false, hasRequest: false))
        XCTAssertEqual(AppDelegate.noticeCategory(for: claude.info, canReply: false, hasRequest: true), AppDelegate.permissionCategory)
    }

    /// The glyph and the text keep to the row at a narrow sidebar and every zoom: the summary ends before
    /// the glyph, the glyph inside the row.
    func testTheRowFitsAtEveryZoomAndANarrowSidebar() {
        let saved = UIScale.factor
        defer { UIScale.factor = saved }
        var steps = [UIScale.range.lowerBound]
        while let last = steps.last, last < UIScale.range.upperBound { steps.append(UIScale.next(last, steps: 1)) }
        XCTAssertEqual(steps.count, 9)
        for factor in steps {
            UIScale.factor = factor
            for width in [150, 236, 420] as [CGFloat] {
                let row = AgentRow(entry("copilot", source: "osc", message: String(repeating: "A long plain message. ", count: 14)))
                row.frame = NSRect(x: 0, y: 0, width: width, height: AgentRow.height)
                row.layoutSubtreeIfNeeded()
                let what = "\(Int(factor * 100)) % at \(Int(width))"
                XCTAssertTrue(row.bounds.contains(row.kindGlyph.frame), what)
                // The glyph only where the row has room for it beside its words.
                XCTAssertEqual(row.kindGlyph.isHidden, width < AgentRow.glyphLeastRow, what)
                XCTAssertEqual(row.kindGlyph.frame.width, width < AgentRow.glyphLeastRow ? 0 : AgentRow.glyphSlot, accuracy: 1, what)
                let titleNeeds = row.label.cell?.cellSize.width ?? 0
                XCTAssertGreaterThanOrEqual(row.label.frame.width, min(titleNeeds, (width * AgentRow.titleShare - MachineHeader.nameInset).rounded(.down)) - 1,
                                            "the title has its share of the row, \(what)")
                // A label's frame reaches 2 pt past where its words can.
                XCTAssertLessThanOrEqual(row.summary.frame.maxX, row.kindGlyph.frame.minX + 2.5, what)
                XCTAssertLessThanOrEqual(row.label.frame.maxX, row.kindGlyph.frame.minX + 2.5, what)
                XCTAssertGreaterThanOrEqual(row.summary.frame.height, row.summary.cell?.cellSize.height ?? .infinity, "the line has its height, \(what)")
                XCTAssertTrue(row.bounds.insetBy(dx: 0, dy: -0.5).contains(row.summary.frame), what)
                XCTAssertTrue(row.bounds.contains(row.progressBar.frame), what)
            }
        }
    }
}
