import Foundation

/// The text of a notification about an agent: one renderer for the Mac's notifications, the iOS app's
/// banners and the iOS push extension.
///
///     title     Platform · Claude finished
///     subtitle  devbox · api-server · 4m
///     body      Allow Bash: npm test?   (or the start of the agent's last message)
///
/// The workspace is the pane's, from the client's model (the push record's `w`), and the project is the
/// last part of the pane's cwd (`pj`). The time is the turn's length, once it ended. With no workspace
/// (older daemons, a pane the model doesn't place) the machine moves into the title, as before:
/// "Claude finished on devbox", and the subtitle keeps the rest.
public struct AgentNotice: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    /// The longest body, in characters; longer results are cut at a word with an ellipsis.
    public static let bodyLimit = 240

    /// From plain fields, as a push record carries them (`k`, `s`, `w`, `pj`, `d`, `msg`, `tool`, `cmd`, `sm`).
    /// `state` is the raw state name; `result` is the agent's message (for done, its last reply), in
    /// Markdown. `summary` is the daemon's one-line summary of it. `fallback` is the body when there is
    /// neither (the prompt, a tab title).
    ///
    /// The body: for a permission ask, "Allow Bash: npm test?" whole, then the summary in the room left.
    /// Otherwise the summary, else the message as plain text (`PlainText`), else the fallback.
    public init(kind: String, state: String, machine: String, workspace: String?, project: String?, duration: TimeInterval?,
                result: String?, tool: String?, toolInput: String?, fallback: String? = nil, summary: String? = nil) {
        let state = AgentInfo.State(rawValue: state) ?? .unknown
        let what = "\(AgentInfo.shortName(ofKind: kind)) \(state.noticeVerb)"
        let machine = machine.nonEmpty
        if let workspace = workspace?.nonEmpty {
            title = "\(workspace) · \(what)"
            subtitle = [machine, project?.nonEmpty, duration.flatMap(Self.duration)].compactMap { $0 }.joined(separator: " · ")
        } else {
            title = machine.map { "\(what) on \($0)" } ?? what
            subtitle = [project?.nonEmpty, duration.flatMap(Self.duration)].compactMap { $0 }.joined(separator: " · ")
        }
        let summary = summary.map(PlainText.oneLine)?.nonEmpty
        if let ask = Self.permissionAsk(state: state, message: result, tool: tool, toolInput: toolInput) {
            let flat = Self.clip(ask, to: .max)
            let room = Self.bodyLimit - flat.count - 1
            body = flat + (summary.flatMap { room >= 8 ? " " + Self.clip($0, to: room) : nil } ?? "")
        } else {
            let text = summary ?? result.map(PlainText.oneLine)?.nonEmpty ?? fallback.map(PlainText.oneLine)?.nonEmpty ?? ""
            body = Self.clip(text, to: Self.bodyLimit)
        }
    }

    /// From a pane's agent. `cwd` is the pane's; its last part names the project. With no result the body
    /// is the turn's prompt. A pending permission request (the oldest) names the tool it asks about.
    public init(info: AgentInfo, machine: String, workspace: String? = nil, cwd: String? = nil) {
        self.init(kind: info.kind, state: info.state.rawValue, machine: machine, workspace: workspace,
                  project: cwd.flatMap(Self.project), duration: info.turnDuration, result: info.message,
                  tool: info.pendingRequests.first?.tool ?? info.tool,
                  toolInput: info.pendingRequests.first.map(\.summary) ?? info.toolInput, fallback: info.prompt,
                  summary: info.summary)
    }

    /// What the agent came to. A permission wait (waiting, with a tool, and a message that mentions
    /// permission or is empty) reads "Allow Bash: npm test?" ("Allow Bash?" without input). The check
    /// matters because the tool is the turn's last one: a question ("Which database should I use?")
    /// must not read as "Allow Bash: ls?". Anything else, done turns included, is the message.
    /// The message comes back as plain text (`PlainText.oneLine`).
    public static func result(state: AgentInfo.State, message: String?, tool: String?, toolInput: String?) -> String? {
        permissionAsk(state: state, message: message, tool: tool, toolInput: toolInput) ?? message.map(PlainText.oneLine)?.nonEmpty
    }

    /// "Allow Bash: npm test?" for a permission wait, else nil. The command stays exactly as given
    /// (only its whitespace is collapsed): it's what the user is asked to allow.
    public static func permissionAsk(state: AgentInfo.State, message: String?, tool: String?, toolInput: String?) -> String? {
        let message = message?.nonEmpty
        guard state == .waiting, let tool = tool?.nonEmpty, message == nil || message!.lowercased().contains("permission") else { return nil }
        let input = toolInput.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }?.nonEmpty
        return "Allow \(tool)" + (input.map { ": \($0)" } ?? "") + "?"
    }

    /// The project a cwd is in: its last component ("/home/me/api-server/" is "api-server"); nil for
    /// the root and the home directory alone ("~").
    public static func project(_ cwd: String) -> String? {
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last, last != "~" else { return nil }
        return String(last)
    }

    /// "4m", "1h 5m", "12s"; nil under a second.
    public static func duration(_ seconds: TimeInterval) -> String? {
        let s = Int(seconds.rounded())
        switch s {
        case ..<1: return nil
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        default:
            let minutes = (s % 3600) / 60
            return minutes == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(minutes)m"
        }
    }

    /// The text on one paragraph (runs of whitespace become one space), cut at a word to `limit` characters.
    public static func clip(_ text: String, to limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

extension AgentInfo {
    /// "Claude", "Codex": the agent's short name, for notification titles.
    public var shortKindName: String { Self.shortName(ofKind: kind) }

    public static func shortName(ofKind kind: String) -> String {
        switch kind.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "": return "Agent"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    /// What the agent came to (see `AgentNotice.result`): "Allow Bash: npm test?" for a permission wait,
    /// else its message.
    public var result: String? { AgentNotice.result(state: state, message: message, tool: tool, toolInput: toolInput) }

    /// What the agent is at, on one line, for rows and subtitles: a permission ask ("Allow Bash: npm
    /// test?") exactly, else the daemon's summary, else the message as plain text. Nil when there's none.
    public var headline: String? {
        AgentNotice.permissionAsk(state: state, message: message, tool: tool, toolInput: toolInput)
            ?? summary.map(PlainText.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            ?? message.map(PlainText.oneLine).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension AgentInfo.State {
    /// What a notification says happened: "finished", "is waiting", "hit an error".
    public var noticeVerb: String {
        switch self {
        case .waiting: return "is waiting"
        case .done: return "finished"
        case .error: return "hit an error"
        case .running: return "is working"
        case .starting: return "is starting"
        case .unknown: return "changed"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
