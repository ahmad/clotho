@testable import Clotho
import CryptoKit
import Darwin
import XCTest

/// SSHSession's dial mode (SSHSession.socketDialer): a connected socket from elsewhere, handed to NIO with
/// ClientBootstrap.withConnectedSocket, for both connect sites. No tailnet node needed: socketpairs, and a
/// plain TCP socket to the throwaway sshd (ios/scripts/ssh-test-server.sh) for the full login.
final class SSHDialTests: XCTestCase {
    override func tearDown() {
        SSHSession.socketDialer = nil
    }

    func testDialerErrorFailsTheProbePromptly() {
        struct DialFailed: Error {}
        SSHSession.socketDialer = { _, _, _ in throw DialFailed() }
        let t0 = Date()
        XCTAssertThrowsError(try SSHSession.presentedHostKey(host: "peer", port: 22, timeout: .seconds(5))) { error in
            XCTAssertTrue(error is DialFailed, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }

    /// A peer that isn't SSH: the probe fails within its time, and NIO closed the adopted end.
    func testNotSSHFailsAndClosesTheAdoptedSocket() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let ours = fds[1], adopted = fds[0]
        defer { close(ours) }
        var on: Int32 = 1
        setsockopt(ours, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let reply = "HTTP/1.1 400 Bad Request\r\n\r\n"
        XCTAssertEqual(write(ours, reply, reply.utf8.count), reply.utf8.count)
        shutdown(ours, SHUT_WR)
        SSHSession.socketDialer = { host, port, _ in
            XCTAssertEqual(host, "not-ssh")
            XCTAssertEqual(port, 2022)
            return adopted
        }
        let t0 = Date()
        XCTAssertThrowsError(try SSHSession.presentedHostKey(host: "not-ssh", port: 2022, timeout: .seconds(5)))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        // Our end reads EOF once NIO has closed its end (after whatever it sent first).
        var buffer = [UInt8](repeating: 0, count: 4096)
        var p = pollfd(fd: ours, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(3)
        var eof = false
        while Date() < deadline {
            guard poll(&p, 1, 500) > 0 else { continue }
            let n = read(ours, &buffer, buffer.count)
            if n <= 0 { eof = true; break }
        }
        XCTAssertTrue(eof, "the adopted socket wasn't closed")
    }

    /// The whole path over an adopted socket: key exchange (the host key) and a login with the test key.
    func testHandshakeAndLoginOverAdoptedSocket() throws {
        let dir = URL(fileURLWithPath: "/tmp/clotho-ios-sshtest")
        func read(_ name: String) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let seedHex = read("seed.hex"), let user = read("user"), let hostKey = read("host_ed25519.pub") else {
            throw XCTSkip("no SSH test server")
        }
        final class Dialed: @unchecked Sendable {
            let lock = NSLock()
            var targets: [String] = []
        }
        let dialed = Dialed()
        SSHSession.socketDialer = { host, port, _ in
            dialed.lock.withLock { dialed.targets.append("\(host):\(port)") }
            return try Self.tcpConnect(port: 2222)
        }
        // Names the dialer resolves itself: NIO never looks this one up.
        let presented = try SSHSession.presentedHostKey(host: "dialed-machine", port: 22)
        XCTAssertEqual(presented.split(separator: " ").prefix(2), hostKey.split(separator: " ").prefix(2))

        let seed = Data(stride(from: 0, to: seedHex.count, by: 2).map {
            UInt8(seedHex[seedHex.index(seedHex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
        let key = SSHKey(id: "ssh-dial-test", name: "clotho-ios-dev-test", kind: .ed25519, created: Date(),
                         secret: try Curve25519.Signing.PrivateKey(rawRepresentation: seed).rawRepresentation)
        try KeyStore.save(key)
        let machine = Machine(id: UUID(uuidString: "5E55E55E-0000-0000-0000-0000000000D1")!, name: "dial test",
                              host: "dialed-machine", port: 22, user: user, keyID: key.id, devDirs: true)
        TrustedHostKeys.shared.set(nil, for: machine.id)
        defer {
            TrustedHostKeys.shared.set(nil, for: machine.id)
            KeyStore.delete(key.id)
        }
        let runner = NIOCommandRunner(machine: machine)
        let result = try runner.run("echo hi", input: nil)
        runner.reset()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(dialed.lock.withLock { dialed.targets }, ["dialed-machine:22", "dialed-machine:22"])
    }

    /// A blocking TCP connection to 127.0.0.1:port, as a dialer would return it.
    static func tcpConnect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }
}
