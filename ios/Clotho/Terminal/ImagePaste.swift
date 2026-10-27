import ClothoKit
import UIKit

// Pasting images into agents (Claude Code, Codex). They read images from the clipboard of the machine they
// run on, which is never this phone's, and a terminal paste carries only text. So the app saves the image
// as a PNG on the pane's machine and pastes its path, which the agents attach. Same names, folder and
// lifetime as the Mac app (mac/Sources/Clotho/ImagePaste.swift).

enum ImagePaste {
    /// Text wins, as before; an image alone used to paste nothing.
    static func shouldPasteImage(hasText: Bool, hasImage: Bool) -> Bool { hasImage && !hasText }

    /// Where pastes go on a machine, from its home directory.
    static func remoteFolder(home: String) -> String {
        (home.hasSuffix("/") ? home : home + "/") + ".cache/clotho/paste"
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

    /// A path as typed into a shell or agent prompt: special characters escaped with a backslash.
    static func typed(_ path: String) -> String {
        let special = Set(" \t'\"\\()[]{}&;|<>*?$`!#")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// An image as PNG (the clipboard and Photos hand over PNG, JPEG or HEIC).
    static func png(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.pngData()
    }

    /// The clipboard's image as PNG.
    static func png(from pasteboard: UIPasteboard) -> Data? {
        if let png = pasteboard.data(forPasteboardType: "public.png") { return png }
        return pasteboard.image?.pngData()
    }
}

extension MachineConnection {
    /// Saves `png` in the machine's paste folder, with progress in the pane screen's transfer bar, and pastes
    /// its path into the pane once it's there (bracketed when the app asked). A failure shows in the bar and
    /// pastes nothing.
    func pasteImage(_ png: Data, into host: PaneHostView) {
        let title = "Uploading image…"
        let center = TransferCenter.shared
        let name = ImagePaste.imageName(Date(), id: ImagePaste.newID())
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("clotho-paste-" + ImagePaste.newID(), isDirectory: true)
        let file = staging.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            return center.fail(title, on: self, "Couldn't stage the image: \(error.localizedDescription)")
        }
        let removeStaging: () -> Void = { try? FileManager.default.removeItem(at: staging) }
        let files: FileBackend
        do {
            files = try fileBackend()
        } catch {
            removeStaging()
            return center.fail(title, on: self, error.localizedDescription)
        }
        guard let home = files.homeDirectory else {
            removeStaging()
            return center.fail(title, on: self, "\(machine.displayName) didn't say where its home folder is.")
        }
        let folder = ImagePaste.remoteFolder(home: home)
        log("paste: image (\(png.count) bytes) into pane \(host.paneID) on \(machine.displayName) as \(name)")
        Task { @MainActor in
            do {
                _ = try await files.mkdir(folder, parents: true)
            } catch where error.fileErrorCode == .exists {
            } catch {
                removeStaging()
                return center.fail(title, on: self, "Couldn't create \(folder): \(error.localizedDescription)")
            }
            center.upload([file], into: folder, on: self, conflict: .replace, title: title, release: removeStaging) { ok in
                // A failure stays in the bar; nothing is pasted.
                guard ok else { return }
                host.terminal.pasteText(ImagePaste.typed(folder + "/" + name))
            }
            Self.cleanUpPastes(in: folder, on: files)
        }
    }

    /// Removes pastes older than a week, in the background; failures don't matter.
    static func cleanUpPastes(in folder: String, on files: FileBackend) {
        Task.detached {
            guard let listing = try? await files.listAll(folder) else { return }
            for path in ImagePaste.expired(listing.entries, now: Date()) {
                try? await files.remove(path, recursive: true)
            }
        }
    }
}
