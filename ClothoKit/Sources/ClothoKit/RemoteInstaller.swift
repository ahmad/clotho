import Foundation

/// Runs one command on a remote machine, with optional stdin, and returns how it ended. This is all a
/// platform supplies for remote setup: an ssh process on macOS, an exec channel over SwiftNIO SSH on iOS.
/// Exit status 255 means ssh itself failed (can't connect or authenticate), as with OpenSSH.
public protocol RemoteCommandRunner: Sendable {
    /// For messages, such as "user@devbox".
    var target: String { get }
    func run(_ command: String, input: Data?) throws -> RemoteCommandResult
}

public struct RemoteCommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Gets clothod running on a remote machine, per docs/remote.md: probe, install the bundled build if
/// it's missing, switch the logic process to it if an older one is running, and hand back the bridge
/// command. Platform-neutral: it runs everything through a RemoteCommandRunner. Use it as a transport's
/// `prepare` step and bridge command.
public final class RemoteInstaller: @unchecked Sendable {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }

        public init(message: String) {
            self.message = message
        }
    }

    public var target: String { runner.target }
    /// The bundled `dist/` directory (manifest.json plus one clothod per platform).
    public let dist: URL
    public let runner: RemoteCommandRunner
    private let env: String
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var bridgePath: String?
    private var outdatedDaemon: String?
    /// The bundled build's path once installed, which `upgrade` runs from.
    private var installedBuild: String?
    private var lastProbe: RemoteSetup.Probe?
    private var bundled: RemoteSetup.Manifest.Build?

    /// The executable of the daemon running on the machine, when it isn't the bundled build. The bridge
    /// still connects to it; switching builds restarts its logic process, so that's the user's call
    /// (`switchToInstalledBuild()`).
    public var outdatedDaemonExe: String? { lock.withLock { outdatedDaemon } }

    /// How the machine's clothod compares with the build this app bundles, by version (builds of one
    /// version are the same release). The app never downgrades a machine.
    public enum VersionStatus: Equatable, Sendable {
        /// Same version, or not known yet.
        case current
        /// The machine runs an older version (its build id); "Update clothod" applies.
        case updateAvailable(running: String)
        /// The machine runs a newer version than the app bundles: update the app instead.
        case appOutdated(running: String)
    }

    public var versionStatus: VersionStatus { lock.withLock { status } }
    private var status = VersionStatus.current

    /// `installDir` and `runtimeDir` override where clothod installs and listens on the machine (for
    /// test runs that mustn't touch the user's daemon there). The remote shell expands them.
    /// `ephemeral` ("exit", or idle seconds) is required with a non-default `runtimeDir`: the instance
    /// then ends itself, and removes its dir, once its clients are gone.
    public init(runner: RemoteCommandRunner, dist: URL, installDir: String? = nil, runtimeDir: String? = nil,
                ephemeral: String? = nil, log: (@Sendable (String) -> Void)? = nil) {
        self.runner = runner
        self.dist = dist
        env = RemoteSetup.envPrefix(installDir: installDir, runtimeDir: runtimeDir, ephemeral: ephemeral)
        self.log = log
    }

    /// The `bridge` command for the build `prepare` settled on.
    public func bridgeCommand() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let bridgePath else { throw Failure(message: "clothod isn't set up on \(target) yet") }
        return RemoteSetup.bridgeCommand(path: bridgePath, env: env)
    }

    /// Runs a clothod subcommand on the machine (such as `hooks print claude`) with the build `prepare`
    /// settled on and the same environment as every other step.
    public func runClothod(_ arguments: [String]) throws -> RemoteCommandResult {
        let path: String? = lock.withLock { bridgePath }
        guard let path else { throw Failure(message: "clothod isn't set up on \(target) yet") }
        return try ssh(env + RemoteSetup.quote(path) + " " + arguments.map(RemoteSetup.quote).joined(separator: " "))
    }

    /// Switches the machine's daemon to the bundled build: uploads it, then clothod's `upgrade` (stop,
    /// start, verify, remove other versions), keeping the holder and its shells. Only on the user's say-so. Exit 3 (an incompatible
    /// holder) throws with that status in the message.
    public func switchToInstalledBuild() throws {
        let (path, probe, build): (String?, RemoteSetup.Probe?, RemoteSetup.Manifest.Build?) = lock.withLock { (installedBuild, lastProbe, bundled) }
        guard var path, let probe, let build else { throw Failure(message: "clothod isn't set up on \(target) yet") }
        // Upload the bundled build only now that the user asked; `upgrade` switches to it and removes the
        // other versions.
        if !probe.installed.contains(build.id) {
            let base = try install(build, probe: probe)
            path = RemoteSetup.installedPath(base: base, id: build.id)
        }
        let result = try ssh(env + RemoteSetup.quote(path) + " upgrade")
        log?("\(target): upgrade exited with \(result.status) \(result.stdout) \(result.stderr)")
        guard result.status == 0 else {
            throw Failure(message: result.status == RemoteSetup.holderTooOldExit
                ? "The sessions on \(target) use an older clothod; restart them to finish upgrading. \(result.stderr)"
                : (result.stderr.isEmpty ? "clothod upgrade on \(target) exited with \(result.status)" : result.stderr))
        }
        lock.withLock {
            outdatedDaemon = nil
            status = .current
        }
    }

    /// `shutdown` on the machine: ends every session there, for finishing an upgrade.
    public func shutdownSessions() throws {
        let path: String? = lock.withLock { bridgePath }
        guard let path else { throw Failure(message: "clothod isn't set up on \(target) yet") }
        let result = try ssh(RemoteSetup.shutdownCommand(path: path, env: env))
        log?("\(target): shutdown exited with \(result.status) \(result.stderr)")
    }

    /// Probes, installs if needed, and upgrades the logic process if an older build is running.
    /// Runs before every connection; over a multiplexed connection the probe costs one round trip.
    public func prepare(progress: @Sendable (String) -> Void) throws {
        progress("Checking \(target)")
        let probeRun = try ssh(RemoteSetup.probeCommand(env: env), input: Data(RemoteSetup.probeScript.utf8))
        guard probeRun.status != 255 else { throw Failure(message: sshMessage(probeRun.stderr)) }
        guard let probe = RemoteSetup.Probe(output: probeRun.stdout) else {
            throw Failure(message: "\(target) didn't answer the clothod probe; it needs a POSIX shell. \(probeRun.stdout) \(probeRun.stderr)")
        }
        let manifest = try RemoteSetup.Manifest.load(from: dist)
        guard let build = manifest.builds[probe.platform] else {
            throw Failure(message: "\(target) runs \(probe.platform), which Clotho has no clothod build for.")
        }

        // One clothod version per machine (protocol.md, "Starting and upgrading"). Only a machine with no
        // clothod at all gets the bundled build now. Otherwise Clotho uses the machine's `current`, whatever
        // version it is, and offers the update only for a higher version (switchToInstalledBuild).
        var base = probe.base
        if probe.isFresh {
            progress("Installing clothod \(manifest.version) on \(target)")
            base = try install(build, probe: probe)
            // The upload only places the binary; its own `install` adds `current` (and nothing else).
            let uploaded = RemoteSetup.installedPath(base: base, id: build.id)
            _ = try? ssh(env + RemoteSetup.quote(uploaded) + " install")
        } else if probe.installed.isEmpty, let fallback = probe.fallbackBase {
            base = fallback
        }
        let current = RemoteSetup.installedPath(base: base, id: "current")
        let hasCurrent = (!probe.isFresh && probe.current != nil)
            || (try? ssh("[ -x \(RemoteSetup.quote(current)) ]"))?.status == 0
        let installedBuilds = probe.installed.isEmpty ? probe.fallbackInstalled : probe.installed
        let bridgeVia = hasCurrent || installedBuilds.isEmpty
            ? current : RemoteSetup.installedPath(base: base, id: installedBuilds.sorted().last!)
        // What the machine runs: the daemon's own report, else what `current` (or the one build) points at.
        let running = probe.daemonBuild ?? probe.current ?? installedBuilds.sorted().last
        let offer = !probe.isFresh && running.map { RemoteSetup.isOlder($0, than: build.id) } == true
        if offer { log?("\(target): runs \(running ?? "?"); bundled clothod \(build.id) is a newer version, offering it") }
        let versionStatus: VersionStatus
        if offer, let running { versionStatus = .updateAvailable(running: running) }
        else if let running, RemoteSetup.isOlder(build.id, than: running) { versionStatus = .appOutdated(running: running) }
        else { versionStatus = .current }
        lock.withLock {
            status = versionStatus
            bridgePath = bridgeVia
            installedBuild = RemoteSetup.installedPath(base: base, id: build.id)
            outdatedDaemon = offer ? running : nil
            lastProbe = probe
            bundled = build
        }
    }

    /// Uploads the build, retrying as remote.md says: once for a bad upload (4), and once in the
    /// fallback directory when the default one isn't writable (5). Returns the base it installed into.
    private func install(_ build: RemoteSetup.Manifest.Build, probe: RemoteSetup.Probe) throws -> String {
        let binary = try Data(contentsOf: dist.appendingPathComponent(build.file))
        var quotedBase = RemoteSetup.quote(probe.base)
        var triedFallback = false, triedAgain = false
        while true {
            let result = try ssh(RemoteSetup.installCommand(id: build.id, quotedBase: quotedBase, env: env), input: binary)
            log?("\(target): install exited with \(result.status) \(result.stderr)")
            switch result.status {
            case 0:
                guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("installed=") }) else {
                    throw Failure(message: "The install on \(target) didn't report a path.")
                }
                // installed=<base>/<id>/clothod
                let path = String(line.dropFirst("installed=".count))
                return ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            case 4 where !triedAgain:
                triedAgain = true
            case 5 where !triedFallback:
                triedFallback = true
                quotedBase = RemoteSetup.fallbackBase
            case 255:
                throw Failure(message: sshMessage(result.stderr))
            default:
                throw Failure(message: result.stderr.isEmpty ? "Installing clothod on \(target) failed (\(result.status))." : result.stderr)
            }
        }
    }

    private func sshMessage(_ stderr: String) -> String {
        "Can't reach \(target) over SSH" + (stderr.isEmpty ? "." : ": \(stderr)")
    }

    private func ssh(_ command: String, input: Data? = nil) throws -> RemoteCommandResult {
        try runner.run(command, input: input)
    }
}

#if os(macOS)
/// Runs remote commands with /usr/bin/ssh (no PTY, no prompts), sharing whatever multiplexed connection
/// the options set up.
public struct SSHCommandRunner: RemoteCommandRunner {
    public let target: String
    public var options: [String]
    public var sshPath = "/usr/bin/ssh"

    public init(target: String, options: [String] = SSHProcessTransport.baseOptions) {
        self.target = target
        self.options = options
    }

    public func run(_ command: String, input: Data?) throws -> RemoteCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        try SSHTarget.check(target)
        process.arguments = options + ["--", target, command]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Read both streams to their ends while writing, so a chatty command can't fill a pipe and stall.
        let group = DispatchGroup()
        let collected = Collected()
        for (pipe, isOutput) in [(stdout, true), (stderr, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(data, isOutput: isOutput)
                group.leave()
            }
        }
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        group.wait()
        let text = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return RemoteCommandResult(status: process.terminationStatus, stdout: text(collected.output), stderr: text(collected.errors))
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var output = Data()
    private(set) var errors = Data()

    func set(_ data: Data, isOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isOutput { output = data } else { errors = data }
    }
}
#endif

/// What a user typed as an SSH destination ("user@host", an alias), checked before it reaches ssh: one
/// starting with "-" would be read as an option ("-oProxyCommand=…" runs a command), and whitespace or
/// control characters have no place in a host. Every ssh call also puts "--" before the destination.
public enum SSHTarget {
    /// Why `target` can't be used, or nil when it's fine.
    public static func problem(_ target: String) -> String? {
        if target.isEmpty { return "Type an SSH target, such as you@host." }
        if target.hasPrefix("-") { return "An SSH target can't start with \"-\"." }
        if target.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "An SSH target can't contain spaces or control characters."
        }
        return nil
    }

    /// Throws when `target` isn't usable (see `problem`).
    public static func check(_ target: String) throws {
        if let problem = problem(target) { throw RemoteInstaller.Failure(message: problem) }
    }
}
