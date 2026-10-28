#if LIVE_ACTIVITIES
import ActivityKit
import Foundation

/// A Live Activity that follows one agent (docs/push.md, "Live Activities"). Its content is what the machine
/// sends through the relay: the agent's state, kind and times, and the tool, the current command or file and
/// the last message or question. Those pass Apple and the relay unencrypted: the user chose to see them
/// ("Live Activity detail", 2026-10-28).
struct AgentActivityAttributes: ActivityAttributes {
    /// The relay's `content-state`, key for key. The text keys are optional: a clothod before the detail sends
    /// only the first four, and any of them is left out when it doesn't apply.
    struct ContentState: Codable, Hashable {
        /// running, waiting, done or error.
        var state: String
        /// The agent kind: claude, codex, other.
        var kind: String
        /// When the current state began (unix seconds).
        var since: Int
        /// When the turn began (unix seconds): the elapsed timer counts from here.
        var started: Int
        /// The tool in use, or the one waiting for permission: "Bash", "Edit".
        var tool: String? = nil
        /// The current command, file or pattern.
        var detail: String? = nil
        /// Done: the last message. Error: the error. Waiting: the question it shows.
        var msg: String? = nil
    }

    /// The app's id for the machine and the pane, to open it from the activity. Set on this phone when the
    /// activity starts; never sent anywhere.
    var machine: UUID
    var pane: UInt64
    /// Where the agent is and what it was asked, also set on this phone when the user follows it, and never
    /// sent anywhere. Optional, so activities an earlier build started still decode.
    var machineName: String? = nil
    var workspace: String? = nil
    var tab: String? = nil
    var prompt: String? = nil

    /// "devbox · Clotho / orchestrator".
    var place: String? {
        let inside = [workspace, tab].compactMap { $0.flatMap { Self.line($0, max: 60) } }.joined(separator: " / ")
        let parts = [machineName.flatMap { Self.line($0, max: 40) }, inside.isEmpty ? nil : inside].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One line, at most `max` characters, ending in "…" when cut; nil if nothing is left.
    static func line(_ text: String, max: Int = 120) -> String? {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if flat.isEmpty { return nil }
        return flat.count <= max ? flat : String(flat.prefix(max - 1)) + "…"
    }

    static func content(_ state: ContentState, staleAfter seconds: TimeInterval = 900) -> ActivityContent<ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(seconds))
    }
}

extension AgentActivityAttributes.ContentState {
    var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(started)) }
    var sinceDate: Date { Date(timeIntervalSince1970: TimeInterval(since)) }
    var isOver: Bool { state == "done" || state == "error" }

    /// "Claude", "Codex".
    var name: String { kind.prefix(1).uppercased() + kind.dropFirst() }

    /// "is working", "is waiting for you", "finished", "hit an error".
    var verb: String {
        switch state {
        case "waiting": return "is waiting for you"
        case "done": return "finished"
        case "error": return "hit an error"
        default: return "is working"
        }
    }

    /// The state line: "Claude is running Bash", "Claude wants to use Edit", "Claude finished".
    var headline: String {
        switch (state, tool.flatMap { AgentActivityAttributes.line($0, max: 64) }) {
        case ("running", let tool?): return "\(name) is running \(tool)"
        case ("waiting", let tool?): return "\(name) wants to use \(tool)"
        default: return "\(name) \(verb)"
        }
    }

    /// The tool for the compact Dynamic Island while it's in use: an MCP tool by its last part.
    var compactTool: String? {
        guard !isOver, let tool, !tool.isEmpty else { return nil }
        return tool.components(separatedBy: "__").last { !$0.isEmpty } ?? tool
    }

    /// The command or file, one line; only while the agent is in a tool.
    var detailLine: String? { isOver ? nil : detail.flatMap { AgentActivityAttributes.line($0, max: 200) } }

    /// The last message or the question; not while running.
    var messageLine: String? { state == "running" ? nil : msg.flatMap { AgentActivityAttributes.line($0, max: 300) } }

    var symbol: String {
        switch state {
        case "waiting": return "hand.raised.fill"
        case "done": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "sparkles"
        }
    }
}
#endif
