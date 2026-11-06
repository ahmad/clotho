@testable import ClothoKit
import XCTest

/// When a stream counts as stalled: only when the daemon owes it something.
final class FileStallRuleTests: XCTestCase {
    private let now = Date()

    private func write(sent: UInt64, acked: UInt64, fin: Bool = false, quiet: TimeInterval) -> FileStream {
        let state = FileStream(.write)
        state.window = 4 << 20
        state.sent = sent
        state.acked = acked
        state.finSent = fin
        state.lastActivity = now.addingTimeInterval(-quiet)
        return state
    }

    func testWrites() {
        // A quarter window unacked for a minute: the daemon owes an ack.
        XCTAssertTrue(ClothodBackend.isStalled(write(sent: 2 << 20, acked: 0, quiet: 61), now: now, timeout: 60))
        // Not for long enough yet.
        XCTAssertFalse(ClothodBackend.isStalled(write(sent: 2 << 20, acked: 0, quiet: 30), now: now, timeout: 60))
        // Less than a quarter window: the daemon may be waiting for more (a slow source).
        XCTAssertFalse(ClothodBackend.isStalled(write(sent: 100_000, acked: 0, quiet: 600), now: now, timeout: 60))
        // The end was sent and fs.done never came.
        XCTAssertTrue(ClothodBackend.isStalled(write(sent: 10, acked: 10, fin: true, quiet: 61), now: now, timeout: 60))
        // Ended already.
        let ended = write(sent: 2 << 20, acked: 0, quiet: 600)
        ended.outcome = .failure(CancellationError())
        XCTAssertFalse(ClothodBackend.isStalled(ended, now: now, timeout: 60))
    }

    func testReads() {
        let (_, feed) = AsyncThrowingStream.makeStream(of: Data.self)
        let state = FileStream(.read(feed))
        state.window = 4 << 20
        state.chunk = 256 << 10
        state.lastActivity = now.addingTimeInterval(-120)
        // Room in the window and nothing arriving: stalled.
        state.received = 1 << 20
        state.readAcked = 1 << 20
        XCTAssertTrue(ClothodBackend.isStalled(state, now: now, timeout: 60))
        // The window is full because the app isn't taking the data: that's not the daemon's fault.
        state.received = (1 << 20) + (4 << 20) - 1000
        XCTAssertFalse(ClothodBackend.isStalled(state, now: now, timeout: 60))
    }
}

extension ClothodBackendTests {
    /// A daemon that stops answering mid-upload (SIGSTOP) fails the write with `stalled` and drops the
    /// connection; once it answers again, FileTransfer's retry resumes the file and finishes it.
    func testStalledUploadResumes() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        backend.fileStallTimeout = 2
        try await backend.start()
        guard let pid = backend.locked({ backend.lastHello?.pid }) else { return XCTFail("no daemon pid in hello") }
        let root = try makeFileRoot()
        let source = filePath(root, "src")
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        let data = FileBackendChecks.randomData(24 << 20)
        try data.write(to: URL(fileURLWithPath: filePath(source, "big.bin")))

        let copy = FileTransfer(from: LocalFileBackend(), to: backend)
        copy.chunk = 64 << 10
        copy.window = 1 << 20
        copy.retryDelays = [1, 2, 3, 3, 3]
        let retries = RetryLog()
        copy.onRetry = { _, error, _ in retries.add((error as? BackendError)?.code ?? "\(error)") }
        let stopped = StopOnce()
        try await copy.copy([filePath(source, "big.bin")], into: root, conflict: .replace) { progress in
            // Freeze the daemon a few MB in, and let it go again after the watchdog has fired.
            guard progress.doneBytes > 4 << 20, stopped.first() else { return }
            kill(pid, SIGSTOP)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { kill(pid, SIGCONT) }
        }
        XCTAssertTrue(retries.codes.contains("stalled"), "retries: \(retries.codes)")
        let back = try Data(contentsOf: URL(fileURLWithPath: filePath(root, "big.bin")))
        XCTAssertEqual(back, data)
    }
}

final class RetryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var codes: [String] { lock.withLock { stored } }
    func add(_ code: String) { lock.withLock { stored.append(code) } }
}

final class StopOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

final class SSHTargetTests: XCTestCase {
    func testRefusesOptionsAndOddCharacters() {
        XCTAssertNil(SSHTarget.problem("user@imac"))
        XCTAssertNil(SSHTarget.problem("imac"))
        XCTAssertNil(SSHTarget.problem("me@192.0.2.2"))
        XCTAssertNotNil(SSHTarget.problem("-oProxyCommand=touch /tmp/pwned"))
        XCTAssertNotNil(SSHTarget.problem("-p22"))
        XCTAssertNotNil(SSHTarget.problem("me@host extra"))
        XCTAssertNotNil(SSHTarget.problem("me@host\n"))
        XCTAssertNotNil(SSHTarget.problem("me@ho\u{07}st"))
        XCTAssertNotNil(SSHTarget.problem(""))
    }

    /// Even if a bad target got saved somehow, the runner refuses it before ssh starts.
    func testRunnerRefuses() {
        let runner = SSHCommandRunner(target: "-oProxyCommand=false")
        XCTAssertThrowsError(try runner.run("true", input: nil))
    }
}
