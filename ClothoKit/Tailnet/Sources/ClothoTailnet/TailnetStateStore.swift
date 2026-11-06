import Foundation

/// Where a node keeps its state (its keys and profile) when it shouldn't be a file in the node's dir: on iOS,
/// the Keychain (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly), so the node survives reinstalls.
///
/// The contract (clotho_tailnet.h, ctn_store_read_fn and ctn_store_write_fn):
/// - Called on the shim's own threads, never the caller's, at any time while the node runs and while it
///   shuts down, one call at a time per node. Must be thread-safe and quick (no UI, no waiting on the main
///   thread).
/// - Keys are tsnet's state keys (ipn.StateKey: "_machinekey", "_current-profile", "_profiles",
///   "profile-<id>", ...): short ASCII strings. Values are opaque bytes; the node's private keys are in them.
/// - `read` returns nil for a key that isn't there. `write` replaces the value; nil deletes the key.
/// - A thrown error fails that read or write in the node (it logs it and may fail to start or to save).
/// - The store must stay usable until the node has shut down (`TailnetNode.waitForClose`), not just until
///   `stop()` returns.
public protocol TailnetStateStore: AnyObject, Sendable {
    func read(key: String) throws -> Data?
    func write(key: String, value: Data?) throws
}

/// A store in memory: tests, and nodes that must forget everything when the process ends.
public final class MemoryStateStore: TailnetStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func read(key: String) throws -> Data? { lock.locked { values[key] } }

    public func write(key: String, value: Data?) throws { lock.locked { values[key] = value } }

    /// The keys stored, for tests.
    public var keys: [String] { lock.locked { values.keys.sorted() } }
}
