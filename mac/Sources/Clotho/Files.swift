import AppKit
import ClothoKit
import SystemConfiguration
import UniformTypeIdentifiers

// MARK: Machines

// Local, or a saved SSH host whose clothod the app reaches with `clothod bridge` over ssh. The saved
// hosts live in the "Machines" default as [{id, label, target}].
struct Machine: Equatable {
    let id: String?
    let label: String
    let target: String?

    var isLocal: Bool { target == nil }
    /// This Mac, named by its Computer Name.
    static var local: Machine { Machine(id: nil, label: ComputerName.current, target: nil) }

    /// The same machine, even if its name changed since.
    static func == (a: Machine, b: Machine) -> Bool { a.id == b.id && a.target == b.target }

    static func all() -> [Machine] {
        let saved = UserDefaults.standard.array(forKey: "Machines") as? [[String: String]] ?? []
        return [.local] + saved.compactMap { entry in
            guard let id = entry["id"], let target = entry["target"] else { return nil }
            return Machine(id: id, label: entry["label"] ?? target, target: target)
        }
    }

    /// Saves a new SSH host; `target` is anything ssh accepts (user@host, an alias, a Tailscale name).
    static func add(label: String, target: String) -> Machine {
        let machine = Machine(id: UUID().uuidString, label: label.isEmpty ? target : label, target: target)
        save(saved() + [["id": machine.id!, "label": machine.label, "target": target]])
        return machine
    }

    /// Changes a saved machine's name and SSH target.
    static func update(_ id: String, label: String, target: String) -> Machine {
        let machine = Machine(id: id, label: label.isEmpty ? target : label, target: target)
        save(saved().map { $0["id"] == id ? ["id": id, "label": machine.label, "target": target] : $0 })
        return machine
    }

    static func remove(_ id: String) {
        save(saved().filter { $0["id"] != id })
        UserDefaults.standard.removeObject(forKey: "BrowserPath.\(id)")
    }

    /// Posted whenever the saved machines change.
    static let didChange = Notification.Name("ClothoMachinesDidChange")

    private static func saved() -> [[String: String]] {
        UserDefaults.standard.array(forKey: "Machines") as? [[String: String]] ?? []
    }

    private static func save(_ machines: [[String: String]]) {
        UserDefaults.standard.set(machines, forKey: "Machines")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The last folder the file browser showed on this machine.
    var lastFolder: String? {
        get { UserDefaults.standard.string(forKey: isLocal ? "LocalBrowserPath" : "BrowserPath.\(id!)") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: isLocal ? "LocalBrowserPath" : "BrowserPath.\(id!)") }
    }
}

/// This Mac's Computer Name (System Settings › General › About), cached and kept current: the name
/// the user gave it, rather than the hostname the network hands out.
enum ComputerName {
    /// Posted on the main queue when the user renames the computer.
    static let didChange = Notification.Name("ClothoComputerNameDidChange")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?
    nonisolated(unsafe) private static var store: SCDynamicStore?

    static var current: String {
        lock.withLock {
            if let cached { return cached }
            let name = read()
            cached = name
            return name
        }
    }

    private static func read() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
    }

    /// Starts following renames. Call once at launch.
    static func observe() {
        guard store == nil, let created = SCDynamicStoreCreate(nil, "Clotho" as CFString, { _, _, _ in
            ComputerName.lock.withLock { ComputerName.cached = nil }
            DispatchQueue.main.async { NotificationCenter.default.post(name: ComputerName.didChange, object: nil) }
        }, nil) else { return }
        let key = SCDynamicStoreKeyCreateComputerName(nil)
        SCDynamicStoreSetNotificationKeys(created, [key] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(created, DispatchQueue.main)
        store = created
    }
}

struct FileError: LocalizedError {
    let message: String
    /// The machine is still connecting, so trying again shortly may work.
    var isTransient = false
    var errorDescription: String? { message }
}

// MARK: SSH

// Connection checks (`ssh <target> true`) share one multiplexed connection per machine.
enum SSH {
    static var options: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
         "-o", "ControlMaster=auto", "-o", "ControlPath=\(NSHomeDirectory())/.ssh/cm-clothoapp-%C", "-o", "ControlPersist=600"]
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func run(_ machine: Machine, _ command: String, input: Data? = nil) throws -> Data {
        guard let target = machine.target else { throw FileError(message: "Not a remote machine") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + [target, command]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inp
        try process.run()
        if let input {
            inp.fileHandleForWriting.write(input)
            try? inp.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 255 {
            throw FileError(message: "Can't reach \(machine.label) over SSH. \(errText)")
        }
        if process.terminationStatus != 0 {
            throw FileError(message: errText.isEmpty ? "Command failed on \(machine.label)" : errText)
        }
        return data
    }
}

// MARK: Transfers

// A file or folder on some machine.
struct Location {
    let machine: Machine
    let path: String

    var name: String { (path as NSString).lastPathComponent }
}

final class Transfer {
    enum State { case running, done, failed(String), cancelled }

    let id = UUID()
    let title: String
    let sources: [Location]
    let destination: Location
    var state = State.running
    var progress: Double = 0
    var detail = "Starting…"
    var task: Task<Void, Never>?
    var onFinish: ((Bool) -> Void)?
    /// When the toast last showed this transfer's progress, to redraw it a few times a second at most.
    var shown = Date.distantPast

    init(title: String, sources: [Location], destination: Location) {
        self.title = title
        self.sources = sources
        self.destination = destination
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }
}

// Copies with ClothoKit's FileTransfer, between any two machines (through the app when neither is
// this Mac), and reports progress to the toast.
@MainActor
final class TransferManager {
    private(set) var transfers: [Transfer] = []
    var onChange: (() -> Void)?
    /// After every transfer with something to copy ends; `ok` is false for a failure or cancel.
    var onEnded: ((Transfer, _ ok: Bool) -> Void)?
    /// The file access for a machine, or why there's none.
    var files: ((Machine) throws -> FileBackend)?

    @discardableResult
    func start(title: String, sources: [Location], to destination: Location, conflict: FileTransfer.Conflict = .replace,
               onFinish: ((Bool) -> Void)? = nil) -> Transfer {
        let transfer = Transfer(title: title, sources: sources, destination: destination)
        transfer.onFinish = onFinish
        transfers.append(transfer)
        log("transfer: \(title) → \(destination.machine.label):\(destination.path)")
        run(transfer, conflict: conflict)
        onChange?()
        return transfer
    }

    func cancel(_ transfer: Transfer) {
        guard transfer.isRunning else { return remove(transfer) }
        transfer.state = .cancelled
        transfer.task?.cancel()
    }

    func remove(_ transfer: Transfer) {
        transfers.removeAll { $0.id == transfer.id }
        onChange?()
    }

    private func run(_ transfer: Transfer, conflict: FileTransfer.Conflict) {
        guard !transfer.sources.isEmpty else {
            transfer.state = .done
            return finish(transfer)
        }
        let to: FileBackend
        var copies: [(FileTransfer, [String])] = []
        do {
            to = try backend(transfer.destination.machine)
            // Sources are grouped by machine; in practice they all come from one side of the browser.
            var order: [MachineKey] = []
            var groups: [MachineKey: [Location]] = [:]
            for source in transfer.sources {
                if groups[source.machine.key] == nil { order.append(source.machine.key) }
                groups[source.machine.key, default: []].append(source)
            }
            for key in order {
                let items = groups[key]!
                copies.append((FileTransfer(from: try backend(items[0].machine), to: to), items.map(\.path)))
            }
        } catch {
            transfer.state = .failed(error.localizedDescription)
            return finish(transfer)
        }
        let folder = transfer.destination.path
        transfer.task = Task { [weak self] in
            do {
                for (index, (copy, paths)) in copies.enumerated() {
                    try await copy.copy(paths, into: folder, conflict: conflict) { progress in
                        Task { @MainActor in self?.update(transfer, progress, part: index, of: copies.count) }
                    }
                }
                if transfer.isRunning {
                    transfer.state = .done
                    transfer.progress = 1
                }
            } catch {
                if transfer.isRunning {
                    transfer.state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                    log("transfer failed: \(error)")
                }
            }
            self?.finish(transfer)
        }
    }

    private func backend(_ machine: Machine) throws -> FileBackend {
        guard let files else { throw FileError(message: "File access isn't set up") }
        return try files(machine)
    }

    private func update(_ transfer: Transfer, _ progress: FileTransfer.Progress, part: Int, of parts: Int) {
        guard transfer.isRunning else { return }
        transfer.progress = (Double(part) + progress.fraction) / Double(parts)
        let size = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        var detail = progress.current ?? "Preparing…"
        if progress.totalFiles > 1 { detail += " (\(min(progress.doneFiles + 1, progress.totalFiles)) of \(progress.totalFiles))" }
        if progress.totalBytes > 0 { detail += " · \(size(progress.doneBytes)) of \(size(progress.totalBytes))" }
        transfer.detail = detail
        // Fast local copies report thousands of times a second; the toast redraws a few times.
        guard Date().timeIntervalSince(transfer.shown) > 0.2 else { return }
        transfer.shown = Date()
        onChange?()
    }

    private func finish(_ transfer: Transfer) {
        let ok: Bool
        switch transfer.state {
        case .done: ok = true; transfer.detail = "Done"
        case .cancelled: ok = false; transfer.detail = "Cancelled"
        case .failed(let message): ok = false; transfer.detail = message
        case .running: return
        }
        transfer.onFinish?(ok)
        if !transfer.sources.isEmpty { onEnded?(transfer, ok) }
        onChange?()
        // Finished rows linger briefly; failures stay longer so the reason can be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 3 : 10)) { [weak self] in self?.remove(transfer) }
    }
}

// MARK: Transfer toast

// Stacked progress rows in the window's bottom-right corner, above everything else.
final class TransferToast: NSView {
    let manager: TransferManager
    let stack = NSStackView()
    static let width: CGFloat = 340

    init(manager: TransferManager) {
        self.manager = manager
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x23282C).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(hex: 0x343A3F).cgColor
        appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for transfer in manager.transfers { stack.addArrangedSubview(row(for: transfer)) }
        isHidden = manager.transfers.isEmpty
        guard let superview, !isHidden else { return }
        layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        setFrameSize(NSSize(width: Self.width, height: height))
        setFrameOrigin(NSPoint(x: superview.bounds.maxX - Self.width - 16, y: 16))
    }

    func row(for transfer: Transfer) -> NSView {
        let title = ShortcutsOverlay.label(transfer.title, size: 12, weight: .semibold, color: Theme.foreground)
        title.lineBreakMode = .byTruncatingMiddle
        var detailColor = NSColor(hex: 0x9AA3AA)
        if case .failed = transfer.state { detailColor = NSColor(hex: 0xC76156) }
        if case .done = transfer.state { detailColor = NSColor(hex: 0x57C78A) }
        let detail = ShortcutsOverlay.label(transfer.detail, size: 11, weight: .regular, color: detailColor)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 2
        detail.cell?.wraps = true

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = transfer.progress
        bar.controlSize = .small
        bar.isHidden = !transfer.isRunning

        let button = NSButton(image: NSImage(systemSymbolName: transfer.isRunning ? "xmark.circle.fill" : "xmark",
                                             accessibilityDescription: transfer.isRunning ? "Cancel" : "Dismiss")!,
                              target: self, action: #selector(cancelTapped(_:)))
        button.isBordered = false
        button.contentTintColor = NSColor(hex: 0x7F888F)
        button.identifier = NSUserInterfaceItemIdentifier(transfer.id.uuidString)

        let top = NSStackView(views: [title, NSView(), button])
        top.orientation = .horizontal
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [top, bar, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        let width = Self.width - 28
        for view in [top, bar, detail] { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return column
    }

    @objc func cancelTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let transfer = manager.transfers.first(where: { $0.id.uuidString == id }) else { return }
        manager.cancel(transfer)
    }

    override func mouseDown(with event: NSEvent) {}
}

// MARK: App integration

extension AppDelegate {
    func installTransferToast() {
        transferToast = TransferToast(manager: transfers)
        transferToast.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(transferToast)
        transfers.onChange = { [weak self] in self?.transferToast.refresh() }
        // Unfinished uploads leave part files behind (see PartCleanup).
        transfers.onEnded = { [weak self] transfer, ok in
            guard let self else { return }
            if !ok { noteUnfinishedTransfer(to: transfer.destination) }
            cleanUpPartFiles()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.cleanUpPartFiles() }
        transfers.files = { [weak self] machine in
            guard let self else { throw FileError(message: "Clotho is closing") }
            return try fileBackend(for: machine)
        }
    }

    /// File access on a machine: this Mac's own files, or the machine's clothod (`fs.*`) through
    /// its connection. Throws a message for the browser when the machine can't share files yet.
    func fileBackend(for machine: Machine) throws -> FileBackend {
        if machine.isLocal { return Self.localFiles }
        guard let session = connections[machine.key] else {
            throw FileError(message: "Connect to \(machine.label) to browse its files.")
        }
        guard let files = session.store.backend as? FileBackend, let hello = session.store.hello else {
            throw FileError(message: "Waiting for \(machine.label)…", isTransient: true)
        }
        guard files.supportsFiles else {
            throw FileError(message: "\(machine.label) runs clothod \(hello.version), which can't share files. "
                + "Update it to 0.1.3 or later from the machine's menu in the sidebar.")
        }
        return files
    }

    static let localFiles = LocalFileBackend()

    // Keeps the toast above any overlay that was added after it.
    func raiseTransferToast() {
        transferToast.removeFromSuperview()
        container.addSubview(transferToast)
        transferToast.refresh()
    }

    @objc func showFileBrowser(_ sender: Any?) {
        if let fileBrowser {
            fileBrowser.dismiss()
            return
        }
        showFileBrowser(on: nil)
    }

    /// Opens the file browser with its left side on `machine` (the terminals' machine when nil), or
    /// switches the open browser to it.
    func showFileBrowser(on machine: Machine?) {
        if let fileBrowser {
            if let machine { fileBrowser.left.switchTo(machine) }
            return
        }
        shortcutsOverlay?.dismiss()
        let browser = FileBrowserOverlay(app: self, machine: machine)
        browser.onDismiss = { [weak self] in
            guard let self else { return }
            fileBrowser = nil
            window.makeFirstResponder(activeTerminal)
        }
        browser.frame = container.bounds
        browser.autoresizingMask = [.width, .height]
        container.addSubview(browser)
        fileBrowser = browser
        raiseTransferToast()
        browser.focusFirstPane()
    }

    @objc func chooseFilesToUpload(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        panel.message = "Choose files to send to the active pane's folder on \(focusedConnection.machine.label)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.upload(panel.urls)
        }
    }

    // Sends local files to a pane's folder (the focused pane's by default) on that pane's machine, as its
    // daemon reports the folder.
    func upload(_ urls: [URL], toPane key: PaneKey? = nil) {
        let session = key.flatMap { connections[$0.machine] } ?? focusedConnection
        let machine = session.machine
        guard let folder = session.store.state.pane(key?.pane ?? focusedPaneID)?.cwd else {
            let failed = Transfer(title: "Upload to \(machine.label)", sources: [], destination: Location(machine: machine, path: "~"))
            showError(failed, "Couldn't find the pane's folder on \(machine.label).")
            return
        }
        copy(urls.map { Location(machine: .local, path: $0.path) }, to: Location(machine: machine, path: folder), then: nil)
    }

    private func showError(_ transfer: Transfer, _ message: String) {
        let t = transfers.start(title: transfer.title, sources: [], to: transfer.destination)
        t.state = .failed(message)
        t.detail = message
        transferToast.refresh()
    }

    // Copies items to a folder, asking first if any names are already there.
    func copy(_ sources: [Location], to destination: Location, then done: ((Bool) -> Void)?) {
        guard !sources.isEmpty else { return }
        let names = sources.map(\.name)
        let files: FileBackend
        do {
            files = try fileBackend(for: destination.machine)
        } catch {
            let failed = Transfer(title: "Copy to \(destination.machine.label)", sources: [], destination: destination)
            return showError(failed, error.localizedDescription)
        }
        Task { @MainActor [self] in
            let clashes = await FileTransfer.existing(names, in: destination.path, on: files)
            let begin = { (items: [Location]) in
                guard !items.isEmpty else { return }
                let verb = items.allSatisfy({ $0.machine == destination.machine }) ? "Copying"
                    : destination.machine.isLocal ? "Downloading" : "Uploading"
                let what = items.count == 1 ? items[0].name : "\(items.count) items"
                let place = "\(destination.machine.label):\((destination.path as NSString).abbreviatingWithTildeInPath)"
                self.transfers.start(title: "\(verb) \(what) → \(place)", sources: items, to: destination, onFinish: done)
            }
            guard !clashes.isEmpty else { return begin(sources) }
            let alert = NSAlert()
            alert.messageText = clashes.count == 1
                ? "“\(clashes[0])” already exists in \(destination.name)."
                : "\(clashes.count) items already exist in \(destination.name)."
            alert.informativeText = clashes.count == 1
                ? "Replace overwrites it (a folder is merged). Skip leaves it as it is."
                : "Replace overwrites them (folders are merged). Skip copies only the new items."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: begin(sources)
                case .alertSecondButtonReturn: begin(sources.filter { !clashes.contains($0.name) })
                default: break
                }
            }
        }
    }
}

// MARK: File browser

extension NSPasteboard.PasteboardType {
    static let clothoRemoteFile = NSPasteboard.PasteboardType("app.clotho.desktop.remote-file")
}

// A remote row being dragged: other panes read the Clotho type, Finder gets a file promise it fills by downloading.
final class RemoteFilePromise: NSFilePromiseProvider {
    var location: Location!

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.clothoRemoteFile] + super.writableTypes(for: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .clothoRemoteFile {
            return [location.machine.id ?? "", location.path].joined(separator: "\n")
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

// A card over the terminal with the active machine on the left and this Mac on the right.
final class FileBrowserOverlay: NSView {
    weak var app: AppDelegate?
    var onDismiss: (() -> Void)?
    let card = NSView()
    var left: FilePane!
    var right: FilePane!

    init(app: AppDelegate, machine: Machine? = nil) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        appearance = NSAppearance(named: .darkAqua)

        // FilesMachine (a launch argument, for testing) overrides which machine the left side shows.
        // "label" or "label:/path".
        let override = UserDefaults.standard.string(forKey: "FilesMachine")?.split(separator: ":", maxSplits: 1).map(String.init)
        let active = machine ?? override.flatMap { o in Machine.all().first { $0.label == o[0] } } ?? app.focusedConnection.machine
        let activePath = override.flatMap { $0.count > 1 ? $0[1] : nil }
        let localPath = UserDefaults.standard.string(forKey: "LocalBrowserPath") ?? "~/Downloads"
        left = FilePane(app: app, machine: active, path: activePath, choosable: true)
        right = FilePane(app: app, machine: .local, path: localPath, choosable: false)
        left.other = right
        right.other = left

        let title = ShortcutsOverlay.label("Files", size: 15, weight: .semibold, color: Theme.foreground)
        let hint = ShortcutsOverlay.label("Drag between sides or to Finder · ⇧⌘O or Esc to close",
                                          size: 12, weight: .regular, color: NSColor(hex: 0x7F888F))
        let top = NSStackView(views: [title, NSView(), hint])
        top.orientation = .horizontal
        top.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)

        let divider = NSBox()
        divider.boxType = .custom
        divider.fillColor = NSColor(hex: 0x343A3F)
        divider.borderWidth = 0
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let panes = NSStackView(views: [left, divider, right])
        panes.orientation = .horizontal
        panes.spacing = 0
        panes.distribution = .fill
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.background.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(hex: 0x343A3F).cgColor
        card.layer?.masksToBounds = true

        let stack = NSStackView(views: [top, panes])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)
        for view in [stack, card, top, panes] { view.translatesAutoresizingMaskIntoConstraints = false }
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            panes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // A centered card, at most 960×600, shrinking with the window.
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            card.heightAnchor.constraint(lessThanOrEqualToConstant: 600),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -64),
        ])
        for (dimension, other) in [(card.widthAnchor, widthAnchor), (card.heightAnchor, heightAnchor)] {
            let fill = dimension.constraint(equalTo: other)
            fill.priority = .defaultLow
            fill.isActive = true
        }
        left.start()
        right.start()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusFirstPane() { window?.makeFirstResponder(left.table) }

    func dismiss() {
        removeFromSuperview()
        onDismiss?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() }
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// A Windows Explorer-style address bar: each folder in the path is a button that jumps there.
// Clicking the empty part of the bar switches to an editable path; Enter goes there, Esc cancels.
final class BreadcrumbBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((String) -> Void)?
    private let crumbs = NSStackView()
    private let field = NSTextField()
    private var path = "/"
    private var home: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x23282C).cgColor
        layer?.cornerRadius = 5
        layer?.masksToBounds = true

        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crumbs)

        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = Theme.foreground
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.isHidden = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        // Pinned to the right, so a long path drops its leading folders off the left edge first.
        let leading = crumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        leading.priority = .defaultLow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            leading,
            crumbs.leadingAnchor.constraint(lessThanOrEqualTo: leadingAnchor, constant: 4),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Shows a path as crumbs; paths inside `home` start from "~".
    func show(_ path: String, home: String?) {
        self.path = path
        self.home = home
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var segments: [(title: String, path: String)] = []
        var rest = path
        if let home, path == home || path.hasPrefix(home + "/") {
            segments.append(("~", home))
            rest = String(path.dropFirst(home.count))
        } else {
            segments.append(("/", "/"))
        }
        var current = segments[0].path
        for part in rest.split(separator: "/") {
            current = (current as NSString).appendingPathComponent(String(part))
            segments.append((String(part), current))
        }

        for (i, segment) in segments.enumerated() {
            if i > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.font = NSFont.systemFont(ofSize: 13)
                separator.textColor = NSColor(hex: 0x5C656C)
                crumbs.addArrangedSubview(separator)
            }
            let isLast = i == segments.count - 1
            let button = NSButton(title: segment.title, target: self, action: #selector(crumbClicked(_:)))
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.controlSize = .small
            button.attributedTitle = NSAttributedString(string: segment.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isLast ? .semibold : .regular),
                .foregroundColor: isLast ? Theme.foreground : NSColor(hex: 0x9AA3AA),
            ])
            button.toolTip = segment.path
            button.identifier = NSUserInterfaceItemIdentifier(segment.path)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            crumbs.addArrangedSubview(button)
        }
    }

    @objc func crumbClicked(_ sender: NSButton) {
        guard let target = sender.identifier?.rawValue else { return }
        onNavigate?(target)
    }

    // Clicking beside the crumbs edits the path as text.
    override func mouseDown(with event: NSEvent) { beginEditing() }

    func beginEditing() {
        let shown = home.map { path == $0 || path.hasPrefix($0 + "/") ? "~" + path.dropFirst($0.count) : path } ?? path
        field.stringValue = shown
        crumbs.isHidden = true
        field.isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        field.isHidden = true
        crumbs.isHidden = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            endEditing()
            if !text.isEmpty { onNavigate?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            window?.makeFirstResponder(superview)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

// Return opens, Backspace or ⌘↑ goes up; Esc falls through to the overlay.
final class FileTable: NSTableView {
    var onOpen: (() -> Void)?
    var onUp: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onOpen?()
        case 51: onUp?()
        case 126 where event.modifierFlags.contains(.command): onUp?()
        case 125 where event.modifierFlags.contains(.command): onOpen?()
        default: super.keyDown(with: event)
        }
    }
}

// One side of the browser: a machine, a folder and its contents.
final class FilePane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
    weak var app: AppDelegate?
    weak var other: FilePane?
    private(set) var machine: Machine
    private(set) var path: String
    private var requestedPath: String?
    private var entries: [FileEntry] = []
    private var shown: [FileEntry] = []
    private var showHidden = false
    private var generation = 0
    /// The machine's home folder, for breadcrumbs that start at "~".
    private var home: String?

    let table = FileTable()
    let pathBar = BreadcrumbBar()
    let status = ShortcutsOverlay.label("", size: 11, weight: .regular, color: NSColor(hex: 0x7F888F))
    let machineMenu = NSPopUpButton()
    let hiddenButton = NSButton()
    let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(app: AppDelegate, machine: Machine, path: String?, choosable: Bool) {
        self.app = app
        self.machine = machine
        self.path = path ?? "~"
        self.requestedPath = path
        super.init(frame: .zero)

        machineMenu.isBordered = false
        machineMenu.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        machineMenu.target = self
        machineMenu.action = #selector(machineChosen(_:))
        machineMenu.isEnabled = choosable
        rebuildMachineMenu()

        let up = Self.iconButton("arrow.up", "Enclosing Folder", self, #selector(goUp))
        let refresh = Self.iconButton("arrow.clockwise", "Refresh", self, #selector(reload))
        hiddenButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Show Hidden Files")
        hiddenButton.isBordered = false
        hiddenButton.contentTintColor = NSColor(hex: 0x9AA3AA)
        hiddenButton.target = self
        hiddenButton.action = #selector(toggleHidden)
        hiddenButton.toolTip = "Show hidden files"

        let header = NSStackView(views: [machineMenu, NSView(), hiddenButton, refresh, up])
        header.orientation = .horizontal
        header.spacing = 10

        pathBar.onNavigate = { [weak self] target in
            self?.load(target)
            self?.window?.makeFirstResponder(self?.table)
        }

        setUpTable()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let stack = NSStackView(views: [header, pathBar, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            pathBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func iconButton(_ symbol: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = NSColor(hex: 0x9AA3AA)
        button.toolTip = label
        return button
    }

    static let addMachineTag = 1

    func rebuildMachineMenu() {
        machineMenu.removeAllItems()
        for m in Machine.all() {
            machineMenu.addItem(withTitle: m.label)
            machineMenu.lastItem?.representedObject = m.id
        }
        if machineMenu.isEnabled {
            machineMenu.menu?.addItem(.separator())
            machineMenu.addItem(withTitle: "Add Machine…")
            machineMenu.lastItem?.tag = Self.addMachineTag
        }
        machineMenu.selectItem(withTitle: machine.label)
    }

    // Asks for a label and an SSH target, saves the machine and switches to it.
    func addMachine() {
        guard let app else { return }
        app.promptForMachine(editing: nil) { [weak self] machine in
            guard let self else { return }
            if let machine { switchTo(machine) } else { rebuildMachineMenu() }
        }
    }

    private func setUpTable() {
        let columns: [(String, String, CGFloat)] = [("name", "Name", 260), ("size", "Size", 80), ("modified", "Modified", 120)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 120 : 60
            column.resizingMask = id == "name" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.style = .plain
        table.backgroundColor = Theme.background
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(openSelected)
        table.target = self
        table.onOpen = { [weak self] in self?.openSelected() }
        table.onUp = { [weak self] in self?.goUp() }
        table.registerForDraggedTypes([.fileURL, .clothoRemoteFile])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        table.menu = NSMenu()
        table.menu?.delegate = self
    }

    // MARK: Loading

    // Opens at the given folder; on this Mac, at the focused pane's folder; elsewhere, where it was last time.
    func start() {
        if let requestedPath { return load(requestedPath) }
        // A machine with a connected daemon opens in its focused pane's folder.
        if let folder = app?.connections[machine.key]?.store.focusedPane?.cwd { return load(folder) }
        load(machine.lastFolder ?? "~")
    }

    func load(_ target: String) {
        generation += 1
        let token = generation
        status.stringValue = "Loading…"
        let files: FileBackend
        do {
            guard let app else { return }
            files = try app.fileBackend(for: machine)
        } catch {
            entries = []
            applyFilter()
            status.stringValue = error.localizedDescription
            // A machine that's still connecting gets its listing once it's up.
            if (error as? FileError)?.isTransient == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, token == generation, window != nil else { return }
                    load(target)
                }
            }
            return
        }
        let machine = machine
        Task { @MainActor [weak self] in
            do {
                let listing = try await files.listAll(target, hidden: true)
                guard let self, token == generation else { return }
                path = listing.dir.path
                home = files.homeDirectory
                entries = listing.entries.sorted {
                    $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                machine.lastFolder = path
                applyFilter()
            } catch {
                guard let self, token == generation else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func applyFilter() {
        shown = showHidden ? entries : entries.filter { !$0.hidden }
        pathBar.show(path, home: home)
        table.reloadData()
        let hidden = entries.count - shown.count
        status.stringValue = "\(shown.count) item\(shown.count == 1 ? "" : "s")" + (hidden > 0 ? " · \(hidden) hidden" : "")
    }

    @objc func reload() { load(path) }

    @objc func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    @objc func toggleHidden() {
        showHidden.toggle()
        hiddenButton.image = NSImage(systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: "Show Hidden Files")
        hiddenButton.contentTintColor = showHidden ? Theme.accent : NSColor(hex: 0x9AA3AA)
        applyFilter()
    }

    @objc func machineChosen(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == Self.addMachineTag { return addMachine() }
        let id = sender.selectedItem?.representedObject as? String
        guard let chosen = Machine.all().first(where: { $0.id == id }), chosen != machine else { return }
        switchTo(chosen)
    }

    func switchTo(_ chosen: Machine) {
        machine = chosen
        rebuildMachineMenu()
        entries = []
        applyFilter()
        requestedPath = nil
        start()
    }

    func fullPath(_ entry: FileEntry) -> String { (path as NSString).appendingPathComponent(entry.name) }

    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let entry = shown[row]
        if entry.isDirectory {
            load(fullPath(entry))
        } else if machine.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: fullPath(entry)))
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return f
    }()

    // "Today 3:07 PM" for today, otherwise "Oct 22, 2026".
    static func format(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today " + timeFormatter.string(from: date) : dayFormatter.string(from: date)
    }

    func icon(for entry: FileEntry) -> NSImage {
        if machine.isLocal { return NSWorkspace.shared.icon(forFile: fullPath(entry)) }
        if entry.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (entry.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < shown.count else { return nil }
        let entry = shown[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.font = NSFont.systemFont(ofSize: 12)
        text.textColor = id == "name" ? Theme.foreground : NSColor(hex: 0x9AA3AA)
        switch id {
        case "name": text.stringValue = entry.name
        case "size": text.stringValue = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        default: text.stringValue = Self.format(entry.modified)
        }
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id == "name" {
            let image = NSImageView(image: icon(for: entry))
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < shown.count else { return nil }
        let entry = shown[row]
        if machine.isLocal { return NSURL(fileURLWithPath: fullPath(entry)) }
        let ext = (entry.name as NSString).pathExtension
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
        let promise = RemoteFilePromise(fileType: type.identifier, delegate: self)
        promise.location = Location(machine: machine, path: fullPath(entry))
        promise.userInfo = entry.name
        return promise
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        provider.userInfo as? String ?? "download"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    // Finder dropped a remote row: download it to where Finder asked.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let location = (provider as? RemoteFilePromise)?.location else {
            return completionHandler(FileError(message: "Nothing to download"))
        }
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.main.async { [weak self] in
            let destination = Location(machine: .local, path: url.deletingLastPathComponent().path)
            let started = self?.app?.transfers.start(title: "Downloading \(location.name) → Finder", sources: [location], to: destination) { ok in
                if !ok { failure = FileError(message: "Download of \(location.name) failed") }
                done.signal()
            }
            if started == nil { done.signal() }
        }
        done.wait()
        completionHandler(failure)
    }

    // MARK: Dropping in

    private func destinationFolder(forRow row: Int, operation: NSTableView.DropOperation) -> String? {
        if operation == .on, row >= 0, row < shown.count {
            return shown[row].isDirectory ? fullPath(shown[row]) : nil
        }
        return path
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, row >= 0, row < shown.count, shown[row].isDirectory {
            return .copy
        }
        tableView.setDropRow(-1, dropOperation: .on)
        if (info.draggingSource as? NSTableView) === tableView { return [] }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let folder = destinationFolder(forRow: row, operation: dropOperation) else { return false }
        let pasteboard = info.draggingPasteboard
        var sources: [Location] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let text = item.string(forType: .clothoRemoteFile) {
                let parts = text.components(separatedBy: "\n")
                guard parts.count == 2, let source = Machine.all().first(where: { ($0.id ?? "") == parts[0] }) else { continue }
                sources.append(Location(machine: source, path: parts[1]))
            } else if let string = item.string(forType: .fileURL), let url = URL(string: string) {
                sources.append(Location(machine: .local, path: url.path))
            }
        }
        // Copies between any two machines, or into another folder on the same one.
        sources = sources.filter { $0.machine != machine || ($0.path as NSString).deletingLastPathComponent != folder }
        guard !sources.isEmpty else { return false }
        app?.copy(sources, to: Location(machine: machine, path: folder)) { [weak self] ok in
            if ok { self?.reload() }
        }
        return true
    }

    // MARK: Context menu

    func selectedLocations() -> [Location] {
        let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return rows.filter { $0 < shown.count }.map { Location(machine: machine, path: fullPath(shown[$0])) }
    }

    @objc func sendToOtherSide() {
        guard let other else { return }
        let items = selectedLocations()
        guard !items.isEmpty else { return }
        app?.copy(items, to: Location(machine: other.machine, path: other.path)) { [weak other] ok in
            if ok { other?.reload() }
        }
    }

    @objc func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedLocations().map { URL(fileURLWithPath: $0.path) })
    }

    @objc func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedLocations().map(\.path).joined(separator: "\n"), forType: .string)
    }
}

extension FilePane: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !selectedLocations().isEmpty else { return }
        if let other {
            let verb = machine.isLocal ? (other.machine.isLocal ? "Copy" : "Upload") : "Download"
            menu.addItem(withTitle: "\(verb) to \(other.machine.label): \((other.path as NSString).lastPathComponent)",
                         action: #selector(sendToOtherSide), keyEquivalent: "").target = self
        }
        if machine.isLocal {
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
    }
}
