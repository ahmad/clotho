import ClothoKit
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

/// What a machine encrypts into an alert (docs/push.md): `{"v":1, "m", "p", "k", "s", "msg", "t"}`, and
/// since clothod 0.1.13 the detail fields below, each optional.
struct PushAlert: Codable, Equatable, Sendable {
    var v: Int
    /// The label the app registered with (`PushLabel`).
    var m: String
    var p: UInt64
    var k: String
    var s: String
    var msg: String?
    var t: Double?
    /// Workspace name and id, tab title, project.
    var w: String?
    var wid: UInt64?
    var tb: String?
    var pj: String?
    /// The first line of the prompt the user typed for this turn.
    var q: String?
    /// A wait: the last tool the turn used and its key input ("Bash", "npm test").
    var tool: String?
    var cmd: String?
    /// Done and error: seconds since the turn started.
    var d: Double?
    /// A permission request's id (clothod 0.1.13): the alert can answer it with Allow or Deny.
    var rq: String?
    /// A short summary of `msg` by a small model (clothod 0.1.29): the body when it's there.
    var sm: String?

    init(v: Int = 1, m: String, p: UInt64, k: String, s: String, msg: String? = nil, t: Double? = nil,
         w: String? = nil, wid: UInt64? = nil, tb: String? = nil, pj: String? = nil, q: String? = nil,
         tool: String? = nil, cmd: String? = nil, d: Double? = nil, rq: String? = nil, sm: String? = nil) {
        self.v = v; self.m = m; self.p = p; self.k = k; self.s = s; self.msg = msg; self.t = t
        self.w = w; self.wid = wid; self.tb = tb; self.pj = pj; self.q = q; self.tool = tool; self.cmd = cmd; self.d = d; self.rq = rq; self.sm = sm
    }

    /// The alert's text (ClothoKit's AgentNotice, the same as the app's own banner and the Mac's): the summary
    /// when there is one, else the message as plain text; a permission ask always names its tool and command
    /// first. With neither, the body is the prompt, then the tab title.
    func notice(machine name: String) -> AgentNotice {
        AgentNotice(kind: k, state: s, machine: name, workspace: w, project: pj, duration: d, result: msg,
                    tool: tool, toolInput: cmd, fallback: q ?? tb, summary: sm)
    }

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
        AlertText.apply(alert.notice(machine: target.name), to: out)
        out.threadIdentifier = AlertText.thread(machine: target.machine, workspace: alert.wid.map(String.init) ?? alert.w)
        var info = out.userInfo
        info.removeValue(forKey: "e")
        info["machine"] = target.machine.uuidString
        info["pane"] = NSNumber(value: alert.p)
        if let rq = alert.rq, alert.s == "waiting" { info["request"] = rq }
        out.userInfo = info
        out.categoryIdentifier = AlertActions.category(state: alert.s, request: alert.rq)
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

/// How an agent alert shows: AgentNotice's text, threaded by machine and workspace so one workspace's alerts
/// stack. The same for a push (ClothoNotify) and the app's foreground notification.
enum AlertText {
    static func apply(_ notice: AgentNotice, to content: UNMutableNotificationContent) {
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
    }

    /// Machine and workspace (its id, else its name); the machine alone when the workspace isn't known.
    static func thread(machine: UUID, workspace: String?) -> String {
        guard let workspace, !workspace.isEmpty else { return machine.uuidString }
        return machine.uuidString + "/" + workspace
    }
}

/// What an agent alert lets the user do without opening the app: answer a permission request (Allow, which needs
/// the phone unlocked, Deny, or Deny with a reason the agent is told), or reply to a waiting or finished agent.
/// The same for a push (the extension sets the category) and the app's own banner.
enum AlertActions {
    static let permissionCategory = "agent.permission"
    static let replyCategory = "agent.reply"
    static let allow = "allow"
    static let deny = "deny"
    static let denyWithReason = "denyReason"
    static let reply = "reply"

    /// A waiting agent with a request id is a permission request; other waits and finished turns take a reply.
    static func category(state: String, request: String?) -> String {
        if state == "waiting", let request, !request.isEmpty { return permissionCategory }
        return state == "waiting" || state == "done" ? replyCategory : ""
    }

    static var categories: Set<UNNotificationCategory> {
        let allowAction = UNNotificationAction(identifier: allow, title: "Allow", options: [.authenticationRequired])
        let denyAction = UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive])
        let reasonAction = UNTextInputNotificationAction(identifier: denyWithReason, title: "Deny with Reason…",
                                                         options: [.destructive], textInputButtonTitle: "Deny",
                                                         textInputPlaceholder: "Tell the agent why")
        let replyAction = UNTextInputNotificationAction(identifier: reply, title: "Reply", options: [],
                                                        textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        return [
            UNNotificationCategory(identifier: permissionCategory, actions: [allowAction, denyAction, reasonAction],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: replyCategory, actions: [replyAction], intentIdentifiers: [], options: []),
        ]
    }
}
