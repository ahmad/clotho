import ClothoKit
import Darwin
import Foundation

/// A ClothodTransport over Clotho's own tailnet node: a TCP connection to clothod-net (`clothod-net serve
/// --port N`) on a machine in the user's tailnet, speaking the protocol directly (docs/protocol.md), with no
/// SSH in between.
public struct TailnetTransport: ClothodTransport {
    public let node: TailnetNode
    public var host: String
    public var port: Int
    /// How long one dial may take, including the node coming up and learning about the peer.
    public var dialTimeout: TimeInterval

    public init(node: TailnetNode, host: String, port: Int, dialTimeout: TimeInterval = 15) {
        self.node = node
        self.host = host
        self.port = port
        self.dialTimeout = dialTimeout
    }

    public var name: String { "tailnet:\(host):\(port)" }
    public var maxReconnectDelay: TimeInterval { 30 }
    public var heartbeatInterval: TimeInterval? { 30 }

    public func open(progress: @escaping @Sendable (String) -> Void) throws -> ByteStream {
        progress("Connecting over the tailnet")
        let fd = try node.dialSync(host: host, port: port, timeout: dialTimeout)
        return ByteStream(readFD: fd, writeFD: fd, onShutdown: { shutdown(fd, SHUT_RDWR) })
    }
}
