import ClothoKit
import SwiftUI
import UIKit
import UserNotifications

/// The Settings tab (a sheet on the iPad): what used to sit in menus and sheets around Home. Notifications and
/// each machine's alerts, each machine's summaries (Claude Haiku on the machine) and agent status, the app's
/// appearance, each machine's own settings, the welcome guide, and the versions.
struct SettingsView: View {
    @EnvironmentObject private var machines: MachineList
    @EnvironmentObject private var connections: Connections
    @EnvironmentObject private var navigator: Navigator
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system
    @State private var notifications: UNAuthorizationStatus?

    var body: some View {
        Form {
            notificationsSection
            summariesSection
            agentStatusSection
            Section("Display") {
                Picker(selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                .accessibilityIdentifier("appearancePicker")
                KeepPreviewsToggle()
            }
            if !machines.all.isEmpty {
                Section {
                    ForEach(machines.all) { machine in
                        NavigationLink {
                            MachineSettingsView(connection: connections.connection(for: machine))
                        } label: {
                            Label(machine.displayName, systemImage: machine.kind == .localSocket ? "laptopcomputer" : "server.rack")
                        }
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("Each machine's scrollback and start at login. They live on the machine, so every device sees the same.")
                }
            }
            Section {
                Button { navigator.guide = .firstRun } label: { Label("Welcome Guide", systemImage: "questionmark.circle") }
            }
            aboutSection
        }
        .navigationTitle("Settings")
        .onChange(of: appearance) { AppearanceChoice.applyToAllWindows() }
        .task { await readNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await readNotifications() }
        }
    }

    private func readNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            switch notifications {
            case .authorized, .provisional, .ephemeral:
                Label("Notifications are on", systemImage: "bell.badge")
            case .denied:
                Button { openSystemSettings() } label: { Label("Turn On in Settings", systemImage: "bell.slash") }
            case .notDetermined:
                Button {
                    Task { _ = await AgentNotifier.shared.requestPermission(); await readNotifications() }
                } label: { Label("Allow Notifications", systemImage: "bell") }
            default:
                ProgressView()
            }
            ForEach(machines.all.filter { $0.kind == .ssh }) { machine in
                Toggle(isOn: Binding(get: { machine.alerts ?? true }, set: { on in
                    var changed = machine
                    changed.alerts = on
                    machines.save(changed)
                })) {
                    Text("Alerts from \(machine.displayName)")
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Clotho tells you when an agent needs you or finishes. With alerts on, a machine also reaches this iPhone while Clotho is closed, encrypted end to end.")
        }
    }

    // MARK: Summaries

    private var connected: [MachineConnection] {
        machines.all.map { connections.connection(for: $0) }.filter { $0.store.isConnected }
    }

    @ViewBuilder private var summariesSection: some View {
        let live = connected
        Section {
            if live.isEmpty {
                Text("Connect to a machine to change this.").foregroundStyle(.secondary)
            }
            ForEach(live, id: \.machine.id) { connection in
                SummaryToggle(connection: connection)
            }
        } header: {
            Text("Summarize Agent Messages")
        } footer: {
            Text("Claude Haiku, on each machine with its own Claude login, rewrites what an agent said into a sentence or two for notifications and the Agents list. Off: the message itself, without Markdown. A permission request always shows its exact command too.")
        }
    }

    // MARK: Agent status

    private var agentStatusSection: some View {
        Section {
            Text("Claude Code and Codex report working, waiting and done through hooks on each machine. Set them up from the Mac app (Set Up Agent Status…), or run clothod hooks install claude (and codex) on the machine.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Agent Status")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Clotho", value: Self.appVersion)
            if let clothod = Self.bundledClothod {
                LabeledContent("clothod in this app", value: clothod)
            }
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// The clothod version this app installs on machines (its packed dist's manifest).
    static var bundledClothod: String? {
        guard let url = Bundle.main.url(forResource: "dist", withExtension: nil)?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// One machine's "Summarize agent messages" switch (`notification_rewrite`, clothod 0.1.29). It lives on the
/// machine, so the Mac and every phone see the same.
private struct SummaryToggle: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore
    @State private var busy = false
    @State private var error: String?

    init(connection: MachineConnection) {
        self.connection = connection
        store = connection.store
    }

    private var name: String { connection.machine.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.hello?.features.contains(.summary) != true {
                LabeledContent(name, value: "Update clothod")
                    .foregroundStyle(.secondary)
            } else if let on = store.settings?.notificationRewrite {
                Toggle(name, isOn: Binding(get: { on }, set: { change($0) }))
                    .disabled(busy)
                    .accessibilityIdentifier("summarize-\(name)")
            } else {
                LabeledContent(name) { ProgressView() }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: store.hello?.instance) {
            guard store.hello?.features.contains(.settings) == true else { return }
            do { _ = try await store.loadSettings() } catch { self.error = error.localizedDescription }
        }
    }

    private func change(_ on: Bool) {
        busy = true
        error = nil
        Task {
            do { _ = try await store.changeSettings(.init(notificationRewrite: on)) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
