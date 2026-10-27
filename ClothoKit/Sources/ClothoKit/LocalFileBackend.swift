import Darwin
import Foundation

/// FileBackend over this device's own files, with the same behavior as clothod's `fs.*`: listings sorted
/// by name and paged with a cursor, nanosecond mtimes, and atomic, resumable writes through a part file
/// next to the target. "This Mac" in the file browser uses it, and so does FakeBackend.
public final class LocalFileBackend: FileBackend, @unchecked Sendable {
    public init() {}

    public var supportsFiles: Bool { true }
    public var homeDirectory: String? { NSHomeDirectory() }

    // MARK: Paths and entries

    /// `~` and `~/…` expand to the home directory; anything else must be absolute.
    func resolve(_ path: String) throws -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        guard path.hasPrefix("/") else { throw Self.error(.badRequest, "not an absolute path: \(path)") }
        return path
    }

    func entry(at path: String, text: Bool = false) throws -> FileEntry {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw Self.posixError(path) }
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        var target: String?
        if isLink {
            target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            var followed = Darwin.stat()
            // A dangling link is "other", not an error.
            if posixStat(path, &followed) == 0 { info = followed } else { info.st_mode = S_IFLNK }
        }
        let type: FileType
        switch info.st_mode & S_IFMT {
        case S_IFREG: type = .file
        case S_IFDIR: type = .dir
        default: type = .other
        }
        let seconds = Int64(info.st_mtimespec.tv_sec), nanos = Int64(info.st_mtimespec.tv_nsec)
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        var entry = FileEntry(name: name, path: path, type: type, link: isLink, target: target, size: UInt64(info.st_size),
                              mtime: Double(seconds) + Double(nanos) / 1e9, mtimeNs: String(seconds * 1_000_000_000 + nanos),
                              mode: Int(info.st_mode & 0o7777), hidden: name.hasPrefix("."))
        if text, type == .file { entry.text = Self.looksLikeText(path) }
        return entry
    }

    static func looksLikeText(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0)
    }

    // MARK: Metadata

    public func stat(_ path: String) async throws -> FileEntry {
        try entry(at: try resolve(path), text: true)
    }

    public func list(_ path: String, hidden: Bool, limit: Int?, cursor: String?) async throws -> FileListing {
        let dir = try resolve(path)
        let dirEntry = try entry(at: dir)
        guard dirEntry.isDirectory else { throw Self.error(.notADirectory, "\(path) isn't a directory") }
        var names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir)
        } catch {
            throw Self.translate(error, path)
        }
        if !hidden { names.removeAll { $0.hasPrefix(".") } }
        // Sorted by name bytes, as clothod does; the cursor is the last name of the previous page.
        names.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        if let cursor { names.removeAll { !Array(cursor.utf8).lexicographicallyPrecedes(Array($0.utf8)) } }
        let pageSize = min(max(limit ?? 1000, 1), 10000)
        let page = Array(names.prefix(pageSize))
        let entries = page.compactMap { try? entry(at: filePath(dir, $0)) }
        return FileListing(dir: dirEntry, entries: entries, next: names.count > pageSize ? page.last : nil)
    }

    public func mkdir(_ path: String, parents: Bool) async throws -> FileEntry {
        let dir = try resolve(path)
        do {
            if parents {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } else if Darwin.mkdir(dir, 0o755) != 0 {
                throw Self.posixError(dir)
            }
        } catch let error as BackendError {
            throw error
        } catch {
            throw Self.translate(error, path)
        }
        return try entry(at: dir)
    }

    public func setattr(_ path: String, mtimeNs: String?, mode: Int?) async throws -> FileEntry {
        let resolved = try resolve(path)
        if let mode, chmod(resolved, mode_t(mode)) != 0 { throw Self.posixError(resolved) }
        if let mtimeNs { try Self.setMtime(resolved, mtimeNs) }
        return try entry(at: resolved)
    }

    public func rename(_ from: String, to: String, overwrite: Bool) async throws -> FileEntry {
        let source = try resolve(from), destination = try resolve(to)
        let result = overwrite ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
        guard result == 0 else { throw Self.posixError(errno == EXDEV ? destination : source) }
        return try entry(at: destination)
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        let resolved = try resolve(path)
        let found = try entry(at: resolved)
        if found.isDirectory && !found.link {
            if recursive {
                do { try FileManager.default.removeItem(atPath: resolved) } catch { throw Self.translate(error, path) }
            } else if rmdir(resolved) != 0 {
                throw Self.posixError(resolved)
            }
        } else if unlink(resolved) != 0 {
            throw Self.posixError(resolved)
        }
    }

    public func statfs(_ path: String) async throws -> FileSpace {
        let resolved = try resolve(path)
        var info = Darwin.statfs()
        guard posixStatfs(resolved, &info) == 0 else { throw Self.posixError(resolved) }
        let block = UInt64(info.f_bsize)
        return FileSpace(total: UInt64(info.f_blocks) * block, free: UInt64(info.f_bfree) * block, available: UInt64(info.f_bavail) * block)
    }

    // MARK: Transfers

    public func read(_ path: String, options: FileReadOptions) async throws -> FileReadStream {
        let resolved = try resolve(path)
        let found = try entry(at: resolved)
        guard found.type == .file else { throw Self.error(found.isDirectory ? .isADirectory : .badRequest, "\(path) isn't a file") }
        if let size = options.expectSize, size != found.size { throw Self.error(.changed, "\(path) changed size") }
        if let mtime = options.expectMtimeNs, mtime != found.mtimeNs { throw Self.error(.changed, "\(path) changed") }
        guard let handle = FileHandle(forReadingAtPath: resolved) else { throw Self.posixError(resolved) }
        let end = options.length.map { min(found.size, options.offset + $0) } ?? found.size
        let chunk = max(4096, options.chunk)
        let cancelled = Flag()
        let data = AsyncThrowingStream<Data, Error> { continuation in
            let thread = Thread {
                defer { try? handle.close() }
                do {
                    try handle.seek(toOffset: options.offset)
                    var position = options.offset
                    while position < end, !cancelled.isSet {
                        let piece = try handle.read(upToCount: Int(min(UInt64(chunk), end - position))) ?? Data()
                        if piece.isEmpty { break }
                        position += UInt64(piece.count)
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translate(error, path))
                }
            }
            thread.start()
            continuation.onTermination = { _ in cancelled.set() }
        }
        return FileReadStream(size: found.size, mtimeNs: found.mtimeNs, offset: options.offset, data: data, cancel: { cancelled.set() })
    }

    public func write(_ path: String, options: FileWriteOptions, source: FileDataSource,
                      progress: @escaping @Sendable (UInt64) -> Void) async throws -> FileEntry {
        var target = try resolve(path)
        // Writing through a symlink writes the file it points to, so links survive.
        if let existing = try? entry(at: target), existing.link {
            guard existing.type != .other, let link = existing.target else { throw Self.error(.notFound, "\(path) is a dangling link") }
            target = link.hasPrefix("/") ? link : filePath((target as NSString).deletingLastPathComponent, link)
        }
        let existing = try? entry(at: target)
        if let existing, existing.isDirectory { throw Self.error(.isADirectory, "\(path) is a directory") }
        if existing != nil, !options.overwrite { throw Self.error(.exists, "\(path) already exists") }

        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let id = options.uploadID ?? UUID().uuidString
        let part = filePath(directory, ".\(name).clotho-part-\(id)")
        let sourceNote = part + ".source"
        // Resume only the same data into the same part file.
        var offset: UInt64 = 0
        if options.uploadID != nil, let size = try? entry(at: part).size,
           (try? String(contentsOfFile: sourceNote, encoding: .utf8)) == options.source {
            offset = size
        } else {
            unlink(part)
            if options.uploadID != nil, let note = options.source { try? note.write(toFile: sourceNote, atomically: true, encoding: .utf8) }
            guard FileManager.default.createFile(atPath: part, contents: nil) else { throw Self.posixError(part) }
        }
        guard let handle = FileHandle(forWritingAtPath: part) else { throw Self.posixError(part) }
        var written = offset
        do {
            try handle.seek(toOffset: offset)
            progress(written)
            for try await piece in try await source.open(at: offset) {
                try Task.checkCancellation()
                try handle.write(contentsOf: piece)
                written += UInt64(piece.count)
                progress(written)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            // An upload with an id keeps its part file for resuming; others leave nothing behind.
            if options.uploadID == nil { unlink(part) }
            throw (error as? BackendError) ?? Self.translate(error, path)
        }
        if let size = options.size, size != written {
            throw Self.error(.ioError, "\(path): expected \(size) bytes, got \(written)")
        }
        if let expect = options.expectMtimeNs, let now = try? entry(at: target), now.mtimeNs != expect {
            throw Self.error(.conflict, "\(path) changed while it was being written")
        }
        // A replaced file keeps its mode unless told otherwise; a new one gets the umask's default.
        if let mode = options.mode ?? existing?.mode { chmod(part, mode_t(mode)) }
        if let mtime = options.mtimeNs { try Self.setMtime(part, mtime) }
        let renamed = options.overwrite ? Darwin.rename(part, target) : renamex_np(part, target, UInt32(RENAME_EXCL))
        guard renamed == 0 else { throw Self.posixError(target) }
        unlink(sourceNote)
        return try entry(at: target)
    }

    // MARK: Helpers

    static func setMtime(_ path: String, _ mtimeNs: String) throws {
        guard let value = Int64(mtimeNs) else { throw error(.badRequest, "bad mtime_ns \(mtimeNs)") }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(value / 1_000_000_000), tv_nsec: Int(value % 1_000_000_000))]
        guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { throw posixError(path) }
    }

    static func error(_ code: FileErrorCode, _ message: String) -> BackendError {
        BackendError(code: code.rawValue, message: message)
    }

    /// The fs error code for the current errno.
    static func posixError(_ path: String) -> BackendError {
        let number = errno
        let message = "\(path): \(String(cString: strerror(number)))"
        switch number {
        case ENOENT: return error(.notFound, message)
        case EEXIST: return error(.exists, message)
        case EACCES, EPERM: return error(.permissionDenied, message)
        case ENOTDIR: return error(.notADirectory, message)
        case EISDIR: return error(.isADirectory, message)
        case ENOTEMPTY: return error(.notEmpty, message)
        case EXDEV: return error(.crossDevice, message)
        case ENOSPC, EDQUOT: return error(.noSpace, message)
        case EROFS: return error(.readOnly, message)
        default: return error(.ioError, message)
        }
    }

    static func translate(_ error: Error, _ path: String) -> BackendError {
        if let backend = error as? BackendError { return backend }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { errno = Int32(ns.code); return posixError(path) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            errno = Int32(underlying.code)
            return posixError(path)
        }
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return Self.error(.notFound, "\(path): \(ns.localizedDescription)")
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return Self.error(.permissionDenied, "\(path): \(ns.localizedDescription)")
        case NSFileWriteOutOfSpaceError: return Self.error(.noSpace, "\(path): \(ns.localizedDescription)")
        default: return Self.error(.ioError, "\(path): \(ns.localizedDescription)")
        }
    }
}

/// A local file as a write's source.
public struct LocalFileSource: FileDataSource {
    public let path: String
    public let size: UInt64
    public let fingerprint: String
    public var chunk = 256 << 10

    public init(path: String) throws {
        let resolved = path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst(1) : path
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved)
        self.path = resolved
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        fingerprint = "\(size):\(modified)"
    }

    public func open(at offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw LocalFileBackend.posixError(path) }
        try handle.seek(toOffset: offset)
        let chunk = chunk
        return AsyncThrowingStream { continuation in
            let thread = Thread {
                defer { try? handle.close() }
                do {
                    while true {
                        let piece = try handle.read(upToCount: chunk) ?? Data()
                        if piece.isEmpty { break }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.start()
        }
    }
}

// The POSIX calls, under names the backend's own `stat` and `statfs` methods don't hide.
private func posixStat(_ path: String, _ info: UnsafeMutablePointer<Darwin.stat>) -> Int32 { stat(path, info) }
private func posixStatfs(_ path: String, _ info: UnsafeMutablePointer<Darwin.statfs>) -> Int32 { statfs(path, info) }

/// A thread-safe one-way switch.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
