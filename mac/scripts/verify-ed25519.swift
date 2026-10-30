// Checks a Sparkle EdDSA signature the way the app will: the file, the signature sparkle:edSignature
// carries, and the public key the app trusts (Resources/SparklePublicKey). scripts/release.sh runs it on
// every release, so a zip signed with any other key never reaches the appcast.
//
//   swift scripts/verify-ed25519.swift <public key file> <base64 signature> <file>
//
// Exits 0 and prints "verified" only when the signature is valid.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-ed25519.swift <public key file> <base64 signature> <file>\n".utf8))
    exit(2)
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-ed25519: \(message)\n".utf8))
    exit(1)
}
guard let keyText = try? String(contentsOfFile: args[1], encoding: .utf8),
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("can't read a public key from \(args[1])") }
guard let signature = Data(base64Encoded: args[2]) else { fail("the signature isn't base64") }
guard let file = FileManager.default.contents(atPath: args[3]) else { fail("can't read \(args[3])") }
guard key.isValidSignature(signature, for: file) else { fail("the signature doesn't verify against \(args[1])") }
print("verified")
