import Foundation
import Security

/// What the "Needs you" widget shows (docs/ios-redesign.md, phase 6): agents that need the user, with no
/// terminal text and no agent messages. The app writes it when its agent list changes, the notification
/// extension adds each alert's agent, and the widget reads it. It lives in the Keychain group the app and its
/// extensions already share, so the widget needs no App Group.
struct AgentsSummary: Codable, Equatable, Sendable {
    struct Agent: Codable, Equatable, Sendable, Identifiable {
        var machine: UUID
        var machineName: String
        var pane: UInt64
        var workspace: String?
        var kind: String
        var state: String
        /// When it started needing the user (unix seconds).
        var since: Double
        var id: String { "\(machine.uuidString)/\(pane)" }
    }

    var updated: Double
    var agents: [Agent]

    static let empty = AgentsSummary(updated: 0, agents: [])
    /// The widget shows at most this many; more only make the item bigger.
    static let maxAgents = 12

    /// Newest first, at most `maxAgents`.
    func normalized() -> AgentsSummary {
        AgentsSummary(updated: updated, agents: Array(agents.sorted { $0.since > $1.since }.prefix(Self.maxAgents)))
    }

    /// An alert's agent added (or replacing the same pane's), for the notification extension: it knows
    /// what just started needing the user, not what stopped (the app's next write settles that).
    func adding(_ agent: Agent, now: Double) -> AgentsSummary {
        var agents = self.agents.filter { $0.id != agent.id }
        agents.append(agent)
        return AgentsSummary(updated: now, agents: agents).normalized()
    }

    // MARK: Keychain

    private static let service = "nyc.amin.clotho.agents-summary"
    private static let account = "summary"

    static func load() -> AgentsSummary {
        for group in [PushKey.accessGroup, nil] as [String?] {
            var query = baseQuery(group: group)
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
               let summary = try? JSONDecoder().decode(AgentsSummary.self, from: data) {
                return summary
            }
        }
        return .empty
    }

    /// Writes it if it changed; true if it did (so callers reload the widget only then).
    @discardableResult
    func save() -> Bool {
        guard let data = try? JSONEncoder().encode(self), self != Self.load() else { return false }
        for group in [PushKey.accessGroup, nil] as [String?] {
            let query = Self.baseQuery(group: group)
            let update = [kSecValueData as String: data] as [String: Any]
            if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess { return true }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    private static func baseQuery(group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }
}
