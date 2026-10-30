import ClothoKit
import Foundation
import UniformTypeIdentifiers

// The file browser's ordering and filter. Clicking a column's header sorts by it and clicking again
// reverses it; folders always stay first, whichever way. Each side of the browser remembers its own
// sort. The filter keeps the current folder's entries whose name contains the typed text, ignoring
// case (and diacritics), as you type.

struct FileSort: Equatable {
    enum Column: String, CaseIterable {
        case name, size, modified, kind
    }

    var column: Column = .name
    var ascending = true

    /// Folders first, then by the column (ties by name, so the order is stable); `ascending` false
    /// reverses within the folders and within the files.
    func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = compare(a, b)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            let byName = a.name.localizedStandardCompare(b.name)
            return ascending ? byName == .orderedAscending : byName == .orderedDescending
        }
    }

    private func compare(_ a: FileEntry, _ b: FileEntry) -> ComparisonResult {
        switch column {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .size:
            // Folders show no size; among themselves they go by name.
            if a.isDirectory && b.isDirectory { return .orderedSame }
            return a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
        case .modified: return a.mtime == b.mtime ? .orderedSame : a.mtime < b.mtime ? .orderedAscending : .orderedDescending
        case .kind: return Self.kind(of: a).localizedStandardCompare(Self.kind(of: b))
        }
    }

    /// What the Kind column says: "Folder", or the type's name from the extension ("PNG image").
    static func kind(of entry: FileEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription else {
            return "Document"
        }
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    // MARK: Saved, per side ("left" / "right")

    nonisolated(unsafe) static var store = UserDefaults.standard

    static func saved(for side: String) -> FileSort {
        guard let text = store.string(forKey: "FilesSort.\(side)") else { return FileSort() }
        let parts = text.split(separator: ":").map(String.init)
        guard let column = parts.first.flatMap(Column.init(rawValue:)) else { return FileSort() }
        return FileSort(column: column, ascending: parts.dropFirst().first != "desc")
    }

    func save(for side: String) {
        Self.store.set("\(column.rawValue):\(ascending ? "asc" : "desc")", forKey: "FilesSort.\(side)")
    }

    /// The entries whose names contain `text` (ignoring case and diacritics); all of them when it's blank.
    static func filter(_ entries: [FileEntry], by text: String) -> [FileEntry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
