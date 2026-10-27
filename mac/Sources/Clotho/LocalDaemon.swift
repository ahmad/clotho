import ClothoKit
import Foundation

/// Installs and starts this Mac's clothod, following docs/protocol.md ("Starting and upgrading the
/// daemon"): the bundled binary installs itself to a versioned directory under
/// ~/Library/Application Support/clothod/bin/, and the daemon always runs from there, never from inside
/// the app, so replacing the app never swaps the binary under a running daemon.
struct LocalDaemon: Sendable {
    enum Failure: Error, LocalizedError {
        /// `start` exited 3: the running holder (and its shells) is from a version this one can't drive.
        case holderTooOld(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .holderTooOld(let message): return message
            case .failed(let message): return message
            }
        }
    }

    /// The binary to install from (the app's bundled copy), or a development build used as is.
    let source: String
    /// Development builds (ClothodPath, CLOTHOD_BIN) run in place instead of being installed.
    let runInPlace: Bool
    let runtimeDir: String?
    /// Where builds install (CLOTHOD_INSTALL_DIR); nil for the user's normal location. The dev build keeps
    /// its own, so testing never adds a version to the user's machine or moves their `current`.
    var installDir: String? = nil

    /// Where the bundled build lives once installed (`install --print-path`, which installs nothing).
    func bundledInstallPath() throws -> String {
        guard !runInPlace else { return source }
        let result = try Self.run(source, ["install", "--print-path"], runtimeDir: runtimeDir, installDir: installDir)
        guard result.status == 0, let path = result.stdout.split(separator: "\n").last.map(String.init), !path.isEmpty else {
            throw Failure.failed("Couldn't ask clothod where it installs: \(result.stderr)")
        }
        return path
    }

    var bundledID: String? { (try? bundledInstallPath()).flatMap(RemoteSetup.installID(ofExecutable:)) }

    /// The clothod this Mac runs: `<base>/current/clothod`, or another installed build for installs from
    /// before `current`. One version per machine: the bundled build is installed only when there's none at
    /// all; otherwise an update is only offered (DaemonUpdates.swift).
    func installedPath() throws -> String {
        guard !runInPlace else { return source }
        let bundled = try bundledInstallPath()
        let base = ((bundled as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let current = (base as NSString).appendingPathComponent("current/clothod")
        // `install` installs only on a machine with no clothod (or this exact build), and refuses otherwise,
        // which is fine: then the machine's own `current` is used, whatever version it is.
        let installed = try Self.run(source, ["install"], runtimeDir: runtimeDir, installDir: installDir)
        if FileManager.default.isExecutableFile(atPath: current) { return current }
        let builds = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
            .filter { $0.contains("-") && FileManager.default.isExecutableFile(atPath: "\(base)/\($0)/clothod") }.sorted()
        if let last = builds.last { return "\(base)/\(last)/clothod" }
        guard installed.status == 0, let path = installed.stdout.split(separator: "\n").last.map(String.init), !path.isEmpty else {
            throw Failure.failed("Couldn't install clothod: \(installed.stderr)")
        }
        return path
    }

    /// The installed clothod (see installedPath); kept for callers that start through `current`.
    func currentPath() throws -> String { try installedPath() }

    /// Starts the daemon unless it's running. Throws `holderTooOld` for exit code 3.
    func start() throws {
        let path = try currentPath()
        let result = try Self.run(path, ["start"], runtimeDir: runtimeDir, installDir: installDir)
        log("clothod start (\(path)) exited with \(result.status)")
        switch result.status {
        case 0: return
        case 3: throw Failure.holderTooOld(result.stderr.isEmpty ? "The running shells use an older clothod." : result.stderr)
        default: throw Failure.failed(result.stderr.isEmpty ? "clothod start exited with \(result.status)" : result.stderr)
        }
    }

    /// Where the daemon listens, as clothod itself reports it (`status --print-socket`), so the app never
    /// guesses at per-platform temp directories. Nil if this build can't say.
    func socketPath() -> String? {
        guard let path = try? installedPath(), let result = try? Self.run(path, ["status", "--print-socket"], runtimeDir: runtimeDir, installDir: installDir),
              result.status == 0, let socket = result.stdout.split(separator: "\n").last.map(String.init), !socket.isEmpty
        else { return nil }
        return socket
    }

    /// Runs a clothod subcommand (such as `hooks print claude`) with the installed build.
    func runClothod(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        try Self.run(try installedPath(), arguments, runtimeDir: runtimeDir, installDir: installDir)
    }

    /// Switches the running daemon to the installed build (`upgrade`: install, stop, start the new build,
    /// verify it took over). The holder and shells are kept. Throws `holderTooOld` for exit code 3.
    func upgrade() throws {
        // The bundled binary installs itself and switches the daemon over, removing the other versions.
        let path = source
        let result = try Self.run(path, ["upgrade"], runtimeDir: runtimeDir, installDir: installDir)
        log("clothod upgrade (\(path)) exited with \(result.status): \(result.stdout) \(result.stderr)")
        switch result.status {
        case 0: return
        case 3: throw Failure.holderTooOld(result.stderr.isEmpty ? "The running shells use an older clothod." : result.stderr)
        default: throw Failure.failed(result.stderr.isEmpty ? "clothod upgrade exited with \(result.status)" : result.stderr)
        }
    }

    /// Stops this daemon for good (holder, shells and all) and deletes its runtime and install directories.
    /// Only for the dev build's private daemon, when it quits.
    func shutdownAndRemove() {
        if let path = try? currentPath() { _ = try? Self.run(path, ["shutdown"], runtimeDir: runtimeDir, installDir: installDir) }
        for dir in [runtimeDir, installDir].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// Ends every workspace (the holder and its shells), then starts the current version.
    func restartClothod() throws {
        let path = try installedPath()
        _ = try Self.run(path, ["shutdown"], runtimeDir: runtimeDir, installDir: installDir)
        try start()
    }

    static func run(_ executable: String, _ args: [String], runtimeDir: String?, installDir: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") && !$0.key.hasPrefix("CLOTHO_") }
        if let runtimeDir { environment["CLOTHOD_RUNTIME_DIR"] = runtimeDir }
        if let installDir { environment["CLOTHOD_INSTALL_DIR"] = installDir }
        // A private runtime dir is a temporary instance: it ends itself, and removes its dir, once unused.
        // It also keeps its own config, so changing settings never writes the user's config.toml.
        if let runtimeDir {
            environment["CLOTHOD_EPHEMERAL"] = "exit"
            environment["CLOTHOD_CONFIG"] = filePath(runtimeDir, "config.toml")
        }
        process.environment = environment
        // Files, not pipes: `start` forks the daemon, which must not hold a pipe we wait on.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clothod-\(UUID().uuidString).out")
        let err = out.deletingPathExtension().appendingPathExtension("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        return (process.terminationStatus, read(out), read(err))
    }
}
