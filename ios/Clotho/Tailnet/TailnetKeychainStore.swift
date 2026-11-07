import Foundation
import Security

/// Where Clotho's own tailnet node keeps its state (its keys and profile) on iOS: generic-password Keychain
/// items, one per tsnet state key, readable after the first unlock and never leaving the device. The contract
/// is ClothoTailnet's TailnetStateStore (ClothoKit/Tailnet/README.md): calls come on the shim's threads, one at
/// a time per node, must be quick, read nil for a missing key, and write(nil) deletes.
///
/// It compiles in every build (so -CleanState can wipe it); only its conformance to TailnetStateStore needs a
/// CLOTHO_TAILNET build (the bottom of this file).
///
/// A node gets a `Lease`, not the store. Recreating a node (TailnetController, on foreground) revokes the old
/// node's lease first: a node stuck shutting down (tailscale#21353) can still read until it closes, as the
/// contract requires, but its writes are dropped, so it can never overwrite the new node's state.
final class TailnetKeychainStore: @unchecked Sendable {
    enum Service: String, CaseIterable {
        case release = "nyc.amin.clotho.tailnet"
        /// Debug builds: a node of their own, which -CleanState wipes.
        case dev = "nyc.amin.clotho.tailnet-dev"
        /// Tests and test-mode nodes (a loopback control server): never shared with a real node.
        case test = "nyc.amin.clotho.tailnet-test"

        static var forBuild: Service {
            #if DEBUG
            return .dev
            #else
            return .release
            #endif
        }
    }

    let service: Service

    /// One lock for every instance and lease in the process: an old node still shutting down and its
    /// replacement share the same items, while the shim only promises one call at a time per node.
    private static let lock = NSLock()

    init(service: Service) {
        self.service = service
    }

    private func query(_ key: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        if let key { q[kSecAttrAccount as String] = key }
        return q
    }

    /// The value of `key`, or nil when there's none.
    func read(key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = Self.lock.withLock { SecItemCopyMatching(q as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data ?? Data()
    }

    /// Replaces the value of `key`; nil (or empty) deletes it, and deleting a missing key is fine. An update in
    /// place, not delete-then-add (KeyStore's way): a crash between the two would lose the node's keys.
    func write(key: String, value: Data?) throws {
        try Self.lock.withLock {
            guard let value, !value.isEmpty else {
                let status = SecItemDelete(query(key) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
                return
            }
            let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw KeychainError(status: update) }
            var item = query(key)
            item[kSecValueData as String] = value
            item[kSecAttrLabel as String] = "Clotho tailnet state"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        }
    }

    /// The keys stored, sorted.
    func keys() -> [String] {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = Self.lock.withLock { SecItemCopyMatching(q as CFDictionary, &result) }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Deletes every item of `service` (never another service's).
    static func deleteAll(_ service: Service) {
        let store = TailnetKeychainStore(service: service)
        _ = lock.withLock { SecItemDelete(store.query() as CFDictionary) }
    }

    /// What one node gets: reads and writes go to the store until `revoke`.
    func lease() -> Lease { Lease(store: self) }

    final class Lease: @unchecked Sendable {
        let store: TailnetKeychainStore
        private let lock = NSLock()
        private var revoked = false

        fileprivate init(store: TailnetKeychainStore) {
            self.store = store
        }

        var isRevoked: Bool { lock.withLock { revoked } }

        /// Later writes are dropped (without an error, so the old node's shutdown doesn't log failures); reads
        /// are still served until the node has closed.
        func revoke() { lock.withLock { revoked = true } }

        func read(key: String) throws -> Data? { try store.read(key: key) }

        func write(key: String, value: Data?) throws {
            guard !isRevoked else { return }
            try store.write(key: key, value: value)
        }
    }

    /// The debug build's node dir (tsnet's own files besides the state; the state is in the Keychain), which
    /// -CleanState removes with the dev and test services.
    static var debugNodeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clotho", isDirectory: true).appendingPathComponent("tailnet-dev", isDirectory: true)
    }
}

#if CLOTHO_TAILNET
import ClothoTailnet

extension TailnetKeychainStore.Lease: TailnetStateStore {}
#endif
