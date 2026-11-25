@testable import ClothoKit
import XCTest

/// The kind table (`AgentKind`): names, short names and symbols for the kinds clothod 0.1.33 knows, and
/// what a kind nobody knows shows as.
final class AgentKindTests: XCTestCase {
    func testTheTable() {
        let rows: [(id: String, name: String, short: String, symbol: String)] = [
            ("claude", "Claude Code", "Claude", "sparkle"),
            ("codex", "Codex", "Codex", "chevron.left.forwardslash.chevron.right"),
            ("opencode", "OpenCode", "OpenCode", "curlybraces"),
            ("gemini", "Gemini CLI", "Gemini", "sparkles"),
            ("copilot", "GitHub Copilot CLI", "Copilot", "eyeglasses"),
            ("aider", "Aider", "Aider", "wrench.and.screwdriver"),
            ("amp", "Amp", "Amp", "bolt"),
            ("cursor", "Cursor Agent", "Cursor", "cursorarrow"),
        ]
        for row in rows {
            let kind = AgentKind.of(row.id)
            XCTAssertEqual(kind.id, row.id)
            XCTAssertEqual(kind.name, row.name, row.id)
            XCTAssertEqual(kind.shortName, row.short, row.id)
            XCTAssertEqual(kind.symbolName, row.symbol, row.id)
            XCTAssertTrue(kind.isKnown, row.id)
            XCTAssertTrue(kind.isCodingAgent, row.id)
            XCTAssertEqual(AgentKind.of(row.id.uppercased()), kind, "the case of a kind doesn't matter")
        }
        // The ninth row: "other", and no kind at all.
        for id in ["other", ""] {
            let kind = AgentKind.of(id)
            XCTAssertEqual(kind.id, "other")
            XCTAssertEqual(kind.name, "Agent")
            XCTAssertEqual(kind.shortName, "Agent")
            XCTAssertEqual(kind.symbolName, "terminal")
            XCTAssertEqual(kind.symbolName, AgentKind.genericSymbol)
            XCTAssertTrue(kind.isKnown)
            XCTAssertFalse(kind.isCodingAgent)
        }
        XCTAssertEqual(AgentKind.hookable, ["claude", "codex", "gemini", "copilot"])
        XCTAssertTrue(AgentKind.hookable.allSatisfy { AgentKind.of($0).isCodingAgent })
    }

    func testAnUnknownKindShowsAsItsOwnName() {
        let kind = AgentKind.of("deploy")
        XCTAssertEqual(kind.id, "deploy")
        XCTAssertEqual(kind.name, "deploy", "verbatim: not capitalised")
        XCTAssertEqual(kind.shortName, "deploy")
        XCTAssertEqual(kind.symbolName, AgentKind.genericSymbol)
        XCTAssertFalse(kind.isKnown)
        XCTAssertFalse(kind.isCodingAgent)
        XCTAssertEqual(AgentKind.of("nightly-backup.v2").name, "nightly-backup.v2")
    }

    func testHostileKinds() {
        // A path is only ever text.
        let path = AgentKind.of("../x")
        XCTAssertEqual(path.name, "../x")
        XCTAssertEqual(path.symbolName, "terminal")

        // Control characters and bidi overrides are dropped.
        XCTAssertEqual(AgentKind.of("de\nploy").name, "deploy")
        XCTAssertEqual(AgentKind.of("a\u{1b}[31mb\u{07}").name, "a[31mb")
        XCTAssertEqual(AgentKind.of("\u{202E}yolped\u{202C}").name, "yolped")
        XCTAssertEqual(AgentKind.of("x\u{2066}y\u{2069}\u{200F}z").name, "xyz")
        XCTAssertEqual(AgentKind.of("a\u{2028}b\u{2029}c").name, "abc")
        XCTAssertEqual(AgentKind.of("\n\u{202E}\u{7}").name, "Agent", "nothing left to show")
        XCTAssertEqual(AgentKind.of("   ").name, "Agent")

        // Cut at 32 characters.
        let long = String(repeating: "k", count: 200)
        XCTAssertEqual(AgentKind.of(long).name, String(repeating: "k", count: 32))
        XCTAssertEqual(AgentKind.of(long).shortName.count, 32)

        // The symbol of a kind the table doesn't know never has the kind in it.
        for kind in ["deploy", "../x", "sparkle", "claude.fill", "terminal.fill", "x", long, "de\nploy", "\u{202E}abc", "Claude Code"] {
            let found = AgentKind.of(kind)
            XCTAssertFalse(found.isKnown, kind)
            XCTAssertEqual(found.symbolName, AgentKind.genericSymbol, kind)
            XCTAssertFalse(found.symbolName.contains(kind), kind)
        }
    }

    func testAgentInfoNames() {
        XCTAssertEqual(AgentInfo.shortName(ofKind: "claude"), "Claude")
        XCTAssertEqual(AgentInfo.shortName(ofKind: "copilot"), "Copilot")
        XCTAssertEqual(AgentInfo.shortName(ofKind: ""), "Agent")
        XCTAssertEqual(AgentInfo.shortName(ofKind: "other"), "Agent", "was \"Other\"")
        XCTAssertEqual(AgentInfo.shortName(ofKind: "deploy"), "deploy", "no longer capitalised")
        let gemini = AgentInfo(kind: "gemini", state: .running, source: "hook")
        XCTAssertEqual(gemini.shortKindName, "Gemini")
        XCTAssertEqual(gemini.kindName, "Gemini CLI")
        XCTAssertEqual(gemini.kindSymbolName, "sparkles")
        let deploy = AgentInfo(kind: "deploy", state: .waiting, source: "hook")
        XCTAssertEqual(deploy.kindName, "deploy")
        XCTAssertEqual(deploy.kindSymbolName, "terminal")
        XCTAssertEqual(AgentNotice(info: deploy, machine: "devbox").title, "deploy is waiting on devbox")
        XCTAssertEqual(AgentNotice(info: AgentInfo(kind: "other", state: .waiting, source: "osc", needsUser: true), machine: "devbox").title,
                       "Agent needs you on devbox")
    }

    func testSourcesAndReplies() {
        func agent(_ kind: String, _ source: String?) -> AgentInfo { AgentInfo(kind: kind, state: .waiting, source: source) }
        XCTAssertTrue(agent("other", "osc").isOscSourced)
        XCTAssertFalse(agent("other", "osc").isDetected)
        XCTAssertFalse(agent("other", "osc").isHookSourced)
        XCTAssertTrue(agent("claude", "detected").isDetected)
        XCTAssertTrue(agent("claude", nil).isDetected, "no source is a detected agent")
        XCTAssertFalse(agent("claude", "hook").isDetected)
        XCTAssertFalse(agent("claude", "hook").isOscSourced)

        XCTAssertTrue(agent("claude", "hook").acceptsReplies)
        XCTAssertTrue(agent("gemini", "hook").acceptsReplies)
        XCTAssertFalse(agent("deploy", "hook").acceptsReplies, "a script's report has nobody to answer")
        XCTAssertFalse(agent("other", "hook").acceptsReplies)
        XCTAssertFalse(agent("other", "osc").acceptsReplies)
        XCTAssertFalse(agent("claude", "detected").acceptsReplies)
        XCTAssertFalse(agent("claude", "osc").acceptsReplies)
    }

    func testIsValidName() {
        for name in ["claude", "deploy", "a", "nightly-backup.v2", "x_1", "0", ".hidden", "_", String(repeating: "a", count: 32)] {
            XCTAssertTrue(AgentKind.isValidName(name), name)
        }
        for name in ["", "-rf", "-", "Deploy", "my kind", "a/b", "../x", "a\nb", "naïve", "a;b", "$(x)", String(repeating: "a", count: 33)] {
            XCTAssertFalse(AgentKind.isValidName(name), name)
        }
        XCTAssertTrue(AgentKind.hookable.allSatisfy(AgentKind.isValidName))
    }
}
