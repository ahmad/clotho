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
    let machine: Machine
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

    private var panes: [PaneID: PaneHostView] = [:]
    private var hostKeyObserver: NSObjectProtocol?
    private let transport: ClothodTransport

    var id: UUID { machine.id }

    init(machine: Machine, transport: ClothodTransport) {
        self.machine = machine
        self.transport = transport
        backend = ClothodBackend(configuration: .init(transport: transport, clientName: "clotho-ios/0.1",
                                                      log: { log("[\(machine.displayName)] \($0)") }))
        store = ModelStore(backend: backend)
        // Drop terminals for panes that left the model.
        store.onChange = { [weak self] in
            guard let self else { return }
            self.pruneTerminals()
            // The probe that ran before this connection compares the machine's clothod with the app's.
            let status = (self.transport as? SSHTransport)?.versionStatus ?? .current
            if status != self.versionStatus { self.versionStatus = status }
        }
        store.onAgentChange = { [weak self] pane, before, after in
            guard let self else { return }
            let title = self.store.state.location(of: pane).map { self.store.displayTitle(of: $0.tab) } ?? ""
            AgentNotifier.shared.agentChanged(machine: self.machine, pane: pane, title: title, before: before, after: after)
        }
        let id = machine.id
        hostKeyObserver = NotificationCenter.default.addObserver(forName: .hostKeyChanged, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["machine"] as? UUID == id,
                  let trusted = note.userInfo?["trusted"] as? String, let presented = note.userInfo?["presented"] as? String else { return }
            MainActor.assumeIsolated { self?.hostKeyChange = (trusted, presented) }
        }
    }

    deinit {
        if let hostKeyObserver { NotificationCenter.default.removeObserver(hostKeyObserver) }
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
                if let failure { self.lastError = "Restarting sessions failed: \(failure)" }
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
        panes[pane.id] = host
        return host
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
        if let existing = connections[machine.id], existing.machine.endpoint == machine.endpoint { return existing }
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

    func suspendAll() { connections.values.forEach { $0.suspend() } }
    func resumeAll() { connections.values.forEach { $0.resume() } }

    static func transport(for machine: Machine) -> ClothodTransport {
        switch machine.kind {
        case .localSocket:
            return UnixSocketTransport(socketPath: machine.socketPath ?? "")
        case .ssh:
            return SSHTransport(machine: machine)
        }
    }
}
