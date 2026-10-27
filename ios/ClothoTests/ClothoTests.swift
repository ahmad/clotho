@testable import Clotho
import XCTest

final class ClothoTests: XCTestCase {
    func testFingerprintMatchesSSHKeygen() {
        // `ssh-keygen -lf` on this key prints SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test"
        XCTAssertEqual(HostKeys.fingerprint(key), "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
    }

    func testMachineRoundTrips() throws {
        let machine = Machine(name: "devbox", host: "devbox", user: "ahmad", devDirs: true)
        let data = try JSONEncoder.iso.encode([machine])
        let decoded = try JSONDecoder.iso.decode([Machine].self, from: data)
        XCTAssertEqual(decoded.first?.endpoint, machine.endpoint)
        XCTAssertEqual(decoded.first?.devDirs, true)
    }
}
