import AppKit
import ClothoKit

// Saved SSH machines: adding, editing and removing them, a connection check for machines that aren't
// connected, and the sidebar's machine menu. Connected machines' workspaces are in MachineConnections.swift.

enum MachineStatus: Equatable {
    case unknown, checking, reachable
    case unreachable(String)

    var color: NSColor? {
        switch self {
        case .unknown: return nil
        case .checking: return Theme.dimText
        case .reachable: return Theme.success
        case .unreachable: return Theme.danger
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

    /// Asks for a name and an SSH target, then saves the machine (new, or `editing`) and checks it, as a
    /// sheet on `parent` (the main window by default). A connected machine whose target changed is
    /// reconnected to the new target; its workspaces stay on the old host, which keeps running them.
    func promptForMachine(editing existing: Machine?, in parent: NSWindow? = nil, then done: @escaping (Machine?) -> Void) {
        let host = parent ?? window!
        guard host.attachedSheet == nil else { return done(nil) }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Machine" : "Edit \(existing!.label)"
        alert.informativeText = "Clotho connects with ssh using your ~/.ssh/config and keys, without prompts, "
            + "so the host must accept your key or agent."
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
        alert.beginSheetModal(for: host) { [weak self] response in
            let sshTarget = target.stringValue.trimmingCharacters(in: .whitespaces)
            let label = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !sshTarget.isEmpty else { return done(nil) }
            if let problem = SSHTarget.problem(sshTarget) {
                // Nothing is saved; the sheet is gone, so the reason gets its own.
                DispatchQueue.main.async {
                    let refusal = NSAlert()
                    refusal.messageText = "Can't use \"\(sshTarget)\""
                    refusal.informativeText = problem
                    refusal.beginSheetModal(for: host)
                }
                return done(nil)
            }
            let machine = existing?.id.map { Machine.update($0, label: label, target: sshTarget) }
                ?? Machine.add(label: label, target: sshTarget)
            if let id = machine.id { machineStatus[id] = .unknown }
            if let existing, existing.target != sshTarget, connections[existing.key] != nil {
                log("\(machine.label): target changed to \(sshTarget), reconnecting")
                disconnect(existing.key)
                connect(machine)
            } else {
                checkMachine(machine)
            }
            done(machine)
        }
    }

    func removeMachine(_ machine: Machine, in parent: NSWindow? = nil) {
        let host = parent ?? window!
        guard machine.isEditable, let id = machine.id, host.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(machine.label)?"
        alert.informativeText = "This only removes it from Clotho's list. Nothing on the machine changes: its clothod and its shells keep running there, and adding it again shows them."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: host) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // Its workspaces keep running on the machine; Clotho just stops showing them.
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
        let connected = connections[key] != nil
        if connected || machine.isLocal {
            add("New Workspace") { [weak self] in self?.newWorkspace(on: key) }
        } else {
            add("Connect") { [weak self] in self?.connect(machine) }
            add("Connect and Start a Workspace") { [weak self] in self?.connect(machine, startWorkspace: true) }
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
        // Older hooks (from a previous clothod) are offered as an update even though they still report.
        if (connected || machine.isLocal), !hasHookSourcedAgents(key) || hooksNeedUpdate(key) {
            add(hooksNeedUpdate(key) ? "Update Agent Status…" : "Set Up Agent Status…") { [weak self] in self?.setUpAgentHooks(on: key) }
        }
        guard !machine.isLocal else { return menu }
        if connected {
            add("Reconnect") { [weak self] in self?.connections[key]?.store.backend.reconnectNow() }
            add("Disconnect") { [weak self] in self?.disconnect(key) }
        } else {
            add("Check Connection") { [weak self] in self?.checkMachine(machine) }
        }
        menu.addItem(.separator())
        add("Edit…") { [weak self] in self?.promptForMachine(editing: machine) { _ in } }
        add("Remove…") { [weak self] in self?.removeMachine(machine) }
        add("Manage Machines…") { [weak self] in self?.showMachineManager(nil) }
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
