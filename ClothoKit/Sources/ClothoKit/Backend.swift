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
        /// `push.activity` / `push.activity_end`: Live Activity updates through the relay (docs/push.md, "Live Activities").
        case pushActivity = "push.activity"
        /// File access: `fs.*` and FILE_DATA streams (protocol.md, "Files").
        case fs
        /// `pane.clipboard` events: OSC 52 copies from a pane's application.
        case paneClipboard = "pane.clipboard"
        /// `agent.mute`: the user mutes an agent until unmuted or its session ends.
        case agentMute = "agent.mute"
        /// `pane.search`: search a pane's scrollback on the daemon (0.1.11).
        case paneSearch = "pane.search"
        /// `agent.history`: an agent's recorded transitions and messages (0.1.11).
        case agentHistory = "agent.history"
        /// `agent.decide` and the agent's `requests`: answer Claude's permission requests (0.1.13).
        case agentDecide = "agent.decide"
        /// `settings.get` / `settings.set` and `settings` events (clothod 0.1.7).
        case settings
        /// `service.status` / `install` / `uninstall` and `service` events: start clothod at login (0.1.7).
        case service
        /// `client.colors`: the client's terminal colours, which the daemon reports to apps that ask (OSC
        /// 10/11/12, OSC 4, mode 2031), so they draw for a light or dark background as shown (0.1.20).
        case clientColors = "client.colors"
        /// Panes come back after a restart, marked `restored`; `pane.dismiss_restored` clears the mark (0.1.21).
        case restore
        /// `workspace.move` and `tab.move`: reorder workspaces, reorder or move tabs (0.1.22).
        case move
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
    /// The pane's application set the clipboard (OSC 52), sent only to clients attached to the pane.
    /// `selection` is true for the primary selection (`p`/`s` targets), false for the clipboard.
    /// Applications can never read the clipboard.
    case clipboard(PaneID, text: String, selection: Bool)
    /// The machine's daemon settings changed (by any client).
    case settings(DaemonSettings)
    /// A client installed or removed the machine's login service.
    case service(DaemonService)

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

/// A pane's visible screen as plain text (`pane.text`): one string per row, trailing blanks trimmed.
public struct PaneText: Codable, Equatable, Sendable {
    public var lines: [String]
    public var cursorCol: Int
    public var cursorRow: Int
    public var cols: Int
    public var rows: Int
    /// The output position the text reflects.
    public var seq: UInt64

    public init(lines: [String], cursorCol: Int = 0, cursorRow: Int = 0, cols: Int, rows: Int, seq: UInt64 = 0) {
        self.lines = lines
        self.cursorCol = cursorCol
        self.cursorRow = cursorRow
        self.cols = cols
        self.rows = rows
        self.seq = seq
    }

    /// The lines joined, with trailing empty rows dropped.
    public var text: String {
        var lines = lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey { case lines, cursor, cols, rows, seq }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decode([String].self, forKey: .lines)
        let cursor = try c.decodeIfPresent([Int].self, forKey: .cursor) ?? []
        cursorCol = cursor.first ?? 0
        cursorRow = cursor.dropFirst().first ?? 0
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lines, forKey: .lines)
        try c.encode([cursorCol, cursorRow], forKey: .cursor)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(seq, forKey: .seq)
    }
}

public struct BackendError: Error, LocalizedError, Equatable, Sendable {
    /// One of the protocol's error codes, such as `not_found` or `spawn_failed`.
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// `agent.decide`'s "already answered": the request was answered (here or in the terminal),
    /// retired or never existed. Don't retry; say so.
    public var isStale: Bool { code == "stale" }

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

    /// Remembers the colours this client shows panes in and tells the daemon (`client.colors`), now and
    /// after every reconnect, when it announces `.clientColors`. Nil clears them. A requirement (not only
    /// an extension method) so calls through `SessionBackend` reach the backend's own.
    func setTerminalColors(_ colors: TerminalColors?)

    /// Clears a pane's `restored` mark on the daemon, for every client (`pane.dismiss_restored`), when hello's
    /// `features` contains `.restore`. The daemon also clears it on the pane's first typing.
    func dismissRestored(_ pane: PaneID) async throws

    /// Applies a move on the daemon (`workspace.move` or `tab.move`), when hello's `features` contains
    /// `.move`. The rules are `ModelState.moving`'s.
    func move(_ move: MoveRequest) async throws

    /// Acknowledges a pane's agent state (`agent.ack`), clearing its `attention`.
    func ackAgent(_ pane: PaneID) async throws

    /// Mutes or unmutes a pane's agent (`agent.mute`), when hello's `features` contains `.agentMute`.
    func muteAgent(_ pane: PaneID, muted: Bool) async throws

    /// The visible screen of a pane as plain text (`pane.text`), e.g. a preview for a pane this client
    /// never opened. Every clothod has it.
    func paneText(_ pane: PaneID) async throws -> PaneText

    /// Answers one of an agent's permission `requests` (`agent.decide`), when hello's `features` contains
    /// `.agentDecide`. `message` (deny only, at most 300 characters) is told to the agent. Fails with a
    /// `BackendError` whose `isStale` is true when the request was already answered or retired.
    func decide(pane: PaneID, request: String, decision: PermissionDecision, message: String?) async throws

    /// Searches the scrollback the daemon keeps for a pane (`pane.search`), newest match first, when hello's
    /// `features` contains `.paneSearch`. A bad regex or an empty query fails with `bad_request`.
    func searchPane(_ pane: PaneID, query: String, options: PaneSearchOptions) async throws -> PaneSearchResult

    /// An agent's recorded history (`agent.history`), oldest first, when hello's `features` contains
    /// `.agentHistory`. `since` (unix seconds) fetches only newer entries.
    func agentHistory(_ pane: PaneID, limit: Int?, since: Double?) async throws -> AgentHistory

    /// Pastes `text` (bracketed if the app enabled it), then presses `keys` ("enter", "esc", "tab", "up",
    /// "ctrl+c", "shift+tab", "f5"…), encoded by the daemon for the pane's current modes (`pane.keys`).
    /// Only when hello's `features` contains `.paneKeys`; never fall back to raw bytes.
    func sendKeys(_ pane: PaneID, text: String?, keys: [String]) async throws

    /// The daemon's machine-wide settings (`settings.get`), when hello's `features` contains `.settings`.
    func getSettings() async throws -> DaemonSettings
    /// Changes them (`settings.set`); only the fields given change. The reply is the new settings.
    func setSettings(_ change: DaemonSettings.Change) async throws -> DaemonSettings

    /// Start at login (`service.*`), when hello's `features` contains `.service`. Each returns the service
    /// as it is afterwards. Install is idempotent; uninstall never stops the daemon.
    func serviceStatus() async throws -> DaemonService
    func installService() async throws -> DaemonService
    func uninstallService() async throws -> DaemonService

    // Push alerts (docs/push.md), when hello's `features` contains `.push`.
    func pushRegister(_ registration: PushRegistration) async throws
    func pushUnregister(device: String) async throws
    func pushList() async throws -> [PushDevice]
    func pushTest(device: String) async throws

    // Live Activities (docs/push.md, "Live Activities"), when hello's `features` contains `.pushActivity`.
    /// Sends an activity's push token for `pane` to the machine, which then pushes the pane's agent to it.
    /// Replaces an earlier token for the same pane and device. `device` must be `push.register`ed
    /// (`not_found` otherwise); `token` is 64–200 hex characters; `env` defaults to the registration's.
    func pushActivity(pane: PaneID, device: String, token: String, env: String?) async throws
    /// Tells the machine to forget the pane's activity token. Nothing is sent: the app ends the activity.
    func pushActivityEnd(pane: PaneID, device: String) async throws
    /// The machine's live activity tokens, as `push.list` reports them (never the token).
    func pushActivities() async throws -> [PushActivity]
}

public extension SessionBackend {
    /// Drops the connection and reconnects at once (after sleep or a network change). A no-op for
    /// backends without a connection.
    func reconnectNow() {}

    /// Backends without a daemon have no apps to tell.
    func setTerminalColors(_ colors: TerminalColors?) {}

    func dismissRestored(_ pane: PaneID) async throws {
        throw BackendError(code: "unknown_method", message: "this backend doesn't restore panes")
    }

    func move(_ move: MoveRequest) async throws {
        throw BackendError(code: "unknown_method", message: "this backend can't move tabs or workspaces")
    }

    func ackAgent(_ pane: PaneID) async throws {}

    func muteAgent(_ pane: PaneID, muted: Bool) async throws {
        throw BackendError(code: "unknown_method", message: "this backend can't mute agents")
    }

    func searchPane(_ pane: PaneID, query: String, options: PaneSearchOptions) async throws -> PaneSearchResult {
        throw BackendError(code: "unknown_method", message: "this backend can't search scrollback")
    }

    func paneText(_ pane: PaneID) async throws -> PaneText {
        throw BackendError(code: "unknown_method", message: "this backend can't read a pane's text")
    }

    func decide(pane: PaneID, request: String, decision: PermissionDecision, message: String?) async throws {
        throw BackendError(code: "unknown_method", message: "this backend can't answer permission requests")
    }

    func agentHistory(_ pane: PaneID, limit: Int?, since: Double?) async throws -> AgentHistory {
        throw BackendError(code: "unknown_method", message: "this backend keeps no agent history")
    }

    func getSettings() async throws -> DaemonSettings {
        throw BackendError(code: "unknown_method", message: "this backend has no settings")
    }

    func setSettings(_ change: DaemonSettings.Change) async throws -> DaemonSettings {
        throw BackendError(code: "unknown_method", message: "this backend has no settings")
    }

    func serviceStatus() async throws -> DaemonService { throw Self.noService }
    func installService() async throws -> DaemonService { throw Self.noService }
    func uninstallService() async throws -> DaemonService { throw Self.noService }

    private static var noService: BackendError { BackendError(code: "unknown_method", message: "this backend can't start at login") }

    func sendKeys(_ pane: PaneID, text: String?, keys: [String]) async throws {
        throw BackendError(code: "unknown_method", message: "this backend can't send keys")
    }

    func pushRegister(_ registration: PushRegistration) async throws { throw Self.noPush }
    func pushUnregister(device: String) async throws { throw Self.noPush }
    func pushList() async throws -> [PushDevice] { throw Self.noPush }
    func pushTest(device: String) async throws { throw Self.noPush }
    func pushActivity(pane: PaneID, device: String, token: String, env: String?) async throws { throw Self.noActivities }
    func pushActivityEnd(pane: PaneID, device: String) async throws { throw Self.noActivities }
    func pushActivities() async throws -> [PushActivity] { throw Self.noActivities }

    private static var noPush: BackendError { BackendError(code: "unknown_method", message: "this backend has no push alerts") }
    private static var noActivities: BackendError { BackendError(code: "unknown_method", message: "this backend has no Live Activities") }

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

/// A Live Activity token a machine holds, as `push.list` reports it (never the token itself).
public struct PushActivity: Codable, Equatable, Sendable {
    public var pane: PaneID
    public var device: String
    public var created: Double?
    /// The last failure sending to it, if any.
    public var lastError: String?

    enum CodingKeys: String, CodingKey { case pane, device, created, lastError = "last_error" }

    public init(pane: PaneID, device: String, created: Double? = nil, lastError: String? = nil) {
        self.pane = pane
        self.device = device
        self.created = created
        self.lastError = lastError
    }
}

/// A machine's daemon settings (protocol.md, "Settings"). They live in the machine's clothod config file
/// and apply to every client.
public struct DaemonSettings: Codable, Equatable, Sendable {
    /// History kept per pane, for new panes and panes spawned without their own value.
    public var scrollbackLines: Int
    public var limits: Limits
    /// The config file that holds them.
    public var config: String?
    /// After a set: the panes whose scrollback changed.
    public var appliedPanes: [PaneID]?

    public struct Limits: Codable, Equatable, Sendable {
        public var scrollbackLines: Range

        enum CodingKeys: String, CodingKey { case scrollbackLines = "scrollback_lines" }
    }

    public struct Range: Codable, Equatable, Sendable {
        public var min: Int
        public var max: Int
        public var `default`: Int
    }

    /// The fields a `settings.set` changes; nil ones stay as they are.
    public struct Change: Equatable, Sendable {
        public var scrollbackLines: Int?
        public init(scrollbackLines: Int? = nil) { self.scrollbackLines = scrollbackLines }

        var params: [String: Any] {
            var params: [String: Any] = [:]
            if let scrollbackLines { params["scrollback_lines"] = scrollbackLines }
            return params
        }
    }

    public init(scrollbackLines: Int, limits: Limits, config: String? = nil, appliedPanes: [PaneID]? = nil) {
        self.scrollbackLines = scrollbackLines
        self.limits = limits
        self.config = config
        self.appliedPanes = appliedPanes
    }

    enum CodingKeys: String, CodingKey {
        case scrollbackLines = "scrollback_lines", limits, config, appliedPanes = "applied_panes"
    }
}

/// The machine's login service for clothod (protocol.md, "Start at login"): a launchd agent on macOS, a
/// systemd user unit on Linux. Only the user turns it on.
public struct DaemonService: Codable, Equatable, Sendable {
    /// False when the machine has no service manager to use; `message` says why.
    public var supported: Bool
    /// "launchd" or "systemd".
    public var manager: String?
    public var label: String?
    /// The unit file.
    public var file: String?
    /// Whether it's set to start at login: the toggle's state.
    public var installed: Bool
    /// Whether the service manager has it right now.
    public var loaded: Bool
    /// False while installed means installing again refreshes it.
    public var upToDate: Bool
    public var command: [String]?
    /// Linux: whether the user's services run without a login session (nil elsewhere).
    public var linger: Bool?
    /// What's missing before it can be installed, such as "linger".
    public var needs: [String]
    /// A message for the user (for example how to enable lingering), when there's something to say.
    public var message: String?

    public init(supported: Bool, manager: String? = nil, label: String? = nil, file: String? = nil, installed: Bool,
                loaded: Bool = false, upToDate: Bool = false, command: [String]? = nil, linger: Bool? = nil,
                needs: [String] = [], message: String? = nil) {
        self.supported = supported
        self.manager = manager
        self.label = label
        self.file = file
        self.installed = installed
        self.loaded = loaded
        self.upToDate = upToDate
        self.command = command
        self.linger = linger
        self.needs = needs
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        manager = try c.decodeIfPresent(String.self, forKey: .manager)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        upToDate = try c.decodeIfPresent(Bool.self, forKey: .upToDate) ?? false
        command = try c.decodeIfPresent([String].self, forKey: .command)
        linger = try c.decodeIfPresent(Bool.self, forKey: .linger)
        needs = try c.decodeIfPresent([String].self, forKey: .needs) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey {
        case supported, manager, label, file, installed, loaded, upToDate = "up_to_date", command, linger, needs, message
    }
}
