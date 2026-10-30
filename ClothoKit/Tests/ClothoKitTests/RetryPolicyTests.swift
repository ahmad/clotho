@testable import ClothoKit
import Foundation
import XCTest

/// A machine that can't be reached: a few tries with a growing wait, then nothing (no ssh in a loop)
/// until asked again, which starts the count over.
final class RetryPolicyTests: XCTestCase {
    func testDelays() throws {
        let remote = RetryPolicy.remote
        XCTAssertEqual(remote.delay(afterFailures: 1), 1)
        XCTAssertEqual(remote.delay(afterFailures: 2), 2)
        XCTAssertNil(remote.delay(afterFailures: 3), "three failures in a row: stop")
        XCTAssertNil(remote.delay(afterFailures: 9))
        let forever = RetryPolicy(limit: nil, firstDelay: 0.1, maxDelay: 2)
        XCTAssertEqual(forever.delay(afterFailures: 1), 0.1)
        XCTAssertEqual(try XCTUnwrap(forever.delay(afterFailures: 3)), 0.4, accuracy: 1e-9)
        XCTAssertEqual(forever.delay(afterFailures: 50), 2, "capped")
    }

    /// Never reaches anything; counts the attempts.
    final class Unreachable: ClothodTransport, @unchecked Sendable {
        let name = "unreachable"
        let maxReconnectDelay: TimeInterval = 30
        let heartbeatInterval: TimeInterval? = nil
        private let lock = NSLock()
        private var count = 0
        var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }

        func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
            lock.lock(); count += 1; lock.unlock()
            progress("Checking devbox")
            throw BackendError(code: "unreachable", message: "Can't resolve devbox")
        }
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testStopsAfterTheLimitAndResumesWhenAsked() async throws {
        let transport = Unreachable()
        var configuration = ClothodBackend.Configuration(transport: transport, clientName: "test")
        configuration.retry = RetryPolicy(limit: 3, firstDelay: 0.05, maxDelay: 1)
        let backend = ClothodBackend(configuration: configuration)
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        do { try await store.start(); XCTFail("can't connect") } catch {}

        try await wait("the pause") { store.retryPaused }
        XCTAssertEqual(transport.attempts, 3, "the first connect and two retries")
        XCTAssertEqual(store.connection, .reconnecting("Can't resolve devbox"))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(transport.attempts, 3, "nothing while paused")

        // Reconnect (the button, a network change, wake): three more, then paused again.
        backend.reconnectNow()
        try await wait("the next tries") { transport.attempts == 6 && store.retryPaused }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(transport.attempts, 6)
        XCTAssertTrue(store.retryPaused)
    }

    @MainActor
    func testWithoutALimitItKeepsTrying() async throws {
        let transport = Unreachable()
        var configuration = ClothodBackend.Configuration(transport: transport, clientName: "test")
        configuration.retry = RetryPolicy(limit: nil, firstDelay: 0.02, maxDelay: 0.05)
        let backend = ClothodBackend(configuration: configuration)
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        do { try await store.start() } catch {}
        try await wait("many tries") { transport.attempts >= 8 }
        XCTAssertFalse(store.retryPaused)
    }
}
