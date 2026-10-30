import Darwin
import Foundation

/// How ClothodBackend reaches a daemon. A transport only produces a byte stream; framing, the handshake,
/// reconnecting and resuming all live in the backend, so every transport behaves the same above it.
///
/// - `UnixSocketTransport`: the local daemon's socket.
/// - `SSHProcessTransport` (macOS): `ssh <target> clothod bridge`, which speaks the same protocol over stdio.
/// - iOS will add a SwiftNIO SSH transport behind this protocol.
public protocol ClothodTransport: Sendable {
    /// For logs and error messages, such as the socket path or the SSH target.
    var name: String { get }
    /// The longest wait between reconnect attempts. Remote links back off further than a local socket.
    var maxReconnectDelay: TimeInterval { get }
    /// After this long without hearing from the daemon, the backend checks the link is alive (nil: never).
    var heartbeatInterval: TimeInterval? { get }
    /// Opens a byte stream to the daemon. It may start the daemon (or install it) first, reporting each
    /// step through `progress` (for example "Installing clothod 0.2.0").
    func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream
}

/// A connected, bidirectional byte stream: a pair of file descriptors (the same one for a socket).
/// Reading happens on a dedicated thread; writes block on the caller's (serial) queue.
public final class ByteStream: @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let lock = NSLock()
    private var closed = false
    private let onShutdown: () -> Void
    /// Explains why the stream ended, beyond "closed" (for example ssh's error output and exit status).
    private let closeReason: () -> String?

    /// `onShutdown` makes a blocked read return (shutting a socket down, ending a process).
    /// The descriptors are closed when the read loop ends.
    public init(readFD: Int32, writeFD: Int32, onShutdown: @escaping () -> Void, closeReason: @escaping () -> String? = { nil }) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.onShutdown = onShutdown
        self.closeReason = closeReason
        // A write to a pipe whose reader is gone (an ssh that was just ended) must fail with EPIPE, not
        // raise SIGPIPE, which would end the whole app. Sockets get SO_NOSIGPIPE where they're made.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    }

    /// Reads until the stream ends, handing each chunk to `onData`, then calls `onClose` once.
    func startReading(onData: @escaping (UnsafeRawBufferPointer) -> Bool, onClose: @escaping (String) -> Void) {
        let thread = Thread { [self] in
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            var reason: String?
            while true {
                let n = chunk.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    if n < 0 { reason = "read failed: \(String(cString: strerror(errno)))" }
                    break
                }
                let keepGoing = chunk.withUnsafeBytes { onData(UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
                if !keepGoing {
                    reason = "protocol error"
                    break
                }
            }
            let closedHere = isClosed
            close()
            // Only the read loop closes the descriptors, so none is reused while a read is blocked on it.
            Darwin.close(readFD)
            if writeFD != readFD { Darwin.close(writeFD) }
            // closeReason runs either way (it reports how a remote command ended), but a stream this side
            // closed (reconnectNow, stop) ended on purpose, whatever the process says about it.
            let explained = closeReason()
            onClose(closedHere ? "reconnecting" : explained ?? reason ?? "the connection closed")
        }
        thread.name = "clotho.clothod.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(writeFD, raw.baseAddress! + sent, raw.count - sent)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Ends the stream, which ends the read loop.
    public func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        if first { onShutdown() }
    }
}

// MARK: - Unix socket

public struct UnixSocketTransport: ClothodTransport {
    public var socketPath: String
    /// Called when the socket can't be reached, to start the daemon (`clothod start`). Nil never starts it.
    public var startDaemon: (@Sendable () throws -> Void)?

    public init(socketPath: String = ClothodBackend.defaultSocketPath(), startDaemon: (@Sendable () throws -> Void)? = nil) {
        self.socketPath = socketPath
        self.startDaemon = startDaemon
    }

    public var name: String { socketPath }
    public var maxReconnectDelay: TimeInterval { 2 }
    // A local socket reports a dead daemon at once.
    public var heartbeatInterval: TimeInterval? { nil }

    public func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
        let socket: Int32
        do {
            socket = try Self.connect(socketPath)
        } catch {
            guard let startDaemon else { throw error }
            progress("Starting clothod")
            try startDaemon()
            socket = try Self.connect(socketPath)
        }
        return ByteStream(readFD: socket, writeFD: socket, onShutdown: { shutdown(socket, SHUT_RDWR) })
    }

    static func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw BackendError(code: "bad_request", message: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendError(code: "internal", message: "socket() failed: \(errno)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw BackendError(code: "disconnected", message: "can't connect to \(path): \(String(cString: strerror(code)))")
        }
        return fd
    }
}

// MARK: - SSH process (macOS)

#if os(macOS)
/// Runs `ssh -T <target> -- <remote command>` and speaks the protocol over its stdin and stdout. ssh reads
/// the user's ~/.ssh/config and keys, never prompts (BatchMode), and keepalives detect a dead link.
public struct SSHProcessTransport: ClothodTransport {
    public var target: String
    /// The command run on the remote machine, such as `~/.local/share/clothod/bin/0.2.0/clothod bridge`.
    /// Resolved per connection, because an installer may change it.
    public var remoteCommand: @Sendable () throws -> String
    /// Runs before each connection, for example to install or upgrade clothod on the machine.
    public var prepare: (@Sendable (_ progress: @escaping @Sendable (String) -> Void) throws -> Void)?
    public var sshPath = "/usr/bin/ssh"
    public var extraOptions: [String] = []
    /// Each line ssh or the remote command writes to stderr, such as clothod's `clothod: warning:` lines.
    public var onStderrLine: (@Sendable (String) -> Void)?
    /// How the remote command ended: its exit status and stderr. Status 3 (RemoteSetup.holderTooOldExit)
    /// means the machine's sessions need restarting to finish an upgrade.
    public var onExit: (@Sendable (Int32, String) -> Void)?

    public init(target: String, remoteCommand: @escaping @Sendable () throws -> String,
                prepare: (@Sendable (_ progress: @escaping @Sendable (String) -> Void) throws -> Void)? = nil) {
        self.target = target
        self.remoteCommand = remoteCommand
        self.prepare = prepare
    }

    public var name: String { target }
    public var maxReconnectDelay: TimeInterval { 30 }
    public var heartbeatInterval: TimeInterval? { 15 }

    public static let baseOptions = [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
    ]

    public func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
        try SSHTarget.check(target)
        if let prepare { try prepare(progress) }
        progress("Connecting")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        // "--" ends ssh's options, so neither the target nor anything after it is read as one.
        process.arguments = Self.baseOptions + extraOptions + ["--", target, try remoteCommand()]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // ssh's complaints ("Permission denied", "Connection refused") explain a closed stream.
        let errors = StderrTail()
        errors.onLine = onStderrLine
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errors.append(data) }
        }
        try process.run()
        // The stream owns duplicates, so Foundation's handles can't close them underneath it.
        let readFD = dup(stdout.fileHandleForReading.fileDescriptor)
        let writeFD = dup(stdin.fileHandleForWriting.fileDescriptor)
        try? stdout.fileHandleForReading.close()
        try? stdin.fileHandleForWriting.close()
        let target = target, onExit = onExit
        return ByteStream(readFD: readFD, writeFD: writeFD, onShutdown: {
            guard process.isRunning else { return }
            process.terminate()
            // An ssh stuck in a write to a dead link may not get to its SIGTERM handler; the read loop
            // only ends once the process is gone.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }, closeReason: {
            process.waitUntilExit()
            let message = errors.text
            onExit?(process.terminationStatus, message)
            switch process.terminationStatus {
            case 0: return message.isEmpty ? nil : message
            case RemoteSetup.holderTooOldExit:
                return "The sessions on \(target) use an older clothod; restart them to finish upgrading"
            case 255: return "Can't reach \(target) over SSH" + (message.isEmpty ? "" : ": \(message)")
            case let code: return "clothod on \(target) exited with \(code)" + (message.isEmpty ? "" : ": \(message)")
            }
        })
    }
}

/// The last part of a process's output (4 KB by default).
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    /// Called with each complete line as it arrives.
    var onLine: ((String) -> Void)?
    private var partial = Data()

    init(limit: Int = 4096) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > limit { data = data.suffix(limit) }
        var lines: [String] = []
        if onLine != nil {
            partial.append(chunk)
            while let newline = partial.firstIndex(of: 0x0a) {
                lines.append(String(decoding: partial[partial.startIndex ..< newline], as: UTF8.self))
                partial.removeSubrange(partial.startIndex ... newline)
            }
        }
        let onLine = onLine
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
