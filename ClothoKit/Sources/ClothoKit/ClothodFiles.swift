import Foundation

// ClothodBackend's file access (protocol.md, "Files"): the fs.* methods, and fs.read/fs.write streams
// carried in FILE_DATA frames with credit-based flow control.

/// An open stream. Guarded by the backend's lock.
final class FileStream: @unchecked Sendable {
    enum Kind {
        case read(AsyncThrowingStream<Data, Error>.Continuation)
        case write
    }

    let kind: Kind
    // Writes: how far the daemon has written, and how far past that it lets us send.
    var acked: UInt64 = 0
    var window: UInt64 = 0
    var progress: (@Sendable (UInt64) -> Void)?
    var creditWaiter: CheckedContinuation<Void, Error>?
    var doneWaiter: CheckedContinuation<FileEntry, Error>?
    /// How the write ended (fs.done, fs.error, cancelled, or a dropped connection).
    var outcome: Result<FileEntry, Error>?

    init(_ kind: Kind) { self.kind = kind }
}

extension ClothodBackend: FileBackend {
    public var supportsFiles: Bool { locked { lastHello?.features.contains(.fs) ?? false } }
    public var homeDirectory: String? { locked { lastHello?.machine?.home } }

    public func stat(_ path: String) async throws -> FileEntry {
        try Self.decode(FileEntry.self, from: try await request("fs.stat", ["path": path]))
    }

    public func list(_ path: String, hidden: Bool, limit: Int?, cursor: String?) async throws -> FileListing {
        var params: [String: Any] = ["path": path, "hidden": hidden]
        params["limit"] = limit
        params["cursor"] = cursor
        return try Self.decode(FileListing.self, from: try await request("fs.list", params))
    }

    public func mkdir(_ path: String, parents: Bool) async throws -> FileEntry {
        try Self.decode(FileEntry.self, from: try await request("fs.mkdir", ["path": path, "parents": parents]))
    }

    public func setattr(_ path: String, mtimeNs: String?, mode: Int?) async throws -> FileEntry {
        var params: [String: Any] = ["path": path]
        params["mtime_ns"] = mtimeNs
        params["mode"] = mode
        return try Self.decode(FileEntry.self, from: try await request("fs.setattr", params))
    }

    public func rename(_ from: String, to: String, overwrite: Bool) async throws -> FileEntry {
        try Self.decode(FileEntry.self, from: try await request("fs.rename", ["from": from, "to": to, "overwrite": overwrite]))
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        _ = try await request("fs.remove", ["path": path, "recursive": recursive])
    }

    public func statfs(_ path: String) async throws -> FileSpace {
        try Self.decode(FileSpace.self, from: try await request("fs.statfs", ["path": path]))
    }

    public func read(_ path: String, options: FileReadOptions) async throws -> FileReadStream {
        var params: [String: Any] = ["path": path, "offset": options.offset, "chunk": options.chunk, "window": options.window]
        params["length"] = options.length
        params["expect_size"] = options.expectSize
        params["expect_mtime_ns"] = options.expectMtimeNs
        // Frames arrive in order on the read thread; the stream is buffered here until it's consumed,
        // which the daemon bounds to one window because it waits for our acks.
        let (frames, feed) = AsyncThrowingStream.makeStream(of: Data.self)
        let result = try await request("fs.read", params, onReply: { [weak self] result in
            guard let self, let stream = Self.streamID(in: result) else { return }
            self.locked { self.fileStreams[stream] = FileStream(.read(feed)) }
        })
        guard let object = result as? [String: Any], let stream = Self.streamID(in: result) else {
            throw BackendError(code: "internal", message: "fs.read reply without a stream")
        }
        let offset = (object["offset"] as? NSNumber)?.uint64Value ?? options.offset
        let pump = ReadPump(frames: frames, backend: self, stream: stream, position: offset, window: UInt64(options.window))
        return FileReadStream(size: (object["size"] as? NSNumber)?.uint64Value ?? 0, mtimeNs: object["mtime_ns"] as? String ?? "",
                              offset: offset, data: AsyncThrowingStream(unfolding: { try await pump.next() }),
                              cancel: { [weak self] in self?.cancelStream(stream) })
    }

    public func write(_ path: String, options: FileWriteOptions, source: FileDataSource,
                      progress: @escaping @Sendable (UInt64) -> Void) async throws -> FileEntry {
        var params: [String: Any] = ["path": path, "overwrite": options.overwrite, "chunk": options.chunk, "window": options.window]
        params["size"] = options.size
        params["expect_mtime_ns"] = options.expectMtimeNs
        params["mode"] = options.mode
        params["mtime_ns"] = options.mtimeNs
        params["upload_id"] = options.uploadID
        params["source"] = options.source
        let state = FileStream(.write)
        state.progress = progress
        let result = try await request("fs.write", params, onReply: { [weak self] result in
            guard let self, let stream = Self.streamID(in: result) else { return }
            let object = result as? [String: Any]
            self.locked {
                state.acked = (object?["offset"] as? NSNumber)?.uint64Value ?? 0
                state.window = (object?["window"] as? NSNumber)?.uint64Value ?? UInt64(options.window)
                self.fileStreams[stream] = state
            }
        })
        guard let stream = Self.streamID(in: result) else {
            throw BackendError(code: "internal", message: "fs.write reply without a stream")
        }
        let start = locked { state.acked }
        progress(start)
        do {
            try await withTaskCancellationHandler {
                var position = start
                var pending = Data()
                func sendPiece(_ piece: Data) async throws {
                    try await waitForCredit(state, upTo: position + UInt64(piece.count))
                    sendFileData(stream: stream, offset: position, fin: false, piece)
                    position += UInt64(piece.count)
                }
                for try await data in try await source.open(at: start) {
                    try Task.checkCancellation()
                    pending.append(data)
                    while pending.count >= options.chunk {
                        let piece = Data(pending.prefix(options.chunk))
                        pending.removeFirst(options.chunk)
                        try await sendPiece(piece)
                    }
                }
                if !pending.isEmpty { try await sendPiece(pending) }
                sendFileData(stream: stream, offset: position, fin: true, Data())
            } onCancel: {
                self.cancelStream(stream)
            }
            return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<FileEntry, Error>) in
                let outcome: Result<FileEntry, Error>? = locked {
                    if let outcome = state.outcome { return outcome }
                    state.doneWaiter = waiter
                    return nil
                }
                if let outcome { waiter.resume(with: outcome) }
            }
        } catch {
            // The daemon's reason (a full disk, say) beats the local symptom.
            if case .failure(let reason)? = locked({ state.outcome }) { throw reason }
            cancelStream(stream)
            throw error
        }
    }

    // MARK: Streams

    private func waitForCredit(_ state: FileStream, upTo end: UInt64) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            let now: Result<Void, Error>? = locked {
                if case .failure(let error)? = state.outcome { return .failure(error) }
                if state.outcome != nil || end <= state.acked + state.window { return .success(()) }
                state.creditWaiter = waiter
                return nil
            }
            if let now { waiter.resume(with: now) }
        }
        // A wake-up from an ack that didn't open enough room (or the outcome) is checked again.
        if locked({ state.outcome == nil && end > state.acked + state.window }) {
            try await waitForCredit(state, upTo: end)
        } else if case .failure(let error)? = locked({ state.outcome }) {
            throw error
        }
    }

    private func sendFileData(stream: UInt64, offset: UInt64, fin: Bool, _ bytes: Data) {
        var body = Data(capacity: bytes.count + 17)
        body.appendBigEndian(stream)
        body.appendBigEndian(offset)
        body.append(fin ? 1 : 0)
        body.append(bytes)
        send(.fileData, body)
    }

    /// Stops a read or abandons a write; the daemon confirms with fs.done {cancelled}.
    func cancelStream(_ stream: UInt64) {
        guard locked({ fileStreams[stream] != nil }) else { return }
        Task { _ = try? await request("fs.cancel", ["stream": stream]) }
    }

    func handleFileData(stream: UInt64, offset: UInt64, fin: Bool, bytes: Data) {
        locked {
            guard let state = fileStreams[stream], case .read(let feed) = state.kind else { return }
            if !bytes.isEmpty { feed.yield(bytes) }
            if fin {
                feed.finish()
                fileStreams[stream] = nil
            }
        }
    }

    func handleFileEvent(_ name: String, _ data: [String: Any]) {
        guard let stream = (data["stream"] as? NSNumber)?.uint64Value else { return }
        switch name {
        case "fs.ack":
            guard let offset = (data["offset"] as? NSNumber)?.uint64Value else { return }
            let (waiter, progress): (CheckedContinuation<Void, Error>?, (@Sendable (UInt64) -> Void)?) = locked {
                guard let state = fileStreams[stream], case .write = state.kind else { return (nil, nil) }
                state.acked = max(state.acked, offset)
                defer { state.creditWaiter = nil }
                return (state.creditWaiter, state.progress)
            }
            progress?(offset)
            waiter?.resume()
        case "fs.done":
            if data["cancelled"] as? Bool == true {
                endStream(stream, .failure(CancellationError()))
            } else if let entry = (data["entry"]).flatMap({ try? Self.decode(FileEntry.self, from: $0) }) {
                endStream(stream, .success(entry))
            } else {
                endStream(stream, .failure(BackendError(code: "internal", message: "fs.done without an entry")))
            }
        default:
            endStream(stream, .failure(BackendError(code: data["code"] as? String ?? "io_error",
                                                   message: data["message"] as? String ?? "file transfer failed")))
        }
    }

    /// Ends every open stream, when the connection is gone: the daemon has cancelled them.
    func failFileStreams(_ error: Error) {
        let streams: [UInt64] = locked { Array(fileStreams.keys) }
        streams.forEach { endStream($0, .failure(error)) }
    }

    private func endStream(_ stream: UInt64, _ outcome: Result<FileEntry, Error>) {
        let waiters: [() -> Void] = locked {
            guard let state = fileStreams.removeValue(forKey: stream) else { return [] }
            switch state.kind {
            case .read(let feed):
                if case .failure(let error) = outcome { feed.finish(throwing: error) } else { feed.finish() }
                return []
            case .write:
                state.outcome = outcome
                let credit = state.creditWaiter, done = state.doneWaiter
                state.creditWaiter = nil
                state.doneWaiter = nil
                return [{ credit?.resume() }, { done?.resume(with: outcome) }]
            }
        }
        waiters.forEach { $0() }
    }

    static func streamID(in result: Any) -> UInt64? {
        ((result as? [String: Any])?["stream"] as? NSNumber)?.uint64Value
    }
}

/// Hands a read's chunks to its consumer and acks them as they're taken, so the daemon sends only
/// as fast as the app actually uses the data.
private final class ReadPump: @unchecked Sendable {
    private var frames: AsyncThrowingStream<Data, Error>.AsyncIterator
    private weak var backend: ClothodBackend?
    private let stream: UInt64
    private var position: UInt64
    private var acked: UInt64
    private let window: UInt64

    init(frames: AsyncThrowingStream<Data, Error>, backend: ClothodBackend, stream: UInt64, position: UInt64, window: UInt64) {
        self.frames = frames.makeAsyncIterator()
        self.backend = backend
        self.stream = stream
        self.position = position
        acked = position
        self.window = window
    }

    func next() async throws -> Data? {
        guard let chunk = try await frames.next() else { return nil }
        position += UInt64(chunk.count)
        if position - acked >= window / 4 {
            backend?.notify("fs.ack", ["stream": stream, "offset": position])
            acked = position
        }
        return chunk
    }
}
