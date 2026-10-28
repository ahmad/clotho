#if LIVE_ACTIVITIES
import ActivityKit
import Foundation

/// A Live Activity that follows one agent (docs/push.md, "Live Activities"). Its content is what the machine
/// sends through the relay, and only that: the agent's state and kind and two times. No text ever: Live
/// Activity updates aren't encrypted for the phone (the user's decision 3).
struct AgentActivityAttributes: ActivityAttributes {
    /// The relay's `content-state`, key for key.
    struct ContentState: Codable, Hashable {
        /// running, waiting, done or error.
        var state: String
        /// The agent kind: claude, codex, other.
        var kind: String
        /// When the current state began (unix seconds).
        var since: Int
        /// When the turn began (unix seconds): the elapsed timer counts from here.
        var started: Int
    }

    /// The app's id for the machine and the pane, to open it from the activity. Set on this phone when the
    /// activity starts; never sent anywhere.
    var machine: UUID
    var pane: UInt64

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
