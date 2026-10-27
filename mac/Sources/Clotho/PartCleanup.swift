import AppKit
import ClothoKit

// Unfinished uploads leave hidden part files next to their targets (`.<name>.clotho-part-<id>`, plus a
// `.source` note on this Mac), so a retry can resume. clothod deletes its own after 24 h, but only the
// next time something writes on that machine, and this Mac's never expire. So the app remembers where
// transfers failed or were cancelled, and later removes part files there that are older than a day,
// best effort, on any machine it can reach.

enum PartCleanup {
    /// Same as clothod's: younger part files may still be resumed by copying again.
    static let age: TimeInterval = 24 * 3600
    /// How much of a destination tree one sweep looks at.
    static let maxEntries = 20_000

    static func isPartFile(_ name: String) -> Bool {
        name.hasPrefix(".") && name.contains(".clotho-part-")
    }

    /// Part files (and their source notes) in a listing that are old enough to remove.
    static func expired(_ entries: [FileEntry], now: Date) -> [String] {
        let cutoff = now.timeIntervalSince1970 - age
        return entries.filter { $0.type == .file && isPartFile($0.name) && $0.mtime < cutoff }.map(\.path)
    }

    /// Remembered destinations, as "machine key \n folder".
    static let defaultsKey = "UnfinishedTransfers"

    static func encode(_ machine: MachineKey, _ folder: String) -> String { machine + "\n" + folder }

    static func decode(_ value: String) -> (machine: MachineKey, folder: String)? {
        let parts = value.split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Walks a folder tree (directories only, without following links) up to `maxEntries` entries and
    /// removes expired part files. Returns whether the folder now holds none, young or old, so it can be
    /// forgotten; a folder that's gone counts as clean.
    static func sweep(_ folder: String, on files: FileBackend, now: Date = Date()) async -> Bool {
        var queue = [folder]
        var seen = 0
        var remaining = 0
        while let directory = queue.first, seen < maxEntries {
            queue.removeFirst()
            let listing: (dir: FileEntry, entries: [FileEntry])
            do {
                listing = try await files.listAll(directory)
            } catch {
                // Gone counts as clean; anything else (no connection, no permission) means try again later.
                if directory == folder { return error.fileErrorCode == .notFound }
                remaining += 1
                continue
            }
            seen += listing.entries.count
            let expired = Set(expired(listing.entries, now: now))
            for path in expired { try? await files.remove(path, recursive: false) }
            remaining += listing.entries.filter { isPartFile($0.name) && !expired.contains($0.path) }.count
            queue += listing.entries.filter { $0.type == .dir && !$0.link }.map(\.path)
        }
        return remaining == 0 && queue.isEmpty
    }
}

extension AppDelegate {
    /// Remembers where a transfer that didn't finish was writing.
    func noteUnfinishedTransfer(to destination: Location) {
        var list = UserDefaults.standard.stringArray(forKey: PartCleanup.defaultsKey) ?? []
        let entry = PartCleanup.encode(destination.machine.key, destination.path)
        guard !list.contains(entry) else { return }
        list.append(entry)
        UserDefaults.standard.set(Array(list.suffix(200)), forKey: PartCleanup.defaultsKey)
        log("parts: remembering \(destination.machine.label):\(destination.path) for cleanup")
    }

    /// Sweeps every remembered destination on machines that are connected now, and forgets the clean ones.
    func cleanUpPartFiles() {
        let list = UserDefaults.standard.stringArray(forKey: PartCleanup.defaultsKey) ?? []
        guard !list.isEmpty else { return }
        var work: [(entry: String, folder: String, files: FileBackend)] = []
        for entry in list {
            guard let (key, folder) = PartCleanup.decode(entry) else { continue }
            let machine = key == Self.localKey ? Machine.local : connections[key]?.machine
            guard let machine, let files = try? fileBackend(for: machine) else { continue }
            work.append((entry, folder, files))
        }
        guard !work.isEmpty else { return }
        Task { @MainActor in
            var clean: Set<String> = []
            for item in work where await PartCleanup.sweep(item.folder, on: item.files) {
                clean.insert(item.entry)
            }
            let now = UserDefaults.standard.stringArray(forKey: PartCleanup.defaultsKey) ?? []
            UserDefaults.standard.set(now.filter { !clean.contains($0) }, forKey: PartCleanup.defaultsKey)
            if !clean.isEmpty { log("parts: cleaned \(clean.count) of \(work.count) folders") }
        }
    }
}
