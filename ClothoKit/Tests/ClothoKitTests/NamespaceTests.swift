@testable import ClothoKit
import XCTest

/// clothod 0.1.24 reports the launchd namespace its serve and holder run in; shells outside the login
/// session (anything but "Aqua") can lose DNS, the keychain and user lookups.
final class NamespaceTests: XCTestCase {
    private func hello(holder: String?, serve: String? = "Aqua") throws -> Hello {
        var holderJSON = #"{"pid": 9573, "version": "0.1.24""#
        if let holder { holderJSON += #", "namespace": "\#(holder)""# }
        holderJSON += "}"
        let serveJSON = serve.map { #", "namespace": "\#($0)""# } ?? ""
        let json = #"{"protocol": 1, "daemon": "clothod", "version": "0.1.24", "instance": "i"\#(serveJSON), "holder": \#(holderJSON)}"#
        return try JSONDecoder().decode(Hello.self, from: Data(json.utf8))
    }

    func testDecodesBothNamespaces() throws {
        let h = try hello(holder: "Background", serve: "Aqua")
        XCTAssertEqual(h.namespace, "Aqua")
        XCTAssertEqual(h.holder?.namespace, "Background")
    }

    func testOnlyTheHoldersNamespaceDecides() throws {
        XCTAssertFalse(try hello(holder: "Aqua").shellsLackSystemServices)
        XCTAssertTrue(try hello(holder: "Background").shellsLackSystemServices)
        XCTAssertTrue(try hello(holder: "none").shellsLackSystemServices, "torn down")
        XCTAssertFalse(try hello(holder: nil).shellsLackSystemServices, "not macOS, or an older holder")
        XCTAssertFalse(try hello(holder: "Aqua", serve: "Background").shellsLackSystemServices, "the shells are the holder's")
    }
}
