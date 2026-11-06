import ClothoKit
import ClothoTailnet
import Foundation
import XCTest

/// End to end: clothod-net serve (clothod's sidecar, a test instance) fronts an ephemeral clothod, all in this
/// run's dir; a TailnetNode dials it, and ClothodBackend's hello succeeds over that connection.
final class ClothodOverTailnetTests: TailnetTestCase {
    var clothod: String?
    var runtimeDir: String?

    override func tearDown() {
        super.tearDown() // stops clothod-net (SIGTERM) and testctl
        if let clothod, let runtimeDir {
            run(clothod, ["shutdown", "--runtime-dir", runtimeDir])
            run("/usr/bin/pkill", ["-f", "runtime-dir \(runtimeDir)"])
        }
    }

    func testClothodHelloOverTheTailnet() async throws {
        let net = try TestTailnet.binary("CLOTHOD_NET_BIN")
        let clothod = try TestTailnet.binary("CLOTHOD_BIN")
        self.clothod = clothod
        // Short: clothod's socket path must fit in sun_path.
        let rt = dir.appendingPathComponent("rt").path
        runtimeDir = rt
        let env = [
            "CLOTHOD_STATE_DIR": dir.appendingPathComponent("state").path,
            "CLOTHOD_RUNTIME_DIR": rt,
            "CLOTHOD_REGISTRY_DIR": dir.appendingPathComponent("registry").path,
            "CLOTHOD_CONFIG": dir.appendingPathComponent("config.toml").path,
            "CLAUDE_CONFIG_DIR": dir.appendingPathComponent("claude-config").path,
            "XDG_DATA_HOME": dir.appendingPathComponent("xdg-data").path,
        ]
        let port = 7443
        let serve = try TestProcess("clothod-net", executable: net, arguments: [
            "serve", "--port", "\(port)", "--hostname", "cmac-serve",
            "--state-dir", dir.appendingPathComponent("net").path, "--control-url", control.absoluteString, "--ephemeral",
            "--clothod", clothod, "--runtime-dir", rt,
        ], dir: dir, environment: env)
        processes.append(serve)

        let node = makeNode("cmac-client")
        let t0 = Date()
        try await startRunning(node)
        let joined = Date().timeIntervalSince(t0)
        let ip = try await waitForPeer(node, hostname: "cmac-serve", timeout: 60)

        let backend = ClothodBackend(configuration: .init(transport: TailnetTransport(node: node, host: ip, port: port), clientName: "tailnet-tests"))
        defer { backend.stop() }
        let t1 = Date()
        let hello = Task { () -> Hello? in
            for await event in backend.events { if case .connected(let h) = event { return h } }
            return nil
        }
        try await backend.start()
        _ = try await backend.getState() // a request and its reply, after the hello
        let helloReply = await hello.value
        XCTAssertEqual(helloReply?.protocol, ClothodBackend.protocolVersion)
        print("MEASURE e2e: node Running in \(Int(joined * 1000)) ms; dial + clothod start + hello + state in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
        XCTAssertTrue(serve.log.contains("accepted"), serve.log)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["CLOTHOD_RUNTIME_DIR": runtimeDir ?? ""]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? runToEnd(p, timeout: 15)) ?? -1
    }
}
