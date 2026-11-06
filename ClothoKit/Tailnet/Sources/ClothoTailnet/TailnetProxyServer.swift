#if os(macOS)
import Darwin
import Foundation
import TailnetFdPass

/// Serves dials to `clotho-tailnet-proxy`, ssh's ProxyCommand with ProxyUseFdpass=yes: on a Unix socket
/// (mode 0600, in a 0700 dir), each client of this user writes `HOST PORT\n`, and gets back the connected
/// tailnet socket by SCM_RIGHTS, or `error <why>\n`. ssh then talks to the peer directly. The dial's timeout
/// (8 s) is shorter than the helper's own deadline (10 s), so a failed dial reaches ssh as an error line.
public final class TailnetProxyServer: @unchecked Sendable {
    public let socketPath: String
    public let node: TailnetNode
    public var dialTimeout: TimeInterval
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var wake: (read: Int32, write: Int32) = (-1, -1)

    public init(node: TailnetNode, socketPath: String, dialTimeout: TimeInterval = 8, log: (@Sendable (String) -> Void)? = nil) {
        self.node = node
        self.socketPath = socketPath
        self.dialTimeout = dialTimeout
        self.log = log
    }

    deinit { stop() }

    /// Starts listening. The socket's dir is created 0700 if needed, and must belong to this user.
    public func start() throws {
        try lock.locked {
            guard listener < 0 else { return }
            let dir = (socketPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var st = stat()
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
                throw TailnetError.failed("\(dir) is not a directory of this user's")
            }
            chmod(dir, 0o700)
            let fd = tfp_listen(socketPath, 16)
            guard fd >= 0 else {
                let why = errno == ENAMETOOLONG ? "the path is too long for a Unix socket (\(socketPath.utf8.count) bytes, at most 103)" : String(cString: strerror(errno))
                throw TailnetError.failed("can't listen on \(socketPath): \(why)")
            }
            var pipeFDs: [Int32] = [-1, -1]
            guard pipe(&pipeFDs) == 0 else {
                close(fd)
                throw TailnetError.failed("pipe: \(String(cString: strerror(errno)))")
            }
            listener = fd
            wake = (pipeFDs[0], pipeFDs[1])
            let thread = Thread { [self] in acceptLoop(listener: fd, wake: pipeFDs[0], wakeWrite: pipeFDs[1]) }
            thread.name = "clotho.tailnet.proxy"
            thread.start()
        }
    }

    /// Stops listening and removes the socket. Requests in flight finish.
    public func stop() {
        let wakeWrite: Int32 = lock.locked {
            guard listener >= 0 else { return -1 }
            listener = -1
            let w = wake.write
            wake = (-1, -1)
            return w
        }
        guard wakeWrite >= 0 else { return }
        unlink(socketPath)
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    private func acceptLoop(listener: Int32, wake: Int32, wakeWrite: Int32) {
        defer {
            close(listener)
            close(wake)
            close(wakeWrite)
        }
        while true {
            let client = tfp_accept(listener, wake, 60_000)
            if client == -2 { return }
            if client < 0 {
                if errno == ETIMEDOUT { continue }
                log?("tailnet proxy: accept failed: \(String(cString: strerror(errno)))")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        func reply(_ message: String) {
            log?("tailnet proxy: \(message)")
            _ = "error \(message)\n".withCString { tfp_write_all(client, $0, strlen($0)) }
        }
        // Only this user's processes: the socket is 0600 in a 0700 dir, and this checks it again.
        guard tfp_peer_uid(client) == Int(getuid()) else { return reply("refused: another user") }
        var buffer = [CChar](repeating: 0, count: 512)
        guard tfp_read_line(client, &buffer, buffer.count, 5000) >= 0 else { return reply("no request") }
        let parts = String(cString: buffer).split(separator: " ")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return reply("bad request (want HOST PORT)") }
        let host = String(parts[0])
        let start = Date()
        let fd: Int32
        do {
            fd = try node.dialSync(host: host, port: port, timeout: dialTimeout)
        } catch {
            return reply("\(host):\(port): \(error.localizedDescription)")
        }
        defer { close(fd) }
        if tfp_send_fd(client, fd) != 0 {
            log?("tailnet proxy: passing \(host):\(port) to the helper: \(String(cString: strerror(errno)))")
            return
        }
        log?("tailnet proxy: \(host):\(port) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }
}
#endif
