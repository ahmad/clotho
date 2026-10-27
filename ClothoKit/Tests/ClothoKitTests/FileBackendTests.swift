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
