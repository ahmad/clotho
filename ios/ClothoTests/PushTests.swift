import ClothoKit
import CryptoKit
@testable import Clotho
import UserNotifications
import XCTest

/// The push alert format (docs/push.md). The fixed vector is shared with clothod's sender tests, so both
/// sides agree on HPKE, the collapse id and the plaintext.
final class PushTests: XCTestCase {
    static let vectorKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    static let vectorLabel = "00000000-0000-0000-0000-00000000C10D devbox"
    static let vectorCollapse = "2d85134107d287e04043e26b56beefb2"
    static let vectorCiphertext = "LaMPSZpg7wDeSa1yKp1q9SqiEIXggADLO+ezBn4U+ASwiLzAzxIW/mFiE3NZD9atex8F8qBz71MO52bkXdUDQicnz4HhbuiIsGs9wtoKFYzhZC3un764DD+Oia6eDSVNLpEq+dZ7MGzfC3zaIkHKhDDBk2Ut7/UdoR2JL8pThT1ZBuB3CSHZZ8AGF8gUdjpYzFZaVM6rrDRS25e7dlGvSQi/Y+vaakVJyA8yhPKEfksd9AZIwTNsu+huFFT2jzU="

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
        let rust = "7Nr1oOMC39SZcf90z0zGpw6evTVseUzsnkRUWv1Dz3GDqh2klG2lrOSWha+TcMj78vQjWJdV5OHK4XEpXTo5ri24K2/R/Ca6H+6hEMjL19aYfHwIY26pxFi+O4BQYdc7e/Gao2nYt8ZONGK9BnLADuzmSh3FhkrBoNIrE3zlefKhzUbE700B8hKzUGL5eorQ/vAEcJvPX29y1YNtaB5qjuIN25vsqRM25H9l54TJa58geXZqxyDDSWpPyyQcLB0="
        let alert = try PushAlert.open(rust, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert, PushAlert(v: 1, m: Self.vectorLabel, p: 7, k: "claude", s: "waiting",
                                        msg: "Allow cargo test --release?", t: 1761512345.5))
    }

    /// clothod pads every alert to 1024 bytes with a trailing "pad" key, so the relay and Apple can't tell
    /// message lengths apart; the app ignores the key. The vector is clothod's PADDED/CT_PADDED.
    func testOpensClothodPaddedVector() throws {
        let rust = "1os6Zx8iJ3Bc8mFS6jX808zzJa+FCOcYMMsicsVk+l7MeFf9SFSQ+BugL0LbWMK8BPSPbUwxMaEMx9vv+tk/keKCDSJzL2N9uzXaKV4wZBhWtWKeyA/VopbuU8AkiuIQBglHHl/3wUBzpkGSKRtnj1m21gToALLQrv0eY3p/dvnM3KxZIVQDk0ygbwbOU5DgU6nlc65g7W7fZ+swgcUVcKIsiKz8sZ5hau6FuIsWdAVZoA6BeXEa3MiDg6War2NkKsV6YXiy2GLbqLujaESWGiMh/vdwqE9mTQkZJmMqZ1hcT6FAqEKFm/I9OUkheONXTxvU+JpjNoqzQjRYmYuf7o+cUfb0y/n6pqNGapTX3Wo2tJZGrcZnHiA6Plh2LoOdOvtDYONZ2o8msQBLW3kbAKmXQhVrBPwmoCFmuACZ6L5l5hmrXhC6T9ryB3tF/7LFwGoHOA9OjNP9jxKXPpeOfVi0t8vYIXRPgK+U7WjOD/fmA7e9sw7f3aqfY8I6wbjyZzepxvG+Ihx4SP0UsaQmwUhcdv08FGn4X3hzwbzg8RU/SZpvD3MdeTG/6Vu2AgUwiwbGwlYZTejB8Lgbg39+VPbGgaRfQehTjST92xir5jHU6yEreM2kQMu+XyY4ZHNj8zq6idApk7l4hI5p4kgIj+4CSi//78VgAmCW7Cxd/NPHr43m07niXZyW2fuIUDgt9iPvSc4gSqhV4m3gme2VRzSgUC3KXDKiHmiOM+DAvBGe8subWB9vLioLM8zsuo3h/peIbHJ+Co8g0A48a2lb11GQXMp/qFNUZsHqGYiF8+Xry/AK/vy9Gy0/OkmmJO8yG3JU9wprvlE+4GMYxXO1RIPdP2Imka+Z1vIGDG+866pyLAKQNQIVubhladTr7mx8B95SzsqDP4DnHW9KGtXvZqYIrT5uqdUoQxW/u7D5DjRua3NSSaMyL4GgpqWtpBkxqiXiWCh4omqClpGgA435tQYcGZTSzDX8T6HqkAMRaUzIggy7leRMUtayWKNOFM8xD6GQk5SVU0edtsfkm/+q04T0nz0Qv3X0gTbrAMKbsvbJGJ0O/IbNgfZfSTmUfyypK5xD8vNjVbUtQUbfR9bnJKK/4h++ylYZG45+EM+Q2HCTqd/CkUd6PluHJmVi0mozOcE3VhMKO6ukB02YNLMYFeu+nAmPQnkjajXkUypD2Ez5iq0BMLA4OD9WQMbLsijHVOfqpkx/lhKz/xvg40YziXbr5OomxNGN7F7YmToZa1ki0M/2ywwTIuYH63TDXW4kl8VEJjDQAGQtVHvoA7mYK5VM8/pyGVyoRWV34wLCqKgXo9aNivxiaOnpzYkD4xmxzZY5vrVT9RfkEyEzR5oh+I81/T+jxmJ7ZbBtGP6QwJkifSYAzrpU3dsZ/W8k9L5JwM8Hz6tgARWg7jNxLUGuLA=="
        let alert = try PushAlert.open(rust, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
        XCTAssertEqual(alert, PushAlert(v: 1, m: Self.vectorLabel, p: 7, k: "claude", s: "waiting",
                                        msg: "Allow cargo test --release?", t: 1761512345.5))
        // enc (32 bytes) + 1024 bytes of plaintext + the 16-byte tag.
        XCTAssertEqual(Data(base64Encoded: rust)?.count, 32 + 1024 + 16)
    }

    /// clothod 0.1.13's FULL/CT_FULL: a done record with every detail field, padded to 1024, sealed by the
    /// Rust sender. Pins the record keys and the extension's text for them.
    func testOpensClothodFullVector() throws {
        let rust = "9opST3exXumrNqA5EzaDfCCQ9hFt7c7zvTyHThUFERC6Kn83TrqqibBRtQNa8KRf099Jr7nhaROwZffD9uF+qo6UJCfwZhRDvO+QuviILs0sXV4Pji5/+eAOaY00QI815TXpoRArqH9p65gJLiyU8O6Eytrcv9ePw9Cowfe9q1yF7JH04hkOIKq28Io+/2gpqRCP8RQWgvZ3I5wUXcuSTZqWCcW4iytVi7DywhrtnCythnT0l0+FR3760cnU9HdWgdIoqMurYiy9uDitrHsQaUrgOydHHTWV85qNrtp8oXkO0JmNCusqFMVad1LUZo600b8bPVprDdVlSiKx5rbfT30a7Gq7OJo67ZIas0kLOBas8j1PrmiqLMS8G1GKcB+9SyvIXXEGCGCK6OO4gptSgKAw5ZOhibTRLRZDGVzC/9EPRpz65k/JWhny9M2Ig1qpS77gu6QKcfW+AlT/PXaI3zL1k/pPnfCvSQL9KAGasKxRxWzEDpal7dhS3ieSbBL1FiDjxS8/Q8dYAMJa3Hg2r5C33GlISrXUiWqJzvah0+bxxUjGJMh0OxDRklZ6REPvsKkVqIcefWYRGRcz6T4763gsTqKU59fzZoXp5tTbzDbYM6nc6+YYdp1MPcsYqTu+HgmGW7R4Nbs6mNVSAsgMfDYydOmxFqVegPIZRDfjNoRxtgr0Y6LfBWEF3yOYbnqnFniimqyu4NzbkWqWOKw1d3HCT0sSPr9cP+TjNaCPXiPToFBHlDPhsvxUL1NioavtIl7P3V7xPxCE7eDlcwFmoHtmvHrhpA93TD60Q/TSFHu9rl6rhIIkR+fBw4pujQTtGd0/laDNZy/CLGznF9RNCaUKjN5FBanTsgf6F20J11d9EC+7G5AtOxQvop2OewGHr3+op+8v3XPMWyjhXmoQQvwA28nvajzAb4oNGd6BlreiTnu3pL2tawxRfUcej55eEty+gp++VeNeRsMDkmSfLSujmV1WffdHUtpPnYqO7w7iUC9MKs0ehUgwL5Q9bEE5YbgJkMj4KUqe3WfkLY5TWlp08cgp/im8PuZq1LRQqeOnCbTCC8WhlWBfSu468Y676YwSwDTm0xfAXoh3S4smP23Xbe4rUDInYOhqDh5pouO87OMpsuqdV8Y4NI/XUQecqZGO57Vph73tu8cnMna3Ksc3YjrO6zzb9q8enECHJkk0Mc4PGm/42ls/spaGUM9hAK4g8WgBNv6jAkZjhE8/TaHKBk9v7mjidjyC6CXZUn7ADexHvXs0Vef4DtnYLc9W5jWMXEGyKemOY0L8F2EABANJ9ObX485dYLxV7Dq5frE+MPAJR0nEZtmYH1I8Gae5bCL13DBpowzsLjvC0H6hMmRczdaX6IzjI1nX4Jc/qojn7crBf7K2KgSUJjBf3ZKqqsHK0AM/l2cmQ+VFtmBrEQ=="
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

    /// clothod's PERMISSION/CT_PERMISSION: a permission wait with its request id (`rq`), sealed by the
    /// Rust sender. The extension makes it an actionable alert: Allow/Deny category and the request to answer.
    func testOpensClothodPermissionVector() throws {
        let rust = "GO2U6qxLoSfGq56/pQlDPdcXC6pJtnjUBjnruelxeHZxNvOlIk4/0MmiOYevavq8+s2cs7dzeqV9hgTbCYdTX8kgf6TGyhpbHlerT7vzQA3IIDPlh5d3LXSwRYarSZ6UOtL2SGDU+HvMj2k72XpbaHu27shLXVi7mKb8DzC2V3wuEFm8jWKIQLI30k48olIzv46a34pAeOkxBeS3yThDIb6v4s+jlCSw2o9dNBmOmT40O/oU0VS7RPevdnWf39QjHn8HUWzltUCigV4sgN4/V02I1VDqiGNEOfSw3jOZNsv8UUuF+AZwYuxGfWOLex91CTs21kwIHNfEaPcESRLSecqgK4z+NZQuuYB7YL/5q3l0pyui+aF1Z1KzQssEPZopLLgCquQAHvYzEBfUqg2GTRz2qUTc28Z5jimEswO3AGTHz+Nmcx7mnjw7aLqZpUqjXAUYJk9Wsu2m6h6FIQj2sid2XVAtrB7gEK8PDjyWYhi5nIg9z+Kmfv158SOpwJHbRbLPRvSRQ563xKtZ6FULUIpuIBt9b9Deg38L0e/nM81x9RN3aCp4xaMNNKSrFLZ7xlmzomjrUrT0PHiRxoE6rx4h0C6uKJNnfYKvKlxmAUfIWXUuPzdlsPnM9jfh9bxxLhbu9YH1SmIfTD/53gegGSAaankmEiO9cIfB9FXTlEaAviMB6A2zQOQeZn1aZpadviRPgJeIJ/Abv22FhuWtCB4MF/c/Z/d01vOQGLvHqGYIkAqrBJ67UB/KuFde/owadwwZVYNmoMk8P9nt4gbU8Lf/J3g5wYVO2bEv8XregYBMHiVVgAXTb5dfMew/Rh0SFOBsrQwOBdK/lGUfse3DJPrYs95bd+qg2g/TxGjxowK1+tAc+elLeVC/XzW7GHxIfbQA4Hd/VTsbHgOhszt/X/Eq7Gm4+x5FEprXuEkFVSeODNv3CqObv5OChyK2+uLmH73HfbY4s/0C92sZ6UH1VRMpESvNvFkfgkyXR17FpuRa6k25fXrfNPxIWXsmyCGB9L4Q3Hi8vUEkkZd/o+5KjUmg+7qfcNpivTeNWbjVVb4+akgXOwvQ01/qCku4qMXLBbo4pfLlbmscPr9nYVFj4Pvw5W357d163SYTEusThclJtz0tk5nv/qqJQCcXJ8VxU5+pW1/n63L/eC7JUWoRc9b34jfMypWk4W2rL8Fg7mk1/yshIEBKjzZDyxO6HU6AbX9ixrXYGUJjDHVJKPZ95MOssxIbMa7X7B3GRe/wmzUW8GF+WeBTGPdDkCCmt6ugzAci7osqf5M+skfWo9iWbreTQWYSHiJdwKZN3qqORyxzvumONgopxQ8YZH2sINLorneaUrPCplLr9txQ9S23lmYGP74Yocny+AkhWe1X/ylgOBsU0YkW+nLf3h91SVvhduaVBdQaI0iIE4n9K04owQ=="
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

    /// clothod's NU_TRUE/CT_NU_TRUE and NU_FALSE/CT_NU_FALSE (push.rs): a done record with `nu`, padded to 1024
    /// bytes and sealed by the Rust sender. The plaintexts are clothod's, byte for byte.
    static let nuTrue = #"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"done","msg":"Both fixes are ready. Should I push them, or do you want to read the diff first?","t":1761512345.5,"q":"fix the flaky push test on macOS","pj":"clotho","tb":"clothod","w":"clotho","wid":3,"d":254,"nu":true,"pad":"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           "}"#
    static let ctNuTrue = "Dx3qmBHkrYzps9SKQuYVYsuIBJhO11enqxWxSjXHS2DmafmsPY9YgzURuM6WdkLYzWtz9KS0iYIJSwPfmAsarSx25k0E1GmWHU+NYxnvaQnMONLhTWQ3lnGhOOa2+uZPKHCQkDmG8qohNP1wah+piyNtzWcJ4vwlntHF2H/urb03fYn1/9ToF5QVcSGc4m7xiAKok2XT1hlFG5t7o/kfIniekFHxJlIcSPgNrYlz0Xwd83k7e4FHkdTqBL0RQFUlEaa7SgbbMxPG4Sv+Z+RKi3H1ibrzU5bmsFL/BUscYQV3d4BK2Mql5iPhTduiB4HJaWgUU3pkn+p2unczy/p/cR1Ok7PLXsvyNUUUDaSFbVSOTOOz3QZnPNxbkvO95Rkw/kg7mZqcmE0M/yaHrBWA8K7tZn/ZpRTF4qYvhrT1xqtqaf+CVo49dbKncdPc8yNsZ6r11h2c6lXp8NsH38aYDBgJYGZYigkYuq4kxB0nM2XlqhE1FF+V7TThSxIoIct0I7S3x+JjbxiKMYO9VxBqUZ3znqsQ2Z9Bz7OIeax1SBocESoDhFSpPsGdRV2VKQdvPF7DfHxLkjaGhi9EB3wV8fl+9eL+ZYuj4OqFfbrw2NfkA9abpwVq75gzQiuVuRyZiV0j1zzs+AEbtWOIBQMeiQbEwyQ0w0117DBKcQAEbYALnvF+eWGs95mazzvI+tqrWS1JUZdkzqTdG7PDaWDLgAi9tTBVI3B1J8VBl7565t12/0R5oRwNEyJjcowmtM/Vo8IDFpPhFP1wlIelgBA4K1rgwfwzZqN3ZRfdxfpmg3jfwUi0XCwxyolOV/gZYAdHLmtd9I4Bk60so8C8Z1KOEZN3/H3YWeKuJQXfNJofPjOn5LLsH0zG6pVR49cj1RmaCW92ix17KSdhLQMX7gFL0wShadtEAe+4hhwRiRmmrXy6EUGAtc0do+tpY7V4IQgAxTGH8jKsh9gweBAcZ21ZaP/yqbcXjrlZH5YW1HHPzZyrbmLTxcyDRsbwNCh4/H2hWGyr57UCDB0yQdF5DS62xwzJJjOXVg8U+EJDvvLAwY+Wm3+Y36CXqqxScWFaCvrVpT+oZv0TfM0jJXRKTSmjs5sVs9JmPzjqwXFtpypKUlLpEOxYv6I2V4PmPvQZnX6XkrDXqGCS47vw3W4kXQ6hKFAFf+kvAxmfQKakzysgQ7qVyL00SmFVovdNp7JU9BTcFLb0hCsCl2HmYQSf26AbGkBg63IpkxjfMx4Y3g7sCe7w9IxQgNZbfOOdrBmaP6hEkYlq9luI2G84Rib67hi+65Qqv4r9gFHk5m21i5bY25+UgdTXwqsz9v68ZBR/0OVPrFi5zFd5W4oXnnGl0mPvkcbEGxyUaYv8fMb9ulVbZlbbUG+lpyvT6Pytbq0BlWmBk4lTf1cVySOlKkVLnqj3Dg=="
    static let nuFalse = #"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"done","msg":"All 61 tests pass. I fixed the flaky timing test by measuring from the report instead of the first delivery.","t":1761512345.5,"q":"fix the flaky push test on macOS","pj":"clotho","tb":"clothod","w":"clotho","wid":3,"d":254,"nu":false,"pad":"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              "}"#
    static let ctNuFalse = "AYfkADlh+MiCzsIrrzGqBccHN5eNWxlsaDP6y8ygEH4KIXwNUO5M8Hlof0t+fm7mQwg80GPcId9ZJeo4DB1n22tNlG8xlWepFDLaqKrwsifcK32rkKul5dl9KhXj8FwfKM023+fcum9M2+zg2wFJpAmbbP9QeXSxCWrRPmIaFPL6WpHaWGyfshSRNJjOL4gEd6oRCIWcyR739iQaB0ZIfdC11Etlu3L60uIxvkTTlzDKHEr5aXZ9PDWOamOp7eaIWF877EcaF03ZTOXbWhWUBoXQsWpb6yjtxOD1cMkCJWZfZqBhc7WzE/vMTPCA4K9x+oInMsrvqku3l2CIQSMpAkTg80OrEYcrgI696XbbyUfbXu206ENIhUY6Wxm4x0SeL2p5ynbU6dA8x4NQQpEbs2yNQ2yFjCPD89V6FZ4FVuIXRzOEGbyshIGzGedU3xduvFmwp/AznJl5p+KQX9lN3EbDqy+RhSV/ntNN3jKQ7NyRMxQU/9iDnOThisUnuRy2iUN+fCjJNxYZG1xuKpmHe/GFVq+BlV8+5pZFwtW7Q2G777vhtsZ/F4v7URhrK/Tli3g8w2bRr8o/o8mrqyRLWkgt2QqdBEkipBnDIucKabZIKOPHnBHkVJnk5inXdFAMHtWG4eahFv2Dc9TXMiOHTHpQKeXBEZuy8OEr8dKtaYJzt2PQA/zv3PA8kt9XL3CcQYUVXR9YehVvzVDJGOPy+6jpZlWs7tNv4SRlcXisP2iY5SAS0MS+Bn3Y+M+iG+EQDMarfTNdvVYX56mUByLUPixcHMBGIjGDu8UBnghMRW/oQfdwySAb8bV3I/1yD+10uEFKesFtU3NtelDlatrxRT7oLQYBPR7dG4x5UbtqtYfwqaAn8x+MEBBxVmunQ5Ft1phRsVcX8HcSoJ0aYS6TuV+KrsHV7ZQng9IcuoYJKOSeF/PgrIaBHPCX5xC27i+gXL4QmFyl/EL/+ZucCT7gY8QWiTKopkELy5i+kshNK/ARCmbBBLtQA2bdjoebmxVAEXx+cl7pah9wCsQ6QAby7v84kuZlABUckRC0Epa9vp74sVVQu7IUvpeuWGOdCusOCavvAQKgaBoW9toQr0Q4jIzpPH5GhyekixlWdEc97rCOzdFqxphRDcB2Qx91lQZnU1CtRrbbsa2j9MeECgBsq/ZfJYeTcp8je0gV+RShJRaQdHLR4+StrF3IfyHFqyGXs54YO6WcfPbD5zng8sLsvZvssOiT0Sv46LrevWcyxYUwbS8XVHLJ92Rb89RjtGNQijf8jJAud511PkKbIJMbUkUgxatB+0h6pVBAx3D3IWXt2arqG3OgZfh7H1t+g8YPSxGHKlAXVf9MI7ppnxO8QurOJ4PLtjZaL9Wdw7IsvdkV8XUx3XsDe3YajCk/w2vG2b1aLebkx0tLT3u0us9TqQ=="

    /// The sealed `nu` vectors open to exactly clothod's bytes, 1024 of them, only under the right collapse id,
    /// and decode to a done record with `nu` true and false.
    func testOpensClothodNeedsUserVectors() throws {
        for (name, plain, sealed, nu) in [("NU_TRUE", Self.nuTrue, Self.ctNuTrue, true), ("NU_FALSE", Self.nuFalse, Self.ctNuFalse, false)] {
            XCTAssertEqual(Data(base64Encoded: sealed)?.count, 32 + 1024 + 16, name)
            let opened = try PushAlert.openData(sealed, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
            XCTAssertEqual(opened.count, 1024, name)
            XCTAssertEqual(opened, Data(plain.utf8), name)
            XCTAssertThrowsError(try PushAlert.openData(sealed, collapseID: "00000000000000000000000000000000",
                                                        key: try vectorPrivateKey()), "\(name): wrong associated data")
            XCTAssertThrowsError(try PushAlert.open(sealed, collapseID: "00000000000000000000000000000000",
                                                    key: try vectorPrivateKey()), "\(name): wrong associated data")
            let alert = try PushAlert.open(sealed, collapseID: Self.vectorCollapse, key: try vectorPrivateKey())
            XCTAssertEqual(alert.s, "done", name)
            XCTAssertEqual(alert.nu, nu, name)
            XCTAssertEqual(alert.m, Self.vectorLabel, name)
            XCTAssertEqual(alert.p, 7, name)
            XCTAssertEqual(alert.tb, "clothod", name)

            let content = UNMutableNotificationContent()
            content.threadIdentifier = Self.vectorCollapse
            content.userInfo = ["e": sealed]
            let out = try XCTUnwrap(PushAlert.decrypt(content, key: try vectorPrivateKey()), name)
            XCTAssertEqual(out.title, nu ? "Needs you · clotho › clothod" : "Done · clotho › clothod", name)
            XCTAssertEqual(out.categoryIdentifier, AlertActions.replyCategory, name)
        }
    }

    private func delivered(_ alert: PushAlert) throws -> UNNotificationContent {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let collapse = PushLabel.collapseID(label: alert.m, pane: alert.p)
        let content = UNMutableNotificationContent()
        content.threadIdentifier = collapse
        content.userInfo = ["e": try PushAlert.seal(alert, collapseID: collapse, to: key.publicKey)]
        return try XCTUnwrap(PushAlert.decrypt(content, key: key))
    }

    static let markdown = "## Done\n\nI fixed **the flaky test** in `push.rs`:\n\n- measure from the report\n- [docs](https://example.com/push)"

    /// clothod 0.1.29's `sm`, a small model's summary of the message, is the body when it's there; without it
    /// the message shows as plain text, never raw Markdown.
    func testSummaryOrPlainMessageIsTheBody() throws {
        var alert = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: "done", msg: Self.markdown, w: "clotho",
                              sm: "Fixed the flaky push test.")
        XCTAssertEqual(try delivered(alert).body, "Fixed the flaky push test.")

        alert.sm = nil
        let body = try delivered(alert).body
        for raw in ["##", "**", "`", "](", "- measure"] { XCTAssertFalse(body.contains(raw), "raw Markdown \(raw) in \(body)") }
        XCTAssertTrue(body.contains("the flaky test"), body)
        XCTAssertTrue(body.contains("push.rs"), body)
    }

    /// A permission ask always shows the exact tool and command the user approves, summary or not.
    func testPermissionAskKeepsToolAndCommandWithASummary() throws {
        let alert = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: "waiting", msg: "Claude needs your permission to use Bash",
                              w: "clotho", tool: "Bash", cmd: "rm -rf build && npm test", rq: "87b99bd3910be450",
                              sm: "Wants to clean the build and run the tests.")
        let out = try delivered(alert)
        XCTAssertTrue(out.body.hasPrefix("Allow Bash: rm -rf build && npm test?"), out.body)
        XCTAssertTrue(out.body.contains("Wants to clean the build"), out.body)
        XCTAssertEqual(out.categoryIdentifier, AlertActions.permissionCategory)

        // A command long enough to fill the body is never cut; the summary gives way.
        let long = String(repeating: "x", count: 230)
        var big = alert
        big.cmd = long
        XCTAssertTrue(try delivered(big).body.hasPrefix("Allow Bash: \(long)?"))
    }

    /// The extension has about 30 seconds and 24 MB: a full record with a Markdown message (the largest it gets)
    /// decrypts and renders in milliseconds, with nothing loaded beyond the record.
    func testExtensionWorkStaysSmall() throws {
        let msg = String((Self.markdown + "\n\n" + String(repeating: "**word** `code` ", count: 40)).utf8.prefix(400))!
        let alert = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: "done", msg: msg, w: "clotho", tb: "tab", pj: "clotho",
                              q: "fix it", d: 254, sm: String(repeating: "Short summary. ", count: 8))
        let key = Curve25519.KeyAgreement.PrivateKey()
        let collapse = PushLabel.collapseID(label: alert.m, pane: alert.p)
        let content = UNMutableNotificationContent()
        content.threadIdentifier = collapse
        content.userInfo = ["e": try PushAlert.seal(alert, collapseID: collapse, to: key.publicKey)]
        var noSummary = alert
        noSummary.sm = nil
        let plainContent = UNMutableNotificationContent()
        plainContent.threadIdentifier = collapse
        plainContent.userInfo = ["e": try PushAlert.seal(noSummary, collapseID: collapse, to: key.publicKey)]
        let start = Date()
        for _ in 0..<50 {
            XCTAssertNotNil(PushAlert.decrypt(content, key: key))
            XCTAssertNotNil(PushAlert.decrypt(plainContent, key: key))
        }
        let each = Date().timeIntervalSince(start) / 100
        XCTAssertLessThan(each, 0.05, "one alert took \(each) s")
        print("extension: one alert in \(String(format: "%.2f", each * 1000)) ms")
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

    /// clothod's `nu` (the agent's `needs_user`) survives the record, true and false; a record without it
    /// encodes no key, so it's what an older daemon sends.
    func testNeedsUserRoundTrips() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        for nu in [true, false] {
            let alert = PushAlert(m: "label", p: 3, k: "claude", s: "done", w: "W", tb: "T", nu: nu)
            let sealed = try PushAlert.seal(alert, collapseID: "abc", to: key.publicKey)
            XCTAssertEqual(try PushAlert.open(sealed, collapseID: "abc", key: key).nu, nu)
        }
        let old = try JSONEncoder().encode(PushAlert(m: "label", p: 3, k: "claude", s: "done"))
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("\"nu\""))
        XCTAssertNil(try JSONDecoder().decode(PushAlert.self, from: old).nu)
    }

    /// With `nu` and a workspace the title says first whether the user has to act, then where.
    func testTitleWithNeedsUser() throws {
        func alert(_ state: String, _ nu: Bool?, w: String? = "W", tb: String? = "T") -> PushAlert {
            PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: state, msg: "All tests pass.", w: w, tb: tb, nu: nu)
        }
        for state in ["waiting", "error", "done"] {
            XCTAssertEqual(try delivered(alert(state, true)).title, "Needs you · W › T", state)
        }
        // A waiting or failed agent needs the user whatever the flag says.
        XCTAssertEqual(try delivered(alert("waiting", false)).title, "Needs you · W › T")
        XCTAssertEqual(try delivered(alert("error", false)).title, "Needs you · W › T")
        XCTAssertEqual(try delivered(alert("done", false)).title, "Done · W › T")
        // No tab.
        XCTAssertEqual(try delivered(alert("done", false, tb: nil)).title, "Done · W")
        XCTAssertEqual(try delivered(alert("waiting", true, tb: "")).title, "Needs you · W")
        // No workspace: AgentNotice's title, with its wording for the flag.
        for (state, nu) in [("waiting", true), ("done", false)] {
            let record = alert(state, nu, w: nil)
            XCTAssertEqual(try delivered(record).title, record.notice(machine: "devbox").title)
            XCTAssertEqual(try delivered(alert(state, nu, w: "")).title, record.notice(machine: "devbox").title)
        }
        XCTAssertEqual(try delivered(alert("done", false, w: nil)).title, "Claude is done on devbox")
        // No `nu` (an older daemon): exactly as before.
        XCTAssertEqual(try delivered(alert("done", nil)).title, "W · Claude finished")
        XCTAssertEqual(try delivered(alert("waiting", nil)).title, "W · Claude is waiting")
        // The subtitle and body stay AgentNotice's.
        let out = try delivered(alert("done", false))
        XCTAssertEqual(out.subtitle, alert("done", false).notice(machine: "devbox").subtitle)
        XCTAssertEqual(out.body, "All tests pass.")
    }

    /// The title for states a push doesn't carry, as `apply` sets it: ClothoKit's place title when there is
    /// one, else the notice's own. Anything but waiting, error and done keeps the notice's unless the user
    /// has to act.
    func testApplySetsTheTitle() {
        func applied(_ state: String, _ nu: Bool?, w: String? = "W", tb: String? = "T") -> (title: String, notice: AgentNotice) {
            let notice = PushAlert(m: "x", p: 1, k: "claude", s: state, w: w, nu: nu).notice(machine: "devbox")
            let content = UNMutableNotificationContent()
            AlertText.apply(notice, state: state, needsUser: nu, workspace: w, tab: tb, to: content)
            XCTAssertEqual(content.subtitle, notice.subtitle)
            XCTAssertEqual(content.body, notice.body)
            return (content.title, notice)
        }
        XCTAssertEqual(applied("running", false).title, applied("running", false).notice.title)
        XCTAssertEqual(applied("running", true).title, "Needs you · W › T")
        XCTAssertEqual(applied("done", nil).title, applied("done", nil).notice.title)
        XCTAssertEqual(applied("done", nil).title, "W · Claude finished")
        XCTAssertEqual(applied("done", false).title, "Done · W › T")
        XCTAssertEqual(applied("done", false, tb: nil).title, "Done · W")
        XCTAssertEqual(applied("error", false, tb: "").title, "Needs you · W")
        XCTAssertEqual(applied("waiting", true, w: nil).title, applied("waiting", true, w: nil).notice.title)
        XCTAssertEqual(applied("waiting", true, w: "").title, applied("waiting", true, w: "").notice.title)
    }

    /// Since clothod 0.1.33 `tb` is always there, the Tab's title as the apps show it (a pane title or folder
    /// for a Tab without a name), so the title always names the Tab. An older daemon's record may have none.
    func testTitleNamesTheTab() throws {
        var alert = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: "waiting", msg: "Which database?", w: "W", tb: "T", nu: true)
        XCTAssertEqual(try delivered(alert).title, "Needs you · W › T")
        alert.tb = "api-server"
        XCTAssertEqual(try delivered(alert).title, "Needs you · W › api-server")
        alert.s = "done"; alert.nu = false
        XCTAssertEqual(try delivered(alert).title, "Done · W › api-server")
        alert.tb = nil
        XCTAssertEqual(try delivered(alert).title, "Done · W", "an older daemon, a Tab without a name")
    }

    /// Reply only where a reply can go. The record has no source, so the kind stands in: a coding agent takes
    /// one; a script's kind and "other" (a program's notification) don't. A permission request keeps Allow and Deny.
    func testReplyOnlyForCodingAgents() throws {
        func category(_ kind: String, _ state: String, rq: String? = nil) throws -> String {
            try delivered(PushAlert(m: Self.vectorLabel, p: 7, k: kind, s: state, msg: "x", w: "W", tb: "T", rq: rq, nu: true)).categoryIdentifier
        }
        for kind in ["claude", "gemini", "codex", "copilot"] {
            XCTAssertEqual(try category(kind, "done"), AlertActions.replyCategory, kind)
            XCTAssertEqual(try category(kind, "waiting"), AlertActions.replyCategory, kind)
            XCTAssertEqual(try category(kind, "error"), "", kind)
        }
        for kind in ["deploy", "other", "", "nightly.backup"] {
            XCTAssertEqual(try category(kind, "done"), "", kind)
            XCTAssertEqual(try category(kind, "waiting"), "", kind)
            XCTAssertEqual(try category(kind, "error"), "", kind)
            XCTAssertEqual(try category(kind, "waiting", rq: "87b99bd3910be450"), AlertActions.permissionCategory, kind)
        }
        XCTAssertEqual(try category("claude", "waiting", rq: "87b99bd3910be450"), AlertActions.permissionCategory)
    }

    /// A record whose kind isn't a coding agent carries any program's text: it shows as typed (no Markdown is
    /// read) and `msg` goes before `sm`, which for such text is only a Markdown-stripped copy. A coding agent's
    /// record is Markdown, as before: `sm` first, else `msg` cleaned.
    func testOtherKindsShowTheirTextAsTyped() throws {
        let typed = "build **failed**:\t`make` exited 2 [log](x)"
        for kind in ["other", "deploy", ""] {
            var alert = PushAlert(m: Self.vectorLabel, p: 7, k: kind, s: "error", msg: typed, w: "W", tb: "T",
                                  sm: "build failed: make exited 2 log", nu: true)
            XCTAssertEqual(try delivered(alert).body, "build **failed**: `make` exited 2 [log](x)", kind)
            alert.msg = nil
            XCTAssertEqual(try delivered(alert).body, "build failed: make exited 2 log", "\(kind): the summary when there is no message")
            // Nothing reads as a permission ask.
            alert.msg = "needs permission"; alert.s = "waiting"; alert.tool = "Bash"; alert.cmd = "ls"
            XCTAssertEqual(try delivered(alert).body, "needs permission", kind)
        }
        XCTAssertEqual(try delivered(PushAlert(m: Self.vectorLabel, p: 7, k: "deploy", s: "done", msg: "ok", w: "W", tb: "T", nu: false)).subtitle, "devbox")
        XCTAssertEqual(PushAlert(m: "x", p: 1, k: "deploy", s: "done").notice(machine: "devbox").title, "deploy finished on devbox")
        XCTAssertEqual(PushAlert(m: "x", p: 1, k: "other", s: "done").notice(machine: "devbox").title, "Agent finished on devbox")

        var claude = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: "done", msg: typed, w: "W", tb: "T",
                               sm: "The build failed.", nu: true)
        XCTAssertEqual(try delivered(claude).body, "The build failed.")
        claude.sm = nil
        let body = try delivered(claude).body
        for raw in ["**", "`", "]("] { XCTAssertFalse(body.contains(raw), "raw Markdown \(raw) in \(body)") }
        XCTAssertTrue(body.contains("failed"), body)
    }

    /// A turn that just finished with nothing for the user to do arrives silently; everything else keeps the
    /// sound the relay sent.
    func testPlainDoneIsSilent() throws {
        func sound(_ state: String, _ nu: Bool?) throws -> UNNotificationSound? {
            let alert = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: state, w: "W", tb: "T", nu: nu)
            let key = Curve25519.KeyAgreement.PrivateKey()
            let collapse = PushLabel.collapseID(label: alert.m, pane: alert.p)
            let content = UNMutableNotificationContent()
            content.sound = .default
            content.threadIdentifier = collapse
            content.userInfo = ["e": try PushAlert.seal(alert, collapseID: collapse, to: key.publicKey)]
            return try XCTUnwrap(PushAlert.decrypt(content, key: key)).sound
        }
        XCTAssertNil(try sound("done", false))
        XCTAssertNotNil(try sound("done", true))
        XCTAssertNotNil(try sound("done", nil), "an older daemon's done alert sounds as before")
        XCTAssertNotNil(try sound("waiting", false))
        XCTAssertNotNil(try sound("waiting", true))
        XCTAssertNotNil(try sound("error", false))
    }

    /// A permission ask with `nu`: the new title, and still the exact ask with its Allow and Deny actions.
    func testPermissionAskWithNeedsUser() throws {
        let alert = PushAlert(m: Self.vectorLabel, p: 7, k: "claude", s: "waiting", msg: "Claude needs your permission to use Bash",
                              w: "Platform", tb: "cargo test", tool: "Bash", cmd: "npm test", rq: "87b99bd3910be450", nu: true)
        let out = try delivered(alert)
        XCTAssertEqual(out.title, "Needs you · Platform › cargo test")
        XCTAssertEqual(out.body, "Allow Bash: npm test?")
        XCTAssertEqual(out.categoryIdentifier, AlertActions.permissionCategory)
        XCTAssertEqual(out.userInfo["request"] as? String, "87b99bd3910be450")
    }

    func testLabelRoundTrips() {
        let id = UUID()
        let label = PushLabel.make(machine: id, name: "dev box")
        XCTAssertEqual(PushLabel.parse(label)?.machine, id)
        XCTAssertEqual(PushLabel.parse(label)?.name, "dev box")
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
