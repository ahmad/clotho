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

    /// clothod 0.1.13's FULL/CT_FULL: a done record with every detail field, padded to 1024, sealed by the
    /// Rust sender. Pins the record keys and the extension's text for them.
    func testOpensClothodFullVector() throws {
        let rust = "KxD6ecRzxhwdb8a8kQcn1HJxe06PVDr0jPkrw1AEjga5wOWPrCWNc5qyxqJ+lsXrI7SA0wNVuQu/in3JHvk3noKJbNfkv/8vSZ8/WW384OUMBgNJ2ty1NyH0XqR0KfV0nbo/2ZwEOzKdPcaZXb+bxF0Q11LFd4OEQVDg86qZTihbonRnCwYr96K/GjhDXpI/d9thuhi4UESO9jZMh3getSVp+aE6qAUNe+ye01LhSYn+Bk26fTbXlaRIM4/0NCmgNs2ARYS3i8ga4SlHiIzfcn9TktUdbxKlT6TTf3pFn+b8KT6SHS1UV4sNCV8H/NHUG8Tg3/MlhoVm+naQuCjMsH8EhpYaWNJBHs5M7KdzaOkgvCPLRbSy0xyP0Gf4v3uJb2FRry8qElK9F1HUoEEGKG5e1Vk6koOhqaC5lMNN91ess/5bNQvUHfE7tU5I+JAXHRrs1lhweWWUfpKMfDH+PQiA9CutRG/2xAk5smyQGvVY9n4/BRJsVnLmkj56cDT/PPRad6uTu2a8N1gZkXqQX/gUxUh3E7mAdLxk1HANFgke899K8yCKvGSxk58qygdzn9tBxOyXyD6+pYLsPHktZGhaCT7WtXr58RHdBXYjoYv91HazhfWd1Zb7r02zBw4tjEMuz/t6vk1X0Pbr71rWRlm8vsvDSgVrOuTInrkuIhipVp1TqBI3UZYiMwTF09RdPYJdxTZjMWdzbX7LQtaCgl6sOQ0wUuQlKM+x936kynYd1YzVS3Qu0aCTVCRRTrX5i9EnDvX0H3QB4OAbiwBdRtvrxa11p/GQ1lmAKYUY4AjgoT+F9555gCqDAIAh/mhiEaW0NafPWirKRZyxnt6heh0VXSEsunyHS7Xwab7uOR7UgssBND893fTxI1TZNbjVtdsjOe5bUd5zoJAsspqRXMys0gylgG8IAnfJObGhUFbuqr0r+eRn7A79FLOynhofadfN/BotO2Y2kUUYVOf5PJmr31M6EvggN3D0vW0tiufnhvG9XS5S06WQNpuansEtgsXYyXcNVoVzNJGx+fIorzTVdfpQLD7ZwOyynXr0hwDF58qS5jAb9AkCcufxQZpvUM2l5K2i/bQTB+R/or5X9cdp2cqNbUlOwj4fTTfHAPYElDHU+y1aUZObnjfkOntr0U3ILIIp5FcV7zOJrbgpeqolQIvUMbTb9jmexng2JVIxduxnEFhyG0herCshLkgSGypxJcl/Ljsj8Xd7KZ9CqgpOhC67+HcViQJb5OYK6FxfbikXGO1wssEqDn8ePL7eOI3SdfhdDMiHKknavr2alPRdVxy10LXufYjoLlmnouLkQNID4AaBghhKW0NAJCvE8Kx8AbbC4alLlKtH3470EcEMSJ4Nc9yUmkwrgXp6QUUNw8Ka8rbNifdBgMIIddCRGQLHBvp6iA5iZVnxvPRteQ=="
        let alert = try PushAlert.open(rust, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert, PushAlert(v: 1, m: Self.vectorLabel, p: 7, k: "claude", s: "done",
                                        msg: "All 61 tests pass. I fixed the flaky timing test by measuring from the report instead of the first delivery.",
                                        t: 1761512345.5, w: "clotho", wid: 3, tb: "clothod", pj: "clotho",
                                        q: "fix the flaky push test on macOS", d: 254))
        XCTAssertEqual(Data(base64Encoded: rust)?.count, 32 + 1024 + 16)

        let content = UNMutableNotificationContent()
        content.threadIdentifier = Self.vectorCollapse
        content.userInfo = ["e": rust]
        let out = try XCTUnwrap(PushAlert.decrypt(content, key: try vectorPrivateKey()))
        XCTAssertEqual(out.title, "clotho · Claude finished")
        XCTAssertEqual(out.subtitle, "devbox · clotho · 4m")
        XCTAssertEqual(out.body, "All 61 tests pass. I fixed the flaky timing test by measuring from the report instead of the first delivery.")
        XCTAssertEqual(out.threadIdentifier, "00000000-0000-0000-0000-00000000C10D/3")
    }

    /// clothod's PERMISSION/CT_PERMISSION (62a4c25): a permission wait with its request id (`rq`), sealed by the
    /// Rust sender. The extension makes it an actionable alert: Allow/Deny category and the request to answer.
    func testOpensClothodPermissionVector() throws {
        let rust = "Dsqpft9hJJTBD35nK1YON/fVtbJtptM3zZyUgxK7oml/myC4D7uWlwKzOMz+re6cuJr7sh+J3AVM9PpyoY1HYy5al79dy7tx8I+vzuTRNVBRu2P/YrYl0Q3HVSI74wRZtpL4Mw/70cFax41RKh7WxaU65zaBkybJQ5wJ7hlPHIfR7fylsZabQVzNqJKAXdl9IbCcoOy12lz+M7ofd3GQueaV3qpq7YwGkZQ45eg7u8yEcjkp4lEuADb6b7NKlaRH8DH1pgTBi3+/r73UWmTN4E1z969bGPsT1SGXohSgv01XURUgR+gw16adaaGfETT65lKd/n17Qlt9hOfLG4qlw7llWVHfYtLYGuw02ZAWmaOAnEqpz7dSBpv9lyesF10JKWg76EEJcnkcsaxqVwJilZVPZzuxx72xXzyd6jLzDgtpzyufo0KU9lbt/o/aEJtU9hcnxI95+UTrBG19+cOSqgibXViL6sLy2QIl/C92oYKrr85ZiKxzITv28XUG1UpDKyvCtWDdkXS3u4n2bkJq5YNP4eQMuducPV09/ew5iXbk5CzvKcyn+opBt2Va/LBecH8V4n+nplYvQqJVZPuL+ttUg19dMrHA5Hr8uePHCz9pWLxvwIVw3aAEd/aGbWcPdgAkeZV7SVJ4AeEZIEa+HqLq1Gyq5XhF7I6GX2gHvQT94J73SohuuHLoSMBhpD4+X/iiGuCRC1tU8GhBOa2pqsp3Zic5iBlUFpMrIl52Og508pBUY6VXlzShkpQhmzlkptiZgDe3u8OSt9mWEK1lXb8RDHWdSIm0QgHzjs5CQhn9Ina8zfcAXpTKBNq+AcIdmZvMfChlelmwNyzB78ArWp03psmwsmSAdPYZHi36Zz4bCVRUbnlUJZLXKdRcqhACiyWYlLxrGbyrVtCB43DAi7opBRfi9Nf+WeQkK5Sw80rj+UHY4MN6IUu6q9bQ+/bAORwhKlQYttTYiLADk0Sp4kk3qfBOAZ37SKJrpBdqatbtQ5rnOPJj6TaO7/gV1tb+IZGsW/9rwBXWL5XNFs8ixR096Nl0BzGb5x3jUAG2bu/Tj8Kywq87XXVJAzsO0LPQWJObYLcMHIPwKKq4SZtN7E+mm7bH/JrV4GUCUIrrV1bhH+oR9YHAGCuJHb0R4hb56QSKKHBKhGZwJYsHbJ3DxAJ+LOB+sFmP3Ux67jDgZjat/BpFGowIlhntfz3eUZ3zkK0Oxx8X0/XPBnk5eWlNjaLPk2Zp53LNd8Y/wIsotVQkJ1UiGG2ueZaiRktasoiow0vGjnZVApG7dH9cyuLv1yPNvQXLhRoR26LGxcitb0ofdkMQUqDx5RpRXadnnz+crfoNZ8E5jXElC3U235Hs8sYEnZBT0ktEZuqkuk4VpaguDXgkHHXwBHk4yUJWj48sd9L890tMCsgAJR4SSgwU1A=="
        let alert = try PushAlert.open(rust, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert.rq, "87b99bd3910be450")
        XCTAssertEqual(alert.s, "waiting")
        XCTAssertEqual(alert.tool, "Bash")
        XCTAssertEqual(alert.cmd, "date > /tmp/clotho-phone-test.txt")

        let content = UNMutableNotificationContent()
        content.threadIdentifier = Self.vectorCollapse
        content.userInfo = ["e": rust]
        let out = try XCTUnwrap(PushAlert.decrypt(content, key: try vectorPrivateKey()))
        XCTAssertEqual(out.categoryIdentifier, AlertActions.permissionCategory)
        XCTAssertEqual(out.userInfo["request"] as? String, "87b99bd3910be450")
        XCTAssertEqual(out.title, "clotho · Claude is waiting")
        XCTAssertEqual(out.body, "Allow Bash: date > /tmp/clotho-phone-test.txt?")
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

    /// An older daemon's record (no detail fields): today's titles, with the machine in them.
    func testOlderRecordTitles() {
        func title(_ kind: String, _ state: String, _ machine: String) -> String {
            PushAlert(m: "x", p: 1, k: kind, s: state).notice(machine: machine).title
        }
        XCTAssertEqual(title("claude", "waiting", "devbox"), "Claude is waiting on devbox")
        XCTAssertEqual(title("codex", "error", "imac"), "Codex hit an error on imac")
        XCTAssertEqual(title("claude", "done", "imac"), "Claude finished on imac")
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
