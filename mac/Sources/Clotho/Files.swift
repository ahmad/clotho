import AppKit
import ClothoKit
import UniformTypeIdentifiers

// MARK: Machines

// Local, or a saved SSH host that the file browser reaches over ssh and rsync. Terminals run on the
// session daemon's machine (this Mac, for now). The saved hosts live in the "Machines" default as
// [{id, label, target}], imported once from herdr's saved machines.
struct Machine: Equatable {
    let id: String?
    let label: String
    let target: String?

    var isLocal: Bool { target == nil }
    static let local = Machine(id: nil, label: "Local", target: nil)

    static func all() -> [Machine] {
        importHerdrMachines()
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
        importHerdrMachines()
        return UserDefaults.standard.array(forKey: "Machines") as? [[String: String]] ?? []
    }

    private static func save(_ machines: [[String: String]]) {
        UserDefaults.standard.set(machines, forKey: "Machines")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // herdr kept its SSH profiles in ~/.local/state/herdr/client/endpoints.json; bring them over the first time.
    private static func importHerdrMachines() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "Machines") == nil else { return }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/herdr/client/endpoints.json")
        let profiles = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ssh"] as? [[String: Any]] ?? []
        let saved = profiles.compactMap { p -> [String: String]? in
            guard p["enabled"] as? Bool != false, let id = p["id"] as? String, let target = p["target"] as? String else { return nil }
            return ["id": id, "label": p["label"] as? String ?? target, "target": target]
        }
        defaults.set(saved, forKey: "Machines")
    }


    /// The last folder the file browser showed on this machine.
    var lastFolder: String? {
        get { UserDefaults.standard.string(forKey: isLocal ? "LocalBrowserPath" : "BrowserPath.\(id!)") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: isLocal ? "LocalBrowserPath" : "BrowserPath.\(id!)") }
    }
}

struct FileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: SSH

// Every remote call shares one multiplexed connection per machine, so listings feel instant.
enum SSH {
    static var options: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
         "-o", "ControlMaster=auto", "-o", "ControlPath=\(NSHomeDirectory())/.ssh/cm-clothoapp-%C", "-o", "ControlPersist=600"]
    }

    // The ssh command rsync runs (-e).
    static var rsyncShell: String { (["ssh"] + options).joined(separator: " ") }

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

// MARK: Listing and lookups

struct FileEntry {
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date
}

enum FileSource {
    static let listScript = """
    import json, os, sys
    p = os.path.abspath(os.path.expanduser(sys.argv[1]))
    out = {"path": p, "entries": []}
    try:
        with os.scandir(p) as it:
            for e in it:
                try:
                    st = e.stat(follow_symlinks=True); d = e.is_dir(follow_symlinks=True)
                except OSError:
                    st = e.stat(follow_symlinks=False); d = False
                out["entries"].append([e.name, d, st.st_size, int(st.st_mtime)])
    except OSError as err:
        out["error"] = err.strerror or str(err)
    print(json.dumps(out))
    """

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    // Returns the resolved folder and its contents.
    static func list(_ machine: Machine, _ path: String) throws -> (String, [FileEntry]) {
        if machine.isLocal {
            let dir = URL(fileURLWithPath: expand(path)).standardizedFileURL
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
            } catch {
                throw FileError(message: (error as NSError).localizedDescription)
            }
            let entries = urls.map { url -> FileEntry in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDir = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileEntry(name: url.lastPathComponent, isDir: isDir,
                                 size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
            }
            return (dir.path, entries)
        }
        let data = try SSH.run(machine, "python3 - " + SSH.quote(path), input: Data(listScript.utf8))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resolved = json["path"] as? String
        else { throw FileError(message: "Couldn't read the folder listing from \(machine.label)") }
        if let error = json["error"] as? String { throw FileError(message: error) }
        let entries = (json["entries"] as? [[Any]] ?? []).compactMap { e -> FileEntry? in
            guard e.count >= 4, let name = e[0] as? String else { return nil }
            return FileEntry(name: name, isDir: e[1] as? Bool ?? false, size: (e[2] as? NSNumber)?.int64Value ?? 0,
                             modified: Date(timeIntervalSince1970: (e[3] as? NSNumber)?.doubleValue ?? 0))
        }
        return (resolved, entries)
    }

    // Which of these names already exist in a folder.
    static func existing(_ names: [String], in dir: String, on machine: Machine) -> [String] {
        if machine.isLocal {
            return names.filter { FileManager.default.fileExists(atPath: (expand(dir) as NSString).appendingPathComponent($0)) }
        }
        let script = "import os,sys\nd=os.path.expanduser(sys.argv[1])\nfor n in sys.argv[2:]:\n    if os.path.lexists(os.path.join(d,n)): print(n)"
        let command = (["python3", "-c", SSH.quote(script), SSH.quote(dir)] + names.map(SSH.quote)).joined(separator: " ")
        guard let data = try? SSH.run(machine, command), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

// MARK: Transfers

// A file or folder on some machine.
struct Location {
    let machine: Machine
    let path: String

    var name: String { (path as NSString).lastPathComponent }

    // How rsync addresses it; remote paths are quoted for the remote shell.
    var rsyncArg: String {
        guard let target = machine.target else { return FileSource.expand(path) }
        return target + ":" + SSH.quote(path)
    }
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
    var process: Process?
    var onFinish: ((Bool) -> Void)?

    init(title: String, sources: [Location], destination: Location) {
        self.title = title
        self.sources = sources
        self.destination = destination
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }
}

// Runs rsync for each item in turn and reports progress to the toast.
final class TransferManager {
    private(set) var transfers: [Transfer] = []
    var onChange: (() -> Void)?

    @discardableResult
    func start(title: String, sources: [Location], to destination: Location, onFinish: ((Bool) -> Void)? = nil) -> Transfer {
        let transfer = Transfer(title: title, sources: sources, destination: destination)
        transfer.onFinish = onFinish
        transfers.append(transfer)
        log("transfer: \(title) → \(destination.machine.label):\(destination.path)")
        run(transfer, index: 0)
        onChange?()
        return transfer
    }

    func cancel(_ transfer: Transfer) {
        guard transfer.isRunning else { return remove(transfer) }
        transfer.state = .cancelled
        transfer.process?.terminate()
    }

    func remove(_ transfer: Transfer) {
        transfers.removeAll { $0.id == transfer.id }
        onChange?()
    }

    private func run(_ transfer: Transfer, index: Int) {
        guard transfer.isRunning else { return finish(transfer) }
        guard index < transfer.sources.count else {
            transfer.state = .done
            transfer.progress = 1
            return finish(transfer)
        }
        let source = transfer.sources[index]
        let count = transfer.sources.count
        transfer.detail = count > 1 ? "\(source.name) (\(index + 1) of \(count))" : source.name

        var args = ["-a", "--partial", "--progress"]
        if !source.machine.isLocal || !transfer.destination.machine.isLocal {
            args += ["-z", "-e", SSH.rsyncShell]
        }
        var dest = transfer.destination.rsyncArg
        if transfer.destination.machine.isLocal {
            dest = FileSource.expand(transfer.destination.path) + "/"
        } else {
            dest = transfer.destination.machine.target! + ":" + SSH.quote(transfer.destination.path + "/")
        }
        args += [source.rsyncArg, dest]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var errText = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8),
                  let match = chunk.range(of: #"(\d+)%"#, options: [.regularExpression, .backwards]),
                  let pct = Double(chunk[match].dropLast())
            else { return }
            DispatchQueue.main.async {
                transfer.progress = (Double(index) + pct / 100) / Double(count)
                self?.onChange?()
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8) {
                DispatchQueue.main.async { errText += text }
            }
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if p.terminationStatus != 0, transfer.isRunning {
                    let lines = errText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    transfer.state = .failed(lines.last ?? "rsync exited with status \(p.terminationStatus)")
                    log("transfer failed: \(errText)")
                }
                self.run(transfer, index: index + 1)
            }
        }
        transfer.process = process
        do {
            try process.run()
        } catch {
            transfer.state = .failed(error.localizedDescription)
            finish(transfer)
        }
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
    }

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
        panel.message = "Choose files to send to the active pane's folder on \(focusedSession.machine.label)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.upload(panel.urls)
        }
    }

    // Sends local files to a pane's folder (the focused pane's by default) on that pane's machine, as its
    // daemon reports the folder.
    func upload(_ urls: [URL], toPane key: PaneKey? = nil) {
        let session = key.flatMap { sessions[$0.machine] } ?? focusedSession
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
        DispatchQueue.global(qos: .userInitiated).async {
            let clashes = FileSource.existing(names, in: destination.path, on: destination.machine)
            DispatchQueue.main.async { [self] in
                let begin = { (items: [Location]) in
                    guard !items.isEmpty else { return }
                    let verb = destination.machine.isLocal
                        ? (items.allSatisfy { $0.machine.isLocal } ? "Copying" : "Downloading")
                        : "Uploading"
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
        let active = machine ?? override.flatMap { o in Machine.all().first { $0.label == o[0] } } ?? app.focusedSession.machine
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
        if let folder = app?.sessions[machine.key]?.store.focusedPane?.cwd { return load(folder) }
        load(machine.lastFolder ?? "~")
    }

    func load(_ target: String) {
        generation += 1
        let token = generation
        let machine = machine
        status.stringValue = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FileSource.list(machine, target) }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == generation else { return }
                switch result {
                case .success(let (resolved, items)):
                    path = resolved
                    entries = items.sorted {
                        $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    machine.lastFolder = resolved
                    applyFilter()
                case .failure(let error):
                    status.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func applyFilter() {
        shown = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        pathBar.show(path, home: machine.isLocal ? NSHomeDirectory() : nil)
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
        if entry.isDir {
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
        if entry.isDir { return NSWorkspace.shared.icon(for: .folder) }
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
        case "size": text.stringValue = entry.isDir ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
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
        let type = entry.isDir ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
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
            return shown[row].isDir ? fullPath(shown[row]) : nil
        }
        return path
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, row >= 0, row < shown.count, shown[row].isDir {
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
        // Only copies across machines or into a different local folder; remote-to-same-remote moves aren't supported.
        sources = sources.filter { source in
            if source.machine == machine {
                return machine.isLocal && (source.path as NSString).deletingLastPathComponent != folder
            }
            return source.machine.isLocal || machine.isLocal
        }
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
