import Foundation

/// The three groups every client sorts agents into, and their titles: the iOS Agents list, the Mac's
/// sidebar inbox and its Overview all say "Needs you", "Done" and "Working".
public enum AgentStatusGroup: Int, CaseIterable, Sendable {
    /// The user has to act: a wait, a failed turn, a finished turn that asks something, a bell.
    case needsYou
    /// A turn finished and asks nothing, and nobody has looked yet.
    case done
    /// The rest.
    case working

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .working: return "Working"
        }
    }
}

public extension AgentInfo {
    /// The group of an agent whose attention is raised: Done for a finished turn that doesn't ask the
    /// user (`needsUser` false, or nil from an older daemon), Needs you for everything else. Nil without
    /// `needsAttention`, so a settling or a muted agent is in neither.
    var attentionGroup: AgentStatusGroup? {
        guard needsAttention else { return nil }
        return state == .done && needsUser != true ? .done : .needsYou
    }

    /// The agent's group where every agent has one (the iOS list): its attention group, else Working.
    var statusGroup: AgentStatusGroup { attentionGroup ?? .working }

    /// The agent's group where only active agents show (the Mac's inbox and Overview): its attention
    /// group, else Working only while it runs or starts. Nil for the rest: idle, resolved, settling, or
    /// muted and not running.
    var activeStatusGroup: AgentStatusGroup? {
        attentionGroup ?? (state == .running || state == .starting ? .working : nil)
    }
}
