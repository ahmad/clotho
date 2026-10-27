import Foundation

/// Copies files and folders from one FileBackend to another (protocol.md, "Files" › Directories):
/// walks each tree, creates its folders, streams the files a few at a time, keeping their modes and
/// times, and restores the folders' times last. Either side can be this device or any machine, so a
/// copy between two remote machines relays through the app.
public final class FileTransfer: @unchecked Sendable {
    /// What to do with a file that already exists at the destination.
    public enum Conflict: Sendable {
        case replace, skip
    }

    public struct Progress: Sendable {
        public var totalBytes: UInt64 = 0
        public var doneBytes: UInt64 = 0
        public var totalFiles = 0
        public var doneFiles = 0
        public var skippedFiles = 0
        /// The file most recently started.
        public var current: String?

        public var fraction: Double { totalBytes == 0 ? (totalFiles == 0 ? 0 : Double(doneFiles) / Double(totalFiles)) : Double(doneBytes) / Double(totalBytes) }
    }

    public let source: FileBackend
    public let destination: FileBackend
    /// Concurrent file streams per copy; the protocol asks for at most 4.
    public var maxStreams = 4

    private let lock = NSLock()
    private var progress = Progress()
    private var written: [String: UInt64] = [:]
    private var onProgress: (@Sendable (Progress) -> Void)?

    public init(from source: FileBackend, to destination: FileBackend) {
        self.source = source
        self.destination = destination
    }

    /// Which of `names` already exist in `directory` on `backend`.
    public static func existing(_ names: [String], in directory: String, on backend: FileBackend) async -> [String] {
        var found: [String] = []
        for name in names where (try? await backend.stat(filePath(directory, name))) != nil {
            found.append(name)
        }
        return found
    }

    /// Copies each of `paths` (files or folders on the source) into `directory` on the destination.
    /// Folders merge into existing ones; existing files are replaced or skipped per `conflict`.
    /// Cancel the calling task to stop; finished files stay, and an unfinished upload can resume.
    public func copy(_ paths: [String], into directory: String, conflict: Conflict,
                     progress onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        locked {
            progress = Progress()
            written = [:]
            self.onProgress = onProgress
        }
        var directories: [(source: FileEntry, path: String)] = []
        var files: [(source: FileEntry, path: String)] = []
        func walk(_ entry: FileEntry, to path: String, top: Bool) async throws {
            try Task.checkCancellation()
            switch entry.type {
            case .dir:
                // Links to folders inside a tree are skipped: following them can loop.
                guard top || !entry.link else { return }
                directories.append((entry, path))
                for child in try await source.listAll(entry.path).entries {
                    try await walk(child, to: filePath(path, child.name), top: false)
                }
            case .file:
                files.append((entry, path))
            case .other, .unknown:
                break
            }
        }
        for path in paths {
            let entry = try await source.stat(path)
            try await walk(entry, to: filePath(directory, entry.name), top: true)
        }
        report {
            $0.totalFiles = files.count
            $0.totalBytes = files.reduce(0) { $0 + $1.source.size }
        }

        for (_, path) in directories {
            do {
                _ = try await destination.mkdir(path, parents: true)
            } catch where error.fileErrorCode == .exists {
                guard try await destination.stat(path).isDirectory else { throw error }
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for file in files {
                if running >= maxStreams {
                    try await group.next()
                    running -= 1
                }
                group.addTask { try await self.copyFile(file.source, to: file.path, conflict: conflict) }
                running += 1
            }
            try await group.waitForAll()
        }

        // Writing into a folder changes its time, so folders get theirs back once they're filled.
        for (entry, path) in directories.reversed() {
            _ = try? await destination.setattr(path, mtimeNs: entry.mtimeNs, mode: nil)
        }
    }

    private func copyFile(_ entry: FileEntry, to path: String, conflict: Conflict) async throws {
        report { $0.current = entry.name }
        let data = StreamedSource(backend: source, entry: entry)
        defer { data.close() }
        let options = FileWriteOptions(size: entry.size, overwrite: conflict == .replace, mode: entry.mode, mtimeNs: entry.mtimeNs,
                                       uploadID: Self.uploadID(path, data.fingerprint), source: data.fingerprint)
        do {
            _ = try await destination.write(path, options: options, source: data) { [weak self] bytes in
                self?.setWritten(path, bytes)
            }
            setWritten(path, entry.size)
            report { $0.doneFiles += 1 }
        } catch where conflict == .skip && error.fileErrorCode == .exists {
            setWritten(path, entry.size)
            report {
                $0.doneFiles += 1
                $0.skippedFiles += 1
            }
        }
    }

    private func setWritten(_ path: String, _ bytes: UInt64) {
        report { progress in
            let before = written[path] ?? 0
            guard bytes > before else { return }
            written[path] = bytes
            progress.doneBytes += bytes - before
        }
    }

    /// Changes the progress under the lock, then reports it.
    private func report(_ change: (inout Progress) -> Void) {
        let (snapshot, callback) = locked { () -> (Progress, (@Sendable (Progress) -> Void)?) in
            change(&progress)
            return (progress, onProgress)
        }
        callback?(snapshot)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The same destination and source data always get the same id, so a retry resumes the upload.
    static func uploadID(_ path: String, _ fingerprint: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (path + "\u{0}" + fingerprint).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// A file on one backend as the data for a write on another. A resumed write opens it at an offset,
/// and the read checks the file is still the one that was listed.
final class StreamedSource: FileDataSource, @unchecked Sendable {
    let backend: FileBackend
    let entry: FileEntry
    private let lock = NSLock()
    private var stream: FileReadStream?

    init(backend: FileBackend, entry: FileEntry) {
        self.backend = backend
        self.entry = entry
    }

    var size: UInt64 { entry.size }
    var fingerprint: String { "\(entry.size):\(entry.mtimeNs)" }

    func open(at offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let stream = try await backend.read(entry.path, options: FileReadOptions(offset: offset, expectSize: entry.size, expectMtimeNs: entry.mtimeNs))
        lock.withLock { self.stream = stream }
        return stream.data
    }

    /// Stops the read if the write ended early; harmless after it finished.
    func close() {
        lock.withLock { stream }?.cancel()
    }
}
