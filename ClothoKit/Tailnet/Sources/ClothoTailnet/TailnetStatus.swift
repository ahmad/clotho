import Foundation

/// What the app needs of tsnet's ipnstate.Status (ctn_status_json).
public struct TailnetStatus: Sendable {
    /// NoState, Starting, NeedsLogin, NeedsMachineAuth, Stopped or Running.
    public var backendState: String
    public var authURL: URL?
    /// This node; nil before it has signed in.
    public var selfNode: Peer?
    /// The other nodes in the tailnet, by name.
    public var peers: [Peer]
    /// The users of this node and its peers, by ID.
    public var users: [Int64: User]

    public struct Peer: Sendable, Equatable {
        public var id: String
        public var hostName: String
        /// The MagicDNS name, without the trailing dot.
        public var dnsName: String
        public var tailscaleIPs: [String]
        public var userID: Int64
        public var os: String
        public var online: Bool
        public var tags: [String]
        public var keyExpiry: Date?
        public var expired: Bool

        /// The first IPv4 address, else the first address.
        public var primaryIP: String? { tailscaleIPs.first { !$0.contains(":") } ?? tailscaleIPs.first }
    }

    public struct User: Sendable, Equatable {
        public var id: Int64
        public var loginName: String
        public var displayName: String
    }

    static func decode(_ json: String) throws -> TailnetStatus {
        let raw = try JSONDecoder().decode(RawStatus.self, from: Data(json.utf8))
        var users: [Int64: User] = [:]
        for user in raw.User?.values ?? [:].values {
            users[user.ID] = User(id: user.ID, loginName: user.LoginName ?? "", displayName: user.DisplayName ?? "")
        }
        return TailnetStatus(
            backendState: raw.BackendState,
            authURL: raw.AuthURL.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            selfNode: raw.Self_.flatMap { $0.peer },
            peers: (raw.Peer?.values.compactMap { $0.peer } ?? []).sorted { $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending },
            users: users)
    }
}

/// tsnet's apitype.WhoIsResponse (ctn_whois): the node and user behind a tailnet address.
public struct TailnetWhoIs: Sendable, Equatable {
    public var node: Node
    public var user: TailnetStatus.User

    public struct Node: Sendable, Equatable {
        public var id: Int64
        public var name: String
        /// The node's owner. For a tagged node this is not a person (tags replace the user identity).
        public var userID: Int64
        /// Set when the node is shared in from another tailnet: the user who shared it.
        public var sharer: Int64?
        public var tags: [String]
        public var addresses: [String]
    }

    static func decode(_ json: String) throws -> TailnetWhoIs {
        let raw = try JSONDecoder().decode(RawWhoIs.self, from: Data(json.utf8))
        guard let n = raw.Node, let u = raw.UserProfile else { throw TailnetError.failed("whois: no node or user in the reply") }
        return TailnetWhoIs(
            node: Node(id: n.ID, name: n.Name ?? "", userID: n.User ?? 0, sharer: n.Sharer.flatMap { $0 == 0 ? nil : $0 },
                       tags: n.Tags ?? [], addresses: n.Addresses ?? []),
            user: TailnetStatus.User(id: u.ID, loginName: u.LoginName ?? "", displayName: u.DisplayName ?? ""))
    }
}

// MARK: - The JSON, as Go writes it

private struct RawStatus: Decodable {
    var BackendState: String
    var AuthURL: String?
    var Self_: RawPeer?
    var Peer: [String: RawPeer]?
    var User: [String: RawUser]?

    enum CodingKeys: String, CodingKey {
        case BackendState, AuthURL, Peer, User
        case Self_ = "Self"
    }
}

private struct RawPeer: Decodable {
    var ID: String?
    var HostName: String?
    var DNSName: String?
    var TailscaleIPs: [String]?
    var UserID: Int64?
    var OS: String?
    var Online: Bool?
    var Tags: [String]?
    var KeyExpiry: String?
    var Expired: Bool?

    var peer: TailnetStatus.Peer? {
        TailnetStatus.Peer(
            id: ID ?? "", hostName: HostName ?? "",
            dnsName: (DNSName ?? "").hasSuffix(".") ? String((DNSName ?? "").dropLast()) : DNSName ?? "",
            tailscaleIPs: TailscaleIPs ?? [], userID: UserID ?? 0, os: OS ?? "", online: Online ?? false, tags: Tags ?? [],
            keyExpiry: KeyExpiry.flatMap(parseGoTime), expired: Expired ?? false)
    }
}

private struct RawUser: Decodable {
    var ID: Int64
    var LoginName: String?
    var DisplayName: String?
}

private struct RawWhoIs: Decodable {
    struct RawNode: Decodable {
        var ID: Int64
        var Name: String?
        var User: Int64?
        var Sharer: Int64?
        var Tags: [String]?
        var Addresses: [String]?
    }
    var Node: RawNode?
    var UserProfile: RawUser?
}

/// Go's time.Time JSON (RFC 3339 with up to nine fractional digits).
func parseGoTime(_ s: String) -> Date? {
    var text = s
    if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
        text.removeSubrange(dot..<end)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}
