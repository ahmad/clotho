@testable import ClothoKit
import XCTest

final class RemoteSetupTests: XCTestCase {
    func testParsesProbe() throws {
        let output = """
        clothod-probe=1
        os=linux
        arch=x86_64
        base=/home/a b/.local/share/clothod/bin
        installed=0.1.0-aaa 0.1.0-bbb
        runtime=/tmp/clothod-1000
        daemon=running
        daemon_pid=42
        daemon_exe=/home/a b/.local/share/clothod/bin/0.1.0-aaa/clothod
        writable=yes
        """
        let probe = try XCTUnwrap(RemoteSetup.Probe(output: output))
        XCTAssertEqual(probe.platform, "linux-x86_64")
        XCTAssertEqual(probe.base, "/home/a b/.local/share/clothod/bin")
        XCTAssertEqual(probe.installed, ["0.1.0-aaa", "0.1.0-bbb"])
        XCTAssertTrue(probe.daemonRunning)
        XCTAssertEqual(probe.daemonExe, "/home/a b/.local/share/clothod/bin/0.1.0-aaa/clothod")
        XCTAssertNil(RemoteSetup.Probe(output: "Welcome to fish\n"))
    }

    func testQuoting() {
        XCTAssertEqual(RemoteSetup.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(RemoteSetup.bridgeCommand(path: "/a b/clothod", env: ""), "'/a b/clothod' bridge")
    }

    /// The whole remote flow on this Mac: a stand-in ssh runs each command locally, so the probe, the
    /// upload and build-id check, the bridge and a reconnect all run for real, in private directories.
    func testInstallAndBridge() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dist = package.deletingLastPathComponent().appendingPathComponent("clothod/dist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dist.appendingPathComponent("manifest.json").path), "clothod/dist isn't built")
        let root = "/tmp/ckr-\(getpid())-\(UUID().uuidString.prefix(4))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fakeSSH = root + "/ssh"
        // Skip ssh's options and the target, then run the command (stdin passes through).
        try "#!/bin/sh\nwhile [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec /bin/sh -c \"$1\"\n"
            .write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH, 0o755)
        let installDir = root + "/bin", runtimeDir = root + "/rt"
        defer {
            let bin = (try? FileManager.default.contentsOfDirectory(atPath: installDir))?.first.map { "\(installDir)/\($0)/clothod" }
            if let bin {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: bin)
                process.arguments = ["shutdown"]
                process.environment = ["CLOTHOD_RUNTIME_DIR": runtimeDir, "HOME": NSHomeDirectory()]
                try? process.run()
                process.waitUntilExit()
            }
            // shutdown needs the logic process; stop whatever still uses this test's runtime dir.
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", "runtime-dir \(runtimeDir)"]
            try? pkill.run()
            pkill.waitUntilExit()
            try? FileManager.default.removeItem(atPath: root)
        }

        var runner = SSHCommandRunner(target: "here", options: [])
        runner.sshPath = fakeSSH
        let installer = RemoteInstaller(runner: runner, dist: dist, installDir: installDir, runtimeDir: runtimeDir, ephemeral: "120")
        var transport = SSHProcessTransport(target: "here", remoteCommand: { try installer.bridgeCommand() },
                                            prepare: { try installer.prepare(progress: $0) })
        transport.sshPath = fakeSSH
        let backend = ClothodBackend(configuration: .init(transport: transport))
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        defer { backend.stop(); reader.cancel() }

        try await backend.start()
        let progress = collector.all.compactMap { e -> String? in if case .progress(let p) = e { return p }; return nil }
        XCTAssertTrue(progress.contains { $0.hasPrefix("Installing clothod") }, "\(progress)")
        let manifest = try RemoteSetup.Manifest.load(from: dist)
        let build = try XCTUnwrap(manifest.builds["macos-aarch64"] ?? manifest.builds["macos-x86_64"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "\(installDir)/\(build.id)/clothod"))

        let created = try await backend.createWorkspace(name: "remote", spawn: SpawnOptions(command: ["/bin/sh"]))
        _ = try await backend.subscribe(created.pane, haveSeq: nil, scrollback: 100, viewport: Size(cols: 80, rows: 20))
        backend.sendInput(created.pane, Data("echo over-''-bridge\n".utf8))
        try await waitFor("output over the bridge") { collector.output(of: created.pane).contains("over--bridge") }

        // Reconnecting probes again and finds the build already installed.
        backend.reconnectNow()
        try await waitFor("second hello") { collector.all.filter { if case .connected = $0 { return true }; return false }.count >= 2 }
        let installs = collector.all.filter { if case .progress(let p) = $0 { return p.hasPrefix("Installing") }; return false }
        XCTAssertEqual(installs.count, 1)
        backend.sendInput(created.pane, Data("echo still-''-here\n".utf8))
        try await waitFor("output after reconnect") { collector.output(of: created.pane).contains("still--here") }
    }

    /// One version per machine: a machine that already has clothod is never given a second build. An
    /// older one gets an update offer, a newer one is used as is (never downgraded).
    func testNeverInstallsAlongside() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dist = package.deletingLastPathComponent().appendingPathComponent("clothod/dist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dist.appendingPathComponent("manifest.json").path), "clothod/dist isn't built")
        let manifest = try RemoteSetup.Manifest.load(from: dist)
        let build = try XCTUnwrap(manifest.builds["macos-aarch64"] ?? manifest.builds["macos-x86_64"])
        for (existing, expectOffer) in [("0.0.9-older", true), ("9.0.0-newer", false)] {
            let root = "/tmp/ckv-\(getpid())-\(UUID().uuidString.prefix(4))"
            defer { try? FileManager.default.removeItem(atPath: root) }
            let installDir = root + "/bin", runtimeDir = root + "/rt"
            // The machine's one existing build (a copy of the bundled binary under another id is enough here).
            try FileManager.default.createDirectory(atPath: "\(installDir)/\(existing)", withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: dist.appendingPathComponent(build.file).path, toPath: "\(installDir)/\(existing)/clothod")
            let fakeSSH = root + "/ssh"
            try "#!/bin/sh\nwhile [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec /bin/sh -c \"$1\"\n"
                .write(toFile: fakeSSH, atomically: true, encoding: .utf8)
            chmod(fakeSSH, 0o755)
            var runner = SSHCommandRunner(target: "here", options: [])
            runner.sshPath = fakeSSH
            let installer = RemoteInstaller(runner: runner, dist: dist, installDir: installDir, runtimeDir: runtimeDir, ephemeral: "120")

            try installer.prepare(progress: { _ in })
            let versions = try FileManager.default.contentsOfDirectory(atPath: installDir).filter { $0 != "current" && !$0.hasPrefix(".") }
            XCTAssertEqual(versions, [existing], "no build installed alongside \(existing)")
            XCTAssertEqual(installer.outdatedDaemonExe != nil, expectOffer, "update offered for \(existing)")
            XCTAssertEqual(installer.versionStatus, expectOffer ? .updateAvailable(running: existing) : .appOutdated(running: existing))
            XCTAssertTrue(try installer.bridgeCommand().contains("/\(existing)/clothod"), "bridges with the machine's own build")
        }
    }

    func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

final class UpdateOrderTests: XCTestCase {
    func testOnlyProvableUpgradesCount() {
        let base = "/Users/a/Library/Application Support/clothod/bin"
        XCTAssertTrue(RemoteSetup.isOutdated(runningExecutable: nil, bundledID: "0.1.0-aaa"), "no exe: predates installs")
        XCTAssertTrue(RemoteSetup.isOutdated(runningExecutable: "/Applications/Clotho.app/Contents/MacOS/clothod", bundledID: "0.1.0-aaa"))
        XCTAssertTrue(RemoteSetup.isOutdated(runningExecutable: "\(base)/0.1.0-bbb/clothod", bundledID: "0.2.0-aaa"))
        XCTAssertTrue(RemoteSetup.isOutdated(runningExecutable: "\(base)/0.9.0-bbb/clothod", bundledID: "0.10.0-aaa"))
        XCTAssertFalse(RemoteSetup.isOutdated(runningExecutable: "\(base)/0.1.0-aaa/clothod", bundledID: "0.1.0-aaa"), "same build")
        XCTAssertFalse(RemoteSetup.isOutdated(runningExecutable: "\(base)/0.1.0-bbb/clothod", bundledID: "0.1.0-aaa"), "same version: can't order")
        XCTAssertFalse(RemoteSetup.isOutdated(runningExecutable: "\(base)/0.2.0-bbb/clothod", bundledID: "0.1.0-aaa"), "never a downgrade")
        XCTAssertFalse(RemoteSetup.isOutdated(runningExecutable: "\(base)/current/clothod", bundledID: "0.2.0-aaa"), "current is the newest")
    }
}
