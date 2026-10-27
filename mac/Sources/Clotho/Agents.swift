import AppKit
import ClothoKit
import UserNotifications

// Coding agents (Claude Code, Codex, …) on every machine: the sidebar's Agents section, badges on
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

    /// Quick replies only when the agent itself (through its hooks) says it's waiting for the user.
    /// Detected or idle agents aren't asking anything.
    var offersReplies: Bool { canReply && info.state == .waiting && info.needsAttention && info.isHookSourced }

    /// Needing the user first (waiting, then failed, then finished), then running, then the rest.
    var rank: Int {
        if info.needsAttention {
            switch info.state {
            case .waiting: return 0
            case .error: return 1
            default: return 2
            }
        }
        switch info.state {
        case .running, .starting: return 3
        default: return 4
        }
    }

    /// Most urgent first, and the most recent change first within a rank.
    static func sorted(_ entries: [AgentEntry]) -> [AgentEntry] {
        entries.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return ($0.info.since ?? 0) > ($1.info.since ?? 0)
        }
    }

    /// The Agents panel: agents whose `attention` the daemon raised (until resolved, on any device, or
    /// until someone types into the pane) at the top; every other agent in the section below.
    static func split(_ entries: [AgentEntry]) -> (attention: [AgentEntry], others: [AgentEntry]) {
        let sorted = sorted(entries)
        return (sorted.filter(\.info.needsAttention), sorted.filter { !$0.info.needsAttention })
    }

    var place: String {
        [workspace?.name, tabTitle].compactMap { $0 }.joined(separator: " › ")
    }
}

extension AgentInfo.State {
    var color: NSColor {
        switch self {
        case .waiting: return NSColor(hex: 0xE5A01A)
        case .running: return Theme.accent
        case .starting, .unknown: return Theme.dimText
        case .done: return NSColor(hex: 0x57C78A)
        case .error: return NSColor(hex: 0xC76156)
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
    var kindName: String {
        switch kind.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    /// The color a badge shows for this agent, or nil when it needs no badge.
    var badgeColor: NSColor? {
        needsAttention ? state.color : (state == .running || state == .starting ? Theme.accent : nil)
    }

    /// The state as shown: a quiet "waiting" reads as idle.
    var shownState: (symbol: String, color: NSColor, label: String) {
        isQuiet ? ("moon.zzz", Theme.dimText, "Idle") : (state.symbol, state.color, state.label)
    }
}

extension AppDelegate {
    // MARK: Collecting

    /// Whether a machine's agents show in the Agents section, notify and count toward the dock badge.
    func monitorsAgents(_ key: MachineKey) -> Bool {
        UserDefaults.standard.object(forKey: "MonitorAgents.\(key)") as? Bool ?? true
    }

    func setMonitorsAgents(_ key: MachineKey, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "MonitorAgents.\(key)")
        sync()
    }

    /// Every agent on every monitored machine, most urgent first.
    func agentEntries() -> [AgentEntry] {
        var entries: [AgentEntry] = []
        for (key, session) in connections where monitorsAgents(key) {
            let state = session.store.state
            for pane in state.panes where pane.exited == nil {
                guard let info = pane.agent else { continue }
                let location = state.location(of: pane.id)
                entries.append(AgentEntry(machine: key, machineName: session.title, pane: pane.id, workspace: location?.workspace,
                                          tab: location?.tab, paneTitle: pane.displayTitle,
                                          tabTitle: location.map { session.store.displayTitle(of: $0.tab) }, info: info,
                                          canReply: session.store.hello?.features.contains(.paneKeys) == true))
            }
        }
        return AgentEntry.sorted(entries)
    }

    /// Monitored machines that can't be reached, so their agents aren't silently missing.
    func unreachableMonitoredMachines() -> [(name: String, reason: String)] {
        connections.values.filter { monitorsAgents($0.key) }.compactMap { session in
            if case .reconnecting(let reason) = session.store.connection { return (session.title, reason) }
            return nil
        }.sorted { $0.name < $1.name }
    }

    /// The most urgent agent badge for a workspace or tab on a machine.
    func agentBadge(machine: MachineKey, panes: [PaneID]) -> NSColor? {
        guard monitorsAgents(machine), let state = connections[machine]?.store.state else { return nil }
        let agents = panes.compactMap { state.pane($0)?.agent }
        let urgent = agents.filter(\.needsAttention).min { rank($0) < rank($1) }
        return (urgent ?? agents.first { $0.badgeColor != nil })?.badgeColor
    }

    private func rank(_ info: AgentInfo) -> Int { info.state == .waiting ? 0 : info.state == .error ? 1 : 2 }

    // MARK: Opening

    /// Shows the agent's pane (its machine, workspace, tab and pane). Looking doesn't resolve it: the
    /// checkmark does, or typing into the pane (the daemon clears attention on input).
    func openAgent(machine: MachineKey, pane: PaneID) {
        guard let session = connections[machine] else { return }
        focus(machine: machine)
        if NSApp.isHidden || !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        let backend = session.store.backend
        Task { @MainActor in try? await backend.focus(.pane(pane)) }
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
    /// machine's daemon for the agent's terminal modes (`pane.keys`). Answering also marks it seen.
    func reply(machine: MachineKey, pane: PaneID, text: String? = nil, keys: [String]) {
        guard let session = connections[machine], session.store.hello?.features.contains(.paneKeys) == true else {
            return log("reply to \(machine)/\(pane): this clothod can't send keys")
        }
        let backend = session.store.backend
        log("reply to \(machine)/\(pane): \(text.map { "text (\($0.count) chars) + " } ?? "")\(keys)")
        Task { @MainActor in
            do {
                try await backend.sendKeys(pane, text: text, keys: keys)
                try await backend.ackAgent(pane)
            } catch {
                log("reply to \(machine)/\(pane) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Asks for a line of text and sends it with Enter.
    func promptReply(machine: MachineKey, pane: PaneID) {
        guard window.attachedSheet == nil, let session = connections[machine], let agent = session.store.state.pane(pane)?.agent else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Reply to \(agent.kindName) on \(session.title)"
        alert.informativeText = agent.message ?? "Sends your text, then Enter."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
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
        if connections[machine]?.store.state.pane(pane)?.agent?.needsAttention == true {
            menu.addItem(ClosureMenuItem(title: "Resolve") { [weak self] in self?.resolveAgent(machine: machine, pane: pane) })
        }
        guard canReply else { return menu }
        menu.addItem(.separator())
        for reply in Self.quickReplies {
            menu.addItem(ClosureMenuItem(title: reply.help) { [weak self] in self?.reply(machine: machine, pane: pane, keys: reply.keys) })
        }
        menu.addItem(ClosureMenuItem(title: "Reply…") { [weak self] in self?.promptReply(machine: machine, pane: pane) })
        return menu
    }

    // MARK: Transitions, notifications and the dock badge

    func agentChanged(machine: MachineKey, pane: PaneID, from before: AgentInfo?, to after: AgentInfo?) {
        log("agent \(machine)/\(pane): \(before?.state.rawValue ?? "none") → \(after.map { "\($0.kind) \($0.state.rawValue) (\($0.source ?? "?"))\($0.message.map { ": " + $0 } ?? "")" } ?? "none")")
        if after?.isHookSourced == true { hookSourcedMachines.insert(machine) }
        // Only when the daemon raises attention (a hook-reported waiting, done or error, or a bell): quiet
        // output alone never alerts.
        guard let after, monitorsAgents(machine), after.needsAttention, before?.needsAttention != true,
              [.waiting, .done, .error].contains(after.state), notifies(after.state) else { return }
        // Not for the pane the user is looking at.
        if NSApp.isActive, window.isKeyWindow, machine == focusedMachine, store.focusedPane?.id == pane { return }
        // Detection can flicker (waiting → running → waiting), so one notification per pane and state a minute.
        let key = "\(machine)/\(pane)"
        if let last = lastAgentNotification[key], last.state == after.state, Date().timeIntervalSince(last.date) < 60 { return }
        lastAgentNotification[key] = (after.state, Date())
        guard let session = connections[machine] else { return }
        let location = session.store.state.location(of: pane)
        let title = "\(after.kindName) \(after.state == .waiting ? "is waiting" : after.state == .done ? "finished" : "hit an error")"
        // machine · workspace › tab, as in the Agents panel and on iOS.
        let inside = [location?.workspace.name, location.map { session.store.displayTitle(of: $0.tab) }].compactMap { $0 }
        let place = ([session.title] + (inside.isEmpty ? [] : [inside.joined(separator: " › ")])).joined(separator: " · ")
        // Answerable from the notification when the daemon can type for us.
        let canReply = session.store.hello?.features.contains(.paneKeys) == true
        let category = canReply ? (after.state == .waiting ? Self.waitingCategory : Self.finishedCategory) : nil
        postNotification(title: title, body: [place, after.message].compactMap { $0 }.joined(separator: "\n"),
                         machine: machine, pane: pane, category: category)
    }

    /// Mutable per state in the Agents menu; all on by default.
    func notifies(_ state: AgentInfo.State) -> Bool {
        UserDefaults.standard.object(forKey: "NotifyAgent.\(state.rawValue)") as? Bool ?? true
    }

    /// Notification switches, for the Agents menu and the sidebar's Agents header.
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

    static let waitingCategory = "agent.waiting"
    static let finishedCategory = "agent.finished"

    /// Approve (1), Deny (Esc) and a typed Reply for a waiting agent; a typed Reply for a finished one.
    static func notificationCategories() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: "approve", title: "Approve (1)")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny (Esc)", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Your reply")
        return [
            UNNotificationCategory(identifier: waitingCategory, actions: [approve, deny, reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: finishedCategory, actions: [reply], intentIdentifiers: []),
        ]
    }

    private func postNotification(title: String, body: String, machine: MachineKey, pane: PaneID, category: String? = nil) {
        // AgentNotifications=NO (for test runs) logs instead, so no permission prompt appears. bool(forKey:)
        // reads a launch argument's "NO" too.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "AgentNotifications") == nil || defaults.bool(forKey: "AgentNotifications") else {
            return log("agent notification: \(title) — \(body.replacingOccurrences(of: "\n", with: " · "))\(category.map { " [\($0)]" } ?? "")")
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["machine": machine, "pane": NSNumber(value: pane)]
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
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().setNotificationCategories(Self.notificationCategories())
        notificationDelegate.onOpen = { [weak self] machine, pane in self?.openAgent(machine: machine, pane: pane) }
        notificationDelegate.onAction = { [weak self] machine, pane, action, text in
            switch action {
            case "approve": self?.reply(machine: machine, pane: pane, keys: ["1"])
            case "deny": self?.reply(machine: machine, pane: pane, keys: ["escape"])
            case "reply" where !(text ?? "").isEmpty: self?.reply(machine: machine, pane: pane, text: text, keys: ["enter"])
            default: break
            }
        }
        // Elapsed times in the Agents section stay current.
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
    var onAction: ((MachineKey, PaneID, String, String?) -> Void)?

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
            DispatchQueue.main.async {
                if action == UNNotificationDefaultActionIdentifier {
                    self.onOpen?(machine, pane)
                } else if action != UNNotificationDismissActionIdentifier {
                    // Answered from the notification: the pane stays where it is.
                    self.onAction?(machine, pane, action, text)
                }
            }
        }
        completionHandler()
    }
}

/// An agent in the sidebar: state icon, kind and machine, where it is, what it says, and how long ago its
/// state changed.
final class AgentRow: ChromeItem {
    private let icon = NSImageView()
    private let detail = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    /// The Resolve checkmark: always in place (so nothing moves), shown only while the row is hovered.
    private(set) var resolve: ClosureButton?
    static let fade: TimeInterval = 0.12

    /// With `onResolve`, the row has a checkmark that resolves the agent (agents needing attention).
    init(_ entry: AgentEntry, onResolve: (() -> Void)? = nil) {
        super.init(closable: false)
        let info = entry.info
        let shown = info.shownState
        icon.image = NSImage(systemSymbolName: shown.symbol, accessibilityDescription: shown.label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = shown.color
        // Where it is: machine · workspace (bold) › tab, as on iOS.
        let strong = info.needsAttention ? Theme.foreground : NSColor(hex: 0xA9B0B6)
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.dimText]
        let title = NSMutableAttributedString(string: entry.machineName + " · ", attributes: quiet)
        title.append(NSAttributedString(string: entry.workspace?.name ?? "Workspace", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: strong,
        ]))
        if let tab = entry.tabTitle, !tab.isEmpty {
            title.append(NSAttributedString(string: " › " + tab, attributes: quiet))
        }
        colorsOwnTitle = true
        // Attributed text brings its own line breaking, so truncation is set on it as well.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        label.attributedStringValue = title
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = true
        // Hovering a cut-off title or detail shows all of it in place, as Finder does.
        label.allowsExpansionToolTips = true
        detail.allowsExpansionToolTips = true
        // Which agent, then what it says.
        detail.stringValue = [info.kind, info.message ?? (shown.label == "Idle" ? "idle" : nil)].compactMap { $0 }.joined(separator: " · ")
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = Theme.dimText
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        elapsed.stringValue = info.sinceDate.map(Self.elapsed) ?? ""
        elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsed.textColor = Theme.dimText
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = [
            title.string,
            "\(info.kindName) on \(entry.machineName): \(shown.label)",
            entry.place.isEmpty ? nil : entry.place,
            info.message,
            info.isHookSourced ? "Reported by \(info.kindName)'s hooks" : "Detected from the terminal",
        ].compactMap { $0 }.joined(separator: "\n")
        for view in [icon, detail, elapsed] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var trailing = trailingAnchor
        var inset: CGFloat = -10
        if let onResolve {
            let button = ClosureButton(title: "", action: onResolve)
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Resolve")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.isBordered = false
            button.contentTintColor = Theme.dimText
            button.toolTip = "Resolve: hide it until it needs you again (on every device)"
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
            resolve = button
            button.alphaValue = 0
            onHoverChanged = { [weak self] on in self?.showResolve(on, animated: true) }
            trailing = button.leadingAnchor
            inset = -4
        }
        // The title moves right of the icon, and up to make room for the detail line.
        constraints.filter { $0.firstItem === label }.forEach { $0.isActive = false }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: elapsed.leadingAnchor, constant: -6),
            elapsed.trailingAnchor.constraint(equalTo: trailing, constant: inset),
            elapsed.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fades the checkmark in or out. Hidden only by alpha: it keeps its place and stays clickable and
    /// reachable to accessibility (and the row's menu has Resolve too).
    func showResolve(_ visible: Bool, animated: Bool) {
        guard let resolve else { return }
        let alpha: CGFloat = visible ? 1 : 0
        guard animated, window != nil else { return resolve.alphaValue = alpha }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            resolve.animator().alphaValue = alpha
        }
    }

    /// "now", "45s", "12m", "3h", "2d".
    static func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<10: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
