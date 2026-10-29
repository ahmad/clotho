import Combine
import Foundation

/// Receives one pane's data stream, in order. Implemented by the view that shows the pane.
@MainActor
public protocol PaneDataSink: AnyObject {
    func paneSubscribed(_ subscription: Subscription)
    func paneOutput(seq: UInt64, bytes: Data)
    func paneSnapshot(seq: UInt64, cols: Int, rows: Int, bytes: Data)
    func paneResized(cols: Int, rows: Int, seq: UInt64)
    func paneResync()
    /// The daemon's `instance` changed, so any seq the sink holds is meaningless.
    func paneReset()
    /// The pane's application set the clipboard (OSC 52); see `SessionEvent.clipboard`. Only sinks
    /// get it, so only panes a client shows can set the clipboard. Does nothing unless implemented.
    func paneClipboard(text: String, selection: Bool)
}

public extension PaneDataSink {
    func paneClipboard(text: String, selection: Bool) {}
}

/// Where a backend's connection stands, for showing next to a machine.
public enum ConnectionState: Equatable, Sendable {
    /// Not started yet.
    case idle
    /// Working toward a connection; the text names the step ("Connecting", "Installing clothod").
    case connecting(String)
    case connected
    /// Was connected (or tried) and is retrying; the text is the last error.
    case reconnecting(String)

    public var isConnected: Bool { self == .connected }
}

/// Mirrors the daemon's model by applying a backend's events, and routes pane data to sinks.
@MainActor
public final class ModelStore: ObservableObject {
    public let backend: SessionBackend
    @Published public private(set) var state = ModelState()
    @Published public private(set) var hello: Hello?
    @Published public private(set) var connection = ConnectionState.idle
    public var isConnected: Bool { connection.isConnected }
    /// Called for every model change, after `state` is updated (AppKit observers that don't use Combine).
    public var onChange: (() -> Void)?
    public var onBell: ((PaneID) -> Void)?
    /// The daemon's settings as of its last `settings` event (fetch them first with `backend.getSettings()`).
    @Published public private(set) var settings: DaemonSettings?
    /// The machine's settings changed, from any client.
    public var onSettings: ((DaemonSettings) -> Void)?
    /// The machine's login service as last fetched or announced (`loadService()`, `service` events).
    @Published public private(set) var service: DaemonService?
    public var onService: ((DaemonService) -> Void)?
    /// An agent changed state: the pane, its previous info and its new one.
    public var onAgentChange: ((PaneID, AgentInfo?, AgentInfo?) -> Void)?

    /// Whether `state` is the live model, or a saved one shown until the daemon sends its own.
    public enum Phase: Equatable, Sendable { case saved, live }
    @Published public private(set) var phase = Phase.live
    public var isSaved: Bool { phase == .saved }
    /// What `restore` loaded, while `phase` is `.saved`.
    public private(set) var saved: CachedMachineState?
    /// When the connection last dropped; nil while it's up or before it ever was.
    private var lostAt: Date?

    private var sinks: [PaneID: WeakSink] = [:]
    private var task: Task<Void, Never>?

    /// A focus shown before the daemon confirmed it (`focus(_:)`): re-applied to the daemon's states until
    /// one has it, the request fails, or `until` passes.
    private var localFocus: (target: FocusTarget, focus: Focus, until: Date)?
    /// The daemon's own focus and active tabs, to go back to when a focus request fails.
    private var daemonFocus: (focus: Focus, activeTabs: [WorkspaceID: TabID?])?
    /// How long a local focus waits for the daemon; after a successful reply, `localFocusGrace`.
    public static var localFocusTimeout: TimeInterval = 3
    public static var localFocusGrace: TimeInterval = 0.5

    /// Moves shown before the daemon confirmed them (`move(_:)`), oldest first: re-applied to the daemon's
    /// states until their reply plus `localFocusGrace`, or `localFocusTimeout`. Re-applying a move the daemon
    /// already made changes nothing, so a state with it in is safe to apply it to again.
    private var localMoves: [(id: Int, move: MoveRequest, until: Date)] = []
    private var nextLocalMove = 0
    /// The daemon's latest state, before local moves and focus: what a refused move goes back to.
    private var daemonState: ModelState?

    public init(backend: SessionBackend) {
        self.backend = backend
    }

    /// Starts consuming events and connects the backend.
    public func start() async throws {
        if task == nil {
            let events = backend.events
            task = Task { [weak self] in
                for await event in events {
                    self?.apply(event)
                }
            }
        }
        try await backend.start()
    }

    /// Fetches the daemon's settings into `settings` (events keep them current afterwards).
    @discardableResult
    public func loadSettings() async throws -> DaemonSettings {
        let loaded = try await backend.getSettings()
        settings = loaded
        return loaded
    }

    /// Changes the daemon's settings and keeps `settings` in step with the reply.
    @discardableResult
    public func changeSettings(_ change: DaemonSettings.Change) async throws -> DaemonSettings {
        let changed = try await backend.setSettings(change)
        settings = changed
        return changed
    }

    /// Fetches the login service's status into `service`.
    @discardableResult
    public func loadService() async throws -> DaemonService {
        let loaded = try await backend.serviceStatus()
        service = loaded
        return loaded
    }

    /// Turns start at login on or off, and keeps `service` in step with the reply.
    @discardableResult
    public func setStartsAtLogin(_ on: Bool) async throws -> DaemonService {
        let result = try await (on ? backend.installService() : backend.uninstallService())
        service = result
        return result
    }

    public func stop() {
        task?.cancel()
        task = nil
        backend.stop()
    }

    // MARK: Saved state

    /// Shows a saved model until the daemon's arrives: `state` becomes the saved one and `phase`
    /// `.saved`. The first `state` from the daemon replaces it whole (no merge) and makes it `.live`,
    /// without `onAgentChange` calls, as on any first load. Ignored once live data has arrived, and for
    /// caches of another format.
    public func restore(_ cached: CachedMachineState) {
        guard cached.format == CachedMachineState.currentFormat, phase == .saved || state.rev == 0 && state.workspaces.isEmpty else { return }
        saved = cached
        state = cached.state
        phase = .saved
        onChange?()
    }

    /// The model to save: the live one with `lastSeen` now (or when the connection dropped), or, while
    /// still showing a saved one, that one unchanged.
    public func cacheSnapshot(now: Date = Date()) -> CachedMachineState {
        if phase == .saved, let saved { return saved }
        return CachedMachineState(state: state, lastSeen: isConnected ? now : (lostAt ?? now), daemonVersion: hello?.version,
                                  instance: hello?.instance, featureNames: hello?.featureNames ?? [])
    }

    /// The daemon's features: live once connected, else those saved with the model.
    public var features: Set<Hello.Feature> { hello?.features ?? saved?.features ?? [] }

    // MARK: Focus

    /// Focuses `target` now, in `state` (by the daemon's rules, `ModelState.focusing`), and in the daemon.
    /// A click shows on the frame it happens in rather than after a round trip; the daemon's state then
    /// confirms it. States that arrive before the daemon has it (older changes, still in flight) keep the
    /// local focus. If the daemon refuses, the daemon's focus comes back and the error is thrown.
    public func focus(_ target: FocusTarget) async throws {
        showFocus(target)
        try await sendFocus(target)
    }

    /// The local half of `focus(_:)`: `state` shows the focus at once (synchronously, with `onChange`).
    /// Follow it with `sendFocus(_:)`. Returns whether the target is in the model.
    @discardableResult
    public func showFocus(_ target: FocusTarget) -> Bool {
        guard phase == .live, let shown = state.focusing(target) else { return false }
        if localFocus == nil { daemonFocus = (state.focus, Self.activeTabs(state)) }
        localFocus = (target, shown.focus, Date().addingTimeInterval(Self.localFocusTimeout))
        if shown != state {
            state = shown
            onChange?()
        }
        return true
    }

    /// The daemon's half of `focus(_:)`.
    public func sendFocus(_ target: FocusTarget) async throws {
        do {
            try await backend.focus(target)
            // The daemon has it. Its state may already be here (then this was cleared), or be on its way.
            if let local = localFocus, local.target == target {
                localFocus!.until = min(local.until, Date().addingTimeInterval(Self.localFocusGrace))
            }
        } catch {
            if let local = localFocus, local.target == target {
                localFocus = nil
                if let daemon = daemonFocus {
                    state.focus = daemon.focus
                    for (index, workspace) in state.workspaces.enumerated() {
                        if let tab = daemon.activeTabs[workspace.id] { state.workspaces[index].activeTab = tab }
                    }
                    onChange?()
                }
            }
            throw error
        }
    }

    // MARK: Moves

    /// Moves a workspace or tab now, in `state` (by the daemon's rules, `ModelState.moving`), and in the
    /// daemon: a drop shows on the frame it happens in. States that arrive before the daemon has it keep
    /// the move. If the daemon refuses, the daemon's state comes back and the error is thrown.
    public func move(_ move: MoveRequest) async throws {
        guard let id = showMove(move) else { throw BackendError(code: "not_found", message: "nothing to move: \(move)") }
        try await sendMove(move, id: id)
    }

    /// The local half of `move(_:)`: `state` shows it at once (with `onChange`). Returns its id for
    /// `sendMove`, or nil when it isn't in the model.
    @discardableResult
    public func showMove(_ move: MoveRequest) -> Int? {
        guard phase == .live, let moved = state.moving(move) else { return nil }
        nextLocalMove += 1
        localMoves.append((nextLocalMove, move, Date().addingTimeInterval(Self.localFocusTimeout)))
        if moved != state {
            state = moved
            onChange?()
        }
        return nextLocalMove
    }

    /// The daemon's half of `move(_:)`.
    public func sendMove(_ move: MoveRequest, id: Int) async throws {
        do {
            try await backend.move(move)
            if let index = localMoves.firstIndex(where: { $0.id == id }) {
                localMoves[index].until = min(localMoves[index].until, Date().addingTimeInterval(Self.localFocusGrace))
            }
        } catch {
            localMoves.removeAll { $0.id == id }
            if var shown = daemonState {
                for local in localMoves { shown = shown.moving(local.move) ?? shown }
                if let local = localFocus, let focused = shown.focusing(local.target) { shown = focused }
                state = shown
                onChange?()
            }
            throw error
        }
    }

    /// Whether a move is shown that the daemon hasn't confirmed yet.
    public var isMoveLocal: Bool { !localMoves.isEmpty }

    /// Whether `state.focus` is a local one the daemon hasn't confirmed yet.
    public var isFocusLocal: Bool { localFocus != nil }

    private static func activeTabs(_ state: ModelState) -> [WorkspaceID: TabID?] {
        Dictionary(state.workspaces.map { ($0.id, $0.activeTab) }, uniquingKeysWith: { a, _ in a })
    }

    public func register(_ sink: PaneDataSink, for pane: PaneID) { sinks[pane] = WeakSink(sink) }
    public func unregister(_ pane: PaneID) { sinks[pane] = nil }

    func apply(_ event: SessionEvent) {
        switch event {
        case .connected(let newHello):
            // A new holder means new shells; pane IDs may be reused, so every sink starts over. That
            // includes panes shown from a saved model of another instance.
            if let previous = hello?.instance ?? (phase == .saved ? saved?.instance : nil), previous != newHello.instance {
                sinks.values.forEach { $0.sink?.paneReset() }
            }
            hello = newHello
            connection = .connected
            lostAt = nil
            onChange?()
        case .disconnected(let reason):
            if connection.isConnected { lostAt = Date() }
            localFocus = nil
            localMoves.removeAll()
            connection = .reconnecting(reason)
            onChange?()
        case .progress(let step):
            connection = .connecting(step)
            onChange?()
        case .state(var newState):
            daemonState = newState
            let now = Date()
            localMoves.removeAll { now >= $0.until }
            for local in localMoves { newState = newState.moving(local.move) ?? newState }
            if let local = localFocus {
                daemonFocus = (newState.focus, Self.activeTabs(newState))
                if newState.focus == local.focus || Date() >= local.until {
                    localFocus = nil
                } else if let shown = newState.focusing(local.target) {
                    newState = shown
                } else {
                    localFocus = nil
                }
            }
            state = newState
            if phase == .saved {
                phase = .live
                saved = nil
            }
            onChange?()
        case .pane(let pane, let rev):
            // While a saved model shows, changes to the live one it doesn't have yet are dropped: the
            // daemon's whole state follows.
            guard phase == .live else { return }
            if let index = state.panes.firstIndex(where: { $0.id == pane.id }) {
                let before = state.panes[index].agent
                state.panes[index] = pane
                if before != pane.agent { onAgentChange?(pane.id, before, pane.agent) }
            } else {
                state.panes.append(pane)
            }
            state.rev = max(state.rev, rev)
            onChange?()
        case .bell(let pane):
            onBell?(pane)
        case .settings(let new):
            settings = new
            onSettings?(new)
        case .service(let new):
            service = new
            onService?(new)
        case .clipboard(let pane, let text, let selection):
            sinks[pane]?.sink?.paneClipboard(text: text, selection: selection)
        case .subscribed(let pane, let subscription):
            sinks[pane]?.sink?.paneSubscribed(subscription)
        case .output(let pane, let seq, let bytes):
            sinks[pane]?.sink?.paneOutput(seq: seq, bytes: bytes)
        case .snapshot(let pane, let seq, let cols, let rows, let bytes):
            sinks[pane]?.sink?.paneSnapshot(seq: seq, cols: cols, rows: rows, bytes: bytes)
        case .resized(let pane, let cols, let rows, let seq):
            sinks[pane]?.sink?.paneResized(cols: cols, rows: rows, seq: seq)
        case .resync(let pane):
            sinks[pane]?.sink?.paneResync()
        case .agent(let pane, let agent):
            guard phase == .live else { return }
            guard let index = state.panes.firstIndex(where: { $0.id == pane }), state.panes[index].agent != agent else { return }
            let before = state.panes[index].agent
            state.panes[index].agent = agent
            onAgentChange?(pane, before, agent)
            onChange?()
        }
    }

    // MARK: Lookups

    public var focusedWorkspace: Workspace? { state.workspace(state.focus.workspace) ?? state.workspaces.first }

    public var focusedTab: Tab? {
        guard let workspace = focusedWorkspace else { return nil }
        return workspace.tabs.first { $0.id == state.focus.tab } ?? workspace.tabs.first
    }

    public var focusedPane: Pane? {
        guard let tab = focusedTab else { return nil }
        let id = tab.layout.contains(state.focus.pane ?? 0) ? state.focus.pane : tab.activePane
        return state.pane(id)
    }

    /// A tab's display name: its title, or else its active pane's title or folder.
    public func displayTitle(of tab: Tab) -> String {
        if let title = tab.title, !title.isEmpty { return title }
        let pane = state.pane(tab.activePane)
        if let title = pane?.displayTitle { return title }
        if let cwd = pane?.cwd { return (cwd as NSString).lastPathComponent }
        return "Shell"
    }
}

private struct WeakSink {
    weak var sink: PaneDataSink?
    init(_ sink: PaneDataSink) { self.sink = sink }
}
