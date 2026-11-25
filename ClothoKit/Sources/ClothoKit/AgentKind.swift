import Foundation

/// What the apps show for an agent's `kind` (protocol.md, "Agents"): its name, a short name for titles,
/// and an SF Symbol. One table, so the Mac and iOS say and draw the same thing.
///
/// A kind may be any name a reporter gave (`clothod report --kind deploy`, clothod 0.1.33, feature
/// `agent.kinds`). One this table doesn't know shows by its own name, as text made safe (`safeText`),
/// with the generic symbol. The symbol only ever comes from the switch over the known ids: a kind's
/// text never becomes part of a symbol, image or file name.
public struct AgentKind: Equatable, Sendable {
    /// The table's id for a known kind ("claude"; "other" for "" too); for an unknown one the kind as it
    /// was given. For comparing only: show `name`, and never build a name of anything from it.
    public let id: String
    /// "Claude Code", "GitHub Copilot CLI"; an unknown kind's own text.
    public let name: String
    /// "Claude", "Copilot": for notification titles and narrow rows.
    public let shortName: String
    /// An SF Symbol that exists on macOS 13 and iOS 16.
    public let symbolName: String
    /// Whether the table has this kind ("other" and "" included).
    public let isKnown: Bool
    /// One of the coding agents (Claude Code, Codex, …), as opposed to a script or a program that only
    /// sent a notification.
    public let isCodingAgent: Bool

    /// The symbol of "other" and of every kind the table doesn't know.
    public static let genericSymbol = "terminal"
    /// The name of "other", of "", and of a kind whose text has nothing safe to show.
    public static let genericName = "Agent"
    /// The longest kind name, in characters (the daemon's limit too).
    public static let nameLimit = 32
    /// The kinds `clothod hooks` can install for (clothod 0.1.33), in the order the apps list them.
    public static let hookable = ["claude", "codex", "gemini", "copilot"]

    public static func of(_ kind: String) -> AgentKind {
        switch kind.lowercased() {
        case "claude": return coding("claude", "Claude Code", "Claude")
        case "codex": return coding("codex", "Codex", "Codex")
        case "opencode": return coding("opencode", "OpenCode", "OpenCode")
        case "gemini": return coding("gemini", "Gemini CLI", "Gemini")
        case "copilot": return coding("copilot", "GitHub Copilot CLI", "Copilot")
        case "aider": return coding("aider", "Aider", "Aider")
        case "amp": return coding("amp", "Amp", "Amp")
        case "cursor": return coding("cursor", "Cursor Agent", "Cursor")
        case "other", "":
            return AgentKind(id: "other", name: genericName, shortName: genericName, symbolName: genericSymbol,
                             isKnown: true, isCodingAgent: false)
        default:
            let text = safeText(kind)
            return AgentKind(id: kind, name: text, shortName: text, symbolName: genericSymbol, isKnown: false, isCodingAgent: false)
        }
    }

    private static func coding(_ id: String, _ name: String, _ shortName: String) -> AgentKind {
        AgentKind(id: id, name: name, shortName: shortName, symbolName: symbol(ofKnown: id), isKnown: true, isCodingAgent: true)
    }

    /// The only place a symbol name is made: literals, chosen by a known id.
    private static func symbol(ofKnown id: String) -> String {
        switch id {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "curlybraces"
        case "gemini": return "sparkles"
        case "copilot": return "eyeglasses"
        case "aider": return "wrench.and.screwdriver"
        case "amp": return "bolt"
        case "cursor": return "cursorarrow"
        default: return genericSymbol
        }
    }

    /// A kind's text, safe to show on one line: control characters, format characters (the bidi
    /// overrides and marks among them), line and paragraph separators and private-use characters are
    /// dropped, then it is cut at 32 characters. With nothing left it reads "Agent".
    public static func safeText(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isHidden(scalar) { kept.append(scalar) }
        let cut = String(String(kept).trimmingCharacters(in: .whitespaces).prefix(nameLimit))
        return cut.isEmpty ? genericName : cut
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse: return true
        default: return false
        }
    }

    /// Whether `name` is a kind as the daemon keeps one: 1 to 32 of a-z, 0-9, ".", "_" and "-", not
    /// starting with "-" (it would read as an option to `clothod hooks`).
    public static func isValidName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= nameLimit, !name.hasPrefix("-") else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }
}
