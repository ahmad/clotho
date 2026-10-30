import ClothoKit
import XCTest

/// clothod 0.1.25 marks a restore that continued the folder's latest conversation (no session id) with
/// `continued: true`; older daemons leave it out.
final class PaneRestoreTests: XCTestCase {
    func testDecodesContinuedAndAMissingSession() throws {
        let decode = { (json: String) in try JSONDecoder().decode(PaneRestore.self, from: Data(json.utf8)) }
        let continued = try decode(#"{"at": 5, "agent": "claude", "session": null, "continued": true}"#)
        XCTAssertEqual(continued, PaneRestore(at: 5, agent: "claude", continued: true))
        XCTAssertEqual(try decode(#"{"at": 5, "agent": "codex", "session": "x"}"#), PaneRestore(at: 5, agent: "codex", session: "x"),
                       "older daemons send no continued")
        XCTAssertEqual(try decode(#"{"at": 5}"#), PaneRestore(at: 5))
    }

    func testNote() {
        XCTAssertEqual(PaneRestore(at: 1, agent: "claude", continued: true).note, "Continued the latest conversation in this folder")
        XCTAssertEqual(PaneRestore(at: 1, agent: "claude", session: "abc").note, "Restored after restart · resumed Claude session")
    }
}
