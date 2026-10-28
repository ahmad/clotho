import ClothoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Whether the welcome guide has been seen, and when it shows by itself.
enum Onboarding {
    private static let doneKey = "OnboardingDone"

    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// On first launch with no machines saved. UI tests see it only when they ask for a clean state.
    static func showsAtLaunch(savedMachines: Int) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-UITesting") && !arguments.contains("-CleanState") { return false }
        return !isDone && savedMachines == 0
    }

    /// Debug builds' `-CleanState YES`: forget machines, keys, trusted host keys and the guide, as a fresh install
    /// would. Runs before anything reads them.
    static func resetIfAsked() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "CleanState") else { return }
        try? FileManager.default.removeItem(at: MachineList.defaultURL)
        KeyStore.all().forEach { KeyStore.delete($0.id) }
        UserDefaults.standard.removeObject(forKey: "TrustedHostKeys")
        UserDefaults.standard.removeObject(forKey: doneKey)
        MainActor.assumeIsolated { SavedState.shared.deleteAll() }
        #endif
    }
}

/// The welcome guide: what Workspaces, Tabs and Panes are, then setting up a first machine from SSH target to
/// a running clothod, with notifications and start at login. `addMachine` runs only the machine part (the +
/// button). Every step can be skipped; the Machines screen reopens the guide.
struct OnboardingView: View {
    enum Mode { case firstRun, addMachine }

    /// Three screens: add a machine (with its key), check it (host key, log in, install clothod), done.
    /// Notifications are asked once a machine is connected, and Start at login is in the machine's Settings.
    enum Step: Int, Comparable {
        case machine, check, done
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum CheckStage: Int { case hostKey, logIn, install }

    let mode: Mode
    /// Called when the guide closes, with the machine it set up (if it got that far).
    let finish: (UUID?) -> Void

    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @State private var step: Step
    @State private var machine = Machine(name: "", devDirs: HomeView.defaultDevDirs)
    @State private var port = "22"
    @State private var saved = false
    @State private var stage = CheckStage.hostKey

    init(mode: Mode, finish: @escaping (UUID?) -> Void) {
        self.mode = mode
        self.finish = finish
        _step = State(initialValue: .machine)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    page
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .done {
                        Button(mode == .firstRun ? "Skip" : "Cancel") { close() }
                            .accessibilityIdentifier("onboardingSkip")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if let progress { ProgressView(value: progress).frame(width: 120).accessibilityLabel("Step \(step.rawValue + 1)") }
                }
            }
            .animation(.default, value: step)
        }
        .interactiveDismissDisabled()
    }

    private var progress: Double? {
        guard step != .done else { return nil }
        return Double(step.rawValue + 1) / Double(Step.done.rawValue + 1)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .machine:
            AddMachinePage(machine: $machine, port: $port, firstRun: mode == .firstRun) { advance() }
        case .check:
            CheckList(stage: stage, machine: machine)
            switch stage {
            case .hostKey: HostKeyPage(machine: machine, back: { step = .machine }) { stage = .logIn }
            case .logIn: LogInPage(machine: machine, back: { step = .machine }) { save(); stage = .install }
            case .install: InstallPage(connection: connections.connection(for: machine)) { step = .done }
            }
        case .done:
            DonePage(machine: machine, mode: mode) { close(openMachine: true) }
        }
    }

    private func advance() {
        machine.port = Int(port) ?? 22
        machine.host = machine.host.trimmingCharacters(in: .whitespaces)
        machine.user = machine.user.trimmingCharacters(in: .whitespaces)
        stage = .hostKey
        step = .check
    }

    private func save() {
        machines.save(machine)
        saved = true
    }

    private func close(openMachine: Bool = false) {
        if mode == .firstRun { Onboarding.isDone = true }
        finish(saved && openMachine ? machine.id : nil)
    }
}

// MARK: - Shared pieces

private struct PageHeader: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.selection)
                .accessibilityHidden(true)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

private struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.selection)
        .disabled(!enabled)
        .padding(.top, 8)
    }
}

/// A red callout with what went wrong and what to do.
private struct ErrorNote: View {
    let text: String

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("onboardingError")
    }
}

private struct Field: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier(label)
        }
    }
}

// MARK: - Add a machine

/// Screen 1: where the machine is, and the key this device logs in with. A key is made silently when the device
/// has none (Ed25519 in the Keychain); the card below shows the one command that lets it in.
private struct AddMachinePage: View {
    @Binding var machine: Machine
    @Binding var port: String
    let firstRun: Bool
    let next: () -> Void
    @State private var keys: [SSHKey] = KeyStore.all()
    @State private var choosingKey = false
    @State private var importing = false
    @State private var error: String?

    private var host: String { machine.host.trimmingCharacters(in: .whitespaces) }
    private var user: String { machine.user.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { host.isEmpty && user.isEmpty ? nil : Machine.problem(host: host, user: user) }
    private var key: SSHKey? { keys.first { $0.id == machine.keyID } }

    private var valid: Bool {
        !host.isEmpty && !user.isEmpty && problem == nil && key != nil && Int(port).map { (1...65535).contains($0) } == true
    }

    var body: some View {
        PageHeader(symbol: "server.rack", title: firstRun ? "Welcome to Clotho" : "Add a machine",
                   text: "Clotho runs your terminals and agents on a Mac or Linux machine you can reach with SSH, on your network or over Tailscale. On a Mac, turn on System Settings › General › Sharing › Remote Login.")
        Field(label: "Host", placeholder: "mac-mini.local, 192.168.1.20 or a Tailscale name", text: $machine.host, keyboard: .URL)
        Field(label: "User", placeholder: "Your user name on that machine", text: $machine.user)
        HStack(spacing: 12) {
            Field(label: "Port", placeholder: "22", text: $port, keyboard: .numberPad).frame(width: 100)
            Field(label: "Name", placeholder: "Optional", text: $machine.name)
        }
        #if DEBUG
        Toggle("Test install directories", isOn: Binding(get: { machine.devDirs ?? false }, set: { machine.devDirs = $0 }))
            .font(.callout)
        #endif
        if let problem { ErrorNote(text: problem) }

        if let key {
            Text("Let this device log in").font(.headline).padding(.top, 8)
            PublicKeyCard(key: key, user: user.isEmpty ? "you" : user, host: host.isEmpty ? "the machine" : host)
            Button(choosingKey ? "Keep this key" : "Use a different key…") { choosingKey.toggle() }
                .font(.callout)
                .accessibilityIdentifier("chooseKey")
        }
        if choosingKey || key == nil {
            keyChoices
        }
        if let error { ErrorNote(text: error) }
        PrimaryButton(title: "Continue", enabled: valid, action: next)
        Color.clear.frame(height: 0)
            .onAppear(perform: pickKey)
            .sheet(isPresented: $importing) {
                KeyImportSheet { imported in
                    keys = KeyStore.all()
                    machine.keyID = imported.id
                    choosingKey = false
                }
            }
    }

    @ViewBuilder private var keyChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(keys) { other in
                Button {
                    machine.keyID = other.id
                    choosingKey = false
                } label: {
                    Label("\(other.name) (\(other.kindLabel))", systemImage: other.id == machine.keyID ? "checkmark.circle.fill" : "key.horizontal")
                }
            }
            Button { generate(.ed25519) } label: { Label("Make a New Key", systemImage: "plus") }
                .accessibilityIdentifier("generateKey")
            if KeyStore.secureEnclaveAvailable {
                Button { generate(.secureEnclaveP256) } label: { Label("Make One in the Secure Enclave", systemImage: "lock.shield") }
                Text("A Secure Enclave key can never leave this device. Some servers don't accept its type, so Ed25519 is the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { importing = true } label: { Label("Import an Existing Key…", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("importKey")
        }
        .font(.callout)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The key this machine will use: the one already chosen, else the device's first, else a new Ed25519 one.
    private func pickKey() {
        guard machine.keyID == nil || key == nil else { return }
        if let first = keys.first {
            machine.keyID = first.id
        } else {
            generate(.ed25519)
        }
    }

    private func generate(_ kind: SSHKey.Kind) {
        do {
            let made = try KeyStore.generate(kind: kind, name: "clotho-\(UIDevice.current.name)".replacingOccurrences(of: " ", with: "-"))
            keys = KeyStore.all()
            machine.keyID = made.id
            choosingKey = false
            error = nil
        } catch {
            self.error = "Couldn't make a key: \(error.localizedDescription)"
        }
    }
}

/// Screen 2's progress: what has been checked so far.
private struct CheckList: View {
    let stage: OnboardingView.CheckStage
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Machine's identity", done: stage.rawValue > OnboardingView.CheckStage.hostKey.rawValue, current: stage == .hostKey)
            row("Log in as \(machine.user)", done: stage.rawValue > OnboardingView.CheckStage.logIn.rawValue, current: stage == .logIn)
            row("clothod running", done: false, current: stage == .install)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("checkList")
    }

    private func row(_ title: String, done: Bool, current: Bool) -> some View {
        Label {
            Text(title).foregroundStyle(done || current ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : current ? "circle.dotted" : "circle")
                .foregroundStyle(done ? .green : current ? Color.selection : .secondary)
        }
    }
}

/// The public key and how to put it on the machine: copy it, copy a command that adds it, or share it.
struct PublicKeyCard: View {
    let key: SSHKey
    let user: String
    let host: String
    @State private var copied: String?

    private var line: String? { try? key.openSSHPublicKey() }

    /// Adds the key to authorized_keys with the permissions sshd wants, once.
    static func installCommand(_ line: String) -> String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(line)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    var body: some View {
        if let line {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add this public key to \(host.isEmpty ? "the machine" : host)").font(.headline)
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("publicKey")
                Text("Copy the command below and run it on \(host.isEmpty ? "the machine" : host) as \(user.isEmpty ? "your user" : user), from a terminal you already have there (or over SSH from your computer). It adds the key to ~/.ssh/authorized_keys. Only the public key leaves this device.")
                    .font(.callout).foregroundStyle(.secondary)
                copyButton("Copy Command", value: Self.installCommand(line), symbol: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    copyButton("Copy Key", value: line, symbol: "doc.on.doc")
                    ShareLink(item: line) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func copyButton(_ title: String, value: String, symbol: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = title
        } label: {
            Label(copied == title ? "Copied" : title, systemImage: copied == title ? "checkmark" : symbol)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(title)
    }
}

/// Paste a private key or pick its file.
private struct KeyImportSheet: View {
    let imported: (SSHKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("privateKeyText")
                    Button { picking = true } label: { Label("Choose File…", systemImage: "doc") }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("An Ed25519 key without a passphrase, as in ~/.ssh/id_ed25519 (not the .pub file). It goes into this device's Keychain and never leaves it.")
                }
                Section("Name") {
                    TextField("Optional", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let error {
                    Section { Text(error).font(.callout).foregroundStyle(.orange) }
                        .accessibilityIdentifier("importError")
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }.disabled(text.isEmpty)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .text]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count < 64 * 1024 {
                    text = String(decoding: data, as: UTF8.self)
                } else {
                    error = "Couldn't read that file."
                }
            }
        }
    }

    private func importKey() {
        do {
            let key = try KeyImport.parse(text, name: name)
            try KeyStore.save(key)
            imported(key)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Host key and login

private struct HostKeyPage: View {
    let machine: Machine
    let back: () -> Void
    let next: () -> Void
    @State private var presented: String?
    @State private var error: String?

    var body: some View {
        PageHeader(symbol: "checkmark.shield", title: "Check the machine's identity",
                   text: "The first time Clotho connects, it remembers the machine's host key and refuses to connect if it ever changes, which could mean someone is in between.")
        if let presented {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Machine", value: "\(machine.host):\(machine.port)")
                LabeledContent("Key type", value: HostKeys.keyType(presented))
                Text(HostKeys.fingerprint(presented) ?? "unknown")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("hostKeyFingerprint")
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            Text("To compare, run this on the machine: ssh-keygen -lf /etc/ssh/ssh_host_\(Self.keyFile(presented))_key.pub (on a Mac too). The SHA256 values should match.")
                .font(.callout).foregroundStyle(.secondary)
            PrimaryButton(title: "Trust This Machine") {
                TrustedHostKeys.shared.set(presented, for: machine.id)
                next()
            }
            .accessibilityIdentifier("trustHostKey")
        } else if let error {
            ErrorNote(text: error)
            HStack {
                Button("Try Again") { Task { await probe() } }.buttonStyle(.bordered)
                Button("Change Machine", action: back).buttonStyle(.bordered)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(machine.host)…").foregroundStyle(.secondary)
            }
        }
        Color.clear.frame(height: 0).task { await probe() }
    }

    static func keyFile(_ openSSH: String) -> String {
        switch HostKeys.keyType(openSSH) {
        case "ssh-ed25519": return "ed25519"
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": return "rsa"
        default: return "ecdsa"
        }
    }

    private func probe() async {
        error = nil
        presented = nil
        do {
            presented = try await ConnectionCheck.hostKey(of: machine)
        } catch {
            self.error = ConnectionCheck.describe(error, machine: machine)
        }
    }
}

private struct LogInPage: View {
    let machine: Machine
    let back: () -> Void
    let next: () -> Void
    @State private var result: ConnectionCheck.Login?
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        PageHeader(symbol: "person.badge.key", title: "Log in",
                   text: "Clotho logs in to \(machine.host) as \(machine.user) with the key.")
        if let result {
            Label("Logged in to \(machine.host) (\(result.system)).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("loggedIn")
                // On to installing without another tap: the guide only stops for a decision or a problem.
                .task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    next()
                }
        } else if let error {
            ErrorNote(text: error)
            if let key = machine.keyID.flatMap(KeyStore.key) {
                PublicKeyCard(key: key, user: machine.user, host: machine.host)
            }
            HStack {
                Button("Try Again") { Task { await check() } }.buttonStyle(.bordered)
                Button("Change Key", action: back).buttonStyle(.bordered)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Logging in…").foregroundStyle(.secondary)
            }
        }
        Color.clear.frame(height: 0).task { await check() }
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        error = nil
        do {
            result = try await ConnectionCheck.logIn(machine)
        } catch {
            self.error = ConnectionCheck.describe(error, machine: machine)
        }
        checking = false
    }
}

// MARK: - Install

private struct InstallPage: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    let next: () -> Void

    init(connection: MachineConnection, next: @escaping () -> Void) {
        self.connection = connection
        store = connection.store
        self.next = next
    }

    var body: some View {
        PageHeader(symbol: "shippingbox", title: "Install clothod",
                   text: "clothod is the small program that keeps your shells and agents running on \(connection.machine.displayName). Clotho installs the version it carries in your user's own folders there (no admin rights needed), or uses the one already installed, and starts it.")
        switch store.connection {
        case .connected:
            Label("clothod \(store.hello?.version ?? "") is running on \(connection.machine.displayName).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("clothodRunning")
                .task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    next()
                }
        case .reconnecting(let reason):
            ErrorNote(text: reason)
            Text("Clotho keeps trying. Fix the problem on the machine, or go on and come back to it later.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Continue Anyway", action: next).buttonStyle(.bordered)
        case .connecting(let step):
            HStack(spacing: 10) { ProgressView(); Text(step).foregroundStyle(.secondary) }
        case .idle:
            HStack(spacing: 10) { ProgressView(); Text("Starting…").foregroundStyle(.secondary) }
        }
        Color.clear.frame(height: 0).onAppear { connection.connect() }
    }
}

// MARK: - Done

private struct DonePage: View {
    let machine: Machine
    let mode: OnboardingView.Mode
    let open: () -> Void

    var body: some View {
        PageHeader(symbol: "checkmark.circle", title: "\(machine.displayName) is ready",
                   text: "Its workspaces show on Home; tap + there to start one. Agents that need you appear at the top. Add more machines with + at the top of Home.")
        PrimaryButton(title: "Open Home", action: open)
            .accessibilityIdentifier("openMachine")
    }
}
