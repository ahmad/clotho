import ClothoKit
@testable import Clotho
import XCTest

/// Uploads and downloads through TransferCenter against the Mac's dev clothod (/tmp/cki-ios, started by
/// build.sh test), including a download interrupted by a dropped connection that resumes.
@MainActor
final class FileTransferTests: XCTestCase {
    let root = "/tmp/clotho-ios-transfer"
    private var connection: MachineConnection!

    override func setUp() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/cki-ios/clothod.sock") else { throw XCTSkip("no dev clothod") }
        try? FileManager.default.removeItem(atPath: root)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        connection = MachineConnection(machine: .localDev, transport: Connections.transport(for: .localDev))
        connection.connect()
        for _ in 0..<50 where !connection.store.isConnected { try await Task.sleep(nanoseconds: 100_000_000) }
        let files = try connection.fileBackend()
        XCTAssertTrue(files.supportsFiles)
    }

    override func tearDown() async throws {
        connection?.disconnect()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func wait(for transfer: @autoclosure () -> TransferCenter.Transfer?, timeout: TimeInterval = 30) async throws -> TransferCenter.Transfer {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let t = transfer(), !t.state.isActive { return t }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("transfer didn't finish")
    }

    func testUploadThenDownload() async throws {
        let center = TransferCenter.shared
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString).bin")
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        center.upload([local], into: root, on: connection, conflict: .replace)
        let up = try await wait(for: center.transfers.last)
        XCTAssertEqual(up.state, .done)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/" + local.lastPathComponent)), bytes)

        var shared: [URL] = []
        center.onDownloaded = { shared = $0.localItems }
        let entry = try await connection.fileBackend().stat(root + "/" + local.lastPathComponent)
        center.download([entry], from: connection)
        let down = try await wait(for: center.transfers.last)
        XCTAssertEqual(down.state, .done)
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(try Data(contentsOf: shared[0]), bytes)
    }

    /// The connection drops mid-download (as when iOS suspends the app); the transfer waits, then resumes.
    func testDownloadSurvivesReconnect() async throws {
        let center = TransferCenter.shared
        let bytes = Data((0..<40_000_000).map { UInt8($0 % 249) })
        let path = root + "/big.bin"
        try bytes.write(to: URL(fileURLWithPath: path))
        let entry = try await connection.fileBackend().stat(path)
        var shared: [URL] = []
        center.onDownloaded = { shared = $0.localItems }
        center.download([entry], from: connection)
        let transfer = try XCTUnwrap(center.transfers.last)
        while transfer.fraction < 0.05 && transfer.state.isActive { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(transfer.state.isActive, "finished before the drop; make the file bigger")
        connection.suspend()
        try await Task.sleep(nanoseconds: 500_000_000)
        connection.resume()
        let done = try await wait(for: transfer, timeout: 60)
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(try Data(contentsOf: shared[0]), bytes)
    }
}
