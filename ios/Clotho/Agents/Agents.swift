import ClothoKit
import Foundation
import SwiftUI
import UserNotifications

/// One coding agent on one machine, for the Agents list. Keyed by (machine, pane), since pane ids are
/// only unique per daemon.
struct AgentRow: Identifiable, Hashable {
    let machineID: UUID
    let machineName: String
    let pane: PaneID
    let tab: TabID
    let workspace: String
    let title: String
    let info: AgentInfo

    var id: String { "\(machineID.uuidString)/\(pane)" }

    /// Only an agent that reported through its hook that it's waiting on the user, and hasn't been answered
    /// yet, takes a quick reply. Idle, detected (quiet output read as waiting) or acknowledged agents don't.
    var acceptsReply: Bool { info.state == .waiting && info.isHookSourced && wantsAttention }

    /// The daemon's `attention`: set when an agent reports it needs the user (or rings the bell), cleared when
    /// the agent starts working again or the user resolves it (agent.ack, on any device). Viewing, opening or
    /// typing doesn't clear it. A detected agent that just went quiet is waiting without it.
    /// A muted agent never wants it (AgentInfo.needsAttention).
    var wantsAttention: Bool { info.needsAttention }

    /// Muted by the user (agent.mute): it stays under Quiet and sends no notifications until unmuted or until
    /// this agent session ends.
    var isMuted: Bool { info.isMuted }

    /// Anything wanting attention first (waiting, then errors, then finished), then the rest; newest first within each.
    static func sorted(_ rows: [AgentRow]) -> [AgentRow] {
        func rank(_ row: AgentRow) -> Int {
            switch (row.info.state, row.wantsAttention) {
            case (.waiting, true): return 0
            case (.error, true): return 1
            case (.done, true): return 2
            case (.waiting, false): return 3
            case (.running, _): return 4
            case (.starting, _): return 5
            case (.error, false): return 6
            case (.done, false): return 7
            case (.unknown, _): return 8
            }
        }
        return rows.sorted {
            (rank($0), -($0.info.since ?? 0), $0.id) < (rank($1), -($1.info.since ?? 0), $1.id)
        }
    }

    /// The Agents list's two parts: agents that need the user (the daemon's `attention`), at the top with a
    /// Resolve action, and the quiet rest (running, idle, resolved), folded away. Resolving on any device
    /// clears attention everywhere; the agent comes back to the top when attention is raised again.
    static func split(_ rows: [AgentRow]) -> (attention: [AgentRow], quiet: [AgentRow]) {
        let sorted = sorted(rows)
        return (sorted.filter(\.wantsAttention), sorted.filter { !$0.wantsAttention })
    }

    static func == (a: AgentRow, b: AgentRow) -> Bool { a.id == b.id && a.info == b.info && a.title == b.title }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension MachineConnection {
    /// The agents in this machine's model. With the FakeAgents setting (`-FakeAgents YES`), panes
    /// without an `agent` get a made-up one, so the list can be worked on before clothod reports agents.
    var agentRows: [AgentRow] {
        let state = store.state
        var rows: [AgentRow] = []
        for workspace in state.workspaces {
            for tab in workspace.tabs {
                for id in tab.layout.panes {
                    guard let pane = state.pane(id), let info = pane.agent ?? fakeAgent(for: pane) else { continue }
                    rows.append(AgentRow(machineID: machine.id, machineName: machine.displayName, pane: id, tab: tab.id,
                                         workspace: workspace.name, title: store.displayTitle(of: tab), info: info))
                }
            }
        }
        return rows
    }

    /// Whether this machine's daemon takes `agent.mute` (always for made-up agents).
    var canMute: Bool { FakeAgents.enabled || (store.hello?.features.contains(.agentMute) ?? false) }

    /// `agent.mute`: keeps the agent quiet (no attention, no notifications) until unmuted or until this agent
    /// session ends. The daemon owns it, so it applies on every device.
    func muteAgent(_ pane: PaneID, _ muted: Bool) {
        if store.state.pane(pane)?.agent == nil {
            if muted { fakeMuted.insert(pane) } else { fakeMuted.remove(pane) }
            objectWillChange.send()
            return
        }
        guard canMute else { return }
        run(muted ? "Mute" : "Unmute") { try await $0.muteAgent(pane, muted: muted) }
    }

    /// `agent.ack`: the user resolved this agent. The only place the app clears attention (Resolve).
    func ackAgent(_ pane: PaneID) {
        if store.state.pane(pane)?.agent == nil {
            fakeAcked.insert(pane)
            objectWillChange.send()
            return
        }
        run("Acknowledge") { try await $0.ackAgent(pane) }
    }

    /// Whether this machine's daemon takes `pane.keys`, which quick replies need: a bare CR doesn't submit once
    /// an agent turns on the kitty keyboard protocol, and only the daemon knows the pane's current modes.
    /// Older daemons get no reply action (never a raw-CR fallback).
    var canReply: Bool { store.hello?.features.contains(.paneKeys) ?? false }

    /// Answers a waiting agent: `text` (pasted, bracketed if the app asked) and then `keys` such as ["enter"],
    /// encoded by the daemon for the pane's modes. The agent leaves the top of the list when it starts working
    /// on the reply (its state changes), not because of the input itself.
    func reply(to pane: PaneID, text: String?, keys: [String]) {
        guard canReply else { return }
        run("Reply") { try await $0.sendKeys(pane, text: text?.isEmpty == true ? nil : text, keys: keys) }
    }

    private func fakeAgent(for pane: Pane) -> AgentInfo? {
        guard FakeAgents.enabled, pane.exited == nil else { return nil }
        let states: [AgentInfo.State] = [.waiting, .running, .done, .error, .starting]
        let state = states[Int((pane.id + UInt64(states.count) - 1) % UInt64(states.count))]
        let messages: [AgentInfo.State: String] = [
            .waiting: "Allow `cargo test --release`?", .running: "Editing src/protocol.rs",
            .done: "Finished: 3 files changed", .error: "API error: overloaded", .starting: "Starting",
        ]
        return AgentInfo(kind: pane.id % 2 == 0 ? "codex" : "claude", state: state, source: "hook", message: messages[state],
                         since: Date().timeIntervalSince1970 - Double(pane.id) * 90,
                         attention: state != .running && state != .starting && !fakeAcked.contains(pane.id)
                            && !fakeMuted.contains(pane.id),
                         muted: fakeMuted.contains(pane.id))
    }
}

enum FakeAgents {
    /// Off unless asked for (`-FakeAgents YES` as a launch argument), so made-up agents never sit next to real ones.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "FakeAgents") }
}

// MARK: - Notifications

/// Local notifications when an agent starts needing the user, while the app is running. While it's closed,
/// machines send the same alert as a push (docs/push.md, PushRegistrar); both use the pane's collapse id
/// as their identifier, so one replaces the other instead of stacking.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    /// The user tapped a notification; the home screen opens that pane.
    var onOpen: ((UUID, PaneID) -> Void)?
    /// Whether the app has a live connection to a machine, whose own notifications make its pushes redundant.
    var isLive: ((UUID) -> Bool)?
    private var authorized = false

    /// While the welcome guide shows, it asks for permission itself, at its notifications step.
    var deferPrompt = false

    /// Becomes the notification delegate and reads the current permission. It doesn't ask for it: that waits
    /// until there's a machine whose agents can need the user (the guide's step, or `promptIfUndecided`).
    func setUp() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
        // UI tests other than the guide's expect the prompt at launch, as before the guide had a step for it.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-UITesting") && !arguments.contains("-CleanState") { Task { await requestPermission() } }
    }

    /// The user can change the permission in Settings while the app is in the background.
    func refreshAuthorization() {
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            authorized = [.authorized, .provisional, .ephemeral].contains(status)
        }
    }

    /// Asks for permission (the system prompt shows once per install) and returns whether it was given.
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
        return granted
    }

    /// Asks once a machine is connected, for users who skipped the guide's step.
    func promptIfUndecided() {
        guard !deferPrompt, !ProcessInfo.processInfo.arguments.contains("-UITesting") else { return }
        Task {
            guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined, !deferPrompt else { return }
            await requestPermission()
        }
    }

    func agentChanged(machine: Machine, pane: PaneID, title: String, before: AgentInfo?, after: AgentInfo?) {
        // Only when the daemon raises attention (false → true), not on every state change.
        // A muted agent never notifies (needsAttention is false while muted).
        guard authorized, let after, after.needsAttention, before?.needsAttention != true else { return }
        let content = UNMutableNotificationContent()
        content.title = AlertText.title(kind: after.kind, state: after.state.rawValue, machine: machine.displayName)
        content.body = after.message ?? title
        content.sound = .default
        content.threadIdentifier = machine.id.uuidString
        content.userInfo = ["machine": machine.id.uuidString, "pane": pane]
        let label = PushLabel.make(machine: machine.id, name: machine.displayName)
        let request = UNNotificationRequest(identifier: PushLabel.collapseID(label: label, pane: pane), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Removes delivered agent notifications (local or pushed) for a machine's panes that no longer want attention.
    func removeDelivered(machine: UUID, except attention: Set<PaneID>) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = delivered.filter { note in
                let info = note.request.content.userInfo
                guard info["machine"] as? String == machine.uuidString, let pane = (info["pane"] as? NSNumber)?.uint64Value else { return false }
                return !attention.contains(pane)
            }.map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A push for a machine the app is connected to repeats the local notification it already showed.
        let info = notification.request.content.userInfo
        let pushed = notification.request.trigger is UNPushNotificationTrigger
        let machine = (info["machine"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if pushed, let machine, self.isLive?(machine) == true { completionHandler([]) } else { completionHandler([.banner, .sound, .list]) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let machine = (info["machine"] as? String).flatMap(UUID.init(uuidString:)), let pane = (info["pane"] as? NSNumber)?.uint64Value {
            Task { @MainActor in self.onOpen?(machine, pane) }
        }
        completionHandler()
    }
}
