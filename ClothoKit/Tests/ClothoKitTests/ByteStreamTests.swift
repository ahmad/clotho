import Foundation
import XCTest
@testable import ClothoKit

final class ByteStreamTests: XCTestCase {
    /// Switching a machine off mid-transfer ends its ssh while a write may still be on its way. Writing
    /// to a pipe with no reader must fail quietly instead of raising SIGPIPE, which ends the whole app.
    func testWritingToAPipeWithNoReaderDoesNotRaiseSIGPIPE() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let stream = ByteStream(readFD: fds[0], writeFD: fds[1], onShutdown: {})
        // The reading side goes away, as when ssh exits.
        close(fds[0])
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        // Without F_SETNOSIGPIPE this kills the test process.
        stream.write(Data(repeating: 0x41, count: 256 << 10))
        stream.write(Data("again".utf8))
        close(fds[1])
    }
}
