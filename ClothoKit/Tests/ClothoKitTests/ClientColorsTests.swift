@testable import ClothoKit
import ClothoFake
import Darwin
import XCTest

/// `client.colors`: the client tells the daemon the colours it shows panes in, after every hello and on
/// each change, so apps that ask (Claude Code's "auto" theme) draw for the right background. Only to a
/// daemon that announces the feature.
final class ClientColorsTests: XCTestCase {
    func testJSONIsHexStrings() throws {
        let colors = TerminalColors(ClothoPalette.light)
        let json = colors.json
        XCTAssertEqual(json["background"] as? String, "#f7f7f5")
        XCTAssertEqual(json["foreground"] as? String, "#2b3035")
        XCTAssertEqual(json["cursor"] as? String, "#3f6e8f")
        let ansi = try XCTUnwrap(json["ansi"] as? [String])
        XCTAssertEqual(ansi.count, 16)
        XCTAssertEqual(ansi[1], "#b3392f")
        XCTAssertTrue(ansi.allSatisfy { $0.count == 7 && $0.hasPrefix("#") })
        let bare = TerminalColors(foreground: 0x000001, background: 0xFFFFFF).json
        XCTAssertEqual(bare.keys.sorted(), ["background", "foreground"], "cursor and ansi only when set")
        XCTAssertEqual(bare["foreground"] as? String, "#000001")
    }

    func testSentAfterHelloAndOnChange() async throws {
        let daemon = ScriptedDaemon(features: ["client.colors"])
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        backend.setTerminalColors(TerminalColors(ClothoPalette.dark))
        try await backend.start()
        try await daemon.waitFor { $0.contains { $0.method == "client.colors" } }
        var calls = daemon.calls
        let hello = try XCTUnwrap(calls.firstIndex { $0.method == "hello" })
        let first = try XCTUnwrap(calls.firstIndex { $0.method == "client.colors" })
        XCTAssertLessThan(hello, first, "after hello")
        if let subscribe = calls.firstIndex(where: { $0.method == "events.subscribe" }) {
            XCTAssertLessThan(first, subscribe, "before the events (and any pane) subscribe")
        }
        XCTAssertEqual((calls[first].params?["colors"] as? [String: Any])?["background"] as? String, "#1d2022")

        // The appearance flips: sent again. The same colours again: not.
        backend.setTerminalColors(TerminalColors(ClothoPalette.light))
        backend.setTerminalColors(TerminalColors(ClothoPalette.light))
        try await daemon.waitFor { $0.filter { $0.method == "client.colors" }.count >= 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        calls = daemon.calls.filter { $0.method == "client.colors" }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual((calls[1].params?["colors"] as? [String: Any])?["background"] as? String, "#f7f7f5")

        // Cleared: colors null.
        backend.setTerminalColors(nil)
        try await daemon.waitFor { $0.filter { $0.method == "client.colors" }.count >= 3 }
        XCTAssertTrue(daemon.calls.last { $0.method == "client.colors" }?.params?["colors"] is NSNull)
    }

    func testNeverSentWithoutTheFeature() async throws {
        let daemon = ScriptedDaemon(features: ["pane.keys"])
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        backend.setTerminalColors(TerminalColors(ClothoPalette.dark))
        try await backend.start()
        try await daemon.waitFor { $0.contains { $0.method == "events.subscribe" } }
        backend.setTerminalColors(TerminalColors(ClothoPalette.light))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(daemon.calls.contains { $0.method == "client.colors" }, "an older daemon would answer unknown_method")
    }
}

/// A daemon on the far end of a socketpair that answers every request with {} (hello with `features`) and
/// records what it was asked.
final class ScriptedDaemon: ClothodTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var params: [String: Any]?
    }

    let name = "scripted"
    let maxReconnectDelay: TimeInterval = 0.2
    let heartbeatInterval: TimeInterval? = nil
    private let features: [String]
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(features: [String]) { self.features = features }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func waitFor(timeout: TimeInterval = 5, _ condition: ([Call]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(calls) {
            if Date() > deadline { throw BackendError(code: "timeout", message: "timed out; calls: \(calls.map(\.method))") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw BackendError(code: "io", message: "socketpair") }
        let (client, server) = (fds[0], fds[1])
        Thread { [self] in serve(server) }.start()
        return ByteStream(readFD: client, writeFD: client, onShutdown: { shutdown(client, SHUT_RDWR) })
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        func readExactly(_ count: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
                if n <= 0 { return nil }
                got += n
            }
            return buffer
        }
        while let header = readExactly(5) {
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard let body = readExactly(length - 1) else { return }
            guard header[4] == 1, let message = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  let id = message["id"], let method = message["method"] as? String else { continue }
            lock.lock()
            recorded.append(Call(method: method, params: message["params"] as? [String: Any]))
            lock.unlock()
            let result: Any = method == "hello"
                ? ["protocol": 1, "daemon": "clothod", "version": "0.1.20", "instance": "test", "features": features]
                : [String: Any]()
            let reply = try! JSONSerialization.data(withJSONObject: ["id": id, "result": result])
            var frame = [UInt8]()
            let size = UInt32(reply.count + 1)
            frame += [UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff), 1]
            frame += reply
            _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }
}

/// FakeBackend keeps what it was given, for app tests.
final class FakeBackendColorsTests: XCTestCase {
    func testRecordsTheLastColours() {
        let fake = FakeBackend()
        XCTAssertNil(fake.terminalColors)
        fake.setTerminalColors(TerminalColors(ClothoPalette.light))
        XCTAssertEqual(fake.terminalColors, TerminalColors(ClothoPalette.light))
        fake.setTerminalColors(nil)
        XCTAssertNil(fake.terminalColors)
        XCTAssertEqual(fake.terminalColorsCalls, 2)
    }
}
