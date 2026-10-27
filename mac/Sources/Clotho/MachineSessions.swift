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
final class MachineSession {
    let machine: Machine
    let store: ModelStore

    init(machine: Machine, backend: SessionBackend) {
        self.machine = machine
        store = ModelStore(backend: backend)
    }

    var key: MachineKey { machine.key }

    /// The machine's name as its daemon reports it, or its saved name.
    var title: String {
        if machine.isLocal {
            return store.hello?.machine.map { $0.hostname.replacingOccurrences(of: ".local", with: "") } ?? "Local"
        }
        return machine.label
    }
}

extension AppDelegate {
    nonisolated static let localKey: MachineKey = "local"

    var focusedSession: MachineSession { sessions[focusedMachine] ?? sessions[Self.localKey]! }
    /// The focused machine's model; shortcuts and the tab bar work on it.
    var store: ModelStore { focusedSession.store }

    func tabKey(_ tab: TabID) -> TabKey { TabKey(machine: focusedMachine, tab: tab) }

    /// Remote machines connected last time reconnect at launch.
    var connectedMachineIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ConnectedMachines") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "ConnectedMachines") }
    }

    // MARK: Connecting

    func addSession(_ session: MachineSession) {
        sessions[session.key] = session
        session.store.onChange = { [weak self] in self?.sync() }
        session.store.onBell = { [weak self] pane in self?.bell(pane) }
        let key = session.key
        session.store.onAgentChange = { [weak self] pane, before, after in
            self?.agentChanged(machine: key, pane: pane, from: before, to: after)
        }
    }

    /// Connects to a remote machine's daemon (installing it as needed). `show` switches the window to it
    /// (opening a first session if it has none); `newSession` always starts one there.
    func connect(_ machine: Machine, newSession: Bool = false, show: Bool = false) {
        guard !machine.isLocal else { return }
        if sessions[machine.key] != nil {
            if newSession || show { focus(machine: machine.key) }
            if newSession { self.newSession(nil) }
            return
        }
        let (backend, installer) = makeRemoteBackend(for: machine)
        let session = MachineSession(machine: machine, backend: backend)
        remoteInstallers[machine.key] = installer
        addSession(session)
        if !connectedMachineIDs.contains(machine.key) { connectedMachineIDs.append(machine.key) }
        if newSession || show { focusedMachine = machine.key }
        sync()
        Task { @MainActor in
            do {
                try await session.store.start()
                checkRemoteDaemonUpdate(machine.key)
                offerHolderRestartIfNeeded(session)
                refreshHookStatus(machine.key)
                // A machine with no sessions yet gets one when it's the one being looked at.
                let empty = try await session.store.backend.getState().workspaces.isEmpty
                if newSession || (empty && focusedMachine == machine.key) {
                    _ = try await session.store.backend.createWorkspace(name: nil, spawn: spawnOptions())
                }
            } catch {
                // The backend keeps retrying; the sidebar shows the error meanwhile.
                log("connecting to \(machine.label) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Closes the connection. The machine's sessions keep running there.
    func disconnect(_ key: MachineKey) {
        guard key != Self.localKey, let session = sessions.removeValue(forKey: key) else { return }
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
        guard sessions[key] != nil, focusedMachine != key else { return }
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
            log("\(label): no bundled clothod builds; remote sessions need the app built with build-app.sh")
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
        transport.extraOptions = Self.sshMultiplexOptions
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
        return (ClothodBackend(configuration: configuration), installer)
    }

    /// Shared with the file browser's ssh calls, so they all ride one connection per machine.
    static let sshMultiplexOptions = [
        "-o", "ControlMaster=auto", "-o", "ControlPath=\(NSHomeDirectory())/.ssh/cm-clothoapp-%C", "-o", "ControlPersist=600",
    ]

    /// clothod's warnings (for example that sessions won't survive logout), once per machine per run.
    func showRemoteWarning(_ line: String, for key: MachineKey) {
        guard !warnedMachines.contains(key + line) else { return }
        warnedMachines.insert(key + line)
        let name = sessions[key]?.title ?? "the machine"
        showNotice("\(name): " + line.replacingOccurrences(of: "clothod: warning:", with: "").trimmingCharacters(in: .whitespaces),
                   detail: nil, action: nil, then: nil)
    }

    /// The machine's running holder is older than this build can drive (bridge exit 3). Its shells are
    /// untouched; restarting them is the user's call.
    func offerRemoteRestart(_ key: MachineKey, message: String) {
        guard let session = sessions[key], noticeBar == nil || !upgradeNoticeMachines.contains(key) else { return }
        upgradeNoticeMachines.insert(key)
        showNotice("Clotho was updated. Restart the sessions on \(session.title) to finish upgrading; this ends the programs running there.",
                   detail: message, action: "Restart Sessions…") { [weak self] in self?.confirmRemoteRestart(key) }
    }

    func confirmRemoteRestart(_ key: MachineKey) {
        guard let session = sessions[key], let installer = remoteInstallers[key], window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Restart all sessions on \(session.title)?"
        alert.informativeText = "Every shell and program running in Clotho on \(session.title) ends."
        alert.addButton(withTitle: "Restart Sessions")
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
        for session in sessions.values where !session.machine.isLocal {
            log("\(session.machine.label): reconnecting after \(reason)")
            session.store.backend.reconnectNow()
        }
    }

    // MARK: Sidebar

    /// The sidebar's groups: this Mac, then each saved machine, connected or not.
    func sidebarGroups() -> [SidebarGroup] {
        var groups: [SidebarGroup] = []
        let local = sessions[Self.localKey]!
        groups.append(SidebarGroup(key: Self.localKey, title: local.title, status: connectionStatus(local.store.connection, isLocal: true),
                                   workspaces: local.store.state.workspaces, selected: selectedWorkspace(in: local),
                                   isConnected: true, isLocal: true, badges: workspaceBadges(local)))
        for machine in remoteMachines {
            if let session = sessions[machine.key] {
                groups.append(SidebarGroup(key: machine.key, title: machine.label, status: connectionStatus(session.store.connection, isLocal: false),
                                           workspaces: session.store.state.workspaces, selected: selectedWorkspace(in: session),
                                           isConnected: true, isLocal: false, badges: workspaceBadges(session)))
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

    private func workspaceBadges(_ session: MachineSession) -> [WorkspaceID: NSColor] {
        var badges: [WorkspaceID: NSColor] = [:]
        for workspace in session.store.state.workspaces {
            badges[workspace.id] = agentBadge(machine: session.key, panes: workspace.tabs.flatMap(\.layout.panes))
        }
        return badges
    }

    private func selectedWorkspace(in session: MachineSession) -> WorkspaceID? {
        session.key == focusedMachine ? session.store.focusedWorkspace?.id : nil
    }

    private func connectionStatus(_ state: ConnectionState, isLocal: Bool) -> (NSColor?, String?) {
        switch state {
        case .connected: return (isLocal ? nil : NSColor(hex: 0x57C78A), nil)
        case .idle: return (Theme.dimText, "Starting…")
        case .connecting(let step): return (NSColor(hex: 0xC8A35A), step + "…")
        case .reconnecting(let reason): return (NSColor(hex: 0xC76156), "Reconnecting: \(reason)")
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
    /// Connected (or connecting) machines list their sessions; others offer Connect.
    let isConnected: Bool
    let isLocal: Bool
    /// Agent badges for sessions.
    let badges: [WorkspaceID: NSColor]
}

/// The network path the monitor saw last (its handler runs on one serial queue).
private final class LastPath: @unchecked Sendable {
    private var path: NWPath?

    func swap(_ new: NWPath) -> NWPath? {
        defer { path = new }
        return path
    }
}
