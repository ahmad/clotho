import AppKit

// Manage Machines… (the sidebar's footer, and each machine's menu): the saved machines in the order
// the sidebar shows them, with Add, Edit and Remove, and drag to reorder. This Mac is listed first and
// can't be removed, edited or moved. Removing only forgets a machine in Clotho.

@MainActor
final class MachineManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    weak var app: AppDelegate?
    private let table = NSTableView()
    private var machines: [Machine] = []
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    static let dragType = NSPasteboard.PasteboardType("app.clotho.desktop.machine-row")

    init(app: AppDelegate) {
        self.app = app
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Machines"
        panel.setFrameAutosaveName("ClothoMachines")
        panel.minSize = NSSize(width: 380, height: 220)
        panel.isFloatingPanel = false
        super.init(window: panel)
        panel.delegate = self

        let column = NSTableColumn(identifier: .init("machine"))
        column.title = "Machine"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "Add…", target: self, action: #selector(addMachine))
        editButton.target = self
        editButton.action = #selector(editSelected)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        let note = NSTextField(wrappingLabelWithString: "Drag to change the sidebar's order. Removing a machine only forgets it here; its clothod and shells keep running.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [add, editButton, removeButton, NSView()])
        buttons.orientation = .horizontal
        let content = NSView()
        for view in [scroll, buttons, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            note.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
        observer = NotificationCenter.default.addObserver(forName: Machine.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        log("machines: \(machines.map { $0.isLocal ? "\($0.label) (this Mac)" : "\($0.label) → \($0.target ?? "")" }.joined(separator: ", "))")
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let selected = selectedMachine?.id
        machines = Machine.all()
        table.reloadData()
        if let selected, let row = machines.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selectedMachine: Machine? {
        table.selectedRow >= 0 && table.selectedRow < machines.count ? machines[table.selectedRow] : nil
    }

    private func updateButtons() {
        let editable = selectedMachine?.isEditable == true
        editButton.isEnabled = editable
        removeButton.isEnabled = editable
    }

    // MARK: Actions

    @objc private func addMachine() {
        guard let window else { return }
        app?.promptForMachine(editing: nil, in: window) { _ in }
    }

    @objc private func editSelected() {
        guard let machine = selectedMachine, machine.isEditable, let window else { return }
        app?.promptForMachine(editing: machine, in: window) { _ in }
    }

    @objc private func removeSelected() {
        guard let machine = selectedMachine, machine.isEditable, let window else { return }
        app?.removeMachine(machine, in: window)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { machines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let machine = machines[row]
        let name = NSTextField(labelWithString: machine.isLocal ? "\(machine.label) (this Mac)" : machine.label)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: machine.target ?? "Always listed first, can't be removed")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: machine.isLocal ? "laptopcomputer" : "server.rack",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let cell = NSStackView(views: [icon, text])
        cell.orientation = .horizontal
        cell.spacing = 8
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

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
        // Rows count this Mac first; saved-machine indexes don't. Dropping below itself moves past it.
        let target = Self.savedIndex(dropRow: row, from: from)
        Machine.move(id, to: target)
        return true
    }

    /// Where a machine dragged from table row `from` lands among the saved machines when dropped above
    /// table row `dropRow` (row 0 is this Mac).
    nonisolated static func savedIndex(dropRow: Int, from: Int) -> Int {
        let row = max(dropRow, 1)
        return (row > from ? row - 1 : row) - 1
    }

    func windowWillClose(_ notification: Notification) {
        app?.machineManager = nil
    }
}

extension AppDelegate {
    @objc func showMachineManager(_ sender: Any?) {
        if machineManager == nil { machineManager = MachineManagerController(app: self) }
        machineManager?.show()
    }

    /// The sidebar's Create Workspace: on a connected machine at once; on another, it connects first.
    func createWorkspace(on key: MachineKey) {
        if key == Self.localKey || connections[key] != nil { return newWorkspace(on: key) }
        guard let machine = remoteMachines.first(where: { $0.key == key }) else { return }
        connect(machine, startWorkspace: true)
    }
}
