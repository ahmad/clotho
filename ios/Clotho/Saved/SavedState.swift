import ClothoKit
import Foundation
import SwiftUI

/// A pane's last screen, kept so the app can show it before the machine connects: escape sequences that
/// redraw it (text and colours) at the size it had.
struct SavedScreen: Codable, Equatable, Sendable {
    var cols: Int
    var rows: Int
    var ansi: String
    /// Where the cursor was, zero-based.
    var cursorCol: Int
    var cursorRow: Int
    var saved: Date
}

/// The phone's copy of each machine's last-known state (docs/ios-redesign.md, phase 1): the model
/// (ClothoKit's CachedMachineState: workspaces, tabs, panes, agents) and, unless "Keep pane previews" is
/// off, each pane's last screen. The app opens on it at once, dimmed and read-only until live.
///
/// Terminal text is sensitive: every file is written with complete file protection (encrypted by iOS and
/// unreadable while the phone is locked), and the folder is excluded from backups. Removing a machine
/// removes its copy.
@MainActor
final class SavedState {
    static let shared = SavedState()
    /// "Keep pane previews" in Settings; on unless turned off.
    static let keepPreviewsKey = "KeepPanePreviews"
    /// Screens kept per machine, most recent first.
    static let maxScreens = 60

    let root: URL
    private var machinesDir: URL { root.appendingPathComponent("machines", isDirectory: true) }
    private var screensDir: URL { root.appendingPathComponent("screens", isDirectory: true) }
    /// What was last written for each machine, so an unchanged model isn't written again.
    private var written: [UUID: CachedMachineState] = [:]
    private let defaults: UserDefaults

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saved", isDirectory: true)
        self.defaults = defaults
        prepare()
    }

    var keepPreviews: Bool {
        get { defaults.object(forKey: Self.keepPreviewsKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.keepPreviewsKey)
            if !newValue { deleteScreens() }
        }
    }

    // MARK: Models

    func load(_ machine: UUID) -> CachedMachineState? {
        guard let data = try? Data(contentsOf: modelURL(machine)),
              let cached = try? Self.decoder.decode(CachedMachineState.self, from: data),
              cached.format == CachedMachineState.currentFormat else { return nil }
        written[machine] = cached
        return cached
    }

    /// Writes the machine's model unless it's what was written last. Screens of panes that are gone go too.
    func save(_ cached: CachedMachineState, for machine: UUID) {
        guard written[machine] != cached else { return }
        guard write(try? Self.encoder.encode(cached), to: modelURL(machine)) else { return }
        written[machine] = cached
        prune(machine, keeping: Set(cached.state.panes.map(\.id)))
    }

    // MARK: Screens

    func screen(_ pane: PaneID, on machine: UUID) -> SavedScreen? {
        guard keepPreviews, let data = try? Data(contentsOf: screenURL(pane, machine)) else { return nil }
        return try? Self.decoder.decode(SavedScreen.self, from: data)
    }

    func hasScreen(_ pane: PaneID, on machine: UUID) -> Bool {
        keepPreviews && FileManager.default.fileExists(atPath: screenURL(pane, machine).path)
    }

    func saveScreen(_ screen: SavedScreen, pane: PaneID, on machine: UUID) {
        guard keepPreviews else { return }
        let dir = screensDir.appendingPathComponent(machine.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = write(try? Self.encoder.encode(screen), to: screenURL(pane, machine))
        trimScreens(machine)
    }

    /// "Keep pane previews" turned off: every saved screen goes at once.
    func deleteScreens() {
        try? FileManager.default.removeItem(at: screensDir)
        prepare()
    }

    /// The machine was removed from the app.
    func delete(_ machine: UUID) {
        written[machine] = nil
        try? FileManager.default.removeItem(at: modelURL(machine))
        try? FileManager.default.removeItem(at: screensDir.appendingPathComponent(machine.uuidString, isDirectory: true))
    }

    func deleteAll() {
        written.removeAll()
        try? FileManager.default.removeItem(at: root)
        prepare()
    }

    // MARK: Files

    private func modelURL(_ machine: UUID) -> URL {
        machinesDir.appendingPathComponent(machine.uuidString + ".json")
    }

    private func screenURL(_ pane: PaneID, _ machine: UUID) -> URL {
        screensDir.appendingPathComponent(machine.uuidString, isDirectory: true).appendingPathComponent("\(pane).json")
    }

    private func prepare() {
        let fm = FileManager.default
        for dir in [root, machinesDir, screensDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        }
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    @discardableResult
    private func write(_ data: Data?, to url: URL) -> Bool {
        guard let data else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            log("saved state: \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func prune(_ machine: UUID, keeping panes: Set<PaneID>) {
        let dir = screensDir.appendingPathComponent(machine.uuidString, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where PaneID(file.deletingPathExtension().lastPathComponent).map({ !panes.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func trimScreens(_ machine: UUID) {
        let dir = screensDir.appendingPathComponent(machine.uuidString, isDirectory: true)
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [key]),
              files.count > Self.maxScreens else { return }
        let byAge = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
            return a > b
        }
        byAge.dropFirst(Self.maxScreens).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// "Keep pane previews": on by default; turning it off deletes every saved screen at once. The model
/// (names, agents) is still kept, which is what opens the app instantly.
struct KeepPreviewsToggle: View {
    @AppStorage(SavedState.keepPreviewsKey) private var keep = true

    var body: some View {
        Toggle(isOn: $keep) {
            Label("Keep Pane Previews", systemImage: "rectangle.on.rectangle")
        }
        .onChange(of: keep) { _, on in SavedState.shared.keepPreviews = on }
        .accessibilityIdentifier("keepPanePreviews")
    }
}
