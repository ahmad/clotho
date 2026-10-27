import CryptoKit
import Foundation

/// Imports an existing private key in OpenSSH's format (`~/.ssh/id_ed25519`, "-----BEGIN OPENSSH PRIVATE
/// KEY-----"). Only unencrypted Ed25519 keys, which is what SwiftNIO SSH can use; every other case gets an
/// error that says what to do instead.
enum KeyImport {
    enum Failure: Error, LocalizedError, Equatable {
        case empty
        case publicKey
        case notOpenSSH
        case encrypted
        case unsupported(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste the private key, or choose its file."
            case .publicKey:
                return "That's a public key (the .pub file). Import the private key: the file without .pub, starting with -----BEGIN OPENSSH PRIVATE KEY-----."
            case .notOpenSSH:
                return "That isn't an OpenSSH private key. It should start with -----BEGIN OPENSSH PRIVATE KEY-----."
            case .encrypted:
                return "This key has a passphrase. Clotho can't use it as it is: on your computer, make a copy without one (cp id_ed25519 clotho_key; ssh-keygen -p -N '' -f clotho_key) and import the copy, or generate a new key here."
            case .unsupported(let type):
                return "Clotho supports Ed25519 keys, and this one is \(type). Generate an Ed25519 key here instead, or on your computer with ssh-keygen -t ed25519."
            case .malformed:
                return "The key is incomplete or damaged. Copy the whole file, including the BEGIN and END lines."
            }
        }
    }

    /// The key as an SSHKey (not yet saved), named after its comment unless `name` is given.
    static func parse(_ text: String, name: String? = nil) throws -> SSHKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") { throw Failure.publicKey }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw Failure.unsupported("an RSA key") }
        if trimmed.contains("BEGIN EC PRIVATE KEY") { throw Failure.unsupported("an ECDSA key") }
        if trimmed.contains("ENCRYPTED") && !trimmed.contains("OPENSSH") { throw Failure.encrypted }
        guard trimmed.contains("BEGIN OPENSSH PRIVATE KEY") else { throw Failure.notOpenSSH }

        let body = trimmed.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: body) else { throw Failure.malformed }
        var reader = Reader(blob)
        let magic = Data("openssh-key-v1\0".utf8)
        guard blob.prefix(magic.count) == magic else { throw Failure.notOpenSSH }
        reader.offset = magic.count
        let cipher = try reader.string()
        _ = try reader.bytes() // kdf name
        _ = try reader.bytes() // kdf options
        guard cipher == "none" else { throw Failure.encrypted }
        guard try reader.uint32() >= 1 else { throw Failure.malformed }
        _ = try reader.bytes() // the first public key

        var section = Reader(try reader.bytes())
        guard try section.uint32() == section.uint32() else { throw Failure.malformed }
        let type = try section.string()
        switch type {
        case "ssh-ed25519": break
        case "ssh-rsa": throw Failure.unsupported("an RSA key")
        case let ecdsa where ecdsa.hasPrefix("ecdsa-"): throw Failure.unsupported("an ECDSA key")
        case let sk where sk.hasPrefix("sk-"): throw Failure.unsupported("a security-key (FIDO) key")
        default: throw Failure.unsupported("a \(type) key")
        }
        let publicKey = try section.bytes()
        let privateKey = try section.bytes()
        let comment = (try? section.string()) ?? ""
        guard publicKey.count == 32, privateKey.count == 64 else { throw Failure.malformed }
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey.prefix(32))
        guard signing.publicKey.rawRepresentation == publicKey else { throw Failure.malformed }

        let chosen = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return SSHKey(id: UUID().uuidString, name: chosen.isEmpty ? (comment.isEmpty ? "imported" : comment) : chosen,
                      kind: .ed25519, created: Date(), secret: signing.rawRepresentation)
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(_ data: Data) { self.data = Data(data) }

        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw Failure.malformed }
            let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += 4
            return value
        }

        mutating func bytes() throws -> Data {
            let count = Int(try uint32())
            guard count <= data.count - offset else { throw Failure.malformed }
            defer { offset += count }
            return data[offset..<offset + count]
        }

        mutating func string() throws -> String {
            String(decoding: try bytes(), as: UTF8.self)
        }
    }
}
