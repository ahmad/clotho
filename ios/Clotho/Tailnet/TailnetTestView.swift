#if CLOTHO_TAILNET
import SwiftUI

/// The debug Tailnet Test screen (Settings > Developer, or -TailnetTest YES at launch): Phase 0 of PLAN.md's
/// "Built-in Tailscale". Only CLOTHO_TAILNET=1 builds have it. See TailnetController for what it runs.
struct TailnetTestView: View {
    @ObservedObject var tailnet = TailnetController.shared
    @State private var controlURL = UserDefaults.standard.string(forKey: "TailnetControlURL") ?? ""
    @State private var dialHost = ""
    @State private var dialPort = "22"
    @State private var dialResult: String?
    @State private var dialing = false
    @State private var footprint = TailnetController.footprintMB

    var body: some View {
        Form {
            nodeSection
            peersSection
            dialSection
            foregroundSection
        }
        .navigationTitle("Tailnet Test")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Peers and memory, every 2 s while the screen is up.
            while !Task.isCancelled {
                await tailnet.refresh()
                footprint = TailnetController.footprintMB
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: Node

    private var nodeSection: some View {
        Section {
            LabeledContent("State") {
                Text(tailnet.stateText).accessibilityIdentifier("tailnet.state")
            }
            if let name = tailnet.selfName {
                LabeledContent("Name", value: name)
            }
            if !tailnet.selfIPs.isEmpty {
                LabeledContent("Addresses", value: tailnet.selfIPs.joined(separator: "\n"))
            }
            TextField("Tailscale", text: $controlURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(tailnet.hasNode)
                .accessibilityIdentifier("tailnet.controlURL")
                .accessibilityLabel("Control server")
            LabeledContent("Node dir") {
                Text(tailnet.settings.dir.path).font(.caption).lineLimit(2).truncationMode(.middle)
            }
            Button(tailnet.hasNode ? "Stop" : "Start") {
                if tailnet.hasNode { tailnet.stop() } else { start() }
            }
            .accessibilityIdentifier("tailnet.start")
            if tailnet.needsLogin || tailnet.signingIn {
                Button("Sign In…") { tailnet.startSignIn() }
                    .disabled(tailnet.signingIn)
                    .accessibilityIdentifier("tailnet.signIn")
            }
            if tailnet.isRunning {
                Button("Sign Out", role: .destructive) { tailnet.signOut() }
            }
            if let seconds = tailnet.startToRunning {
                LabeledContent("Start to Running", value: String(format: "%.2f s", seconds))
            }
            if let line = tailnet.launchLine {
                Text(line).font(.caption)
            }
            LabeledContent("Memory", value: String(format: "%.1f MB", footprint))
            if let error = tailnet.lastError {
                Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("tailnet.error")
            }
        } header: {
            Text("Node")
        } footer: {
            Text("An empty control server is Tailscale's. A loopback one (clothod's testctl) is test mode, which stays on until Clotho is relaunched.")
        }
    }

    private func start() {
        let trimmed = controlURL.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed, forKey: "TailnetControlURL")
        var settings = TailnetSettings.fromDefaults()
        settings.controlURL = trimmed.isEmpty ? nil : URL(string: trimmed)
        if tailnet.testModeUsed, !settings.testMode {
            tailnet.lastError = "Test mode was on in this run: relaunch Clotho before using another control server"
            return
        }
        tailnet.settings = settings
        tailnet.start()
    }

    // MARK: Peers

    private var peersSection: some View {
        Section("Peers") {
            if tailnet.peers.isEmpty {
                Text(tailnet.isRunning ? "No other devices" : "None").foregroundStyle(.secondary)
            }
            ForEach(tailnet.peers) { peer in
                Button {
                    dialHost = peer.ip
                } label: {
                    HStack {
                        Image(systemName: peer.online ? "circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(peer.online ? .green : .secondary)
                        Text(peer.name)
                        Spacer()
                        Text(peer.ip).foregroundStyle(.secondary).font(.callout.monospaced())
                    }
                }
                .accessibilityIdentifier("tailnet.peer.\(peer.name)")
            }
        }
    }

    // MARK: Dial

    private var dialSection: some View {
        Section {
            TextField("Peer name or 100.x address", text: $dialHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("tailnet.dialHost")
            TextField("Port", text: $dialPort)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("tailnet.dialPort")
            Button("Dial") {
                run { host, port in await tailnet.dial(host: host, port: port) }
            }
            .disabled(!tailnet.isRunning || dialing)
            .accessibilityIdentifier("tailnet.dial")
            Button("SSH Handshake") {
                run { host, port in
                    do { return "Host key \(try await tailnet.sshHandshake(host: host, port: port))" } catch {
                        return "Failed: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(!tailnet.isRunning || dialing)
            .accessibilityIdentifier("tailnet.sshHandshake")
            if let dialResult {
                Text(dialResult).font(.callout.monospaced()).textSelection(.enabled).accessibilityIdentifier("tailnet.dialResult")
            }
            Toggle("Route SSH through this node", isOn: $tailnet.routeSSH)
                .accessibilityIdentifier("tailnet.routeSSH")
        } header: {
            Text("Dial")
        } footer: {
            Text("While routing is on, every machine's SSH goes over the tailnet, until it's turned off.")
        }
    }

    private func run(_ body: @escaping (String, Int) async -> String) {
        let host = dialHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(dialPort), (1...65535).contains(port) else {
            dialResult = "Enter a peer and a port"
            return
        }
        dialing = true
        dialResult = "Dialing \(host):\(port)…"
        Task {
            dialResult = await body(host, port)
            dialing = false
        }
    }

    // MARK: Foreground

    private var foregroundSection: some View {
        Section {
            Toggle("Treat node as dead on next foreground", isOn: $tailnet.forceUnhealthyOnForeground)
                .accessibilityIdentifier("tailnet.forceDead")
            TextField("Probe host:port", text: $tailnet.probeTarget)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("tailnet.probe")
            Button("Recreate Now") { tailnet.recreate() }
                .disabled(!tailnet.hasNode)
            ForEach(Array(tailnet.timings.enumerated()), id: \.element.id) { index, timing in
                VStack(alignment: .leading, spacing: 2) {
                    Text(timing.at, style: .time).font(.caption).foregroundStyle(.secondary)
                    Text(timing.summary).font(.callout)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(index == 0 ? "tailnet.lastTiming" : "tailnet.timing")
            }
            if !tailnet.timings.isEmpty {
                Button("Clear Timings", role: .destructive) { tailnet.clearTimings() }
            }
        } header: {
            Text("Foreground")
        } footer: {
            Text("On every return to the foreground the node is checked (Running, and a status call within 2 s) and the probe target dialed; a dead node is recreated from its Keychain state, without signing in again.")
        }
    }
}
#endif
