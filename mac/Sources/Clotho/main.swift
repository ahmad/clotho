import AppKit
import ClothoFake
import ClothoKit
import Network
import SwiftTerm

// Warp's Adeberry theme (from warpdotdev/warp app/src/themes/default_themes.rs), with the
// foreground and both whites toned down so text and the active pane's outline are easier on the eyes.
enum Theme {
    static let background = NSColor(hex: 0x1D2022)
    static let foreground = NSColor(hex: 0xC5CDD4)
    static let accent = NSColor(hex: 0x6C96B4)
    // The sidebar and tab bar share this, so the notch strip blends into both.
    static let sidebar = NSColor(hex: 0x191C1E)
    static let hover = NSColor(hex: 0x24282B)
    static let divider = NSColor(hex: 0x343A3F)
    static let dimText = NSColor(hex: 0x7F888F)
    static let ansi: [UInt32] = [
        0x121212, 0xC76156, 0x57C78A, 0xC8A35A, 0x5785C7, 0xC756A9, 0x57C7C3, 0xA9B0B6,
        0x292929, 0xD22D1E, 0x1CA05A, 0xE5A01A, 0x1458B8, 0xA43787, 0x4D9989, 0xD6DCE1,
    ]

    static var terminalColors: [SwiftTerm.Color] {
        ansi.map { hex in
            // SwiftTerm colors are 16 bits per channel.
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257,
                            green: UInt16((hex >> 8) & 0xff) * 257,
                            blue: UInt16(hex & 0xff) * 257)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// A borderless window, so macOS draws no title bar or 1px edge, that can still take focus.
final class FramelessWindow: NSWindow {
    // Set while filling the whole display, so AppKit doesn't push the window below the menu bar.
    var fillsScreen = false
    private var frameBeforeMinimize: NSRect?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        fillsScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    // AppKit won't minimize a borderless window, so it gets a hidden title bar until it's restored.
    func minimize() {
        frameBeforeMinimize = frame
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        styleMask.insert([.titled, .fullSizeContentView])
        miniaturize(nil)
    }

    func restoreAfterMinimize() {
        guard let frame = frameBeforeMinimize else { return }
        frameBeforeMinimize = nil
        styleMask.remove([.titled, .fullSizeContentView])
        setFrame(frame, display: true)
    }
}

// The close, minimize and full-screen buttons in the top-left corner, always shown. Like the standard
// ones, their symbols appear while the pointer is over the group.
final class WindowButtons: NSView {
    private var buttons: [NSButton] = []
    private var hovering = false

    // The window is borderless, so these are free-standing copies of the standard buttons.
    init(target: AnyObject, close: Selector, minimize: Selector, fullScreen: Selector) {
        super.init(frame: .zero)
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let specs: [(NSWindow.ButtonType, Selector)] = [(.closeButton, close), (.miniaturizeButton, minimize), (.zoomButton, fullScreen)]
        for (index, (type, action)) in specs.enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: mask) else { continue }
            button.target = target
            button.action = action
            button.setFrameOrigin(NSPoint(x: 9 + CGFloat(index) * 20, y: 0))
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let width: CGFloat = 9 + 3 * 20

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    // AppKit asks the buttons' superview whether to draw their ×, − and full-screen symbols.
    @objc func _mouseInGroup(_ button: NSButton) -> Bool { hovering }

    override func layout() {
        super.layout()
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: ((bounds.height - button.frame.height) / 2).rounded()))
        }
    }

    // Clickable even when the window isn't active yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setHovering(_ value: Bool) {
        hovering = value
        buttons.forEach { $0.needsDisplay = true }
    }
}

/// "Clotho Dev.app" (build-app.sh --dev) keeps its log and workspaces apart from the installed app.
let isDevBuild = Bundle.main.object(forInfoDictionaryKey: "ClothoDevBuild") as? Bool == true

// Appends a line to ~/Library/Logs/Clotho.log (Clotho Dev.log for the dev build) so problems can be diagnosed.
func log(_ message: String) {
    let name = isDevBuild ? "Clotho Dev" : "Clotho"
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/\(name).log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let cornerRadius: CGFloat = 12

    var window: FramelessWindow!
    var container: NSView!
    var notchExtension: NSView!
    var notchHeight: NSLayoutConstraint!
    var sidebar: SidebarView!
    var sidebarWidth: NSLayoutConstraint!
    var tabBar: TabBarView!
    var tabBarLeading: NSLayoutConstraint!
    var splitView: SplitLayoutView!
    var emptyLabel: NSTextField!
    var shortcutsOverlay: ShortcutsOverlay?
    var fileBrowser: FileBrowserOverlay?
    var keyMonitor: Any?
    var settingsWindow: SettingsWindowController?
    let transfers = TransferManager()
    var transferToast: TransferToast!

    // One daemon connection per machine (see MachineConnections.swift); the window shows the focused one.
    var connections: [MachineKey: MachineConnection] = [:]
    var focusedMachine: MachineKey = AppDelegate.localKey {
        didSet { UserDefaults.standard.set(focusedMachine, forKey: "FocusedMachine") }
    }
    var networkMonitor: NWPathMonitor?
    var localDaemon: LocalDaemon?
    var remoteInstallers: [MachineKey: RemoteInstaller] = [:]
    var warnedMachines: Set<String> = []
    let notificationDelegate = AgentNotificationDelegate()
    let agentsMenuDelegate = AgentsMenuDelegate()
    /// Machines where agents have reported through hooks, so setup isn't offered again.
    var hookSourcedMachines: Set<MachineKey> = []
    /// `hooks status` per machine: agent → installed.
    var hookStatus: [MachineKey: [String: Bool]] = [:]
    var lastAgentNotification: [String: (state: AgentInfo.State, date: Date)] = [:]
    /// Machines whose daemon runs an older build than the one installed, waiting for the user.
    var pendingDaemonUpdates: Set<MachineKey> = []
    /// Machines whose legacy holder needs a clothod restart to finish an update, waiting for the user.
    var pendingHolderRestarts: Set<MachineKey> = []
    var agentClock: Timer?
    var upgradeNoticeMachines: Set<MachineKey> = []
    var noticeBar: NoticeBar?
    /// Moves the panes down while a notice shows, so it never covers them.
    var splitTop: NSLayoutConstraint!
    var termSource: DispatchSourceSignal?
    var lastRemoteReconnect = Date.distantPast
    var paneHosts: [PaneKey: PaneHostView] = [:]
    // Maximize is a per-window view state, not part of the daemon's model.
    var maximized: [TabKey: PaneID] = [:]
    // Saved machines' last connection check, by machine id.
    var machineStatus: [String: MachineStatus] = [:]
    var lastMachineCheck = Date.distantPast

    static let defaultFontSize: CGFloat = 13
    var fontSize: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: "FontSize")
            return saved > 0 ? saved : Self.defaultFontSize
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "FontSize") }
    }
    var windowedFrame: NSRect?
    var firstResponderObservation: NSKeyValueObservation?

    // Carries settings over, once, from the "Clotho Next" builds that ran beside the herdr-based app
    // (bundle id app.clotho.desktop.next), without replacing anything already set here.
    func migrateLegacyPreferences() {
        guard !isDevBuild else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "MigratedNextPreferences") else { return }
        let legacy = defaults.persistentDomain(forName: "app.clotho.desktop.next") ?? [:]
        let keys = ["FontSize", "LocalBrowserPath", "HideSidebar", "NSWindow Frame ClothoMainWindow"]
            + legacy.keys.filter { $0.hasPrefix("SkipCloseConfirm.") }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "MigratedNextPreferences")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyPreferences()
        buildMenu()
        Self.registerBundledFonts()

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = FramelessWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = isDevBuild ? "Clotho Dev" : "Clotho"
        window.delegate = self
        // Transparent window with a rounded content layer; the shadow follows the rounded shape.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Native full screen keeps content below the camera notch, so the app does its own.
        window.collectionBehavior = [.fullScreenNone]
        window.setFrameAutosaveName("ClothoMainWindow")
        if !window.setFrameUsingName("ClothoMainWindow") {
            window.center()
        }

        container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.background.cgColor
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        // In full screen on a notched display, a strip in the chrome color fills the space beside the notch.
        notchExtension = NSView()
        notchExtension.wantsLayer = true
        notchExtension.layer?.backgroundColor = Theme.sidebar.cgColor
        notchExtension.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(notchExtension)
        notchHeight = notchExtension.heightAnchor.constraint(equalToConstant: 0)

        sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelect = { [weak self] key, id in
            guard let self else { return }
            focus(machine: key)
            run { try await $0.focus(.workspace(id)) }
        }
        sidebar.onRename = { [weak self] key, id, name in
            guard let store = self?.connections[key]?.store else { return }
            Task { try? await store.backend.renameWorkspace(id, name: name) }
        }
        sidebar.onEditingEnded = { [weak self] in self?.focusTerminalAfterEdit() }
        sidebar.onClose = { [weak self] key, id in
            self?.focus(machine: key)
            self?.closeWorkspace(id)
        }
        sidebar.onNewWorkspace = { [weak self] key in self?.newWorkspace(on: key) }
        sidebar.onConnect = { [weak self] key in
            guard let self, let machine = remoteMachines.first(where: { $0.key == key }) else { return }
            // Shows the machine's workspaces; a first one only if it has none.
            connect(machine, show: true)
        }
        sidebar.onAddMachine = { [weak self] in self?.addMachine(nil) }
        sidebar.onOpenAgent = { [weak self] machine, pane in self?.openAgent(machine: machine, pane: pane) }
        sidebar.onResolveAgent = { [weak self] machine, pane in self?.resolveAgent(machine: machine, pane: pane) }
        sidebar.agentRowMenu = { [weak self] machine, pane, canReply in
            self?.agentMenu(machine: machine, pane: pane, canReply: canReply) ?? NSMenu()
        }
        sidebar.agentsMenu = { [weak self] in self?.agentsNotificationMenu() ?? NSMenu() }
        sidebar.machineMenu = { [weak self] key in self?.menu(forMachine: key) ?? NSMenu() }
        ComputerName.observe()
        NotificationCenter.default.addObserver(forName: ComputerName.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        NotificationCenter.default.addObserver(forName: Machine.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        container.addSubview(sidebar)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: UserDefaults.standard.bool(forKey: "HideSidebar") ? 0 : savedSidebarWidth)
        sidebar.onResize = { [weak self] width in
            guard let self else { return }
            sidebarWidth.constant = min(max(width.rounded(), Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
        }
        sidebar.onResizeEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(sidebarWidth.constant), forKey: "SidebarWidth")
        }

        tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] id in self?.run { try await $0.focus(.tab(id)) } }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        tabBar.onRename = { [weak self] id, title in
            self?.run { try await $0.renameTab(id, title: title.isEmpty ? nil : title) }
        }
        tabBar.onEditingEnded = { [weak self] in self?.focusTerminalAfterEdit() }
        tabBar.onNewTab = { [weak self] in self?.newTab(nil) }
        installKeyMonitor()
        container.addSubview(tabBar)
        tabBarLeading = tabBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)

        splitView = SplitLayoutView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.onRatioChange = { [weak self] split, ratio in self?.run { try await $0.setRatio(split, ratio: ratio) } }
        container.addSubview(splitView)

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.textColor = Theme.dimText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        let corner = WindowButtons(
            target: self,
            close: #selector(closeWindow(_:)),
            minimize: #selector(minimizeWindow(_:)),
            fullScreen: #selector(toggleFullScreen(_:))
        )
        corner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(corner)

        splitTop = splitView.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        NSLayoutConstraint.activate([
            notchExtension.topAnchor.constraint(equalTo: container.topAnchor),
            notchExtension.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            notchExtension.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            notchHeight,
            sidebar.topAnchor.constraint(equalTo: notchExtension.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebarWidth,
            tabBar.topAnchor.constraint(equalTo: notchExtension.bottomAnchor),
            tabBarLeading,
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            splitTop,
            splitView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: splitView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: splitView.centerYAnchor),
            corner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            corner.topAnchor.constraint(equalTo: sidebar.topAnchor),
            corner.widthAnchor.constraint(equalToConstant: WindowButtons.width),
            corner.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateTabBarInset()

        window.contentView = container
        installTransferToast()
        // Testing aid: LaunchInBackground=YES shows the window behind others without taking keyboard focus,
        // so scripted runs never catch keystrokes meant for another app.
        if UserDefaults.standard.bool(forKey: "LaunchInBackground") {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if UserDefaults.standard.bool(forKey: "StartFullScreen") {
            toggleFullScreen(nil)
        }

        firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged() }
        }
        let (backend, daemon) = Self.makeBackend()
        localDaemon = daemon
        addSession(MachineConnection(machine: .local, backend: backend))
        startBackend()
        // Remote machines that were connected last time connect again, and focus returns where it was.
        for machine in remoteMachines where connectedMachineIDs.contains(machine.key) { connect(machine) }
        if let saved = UserDefaults.standard.string(forKey: "FocusedMachine"), connections[saved] != nil { focusedMachine = saved }
        watchForWakeAndNetworkChanges()
        setUpAgentNotifications()
        installAgentsMenu()
        // A plain `kill` quits normally, so the dev build's cleanup runs then too.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        runTestScripts()
        checkMachinesIfStale()

        if UserDefaults.standard.bool(forKey: "ShowShortcuts") { showShortcuts(nil) }
        if UserDefaults.standard.bool(forKey: "ShowFiles") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.showFileBrowser(nil) }
        }
        // Testing aid: TestCopy="machine|source path|destination folder[|replace]" copies through the transfer
        // pipeline. "remote:/path" as the source downloads from the machine; "other:/path" as the
        // destination (a saved machine's name) copies between two remote machines through the app.
        if let spec = UserDefaults.standard.string(forKey: "TestCopy")?.components(separatedBy: "|"), spec.count >= 3,
           let machine = Machine.all().first(where: { $0.label == spec[0] }) {
            Task { @MainActor in
                let fromRemote = spec[1].hasPrefix("remote:")
                let source = Location(machine: fromRemote ? machine : .local, path: fromRemote ? String(spec[1].dropFirst(7)) : spec[1])
                var dest = Location(machine: fromRemote ? .local : machine, path: spec[2])
                if let colon = spec[2].firstIndex(of: ":"),
                   let other = Machine.all().first(where: { $0.label == String(spec[2][..<colon]) }) {
                    dest = Location(machine: other, path: String(spec[2][spec[2].index(after: colon)...]))
                }
                // Once both machines can share files (or after two minutes, to show why not).
                for _ in 0 ..< 120 where (try? self.fileBackend(for: source.machine)) == nil || (try? self.fileBackend(for: dest.machine)) == nil {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                log("TestCopy: \(source.machine.label):\(source.path) → \(dest.machine.label):\(dest.path)")
                let started = Date()
                let done = { (ok: Bool) in log("TestCopy finished ok=\(ok) in \(Int(Date().timeIntervalSince(started)))s") }
                // A fourth field "replace" skips the Replace/Skip question (a rerun that should resume).
                if spec.count > 3, spec[3] == "replace" {
                    self.transfers.start(title: "TestCopy", sources: [source], to: dest, conflict: .replace, onFinish: done)
                } else {
                    self.copy([source], to: dest, then: done)
                }
            }
        }
        // Testing aid: RunShortcuts="New Tab,Split Right" fires those menu items, a second apart.
        if let titles = UserDefaults.standard.string(forKey: "RunShortcuts")?.components(separatedBy: ",") {
            for (i, title) in titles.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i)) {
                    let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
                    guard let item = items.first(where: { $0.title == title }), let action = item.action else {
                        log("RunShortcuts: no menu item \(title)")
                        return
                    }
                    log("RunShortcuts: \(title)")
                    NSApp.sendAction(action, to: nil, from: item)
                }
            }
        }
    }

    // Testing aids: TypeText="vim\\r|:q\\r" sends each step to the focused pane (\\r is Return, \\e is Esc),
    // and ResizeWindow="900x600|1400x900" sets the window size; both start after 3 seconds, 2 seconds apart.
    // A TypeText step "key:shift+return" instead posts that key as a key event, which goes through the
    // window's key handling like a real press (modifiers shift, cmd, ctrl, alt; keys return, enter, tab,
    // esc, delete, left, right, a, c, v),
    // "type:new name" posts those characters as key events, for typing into whatever has focus, and
    // "click:600,300" clicks at that point of the window (from its bottom-left corner), "rclick:600,300"
    // right-clicks, and either takes modifiers after the point, as in "click:600,300,ctrl" or
    // "rclick:600,300,alt". "menu:Paste" picks that item of the focused pane's right-click menu, and
    // "drop:/path/file" handles that file as if dropped on the focused pane. "resolve:0" presses the
    // Agents checkmark for the focused machine's first pane. "scrollback:5000" opens Settings and sets the
    // focused machine's scrollback through it.
    func runTestScripts() {
        let decode = { (text: String) in text.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}") }
        for (i, step) in (UserDefaults.standard.string(forKey: "TypeText")?.components(separatedBy: "|") ?? []).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 2) { [self] in
                guard !step.isEmpty, let pane = store.focusedPane?.id else { return }
                log("TypeText: \(step)")
                if step.hasPrefix("key:") { return postTestKey(String(step.dropFirst(4))) }
                if step.hasPrefix("type:") { return postTestText(String(step.dropFirst(5))) }
                if step.hasPrefix("click:") { return postTestClick(String(step.dropFirst(6))) }
                if step.hasPrefix("rclick:") { return postTestClick(String(step.dropFirst(7)), right: true) }
                if step.hasPrefix("menu:") { return runPaneMenuItem(String(step.dropFirst(5))) }
                if step.hasPrefix("login:") {
                    showSettings(nil)
                    return settingsWindow?.setStartsAtLogin(step.hasSuffix("on"), on: focusedMachine) ?? ()
                }
                if step.hasPrefix("scrollback:"), let lines = Int(step.dropFirst(11)) {
                    showSettings(nil)
                    return settingsWindow?.setScrollback(lines, on: focusedMachine) ?? ()
                }
                if step.hasPrefix("resolve:"), let index = Int(step.dropFirst(8)) {
                    let panes = store.state.panes.map(\.id)
                    return index < panes.count ? resolveAgent(machine: focusedMachine, pane: panes[index]) : log("TypeText: no pane \(index)")
                }
                if step.hasPrefix("drop:") {
                    return dropFiles([URL(fileURLWithPath: String(step.dropFirst(5)))], on: PaneKey(machine: focusedMachine, pane: pane))
                }
                backend.sendInput(pane, Data(decode(step).utf8))
            }
        }
        // FakeAgents=YES (with Backend=fake) puts fake agents in this Mac's panes and moves them through
        // their states, for building the Agents section without clothod.
        if UserDefaults.standard.bool(forKey: "FakeAgents"), let fake = connections[Self.localKey]?.store.backend as? FakeBackend {
            let steps: [(TimeInterval, Int, AgentInfo?)] = [
                (3, 0, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Editing Sources/Model.swift")),
                (3, 1, AgentInfo(kind: "codex", state: .running, message: "Running the test suite")),
                (3, 2, AgentInfo(kind: "claude", state: .starting)),
                // Quiet, not raised: shows as idle and never notifies.
                (5, 2, AgentInfo(kind: "claude", state: .waiting, message: "No output for a while", attention: false)),
                (6, 0, AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Allow running `swift test`?")),
                (8, 1, AgentInfo(kind: "codex", state: .done, message: "All 15 tests pass")),
                (10, 2, AgentInfo(kind: "claude", state: .error, source: "hook", message: "API rate limit reached")),
            ]
            for (time, index, agent) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + time) { [self] in
                    let panes = connections[Self.localKey]?.store.state.panes.map(\.id) ?? []
                    guard index < panes.count else { return log("FakeAgents: no pane \(index)") }
                    log("FakeAgents: pane \(panes[index]) → \(agent?.state.rawValue ?? "none")")
                    fake.setAgent(panes[index], agent)
                }
            }
        }
        // SetUpAgentStatus="devbox" (or "local") opens the agent status setup sheet after 6 seconds.
        if let name = UserDefaults.standard.string(forKey: "SetUpAgentStatus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
                let key = name == "local" ? Self.localKey : remoteMachines.first { $0.label == name }?.key
                log("SetUpAgentStatus: \(name), needs \(key.map(agentsNeedingHooks) ?? [])")
                if let key { setUpAgentHooks(on: key) }
            }
        }
        // ApplyDaemonUpdates=8 presses the "Restart Daemon" notice's button after that many seconds.
        let applyAfter = UserDefaults.standard.double(forKey: "ApplyDaemonUpdates")
        if applyAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + applyAfter) { [self] in
                // Dev builds only: also run the switch on machines already on the newest build, to exercise it.
                if isDevBuild { pendingDaemonUpdates.formUnion(connections.keys) }
                log("ApplyDaemonUpdates: \(pendingDaemonUpdates.sorted())")
                applyDaemonUpdates()
            }
        }
        // PaneMenu="Split Left" builds the focused pane's right-click menu, logs it, and picks that item.
        if let title = UserDefaults.standard.string(forKey: "PaneMenu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in runPaneMenuItem(title) }
        }
        // QuickReply="30|1" (or "40|text:hello") answers the first waiting (or attention) agent then: keys
        // separated by commas, or text followed by Enter.
        for spec in (UserDefaults.standard.string(forKey: "QuickReply")?.components(separatedBy: ";") ?? []) {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let time = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [self] in
                guard let entry = agentEntries().first(where: { $0.info.state == .waiting || $0.info.needsAttention }) else {
                    return log("QuickReply: no agent to answer")
                }
                log("QuickReply: \(parts[1]) → \(entry.machine)/\(entry.pane), offersReplies \(entry.offersReplies)")
                if parts[1].hasPrefix("text:") {
                    reply(machine: entry.machine, pane: entry.pane, text: String(parts[1].dropFirst(5)), keys: ["enter"])
                } else {
                    reply(machine: entry.machine, pane: entry.pane, keys: parts[1].components(separatedBy: ","))
                }
            }
        }
        // ConnectMachine="devbox" connects to that saved machine and starts a workspace there.
        if let name = UserDefaults.standard.string(forKey: "ConnectMachine"),
           let machine = remoteMachines.first(where: { $0.label == name }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in connect(machine, startWorkspace: true) }
        }
        // DumpScreens="5|9" logs each shown pane's text and cursor at those seconds after launch (the last 12
    // non-empty lines, or DumpLines), which works
        // even while the window is covered (SwiftTerm stops drawing then, so screenshots go stale).
        for time in (UserDefaults.standard.string(forKey: "DumpScreens")?.components(separatedBy: "|") ?? []).compactMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [self] in
                for id in store.focusedTab?.layout.panes ?? [] {
                    guard let snapshot = paneHosts[PaneKey(machine: focusedMachine, pane: id)]?.terminal
                        .terminalContentSnapshot(region: .viewport) else { continue }
                    let lines = snapshot.rows.map { $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                    let shown = lines.prefix { _ in true }.enumerated().filter { !$0.element.isEmpty }.map { "  \($0.offset): \($0.element)" }
                    log("screen pane \(id) cursor \(snapshot.cursorColumn),\(snapshot.cursorRow)\n" + shown.suffix(UserDefaults.standard.integer(forKey: "DumpLines") > 0
                        ? UserDefaults.standard.integer(forKey: "DumpLines") : 12).joined(separator: "\n"))
                }
            }
        }
        for (i, step) in (UserDefaults.standard.string(forKey: "ResizeWindow")?.components(separatedBy: "|") ?? []).enumerated() {
            let parts = step.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 2) { [self] in
                log("ResizeWindow: \(step)")
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - parts[1], width: parts[0], height: parts[1]), display: true)
            }
        }
    }

    /// Builds the focused pane's right-click menu, logs it, and picks the item with that title.
    func runPaneMenuItem(_ title: String) {
        guard let pane = store.focusedPane?.id, let menu = paneMenu(for: PaneKey(machine: focusedMachine, pane: pane)) else {
            return log("PaneMenu: no focused pane")
        }
        log("PaneMenu: " + menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", "))
        guard let item = menu.items.first(where: { $0.title == title }) else { return log("PaneMenu: no item \(title)") }
        _ = item.target?.perform(item.action, with: item)
    }

    /// Posts a left click, for TypeText's "click:" steps.
    func postTestClick(_ spec: String, right: Bool = false) {
        let parts = spec.split(separator: ",").map(String.init)
        let numbers = parts.prefix(2).compactMap { Double($0) }
        let flags: [String: NSEvent.ModifierFlags] = ["shift": .shift, "cmd": .command, "ctrl": .control, "alt": .option]
        guard numbers.count == 2, parts.dropFirst(2).allSatisfy({ flags[$0] != nil }) else { return log("TypeText: bad click \(spec)") }
        let modifiers = parts.dropFirst(2).reduce(into: NSEvent.ModifierFlags()) { $0.formUnion(flags[$1]!) }
        window.makeKey()
        for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: numbers[0], y: numbers[1]), modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Posts each character as a key press, for TypeText's "type:" steps.
    func postTestText(_ text: String) {
        window.makeKey()
        for character in text.map(String.init) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: character, charactersIgnoringModifiers: character,
                                                   isARepeat: false, keyCode: 0) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Posts a key event to the window, for TypeText's "key:" steps. The window becomes key without the
    /// app activating, so the real keyboard still goes to the app in front.
    func postTestKey(_ spec: String) {
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        let name = parts.popLast() ?? ""
        let keys: [String: (code: UInt16, char: String)] = [
            "return": (36, "\r"), "enter": (76, "\u{3}"), "tab": (48, "\t"), "esc": (53, "\u{1b}"), "delete": (51, "\u{7f}"),
            "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            "a": (0, "a"), "c": (8, "c"), "v": (9, "v"),
        ]
        let flags: [String: NSEvent.ModifierFlags] = ["shift": .shift, "cmd": .command, "ctrl": .control, "alt": .option]
        guard let key = keys[name], parts.allSatisfy({ flags[$0] != nil }) else { return log("TypeText: unknown key \(spec)") }
        let modifiers = parts.reduce(into: NSEvent.ModifierFlags()) { $0.formUnion(flags[$1]!) }
        window.makeKey()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: key.char, charactersIgnoringModifiers: key.char,
                                               isARepeat: false, keyCode: key.code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// clothod by default. `Backend=fake` (a launch argument or default) runs local shells in-process instead.
    /// The bundled clothod installs itself to a versioned directory and runs from there (LocalDaemon).
    /// `ClothodPath` (or `CLOTHOD_BIN`) runs a development build in place instead. `ClothodRuntimeDir`
    /// gives a private daemon its own socket directory.
    static func makeBackend() -> (SessionBackend, LocalDaemon?) {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        if defaults.string(forKey: "Backend") == "fake" {
            log("backend: fake")
            return (FakeBackend(), nil)
        }
        let override = [defaults.string(forKey: "ClothodPath"), env["CLOTHOD_BIN"]].compactMap { $0 }.first
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("clothod").path
        guard let source = override ?? bundled, FileManager.default.isExecutableFile(atPath: source) else {
            log("backend: no clothod binary (tried \(override ?? bundled ?? "nothing")), using the fake backend")
            return (FakeBackend(), nil)
        }
        // The dev build runs its own daemon, so testing never touches the user's workspaces.
        let runtimeDir = defaults.string(forKey: "ClothodRuntimeDir") ?? env["CLOTHOD_RUNTIME_DIR"]
            ?? (isDevBuild ? (NSTemporaryDirectory() as NSString).appendingPathComponent("clotho-dev") : nil)
        var configured = LocalDaemon(source: source, runInPlace: override != nil, runtimeDir: runtimeDir)
        if isDevBuild { configured.installDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("clotho-dev-bin") }
        let daemon = configured
        // Asked of clothod itself; the computed default is only a fallback for builds that can't answer.
        let socket = daemon.socketPath() ?? ClothodBackend.defaultSocketPath(runtimeDir: runtimeDir)
        log("backend: clothod from \(source)\(override != nil ? " (in place)" : ""), socket \(socket)")
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let backend = ClothodBackend(configuration: configure(.init(socketPath: socket, clientName: "clotho-mac/\(version)", log: { log($0) }) {
            // `start` returns once the socket accepts connections (a no-op if it's already running).
            try daemon.start()
        }))
        return (backend, daemon)
    }

    // TraceFrames=YES logs every pane data frame both ways (pane, seq, length).
    private static func configure(_ configuration: ClothodBackend.Configuration) -> ClothodBackend.Configuration {
        var configuration = configuration
        if UserDefaults.standard.bool(forKey: "TraceFrames") { configuration.trace = { log("frame \($0)") } }
        return configuration
    }

    func startBackend() {
        guard let local = connections[Self.localKey] else { return }
        let daemon = localDaemon
        Task { @MainActor in
            do {
                // Install the bundled version if it's new, and start the daemon from the installed copy.
                try await Task.detached { try daemon?.start() }.value
                try await local.store.start()
                await upgradeLocalLogicProcessIfNeeded(local)
                refreshHookStatus(Self.localKey)
                // clothod brings back the previous layout; only an empty daemon gets a first workspace. (Retried
                // briefly, since an upgrade above reconnects.)
                var state: ModelState?
                for attempt in 0..<40 {
                    do {
                        state = try await local.store.backend.getState()
                        break
                    } catch where attempt < 39 {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                if state?.workspaces.isEmpty == true {
                    _ = try await local.store.backend.createWorkspace(name: "Workspace 1", spawn: spawnOptions())
                }
            } catch LocalDaemon.Failure.holderTooOld(let message) {
                // The shells belong to an older holder that this version can't drive. They're untouched;
                // ending them is the user's call.
                log("clothod: \(message)")
                showNotice("This Mac runs an older clothod that can't be updated in place. Restarting it finishes the update and ends every shell on this Mac.",
                           detail: message, action: "Restart clothod…") { [weak self] in self?.confirmRestartClothod() }
            } catch {
                log("backend failed to start: \(error)")
                emptyLabel.stringValue = "Couldn't start clothod: \(error.localizedDescription)"
            }
        }
    }

    /// `start` leaves an older daemon running, so after an update the app may be talking to the previous
    /// build. Its logic process can be swapped without touching the shells, but that restarts it, which
    /// the user decides: this only offers it (see DaemonUpdates.swift).
    func upgradeLocalLogicProcessIfNeeded(_ local: MachineConnection) async {
        // The hello arrives through the event stream, just after start() returns.
        for _ in 0..<20 where local.store.hello == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard let daemon = localDaemon, !daemon.runInPlace, local.store.hello != nil,
              let bundledID = await Task.detached(operation: { daemon.bundledID }).value else { return }
        // Only a provable upgrade: a hello without `exe` predates the install scheme, or the running
        // version is lower. Never a downgrade, and never between builds of the same version. `current`
        // resolves to the build it points at.
        offerHolderRestartIfNeeded(local)
        let running = local.store.hello?.exe.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        // The daemon's reported build decides, by version; daemons that don't report one fall back to `exe`.
        let outdated = local.store.hello?.build.map { RemoteSetup.isOlder($0, than: bundledID) }
            ?? RemoteSetup.isOutdated(runningExecutable: running, bundledID: bundledID)
        guard outdated else {
            if let running, RemoteSetup.installID(ofExecutable: running) != bundledID {
                log("clothod: the daemon runs \(running); not offering \(bundledID), it isn't a newer version")
            }
            return
        }
        log("clothod: the daemon runs \(running ?? "an older build"); offering the bundled \(bundledID)")
        offerDaemonUpdate(for: Self.localKey)
    }

    func confirmRestartClothod() {
        guard let daemon = localDaemon, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Restart clothod on this Mac?"
        alert.informativeText = "Every shell and program running in Clotho on this Mac ends. Other machines aren't affected."
        alert.addButton(withTitle: "End all shells and restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            hideNotice()
            Task { @MainActor in
                do {
                    try await Task.detached { try daemon.restartClothod() }.value
                    self.startBackend()
                } catch {
                    self.showNotice("Restarting clothod failed.", detail: error.localizedDescription, action: nil, then: nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only disconnects; every machine's daemon keeps its workspaces.
        connections.values.forEach { $0.store.stop() }
        // The dev build's daemons are temporary: shut them down and delete them, here and on every machine.
        if isDevBuild { cleanUpDevDaemons() }
    }

    func cleanUpDevDaemons() {
        let group = DispatchGroup()
        if let daemon = localDaemon, !daemon.runInPlace {
            group.enter()
            DispatchQueue.global().async { daemon.shutdownAndRemove(); group.leave() }
        }
        for (key, installer) in remoteInstallers {
            group.enter()
            DispatchQueue.global().async {
                try? installer.shutdownSessions()
                _ = try? installer.runner.run(RemoteSetup.removeDevDirsCommand, input: nil)
                log("\(key): dev daemon shut down and removed")
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 15)
        log("dev daemons cleaned up")
    }

    // Hack (Warp's default font), in its Nerd Font build so prompt icons render, ships inside the app.
    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let fonts = urls.filter { $0.pathExtension == "ttf" }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    static func terminalFont(size: CGFloat) -> NSFont {
        for name in ["HackNFM-Regular", "0xProtoNerdFontMono-Regular", "SFMono-Regular", "Menlo-Regular"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // Above the menu bar and Dock, so full screen covers them on this display only.
    // (Presentation options would hide the menu bar on every display.)
    static let fullScreenLevel = NSWindow.Level.statusBar

    // Fills the entire display, including the strip beside the camera notch.
    @objc func toggleFullScreen(_ sender: Any?) {
        if let frame = windowedFrame {
            windowedFrame = nil
            window.fillsScreen = false
            window.level = .normal
            container.layer?.cornerRadius = Self.cornerRadius
            window.hasShadow = true
            setNotchExtension(for: nil)
            window.setFrame(frame, display: true)
            window.setFrameAutosaveName("ClothoMainWindow")
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            windowedFrame = window.frame
            window.saveFrame(usingName: "ClothoMainWindow")
            window.setFrameAutosaveName("")
            window.fillsScreen = true
            window.level = Self.fullScreenLevel
            container.layer?.cornerRadius = 0
            window.hasShadow = false
            window.setFrame(screen.frame, display: true)
            setNotchExtension(for: screen)
        }
    }

    // On a notched display, push the chrome below the notch and fill the strip beside it.
    func setNotchExtension(for screen: NSScreen?) {
        let notch = screen?.safeAreaInsets.top ?? 0
        notchHeight.constant = notch
        notchExtension.isHidden = notch == 0
    }

    // Drop below other apps' windows while they're in use, and cover the menu bar again on return.
    func applicationDidResignActive(_ notification: Notification) {
        guard windowedFrame != nil else { return }
        window.level = .normal
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkMachinesIfStale()
        guard windowedFrame != nil, let screen = window.screen ?? NSScreen.main else { return }
        window.level = Self.fullScreenLevel
        window.setFrame(screen.frame, display: true)
        setNotchExtension(for: screen)
    }

    @objc func closeWindow(_ sender: Any?) {
        window.close()
    }

    @objc func minimizeWindow(_ sender: Any?) {
        window.minimize()
    }

    @objc func zoomWindow(_ sender: Any?) {
        guard windowedFrame == nil else { return }
        window.zoom(nil)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        window.restoreAfterMinimize()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        let hide = sidebarWidth.constant > 0
        UserDefaults.standard.set(hide, forKey: "HideSidebar")
        sidebarWidth.constant = hide ? 0 : savedSidebarWidth
        updateTabBarInset()
    }

    // Wide enough to read long agent titles in the Agents panel (rows stay one line each).
    static let sidebarWidthRange: ClosedRange<CGFloat> = 150...640

    /// The width the sidebar was last dragged to.
    var savedSidebarWidth: CGFloat {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "SidebarWidth"))
        return saved > 0 ? min(max(saved, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound) : SidebarView.width
    }

    // With the sidebar hidden, the tab bar starts after the window buttons.
    func updateTabBarInset() {
        tabBarLeading.constant = sidebarWidth.constant > 0 ? 0 : 80
    }

    @objc func zoomIn(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetZoom(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    // Every pane re-measures, and sends its new viewport to the backend.
    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 8), 32)
        guard clamped != fontSize || paneHosts.values.contains(where: { $0.terminal.font.pointSize != clamped }) else { return }
        fontSize = clamped
        let font = Self.terminalFont(size: clamped)
        paneHosts.values.forEach { $0.fontChanged(font) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
