#if LIVE_ACTIVITIES
import ActivityKit
import ClothoKit
import Foundation

/// Following an agent with a Live Activity (docs/push.md, "Live Activities"): the app starts the activity,
/// gives the machine its push token (`push.activity`), and the machine keeps it current through the relay
/// until the turn ends. Only the agent's state, kind and times ever go into it.
extension MachineConnection {
    /// Whether this phone can follow agents on this machine: Live Activities on, alerts registered with it
    /// (the activity's updates use the same relay handle), and a clothod with push.activity.
    var canFollow: Bool {
        store.isConnected && store.features.contains(.pushActivity) && ActivityAuthorizationInfo().areActivitiesEnabled
            && alertsOn && PushRegistrar.shared.registration(for: machine) != nil
    }

    func isFollowing(_ pane: PaneID) -> Bool {
        Activity<AgentActivityAttributes>.activities.contains { $0.attributes.machine == machine.id && $0.attributes.pane == pane }
    }

    /// Starts following the pane's agent.
    func follow(_ pane: PaneID) {
        guard canFollow, !isFollowing(pane), let agent = store.state.pane(pane)?.agent else { return }
        let state = Self.activityState(agent)
        do {
            let activity = try Activity.request(attributes: AgentActivityAttributes(machine: machine.id, pane: pane),
                                                content: AgentActivityAttributes.content(state), pushType: .token)
            let backend = store.backend, device = PushRegistrar.shared.device, env = PushRegistrar.shared.environment
            let name = machine.displayName
            Task {
                // A token arrives at once and again whenever iOS rotates it; the machine keeps the latest.
                for await data in activity.pushTokenUpdates {
                    let token = data.map { String(format: "%02x", $0) }.joined()
                    do {
                        try await backend.pushActivity(pane: pane, device: device, token: token, env: env)
                    } catch {
                        log("[\(name)] push.activity failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            lastError = "Couldn't follow this agent: \(error.localizedDescription)"
        }
    }

    /// Stops following: ends the activity here and tells the machine to forget its token.
    func unfollow(_ pane: PaneID) {
        let backend = store.backend, device = PushRegistrar.shared.device
        for activity in Activity<AgentActivityAttributes>.activities where activity.attributes.machine == machine.id && activity.attributes.pane == pane {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        Task { try? await backend.pushActivityEnd(pane: pane, device: device) }
    }

    /// The first content, before the machine's first update: the same mapping clothod uses.
    static func activityState(_ agent: AgentInfo, now: Date = Date()) -> AgentActivityAttributes.ContentState {
        let state: String
        switch agent.state {
        case .waiting: state = "waiting"
        case .done: state = "done"
        case .error: state = "error"
        default: state = "running"
        }
        let since = Int(agent.since ?? now.timeIntervalSince1970)
        let started = agent.turnStarted.map { Int($0) } ?? since
        let kind = agent.kind.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return AgentActivityAttributes.ContentState(state: state, kind: kind.isEmpty ? "other" : kind, since: since, started: started)
    }
}
#endif
