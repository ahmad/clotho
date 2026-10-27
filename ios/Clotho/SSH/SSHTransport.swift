import ClothoKit
import Foundation

/// A remote machine over SwiftNIO SSH: each connect makes a fresh SSH connection, runs ClothoKit's
/// RemoteInstaller over it (probe, install if missing, upgrade the logic process), then opens an exec
/// channel for `clothod bridge` and hands its stdio to the backend.
final class SSHTransport: ClothodTransport, @unchecked Sendable {
    let machine: Machine
    let runner: NIOCommandRunner
    let installer: RemoteInstaller?

    /// Where test builds install and run clothod on a machine, away from the user's own daemon there.
    static let devInstallDir = "$HOME/.local/share/clotho-ios-dev/bin"
    static let devRuntimeDir = "/tmp/clothod-ios-dev-$(id -u)"
    /// A test instance ends itself after this many idle seconds (no clients, no panes). Not "exit": iOS drops
    /// the connection whenever the app is backgrounded, and resuming must find the shells still there.
    /// Disconnecting the machine removes it right away (`removeDevDaemon`).
    static let devEphemeral = "600"

    /// The clothod builds bundled with the app (clothod/dist: manifest.json plus one build per platform).
    static var distURL: URL? {
        do {
            return try DistBundle.directory()
        } catch {
            log("unpacking the bundled clothod failed: \(error.localizedDescription)")
            return nil
        }
    }

    init(machine: Machine) {
        self.machine = machine
        let runner = NIOCommandRunner(machine: machine)
        self.runner = runner
        let dev = machine.devDirs ?? false
        installer = SSHTransport.distURL.map {
            RemoteInstaller(runner: runner, dist: $0, installDir: dev ? SSHTransport.devInstallDir : nil,
                            runtimeDir: dev ? SSHTransport.devRuntimeDir : nil,
                            ephemeral: dev ? SSHTransport.devEphemeral : nil,
                            log: { log("[\(machine.displayName)] \($0)") })
        }
    }

    var name: String { runner.target }
    var maxReconnectDelay: TimeInterval { 30 }
    /// A ping after 15 s without traffic, and a reconnect if 15 s more pass without an answer (protocol.md:
    /// clients ping every 15 s and drop the connection after 30 s of silence).
    var heartbeatInterval: TimeInterval? { 15 }

    func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
        // A link that went quiet (heartbeat timeout, network change) may look alive; start clean.
        runner.reset()
        progress("Connecting to \(runner.target)")
        let command: String
        if let custom = machine.remoteCommand {
            command = custom
        } else {
            guard let installer else {
                throw BackendError(code: "internal", message: "This build has no bundled clothod to install.")
            }
            try installer.prepare(progress: progress)
            command = try installer.bridgeCommand()
        }
        progress("Starting clothod on \(machine.displayName)")
        do {
            return try runner.session().openStream(command)
        } catch {
            runner.reset()
            throw BackendError(code: "disconnected", message: error.localizedDescription)
        }
    }

    /// Shuts down the test-directory clothod on a machine, waits for it to exit (the holder goes a moment
    /// after serve), and deletes its install and runtime dirs. Test daemons are temporary: the one clothod
    /// on a machine is the user's own. Run with `sh -s` so the login shell (zsh globs) doesn't matter.
    static let devCleanupScript = """
        rt=/tmp/clothod-ios-dev-$(id -u)
        for b in "$HOME"/.local/share/clotho-ios-dev/bin/*/clothod; do
          [ -x "$b" ] && CLOTHOD_RUNTIME_DIR=$rt "$b" shutdown >/dev/null 2>&1
        done
        i=0
        while [ $i -lt 20 ] && ps -eo args | grep -v grep | grep -q 'clotho-ios-dev/bin/.*/clothod'; do
          sleep 0.5; i=$((i + 1))
        done
        rm -rf "$HOME/.local/share/clotho-ios-dev" "$rt"

        """

    /// Removes the test-directory daemon (`devDirs` machines only), after the connection is closed.
    func removeDevDaemon() throws {
        guard machine.devDirs == true else { return }
        let result = try runner.run("sh -s", input: Data(Self.devCleanupScript.utf8))
        runner.reset()
        guard result.status == 0 else {
            throw BackendError(code: "internal", message: "Removing the test clothod on \(machine.displayName) failed: \(result.stderr)")
        }
        log("[\(machine.displayName)] removed the test clothod")
    }

    /// How the machine's clothod compares with the bundled one, from each connect's probe. Never a downgrade:
    /// a newer machine means the app needs updating.
    var versionStatus: RemoteInstaller.VersionStatus { installer?.versionStatus ?? .current }

    /// Switches the machine to the bundled clothod with its `upgrade` (all or nothing; the shells stay).
    /// Only after the user confirms.
    func updateClothod() throws {
        guard let installer else { throw BackendError(code: "internal", message: "This build has no bundled clothod.") }
        try installer.switchToInstalledBuild()
    }

    /// Ends every session on the machine, to finish an upgrade the running holder can't take.
    func restartSessions() throws {
        try installer?.shutdownSessions()
    }
}
