import AppKit
import ClothoKit

// Settings (⌘,): one window with two tabs in the standard Settings toolbar, and its title follows the tab.
//   General   agent notifications, light or dark, and updates.
//   Machines  the saved machines (MachinesSettings.swift): order, on/off, add, edit, remove, and the
//             selected machine's own settings (its agents, clothod's scrollback and start at login),
//             which live in that machine's clothod, so every client sees the same values.
// The sidebar's Settings button opens General; its Machines button and Manage Machines… open Machines.

enum SettingsTab: String, CaseIterable {
    case general, machines

    var title: String { self == .general ? "General" : "Machines" }
    var symbol: String { self == .general ? "gearshape" : "server.rack" }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    weak var app: AppDelegate?
    let tabs = SettingsTabsController()
    let general: GeneralSettingsController
    let machines: MachinesSettingsController

    init(app: AppDelegate) {
        self.app = app
        general = GeneralSettingsController(app: app)
        machines = MachinesSettingsController(app: app)
        for (tab, controller) in [(SettingsTab.general, general as NSViewController), (.machines, machines)] {
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        // A Settings window: fixed size per tab, no zoom, the system's standard buttons.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("ClothoSettings")
        super.init(window: window)
        window.delegate = self
        tabs.onSelect = { [weak self] in self?.fitWindowToTab(animate: true) }
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedTab: SettingsTab {
        SettingsTab(rawValue: tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String ?? "") ?? .general
    }

    func show(_ tab: SettingsTab) {
        let wasVisible = window?.isVisible == true
        reload()
        loadMachineSettings()
        if let index = SettingsTab.allCases.firstIndex(of: tab) { tabs.selectedTabViewItemIndex = index }
        fitWindowToTab(animate: false)
        if !wasVisible { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        log("settings: showing \(tab.rawValue)")
    }

    /// Each tab has its own fixed size; the window takes it, keeping its top edge where it is.
    func fitWindowToTab(animate: Bool) {
        guard let window, let controller = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController else { return }
        controller.view.layoutSubtreeIfNeeded()
        let size = NSSize(width: SettingsStyle.width, height: controller.view.fittingSize.height)
        controller.preferredContentSize = size
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    // MARK: What the rest of the app calls

    func reload() {
        general.reload()
        machines.reload()
    }

    func refreshIfNeeded() {
        guard window?.isVisible == true else { return }
        machines.refreshIfNeeded()
    }

    func loadMachineSettings() { machines.loadMachineSettings() }
    func setStartsAtLogin(_ on: Bool, on key: MachineKey) { machines.setStartsAtLogin(on, on: key) }
    func setScrollback(_ lines: Int, on key: MachineKey) { machines.setScrollback(lines, on: key) }

    func windowWillClose(_ notification: Notification) {
        log("settings: closed")
    }
}

/// The tab controller, telling the window when the user picks another tab.
final class SettingsTabsController: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}

// MARK: General

@MainActor
final class GeneralSettingsController: NSViewController {
    weak var app: AppDelegate?
    private let content = NSStackView()
    /// Targets for closure-based controls live as long as the current contents.
    private var targets: [ClosureTarget] = []
    /// The appearance control, for tests and the toggle in the sidebar.
    private(set) var appearanceControl: NSSegmentedControl?
    private(set) var updatesSwitch: NSSwitch?

    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: SettingsStyle.width),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: SettingsStyle.margin),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsStyle.margin),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsStyle.margin),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -SettingsStyle.margin),
        ])
        view = root
        reload()
    }

    func reload() {
        guard let app, isViewLoaded else { return }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll()
        for section in [notifications(app), appearance(), updates(app)] {
            content.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func toggle(_ on: Bool, _ label: String, _ changed: @escaping (Bool) -> Void) -> NSSwitch {
        let (toggle, target) = SettingsStyle.toggle(on: on, label: label, changed: changed)
        targets.append(target)
        return toggle
    }

    private func notifications(_ app: AppDelegate) -> NSView {
        let rows = [(AgentInfo.State.waiting, "An agent is waiting for you"), (.done, "An agent finishes"),
                    (.error, "An agent hits an error")].map { state, title in
            FormRow(title, control: toggle(app.notifies(state), title) { on in
                UserDefaults.standard.set(on, forKey: "NotifyAgent.\(state.rawValue)")
            })
        }
        return formSection("Notifications", FormGroup(rows), footnote: "From agents that report their state, such as Claude Code and Codex with status hooks.")
    }

    private func appearance() -> NSView {
        let modes = Theme.Mode.allCases
        let control = NSSegmentedControl(labels: modes.map { $0 == .system ? "System" : $0.title }, trackingMode: .selectOne,
                                         target: nil, action: nil)
        control.selectedSegment = modes.firstIndex(of: Theme.Mode.current) ?? 0
        control.controlSize = .regular
        let target = ClosureTarget { [weak app] sender in
            guard let index = (sender as? NSSegmentedControl)?.selectedSegment, modes.indices.contains(index) else { return }
            app?.setAppearance(modes[index])
        }
        targets.append(target)
        control.target = target
        control.action = #selector(ClosureTarget.fire(_:))
        control.setAccessibilityLabel("Appearance")
        appearanceControl = control
        return formSection("Appearance", FormGroup([FormRow("Appearance", caption: "Terminals follow too", control: control)]))
    }

    private func updates(_ app: AppDelegate) -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let check = ClosureButton(title: "Check Now") { [weak app] in app?.checkForUpdates(nil) }
        check.bezelStyle = .rounded
        let automatic: FormRow
        if let reason = app.updates.unavailableReason {
            let off = toggle(false, "Check for updates automatically") { _ in }
            off.isEnabled = false
            check.isEnabled = false
            automatic = FormRow("Check for updates automatically", caption: reason, control: off)
        } else {
            let on = toggle(app.updates.automaticallyChecks, "Check for updates automatically") { [weak app] on in
                app?.updates.automaticallyChecks = on
            }
            updatesSwitch = on
            automatic = FormRow("Check for updates automatically", caption: "Daily; asks before installing", control: on)
        }
        let current = FormRow("Clotho \(version)", caption: build.map { "Build \($0)" }, control: check)
        return formSection("Updates", FormGroup([automatic, current]))
    }
}

/// Runs a closure as a control's action.
final class ClosureTarget: NSObject {
    private let body: (Any?) -> Void
    init(_ body: @escaping (Any?) -> Void) { self.body = body }
    @objc func fire(_ sender: Any?) { body(sender) }
}

extension AppDelegate {
    /// ⌘, and the sidebar's Settings button: Settings on General.
    @objc func showSettings(_ sender: Any?) { showSettings(tab: .general) }

    /// Manage Machines… and the sidebar's Machines button: Settings on Machines.
    @objc func showMachineManager(_ sender: Any?) { showSettings(tab: .machines) }

    /// The sidebar's Machines and Settings buttons (and its machines' Manage Machines…) open Settings on
    /// their tab.
    func wireSettingsButtons(_ sidebar: SidebarView) {
        sidebar.onManageMachines = { [weak self] in self?.showMachineManager(nil) }
        sidebar.footer.onSettings = { [weak self] in self?.showSettings(nil) }
    }

    func showSettings(tab: SettingsTab) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show(tab)
    }
}
