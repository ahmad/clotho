import ClothoKit
import Foundation

extension AgentRow {
    /// The row's group, by ClothoKit's rule, which the Mac shares (`AgentInfo.statusGroup`). Only an agent with
    /// the daemon's attention (never a muted or a settling one) is in Needs you or Done; a finished turn is Done
    /// unless the daemon says the user has to act. Everything else, idle and resolved agents too, is Working.
    var group: AgentStatusGroup { info.statusGroup }

    /// The Agents tab's badge: the agents in Needs you. A turn that only finished (Done) doesn't count, as it
    /// doesn't in the widget.
    static func needsYouCount(_ rows: [AgentRow]) -> Int {
        rows.filter { $0.group == .needsYou }.count
    }

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

    /// The pane's progress for its agent's row: only from a daemon that reports it (feature `pane.progress`) and
    /// only while the machine is connected (`live`), so a saved model or a lost connection never leaves a bar
    /// standing.
    static func progress(of progress: PaneProgress?, features: Set<Hello.Feature>, live: Bool) -> PaneProgress? {
        live && features.contains(.paneProgress) ? progress : nil
    }
}
