import ClothoTailnet
import Foundation
import XCTest

/// The offline test tailnet: clothod's testctl (a Tailscale test control server, DERP and STUN on 127.0.0.1)
/// and test-only peers, all in this run's dir under /tmp/cmac-. Nothing here ever reaches Tailscale or the
/// user's tailnet. scripts/test.sh builds the binaries and sets the environment:
///
///   TAILNET_TEST_DIR      this run's dir (/tmp/cmac-tn.*); every node dir is under it
///   TAILNET_TESTCTL       clothod/net's testctl
///   TAILNET_TESTPEER      go/cmd/tailnet-testpeer
///   CLOTHOD_NET_BIN       clothod-net (end to end)
///   CLOTHOD_BIN           clothod (end to end)
///   TAILNET_PROXY_HELPER  clotho-tailnet-proxy (the ssh test)
enum TestTailnet {
    static let env = ProcessInfo.processInfo.environment

    /// The run's dir; refuses anything outside /tmp/cmac- (the mac role's test dirs).
    static func runDir() throws -> URL {
        guard let dir = env["TAILNET_TEST_DIR"] else { throw XCTSkip("TAILNET_TEST_DIR isn't set: run scripts/test.sh") }
        precondition(dir.hasPrefix("/tmp/cmac-") || dir.hasPrefix("/private/tmp/cmac-"), "test dirs live in /tmp/cmac-*, not \(dir)")
        return URL(fileURLWithPath: dir)
    }

    static func binary(_ name: String) throws -> String {
        guard let path = env[name], FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("\(name) isn't set to an executable: run scripts/test.sh")
        }
        return path
    }

    static func node(dir: URL, hostname: String, control: URL, ephemeral: Bool = true, store: TailnetStateStore? = nil) -> TailnetNode {
        precondition(dir.path.hasPrefix("/tmp/cmac-") || dir.path.hasPrefix("/private/tmp/cmac-"))
        precondition(["127.0.0.1", "localhost", "::1"].contains(control.host ?? ""), "test nodes only join a control server on this machine")
        return TailnetNode(configuration: .init(dir: dir, hostname: hostname, controlURL: control, ephemeral: ephemeral, testMode: true,
                                                store: store, log: nil))
    }
}

/// A helper process for a test: its stdin stays open (testctl and the test peer exit when it closes), its
/// stdout is read for `key=value` lines, and its stderr goes to a log in the run's dir.
final class TestProcess: @unchecked Sendable {
    let name: String
    let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""
    /// Left when the process exits. Not Process.isRunning or waitUntilExit: those wait on the main queue, which
    /// XCTest's tearDown blocks (a hang seen with async tests).
    private let exited = DispatchGroup()
    let logURL: URL

    init(_ name: String, executable: String, arguments: [String], dir: URL, environment: [String: String] = [:]) throws {
        self.name = name
        logURL = dir.appendingPathComponent("\(name).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "TS_LOGS_DIR" }.merging(environment) { $1 }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: logURL)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.locked {
                self.partial += String(decoding: data, as: UTF8.self)
                while let nl = self.partial.firstIndex(of: "\n") {
                    self.lines.append(String(self.partial[..<nl]))
                    self.partial.removeSubrange(...nl)
                }
            }
        }
        exited.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
        try process.run()
    }

    var isRunning: Bool { exited.wait(timeout: .now()) == .timedOut }

    /// The value of the first stdout line `key=value`, waiting up to `timeout`.
    func value(_ key: String, timeout: TimeInterval = 30) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = lock.locked({ lines.first { $0.hasPrefix(key + "=") } }) { return String(line.dropFirst(key.count + 1)) }
            if !isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TailnetError.failed("\(name): no \(key)= line (running: \(isRunning))\n\(log)")
    }

    var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    /// Closes stdin, then SIGTERM, then SIGKILL; waits for the exit.
    func stop() {
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 3) == .success { return }
        kill(process.processIdentifier, SIGTERM)
        if exited.wait(timeout: .now() + 5) == .success { return }
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 5)
    }
}

/// Runs a process to its end (SIGTERM after `timeout`): its exit status. Waits with terminationHandler, never
/// waitUntilExit (see TestProcess.exited).
@discardableResult
func runToEnd(_ process: Process, timeout: TimeInterval) throws -> Int32 {
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        kill(process.processIdentifier, SIGTERM)
        if done.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 3)
        }
    }
    return process.terminationStatus
}

/// Starts a fresh testctl per test (cheap: about 50 ms) and cleans up after it.
class TailnetTestCase: XCTestCase {
    var dir: URL!
    var control: URL!
    var processes: [TestProcess] = []
    var nodes: [TailnetNode] = []
    /// Start testctl with --require-auth: new nodes need their AuthURL visited.
    var requireAuth: Bool { false }

    override func setUpWithError() throws {
        let root = try TestTailnet.runDir()
        dir = root.appendingPathComponent("\(name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test")")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        control = try startControl(requireAuth: requireAuth)
    }

    override func tearDown() {
        nodes.forEach { $0.stop() }
        for node in nodes { _ = node.waitForClose(timeout: 10) }
        nodes.removeAll()
        processes.reversed().forEach { $0.stop() }
        if testRun?.hasSucceeded == false {
            for p in processes { print("--- \(p.name).log:\n\(p.log)") }
        }
        processes.removeAll()
    }

    func startControl(requireAuth: Bool) throws -> URL {
        var args = ["--exit-with-stdin"]
        if requireAuth { args.append("--require-auth") }
        let p = try TestProcess("testctl", executable: try TestTailnet.binary("TAILNET_TESTCTL"), arguments: args, dir: dir)
        processes.append(p)
        let url = try XCTUnwrap(URL(string: try p.value("control_url")))
        precondition(url.host == "127.0.0.1", "testctl must serve on loopback")
        return url
    }

    /// A test-only peer (go/cmd/tailnet-testpeer); its tailnet IPv4.
    func startPeer(hostname: String, forward: [String] = []) throws -> String {
        var args = ["--control-url", control.absoluteString, "--dir", dir.appendingPathComponent("peer-\(hostname)").path, "--hostname", hostname]
        for f in forward { args += ["--forward", f] }
        let p = try TestProcess("peer-\(hostname)", executable: try TestTailnet.binary("TAILNET_TESTPEER"), arguments: args, dir: dir)
        processes.append(p)
        return try p.value("ip", timeout: 60)
    }

    func makeNode(_ hostname: String = "cmac-node", subdir: String = "node", ephemeral: Bool = true, store: TailnetStateStore? = nil) -> TailnetNode {
        let node = TestTailnet.node(dir: dir.appendingPathComponent(subdir), hostname: hostname, control: control, ephemeral: ephemeral, store: store)
        nodes.append(node)
        return node
    }

    /// Starts the node and waits until it runs.
    func startRunning(_ node: TailnetNode, timeout: TimeInterval = 30) async throws {
        try node.start()
        let state = await node.waitForState(timeout: timeout) { $0 == .running }
        XCTAssertEqual(state, .running, "the node didn't reach Running in \(timeout) s")
        guard state == .running else { throw TailnetError.failed("not running: \(state)") }
    }

    /// Waits until a peer with that hostname is in the node's netmap; its first IP.
    func waitForPeer(_ node: TailnetNode, hostname: String, timeout: TimeInterval = 30) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ip = try await node.status().peers.first(where: { $0.hostName == hostname })?.primaryIP { return ip }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TailnetError.failed("no peer \(hostname) after \(timeout) s")
    }

    /// A plain GET, as a browser visit to testctl's auth URL.
    func visit(_ url: URL) async throws {
        guard url.host == control.host, url.port == control.port else {
            throw TailnetError.failed("only the test control server's URLs: \(url.absoluteString)")
        }
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
