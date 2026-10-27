import ClothoKit
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

    /// Reply only on a hook-reported waiting agent that still wants attention.
    func testReplyOnlyForHookWaitingWithAttention() {
        func row(_ state: AgentInfo.State, _ source: String?, _ attention: Bool?) -> AgentRow {
            AgentRow(machineID: UUID(), machineName: "m", pane: 1, tab: 1, workspace: "w", title: "t",
                     info: AgentInfo(kind: "claude", state: state, source: source, attention: attention))
        }
        XCTAssertTrue(row(.waiting, "hook", true).acceptsReply)
        XCTAssertFalse(row(.waiting, "hook", false).acceptsReply, "already answered or acked")
        XCTAssertFalse(row(.waiting, "detected", true).acceptsReply, "detected agent (bell)")
        XCTAssertFalse(row(.waiting, "detected", nil).acceptsReply, "quiet output read as waiting")
        XCTAssertFalse(row(.running, "hook", true).acceptsReply)
        XCTAssertFalse(row(.done, "hook", true).acceptsReply)
    }
}
