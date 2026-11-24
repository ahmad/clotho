@testable import ClothoKit
import Darwin
import XCTest

/// Replies are matched to requests by id alone. clothod answers a slow request (git, a worktree
/// checkout) when it is done, so replies come back in any order: each caller must still get its own.
final class ReplyOrderTests: XCTestCase {
    func testEachCallerGetsItsOwnReplyWhenTheyComeBackReversed() async throws {
        let daemon = ReorderingDaemon(hold: 4)
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        try await backend.start()

        async let first = backend.gitChanges(1, limit: nil)
        async let second = backend.gitDiff(2, path: "src/a.rs", group: .branch, oldPath: nil, context: nil)
        async let third = backend.gitChanges(3, limit: 10)
        async let fourth = backend.paneText(4)
        let (one, two, three, four) = try await (first, second, third, fourth)

        // Each result names the request it answers; a reply handed to the wrong caller would either
        // carry the wrong name or fail to decode as the caller's type.
        XCTAssertEqual(one.root, "/repo/1")
        XCTAssertEqual(two.path, "src/a.rs")
        XCTAssertEqual(two.status, .renamed)
        XCTAssertEqual(three.root, "/repo/3")
        XCTAssertEqual(four.lines, ["pane 4"])

        let held = daemon.held, answered = daemon.answered
        XCTAssertEqual(held.count, 4)
        XCTAssertEqual(Set(held).count, 4, "four different ids")
        XCTAssertEqual(answered, held.reversed(), "the daemon answered in reverse")

        // The replies nobody waited for (an unknown id before the four, one of theirs again after)
        // were dropped: the connection still answers, each request with its own reply.
        XCTAssertEqual(daemon.strays, 2)
        let after = try await backend.gitChanges(5, limit: nil)
        XCTAssertEqual(after.root, "/repo/5")
        _ = try await backend.request("ping", nil)
    }

    /// What the new requests put on the wire: optional fields are left out, not sent as null.
    func testGitAndWorktreeParams() async throws {
        let daemon = ScriptedDaemon(features: ["git.changes", "worktree"])
        let backend = ClothodBackend(configuration: .init(transport: daemon, clientName: "test"))
        defer { backend.stop() }
        try await backend.start()
        func params(_ method: String, _ index: Int = 0) throws -> [String: Any] {
            let calls = daemon.calls.filter { $0.method == method }
            return try XCTUnwrap(calls.count > index ? calls[index].params : nil, "\(method) call \(index)")
        }

        // The scripted daemon answers {}, which is no GitChanges: the request is what's checked.
        _ = try? await backend.gitChanges(3, limit: nil)
        _ = try? await backend.gitChanges(3, limit: 2000)
        XCTAssertEqual(try params("git.changes").keys.sorted(), ["pane"])
        XCTAssertEqual(try params("git.changes", 1)["limit"] as? Int, 2000)

        _ = try? await backend.gitDiff(3, path: "src/login.rs", group: .uncommitted, oldPath: nil, context: nil)
        _ = try? await backend.gitDiff(3, path: "src/auth.rs", group: .branch, oldPath: "src/session.rs", context: 0)
        let plain = try params("git.diff")
        XCTAssertEqual(plain.keys.sorted(), ["group", "pane", "path"], "no old_path and no context when nil")
        XCTAssertEqual(plain["group"] as? String, "uncommitted")
        XCTAssertEqual(plain["path"] as? String, "src/login.rs")
        let renamed = try params("git.diff", 1)
        XCTAssertEqual(renamed["group"] as? String, "branch")
        XCTAssertEqual(renamed["old_path"] as? String, "src/session.rs")
        XCTAssertEqual(renamed["context"] as? Int, 0)

        // A worktree needs the repository's folder: refused here, and nothing is sent.
        for spawn in [SpawnOptions(), SpawnOptions(cwd: "")] {
            do {
                _ = try await backend.createTab(in: 1, spawn: spawn, worktree: WorktreeRequest(name: "fix"))
                XCTFail("a worktree without cwd was sent")
            } catch {
                XCTAssertEqual((error as? BackendError)?.code, "bad_request")
            }
            do {
                _ = try await backend.createWorkspace(name: nil, spawn: spawn, worktree: WorktreeRequest(name: "fix"))
                XCTFail("a worktree without cwd was sent")
            } catch {
                XCTAssertEqual((error as? BackendError)?.code, "bad_request")
            }
        }
        XCTAssertFalse(daemon.calls.contains { $0.method == "tab.create" || $0.method == "workspace.create" })

        _ = try? await backend.createTab(in: 7, spawn: SpawnOptions(cwd: "/repo"), worktree: WorktreeRequest(name: "fix/login"))
        let tab = try params("tab.create")
        XCTAssertEqual(tab["workspace"] as? Int, 7)
        XCTAssertEqual(tab["cwd"] as? String, "/repo")
        XCTAssertEqual((tab["worktree"] as? [String: Any])?.keys.sorted(), ["name"], "no base when nil")
        XCTAssertEqual((tab["worktree"] as? [String: Any])?["name"] as? String, "fix/login")

        _ = try? await backend.createWorkspace(name: "fix", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/repo"),
                                               worktree: WorktreeRequest(name: "fix", base: "origin/main"))
        let workspace = try params("workspace.create")
        XCTAssertEqual(workspace["name"] as? String, "fix")
        XCTAssertEqual((workspace["worktree"] as? [String: Any])?["base"] as? String, "origin/main")
        XCTAssertEqual(workspace["command"] as? [String], ["/bin/sh"])

        // The replies decode with and without `worktree`.
        let with = try JSONDecoder().decode(CreatedTab.self, from: Data("""
        {"tab": 14, "pane": 31, "worktree": {"path": "/Users/me/Projects/clotho-fix-login", "branch": "fix/login", "head": "9f8e7d6"}}
        """.utf8))
        XCTAssertEqual(with, CreatedTab(tab: 14, pane: 31, worktree: CreatedWorktree(path: "/Users/me/Projects/clotho-fix-login", branch: "fix/login", head: "9f8e7d6")))
        XCTAssertNil(try JSONDecoder().decode(CreatedTab.self, from: Data(#"{"tab": 14, "pane": 31}"#.utf8)).worktree)
        XCTAssertNil(try JSONDecoder().decode(CreatedWorkspace.self, from: Data(#"{"workspace": 1, "tab": 14, "pane": 31, "worktree": null}"#.utf8)).worktree)
    }

    /// A backend that isn't a daemon answers the new requests with `unknown_method`, as for any other
    /// request it doesn't have.
    func testBackendsWithoutThemSayUnknownMethod() async {
        let backend: SessionBackend = Bare()
        func code(_ body: () async throws -> Void) async -> String? {
            do { try await body(); return nil } catch { return (error as? BackendError)?.code }
        }
        let changes = await code { _ = try await backend.gitChanges(1, limit: nil) }
        let diff = await code { _ = try await backend.gitDiff(1, path: "a", group: .uncommitted, oldPath: nil, context: nil) }
        let tab = await code { _ = try await backend.createTab(in: 1, spawn: SpawnOptions(cwd: "/repo"), worktree: WorktreeRequest(name: "x")) }
        let workspace = await code { _ = try await backend.createWorkspace(name: nil, spawn: SpawnOptions(cwd: "/repo"), worktree: WorktreeRequest(name: "x")) }
        XCTAssertEqual([changes, diff, tab, workspace], ["unknown_method", "unknown_method", "unknown_method", "unknown_method"])
        XCTAssertEqual(Hello.Feature(rawValue: "git.changes"), .gitChanges)
        XCTAssertEqual(Hello.Feature(rawValue: "worktree"), .worktree)
        XCTAssertNil(Hello.Feature(rawValue: "peek"), "not a feature this client uses")
    }

    /// The least a SessionBackend can be: everything optional comes from the protocol's defaults.
    private final class Bare: SessionBackend, @unchecked Sendable {
        let events = AsyncStream<SessionEvent> { $0.finish() }
        private var unsupported: BackendError { BackendError(code: "unsupported", message: "bare") }
        func start() async throws {}
        func stop() {}
        func getState() async throws -> ModelState { ModelState() }
        func createWorkspace(name: String?, spawn: SpawnOptions) async throws -> CreatedWorkspace { throw unsupported }
        func renameWorkspace(_ workspace: WorkspaceID, name: String) async throws {}
        func closeWorkspace(_ workspace: WorkspaceID) async throws {}
        func createTab(in workspace: WorkspaceID, spawn: SpawnOptions) async throws -> CreatedTab { throw unsupported }
        func renameTab(_ tab: TabID, title: String?) async throws {}
        func closeTab(_ tab: TabID) async throws {}
        func split(_ pane: PaneID, direction: Direction, ratio: Double?, spawn: SpawnOptions) async throws -> CreatedSplit { throw unsupported }
        func closePane(_ pane: PaneID) async throws {}
        func setRatio(_ split: SplitID, ratio: Double) async throws {}
        func focus(_ target: FocusTarget) async throws {}
        func subscribe(_ pane: PaneID, haveSeq: UInt64?, scrollback: Int?, viewport: Size?) async throws -> Subscription { throw unsupported }
        func unsubscribe(_ pane: PaneID) async throws {}
        func setViewport(_ pane: PaneID, _ size: Size) async throws {}
        func resize(_ pane: PaneID, _ size: Size) async throws {}
        func sendInput(_ pane: PaneID, _ bytes: Data) {}
    }
}

/// A daemon on the far end of a socketpair that answers hello, `events.subscribe` and `ping` at once
/// and holds everything else until it has `hold` requests. Then it answers them newest first, each
/// with a result that names its own request, with a reply for an id nobody sent before them and a
/// second reply for one of theirs after. From then on it answers everything at once.
final class ReorderingDaemon: ClothodTransport, @unchecked Sendable {
    let name = "reordering"
    let maxReconnectDelay: TimeInterval = 0.2
    let heartbeatInterval: TimeInterval? = nil
    private let hold: Int
    private let lock = NSLock()
    private var heldIDs: [Int] = []
    private var answeredIDs: [Int] = []
    private var strayCount = 0

    init(hold: Int) { self.hold = hold }

    /// The ids of the held requests, in the order they arrived.
    var held: [Int] { lock.lock(); defer { lock.unlock() }; return heldIDs }
    /// The same ids, in the order they were answered.
    var answered: [Int] { lock.lock(); defer { lock.unlock() }; return answeredIDs }
    /// Replies sent that no request was waiting for.
    var strays: Int { lock.lock(); defer { lock.unlock() }; return strayCount }

    func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw BackendError(code: "io", message: "socketpair") }
        let (client, server) = (fds[0], fds[1])
        Thread { [self] in serve(server) }.start()
        return ByteStream(readFD: client, writeFD: client, onShutdown: { shutdown(client, SHUT_RDWR) })
    }

    /// A result only its own request's caller can use: named after the request's pane or path.
    private static func result(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let pane = (params["pane"] as? NSNumber)?.intValue ?? 0
        switch method {
        case "git.changes":
            let group: [String: Any] = ["files": [Any](), "total": 0, "truncated": false]
            return ["root": "/repo/\(pane)", "uncommitted": group]
        case "git.diff":
            return ["path": params["path"] as? String ?? "", "status": "renamed", "binary": false, "truncated": false,
                    "added": 0, "removed": 0, "hunks": [Any]()]
        case "pane.text":
            return ["lines": ["pane \(pane)"], "cols": 80, "rows": 1]
        default:
            return [:]
        }
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
        func reply(_ id: Int, _ result: [String: Any]) {
            guard let body = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result] as [String: Any]) else { return }
            var frame = [UInt8]()
            let size = UInt32(body.count + 1)
            frame += [UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff), 1]
            frame += body
            _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        var waiting: [(id: Int, method: String, params: [String: Any])] = []
        var released = false
        while let header = readExactly(5) {
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length >= 1, let body = readExactly(length - 1) else { return }
            guard header[4] == 1, let message = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  let id = (message["id"] as? NSNumber)?.intValue, let method = message["method"] as? String else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "hello":
                reply(id, ["protocol": 1, "daemon": "clothod", "version": "0.1.32", "instance": "test", "features": ["git.changes", "worktree"]])
                continue
            case "events.subscribe", "ping":
                reply(id, [:])
                continue
            default:
                break
            }
            if released {
                reply(id, Self.result(method, params))
                continue
            }
            waiting.append((id, method, params))
            lock.lock(); heldIDs.append(id); lock.unlock()
            guard waiting.count == hold else { continue }
            // Recorded before anything is written: a caller may look as soon as its reply arrives.
            lock.lock()
            answeredIDs = waiting.reversed().map { $0.id }
            strayCount += 2
            lock.unlock()
            // An id far from any the client uses, with a result that would decode as a GitChanges.
            reply(987_654, Self.result("git.changes", ["pane": 0]))
            for request in waiting.reversed() { reply(request.id, Self.result(request.method, request.params)) }
            // Again for a request that already has its answer.
            if let last = waiting.last { reply(last.id, Self.result("git.changes", ["pane": 0])) }
            waiting.removeAll()
            released = true
        }
    }
}
