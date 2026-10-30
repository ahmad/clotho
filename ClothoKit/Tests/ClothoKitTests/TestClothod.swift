import Foundation

/// Running clothod's CLI from tests. Every call names the test's runtime dir twice, as `--runtime-dir`
/// and as CLOTHOD_RUNTIME_DIR, so a test client never falls back to the default instance, the user's;
/// and every call is bounded: after `timeout` the process is ended (SIGTERM, then SIGKILL a second
/// later), so an interrupted run can't leave a client waiting for long.
enum TestClothod {
    static let timeout: TimeInterval = 15

    /// `clothod <args> --runtime-dir <runtimeDir>`; its combined output.
    @discardableResult
    static func run(_ clothod: String, _ args: [String], runtimeDir: String, environment: [String: String] = [:],
                    timeout: TimeInterval = timeout) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: clothod)
        process.arguments = args + ["--runtime-dir", runtimeDir]
        process.environment = ProcessInfo.processInfo.environment.merging(environment.merging(["CLOTHOD_RUNTIME_DIR": runtimeDir]) { $1 }) { $1 }
        // A file, not a pipe: `start` forks the daemon, which must not hold a pipe we read to its end.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cmac-clothod-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    /// Stops the test's instance: `clothod shutdown` (bounded), then anything still using its runtime
    /// dir (shutdown needs the logic process, which a test may have killed).
    static func shutdown(_ clothod: String, runtimeDir: String) {
        _ = try? run(clothod, ["shutdown"], runtimeDir: runtimeDir, environment: ["HOME": NSHomeDirectory()])
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "runtime-dir \(runtimeDir)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }
}
