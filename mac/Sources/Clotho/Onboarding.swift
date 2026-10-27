import AppKit
import ClothoKit
import Combine

// First-run onboarding: a welcome window for someone new to Clotho. It explains Workspace, Tab and Pane,
// shows this Mac being set up (that happens anyway, at launch), offers adding a remote machine with a
// connection check that explains what's wrong, and offers agent status and start at login. Every step can
// be skipped, and Help › Welcome to Clotho opens it again.

// MARK: SSH problems, in words

/// Why `ssh <target> true` failed, from ssh's own message, with what to do about it.
enum SSHDiagnosis: Equatable {
    /// No key in ~/.ssh and none in the agent, so there's nothing to offer the host.
    case noKey
    /// The host turned down every key offered.
    case authRejected
    /// The host isn't in known_hosts yet, and Clotho never answers ssh's yes/no question for the user.
    case hostKeyUnknown
    /// The host's key differs from the one in known_hosts.
    case hostKeyChanged
    case unknownHost
    case refused
    case timedOut
    case other(String)

    /// Reads ssh's stderr. `hasKeys` is whether there's any key to offer (files in ~/.ssh or the agent).
    static func classify(_ stderr: String, hasKeys: Bool) -> SSHDiagnosis {
        let text = stderr.lowercased()
        if text.contains("remote host identification has changed") || text.contains("host key for") && text.contains("has changed") {
            return .hostKeyChanged
        }
        if text.contains("host key verification failed") || text.contains("no matching host key") && !text.contains("type") {
            return .hostKeyUnknown
        }
        if text.contains("could not resolve hostname") || text.contains("name or service not known")
            || text.contains("nodename nor servname") {
            return .unknownHost
        }
        if text.contains("permission denied") || text.contains("too many authentication failures")
            || text.contains("no more authentication methods") {
            return hasKeys ? .authRejected : .noKey
        }
        if text.contains("connection refused") { return .refused }
        if text.contains("timed out") || text.contains("no route to host") || text.contains("network is unreachable")
            || text.contains("host is down") {
            return .timedOut
        }
        let last = stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return .other(last.isEmpty ? "ssh failed without saying why." : last)
    }

    /// A short headline.
    var title: String {
        switch self {
        case .noKey: return "There's no SSH key on this Mac"
        case .authRejected: return "The machine didn't accept your SSH key"
        case .hostKeyUnknown: return "This Mac hasn't seen the machine's host key yet"
        case .hostKeyChanged: return "The machine's host key has changed"
        case .unknownHost: return "That machine name wasn't found"
        case .refused: return "The machine refused the connection"
        case .timedOut: return "The machine didn't answer"
        case .other: return "SSH couldn't connect"
        }
    }

    /// What to do, with the commands to run in Terminal. `target` is what the user typed.
    func advice(target: String) -> String {
        let host = target.split(separator: "@").last.map(String.init) ?? target
        switch self {
        case .noKey:
            return "Clotho signs in with an SSH key and never asks for a password. Make a key in Terminal, then copy it to the machine (this one asks for its password once):\n\n    ssh-keygen -t ed25519\n    ssh-copy-id \(target)"
        case .authRejected:
            return "Copy your key to the machine (it asks for the password once), or add the right IdentityFile for it to ~/.ssh/config:\n\n    ssh-copy-id \(target)"
        case .hostKeyUnknown:
            return "Connect once in Terminal and answer \"yes\" if the fingerprint is the one you expect. Clotho never accepts a host key for you.\n\n    ssh \(target) true"
        case .hostKeyChanged:
            return "Either the machine was reinstalled or something is in the way. If you know why it changed, forget the old key and connect once in Terminal to accept the new one:\n\n    ssh-keygen -R \(host)\n    ssh \(target) true"
        case .unknownHost:
            return "Check the spelling. You can use user@host, an alias from ~/.ssh/config, an IP address or a Tailscale name."
        case .refused:
            return "SSH isn't running there, or listens on another port. On a Mac, turn on System Settings › General › Sharing › Remote Login. For another port, add a Host entry with Port to ~/.ssh/config."
        case .timedOut:
            return "Check that the machine is on and on the same network or tailnet, and that a firewall isn't blocking port 22."
        case .other(let message):
            return message
        }
    }

    /// Whether this Mac has any key to offer: a private key in ~/.ssh or an identity in ssh-agent.
    static func hasKeys() -> Bool {
        let ssh = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ssh)) ?? []
        if names.contains(where: { $0.hasPrefix("id_") && !$0.hasSuffix(".pub") }) { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["-l"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Runs `ssh <target> true` the way Clotho connects (BatchMode, no prompts), without saving anything.
enum SSHCheck {
    enum Result: Equatable {
        case ok
        case failed(SSHDiagnosis)
    }

    static func run(target: String) async -> Result {
        if let problem = SSHTarget.problem(target) { return .failed(.other(problem)) }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // Its own connection, not the shared master: a check must see the host as a new connection would.
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlMaster=no",
                                 "-o", "ControlPath=none", "--", target, "true"]
            let err = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return .failed(.other(error.localizedDescription)) }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .ok }
            // Exit status other than 255 is `true` failing on the host, which means ssh itself worked.
            if process.terminationStatus != 255 { return .ok }
            return .failed(SSHDiagnosis.classify(text, hasKeys: SSHDiagnosis.hasKeys()))
        }.value
    }
}

// MARK: The window

@MainActor
final class OnboardingController: NSWindowController, NSWindowDelegate {
    enum Step: Int, CaseIterable { case welcome, thisMac, remote, agents, done }

    nonisolated static let doneKey = "OnboardingDone"

    weak var app: AppDelegate?
    private(set) var step = Step.welcome
    private let page = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip Setup", target: nil, action: nil)
    private let dots = NSStackView()
    private var watchers: [AnyCancellable] = []

    // The remote step.
    private let nameField = NSTextField()
    private let targetField = NSTextField()
    private let checkButton = NSButton(title: "Check Connection", target: nil, action: nil)
    private let connectButton = NSButton(title: "Install clothod and Connect", target: nil, action: nil)
    private let remoteStatus = NSTextField(wrappingLabelWithString: "")
    private let remoteAdvice = NSTextField(wrappingLabelWithString: "")
    private let remoteSpinner = NSProgressIndicator()
    private var checkedTarget: String?
    private var addedMachine: Machine?

    // The this-Mac and agents steps.
    private let localStatus = NSTextField(wrappingLabelWithString: "")
    private let hooksStatus = NSTextField(wrappingLabelWithString: "")
    private var setUpButton: NSButton?
    private let loginBox = NSButton(checkboxWithTitle: "Start clothod at login", target: nil, action: nil)
    private let loginNote = NSTextField(wrappingLabelWithString: "")

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Clotho"
        super.init(window: window)
        window.delegate = self

        let content = NSView()
        backButton.target = self
        backButton.action = #selector(back)
        nextButton.target = self
        nextButton.action = #selector(advance)
        nextButton.keyEquivalent = "\r"
        skipButton.target = self
        skipButton.action = #selector(skip)
        skipButton.bezelStyle = .inline
        skipButton.isBordered = false
        skipButton.contentTintColor = .secondaryLabelColor
        dots.orientation = .horizontal
        dots.spacing = 6

        for view in [page, backButton, nextButton, skipButton, dots] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            page.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -16),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nextButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            skipButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            skipButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            dots.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
        ])
        window.contentView = content

        nameField.placeholderString = "Name, for example Studio"
        targetField.placeholderString = "user@host, an ssh alias or a Tailscale name"
        nameField.nextKeyView = targetField
        checkButton.target = self
        checkButton.action = #selector(checkConnection)
        connectButton.target = self
        connectButton.action = #selector(addAndConnect)
        connectButton.isEnabled = false
        remoteSpinner.style = .spinning
        remoteSpinner.controlSize = .small
        remoteSpinner.isDisplayedWhenStopped = false
        remoteAdvice.isSelectable = true
        remoteAdvice.font = .systemFont(ofSize: 12)
        loginBox.target = self
        loginBox.action = #selector(toggleLogin)
        for label in [localStatus, hooksStatus, remoteStatus] { label.font = .systemFont(ofSize: 13) }
        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .secondaryLabelColor
        NotificationCenter.default.addObserver(self, selector: #selector(targetEdited), name: NSControl.textDidChangeNotification, object: targetField)

        show(.welcome)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whether this is someone's first launch: nothing set up yet. Existing installs (a saved window,
    /// a focused machine or saved machines) never see onboarding on their own.
    nonisolated static func isFirstRun(_ defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        let used = defaults.object(forKey: "FocusedMachine") != nil
            || defaults.object(forKey: "NSWindow Frame ClothoMainWindow") != nil
            || !(defaults.array(forKey: "Machines") ?? []).isEmpty
        return !used
    }

    func present() {
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        log("onboarding: shown at \(step)")
    }

    // MARK: Navigation

    func show(_ next: Step) {
        step = next
        watchers.removeAll()
        page.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor),
        ])
        switch next {
        case .welcome: buildWelcome(stack)
        case .thisMac: buildThisMac(stack)
        case .remote: buildRemote(stack)
        case .agents: buildAgents(stack)
        case .done: buildDone(stack)
        }
        for view in stack.arrangedSubviews where !(view is NSButton) && !(view is NSStackView && (view as! NSStackView).orientation == .horizontal) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        backButton.isHidden = next == .welcome
        skipButton.isHidden = next == .done
        nextButton.title = switch next {
        case .welcome: "Get Started"
        case .remote: addedMachine == nil ? "Not Now" : "Continue"
        case .done: "Start Using Clotho"
        default: "Continue"
        }
        updateDots()
        log("onboarding: step \(next)")
    }

    private func updateDots() {
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for each in Step.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = (each == step ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.addArrangedSubview(dot)
        }
    }

    @objc private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        show(next)
    }

    @objc private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous)
    }

    @objc private func skip() {
        log("onboarding: skipped at \(step)")
        finish()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing it any way counts as done; Help › Welcome to Clotho brings it back.
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        watchers.removeAll()
        app?.onboarding = nil
        app?.window.makeKeyAndOrderFront(nil)
    }

    // MARK: Pages

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        return label
    }

    private func body(_ text: String, color: NSColor = .labelColor, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        return label
    }

    private func symbol(_ name: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        view.contentTintColor = .controlAccentColor
        view.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return view
    }

    /// An icon, a bold term and a line of explanation, side by side.
    private func explainer(_ icon: String, _ term: String, _ text: String) -> NSView {
        let title = NSTextField(labelWithString: term)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = body(text, color: .secondaryLabelColor)
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let row = NSStackView(views: [symbol(icon), words])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        detail.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        return row
    }

    private func buildWelcome(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("Welcome to Clotho"))
        stack.addArrangedSubview(body("Clotho keeps your shells and coding agents running on each machine, even when the app is closed, and shows them all in one window.",
                                      color: .secondaryLabelColor))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(explainer("sidebar.left", "1. Workspaces",
            "One per project or task, listed in the sidebar under its machine. ⌘N makes a new one."))
        stack.addArrangedSubview(explainer("rectangle.topthird.inset.filled", "2. Tabs",
            "A workspace holds tabs, shown across the top. ⌘T opens a tab, ⌘1…⌘9 switch between them."))
        stack.addArrangedSubview(explainer("rectangle.split.2x1", "3. Panes",
            "Split a tab into panes, each its own shell. ⌘D splits right, ⇧⌘D splits down, ⌘W closes one."))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(body("Next: this Mac, another machine if you have one, and agent status. Each takes a moment, and you can skip any of them.",
                                      color: .secondaryLabelColor, size: 12))
    }

    private func buildThisMac(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("This Mac"))
        stack.addArrangedSubview(body("Clotho runs clothod, a small background program, to keep this Mac's shells alive while the window is closed. It comes with the app; there's nothing to install."))
        stack.addArrangedSubview(localStatus)
        guard let store = app?.connections[AppDelegate.localKey]?.store else { return }
        store.$connection.combineLatest(store.$hello).receive(on: DispatchQueue.main).sink { [weak self] state, hello in
            self?.showLocal(state, hello: hello)
        }.store(in: &watchers)
    }

    private func showLocal(_ state: ConnectionState, hello: Hello?) {
        let text: String
        switch state {
        case .idle: text = "Starting clothod…"
        case .connecting(let what): text = "\(what)…"
        case .connected: text = "✓  This Mac is ready, running clothod \(hello?.version ?? "")."
        case .reconnecting(let error): text = "clothod isn't answering yet: \(error)"
        }
        localStatus.stringValue = text
        localStatus.textColor = state.isConnected ? .systemGreen : .labelColor
        log("onboarding: this Mac: \(text)")
    }

    private func buildRemote(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("Another machine (optional)"))
        stack.addArrangedSubview(body("Clotho can run workspaces on a Linux box or another Mac you reach over SSH. It installs clothod there for you, in your home folder, without sudo.",
                                      color: .secondaryLabelColor))
        for field in [nameField, targetField] {
            field.font = .systemFont(ofSize: 13)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name:"), nameField],
                                      [NSTextField(labelWithString: "SSH target:"), targetField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        stack.addArrangedSubview(grid)
        let buttons = NSStackView(views: [checkButton, connectButton, remoteSpinner])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(remoteStatus)
        stack.addArrangedSubview(remoteAdvice)
        if let machine = addedMachine { watchRemote(machine) }
        window?.makeFirstResponder(addedMachine == nil ? (nameField.stringValue.isEmpty ? nameField : targetField) : nil)
    }

    @objc private func targetEdited() {
        // A different target needs a fresh check.
        if checkedTarget != currentTarget {
            checkedTarget = nil
            connectButton.isEnabled = false
        }
    }

    private var currentTarget: String { targetField.stringValue.trimmingCharacters(in: .whitespaces) }

    @objc func checkConnection() {
        let target = currentTarget
        guard !target.isEmpty else {
            return setRemote("Type the SSH target first, such as you@studio.local.", advice: "", color: .labelColor)
        }
        checkButton.isEnabled = false
        connectButton.isEnabled = false
        remoteSpinner.startAnimation(nil)
        setRemote("Checking \(target)…", advice: "", color: .labelColor)
        Task { @MainActor in
            let result = await SSHCheck.run(target: target)
            checkButton.isEnabled = true
            remoteSpinner.stopAnimation(nil)
            guard target == currentTarget else { return }
            switch result {
            case .ok:
                checkedTarget = target
                connectButton.isEnabled = addedMachine == nil
                setRemote("✓  \(target) accepted your SSH key.", advice: "Next, Clotho copies clothod there and connects.", color: .systemGreen)
            case .failed(let diagnosis):
                setRemote(diagnosis.title, advice: diagnosis.advice(target: target) + "\n\nThen check again.", color: .systemRed)
                log("onboarding: check \(target) failed: \(diagnosis)")
            }
        }
    }

    private func setRemote(_ status: String, advice: String, color: NSColor) {
        remoteStatus.stringValue = status
        remoteStatus.textColor = color
        remoteAdvice.stringValue = advice
        remoteAdvice.font = advice.contains("\n    ") ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12)
        if !status.isEmpty { log("onboarding: remote: \(status)") }
    }

    @objc func addAndConnect() {
        guard let app, let target = checkedTarget, addedMachine == nil else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let label = name.isEmpty ? (target.split(separator: "@").last.map(String.init) ?? target) : name
        let machine = Machine.all().first { $0.target == target } ?? Machine.add(label: label, target: target)
        addedMachine = machine
        connectButton.isEnabled = false
        checkButton.isEnabled = false
        nameField.isEnabled = false
        targetField.isEnabled = false
        nextButton.title = "Continue"
        app.connect(machine, show: true)
        watchRemote(machine)
    }

    private func watchRemote(_ machine: Machine) {
        guard let store = app?.connections[machine.key]?.store else { return }
        remoteSpinner.startAnimation(nil)
        store.$connection.combineLatest(store.$hello).receive(on: DispatchQueue.main).sink { [weak self] state, hello in
            guard let self else { return }
            switch state {
            case .idle, .connecting:
                let what = if case .connecting(let step) = state { step } else { "Starting" }
                setRemote("\(machine.label): \(what)…", advice: "The first time, this copies clothod (a few MB) to the machine.", color: .labelColor)
            case .connected:
                remoteSpinner.stopAnimation(nil)
                setRemote("✓  Connected to \(machine.label), running clothod \(hello?.version ?? "").",
                          advice: "It's in the sidebar under its name. Its workspaces keep running there when Clotho quits.", color: .systemGreen)
            case .reconnecting(let error):
                remoteSpinner.stopAnimation(nil)
                setRemote("Couldn't finish connecting to \(machine.label)", advice: "\(error)\n\nClotho keeps retrying in the background. You can continue; the sidebar shows how it goes.",
                          color: .systemRed)
            }
        }.store(in: &watchers)
    }

    private func buildAgents(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("Agent status"))
        stack.addArrangedSubview(body("When Claude Code or Codex runs in a pane, Clotho can show in the sidebar when it's working, waiting for you, done or stuck, and notify you. On its own it guesses from the terminal; with agent status set up, the agents report it themselves, exactly."))
        stack.addArrangedSubview(body("Setting it up adds Clotho's hooks to ~/.claude/settings.json and sets notify in ~/.codex/config.toml, keeping what's there and a backup of each file. You'll see every change before anything is written, and `clothod hooks uninstall` undoes it.",
                                      color: .secondaryLabelColor, size: 12))
        setUpButton = ClosureButton(title: "Set Up Agent Status…") { [weak self] in
            guard let self, let app, let window else { return }
            app.setUpAgentHooks(on: AppDelegate.localKey, in: window)
        }
        stack.addArrangedSubview(setUpButton!)
        stack.addArrangedSubview(hooksStatus)
        refreshHooks()
        stack.setCustomSpacing(24, after: hooksStatus)

        stack.addArrangedSubview(loginBox)
        stack.addArrangedSubview(loginNote)
        loginBox.isEnabled = false
        loginNote.stringValue = "Starts clothod when you log in, so this Mac's workspaces are running before you open Clotho. Without it, clothod starts with the app and keeps running after it quits."
        guard let store = app?.connections[AppDelegate.localKey]?.store else { return }
        store.$service.receive(on: DispatchQueue.main).sink { [weak self] service in self?.showService(service) }.store(in: &watchers)
        Task { _ = try? await store.loadService() }
    }

    func refreshHooks() {
        guard let app else { return }
        let installed = app.hookStatus[AppDelegate.localKey] ?? [:]
        if !installed.isEmpty, installed.values.allSatisfy({ $0 }) {
            hooksStatus.stringValue = "✓  Already set up for Claude Code and Codex on this Mac."
            hooksStatus.textColor = .systemGreen
            setUpButton?.isEnabled = false
        } else {
            let done = installed.filter(\.value).keys.map { $0 == "claude" ? "Claude Code" : "Codex" }.sorted()
            hooksStatus.stringValue = done.isEmpty ? "Not set up yet." : "Set up for \(done.joined(separator: " and ")) so far."
            hooksStatus.textColor = .secondaryLabelColor
            setUpButton?.isEnabled = true
        }
        log("onboarding: hooks: \(hooksStatus.stringValue)")
    }

    private func showService(_ service: DaemonService?) {
        guard let service else { return }
        loginBox.state = service.installed ? .on : .off
        loginBox.isEnabled = service.installed || (service.supported && service.needs.isEmpty)
        if let message = service.message, !service.supported { loginNote.stringValue = message }
        log("onboarding: login service installed=\(service.installed) supported=\(service.supported)")
    }

    @objc private func toggleLogin() {
        guard let store = app?.connections[AppDelegate.localKey]?.store else { return }
        let on = loginBox.state == .on
        loginBox.isEnabled = false
        Task { @MainActor in
            do { _ = try await store.setStartsAtLogin(on) } catch {
                loginNote.stringValue = "Couldn't change it: \((error as? BackendError)?.message ?? error.localizedDescription)"
            }
            loginBox.isEnabled = true
            showService(store.service)
        }
    }

    private func buildDone(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("You're set"))
        stack.addArrangedSubview(body("A few things worth knowing:", color: .secondaryLabelColor))
        stack.addArrangedSubview(explainer("command", "Shortcuts", "⌘/ shows every shortcut. ⇧⌘O opens the file browser, for copying files between machines."))
        stack.addArrangedSubview(explainer("bell.badge", "Agents", "The Agents section of the sidebar lists every agent across your machines; the ones waiting for you come first."))
        stack.addArrangedSubview(explainer("server.rack", "Machines", "Add more any time from the sidebar's Manage Machines, or File › Add Machine."))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(body("Help › Welcome to Clotho shows this again.", color: .secondaryLabelColor, size: 12))
    }

    // MARK: Testing aid

    /// OnboardingScript="target:macbook@imac|check|connect|next|back" drives the window, 3 s per step;
    /// "shot:/tmp/x.png" saves an image of the window alone.
    func runScript(_ steps: [String]) {
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 3) { [weak self] in
                guard let self else { return }
                log("onboarding script: \(step)")
                if step == "next" { advance() }
                else if step == "back" { back() }
                else if step == "skip" { skip() }
                else if step == "check" { checkConnection() }
                else if step == "connect" { addAndConnect() }
                else if step == "hooks" { app?.setUpAgentHooks(on: AppDelegate.localKey, in: window) }
                else if step.hasPrefix("target:") { targetField.stringValue = String(step.dropFirst(7)); targetEdited() }
                else if step.hasPrefix("name:") { nameField.stringValue = String(step.dropFirst(5)) }
                else if step.hasPrefix("step:"), let n = Int(step.dropFirst(5)), let to = Step(rawValue: n) { show(to) }
                else if step.hasPrefix("shot:"), let view = window?.contentView { saveSnapshot(of: view, to: String(step.dropFirst(5))) }
            }
        }
    }
}

/// Testing aid: saves an image of `view` alone (never the screen), rendered from its layers so the
/// backgrounds and text come out as on screen.
@MainActor
func saveSnapshot(of view: NSView, to path: String) {
    view.layoutSubtreeIfNeeded()
    view.wantsLayer = true
    let scale = view.window?.backingScaleFactor ?? 2
    let size = view.bounds.size
    guard let layer = view.layer,
          let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return log("snapshot: no layer") }
    context.scaleBy(x: scale, y: scale)
    view.withAppearance {
        // The window's own background first, which isn't part of the view's layers.
        let background = view.window?.backgroundColor ?? .windowBackgroundColor
        context.setFillColor((background.alphaComponent > 0 ? background : .windowBackgroundColor).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
    }
    layer.render(in: context)
    guard let image = context.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    log("snapshot saved \(path)")
}

extension AppDelegate {
    @objc func showOnboarding(_ sender: Any?) {
        if onboarding == nil { onboarding = OnboardingController(app: self) }
        onboarding?.present()
    }

    /// At launch: onboarding for a first run (or when asked with ShowOnboarding=YES); an existing install
    /// is marked done so it never appears later on its own.
    func showOnboardingIfFirstRun(firstRun: Bool) {
        let defaults = UserDefaults.standard
        if firstRun || defaults.bool(forKey: "ShowOnboarding") {
            showOnboarding(nil)
            if let script = defaults.string(forKey: "OnboardingScript") {
                onboarding?.runScript(script.components(separatedBy: "|"))
            }
        } else if !defaults.bool(forKey: OnboardingController.doneKey) {
            defaults.set(true, forKey: OnboardingController.doneKey)
        }
    }
}
