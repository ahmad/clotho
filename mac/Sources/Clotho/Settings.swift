import AppKit
import ClothoKit

// Clotho › Settings… (⌘,): agent notifications, and per machine whether its agents show, how much
// history each pane keeps (clothod's scrollback setting) and whether clothod starts at login. The
// machine settings live in that machine's clothod, so every client sees the same values.

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    weak var app: AppDelegate?
    private let stack = NSStackView()
    /// Scrollback edits wait a moment, so typing 10000 doesn't set 1, 10, 100 and 1000 on the way.
    private var pendingScrollback: [MachineKey: DispatchWorkItem] = [:]
    /// The last error per machine, shown under its controls until the next change.
    private var errors: [MachineKey: String] = [:]

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = isDevBuild ? "Clotho Dev Settings" : "Clotho Settings"
        window.setFrameAutosaveName("ClothoSettings")
        window.minSize = NSSize(width: 460, height: 300)
        super.init(window: window)
        window.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = s(10)
        stack.edgeInsets = NSEdgeInsets(top: s(20), left: s(24), bottom: s(20), right: s(24))
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedStackHost()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        loadMachineSettings()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Fetches each connected machine's settings (events keep them current afterwards).
    func loadMachineSettings() {
        guard let app else { return }
        for session in app.connections.values {
            let store = session.store
            let key = session.key
            let features = store.hello?.features ?? []
            guard features.contains(.settings) || features.contains(.service) else { continue }
            Task { @MainActor [weak self] in
                do {
                    if features.contains(.settings) { try await store.loadSettings() }
                    if features.contains(.service) { try await store.loadService() }
                    self?.errors[key] = nil
                } catch {
                    self?.errors[key] = error.localizedDescription
                }
                self?.reload()
            }
        }
    }

    /// What the machine blocks depend on: which machines are connected, their clothod, and whether their
    /// settings are loaded. Model changes come often, so the window rebuilds only when this changes.
    private var shownSignature = ""

    func refreshIfNeeded() {
        guard let app, window?.isVisible == true else { return }
        let signature = app.connections.values.map { session in
            "\(session.key):\(session.store.isConnected):\(session.store.hello?.version ?? "-"):\(session.store.settings != nil):\(session.store.service != nil)"
        }.sorted().joined(separator: ",") + "|\(app.remoteMachines.map(\.key))"
        guard signature != shownSignature else { return }
        shownSignature = signature
        // A machine that just connected gets its settings fetched.
        if app.connections.values.contains(where: {
            ($0.store.settings == nil && $0.store.hello?.features.contains(.settings) == true)
                || ($0.store.service == nil && $0.store.hello?.features.contains(.service) == true)
        }) {
            loadMachineSettings()
        }
        reload()
    }

    // MARK: Building

    func reload() {
        guard let app, window?.isVisible == true || stack.arrangedSubviews.isEmpty else { return }
        // A field being edited keeps its text: rebuilding would throw the edit away.
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        section("Notifications")
        note("Agents notify when they need you: when the daemon raises their attention, for example through Claude Code's or Codex's status hooks.")
        for (state, title) in [(AgentInfo.State.waiting, "When an agent is waiting for you"), (.done, "When an agent finishes"),
                               (.error, "When an agent hits an error")] {
            add(checkbox(title, on: app.notifies(state)) { on in
                UserDefaults.standard.set(on, forKey: "NotifyAgent.\(state.rawValue)")
            })
        }

        section("Appearance")
        let modes = NSPopUpButton()
        modes.addItems(withTitles: Theme.Mode.allCases.map(\.title))
        modes.selectItem(at: Theme.Mode.allCases.firstIndex(of: Theme.Mode.current) ?? 0)
        let modeTarget = ClosureTarget { [weak app] sender in
            guard let index = (sender as? NSPopUpButton)?.indexOfSelectedItem else { return }
            app?.setAppearance(Theme.Mode.allCases[index])
        }
        targets.append(modeTarget)
        modes.target = modeTarget
        modes.action = #selector(ClosureTarget.fire(_:))
        add(modes)
        note("Light or dark for the whole window, terminals included. Match System follows macOS.")

        section("Updates")
        if let reason = app.updates.unavailableReason {
            note(reason)
        } else {
            add(checkbox("Check for updates automatically", on: app.updates.automaticallyChecks) { [weak app] on in
                app?.updates.automaticallyChecks = on
            })
            let check = ClosureButton(title: "Check Now") { [weak app] in app?.checkForUpdates(nil) }
            check.bezelStyle = .rounded
            check.controlSize = .small
            add(check, indent: 20)
            note("Clotho checks once a day and asks before installing anything. Updates are signed, and one that isn't signed with Clotho's key is refused.")
        }

        section("Machines")
        var machines = [Machine.local] + app.remoteMachines
        machines.sort { $0.isLocal != $1.isLocal ? $0.isLocal : $0.label < $1.label }
        for machine in machines { machineBlock(machine, app: app) }
    }

    private func machineBlock(_ machine: Machine, app: AppDelegate) {
        let key = machine.key
        let session = app.connections[key]
        let name = machine.isLocal ? ComputerName.current : machine.label
        let title = NSTextField(labelWithString: name + (machine.isLocal ? " (this Mac)" : ""))
        title.font = .systemFont(ofSize: s(13), weight: .semibold)
        add(title, spacingBefore: 14)

        add(checkbox("Show its agents and notify", on: app.monitorsAgents(key)) { [weak app] on in
            app?.setMonitorsAgents(key, on)
        }, indent: 12)

        guard let session, session.store.isConnected, let hello = session.store.hello else {
            note("Connect to \(name) to change its clothod settings.", indent: 12)
            return
        }
        if !hello.features.contains(.settings) && !hello.features.contains(.service) {
            note("\(name) runs clothod \(hello.version). Scrollback and Start at Login need clothod 0.1.7 or later; update it from the machine's menu in the sidebar.", indent: 12)
            return
        }
        if hello.features.contains(.settings) {
            if let settings = session.store.settings { scrollbackControls(settings, key: key) } else { note("Loading…", indent: 12) }
        }
        if hello.features.contains(.service) {
            if let service = session.store.service { loginControls(service, key: key, name: name) } else { note("Loading…", indent: 12) }
        }
        if let error = errors[key] { note(error, indent: 12, color: NSColor.systemRed) }
    }

    private func scrollbackControls(_ settings: DaemonSettings, key: MachineKey) {
        // Scrollback: a number field and a stepper, within the daemon's limits.
        let limits = settings.limits.scrollbackLines
        let field = NSTextField(string: "\(settings.scrollbackLines)")
        field.alignment = .right
        field.formatter = Self.lineFormatter(limits)
        field.widthAnchor.constraint(equalToConstant: s(80)).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(limits.min)
        stepper.maxValue = Double(limits.max)
        stepper.increment = 1000
        stepper.integerValue = settings.scrollbackLines
        let apply = { [weak self] (value: Int) in self?.setScrollback(value, on: key) }
        let fieldTarget = ClosureTarget { [weak stepper] sender in
            guard let field = sender as? NSTextField else { return }
            stepper?.integerValue = field.integerValue
            apply(field.integerValue)
        }
        field.target = fieldTarget
        field.action = #selector(ClosureTarget.fire(_:))
        let stepperTarget = ClosureTarget { [weak field] sender in
            guard let stepper = sender as? NSStepper else { return }
            field?.integerValue = stepper.integerValue
            apply(stepper.integerValue)
        }
        stepper.target = stepperTarget
        stepper.action = #selector(ClosureTarget.fire(_:))
        targets += [fieldTarget, stepperTarget]
        let row = NSStackView(views: [NSTextField(labelWithString: "Scrollback:"), field, stepper,
                                      NSTextField(labelWithString: "lines per pane")])
        row.spacing = s(6)
        add(row, indent: 12)
        note("""
        \(limits.min)–\(limits.max) lines (default \(limits.default)). About 3 MB of memory per 1000 lines for every pane \
        whose history fills up. Applies to new panes and to panes without their own setting; lowering it drops \
        their oldest lines at once. Saved in \(settings.config ?? "clothod's config file").
        """, indent: 12)

    }

    /// Start at login: the toggle is whether the service is installed.
    private func loginControls(_ service: DaemonService, key: MachineKey, name: String) {
        let login = checkbox("Start clothod at login", on: service.installed) { [weak self] on in self?.setStartsAtLogin(on, on: key) }
        // Turning it off always works; turning it on needs a service manager and nothing missing.
        login.isEnabled = service.installed || (service.supported && service.needs.isEmpty)
        if service.installed && !service.upToDate {
            let refresh = ClosureButton(title: "Refresh") { [weak self] in self?.setStartsAtLogin(true, on: key) }
            refresh.bezelStyle = .rounded
            refresh.controlSize = .small
            let row = NSStackView(views: [login, refresh])
            row.spacing = s(8)
            add(row, indent: 12)
            note("The installed login item is from another clothod build; Refresh rewrites it.", indent: 12)
        } else {
            add(login, indent: 12)
        }
        var lines = ["Keeps \(name)'s workspaces running from login, before Clotho connects. Turning it off leaves clothod running."]
        if service.installed, !service.loaded { lines.append("Installed, but \(service.manager ?? "the service manager") hasn't loaded it.") }
        if let message = service.message { lines.append(message) }
        note(lines.joined(separator: " "), indent: 12)
    }

    func setStartsAtLogin(_ on: Bool, on key: MachineKey) {
        guard let store = app?.connections[key]?.store else { return }
        log("settings: \(key) start at login → \(on)")
        Task { @MainActor [weak self] in
            do {
                let result = try await store.setStartsAtLogin(on)
                self?.errors[key] = nil
                log("settings: \(key) service installed=\(result.installed) loaded=\(result.loaded)")
            } catch {
                let message = (error as? BackendError)?.message ?? error.localizedDescription
                self?.errors[key] = on ? "Couldn't turn on start at login: \(message)" : "Couldn't turn off start at login: \(message)"
                log("settings: \(key) service failed: \(error)")
            }
            self?.reload()
        }
    }

    static func lineFormatter(_ limits: DaemonSettings.Range) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: limits.min)
        formatter.maximum = NSNumber(value: limits.max)
        return formatter
    }

    // MARK: Applying

    func setScrollback(_ lines: Int, on key: MachineKey) {
        pendingScrollback[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let store = app?.connections[key]?.store, store.settings?.scrollbackLines != lines else { return }
            log("settings: \(key) scrollback → \(lines)")
            Task { @MainActor [weak self] in
                do {
                    let result = try await store.changeSettings(.init(scrollbackLines: lines))
                    self?.errors[key] = nil
                    log("settings: \(key) scrollback is \(result.scrollbackLines), applied to \(result.appliedPanes?.count ?? 0) panes")
                } catch {
                    self?.errors[key] = "Couldn't change the scrollback: \(error.localizedDescription)"
                    log("settings: \(key) failed: \(error)")
                }
                self?.reload()
            }
        }
        pendingScrollback[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Pieces

    /// Targets for closure-based controls live as long as the window's current contents.
    private var targets: [ClosureTarget] = []

    private func section(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: s(15), weight: .bold)
        add(label, spacingBefore: stack.arrangedSubviews.isEmpty ? 0 : 22)
    }

    private func note(_ text: String, indent: CGFloat = 0, color: NSColor = .secondaryLabelColor) {
        if UserDefaults.standard.bool(forKey: "LogSettings") { log("settings window: \(text.prefix(140))") }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: s(11))
        label.textColor = color
        label.preferredMaxLayoutWidth = 440
        add(label, indent: indent)
    }

    private func checkbox(_ title: String, on: Bool, changed: @escaping (Bool) -> Void) -> NSButton {
        let target = ClosureTarget { sender in changed((sender as? NSButton)?.state == .on) }
        targets.append(target)
        let box = NSButton(checkboxWithTitle: title, target: target, action: #selector(ClosureTarget.fire(_:)))
        box.state = on ? .on : .off
        return box
    }

    private func add(_ view: NSView, indent: CGFloat = 0, spacingBefore: CGFloat? = nil) {
        if let spacingBefore, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacingBefore, after: last) }
        guard indent > 0 else { return stack.addArrangedSubview(view) }
        let wrapper = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: indent),
            view.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        stack.addArrangedSubview(wrapper)
    }

    func windowWillClose(_ notification: Notification) {
        targets.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}

/// Runs a closure as a control's action.
final class ClosureTarget: NSObject {
    private let body: (Any?) -> Void
    init(_ body: @escaping (Any?) -> Void) { self.body = body }
    @objc func fire(_ sender: Any?) { body(sender) }
}

/// The scroll view's document, top-aligned.
private final class FlippedStackHost: NSView {
    override var isFlipped: Bool { true }
}

extension AppDelegate {
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }
}
