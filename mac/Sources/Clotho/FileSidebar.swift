import AppKit
import ClothoKit

// The file sidebar on the window's right (View ▸ Show/Hide File Sidebar, ⌥⌘B, or the sidebar.right
// button at the far right of the title row). It lists the focused pane's folder on the pane's
// machine and follows the pane as it moves (a `cd`, another pane, another machine) until the user
// browses somewhere else; then "Follow Pane" brings it back.
//
// Double-clicking a file on another machine opens a copy of it here in its default app and uploads
// each save back (RemoteEdits in ClothoKit); a file on this Mac opens in place. Each opened row shows
// its copy's state (open, syncing, synced, conflict, failed).
//
// It slides out and in like the left sidebar and keeps its width while hidden, so it's never laid
// out at width 0 (1.0.13's crash). Its left edge drags to resize, and the width is remembered.

final class FileSidebarView: NSView {
    let pane: FilePane
    let title = NSTextField(labelWithString: "")
    let followButton = NSButton()
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    /// Lists the focused pane's folder as it changes; off once the user browses away.
    private(set) var following = true
    /// The focused pane's machine and folder, as last told.
    private(set) var target: (machine: Machine, folder: String)?

    /// The band at the top, as tall as the tab bar; the toggle sits at its right end.
    static var bandHeight: CGFloat { TabBarView.height }

    init(app: AppDelegate) {
        pane = FilePane(app: app, machine: .local, path: "~", choosable: false, side: "sidebar", compact: true)
        super.init(frame: .zero)
        wantsLayer = true
        withAppearance { layer?.backgroundColor = Theme.sidebar.cgColor }
        setAccessibilityIdentifier("FileSidebar")
        setAccessibilityLabel("Files")

        title.font = NSFont.systemFont(ofSize: s(12), weight: .semibold)
        title.textColor = Theme.secondaryText
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        followButton.title = "↩ Follow Pane"
        followButton.bezelStyle = .inline
        followButton.controlSize = .small
        followButton.font = NSFont.systemFont(ofSize: s(11), weight: .medium)
        followButton.toolTip = "Go back to the focused pane's folder, and follow it again"
        followButton.target = self
        followButton.action = #selector(followAgain)
        followButton.isHidden = true

        pane.onUserNavigate = { [weak self] in self?.stopFollowing() }
        pane.onLoaded = { [weak self] _ in self?.updateFollowButton() }

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Theme.divider
        let handle = ResizeHandle()
        // The pointer's distance past the left edge is how much narrower (or, negative, wider) it gets.
        handle.onDrag = { [weak self] x in
            guard let self else { return }
            onResize?(bounds.width - x)
        }
        handle.onEnd = { [weak self] in self?.onResizeEnd?() }
        for view in [title, followButton, pane, divider, handle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: s(12)),
            title.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.bandHeight / 2),
            followButton.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: s(8)),
            followButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            // Clear of the toggle at the band's right end.
            followButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -AppDelegate.fileToggleInset),
            pane.topAnchor.constraint(equalTo: topAnchor, constant: Self.bandHeight),
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance { layer?.backgroundColor = Theme.sidebar.cgColor }
    }

    /// The focused pane is on `machine`, in `folder` (nil: no pane, or its folder isn't known yet).
    func follow(machine: Machine, folder: String?) {
        let new = folder.map { (machine, $0) }
        let changed = new?.0 != target?.machine || new?.1 != target?.folder
        target = new
        title.stringValue = machine.isLocal ? ComputerName.current : machine.label
        if following, changed, let new { pane.show(machine: new.0, folder: new.1) }
        updateFollowButton()
    }

    /// Lists the pane's folder again even if it didn't change (the sidebar was just shown).
    func refollow() {
        guard following, let target else { return }
        pane.show(machine: target.machine, folder: target.folder)
    }

    @objc func followAgain() {
        following = true
        refollow()
        updateFollowButton()
    }

    private func stopFollowing() {
        following = false
        updateFollowButton()
    }

    private func updateFollowButton() {
        guard let target else { return followButton.isHidden = true }
        followButton.isHidden = following || (target.machine == pane.machine && target.folder == pane.path)
    }
}

// MARK: The sidebar in the window

extension AppDelegate {
    static let fileSidebarWidthRange: ClosedRange<CGFloat> = 220...720
    static var fileSidebarDefaultWidth: CGFloat { s(300) }
    static let showFileSidebarKey = "ShowFileSidebar"
    /// Room the toggle takes at the title row's right end: the tab bar stops before it.
    static var fileToggleInset: CGFloat { sidebarToggleSize + s(16) }

    var savedFileSidebarWidth: CGFloat {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "FileSidebarWidth"))
        return saved > 0 ? Self.clampFileSidebar(saved) : Self.fileSidebarDefaultWidth
    }

    static func clampFileSidebar(_ width: CGFloat) -> CGFloat {
        min(max(width.rounded(), fileSidebarWidthRange.lowerBound), fileSidebarWidthRange.upperBound)
    }

    var isFileSidebarShown: Bool { fileSidebarTrailing.constant == 0 }

    /// Adds the file sidebar and its toggle to the window, and returns their constraints, the tab bar's
    /// and the terminal area's trailing edges among them.
    func makeFileSidebar(corner: NSView) -> [NSLayoutConstraint] {
        let files = FileSidebarView(app: self)
        files.translatesAutoresizingMaskIntoConstraints = false
        files.pane.onOpenFile = { [weak self] location, entry in self?.openFile(location, size: entry.size) }
        files.pane.badge = { [weak self] location in self?.fileBadge(location) }
        files.pane.fillMenu = { [weak self] menu, locations in self?.fillFileMenu(menu, locations) }
        files.pane.onRename = { [weak self] location, name in self?.renameFile(location, to: name) }
        container.addSubview(files)
        fileSidebar = files

        let shown = UserDefaults.standard.bool(forKey: Self.showFileSidebarKey)
        let width = savedFileSidebarWidth
        fileSidebarWidth = files.widthAnchor.constraint(equalToConstant: width)
        // Slid out past the window's right edge, at its full width.
        fileSidebarTrailing = files.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: shown ? 0 : width)
        files.isHidden = !shown
        files.onResize = { [weak self] width in self?.fileSidebarWidth.constant = Self.clampFileSidebar(width) }
        files.onResizeEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(fileSidebarWidth.constant), forKey: "FileSidebarWidth")
        }

        let toggle = QuietButton(symbol: "sidebar.right", label: "Show/Hide File Sidebar", pointSize: s(13)) { [weak self] in
            self?.showOrHideFileSidebar(self?.fileSidebarToggle)
        }
        toggle.toolTip = "Show/Hide File Sidebar (⌥⌘B)"
        toggle.setAccessibilityLabel("Show/Hide File Sidebar")
        toggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggle)
        fileSidebarToggle = toggle

        tabBarTrailing = tabBar.trailingAnchor.constraint(equalTo: files.leadingAnchor, constant: shown ? 0 : -Self.fileToggleInset)
        return [
            files.topAnchor.constraint(equalTo: sidebar.topAnchor),
            files.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fileSidebarWidth,
            fileSidebarTrailing,
            tabBarTrailing,
            splitView.trailingAnchor.constraint(equalTo: files.leadingAnchor),
            toggle.widthAnchor.constraint(equalToConstant: Self.sidebarToggleSize),
            toggle.heightAnchor.constraint(equalToConstant: Self.sidebarToggleSize),
            toggle.centerYAnchor.constraint(equalTo: corner.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -s(8)),
        ]
    }

    /// View ▸ Show/Hide File Sidebar (⌥⌘B): slides it in or out, and remembers which.
    @objc func showOrHideFileSidebar(_ sender: Any?) {
        let show = !isFileSidebarShown
        log("file sidebar: \(show ? "show" : "hide") (\(Self.describeTrigger(sender)))")
        UserDefaults.standard.set(show, forKey: Self.showFileSidebarKey)
        let animate = sender != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if show {
            fileSidebar.isHidden = false
            followFocusedPaneInFileSidebar()
            fileSidebar.refollow()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animate ? 0.18 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = animate
            (animate ? fileSidebarTrailing.animator() : fileSidebarTrailing).constant = show ? 0 : fileSidebarWidth.constant
            (animate ? tabBarTrailing.animator() : tabBarTrailing).constant = show ? 0 : -Self.fileToggleInset
            if animate { window.contentView?.layoutSubtreeIfNeeded() }
        }, completionHandler: { [weak self] in
            guard let self, !isFileSidebarShown else { return }
            fileSidebar.isHidden = true
        })
        if !animate, !show { fileSidebar.isHidden = true }
    }

    /// Tells the sidebar where the focused pane is (every sync; cheap when nothing moved).
    func followFocusedPaneInFileSidebar() {
        guard let fileSidebar, isFileSidebarShown else { return }
        fileSidebar.follow(machine: focusedConnection.machine, folder: store.focusedPane?.cwd)
    }
}

// MARK: Opening files

extension AppDelegate {
    /// Above this, opening asks first: the whole file comes down.
    static let largeFileBytes: UInt64 = 200 * 1_000_000

    var remoteEdits: RemoteEdits {
        if let existing = remoteEditsStore { return existing }
        let edits = RemoteEdits(root: Self.openFilesRoot)
        edits.backendFor = { [weak self] key in
            guard let self, let machine = Machine.all().first(where: { $0.key == key }) else { return nil }
            return try? fileBackend(for: machine)
        }
        edits.onChange = { [weak self] _, edit in self?.remoteEditChanged(edit) }
        remoteEditsStore = edits
        return edits
    }

    /// ~/Library/Caches/<bundle id>/open: per machine, per file. Tests get their own temp folder.
    static var openFilesRoot: URL {
        // Test runs of the app (OpenFilesRoot=/tmp/cmac-open) keep their copies apart.
        if let custom = UserDefaults.standard.string(forKey: "OpenFilesRoot") { return URL(fileURLWithPath: custom) }
        if Bundle.main.bundleURL.pathExtension != "app" {
            return FileManager.default.temporaryDirectory.appendingPathComponent("clotho-tests-open-\(getpid())")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.clotho.desktop").appendingPathComponent("open")
    }

    /// At launch: copies the machines have every change of go; the others keep syncing. Then every
    /// ten minutes, copies idle for an hour that no app holds open go too.
    func startOpenFileCleanup() {
        let edits = remoteEdits
        let removed = edits.cleanUp(idle: 0, inUse: Self.isOpenByAnyProcess)
        if !removed.isEmpty { log("open files: removed \(removed.count) synced copies") }
        for id in edits.edits.keys { edits.watch(id) }
        openFileCleanupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.remoteEdits.cleanUp(idle: 3600, inUse: Self.isOpenByAnyProcess) }
        }
    }

    /// Whether any process has the file open (many editors don't keep it open; the idle time covers them).
    nonisolated static func isOpenByAnyProcess(_ url: URL) -> Bool {
        var pids = [Int32](repeating: 0, count: 64)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return bytes > 0
    }

    /// Opens a file from the sidebar: in place on this Mac; from another machine, through a copy
    /// whose saves go back. `app` is Open With's choice.
    func openFile(_ location: Location, size: UInt64?, with app: URL? = nil) {
        if location.machine.isLocal {
            return launch(URL(fileURLWithPath: location.path), with: app)
        }
        if let size, size > Self.largeFileBytes {
            let alert = NSAlert()
            alert.messageText = "Open “\(location.name)”?"
            alert.informativeText = "It's \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)). "
                + "Clotho downloads all of it from \(location.machine.label) first."
            alert.addButton(withTitle: "Download and Open")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.downloadAndOpen(location, with: app)
            }
            return
        }
        downloadAndOpen(location, with: app)
    }

    private func downloadAndOpen(_ location: Location, with app: URL?) {
        let key = "\(location.machine.key)\n\(location.path)"
        openingFiles.insert(key)
        fileSidebar?.pane.refreshRows()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                openingFiles.remove(key)
                fileSidebar?.pane.refreshRows()
            }
            do {
                let files = try fileBackend(for: location.machine)
                let edit = try await remoteEdits.open(machine: location.machine.key, machineName: location.machine.label,
                                                      path: location.path, backend: files)
                log("open files: \(location.machine.key):\(location.path) → \(edit.localPath)")
                launch(edit.localURL, with: app)
            } catch {
                showNotice("Couldn't open “\(location.name)” from \(location.machine.label)", detail: error.localizedDescription,
                           action: nil, then: nil)
            }
        }
    }

    private func launch(_ url: URL, with app: URL?) {
        // Tests (OpenFilesInApps=NO) stop here, so nothing opens on the machine running them.
        if UserDefaults.standard.object(forKey: "OpenFilesInApps") != nil, !UserDefaults.standard.bool(forKey: "OpenFilesInApps") {
            return log("open files: would open \(url.path)")
        }
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The row's badge: what its copy is doing.
    func fileBadge(_ location: Location) -> (String, NSColor)? {
        if openingFiles.contains("\(location.machine.key)\n\(location.path)") { return ("opening", Theme.dimText) }
        guard !location.machine.isLocal, let edit = remoteEditsStore?.edit(machine: location.machine.key, path: location.path) else { return nil }
        switch edit.state {
        case .open: return ("open", Theme.dimText)
        case .syncing: return ("syncing", Theme.accent)
        case .synced: return ("synced", Theme.success)
        case .conflict: return ("conflict", Theme.warning)
        case .failed: return ("not saved", Theme.danger)
        }
    }

    private func remoteEditChanged(_ edit: RemoteEdit?) {
        fileSidebar?.pane.refreshRows()
        guard let edit else { return }
        switch edit.state {
        case .conflict where !shownConflicts.contains(edit.id):
            shownConflicts.insert(edit.id)
            askAboutConflict(edit.id)
        case .failed:
            showNotice("Couldn't save “\(edit.name)” to \(edit.machineName)", detail: edit.failure, action: "Try Again") { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.remoteEdits.sync(edit.id) }
            }
        case .synced, .open:
            shownConflicts.remove(edit.id)
        default: break
        }
    }

    /// "Changed on devbox since you opened it": Overwrite, Save a Copy Beside, or Discard My Changes.
    func askAboutConflict(_ id: String) {
        guard let edit = remoteEdits.edits[id], edit.state == .conflict else { return }
        if window.attachedSheet != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.askAboutConflict(id) }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = edit.conflictRemote == nil
            ? "“\(edit.name)” was deleted on \(edit.machineName) since you opened it"
            : "“\(edit.name)” changed on \(edit.machineName) since you opened it"
        let copy = RemoteEdits.copyName(for: edit.name, taken: [])
        alert.informativeText = "Your save isn't on \(edit.machineName) yet. Overwrite replaces their version with yours. "
            + "Save a Copy Beside keeps theirs and puts yours in “\(copy)”. Discard My Changes replaces your copy with theirs."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Save a Copy Beside")
        alert.addButton(withTitle: "Discard My Changes")
        alert.buttons[2].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let choice: RemoteEdits.Resolution = switch response {
            case .alertFirstButtonReturn: .overwrite
            case .alertSecondButtonReturn: .saveCopyBeside
            default: .discard
            }
            log("open files: \(edit.name) conflict → \(choice)")
            Task { @MainActor in
                do {
                    try await self.remoteEdits.resolve(id, choice)
                    self.fileSidebar?.pane.reload()
                } catch {
                    self.showNotice("Couldn't save “\(edit.name)” to \(edit.machineName)", detail: error.localizedDescription, action: nil, then: nil)
                }
            }
        }
    }
}

// MARK: The context menu

extension AppDelegate {
    func fillFileMenu(_ menu: NSMenu, _ locations: [Location]) {
        guard let pane = fileSidebar?.pane, let first = locations.first else { return }
        let entry = pane.entry(for: first)
        let single = locations.count == 1
        let isFile = entry.map { !$0.isDirectory } ?? true
        let machine = first.machine

        menu.addItem(ClosureMenuItem(title: "Open") { [weak self, weak pane] in
            for location in locations {
                if let entry = pane?.entry(for: location), entry.isDirectory {
                    pane?.onUserNavigate?()
                    pane?.load(location.path)
                    return
                }
                self?.openFile(location, size: pane?.entry(for: location)?.size)
            }
        })
        if single, isFile {
            menu.addItem(ClosureMenuItem(title: "Open With…") { [weak self] in self?.chooseAppToOpen(first, size: entry?.size) })
        }
        menu.addItem(.separator())
        if machine.isLocal {
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(locations.map { URL(fileURLWithPath: $0.path) })
            })
        } else {
            let copies = locations.compactMap { remoteEditsStore?.edit(machine: machine.key, path: $0.path)?.localURL }
            let reveal = ClosureMenuItem(title: "Reveal Local Copy") { NSWorkspace.shared.activateFileViewerSelecting(copies) }
            reveal.isEnabled = !copies.isEmpty
            menu.addItem(reveal)
        }
        menu.addItem(ClosureMenuItem(title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(locations.map(\.path).joined(separator: "\n"), forType: .string)
        })
        if !machine.isLocal {
            menu.addItem(ClosureMenuItem(title: "Download To…") { [weak self] in self?.chooseDownloadFolder(locations) })
        }
        let others = Machine.enabled().filter { $0 != machine }
        if !others.isEmpty {
            let copyTo = NSMenuItem(title: "Copy to Machine", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for other in others {
                // Into that machine's focused pane's folder, else its home.
                let folder = connections[other.key]?.store.focusedPane?.cwd ?? "~"
                let label = other.isLocal ? ComputerName.current : other.label
                submenu.addItem(ClosureMenuItem(title: "\(label): \((folder as NSString).lastPathComponent)") { [weak self] in
                    self?.copy(locations, to: Location(machine: other, path: folder), then: nil)
                })
            }
            copyTo.submenu = submenu
            menu.addItem(copyTo)
        }
        menu.addItem(.separator())
        if single {
            menu.addItem(ClosureMenuItem(title: "Rename") { [weak pane] in
                guard let pane, let row = pane.shownNames.firstIndex(of: first.name) else { return }
                pane.beginRename(row: row)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Delete…") { [weak self] in self?.confirmDelete(locations) })
    }

    private func chooseAppToOpen(_ location: Location, size: UInt64?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open “\(location.name)” with."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            self?.openFile(location, size: size, with: app)
        }
    }

    private func chooseDownloadFolder(_ locations: [Location]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Download"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.copy(locations, to: Location(machine: .local, path: folder.path), then: nil)
        }
    }

    func renameFile(_ location: Location, to name: String) {
        let folder = (location.path as NSString).deletingLastPathComponent
        let target = filePath(folder.isEmpty ? "/" : folder, name)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let files = try fileBackend(for: location.machine)
                _ = try await files.rename(location.path, to: target, overwrite: false)
                remoteEditsStore?.moved(machine: location.machine.key, from: location.path, to: target)
            } catch {
                showNotice("Couldn't rename “\(location.name)”", detail: error.localizedDescription, action: nil, then: nil)
            }
            fileSidebar?.pane.reload()
        }
    }

    private func confirmDelete(_ locations: [Location]) {
        guard let first = locations.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let place = first.machine.isLocal ? ComputerName.current : first.machine.label
        alert.messageText = locations.count == 1 ? "Delete “\(first.name)” on \(place)?" : "Delete \(locations.count) items on \(place)?"
        alert.informativeText = "This can't be undone. Folders are deleted with everything in them."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                do {
                    let files = try self.fileBackend(for: first.machine)
                    for location in locations {
                        let isFolder = self.fileSidebar?.pane.entry(for: location)?.isDirectory ?? false
                        try await files.remove(location.path, recursive: isFolder)
                    }
                } catch {
                    self.showNotice("Couldn't delete “\(first.name)”", detail: error.localizedDescription, action: nil, then: nil)
                }
                self.fileSidebar?.pane.reload()
            }
        }
    }
}
