import ClothoKit
import SwiftUI

/// One machine's clothod settings (protocol.md "Settings" and "Start at login"): how much history each pane
/// keeps, and whether clothod starts when the user logs in there. Both live on the machine, so every client
/// sees the same values.
struct MachineSettingsView: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @State private var error: String?
    @State private var busy = false

    init(connection: MachineConnection) {
        self.connection = connection
        store = connection.store
    }

    private var features: Set<Hello.Feature> { store.hello?.features ?? [] }
    private var name: String { connection.machine.displayName }

    var body: some View {
        List {
            if !store.isConnected {
                Section { Text("Connect to \(name) to see its settings.").foregroundStyle(.secondary) }
            } else {
                scrollbackSection
                loginSection
            }
            if let error {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.hello?.instance) { await load() }
    }

    private func load() async {
        guard store.isConnected else { return }
        do {
            if features.contains(.settings) { try await store.loadSettings() }
            if features.contains(.service) { try await store.loadService() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    // MARK: Scrollback

    @ViewBuilder private var scrollbackSection: some View {
        Section {
            if !features.contains(.settings) {
                Text("Update clothod on \(name) to change its scrollback here.").foregroundStyle(.secondary)
            } else if let settings = store.settings {
                Picker("Scrollback", selection: Binding(get: { settings.scrollbackLines }, set: { lines in
                    perform { _ = try await store.changeSettings(.init(scrollbackLines: lines)) }
                })) {
                    ForEach(ScrollbackChoices.values(current: settings.scrollbackLines, range: settings.limits.scrollbackLines), id: \.self) { lines in
                        Text(ScrollbackChoices.label(lines, default: settings.limits.scrollbackLines.default)).tag(lines)
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("scrollbackPicker")
            } else {
                ProgressView()
            }
        } header: {
            Text("Scrollback")
        } footer: {
            if let settings = store.settings, features.contains(.settings) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History each pane keeps on \(name). It costs about 3 MB per 1,000 lines for every pane that fills it (at 120 columns): \(ScrollbackChoices.memory(settings.scrollbackLines)) per pane now. Lowering it drops older history at once.")
                    if let config = settings.config {
                        Text(config).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Start at login

    @ViewBuilder private var loginSection: some View {
        if features.contains(.service) {
            Section {
                if let service = store.service {
                    Toggle("Start clothod at login", isOn: Binding(get: { service.installed }, set: { on in
                        perform { _ = try await store.setStartsAtLogin(on) }
                    }))
                    .disabled(busy || !LoginService.canToggle(service, testInstall: connection.machine.isTestInstall))
                    .accessibilityIdentifier("startAtLogin")
                    if service.installed && !service.upToDate {
                        Button("Refresh Login Item") { perform { _ = try await store.setStartsAtLogin(true) } }
                            .disabled(busy)
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Login")
            } footer: {
                if let service = store.service {
                    Text(LoginService.footer(service, machine: name, testInstall: connection.machine.isTestInstall))
                }
            }
        } else {
            Section("Login") {
                Text("Update clothod on \(name) to start it at login from here.").foregroundStyle(.secondary)
            }
        }
    }
}

/// The scrollback picker's values: round sizes within the daemon's limits, plus the current value.
enum ScrollbackChoices {
    static func values(current: Int, range: DaemonSettings.Range) -> [Int] {
        let presets = [0, 1000, 2000, 5000, 10000, 20000, 50000, range.default, current]
        return Array(Set(presets.filter { $0 >= range.min && $0 <= range.max })).sorted()
    }

    static func label(_ lines: Int, default: Int) -> String {
        let text = lines == 0 ? "None" : "\(lines.formatted()) lines"
        return lines == `default` ? text + " (default)" : text
    }

    /// clothod's measurement: about 8 MB at 2,000 lines, 31 MB at 10,000, 142 MB at 50,000, per full pane.
    static func memory(_ lines: Int) -> String {
        let mb = max(1, Int((Double(lines) * 0.0029).rounded()))
        return lines == 0 ? "almost nothing" : "about \(mb) MB"
    }
}

/// When the toggle works, and what to say under it.
enum LoginService {
    static func canToggle(_ service: DaemonService, testInstall: Bool) -> Bool {
        service.supported && !testInstall && (service.installed || service.needs.isEmpty)
    }

    static func footer(_ service: DaemonService, machine: String, testInstall: Bool) -> String {
        if testInstall {
            return "\(machine) uses this app's test install of clothod, which never starts at login."
        }
        if let message = service.message, !message.isEmpty, !service.supported || !service.needs.isEmpty {
            return message
        }
        let manager = service.manager == "systemd" ? "a systemd user service" : service.manager == "launchd" ? "a launchd agent" : "a login item"
        if service.installed && !service.upToDate {
            return "clothod starts at login on \(machine) through \(manager), which points at an older clothod. Refresh it to use the current one."
        }
        return service.installed
            ? "clothod starts at login on \(machine) through \(manager), so agents and shells are up before any app connects. Turning it off never stops clothod."
            : "Otherwise clothod starts when an app connects to \(machine)."
    }
}

extension Machine {
    /// A daemon this app started for testing (the dev install dirs, or the simulator's "Local Mac (dev)"),
    /// which must never become a login item.
    var isTestInstall: Bool { devDirs == true || kind == .localSocket }
}

