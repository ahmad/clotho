@testable import Clotho
import XCTest

/// The private build-time values (the team prefix and the relay URL) reach the app through Info.plist; these
/// are how the app reads them. Fake values only.
final class BuildSettingsTests: XCTestCase {
    func testSharedGroupFromPrefix() {
        XCTAssertEqual(PushKey.sharedGroup(prefix: "ABCDE12345."), "ABCDE12345.nyc.amin.clotho.shared")
    }

    func testNoSharedGroupWithoutAPrefix() {
        for prefix in [nil, "", ".", "ABCDE12345", "$(AppIdentifierPrefix)"] as [String?] {
            XCTAssertNil(PushKey.sharedGroup(prefix: prefix), "\(prefix ?? "nil")")
        }
    }

    func testBuiltInRelay() {
        XCTAssertEqual(PushRegistrar.builtInRelay("https://relay.example.com"), URL(string: "https://relay.example.com"))
        XCTAssertEqual(PushRegistrar.builtInRelay(" https://relay.example.com\n"), URL(string: "https://relay.example.com"))
        XCTAssertEqual(PushRegistrar.builtInRelay("http://127.0.0.1:8787"), URL(string: "http://127.0.0.1:8787"))
    }

    func testNoBuiltInRelayWithoutAURL() {
        for value in [nil, "", "  ", "$(CLOTHO_RELAY_URL)", "relay.example.com", "ftp://relay.example.com", "https://"] as [String?] {
            XCTAssertNil(PushRegistrar.builtInRelay(value), "\(value ?? "nil")")
        }
    }
}
