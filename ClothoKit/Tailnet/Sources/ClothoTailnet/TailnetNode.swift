import CClothoTailnet
import ClothoKit
import Darwin
import Foundation

/// Clotho's own userspace Tailscale node (PLAN.md, "Built-in Tailscale"): the Go shim (tsnet) behind
/// clotho_tailnet.h, wrapped for Swift. One node per app process. It joins the user's own tailnet after a
/// browser sign-in, and dials peers without a system VPN.
///
/// Every call that waits runs on a private queue, never the caller's thread. `stop()` returns at once:
/// the shim shuts the node down in the background, because tsnet's Close can hang for minutes
/// (tailscale/tailscale#21353). Starting the same node again (same dir or store) before that shutdown
/// finished can race on its state; `waitForClose(timeout:)` tells when it has.
public final class TailnetNode: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The node's dir, absolute. The shim creates it 0700. It holds the state (unless `store` is set)
        /// and the backend's own files.
        public var dir: URL
        /// clotho-<device>, -dev for dev builds (`defaultHostname`).
        public var hostname: String
        /// The coordination server; nil is Tailscale's.
        public var controlURL: URL?
        /// An ephemeral node, which control deletes soon after it goes offline, and whose clean shutdown logs
        /// it out. Dev and test nodes only (PLAN decision 5).
        public var ephemeral: Bool
        /// Tests: port mapper and netns binding off, process-wide. Refused unless `controlURL` is on this
        /// machine (loopback or localhost), so a test node never joins a real tailnet.
        public var testMode: Bool
        /// Where the node keeps its state instead of `<dir>/tailscaled.state` (the Keychain, on iOS).
        public var store: TailnetStateStore?
        /// The node's own log lines (verbose), on the shim's threads.
        public var log: (@Sendable (String) -> Void)?

        public init(dir: URL, hostname: String, controlURL: URL? = nil, ephemeral: Bool = false, testMode: Bool = false,
                    store: TailnetStateStore? = nil, log: (@Sendable (String) -> Void)? = nil) {
            self.dir = dir
            self.hostname = hostname
            self.controlURL = controlURL
            self.ephemeral = ephemeral
            self.testMode = testMode
            self.store = store
            self.log = log
        }
    }

    public enum State: Equatable, Sendable, CustomStringConvertible {
        case stopped
        case starting
        /// Sign in with the URL (a browser login); nil until control has handed one out.
        case needsLogin(URL?)
        /// Signed in, but the tailnet's admin must approve the device.
        case needsMachineAuth
        case running
        /// The node's key expired: sign in again.
        case expired

        public var description: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .needsLogin(let url): return url.map { "NeedsLogin(\($0.absoluteString))" } ?? "NeedsLogin"
            case .needsMachineAuth: return "NeedsMachineAuth"
            case .running: return "Running"
            case .expired: return "Expired"
            }
        }

        /// The shim's state report: {"BackendState": ..., "AuthURL": ..., "Expired": ...}.
        static func from(backendState: String, authURL: String?, expired: Bool) -> State {
            switch backendState {
            case "Running": return .running
            case "NeedsMachineAuth": return .needsMachineAuth
            case "NeedsLogin":
                if expired { return .expired }
                return .needsLogin(authURL.flatMap { $0.isEmpty ? nil : URL(string: $0) })
            case "Stopped", "InUseOtherUser": return .stopped
            default: return .starting // NoState, Starting
            }
        }
    }

    public let configuration: Configuration

    private let lock = NSLock()
    private var handle: ctn_node = 0
    /// A start() is between deciding to start and having its handle.
    private var starting = false
    private var generation = 0
    private var currentState: State = .stopped
    private var stateHandler: (@Sendable (State) -> Void)?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]
    /// The callbacks of the node started last; its `closed` group says when its shutdown finished.
    private var lastBox: CallbackBox?

    private static let queue = DispatchQueue(label: "clotho.tailnet", qos: .userInitiated, attributes: .concurrent)

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        let h = handle
        if h != 0 { ctn_close(h) }
        observers.values.forEach { $0.finish() }
    }

    /// clotho-<device>[-dev] (PLAN decision 7): the device name lowercased, anything but [a-z0-9-] made a
    /// '-', at most 63 characters in all (a DNS label).
    public static func defaultHostname(device: String, dev: Bool) -> String {
        var name = String(device.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "mac" }
        let suffix = dev ? "-dev" : ""
        let room = 63 - "clotho-".count - suffix.count
        if name.count > room { name = String(name.prefix(room)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return "clotho-" + name + suffix
    }

    // MARK: State

    public var state: State { lock.locked { currentState } }

    /// Called on every state change, on a shim thread. Keep it quick (hop to your own queue).
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { lock.locked { stateHandler } }
        set { lock.locked { stateHandler = newValue } }
    }

    /// The current state, then every change, until the stream is dropped.
    public func states() -> AsyncStream<State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(16))
        lock.locked {
            observers[id] = continuation
            continuation.yield(currentState)
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.locked { _ = self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Waits until the state matches, up to `timeout`; the last state seen either way.
    @discardableResult
    public func waitForState(timeout: TimeInterval, _ matches: @escaping @Sendable (State) -> Bool) async -> State {
        let stream = states()
        return await withTaskGroup(of: State?.self) { group in
            group.addTask {
                for await s in stream where matches(s) { return s }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? self.state
        }
    }

    private func setState(_ new: State, generation gen: Int) {
        let (handler, conts): ((@Sendable (State) -> Void)?, [AsyncStream<State>.Continuation]) = lock.locked {
            guard gen == generation, new != currentState else { return (nil, []) }
            currentState = new
            return (stateHandler, Array(observers.values))
        }
        conts.forEach { $0.yield(new) }
        handler?(new)
    }

    fileprivate func received(stateJSON json: String, generation gen: Int) {
        struct Message: Decodable {
            var BackendState: String
            var AuthURL: String?
            var Expired: Bool?
        }
        guard let m = try? JSONDecoder().decode(Message.self, from: Data(json.utf8)) else { return }
        setState(.from(backendState: m.BackendState, authURL: m.AuthURL, expired: m.Expired ?? false), generation: gen)
    }

    // MARK: Lifecycle

    /// Starts the node and returns without waiting for it to run: watch `state`. Starting a started node
    /// does nothing.
    public func start() throws {
        let (gen, box): (Int, CallbackBox?) = lock.locked {
            guard handle == 0, !starting else { return (generation, nil) }
            starting = true
            generation += 1
            let box = CallbackBox(generation: generation, store: configuration.store, log: configuration.log)
            box.node = self
            return (generation, box)
        }
        guard let box else { return }
        setState(.starting, generation: gen)
        let unmanaged = Unmanaged.passRetained(box)
        var error: UnsafeMutablePointer<CChar>?
        let c = configuration
        let h: ctn_node = c.dir.path.withCString { dir in
            c.hostname.withCString { hostname in
                (c.controlURL?.absoluteString ?? "").withCString { controlURL in
                    var cfg = ctn_config()
                    cfg.dir = dir
                    cfg.hostname = hostname
                    cfg.control_url = controlURL
                    cfg.ephemeral = c.ephemeral ? 1 : 0
                    cfg.test_mode = c.testMode ? 1 : 0
                    cfg.ctx = unmanaged.toOpaque()
                    if c.store != nil {
                        cfg.store_read = tailnetStoreRead
                        cfg.store_write = tailnetStoreWrite
                    }
                    cfg.on_state = tailnetOnState
                    if c.log != nil { cfg.log = tailnetLog }
                    cfg.on_closed = tailnetOnClosed
                    return ctn_start(&cfg, &error)
                }
            }
        }
        guard h != 0 else {
            // A failed start never calls back: the box is ours to release.
            unmanaged.release()
            box.closed.leave()
            lock.locked { starting = false }
            setState(.stopped, generation: gen)
            throw TailnetError.failed(takeString(error) ?? "the node didn't start")
        }
        let stoppedMeanwhile: Bool = lock.locked {
            starting = false
            lastBox = box
            guard gen == generation else { return true }
            handle = h
            return false
        }
        // stop() ran while this started: close what started.
        if stoppedMeanwhile { ctn_close(h) }
    }

    /// Stops the node and returns at once; the shutdown finishes in the background. Calls made after it fail
    /// with `TailnetError.stopped`.
    public func stop() {
        let h: ctn_node = lock.locked {
            let h = handle
            handle = 0
            generation += 1
            return h
        }
        if h != 0 { ctn_close(h) }
        let (handler, conts): ((@Sendable (State) -> Void)?, [AsyncStream<State>.Continuation]) = lock.locked {
            guard currentState != .stopped else { return (nil, []) }
            currentState = .stopped
            return (stateHandler, Array(observers.values))
        }
        conts.forEach { $0.yield(.stopped) }
        handler?(.stopped)
    }

    /// Waits until the last node stopped has finished shutting down (true), or `timeout` passes (false).
    public func waitForClose(timeout: TimeInterval) -> Bool {
        guard let box = lock.locked({ lastBox }) else { return true }
        return box.closed.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Calls

    private func currentHandle() throws -> ctn_node {
        let h = lock.locked { handle }
        guard h != 0 else { throw TailnetError.stopped }
        return h
    }

    /// Runs a blocking shim call on the node's queue.
    private func call<T>(_ body: @escaping @Sendable (ctn_node) throws -> T) async throws -> T {
        let h = try currentHandle()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Self.queue.async { continuation.resume(with: Result { try body(h) }) }
        }
    }

    /// The node's status, with its peers.
    public func status(timeout: TimeInterval = 10) async throws -> TailnetStatus {
        let json: String = try await call { h in try Self.string { e in ctn_status_json(h, Self.ms(timeout), e) } }
        return try TailnetStatus.decode(json)
    }

    /// Starts an interactive login and returns its URL, for the user to open in a browser. nil: the node is
    /// running and control signed it in without one.
    public func login(timeout: TimeInterval = 30) async throws -> URL? {
        let text: String = try await call { h in try Self.string { e in ctn_login_interactive(h, Self.ms(timeout), e) } }
        if text.isEmpty { return nil }
        guard let url = URL(string: text) else { throw TailnetError.failed("bad login URL from control: \(text)") }
        return url
    }

    /// Signs the node out of the tailnet (control expires its key). The node stays up, needing a login.
    public func logout(timeout: TimeInterval = 15) async throws {
        try await call { h in
            var error: UnsafeMutablePointer<CChar>?
            if ctn_logout(h, Self.ms(timeout), &error) != 0 { throw TailnetError.failed(takeString(error) ?? "logout failed") }
        }
    }

    /// Who is behind a tailnet address (an IP, or IP:port).
    public func whois(_ address: String, timeout: TimeInterval = 10) async throws -> TailnetWhoIs {
        let json: String = try await call { h in try Self.string { e in address.withCString { ctn_whois(h, $0, Self.ms(timeout), e) } } }
        return try TailnetWhoIs.decode(json)
    }

    /// Connects to host:port over the tailnet; the connected socket is the caller's to close. Retries while
    /// the node starts or the peer isn't known yet, until `timeout`; a refused connection fails at once.
    public func dial(host: String, port: Int, timeout: TimeInterval = 15) async throws -> Int32 {
        try await call { h in try Self.dial(h, host: host, port: port, timeout: timeout) }
    }

    /// `dial`, blocking the calling thread (for ClothodTransport.open and the ssh proxy server).
    public func dialSync(host: String, port: Int, timeout: TimeInterval = 15) throws -> Int32 {
        try Self.dial(try currentHandle(), host: host, port: port, timeout: timeout)
    }

    /// `dial` as a ByteStream, ready for ClothodBackend.
    public func dialStream(host: String, port: Int, timeout: TimeInterval = 15) async throws -> ByteStream {
        let fd = try await dial(host: host, port: port, timeout: timeout)
        return ByteStream(readFD: fd, writeFD: fd, onShutdown: { shutdown(fd, SHUT_RDWR) })
    }

    private static func dial(_ h: ctn_node, host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var error: UnsafeMutablePointer<CChar>?
        let fd = host.withCString { ctn_dial(h, $0, Int32(clamping: port), ms(timeout), &error) }
        guard fd >= 0 else { throw TailnetError.failed(takeString(error) ?? "dialing \(host):\(port) failed") }
        return fd
    }

    private static func ms(_ t: TimeInterval) -> Int32 { Int32(clamping: Int((t * 1000).rounded())) }

    /// A string the shim returned (freed here), or its error.
    private static func string(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>?) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let p = body(&error) else { throw TailnetError.failed(takeString(error) ?? "the tailnet call failed") }
        defer { ctn_free(p) }
        return String(cString: p)
    }
}

public enum TailnetError: Error, LocalizedError, Equatable {
    /// The node isn't running (never started, or stopped).
    case stopped
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .stopped: return "The tailnet node isn't running"
        case .failed(let message): return message
        }
    }
}

/// Takes ownership of a string the shim returned.
func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { ctn_free(p) }
    return String(cString: p)
}

// MARK: - Callbacks from the shim

/// What the shim's callbacks reach, through ctx. Retained for the shim from start until on_closed.
final class CallbackBox: @unchecked Sendable {
    let generation: Int
    let store: TailnetStateStore?
    let log: (@Sendable (String) -> Void)?
    weak var node: TailnetNode?
    /// Left once the node has fully shut down.
    let closed = DispatchGroup()

    init(generation: Int, store: TailnetStateStore?, log: (@Sendable (String) -> Void)?) {
        self.generation = generation
        self.store = store
        self.log = log
        closed.enter()
    }
}

private func box(_ ctx: UnsafeMutableRawPointer?) -> CallbackBox? {
    ctx.map { Unmanaged<CallbackBox>.fromOpaque($0).takeUnretainedValue() }
}

private let tailnetOnState: ctn_on_state_fn = { ctx, json in
    guard let box = box(ctx), let json else { return }
    box.node?.received(stateJSON: String(cString: json), generation: box.generation)
}

private let tailnetLog: ctn_log_fn = { ctx, line in
    guard let box = box(ctx), let line else { return }
    box.log?(String(cString: line))
}

private let tailnetOnClosed: ctn_on_closed_fn = { ctx in
    guard let ctx else { return }
    let unmanaged = Unmanaged<CallbackBox>.fromOpaque(ctx)
    unmanaged.takeUnretainedValue().closed.leave()
    unmanaged.release()
}

private let tailnetStoreRead: ctn_store_read_fn = { ctx, key, out, len in
    guard let store = box(ctx)?.store, let key, let out, let len else { return -1 }
    do {
        guard let data = try store.read(key: String(cString: key)) else { return 1 }
        let buffer = malloc(max(data.count, 1))!.assumingMemoryBound(to: UInt8.self)
        data.copyBytes(to: buffer, count: data.count)
        out.pointee = buffer
        len.pointee = data.count
        return 0
    } catch {
        box(ctx)?.log?("tailnet: reading \(String(cString: key)) from the state store: \(error)")
        return -1
    }
}

private let tailnetStoreWrite: ctn_store_write_fn = { ctx, key, data, len in
    guard let store = box(ctx)?.store, let key else { return -1 }
    let value = data.map { Data(bytes: $0, count: len) } ?? Data()
    do {
        try store.write(key: String(cString: key), value: len == 0 && data == nil ? nil : value)
        return 0
    } catch {
        box(ctx)?.log?("tailnet: writing \(String(cString: key)) to the state store: \(error)")
        return -1
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
