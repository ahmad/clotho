@testable import ClothoKit
import XCTest

/// Runs against a real clothod in a private runtime directory. Skipped when the binary isn't built
/// (CLOTHOD_BIN, or ../clothod/target/debug/clothod next to this package).
final class ClothodBackendTests: XCTestCase {
    var clothod: String!
    var runtimeDir: String!

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        clothod = ProcessInfo.processInfo.environment["CLOTHOD_BIN"]
            ?? package.deletingLastPathComponent().appendingPathComponent("clothod/target/debug/clothod").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clothod), "clothod isn't built")
        // Short, so the socket path fits in sun_path.
        // One daemon per test: a shared directory let one test's shutdown race the next test's start.
        runtimeDir = "/tmp/ckt-\(getpid())-\(UUID().uuidString.prefix(6))"
    }

    override func tearDown() {
        if let clothod, let runtimeDir {
            _ = try? run(clothod, ["shutdown"])
            // shutdown needs the logic process; if a test killed it, stop whatever still uses this test's dir.
            _ = try? run("/usr/bin/pkill", ["-f", "runtime-dir \(runtimeDir)"])
            try? FileManager.default.removeItem(atPath: runtimeDir)
        }
    }

    @discardableResult
    func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // A private runtime dir needs an ephemeral instance; it also cleans itself up if a test dies.
        // Its own config too, so settings.set never writes the user's.
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CLOTHOD_RUNTIME_DIR": runtimeDir, "CLOTHOD_EPHEMERAL": "60", "CLOTHOD_CONFIG": runtimeDir + "/config.toml",
        ]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func makeBackend() -> ClothodBackend {
        let clothod = clothod!, dir = runtimeDir!
        return ClothodBackend(configuration: .init(
            socketPath: ClothodBackend.defaultSocketPath(runtimeDir: dir), clientName: "clothokit-tests",
            startDaemon: { [self] in
                _ = try self.run(clothod, ["start"])
                _ = dir
            }))
    }

    func testRoundTripAndReconnect() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }

        // Starts the daemon on demand.
        try await backend.start()
        let hellos = { collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil } }
        try await waitFor("hello") { !hellos().isEmpty }
        let hello = try XCTUnwrap(hellos().first)
        XCTAssertEqual(hello.protocol, 1)

        let created = try await backend.createWorkspace(name: "kit", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        let first = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 90, rows: 20))
        XCTAssertEqual(first.mode, .snapshot)
        XCTAssertEqual(first.cols, 90)
        try await waitFor("state with the workspace") { collector.lastState?.workspaces.contains { $0.id == created.workspace } == true }

        backend.sendInput(created.pane, Data("echo one-''-clotho\n".utf8))
        try await waitFor("first output") { collector.output(of: created.pane).contains("one--clotho") }

        // Kill the logic process; the holder keeps the shell, and the backend reconnects by itself.
        let pid = try XCTUnwrap(hello.pid)
        kill(pid, SIGKILL)
        try await waitFor("reconnect", timeout: 15) { hellos().count >= 2 }
        XCTAssertEqual(hellos().last?.instance, hello.instance, "the holder survived, so the instance is the same")
        XCTAssertNotEqual(hellos().last?.pid, hello.pid)
        // The pane was resubscribed from where it left off.
        try await waitFor("resubscribe") {
            collector.all.filter { if case .subscribed(let p, _) = $0 { return p == created.pane }; return false }.count >= 2
        }
        backend.sendInput(created.pane, Data("echo two-''-clotho\n".utf8))
        try await waitFor("output after reconnect") { collector.output(of: created.pane).contains("two--clotho") }
        let state = try await backend.getState()
        XCTAssertNotNil(state.pane(created.pane))
    }

    /// pane.keys: detected after hello, then text and a named key typed into a shell.
    func testSendKeys() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        let hello = { collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil }.first }
        try await waitFor("hello") { hello() != nil }
        try XCTSkipUnless(hello()?.features.contains(.paneKeys) == true, "this clothod predates pane.keys")
        let created = try await backend.createWorkspace(name: "keys", spawn: SpawnOptions(command: ["/bin/sh"]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 80, rows: 20))
        try await backend.sendKeys(created.pane, text: "echo typed-''-by-keys", keys: ["enter"])
        try await waitFor("keys output") { collector.output(of: created.pane).contains("typed--by-keys") }
    }

    /// pane.clipboard: an OSC 52 copy in a subscribed pane arrives as a clipboard event.
    func testClipboardEvent() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        let hello = { collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil }.first }
        try await waitFor("hello") { hello() != nil }
        try XCTSkipUnless(hello()?.features.contains(.paneClipboard) == true, "this clothod predates pane.clipboard")
        let created = try await backend.createWorkspace(name: "clip", spawn: SpawnOptions(command: ["/bin/sh"]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 80, rows: 20))
        // "hello clip"; a read (?) must produce nothing.
        backend.sendInput(created.pane, Data("printf '\\033]52;c;?\\007\\033]52;c;aGVsbG8gY2xpcA==\\007'\n".utf8))
        let clips = { collector.all.compactMap { e -> String? in
            if case let .clipboard(p, text, false) = e, p == created.pane { return text }
            return nil
        } }
        try await waitFor("clipboard event") { !clips().isEmpty }
        XCTAssertEqual(clips(), ["hello clip"])
    }

    /// settings.get / settings.set against the test daemon's own config file, and the settings event.
    func testSettings() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        let hello = { collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil }.first }
        try await waitFor("hello") { hello() != nil }
        try XCTSkipUnless(hello()?.features.contains(.settings) == true, "this clothod predates settings")
        let before = try await backend.getSettings()
        // Never write anything but this test's config.
        XCTAssertEqual(before.config, runtimeDir + "/config.toml")
        guard before.config == runtimeDir + "/config.toml" else { return }
        let limits = before.limits.scrollbackLines
        XCTAssertLessThanOrEqual(limits.min, limits.default)
        XCTAssertLessThanOrEqual(limits.default, limits.max)

        let created = try await backend.createWorkspace(name: "settings", spawn: SpawnOptions(command: ["/bin/sh"]))
        let target = limits.default == 1000 ? 1200 : 1000
        let after = try await backend.setSettings(.init(scrollbackLines: target))
        XCTAssertEqual(after.scrollbackLines, target)
        XCTAssertEqual(after.appliedPanes, [created.pane])
        try await waitFor("settings event") {
            collector.all.contains { if case .settings(let s) = $0 { return s.scrollbackLines == target }; return false }
        }
        let config = try String(contentsOfFile: runtimeDir + "/config.toml", encoding: .utf8)
        XCTAssertTrue(config.contains("\(target)"), config)

        // Out of range: refused, nothing changes.
        do {
            _ = try await backend.setSettings(.init(scrollbackLines: limits.max + 1))
            XCTFail("an out-of-range value was accepted")
        } catch let error as BackendError {
            XCTAssertEqual(error.code, "bad_request")
        }
        let again = try await backend.getSettings()
        XCTAssertEqual(again.scrollbackLines, target)
    }

    /// service.status on a test instance: it reports, but this test never installs (on macOS that loads a
    /// launchd agent into the GUI session). A test instance without its own label is refused outright.
    func testServiceStatus() async throws {
        let backend = makeBackend()
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        try await backend.start()
        let hello = { collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil }.first }
        try await waitFor("hello") { hello() != nil }
        try XCTSkipUnless(hello()?.features.contains(.service) == true, "this clothod predates service")
        do {
            _ = try await backend.serviceStatus()
            XCTFail("a test instance without its own label must be refused")
        } catch let error as BackendError {
            XCTAssertEqual(error.code, "bad_request", error.message)
        }
    }

    func testDecodesService() throws {
        let json: [String: Any] = [
            "supported": true, "manager": "systemd", "label": "nyc.amin.clotho.clothod", "file": "/home/a/.config/systemd/user/x.service",
            "installed": false, "loaded": false, "up_to_date": false, "command": ["/x/clothod", "start"], "linger": false,
            "needs": ["linger"], "message": "Run sudo loginctl enable-linger a",
        ]
        let service = try ClothodBackend.decode(DaemonService.self, from: json)
        XCTAssertEqual(service.linger, false)
        XCTAssertEqual(service.needs, ["linger"])
        XCTAssertFalse(service.installed)
        let mac = try ClothodBackend.decode(DaemonService.self, from: ["supported": true, "installed": true, "loaded": true,
                                                                      "up_to_date": true, "linger": NSNull(), "needs": [String]()])
        XCTAssertNil(mac.linger)
        XCTAssertTrue(mac.upToDate)
    }

    /// The process transport, with a stand-in "ssh" that pipes stdio to the local daemon's socket (what
    /// `clothod bridge` will do on a remote machine), through a full session and a logic-process restart.
    func testProcessTransport() async throws {
        _ = try run(clothod, ["start"])
        let socket = ClothodBackend.defaultSocketPath(runtimeDir: runtimeDir)
        let fakeSSH = runtimeDir + "/fake-ssh"
        try "#!/bin/sh\nexec /usr/bin/nc -U '\(socket)'\n".write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH, 0o755)
        let clothod = clothod!, dir = runtimeDir!
        var transport = SSHProcessTransport(target: "test-host", remoteCommand: { "clothod bridge" }, prepare: { _ in
            // Like an installer: make sure the daemon is up before connecting.
            _ = try self.run(clothod, ["start"])
            _ = dir
        })
        transport.sshPath = fakeSSH
        let backend = ClothodBackend(configuration: .init(transport: transport, clientName: "clothokit-tests"))
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }

        try await backend.start()
        let hellos = { collector.all.compactMap { e -> Hello? in if case .connected(let h) = e { return h }; return nil } }
        try await waitFor("hello") { !hellos().isEmpty }
        XCTAssertTrue(collector.all.contains { if case .progress("Connecting") = $0 { return true }; return false })
        let created = try await backend.createWorkspace(name: "remote", spawn: SpawnOptions(command: ["/bin/sh"]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 80, rows: 20))
        backend.sendInput(created.pane, Data("echo via-''-process\n".utf8))
        try await waitFor("output over the process transport") { collector.output(of: created.pane).contains("via--process") }

        kill(try XCTUnwrap(hellos().first?.pid), SIGKILL)
        try await waitFor("reconnect over the process transport", timeout: 15) { hellos().count >= 2 }
        backend.sendInput(created.pane, Data("echo again-''-process\n".utf8))
        try await waitFor("output after reconnect") { collector.output(of: created.pane).contains("again--process") }
    }

    /// An ssh that fails reports its exit status and stderr as the reason.
    func testProcessTransportReportsSSHErrors() async throws {
        let fakeSSH = runtimeDir + "/failing-ssh"
        try FileManager.default.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'Permission denied (publickey).' >&2\nexit 255\n".write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH, 0o755)
        var transport = SSHProcessTransport(target: "nowhere", remoteCommand: { "clothod bridge" })
        transport.sshPath = fakeSSH
        let backend = ClothodBackend(configuration: .init(transport: transport))
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }
        do {
            try await backend.start()
            XCTFail("connecting should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Permission denied"), error.localizedDescription)
        }
    }

    func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
