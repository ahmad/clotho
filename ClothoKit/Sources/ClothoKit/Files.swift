import Foundation

// File access on a machine (protocol.md, "Files"): listing, metadata and streamed, resumable transfers.
// `FileBackend` is the interface; ClothodBackend implements it over a daemon's `fs.*` methods,
// LocalFileBackend over this device's own files, and FileTransfer copies between any two of them.

public enum FileType: String, Codable, Sendable {
    case file, dir, other
    /// A type this client doesn't know yet.
    case unknown

    public init(from decoder: Decoder) throws {
        self = FileType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One file or directory. For a symlink, `type`, `size` and `mode` describe what it points to.
public struct FileEntry: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var type: FileType
    public var link: Bool
    /// The link text, for symlinks.
    public var target: String?
    public var size: UInt64
    /// Unix seconds, for display.
    public var mtime: Double
    /// Unix nanoseconds as a decimal string: the exact value to compare and send back.
    public var mtimeNs: String
    /// Permission bits (0o644 = 420).
    public var mode: Int
    public var hidden: Bool
    /// The exact path bytes (base64) when the path isn't valid UTF-8; send it back as `path_raw`.
    public var pathRaw: String?
    /// `fs.stat` only: the start of the file looks like text.
    public var text: Bool?

    enum CodingKeys: String, CodingKey {
        case name, path, type, link, target, size, mtime, mtimeNs = "mtime_ns", mode, hidden, pathRaw = "path_raw", text
    }

    public init(name: String, path: String, type: FileType, link: Bool = false, target: String? = nil, size: UInt64,
                mtime: Double, mtimeNs: String, mode: Int, hidden: Bool, pathRaw: String? = nil, text: Bool? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.link = link
        self.target = target
        self.size = size
        self.mtime = mtime
        self.mtimeNs = mtimeNs
        self.mode = mode
        self.hidden = hidden
        self.pathRaw = pathRaw
        self.text = text
    }

    public var isDirectory: Bool { type == .dir }
    public var modified: Date { Date(timeIntervalSince1970: mtime) }
}

/// One page of a directory listing. `next` continues it.
public struct FileListing: Codable, Equatable, Sendable {
    public var dir: FileEntry
    public var entries: [FileEntry]
    public var next: String?

    public init(dir: FileEntry, entries: [FileEntry], next: String?) {
        self.dir = dir
        self.entries = entries
        self.next = next
    }
}

public struct FileSpace: Codable, Equatable, Sendable {
    public var total: UInt64
    public var free: UInt64
    public var available: UInt64

    public init(total: UInt64, free: UInt64, available: UInt64) {
        self.total = total
        self.free = free
        self.available = available
    }
}

public struct FileReadOptions: Sendable {
    public var offset: UInt64 = 0
    /// Nil reads to the end.
    public var length: UInt64?
    public var chunk: Int = 256 << 10
    public var window: Int = 4 << 20
    /// From an earlier attempt, so a resumed download fails (`changed`) rather than splicing versions.
    public var expectSize: UInt64?
    public var expectMtimeNs: String?

    public init(offset: UInt64 = 0, length: UInt64? = nil, expectSize: UInt64? = nil, expectMtimeNs: String? = nil) {
        self.offset = offset
        self.length = length
        self.expectSize = expectSize
        self.expectMtimeNs = expectMtimeNs
    }
}

public struct FileWriteOptions: Sendable {
    /// The total size, checked before the file replaces anything.
    public var size: UInt64?
    public var overwrite = false
    /// The target must still have this mtime when the write completes (safe edit-and-save).
    public var expectMtimeNs: String?
    public var mode: Int?
    /// The final file's modification time; copies keep their times.
    public var mtimeNs: String?
    /// Names the part file so an interrupted upload can resume; `source` identifies the local data.
    public var uploadID: String?
    public var source: String?
    public var chunk: Int = 256 << 10
    public var window: Int = 4 << 20

    public init(size: UInt64? = nil, overwrite: Bool = false, mode: Int? = nil, mtimeNs: String? = nil,
                uploadID: String? = nil, source: String? = nil) {
        self.size = size
        self.overwrite = overwrite
        self.mode = mode
        self.mtimeNs = mtimeNs
        self.uploadID = uploadID
        self.source = source
    }
}

/// A read in progress: what's being read, and its bytes in order. Cancel to stop early.
public struct FileReadStream: Sendable {
    public var size: UInt64
    public var mtimeNs: String
    /// Where the data starts.
    public var offset: UInt64
    public var data: AsyncThrowingStream<Data, Error>
    public var cancel: @Sendable () -> Void

    public init(size: UInt64, mtimeNs: String, offset: UInt64, data: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void) {
        self.size = size
        self.mtimeNs = mtimeNs
        self.offset = offset
        self.data = data
        self.cancel = cancel
    }
}

/// Where a write's bytes come from. `open(at:)` starts at an offset, for resuming.
public protocol FileDataSource: Sendable {
    var size: UInt64 { get }
    /// Identifies this data across attempts (`fs.write`'s `source`), such as "size:mtime".
    var fingerprint: String { get }
    func open(at offset: UInt64) async throws -> AsyncThrowingStream<Data, Error>
}

public protocol FileBackend: AnyObject, Sendable {
    /// Whether file access is available (clothod announces `fs` in hello.features).
    var supportsFiles: Bool { get }
    /// The user's home directory, for breadcrumbs (hello.machine.home on clothod).
    var homeDirectory: String? { get }

    func stat(_ path: String) async throws -> FileEntry
    func list(_ path: String, hidden: Bool, limit: Int?, cursor: String?) async throws -> FileListing
    func mkdir(_ path: String, parents: Bool) async throws -> FileEntry
    func setattr(_ path: String, mtimeNs: String?, mode: Int?) async throws -> FileEntry
    func rename(_ from: String, to: String, overwrite: Bool) async throws -> FileEntry
    func remove(_ path: String, recursive: Bool) async throws
    func statfs(_ path: String) async throws -> FileSpace
    func read(_ path: String, options: FileReadOptions) async throws -> FileReadStream
    /// Writes `source` (from the offset the machine already has, when resuming) and returns the new entry.
    /// `progress` gets the bytes written so far.
    func write(_ path: String, options: FileWriteOptions, source: FileDataSource,
               progress: @escaping @Sendable (UInt64) -> Void) async throws -> FileEntry
}

public extension FileBackend {
    /// Every entry of a directory, following `next` until the end.
    func listAll(_ path: String, hidden: Bool = true) async throws -> (dir: FileEntry, entries: [FileEntry]) {
        var cursor: String?
        var entries: [FileEntry] = []
        var dir: FileEntry?
        repeat {
            let page = try await list(path, hidden: hidden, limit: 1000, cursor: cursor)
            dir = dir ?? page.dir
            entries += page.entries
            cursor = page.next
        } while cursor != nil
        return (dir!, entries)
    }
}

/// `fs.*` error codes (protocol.md, "Files" › Errors), from a BackendError.
public enum FileErrorCode: String, Sendable {
    case notFound = "not_found", exists, permissionDenied = "permission_denied", notADirectory = "not_a_directory"
    case isADirectory = "is_a_directory", notEmpty = "not_empty", crossDevice = "cross_device", noSpace = "no_space"
    case readOnly = "read_only", conflict, changed, tooManyStreams = "too_many_streams", badRequest = "bad_request"
    case ioError = "io_error"
}

public extension Error {
    /// The `fs.*` error code, if this is one.
    var fileErrorCode: FileErrorCode? { (self as? BackendError).flatMap { FileErrorCode(rawValue: $0.code) } }
}

/// Joins a directory path and a name, the way the machine spells paths.
public func filePath(_ directory: String, _ name: String) -> String {
    directory.hasSuffix("/") ? directory + name : directory + "/" + name
}
