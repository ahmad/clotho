import CryptoKit
@testable import Clotho
import UserNotifications
import XCTest

/// The push alert format (docs/push.md). The fixed vector is shared with clothod's sender tests, so both
/// sides agree on HPKE, the collapse id and the plaintext.
final class PushTests: XCTestCase {
    static let vectorKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    static let vectorLabel = "00000000-0000-0000-0000-00000000C10D devbox"
    static let vectorCollapse = "c1b5d6191cb70ab41a81baa4c6158682"
    static let vectorCiphertext = "jmHxxNQXj2wm3geR2KiLzXdhyo1/9E1jusxEmNVobigz4a+nHrN7MWYh8vvydxOmkSaESvX70WVLehRpiZb+pr9SJQPvKyhGm4Ym2ZXUGzUh5CrZVaVjnxOAIeuxPWOn8cGaelb1KkT8UR18z+Q4otc5PJLweY7a6nZmQ8ih8y9x35WLjHMHBQvaRUSZTr1K2uWBauhUmNsmQX6G2HcBf3XFG+sNQEyXVfJUlMJw0/+rp4gtYszv3tIXRNHrKpk="

    private func vectorPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: Self.vectorKey)!)
    }

    func testCollapseIDMatchesVector() {
        XCTAssertEqual(PushLabel.collapseID(label: Self.vectorLabel, pane: 7), Self.vectorCollapse)
    }

    func testOpensVector() throws {
        let alert = try PushAlert.open(Self.vectorCiphertext, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert, PushAlert(v: 1, m: Self.vectorLabel, p: 7, k: "claude", s: "waiting",
                                        msg: "Allow cargo test --release?", t: 1761512345.5))
    }

    /// The same alert sealed by clothod's Rust sender (the `hpke` crate) to the vector's public key.
    func testOpensClothodSealedVector() throws {
        let rust = "8AFMCmofcTuxV5Vtxag5O0/ZpkzEakZW+KEDOwzj+yBosSKsDGq9YGQrJV0j1Pd0BKqSpr4ZC937n+jQ5qe92MHlz9qCPy48Wn53QIdt5Rarvgm0SnZr1E0p2ZQwSnYEFGG9Bh0AErDkGExGcVOqrOshq6YrVBPLo+9yv1U8hKru+m6z7p1RsTa/YCw0IA79QrFBCkWuR+0wneXZvyZmKlvM2xCEPy+0k8kyU1828f/bpErpbAaL/E3wQSSf45w="
        let alert = try PushAlert.open(rust, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert, PushAlert(v: 1, m: Self.vectorLabel, p: 7, k: "claude", s: "waiting",
                                        msg: "Allow cargo test --release?", t: 1761512345.5))
    }

    /// clothod pads every alert to 1024 bytes with a trailing "pad" key, so the relay and Apple can't tell
    /// message lengths apart; the app ignores the key. The vector is clothod's PADDED/CT_PADDED.
    func testOpensClothodPaddedVector() throws {
        let rust = "waIuQwmR41aqP/FeDl6qcxO3VMlzn9JWMLLSVBBno3RoZ6H0WMBF+pB381kmx09JSwR0LKdoo1tQiL82E1SUpXiSbNRqF/I2TLdju9z5NN3Tcjo28n1MRYN8N54znoR81MryHYIWWw/enTmy3dld+zdiULd8YS8ZWuh/Yzv82zWvJRRoOMF2gHElBCt9BxNEXA3vxxlgM8dxksJx8uKZGql7nXKBsBVjnkUjSm/5JnzaHW89fhAbpaKXUXLP5TwGJ8N6d1k0yO/ikMJgQOJ3cMSkygWVIOLJFtuQ/hPDEj7vJSzVcud/zb+wZlbVJxjl1eSr+t4x9ESxBWnwy13o3zdDhwiHkbXlVYpCbaNtFjTmvSRf27nGoPEPCEIMskcnciNhc1aRrE1oEg9gHO2AbWuTD3qBOazA3YMGXPkgljx3JMSdjPA0mKoascgEZzt6x1aITqdnu4dNhTaDtgN8qpyZi+bDaSvXRpY5vRm14T9izWayls3wHDa2VWBVXSiKTbge3gYoKIBtTMnNEPYQ/hM3ibv0u8eIXRpdvTNljP9+WOPSb2y0dMcK7ZgnCMZ7CqJbM+Bk0rXye+WiuM+vQGe4E1grJMo7Ot7NtW+oWSadm8s+QeGELUhwk9Ol1zkbswNWON1mSCcFh3XnAyZzegzd1lqMCIBL57bnxm/trSrpPOQNICHjvQhd91H0A20XSXMQWOfVP6m8O0AMa9fwLM3GzWJhlZJhysvmRlZjHtV/gsq1/rqnMOGGj6GlWYDZ1ye59wBkwOPfJmOrTjQVgnrIi4GG7WhlKd2o4Ushvh3Bml7+S1uJq2b+DymcOydvSsqYRmG7N7vSvd+VsgeSbdn7DQ2nwY100B99kosRiOeID6wmQml+OIP6YJsSSrLgBtF+zwvWD4NMGg+DLCFeCusFQZE9JVbEPDATWHe4FGVXfKrR2uzK6Hhj3QSUOJzAOUdPKYIs+aDYgrqC3FRZtZdwFUFORxp9kfG4uhF3fVqXFCxM4PQMQv5PtuGzkrYvIxASp1+ZmIBWUB03C5R3HJ7IU/HE0IViOzJmSv3XpSmbf2S+fF+yZv1Jv8OJbtzF7n+0mKzM5tbXNVOlEI1ie7nC1zExWoVjE/XYOzaMToo10qzrW0PRf5VBRMX0i2rOZTHyJE9KTCHDoy/0DqfewdGX/HbB16P+yzY9r50J9fcR3YyPOPba/qtMEVs/Ovskng9U+br7THXQ17gr3x86oQRcDwzfv0ws/g+VgmNANpL72ra6TewLGmYWOiyam7jHJrfcY5V17E7Tdm4pqpLadui7ua6GShgm6c4iR/ppy80CJOYYnFfxqeZczor6O5Rear0J9C/ul1NCYeONaGOzZtq8xf4t3QrMmxhO5/4rPvwOBwUsqqf1apYuBAN3NNF1I36qfakZ6JlKqOg2O587HA=="
        let alert = try PushAlert.open(rust, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert, PushAlert(v: 1, m: Self.vectorLabel, p: 7, k: "claude", s: "waiting",
                                        msg: "Allow cargo test --release?", t: 1761512345.5))
        // enc (32 bytes) + 1024 bytes of plaintext + the 16-byte tag.
        XCTAssertEqual(Data(base64Encoded: rust)?.count, 32 + 1024 + 16)
    }

    func testWrongCollapseIDOrKeyFails() throws {
        XCTAssertThrowsError(try PushAlert.open(Self.vectorCiphertext, collapseID: "00000000000000000000000000000000",
                                                key: try vectorPrivateKey()))
        XCTAssertThrowsError(try PushAlert.open(Self.vectorCiphertext, collapseID: Self.vectorCollapse,
                                                key: Curve25519.KeyAgreement.PrivateKey()))
        XCTAssertThrowsError(try PushAlert.open("AAAA", collapseID: Self.vectorCollapse, key: try vectorPrivateKey()))
    }

    func testSealRoundTrips() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let alert = PushAlert(v: 1, m: "label", p: 3, k: "codex", s: "done", msg: nil, t: nil)
        let sealed = try PushAlert.seal(alert, collapseID: "abc", to: key.publicKey)
        XCTAssertEqual(try PushAlert.open(sealed, collapseID: "abc", key: key), alert)
    }

    func testLabelRoundTrips() {
        let id = UUID()
        let label = PushLabel.make(machine: id, name: "big boy")
        XCTAssertEqual(PushLabel.parse(label)?.machine, id)
        XCTAssertEqual(PushLabel.parse(label)?.name, "big boy")
        XCTAssertNil(PushLabel.parse("nonsense"))
    }

    func testAlertText() {
        XCTAssertEqual(AlertText.title(kind: "claude", state: "waiting", machine: "devbox"), "Claude is waiting on devbox")
        XCTAssertEqual(AlertText.title(kind: "codex", state: "error", machine: "imac"), "Codex hit an error on imac")
        XCTAssertEqual(AlertText.title(kind: "claude", state: "done", machine: "imac"), "Claude finished on imac")
    }

    /// What the notification service extension shows for the relay's notification.
    func testDecryptsNotificationContent() throws {
        let content = UNMutableNotificationContent()
        content.title = "Clotho"
        content.body = "An agent needs you"
        content.threadIdentifier = Self.vectorCollapse
        content.userInfo = ["aps": ["mutable-content": 1], "e": Self.vectorCiphertext]
        let out = try XCTUnwrap(PushAlert.decrypt(content, key: try vectorPrivateKey()))
        XCTAssertEqual(out.title, "Claude is waiting on devbox")
        XCTAssertEqual(out.body, "Allow cargo test --release?")
        XCTAssertEqual(out.threadIdentifier, "00000000-0000-0000-0000-00000000C10D")
        XCTAssertEqual(out.userInfo["machine"] as? String, "00000000-0000-0000-0000-00000000C10D")
        XCTAssertEqual((out.userInfo["pane"] as? NSNumber)?.uint64Value, 7)
        XCTAssertNil(out.userInfo["e"], "the ciphertext doesn't stay in the delivered notification")
        // A mismatched thread id (collapse id), no key, or no ciphertext leaves the generic content.
        content.threadIdentifier = "ffffffffffffffffffffffffffffffff"
        XCTAssertNil(PushAlert.decrypt(content, key: try vectorPrivateKey()))
        XCTAssertNil(PushAlert.decrypt(content, key: nil))
    }

    func testPushKeyPersists() throws {
        let first = try XCTUnwrap(PushKey.privateKey(create: true))
        XCTAssertEqual(PushKey.privateKey(create: false)?.rawRepresentation, first.rawRepresentation)
    }
}
