import Foundation

// The interface the UI talks to. Method and event names follow docs/protocol.md one to one, so the
// clothod client (M5) and FakeBackend are interchangeable behind it.

/// Spawn options shared by every command that creates a pane. Nil fields take the daemon's defaults.
public struct SpawnOptions: Codable, Equatable, Sendable {
    public var command: [String]?
    public var cwd: String?
    public var env: [String: String]?
    public var cols: Int?
    public var rows: Int?

    public init(command: [String]? = nil, cwd: String? = nil, env: [String: String]? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.command = command
        self.cwd = cwd
        self.env = env
        self.cols = cols
        self.rows = rows
    }
}

public struct Size: Codable, Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// The `hello` reply.
public struct Hello: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        public var hostname: String
        public var os: String
        public var arch: String
        /// The expanded home directory (clothod 0.1.3+), for file browser breadcrumbs.
        public var home: String?

        public init(hostname: String, os: String, arch: String, home: String? = nil) {
            self.hostname = hostname
            self.os = os
            self.arch = arch
            self.home = home
        }
    }

    public var `protocol`: Int
    /// The range of protocol versions the daemon accepts.
    public var protocolMin: Int?
    public var protocolMax: Int?
    public var daemon: String
    public var version: String
    /// The PTY holder's lifetime. When it changes, every cached seq and pane state is invalid.
    public var instance: String
    public var pid: Int32?
    public var machine: Machine?
    /// Optional methods and behaviors the daemon announces (`features`; none when absent). Names this
    /// client doesn't know are kept in `featureNames` and otherwise ignored.
    public var featureNames: [String]?
    public var features: Set<Feature> { Set((featureNames ?? []).compactMap(Feature.init(rawValue:))) }

    public enum Feature: String, Sendable {
        /// `pane.keys`: text and named keys, encoded for the pane's current modes.
        case paneKeys = "pane.keys"
        case agents
        case agentReportPid = "agent.report.pid"
        case ping
        case splitSetRatio = "split.set_ratio"
        /// Push alerts to phones through a relay (docs/push.md).
        case push
        /// File access: `fs.*` and FILE_DATA streams (protocol.md, "Files").
        case fs
    }

    /// The daemon's executable. After an upgrade it can differ from the holder's.
    public var exe: String?
    /// The daemon's install id (`<version>-<hash>`).
    public var build: String?
    public var holder: Holder?
    /// A legacy holder that can't be upgraded in place: finishing an update means restarting the machine's
    /// sessions (`shutdown` + `start`, which ends their shells), only ever with the user's OK.
    public var holderOutdated: Bool?

    public struct Holder: Codable, Equatable, Sendable {
        public var pid: Int32?
        public var version: String?
        public var `protocol`: Int?
        public var exe: String?
        public var build: String?
        public var canUpgrade: Bool?
        public var outdated: Bool?

        enum CodingKeys: String, CodingKey {
            case pid, version, `protocol`, exe, build, canUpgrade = "can_upgrade", outdated
        }
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`, protocolMin = "protocol_min", protocolMax = "protocol_max", daemon, version, instance, pid, machine, exe, holder
        case build, holderOutdated = "holder_outdated"
        case featureNames = "features"
    }

    public init(protocol: Int, protocolMin: Int? = nil, protocolMax: Int? = nil, daemon: String, version: String, instance: String, pid: Int32? = nil, machine: Machine? = nil) {
        self.protocol = `protocol`
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.daemon = daemon
        self.version = version
        self.instance = instance
        self.pid = pid
        self.machine = machine
    }
}

public struct CreatedWorkspace: Codable, Equatable, Sendable {
    public var workspace: WorkspaceID
    public var tab: TabID
    public var pane: PaneID

    public init(workspace: WorkspaceID, tab: TabID, pane: PaneID) {
        self.workspace = workspace
        self.tab = tab
        self.pane = pane
    }
}

public struct CreatedTab: Codable, Equatable, Sendable {
    public var tab: TabID
    public var pane: PaneID

    public init(tab: TabID, pane: PaneID) {
        self.tab = tab
        self.pane = pane
    }
}

public struct CreatedSplit: Codable, Equatable, Sendable {
    public var pane: PaneID
    public var split: SplitID

    public init(pane: PaneID, split: SplitID) {
        self.pane = pane
        self.split = split
    }
}

/// The `pane.subscribe` reply. `seq` is where the stream continues; `cols`/`rows` is the pane's current size.
public struct Subscription: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Nothing missed; live OUTPUT follows.
        case live
        /// OUTPUT frames from the requested `have_seq` follow, then live output.
        case replay
        /// One SNAPSHOT at `seq` follows, then live OUTPUT.
        case snapshot
    }

    public var mode: Mode
    public var seq: UInt64
    public var cols: Int
    public var rows: Int

    public init(mode: Mode, seq: UInt64, cols: Int, rows: Int) {
        self.mode = mode
        self.seq = seq
        self.cols = cols
        self.rows = rows
    }
}

public enum FocusTarget: Equatable, Sendable {
    case pane(PaneID)
    case tab(TabID)
    case workspace(WorkspaceID)
}

/// Everything a backend delivers, in the order the daemon produced it.
public enum SessionEvent: Sendable {
    /// `hello` succeeded; a changed `instance` means drop all pane state.
    case connected(Hello)
    /// The connection dropped (or an attempt failed); the backend keeps reconnecting on its own and sends
    /// `connected` again.
    case disconnected(String)
    /// A step on the way to connecting, such as "Connecting" or "Installing clothod".
    case progress(String)

    // Model events (after `events.subscribe`).
    /// Replaces the whole model.
    case state(ModelState)
    /// Replaces one pane.
    case pane(Pane, rev: UInt64)
    case bell(PaneID)

    // A pane's data stream (only for subscribed panes), in order.
    /// The `pane.subscribe` reply, delivered in stream order ahead of the pane's first frame.
    case subscribed(PaneID, Subscription)
    /// Bytes covering `[seq, seq + bytes.count)`.
    case output(PaneID, seq: UInt64, bytes: Data)
    /// Terminal state after exactly `seq` bytes, at `cols`×`rows`. Starts with a full reset.
    case snapshot(PaneID, seq: UInt64, cols: Int, rows: Int, bytes: Data)
    /// The PTY size changed at `seq`; later bytes were produced at the new size.
    case resized(PaneID, cols: Int, rows: Int, seq: UInt64)
    /// The client fell behind; a SNAPSHOT follows.
    case resync(PaneID)

    /// An agent in a pane changed state (nil: it went away). The pane in `state` carries it too.
    case agent(PaneID, AgentInfo?)
}

public struct BackendError: Error, LocalizedError, Equatable, Sendable {
    /// One of the protocol's error codes, such as `not_found` or `spawn_failed`.
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public protocol SessionBackend: AnyObject, Sendable {
    /// Every event, in order. There is one stream per backend; consume it once.
    var events: AsyncStream<SessionEvent> { get }

    /// Connects (`hello`, then `events.subscribe`), which leads to `connected` and `state` events.
    func start() async throws
    func stop()
    /// Drops the connection and reconnects at once, resuming every pane.
    func reconnectNow()

    /// The whole model (`state.get`).
    func getState() async throws -> ModelState

    func createWorkspace(name: String?, spawn: SpawnOptions) async throws -> CreatedWorkspace
    func renameWorkspace(_ workspace: WorkspaceID, name: String) async throws
    func closeWorkspace(_ workspace: WorkspaceID) async throws

    func createTab(in workspace: WorkspaceID, spawn: SpawnOptions) async throws -> CreatedTab
    /// Nil clears the title, so the tab shows its active pane's title.
    func renameTab(_ tab: TabID, title: String?) async throws
    func closeTab(_ tab: TabID) async throws

    func split(_ pane: PaneID, direction: Direction, ratio: Double?, spawn: SpawnOptions) async throws -> CreatedSplit
    func closePane(_ pane: PaneID) async throws
    func setRatio(_ split: SplitID, ratio: Double) async throws
    func focus(_ target: FocusTarget) async throws

    /// Starts (or restarts) the pane's data stream. `haveSeq` resumes from a seq already applied.
    @discardableResult
    func subscribe(_ pane: PaneID, haveSeq: UInt64?, scrollback: Int?, viewport: Size?) async throws -> Subscription
    func unsubscribe(_ pane: PaneID) async throws
    /// The size this client can show the pane at; the daemon decides the PTY size.
    func setViewport(_ pane: PaneID, _ size: Size) async throws
    /// Forces the PTY size.
    func resize(_ pane: PaneID, _ size: Size) async throws

    /// Keys, paste, mouse and focus reports. Never the local emulator's automatic replies.
    func sendInput(_ pane: PaneID, _ bytes: Data)

    /// Acknowledges a pane's agent state (`agent.ack`), clearing its `attention`.
    func ackAgent(_ pane: PaneID) async throws

    /// Pastes `text` (bracketed if the app enabled it), then presses `keys` ("enter", "esc", "tab", "up",
    /// "ctrl+c", "shift+tab", "f5"…), encoded by the daemon for the pane's current modes (`pane.keys`).
    /// Only when hello's `features` contains `.paneKeys`; never fall back to raw bytes.
    func sendKeys(_ pane: PaneID, text: String?, keys: [String]) async throws

    // Push alerts (docs/push.md), when hello's `features` contains `.push`.
    func pushRegister(_ registration: PushRegistration) async throws
    func pushUnregister(device: String) async throws
    func pushList() async throws -> [PushDevice]
    func pushTest(device: String) async throws
}

public extension SessionBackend {
    /// Drops the connection and reconnects at once (after sleep or a network change). A no-op for
    /// backends without a connection.
    func reconnectNow() {}

    func ackAgent(_ pane: PaneID) async throws {}

    func sendKeys(_ pane: PaneID, text: String?, keys: [String]) async throws {
        throw BackendError(code: "unknown_method", message: "this backend can't send keys")
    }

    func pushRegister(_ registration: PushRegistration) async throws { throw Self.noPush }
    func pushUnregister(device: String) async throws { throw Self.noPush }
    func pushList() async throws -> [PushDevice] { throw Self.noPush }
    func pushTest(device: String) async throws { throw Self.noPush }

    private static var noPush: BackendError { BackendError(code: "unknown_method", message: "this backend has no push alerts") }

    func createWorkspace(name: String? = nil) async throws -> CreatedWorkspace {
        try await createWorkspace(name: name, spawn: SpawnOptions())
    }

    func createTab(in workspace: WorkspaceID) async throws -> CreatedTab {
        try await createTab(in: workspace, spawn: SpawnOptions())
    }

    func split(_ pane: PaneID, direction: Direction, spawn: SpawnOptions = SpawnOptions()) async throws -> CreatedSplit {
        try await split(pane, direction: direction, ratio: nil, spawn: spawn)
    }
}

/// A phone's registration for push alerts from this machine (`push.register`).
public struct PushRegistration: Codable, Equatable, Sendable {
    /// A stable id the phone chose.
    public var device: String
    /// The relay's opaque handle for the phone.
    public var handle: String
    /// The phone's X25519 public key, base64.
    public var key: String
    /// The app's own id for this machine, echoed back in payloads.
    public var label: String
    /// The relay's URL.
    public var relay: String
    /// "sandbox" or "production".
    public var env: String

    public init(device: String, handle: String, key: String, label: String, relay: String, env: String) {
        self.device = device
        self.handle = handle
        self.key = key
        self.label = label
        self.relay = relay
        self.env = env
    }
}

/// A registered phone as `push.list` reports it (never its handle or key).
public struct PushDevice: Codable, Equatable, Sendable {
    public var device: String
    public var label: String
    public var relay: String
    public var env: String
    public var created: Double?
    public var lastError: String?

    enum CodingKeys: String, CodingKey { case device, label, relay, env, created, lastError = "last_error" }

    public init(device: String, label: String, relay: String, env: String, created: Double? = nil, lastError: String? = nil) {
        self.device = device
        self.label = label
        self.relay = relay
        self.env = env
        self.created = created
        self.lastError = lastError
    }
}
