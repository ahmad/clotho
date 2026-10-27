import ClothoKit
import Foundation
import Network
import UIKit

/// File access on a machine through its clothod (`fs.*`, protocol.md "Files"), or why there's none yet.
struct FileAccessError: LocalizedError {
    var message: String
    /// Still connecting: worth waiting for rather than showing as a failure.
    var isTransient = false
    var errorDescription: String? { message }
}

extension MachineConnection {
    func fileBackend() throws -> FileBackend {
        guard let files = store.backend as? FileBackend, let hello = store.hello, store.isConnected else {
            throw FileAccessError(message: "Connecting to \(machine.displayName)…", isTransient: true)
        }
        guard files.supportsFiles else {
            throw FileAccessError(message: "\(machine.displayName) runs clothod \(hello.version), which can't share files. "
                + "Update it to 0.1.3 or later from the machine's screen.")
        }
        return files
    }
}

/// Copies between this iPhone and machines, a few at a time, with progress. A transfer interrupted by a
/// dropped connection (the app suspended, a network change) waits for the machine to come back and retries;
/// FileTransfer resumes uploads from their part files and downloads from where they stopped. While anything
/// runs, the app asks iOS for background time and keeps those connections open.
@MainActor
final class TransferCenter: ObservableObject {
    static let shared = TransferCenter()

    enum Direction { case download, upload }

    enum State: Equatable {
        case running, waiting(String), done, failed(String), cancelled
        var isActive: Bool { if case .running = self { return true }; if case .waiting = self { return true }; return false }
    }

    final class Transfer: ObservableObject, Identifiable {
        let id = UUID()
        let machine: UUID
        let direction: Direction
        let title: String
        @Published var fraction: Double = 0
        @Published var state: State = .running
        /// Where a download landed, for sharing.
        var localItems: [URL] = []
        var task: Task<Void, Never>?

        init(machine: UUID, direction: Direction, title: String) {
            self.machine = machine
            self.direction = direction
            self.title = title
        }
    }

    @Published private(set) var transfers: [Transfer] = []
    /// A download finished and its files should be offered to the user (share sheet, Save to Files).
    var onDownloaded: ((Transfer) -> Void)?
    /// A machine has nothing left in flight; the app suspends its connection if it's in the background.
    var onIdle: ((UUID) -> Void)?

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let pathMonitor = NWPathMonitor()
    /// On cellular or a hotspot: smaller pieces, so terminals sharing the connection stay responsive.
    private(set) var constrained = false

    private init() {
        pathMonitor.pathUpdateHandler = { path in
            let constrained = path.isExpensive || path.isConstrained
            Task { @MainActor in TransferCenter.shared.constrained = constrained }
        }
        pathMonitor.start(queue: .main)
    }

    /// Downloads left from earlier launches, with any part files an abandoned copy kept.
    func removeOldDownloads() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads")
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }

    func isActive(on machine: UUID) -> Bool { transfers.contains { $0.machine == machine && $0.state.isActive } }

    var visible: [Transfer] { transfers.filter { $0.state != .cancelled } }

    /// Downloads `entries` from the machine into a fresh folder in the app's caches.
    func download(_ entries: [FileEntry], from connection: MachineConnection) {
        guard !entries.isEmpty else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transfer = Transfer(machine: connection.machine.id, direction: .download, title: Self.title(entries.map(\.name)))
        transfer.localItems = entries.map { folder.appendingPathComponent($0.name) }
        start(transfer, connection: connection) { remote in
            FileTransfer(from: remote, to: LocalFileBackend()).configured(constrained: self.constrained)
        } copy: { transfer, progress in
            try await transfer.copy(entries.map(\.path), into: folder.path, conflict: .replace, progress: progress)
        }
    }

    /// Uploads local files (from the document picker or Photos) into `directory` on the machine.
    /// `release` runs when it's over, to end security-scoped access or delete temporary copies; `finished`
    /// then says whether everything arrived.
    func upload(_ urls: [URL], into directory: String, on connection: MachineConnection, conflict: FileTransfer.Conflict,
                title: String? = nil, release: @escaping () -> Void = {}, finished: ((Bool) -> Void)? = nil) {
        guard !urls.isEmpty else { release(); finished?(false); return }
        let transfer = Transfer(machine: connection.machine.id, direction: .upload, title: title ?? Self.title(urls.map(\.lastPathComponent)))
        start(transfer, connection: connection, release: { release(); finished?(transfer.state == .done) }) { remote in
            FileTransfer(from: LocalFileBackend(), to: remote).configured(constrained: self.constrained)
        } copy: { transfer, progress in
            try await transfer.copy(urls.map(\.path), into: directory, conflict: conflict, progress: progress)
        }
    }

    /// A transfer that failed before it could start, shown like any other failure.
    func fail(_ title: String, on connection: MachineConnection, _ message: String) {
        log("\(title) on \(connection.machine.displayName) failed: \(message)")
        let transfer = Transfer(machine: connection.machine.id, direction: .upload, title: title)
        transfer.state = .failed(message)
        transfers.removeAll { $0.state == .done }
        transfers.append(transfer)
    }

    func cancel(_ transfer: Transfer) {
        transfer.task?.cancel()
    }

    func dismiss(_ transfer: Transfer) {
        guard !transfer.state.isActive else { return }
        transfers.removeAll { $0.id == transfer.id }
    }

    private func start(_ transfer: Transfer, connection: MachineConnection, release: @escaping () -> Void = {},
                       make: @escaping (FileBackend) -> FileTransfer,
                       copy: @escaping (FileTransfer, @escaping @Sendable (FileTransfer.Progress) -> Void) async throws -> Void) {
        transfers.removeAll { $0.state == .done }
        transfers.append(transfer)
        beginBackgroundTime()
        transfer.task = Task {
            defer {
                release()
                self.finished(transfer)
            }
            var attempts = 0
            while true {
                do {
                    let remote = try await Self.waitForFiles(connection)
                    transfer.state = .running
                    try await copy(make(remote)) { progress in
                        Task { @MainActor in transfer.fraction = progress.fraction }
                    }
                    transfer.fraction = 1
                    transfer.state = .done
                    if transfer.direction == .download { onDownloaded?(transfer) }
                    return
                } catch is CancellationError {
                    transfer.state = .cancelled
                    return
                } catch {
                    if Task.isCancelled { transfer.state = .cancelled; return }
                    // A file error (exists, no space, permission) won't fix itself; a lost connection will, and
                    // a source that changed mid-copy is copied again from the start.
                    attempts += 1
                    if (error.fileErrorCode != nil && error.fileErrorCode != .changed) || attempts > 5 {
                        transfer.state = .failed(error.localizedDescription)
                        return
                    }
                    log("transfer \(transfer.title): \(error.localizedDescription); retrying")
                    transfer.state = .waiting("Waiting for \(connection.machine.displayName)…")
                    try? await Task.sleep(nanoseconds: UInt64(attempts) * 1_000_000_000)
                }
            }
        }
    }

    /// The machine's file access, once its connection is up again (for up to five minutes).
    private static func waitForFiles(_ connection: MachineConnection) async throws -> FileBackend {
        for _ in 0..<600 {
            try Task.checkCancellation()
            do { return try connection.fileBackend() } catch let error as FileAccessError where error.isTransient {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return try connection.fileBackend()
    }

    private func finished(_ transfer: Transfer) {
        if !isActive(on: transfer.machine) { onIdle?(transfer.machine) }
        if !transfers.contains(where: { $0.state.isActive }) { endBackgroundTime() }
    }

    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "File transfers") { [weak self] in
            // Out of time: the connections close, and the transfers resume when the app comes back.
            MainActor.assumeIsolated {
                guard let self else { return }
                Set(self.transfers.filter { $0.state.isActive }.map(\.machine)).forEach { self.onIdle?($0) }
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func title(_ names: [String]) -> String {
        names.count == 1 ? names[0] : "\(names.count) items"
    }
}

private extension FileTransfer {
    func configured(constrained: Bool) -> FileTransfer {
        if constrained {
            chunk = 32 << 10
            window = 512 << 10
            maxStreams = 2
        }
        return self
    }
}
