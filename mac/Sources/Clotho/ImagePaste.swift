import AppKit
import ClothoKit

// Pasting images and dropping files into agents (Claude Code, Codex) that run on another machine.
//
// Those agents read images from the clipboard of the machine they run on (pbpaste/osascript on a Mac,
// xclip/wl-paste/arboard on Linux), which isn't this Mac's, and a terminal paste carries only text. So
// the app saves the image as a PNG on the pane's machine and pastes its path, which the agents attach.

/// The decisions, kept apart from AppKit so they can be tested.
enum ImagePaste {
    enum Key { case command, control }

    struct Context: Equatable {
        var key: Key
        /// The pane is on another machine.
        var remote: Bool
        var hasText: Bool
        var hasImage: Bool
        /// A Claude Code or Codex runs in the pane (from the daemon's agent status).
        var agent: Bool
    }

    enum Action: Equatable {
        /// What the terminal does anyway: a text paste for ⌘V, ^V for ⌃V.
        case terminal
        /// Save the image as a file on the pane's machine and paste its path.
        case imageFile
    }

    static func action(_ c: Context) -> Action {
        switch c.key {
        // Text wins, as before. An image alone pasted nothing, here or remotely.
        case .command:
            return c.hasImage && !c.hasText ? .imageFile : .terminal
        // ⌃V is Claude Code's image-paste key, but vim, shells and others use it too. A local agent reads
        // this Mac's clipboard itself, so only a remote agent with an image on the clipboard gets a file.
        case .control:
            return c.remote && c.agent && c.hasImage ? .imageFile : .terminal
        }
    }

    static let agentKinds: Set<String> = ["claude", "codex"]

    /// Where pastes go on a remote machine, from its home directory.
    static func remoteFolder(home: String) -> String { filePath(home, ".cache/clotho/paste") }

    /// Where pastes go on this Mac.
    static var localFolder: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.clotho.desktop")
            .appendingPathComponent("paste").path
    }

    /// `20261027-150102-a1b2c3`: sorts by time, and the id keeps two pastes in one second apart.
    static func stamp(_ date: Date, id: String) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return "\(format.string(from: date))-\(id)"
    }

    static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased() }

    static func imageName(_ date: Date, id: String) -> String { stamp(date, id: id) + ".png" }

    /// How long pasted files are kept.
    static let lifetime: TimeInterval = 7 * 24 * 3600

    /// Paths in the paste folder older than `lifetime`.
    static func expired(_ entries: [FileEntry], now: Date) -> [String] {
        let cutoff = now.timeIntervalSince1970 - lifetime
        return entries.filter { $0.mtime < cutoff }.map(\.path)
    }

    /// A path as typed into a shell or agent prompt: special characters escaped with a backslash, as
    /// Terminal and iTerm2 do for dropped files.
    static func typed(_ path: String) -> String {
        let special = Set(" \t'\"\\()[]{}&;|<>*?$`!#")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    // MARK: The clipboard

    static func hasText(_ pasteboard: NSPasteboard) -> Bool {
        !(pasteboard.string(forType: .string) ?? "").isEmpty
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// The clipboard's image as PNG.
    static func png(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
        return image.representation(using: .png, properties: [:])
    }
}

extension AppDelegate {
    /// Whether an agent (Claude Code, Codex) runs in the pane.
    func paneRunsAgent(_ key: PaneKey) -> Bool {
        guard let agent = connections[key.machine]?.store.state.pane(key.pane)?.agent else { return false }
        return ImagePaste.agentKinds.contains(agent.kind)
    }

    /// ⌘V (the terminal's paste:) or ⌃V in a pane. Returns true when it took the paste: an image is
    /// saved on the pane's machine and its path pasted once it's there (or an error shown, and nothing
    /// pasted). False leaves the key to the terminal as before.
    func pasteImage(into terminal: PaneTerminalView, key: ImagePaste.Key) -> Bool {
        let pane = PaneKey(machine: terminal.machine, pane: terminal.paneID)
        guard let session = connections[pane.machine] else { return false }
        let pasteboard = NSPasteboard.general
        let context = ImagePaste.Context(key: key, remote: !session.machine.isLocal, hasText: ImagePaste.hasText(pasteboard),
                                         hasImage: ImagePaste.hasImage(pasteboard), agent: paneRunsAgent(pane))
        guard ImagePaste.action(context) == .imageFile else { return false }
        let machine = session.machine
        guard let png = ImagePaste.png(pasteboard) else {
            showTransferError("Paste image on \(machine.label)", machine, "The clipboard's image couldn't be read as PNG.")
            return true
        }
        let name = ImagePaste.imageName(Date(), id: ImagePaste.newID())
        log("paste: image (\(png.count) bytes) into pane \(pane.pane) on \(machine.label) as \(name)")
        if machine.isLocal {
            let folder = ImagePaste.localFolder
            let path = filePath(folder, name)
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: path))
            } catch {
                showTransferError("Paste image", machine, "Couldn't save the image: \(error.localizedDescription)")
                return true
            }
            terminal.pasteText(path)
            cleanUpPastes(in: folder, on: Self.localFiles)
            return true
        }
        // Remote: through a local file, so the upload shows in the transfer toast like any other.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clotho-paste-" + ImagePaste.newID())
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try png.write(to: staging.appendingPathComponent(name))
        } catch {
            showTransferError("Paste image on \(machine.label)", machine, "Couldn't stage the image: \(error.localizedDescription)")
            return true
        }
        uploadForPaste([staging.appendingPathComponent(name)], into: terminal, on: machine, title: "Uploading image…",
                       subfolder: false) { try? FileManager.default.removeItem(at: staging) }
        return true
    }

    /// Files dropped on a pane. On a remote pane where an agent runs they go to the paste folder (each drop in
    /// its own folder, so names can't clash) and their paths are typed, so the agent attaches them;
    /// otherwise they go to the pane's folder as before. (Option-drop types the local paths, unchanged.)
    func dropFiles(_ urls: [URL], on key: PaneKey) {
        guard let session = connections[key.machine], !session.machine.isLocal, paneRunsAgent(key),
              let terminal = paneHosts[key]?.terminal else {
            return upload(urls, toPane: key)
        }
        uploadForPaste(urls, into: terminal, on: session.machine,
                       title: urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)…" : "Uploading \(urls.count) items…",
                       subfolder: true, then: nil)
    }

    /// Uploads local files to the machine's paste folder and pastes their paths into the pane when done.
    private func uploadForPaste(_ urls: [URL], into terminal: PaneTerminalView, on machine: Machine, title: String,
                                subfolder: Bool, then cleanup: (() -> Void)?) {
        let files: FileBackend
        do {
            files = try fileBackend(for: machine)
        } catch {
            cleanup?()
            return showTransferError(title, machine, error.localizedDescription)
        }
        guard let home = files.homeDirectory else {
            cleanup?()
            return showTransferError(title, machine, "\(machine.label) didn't say where its home folder is.")
        }
        let root = ImagePaste.remoteFolder(home: home)
        let folder = subfolder ? filePath(root, ImagePaste.stamp(Date(), id: ImagePaste.newID())) : root
        Task { @MainActor [self] in
            do {
                _ = try await files.mkdir(folder, parents: true)
            } catch where error.fileErrorCode == .exists {
            } catch {
                cleanup?()
                return showTransferError(title, machine, "Couldn't create \(folder): \(error.localizedDescription)")
            }
            let sources = urls.map { Location(machine: .local, path: $0.path) }
            transfers.start(title: title, sources: sources, to: Location(machine: machine, path: folder)) { ok in
                cleanup?()
                // A failure stays in the toast; nothing is pasted.
                guard ok else { return }
                // Dropped files are followed by a space, as other terminals and Option-drop type them; an
                // image path alone is what agents turn into an attachment.
                let paths = urls.map { ImagePaste.typed(filePath(folder, $0.lastPathComponent)) }
                terminal.pasteText(paths.joined(separator: " ") + (subfolder ? " " : ""))
            }
            cleanUpPastes(in: root, on: files)
        }
    }

    /// Removes pastes older than a week, in the background; failures don't matter.
    func cleanUpPastes(in folder: String, on files: FileBackend) {
        Task.detached {
            guard let listing = try? await files.listAll(folder) else { return }
            for path in ImagePaste.expired(listing.entries, now: Date()) {
                try? await files.remove(path, recursive: true)
            }
        }
    }

    /// A failed row in the transfer toast.
    func showTransferError(_ title: String, _ machine: Machine, _ message: String) {
        log("paste failed on \(machine.label): \(message)")
        let failed = transfers.start(title: title, sources: [], to: Location(machine: machine, path: "~"))
        failed.state = .failed(message)
        failed.detail = message
        transferToast.refresh()
    }
}
