#if CLOTHO_TAILNET
@testable import Clotho
import CryptoKit
import SwiftUI
import XCTest

/// The app's tailnet node (TailnetController) in the simulator, offline: clothod's testctl and a test peer that
/// ios/scripts/tailnet-test-net.sh starts (CLOTHO_TAILNET=1 ./build.sh test does), with the peer's tailnet port
/// 22 forwarded to the throwaway sshd (ios/scripts/ssh-test-server.sh). Skipped without them. The tests use only
/// the controller's plain Swift API, never ClothoTailnet's types: this bundle doesn't link the node, the app does.
/// State goes to the Keychain's test service, node dirs to /tmp/cki-tailnet/unit-*.
@MainActor
final class TailnetNodeAppTests: XCTestCase {
    private var net: (control: URL, auth: URL, peer: String)!
    private var controllers: [TailnetController] = []
    private var dirs: [URL] = []
    private let machineID = UUID(uuidString: "5E55E55E-0000-0000-0000-00000000007A")!

    override func setUp() async throws {
        func read(_ name: String) -> String? {
            (try? String(contentsOfFile: "/tmp/cki-tailnet/\(name)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let control = read("control_url").flatMap(URL.init(string:)), let auth = read("auth_control_url").flatMap(URL.init(string:)),
              let peer = read("peer_ip"), !peer.isEmpty else {
            throw XCTSkip("no test tailnet (scripts/tailnet-test-net.sh start)")
        }
        // Never a real control server.
        XCTAssertEqual(control.host, "127.0.0.1")
        XCTAssertEqual(auth.host, "127.0.0.1")
        net = (control, auth, peer)
        TailnetKeychainStore.deleteAll(.test)
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.routeSSH = false
            controller.stop()
            let closed = await controller.waitForClose(timeout: 10)
            if !closed { print("tailnet test: a node didn't close within 10 s") }
        }
        controllers = []
        SSHSession.socketDialer = nil
        TailnetKeychainStore.deleteAll(.test)
        TrustedHostKeys.shared.set(nil, for: machineID)
        KeyStore.delete("ssh-tailnet-test")
        for key in ["TailnetProbe", "TailnetForceRecreate"] { UserDefaults.standard.removeObject(forKey: key) }
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
    }

    private func controller(_ name: String, control: URL? = nil) -> TailnetController {
        let dir = URL(fileURLWithPath: "/tmp/cki-tailnet/unit-\(name)", isDirectory: true)
        if !dirs.contains(dir) { dirs.append(dir) }
        let url = control ?? net.control
        let settings = TailnetSettings(controlURL: url, dir: dir, hostname: "cki-ios-\(name)",
                                       testMode: TailnetSettings.isLoopback(url))
        let controller = TailnetController(settings: settings, service: .test)
        controllers.append(controller)
        return controller
    }

    private func running(_ controller: TailnetController, timeout: TimeInterval = 30) async throws {
        controller.start()
        let ok = await controller.waitUntilRunning(timeout: timeout)
        XCTAssertTrue(ok, "not Running after \(Int(timeout)) s: \(controller.stateText) \(controller.lastError ?? "")")
        if !ok { throw XCTSkip("the node didn't run") }
        await controller.refresh()
    }

    private func waitForPeer(_ controller: TailnetController) async throws {
        for _ in 0..<60 {
            await controller.refresh()
            if controller.peers.contains(where: { $0.ip == net.peer }) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("the test peer \(net.peer) never showed up: \(controller.peers)")
    }

    func testReachesRunningWithStateInKeychain() async throws {
        let devBefore = TailnetKeychainStore(service: .dev).keys()
        let tailnet = controller("running")
        try await running(tailnet)
        XCTAssertFalse(tailnet.selfIPs.isEmpty)
        XCTAssertNotNil(tailnet.selfStableID)
        XCTAssertNotNil(tailnet.startToRunning)
        print("tailnet test: start to Running \(String(format: "%.2f", tailnet.startToRunning ?? -1)) s, footprint \(String(format: "%.1f", TailnetController.footprintMB)) MB")
        let keys = TailnetKeychainStore(service: .test).keys()
        XCTAssertTrue(keys.contains("_machinekey"), "\(keys)")
        XCTAssertTrue(keys.contains("_current-profile"), "\(keys)")
        XCTAssertEqual(TailnetKeychainStore(service: .dev).keys(), devBefore, "a test node wrote the debug node's state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailnet.settings.dir.appendingPathComponent("tailscaled.state").path),
                       "the state went to a file, not the Keychain")
    }

    /// Signed in once (a GET of the login URL, as a browser would), the node starts again from its Keychain state
    /// as the same node, without needing a login.
    func testRestartFromKeychainNeedsNoNewLogin() async throws {
        let first = controller("restart", control: net.auth)
        first.start()
        let loginURL = await first.waitForLoginURL(timeout: 30)
        let url = try XCTUnwrap(loginURL, "no login URL: \(first.stateText)")
        XCTAssertEqual(url.host, net.auth.host)
        XCTAssertEqual(url.port, net.auth.port)
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let ran = await first.waitUntilRunning(timeout: 30)
        XCTAssertTrue(ran, first.stateText)
        await first.refresh()
        XCTAssertTrue(first.stateHistory.contains("NeedsLogin"), "\(first.stateHistory)")
        let id = try XCTUnwrap(first.selfStableID)
        let ips = first.selfIPs
        first.stop()
        let closed = await first.waitForClose(timeout: 10)
        XCTAssertTrue(closed, "the first node didn't shut down")

        let second = controller("restart", control: net.auth)
        try await running(second)
        XCTAssertFalse(second.stateHistory.contains("NeedsLogin"), "needed a new login: \(second.stateHistory)")
        XCTAssertEqual(second.selfStableID, id)
        XCTAssertEqual(second.selfIPs, ips)
    }

    func testDialPeerReadsSSHBanner() async throws {
        let tailnet = controller("dial")
        try await running(tailnet)
        try await waitForPeer(tailnet)
        let first = await tailnet.dial(host: net.peer, port: 22)
        XCTAssertTrue(first.hasPrefix("SSH-2.0-"), first)
    }

    /// SSHSession's dial mode over the node: the host key in the key exchange, then a login and a command with the
    /// throwaway test key (nothing in anyone's ~/.ssh).
    func testSSHOverTailnet() async throws {
        let ssh = URL(fileURLWithPath: "/tmp/clotho-ios-sshtest")
        func read(_ name: String) -> String? {
            (try? String(contentsOf: ssh.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let seedHex = read("seed.hex"), let user = read("user"), let hostKey = read("host_ed25519.pub") else {
            throw XCTSkip("no SSH test server")
        }
        let tailnet = controller("ssh")
        try await running(tailnet)
        try await waitForPeer(tailnet)
        tailnet.routeSSH = true
        let peer = net.peer
        let presented = try await Task.detached { try SSHSession.presentedHostKey(host: peer, port: 22) }.value
        XCTAssertEqual(presented.split(separator: " ").prefix(2), hostKey.split(separator: " ").prefix(2))
        let fingerprint = try await tailnet.sshHandshake(host: peer, port: 22)
        XCTAssertEqual(fingerprint, HostKeys.fingerprint(hostKey))

        let seed = Data(stride(from: 0, to: seedHex.count, by: 2).map {
            UInt8(seedHex[seedHex.index(seedHex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
        let key = SSHKey(id: "ssh-tailnet-test", name: "clotho-ios-dev-test", kind: .ed25519, created: Date(),
                         secret: try Curve25519.Signing.PrivateKey(rawRepresentation: seed).rawRepresentation)
        try KeyStore.save(key)
        let machine = Machine(id: machineID, name: "tailnet ssh test", host: peer, port: 22, user: user, keyID: key.id, devDirs: true)
        TrustedHostKeys.shared.set(nil, for: machine.id)
        let result = try await Task.detached {
            let runner = NIOCommandRunner(machine: machine)
            defer { runner.reset() }
            return try runner.run("echo hi", input: nil)
        }.value
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "hi\n")
    }

    /// The foreground check, forced to find the node dead: a new node on the same Keychain store runs as the
    /// same node without a login, and the probe dials; the SSH route follows the new node.
    func testForegroundRecreatesDeadNode() async throws {
        let tailnet = controller("recreate")
        try await running(tailnet)
        try await waitForPeer(tailnet)
        let id = tailnet.selfStableID
        tailnet.routeSSH = true
        tailnet.probeTarget = "\(net.peer):22"
        tailnet.forceUnhealthyOnForeground = true
        let t0 = Date()
        let maybeTiming = await tailnet.didBecomeActive()
        let timing = try XCTUnwrap(maybeTiming)
        print("tailnet test: foreground recreate: \(timing.summary) (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
        XCTAssertTrue(timing.forced)
        XCTAssertFalse(timing.healthy)
        XCTAssertTrue(timing.recreated)
        XCTAssertNil(timing.error)
        XCTAssertNotNil(timing.oldClosed)
        let dialAfter = try XCTUnwrap(timing.dialAfter)
        XCTAssertLessThan(dialAfter, 15)
        XCTAssertFalse(tailnet.forceUnhealthyOnForeground, "the one-time switch wasn't cleared")
        XCTAssertTrue(tailnet.isRunning)
        XCTAssertFalse(tailnet.stateHistory.contains("NeedsLogin"), "\(tailnet.stateHistory)")
        await tailnet.refresh()
        XCTAssertEqual(tailnet.selfStableID, id, "the recreated node isn't the same node")
        XCTAssertLessThanOrEqual(tailnet.retiredCount, 1)
        XCTAssertEqual(tailnet.timings.first, timing)
        let peer = net.peer
        let presented = try await Task.detached { try SSHSession.presentedHostKey(host: peer, port: 22) }.value
        XCTAssertTrue(presented.hasPrefix("ssh-ed25519 "), presented)
    }

    func testForegroundKeepsHealthyNode() async throws {
        let tailnet = controller("healthy")
        try await running(tailnet)
        try await waitForPeer(tailnet)
        tailnet.probeTarget = "\(net.peer):22"
        let maybeTiming = await tailnet.didBecomeActive()
        let timing = try XCTUnwrap(maybeTiming)
        print("tailnet test: foreground, healthy: \(timing.summary)")
        XCTAssertTrue(timing.healthy)
        XCTAssertFalse(timing.recreated)
        XCTAssertNil(timing.error)
        XCTAssertLessThan(try XCTUnwrap(timing.dialAfter), 3)
        XCTAssertEqual(tailnet.retiredCount, 0)
    }

    /// A foreground while the node is signing in (the user went to another app for a 2FA code or a magic link)
    /// leaves the node alone, even with the dead switch on: no recreate, so the same login URL and the same node.
    func testForegroundLeavesSigningInNode() async throws {
        let tailnet = controller("signing-in", control: net.auth)
        tailnet.start()
        let loginURL = await tailnet.waitForLoginURL(timeout: 30)
        let url = try XCTUnwrap(loginURL, "no login URL: \(tailnet.stateText)")
        for _ in 0..<20 where tailnet.loginURL == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(tailnet.loginURL, url)
        tailnet.forceUnhealthyOnForeground = true
        tailnet.sceneChanged(.background)
        let maybeTiming = await tailnet.didBecomeActive()
        let timing = try XCTUnwrap(maybeTiming)
        print("tailnet test: foreground while signing in: \(timing.summary)")
        XCTAssertFalse(timing.recreated)
        XCTAssertEqual(timing.skipped, "Needs sign-in")
        XCTAssertTrue(tailnet.forceUnhealthyOnForeground, "the dead switch was used up on a node it didn't check")
        XCTAssertEqual(tailnet.retiredCount, 0)
        XCTAssertTrue(tailnet.hasNode)
        XCTAssertTrue(tailnet.needsLogin)
        XCTAssertEqual(tailnet.loginURL, url)
        let again = await tailnet.waitForLoginURL(timeout: 1)
        XCTAssertEqual(again, url, "the login URL changed")
    }

    /// A start the shim refuses (test mode with a control server that isn't on this machine) fails on a background
    /// thread: start() returns at once on the main thread, and the error shows up after.
    func testStartFailureNeverBlocksMain() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cki-tailnet/unit-refused", isDirectory: true)
        dirs.append(dir)
        let settings = TailnetSettings(controlURL: URL(string: "http://192.0.2.1:1"), dir: dir, hostname: "cki-ios-refused", testMode: true)
        let tailnet = TailnetController(settings: settings, service: .test)
        controllers.append(tailnet)
        let t0 = Date()
        tailnet.start()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
        for _ in 0..<50 where tailnet.lastError == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        let error = try XCTUnwrap(tailnet.lastError, "no error within 5 s")
        print("tailnet test: refused start: \(error)")
        XCTAssertFalse(tailnet.hasNode)
        XCTAssertFalse(tailnet.isRunning)
    }
}
#endif
