import ClothoKit
import Foundation

/// The Agents list's three groups, in the order they show.
enum AgentGroup: Int, CaseIterable, Sendable {
    /// The user has to do something: a question, a permission ask, an error, or a finished turn that ends in one.
    case needsYou
    /// A turn that just finished, with nothing to answer. Resolve (or the agent's next turn) moves it on.
    case done
    /// Everything else: running, starting, settling, idle, resolved and muted agents. Folded away by default.
    case working

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .working: return "Working"
        }
    }

    /// The group of an agent, from what ClothoKit says about it. Only an agent with the daemon's attention
    /// (`needsAttention`: never a muted or a settling one) is in the first two. A finished turn is Done unless the
    /// daemon says the user has to act (`needsUser` true); an older daemon doesn't say (nil), and its finished
    /// turns are Done too.
    init(_ info: AgentInfo) {
        guard info.needsAttention else { self = .working; return }
        self = info.state == .done && info.needsUser != true ? .done : .needsYou
    }
}

extension AgentRow {
    var group: AgentGroup { AgentGroup(info) }

    /// The rows of each group, in order: Needs you with the longest wait first, Done with the newest first,
    /// Working as `sorted` ranks it (idle, running, starting, then resolved ones).
    static func groups(_ rows: [AgentRow]) -> (needsYou: [AgentRow], done: [AgentRow], working: [AgentRow]) {
        let by = Dictionary(grouping: rows, by: \.group)
        return ((by[.needsYou] ?? []).sorted(by: groupOrder), (by[.done] ?? []).sorted(by: groupOrder), sorted(by[.working] ?? []))
    }

    /// By group, then by time: the oldest first among those that need the user (it has waited longest; one
    /// without a time counts as oldest), the newest first in the others. The pinned section's order.
    static func groupOrder(_ a: AgentRow, _ b: AgentRow) -> Bool {
        let (groupA, groupB) = (a.group, b.group)
        if groupA != groupB { return groupA.rawValue < groupB.rawValue }
        let (sinceA, sinceB) = (a.info.since ?? 0, b.info.since ?? 0)
        if sinceA != sinceB { return groupA == .needsYou ? sinceA < sinceB : sinceA > sinceB }
        return a.id < b.id
    }

    /// The pane's change counts for its agent's row, only from a daemon that counts them (feature `git.changes`).
    static func changes(of git: PaneGit?, features: Set<Hello.Feature>?) -> PaneGit.Changes? {
        features?.contains(.gitChanges) == true ? git?.changes : nil
    }
}
