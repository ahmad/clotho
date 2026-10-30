import AppKit
import ClothoKit

// Settings › Machines: the saved machines in the sidebar's order, This Mac first. Each row shows the
// machine's name, its user@host, a status dot (connected, connecting, off, can't reach) and, for saved
// machines, a switch that turns it off in Clotho (AppDelegate.setMachineEnabled). Under the list a +/−
// control adds and removes machines; double-click (or the row's menu) edits one; drag reorders. Below
// that, the selected machine's own settings: whether its agents show, clothod's scrollback and whether
// clothod starts at login. Removing or switching off only changes Clotho; clothod and shells keep running.

/// What a machine's row says about it.
enum MachineRowStatus: Equatable {
    case thisMac, connected, connecting, notConnected, unreachable, off

    var text: String {
        switch self {
        case .thisMac: return "This Mac"
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .notConnected: return "Not connected"
        case .unreachable: return "Can't reach"
        case .off: return "Off"
        }
    }

    /// The dot's colour; nil draws a hollow ring (off).
    var color: NSColor? {
        switch self {
        case .thisMac, .connected: return .systemGreen
        case .connecting: return .systemYellow
        case .notConnected: return .tertiaryLabelColor
        case .unreachable: return .systemRed
        case .off: return nil
        }
    }

    /// `connected` is nil without a connection; `paused` means it stopped retrying (Reconnect).
    static func of(isLocal: Bool, isEnabled: Bool, connected: Bool?, paused: Bool, check: MachineStatus?) -> MachineRowStatus {
        if isLocal { return .thisMac }
        if !isEnabled { return .off }
        if let connected {
            if connected { return .connected }
            return paused ? .unreachable : .connecting
        }
        if case .unreachable = check { return .unreachable }
        return .notConnected
    }
}

@MainActor
final class MachinesSettingsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var app: AppDelegate?
    let table = NSTableView()
    let addRemove = NSSegmentedControl()
    private(set) var machines: [Machine] = []
    private let details = NSStackView()
    private let footnote = SettingsStyle.caption("Drag to reorder. Switching a machine off or removing it leaves its clothod and shells running.")
    private var observer: NSObjectProtocol?
    private var targets: [ClosureTarget] = []
    /// Scrollback edits wait a moment, so typing 10000 doesn't set 1, 10, 100 and 1000 on the way.
    private var pendingScrollback: [MachineKey: DispatchWorkItem] = [:]
    /// The last error per machine, shown in red in place of the footnote until the next change.
    private var errors: [MachineKey: String] = [:]
    private var shownSignature = ""
    static let dragType = NSPasteboard.PasteboardType("app.clotho.desktop.machine-row")
    static let visibleRows = 4

    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("machine"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = SettingsStyle.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Machines")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let list = FormGroup([scroll])
        scroll.heightAnchor.constraint(equalToConstant: SettingsStyle.rowHeight * CGFloat(Self.visibleRows)).isActive = true

        addRemove.segmentCount = 2
        addRemove.trackingMode = .momentary
        addRemove.segmentStyle = .smallSquare
        addRemove.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        addRemove.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        addRemove.setToolTip("Add a machine", forSegment: 0)
        addRemove.setToolTip("Remove the selected machine", forSegment: 1)
        for segment in 0..<2 { addRemove.setWidth(26, forSegment: segment) }
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked(_:))
        addRemove.setAccessibilityLabel("Add or remove a machine")

        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        footnote.preferredMaxLayoutWidth = SettingsStyle.width - 2 * SettingsStyle.margin

        for view in [list, addRemove, details, footnote] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let margin = SettingsStyle.margin
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: SettingsStyle.width),
            list.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            addRemove.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 8),
            addRemove.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            details.topAnchor.constraint(equalTo: addRemove.bottomAnchor, constant: 20),
            details.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            footnote.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 14),
            footnote.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            footnote.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor),
            footnote.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(forName: Machine.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    // MARK: Contents

    var selectedMachine: Machine? {
        table.selectedRow >= 0 && table.selectedRow < machines.count ? machines[table.selectedRow] : nil
    }

    func reload() {
        guard isViewLoaded else { return }
        let selected = selectedMachine?.key
        machines = Machine.all()
        table.reloadData()
        if let selected, let row = machines.firstIndex(where: { $0.key == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateAddRemove()
        reloadDetails()
    }

    /// Rebuilds when what the rows and details show changes: connections, statuses and loaded settings.
    func refreshIfNeeded() {
        guard let app, isViewLoaded else { return }
        let signature = Machine.all().map { machine in
            let store = app.connections[machine.key]?.store
            return "\(machine.key):\(machine.isEnabled):\(store?.isConnected ?? false):\(store?.retryPaused ?? false):"
                + "\(store?.hello?.version ?? "-"):\(store?.settings != nil):\(store?.service != nil):"
                + "\(machine.id.flatMap { app.machineStatus[$0] }.map { "\($0)" } ?? "-")"
        }.joined(separator: ",")
        guard signature != shownSignature else { return }
        shownSignature = signature
        if app.connections.values.contains(where: {
            ($0.store.settings == nil && $0.store.hello?.features.contains(.settings) == true)
                || ($0.store.service == nil && $0.store.hello?.features.contains(.service) == true)
        }) {
            loadMachineSettings()
        }
        reload()
    }

    func status(of machine: Machine) -> MachineRowStatus {
        let store = app?.connections[machine.key]?.store
        return .of(isLocal: machine.isLocal, isEnabled: machine.isEnabled, connected: store.map(\.isConnected),
                   paused: store?.retryPaused ?? false, check: machine.id.flatMap { app?.machineStatus[$0] })
    }

    /// The line under a machine's name: its SSH target.
    static func detail(for machine: Machine) -> String {
        machine.target ?? ComputerName.current
    }

    private func updateAddRemove() {
        addRemove.setEnabled(selectedMachine?.isEditable == true, forSegment: 1)
    }

    // MARK: Actions

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? addMachine() : removeSelected()
    }

    @objc func addMachine() {
        guard let window = view.window else { return }
        app?.promptForMachine(editing: nil, in: window) { _ in }
    }

    @objc func editSelected() {
        guard let machine = selectedMachine, machine.isEditable, let window = view.window else { return }
        app?.promptForMachine(editing: machine, in: window) { _ in }
    }

    @objc func removeSelected() {
        guard let machine = selectedMachine, machine.isEditable, let window = view.window else { return }
        app?.removeMachine(machine, in: window)
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        guard sender.tag >= 0, sender.tag < machines.count else { return }
        app?.setMachineEnabled(machines[sender.tag], sender.state == .on)
    }

    // The row's menu: Edit…, Switch Off/On, Remove….
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, table.clickedRow < machines.count else { return }
        let machine = machines[table.clickedRow]
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        guard machine.isEditable else { return }
        menu.addItem(withTitle: "Edit…", action: #selector(editSelected), keyEquivalent: "").target = self
        let toggle = menu.addItem(withTitle: machine.isEnabled ? "Switch Off" : "Switch On", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove…", action: #selector(removeSelected), keyEquivalent: "").target = self
    }

    @objc private func toggleFromMenu() {
        guard let machine = selectedMachine else { return }
        app?.setMachineEnabled(machine, !machine.isEnabled)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { machines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let machine = machines[row]
        let name = NSTextField(labelWithString: machine.isLocal ? ComputerName.current : machine.label)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: machine.isLocal ? "This Mac" : Self.detail(for: machine))
        detail.font = SettingsStyle.captionFont
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let icon = NSImageView(image: NSImage(systemSymbolName: machine.isLocal ? "laptopcomputer" : "server.rack",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let status = self.status(of: machine)
        let dot = StatusDot(color: status.color)
        let statusLabel = NSTextField(labelWithString: status.text)
        statusLabel.font = SettingsStyle.captionFont
        statusLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [icon, text, spacer, dot, statusLabel]
        if !machine.isLocal {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = machine.isEnabled ? .on : .off
            toggle.tag = row
            toggle.target = self
            toggle.action = #selector(switchToggled(_:))
            toggle.setAccessibilityLabel("\(machine.label) on")
            toggle.toolTip = machine.isEnabled ? "Switch \(machine.label) off in Clotho" : "Switch \(machine.label) back on"
            views.append(toggle)
            // Off: dimmed, but still here to switch back on.
            for view in [icon, text] { view.alphaValue = machine.isEnabled ? 1 : 0.45 }
        } else {
            // Lines the status up with the rows that have a switch.
            let gap = NSView()
            gap.widthAnchor.constraint(equalToConstant: 32).isActive = true
            views.append(gap)
        }
        let cell = NSStackView(views: views)
        cell.orientation = .horizontal
        cell.spacing = 8
        cell.setCustomSpacing(10, after: icon)
        cell.setCustomSpacing(5, after: dot)
        cell.setCustomSpacing(12, after: statusLabel)
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        cell.identifier = NSUserInterfaceItemIdentifier(machine.key)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateAddRemove()
        reloadDetails()
    }

    // Drag to reorder saved machines; this Mac stays first.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard machines[row].isEditable, let id = machines[row].id else { return nil }
        let item = NSPasteboardItem()
        item.setString(id, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(max(row, 1), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.dragType),
              let from = machines.firstIndex(where: { $0.id == id }) else { return false }
        Machine.move(id, to: Self.savedIndex(dropRow: row, from: from))
        return true
    }

    /// Where a machine dragged from table row `from` lands among the saved machines when dropped above
    /// table row `dropRow` (row 0 is this Mac).
    nonisolated static func savedIndex(dropRow: Int, from: Int) -> Int {
        let row = max(dropRow, 1)
        return (row > from ? row - 1 : row) - 1
    }

    // MARK: The selected machine's settings

    /// The machine the details show: the selected row, else this Mac.
    var detailMachine: Machine { selectedMachine ?? .local }

    private func reloadDetails() {
        guard let app else { return }
        // A field being edited keeps its text: rebuilding would throw the edit away.
        if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor, details.arrangedSubviews.contains(where: { editor.isDescendant(of: $0) }) {
            return
        }
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll()
        let machine = detailMachine
        let key = machine.key
        let name = machine.isLocal ? ComputerName.current : machine.label
        let session = machine.isEnabled ? app.connections[key] : nil
        let hello = session?.store.isConnected == true ? session?.store.hello : nil
        // Why clothod's settings can't be changed now, if they can't.
        let unavailable: String? = {
            guard machine.isEnabled else { return "Switched off" }
            guard let hello else { return "Connect to \(name) to change this" }
            return hello.features.contains(.settings) || hello.features.contains(.service) ? nil : "Needs clothod 0.1.7 or later"
        }()

        let (agents, agentsTarget) = SettingsStyle.toggle(on: app.monitorsAgents(key), label: "Show its agents") { [weak app] on in
            app?.setMonitorsAgents(key, on)
        }
        targets.append(agentsTarget)
        let agentsRow = FormRow("Show its agents", caption: "In the sidebar, ⌘P and notifications", control: agents)

        let scrollbackRow: FormRow
        if unavailable == nil, hello?.features.contains(.settings) == true, let settings = session?.store.settings {
            let limits = settings.limits.scrollbackLines
            scrollbackRow = FormRow("Scrollback", caption: "Lines per pane, \(limits.min.formatted())–\(limits.max.formatted())",
                                    control: scrollbackControl(settings, key: key))
        } else {
            let control = scrollbackControl(nil, key: key)
            let waiting = errors[key] == nil ? "Loading…" : "Unavailable"
            scrollbackRow = FormRow("Scrollback", caption: unavailable ?? (hello?.features.contains(.settings) == true ? waiting : "Needs clothod 0.1.7 or later"),
                                    control: control)
        }

        let loginRow: FormRow
        if unavailable == nil, hello?.features.contains(.service) == true, let service = session?.store.service {
            loginRow = loginControl(service, key: key)
        } else {
            let (off, target) = SettingsStyle.toggle(on: false, label: "Start clothod at login") { _ in }
            targets.append(target)
            off.isEnabled = false
            // Loading until the machine answers; Unavailable when it couldn't (the footnote says why).
            let waiting = errors[key] == nil ? "Loading…" : "Unavailable"
            loginRow = FormRow("Start clothod at login", caption: unavailable ?? (hello?.features.contains(.service) == true ? waiting : "Needs clothod 0.1.7 or later"),
                               control: off)
        }

        let section = formSection(machine.isLocal ? "\(name) (this Mac)" : name, FormGroup([agentsRow, scrollbackRow, loginRow]))
        details.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true

        if let error = errors[key] {
            footnote.stringValue = error
            footnote.textColor = .systemRed
        } else {
            footnote.stringValue = "Drag to reorder. Switching a machine off or removing it leaves its clothod and shells running."
            footnote.textColor = .secondaryLabelColor
        }
    }

    /// A number field and a stepper, within the daemon's limits; disabled without settings.
    private func scrollbackControl(_ settings: DaemonSettings?, key: MachineKey) -> NSView {
        let field = NSTextField(string: settings.map { "\($0.scrollbackLines)" } ?? "")
        field.alignment = .right
        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        field.setAccessibilityLabel("Scrollback lines")
        let stepper = NSStepper()
        stepper.controlSize = .small
        stepper.increment = 1000
        guard let settings else {
            field.isEnabled = false
            stepper.isEnabled = false
            return Self.row([field, stepper])
        }
        let limits = settings.limits.scrollbackLines
        field.formatter = Self.lineFormatter(limits)
        stepper.minValue = Double(limits.min)
        stepper.maxValue = Double(limits.max)
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
        return Self.row([field, stepper])
    }

    /// Start at login: the switch is whether the service is installed.
    private func loginControl(_ service: DaemonService, key: MachineKey) -> FormRow {
        let (login, target) = SettingsStyle.toggle(on: service.installed, label: "Start clothod at login") { [weak self] on in
            self?.setStartsAtLogin(on, on: key)
        }
        targets.append(target)
        // Turning it off always works; turning it on needs a service manager and nothing missing.
        login.isEnabled = service.installed || (service.supported && service.needs.isEmpty)
        var caption = "Keeps workspaces running before Clotho connects"
        if service.installed, !service.loaded { caption = "Installed, but \(service.manager ?? "the service manager") hasn't loaded it" }
        if let message = service.message { caption = message }
        guard service.installed && !service.upToDate else {
            return FormRow("Start clothod at login", caption: caption, control: login)
        }
        let refresh = ClosureButton(title: "Refresh") { [weak self] in self?.setStartsAtLogin(true, on: key) }
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.toolTip = "The login item is from another clothod build; Refresh rewrites it."
        return FormRow("Start clothod at login", caption: "From another clothod build", control: Self.row([refresh, login]))
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    static func lineFormatter(_ limits: DaemonSettings.Range) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: limits.min)
        formatter.maximum = NSNumber(value: limits.max)
        return formatter
    }

    // MARK: Applying (these live in each machine's clothod)

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
                self?.reloadDetails()
            }
        }
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
            self?.reloadDetails()
        }
    }

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
                self?.reloadDetails()
            }
        }
        pendingScrollback[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

/// A small status dot: filled with the status colour, or a hollow ring for a machine that's off.
final class StatusDot: NSView {
    let color: NSColor?

    init(color: NSColor?) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        if let color {
            color.setFill()
            path.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
