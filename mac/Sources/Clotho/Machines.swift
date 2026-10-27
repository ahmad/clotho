import AppKit

// Saved SSH machines: adding, editing and removing them, a connection check for machines that aren't
// connected, and the sidebar's machine menu. Connected machines' sessions are in MachineSessions.swift.

enum MachineStatus: Equatable {
    case unknown, checking, reachable
    case unreachable(String)

    var color: NSColor? {
        switch self {
        case .unknown: return nil
        case .checking: return Theme.dimText
        case .reachable: return NSColor(hex: 0x57C78A)
        case .unreachable: return NSColor(hex: 0xC76156)
        }
    }

    var summary: String {
        switch self {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking the connection…"
        case .reachable: return "Reachable over SSH"
        case .unreachable(let reason): return "Can't connect: \(reason)"
        }
    }
}

extension AppDelegate {
    /// Saved machines, without Local.
    var remoteMachines: [Machine] { Machine.all().filter { !$0.isLocal } }

    // MARK: Connection checks

    /// Runs `ssh <target> true` without prompts, the same way the file browser connects.
    func checkMachine(_ machine: Machine) {
        guard let id = machine.id, machineStatus[id] != .checking else { return }
        machineStatus[id] = .checking
        sync()
        DispatchQueue.global(qos: .utility).async {
            let status: MachineStatus
            do {
                _ = try SSH.run(machine, "true")
                status = .reachable
            } catch {
                // ssh's own message, minus the "Can't reach <name> over SSH." lead-in.
                let message = error.localizedDescription.replacingOccurrences(of: "Can't reach \(machine.label) over SSH. ", with: "")
                status = .unreachable(message.isEmpty ? "ssh failed" : message)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                machineStatus[id] = status
                sync()
            }
        }
    }

    /// Checks every machine, at most once a minute (on launch and whenever the app comes forward).
    func checkMachinesIfStale() {
        guard Date().timeIntervalSince(lastMachineCheck) > 60 else { return }
        lastMachineCheck = Date()
        remoteMachines.forEach(checkMachine)
    }

    // MARK: Editing

    @objc func addMachine(_ sender: Any?) {
        promptForMachine(editing: nil) { _ in }
    }

    /// Asks for a name and an SSH target, then saves the machine (new, or `editing`) and checks it.
    func promptForMachine(editing existing: Machine?, then done: @escaping (Machine?) -> Void) {
        guard window.attachedSheet == nil else { return done(nil) }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Machine" : "Edit \(existing!.label)"
        alert.informativeText = "Clotho connects with ssh using your ~/.ssh/config and keys, without prompts, "
            + "so the host must accept your key or agent. The machine needs python3 and rsync for files."
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        name.placeholderString = "Name (for example, iMac)"
        name.stringValue = existing?.label ?? ""
        let target = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        target.placeholderString = "SSH target: user@host, an alias or a Tailscale name"
        target.stringValue = existing?.target ?? ""
        name.nextKeyView = target
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        fields.addSubview(name)
        fields.addSubview(target)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            let host = target.stringValue.trimmingCharacters(in: .whitespaces)
            let label = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !host.isEmpty else { return done(nil) }
            let machine = existing?.id.map { Machine.update($0, label: label, target: host) }
                ?? Machine.add(label: label, target: host)
            if let id = machine.id { machineStatus[id] = .unknown }
            checkMachine(machine)
            done(machine)
        }
    }

    func removeMachine(_ machine: Machine) {
        guard let id = machine.id, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(machine.label)?"
        alert.informativeText = "This only removes it from Clotho's list. Nothing on the machine changes, and its sessions keep running there."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // Its sessions keep running on the machine; Clotho just stops showing them.
            self?.disconnect(machine.key)
            Machine.remove(id)
            self?.machineStatus[id] = nil
        }
    }

    /// The right-click menu for a machine's header in the sidebar.
    func menu(forMachine key: MachineKey) -> NSMenu {
        let menu = NSMenu()
        let add = { (title: String, action: @escaping () -> Void) in menu.addItem(ClosureMenuItem(title: title, action: action)) }
        let machine = key == Self.localKey ? Machine.local : remoteMachines.first { $0.key == key }
        guard let machine else { return menu }
        let connected = sessions[key] != nil
        if connected || machine.isLocal {
            add("New Session") { [weak self] in self?.newSession(on: key) }
        } else {
            add("Connect") { [weak self] in self?.connect(machine) }
            add("Connect and Start a Session") { [weak self] in self?.connect(machine, newSession: true) }
        }
        add("Browse Files") { [weak self] in self?.showFileBrowser(on: machine) }
        // Agents on this machine show in the Agents section, notify and count toward the dock badge.
        let monitor = ClosureMenuItem(title: "Monitor Agents") { [weak self] in
            guard let self else { return }
            setMonitorsAgents(key, !monitorsAgents(key))
        }
        monitor.state = monitorsAgents(key) ? .on : .off
        menu.addItem(monitor)
        // Until an agent there reports through hooks, offer to set them up (never automatically).
        if (connected || machine.isLocal), !hasHookSourcedAgents(key) {
            add("Set Up Agent Status…") { [weak self] in self?.setUpAgentHooks(on: key) }
        }
        guard !machine.isLocal else { return menu }
        if connected {
            add("Reconnect") { [weak self] in self?.sessions[key]?.store.backend.reconnectNow() }
            add("Disconnect") { [weak self] in self?.disconnect(key) }
        } else {
            add("Check Connection") { [weak self] in self?.checkMachine(machine) }
        }
        menu.addItem(.separator())
        add("Edit…") { [weak self] in self?.promptForMachine(editing: machine) { _ in } }
        add("Remove…") { [weak self] in self?.removeMachine(machine) }
        return menu
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
