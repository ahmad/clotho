import CryptoKit
import Foundation

// Opening a file on another machine as if it were here: download it to a cache copy (keeping its
// name, so the right app opens it), let any app edit it, and upload each save.
//
// Each copy remembers the remote file as it was when downloaded or last uploaded (`base`: size,
// mtime_ns, mode) and a digest of the local bytes at that moment. A save is uploaded only if the
// local bytes differ from that digest, and only if the remote file is still the base: otherwise it's
// a conflict, and the user chooses (overwrite, save a copy beside, discard their changes). The upload
// is one `fs.write` with `expect_mtime_ns` = the base: the daemon writes a hidden part file next to
// the target and renames it over the target only when it's complete and the target is still the
// base, so a half upload never clobbers the file, a change between our check and the write is still
// a conflict, and the file keeps its mode.
//
// Copies with changes that haven't reached the machine are never deleted. Others go a while after
// their app is done with them, or at the next launch.

/// One remote file opened through a local copy.
public struct RemoteEdit: Codable, Equatable, Sendable, Identifiable {
    /// The remote file, as last seen in sync with the local copy.
    public struct Base: Codable, Equatable, Sendable {
        public var size: UInt64
        public var mtimeNs: String
        public var mode: Int

        public init(size: UInt64, mtimeNs: String, mode: Int) {
            self.size = size
            self.mtimeNs = mtimeNs
            self.mode = mode
        }

        public init(_ entry: FileEntry) { self.init(size: entry.size, mtimeNs: entry.mtimeNs, mode: entry.mode) }
    }

    public enum State: String, Codable, Sendable {
        /// Downloaded and opened; nothing saved yet.
        case open
        /// A save is going up.
        case syncing
        /// The machine has the last save.
        case synced
        /// The file changed on the machine since it was opened; `resolve` decides.
        case conflict
        /// The last upload failed (`failure` says why); the next save, or `sync`, tries again.
        case failed
    }

    public var id: String
    /// The machine's key, as the app names machines.
    public var machine: String
    /// The machine's name, for messages ("Changed on devbox since you opened it").
    public var machineName: String
    /// Where saves go. After "Save a Copy Beside", the copy's path.
    public var remotePath: String
    public var localPath: String
    public var base: Base
    /// SHA-256 of the local bytes when they last matched `base` (download or upload).
    public var syncedDigest: String
    public var state: State
    public var failure: String?
    /// The remote file when the conflict was found; nil if it was gone.
    public var conflictRemote: Base?
    public var openedAt: Date
    public var lastSync: Date?

    public var localURL: URL { URL(fileURLWithPath: localPath) }
    public var name: String { (remotePath as NSString).lastPathComponent }
}

public enum RemoteEditError: LocalizedError, Equatable {
    case notAFile(String)
    case unknown(String)
    case notConnected(String)

    public var errorDescription: String? {
        switch self {
        case .notAFile(let path): return "\(path) isn't a file."
        case .unknown(let id): return "No open copy \(id)."
        case .notConnected(let machine): return "Not connected to \(machine)."
        }
    }
}

/// The open copies and their sync. One per app; the Mac keeps it in its caches folder.
@MainActor
public final class RemoteEdits {
    public enum SyncResult: Equatable, Sendable {
        /// The local bytes are what the machine has.
        case unchanged
        case uploaded(FileEntry)
        /// The machine's file changed since the base (nil: it's gone). Nothing was written.
        case conflict(FileEntry?)
        case failed(String)
        /// The local copy is gone.
        case missing
    }

    public enum Resolution: Sendable {
        /// Upload the local copy over whatever the machine has now.
        case overwrite
        /// Upload the local copy beside the machine's file ("notes copy.txt"); later saves go there.
        case saveCopyBeside
        /// Replace the local copy with the machine's file.
        case discard
    }

    /// The folder holding the copies: `<root>/<machine>/<hash>/<name>`, and `manifest.json`.
    public let root: URL
    public private(set) var edits: [String: RemoteEdit] = [:]
    /// After any change to an edit (state, base); with nil `edit`, it was removed.
    public var onChange: ((String, RemoteEdit?) -> Void)?
    /// Saves within this long are one save (editors write a file in several steps).
    public var settle: TimeInterval = 0.3

    /// The backend for a machine whose copies were opened before a relaunch (the app's connection).
    public var backendFor: ((String) -> FileBackend?)?

    private var watchers: [String: FileChangeWatcher] = [:]
    private var syncing: Set<String> = []
    private var syncAgain: Set<String> = []
    private var backends: [String: FileBackend] = [:]

    public init(root: URL) {
        self.root = root
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder.edits.decode([RemoteEdit].self, from: data) {
            edits = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // An upload that was going up when the app quit didn't finish.
            for (id, edit) in edits where edit.state == .syncing { edits[id]?.state = .failed; edits[id]?.failure = "Clotho quit during the upload" }
        }
    }

    var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    /// The edit for a remote file, if it's open here.
    public func edit(machine: String, path: String) -> RemoteEdit? {
        edits.values.first { $0.machine == machine && $0.remotePath == path }
    }

    /// Where a remote file's copy goes: its own folder, named by machine and path, keeping its name.
    public func localURL(machine: String, path: String) -> URL {
        let digest = SHA256.hash(data: Data("\(machine)\n\(path)".utf8)).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent
        return root.appendingPathComponent(Self.safe(machine)).appendingPathComponent(String(digest.prefix(16)))
            .appendingPathComponent(name.isEmpty ? "file" : name)
    }

    static func safe(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    // MARK: Opening

    /// Downloads the file (unless an up-to-date copy is here) and starts watching the copy for saves.
    /// A copy with changes the machine doesn't have yet is never replaced: it's returned as it is.
    @discardableResult
    public func open(machine: String, machineName: String, path: String, backend: FileBackend) async throws -> RemoteEdit {
        backends[machine] = backend
        if let existing = edit(machine: machine, path: path), FileManager.default.fileExists(atPath: existing.localPath) {
            if hasUnsyncedChanges(existing.id) || existing.state == .conflict {
                watch(existing.id)
                return existing
            }
            let remote = try await backend.stat(path)
            if remote.mtimeNs == existing.base.mtimeNs, remote.size == existing.base.size {
                watch(existing.id)
                return existing
            }
        }
        let remote = try await backend.stat(path)
        guard remote.type == .file else { throw RemoteEditError.notAFile(path) }
        let local = localURL(machine: machine, path: path)
        let base = try await download(path, to: local, backend: backend)
        let id = edit(machine: machine, path: path)?.id ?? UUID().uuidString
        let edit = RemoteEdit(id: id, machine: machine, machineName: machineName, remotePath: path, localPath: local.path,
                              base: base, syncedDigest: try Self.digest(local), state: .open, openedAt: Date())
        update(edit)
        watch(id)
        return edit
    }

    /// Downloads into a temp file beside `local`, then renames it into place, so an app never opens
    /// half a file and the watcher never sees one.
    private func download(_ path: String, to local: URL, backend: FileBackend) async throws -> RemoteEdit.Base {
        let folder = local.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".download-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        let stream = try await backend.read(path, options: FileReadOptions())
        do {
            for try await piece in stream.data { try handle.write(contentsOf: piece) }
            try handle.close()
        } catch {
            try? handle.close()
            stream.cancel()
            throw error
        }
        let entry = try await backend.stat(path)
        guard Darwin.rename(temp.path, local.path) == 0 else { throw LocalFileBackend.posixError(local.path) }
        // The machine's file as downloaded: the read's own size and mtime (the stat may be newer).
        return RemoteEdit.Base(size: stream.size, mtimeNs: stream.mtimeNs, mode: entry.mode)
    }

    // MARK: Saving

    /// Whether the local copy has bytes the machine doesn't (false when the copy is gone).
    public func hasUnsyncedChanges(_ id: String) -> Bool {
        guard let edit = edits[id], let digest = try? Self.digest(edit.localURL) else { return false }
        return digest != edit.syncedDigest
    }

    /// Uploads the local copy if it changed and the machine's file is still the base. One at a time
    /// per copy: a save during an upload runs once that upload ends.
    @discardableResult
    public func sync(_ id: String, backend: FileBackend? = nil) async -> SyncResult {
        guard let edit = edits[id] else { return .failed(RemoteEditError.unknown(id).localizedDescription) }
        guard let backend = backend ?? backends[edit.machine] ?? backendFor?(edit.machine) else {
            return .failed(RemoteEditError.notConnected(edit.machineName).localizedDescription)
        }
        backends[edit.machine] = backend
        if syncing.contains(id) {
            syncAgain.insert(id)
            return .unchanged
        }
        syncing.insert(id)
        defer { syncing.remove(id) }
        var result = await syncOnce(id, backend: backend)
        while syncAgain.remove(id) != nil { result = await syncOnce(id, backend: backend) }
        return result
    }

    private func syncOnce(_ id: String, backend: FileBackend) async -> SyncResult {
        guard var edit = edits[id] else { return .missing }
        guard let digest = try? Self.digest(edit.localURL) else { return .missing }
        if digest == edit.syncedDigest {
            if edit.state == .failed { edit.state = .synced; edit.failure = nil; update(edit) }
            return .unchanged
        }
        // A conflict waits for the user's choice; saves meanwhile don't change that.
        if edit.state == .conflict { return .conflict(nil) }
        edit.state = .syncing
        update(edit)
        do {
            let remote: FileEntry?
            do { remote = try await backend.stat(edit.remotePath) } catch where error.fileErrorCode == .notFound { remote = nil }
            guard let remote, remote.mtimeNs == edit.base.mtimeNs, remote.size == edit.base.size else {
                return markConflict(id, remote: remote)
            }
            let entry = try await upload(edit, digest: digest, backend: backend, expect: edit.base.mtimeNs)
            return .uploaded(entry)
        } catch where error.fileErrorCode == .conflict || error.fileErrorCode == .changed {
            // Changed between the check and the write: the daemon refused to replace it.
            return markConflict(id, remote: try? await backend.stat(edit.remotePath))
        } catch {
            edit = edits[id] ?? edit
            edit.state = .failed
            edit.failure = error.localizedDescription
            update(edit)
            return .failed(error.localizedDescription)
        }
    }

    private func markConflict(_ id: String, remote: FileEntry?) -> SyncResult {
        guard var edit = edits[id] else { return .missing }
        edit.state = .conflict
        edit.conflictRemote = remote.map(RemoteEdit.Base.init)
        update(edit)
        return .conflict(remote)
    }

    /// One `fs.write` of the local copy to `edit.remotePath`: atomic on the machine (part file, then a
    /// rename over the target), keeping the target's mode. `expect` makes it refuse a changed target.
    private func upload(_ edit: RemoteEdit, digest: String, backend: FileBackend, expect: String?, overwrite: Bool = true) async throws -> FileEntry {
        let source = try LocalFileSource(path: edit.localPath)
        var options = FileWriteOptions(size: source.size, overwrite: overwrite)
        options.expectMtimeNs = expect
        let entry = try await backend.write(edit.remotePath, options: options, source: source) { _ in }
        var done = edits[edit.id] ?? edit
        done.base = RemoteEdit.Base(entry)
        // What went up: the digest taken before the upload. A save during it shows as a new change.
        done.syncedDigest = digest
        done.state = .synced
        done.failure = nil
        done.conflictRemote = nil
        done.lastSync = Date()
        update(done)
        return entry
    }

    /// The machine's file was renamed (or a folder above it): saves follow it there.
    public func moved(machine: String, from old: String, to new: String) {
        for (id, var edit) in edits where edit.machine == machine {
            if edit.remotePath == old {
                edit.remotePath = new
            } else if edit.remotePath.hasPrefix(old + "/") {
                edit.remotePath = new + edit.remotePath.dropFirst(old.count)
            } else { continue }
            update(edit)
            _ = id
        }
    }

    /// Settles a conflict.
    public func resolve(_ id: String, _ resolution: Resolution, backend: FileBackend? = nil) async throws {
        guard var edit = edits[id] else { throw RemoteEditError.unknown(id) }
        guard let backend = backend ?? backends[edit.machine] ?? backendFor?(edit.machine) else { throw RemoteEditError.notConnected(edit.machineName) }
        let digest = try Self.digest(edit.localURL)
        switch resolution {
        case .overwrite:
            _ = try await upload(edit, digest: digest, backend: backend, expect: nil)
        case .saveCopyBeside:
            let folder = (edit.remotePath as NSString).deletingLastPathComponent
            let taken = Set(try await backend.listAll(folder).entries.map(\.name))
            edit.remotePath = filePath(folder, Self.copyName(for: edit.name, taken: taken))
            edits[id] = edit
            _ = try await upload(edit, digest: digest, backend: backend, expect: nil, overwrite: false)
        case .discard:
            let base = try await download(edit.remotePath, to: edit.localURL, backend: backend)
            edit.base = base
            edit.syncedDigest = try Self.digest(edit.localURL)
            edit.state = .synced
            edit.failure = nil
            edit.conflictRemote = nil
            edit.lastSync = Date()
            update(edit)
            watch(id)
        }
    }

    /// "notes copy.txt", then "notes copy 2.txt"…, as Finder names duplicates.
    public static func copyName(for name: String, taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let dot = ext.isEmpty ? "" : "." + ext
        var n = 1
        while true {
            let candidate = "\(stem) copy\(n == 1 ? "" : " \(n)")\(dot)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: Watching

    /// Watches a copy's folder, so saves by atomic replace (write a temp file, rename it over) count as
    /// well as writes in place; each settled save syncs.
    public func watch(_ id: String) {
        guard watchers[id] == nil, let edit = edits[id] else { return }
        let watcher = FileChangeWatcher(file: edit.localURL, settle: settle) { [weak self] in
            Task { @MainActor [weak self] in await self?.sync(id) }
        }
        watchers[id] = watcher
    }

    public func stopWatching(_ id: String) {
        watchers.removeValue(forKey: id)?.cancel()
    }

    public func isWatching(_ id: String) -> Bool { watchers[id] != nil }

    // MARK: Cleaning up

    /// Deletes copies the machine has every change of, that no app is using (`inUse`) and that saw no
    /// activity for `idle` (0 at launch). A copy with unsynced changes, or in conflict, always stays.
    /// Returns the ids it removed.
    @discardableResult
    public func cleanUp(idle: TimeInterval, now: Date = Date(), inUse: (URL) -> Bool = { _ in false }) -> [String] {
        var removed: [String] = []
        for (id, edit) in edits {
            guard FileManager.default.fileExists(atPath: edit.localPath) else {
                drop(id)
                removed.append(id)
                continue
            }
            guard edit.state != .conflict, edit.state != .syncing, !syncing.contains(id), !hasUnsyncedChanges(id) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: edit.localPath)[.modificationDate] as? Date) ?? nil
            let last = [edit.openedAt, edit.lastSync, modified].compactMap { $0 }.max() ?? edit.openedAt
            guard now.timeIntervalSince(last) >= idle, !inUse(edit.localURL) else { continue }
            try? FileManager.default.removeItem(at: edit.localURL.deletingLastPathComponent())
            drop(id)
            removed.append(id)
        }
        return removed
    }

    private func drop(_ id: String) {
        stopWatching(id)
        edits[id] = nil
        save()
        onChange?(id, nil)
    }

    // MARK: State

    private func update(_ edit: RemoteEdit) {
        edits[edit.id] = edit
        save()
        onChange?(edit.id, edit)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.edits.encode(Array(edits.values)) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// SHA-256 of a file's bytes, read a chunk at a time.
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hasher.update(data: piece) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static let edits: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

private extension JSONDecoder {
    static let edits: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Calls `onChange` once a file has settled after being written, renamed over (an atomic save),
/// deleted or recreated. It watches the file's folder (a rename into it or a new file changes it)
/// and the file itself (a write in place doesn't touch the folder), re-attaching to the file whenever
/// it's replaced.
public final class FileChangeWatcher: @unchecked Sendable {
    private let file: URL
    private let settle: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.clotho.file-watch")
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var cancelled = false

    public init(file: URL, settle: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.settle = settle
        self.onChange = onChange
        queue.sync {
            folderSource = source(file.deletingLastPathComponent().path, [.write, .rename, .delete, .link])
            attachFile()
        }
    }

    deinit { cancel() }

    public func cancel() {
        queue.sync {
            cancelled = true
            pending?.cancel()
            folderSource?.cancel()
            fileSource?.cancel()
            folderSource = nil
            fileSource = nil
        }
    }

    private func source(_ path: String, _ events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    /// (Re)watches the file at its path: after an atomic save the path is a new file.
    private func attachFile() {
        fileSource?.cancel()
        fileSource = source(file.path, [.write, .extend, .delete, .rename, .attrib])
    }

    private func changed() {
        guard !cancelled else { return }
        attachFile()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !cancelled else { return }
            attachFile()
            onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
