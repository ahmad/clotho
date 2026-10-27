import AppKit
import ClothoKit

// The right-click menu on a terminal: splits, tabs, workspaces, editing and files, for the pane that was
// clicked. Programs that use the mouse (vim with `mouse=a`, for example) get right-clicks instead, as in
// any terminal.
extension AppDelegate {
    func paneMenu(for key: PaneKey) -> NSMenu? {
        guard let session = connections[key.machine], let pane = session.store.state.pane(key.pane),
              let host = paneHosts[key] else { return nil }
        // The menu acts on this pane, so it becomes the focused one first.
        window.makeFirstResponder(host.terminal)
        let menu = NSMenu()
        // Items are enabled as set here (Copy only with a selection).
        menu.autoenablesItems = false
        let add = { (title: String, key: String, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) in
            let item = ClosureMenuItem(title: title, action: action)
            // Shown for reference; the main menu handles the shortcuts themselves.
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }

        add("Split Right", "d", [.command]) { [weak self] in self?.split(pane, .right) }
        add("Split Left", "d", [.command, .option]) { [weak self] in self?.split(pane, .left) }
        add("Split Down", "d", [.command, .shift]) { [weak self] in self?.split(pane, .down) }
        add("Split Up", "d", [.command, .option, .shift]) { [weak self] in self?.split(pane, .up) }
        if let tab = store.focusedTab, tab.layout.panes.count > 1 {
            let isMaximized = maximized[tabKey(tab.id)] == key.pane
            add(isMaximized ? "Restore Pane" : "Maximize Pane", "\r", [.command, .shift]) { [weak self] in self?.toggleMaximize(key.pane) }
        }
        add("Close Pane", "w", [.command]) { [weak self] in self?.close(pane: key.pane) }

        menu.addItem(.separator())
        add("New Tab", "t", [.command]) { [weak self] in self?.newTab(nil) }
        add("New Workspace", "n", [.command]) { [weak self] in self?.newWorkspace(nil) }

        menu.addItem(.separator())
        let terminal = host.terminal
        add("Copy", "c", [.command]) { terminal.copy(terminal) }
        // Copy with nothing selected would empty the clipboard.
        menu.items.last?.isEnabled = terminal.hasSelection
        add("Paste", "v", [.command]) { terminal.paste(terminal) }
        add("Select All", "a", [.command]) { terminal.selectAll(nil) }
        add("Clear", "k", [.command]) { [weak self] in self?.backend.sendInput(key.pane, Data([0x0c])) }
        add("Find…", "f", [.command]) { [weak self] in self?.paneHosts[key]?.showFind() }

        menu.addItem(.separator())
        let machine = session.machine
        add("Upload Files Here…", "u", [.command, .shift]) { [weak self] in self?.chooseFilesToUpload(nil) }
        add("Browse Files", "o", [.command, .shift]) { [weak self] in
            guard let self else { return }
            if fileBrowser == nil { showFileBrowser(on: machine) }
        }
        return menu
    }
}
