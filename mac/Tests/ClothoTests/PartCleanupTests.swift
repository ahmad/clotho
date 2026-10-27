import ClothoKit
import XCTest
@testable import Clotho

final class PartCleanupTests: XCTestCase {
    private func entry(_ name: String, age: TimeInterval, now: Date, type: String = "file") throws -> FileEntry {
        let json = """
        {"name":"\(name)","path":"/d/\(name)","type":"\(type)","link":false,"size":1,"mtime":\(now.timeIntervalSince1970 - age),
         "mtime_ns":"0","mode":420,"hidden":true}
        """
        return try JSONDecoder().decode(FileEntry.self, from: Data(json.utf8))
    }

    func testOnlyOldPartFiles() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entries = [
            try entry(".big.iso.clotho-part-ab12", age: 2 * 86400, now: now),
            try entry(".big.iso.clotho-part-ab12.source", age: 2 * 86400, now: now),
            try entry(".fresh.bin.clotho-part-cd34", age: 3600, now: now),     // may still resume
            try entry("big.iso", age: 9 * 86400, now: now),                     // a real file
            try entry(".hidden", age: 9 * 86400, now: now),
            try entry(".dir.clotho-part-x", age: 9 * 86400, now: now, type: "dir"),
        ]
        XCTAssertEqual(PartCleanup.expired(entries, now: now), ["/d/.big.iso.clotho-part-ab12", "/d/.big.iso.clotho-part-ab12.source"])
    }

    func testRememberedEntries() {
        let value = PartCleanup.encode("d5ec80", "/home/a/My Folder")
        XCTAssertEqual(PartCleanup.decode(value)?.machine, "d5ec80")
        XCTAssertEqual(PartCleanup.decode(value)?.folder, "/home/a/My Folder")
        XCTAssertNil(PartCleanup.decode("no-separator"))
    }

    /// A real sweep on this Mac's files, in a temporary folder tree.
    func testSweepRemovesOldPartsOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clotho-parts-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSinceNow: -3 * 86400)
        func make(_ url: URL, date: Date) throws {
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try make(sub.appendingPathComponent(".a.bin.clotho-part-1"), date: old)
        try make(sub.appendingPathComponent(".a.bin.clotho-part-1.source"), date: old)
        try make(root.appendingPathComponent("keep.txt"), date: old)
        try make(root.appendingPathComponent(".b.bin.clotho-part-2"), date: Date())

        let clean = await PartCleanup.sweep(root.path, on: LocalFileBackend())
        XCTAssertFalse(clean, "a young part file remains")
        let left = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(left, [".b.bin.clotho-part-2", "keep.txt", "sub"])

        try FileManager.default.removeItem(at: root.appendingPathComponent(".b.bin.clotho-part-2"))
        let cleanNow = await PartCleanup.sweep(root.path, on: LocalFileBackend())
        XCTAssertTrue(cleanNow)
        let gone = await PartCleanup.sweep(root.appendingPathComponent("missing").path, on: LocalFileBackend())
        XCTAssertTrue(gone, "a folder that's gone counts as clean")
        let unreachable = await PartCleanup.sweep(root.path, on: Unreachable())
        XCTAssertFalse(unreachable, "a machine that can't list the folder now keeps it for later")
    }
}

/// File access that fails the way a dropped connection does.
private final class Unreachable: FileBackend, @unchecked Sendable {
    let supportsFiles = true
    let homeDirectory: String? = "/"
    private var error: BackendError { BackendError(code: "disconnected", message: "not connected to clothod") }
    func stat(_ path: String) async throws -> FileEntry { throw error }
    func list(_ path: String, hidden: Bool, limit: Int?, cursor: String?) async throws -> FileListing { throw error }
    func mkdir(_ path: String, parents: Bool) async throws -> FileEntry { throw error }
    func setattr(_ path: String, mtimeNs: String?, mode: Int?) async throws -> FileEntry { throw error }
    func rename(_ from: String, to: String, overwrite: Bool) async throws -> FileEntry { throw error }
    func remove(_ path: String, recursive: Bool) async throws { throw error }
    func statfs(_ path: String) async throws -> FileSpace { throw error }
    func read(_ path: String, options: FileReadOptions) async throws -> FileReadStream { throw error }
    func write(_ path: String, options: FileWriteOptions, source: FileDataSource,
               progress: @escaping @Sendable (UInt64) -> Void) async throws -> FileEntry { throw error }
}
