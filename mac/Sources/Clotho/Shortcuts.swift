import AppKit
import ClothoKit

// One table drives both the menu bar and the shortcuts window, so they can't drift apart.
// Bindings follow Warp's macOS defaults; workspaces play the part of Warp's windows.
struct Shortcut {
    let menu: String
    let title: String
    let key: String
    var modifiers: NSEvent.ModifierFlags = .command
    let action: Selector
    var tag = 0
    // Hidden items still fire but stay out of the menu.
    var hiddenInMenu = false
    // Rows folded into another row's listing are left out of the shortcuts window.
    var listed = true
    var listTitle: String? = nil
    var listKeys: String? = nil

    static let arrows: [(name: String, key: String, symbol: String)] = [
        ("Left", String(UnicodeScalar(NSLeftArrowFunctionKey)!), "←"),
        ("Right", String(UnicodeScalar(NSRightArrowFunctionKey)!), "→"),
        ("Up", String(UnicodeScalar(NSUpArrowFunctionKey)!), "↑"),
        ("Down", String(UnicodeScalar(NSDownArrowFunctionKey)!), "↓"),
    ]

    var displayKeys: String {
        if let listKeys { return listKeys }
        return Self.symbols(for: modifiers) + Self.keySymbol(key)
    }

    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    static func keySymbol(_ key: String) -> String {
        if let arrow = arrows.first(where: { $0.key == key }) { return arrow.symbol }
        switch key {
        case "\r": return "↩"
        case "": return ""
        default: return key.uppercased()
        }
    }

    // AppKit matches shifted punctuation by the character it produces, so ⇧⌘[ is registered as ⌘{.
    ///
    /// Letters too: AppKit reads a lowercase key equivalent with Shift in its mask as the plain letter, so
    /// "r" + ⇧⌘ fired on ⌘R (Rename Workspace took Rename Tab's key) and never on ⇧⌘R. The convention is
    /// the capital letter without Shift in the mask.
    var menuKey: (String, NSEvent.ModifierFlags) {
        let shifted = ["[": "{", "]": "}"]
        if modifiers.contains(.shift), let char = shifted[key] {
            return (char, modifiers.subtracting(.shift))
        }
        if modifiers.contains(.shift), key.count == 1, let letter = key.first, letter.isLetter, letter.isLowercase {
            return (key.uppercased(), modifiers.subtracting(.shift))
        }
        return (key, modifiers)
    }
}

extension AppDelegate {
    static let shortcuts: [Shortcut] = {
        var list: [Shortcut] = [
            Shortcut(menu: "Clotho", title: "Check for Updates…", key: "", action: #selector(checkForUpdates(_:)), listed: false),
            Shortcut(menu: "Clotho", title: "Settings…", key: ",", action: #selector(showSettings(_:))),
            Shortcut(menu: "Clotho", title: "Hide Clotho", key: "h", action: #selector(NSApplication.hide(_:))),
            Shortcut(menu: "Clotho", title: "Quit Clotho", key: "q", action: #selector(NSApplication.terminate(_:))),

            Shortcut(menu: "File", title: "Upload Files…", key: "u", modifiers: [.command, .shift], action: #selector(chooseFilesToUpload(_:))),
            Shortcut(menu: "File", title: "Manage Machines…", key: "", action: #selector(showMachineManager(_:)), listed: false),
            Shortcut(menu: "File", title: "Add Machine…", key: "", action: #selector(addMachine(_:)), listed: false),

            Shortcut(menu: "Edit", title: "Copy", key: "c", action: #selector(NSText.copy(_:))),
            Shortcut(menu: "Edit", title: "Paste", key: "v", action: #selector(NSText.paste(_:))),
            Shortcut(menu: "Edit", title: "Select All", key: "a", action: #selector(NSText.selectAll(_:))),
            Shortcut(menu: "Edit", title: "Clear", key: "k", action: #selector(clearActivePane(_:))),
            // The pane's find bar (PaneSearch.swift): Next goes up to older output, Previous back down.
            Shortcut(menu: "Edit", title: "Find…", key: "f", action: #selector(findInPane(_:))),
            Shortcut(menu: "Edit", title: "Find Next", key: "g", action: #selector(findNextInPane(_:))),
            Shortcut(menu: "Edit", title: "Find Previous", key: "g", modifiers: [.command, .shift], action: #selector(findPreviousInPane(_:))),

            Shortcut(menu: "View", title: "Actual Size", key: "0", action: #selector(resetZoom(_:))),
            Shortcut(menu: "View", title: "Zoom In", key: "+", action: #selector(zoomIn(_:))),
            // ⌘= is the unshifted ⌘+ on most keyboards.
            Shortcut(menu: "View", title: "Zoom In", key: "=", action: #selector(zoomIn(_:)), hiddenInMenu: true, listed: false),
            Shortcut(menu: "View", title: "Zoom Out", key: "-", action: #selector(zoomOut(_:))),
            Shortcut(menu: "View", title: "Bigger Terminal Text", key: "=", modifiers: [.command, .option], action: #selector(terminalZoomIn(_:))),
            Shortcut(menu: "View", title: "Smaller Terminal Text", key: "-", modifiers: [.command, .option], action: #selector(terminalZoomOut(_:))),
            Shortcut(menu: "View", title: "Actual Terminal Text Size", key: "0", modifiers: [.command, .option], action: #selector(terminalActualSize(_:))),
            Shortcut(menu: "View", title: "Toggle Sidebar", key: "/", action: #selector(showOrHideSidebar(_:))),
            Shortcut(menu: "View", title: "Toggle Sidebar", key: "s", modifiers: [.command, .control], action: #selector(showOrHideSidebar(_:)),
                     hiddenInMenu: true, listed: false),
            Shortcut(menu: "View", title: "Move Focus to Sidebar", key: "s", modifiers: [.command, .option], action: #selector(focusSidebar(_:))),

            Shortcut(menu: "Workspace", title: "New Workspace", key: "n", action: #selector(newWorkspace(_:))),
            Shortcut(menu: "Workspace", title: "Close Workspace", key: "w", modifiers: [.command, .shift], action: #selector(closeActiveWorkspace(_:))),
            Shortcut(menu: "Workspace", title: "Rename Workspace", key: "r", modifiers: [.command, .shift], action: #selector(renameActiveWorkspace(_:))),
            Shortcut(menu: "Workspace", title: "Previous Workspace", key: Shortcut.arrows[2].key, modifiers: [.command, .shift], action: #selector(previousWorkspace(_:))),
            Shortcut(menu: "Workspace", title: "Next Workspace", key: Shortcut.arrows[3].key, modifiers: [.command, .shift], action: #selector(nextWorkspace(_:))),

            Shortcut(menu: "Tab", title: "New Tab", key: "t", action: #selector(newTab(_:))),
            Shortcut(menu: "Tab", title: "Close Tab", key: "w", modifiers: [.command, .option], action: #selector(closeActiveTab(_:))),
            Shortcut(menu: "Tab", title: "Rename Tab", key: "r", action: #selector(renameTab(_:))),
            Shortcut(menu: "Tab", title: "Previous Tab", key: "[", modifiers: [.command, .shift], action: #selector(previousTab(_:))),
            Shortcut(menu: "Tab", title: "Next Tab", key: "]", modifiers: [.command, .shift], action: #selector(nextTab(_:))),
        ]
        for n in 1...9 {
            list.append(Shortcut(menu: "Tab", title: "Tab \(n)", key: "\(n)", action: #selector(goToTab(_:)), tag: n,
                                 listed: n == 1, listTitle: "Go to Tab 1–9", listKeys: "⌘1 … ⌘9"))
        }

        list += [
            Shortcut(menu: "Pane", title: "Split Right", key: "d", action: #selector(splitPane(_:)), tag: 1),
            Shortcut(menu: "Pane", title: "Split Down", key: "d", modifiers: [.command, .shift], action: #selector(splitPane(_:)), tag: 3),
            Shortcut(menu: "Pane", title: "Split Left", key: "d", modifiers: [.command, .option], action: #selector(splitPane(_:)), tag: 0),
            Shortcut(menu: "Pane", title: "Split Up", key: "d", modifiers: [.command, .option, .shift], action: #selector(splitPane(_:)), tag: 2),
            Shortcut(menu: "Pane", title: "Close Pane", key: "w", action: #selector(closePane(_:))),
            Shortcut(menu: "Pane", title: "Maximize Pane", key: "\r", modifiers: [.command, .shift], action: #selector(maximizePane(_:))),
        ]
        // Tags index into Shortcut.arrows: left, right, up, down.
        for (i, arrow) in Shortcut.arrows.enumerated() {
            list.append(Shortcut(menu: "Pane", title: "Switch Pane \(arrow.name)", key: arrow.key, modifiers: [.command, .option],
                                 action: #selector(focusPane(_:)), tag: i,
                                 listed: i == 0, listTitle: "Switch Pane", listKeys: "⌥⌘ ← → ↑ ↓"))
        }
        for (i, arrow) in Shortcut.arrows.enumerated() {
            list.append(Shortcut(menu: "Pane", title: "Resize Pane \(arrow.name)", key: arrow.key, modifiers: [.command, .control],
                                 action: #selector(resizePane(_:)), tag: i,
                                 listed: i == 0, listTitle: "Resize Pane", listKeys: "⌃⌘ ← → ↑ ↓"))
        }

        list += [
            Shortcut(menu: "Window", title: "Minimize", key: "m", action: #selector(minimizeWindow(_:))),
            Shortcut(menu: "Window", title: "Zoom", key: "", action: #selector(zoomWindow(_:)), listed: false),
            Shortcut(menu: "Window", title: "Toggle Full Screen", key: "f", modifiers: [.command, .control], action: #selector(toggleFullScreen(_:))),
            Shortcut(menu: "Window", title: "Quick Open…", key: "p", action: #selector(showQuickOpen(_:))),
            Shortcut(menu: "Window", title: "File Browser", key: "o", modifiers: [.command, .shift], action: #selector(showFileBrowser(_:))),

            Shortcut(menu: "Help", title: "Welcome to Clotho", key: "", action: #selector(showOnboarding(_:)), listed: false),
            // ⇧⌘/ (⌘?) is macOS's own Show Help Menu.
            Shortcut(menu: "Help", title: "Keyboard Shortcuts", key: "/", modifiers: [.command, .option], action: #selector(showShortcuts(_:))),
        ]
        return list
    }()

    static let menuOrder = ["Clotho", "File", "Edit", "View", "Workspace", "Tab", "Pane", "Window", "Help"]

    func buildMenu() {
        let main = Self.makeMainMenu()
        if let window = main.items.first(where: { $0.submenu?.title == "Window" })?.submenu { NSApp.windowsMenu = window }
        if let help = main.items.first(where: { $0.submenu?.title == "Help" })?.submenu { NSApp.helpMenu = help }
        NSApp.mainMenu = main
    }

    /// The menu bar, from `shortcuts`; actions go to the responder chain.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        for name in Self.menuOrder {
            let item = NSMenuItem()
            let menu = NSMenu(title: name)
            var lastGroup: String?
            for shortcut in Self.shortcuts where shortcut.menu == name {
                // Separate split/close, switch and resize rows within the Pane menu.
                let group = shortcut.title.components(separatedBy: " ").first
                if name == "Pane", let lastGroup, lastGroup != group, ["Close", "Switch", "Resize", "Maximize"].contains(group ?? "") {
                    menu.addItem(.separator())
                }
                lastGroup = group
                if name == "Window", shortcut.title == "Quick Open…" { menu.addItem(.separator()) }
                let (key, mods) = shortcut.menuKey
                let menuItem = menu.addItem(withTitle: shortcut.title, action: shortcut.action, keyEquivalent: key)
                menuItem.keyEquivalentModifierMask = mods
                menuItem.tag = shortcut.tag
                if shortcut.hiddenInMenu {
                    menuItem.isHidden = true
                    menuItem.allowsKeyEquivalentWhenHidden = true
                }
            }
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    // Shows the shortcuts card over the terminal, inside this window; ⌥⌘/ again, Esc or a click outside hides it.
    @objc func showShortcuts(_ sender: Any?) {
        if let shortcutsOverlay {
            shortcutsOverlay.dismiss()
            return
        }
        let overlay = ShortcutsOverlay(shortcuts: Self.shortcuts)
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            shortcutsOverlay = nil
            window.makeFirstResponder(activeTerminal)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        shortcutsOverlay = overlay
        window.makeFirstResponder(overlay)
    }

    // MARK: Actions. Each one is a backend call on the focused workspace, tab or pane; the result comes
    // back as a model change, which redraws the window.

    var focusedPaneID: PaneID? { store.focusedPane?.id }

    // On the focused machine.
    /// New Workspace makes one and starts renaming it in the sidebar, with the default name selected
    /// (Return keeps what's typed, Esc the default), then the terminal takes the keyboard. Every way of
    /// making a workspace comes here. A hidden sidebar is shown for the rename.
    @objc func newWorkspace(_ sender: Any?) {
        let name = "Workspace \(store.state.workspaces.count + 1)"
        let options = spawnOptions()
        let machine = focusedMachine
        sidebar.expand(machine)
        if sidebarWidth.constant == 0 { showOrHideSidebar(nil) }
        run { [weak self] backend in
            let created = try await backend.createWorkspace(name: name, spawn: options)
            self?.sidebar.renameWhenListed(machine, created.workspace)
        }
    }

    func newWorkspace(on key: MachineKey) {
        focus(machine: key)
        newWorkspace(nil)
    }

    // Closing a workspace stops every agent in it, so it asks first.
    @objc func closeActiveWorkspace(_ sender: Any?) {
        guard let workspace = store.focusedWorkspace else { return }
        closeWorkspace(workspace.id)
    }

    // Asks before closing. Return confirms, Esc cancels; tabs and panes offer "Don't ask again",
    // which is remembered in the SkipCloseConfirm.<kind> default.
    func confirmClose(_ kind: String, info: String, allowSkipping: Bool = true, then close: @escaping () -> Void) {
        let skipKey = "SkipCloseConfirm.\(kind)"
        if allowSkipping, UserDefaults.standard.bool(forKey: skipKey) { return close() }
        // A repeated shortcut while the prompt is up shouldn't stack another one.
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Close the active \(kind.lowercased())?"
        alert.informativeText = info
        alert.addButton(withTitle: "Close \(kind)")
        alert.addButton(withTitle: "Cancel")
        if allowSkipping {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again for \(kind.lowercased())s"
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipKey) }
            close()
        }
    }

    // Workspaces cycle in sidebar order across every connected machine, wrapping around.
    @objc func previousWorkspace(_ sender: Any?) { stepWorkspace(by: -1) }
    @objc func nextWorkspace(_ sender: Any?) { stepWorkspace(by: 1) }

    func stepWorkspace(by step: Int) {
        let all = sidebarGroups().flatMap { group in group.workspaces.map { (machine: group.key, workspace: $0.id) } }
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.machine == focusedMachine && $0.workspace == store.focusedWorkspace?.id } ?? 0
        let target = all[(index + step + all.count) % all.count]
        focusNow(.workspace(target.workspace), on: target.machine, trace: "step workspace")
    }

    // A new tab opens in the focused pane's folder.
    @objc func newTab(_ sender: Any?) {
        guard let workspace = store.focusedWorkspace else { return newWorkspace(sender) }
        let options = spawnOptions(cwd: store.focusedPane?.cwd)
        run { _ = try await $0.createTab(in: workspace.id, spawn: options) }
    }

    /// The sidebar's + on a workspace row: that workspace comes forward, and a new tab opens in it (in
    /// its focused pane's folder), as ⌘T would there.
    func newTab(in workspace: WorkspaceID, on key: MachineKey) {
        guard let store = connections[key]?.store, store.state.workspaces.contains(where: { $0.id == workspace }) else { return }
        focusNow(.workspace(workspace), on: key, trace: "new tab button")
        let shown = store.state.focusing(.workspace(workspace))
        let cwd = shown.flatMap { $0.pane($0.focus.pane)?.cwd }
        let options = spawnOptions(cwd: cwd)
        let backend = store.backend
        Task { @MainActor in
            do {
                _ = try await backend.createTab(in: workspace, spawn: options)
            } catch {
                log("new tab in workspace \(workspace) on \(key) failed: \(error)")
            }
        }
    }

    @objc func closeActiveTab(_ sender: Any?) {
        guard let tab = store.focusedTab else { return }
        closeTab(tab.id)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let tab = store.focusedTab else { return }
        renameTab(withID: tab.id)
    }

    @objc func renameActiveWorkspace(_ sender: Any?) {
        guard let workspace = store.focusedWorkspace else { return }
        renameWorkspace(workspace.id)
    }

    @objc func previousTab(_ sender: Any?) { stepTab(by: -1) }
    @objc func nextTab(_ sender: Any?) { stepTab(by: 1) }

    func stepTab(by step: Int) {
        guard let tabs = store.focusedWorkspace?.tabs, !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == store.focusedTab?.id } ?? 0
        let target = tabs[(index + step + tabs.count) % tabs.count].id
        focusNow(.tab(target), on: focusedMachine, trace: "step tab")
    }

    @objc func goToTab(_ sender: Any?) {
        let n = (sender as? NSMenuItem)?.tag ?? 1
        guard let tabs = store.focusedWorkspace?.tabs, n <= tabs.count else { return }
        let target = tabs[n - 1].id
        focusNow(.tab(target), on: focusedMachine, trace: "tab \(n)")
    }

    // Menu tags index into Shortcut.arrows (left, right, up, down).
    static let directions: [Direction] = [.left, .right, .up, .down]

    @objc func splitPane(_ sender: Any?) {
        guard let pane = store.focusedPane else { return }
        split(pane, Self.directions[(sender as? NSMenuItem)?.tag ?? 1])
    }

    /// Splits a pane of the focused tab; the new pane opens in its folder.
    func split(_ pane: Pane, _ direction: Direction) {
        // The new pane gets half of the current one.
        var size = splitView.paneFrames[pane.id]?.size ?? splitView.bounds.size
        if direction.axis == .horizontal { size.width /= 2 } else { size.height /= 2 }
        let options = spawnOptions(cwd: pane.cwd, size: size)
        if let tab = store.focusedTab { maximized[tabKey(tab.id)] = nil }
        run { _ = try await $0.split(pane.id, direction: direction, ratio: nil, spawn: options) }
    }

    // ⌘W hides the shortcuts card or file browser when one is showing; otherwise it closes the focused
    // pane (and its tab, if it was the last pane).
    @objc func closePane(_ sender: Any?) {
        if let shortcutsOverlay {
            shortcutsOverlay.dismiss()
            return
        }
        if let fileBrowser {
            fileBrowser.dismiss()
            return
        }
        guard let pane = focusedPaneID else { return }
        close(pane: pane)
    }

    func close(pane: PaneID) {
        confirmClose("Pane", info: "This stops anything running in it. Closing a tab's last pane closes the tab.") { [weak self] in
            self?.run { try await $0.closePane(pane) }
        }
    }

    // The neighbor is found from the panes' frames on screen.
    @objc func focusPane(_ sender: Any?) {
        guard let pane = focusedPaneID, store.focusedTab.flatMap({ maximized[tabKey($0.id)] }) == nil else { return }
        let direction = Self.directions[(sender as? NSMenuItem)?.tag ?? 0]
        guard let target = Layout.neighbor(of: pane, toward: direction, in: splitView.paneFrames) else { return }
        focusNow(.pane(target), on: focusedMachine, trace: "switch pane")
    }

    // Moves the nearest divider on that axis toward the arrow.
    @objc func resizePane(_ sender: Any?) {
        guard let pane = focusedPaneID, let tab = store.focusedTab else { return }
        let direction = Self.directions[(sender as? NSMenuItem)?.tag ?? 0]
        guard let split = tab.layout.nearestSplit(of: pane, axis: direction.axis) else { return }
        let step = direction.newPaneIsSecond ? 0.05 : -0.05
        let ratio = min(max(split.ratio + step, Layout.ratioRange.lowerBound), Layout.ratioRange.upperBound)
        run { try await $0.setRatio(split.id, ratio: ratio) }
    }

    @objc func maximizePane(_ sender: Any?) {
        guard let pane = focusedPaneID else { return }
        toggleMaximize(pane)
    }

    func toggleMaximize(_ pane: PaneID) {
        guard let tab = store.focusedTab, tab.layout.panes.count > 1 else { return }
        maximized[tabKey(tab.id)] = maximized[tabKey(tab.id)] == nil ? pane : nil
        sync()
    }

    // ⌘K sends Ctrl+L to the focused pane; shells treat it as clear-screen.
    @objc func clearActivePane(_ sender: Any?) {
        guard let pane = focusedPaneID else { return }
        backend.sendInput(pane, Data([0x0c]))
    }
}

// A Warp-style card listing every shortcut in two columns, drawn over the terminal on a dimmed backdrop.
final class ShortcutsOverlay: NSView {
    static let columns = [["Workspace", "Tab", "Pane"], ["Clotho", "File", "Edit", "View", "Window", "Help"]]
    static let columnWidth: CGFloat = 300
    var onDismiss: (() -> Void)?
    let card = NSView()

    init(shortcuts: [Shortcut]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.backdrop.cgColor

        let heading = Self.label("Keyboard Shortcuts", size: 17, weight: .semibold, color: Theme.foreground)
        let hint = Self.label("⌥⌘/ or Esc to close", size: 12, weight: .regular, color: Theme.dimText)
        let top = NSStackView(views: [heading, NSView(), hint])
        top.orientation = .horizontal
        top.alignment = .firstBaseline

        let columns = NSStackView(views: Self.columns.map { Self.column($0, shortcuts: shortcuts) })
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = s(40)

        let stack = NSStackView(views: [top, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = s(18)
        stack.edgeInsets = NSEdgeInsets(top: s(24), left: s(28), bottom: s(24), right: s(28))
        top.widthAnchor.constraint(equalTo: columns.widthAnchor).isActive = true

        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.background.cgColor
        card.layer?.cornerRadius = s(12)
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.divider.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 24
        card.layer?.shadowOffset = CGSize(width: 0, height: s(-8))
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func dismiss() {
        removeFromSuperview()
        onDismiss?()
    }

    override var acceptsFirstResponder: Bool { true }
    // Esc closes it; other typing is swallowed so it doesn't reach the pane behind.
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() }
    }

    // Clicks on the backdrop close it; clicks on the card are ignored, and nothing reaches the terminal.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    static func column(_ menus: [String], shortcuts: [Shortcut]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = s(2)
        for menu in menus {
            let rows = shortcuts.filter { $0.menu == menu && $0.listed }
            guard !rows.isEmpty else { continue }
            let header = label((menu == "Clotho" ? "App" : menu).uppercased(), size: 11, weight: .semibold, color: Theme.accent)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(s(6), after: header)
            for shortcut in rows {
                let row = Self.row(title: shortcut.listTitle ?? shortcut.title, keys: shortcut.displayKeys)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(s(18), after: last) }
        }
        return stack
    }

    static func row(title: String, keys: String) -> NSView {
        let name = label(title, size: 13, weight: .regular, color: Theme.foreground)
        let key = label(keys, size: 12, weight: .medium, color: Theme.foreground)
        key.font = NSFont.monospacedSystemFont(ofSize: s(12), weight: .medium)
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = Theme.pill.cgColor
        cap.layer?.cornerRadius = s(5)
        cap.addSubview(key)
        key.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: s(7)),
            key.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: s(-7)),
            key.topAnchor.constraint(equalTo: cap.topAnchor, constant: s(2)),
            key.bottomAnchor.constraint(equalTo: cap.bottomAnchor, constant: s(-2)),
        ])
        let row = NSStackView(views: [name, NSView(), cap])
        row.orientation = .horizontal
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: s(3), left: s(0), bottom: s(3), right: s(0))
        name.setContentHuggingPriority(.required, for: .horizontal)
        cap.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
}
