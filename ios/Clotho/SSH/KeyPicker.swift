import SwiftUI
import UIKit

/// Picks the machine's login key, makes new ones, and copies a public key for authorized_keys.
struct KeyPicker: View {
    @Binding var keyID: String?
    @State private var keys: [SSHKey] = KeyStore.all()
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Picker("Key", selection: $keyID) {
            Text("None").tag(String?.none)
            ForEach(keys) { key in
                Text("\(key.name) (\(key.kindLabel))").tag(Optional(key.id))
            }
        }
        if let key = keys.first(where: { $0.id == keyID }) {
            Button {
                do {
                    UIPasteboard.general.string = try key.openSSHPublicKey()
                    copied = true
                } catch {
                    self.error = error.localizedDescription
                }
            } label: {
                Label(copied ? "Copied" : "Copy public key", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            if let line = try? key.openSSHPublicKey() {
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        Menu {
            Button("Ed25519") { generate(.ed25519) }
            if KeyStore.secureEnclaveAvailable {
                Button("P-256 in the Secure Enclave") { generate(.secureEnclaveP256) }
            }
        } label: {
            Label("Generate new key", systemImage: "key")
        }
        .alert("Key error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func generate(_ kind: SSHKey.Kind) {
        do {
            let name = "clotho-\(UIDevice.current.name)-\(keys.count + 1)"
            let key = try KeyStore.generate(kind: kind, name: name)
            keys = KeyStore.all()
            keyID = key.id
            copied = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
