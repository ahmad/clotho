import Darwin
import Foundation

/// The real backend: a client for clothod's protocol (docs/protocol.md) over a transport (the local
/// Unix socket, or `clothod bridge` over SSH).
///
/// One connection carries requests, replies, events and the data of subscribed panes. If it drops,
/// the backend reconnects on its own (the transport starts or installs the daemon if needed), checks
/// `instance`, and resubscribes every pane it was showing with the seq it had reached, so the daemon
/// replays what was missed or sends a snapshot.
public final class ClothodBackend: SessionBackend, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var transport: ClothodTransport
        public var clientName: String
        /// Connection lifecycle messages, for the app's log.
        public var log: (@Sendable (String) -> Void)?
        /// One line per OUTPUT, SNAPSHOT and INPUT frame (pane, seq, length), for chasing stray input.
        public var trace: (@Sendable (String) -> Void)?

        public init(transport: ClothodTransport, clientName: String = "clotho", log: (@Sendable (String) -> Void)? = nil) {
            self.transport = transport
            self.clientName = clientName
            self.log = log
        }

        /// The local daemon's socket, starting the daemon with `startDaemon` when it isn't running.
        public init(socketPath: String = ClothodBackend.defaultSocketPath(), clientName: String = "clotho",
                    log: (@Sendable (String) -> Void)? = nil, startDaemon: (@Sendable () throws -> Void)? = nil) {
            self.init(transport: UnixSocketTransport(socketPath: socketPath, startDaemon: startDaemon), clientName: clientName, log: log)
        }
    }

    public static let protocolVersion = 1
    static let maxFrame = 16 << 20

    enum FrameType: UInt8 {
        case json = 1, output = 2, input = 3, snapshot = 4, fileData = 5
    }

    /// Where clothod listens: `$CLOTHOD_RUNTIME_DIR/clothod.sock`, else `$TMPDIR/clothod/clothod.sock`,
    /// falling back to `/tmp/clothod-<uid>/` when that path is too long for a socket (as clothod does).
    public static func defaultSocketPath(runtimeDir: String? = nil) -> String {
        let env = ProcessInfo.processInfo.environment
        if let dir = runtimeDir ?? env["CLOTHOD_RUNTIME_DIR"] { return (dir as NSString).appendingPathComponent("clothod.sock") }
        let tmp = env["TMPDIR"] ?? NSTemporaryDirectory()
        let path = ((tmp as NSString).appendingPathComponent("clothod") as NSString).appendingPathComponent("clothod.sock")
        if path.utf8.count < 100 { return path }
        return "/tmp/clothod-\(getuid())/clothod.sock"
    }

    public let configuration: Configuration
    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    // Guarded by `lock`.
    private let lock = NSLock()
    private var connection: ByteStream?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var instance: String?
    private var stopped = false
    private var reconnecting = false
    /// Panes this client shows, with what it asked for, so a reconnect can resubscribe them.
    private var subscriptions: [PaneID: (scrollback: Int?, viewport: Size?)] = [:]
    /// How far each subscribed pane's stream has been delivered.
    private var deliveredSeq: [PaneID: UInt64] = [:]

    /// Open fs.read/fs.write streams by daemon stream id (ClothodFiles.swift).
    var fileStreams: [UInt64: FileStream] = [:]
    /// Run on the read thread with a request's result, before its caller resumes, so a stream is
    /// registered before any of its frames are handled.
    private var replyHooks: [Int: (Any) -> Void] = [:]
    /// The latest hello, for `supportsFiles` and `homeDirectory`.
    var lastHello: Hello?

    private let writeQueue = DispatchQueue(label: "clotho.clothod.write")

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    deinit { stop() }

    // MARK: Lifecycle

    public func start() async throws {
        locked { stopped = false }
        do {
            try await connect()
        } catch {
            // The first attempt failed: report it, and keep trying in the background like any reconnect.
            let retry: Bool = locked {
                guard !stopped, !reconnecting else { return false }
                reconnecting = true
                return true
            }
            if retry { Task { await reconnectLoop() } }
            throw error
        }
    }

    public func stop() {
        let (connection, waiting): (ByteStream?, [CheckedContinuation<Any, Error>]) = locked {
            stopped = true
            defer {
                self.connection = nil
                pending.removeAll()
                subscribeRequests.removeAll()
                replyHooks.removeAll()
            }
            return (self.connection, Array(pending.values))
        }
        connection?.close()
        // Requests in flight would otherwise wait forever: the closed connection is no longer current.
        waiting.forEach { $0.resume(throwing: BackendError(code: "disconnected", message: "the backend was stopped")) }
        failFileStreams(BackendError(code: "disconnected", message: "the backend was stopped"))
    }

    /// Drops the current connection and reconnects right away, skipping any backoff wait. For after
    /// sleep or a network change, when a remote link is likely dead but hasn't timed out yet.
    public func reconnectNow() {
        let current: ByteStream? = locked {
            skipBackoff = true
            return connection
        }
        current?.close()
    }

    /// A file stream that the daemon owes data, acks or fs.done for this long fails with `stalled`
    /// and drops the connection (0 turns it off).
    public var fileStallTimeout: TimeInterval {
        get { locked { _fileStallTimeout } }
        set { locked { _fileStallTimeout = newValue } }
    }
    private var _fileStallTimeout: TimeInterval = 60

    private var skipBackoff = false
    private var lastReceived = Date.distantPast

    /// A link can stall silently (a sleeping network, a wedged SSH connection), so when nothing has
    /// arrived for `interval`, ping; if no reply comes in twice that, drop the connection, which starts a
    /// reconnect. Over SSH that's 15 s and 30 s (clothod's recommendation).
    private func startHeartbeat(for stream: ByteStream, every interval: TimeInterval) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, self.locked({ self.connection === stream }) else { return }
                let quiet = Date().timeIntervalSince(self.locked { self.lastReceived })
                guard quiet >= interval else { continue }
                // clothod writes replies ahead of file data, so a busy transfer doesn't delay the answer.
                let answered = await self.answersWithin(interval * 2) { try await self.ping() }
                guard self.locked({ self.connection === stream }) else { return }
                if !answered {
                    self.configuration.log?("no answer from \(self.configuration.transport.name) in \(Int(interval * 2)) s; reconnecting")
                    stream.close()
                    return
                }
            }
        }
    }

    /// `ping`, or `state.get` from daemons that predate it.
    private func ping() async throws -> Any {
        do {
            return try await request("ping", nil)
        } catch let error as BackendError where error.code == "unknown_method" {
            return try await request("state.get", nil)
        }
    }

    private func answersWithin(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> Any) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await operation()) != nil }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func connect() async throws {
        let transport = configuration.transport
        let continuation = continuation
        // Opening may block (starting a daemon, running ssh, installing), so it runs off the caller's thread.
        let stream = try await Task.detached {
            try transport.open(progress: { continuation.yield(.progress($0)) })
        }.value
        locked {
            self.connection = stream
            lastReceived = Date()
        }
        let parser = FrameParser()
        stream.startReading(onData: { [weak self] bytes in
            self?.locked { self?.lastReceived = Date() }
            return parser.append(bytes) { type, body in self?.handle(type: type, body: body) }
        }, onClose: { [weak self, weak stream] reason in
            guard let self, let stream else { return }
            self.connectionClosed(stream, reason: reason)
        })
        if let interval = transport.heartbeatInterval { startHeartbeat(for: stream, every: interval) }

        let reply = try await request("hello", ["protocol": Self.protocolVersion, "client": configuration.clientName])
        let hello = try Self.decode(Hello.self, from: reply)
        let resubscribe: [(PaneID, UInt64?, Int?, Size?)] = locked {
            if instance != hello.instance {
                // A fresh holder: new shells, and pane IDs may be reused. Nothing we delivered still applies.
                deliveredSeq.removeAll()
            }
            instance = hello.instance
            lastHello = hello
            continuation.yield(.connected(hello))
            return subscriptions.map { ($0.key, deliveredSeq[$0.key], $0.value.scrollback, $0.value.viewport) }
        }
        configuration.log?("connected to clothod \(hello.version) pid \(hello.pid ?? 0) instance \(hello.instance)")
        _ = try await request("events.subscribe", nil)
        for (pane, have, scrollback, viewport) in resubscribe {
            do {
                let subscription = try await subscribe(pane, haveSeq: have, scrollback: scrollback, viewport: viewport)
                configuration.log?("resubscribed pane \(pane) from \(have.map(String.init) ?? "nothing"): \(subscription.mode) at \(subscription.seq)")
            } catch {
                configuration.log?("resubscribing pane \(pane) failed: \(error)")
            }
        }
    }

    private func connectionClosed(_ closed: ByteStream, reason: String) {
        let failed: [CheckedContinuation<Any, Error>] = locked {
            guard connection === closed else { return [] }
            connection = nil
            defer {
                pending.removeAll()
                replyHooks.removeAll()
            }
            return Array(pending.values)
        }
        failed.forEach { $0.resume(throwing: BackendError(code: "disconnected", message: reason)) }
        failFileStreams(BackendError(code: "disconnected", message: reason))
        let shouldReconnect: Bool = locked {
            guard !stopped, !reconnecting else { return false }
            reconnecting = true
            continuation.yield(.disconnected(reason))
            return true
        }
        guard shouldReconnect else { return }
        configuration.log?("disconnected: \(reason)")
        Task { await reconnectLoop() }
    }

    /// Retries with a growing delay, up to the transport's limit; `reconnectNow()` cuts a wait short.
    private func reconnectLoop() async {
        var delay: TimeInterval = 0.1
        while !locked({ stopped }) {
            do {
                try await connect()
                // A drop between connecting and here was ignored (a reconnect was in progress), so check.
                let droppedMeanwhile: Bool = locked {
                    if connection == nil, !stopped { return true }
                    reconnecting = false
                    return false
                }
                if droppedMeanwhile { continue }
                return
            } catch {
                configuration.log?("reconnect to \(configuration.transport.name) failed: \(error.localizedDescription)")
                locked { connection }?.close()
                continuation.yield(.disconnected(error.localizedDescription))
                let deadline = Date().addingTimeInterval(delay)
                while Date() < deadline, !locked({ skipBackoff || stopped }) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                locked { skipBackoff = false }
                delay = min(delay * 2, configuration.transport.maxReconnectDelay)
            }
        }
        locked { reconnecting = false }
    }

    // MARK: Commands

    public func getState() async throws -> ModelState {
        try Self.decode(ModelState.self, from: try await request("state.get", nil))
    }

    public func createWorkspace(name: String?, spawn: SpawnOptions) async throws -> CreatedWorkspace {
        var params = Self.spawnParams(spawn)
        params["name"] = name
        return try Self.decode(CreatedWorkspace.self, from: try await request("workspace.create", params))
    }

    public func renameWorkspace(_ workspace: WorkspaceID, name: String) async throws {
        _ = try await request("workspace.rename", ["workspace": workspace, "name": name])
    }

    public func closeWorkspace(_ workspace: WorkspaceID) async throws {
        _ = try await request("workspace.close", ["workspace": workspace])
    }

    public func createTab(in workspace: WorkspaceID, spawn: SpawnOptions) async throws -> CreatedTab {
        var params = Self.spawnParams(spawn)
        params["workspace"] = workspace
        return try Self.decode(CreatedTab.self, from: try await request("tab.create", params))
    }

    public func renameTab(_ tab: TabID, title: String?) async throws {
        _ = try await request("tab.rename", ["tab": tab, "title": title ?? NSNull()])
    }

    public func closeTab(_ tab: TabID) async throws {
        _ = try await request("tab.close", ["tab": tab])
    }

    public func split(_ pane: PaneID, direction: Direction, ratio: Double?, spawn: SpawnOptions) async throws -> CreatedSplit {
        var params = Self.spawnParams(spawn)
        params["pane"] = pane
        params["direction"] = direction.rawValue
        params["ratio"] = ratio
        return try Self.decode(CreatedSplit.self, from: try await request("pane.split", params))
    }

    public func closePane(_ pane: PaneID) async throws {
        _ = try await request("pane.close", ["pane": pane])
    }

    public func setRatio(_ split: SplitID, ratio: Double) async throws {
        _ = try await request("split.set_ratio", ["split": split, "ratio": ratio])
    }

    public func focus(_ target: FocusTarget) async throws {
        switch target {
        case .pane(let id): _ = try await request("focus", ["pane": id])
        case .tab(let id): _ = try await request("focus", ["tab": id])
        case .workspace(let id): _ = try await request("focus", ["workspace": id])
        }
    }

    public func subscribe(_ pane: PaneID, haveSeq: UInt64?, scrollback: Int?, viewport: Size?) async throws -> Subscription {
        locked { subscriptions[pane] = (scrollback, viewport) }
        var params: [String: Any] = ["pane": pane]
        params["have_seq"] = haveSeq
        params["scrollback"] = scrollback
        if let viewport { params["viewport"] = ["cols": viewport.cols, "rows": viewport.rows] }
        // The reply is turned into a `subscribed` event as it's read, ahead of the pane's first frame.
        return try Self.decode(Subscription.self, from: try await request("pane.subscribe", params, subscribing: pane))
    }

    public func unsubscribe(_ pane: PaneID) async throws {
        locked {
            subscriptions[pane] = nil
            deliveredSeq[pane] = nil
        }
        _ = try await request("pane.unsubscribe", ["pane": pane])
    }

    public func setViewport(_ pane: PaneID, _ size: Size) async throws {
        locked { subscriptions[pane]?.viewport = size }
        _ = try await request("pane.viewport", ["pane": pane, "cols": size.cols, "rows": size.rows])
    }

    public func sendKeys(_ pane: PaneID, text: String?, keys: [String]) async throws {
        var params: [String: Any] = ["pane": pane, "keys": keys]
        params["text"] = text
        _ = try await request("pane.keys", params)
    }

    public func pushRegister(_ r: PushRegistration) async throws {
        _ = try await request("push.register", ["device": r.device, "handle": r.handle, "key": r.key,
                                                "label": r.label, "relay": r.relay, "env": r.env])
    }

    public func pushUnregister(device: String) async throws {
        _ = try await request("push.unregister", ["device": device])
    }

    public func pushList() async throws -> [PushDevice] {
        let result = try await request("push.list", nil) as? [String: Any]
        return try Self.decode([PushDevice].self, from: result?["devices"] ?? [Any]())
    }

    public func pushTest(device: String) async throws {
        _ = try await request("push.test", ["device": device])
    }

    public func ackAgent(_ pane: PaneID) async throws {
        _ = try await request("agent.ack", ["pane": pane])
    }

    public func muteAgent(_ pane: PaneID, muted: Bool) async throws {
        _ = try await request("agent.mute", ["pane": pane, "muted": muted])
    }

    public func decide(pane: PaneID, request: String, decision: PermissionDecision, message: String?) async throws {
        var params: [String: Any] = ["pane": pane, "request": request, "decision": decision.rawValue]
        if decision == .deny, let message, !message.isEmpty { params["message"] = String(message.prefix(300)) }
        _ = try await self.request("agent.decide", params)
    }

    public func searchPane(_ pane: PaneID, query: String, options: PaneSearchOptions) async throws -> PaneSearchResult {
        var params: [String: Any] = ["pane": pane, "query": query, "regex": options.regex, "case_sensitive": options.caseSensitive]
        params["limit"] = options.limit
        if let before = options.before { params["before"] = ["line": before.line, "col": before.col] }
        return try Self.decode(PaneSearchResult.self, from: try await request("pane.search", params))
    }

    public func agentHistory(_ pane: PaneID, limit: Int?, since: Double?) async throws -> AgentHistory {
        var params: [String: Any] = ["pane": pane]
        params["limit"] = limit
        params["since"] = since
        return try Self.decode(AgentHistory.self, from: try await request("agent.history", params))
    }

    public func getSettings() async throws -> DaemonSettings {
        try Self.decode(DaemonSettings.self, from: try await request("settings.get", nil))
    }

    public func serviceStatus() async throws -> DaemonService {
        try Self.decode(DaemonService.self, from: try await request("service.status", nil))
    }

    public func installService() async throws -> DaemonService {
        try Self.decode(DaemonService.self, from: try await request("service.install", nil))
    }

    public func uninstallService() async throws -> DaemonService {
        try Self.decode(DaemonService.self, from: try await request("service.uninstall", nil))
    }

    public func setSettings(_ change: DaemonSettings.Change) async throws -> DaemonSettings {
        try Self.decode(DaemonSettings.self, from: try await request("settings.set", change.params))
    }

    public func resize(_ pane: PaneID, _ size: Size) async throws {
        _ = try await request("pane.resize", ["pane": pane, "cols": size.cols, "rows": size.rows])
    }

    public func sendInput(_ pane: PaneID, _ bytes: Data) {
        configuration.trace?("→ INPUT pane \(pane) \(bytes.count)B \(Self.preview(bytes))")
        var body = Data()
        body.appendBigEndian(pane)
        body.append(bytes)
        send(.input, body)
    }

    // MARK: Requests

    private var subscribeRequests: [Int: PaneID] = [:]

    func request(_ method: String, _ params: [String: Any]?, subscribing pane: PaneID? = nil,
                 onReply: ((Any) -> Void)? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Any, Error>) in
            let id: Int? = locked {
                guard connection != nil else { return nil }
                let id = nextRequestID
                nextRequestID += 1
                pending[id] = waiter
                if let pane { subscribeRequests[id] = pane }
                if let onReply { replyHooks[id] = onReply }
                return id
            }
            guard let id else {
                return waiter.resume(throwing: BackendError(code: "disconnected", message: "not connected to clothod"))
            }
            var message: [String: Any] = ["id": id, "method": method]
            if let params { message["params"] = params }
            do {
                send(.json, try JSONSerialization.data(withJSONObject: message))
            } catch {
                locked { pending.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }

    /// A message without an id: the daemon doesn't reply (`fs.ack`).
    func notify(_ method: String, _ params: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else { return }
        send(.json, body)
    }

    func send(_ type: FrameType, _ body: Data) {
        guard let connection = locked({ connection }) else { return }
        var frame = Data(capacity: body.count + 5)
        frame.appendBigEndian(UInt32(body.count + 1))
        frame.append(type.rawValue)
        frame.append(body)
        writeQueue.async { connection.write(frame) }
    }

    // MARK: Incoming frames (on the connection's read thread, in order)

    private func handle(type: UInt8, body: Data) {
        switch FrameType(rawValue: type) {
        case .json:
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
            if let id = (object["id"] as? NSNumber)?.intValue {
                handleReply(id: id, object)
            } else if let event = object["event"] as? String {
                handleEvent(event, object["data"])
            }
        case .output:
            guard body.count >= 16 else { return }
            let pane = body.readBigEndian(UInt64.self, at: 0), seq = body.readBigEndian(UInt64.self, at: 8)
            let bytes = body.subdata(in: body.startIndex + 16 ..< body.endIndex)
            configuration.trace?("← OUTPUT pane \(pane) seq \(seq) \(bytes.count)B")
            locked {
                deliveredSeq[pane] = seq + UInt64(bytes.count)
                continuation.yield(.output(pane, seq: seq, bytes: bytes))
            }
        case .snapshot:
            guard body.count >= 20 else { return }
            let pane = body.readBigEndian(UInt64.self, at: 0), seq = body.readBigEndian(UInt64.self, at: 8)
            let cols = Int(body.readBigEndian(UInt16.self, at: 16)), rows = Int(body.readBigEndian(UInt16.self, at: 18))
            let bytes = body.subdata(in: body.startIndex + 20 ..< body.endIndex)
            configuration.trace?("← SNAPSHOT pane \(pane) seq \(seq) \(cols)x\(rows) \(bytes.count)B")
            locked {
                deliveredSeq[pane] = seq
                continuation.yield(.snapshot(pane, seq: seq, cols: cols, rows: rows, bytes: bytes))
            }
        case .fileData:
            guard body.count >= 17 else { return }
            let stream = body.readBigEndian(UInt64.self, at: 0), offset = body.readBigEndian(UInt64.self, at: 8)
            let fin = body[body.startIndex + 16] & 1 != 0
            handleFileData(stream: stream, offset: offset, fin: fin, bytes: body.subdata(in: body.startIndex + 17 ..< body.endIndex))
        case .input, nil:
            // Unknown frame types are ignored.
            break
        }
    }

    private func handleReply(id: Int, _ object: [String: Any]) {
        let (waiter, subscribing, hook): (CheckedContinuation<Any, Error>?, PaneID?, ((Any) -> Void)?) = locked {
            (pending.removeValue(forKey: id), subscribeRequests.removeValue(forKey: id), replyHooks.removeValue(forKey: id))
        }
        if let error = object["error"] as? [String: Any] {
            waiter?.resume(throwing: BackendError(code: error["code"] as? String ?? "internal",
                                                  message: error["message"] as? String ?? "clothod error"))
            return
        }
        let result = object["result"] ?? [String: Any]()
        hook?(result)
        if let pane = subscribing, let subscription = try? Self.decode(Subscription.self, from: result) {
            locked {
                deliveredSeq[pane] = subscription.seq
                continuation.yield(.subscribed(pane, subscription))
            }
        }
        waiter?.resume(returning: result)
    }

    private func handleEvent(_ name: String, _ data: Any?) {
        guard let data = data as? [String: Any] else { return }
        let pane = (data["pane"] as? NSNumber)?.uint64Value
        let event: SessionEvent?
        switch name {
        case "state":
            event = (try? Self.decode(ModelState.self, from: data)).map { .state($0) }
        case "pane":
            let rev = (data["rev"] as? NSNumber)?.uint64Value ?? 0
            event = (try? Self.decode(Pane.self, from: data)).map { .pane($0, rev: rev) }
        case "bell":
            event = pane.map { .bell($0) }
        case "settings":
            event = (try? Self.decode(DaemonSettings.self, from: data)).map { .settings($0) }
        case "service":
            event = (try? Self.decode(DaemonService.self, from: data)).map { .service($0) }
        case "pane.clipboard":
            guard let pane, let text = data["text"] as? String else { return }
            event = .clipboard(pane, text: text, selection: data["target"] as? String == "selection")
        case "pane.resized":
            guard let pane, let cols = (data["cols"] as? NSNumber)?.intValue, let rows = (data["rows"] as? NSNumber)?.intValue,
                  let seq = (data["seq"] as? NSNumber)?.uint64Value else { return }
            event = .resized(pane, cols: cols, rows: rows, seq: seq)
        case "pane.resync":
            event = pane.map { .resync($0) }
        case "fs.ack", "fs.done", "fs.error":
            handleFileEvent(name, data)
            return
        case "agent":
            // {"pane", "agent": {...} | null}; the shape is a draft until protocol.md has it.
            let info = (data["agent"] as? [String: Any]).flatMap { try? Self.decode(AgentInfo.self, from: $0) }
            event = pane.map { .agent($0, info) }
        default:
            // Unknown events are ignored.
            event = nil
        }
        if let event { locked { _ = continuation.yield(event) } }
    }

    // MARK: Helpers

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func preview(_ bytes: Data) -> String {
        bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func spawnParams(_ spawn: SpawnOptions) -> [String: Any] {
        var params: [String: Any] = [:]
        params["command"] = spawn.command
        params["cwd"] = spawn.cwd
        params["env"] = spawn.env
        params["cols"] = spawn.cols
        params["rows"] = spawn.rows
        return params
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

}

/// Splits a byte stream into frames: u32 big-endian length, u8 type, body.
final class FrameParser: @unchecked Sendable {
    private var buffer = Data()

    /// Hands each complete frame to `frame`; returns false on a malformed length, which ends the connection.
    func append(_ bytes: UnsafeRawBufferPointer, frame: (UInt8, Data) -> Void) -> Bool {
        buffer.append(contentsOf: bytes)
        var offset = buffer.startIndex
        defer { buffer.removeSubrange(buffer.startIndex ..< offset) }
        while buffer.endIndex - offset >= 4 {
            let length = Int(buffer.readBigEndian(UInt32.self, at: offset - buffer.startIndex))
            guard length >= 1, length <= ClothodBackend.maxFrame else { return false }
            guard buffer.endIndex - offset >= 4 + length else { break }
            frame(buffer[offset + 4], buffer.subdata(in: offset + 5 ..< offset + 4 + length))
            offset += 4 + length
        }
        return true
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Reads an integer at `offset` bytes from the start of this data.
    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { target in
            _ = copyBytes(to: target, from: (startIndex + offset) ..< (startIndex + offset + MemoryLayout<T>.size))
        }
        return T(bigEndian: value)
    }
}
