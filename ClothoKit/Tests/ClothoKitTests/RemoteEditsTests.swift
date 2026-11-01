import XCTest
@testable import ClothoKit

/// Opening a machine's file through a local copy and syncing saves back (RemoteEdits), against a real
/// clothod: conflicts, atomic-replace saves, the upload (atomic on the machine, mode kept, no part file
/// left), and clean-up that never loses an unsynced edit. Everything lives in the test's runtime dir.
extension ClothodBackendTests {
    private struct Setup {
        let backend: ClothodBackend
        let remote: String
        let edits: RemoteEdits
    }

    @MainActor
    private func setUpEdits(settle: TimeInterval = 0.1) async throws -> Setup {
        let backend = makeBackend()
        try await backend.start()
        try XCTSkipUnless(backend.lastHello?.features.contains(.fs) == true, "this clothod predates fs")
        let remote = runtimeDir + "/remote"
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        let edits = RemoteEdits(root: URL(fileURLWithPath: runtimeDir + "/cache/open"))
        edits.settle = settle
        return Setup(backend: backend, remote: remote, edits: edits)
    }

    private func put(_ text: String, at path: String, mode: Int? = nil) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        if let mode { chmod(path, mode_t(mode)) }
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// Waits for the file's mtime to move on, so a second write can't land in the same tick.
    private func tick() async throws { try await Task.sleep(nanoseconds: 20_000_000) }

    @MainActor
    func testOpenEditAndSyncKeepsTheModeAndLeavesNoPartFile() async throws {
        let s = try await setUpEdits()
        defer { s.backend.stop() }
        let path = s.remote + "/run.sh"
        try put("echo one\n", at: path, mode: 0o755)

        let edit = try await s.edits.open(machine: "bb", machineName: "devbox", path: path, backend: s.backend)
        XCTAssertEqual(edit.state, .open)
        XCTAssertEqual(edit.localURL.lastPathComponent, "run.sh", "the real name, so the right app opens it")
        XCTAssertTrue(edit.localPath.hasPrefix(runtimeDir + "/cache/open/bb/"), edit.localPath)
        XCTAssertEqual(text(edit.localPath), "echo one\n")
        XCTAssertFalse(s.edits.hasUnsyncedChanges(edit.id))
        let unchanged = await s.edits.sync(edit.id)
        XCTAssertEqual(unchanged, .unchanged, "nothing to send")

        try put("echo two\n", at: edit.localPath)
        XCTAssertTrue(s.edits.hasUnsyncedChanges(edit.id))
        guard case .uploaded(let entry) = await s.edits.sync(edit.id) else { return XCTFail("not uploaded") }
        XCTAssertEqual(text(path), "echo two\n")
        XCTAssertEqual(entry.mode & 0o777, 0o755, "the file keeps its mode")
        XCTAssertEqual(s.edits.edits[edit.id]?.state, .synced)
        XCTAssertEqual(s.edits.edits[edit.id]?.base.mtimeNs, entry.mtimeNs, "the new base is what went up")
        XCTAssertFalse(s.edits.hasUnsyncedChanges(edit.id))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: s.remote).filter { $0.contains("clotho-part") }
        XCTAssertEqual(leftovers, [], "the part file was renamed over the target")

        // Opening it again reuses the copy; opening after a change on the machine downloads it again.
        let again = try await s.edits.open(machine: "bb", machineName: "devbox", path: path, backend: s.backend)
        XCTAssertEqual(again.id, edit.id)
        try await tick()
        try put("echo three\n", at: path)
        let fresh = try await s.edits.open(machine: "bb", machineName: "devbox", path: path, backend: s.backend)
        XCTAssertEqual(text(fresh.localPath), "echo three\n")
        XCTAssertEqual(fresh.id, edit.id, "the same copy")
    }

    /// Editors that save by writing a temp file and renaming it over the original (TextEdit, VS Code,
    /// vim's default) replace the file: the watcher follows the path, not the old file.
    @MainActor
    func testAnAtomicReplaceSaveIsUploaded() async throws {
        let s = try await setUpEdits()
        defer { s.backend.stop() }
        let path = s.remote + "/notes.md"
        try put("# One\n", at: path)
        let edit = try await s.edits.open(machine: "bb", machineName: "devbox", path: path, backend: s.backend)
        XCTAssertTrue(s.edits.isWatching(edit.id))

        func save(_ content: String) throws {
            let temp = edit.localURL.deletingLastPathComponent().appendingPathComponent(".notes.md.sb-\(UUID().uuidString.prefix(6))")
            try content.write(to: temp, atomically: false, encoding: .utf8)
            XCTAssertEqual(rename(temp.path, edit.localPath), 0)
        }
        try save("# Two\n")
        try await waitFor("the first atomic save on the machine") { self.text(path) == "# Two\n" }
        // A second replace: the watcher re-attached to the new file.
        try await tick()
        try save("# Three\n")
        try await waitFor("the second atomic save on the machine") { self.text(path) == "# Three\n" }
        // And a write in place, which doesn't touch the folder.
        try await tick()
        let handle = try FileHandle(forWritingTo: edit.localURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more\n".utf8))
        try handle.close()
        try await waitFor("the write in place on the machine") { self.text(path) == "# Three\nmore\n" }
        try await waitFor("synced") { s.edits.edits[edit.id]?.state == .synced }
        s.edits.stopWatching(edit.id)
    }

    @MainActor
    func testAChangeOnTheMachineIsAConflictAndEachResolution() async throws {
        let s = try await setUpEdits()
        defer { s.backend.stop() }
        let path = s.remote + "/config.toml"
        try put("a = 1\n", at: path)

        // Overwrite.
        var edit = try await s.edits.open(machine: "bb", machineName: "devbox", path: path, backend: s.backend)
        s.edits.stopWatching(edit.id)
        try await tick()
        try put("a = 2 # theirs\n", at: path)
        try put("a = 3 # mine\n", at: edit.localPath)
        guard case .conflict(let remote) = await s.edits.sync(edit.id) else { return XCTFail("no conflict") }
        XCTAssertEqual(remote?.size, 15, "the machine's file as it is now")
        XCTAssertEqual(text(path), "a = 2 # theirs\n", "nothing was written")
        XCTAssertEqual(s.edits.edits[edit.id]?.state, .conflict)
        XCTAssertNotNil(s.edits.edits[edit.id]?.conflictRemote)
        let waiting = await s.edits.sync(edit.id)
        XCTAssertEqual(waiting, .conflict(nil), "saves wait for the user's choice")
        try await s.edits.resolve(edit.id, .overwrite)
        XCTAssertEqual(text(path), "a = 3 # mine\n")
        XCTAssertEqual(s.edits.edits[edit.id]?.state, .synced)

        // Save a Copy Beside: the copy gets the edits, later saves go to it, the original stays theirs.
        try await tick()
        try put("a = 4 # theirs\n", at: path)
        try put("a = 5 # mine\n", at: edit.localPath)
        _ = await s.edits.sync(edit.id)
        try put("", at: s.remote + "/config copy.toml")
        try await s.edits.resolve(edit.id, .saveCopyBeside)
        XCTAssertEqual(text(path), "a = 4 # theirs\n")
        XCTAssertEqual(text(s.remote + "/config copy 2.toml"), "a = 5 # mine\n", "beside it, without replacing the first copy")
        edit = try XCTUnwrap(s.edits.edits[edit.id])
        XCTAssertEqual(edit.remotePath, s.remote + "/config copy 2.toml")
        try put("a = 6 # mine\n", at: edit.localPath)
        _ = await s.edits.sync(edit.id)
        XCTAssertEqual(text(s.remote + "/config copy 2.toml"), "a = 6 # mine\n")

        // Discard: the local copy becomes the machine's file.
        try await tick()
        try put("a = 7 # theirs\n", at: edit.remotePath)
        try put("a = 8 # mine\n", at: edit.localPath)
        _ = await s.edits.sync(edit.id)
        try await s.edits.resolve(edit.id, .discard)
        XCTAssertEqual(text(edit.localPath), "a = 7 # theirs\n")
        XCTAssertEqual(text(edit.remotePath), "a = 7 # theirs\n")
        XCTAssertFalse(s.edits.hasUnsyncedChanges(edit.id))
        s.edits.stopWatching(edit.id)

        // Deleted on the machine: a conflict too, and Overwrite puts it back.
        try FileManager.default.removeItem(atPath: edit.remotePath)
        try put("a = 9\n", at: edit.localPath)
        guard case .conflict(nil) = await s.edits.sync(edit.id) else { return XCTFail("a deleted file is a conflict") }
        try await s.edits.resolve(edit.id, .overwrite)
        XCTAssertEqual(text(edit.remotePath), "a = 9\n")

        XCTAssertEqual(RemoteEdits.copyName(for: "Makefile", taken: ["Makefile copy"]), "Makefile copy 2")
    }

    /// A change that lands between the check and the write is still caught: the write carries the base
    /// mtime, and the daemon refuses to rename over a changed file.
    @MainActor
    func testAChangeBetweenTheCheckAndTheWriteIsStillAConflict() async throws {
        let s = try await setUpEdits()
        defer { s.backend.stop() }
        let path = s.remote + "/race.txt"
        try put("one\n", at: path)
        let edit = try await s.edits.open(machine: "bb", machineName: "devbox", path: path, backend: s.backend)
        s.edits.stopWatching(edit.id)
        let stale = try await s.backend.stat(path)
        try await tick()
        try put("two\n", at: path)
        try put("mine\n", at: edit.localPath)
        // Its stat still answers with the old file, as if the change came right after it.
        let late = StaleStat(s.backend, path: path, entry: stale)
        guard case .conflict = await s.edits.sync(edit.id, backend: late) else { return XCTFail("the write went through") }
        XCTAssertEqual(text(path), "two\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: s.remote).filter { $0.contains("clotho-part") }, [])
    }

    @MainActor
    func testCleanUpNeverDropsAnUnsyncedEdit() async throws {
        let s = try await setUpEdits()
        defer { s.backend.stop() }
        var ids: [String: String] = [:]
        for name in ["synced.txt", "edited.txt", "conflict.txt", "failed.txt", "busy.txt"] {
            try put("x\n", at: s.remote + "/" + name)
            let edit = try await s.edits.open(machine: "bb", machineName: "devbox", path: s.remote + "/" + name, backend: s.backend)
            s.edits.stopWatching(edit.id)
            ids[name] = edit.id
        }
        let copy = { (name: String) in s.edits.edits[ids[name]!]!.localPath }
        // Edited, not uploaded.
        try put("unsynced\n", at: copy("edited.txt"))
        // In conflict.
        try await tick()
        try put("theirs\n", at: s.remote + "/conflict.txt")
        try put("mine\n", at: copy("conflict.txt"))
        _ = await s.edits.sync(ids["conflict.txt"]!)
        // A failed upload: the machine's folder is read-only.
        try put("mine\n", at: copy("failed.txt"))
        chmod(s.remote, 0o555)
        defer { chmod(s.remote, 0o755) }
        _ = await s.edits.sync(ids["failed.txt"]!)
        XCTAssertEqual(s.edits.edits[ids["failed.txt"]!]?.state, .failed)

        // Recent activity keeps everything.
        XCTAssertEqual(s.edits.cleanUp(idle: 3600), [])
        // In use by an app keeps it.
        let inUse = copy("busy.txt")
        let removed = s.edits.cleanUp(idle: 0) { $0.path == inUse }
        XCTAssertEqual(removed, [ids["synced.txt"]!], "only the synced copy no app has open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.edits.localURL(machine: "bb", path: s.remote + "/synced.txt").deletingLastPathComponent().path),
                       "its folder is gone")
        for name in ["edited.txt", "conflict.txt", "failed.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy(name)), "\(name) has unsynced changes")
        }
        XCTAssertEqual(text(copy("edited.txt")), "unsynced\n")

        // The manifest survives a restart; an upload cut off by the quit reads as failed.
        let reloaded = RemoteEdits(root: s.edits.root)
        XCTAssertEqual(Set(reloaded.edits.keys), Set(["edited.txt", "conflict.txt", "failed.txt", "busy.txt"].map { ids[$0]! }))
        XCTAssertEqual(reloaded.edits[ids["conflict.txt"]!]?.state, .conflict)
        XCTAssertTrue(reloaded.hasUnsyncedChanges(ids["edited.txt"]!))
        // At the next launch, everything synced and unused goes; the unsynced ones still stay.
        XCTAssertEqual(reloaded.cleanUp(idle: 0), [ids["busy.txt"]!])
        XCTAssertEqual(Set(reloaded.edits.keys), Set(["edited.txt", "conflict.txt", "failed.txt"].map { ids[$0]! }))

        // Once the failed one uploads, it can go too.
        chmod(s.remote, 0o755)
        guard case .uploaded = await reloaded.sync(ids["failed.txt"]!, backend: s.backend) else { return XCTFail("retry didn't upload") }
        XCTAssertEqual(reloaded.cleanUp(idle: 0), [ids["failed.txt"]!])
    }
}

/// A backend whose `stat` of one path answers with an old entry once, then delegates.
private final class StaleStat: FileBackend, @unchecked Sendable {
    let inner: FileBackend
    let path: String
    var entry: FileEntry?

    init(_ inner: FileBackend, path: String, entry: FileEntry) {
        self.inner = inner
        self.path = path
        self.entry = entry
    }

    var supportsFiles: Bool { inner.supportsFiles }
    var homeDirectory: String? { inner.homeDirectory }
    func stat(_ path: String) async throws -> FileEntry {
        if path == self.path, let entry {
            self.entry = nil
            return entry
        }
        return try await inner.stat(path)
    }
    func list(_ path: String, hidden: Bool, limit: Int?, cursor: String?) async throws -> FileListing {
        try await inner.list(path, hidden: hidden, limit: limit, cursor: cursor)
    }
    func mkdir(_ path: String, parents: Bool) async throws -> FileEntry { try await inner.mkdir(path, parents: parents) }
    func setattr(_ path: String, mtimeNs: String?, mode: Int?) async throws -> FileEntry { try await inner.setattr(path, mtimeNs: mtimeNs, mode: mode) }
    func rename(_ from: String, to: String, overwrite: Bool) async throws -> FileEntry { try await inner.rename(from, to: to, overwrite: overwrite) }
    func remove(_ path: String, recursive: Bool) async throws { try await inner.remove(path, recursive: recursive) }
    func statfs(_ path: String) async throws -> FileSpace { try await inner.statfs(path) }
    func read(_ path: String, options: FileReadOptions) async throws -> FileReadStream { try await inner.read(path, options: options) }
    func write(_ path: String, options: FileWriteOptions, source: FileDataSource, progress: @escaping @Sendable (UInt64) -> Void) async throws -> FileEntry {
        try await inner.write(path, options: options, source: source, progress: progress)
    }
}
