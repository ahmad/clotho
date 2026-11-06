#if CLOTHO_TAILNET
import AppKit
import ClothoTailnet
import Darwin

// The dev build's Tailnet Test window (Help > Tailnet Test…): Phase 0 of PLAN.md's "Built-in Tailscale". It
// exists only in Clotho Dev.app built with CLOTHO_TAILNET=1 (build-app.sh --dev), never in the user's app.
//
// It runs Clotho's own tailnet node, signs it in, shows its peers, dials <peer>:<port> and shows what the peer
// says first, and serves the node's ssh proxy socket (<node dir>/proxy.sock) for clotho-tailnet-proxy, which
// "Route SSH through this node" sets as the dev build's SSH ProxyCommand.
//
// Dev defaults (`defaults write app.clotho.desktop.dev <key> <value>`):
//   TailnetDir         the node's dir (default ~/Library/Application Support/Clotho/tailscale-dev)
//   TailnetControlURL  a control server; a loopback one (clothod's testctl) turns test mode on
//   TailnetAutoStart   YES: start the node at launch (for measurements)
//   TailnetVerbose     YES: the node's own log lines go to the app log

extension AppDelegate {
    @objc func showTailnetTest(_ sender: Any?) {
        TailnetTestController.shared.showWindow()
    }
}

@MainActor
final class TailnetTestController: NSObject, NSWindowDelegate {
    static let shared = TailnetTestController()

    /// From applicationDidFinishLaunching: starts the node when TailnetAutoStart is set, and stops it at quit.
    static func appLaunched() {
        guard isDevBuild else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shared.stop() }
        }
        if UserDefaults.standard.bool(forKey: "TailnetAutoStart") { shared.start() }
    }

    private let defaults = UserDefaults.standard
    private(set) var node: TailnetNode?
    private var proxy: TailnetProxyServer?
    private var startedAt: Date?
    private var reportedRunning = false
    private var lastError: String?
    private var peers: [TailnetStatus.Peer] = []
    private var me: TailnetStatus.Peer?
    private var refreshTimer: Timer?

    private var window: NSWindow?
    // Wraps, as dialResult does: "Connected as <MagicDNS name> <address>" and errors are often wider than the window.
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let controlLabel = NSTextField(labelWithString: "")
    private let dirLabel = NSTextField(labelWithString: "")
    private lazy var startButton = NSButton(title: "Start", target: self, action: #selector(toggleNode))
    private lazy var signInButton = NSButton(title: "Sign In…", target: self, action: #selector(signIn))
    private lazy var signOutButton = NSButton(title: "Sign Out", target: self, action: #selector(signOut))
    private let peersLabel = NSTextField(wrappingLabelWithString: "")
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "22")
    private lazy var dialButton = NSButton(title: "Dial", target: self, action: #selector(dial))
    private let dialResult = NSTextField(wrappingLabelWithString: "")
    private lazy var routeSSH = NSButton(checkboxWithTitle: "Route SSH through this node", target: self, action: #selector(toggleRoute))
    private let routeNote = NSTextField(wrappingLabelWithString: "")

    // MARK: Configuration

    var nodeDir: URL {
        if let dir = defaults.string(forKey: "TailnetDir"), !dir.isEmpty { return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
        // Files, not the Keychain (PLAN decision 3); the dev build keeps a node of its own.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Clotho").appendingPathComponent(isDevBuild ? "tailscale-dev" : "tailscale")
    }

    var controlURL: URL? {
        guard let s = defaults.string(forKey: "TailnetControlURL"), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// A control server on this machine (clothod's testctl): test mode, which the shim refuses otherwise.
    var testMode: Bool { ["127.0.0.1", "localhost", "::1"].contains(controlURL?.host ?? "") }

    var socketPath: String { nodeDir.appendingPathComponent("proxy.sock").path }

    var helperPath: String { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("clotho-tailnet-proxy").path }

    /// The dev build's SSHProxyCommand for this node (AppDelegate.sshProxyOptions).
    var proxyCommand: String { "'\(helperPath)' --socket '\(socketPath)' %h %p" }

    // MARK: The node

    func start() {
        guard node == nil else { return }
        lastError = nil
        reportedRunning = false
        let hostname = TailnetNode.defaultHostname(device: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, dev: isDevBuild)
        var nodeLog: (@Sendable (String) -> Void)?
        if defaults.bool(forKey: "TailnetVerbose") {
            nodeLog = { line in log("tailnet node: \(line)") }
        }
        let node = TailnetNode(configuration: TailnetNode.Configuration(
            dir: nodeDir, hostname: hostname, controlURL: controlURL,
            // A dev node (PLAN decision 5): control forgets it soon after it goes offline.
            ephemeral: true, testMode: testMode, log: nodeLog))
        node.onStateChange = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        let t0 = Date()
        do {
            try node.start()
        } catch {
            lastError = error.localizedDescription
            log("tailnet: can't start: \(error.localizedDescription)")
            update()
            return
        }
        self.node = node
        startedAt = t0
        log("tailnet: starting \(hostname) in \(nodeDir.path), control \(controlURL?.absoluteString ?? "Tailscale")")
        let proxy = TailnetProxyServer(node: node, socketPath: socketPath, log: { line in log(line) })
        do {
            try proxy.start()
            self.proxy = proxy
        } catch {
            lastError = "SSH proxy: \(error.localizedDescription)"
            log("tailnet: \(lastError!)")
        }
        update()
    }

    func stop() {
        guard let node else { return }
        proxy?.stop()
        proxy = nil
        // Returns at once; the node shuts down in the background (tailscale#21353).
        node.stop()
        self.node = nil
        peers = []
        me = nil
        log("tailnet: stopped")
        update()
    }

    private func stateChanged(_ state: TailnetNode.State) {
        guard node != nil else { return }
        log("tailnet: state \(state)")
        if state == .running, !reportedRunning, let startedAt {
            reportedRunning = true
            log("tailnet: Running after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
        }
        refreshPeers()
        update()
    }

    private func refreshPeers() {
        guard let node, node.state == .running else { return }
        Task { [weak self] in
            guard let status = try? await node.status() else { return }
            await MainActor.run {
                guard let self, self.node === node else { return }
                self.peers = status.peers
                self.me = status.selfNode
                self.update()
            }
        }
    }

    // MARK: Actions

    @objc private func toggleNode() {
        if node == nil { start() } else { stop() }
    }

    @objc private func signIn() {
        guard let node else { return }
        if case .needsLogin(let url?) = node.state {
            NSWorkspace.shared.open(url)
            return
        }
        Task { [weak self] in
            do {
                if let url = try await node.login() { NSWorkspace.shared.open(url) }
            } catch {
                await MainActor.run { self?.lastError = error.localizedDescription; self?.update() }
            }
        }
    }

    @objc private func signOut() {
        guard let node else { return }
        Task { [weak self] in
            do { try await node.logout() } catch {
                await MainActor.run { self?.lastError = error.localizedDescription; self?.update() }
            }
        }
    }

    @objc private func dial() {
        guard let node else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(portField.stringValue), (1...65535).contains(port) else {
            dialResult.stringValue = "Enter a peer and a port"
            return
        }
        dialResult.stringValue = "Dialing \(host):\(port)…"
        dialButton.isEnabled = false
        Task { [weak self] in
            let t0 = Date()
            let text: String
            do {
                let fd = try await node.dial(host: host, port: port, timeout: 10)
                let connected = Date().timeIntervalSince(t0)
                let first = await Task.detached { Self.readFirstLine(fd) }.value
                text = "\(first ?? "Connected, nothing received in 3 s") (\(Int(connected * 1000)) ms)"
            } catch {
                text = "Failed: \(error.localizedDescription)"
            }
            log("tailnet: dial \(host):\(port): \(text)")
            await MainActor.run {
                self?.dialResult.stringValue = text
                self?.dialButton.isEnabled = true
            }
        }
    }

    /// Up to 256 bytes within 3 s, the first line of them; closes the descriptor.
    nonisolated private static func readFirstLine(_ fd: Int32) -> String? {
        defer { close(fd) }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 3000) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(n), as: UTF8.self).components(separatedBy: .newlines).first
    }

    @objc private func toggleRoute() {
        if routeSSH.state == .on {
            defaults.set(proxyCommand, forKey: "SSHProxyCommand")
            defaults.set(true, forKey: "SSHProxyUseFdpass")
        } else {
            defaults.removeObject(forKey: "SSHProxyCommand")
            defaults.removeObject(forKey: "SSHProxyUseFdpass")
        }
        log("tailnet: route SSH through the node: \(routeSSH.state == .on) (after a relaunch)")
        update()
    }

    // MARK: Window

    func showWindow() {
        if window == nil { makeWindow() }
        update()
        refreshPeers()
        window?.makeKeyAndOrderFront(nil)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { TailnetTestController.shared.refreshPeers() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Tailnet Test"
        window.isReleasedWhenClosed = false
        window.delegate = self

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        for label in [controlLabel, dirLabel, routeNote, peersLabel, dialResult] {
            label.textColor = .secondaryLabelColor
        }
        dirLabel.lineBreakMode = .byTruncatingMiddle
        controlLabel.lineBreakMode = .byTruncatingMiddle
        // One-line labels truncate rather than widen the window (which holds its size at priority 500).
        for label in [controlLabel, dirLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        stateLabel.isSelectable = true
        dialResult.isSelectable = true
        peersLabel.isSelectable = true
        stateLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium)
        hostField.placeholderString = "Peer name or 100.x address"
        portField.placeholderString = "Port"
        portField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let buttons = NSStackView(views: [startButton, signInButton, signOutButton])
        let dialRow = NSStackView(views: [hostField, portField, dialButton])
        let stack = NSStackView(views: [
            stateLabel, controlLabel, dirLabel, buttons,
            header("Peers"), peersLabel,
            header("Dial"), dialRow, dialResult,
            header("SSH"), routeSSH, routeNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: buttons)
        stack.setCustomSpacing(16, after: peersLabel)
        stack.setCustomSpacing(16, after: dialResult)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            stateLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            controlLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
            peersLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            routeNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            dirLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
            dialResult.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        // The window never gets narrower than its widest fixed row plus the margins (the labels wrap or truncate).
        let minWidth = [buttons, dialRow, routeSSH].map(\.fittingSize.width).max()! + 40
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        window.contentView = content
        window.contentMinSize = NSSize(width: minWidth, height: 0)
        window.center()
        self.window = window
    }

    private func update() {
        guard window != nil else { return }
        let state = node?.state ?? .stopped
        var line: String
        switch state {
        case .stopped: line = "Stopped"
        case .starting: line = "Starting…"
        case .needsLogin: line = "Needs sign-in: sign in with your Tailscale account"
        case .needsMachineAuth: line = "Needs approval in the tailnet's admin console"
        case .running: line = "Connected" + (me.map { " as \($0.dnsName.isEmpty ? $0.hostName : $0.dnsName) \($0.primaryIP ?? "")" } ?? "")
        case .expired: line = "Key expired: sign in again"
        }
        if let lastError { line += " — \(lastError)" }
        stateLabel.stringValue = line
        controlLabel.stringValue = "Control server: " + (controlURL.map { "\($0.absoluteString)\(testMode ? " (test)" : "")" } ?? "Tailscale")
        dirLabel.stringValue = "Node dir: \(nodeDir.path)"
        startButton.title = node == nil ? "Start" : "Stop"
        var canSignIn = false
        if case .needsLogin = state { canSignIn = true }
        if state == .expired { canSignIn = true }
        signInButton.isEnabled = node != nil && canSignIn
        signOutButton.isEnabled = node != nil && state == .running
        dialButton.isEnabled = node != nil && state == .running
        peersLabel.stringValue = peers.isEmpty ? (state == .running ? "No other devices" : "—") : peers.map {
            "\($0.online ? "●" : "○") \($0.hostName)  \($0.primaryIP ?? "")\($0.os.isEmpty ? "" : "  \($0.os)")"
        }.joined(separator: "\n")
        let routed = defaults.string(forKey: "SSHProxyCommand") == proxyCommand && defaults.bool(forKey: "SSHProxyUseFdpass")
        routeSSH.state = routed ? .on : .off
        let active = AppDelegate.sshProxyOptions.contains("ProxyUseFdpass=yes")
        routeNote.stringValue = (routed == active)
            ? "Machines connect over SSH \(routed ? "through this node (ProxyUseFdpass, \(socketPath))" : "the usual way")."
            : "Takes effect when Clotho Dev is relaunched."
    }
}
#endif
