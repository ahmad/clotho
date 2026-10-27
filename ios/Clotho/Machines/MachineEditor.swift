import SwiftUI

struct MachineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var machine: Machine
    @State private var port: String
    @State private var hostKey: String?
    let onSave: (Machine) -> Void

    init(machine: Machine, onSave: @escaping (Machine) -> Void) {
        _machine = State(initialValue: machine)
        _port = State(initialValue: String(machine.port))
        _hostKey = State(initialValue: TrustedHostKeys.shared.key(for: machine.id))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Machine") {
                    TextField("Name (optional)", text: $machine.name)
                    TextField("Host", text: $machine.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("User", text: $machine.user)
                        .textContentType(.username)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                if let problem = Machine.problem(host: machine.host.trimmingCharacters(in: .whitespaces),
                                                 user: machine.user.trimmingCharacters(in: .whitespaces)) {
                    Section { Text(problem).font(.callout).foregroundStyle(.orange) }
                }

                Section {
                    KeyPicker(keyID: $machine.keyID)
                } header: {
                    Text("Key")
                } footer: {
                    Text("Add the public key to ~/.ssh/authorized_keys on the machine.")
                }

                Section {
                    TextField(Machine.defaultBridgeCommand, text: Binding(
                        get: { machine.remoteCommand ?? "" },
                        set: { machine.remoteCommand = $0.isEmpty ? nil : $0 }))
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Remote command")
                } footer: {
                    Text("Runs on the machine and speaks the clothod protocol on stdin and stdout.")
                }

                Section {
                    Toggle("Agent alerts", isOn: Binding(get: { machine.alerts ?? true }, set: { machine.alerts = $0 }))
                } footer: {
                    Text("Alerts when an agent on this machine needs you, even while Clotho is closed. Encrypted on the machine; only this iPhone can read them.")
                }

                Section {
                    Toggle("Test install directories", isOn: Binding(get: { machine.devDirs ?? false },
                                                                     set: { machine.devDirs = $0 }))
                } footer: {
                    Text("Installs clothod under ~/.local/share/clotho-ios-dev and runs it in its own runtime directory, separate from the machine's own clothod and its shells.")
                }

                if let hostKey {
                    Section {
                        LabeledContent("Type", value: HostKeys.keyType(hostKey))
                        Text(HostKeys.fingerprint(hostKey) ?? "unknown")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Forget host key", role: .destructive) {
                            TrustedHostKeys.shared.set(nil, for: machine.id)
                            self.hostKey = nil
                        }
                    } header: {
                        Text("Host key")
                    } footer: {
                        Text("Trusted on first connect. Forgetting it trusts whatever key the machine presents next time.")
                    }
                }
            }
            .navigationTitle(machine.host.isEmpty ? "New Machine" : machine.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        machine.port = Int(port) ?? 22
                        machine.host = machine.host.trimmingCharacters(in: .whitespaces)
                        machine.user = machine.user.trimmingCharacters(in: .whitespaces)
                        onSave(machine)
                        dismiss()
                    }
                    .disabled(machine.host.trimmingCharacters(in: .whitespaces).isEmpty || machine.user.isEmpty
                              || Machine.problem(host: machine.host.trimmingCharacters(in: .whitespaces),
                                                 user: machine.user.trimmingCharacters(in: .whitespaces)) != nil)
                }
            }
        }
    }
}
