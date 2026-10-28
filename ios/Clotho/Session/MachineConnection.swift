import ClothoKit
import Combine
import Foundation
import SwiftUI

/// One machine's live connection: a ClothodBackend over the machine's transport, the ModelStore that
/// mirrors its model, and one terminal per pane the user has looked at.
///
/// Terminals are kept while their pane exists, so switching back to a pane resubscribes from the seq it
/// already applied (live or replay) instead of reloading a snapshot.
@MainActor
final class MachineConnection: ObservableObject, Identifiable {
    /// Updated in place when edits don't change the endpoint (a rename, the alerts switch).
    private(set) var machine: Machine
    let store: ModelStore
    private let backend: ClothodBackend
    private var started = false
    /// True while the app is in the background and the connection is deliberately closed.
    @Published private(set) var suspended = false
    /// Why the last connect or command failed, for an alert.
    @Published var lastError: String?

    /// The machine's clothod against the app's bundled one; updating is the user's call.
    @Published private(set) var versionStatus = RemoteInstaller.VersionStatus.current
    @Published private(set) var updating = false
    @Published private(set) var restarting = false

    var updateAvailable: Bool { if case .updateAvailable = shownVersionStatus { return true } else { return false } }

    /// The machine's sessions run under a legacy holder: updating needs a one-time restart that ends them.
    var holderOutdated: Bool { store.hello?.holderOutdated == true || needsSessionRestart || Self.previewRows != nil }

    /// What the machine screen shows. Debug builds can force the upgrade rows for a look at them
    /// (`-PreviewVersionRows update|app`).
    var shownVersionStatus: RemoteInstaller.VersionStatus {
        switch Self.previewRows {
        case "update": return .updateAvailable(running: "0.1.0-ec24760b269d")
        case "app": return .appOutdated(running: "0.9.0-0123456789ab")
        default: return versionStatus
        }
    }

    private static var previewRows: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "PreviewVersionRows")
        #else
        return nil
        #endif
    }

    /// The machine presented a different host key than the one trusted on first use.
    @Published var hostKeyChange: (trusted: String, presented: String)?

    /// Fake agents (see `FakeAgents`) the user acknowledged.
    var fakeAcked: Set<PaneID> = []
    var fakeMuted: Set<PaneID> = []

    private var panes: [PaneID: PaneHostView] = [:]
    private var hostKeyObserver: NSObjectProtocol?
    private var pushObserver: NSObjectProtocol?
    /// What this machine was last told about alerts (instance, on or off, handle, label); nil to tell it again.
    private var pushSynced: String?
    private var lastAttention: Set<PaneID>?
    private let transport: ClothodTransport

    var id: UUID { machine.id }

    init(machine: Machine, transport: ClothodTransport) {
        self.machine = machine
        self.transport = transport
        backend = ClothodBackend(configuration: .init(transport: transport, clientName: "clotho-ios/0.1",
                                                      log: { log("[\(machine.displayName)] \($0)") }))
        store = ModelStore(backend: backend)
        // The last-known model, shown at once (dimmed, read-only) until the machine's own arrives.
        if let cached = SavedState.shared.load(machine.id) {
            store.restore(cached)
            lastSeen = cached.lastSeen
        }
        // Drop terminals for panes that left the model.
        store.onChange = { [weak self] in
            guard let self else { return }
            self.pruneTerminals()
            self.savedChanged()
            self.scheduleSave()
            self.fetchPreviews()
            // The probe that ran before this connection compares the machine's clothod with the app's.
            let status = (self.transport as? SSHTransport)?.versionStatus ?? .current
            if status != self.versionStatus { self.versionStatus = status }
            self.syncPush()
            self.clearStaleAlerts()
            if self.store.isConnected { AgentNotifier.shared.promptIfUndecided() }
        }
        store.onAgentChange = { [weak self] pane, before, after in
            guard let self else { return }
            let location = self.store.state.location(of: pane)
            let place = AgentNotifier.Place(workspace: location?.workspace.name, workspaceID: location?.workspace.id,
                                            tab: location.map { self.store.displayTitle(of: $0.tab) } ?? "",
                                            cwd: self.store.state.pane(pane)?.cwd)
            AgentNotifier.shared.agentChanged(machine: self.machine, pane: pane, place: place, before: before, after: after)
        }
        let id = machine.id
        hostKeyObserver = NotificationCenter.default.addObserver(forName: .hostKeyChanged, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["machine"] as? UUID == id,
                  let trusted = note.userInfo?["trusted"] as? String, let presented = note.userInfo?["presented"] as? String else { return }
            MainActor.assumeIsolated { self?.hostKeyChange = (trusted, presented) }
        }
        pushObserver = NotificationCenter.default.addObserver(forName: .pushHandleChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPush() }
        }
    }

    deinit {
        if let hostKeyObserver { NotificationCenter.default.removeObserver(hostKeyObserver) }
        if let pushObserver { NotificationCenter.default.removeObserver(pushObserver) }
    }

    /// The saved machine changed without changing how to reach it.
    func update(_ machine: Machine) {
        guard machine != self.machine else { return }
        self.machine = machine
        syncPush()
    }

    // MARK: Push alerts

    var supportsPush: Bool { store.hello?.features.contains(.push) ?? false }
    var alertsOn: Bool { machine.alerts ?? true }

    /// Registers this phone with the machine's clothod for alerts while the app is closed, or unregisters it
    /// when the user turned them off. Again after every reconnect to a new daemon instance, a new relay
    /// handle or a rename, so the machine always has a current registration.
    private func syncPush() {
        guard store.isConnected, supportsPush, let hello = store.hello else { return }
        let registrar = PushRegistrar.shared
        let registration = alertsOn ? registrar.registration(for: machine) : nil
        if alertsOn && registration == nil { return }
        let key = [hello.instance, String(alertsOn), registration?.handle ?? "", registration?.label ?? ""].joined(separator: "|")
        guard key != pushSynced else { return }
        pushSynced = key
        let backend = store.backend, device = registrar.device, name = machine.displayName
        Task {
            do {
                if let registration { try await backend.pushRegister(registration) } else { try await backend.pushUnregister(device: device) }
                log("[\(name)] push: \(registration == nil ? "unregistered" : "registered")")
            } catch {
                log("[\(name)] push: \(registration == nil ? "unregister" : "register") failed: \(error.localizedDescription)")
                if self.pushSynced == key { self.pushSynced = nil }
            }
        }
    }

    /// Asks the machine to send this phone a test alert through the relay.
    func sendTestAlert() {
        let device = PushRegistrar.shared.device
        run("Test alert") { try await $0.pushTest(device: device) }
    }

    /// Removes delivered alerts for panes that no longer need the user (answered here or on another device).
    private func clearStaleAlerts() {
        guard store.isConnected else { return }
        let attention = Set(store.state.panes.filter { $0.agent?.needsAttention == true }.map(\.id))
        guard attention != lastAttention else { return }
        lastAttention = attention
        AgentNotifier.shared.removeDelivered(machine: machine.id, except: attention)
    }

    /// The user accepted the new host key after the warning.
    func trustPresentedHostKey() {
        guard let change = hostKeyChange else { return }
        TrustedHostKeys.shared.set(change.presented, for: machine.id)
        hostKeyChange = nil
        backend.reconnectNow()
    }

    /// Runs the machine's `upgrade` to the bundled clothod (after the user confirmed), then reconnects.
    func updateClothod() {
        guard let ssh = transport as? SSHTransport, !updating else { return }
        updating = true
        // Paused meanwhile: the switch restarts clothod there, and a reconnect would replace the SSH
        // connection the upgrade runs on. Resuming resubscribes every pane from its seq.
        backend.stop()
        Task.detached {
            var failure: String?
            do { try ssh.updateClothod() } catch { failure = error.localizedDescription }
            await MainActor.run {
                if let failure { self.lastError = failure }
                self.updating = false
                self.versionStatus = ssh.versionStatus
                self.started = false
                self.connect()
            }
        }
    }

    /// The running holder is too old for the bundled clothod (bridge exit 3).
    var needsSessionRestart: Bool {
        if case .reconnecting(let reason) = store.connection { return reason.contains("needs its sessions restarted") }
        return false
    }

    /// Ends every shell on the machine so a current holder can take over, then reconnects. Only after the
    /// user confirmed that the shells end.
    func restartSessions() {
        guard let ssh = transport as? SSHTransport, !restarting else { return }
        restarting = true
        backend.stop()
        Task.detached {
            var failure: String?
            do { try ssh.restartSessions() } catch { failure = error.localizedDescription }
            await MainActor.run {
                if let failure { self.lastError = "Restarting clothod failed: \(failure)" }
                self.restarting = false
                self.started = false
                self.connect()
            }
        }
    }

    func connect() {
        guard !started else { return }
        started = true
        suspended = false
        Task {
            #if DEBUG
            // UI tests hold connections back for a while to see the saved model (`-HoldConnections 8`).
            let hold = UserDefaults.standard.double(forKey: "HoldConnections")
            if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
            #endif
            do {
                try await store.start()
            } catch {
                // The backend keeps retrying on its own; the state shows as reconnecting.
                log("[\(machine.displayName)] connect failed: \(error.localizedDescription)")
            }
        }
    }

    /// Closes the connection when the app goes to the background. Terminals keep their seqs.
    func suspend() {
        saveNow()
        guard started else { return }
        started = false
        suspended = true
        backend.stop()
    }

    /// Reconnects after `suspend`. The backend resubscribes every pane it was showing with the seq it
    /// had reached, so each resumes in live or replay mode (or gets a snapshot if the gap is too big).
    func resume() {
        guard suspended else { return }
        connect()
    }

    func disconnect() {
        saveNow()
        started = false
        store.stop()
        panes.values.forEach { $0.detach() }
        panes.removeAll()
        // A test-directory daemon lives only as long as its connection.
        if let ssh = transport as? SSHTransport, machine.devDirs == true {
            let name = machine.displayName
            Task.detached {
                do { try ssh.removeDevDaemon() } catch { log("[\(name)] \(error.localizedDescription)") }
            }
        }
    }

    var connectionLabel: String {
        if store.isSaved { return savedLabel }
        if suspended { return "Paused" }
        switch store.connection {
        case .idle: return "Not connected"
        case .connecting(let step): return step
        case .connected: return "Connected"
        case .reconnecting(let reason): return "Reconnecting: \(reason)"
        }
    }

    // MARK: Terminals

    func terminal(for pane: Pane) -> PaneHostView {
        if let host = panes[pane.id] { return host }
        let host = PaneHostView(pane: pane, store: store)
        host.terminal.onImagePaste = { [weak self, weak host] png in
            guard let self, let host else { return }
            self.pasteImage(png, into: host)
        }
        host.onLeave = { [weak self] host in self?.saveScreen(of: host) }
        host.readOnly = store.isSaved
        if let screen = SavedState.shared.screen(pane.id, on: machine.id) { host.showSaved(screen) }
        panes[pane.id] = host
        return host
    }

    // MARK: Saved state

    /// Whether this machine shows its saved model (dimmed, read-only) rather than a live one.
    var isSaved: Bool { store.isSaved }
    /// When the machine was last seen live, as of the last save (while connected, it's connected).
    @Published private(set) var lastSeen: Date?

    private var saveScheduled = false

    /// "Last seen 3m ago · Connecting…" for a saved model.
    var savedLabel: String {
        let state = suspended ? "Paused" : "Connecting…"
        guard let lastSeen else { return state }
        return "Last seen \(Self.ago(lastSeen)) · \(state)"
    }

    /// "just now", "3m ago", "2h ago", "4d ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }

    func hasSavedScreen(_ pane: PaneID) -> Bool {
        SavedState.shared.hasScreen(pane, on: machine.id)
    }

    /// Terminals follow the saved/live switch.
    private func savedChanged() {
        let readOnly = store.isSaved
        panes.values.forEach { $0.readOnly = readOnly }
    }

    /// Saves the model a moment after it changes, not on every event.
    private func scheduleSave() {
        guard !store.isSaved, !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.saveScheduled = false
            self.saveModel()
        }
    }

    private func saveModel() {
        // Nothing to save before the machine's model ever arrived.
        guard !store.isSaved, store.hello != nil || !store.state.workspaces.isEmpty else { return }
        let snapshot = store.cacheSnapshot()
        SavedState.shared.save(snapshot, for: machine.id)
        if lastSeen != snapshot.lastSeen { lastSeen = snapshot.lastSeen }
    }

    /// The daemon instance whose panes' previews were fetched.
    private var previewedInstance: String?

    /// Once per daemon instance, a plain-text preview (`pane.text`) of every pane this phone isn't showing,
    /// so the saved model has a screen for each. Older daemons don't have it; that's no error.
    private func fetchPreviews() {
        guard SavedState.shared.keepPreviews, store.isConnected, !store.isSaved, let instance = store.hello?.instance,
              previewedInstance != instance, !store.state.panes.isEmpty else { return }
        previewedInstance = instance
        let shown = Set(panes.filter { $0.value.haveSeq != nil }.map(\.key))
        let wanted = store.state.panes.map(\.id).filter { !shown.contains($0) }.prefix(SavedState.maxScreens)
        let backend = store.backend, id = machine.id, name = machine.displayName
        Task { [weak self] in
            var failures = 0
            for pane in wanted {
                do {
                    let text = try await backend.paneText(pane)
                    // A pane opened meanwhile has its own, newer screen.
                    guard self?.panes[pane]?.haveSeq == nil else { continue }
                    SavedState.shared.saveScreen(ScreenCapture.plain(text), pane: pane, on: id)
                } catch {
                    failures += 1
                    if failures == 1 { log("[\(name)] pane previews: \(error.localizedDescription)") }
                    if failures >= 3 { return }
                }
            }
        }
    }

    private func saveScreen(of host: PaneHostView) {
        guard !store.isSaved, let screen = host.capture() else { return }
        SavedState.shared.saveScreen(screen, pane: host.paneID, on: machine.id)
    }

    /// The model and every terminal's screen, now (going to the background).
    func saveNow() {
        saveModel()
        panes.values.forEach(saveScreen(of:))
    }

    func setFont(_ font: UIFont) {
        panes.values.forEach { $0.setFont(font) }
    }

    private func pruneTerminals() {
        let live = Set(store.state.panes.map(\.id))
        for (id, host) in panes where !live.contains(id) {
            host.detach()
            panes[id] = nil
        }
    }

    // MARK: Commands

    func run(_ what: String, _ body: @escaping (SessionBackend) async throws -> Void) {
        let backend = store.backend
        Task {
            do {
                try await body(backend)
            } catch {
                log("[\(machine.displayName)] \(what) failed: \(error.localizedDescription)")
                lastError = "\(what) failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Every machine's connection, created on first use and kept for the app's life.
@MainActor
final class Connections: ObservableObject {
    private var connections: [UUID: MachineConnection] = [:]
    private var watchers: [UUID: [AnyCancellable]] = [:]
    /// Agents on every connected machine, waiting first.
    @Published private(set) var agentRows: [AgentRow] = []
    private var recomputeScheduled = false

    func connection(for machine: Machine) -> MachineConnection {
        if let existing = connections[machine.id], existing.machine.endpoint == machine.endpoint {
            existing.update(machine)
            return existing
        }
        connections[machine.id]?.disconnect()
        let connection = MachineConnection(machine: machine, transport: Self.transport(for: machine))
        connections[machine.id] = connection
        watchers[machine.id] = [
            connection.store.objectWillChange.sink { [weak self] in self?.scheduleRecompute() },
            connection.objectWillChange.sink { [weak self] in self?.scheduleRecompute() },
        ]
        return connection
    }

    /// Connects every machine (events only, until a pane is opened) and waits a few seconds for their models.
    func refresh(_ machines: [Machine]) async {
        let all = machines.map { connection(for: $0) }
        all.forEach { $0.connect() }
        for _ in 0..<60 {
            if all.allSatisfy({ $0.store.isConnected || { if case .reconnecting = $0.store.connection { return true } else { return false } }($0) }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        recompute()
    }

    // objectWillChange fires before the change lands, so read the models on the next turn.
    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        DispatchQueue.main.async { [weak self] in self?.recompute() }
    }

    private func recompute() {
        recomputeScheduled = false
        let rows = AgentRow.sorted(connections.values.flatMap(\.agentRows))
        if rows != agentRows { agentRows = rows }
    }

    func existing(_ id: UUID) -> MachineConnection? { connections[id] }

    /// Closes the machine's connection. A test-directory daemon goes with it, even with no connection open.
    func disconnect(_ machine: Machine) {
        if connections[machine.id] != nil {
            forget(machine.id)
        } else if machine.devDirs == true, machine.kind == .ssh {
            let ssh = SSHTransport(machine: machine)
            Task.detached {
                do { try ssh.removeDevDaemon() } catch { log("[\(machine.displayName)] \(error.localizedDescription)") }
            }
        }
    }

    func forget(_ id: UUID) {
        connections.removeValue(forKey: id)?.disconnect()
        watchers[id] = nil
        scheduleRecompute()
    }

    private var inBackground = false

    /// Connections with file transfers in flight stay open on the background time those get, and close
    /// when they finish or the time runs out.
    func suspendAll() {
        inBackground = true
        connections.values.filter { !TransferCenter.shared.isActive(on: $0.id) }.forEach { $0.suspend() }
        TransferCenter.shared.onIdle = { [weak self] id in
            guard let self, self.inBackground else { return }
            self.connections[id]?.suspend()
        }
    }

    func resumeAll() {
        inBackground = false
        connections.values.forEach { $0.resume() }
    }

    static func transport(for machine: Machine) -> ClothodTransport {
        switch machine.kind {
        case .localSocket:
            return UnixSocketTransport(socketPath: machine.socketPath ?? "")
        case .ssh:
            return SSHTransport(machine: machine)
        }
    }
}
