@testable import ClothoKit
import XCTest

/// Bytes in memory, optionally failing partway, to interrupt an upload.
struct MemorySource: FileDataSource {
    var data: Data
    var failAfter: Int?
    var size: UInt64 { UInt64(data.count) }
    var fingerprint: String { "\(data.count):\(data.hashValue)" }

    func open(at offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let data = data, failAfter = failAfter
        return AsyncThrowingStream { continuation in
            var position = Int(offset)
            while position < data.count {
                let end = min(position + 10_000, data.count)
                if let failAfter, end > failAfter {
                    continuation.finish(throwing: BackendError(code: "test", message: "interrupted"))
                    return
                }
                continuation.yield(data.subdata(in: position ..< end))
                position = end
            }
            continuation.finish()
        }
    }
}

/// The same checks for every FileBackend, so clothod and this device behave alike.
enum FileBackendChecks {
    static func metadata(_ files: FileBackend, root: String) async throws {
        let dir = try await files.mkdir(filePath(root, "a/b"), parents: true)
        XCTAssertEqual(dir.type, .dir)
        do {
            _ = try await files.mkdir(filePath(root, "a"), parents: false)
            XCTFail("mkdir of an existing directory succeeded")
        } catch {
            XCTAssertEqual(error.fileErrorCode, .exists)
        }
        let written = try await files.write(filePath(root, "a/one.txt"), options: FileWriteOptions(mtimeNs: "1700000000123456789"),
                                            source: MemorySource(data: Data("hello".utf8)), progress: { _ in })
        XCTAssertEqual(written.size, 5)
        XCTAssertEqual(written.mtimeNs, "1700000000123456789")
        let stat = try await files.stat(filePath(root, "a/one.txt"))
        XCTAssertEqual(stat.text, true)
        _ = try await files.write(filePath(root, "a/.hidden"), options: FileWriteOptions(), source: MemorySource(data: Data()), progress: { _ in })

        let all = try await files.listAll(filePath(root, "a"))
        XCTAssertEqual(all.entries.map(\.name), [".hidden", "b", "one.txt"])
        XCTAssertEqual(all.entries.first { $0.name == ".hidden" }?.hidden, true)
        let visible = try await files.list(filePath(root, "a"), hidden: false, limit: nil, cursor: nil)
        XCTAssertEqual(visible.entries.map(\.name), ["b", "one.txt"])
        let page = try await files.list(filePath(root, "a"), hidden: true, limit: 2, cursor: nil)
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertNotNil(page.next)

        do {
            _ = try await files.write(filePath(root, "a/one.txt"), options: FileWriteOptions(), source: MemorySource(data: Data("x".utf8)), progress: { _ in })
            XCTFail("write over an existing file without overwrite succeeded")
        } catch {
            XCTAssertEqual(error.fileErrorCode, .exists)
        }
        let moved = try await files.rename(filePath(root, "a/one.txt"), to: filePath(root, "a/b/two.txt"), overwrite: false)
        XCTAssertEqual(moved.name, "two.txt")
        let touched = try await files.setattr(filePath(root, "a/b"), mtimeNs: "1600000000000000000", mode: nil)
        XCTAssertEqual(touched.mtimeNs, "1600000000000000000")
        let space = try await files.statfs(root)
        XCTAssertGreaterThan(space.total, 0)

        do {
            try await files.remove(filePath(root, "a"), recursive: false)
            XCTFail("removing a non-empty directory succeeded")
        } catch {
            XCTAssertEqual(error.fileErrorCode, .notEmpty)
        }
        try await files.remove(filePath(root, "a"), recursive: true)
        do {
            _ = try await files.stat(filePath(root, "a"))
            XCTFail("stat of a removed directory succeeded")
        } catch {
            XCTAssertEqual(error.fileErrorCode, .notFound)
        }
    }

    static func readAll(_ files: FileBackend, _ path: String, options: FileReadOptions = FileReadOptions()) async throws -> Data {
        let stream = try await files.read(path, options: options)
        var data = Data()
        for try await chunk in stream.data { data.append(chunk) }
        return data
    }

    static func randomData(_ count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
    }
}

final class LocalFileBackendTests: XCTestCase {
    func testMetadata() async throws {
        let root = NSTemporaryDirectory() + "ckt-files-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await FileBackendChecks.metadata(LocalFileBackend(), root: root)
    }
}

extension ClothodBackendTests {
    func makeFileRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ckt-files-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    func testFilesMetadata() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        XCTAssertTrue(backend.supportsFiles)
        XCTAssertEqual(backend.homeDirectory, NSHomeDirectory())
        try await FileBackendChecks.metadata(backend, root: try makeFileRoot())
    }

    func testFileTransferWithSmallWindows() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        let path = filePath(try makeFileRoot(), "big.bin")
        let data = FileBackendChecks.randomData(3 << 20 + 123)

        var options = FileWriteOptions(size: UInt64(data.count), mode: 0o751, mtimeNs: "1700000000000000001")
        options.chunk = 16 << 10
        options.window = 64 << 10
        let progress = Progress()
        let entry = try await backend.write(path, options: options, source: MemorySource(data: data),
                                            progress: { progress.set($0) })
        XCTAssertEqual(entry.size, UInt64(data.count))
        XCTAssertEqual(entry.mode, 0o751)
        XCTAssertEqual(entry.mtimeNs, "1700000000000000001")
        XCTAssertEqual(progress.value, UInt64(data.count))

        var read = FileReadOptions()
        read.chunk = 16 << 10
        read.window = 64 << 10
        let back = try await FileBackendChecks.readAll(backend, path, options: read)
        XCTAssertEqual(back, data)

        // A range, and a resume check that fails when the file isn't the one expected.
        let range = try await FileBackendChecks.readAll(backend, path, options: FileReadOptions(offset: 1000, length: 5000))
        XCTAssertEqual(range, data.subdata(in: 1000 ..< 6000))
        do {
            _ = try await FileBackendChecks.readAll(backend, path, options: FileReadOptions(offset: 10, expectSize: 1))
            XCTFail("a read expecting another size succeeded")
        } catch {
            XCTAssertEqual(error.fileErrorCode, .changed)
        }
    }

    func testUploadResumes() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        let path = filePath(try makeFileRoot(), "resume.bin")
        let data = FileBackendChecks.randomData(1 << 20)
        var options = FileWriteOptions(size: UInt64(data.count), uploadID: "ckt-\(UUID().uuidString)", source: "test-source")
        options.window = 64 << 10

        do {
            _ = try await backend.write(path, options: options, source: MemorySource(data: data, failAfter: 600_000), progress: { _ in })
            XCTFail("the interrupted upload succeeded")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, "test")
        }
        let started = Progress()
        let entry = try await backend.write(path, options: options, source: MemorySource(data: data),
                                            progress: { started.setFirst($0) })
        XCTAssertGreaterThan(started.value, 0, "the second attempt started over")
        XCTAssertEqual(entry.size, UInt64(data.count))
        let back = try await FileBackendChecks.readAll(backend, path)
        XCTAssertEqual(back, data)
    }

    func testCancelRead() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        let path = filePath(try makeFileRoot(), "cancel.bin")
        _ = try await backend.write(path, options: FileWriteOptions(), source: MemorySource(data: FileBackendChecks.randomData(2 << 20)), progress: { _ in })

        var options = FileReadOptions()
        options.window = 64 << 10
        let stream = try await backend.read(path, options: options)
        var received = 0
        do {
            for try await chunk in stream.data {
                received += chunk.count
                if received >= 100_000 { stream.cancel() }
            }
            XCTFail("a cancelled read ended normally")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(received, 2 << 20)
        // The connection is still fine afterwards.
        _ = try await backend.stat(path)
    }
}

/// A value set from a progress callback.
final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64?
    var value: UInt64 { lock.withLock { stored ?? 0 } }
    func set(_ value: UInt64) { lock.withLock { stored = value } }
    func setFirst(_ value: UInt64) { lock.withLock { if stored == nil { stored = value } } }
}

extension ClothodBackendTests {
    /// A tree up to clothod and back down again, keeping contents, modes and times, then a merge
    /// that skips what's already there.
    func testTreeTransferRoundTrip() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        let local = LocalFileBackend()
        let root = try makeFileRoot()
        let tree = filePath(root, "tree")
        try FileManager.default.createDirectory(atPath: filePath(tree, "sub/deeper"), withIntermediateDirectories: true)
        let big = FileBackendChecks.randomData(1 << 20 + 7)
        try big.write(to: URL(fileURLWithPath: filePath(tree, "sub/big.bin")))
        try Data("a".utf8).write(to: URL(fileURLWithPath: filePath(tree, "a.txt")))
        try Data().write(to: URL(fileURLWithPath: filePath(tree, "sub/deeper/empty")))
        chmod(filePath(tree, "a.txt"), 0o755)
        _ = try await local.setattr(filePath(tree, "sub"), mtimeNs: "1500000000000000000", mode: nil)
        try FileManager.default.createSymbolicLink(atPath: filePath(tree, "loop"), withDestinationPath: tree)

        // Up: this device → clothod (the daemon sees the same disk, in another folder).
        try FileManager.default.createDirectory(atPath: filePath(root, "up"), withIntermediateDirectories: true)
        let upload = FileTransfer(from: local, to: backend)
        let last = ProgressBox()
        try await upload.copy([tree], into: filePath(root, "up"), conflict: .replace) { last.set($0) }
        XCTAssertEqual(last.value?.totalFiles, 3)
        XCTAssertEqual(last.value?.doneFiles, 3)
        XCTAssertEqual(last.value?.doneBytes, UInt64(big.count + 1))

        // Down: clothod → this device.
        try FileManager.default.createDirectory(atPath: filePath(root, "down"), withIntermediateDirectories: true)
        try await FileTransfer(from: backend, to: local).copy([filePath(root, "up/tree")], into: filePath(root, "down"), conflict: .replace) { _ in }
        let copy = filePath(root, "down/tree")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: filePath(copy, "sub/big.bin"))), big)
        let mode = try await local.stat(filePath(copy, "a.txt")).mode
        let sub = try await local.stat(filePath(copy, "sub")).mtimeNs
        let copied = try await local.stat(filePath(copy, "sub/big.bin")).mtimeNs
        let original = try await local.stat(filePath(tree, "sub/big.bin")).mtimeNs
        let empty = try await local.stat(filePath(copy, "sub/deeper/empty")).size
        XCTAssertEqual(mode, 0o755)
        XCTAssertEqual(sub, "1500000000000000000")
        XCTAssertEqual(copied, original)
        XCTAssertEqual(empty, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath(copy, "loop")), "a link to a folder inside the tree was followed")

        // A merge that skips existing files copies only the new one.
        try Data("changed".utf8).write(to: URL(fileURLWithPath: filePath(tree, "a.txt")))
        try Data("new".utf8).write(to: URL(fileURLWithPath: filePath(tree, "new.txt")))
        let merge = ProgressBox()
        try await FileTransfer(from: local, to: backend).copy([tree], into: filePath(root, "up"), conflict: .skip) { merge.set($0) }
        XCTAssertEqual(merge.value?.skippedFiles, 3)
        XCTAssertEqual(try String(contentsOfFile: filePath(root, "up/tree/a.txt"), encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOfFile: filePath(root, "up/tree/new.txt"), encoding: .utf8), "new")
        let existing = await FileTransfer.existing(["tree", "nope"], in: filePath(root, "up"), on: backend)
        XCTAssertEqual(existing, ["tree"])
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FileTransfer.Progress?
    var value: FileTransfer.Progress? { lock.withLock { stored } }
    func set(_ value: FileTransfer.Progress) { lock.withLock { stored = value } }
}
