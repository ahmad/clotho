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

    /// A waiting agent takes a typed answer (quick reply, next).
    var acceptsReply: Bool { info.state == .waiting }

    /// The daemon's `attention`: set when an agent reports it needs the user (or rings the bell), cleared by
    /// input or agent.ack on any device. A detected agent that just went quiet is waiting without it.
    var wantsAttention: Bool { info.attention == true }

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

    /// `agent.ack`: the user has seen this agent's state.
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
    /// encoded by the daemon for the pane's modes. Counts as input, so the daemon clears attention.
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
        return AgentInfo(kind: pane.id % 2 == 0 ? "codex" : "claude", state: state, source: "fake", message: messages[state],
                         since: Date().timeIntervalSince1970 - Double(pane.id) * 90,
                         attention: state != .running && state != .starting && !fakeAcked.contains(pane.id))
    }
}

enum FakeAgents {
    /// Off unless asked for (`-FakeAgents YES` as a launch argument), so made-up agents never sit next to real ones.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "FakeAgents") }
}

// MARK: - Notifications

/// Local notifications when an agent starts needing the user, while the app is running. Background alerts
/// need the APNs relay (later).
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    /// The user tapped a notification; the home screen opens that pane.
    var onOpen: ((UUID, PaneID) -> Void)?
    private var authorized = false

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func agentChanged(machine: Machine, pane: PaneID, title: String, before: AgentInfo?, after: AgentInfo?) {
        // Only when the daemon raises attention (false → true), not on every state change.
        guard authorized, let after, after.attention == true, before?.attention != true else { return }
        let content = UNMutableNotificationContent()
        let name = after.kind.prefix(1).uppercased() + after.kind.dropFirst()
        switch after.state {
        case .waiting: content.title = "\(name) is waiting on \(machine.displayName)"
        case .error: content.title = "\(name) hit an error on \(machine.displayName)"
        default: content.title = "\(name) finished on \(machine.displayName)"
        }
        content.body = after.message ?? title
        content.sound = .default
        content.threadIdentifier = machine.id.uuidString
        content.userInfo = ["machine": machine.id.uuidString, "pane": pane]
        let request = UNNotificationRequest(identifier: "\(machine.id.uuidString)/\(pane)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
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
