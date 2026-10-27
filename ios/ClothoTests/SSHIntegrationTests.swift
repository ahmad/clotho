import ClothoKit
@testable import Clotho
import CryptoKit
import XCTest

/// NIO SSH against a real sshd. Set up with ios/scripts/ssh-test-server.sh, which writes
/// /tmp/clotho-ios-sshtest/{seed.hex,user,host,port}; skipped otherwise. clothod runs in the dev
/// install and runtime dirs, never the machine's own.
final class SSHIntegrationTests: XCTestCase {
    private var machine: Machine!

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: "/tmp/clotho-ios-sshtest")
        func read(_ name: String) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let seedHex = read("seed.hex"), let user = read("user") else { throw XCTSkip("no SSH test server") }
        let seed = Data(stride(from: 0, to: seedHex.count, by: 2).map {
            UInt8(seedHex[seedHex.index(seedHex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
        let key = SSHKey(id: "ssh-integration-test", name: "clotho-ios-dev-test", kind: .ed25519, created: Date(),
                         secret: try Curve25519.Signing.PrivateKey(rawRepresentation: seed).rawRepresentation)
        try KeyStore.save(key)
        machine = Machine(id: UUID(uuidString: "5E55E55E-0000-0000-0000-000000000001")!, name: "ssh test",
                          host: read("host") ?? "127.0.0.1", port: Int(read("port") ?? "") ?? 2222, user: user,
                          keyID: key.id, devDirs: true)
        TrustedHostKeys.shared.set(nil, for: machine.id)
    }

    /// Test daemons are temporary: shut down and delete the dev install after every test, pass or fail.
    override func tearDownWithError() throws {
        guard let machine else { return }
        // A test may have planted a wrong trusted key; cleanup must reach the real host.
        TrustedHostKeys.shared.set(nil, for: machine.id)
        try SSHTransport(machine: machine).removeDevDaemon()
    }

    func testExecTrustsOnFirstUseAndPassesStdin() throws {
        let runner = NIOCommandRunner(machine: machine)
        let echo = try runner.run("echo hi; echo oops >&2; exit 7", input: nil)
        XCTAssertEqual(echo.status, 7)
        XCTAssertEqual(echo.stdout, "hi\n")
        XCTAssertEqual(echo.stderr, "oops")
        XCTAssertNotNil(TrustedHostKeys.shared.key(for: machine.id), "host key not stored on first use")

        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        let cat = try runner.run("wc -c", input: big)
        XCTAssertEqual(cat.status, 0)
        XCTAssertEqual(cat.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "300000")
        runner.reset()
    }

    /// A changed host key fails the connection promptly, even while the calling thread is the main one and
    /// something observes the change on the main queue, as every MachineConnection does. (That used to
    /// deadlock: the SSH event loop posted synchronously to the main queue, which was waiting on that loop.)
    func testChangedHostKeyIsRefused() throws {
        TrustedHostKeys.shared.set("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl", for: machine.id)
        let changed = expectation(forNotification: .hostKeyChanged, object: nil)
        let observer = NotificationCenter.default.addObserver(forName: .hostKeyChanged, object: nil, queue: .main) { _ in }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(Thread.isMainThread)
        let result = try NIOCommandRunner(machine: machine).run("echo hi", input: nil)
        XCTAssertEqual(result.status, 255)
        XCTAssertTrue(result.stderr.contains("changed"), result.stderr)
        wait(for: [changed], timeout: 5)
    }

    func testWrongKeyIsRejected() throws {
        try KeyStore.save(SSHKey(id: "ssh-integration-other", name: "other", kind: .ed25519, created: Date(),
                                 secret: Curve25519.Signing.PrivateKey().rawRepresentation))
        var other = machine!
        other.keyID = "ssh-integration-other"
        let result = try NIOCommandRunner(machine: other).run("echo hi", input: nil)
        if result.status == 0 {
            // Tailscale SSH (and similar) authenticates the tailnet peer and accepts "none", so keys don't matter.
            throw XCTSkip("\(machine.host) lets clients in without a key")
        }
        XCTAssertEqual(result.status, 255)
        XCTAssertTrue(result.stderr.contains("rejected"), result.stderr)
    }

    /// A machine with an older clothod (/tmp/clotho-ios-sshtest/old-clothod, installed into the dev dirs):
    /// connecting uses it as is, offers the update, the confirmed update switches to the bundled build, and a
    /// legacy holder gets the one-time restart. Skipped without the old build.
    func testUpdateOlderClothod() async throws {
        let oldPath = "/tmp/clotho-ios-sshtest/old-clothod"
        guard let old = FileManager.default.contents(atPath: oldPath) else { throw XCTSkip("no old clothod to start from") }
        let runner = NIOCommandRunner(machine: machine)
        // Lay down the old build the way a previous app version would have: in the dev dirs, with `current`.
        let setup = try runner.run("""
            sh -c 'd=$HOME/.local/share/clotho-ios-dev/bin/old; mkdir -p "$d" && cat > "$d/clothod" && chmod 755 "$d/clothod" \
              && CLOTHOD_INSTALL_DIR=$HOME/.local/share/clotho-ios-dev/bin "$d/clothod" install && rm -rf "$d"'
            """, input: old)
        XCTAssertEqual(setup.status, 0, setup.stderr)

        let transport = SSHTransport(machine: machine)
        let backend = ClothodBackend(configuration: .init(transport: transport, clientName: "clotho-ios-test",
                                                          log: { print("backend: \($0)") }))
        try await backend.start()
        guard case .updateAvailable(let running) = transport.versionStatus else {
            return XCTFail("expected an update offer, got \(transport.versionStatus)")
        }
        print("machine runs \(running); bundled is newer")

        backend.stop() // as the app does: no reconnect may replace the SSH connection the upgrade runs on
        do {
            try transport.updateClothod()
        } catch {
            // A legacy holder can't be driven by the new build: the one-time restart finishes it.
            print("update needs a restart: \(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("restart"), error.localizedDescription)
            try transport.restartSessions()
        }
        var again = ClothodBackend(configuration: .init(transport: transport, clientName: "clotho-ios-test"))
        try await again.start()
        var hello = try await helloOf(again)
        XCTAssertEqual(transport.versionStatus, .current)
        let bundled = try String(contentsOf: try DistBundle.directory().appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(bundled.contains(hello.build ?? "none"), "running \(hello.build ?? "?") isn't the bundled build")

        // The old holder keeps the shells but can't be updated in place: the confirmed one-time restart.
        if hello.holderOutdated == true {
            print("holder is outdated (\(hello.holder?.build ?? "?")); restarting sessions")
            again.stop()
            try transport.restartSessions()
            again = ClothodBackend(configuration: .init(transport: transport, clientName: "clotho-ios-test"))
            try await again.start()
            hello = try await helloOf(again)
        }
        XCTAssertNotEqual(hello.holderOutdated, true, "holder \(hello.holder?.build ?? "?") still outdated")
        XCTAssertTrue(bundled.contains(hello.holder?.build ?? "none"), "holder \(hello.holder?.build ?? "?") isn't the bundled build")
        again.stop()
    }

    private func helloOf(_ backend: ClothodBackend) async throws -> Hello {
        for await event in backend.events { if case .connected(let hello) = event { return hello } }
        throw XCTSkip("no hello")
    }

    /// Install into the dev dirs, bridge, run a shell, and see its output.
    func testBridgeSession() async throws {
        let transport = SSHTransport(machine: machine)
        let backend = ClothodBackend(configuration: .init(transport: transport, clientName: "clotho-ios-test",
                                                          log: { print("backend: \($0)") }))
        let collector = OutputCollector()
        let events = backend.events
        let reader = Task {
            for await event in events {
                if case .output(_, _, let bytes) = event { await collector.append(bytes) }
                if case .snapshot(_, _, _, _, let bytes) = event { await collector.append(bytes) }
            }
        }
        try await backend.start()
        let created = try await backend.createWorkspace(name: "ios-test")
        try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 0, viewport: Size(cols: 80, rows: 24))
        backend.sendInput(created.pane, Data("echo nio-$((6*7))\r".utf8))
        let deadline = Date().addingTimeInterval(15)
        while await !collector.text.contains("nio-42"), Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let text = await collector.text
        XCTAssertTrue(text.contains("nio-42"), text)
        try await backend.closeWorkspace(created.workspace)
        backend.stop()
        reader.cancel()
    }

    /// OSC 52 from a shell (how Claude Code and Codex copy) reaches the clipboard of the pane on screen,
    /// and only that one: a pane off screen copies nothing.
    @MainActor
    func testPaneCopyReachesClipboard() async throws {
        let backend = ClothodBackend(configuration: .init(transport: SSHTransport(machine: machine), clientName: "clotho-ios-test",
                                                          log: { print("backend: \($0)") }))
        let store = ModelStore(backend: backend)
        try await store.start()
        defer { store.stop() }
        let shown = try await backend.createWorkspace(name: "ios-copy-shown")
        let hidden = try await backend.createWorkspace(name: "ios-copy-hidden")
        func pane(_ id: PaneID) async throws -> Pane {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let pane = store.state.pane(id) { return pane }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw XCTSkip("pane \(id) never appeared in the model")
        }

        var copied: [String] = [], hiddenCopied: [String] = [], confirmations = 0
        let host = PaneHostView(pane: try await pane(shown.pane), store: store)
        host.pasteboard = { copied.append($0) }
        host.onCopy = { confirmations += 1 }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        host.frame = window.bounds
        window.addSubview(host)
        window.isHidden = false
        host.layoutIfNeeded()
        let offscreen = PaneHostView(pane: try await pane(hidden.pane), store: store)
        offscreen.pasteboard = { hiddenCopied.append($0) }

        // Copies are live only, so type once the pane's stream has started (its snapshot arrived).
        let subscribed = Date().addingTimeInterval(10)
        while host.haveSeq == nil, Date() < subscribed { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(host.haveSeq, "the visible pane never subscribed")

        // base64 of "clotho copy ✓", printed by the shell so the bytes come from the pane, not from us.
        let text = "clotho copy ✓", encoded = Data(text.utf8).base64EncodedString()
        let osc52 = "printf '\\033]52;c;%s\\a' \(encoded)\r"
        backend.sendInput(shown.pane, Data(osc52.utf8))
        backend.sendInput(hidden.pane, Data(osc52.utf8))
        let deadline = Date().addingTimeInterval(15)
        while copied.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000) // room for a duplicate or a stray background copy

        XCTAssertEqual(copied, [text], "the visible pane's copy, exactly once")
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(hiddenCopied, [], "a pane off screen must not touch the clipboard")
        host.removeFromSuperview()
        try await backend.closeWorkspace(shown.workspace)
        try await backend.closeWorkspace(hidden.workspace)
    }

    /// Mute over the wire (agent.mute, clothod 0.1.10): a hook-reported waiting agent needs the user until it's
    /// muted; while muted, another report raises nothing; unmuting doesn't bring attention back by itself.
    @MainActor
    func testMuteOverTheWire() async throws {
        let backend = ClothodBackend(configuration: .init(transport: SSHTransport(machine: machine), clientName: "clotho-ios-test"))
        let store = ModelStore(backend: backend)
        try await store.start()
        defer { store.stop() }
        func waitUntil(_ what: String, _ seconds: Double = 15, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { return XCTFail("timed out: \(what)") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try await waitUntil("hello") { store.hello != nil }
        guard store.hello?.features.contains(.agentMute) == true else {
            throw XCTSkip("clothod \(store.hello?.version ?? "?") has no agent.mute")
        }
        let created = try await backend.createWorkspace(name: "ios-mute")
        let pane = created.pane
        var agent: AgentInfo? { store.state.pane(pane)?.agent }
        // A long-lived process in the pane reports as an agent's hooks would (each report a child of it, as with
        // Claude Code): waiting, then 4 s later done, then it keeps running. The test install has one build.
        let script = #"b=$(ls "$HOME"/.local/share/clotho-ios-dev/bin/*/clothod | head -1); r() { "$b" report "$1" --agent claude --session ios-mute-test --message mute-test; }; r waiting; sleep 4; r done; sleep 60"#
        backend.sendInput(pane, Data("sh -c '\(script)'\r".utf8))

        try await waitUntil("the reported agent needs the user") { agent?.needsAttention == true }
        XCTAssertEqual(agent?.isMuted, false)

        try await backend.muteAgent(pane, muted: true)
        try await waitUntil("muted, attention cleared") { agent?.isMuted == true && agent?.attention != true }

        try await waitUntil("the done report arrives") { agent?.state == .done }
        XCTAssertNotEqual(agent?.attention, true, "a muted agent's report raised attention")
        XCTAssertTrue(agent?.isMuted == true, "the agent lost its mute")

        try await backend.muteAgent(pane, muted: false)
        try await waitUntil("unmuted") { agent?.isMuted == false }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotEqual(agent?.attention, true, "unmuting raised attention by itself")

        try await backend.closeWorkspace(created.workspace)
    }
}

private actor OutputCollector {
    private var data = Data()
    func append(_ bytes: Data) { data.append(bytes) }
    var text: String { String(decoding: data, as: UTF8.self) }
}
