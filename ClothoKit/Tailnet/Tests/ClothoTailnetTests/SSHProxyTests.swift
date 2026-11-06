import ClothoTailnet
import Darwin
import Foundation
import TailnetFdPass
import XCTest

/// The ssh path: /usr/bin/ssh with ProxyUseFdpass and clotho-tailnet-proxy as its ProxyCommand reaches this
/// Mac's own sshd through the test tailnet (a test peer forwards its tailnet port 22 to 127.0.0.1:22) and reads
/// the server's SSH-2.0 banner. No keys and no login: ssh reads none of ~/.ssh and offers no authentication.
final class SSHProxyTests: TailnetTestCase {
    func testSSHBannerThroughTheTailnet() async throws {
        try XCTSkipUnless(Self.localSSHD(), "nothing listens on 127.0.0.1:22")
        let helper = try TestTailnet.binary("TAILNET_PROXY_HELPER")
        let peerIP = try startPeer(hostname: "cmac-sshpeer", forward: ["22=127.0.0.1:22"])
        let node = makeNode()
        try await startRunning(node)
        _ = try await waitForPeer(node, hostname: "cmac-sshpeer")
        // The peer must learn about this node too before it answers; one dial (retrying up to 30 s) waits for that,
        // so the timing below is ssh's alone.
        let warm = Date()
        close(try await node.dial(host: peerIP, port: 22, timeout: 30))
        print("MEASURE first dial to a new peer: \(Int(Date().timeIntervalSince(warm) * 1000)) ms")

        let socket = dir.appendingPathComponent("node/proxy.sock").path
        let server = TailnetProxyServer(node: node, socketPath: socket)
        try server.start()
        defer { server.stop() }
        var st = stat()
        XCTAssertEqual(lstat(socket, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        let t0 = Date()
        let (status, stderr) = try Self.ssh(helper: helper, socket: socket, host: peerIP)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertTrue(stderr.contains("Remote protocol version 2.0, remote software version OpenSSH"), "ssh exited \(status):\n\(stderr)")
        // No authentication was offered, so the server refuses the login: 255, after the banner.
        XCTAssertEqual(status, 255)
        print("MEASURE ssh through the tailnet: banner and refusal in \(Int(elapsed * 1000)) ms")
    }

    /// ssh's ConnectTimeout doesn't bound a ProxyUseFdpass handoff: the helper's own deadline does.
    func testHelperGivesUpAtItsDeadline() throws {
        let helper = try TestTailnet.binary("TAILNET_PROXY_HELPER")
        let socket = dir.appendingPathComponent("mute.sock").path
        let listener = tfp_listen(socket, 4)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener); unlink(socket) }
        // Accepts (the kernel does, through the backlog) and never answers.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["--socket", socket, "--timeout", "2", "100.64.0.9", "22"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        let t0 = Date()
        let status = try runToEnd(p, timeout: 10)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(status, 255)
        XCTAssertGreaterThan(elapsed, 1.8)
        XCTAssertLessThan(elapsed, 4)
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("clotho-tailnet-proxy: 100.64.0.9:22: no connection after 2.0 s"), text)
    }

    /// The server answers an unreachable peer with an error line, which the helper reports.
    func testHelperReportsDialErrors() async throws {
        let helper = try TestTailnet.binary("TAILNET_PROXY_HELPER")
        let node = makeNode()
        try await startRunning(node)
        let socket = dir.appendingPathComponent("node/proxy.sock").path
        let server = TailnetProxyServer(node: node, socketPath: socket, dialTimeout: 2)
        try server.start()
        defer { server.stop() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["--socket", socket, "--timeout", "8", "100.64.0.250", "22"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        XCTAssertEqual(try runToEnd(p, timeout: 15), 255)
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("clotho-tailnet-proxy: 100.64.0.250:22: "), text)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "stop() left the socket")
    }

    static func ssh(helper: String, socket: String, host: String) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-v", "-F", "/dev/null",
                       "-o", "ProxyCommand='\(helper)' --socket '\(socket)' %h %p",
                       "-o", "ProxyUseFdpass=yes",
                       "-o", "BatchMode=yes",
                       "-o", "StrictHostKeyChecking=no",
                       "-o", "UserKnownHostsFile=/dev/null",
                       "-o", "GlobalKnownHostsFile=/dev/null",
                       "-o", "PreferredAuthentications=none",
                       "-o", "PubkeyAuthentication=no",
                       "-o", "IdentityAgent=none",
                       "-o", "IdentitiesOnly=yes",
                       "-o", "ControlPath=none",
                       "-o", "ConnectTimeout=10",
                       "-l", "cmac-none", host, "true"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let status = try runToEnd(p, timeout: 20)
        return (status, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func localSSHD() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(22).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
