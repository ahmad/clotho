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

    /// Tests never reach the deployed relay unless one asks: under test the built-in relay is dropped, an
    /// override (the dev relay) always wins, and `-PushRealRelay YES` brings the built-in one back.
    func testRelayChoice() {
        let builtIn = URL(string: "https://relay.example.com")!
        let dev = "http://127.0.0.1:8787"
        func relay(_ override: String?, _ builtIn: URL?, test: Bool, real: Bool) -> URL? {
            PushRegistrar.relay(override: override, builtIn: builtIn, underTest: test, realRelayAllowed: real)
        }
        XCTAssertNil(relay(nil, builtIn, test: true, real: false), "under test, not opted in")
        XCTAssertEqual(relay(nil, builtIn, test: true, real: true), builtIn, "under test, opted in")
        XCTAssertEqual(relay(nil, builtIn, test: false, real: false), builtIn, "the app as the user runs it")
        XCTAssertEqual(relay(nil, builtIn, test: false, real: true), builtIn)
        for test in [true, false] {
            for real in [true, false] {
                XCTAssertEqual(relay(dev, builtIn, test: test, real: real), URL(string: dev), "the override wins")
                XCTAssertEqual(relay(dev, nil, test: test, real: real), URL(string: dev))
                XCTAssertNil(relay(nil, nil, test: test, real: real), "a build without a relay has none")
            }
        }
    }

    /// The unit tests' host app is itself under test, so it has no relay unless a launch argument gave one.
    @MainActor
    func testTheTestHostUsesNoBuiltInRelay() {
        XCTAssertTrue(PushRegistrar.isUnderTest)
        guard UserDefaults.standard.string(forKey: "PushRelay") == nil, !UserDefaults.standard.bool(forKey: "PushRealRelay") else { return }
        XCTAssertNil(PushRegistrar.shared.relay)
        XCTAssertNil(PushRegistrar.shared.handle)
    }

    func testNoBuiltInRelayWithoutAURL() {
        for value in [nil, "", "  ", "$(CLOTHO_RELAY_URL)", "relay.example.com", "ftp://relay.example.com", "https://"] as [String?] {
            XCTAssertNil(PushRegistrar.builtInRelay(value), "\(value ?? "nil")")
        }
    }
}
