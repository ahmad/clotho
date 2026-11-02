import ClothoKit
import Foundation

/// Agents the user pinned on this phone: they get their own section at the top of the Agents list, tinted.
/// Keyed by machine and pane (pane ids are only unique per daemon) and kept in UserDefaults, so pins survive
/// relaunches. Only on this phone: not sent to the machine or the Mac.
///
/// A pin goes away when its pane closes or its agent leaves the pane (`prune`, from the machine's live model).
@MainActor
final class AgentPins: ObservableObject {
    static let shared = AgentPins()
    static let storageKey = "PinnedAgents"

    @Published private(set) var keys: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    static func key(machine: UUID, pane: PaneID) -> String { "\(machine.uuidString)/\(pane)" }

    func isPinned(machine: UUID, pane: PaneID) -> Bool { keys.contains(Self.key(machine: machine, pane: pane)) }
    func isPinned(_ row: AgentRow) -> Bool { isPinned(machine: row.machineID, pane: row.pane) }

    func setPinned(_ pinned: Bool, machine: UUID, pane: PaneID) {
        var next = keys
        let key = Self.key(machine: machine, pane: pane)
        if pinned { next.insert(key) } else { next.remove(key) }
        save(next)
    }

    func toggle(_ row: AgentRow) { setPinned(!isPinned(row), machine: row.machineID, pane: row.pane) }

    /// Drops the machine's pins whose pane no longer has an agent. Call only with a live model (connected, not the
    /// saved one), so a machine that's still connecting doesn't lose its pins.
    func prune(machine: UUID, agentPanes: Set<PaneID>) {
        let prefix = machine.uuidString + "/"
        let next = keys.filter { key in
            guard key.hasPrefix(prefix), let pane = PaneID(key.dropFirst(prefix.count)) else { return true }
            return agentPanes.contains(pane)
        }
        if next != keys { save(next) }
    }

    /// Splits rows into the pinned ones (those that need the user first, then the newest) and the rest.
    func split(_ rows: [AgentRow]) -> (pinned: [AgentRow], rest: [AgentRow]) {
        let pinned = rows.filter(isPinned).sorted {
            ($0.wantsAttention ? 0 : 1, -($0.info.since ?? 0), $0.id) < ($1.wantsAttention ? 0 : 1, -($1.info.since ?? 0), $1.id)
        }
        return (pinned, rows.filter { !isPinned($0) })
    }

    private func save(_ next: Set<String>) {
        keys = next
        defaults.set(next.sorted(), forKey: Self.storageKey)
    }
}
