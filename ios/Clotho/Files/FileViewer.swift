import ClothoKit
import SwiftUI
import UniformTypeIdentifiers

/// One file on a machine: text to read and edit, an image to look at, or its details and a download.
struct FileViewer: View {
    let connection: MachineConnection
    @State private var entry: FileEntry
    @State private var content: Content = .loading
    @State private var text = ""
    @State private var savedText = ""
    @State private var saving = false
    @State private var conflict = false
    @State private var error: String?
    @ObservedObject private var transfers = TransferCenter.shared

    /// Larger files open as details only: reading them whole over SSH (and cellular) isn't a preview.
    static let textLimit: UInt64 = 2 << 20
    static let imageLimit: UInt64 = 32 << 20

    enum Content {
        case loading, text, image(UIImage), details(String?)
    }

    init(connection: MachineConnection, entry: FileEntry) {
        self.connection = connection
        _entry = State(initialValue: entry)
    }

    private var edited: Bool { text != savedText }

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .background(Color(Theme.background))
                    .accessibilityIdentifier("fileText")
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                }
            case .details(let note):
                details(note)
            }
        }
        .navigationTitle(entry.name + (edited ? " •" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(edited)
        .toolbar {
            if edited {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert") { text = savedText }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save(force: false) }.disabled(saving)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { transfers.download([entry], from: connection) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                        Button { UIPasteboard.general.string = entry.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                        Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    } label: {
                        Label("File actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { TransferBar(machine: connection.machine.id) }
        .task { await load() }
        .confirmationDialog("“\(entry.name)” changed on \(connection.machine.displayName) since you opened it.",
                            isPresented: $conflict, titleVisibility: .visible) {
            Button("Overwrite with mine", role: .destructive) { save(force: true) }
            Button("Discard mine and reload") { Task { await load() } }
        }
        .alert("Clotho", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func details(_ note: String?) -> some View {
        List {
            Section {
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                LabeledContent("Modified", value: entry.modified.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Permissions", value: String(entry.mode & 0o7777, radix: 8))
                if let target = entry.target { LabeledContent("Link to", value: target) }
                Text(entry.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            } footer: {
                if let note { Text(note) }
            }
            Section {
                Button { transfers.download([entry], from: connection) } label: { Label("Download", systemImage: "square.and.arrow.down") }
            }
        }
    }

    private func load() async {
        do {
            let files = try await FolderModel.backend(connection) { _ in }
            let stat = try await files.stat(entry.path)
            entry = stat
            let type = UTType(filenameExtension: (stat.name as NSString).pathExtension)
            if type?.conforms(to: .image) == true, stat.size <= Self.imageLimit {
                let data = try await Self.readAll(stat, files)
                content = UIImage(data: data).map(Content.image) ?? .details("Not an image this iPhone can show.")
            } else if stat.text == true, stat.size <= Self.textLimit {
                let data = try await Self.readAll(stat, files)
                guard let string = String(data: data, encoding: .utf8) else {
                    content = .details("Not UTF-8 text.")
                    return
                }
                text = string
                savedText = string
                content = .text
            } else if stat.text == true || type?.conforms(to: .image) == true {
                content = .details("Too large to preview here. Download it to open it.")
            } else {
                content = .details(nil)
            }
        } catch {
            content = .details(error.localizedDescription)
        }
    }

    private static func readAll(_ entry: FileEntry, _ files: FileBackend) async throws -> Data {
        let stream = try await files.read(entry.path, options: FileReadOptions(expectSize: entry.size, expectMtimeNs: entry.mtimeNs))
        var data = Data(capacity: Int(entry.size))
        for try await chunk in stream.data { data.append(chunk) }
        return data
    }

    /// Writes the text back atomically. Unless forced, only if nobody changed the file since it was loaded.
    private func save(force: Bool) {
        saving = true
        let data = Data(text.utf8), saved = text, entry = entry
        Task {
            defer { saving = false }
            do {
                let files = try connection.fileBackend()
                var options = FileWriteOptions(size: UInt64(data.count), overwrite: true)
                options.expectMtimeNs = force ? nil : entry.mtimeNs
                self.entry = try await files.write(entry.path, options: options, source: DataSource(data: data)) { _ in }
                savedText = saved
            } catch where error.fileErrorCode == .conflict {
                conflict = true
            } catch {
                self.error = "Saving failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Bytes in memory as a write's data.
struct DataSource: FileDataSource {
    let data: Data
    var size: UInt64 { UInt64(data.count) }
    var fingerprint: String { "\(data.count):\(data.hashValue)" }

    func open(at offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let rest = data.dropFirst(Int(offset))
        return AsyncThrowingStream { continuation in
            var start = rest.startIndex
            while start < rest.endIndex {
                let end = min(start + (64 << 10), rest.endIndex)
                continuation.yield(Data(rest[start..<end]))
                start = end
            }
            continuation.finish()
        }
    }
}
