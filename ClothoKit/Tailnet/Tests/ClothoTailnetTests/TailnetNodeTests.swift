import ClothoTailnet
import Darwin
import Foundation
import XCTest

/// TailnetNode against the offline test tailnet (TestTailnet.swift).
final class TailnetNodeTests: TailnetTestCase {
    func testReachesRunningWithItsHostnameAndUser() async throws {
        let node = makeNode("cmac-node")
        try await startRunning(node)
        let status = try await node.status()
        XCTAssertEqual(status.backendState, "Running")
        let me = try XCTUnwrap(status.selfNode)
        XCTAssertEqual(me.hostName, "cmac-node")
        XCTAssertNotEqual(me.userID, 0)
        XCTAssertNotNil(me.primaryIP)
        XCTAssertTrue(me.dnsName.hasPrefix("cmac-node."), me.dnsName)
    }

    /// WhoIs tells the node's own user from a second user: what the peer check (decision 10) compares.
    func testWhoIsSameAndOtherUser() async throws {
        let sameIP = try startPeer(hostname: "cmac-peer")
        let otherIP = try startPeer(hostname: "other-cmac-peer")
        let node = makeNode()
        try await startRunning(node)
        _ = try await waitForPeer(node, hostname: "cmac-peer")
        _ = try await waitForPeer(node, hostname: "other-cmac-peer")
        let status = try await node.status()
        let me = try XCTUnwrap(status.selfNode)

        let same = try await node.whois(sameIP)
        XCTAssertEqual(same.user.id, me.userID)
        XCTAssertEqual(same.node.userID, me.userID)
        XCTAssertTrue(same.node.name.hasPrefix("cmac-peer."), same.node.name)
        XCTAssertTrue(same.node.tags.isEmpty)
        XCTAssertNil(same.node.sharer)

        let other = try await node.whois(otherIP + ":22")
        XCTAssertNotEqual(other.user.id, me.userID)
    }

    func testLogoutNeedsLoginAgain() async throws {
        let node = makeNode()
        try await startRunning(node)
        try await node.logout()
        let state = await node.waitForState(timeout: 15) { if case .needsLogin = $0 { return true }; return false }
        guard case .needsLogin = state else { return XCTFail("after logout: \(state)") }
    }

    /// stop() never waits for tsnet's Close (tailscale#21353), and calls after it fail at once.
    func testStopReturnsAtOnce() async throws {
        let node = makeNode()
        try await startRunning(node)
        let t0 = Date()
        node.stop()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 0.05, "stop() took \(Int(elapsed * 1000)) ms")
        XCTAssertEqual(node.state, .stopped)
        do {
            _ = try await node.status()
            XCTFail("status after stop")
        } catch {
            XCTAssertEqual(error as? TailnetError, .stopped)
        }
        XCTAssertThrowsError(try node.dialSync(host: "100.64.0.1", port: 22, timeout: 1)) { XCTAssertEqual($0 as? TailnetError, .stopped) }
        let t1 = Date()
        XCTAssertTrue(node.waitForClose(timeout: 15), "the background shutdown didn't finish")
        print("MEASURE stop: returned in \(String(format: "%.2f", elapsed * 1000)) ms; background shutdown done \(Int(Date().timeIntervalSince(t1) * 1000)) ms later")
    }

    func testRefusesUnsafeConfigurations() throws {
        let tsControl = URL(string: "https://controlplane.tailscale.com")!
        for (config, why) in [
            (TailnetNode.Configuration(dir: dir.appendingPathComponent("a"), hostname: "cmac-x", controlURL: nil, testMode: true), "test mode, Tailscale's control"),
            (TailnetNode.Configuration(dir: dir.appendingPathComponent("b"), hostname: "cmac-x", controlURL: tsControl, testMode: true), "test mode, remote control"),
            (TailnetNode.Configuration(dir: URL(string: "relative/dir")!, hostname: "cmac-x", controlURL: control, testMode: true), "relative dir"),
            (TailnetNode.Configuration(dir: dir.appendingPathComponent("c"), hostname: "", controlURL: control, testMode: true), "no hostname"),
        ] {
            let node = TailnetNode(configuration: config)
            XCTAssertThrowsError(try node.start(), why)
            XCTAssertEqual(node.state, .stopped, why)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a").path), "a refused node made its dir")
    }

    func testDefaultHostname() {
        XCTAssertEqual(TailnetNode.defaultHostname(device: "Ahmad's MacBook Pro", dev: false), "clotho-ahmad-s-macbook-pro")
        XCTAssertEqual(TailnetNode.defaultHostname(device: "studio", dev: true), "clotho-studio-dev")
        XCTAssertEqual(TailnetNode.defaultHostname(device: "", dev: false), "clotho-mac")
        XCTAssertEqual(TailnetNode.defaultHostname(device: String(repeating: "x", count: 100), dev: true).count, 63)
    }

    /// The node's files stay in its dir: nothing in tailscaled's default dir (TS_LOGS_DIR).
    func testNothingOutsideTheNodeDir() async throws {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/tailscale").path
        try XCTSkipIf(FileManager.default.fileExists(atPath: defaultDir), "\(defaultDir) already exists")
        let node = makeNode()
        try await startRunning(node)
        node.stop()
        XCTAssertTrue(node.waitForClose(timeout: 15))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDir), "the node created \(defaultDir)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("node/tailscaled.state").path))
        var st = stat()
        XCTAssertEqual(lstat(dir.appendingPathComponent("node").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }
}

/// Sign-in: testctl with --require-auth, whose AuthURL a plain GET completes (like a browser visit).
final class TailnetLoginTests: TailnetTestCase {
    override var requireAuth: Bool { true }

    func testInteractiveLogin() async throws {
        let node = makeNode()
        try node.start()
        let state = await node.waitForState(timeout: 30) { if case .needsLogin(let url) = $0 { return url != nil }; return false }
        guard case .needsLogin(let url?) = state else { return XCTFail("want needsLogin with a URL, got \(state)") }
        XCTAssertEqual(url.host, "127.0.0.1")
        try await visit(url)
        let running = await node.waitForState(timeout: 30) { $0 == .running }
        XCTAssertEqual(running, .running)

        // login() after logout hands out a new URL.
        try await node.logout()
        _ = await node.waitForState(timeout: 15) { if case .needsLogin = $0 { return true }; return false }
        let again = try await node.login()
        let url2 = try XCTUnwrap(again)
        try await visit(url2)
        let runningAgain = await node.waitForState(timeout: 30) { $0 == .running }
        XCTAssertEqual(runningAgain, .running)
    }

    /// The Mac keeps state in files: a node started again on the same dir runs without a new sign-in.
    func testRestartFromSavedFileState() async throws {
        let first = makeNode(ephemeral: false)
        try await signIn(first)
        first.stop()
        XCTAssertTrue(first.waitForClose(timeout: 15))

        let second = makeNode(ephemeral: false)
        let t0 = Date()
        try await startRunning(second, timeout: 20)
        print("MEASURE time to Running from saved state (files): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    /// iOS keeps state in the Keychain through the store callbacks: the same, with a store.
    func testRestartFromSavedStoreState() async throws {
        let store = MemoryStateStore()
        let first = makeNode(ephemeral: false, store: store)
        try await signIn(first)
        first.stop()
        XCTAssertTrue(first.waitForClose(timeout: 15))
        XCTAssertTrue(store.keys.contains("_machinekey"), "\(store.keys)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("node/tailscaled.state").path), "a store node wrote a state file")

        let second = makeNode(ephemeral: false, store: store)
        let t0 = Date()
        try await startRunning(second, timeout: 20)
        print("MEASURE time to Running from saved state (store): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    private func signIn(_ node: TailnetNode) async throws {
        try node.start()
        let state = await node.waitForState(timeout: 30) { if case .needsLogin(let url) = $0 { return url != nil }; return false }
        guard case .needsLogin(let url?) = state else { throw TailnetError.failed("want needsLogin with a URL, got \(state)") }
        try await visit(url)
        let running = await node.waitForState(timeout: 30) { $0 == .running }
        XCTAssertEqual(running, .running)
    }
}
