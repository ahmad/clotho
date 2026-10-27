import CryptoKit
import Foundation
import Security
import UserNotifications

// Shared by the app and the notification service extension (docs/push.md): the phone's push key, the
// encrypted alert machines send, and how an alert reads.

/// The X25519 key machines encrypt alerts to. Made once, kept in the Keychain group the app shares with
/// the extension, readable after first unlock (alerts arrive while the phone is locked), never synced.
enum PushKey {
    static let accessGroup = "TEAMID0000.nyc.amin.clotho.shared"
    private static let service = "nyc.amin.clotho.push-key"
    private static let account = "x25519"

    static func privateKey(create: Bool) -> Curve25519.KeyAgreement.PrivateKey? {
        if let data = read(group: accessGroup) ?? read(group: nil) {
            return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        guard create else { return nil }
        let key = Curve25519.KeyAgreement.PrivateKey()
        // Without the shared group (a build without the push entitlements) the app keeps the key alone,
        // and alerts show their generic text.
        guard store(key.rawRepresentation, group: accessGroup) || store(key.rawRepresentation, group: nil) else { return nil }
        return key
    }

    private static func query(group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func read(group: String?) -> Data? {
        var q = query(group: group)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func store(_ data: Data, group: String?) -> Bool {
        var item = query(group: group)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// What a machine encrypts into an alert: `{"v":1, "m", "p", "k", "s", "msg", "t"}`.
struct PushAlert: Codable, Equatable, Sendable {
    var v: Int
    /// The label the app registered with (`PushLabel`).
    var m: String
    var p: UInt64
    var k: String
    var s: String
    var msg: String?
    var t: Double?

    static let info = Data("clotho push v1".utf8)
    static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .chaChaPoly)
    /// X25519's encapsulated key, in front of the ciphertext.
    static let encLength = 32

    /// Opens `base64(enc || ct)`; the collapse id is the associated data.
    static func open(_ ciphertext: String, collapseID: String, key: Curve25519.KeyAgreement.PrivateKey) throws -> PushAlert {
        guard let data = Data(base64Encoded: ciphertext), data.count > encLength else { throw CocoaError(.coderInvalidValue) }
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info,
                                           encapsulatedKey: data.prefix(encLength))
        let plain = try recipient.open(data.dropFirst(encLength), authenticating: Data(collapseID.utf8))
        return try JSONDecoder().decode(PushAlert.self, from: plain)
    }

    /// The notification as it should show: the relay's generic content with the alert's text, grouped by
    /// machine and routed to the pane on tap like the app's own notifications. Nil if it can't be opened.
    static func decrypt(_ content: UNNotificationContent, key: Curve25519.KeyAgreement.PrivateKey?) -> UNNotificationContent? {
        // The relay puts the collapse id in thread-id; it's the associated data.
        guard let ciphertext = content.userInfo["e"] as? String, let key,
              let alert = try? open(ciphertext, collapseID: content.threadIdentifier, key: key),
              let target = PushLabel.parse(alert.m),
              PushLabel.collapseID(label: alert.m, pane: alert.p) == content.threadIdentifier,
              let out = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        out.title = AlertText.title(kind: alert.k, state: alert.s, machine: target.name)
        out.body = alert.msg ?? ""
        out.threadIdentifier = target.machine.uuidString
        var info = out.userInfo
        info.removeValue(forKey: "e")
        info["machine"] = target.machine.uuidString
        info["pane"] = NSNumber(value: alert.p)
        out.userInfo = info
        return out
    }

    /// What clothod does, for tests and the "Send test alert" check.
    static func seal(_ alert: PushAlert, collapseID: String, to key: Curve25519.KeyAgreement.PublicKey) throws -> String {
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: info)
        let ct = try sender.seal(try JSONEncoder().encode(alert), authenticating: Data(collapseID.utf8))
        return (sender.encapsulatedKey + ct).base64EncodedString()
    }
}

/// The `label` the app registers with each machine, echoed back in its alerts: the machine's id in the app
/// and its name, so the extension can say where an alert comes from without the app's data.
enum PushLabel {
    static func make(machine: UUID, name: String) -> String {
        machine.uuidString + " " + String(name.prefix(60))
    }

    static func parse(_ label: String) -> (machine: UUID, name: String)? {
        guard let space = label.firstIndex(of: " "), let id = UUID(uuidString: String(label[..<space])) else { return nil }
        return (id, String(label[label.index(after: space)...]))
    }

    /// Alerts for one pane replace each other: the push's `apns-collapse-id` and the app's own
    /// foreground notification share this identifier. First 32 hex digits of SHA-256(label + "/" + pane).
    static func collapseID(label: String, pane: UInt64) -> String {
        SHA256.hash(data: Data("\(label)/\(pane)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// How an agent alert reads, the same in a push and in the app's foreground notification.
enum AlertText {
    static func title(kind: String, state: String, machine: String) -> String {
        let name = kind.prefix(1).uppercased() + kind.dropFirst()
        switch state {
        case "waiting": return "\(name) is waiting on \(machine)"
        case "error": return "\(name) hit an error on \(machine)"
        default: return "\(name) finished on \(machine)"
        }
    }
}
