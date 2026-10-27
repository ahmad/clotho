import CryptoKit
import Foundation
import NIOSSH
import Security

/// SSH login keys, generated on this device and kept in its Keychain (never synced, never exported).
/// Ed25519 by default; P-256 in the Secure Enclave as an option, where the private key can't leave the chip.
struct SSHKey: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ed25519
        /// The stored bytes are the Secure Enclave's wrapped key, usable only on this device.
        case secureEnclaveP256
    }

    var id: String
    var name: String
    var kind: Kind
    var created: Date
    /// Ed25519 raw private key, or the Secure Enclave key's `dataRepresentation`.
    var secret: Data

    var kindLabel: String { kind == .ed25519 ? "Ed25519" : "Secure Enclave P-256" }

    func privateKey() throws -> NIOSSHPrivateKey {
        switch kind {
        case .ed25519:
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret))
        case .secureEnclaveP256:
            return NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret))
        }
    }

    /// One line for authorized_keys: "ssh-ed25519 AAAA… name".
    func openSSHPublicKey() throws -> String {
        String(openSSHPublicKey: try privateKey().publicKey) + " " + name.replacingOccurrences(of: " ", with: "-")
    }
}

enum KeyStore {
    private static let service = "nyc.amin.clotho.ssh-keys"

    static var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    static func generate(kind: SSHKey.Kind, name: String) throws -> SSHKey {
        let secret: Data
        switch kind {
        case .ed25519:
            secret = Curve25519.Signing.PrivateKey().rawRepresentation
        case .secureEnclaveP256:
            secret = try SecureEnclave.P256.Signing.PrivateKey().dataRepresentation
        }
        let key = SSHKey(id: UUID().uuidString, name: name, kind: kind, created: Date(), secret: secret)
        try save(key)
        return key
    }

    static func save(_ key: SSHKey) throws {
        let data = try JSONEncoder.iso.encode(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.id,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Clotho SSH key \(key.name)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func all() -> [SSHKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder.iso.decode(SSHKey.self, from: $0) }.sorted { $0.created < $1.created }
    }

    static func key(_ id: String) -> SSHKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder.iso.decode(SSHKey.self, from: data)
    }

    static func delete(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: Error, LocalizedError {
    var status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Host keys in OpenSSH form, for trust on first use.
enum HostKeys {
    static func openSSH(_ key: NIOSSHPublicKey) -> String { String(openSSHPublicKey: key) }

    /// "SHA256:…" as `ssh-keygen -l` prints it.
    static func fingerprint(_ openSSH: String) -> String? {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }

    static func keyType(_ openSSH: String) -> String {
        String(openSSH.split(separator: " ").first ?? "")
    }
}
