import AppKit
import ClothoKit
import UserNotifications

// Coding agents (Claude Code, Codex, …) on every machine: the sidebar's inbox, marks on
// workspaces and tabs, notifications when one needs the user, and the dock badge. Agent state comes from
// each daemon's pane `agent` field; every connected machine keeps an event subscription, which is cheap
// (no pane output flows for panes that aren't on screen).

/// One agent, wherever it runs.
struct AgentEntry {
    let machine: MachineKey
    let machineName: String
    let pane: PaneID
    let workspace: Workspace?
    let tab: Tab?
    let paneTitle: String?
    /// The tab's name as the tab bar shows it.
    let tabTitle: String?
    let info: AgentInfo
    /// The machine's daemon can type for us (`pane.keys`), so quick replies are offered.
    let canReply: Bool
    /// The machine's daemon can mute agents (`agent.mute`).
    var canMute = false

    /// Quick replies only when a coding agent itself (through its hooks) says it's waiting for the user.
    /// Detected or idle agents aren't asking anything, and a script's report or a program's terminal
    /// notification (`source: "osc"`) has nobody to answer.
    var offersReplies: Bool { canReply && info.state == .waiting && info.needsAttention && info.acceptsReplies }

    /// Needing the user first (waiting, then failed, then a finished turn that asks something, then one
    /// that only finished), then running, then the rest.
    var rank: Int { info.urgency }

    /// Most urgent first, and the most recent change first within a rank.
    static func sorted(_ entries: [AgentEntry]) -> [AgentEntry] {
        entries.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return ($0.info.since ?? 0) > ($1.info.since ?? 0)
        }
    }

    var place: String {
        [workspace?.name, tabTitle].compactMap { $0 }.joined(separator: " › ")
    }
}

extension AgentInfo.State {
    var color: NSColor {
        switch self {
        case .waiting: return Theme.caution
        case .running: return Theme.accent
        case .starting, .unknown: return Theme.dimText
        case .done: return Theme.success
        case .error: return Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "hand.raised.fill"
        case .running: return "circle.dashed"
        case .starting: return "hourglass"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .waiting: return "Waiting for you"
        case .running: return "Running"
        case .starting: return "Starting"
        case .done: return "Done"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }
}

extension AgentInfo {
    /// The kind's SF Symbol as an image (ClothoKit's `AgentKind` table), for a chip, a row or a card. The
    /// name is always one of the table's literals; should the system not have it, the generic one.
    func kindImage(pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let image = NSImage(systemSymbolName: kindSymbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: AgentKind.genericSymbol, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

    /// The agent's last message for a sheet or a window: Markdown made plain, except an osc agent's, which
    /// is a program's output and stays as it was sent (no Markdown, no links).
    var plainMessage: String? {
        let text = message.map { isOscSourced ? AgentNotice.plainLine($0) : PlainText.fromMarkdown($0) }
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A finished turn that asks the user something (clothod 0.1.31's `needs_user`), not yet seen: it
    /// reads "Needs you", where a turn that only finished reads "Done".
    var asksUser: Bool { state == .done && needsUser == true && needsAttention }

    /// The state as shown: a quiet "waiting" reads as idle, and a finished turn that asks something as
    /// "Needs you", with the waiting hand, so the icon alone tells it from a plain Done. A settling agent
    /// shows as done.
    var shownState: (symbol: String, color: NSColor, label: String) {
        if isQuiet { return ("moon.zzz", Theme.dimText, "Idle") }
        if asksUser { return (State.waiting.symbol, State.waiting.color, AgentStatusGroup.needsYou.title) }
        return (state.symbol, state.color, state.label)
    }

    /// How much the agent wants the user, most urgent lowest: waiting, failed, a finished turn that asks
    /// something, a turn that only finished; then, with no attention, running and the rest.
    var urgency: Int {
        if needsAttention {
            switch state {
            case .waiting: return 0
            case .error: return 1
            default: return asksUser ? 2 : 3
            }
        }
        switch state {
        case .running, .starting: return 4
        default: return 5
        }
    }

    /// Which of the Agents menu's switches a notification about this agent follows: a finished turn that
    /// asks something goes with "Notify When Waiting for You", any other by its state.
    var notifySwitch: State { state == .done && needsUser == true ? .waiting : state }
}

extension AppDelegate {
    // MARK: Collecting

    /// Whether a machine's agents show in the sidebar's inbox, notify and count toward the dock badge.
    func monitorsAgents(_ key: MachineKey) -> Bool {
        UserDefaults.standard.object(forKey: "MonitorAgents.\(key)") as? Bool ?? true
    }

    func setMonitorsAgents(_ key: MachineKey, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "MonitorAgents.\(key)")
        sync()
    }

    /// Every agent on every monitored machine, most urgent first. With `monitoredOnly` false, on every
    /// connected machine: the Overview shows them all, whatever the machine's "monitor agents" switch says.
    func agentEntries(monitoredOnly: Bool = true) -> [AgentEntry] {
        var entries: [AgentEntry] = []
        for (key, session) in connections where !monitoredOnly || monitorsAgents(key) {
            let state = session.store.state
            for pane in state.panes where pane.exited == nil {
                guard let info = pane.agent else { continue }
                let location = state.location(of: pane.id)
                entries.append(AgentEntry(machine: key, machineName: session.title, pane: pane.id, workspace: location?.workspace,
                                          tab: location?.tab, paneTitle: pane.displayTitle,
                                          tabTitle: location.map { session.store.displayTitle(of: $0.tab) }, info: info,
                                          canReply: session.store.hello?.features.contains(.paneKeys) == true,
                                          canMute: session.store.hello?.features.contains(.agentMute) == true))
            }
        }
        return AgentEntry.sorted(entries)
    }

    // MARK: Opening

    /// Shows the agent's pane (its machine, workspace, tab and pane). Looking doesn't resolve it: the
    /// checkmark does, or typing into the pane (the daemon clears attention on input).
    ///
    /// Every way here is the user asking (an inbox row, its menu, the command bar, a notification), so the
    /// focus that follows is theirs: the pane gets its `pane.focus`, which also drops a held phone push. A
    /// notification click has to say so itself: it reaches the app with no key or mouse event, and with
    /// Clotho already in front nothing comes forward either.
    func openAgent(machine: MachineKey, pane: PaneID) {
        guard connections[machine] != nil else { return }
        // The pane comes into view: not under the Overview (a notification click, the command bar).
        uncoverWindow()
        UserAction.acted()
        if Self.openingAgentBringsAppForward {
            if NSApp.isHidden || !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        }
        focusNow(.pane(pane), on: machine, trace: "agent \(pane)")
        // The pane already had the keyboard, taken quietly: nothing changes above, and it's owed its focus.
        paneFocusReporter?.userActed()
    }

    /// Tests turn this off: a test run must not come in front of what's on the screen.
    static var openingAgentBringsAppForward = true

    /// Whether the machine's clothod can mute agents.
    func canMute(_ machine: MachineKey) -> Bool {
        connections[machine]?.store.hello?.features.contains(.agentMute) == true
    }

    /// Mute (bell.slash) or Unmute: in the daemon, so on every device. A muted agent stays in Quiet,
    /// never notifies and never counts in the dock badge, until unmuted or its session ends.
    func muteAgent(machine: MachineKey, pane: PaneID, muted: Bool) {
        guard let backend = connections[machine]?.store.backend else { return }
        log("agent \(machine)/\(pane): \(muted ? "muted" : "unmuted")")
        Task { @MainActor in
            do { try await backend.muteAgent(pane, muted: muted) } catch { log("muting \(machine)/\(pane) failed: \(error.localizedDescription)") }
        }
    }

    /// The checkmark: clears the agent's attention in its daemon (`agent.ack`), so it's resolved on every
    /// device. It comes back on its own when the agent needs the user again.
    func resolveAgent(machine: MachineKey, pane: PaneID) {
        guard let backend = connections[machine]?.store.backend else { return }
        log("agent \(machine)/\(pane): resolved")
        Task { @MainActor in
            do { try await backend.ackAgent(pane) } catch { log("resolving \(machine)/\(pane) failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Quick replies

    /// Answers an agent without switching to its pane: `text` (pasted) and then `keys`, encoded by the
    /// machine's daemon for the agent's terminal modes (`pane.keys`). It doesn't resolve the agent: the
    /// answer sets it running, which clears its attention in the daemon. Only the checkmark and Resolve
    /// acknowledge (resolveAgent); viewing never does.
    func reply(machine: MachineKey, pane: PaneID, text: String? = nil, keys: [String]) {
        guard let session = connections[machine], session.store.hello?.features.contains(.paneKeys) == true else {
            return log("reply to \(machine)/\(pane): this clothod can't send keys")
        }
        let backend = session.store.backend
        log("reply to \(machine)/\(pane): \(text.map { "text (\($0.count) chars) + " } ?? "")\(keys)")
        Task { @MainActor in
            do {
                try await backend.sendKeys(pane, text: text, keys: keys)
            } catch {
                log("reply to \(machine)/\(pane) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Answers one permission request (`agent.decide`). Already answered (in the terminal, or by another
    /// device) is fine: it's said in the log, never retried.
    func decide(machine: MachineKey, pane: PaneID, request: String, _ decision: PermissionDecision) {
        guard let backend = connections[machine]?.store.backend else { return }
        log("decide \(machine)/\(pane) request \(request): \(decision.rawValue)")
        Task { @MainActor in
            do {
                try await backend.decide(pane: pane, request: request, decision: decision, message: nil)
            } catch let error as BackendError where error.isStale {
                log("decide \(machine)/\(pane) request \(request): already answered")
            } catch {
                log("decide \(machine)/\(pane) request \(request) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Asks for a line of text and sends it with Enter.
    func promptReply(machine: MachineKey, pane: PaneID) {
        guard window.attachedSheet == nil, let session = connections[machine], let agent = session.store.state.pane(pane)?.agent else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Reply to \(agent.kindName) on \(session.title)"
        alert.informativeText = agent.plainMessage ?? "Sends your text, then Enter."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: s(24)))
        field.placeholderString = "Your reply"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let text = field.stringValue
            guard response == .alertFirstButtonReturn, !text.isEmpty else { return }
            self?.reply(machine: machine, pane: pane, text: text, keys: ["enter"])
        }
    }

    /// The quick replies, for an agent row's buttons and menu: (title, keys). "Reply…" asks for text.
    static let quickReplies: [(title: String, help: String, keys: [String])] = [
        ("1", "Press 1 (usually Yes)", ["1"]),
        ("2", "Press 2", ["2"]),
        ("3", "Press 3", ["3"]),
        ("↩", "Press Return", ["enter"]),
        ("Esc", "Press Esc (cancel or deny)", ["escape"]),
    ]

    /// The right-click menu on an agent row.
    func agentMenu(machine: MachineKey, pane: PaneID, canReply: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open Pane") { [weak self] in self?.openAgent(machine: machine, pane: pane) })
        let agent = connections[machine]?.store.state.pane(pane)?.agent
        if agent?.needsAttention == true {
            menu.addItem(ClosureMenuItem(title: "Resolve") { [weak self] in self?.resolveAgent(machine: machine, pane: pane) })
        }
        if let agent, canMute(machine) {
            let muted = agent.isMuted
            menu.addItem(ClosureMenuItem(title: muted ? "Unmute" : "Mute") { [weak self] in
                self?.muteAgent(machine: machine, pane: pane, muted: !muted)
            })
        }
        if connections[machine]?.store.hello?.features.contains(.agentHistory) == true {
            menu.addItem(ClosureMenuItem(title: "History…") { [weak self] in self?.showAgentHistory(machine: machine, pane: pane) })
        }
        // Permission requests the daemon can answer, oldest first.
        if connections[machine]?.store.features.contains(.agentDecide) == true, let requests = agent?.pendingRequests, !requests.isEmpty {
            menu.addItem(.separator())
            for request in requests {
                menu.addItem(ClosureMenuItem(title: String(request.question.dropLast())) { [weak self] in
                    self?.decide(machine: machine, pane: pane, request: request.id, .allow)
                })
                menu.addItem(ClosureMenuItem(title: "Deny \(request.tool)") { [weak self] in
                    self?.decide(machine: machine, pane: pane, request: request.id, .deny)
                })
            }
        }
        // Replies go to a coding agent that reports through its hooks: a script's report or a program's
        // terminal notification has nobody to answer.
        guard canReply, agent?.acceptsReplies != false else { return menu }
        menu.addItem(.separator())
        for reply in Self.quickReplies {
            menu.addItem(ClosureMenuItem(title: reply.help) { [weak self] in self?.reply(machine: machine, pane: pane, keys: reply.keys) })
        }
        menu.addItem(ClosureMenuItem(title: "Reply…") { [weak self] in self?.promptReply(machine: machine, pane: pane) })
        return menu
    }

    // MARK: Transitions, notifications and the dock badge

    func agentChanged(machine: MachineKey, pane: PaneID, from before: AgentInfo?, to after: AgentInfo?) {
        agentHistoryWindows[PaneKey(machine: machine, pane: pane)]?.refresh()
        // The inspector's Activity, when it shows this pane's agent.
        fileSidebar?.activityView.agentChanged(machine: machine, pane: pane)
        log("agent \(machine)/\(pane): \(before?.state.rawValue ?? "none") → \(after.map { "\($0.kind) \($0.state.rawValue) (\($0.source ?? "?"))\($0.message.map { ": " + $0 } ?? "")" } ?? "none")")
        if let after, Self.showsHooksAreSetUp(after) { hookSourcedMachines.insert(machine) }
        // A notification held for its summary goes out once the summary lands (or the agent moved on).
        let paneKey = PaneKey(machine: machine, pane: pane)
        summaryHold.agentChanged(paneKey, to: after)
        // Only when the daemon raises attention (a hook-reported waiting, done or error, or a bell): quiet
        // output alone never alerts. A quiet rise (a turn that ended while the user was at the pane) is
        // badged but not announced.
        guard let after, monitorsAgents(machine), after.notifiesRise(from: before) else {
            if let after, after.isQuietRise, after.needsAttention, before?.needsAttention != true {
                log("agent \(machine)/\(pane): quiet rise, no notification")
            }
            return
        }
        // Not for the pane the user is looking at.
        if NSApp.isActive, window.isKeyWindow, machine == focusedMachine, store.focusedPane?.id == pane { return }
        // Detection can flicker (waiting → running → waiting), so one notification per pane and state a minute.
        let key = "\(machine)/\(pane)"
        if Self.throttlesNotice(after, last: lastAgentNotification[key], now: Date()) { return }
        lastAgentNotification[key] = (after.state, Date())
        // The daemon is rewriting the message (clothod 0.1.29): wait for it, as the phone's push does, up
        // to `summaryWait`, then go with whatever summary there is. Never twice. Whether it reads "needs
        // you" or "is done" may change with the summary, so the switches are asked when it goes out.
        if after.isSummaryPending {
            summaryHold.hold(paneKey, state: after.state)
            return
        }
        postAgentNotice(machine: machine, pane: pane, info: after)
    }

    /// Whether a rise is too soon after the last notification for its pane. Only for detected agents,
    /// whose state can flicker: one per pane and state a minute. An agent that reports through hooks rose
    /// for a real turn each time (clothod settles a done before raising it), so a second Done within the
    /// minute is announced; and a program's terminal notification (`source: "osc"`) is one the program
    /// sent each time, which clothod already limits.
    nonisolated static func throttlesNotice(_ after: AgentInfo, last: (state: AgentInfo.State, date: Date)?, now: Date) -> Bool {
        guard after.isDetected, let last else { return false }
        return last.state == after.state && now.timeIntervalSince(last.date) < 60
    }

    /// Whether seeing this agent says the machine's agent hooks are set up: a coding agent that reports
    /// through them. A script's `clothod report --kind deploy` is hook-sourced too, and says nothing of it.
    nonisolated static func showsHooksAreSetUp(_ agent: AgentInfo) -> Bool {
        agent.isHookSourced && AgentKind.of(agent.kind).isCodingAgent
    }

    /// The notification category (its buttons) for an agent: Allow / Deny for a permission request the
    /// daemon can answer; else, when the daemon can type for us, Approve / Deny / Reply for a waiting
    /// coding agent and Reply for a finished one. None for a program's terminal notification or a
    /// script's report: there is nobody to answer.
    nonisolated static func noticeCategory(for agent: AgentInfo, canReply: Bool, hasRequest: Bool) -> String? {
        if hasRequest { return permissionCategory }
        guard canReply, !agent.isOscSourced, AgentKind.of(agent.kind).isCodingAgent else { return nil }
        return agent.state == .waiting ? waitingCategory : finishedCategory
    }

    func postAgentNotice(machine: MachineKey, pane: PaneID, info after: AgentInfo) {
        guard let session = connections[machine] else { return }
        guard notifies(after) else { return log("agent \(machine)/\(pane): notifications for \(after.notifySwitch.rawValue) are off") }
        let location = session.store.state.location(of: pane)
        // "Needs you · Platform › cargo test" / "devbox · api-server · 4m" / the result: the same shape as on
        // iOS. An older daemon (no `needs_user`) keeps "Platform · Claude finished".
        let notice = AgentNotice(info: after, machine: session.title, workspace: location?.workspace.name,
                                 cwd: session.store.state.pane(pane)?.cwd,
                                 tab: location.map { session.store.displayTitle(of: $0.tab) })
        // Answerable from the notification when the daemon can type for us.
        let canReply = session.store.hello?.features.contains(.paneKeys) == true
        // A permission request the daemon can answer: Allow and Deny for that request.
        let request = session.store.features.contains(.agentDecide) && after.state == .waiting ? after.pendingRequests.first : nil
        let category = Self.noticeCategory(for: after, canReply: canReply, hasRequest: request != nil)
        // A plain Done makes no sound (clothod 0.1.31's `needs_user`); anything that needs the user does.
        postNotification(notice, machine: machine, pane: pane, category: category, request: request?.id, sound: after.playsSound)
    }

    /// Mutable per state in the Agents menu; all on by default.
    func notifies(_ state: AgentInfo.State) -> Bool {
        UserDefaults.standard.object(forKey: "NotifyAgent.\(state.rawValue)") as? Bool ?? true
    }

    /// Whether the switches let a notification about this agent out (see `notifySwitch`).
    func notifies(_ agent: AgentInfo) -> Bool { notifies(agent.notifySwitch) }

    /// Notification switches, for the Agents menu and the sidebar's inbox headers.
    func agentsNotificationMenu() -> NSMenu {
        let menu = NSMenu(title: "Agents")
        fillAgentsMenu(menu)
        return menu
    }

    func fillAgentsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (state, title) in [(AgentInfo.State.waiting, "Notify When Waiting for You"), (.done, "Notify When Done"), (.error, "Notify on Errors")] {
            let item = ClosureMenuItem(title: title) { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(!notifies(state), forKey: "NotifyAgent.\(state.rawValue)")
            }
            item.state = notifies(state) ? .on : .off
            menu.addItem(item)
        }
    }

    /// Adds the Agents menu to the menu bar, before Window.
    func installAgentsMenu() {
        guard let main = NSApp.mainMenu else { return }
        let menu = NSMenu(title: "Agents")
        menu.delegate = agentsMenuDelegate
        agentsMenuDelegate.fill = { [weak self] menu in self?.fillAgentsMenu(menu) }
        let item = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        item.submenu = menu
        let index = main.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? main.items.count
        main.insertItem(item, at: index)
    }

    nonisolated static let waitingCategory = "agent.waiting"
    /// A permission request the daemon can answer for us (`agent.decide`): Allow and Deny go to that
    /// request alone, whatever the terminal shows by then.
    nonisolated static let permissionCategory = "agent.permission"
    nonisolated static let finishedCategory = "agent.finished"

    /// Approve (1), Deny (Esc) and a typed Reply for a waiting agent; a typed Reply for a finished one.
    static func notificationCategories() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: "approve", title: "Approve (1)")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny (Esc)", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Your reply")
        return [
            UNNotificationCategory(identifier: waitingCategory, actions: [approve, deny, reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: permissionCategory, actions: [
                UNNotificationAction(identifier: "allow", title: "Allow"),
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: finishedCategory, actions: [reply], intentIdentifiers: []),
        ]
    }

    private func postNotification(_ notice: AgentNotice, machine: MachineKey, pane: PaneID, category: String? = nil, request: String? = nil,
                                  sound: Bool = true) {
        // AgentNotifications=NO (for test runs) logs instead, so no permission prompt appears. bool(forKey:)
        // reads a launch argument's "NO" too.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "AgentNotifications") == nil || defaults.bool(forKey: "AgentNotifications") else {
            return log("agent notification: \(notice.title) | \(notice.subtitle) | \(notice.body)\(category.map { " [\($0)]" } ?? "")\(request.map { " request \($0)" } ?? "")\(sound ? "" : " [silent]")")
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.subtitle = notice.subtitle
            content.body = notice.body
            content.sound = sound ? .default : nil
            var userInfo: [String: Any] = ["machine": machine, "pane": NSNumber(value: pane)]
            if let request { userInfo["request"] = request }
            content.userInfo = userInfo
            if let category { content.categoryIdentifier = category }
            // One notification per pane: a newer state replaces the older one.
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent.\(machine).\(pane)", content: content, trigger: nil))
        }
    }

    /// The dock shows how many agents need the user.
    func updateDockBadge(_ entries: [AgentEntry]) {
        let count = entries.filter(\.info.needsAttention).count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    func setUpAgentNotifications() {
        // UNUserNotificationCenter needs an app bundle (a test process runs in xctest, which isn't one).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return log("notifications: off (not an app bundle)") }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().setNotificationCategories(Self.notificationCategories())
        notificationDelegate.onOpen = { [weak self] machine, pane in self?.openAgent(machine: machine, pane: pane) }
        notificationDelegate.onAction = { [weak self] machine, pane, action, text, request in
            switch action {
            case "allow" where request != nil: self?.decide(machine: machine, pane: pane, request: request!, .allow)
            case "deny" where request != nil: self?.decide(machine: machine, pane: pane, request: request!, .deny)
            case "approve": self?.reply(machine: machine, pane: pane, keys: ["1"])
            case "deny": self?.reply(machine: machine, pane: pane, keys: ["escape"])
            case "reply" where !(text ?? "").isEmpty: self?.reply(machine: machine, pane: pane, text: text, keys: ["enter"])
            default: break
            }
        }
        // Elapsed times in the inbox and the pane headers stay current.
        agentClock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }
}

/// Rebuilds the Agents menu each time it opens, so its checkmarks are current.
final class AgentsMenuDelegate: NSObject, NSMenuDelegate {
    var fill: ((NSMenu) -> Void)?
    func menuNeedsUpdate(_ menu: NSMenu) { fill?(menu) }
}

/// Opens the agent's pane when its notification is clicked, and shows notifications while Clotho is
/// in front too (unless it's the pane being looked at, which never gets one).
final class AgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((MachineKey, PaneID) -> Void)?
    /// A notification button: the action id ("approve", "deny", "reply") and any typed text.
    /// The request is the permission request the notification was about, if any.
    var onAction: ((MachineKey, PaneID, String, String?, String?) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let machine = info["machine"] as? String, let pane = (info["pane"] as? NSNumber)?.uint64Value {
            let action = response.actionIdentifier
            let text = (response as? UNTextInputNotificationResponse)?.userText
            let request = info["request"] as? String
            DispatchQueue.main.async {
                if action == UNNotificationDefaultActionIdentifier {
                    self.onOpen?(machine, pane)
                } else if action != UNNotificationDismissActionIdentifier {
                    // Answered from the notification: the pane stays where it is.
                    self.onAction?(machine, pane, action, text, request)
                }
            }
        }
        completionHandler()
    }
}

/// An agent in the sidebar's inbox, on one line: its mark, where it is ("workspace › tab") and what it asks
/// or last said, which takes the rest of the row and truncates. The machine, the kind of agent, its state
/// and the full text are in the tooltip and the accessibility label. Nothing else is in the row: Mute and
/// Resolve float over its trailing end under the pointer.
final class AgentRow: ChromeItem {
    static var height: CGFloat { s(26) }
    /// How much of the row the title may take, from the row's leading edge, so the text after it always shows.
    static let titleShare: CGFloat = 0.6
    static let fade: TimeInterval = 0.12

    let mark: AgentMarkView
    /// What the agent asks or last said (hidden when it said nothing).
    let summary = NSTextField(labelWithString: "")
    /// The Resolve checkmark and, left of it, Mute (bell.slash): always in place, shown only under the pointer.
    private(set) var resolve: ClosureButton?
    private(set) var mute: ClosureButton?
    /// Mute and Resolve on their backing, floating over the row's trailing end on hover.
    private(set) var actions: ActionsOverlay?
    /// The kind's symbol, small and dim at the row's trailing end (under the hover actions). Decorative:
    /// the kind's name is in the tooltip and the accessibility label.
    let kindGlyph = NSImageView()
    /// The pane's progress, along the row's bottom edge from the title's inset. Hidden with none.
    let progressBar = ProgressBarView()
    static var glyphSlot: CGFloat { s(16) }
    /// The narrowest row that shows the glyph: in a narrower sidebar its room goes to the title and the
    /// text, which matter more.
    static var glyphLeastRow: CGFloat { s(180) }
    private var glyphWidth: NSLayoutConstraint!
    private var glyphGaps: [NSLayoutConstraint] = []

    /// "Needs you: Claude Code, clotho › alerts on devbox. Allow Bash: cargo test".
    static func description(_ entry: AgentEntry) -> String {
        let info = entry.info
        var text = "\(info.mark?.label ?? info.shownState.label): \(info.kindName)"
        if !entry.place.isEmpty { text += ", \(entry.place)" }
        text += " on \(entry.machineName)"
        if let said = info.inboxText, !said.isEmpty { text += ". \(said)" }
        return text
    }

    /// With `onResolve` (and `onMute`), the row has the hover-only Resolve (and Mute) buttons: agents that
    /// need the user or finished. A working agent's row has none.
    init(_ entry: AgentEntry, onResolve: (() -> Void)? = nil, onMute: (() -> Void)? = nil) {
        mark = AgentMarkView(entry.info.mark ?? .working)
        super.init(closable: false)
        colorsOwnTitle = true
        label.stringValue = entry.place.isEmpty ? (entry.paneTitle ?? entry.info.kindName) : entry.place
        label.font = NSFont.systemFont(ofSize: s(12))
        label.textColor = Theme.foreground
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Above the summary's, so the summary gives way first; the cap below keeps it from being squeezed out.
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        let said = entry.info.inboxText ?? ""
        summary.stringValue = said
        summary.isHidden = said.isEmpty
        summary.font = NSFont.systemFont(ofSize: s(12))
        summary.textColor = Theme.dimText
        summary.lineBreakMode = .byTruncatingTail
        summary.maximumNumberOfLines = 1
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = Self.description(entry)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.description(entry))
        kindGlyph.image = entry.info.kindImage(pointSize: s(10))
        kindGlyph.contentTintColor = Theme.dimText
        kindGlyph.imageScaling = .scaleProportionallyDown
        kindGlyph.setAccessibilityElement(false)
        for view in [mark, summary, kindGlyph, progressBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The mark sits in the chevron's column and the title starts where workspace names do.
        let inset = MachineHeader.nameInset
        constraints.filter { $0.firstItem === label && $0.firstAttribute == .leading }.forEach { $0.constant = inset }
        glyphWidth = kindGlyph.widthAnchor.constraint(equalToConstant: Self.glyphSlot)
        // The text ends before the glyph; with no summary the title does too.
        glyphGaps = [summary.trailingAnchor.constraint(equalTo: kindGlyph.leadingAnchor, constant: s(-4)),
                     label.trailingAnchor.constraint(lessThanOrEqualTo: kindGlyph.leadingAnchor, constant: s(-4))]
        NSLayoutConstraint.activate(glyphGaps)
        // Below required: a row with no width yet gives the bar up, and breaks nothing.
        let barTrailing = progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-8))
        barTrailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: leadingAnchor, constant: s(10) + DisclosureChevron.size / 2),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: s(6)),
            summary.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            kindGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-8)),
            kindGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphWidth,
            kindGlyph.heightAnchor.constraint(equalToConstant: Self.glyphSlot),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            barTrailing,
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: s(-1)),
            progressBar.heightAnchor.constraint(equalToConstant: ProgressBarView.height),
        ])
        if !said.isEmpty {
            // The title ends within its share of the row.
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: Self.titleShare, constant: -inset).isActive = true
        }

        // Hover actions (Mute, then Resolve, right-aligned) float over the trailing end of the row, on a
        // backing in the hover colour that fades in from its leading edge, so the text underneath is
        // covered rather than pushed aside.
        let makeButton = { (symbol: String, name: String, tip: String, action: @escaping () -> Void) -> ClosureButton in
            let button = ClosureButton(title: "", action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: s(13), weight: .regular))
            button.isBordered = false
            button.contentTintColor = Theme.dimText
            button.toolTip = tip
            button.setAccessibilityLabel(name)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: s(20)).isActive = true
            button.heightAnchor.constraint(equalToConstant: s(20)).isActive = true
            return button
        }
        if let onMute { mute = makeButton("bell.slash", "Mute", "Mute: don't bring this agent back until unmuted", onMute) }
        if let onResolve {
            resolve = makeButton("checkmark.circle", "Resolve", "Resolve: hide it until it needs you again (on every device)", onResolve)
        }
        let buttons = [mute, resolve].compactMap { $0 }
        if !buttons.isEmpty {
            let overlay = ActionsOverlay(buttons: buttons)
            overlay.alphaValue = 0
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-2)),
                overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            actions = overlay
            onHoverChanged = { [weak self] on in self?.showResolve(on, animated: true) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitGlyph()
    }

    /// The glyph only in a row wide enough for it beside the title and the text.
    private func fitGlyph() {
        guard let glyphWidth else { return }
        let shows = bounds.width >= Self.glyphLeastRow
        guard kindGlyph.isHidden == shows || glyphWidth.constant != (shows ? Self.glyphSlot : 0) else { return }
        kindGlyph.isHidden = !shows
        glyphWidth.constant = shows ? Self.glyphSlot : 0
        glyphGaps.forEach { $0.constant = shows ? s(-4) : 0 }
    }

    /// Fades the hover actions (Mute and Resolve, with their backing) in or out together. Hidden only by
    /// alpha: they keep their place and stay reachable to accessibility (the row's menu has both too).
    func showResolve(_ visible: Bool, animated: Bool) {
        guard let actions else { return }
        let alpha: CGFloat = visible ? 1 : 0
        guard animated, window != nil else { return actions.alphaValue = alpha }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            actions.animator().alphaValue = alpha
        }
    }
}


/// The hover actions on an agent row: buttons on a backing in the row's hover colour, whose leading edge
/// fades in over a few points so whatever it covers (the end of the row's text) disappears smoothly.
final class ActionsOverlay: NSView {
    static var fadeWidth: CGFloat { s(12) }
    private let fade = CAGradientLayer()

    init(buttons: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = s(2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let solid = NSView()
        solid.wantsLayer = true
        solid.layer?.backgroundColor = Theme.hover.cgColor
        solid.layer?.cornerRadius = s(4)
        solid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(solid)
        addSubview(stack)
        fade.colors = [Theme.hover.withAlphaComponent(0).cgColor, Theme.hover.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(fade)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: s(-2)),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: s(2)),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: s(-2)),
            solid.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: s(-2)),
            solid.trailingAnchor.constraint(equalTo: trailingAnchor),
            solid.topAnchor.constraint(equalTo: topAnchor),
            solid.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.fadeWidth + 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(x: 0, y: 0, width: Self.fadeWidth, height: bounds.height)
        CATransaction.commit()
    }
}

/// Agent notifications waiting for the daemon's summary (clothod 0.1.29): the rise comes with
/// `summary_pending`, and the rewrite follows in a `pane` event, usually in 1–3 s. A held notification
/// goes out once, when the summary lands or after `wait` (with whatever summary there is then), and
/// only if the agent still needs the user in the state it rose to.
@MainActor
final class SummaryHold {
    /// The agent as it is now, from the model.
    var current: (PaneKey) -> AgentInfo?
    var post: (PaneKey, AgentInfo) -> Void
    var dropped: (PaneKey) -> Void = { _ in }
    /// How long to wait (the push waits as long). The `SummaryWait` default overrides it, for tests.
    var wait: TimeInterval = {
        let override = UserDefaults.standard.double(forKey: "SummaryWait")
        return override > 0 ? override : 6
    }()

    private var held: [PaneKey: (state: AgentInfo.State, timer: DispatchWorkItem)] = [:]

    init(current: @escaping (PaneKey) -> AgentInfo?, post: @escaping (PaneKey, AgentInfo) -> Void) {
        self.current = current
        self.post = post
    }

    var isHolding: Bool { !held.isEmpty }
    func isHolding(_ key: PaneKey) -> Bool { held[key] != nil }

    func hold(_ key: PaneKey, state: AgentInfo.State) {
        held[key]?.timer.cancel()
        let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.release(key) } }
        held[key] = (state, timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: timer)
    }

    /// The pane's agent changed: a held notification goes out once its summary is no longer pending.
    func agentChanged(_ key: PaneKey, to info: AgentInfo?) {
        guard held[key] != nil, info?.isSummaryPending != true else { return }
        release(key)
    }

    /// Posts the held notification now, with the agent as it is (or drops it if the agent moved on).
    func release(_ key: PaneKey) {
        guard let entry = held.removeValue(forKey: key) else { return }
        entry.timer.cancel()
        guard let info = current(key), info.needsAttention, info.state == entry.state else { return dropped(key) }
        post(key, info)
    }
}
