@testable import ClothoKit
import Darwin
import XCTest

/// Changes, diffs and worktree Tabs against a real clothod (0.1.32 or later) and a real repository,
/// each test with its own ephemeral daemon. The repository sits in a temp folder of its own
/// (`<prefix><pid>-git-XXXX/repo`), so the worktrees the daemon makes beside it land in that folder too
/// and go with it in tearDown. Skipped when clothod isn't built or lacks `git.changes`, and when there
/// is no git 2.31 or later.
final class GitChangesDaemonTests: XCTestCase {
    var clothod: String!
    var runtimeDir: String!
    var git: String!
    /// The repository's own temp folder, as the system spells it (no symlinks).
    var parent: String!
    var repo: String { parent + "/repo" }

    override func setUpWithError() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["CLOTHOD_BIN"]
            ?? package.deletingLastPathComponent().appendingPathComponent("clothod/target/debug/clothod").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary), "clothod isn't built")
        let found = Self.findGit()
        try XCTSkipUnless(found != nil, "no git 2.31 or later on this machine")
        git = found
        // Assigned only once nothing can skip any more, so tearDown has a daemon to stop exactly when
        // one could have been started.
        clothod = binary
        let prefix = ProcessInfo.processInfo.environment["CLOTHOKIT_RUNTIME_PREFIX"] ?? "/tmp/ckt-"
        runtimeDir = "\(prefix)\(getpid())-\(UUID().uuidString.prefix(6))"
        let made = "\(prefix)\(getpid())-git-\(UUID().uuidString.prefix(4))"
        try FileManager.default.createDirectory(atPath: made + "/repo", withIntermediateDirectories: true)
        // /tmp is a link on macOS, and the daemon reports paths without links.
        parent = Self.real(made)
        try makeRepository()
    }

    override func tearDown() {
        if let clothod, let runtimeDir {
            TestClothod.shutdown(clothod, runtimeDir: runtimeDir)
            try? FileManager.default.removeItem(atPath: runtimeDir)
        }
        if let parent { try? FileManager.default.removeItem(atPath: parent) }
    }

    // MARK: Helpers

    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The first git that says it is 2.31 or later, among the places clothod looks.
    static func findGit() -> String? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/git" }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let version = try? output(of: candidate, ["--version"], environment: [:]) else { continue }
            // "git version 2.54.0", "git version 2.39.5 (Apple Git-154)".
            let numbers = version.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
            guard numbers.count == 2 else { continue }
            if numbers[0] > 2 || (numbers[0] == 2 && numbers[1] >= 31) { return candidate }
        }
        return nil
    }

    /// Runs a program to its end; its combined output. Throws when it can't run or fails.
    @discardableResult
    static func output(of executable: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"]) { old, _ in old }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackendError(code: "test", message: "\(executable) \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }

    /// The test's own git in the repository: no system or global config, and a fixed author.
    @discardableResult
    func runGit(_ arguments: String...) throws -> String {
        try Self.output(of: git, ["-C", repo] + arguments, environment: [
            "HOME": parent, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Clotho Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Clotho Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ])
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: repo + "/" + name))
    }

    /// One commit on `main`, then four uncommitted changes: a.txt modified (+2 −1), blob.bin modified
    /// (binary), old.txt renamed to new.txt, notes.txt untracked (+1). same.txt stays as committed.
    func makeRepository() throws {
        try runGit("init", "-q", "-b", "main")
        try write("a.txt", "one\ntwo\nthree\n")
        try write("old.txt", (0 ..< 20).map { "line \($0)\n" }.joined())
        try write("same.txt", "same\n")
        try Data([0, 1, 2, 0, 255] + [UInt8](repeating: 0, count: 95)).write(to: URL(fileURLWithPath: repo + "/blob.bin"))
        try runGit("add", ".")
        try runGit("commit", "-q", "-m", "first")
        try write("a.txt", "one\n2\nthree\nfour\n")
        try write("notes.txt", "a note\n")
        try runGit("mv", "old.txt", "new.txt")
        try Data([9, 0, 7] + [UInt8](repeating: 0, count: 87)).write(to: URL(fileURLWithPath: repo + "/blob.bin"))
    }

    func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func expect(_ code: GitErrorCode, _ what: String, _ body: () async throws -> Void) async -> BackendError? {
        do {
            try await body()
            XCTFail("\(what) succeeded")
            return nil
        } catch {
            XCTAssertEqual(error.gitErrorCode, code, "\(what): \(error)")
            return error as? BackendError
        }
    }

    /// The pane as its latest `pane` event has it.
    static func latestPane(_ pane: PaneID, in collector: FakeBackendTests.Collector) -> Pane? {
        for event in collector.all.reversed() {
            if case let .pane(found, _) = event, found.id == pane { return found }
        }
        return nil
    }

    /// The pane as the latest event that carries it has it (a `pane` event, or a whole `state`).
    static func current(_ pane: PaneID, in collector: FakeBackendTests.Collector) -> Pane? {
        for event in collector.all.reversed() {
            if case let .pane(found, _) = event, found.id == pane { return found }
            if case let .state(state) = event, let found = state.pane(pane) { return found }
        }
        return nil
    }

    /// `ping`'s reply: how many fields it has ({} has none), or -1 when it isn't an object.
    func ping(_ backend: ClothodBackend) async throws -> Int {
        let reply = try await backend.request("ping", nil)
        return (reply as? [String: Any])?.count ?? -1
    }

    /// A backend on the test's own ephemeral daemon, connected, with a Workspace whose pane is a
    /// shell in the repository. Skips when this clothod has no `git.changes`.
    func connect() async throws -> (backend: ClothodBackend, collector: FakeBackendTests.Collector, reader: Task<Void, Never>, created: CreatedWorkspace) {
        let clothod = clothod!, dir = runtimeDir!
        let backend = ClothodBackend(configuration: .init(
            socketPath: ClothodBackend.defaultSocketPath(runtimeDir: dir), clientName: "clothokit-git-tests",
            startDaemon: {
                // A private runtime dir needs an ephemeral instance, with its own config.
                _ = try TestClothod.run(clothod, ["start"], runtimeDir: dir,
                                        environment: ["CLOTHOD_EPHEMERAL": "60", "CLOTHOD_CONFIG": dir + "/config.toml"])
            }))
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in backend.events { collector.add(event) } }
        do {
            try await backend.start()
            guard let hello = backend.locked({ backend.lastHello }), hello.features.contains(.gitChanges), hello.features.contains(.worktree) else {
                throw XCTSkip("this clothod predates git.changes")
            }
            let created = try await backend.createWorkspace(name: "git", spawn: SpawnOptions(command: ["/bin/sh"], cwd: repo))
            return (backend, collector, reader, created)
        } catch {
            backend.stop()
            reader.cancel()
            throw error
        }
    }

    // MARK: Tests

    func testSummaryListAndDiff() async throws {
        let (backend, collector, reader, created) = try await connect()
        defer { backend.stop(); reader.cancel() }
        let pane = created.pane

        // The summary comes on its own, as a `pane` event, once git has run.
        try await waitFor("the pane's changes", timeout: 20) { Self.latestPane(pane, in: collector)?.git?.changes != nil }
        let git = try XCTUnwrap(Self.latestPane(pane, in: collector)?.git)
        XCTAssertEqual(git.repo, "repo")
        XCTAssertEqual(git.root, repo)
        XCTAssertEqual(git.branch, "main")
        XCTAssertNil(git.changesReason)
        let summary = try XCTUnwrap(git.changes)
        XCTAssertEqual(summary.uncommitted, PaneGit.Changes.Count(files: 4, added: 3, removed: 1))
        XCTAssertNil(summary.branch, "on the base branch itself")
        XCTAssertNil(summary.reason)
        XCTAssertEqual(ChangeCountText.strip(summary), "+3 \u{2212}1 · 4 files")

        // The list: sorted by path, with the same totals.
        let changes = try await backend.gitChanges(pane, limit: nil)
        XCTAssertEqual(changes.root, repo)
        XCTAssertEqual(changes.branch, "main")
        XCTAssertEqual(changes.head, git.head)
        XCTAssertNil(changes.branchChanges)
        XCTAssertEqual(changes.branchReason, "no_base")
        XCTAssertNil(GitText.branchReason(changes.branchReason))
        XCTAssertEqual(changes.summary, summary, "the list and the pane's count agree")
        XCTAssertEqual(changes.uncommitted.files, [
            GitChangedFile(path: "a.txt", status: .modified, added: 2, removed: 1),
            GitChangedFile(path: "blob.bin", status: .modified, added: nil, removed: nil, binary: true),
            GitChangedFile(path: "new.txt", oldPath: "old.txt", status: .renamed, added: 0, removed: 0),
            GitChangedFile(path: "notes.txt", status: .untracked, added: 1, removed: 0),
        ])
        XCTAssertFalse(changes.uncommitted.truncated)
        let cut = try await backend.gitChanges(pane, limit: 1)
        XCTAssertEqual(cut.uncommitted.files.map(\.path), ["a.txt"])
        XCTAssertTrue(cut.uncommitted.truncated)
        XCTAssertEqual(cut.uncommitted.total, 4)
        XCTAssertEqual(cut.uncommitted.more, 3)

        // One file's diff.
        let diff = try await backend.gitDiff(pane, path: "a.txt", group: .uncommitted, oldPath: nil, context: nil)
        XCTAssertEqual(diff.status, .modified)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        let hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .context, .added])
        XCTAssertEqual(hunk.lines.map(\.text), ["one", "two", "2", "three", "four"])
        XCTAssertEqual(hunk.sideBySideRows().map { "\($0.old?.text ?? "") | \($0.new?.text ?? "")" }, ["one | one", "two | 2", "three | three", " | four"])
        let none = try await backend.gitDiff(pane, path: "a.txt", group: .uncommitted, oldPath: nil, context: 0)
        XCTAssertFalse(none.hunks.flatMap(\.lines).contains { $0.kind == .context }, "context 0")
        let untracked = try await backend.gitDiff(pane, path: "notes.txt", group: .uncommitted, oldPath: nil, context: nil)
        XCTAssertEqual(untracked.hunks.flatMap(\.lines).map(\.text), ["a note"], "an untracked file is one hunk of added lines")

        // A rename asked for with its old path: renamed, and nothing changed inside it.
        let renamed = try await backend.gitDiff(pane, path: "new.txt", group: .uncommitted, oldPath: "old.txt", context: nil)
        XCTAssertEqual(renamed.status, .renamed)
        XCTAssertEqual(renamed.oldPath, "old.txt")
        XCTAssertTrue(renamed.hunks.isEmpty)
        let binary = try await backend.gitDiff(pane, path: "blob.bin", group: .uncommitted, oldPath: nil, context: nil)
        XCTAssertTrue(binary.binary)
        XCTAssertTrue(binary.hunks.isEmpty)

        // Errors.
        _ = await expect(.notChanged, "a file with no changes") {
            _ = try await backend.gitDiff(pane, path: "same.txt", group: .uncommitted, oldPath: nil, context: nil)
        }
        _ = await expect(.badPath, "a path outside the repository") {
            _ = try await backend.gitDiff(pane, path: "../outside.txt", group: .uncommitted, oldPath: nil, context: nil)
        }
        _ = await expect(.badRequest, "too much context") {
            _ = try await backend.gitDiff(pane, path: "a.txt", group: .uncommitted, oldPath: nil, context: 21)
        }
        _ = await expect(.notFound, "a pane that isn't there") { _ = try await backend.gitChanges(987_654, limit: nil) }
        let elsewhere = try await backend.createTab(in: created.workspace, spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        _ = await expect(.notARepo, "changes of a pane in /tmp") { _ = try await backend.gitChanges(elsewhere.pane, limit: nil) }
        _ = await expect(.notARepo, "a diff for a pane in /tmp") {
            _ = try await backend.gitDiff(elsewhere.pane, path: "a.txt", group: .uncommitted, oldPath: nil, context: nil)
        }
    }

    /// Three requests at once, two of them waiting on git: each reply reaches its own caller and
    /// decodes as that caller's type.
    func testRequestsFiredTogetherEachGetTheirOwnReply() async throws {
        let (backend, _, reader, created) = try await connect()
        defer { backend.stop(); reader.cancel() }
        let pane = created.pane
        for round in 0 ..< 3 {
            async let changes = backend.gitChanges(pane, limit: nil)
            async let diff = backend.gitDiff(pane, path: "a.txt", group: .uncommitted, oldPath: nil, context: nil)
            async let alive = self.ping(backend)
            async let text = backend.paneText(pane)
            let (listed, patch, pong, screen) = try await (changes, diff, alive, text)
            XCTAssertEqual(listed.root, repo, "round \(round)")
            XCTAssertEqual(listed.uncommitted.total, 4)
            XCTAssertEqual(patch.path, "a.txt")
            XCTAssertEqual(patch.added, 2)
            XCTAssertEqual(pong, 0, "ping answers {}")
            XCTAssertGreaterThan(screen.cols, 0)
        }
    }

    func testWorktreeTab() async throws {
        let (backend, collector, reader, created) = try await connect()
        defer { backend.stop(); reader.cancel() }
        let spawn = SpawnOptions(command: ["/bin/sh"], cwd: repo)
        let head = try runGit("rev-parse", "--short=7", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        let tab = try await backend.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "fix/login"))
        let folder = parent + "/repo-fix-login"
        XCTAssertEqual(tab.worktree, CreatedWorktree(path: folder, branch: "fix/login", head: head), "beside the repository")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/a.txt"), "checked out")
        XCTAssertEqual(try String(contentsOfFile: folder + "/a.txt", encoding: .utf8), "one\ntwo\nthree\n", "from HEAD, not the work tree")

        // The new pane is in the worktree, and says so.
        try await waitFor("the new pane's worktree", timeout: 20) { Self.current(tab.pane, in: collector)?.git?.worktree != nil }
        let git = try XCTUnwrap(Self.current(tab.pane, in: collector)?.git)
        XCTAssertEqual(git.repo, "repo")
        XCTAssertEqual(git.root, folder)
        XCTAssertEqual(git.branch, "fix/login")
        XCTAssertEqual(git.worktree, PaneGit.Worktree(name: "repo-fix-login", path: "../repo-fix-login"))
        let state = try await backend.getState()
        XCTAssertEqual(state.workspace(created.workspace)?.tabs.map(\.id), [created.tab, tab.tab])
        XCTAssertEqual(state.pane(tab.pane)?.cwd, folder)

        // A fresh worktree: a branch group of zeros against where it started.
        let changes = try await backend.gitChanges(tab.pane, limit: nil)
        XCTAssertEqual(changes.root, folder)
        XCTAssertEqual(changes.uncommitted.total, 0)
        let branch = try XCTUnwrap(changes.branchChanges)
        XCTAssertEqual(branch.base, "main")
        XCTAssertEqual(branch.commits, 0)
        XCTAssertEqual(branch.total, 0)
        XCTAssertEqual(branch.mergeBase, head)
        XCTAssertTrue(changes.summary.isEmpty)

        // With a base, in a new Workspace.
        let workspace = try await backend.createWorkspace(name: "second", spawn: spawn, worktree: WorktreeRequest(name: "second", base: "main"))
        XCTAssertEqual(workspace.worktree, CreatedWorktree(path: parent + "/repo-second", branch: "second", head: head))

        // Errors: nothing is made, and each has its words.
        let exists = await expect(.worktreeExists, "the same name again") {
            _ = try await backend.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "fix/login"))
        }
        XCTAssertEqual(exists.map { GitText.worktreeError($0) }, "A file or folder is already there: \(folder) already exists.")
        XCTAssertEqual(exists?.worktreeLeftBehind, false)
        let name = await expect(.worktreeName, "a name with a space") {
            _ = try await backend.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "a b"))
        }
        XCTAssertEqual(name?.worktreeLeftBehind, false)
        let base = await expect(.badBase, "a base that is no commit") {
            _ = try await backend.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "x", base: "nope"))
        }
        XCTAssertEqual(base.map { GitText.worktreeError($0) }, "nope is not a commit here.")
        _ = await expect(.notARepo, "a folder outside any repository") {
            _ = try await backend.createTab(in: created.workspace, spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"), worktree: WorktreeRequest(name: "x"))
        }
        let gone = await expect(.notFound, "a Workspace that isn't there") {
            _ = try await backend.createTab(in: 987_654, spawn: spawn, worktree: WorktreeRequest(name: "x"))
        }
        XCTAssertEqual(gone?.worktreeLeftBehind, false, "nothing was made")
        let folders = try FileManager.default.contentsOfDirectory(atPath: parent).sorted()
        XCTAssertEqual(folders, ["repo", "repo-fix-login", "repo-second"], "the failed ones left nothing")
        XCTAssertFalse(try runGit("branch", "--list", "x").contains("x"), "nor a branch")
        let after = try await backend.getState()
        XCTAssertEqual(after.workspace(created.workspace)?.tabs.count, 2)
    }

    /// The pane can't start (no such command) after the worktree was made: the error says the worktree
    /// stays, and it does.
    func testSpawnFailedLeavesTheWorktree() async throws {
        let (backend, _, reader, created) = try await connect()
        defer { backend.stop(); reader.cancel() }
        let spawn = SpawnOptions(command: ["/nonexistent/cmac-no-such-command"], cwd: repo)
        let error = await expect(.spawnFailed, "a command that isn't there") {
            _ = try await backend.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "left"))
        }
        let failed = try XCTUnwrap(error)
        XCTAssertTrue(failed.worktreeLeftBehind)
        let folder = parent + "/repo-left"
        XCTAssertTrue(failed.message.contains(folder), failed.message)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue, "the folder is still there")
        XCTAssertTrue(try runGit("branch", "--list", "left").contains("left"), "and its branch")
        let text = GitText.worktreeError(failed)
        XCTAssertTrue(text.hasPrefix("The worktree was created and is still there (\(folder)), but its Tab couldn't be opened: "), text)
        let state = try await backend.getState()
        XCTAssertEqual(state.workspace(created.workspace)?.tabs.count, 1, "no Tab was opened")
    }
}
