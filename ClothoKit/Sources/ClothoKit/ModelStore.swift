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
    /// An agent changed state: the pane, its previous info and its new one.
    public var onAgentChange: ((PaneID, AgentInfo?, AgentInfo?) -> Void)?

    private var sinks: [PaneID: WeakSink] = [:]
    private var task: Task<Void, Never>?

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

    public func stop() {
        task?.cancel()
        task = nil
        backend.stop()
    }

    public func register(_ sink: PaneDataSink, for pane: PaneID) { sinks[pane] = WeakSink(sink) }
    public func unregister(_ pane: PaneID) { sinks[pane] = nil }

    func apply(_ event: SessionEvent) {
        switch event {
        case .connected(let newHello):
            // A new holder means new shells; pane IDs may be reused, so every sink starts over.
            if let hello, hello.instance != newHello.instance {
                sinks.values.forEach { $0.sink?.paneReset() }
            }
            hello = newHello
            connection = .connected
            onChange?()
        case .disconnected(let reason):
            connection = .reconnecting(reason)
            onChange?()
        case .progress(let step):
            connection = .connecting(step)
            onChange?()
        case .state(let newState):
            state = newState
            onChange?()
        case .pane(let pane, let rev):
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
