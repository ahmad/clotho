import AppKit
import ClothoKit
import Network

// One backend connection per machine: this Mac's daemon, and each remote machine's daemon through
// `clothod bridge` over SSH. Pane, tab and workspace IDs are only unique within one daemon, so views and
// per-window state are keyed by (machine, id). The window shows one machine at a time, the focused one,
// and every shortcut acts on it.

typealias MachineKey = String

extension Machine {
    /// "local" for this Mac, the saved id for remote machines.
    var key: MachineKey { id ?? AppDelegate.localKey }
}

struct PaneKey: Hashable {
    let machine: MachineKey
    let pane: PaneID
}

struct TabKey: Hashable {
    let machine: MachineKey
    let tab: TabID
}

/// A machine's daemon connection and its model.
@MainActor
final class MachineConnection {
    let machine: Machine
    let store: ModelStore

    init(machine: Machine, backend: SessionBackend) {
        self.machine = machine
        store = ModelStore(backend: backend)
    }

    var key: MachineKey { machine.key }

    /// The name the user knows the machine by: this Mac's Computer Name, or the saved machine's name.
    /// Never the hostname a daemon reports, which the network assigns (mac.lan).
    var title: String { machine.isLocal ? ComputerName.current : machine.label }
}

extension AppDelegate {
    nonisolated static let localKey: MachineKey = "local"

    var focusedConnection: MachineConnection { connections[focusedMachine] ?? connections[Self.localKey]! }
    /// The focused machine's model; shortcuts and the tab bar work on it.
    var store: ModelStore { focusedConnection.store }

    func tabKey(_ tab: TabID) -> TabKey { TabKey(machine: focusedMachine, tab: tab) }

    /// Remote machines connected last time reconnect at launch.
    var connectedMachineIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ConnectedMachines") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "ConnectedMachines") }
    }

    // MARK: Connecting

    func addSession(_ session: MachineConnection) {
        connections[session.key] = session
        session.store.backend.setTerminalColors(terminalColors)
        session.store.onChange = { [weak self] in ClickTrace.measure("sync") { self?.sync() } }
        session.store.onBell = { [weak self] pane in self?.bell(pane) }
        session.store.onSettings = { [weak self] _ in self?.settingsWindow?.reload() }
        session.store.onService = { [weak self] _ in self?.settingsWindow?.reload() }
        let key = session.key
        session.store.onAgentChange = { [weak self] pane, before, after in
            self?.agentChanged(machine: key, pane: pane, from: before, to: after)
        }
    }

    /// Connects to a remote machine's daemon (installing it as needed). `show` switches the window to it
    /// (opening a first workspace if it has none); `startWorkspace` always starts one there.
    func connect(_ machine: Machine, startWorkspace: Bool = false, show: Bool = false) {
        guard !machine.isLocal else { return }
        if connections[machine.key] != nil {
            if startWorkspace || show { focus(machine: machine.key) }
            if startWorkspace { self.newWorkspace(nil) }
            return
        }
        let (backend, installer) = makeRemoteBackend(for: machine)
        let session = MachineConnection(machine: machine, backend: backend)
        remoteInstallers[machine.key] = installer
        addSession(session)
        if !connectedMachineIDs.contains(machine.key) { connectedMachineIDs.append(machine.key) }
        if startWorkspace || show { focusedMachine = machine.key }
        sync()
        Task { @MainActor in
            do {
                try await session.store.start()
                checkRemoteDaemonUpdate(machine.key)
                offerHolderRestartIfNeeded(session)
                refreshHookStatus(machine.key)
                // A machine with no workspaces yet gets one when it's the one being looked at.
                let empty = try await session.store.backend.getState().workspaces.isEmpty
                if startWorkspace || (empty && focusedMachine == machine.key) {
                    _ = try await session.store.backend.createWorkspace(name: nil, spawn: spawnOptions())
                }
            } catch {
                // The backend keeps retrying; the sidebar shows the error meanwhile.
                log("connecting to \(machine.label) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Closes the connection. The machine's workspaces keep running there.
    func disconnect(_ key: MachineKey) {
        guard key != Self.localKey, let session = connections.removeValue(forKey: key) else { return }
        session.store.stop()
        remoteInstallers[key] = nil
        connectedMachineIDs.removeAll { $0 == key }
        for (paneKey, host) in paneHosts where paneKey.machine == key {
            host.detach()
            paneHosts[paneKey] = nil
        }
        maximized = maximized.filter { $0.key.machine != key }
        if focusedMachine == key { focusedMachine = Self.localKey }
        sync()
    }

    func focus(machine key: MachineKey) {
        guard connections[key] != nil, focusedMachine != key else { return }
        focusedMachine = key
        sync()
    }

    /// clothod over SSH: the installer probes the machine and installs or upgrades the bundled build,
    /// then the transport runs its `bridge`. Both share one multiplexed ssh connection.
    func makeRemoteBackend(for machine: Machine) -> (SessionBackend, RemoteInstaller?) {
        let target = machine.target ?? ""
        let label = machine.label
        let sshOptions = SSHProcessTransport.baseOptions + Self.sshMultiplexOptions
        guard let dist = Bundle.main.resourceURL?.appendingPathComponent("clothod-dist"),
              FileManager.default.fileExists(atPath: dist.appendingPathComponent("manifest.json").path) else {
            log("\(label): no bundled clothod builds; remote connections need the app built with build-app.sh")
            return (ClothodBackend(configuration: .init(transport: SSHProcessTransport(target: target, remoteCommand: {
                throw RemoteInstaller.Failure(message: "This build of Clotho doesn't include clothod for remote machines.")
            }))), nil)
        }
        // The dev build keeps its own clothod install and daemon on the machine, apart from the user's.
        let defaults = UserDefaults.standard
        let installDir = defaults.string(forKey: "RemoteInstallDir") ?? (isDevBuild ? RemoteSetup.devInstallDir : nil)
        let runtimeDir = defaults.string(forKey: "RemoteRuntimeDir") ?? (isDevBuild ? RemoteSetup.devRuntimeDir : nil)
        // A private runtime dir is a temporary instance, which ends itself when Clotho disconnects.
        let installer = RemoteInstaller(runner: SSHCommandRunner(target: target, options: sshOptions), dist: dist,
                                        installDir: installDir, runtimeDir: runtimeDir,
                                        ephemeral: runtimeDir != nil ? "exit" : nil, log: { log("\(label): \($0)") })
        var transport = SSHProcessTransport(target: target, remoteCommand: { try installer.bridgeCommand() },
                                            prepare: { progress in try installer.prepare(progress: progress) })
        transport.extraOptions = Self.sshBridgeOptions
        let key = machine.key
        transport.onStderrLine = { [weak self] line in
            guard line.hasPrefix("clothod: warning:") else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.showRemoteWarning(line, for: key) } }
        }
        transport.onExit = { [weak self] status, message in
            guard status == RemoteSetup.holderTooOldExit else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.offerRemoteRestart(key, message: message) } }
        }
        var configuration = ClothodBackend.Configuration(transport: transport, clientName: "clotho-mac", log: { log("\(label): \($0)") })
        if defaults.bool(forKey: "TraceFrames") { configuration.trace = { log("\(label) frame \($0)") } }
        // A few quick tries, then a Reconnect button: no ssh in a loop for a machine that's off or away.
        configuration.retry = .remote
        return (ClothodBackend(configuration: configuration), installer)
    }

    /// Shared with the file browser's ssh calls, so they all ride one connection per machine.
    /// One SSH connection per machine, shared by the session, installs and file access. The dev build
    /// keeps its own (it must never ride, or become, the installed app's connection). Testing aid, dev
    /// build only: SSHProxyCommand routes its SSH through a command (a throttling relay, say), on a
    /// separate connection.
    nonisolated static let sshMultiplexOptions: [String] = {
        var name = isDevBuild ? "cm-clothodev" : "cm-clothoapp"
        if !sshProxyOptions.isEmpty { name += "-proxied" }
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(NSHomeDirectory())/.ssh/\(name)-%C", "-o", "ControlPersist=600"]
            + sshProxyOptions
    }()

    /// The session's bridge gets an SSH connection of its own, outside the shared master. Its keepalives
    /// then watch its own link, killing it ends it for sure, and a wedged master (a dead link it hasn't
    /// noticed) can't hold the session, or the reconnect after it, hostage.
    nonisolated static let sshBridgeOptions: [String] = ["-o", "ControlMaster=no", "-o", "ControlPath=none"] + sshProxyOptions

    nonisolated static let sshProxyOptions: [String] = {
        guard isDevBuild, let command = UserDefaults.standard.string(forKey: "SSHProxyCommand"), !command.isEmpty else { return [] }
        return ["-o", "ProxyCommand=\(command)"]
    }()

    /// clothod's warnings (for example that workspaces won't survive logout), once per machine per run.
    func showRemoteWarning(_ line: String, for key: MachineKey) {
        guard !warnedMachines.contains(key + line) else { return }
        warnedMachines.insert(key + line)
        let name = connections[key]?.title ?? "the machine"
        showNotice("\(name): " + line.replacingOccurrences(of: "clothod: warning:", with: "").trimmingCharacters(in: .whitespaces),
                   detail: nil, action: nil, then: nil)
    }

    /// The machine's running holder is older than this build can drive (bridge exit 3). Its shells are
    /// untouched; restarting them is the user's call.
    func offerRemoteRestart(_ key: MachineKey, message: String) {
        guard let session = connections[key], noticeBar == nil || !upgradeNoticeMachines.contains(key) else { return }
        upgradeNoticeMachines.insert(key)
        showNotice("\(session.title) runs an older clothod that can't be updated in place. Restarting it finishes the update and ends every shell on \(session.title).",
                   detail: message, action: "Restart clothod…") { [weak self] in self?.confirmRemoteRestart(key) }
    }

    func confirmRemoteRestart(_ key: MachineKey) {
        guard let session = connections[key], let installer = remoteInstallers[key], window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Restart clothod on \(session.title)?"
        alert.informativeText = "Every shell and program running in Clotho on \(session.title) ends."
        alert.addButton(withTitle: "End all shells and restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            hideNotice()
            upgradeNoticeMachines.remove(key)
            Task.detached {
                do {
                    try installer.shutdownSessions()
                } catch {
                    log("\(session.machine.label): restart failed: \(error.localizedDescription)")
                }
                await MainActor.run { session.store.backend.reconnectNow() }
            }
        }
    }

    // MARK: Sleep, wake and network changes

    /// After sleep or a network change, remote links are likely dead but haven't timed out, so reconnect
    /// now (resuming every pane) rather than after ssh's keepalive gives up.
    func watchForWakeAndNetworkChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectRemoteMachines(reason: "wake") }
        }
        let monitor = NWPathMonitor()
        let last = LastPath()
        let started = Date()
        monitor.pathUpdateHandler = { [weak self] path in
            // Only a real change: back online, or a different set of interfaces (Wi-Fi to Ethernet, a VPN).
            // The monitor also reports the current path, sometimes more than once, right after it starts.
            guard let previous = last.swap(path), path.status == .satisfied, Date().timeIntervalSince(started) > 5 else { return }
            let interfaces = { (p: NWPath) in Set(p.availableInterfaces.map(\.name)) }
            guard previous.status != .satisfied || interfaces(previous) != interfaces(path) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconnectRemoteMachines(reason: "network change") } }
        }
        monitor.start(queue: DispatchQueue(label: "clotho.network"))
        networkMonitor = monitor
    }

    func reconnectRemoteMachines(reason: String) {
        // Network changes come in bursts (an interface going down, a VPN, DHCP); one reconnect covers them.
        guard Date().timeIntervalSince(lastRemoteReconnect) > 2 else { return }
        lastRemoteReconnect = Date()
        for session in connections.values where !session.machine.isLocal {
            log("\(session.machine.label): reconnecting after \(reason)")
            session.store.backend.reconnectNow()
        }
    }

    // MARK: Sidebar

    // MARK: Git (feature `git`; nothing shows against daemons without it)

    /// A pane's git info, when its daemon has the feature.
    func git(_ pane: PaneID?, in store: ModelStore) -> PaneGit? {
        guard store.features.contains(.git), let pane else { return nil }
        return store.state.pane(pane)?.git
    }

    /// A tab's git info: its active pane's.
    func git(of tab: Tab, in store: ModelStore) -> PaneGit? { git(tab.activePane, in: store) }

    /// The sidebar's groups: this Mac, then each saved machine, connected or not.
    func sidebarGroups() -> [SidebarGroup] {
        var groups: [SidebarGroup] = []
        let local = connections[Self.localKey]!
        groups.append(SidebarGroup(key: Self.localKey, title: local.title, status: connectionStatus(local.store.connection, isLocal: true),
                                   workspaces: local.store.state.workspaces, selected: selectedWorkspace(in: local),
                                   isConnected: true, isLocal: true, badges: workspaceBadges(local)))
        for machine in remoteMachines {
            if let session = connections[machine.key] {
                let paused = session.store.retryPaused
                let status = paused ? Self.pausedStatus(machine.label) : connectionStatus(session.store.connection, isLocal: false)
                groups.append(SidebarGroup(key: machine.key, title: machine.label, status: status,
                                           workspaces: session.store.state.workspaces, selected: selectedWorkspace(in: session),
                                           isConnected: true, isLocal: false, badges: workspaceBadges(session),
                                           retryPaused: paused ? Self.pausedReason(session.store.connection) : nil))
            } else {
                // Not connected: a grey dot when ssh works, red with ssh's message when it doesn't.
                let check = machine.id.flatMap { machineStatus[$0] } ?? .unknown
                let status: (NSColor?, String?)
                switch check {
                case .unreachable: status = (check.color, check.summary)
                case .reachable: status = (Theme.dimText, nil)
                case .unknown, .checking: status = (nil, nil)
                }
                groups.append(SidebarGroup(key: machine.key, title: machine.label, status: status,
                                           workspaces: [], selected: nil, isConnected: false, isLocal: false, badges: [:]))
            }
        }
        return groups
    }

    private func workspaceBadges(_ session: MachineConnection) -> [WorkspaceID: NSColor] {
        var badges: [WorkspaceID: NSColor] = [:]
        for workspace in session.store.state.workspaces {
            badges[workspace.id] = agentBadge(machine: session.key, panes: workspace.tabs.flatMap(\.layout.panes))
        }
        return badges
    }

    private func selectedWorkspace(in session: MachineConnection) -> WorkspaceID? {
        session.key == focusedMachine ? session.store.focusedWorkspace?.id : nil
    }

    /// A machine that stopped retrying: a muted line, with the Reconnect button below it.
    static func pausedStatus(_ name: String) -> (NSColor?, String?) { (Theme.dimText, "Can't reach \(name)") }

    static func pausedReason(_ state: ConnectionState) -> String {
        if case .reconnecting(let reason) = state, !reason.isEmpty { return reason }
        return "The last attempts failed."
    }

    /// The sidebar's Reconnect: tries now, and starts the automatic retries again.
    func reconnect(_ key: MachineKey) {
        guard let session = connections[key] else { return }
        log("\(session.machine.label): reconnecting (asked)")
        session.store.backend.reconnectNow()
    }

    private func connectionStatus(_ state: ConnectionState, isLocal: Bool) -> (NSColor?, String?) {
        switch state {
        case .connected: return (isLocal ? nil : Theme.success, nil)
        case .idle: return (Theme.dimText, "Starting…")
        case .connecting(let step): return (Theme.caution, step + "…")
        case .reconnecting(let reason): return (Theme.danger, "Reconnecting: \(reason)")
        }
    }
}

/// What the sidebar shows for one machine.
struct SidebarGroup {
    let key: MachineKey
    let title: String
    /// A dot color and a status line under the header (nil hides each).
    let status: (color: NSColor?, text: String?)
    let workspaces: [Workspace]
    let selected: WorkspaceID?
    /// Connected (or connecting) machines list their workspaces; others offer Connect.
    let isConnected: Bool
    let isLocal: Bool
    /// Agent badges for workspaces: each one's most urgent agent's.
    let badges: [WorkspaceID: NSColor]
    /// The machine stopped retrying on its own: why (the Reconnect button's tooltip); nil while it isn't.
    var retryPaused: String? = nil
}

/// The network path the monitor saw last (its handler runs on one serial queue).
private final class LastPath: @unchecked Sendable {
    private var path: NWPath?

    func swap(_ new: NWPath) -> NWPath? {
        defer { path = new }
        return path
    }
}
