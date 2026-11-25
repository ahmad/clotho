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
    /// How much changed in the pane's work tree, when the machine counts it (feature `git.changes`); the
    /// caption shows it.
    var changes: PaneGit.Changes? = nil
    /// How far the pane's program says it is (feature `pane.progress`), only from a machine that is connected
    /// now (`AgentRow.progress(of:features:live:)`): a thin bar under the caption. Only drawn and spoken on the
    /// row: no alert, banner, badge or widget entry reads it, and it has no part in the order.
    var progress: PaneProgress? = nil

    var id: String { "\(machineID.uuidString)/\(pane)" }

    /// Only a coding agent that reported through its hook that it's waiting on the user, and hasn't been
    /// answered yet, takes a quick reply (`AgentInfo.acceptsReplies`). Idle, detected (quiet output read as
    /// waiting) or acknowledged agents don't, and neither does a script's report or a program's notification
    /// (`source: "osc"`): nobody there reads a reply.
    var acceptsReply: Bool { info.state == .waiting && info.acceptsReplies && wantsAttention }

    /// The daemon's `attention`: set when an agent reports it needs the user (or rings the bell), cleared when
    /// the agent starts working again or the user resolves it (agent.ack, on any device). Viewing, opening or
    /// typing doesn't clear it. A detected agent that just went quiet is waiting without it.
    /// A muted agent never wants it (AgentInfo.needsAttention).
    var wantsAttention: Bool { info.needsAttention }

    /// Muted by the user (agent.mute): it stays under Working and sends no notifications until unmuted or until
    /// this agent session ends.
    var isMuted: Bool { info.isMuted }

    /// Anything wanting attention first (waiting, then errors, then finished), then the rest; newest first within each.
    /// The order of `Connections.agentRows` and of the Working group; the list's groups are `groups` (AgentGroups).
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

    /// Agents with the daemon's `attention` (Needs you and Done together) and the rest. The list itself shows
    /// `groups` (AgentGroups), and the tab's badge counts Needs you only (`needsYouCount`). Resolving on any
    /// device clears attention everywhere; the agent comes back to the top when attention is raised again.
    static func split(_ rows: [AgentRow]) -> (attention: [AgentRow], quiet: [AgentRow]) {
        let sorted = sorted(rows)
        return (sorted.filter(\.wantsAttention), sorted.filter { !$0.wantsAttention })
    }

    /// What the row draws. The change counts compare without their token (`counts`): an edit that leaves every
    /// count as it was is no reason to redraw.
    static func == (a: AgentRow, b: AgentRow) -> Bool {
        a.id == b.id && a.info == b.info && a.title == b.title && a.changes?.counts == b.changes?.counts
            && a.progress == b.progress
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension MachineConnection {
    /// The agents in this machine's model. With the FakeAgents setting (`-FakeAgents YES`), panes
    /// without an `agent` get a made-up one, so the list can be worked on before clothod reports agents.
    var agentRows: [AgentRow] {
        let state = store.state
        let features = store.hello?.features
        // Progress is live or nothing: never from a saved model, or while the machine is away.
        let live = store.isConnected && !store.isSaved
        var rows: [AgentRow] = []
        for workspace in state.workspaces {
            for tab in workspace.tabs {
                for id in tab.layout.panes {
                    guard let pane = state.pane(id), let info = pane.agent ?? fakeAgent(for: pane) else { continue }
                    // A made-up agent gets made-up counts; a real one its pane's, from a daemon that counts them.
                    let changes = pane.agent == nil ? MachineConnection.fakeChanges(info) : AgentRow.changes(of: pane.git, features: features)
                    let progress = pane.agent == nil ? FakeAgents.progress(info, pane: id)
                        : AgentRow.progress(of: pane.progress, features: store.features, live: live)
                    rows.append(AgentRow(machineID: machine.id, machineName: machine.displayName, pane: id, tab: tab.id,
                                         workspace: workspace.name, title: store.displayTitle(of: tab), info: info, changes: changes,
                                         progress: progress))
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

    /// Whether this machine answers permission requests (`agent.decide`, clothod 0.1.13).
    var canDecide: Bool { store.isConnected && store.features.contains(.agentDecide) }

    enum DecideResult: Equatable {
        case done
        /// Answered already (here, on another device or in the terminal), or the request moved on.
        case alreadyAnswered
        case failed(String)
    }

    /// Answers one permission request, by its id, exactly once. A stale request is not an error to retry:
    /// someone answered it, or the turn moved on.
    func decide(_ pane: PaneID, request: String, decision: PermissionDecision, message: String? = nil) async -> DecideResult {
        do {
            try await store.backend.decide(pane: pane, request: request, decision: decision,
                                           message: decision == .deny ? (message ?? "Denied from the phone") : nil)
            answered[pane] = decision
            objectWillChange.send()
            return .done
        } catch let error as BackendError where error.isStale {
            return .alreadyAnswered
        } catch {
            // The request and the daemon's answer, for diagnosing a failed answer from a notification or card.
            let code = (error as? BackendError)?.code ?? "?"
            log("[\(machine.displayName)] agent.decide {pane: \(pane), request: \(request), decision: \(decision.rawValue)} failed: code \(code), \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
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
        // Waiting and errors need the user; a finished turn does on odd panes only, so every group has rows.
        let needsUser: Bool?
        switch state {
        case .waiting, .error: needsUser = true
        case .done: needsUser = pane.id % 2 == 1
        default: needsUser = nil
        }
        // With `-FakeAgentKinds YES` the other kinds, a script's report and a program's notification stand in.
        let made = FakeAgents.kinds ? FakeAgents.kind(for: pane.id) : nil
        return AgentInfo(kind: made?.kind ?? (pane.id % 2 == 0 ? "codex" : "claude"), state: state, source: made?.source ?? "hook",
                         message: made?.message ?? messages[state],
                         since: Date().timeIntervalSince1970 - Double(pane.id) * 90,
                         attention: state != .running && state != .starting && !fakeAcked.contains(pane.id)
                            && !fakeMuted.contains(pane.id),
                         muted: fakeMuted.contains(pane.id), needsUser: needsUser)
    }

    /// Made-up change counts for a made-up agent: on the waiting and the finished ones.
    private static func fakeChanges(_ info: AgentInfo) -> PaneGit.Changes? {
        switch info.state {
        case .waiting: return PaneGit.Changes(uncommitted: .init(files: 6, added: 128, removed: 32))
        case .done: return PaneGit.Changes(uncommitted: .init(files: 3, added: 41, removed: 7))
        default: return nil
        }
    }
}

enum FakeAgents {
    /// Off unless asked for (`-FakeAgents YES` as a launch argument), so made-up agents never sit next to real ones.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "FakeAgents") }

    /// With `-FakeAgentKinds YES` as well, the made-up agents are of every kind and the running ones show a
    /// progress, so screenshots need no typing. Off by default: the plain fakes stay Claude and Codex.
    static var kinds: Bool { enabled && UserDefaults.standard.bool(forKey: "FakeAgentKinds") }

    /// What `kinds` cycles through, by pane id: the other coding agents, a script's own kind reported through
    /// the hook, and a program's notification (`source: "osc"`), whose text is plain and reads as typed.
    static let made: [(kind: String, source: String, message: String?)] = [
        ("gemini", "hook", nil), ("opencode", "hook", nil), ("copilot", "hook", nil), ("aider", "hook", nil),
        ("amp", "hook", nil), ("cursor", "hook", nil), ("deploy", "hook", nil),
        ("other", "osc", "**Build** finished: see [log](http://x)"),
    ]

    static func kind(for pane: PaneID) -> (kind: String, source: String, message: String?) {
        made[Int(pane % UInt64(made.count))]
    }

    /// A made-up progress for a made-up running agent (only with `kinds`). The running fakes are every fifth
    /// pane, so the turn is counted in fives: every other one is at 40 percent (ten panes in a row always show
    /// one), and those between are indeterminate and an error in turn.
    static func progress(_ info: AgentInfo, pane: PaneID, kinds: Bool = FakeAgents.kinds) -> PaneProgress? {
        guard kinds, info.state == .running else { return nil }
        let turn = pane / 5
        if turn % 2 == 0 { return PaneProgress(state: .running, percent: 40) }
        return (turn / 2) % 2 == 0 ? PaneProgress(state: .indeterminate) : PaneProgress(state: .error, percent: 55)
    }
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
    /// The user picked one of a notification's actions (Allow, Deny, Reply); RootView carries it out. Actions
    /// that arrive before it's set (a background launch for the action) wait for it.
    var onAction: ((AlertAction) async -> Void)? {
        didSet {
            guard let onAction else { return }
            let waiting = pendingActions
            pendingActions = []
            for (action, done) in waiting {
                Task { await onAction(action); done() }
            }
        }
    }
    private var pendingActions: [(AlertAction, () -> Void)] = []
    /// Whether the app has a live connection to a machine, whose own notifications make its pushes redundant.
    var isLive: ((UUID) -> Bool)?
    private var authorized = false

    /// While the welcome guide shows, it asks for permission itself, at its notifications step.
    var deferPrompt = false

    /// Becomes the notification delegate and reads the current permission. It doesn't ask for it: that waits
    /// until there's a machine whose agents can need the user (the guide's step, or `promptIfUndecided`).
    func setUp() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(AlertActions.categories)
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

    /// Where the agent is: its workspace and tab, from the machine's model.
    struct Place: Equatable {
        var workspace: String?
        var workspaceID: WorkspaceID?
        var tab: String
        /// The pane's cwd, whose last part names the project.
        var cwd: String? = nil
    }

    func agentChanged(machine: Machine, pane: PaneID, place: Place, before: AgentInfo?, after: AgentInfo?) {
        let key = HeldKey(machine: machine.id, pane: pane)
        if var entry = held[key] {
            // A held banner follows the agent: it goes once the summary lands, and not at all if the agent moved on.
            entry.machine = machine
            entry.place = place
            entry.agent = after
            held[key] = entry
            if after?.isSummaryPending != true { release(key) }
            return
        }
        guard authorized, let after, after.notifiesRise(from: before) else { return }
        // The machine is rewriting the message (clothod 0.1.29): wait for it, as the push does, up to
        // `summaryWait`, then go with whatever summary there is.
        if after.isSummaryPending {
            let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.release(key) } }
            held[key] = Held(machine: machine, place: place, state: after.state, agent: after, timer: timer)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.summaryWait, execute: timer)
            return
        }
        post(machine: machine, pane: pane, place: place, agent: after)
    }

    /// How long a banner waits for the machine's summary: as long as clothod holds a push for it.
    static var summaryWait: TimeInterval = 6

    private struct HeldKey: Hashable {
        var machine: UUID
        var pane: PaneID
    }

    private struct Held {
        var machine: Machine
        var place: Place
        var state: AgentInfo.State
        var agent: AgentInfo?
        var timer: DispatchWorkItem
    }

    private var held: [HeldKey: Held] = [:]

    /// Posts a held banner with the agent as it is now, unless it no longer needs the user in the same state.
    private func release(_ key: HeldKey) {
        guard let entry = held.removeValue(forKey: key) else { return }
        entry.timer.cancel()
        guard let agent = entry.agent, agent.needsAttention, agent.state == entry.state else { return }
        post(machine: entry.machine, pane: key.pane, place: entry.place, agent: agent)
    }

    private func post(machine: Machine, pane: PaneID, place: Place, agent: AgentInfo) {
        guard authorized, let request = Self.banner(machine: machine, pane: pane, place: place, before: nil, after: agent) else { return }
        UNUserNotificationCenter.current().add(request)
    }

    /// The local banner for an agent change, if it calls for one: only when the daemon raises attention
    /// (false → true) into waiting, done or error, not on every state change. Never for a muted agent, or for
    /// a quiet rise (a turn that ended while the user was at the pane, which the daemon doesn't push either);
    /// those still badge and show in the Agents list, which follow `needsAttention`. Nor for a settling one,
    /// whose attention hasn't risen yet. It reads like the push for the same rise (AlertText), which it
    /// replaces (same identifier), and like it a turn that only finished (done, `needsUser` false) is silent.
    /// Reply is offered only for an agent that takes one (`AgentInfo.acceptsReplies`), as on its row.
    static func banner(machine: Machine, pane: PaneID, place: Place, before: AgentInfo?, after: AgentInfo?) -> UNNotificationRequest? {
        guard let after, after.notifiesRise(from: before) else { return nil }
        let content = UNMutableNotificationContent()
        AlertText.apply(notice(machine: machine, place: place, agent: after), state: after.state.rawValue,
                        needsUser: after.needsUser, workspace: place.workspace, tab: place.tab, to: content)
        content.threadIdentifier = AlertText.thread(machine: machine.id, workspace: place.workspaceID.map(String.init) ?? place.workspace)
        content.sound = after.playsSound ? .default : nil
        var info: [String: Any] = ["machine": machine.id.uuidString, "pane": pane]
        let request = after.state == .waiting ? after.pendingRequests.first?.id : nil
        if let request { info["request"] = request }
        content.userInfo = info
        content.categoryIdentifier = AlertActions.category(state: after.state.rawValue, request: request,
                                                                  acceptsReplies: after.acceptsReplies)
        let label = PushLabel.make(machine: machine.id, name: machine.displayName)
        return UNNotificationRequest(identifier: PushLabel.collapseID(label: label, pane: pane), content: content, trigger: nil)
    }

    /// As the push for the same rise reads; the tab title is the last fallback for the body, as before. An osc
    /// agent's text is a program's output, plain by contract: it is shown as typed, never read as Markdown.
    static func notice(machine: Machine, place: Place, agent: AgentInfo) -> AgentNotice {
        AgentNotice(kind: agent.kind, state: agent.state.rawValue, machine: machine.displayName, workspace: place.workspace,
                    project: place.cwd.flatMap(AgentNotice.project), duration: agent.turnDuration, result: agent.message,
                    // The oldest pending request, as the push for this wait describes it (and AgentNotice(info:)).
                    tool: agent.pendingRequests.first?.tool ?? agent.tool,
                    toolInput: agent.pendingRequests.first.map { $0.summary } ?? agent.toolInput,
                    fallback: agent.prompt ?? place.tab, summary: agent.summary, needsUser: agent.needsUser,
                    plainText: agent.isOscSourced)
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
        guard let machine = (info["machine"] as? String).flatMap(UUID.init(uuidString:)),
              let pane = (info["pane"] as? NSNumber)?.uint64Value else { return completionHandler() }
        let request = info["request"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let kind: AlertAction.Kind?
        switch response.actionIdentifier {
        case AlertActions.allow: kind = .allow
        case AlertActions.deny: kind = .deny(reason: nil)
        case AlertActions.denyWithReason: kind = .deny(reason: text)
        case AlertActions.reply: kind = .reply(text ?? "")
        default: kind = nil
        }
        guard let kind else {
            Task { @MainActor in self.onOpen?(machine, pane) }
            return completionHandler()
        }
        // Done only once the machine has the answer (or it couldn't be reached), within iOS's background time.
        let action = AlertAction(machine: machine, pane: pane, request: request, kind: kind)
        Task { @MainActor in
            if let onAction = self.onAction {
                await onAction(action)
                completionHandler()
            } else {
                self.pendingActions.append((action, completionHandler))
            }
        }
    }
}

/// A notification action to carry out on a machine.
struct AlertAction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case allow
        case deny(reason: String?)
        case reply(String)
    }

    var machine: UUID
    var pane: PaneID
    /// The permission request it answers (Allow, Deny).
    var request: String?
    var kind: Kind
}
