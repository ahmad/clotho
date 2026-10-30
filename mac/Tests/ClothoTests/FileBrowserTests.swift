import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The file browser: sorting by any column (folders first, reversed by a second click, remembered per
/// side), filtering by name, and copies between two other machines streamed through this Mac.
@MainActor
final class FileBrowserTests: XCTestCase {
    private var suite = ""
    private var savedSort: UserDefaults!
    private var savedMachines: UserDefaults!

    override func setUp() {
        _ = NSApplication.shared
        suite = TestDefaults.name("files")
        savedSort = FileSort.store
        savedMachines = Machine.store
        FileSort.store = UserDefaults(suiteName: suite)!
        Machine.store = FileSort.store
    }

    override func tearDown() {
        TestDefaults.remove(suite)
        FileSort.store = savedSort
        Machine.store = savedMachines
    }

    private func entry(_ name: String, dir: Bool = false, size: UInt64 = 0, mtime: Double = 0, hidden: Bool = false) -> FileEntry {
        FileEntry(name: name, path: "/x/\(name)", type: dir ? .dir : .file, size: size, mtime: mtime, mtimeNs: "0", mode: 0o644,
                  hidden: hidden)
    }

    private var sample: [FileEntry] {
        [entry("b.txt", size: 300, mtime: 30), entry("Zeta", dir: true, mtime: 5), entry("a.png", size: 100, mtime: 50),
         entry("alpha", dir: true, mtime: 9), entry("c.swift", size: 200, mtime: 10), entry("file10", size: 1), entry("file9", size: 1)]
    }

    func testSortsByEachColumnWithFoldersFirst() {
        let names = { (sort: FileSort) in sort.sorted(self.sample).map(\.name) }
        XCTAssertEqual(names(FileSort()), ["alpha", "Zeta", "a.png", "b.txt", "c.swift", "file9", "file10"], "Finder's order: case-blind, numbers by value")
        XCTAssertEqual(names(FileSort(column: .name, ascending: false)), ["Zeta", "alpha", "file10", "file9", "c.swift", "b.txt", "a.png"],
                       "reversed, folders still first")
        XCTAssertEqual(names(FileSort(column: .size)), ["alpha", "Zeta", "file9", "file10", "a.png", "c.swift", "b.txt"],
                       "ties by name; folders (no size) by name")
        XCTAssertEqual(names(FileSort(column: .size, ascending: false)).prefix(5), ["Zeta", "alpha", "b.txt", "c.swift", "a.png"])
        XCTAssertEqual(names(FileSort(column: .modified)), ["Zeta", "alpha", "file9", "file10", "c.swift", "b.txt", "a.png"])
        XCTAssertEqual(names(FileSort(column: .modified, ascending: false)).prefix(3), ["alpha", "Zeta", "a.png"])
        let byKind = FileSort(column: .kind).sorted(sample)
        XCTAssertEqual(byKind.prefix(2).map(\.name), ["alpha", "Zeta"])
        let kinds = byKind.dropFirst(2).map(FileSort.kind(of:))
        XCTAssertEqual(kinds, kinds.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "files grouped by kind")
        XCTAssertEqual(FileSort.kind(of: entry("dir", dir: true)), "Folder")
        XCTAssertEqual(FileSort.kind(of: entry("README")), "Document", "no extension")
    }

    func testSortIsRememberedPerSide() {
        XCTAssertEqual(FileSort.saved(for: "left"), FileSort(), "name, ascending by default")
        FileSort(column: .size, ascending: false).save(for: "left")
        FileSort(column: .modified).save(for: "right")
        XCTAssertEqual(FileSort.saved(for: "left"), FileSort(column: .size, ascending: false))
        XCTAssertEqual(FileSort.saved(for: "right"), FileSort(column: .modified))
        FileSort.store.set("bogus:desc", forKey: "FilesSort.left")
        XCTAssertEqual(FileSort.saved(for: "left"), FileSort())
    }

    func testFilterMatchesNamesIgnoringCase() {
        let names = { (text: String) in FileSort.filter(self.sample, by: text).map(\.name) }
        XCTAssertEqual(names("A"), ["Zeta", "a.png", "alpha"], "in the listing's order; the table sorts after")
        XCTAssertEqual(names("FILE1"), ["file10"])
        XCTAssertEqual(names("  "), sample.map(\.name), "blank keeps everything")
        XCTAssertEqual(names("café"), [])
        XCTAssertEqual(FileSort.filter([entry("Café.md")], by: "cafe").map(\.name), ["Café.md"], "accents don't matter")
    }

    func testPaneSortsOnHeaderClickAndFilters() throws {
        let app = AppDelegate()
        let pane = FilePane(app: app, machine: .local, path: "/x", choosable: true, side: "right")
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.show(sample + [entry(".hidden", hidden: true)], in: "/x")
        XCTAssertEqual(pane.shownNames.first, "alpha")
        XCTAssertEqual(pane.table.tableColumns.map(\.identifier.rawValue), ["name", "size", "modified", "kind"])
        XCTAssertTrue(pane.table.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil }, "every header sorts")

        // A header click sets the table's sort descriptors; the second reverses them.
        pane.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true)]
        XCTAssertEqual(pane.sort, FileSort(column: .size))
        XCTAssertEqual(pane.shownNames.suffix(1), ["b.txt"])
        pane.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        XCTAssertEqual(pane.shownNames.prefix(3), ["Zeta", "alpha", "b.txt"])
        XCTAssertEqual(FileSort.saved(for: "right"), FileSort(column: .size, ascending: false), "remembered for this side")
        XCTAssertEqual(FileSort.saved(for: "left"), FileSort(), "the other side keeps its own")

        pane.filterField.stringValue = "FILE"
        pane.filterChanged()
        XCTAssertEqual(pane.shownNames, ["file10", "file9"])
        XCTAssertEqual(pane.status.stringValue, "2 of 7 match “FILE”", "hidden files stay out")
        pane.filterField.stringValue = ""
        pane.filterChanged()
        XCTAssertEqual(pane.shownNames.count, 7)
        XCTAssertEqual(pane.status.stringValue, "7 items · 1 hidden")
    }

    func testVerbs() {
        let imac = Machine(id: "m", label: "imac", target: "macbook@imac"), big = Machine(id: "b", label: "devbox", target: "ahmad@devbox")
        XCTAssertEqual(Transfer.verb(from: .local, to: imac), "Upload")
        XCTAssertEqual(Transfer.verb(from: imac, to: .local, ing: true), "Downloading")
        XCTAssertEqual(Transfer.verb(from: big, to: imac, ing: true), "Copying", "remote to remote")
        XCTAssertEqual(Transfer.verb(from: imac, to: imac), "Copy")
        XCTAssertEqual(Transfer.verb(from: .local, to: imac, ing: true), "Uploading")
    }

    /// devbox → imac: read from one machine's files and write to the other's, through this Mac, with
    /// progress; neither side is this Mac.
    func testRemoteToRemoteCopyStreamsThroughTheApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clt-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("devbox"), to = root.appendingPathComponent("imac")
        try FileManager.default.createDirectory(at: from.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: from.appendingPathComponent("big.bin"))
        try Data("hi".utf8).write(to: from.appendingPathComponent("dir/note.txt"))

        let big = Machine(id: "b", label: "devbox", target: "ahmad@devbox"), imac = Machine(id: "m", label: "imac", target: "macbook@imac")
        let manager = TransferManager()
        var asked: [String] = []
        manager.files = { machine in
            asked.append(machine.label)
            XCTAssertFalse(machine.isLocal)
            return LocalFileBackend()
        }
        var updates = 0
        manager.onChange = { updates += 1 }
        let finished = expectation(description: "copied")
        var result: Bool?
        let transfer = manager.start(title: "Copying 2 items → imac", sources: [Location(machine: big, path: from.appendingPathComponent("big.bin").path),
                                                                                 Location(machine: big, path: from.appendingPathComponent("dir").path)],
                                     to: Location(machine: imac, path: to.path)) { ok in
            result = ok
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 20)
        XCTAssertEqual(result, true, transfer.detail)
        XCTAssertEqual(Set(asked), ["imac", "devbox"], "one side reads, the other writes")
        XCTAssertEqual(try Data(contentsOf: to.appendingPathComponent("big.bin")), payload)
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("dir/note.txt"), encoding: .utf8), "hi")
        XCTAssertEqual(transfer.progress, 1)
        XCTAssertGreaterThan(updates, 0)
    }

    func testRemoteToRemoteCopyCancels() async throws {
        let big = Machine(id: "b", label: "devbox", target: "ahmad@devbox"), imac = Machine(id: "m", label: "imac", target: "macbook@imac")
        let manager = TransferManager()
        manager.files = { _ in LocalFileBackend() }
        let finished = expectation(description: "ended")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clt-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("big.bin")
        try Data(count: 64 << 20).write(to: source)
        let transfer = manager.start(title: "Copying", sources: [Location(machine: big, path: source.path)],
                                     to: Location(machine: imac, path: root.appendingPathComponent("out").path)) { ok in
            XCTAssertFalse(ok)
            finished.fulfill()
        }
        manager.cancel(transfer)
        await fulfillment(of: [finished], timeout: 20)
        XCTAssertEqual(transfer.detail, "Cancelled")
    }
}

/// Machines switched off in Manage Machines: kept and listed there, but not used anywhere else.
@MainActor
final class MachineSwitchTests: XCTestCase {
    private var suite = ""
    private var saved: UserDefaults!

    override func setUp() {
        suite = TestDefaults.name("switch")
        saved = Machine.store
        Machine.store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        TestDefaults.remove(suite)
        Machine.store = saved
    }

    func testOffIsSavedAndKeptThroughEdits() throws {
        let imac = Machine.add(label: "imac", target: "macbook@imac"), big = Machine.add(label: "devbox", target: "ahmad@devbox")
        XCTAssertTrue(imac.isEnabled)
        Machine.setEnabled(try XCTUnwrap(imac.id), false)
        XCTAssertEqual(Machine.all().map(\.label), [Machine.local.label, "imac", "devbox"], "still listed in Manage Machines")
        XCTAssertEqual(Machine.all()[1].isEnabled, false)
        XCTAssertEqual(Machine.enabled().map(\.label), [Machine.local.label, "devbox"])
        let edited = Machine.update(try XCTUnwrap(imac.id), label: "iMac", target: "macbook@imac.tail")
        XCTAssertFalse(edited.isEnabled, "editing doesn't switch it on")
        XCTAssertFalse(Machine.all()[1].isEnabled)
        Machine.move(try XCTUnwrap(imac.id), to: 1)
        XCTAssertFalse(Machine.all()[2].isEnabled, "nor does moving it")
        Machine.setEnabled(try XCTUnwrap(imac.id), true)
        XCTAssertEqual(Machine.enabled().count, 3)
        _ = big
    }

    func testAppLeavesAnOffMachineAlone() throws {
        let imac = Machine.add(label: "imac", target: "nobody@imac.invalid")
        Machine.setEnabled(try XCTUnwrap(imac.id), false)
        let app = AppDelegate()
        XCTAssertTrue(app.remoteMachines.isEmpty, "not in the sidebar, Agents, ⌘P or the file browser's menu")
        app.connect(try XCTUnwrap(Machine.all().last))
        XCTAssertNil(app.connections[imac.key], "switched off: no connection, no ssh")
        XCTAssertEqual(MachinesSettingsController.detail(for: Machine.all().last!), "nobody@imac.invalid")
        XCTAssertFalse(Machine.all().last!.isEnabled, "listed in Settings › Machines as Off")
        XCTAssertFalse(Machine.local.isEditable, "this Mac has no switch")
    }

    /// Switching a machine off during a copy to it ends that copy as cancelled (the app used to quit:
    /// the transfer kept writing to the ssh it had just ended). Copies between other machines go on.
    func testSwitchingOffCancelsThatMachinesTransfers() async throws {
        let imac = Machine.add(label: "imac", target: "nobody@imac.invalid"), big = Machine.add(label: "devbox", target: "nobody@big.invalid")
        let manager = TransferManager()
        manager.files = { _ in LocalFileBackend() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clt-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("big.bin")
        try Data(count: 256 << 20).write(to: source)
        let toMini = expectation(description: "to imac ended"), toLocal = expectation(description: "to this Mac ended")
        var miniResult: Bool?, localResult: Bool?
        let copy = manager.start(title: "Copying", sources: [Location(machine: big, path: source.path)],
                                 to: Location(machine: imac, path: root.appendingPathComponent("a").path)) { ok in
            miniResult = ok
            toMini.fulfill()
        }
        let other = manager.start(title: "Downloading", sources: [Location(machine: big, path: source.path)],
                                  to: Location(machine: .local, path: root.appendingPathComponent("b").path)) { ok in
            localResult = ok
            toLocal.fulfill()
        }
        // What AppDelegate.setMachineEnabled does before it disconnects.
        manager.cancelAll(touching: imac)
        await fulfillment(of: [toMini], timeout: 20)
        XCTAssertEqual(miniResult, false)
        XCTAssertEqual(copy.detail, "Cancelled")
        await fulfillment(of: [toLocal], timeout: 60)
        XCTAssertEqual(localResult, true, "a copy that doesn't touch imac isn't cancelled: \(other.detail)")
    }
}
