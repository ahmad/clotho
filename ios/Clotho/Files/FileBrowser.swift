import ClothoKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One folder on a machine, loaded a page at a time.
@MainActor
final class FolderModel: ObservableObject {
    let connection: MachineConnection
    /// Nil until the first listing says which folder "~" is.
    @Published private(set) var path: String
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var waiting: String?
    private var next: String?
    private var loaded = false

    init(connection: MachineConnection, path: String) {
        self.connection = connection
        self.path = path
    }

    var showHidden: Bool { UserDefaults.standard.bool(forKey: "FilesShowHidden") }
    var hasMore: Bool { next != nil }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        loading = true
        defer { loading = false }
        do {
            let files = try await Self.backend(connection) { self.waiting = $0 }
            waiting = nil
            let page = try await files.list(path, hidden: showHidden, limit: 500, cursor: nil)
            path = page.dir.path
            entries = Self.sorted(page.entries)
            next = page.next
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let cursor = next, !loading, let files = try? connection.fileBackend() else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await files.list(path, hidden: showHidden, limit: 500, cursor: cursor)
            entries += Self.sorted(page.entries)
            next = page.next
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Folders first, within each page (the machine pages by name).
    private static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter(\.isDirectory) + entries.filter { !$0.isDirectory }
    }

    /// Waits while the connection comes up, so opening the browser right after the app starts works.
    static func backend(_ connection: MachineConnection, waiting: (String) -> Void) async throws -> FileBackend {
        connection.connect()
        for _ in 0..<40 {
            do { return try connection.fileBackend() } catch let error as FileAccessError where error.isTransient {
                waiting(error.message)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return try connection.fileBackend()
    }

    func run(_ what: String, _ body: @escaping (FileBackend) async throws -> Void) {
        Task {
            do {
                try await body(try connection.fileBackend())
                await reload()
            } catch {
                self.error = "\(what) failed: \(error.localizedDescription)"
            }
        }
    }
}

/// A folder on a machine: tap a folder to open it, a file to view it. Everything else is in the row's
/// swipe and context menus and the one toolbar menu, to keep the screen to the files themselves.
struct FileBrowserView: View {
    @StateObject private var model: FolderModel
    @ObservedObject private var transfers = TransferCenter.shared
    @State private var renaming: FileEntry?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var deleting: FileEntry?
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pendingUpload: PendingUpload?
    @AppStorage("FilesShowHidden") private var showHidden = false

    init(connection: MachineConnection, path: String) {
        _model = StateObject(wrappedValue: FolderModel(connection: connection, path: path))
    }

    private var connection: MachineConnection { model.connection }

    /// The machine's home folder. Debug builds can start elsewhere (`-FilesStart <path>`), for tests.
    static func startPath(_ connection: MachineConnection) -> String {
        #if DEBUG
        if let start = UserDefaults.standard.string(forKey: "FilesStart") { return start }
        #endif
        return connection.store.hello?.machine?.home ?? "~"
    }

    var body: some View {
        pickers(dialogs(list))
    }

    private var list: some View {
        List {
            status
            ForEach(model.entries, id: \.path) { entry in
                row(entry)
                    .onAppear { if entry.path == model.entries.last?.path { Task { await model.loadMore() } } }
            }
            if model.hasMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(displayName(model.path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu { ancestors }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { folderMenu }
        }
        .safeAreaInset(edge: .bottom) { TransferBar(machine: connection.machine.id) }
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .onChange(of: showHidden) { Task { await model.reload() } }
        .onChange(of: transfers.transfers.map(\.state)) { _, _ in
            // An upload into this folder finished.
            Task { await model.reload() }
        }
    }

    @ViewBuilder private var status: some View {
        if let waiting = model.waiting, model.entries.isEmpty {
            ProgressView(waiting).frame(maxWidth: .infinity).listRowBackground(Color.clear)
        } else if let error = model.error, model.entries.isEmpty {
            ContentUnavailableView("Can't open folder", systemImage: "folder.badge.questionmark", description: Text(error))
                .listRowBackground(Color.clear)
        } else if model.entries.isEmpty, !model.loading {
            ContentUnavailableView("Empty folder", systemImage: "folder").listRowBackground(Color.clear)
        }
    }

    private func dialogs<V: View>(_ view: V) -> some View {
        view
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New folder", isPresented: $creatingFolder) {
                TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("This can't be undone.")
            }
            .confirmationDialog(pendingUpload?.title ?? "", isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { cancelPendingUpload() } }),
                                titleVisibility: .visible) {
                Button("Replace") { finishPendingUpload(.replace) }
                Button("Keep existing") { finishPendingUpload(.skip) }
            }
            .alert("Clotho", isPresented: Binding(get: { model.error != nil && !model.entries.isEmpty }, set: { if !$0 { model.error = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.error ?? "")
            }
    }

    private func pickers<V: View>(_ view: V) -> some View {
        view
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { upload(urls, scoped: true) }
            }
            .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                Task { upload(await PhotoExport.files(for: items), scoped: false, temporary: true) }
            }
    }

    @ViewBuilder private func row(_ entry: FileEntry) -> some View {
        let label = FileRow(entry: entry)
        Group {
            if entry.isDirectory {
                NavigationLink { FileBrowserView(connection: connection, path: entry.path) } label: { label }
            } else {
                NavigationLink { FileViewer(connection: connection, entry: entry) } label: { label }
            }
        }
        .accessibilityIdentifier("file:\(entry.name)")
        .swipeActions {
            Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
            Button { startRename(entry) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
        }
        .contextMenu {
            Button { transfers.download([entry], from: connection) } label: { Label("Download", systemImage: "square.and.arrow.down") }
            Button { startRename(entry) } label: { Label("Rename", systemImage: "pencil") }
            Button { UIPasteboard.general.string = entry.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var folderMenu: some View {
        Menu {
            Button { importing = true } label: { Label("Upload files", systemImage: "square.and.arrow.up") }
            Button { pickingPhotos = true } label: { Label("Upload photos", systemImage: "photo.on.rectangle") }
            Button { newName = ""; creatingFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
            Divider()
            Toggle(isOn: $showHidden) { Label("Show hidden files", systemImage: "eye") }
        } label: {
            Label("Folder actions", systemImage: "ellipsis.circle")
        }
        .disabled(model.error != nil && model.entries.isEmpty)
    }

    /// The folders above this one, from the title's menu.
    @ViewBuilder private var ancestors: some View {
        let parts = model.path.split(separator: "/").map(String.init)
        ForEach(Array(parts.indices.reversed().dropFirst()), id: \.self) { index in
            let path = "/" + parts[...index].joined(separator: "/")
            NavigationLink { FileBrowserView(connection: connection, path: path) } label: { Text(displayName(path)) }
        }
        NavigationLink { FileBrowserView(connection: connection, path: "/") } label: { Text("/") }
        Button { UIPasteboard.general.string = model.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
    }

    private func displayName(_ path: String) -> String {
        if path == "~" || path == connection.store.hello?.machine?.home { return "Home" }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    private var deleteTitle: String {
        guard let deleting else { return "" }
        return deleting.isDirectory ? "Delete “\(deleting.name)” and everything in it?" : "Delete “\(deleting.name)”?"
    }

    // MARK: Actions

    private func startRename(_ entry: FileEntry) {
        newName = entry.name
        renaming = entry
    }

    private func rename() {
        guard let entry = renaming, !newName.isEmpty, newName != entry.name, !newName.contains("/") else { return }
        let to = filePath((entry.path as NSString).deletingLastPathComponent, newName)
        model.run("Rename") { _ = try await $0.rename(entry.path, to: to, overwrite: false) }
    }

    private func createFolder() {
        guard !newName.isEmpty, !newName.contains("/") else { return }
        let path = filePath(model.path, newName)
        model.run("New folder") { _ = try await $0.mkdir(path, parents: false) }
    }

    private func delete() {
        guard let entry = deleting else { return }
        model.run("Delete") { try await $0.remove(entry.path, recursive: entry.isDirectory) }
    }

    // MARK: Uploads

    private struct PendingUpload {
        var urls: [URL]
        var existing: [String]
        var release: () -> Void
        var title: String { existing.count == 1 ? "“\(existing[0])” already exists here." : "\(existing.count) items already exist here." }
    }

    /// Asks first when anything of the same name is already in the folder.
    private func upload(_ urls: [URL], scoped: Bool, temporary: Bool = false) {
        guard !urls.isEmpty else { return }
        let accessed = scoped ? urls.filter { $0.startAccessingSecurityScopedResource() } : []
        let release = {
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
            if temporary { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        }
        let directory = model.path
        Task {
            let existing = (try? connection.fileBackend()).map { files in
                Task { await FileTransfer.existing(urls.map(\.lastPathComponent), in: directory, on: files) }
            }
            let clashes = await existing?.value ?? []
            if clashes.isEmpty {
                transfers.upload(urls, into: directory, on: connection, conflict: .skip, release: release)
            } else {
                pendingUpload = PendingUpload(urls: urls, existing: clashes, release: release)
            }
        }
    }

    private func finishPendingUpload(_ conflict: FileTransfer.Conflict) {
        guard let pending = pendingUpload else { return }
        pendingUpload = nil
        transfers.upload(pending.urls, into: model.path, on: connection, conflict: conflict, release: pending.release)
    }

    private func cancelPendingUpload() {
        pendingUpload?.release()
        pendingUpload = nil
    }
}

private struct FileRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(entry.hidden ? .secondary : .primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        let date = entry.modified.formatted(date: .abbreviated, time: .shortened)
        if entry.isDirectory { return date }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)) · \(date)"
    }

    private var icon: String {
        if entry.type == .other { return entry.link ? "link" : "questionmark.square.dashed" }
        if entry.isDirectory { return entry.link ? "folder.badge.gearshape" : "folder.fill" }
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .script) == true { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }
}

/// Transfers on one machine, above the folder's rows: progress, then a tap to cancel or dismiss.
struct TransferBar: View {
    let machine: UUID
    @ObservedObject private var center = TransferCenter.shared

    var body: some View {
        let items = center.visible.filter { $0.machine == machine }
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { TransferRow(transfer: $0) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var transfer: TransferCenter.Transfer
    private var center: TransferCenter { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.title).font(.caption).lineLimit(1).truncationMode(.middle)
                switch transfer.state {
                case .running: ProgressView(value: transfer.fraction).progressViewStyle(.linear)
                case .waiting(let why): Text(why).font(.caption2).foregroundStyle(.secondary)
                case .done: Text(transfer.direction == .upload ? "Uploaded" : "Downloaded").font(.caption2).foregroundStyle(.secondary)
                case .failed(let why): Text(why).font(.caption2).foregroundStyle(.red).lineLimit(2)
                case .cancelled: EmptyView()
                }
            }
            Spacer()
            Menu {
                if transfer.state.isActive {
                    Button("Cancel", role: .destructive) { center.cancel(transfer) }
                } else {
                    if transfer.direction == .download, transfer.state == .done {
                        Button("Share…") { center.onDownloaded?(transfer) }
                    }
                    Button("Dismiss") { center.dismiss(transfer) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .accessibilityLabel("Transfer actions")
        }
    }
}

/// Photos picked for upload, written to temporary files with their original names where Photos has them.
enum PhotoExport {
    static func files(for items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "dat"
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let url = folder.appendingPathComponent("Photo \(stamp)\(items.count > 1 ? "-\(index + 1)" : "").\(ext)")
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }
}
