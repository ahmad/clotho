import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The Changes list, its states' words, the diff rows and their tints, without a daemon.
@MainActor
final class ChangesViewTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() { window.close() }

    private let login = GitChangedFile(path: "clothod/src/a/very/long/path/that/does/not/fit/login.rs", status: .modified, added: 12, removed: 2)
    private let renamed = GitChangedFile(path: "src/auth.rs", oldPath: "src/session.rs", status: .renamed, added: 0, removed: 0)
    private let image = GitChangedFile(path: "logo.png", status: .added, binary: true)
    private let odd = GitChangedFile(path: "odd\u{1b}[31mname", status: .untracked, diffable: false)

    private var changes: GitChanges {
        GitChanges(root: "/repo", branch: "fix", head: "a1b2c3d",
                   uncommitted: .init(files: [login, renamed], total: 14, added: 12, removed: 2, truncated: true),
                   branchChanges: .init(base: "origin/main", commits: 4, files: [image, odd]))
    }

    /// Open in Editor's tooltip is about one file on one machine: the same path on another machine is asked
    /// about again, and gets its own answer.
    func testTheSamePathOnTwoMachinesIsAskedAboutTwice() async throws {
        let fake = FakeBackend(extraFeatures: ["git.changes"])
        try await fake.start()
        defer { fake.stop() }
        let file = GitChangedFile(path: "deploy", status: .modified, added: 1, removed: 0)
        let listed = GitChanges(root: "/srv/app", branch: "fix", head: "a1b2c3d", uncommitted: .init(files: [file], added: 1, removed: 0))
        let git = PaneGit(repo: "app", root: "/srv/app", branch: "fix", head: "a1b2c3d", changes: listed.summary)
        var panes: [PaneID] = []
        for name in ["here", "there"] {
            let created = try await fake.createWorkspace(name: name, spawn: SpawnOptions(command: ["/bin/sleep", "60"], cwd: "/tmp"))
            fake.setChanges(created.pane, .success(listed))
            panes.append(created.pane)
        }
        let model = ChangesModel()
        model.backend = { _ in fake }
        model.paneGit = { _, _ in (true, git) }
        model.isAppActive = { true }
        model.pollsByTimer = false
        let diff = ChangesDiffView(model: model)
        var asked: [String] = []
        diff.revealsInsteadOfOpening = { machine, path in
            asked.append("\(machine):\(path)")
            return machine == "local"
        }
        model.isVisible = true

        func show(machine: MachineKey, name: String, pane: PaneID) async throws {
            model.select(nil, group: .uncommitted)
            model.setFocused(ChangesModel.Target(machine: machine, machineName: name, pane: pane, git: git, featureOn: true, connected: true))
            try await ChangesFixture.wait("the list on \(name)") {
                guard model.target?.machine == machine, case .loaded = model.list else { return false }
                return true
            }
            model.select(file, group: .uncommitted)
            XCTAssertEqual(diff.fullPath, "/srv/app/deploy")
        }
        try await show(machine: "local", name: "this Mac", pane: panes[0])
        XCTAssertEqual(diff.openButton.toolTip, ChangesDiffView.revealTip)
        diff.update()
        XCTAssertEqual(asked, ["local:/srv/app/deploy"], "asked once per file, not on every update")

        try await show(machine: "devbox", name: "devbox", pane: panes[1])
        XCTAssertEqual(asked, ["local:/srv/app/deploy", "devbox:/srv/app/deploy"], "the same path there is another file")
        XCTAssertEqual(diff.openButton.toolTip, ChangesDiffView.openTip)
        XCTAssertEqual(diff.openButton.accessibilityHelp(), ChangesDiffView.openTip)

        try await show(machine: "local", name: "this Mac", pane: panes[0])
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(diff.openButton.toolTip, ChangesDiffView.revealTip)
    }

    func testRowsGroupsAndTheMoreRow() {
        let rows = ChangesListView.rows(for: changes)
        XCTAssertEqual(rows, [.group("Uncommitted", "14"), .file(login, .uncommitted), .file(renamed, .uncommitted), .more(12),
                              .group("On this branch", "4 commits · vs origin/main"), .file(image, .branch), .file(odd, .branch)])
        var none = changes
        none.branchChanges = nil
        none.branchReason = "no_base"
        XCTAssertFalse(ChangesListView.rows(for: none).contains { if case .group("On this branch", _) = $0 { true } else { false } }, "on the base branch: no group")
        none.branchReason = "no_merge_base"
        XCTAssertEqual(ChangesListView.rows(for: none).suffix(2), [.group("On this branch", ""), .note("This branch shares no history with the base branch.")])
        var one = changes
        one.branchChanges?.commits = 1
        XCTAssertTrue(ChangesListView.rows(for: one).contains(.group("On this branch", "1 commit · vs origin/main")))
    }

    func testAFileRowDrawsLetterPathAndCountsAsPlainText() throws {
        let cell = ChangedFileCell(login)
        XCTAssertEqual(cell.letter.stringValue, "M")
        XCTAssertEqual(cell.path.stringValue, login.path)
        XCTAssertEqual(cell.path.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cell.toolTip, login.path, "the whole path in the tooltip")
        XCTAssertEqual(cell.counts.attributedStringValue.string, "+12 \u{2212}2")
        XCTAssertEqual(cell.accessibilityLabel(), "Modified, \(login.path), 12 lines added, 2 removed")
        // At the inspector's least width the counts stay whole and the path gives way.
        cell.frame = NSRect(x: 0, y: 0, width: 220, height: ChangesListView.fileRowHeight)
        window.contentView!.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(cell.counts.frame.width, cell.counts.intrinsicContentSize.width - 0.5)
        XCTAssertLessThanOrEqual(cell.counts.frame.maxX, 220)
        XCTAssertLessThanOrEqual(cell.path.frame.maxX, cell.counts.frame.minX)

        let moved = ChangedFileCell(renamed)
        XCTAssertEqual(moved.letter.stringValue, "R")
        XCTAssertEqual(moved.toolTip, "src/session.rs → src/auth.rs")
        XCTAssertEqual(moved.counts.attributedStringValue.string, "+0")
        XCTAssertEqual(ChangedFileCell(image).counts.attributedStringValue.string, "bin")
        XCTAssertEqual(ChangedFileCell(image).accessibilityLabel(), "Added, logo.png, binary")
        let strange = ChangedFileCell(odd)
        XCTAssertEqual(strange.path.stringValue, "odd\u{241B}[31mname", "an escape sequence is shown, never run")
        XCTAssertLessThan(strange.alphaValue, 1, "dim: there is no diff behind it")
        XCTAssertTrue(strange.accessibilityLabel()?.hasSuffix("no diff available") == true)
        XCTAssertEqual(ChangedFileCell(GitChangedFile(path: "a", status: .modified)).counts.stringValue, "", "lines not counted: nothing")
        // Every status has its own letter, so colour is never the only sign.
        XCTAssertEqual(Set(GitChangedFile.Status.allCases.map(\.letter)).count, GitChangedFile.Status.allCases.count)
    }

    func testTheListSelectsOpensAndLeaves() throws {
        let list = ChangesListView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        window.contentView!.addSubview(list)
        var selected: [String?] = []
        var opened: [String] = []
        var left = 0
        list.onSelect = { file, _ in selected.append(file?.path) }
        list.onOpen = { file, group in opened.append("\(group.rawValue):\(file.path)") }
        list.onLeave = { left += 1 }
        list.show(changes, selection: nil)
        XCTAssertEqual(list.table.numberOfRows, 7)
        XCTAssertEqual(list.table.selectedRow, -1)
        XCTAssertTrue(selected.isEmpty, "showing a list selects nothing by itself")
        // Only files can be selected.
        XCTAssertFalse(list.tableView(list.table, shouldSelectRow: 0))
        XCTAssertTrue(list.tableView(list.table, shouldSelectRow: 1))
        XCTAssertFalse(list.tableView(list.table, shouldSelectRow: 3), "and N more")
        list.takeKeyboard()
        XCTAssertTrue(window.firstResponder === list.table)
        XCTAssertEqual(list.table.selectedRow, 1, "the first file")
        XCTAssertEqual(selected, [login.path])
        let key = { (code: UInt16) in
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber, context: nil,
                             characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
        }
        list.table.keyDown(with: key(36))
        XCTAssertEqual(opened, ["uncommitted:\(login.path)"], "Return opens the full diff")
        list.table.keyDown(with: key(53))
        XCTAssertEqual(left, 1, "Esc gives the keyboard back")
        // The model's selection is shown without echoing back.
        selected = []
        list.show(changes, selection: .init(group: .branch, path: "logo.png", oldPath: nil))
        XCTAssertEqual(list.table.selectedRow, 5)
        XCTAssertTrue(selected.isEmpty)
        list.show(changes, selection: nil)
        XCTAssertEqual(list.table.selectedRow, -1)
    }

    func testEveryStateHasItsWords() {
        let target = ChangesModel.Target(machine: "bb", machineName: "devbox", pane: 1, git: nil, featureOn: true, connected: true)
        func words(_ state: ChangesModel.ListState) -> String? { ChangesView.words(for: state, target: target)?.text }
        XCTAssertEqual(ChangesView.words(for: .none, target: nil)?.text, "No pane is focused.")
        XCTAssertEqual(words(.notARepo), "This pane isn't in a git repository.")
        XCTAssertEqual(words(.empty), "No changes")
        XCTAssertEqual(words(.loading), "Reading changes…")
        XCTAssertEqual(ChangesView.words(for: .loading, target: target)?.busy, true)
        XCTAssertEqual(ChangesView.words(for: .unknown(GitText.readingChanges, pending: true), target: target)?.busy, true)
        XCTAssertEqual(words(.failed("Not connected to devbox.")), "Not connected to devbox.")
        XCTAssertNil(ChangesView.words(for: .loaded(changes), target: target), "a list")
        for reason in ["pending", "no_git", "git_unsupported", "unsafe", "timeout", "too_large", "partial_clone", "error", "something new"] {
            let text = GitText.reason(reason, machine: "devbox")
            XCTAssertFalse(text.isEmpty, reason)
            XCTAssertFalse(text.contains("Session"), reason)
            XCTAssertEqual(words(.unknown(text, pending: reason == "pending")), text)
        }

        func diff(_ state: ChangesModel.DiffState) -> String? { DiffAreaView.words(for: state)?.text }
        XCTAssertEqual(diff(.loading), "Reading the diff…")
        XCTAssertEqual(diff(.undiffable), "Clotho can't show this file's diff: its name has characters it can't send.")
        XCTAssertEqual(diff(.loaded(GitDiff(path: "logo.png", status: .added, binary: true))), "Binary file: no text diff.")
        XCTAssertEqual(diff(.loaded(GitDiff(path: "src/auth.rs", oldPath: "src/session.rs", status: .renamed))), "Renamed from src/session.rs. No content changes.")
        XCTAssertEqual(diff(.failed("This file has no changes any more.")), "This file has no changes any more.")
        let lines = GitDiff(path: "a", status: .modified, hunks: [.init(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [.init(kind: .context, old: 1, new: 1, text: "x")])])
        XCTAssertNil(DiffAreaView.words(for: .loaded(lines)))
    }

    // MARK: The diff's rows

    private var diff: GitDiff {
        GitDiff(path: "src/login.rs", status: .modified, truncated: true, added: 2, removed: 1, hunks: [
            .init(oldStart: 10, oldLines: 3, newStart: 10, newLines: 4, header: "fn login() {", lines: [
                .init(kind: .context, old: 10, new: 10, text: "    let user = find(name);"),
                .init(kind: .removed, old: 11, text: "    check(user);"),
                .init(kind: .added, new: 11, text: "    let user = user?;\u{1b}[31m"),
                .init(kind: .added, new: 12, text: "    check(&user)?; \u{202E}evil", cut: true),
                .init(kind: .context, old: 12, new: 13, text: "}", noNewline: true),
            ]),
            .init(oldStart: 40, oldLines: 0, newStart: 41, newLines: 1, lines: [.init(kind: .added, new: 41, text: "")]),
        ])
    }

    func testUnifiedAndSideBySideRows() {
        let unified = DiffTableView.items(for: diff, mode: .unified)
        XCTAssertEqual(unified.count, 10, "two headers, six lines, the no-newline note, the truncated note")
        XCTAssertEqual(unified.first, .hunk("@@ \u{2212}10,3 +10,4 @@ fn login() {"))
        XCTAssertEqual(unified[6], .note("No newline at end of file"))
        XCTAssertEqual(unified[7], .hunk("@@ \u{2212}40,0 +41,1 @@"), "the ranges alone when git names no function")
        XCTAssertEqual(unified.last, .note("This diff is long: this is its first part."))
        let sideBySide = DiffTableView.items(for: diff, mode: .sideBySide)
        XCTAssertEqual(sideBySide.count, 9, "the removed line pairs with the first added one")
        guard case let .pair(pair) = sideBySide[2] else { return XCTFail("a pair") }
        XCTAssertEqual(pair.old?.old, 11)
        XCTAssertEqual(pair.new?.new, 11)
        guard case let .pair(lone) = sideBySide[3] else { return XCTFail("a pair") }
        XCTAssertNil(lone.old, "nothing on the old side")
        XCTAssertEqual(lone.new?.new, 12)
    }

    func testRowsShowTextPlainlyWithVisiblePlaceholders() throws {
        let table = DiffTableView(mode: .unified)
        table.frame = NSRect(x: 0, y: 0, width: 220, height: 300)
        window.contentView!.addSubview(table)
        table.show(diff)
        XCTAssertEqual(table.items.count, 10)
        XCTAssertEqual(table.table.numberOfRows, 10)
        let escaped = table.rowView(for: table.items[3])
        XCTAssertEqual(escaped.texts, ["11", "+", "    let user = user?;\u{241B}[31m"], "ESC as its picture")
        XCTAssertEqual(escaped.accessibilityLabel(), "added, line 11:     let user = user?;\u{241B}[31m")
        let bidi = table.rowView(for: table.items[4])
        XCTAssertEqual(bidi.texts.last, "    check(&user)?; <U+202E>evil …", "the override is shown, and the cut marked")
        let removed = table.rowView(for: table.items[2])
        XCTAssertEqual(removed.texts, ["11", "\u{2212}", "    check(user);"], "the old file's number, and the sign says it without colour")
        XCTAssertEqual(removed.accessibilityLabel(), "removed, line 11:     check(user);")
        // Side by side: old number and text, then new.
        let wide = DiffTableView(mode: .sideBySide)
        wide.show(diff)
        let pair = wide.rowView(for: wide.items[2])
        XCTAssertEqual(pair.texts, ["11", "\u{2212}", "    check(user);", "11", "+", "    let user = user?;\u{241B}[31m"])
        XCTAssertEqual(pair.accessibilityLabel(), "removed, line 11:     check(user);; added, line 11:     let user = user?;\u{241B}[31m")
        // Laid out at the inspector's least width, every row has a height and the text wraps inside it.
        table.layoutSubtreeIfNeeded()
        for row in 0..<table.table.numberOfRows { XCTAssertGreaterThan(table.table.rect(ofRow: row).height, 8, "row \(row)") }
    }

    func testALongDiffIsDrawnInPages() {
        let lines = (1...(DiffTableView.page + 500)).map { GitDiff.Line(kind: .added, new: $0, text: "line \($0)") }
        let long = GitDiff(path: "big.txt", status: .added, added: lines.count, hunks: [.init(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines)])
        let table = DiffTableView(mode: .unified)
        table.show(long)
        XCTAssertEqual(table.items.count, DiffTableView.page + 1)
        XCTAssertEqual(table.items.last, .more(501))
        XCTAssertEqual(table.rowView(for: .more(501)).texts, ["Show 501 more lines"])
    }

    /// Text stays readable on both tints, over the pane background and the hover grey, light and dark.
    func testTintsKeepTheTextReadable() {
        func blend(_ tint: UInt32, alpha: Double, over under: UInt32) -> UInt32 {
            func mix(_ shift: UInt32) -> UInt32 {
                let top = Double((tint >> shift) & 0xff), bottom = Double((under >> shift) & 0xff)
                return UInt32((top * alpha + bottom * (1 - alpha)).rounded()) << shift
            }
            return mix(16) | mix(8) | mix(0)
        }
        for appearance in ClothoPalette.Appearance.allCases {
            let palette = appearance == .dark ? ClothoPalette.dark : ClothoPalette.light
            for kind in [GitDiff.Line.Kind.added, .removed] {
                let tint = DiffTableView.tint(kind, for: appearance)!
                let row = blend(tint.hex, alpha: Double(tint.alpha), over: palette.background)
                XCTAssertGreaterThanOrEqual(ClothoPalette.contrast(palette.foreground, row), 4.5, "\(kind) \(appearance)")
                XCTAssertGreaterThan(ClothoPalette.contrast(row, palette.background), 1.1, "\(kind)'s tint shows, \(appearance)")
            }
            XCTAssertNil(DiffTableView.tint(.context, for: appearance))
        }
    }
}
