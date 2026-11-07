@testable import Clotho
import XCTest

/// The tailnet node's Keychain state store, in the test service only. Runs in every build: the store doesn't
/// need the node (the restart-without-login test is TailnetNodeAppTests, in CLOTHO_TAILNET builds).
final class TailnetKeychainStoreTests: XCTestCase {
    private let store = TailnetKeychainStore(service: .test)

    override func setUp() {
        TailnetKeychainStore.deleteAll(.test)
    }

    override func tearDown() {
        TailnetKeychainStore.deleteAll(.test)
        try? TailnetKeychainStore(service: .dev).write(key: "tailnet-store-test", value: nil)
        KeyStore.delete("tailnet-store-test-key")
    }

    func testMissingKeyReadsNil() throws {
        XCTAssertNil(try store.read(key: "_machinekey"))
        XCTAssertEqual(store.keys(), [])
    }

    func testRoundTripAndOverwrite() throws {
        try store.write(key: "_machinekey", value: Data("one".utf8))
        XCTAssertEqual(try store.read(key: "_machinekey"), Data("one".utf8))
        try store.write(key: "_machinekey", value: Data("two".utf8))
        XCTAssertEqual(try store.read(key: "_machinekey"), Data("two".utf8))
        // Another instance on the same service sees the same items.
        XCTAssertEqual(try TailnetKeychainStore(service: .test).read(key: "_machinekey"), Data("two".utf8))
    }

    func testNilAndEmptyDelete() throws {
        try store.write(key: "a", value: Data("x".utf8))
        try store.write(key: "b", value: Data("y".utf8))
        try store.write(key: "a", value: nil)
        try store.write(key: "b", value: Data())
        XCTAssertNil(try store.read(key: "a"))
        XCTAssertNil(try store.read(key: "b"))
        // Deleting what isn't there is fine.
        try store.write(key: "a", value: nil)
        XCTAssertEqual(store.keys(), [])
    }

    func testKeys() throws {
        for key in ["profile-1", "_current-profile", "_machinekey"] { try store.write(key: key, value: Data(key.utf8)) }
        XCTAssertEqual(store.keys(), ["_current-profile", "_machinekey", "profile-1"])
    }

    func testDeleteAllStaysInItsService() throws {
        let dev = TailnetKeychainStore(service: .dev)
        // A key of its own: the simulator's debug node may have real state in .dev.
        try dev.write(key: "tailnet-store-test", value: Data("dev".utf8))
        try store.write(key: "_machinekey", value: Data("test".utf8))
        try KeyStore.save(SSHKey(id: "tailnet-store-test-key", name: "kept", kind: .ed25519, created: Date(), secret: Data(repeating: 7, count: 32)))
        TailnetKeychainStore.deleteAll(.test)
        XCTAssertNil(try store.read(key: "_machinekey"))
        XCTAssertEqual(try dev.read(key: "tailnet-store-test"), Data("dev".utf8))
        XCTAssertNotNil(KeyStore.key("tailnet-store-test-key"), "an SSH key went with the tailnet state")
    }

    func testLargeValue() throws {
        let big = Data((0..<65_536).map { UInt8($0 % 251) })
        try store.write(key: "profile-big", value: big)
        XCTAssertEqual(try store.read(key: "profile-big"), big)
    }

    /// The shim calls from its own threads; an old node shutting down and its replacement may overlap.
    func testConcurrentCallsEndConsistent() throws {
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            let mine = TailnetKeychainStore(service: .test)
            for i in 0..<25 {
                try? mine.write(key: "shared", value: Data("\(thread)-\(i)".utf8))
                _ = try? mine.read(key: "shared")
                try? mine.write(key: "own-\(thread)", value: Data("\(i)".utf8))
            }
        }
        let shared = try XCTUnwrap(try store.read(key: "shared"))
        XCTAssertTrue(String(decoding: shared, as: UTF8.self).hasSuffix("-24"), String(decoding: shared, as: UTF8.self))
        for thread in 0..<8 { XCTAssertEqual(try store.read(key: "own-\(thread)"), Data("24".utf8)) }
        XCTAssertEqual(store.keys().count, 9)
    }

    func testRevokedLeaseDropsWritesButReads() throws {
        let old = store.lease()
        try old.write(key: "_machinekey", value: Data("old".utf8))
        old.revoke()
        let new = store.lease()
        try new.write(key: "_machinekey", value: Data("new".utf8))
        try old.write(key: "_machinekey", value: Data("stale".utf8))   // dropped, no error
        try old.write(key: "_current-profile", value: nil)               // dropped too
        XCTAssertEqual(try old.read(key: "_machinekey"), Data("new".utf8))
        XCTAssertEqual(try store.read(key: "_machinekey"), Data("new".utf8))
        XCTAssertTrue(old.isRevoked)
        XCTAssertFalse(new.isRevoked)
    }
}
