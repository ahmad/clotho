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

    enum Step: Int, Comparable {
        case welcome, concepts, machine, key, hostKey, logIn, install, notifications, login, done
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    let mode: Mode
    /// Called when the guide closes, with the machine it set up (if it got that far).
    let finish: (UUID?) -> Void

    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @State private var step: Step
    @State private var machine = Machine(name: "", devDirs: MachineListView.defaultDevDirs)
    @State private var port = "22"
    @State private var saved = false

    init(mode: Mode, finish: @escaping (UUID?) -> Void) {
        self.mode = mode
        self.finish = finish
        _step = State(initialValue: mode == .firstRun ? .welcome : .machine)
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
        let first: Step = mode == .firstRun ? .welcome : .machine
        guard step != .done else { return nil }
        return Double(step.rawValue - first.rawValue + 1) / Double(Step.done.rawValue - first.rawValue + 1)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: WelcomePage { step = .concepts }
        case .concepts: ConceptsPage { step = .machine }
        case .machine: MachinePage(machine: $machine, port: $port) { advance(from: .machine) }
        case .key: KeyPage(machine: $machine) { step = .hostKey }
        case .hostKey: HostKeyPage(machine: machine, back: { step = .machine }) { step = .logIn }
        case .logIn: LogInPage(machine: machine, back: { step = .key }) { save(); step = .install }
        case .install: InstallPage(connection: connections.connection(for: machine)) { advance(from: .install) }
        case .notifications: NotificationsPage { step = .login }
        case .login: LoginPage(connection: connections.connection(for: machine)) { step = .done }
        case .done: DonePage(machine: machine, mode: mode) { close(openMachine: true) }
        }
    }

    private func advance(from current: Step) {
        switch current {
        case .machine:
            machine.port = Int(port) ?? 22
            machine.host = machine.host.trimmingCharacters(in: .whitespaces)
            machine.user = machine.user.trimmingCharacters(in: .whitespaces)
            step = .key
        case .install:
            // The permission prompt comes once there's a machine whose agents can need the user.
            Task {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                step = status == .notDetermined ? .notifications : .login
            }
        default:
            break
        }
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

// MARK: - Intro

private struct WelcomePage: View {
    let next: () -> Void

    var body: some View {
        PageHeader(symbol: "rectangle.split.2x2", title: "Welcome to Clotho",
                   text: "Your terminals and coding agents, on every machine you use, from this device. Shells and agents keep running on the machine when Clotho closes, and pick up where they were when it opens.")
        VStack(alignment: .leading, spacing: 12) {
            Point(symbol: "server.rack", text: "Connects to your Macs and Linux machines over SSH.")
            Point(symbol: "bell.badge", text: "Tells you when an agent like Claude Code or Codex needs you, even while Clotho is closed.")
            Point(symbol: "lock", text: "Keys stay in this device's Keychain. Alerts are encrypted on the machine for this device only.")
        }
        PrimaryButton(title: "Get Started", action: next)
    }
}

private struct Point: View {
    let symbol: String
    let text: String

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(Color.selection).frame(width: 28) }
    }
}

private struct ConceptsPage: View {
    let next: () -> Void

    var body: some View {
        PageHeader(symbol: "square.stack.3d.up", title: "Workspaces, Tabs and Panes",
                   text: "Every machine runs clothod, which keeps your shells in three levels.")
        ConceptRow(title: "Workspace", symbol: "folder",
                   text: "One project or task: a set of tabs, often in one folder. Switch between workspaces on each machine.")
        ConceptRow(title: "Tab", symbol: "rectangle.on.rectangle",
                   text: "A layout of panes side by side, like a window on your computer.")
        ConceptRow(title: "Pane", symbol: "terminal",
                   text: "One shell or agent. Here a pane fills the screen; swipe the pane strip to switch. Panes keep running when you close the app.")
        PrimaryButton(title: "Add a Machine", action: next)
    }
}

private struct ConceptRow: View {
    let title: String
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.selection)
                .frame(width: 44, height: 44)
                .background(Color.selection.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Machine

private struct MachinePage: View {
    @Binding var machine: Machine
    @Binding var port: String
    let next: () -> Void

    private var host: String { machine.host.trimmingCharacters(in: .whitespaces) }
    private var user: String { machine.user.trimmingCharacters(in: .whitespaces) }
    private var problem: String? { host.isEmpty && user.isEmpty ? nil : Machine.problem(host: host, user: user) }

    private var valid: Bool {
        !host.isEmpty && !user.isEmpty && problem == nil && Int(port).map { (1...65535).contains($0) } == true
    }

    var body: some View {
        PageHeader(symbol: "server.rack", title: "Add a machine",
                   text: "Any Mac or Linux machine you can reach with SSH from this device: on the same network, or over Tailscale or a VPN. On a Mac, turn on System Settings › General › Sharing › Remote Login.")
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
        PrimaryButton(title: "Continue", enabled: valid, action: next)
    }
}

// MARK: - Key

private struct KeyPage: View {
    @Binding var machine: Machine
    let next: () -> Void
    @State private var keys: [SSHKey] = KeyStore.all()
    @State private var importing = false
    @State private var error: String?

    private var key: SSHKey? { keys.first { $0.id == machine.keyID } }

    var body: some View {
        PageHeader(symbol: "key", title: "Log in with a key",
                   text: "Clotho logs in with an SSH key kept in this device's Keychain. Make a new one here (recommended), or import one you already use.")
        if let key {
            PublicKeyCard(key: key, user: machine.user, host: machine.host)
            Button("Use a different key") { machine.keyID = nil }
                .font(.callout)
            PrimaryButton(title: "I've Added the Key", action: next)
        } else {
            if !keys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keys on this device").font(.subheadline.weight(.medium))
                    ForEach(keys) { key in
                        Button { machine.keyID = key.id } label: {
                            Label("\(key.name) (\(key.kindLabel))", systemImage: "key.horizontal")
                        }
                    }
                }
            }
            PrimaryButton(title: "Generate New Key") { generate(.ed25519) }
                .accessibilityIdentifier("generateKey")
            if KeyStore.secureEnclaveAvailable {
                Button("Generate in the Secure Enclave") { generate(.secureEnclaveP256) }
                    .font(.callout)
                Text("A Secure Enclave key can never leave this device. Some servers (older OpenSSH, Tailscale SSH aside) don't accept its type, so Ed25519 is the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { importing = true } label: { Label("Import an Existing Key…", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("importKey")
        }
        if let error { ErrorNote(text: error) }
        Color.clear.frame(height: 0)
            .sheet(isPresented: $importing) {
                KeyImportSheet { imported in
                    keys = KeyStore.all()
                    machine.keyID = imported.id
                }
            }
    }

    private func generate(_ kind: SSHKey.Kind) {
        do {
            let key = try KeyStore.generate(kind: kind, name: "clotho-\(UIDevice.current.name)".replacingOccurrences(of: " ", with: "-"))
            keys = KeyStore.all()
            machine.keyID = key.id
            error = nil
        } catch {
            self.error = "Couldn't make a key: \(error.localizedDescription)"
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
            PrimaryButton(title: "Install clothod", action: next)
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
            PrimaryButton(title: "Continue", action: next)
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

// MARK: - Notifications and login

private struct NotificationsPage: View {
    let next: () -> Void

    var body: some View {
        PageHeader(symbol: "bell.badge", title: "Know when an agent needs you",
                   text: "When an agent on one of your machines finishes, asks a question or hits an error, Clotho can tell you, even while it's closed. The lock screen shows the agent's message, decrypted on this device.")
        PrimaryButton(title: "Allow Notifications") {
            Task {
                await AgentNotifier.shared.requestPermission()
                next()
            }
        }
        .accessibilityIdentifier("allowNotifications")
        Button("Not Now", action: next)
            .frame(maxWidth: .infinity)
        Text("You can change this later in Settings › Clotho › Notifications, and turn alerts off per machine.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct LoginPage: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    let next: () -> Void
    @State private var busy = false
    @State private var error: String?

    init(connection: MachineConnection, next: @escaping () -> Void) {
        self.connection = connection
        store = connection.store
        self.next = next
    }

    private var name: String { connection.machine.displayName }
    private var supported: Bool { store.hello?.features.contains(.service) == true }

    var body: some View {
        PageHeader(symbol: "power", title: "Start clothod at login",
                   text: "Then your shells and agents on \(name) come back by themselves after it restarts, before any app connects.")
        if connection.machine.isTestInstall {
            Text("\(name) uses this app's test install of clothod, which never starts at login.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("loginUnavailable")
            PrimaryButton(title: "Continue", action: next)
        } else if !store.isConnected || !supported {
            Text(store.isConnected ? "Update clothod on \(name) to turn this on from here." : "Once Clotho is connected to \(name), turn this on in the machine's Settings.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("loginUnavailable")
            PrimaryButton(title: "Continue", action: next)
        } else if let service = store.service {
            if service.installed {
                Label("clothod starts at login on \(name).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                PrimaryButton(title: "Continue", action: next)
            } else if LoginService.canToggle(service, testInstall: false) {
                PrimaryButton(title: "Start at Login", enabled: !busy) { turnOn() }
                Button("Not Now", action: next).frame(maxWidth: .infinity)
            } else {
                Text(LoginService.footer(service, machine: name, testInstall: false)).foregroundStyle(.secondary)
                PrimaryButton(title: "Continue", action: next)
            }
        } else if let error {
            ErrorNote(text: error)
            PrimaryButton(title: "Continue", action: next)
        } else {
            ProgressView()
        }
        Color.clear.frame(height: 0).task(id: store.hello?.instance) { await load() }
    }

    private func load() async {
        guard store.isConnected, supported, !connection.machine.isTestInstall else { return }
        do { try await store.loadService() } catch { self.error = error.localizedDescription }
    }

    private func turnOn() {
        busy = true
        Task {
            do {
                _ = try await store.setStartsAtLogin(true)
                next()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct DonePage: View {
    let machine: Machine
    let mode: OnboardingView.Mode
    let open: () -> Void

    var body: some View {
        PageHeader(symbol: "checkmark.circle", title: "\(machine.displayName) is ready",
                   text: "Open it to start a workspace. Agents that need you show at the top of the Machines list. Add more machines with +, and reopen this guide from the ? button.")
        PrimaryButton(title: "Open \(machine.displayName)", action: open)
            .accessibilityIdentifier("openMachine")
    }
}
