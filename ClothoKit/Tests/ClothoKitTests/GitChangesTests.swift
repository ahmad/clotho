import ClothoFake
@testable import ClothoKit
import XCTest

/// `git.changes` and `git.diff` as clothod sends them (protocol.md, "Changes"), the side-by-side rows,
/// the text made safe to show, and the words for every reason and error.
final class GitChangesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// The `git.changes` example from docs/protocol.md, with the branch group's files filled in.
    static let changesJSON = """
    {"root": "/Users/me/Projects/clotho-fix", "branch": "fix-login", "head": "a1b2c3d",
     "uncommitted": {
       "files": [
         {"path": "src/login.rs", "status": "modified", "added": 12, "removed": 2, "binary": false, "diffable": true},
         {"path": "src/auth.rs", "old_path": "src/session.rs", "status": "renamed", "added": 0, "removed": 0, "binary": false, "diffable": true},
         {"path": "notes.txt", "status": "untracked", "added": 28, "removed": 0, "binary": false, "diffable": true}
       ],
       "total": 3, "added": 40, "removed": 2, "truncated": false
     },
     "branch_changes": {
       "base": "origin/main", "base_head": "9f8e7d6", "merge_base": "9f8e7d6", "commits": 4,
       "files": [{"path": "README.md", "status": "added", "added": 120, "removed": 0, "binary": false, "diffable": true}],
       "total": 7, "added": 120, "removed": 30, "truncated": true
     },
     "branch_reason": null}
    """

    /// The `git.diff` example from docs/protocol.md.
    static let diffJSON = """
    {"path": "src/login.rs", "old_path": null, "status": "modified", "binary": false,
     "truncated": false, "added": 2, "removed": 1,
     "hunks": [
       {"old_start": 10, "old_lines": 3, "new_start": 10, "new_lines": 4, "header": "fn login() {",
        "lines": [
          {"t": " ", "old": 10, "new": 10, "text": "    let user = find(name);"},
          {"t": "-", "old": 11, "new": null, "text": "    check(user);"},
          {"t": "+", "old": null, "new": 11, "text": "    let user = user?;"},
          {"t": "+", "old": null, "new": 12, "text": "    check(&user)?;"},
          {"t": " ", "old": 12, "new": 13, "text": "}"}
        ]}
     ]}
    """

    func testDecodesTheChangesExample() throws {
        let changes = try decode(GitChanges.self, Self.changesJSON)
        XCTAssertEqual(changes.root, "/Users/me/Projects/clotho-fix")
        XCTAssertEqual(changes.branch, "fix-login")
        XCTAssertEqual(changes.head, "a1b2c3d")
        XCTAssertEqual(changes.uncommitted.files.map(\.path), ["src/login.rs", "src/auth.rs", "notes.txt"])
        XCTAssertEqual(changes.uncommitted.files.map(\.status), [.modified, .renamed, .untracked])
        XCTAssertEqual(changes.uncommitted.files[0], GitChangedFile(path: "src/login.rs", status: .modified, added: 12, removed: 2))
        XCTAssertNil(changes.uncommitted.files[0].oldPath, "absent on anything but a rename")
        XCTAssertEqual(changes.uncommitted.files[1].oldPath, "src/session.rs")
        XCTAssertEqual(changes.uncommitted.files[1].name, "auth.rs")
        XCTAssertEqual(changes.uncommitted.total, 3)
        XCTAssertEqual(changes.uncommitted.added, 40)
        XCTAssertEqual(changes.uncommitted.removed, 2)
        XCTAssertFalse(changes.uncommitted.truncated)
        XCTAssertEqual(changes.uncommitted.more, 0)

        let branch = try XCTUnwrap(changes.branchChanges)
        XCTAssertEqual(branch.base, "origin/main")
        XCTAssertEqual(branch.baseHead, "9f8e7d6")
        XCTAssertEqual(branch.mergeBase, "9f8e7d6")
        XCTAssertEqual(branch.commits, 4)
        XCTAssertEqual(branch.total, 7)
        XCTAssertTrue(branch.truncated)
        XCTAssertEqual(branch.more, 6, "the list was cut: six more files than it shows")
        XCTAssertNil(changes.branchReason)

        // The list's totals are the pane's summary.
        XCTAssertEqual(changes.summary, PaneGit.Changes(
            uncommitted: PaneGit.Changes.Count(files: 3, added: 40, removed: 2),
            branch: PaneGit.Changes.BranchCount(base: "origin/main", commits: 4, files: 7, added: 120, removed: 30)))
        XCTAssertEqual(try decode(GitChanges.self, String(decoding: JSONEncoder().encode(changes), as: UTF8.self)), changes)
    }

    /// The reply's top-level `token` (feature `git.changes.token`, clothod 0.1.33), which `summary` carries.
    func testDecodesTheToken() throws {
        let without = try decode(GitChanges.self, Self.changesJSON)
        XCTAssertNil(without.token, "a daemon without the feature")
        XCTAssertNil(without.summary.token)

        let json = Self.changesJSON.replacingOccurrences(of: #""branch_reason": null}"#, with: #""branch_reason": null, "token": "9c1e5b0a77d2f431"}"#)
        XCTAssertNotEqual(json, Self.changesJSON)
        let with = try decode(GitChanges.self, json)
        XCTAssertEqual(with.token, "9c1e5b0a77d2f431")
        XCTAssertEqual(with.summary.token, "9c1e5b0a77d2f431", "the summary is the pane's, token included")
        XCTAssertEqual(with.summary.counts, without.summary, "and the same counts")
        XCTAssertNotEqual(with, without)
        XCTAssertEqual(try decode(GitChanges.self, String(decoding: JSONEncoder().encode(with), as: UTF8.self)).token, with.token)
        XCTAssertNil(GitChanges(root: "/r", uncommitted: .init(files: [])).token, "the init's default")
        XCTAssertEqual(GitChanges(root: "/r", uncommitted: .init(files: []), token: "t").summary.token, "t")
    }

    func testChangesWithoutABranchGroupAndOddFiles() throws {
        let changes = try decode(GitChanges.self, """
        {"root": "/repo", "branch": null, "head": null,
         "uncommitted": {"files": [
            {"path": "logo.png", "status": "modified", "added": null, "removed": null, "binary": true, "diffable": true},
            {"path": "bad\u{FFFD}name", "status": "added", "added": 1, "removed": 0, "binary": false, "diffable": false},
            {"path": "later", "status": "copied", "added": 1, "removed": 1, "binary": false, "diffable": true},
            {"path": "bare"}
          ], "total": 900, "added": null, "removed": null, "truncated": true},
         "branch_changes": null, "branch_reason": "no_merge_base", "future": 1}
        """)
        XCTAssertNil(changes.branch)
        XCTAssertNil(changes.branchChanges)
        XCTAssertEqual(changes.branchReason, "no_merge_base")
        let files = changes.uncommitted.files
        XCTAssertTrue(files[0].binary)
        XCTAssertNil(files[0].added, "a binary file's lines aren't counted")
        XCTAssertNil(files[0].removed)
        XCTAssertFalse(files[1].diffable, "its name can't be sent back")
        XCTAssertEqual(files[2].status, .modified, "an unknown status reads as modified")
        XCTAssertEqual(files[3], GitChangedFile(path: "bare", status: .modified), "missing fields take their defaults")
        XCTAssertTrue(changes.uncommitted.truncated)
        XCTAssertEqual(changes.uncommitted.more, 896)
        XCTAssertNil(changes.uncommitted.added)
        XCTAssertNil(changes.summary.branch)
        XCTAssertNil(changes.summary.reason, "no merge base isn't a failure")
        XCTAssertEqual(changes.summary.uncommitted, PaneGit.Changes.Count(files: 900))

        let failed = try decode(GitChanges.self, #"{"root": "/repo", "uncommitted": {"files": [], "total": 0, "truncated": false}, "branch_reason": "timeout"}"#)
        XCTAssertEqual(failed.summary.reason, "timeout")
        XCTAssertEqual(failed.uncommitted.more, 0)
    }

    func testStatusLettersAndWords() {
        XCTAssertEqual(GitChangedFile.Status.allCases.map(\.letter), ["A", "M", "D", "R", "U", "C"])
        XCTAssertEqual(GitChangedFile.Status.allCases.map(\.word), ["added", "modified", "deleted", "renamed", "untracked", "conflicted"])
    }

    func testDecodesTheDiffExample() throws {
        let diff = try decode(GitDiff.self, Self.diffJSON)
        XCTAssertEqual(diff.path, "src/login.rs")
        XCTAssertNil(diff.oldPath)
        XCTAssertEqual(diff.status, .modified)
        XCTAssertFalse(diff.binary)
        XCTAssertFalse(diff.truncated)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        let hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertEqual([hunk.oldStart, hunk.oldLines, hunk.newStart, hunk.newLines], [10, 3, 10, 4])
        XCTAssertEqual(hunk.header, "fn login() {")
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(hunk.lines[1], GitDiff.Line(kind: .removed, old: 11, new: nil, text: "    check(user);"))
        XCTAssertEqual(hunk.lines[2].new, 11)
        XCTAssertNil(hunk.lines[2].old)
        XCTAssertFalse(hunk.lines[0].noNewline, "absent is false")
        XCTAssertFalse(hunk.lines[0].cut)
        XCTAssertEqual(try decode(GitDiff.self, String(decoding: JSONEncoder().encode(diff), as: UTF8.self)), diff)
    }

    func testDiffLineMarksAndOddShapes() throws {
        let diff = try decode(GitDiff.self, """
        {"path": "big.txt", "old_path": "was.txt", "status": "moved", "binary": false, "truncated": true, "added": 2, "removed": 0,
         "hunks": [{"old_start": 0, "old_lines": 0, "new_start": 1, "new_lines": 2, "header": "",
           "lines": [{"t": "+", "old": null, "new": 1, "text": "long…", "cut": true},
                     {"t": "+", "old": null, "new": 2, "text": "end", "no_newline": true},
                     {"t": "?", "old": 3, "new": 3, "text": "what"}]}]}
        """)
        XCTAssertEqual(diff.oldPath, "was.txt")
        XCTAssertEqual(diff.status, .modified, "an unknown status")
        XCTAssertTrue(diff.truncated)
        let lines = try XCTUnwrap(diff.hunks.first).lines
        XCTAssertTrue(lines[0].cut)
        XCTAssertFalse(lines[0].noNewline)
        XCTAssertTrue(lines[1].noNewline)
        XCTAssertFalse(lines[1].cut)
        XCTAssertEqual(lines[2].kind, .context, "an unknown line type reads as unchanged")

        let binary = try decode(GitDiff.self, #"{"path": "logo.png", "old_path": null, "status": "modified", "binary": true, "truncated": false, "added": 0, "removed": 0, "hunks": []}"#)
        XCTAssertTrue(binary.binary)
        XCTAssertTrue(binary.hunks.isEmpty)
    }

    func testSideBySideRows() throws {
        func line(_ kind: GitDiff.Line.Kind, _ text: String) -> GitDiff.Line { GitDiff.Line(kind: kind, text: text) }
        func hunk(_ lines: [GitDiff.Line]) -> GitDiff.Hunk { GitDiff.Hunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 0, lines: lines) }
        func texts(_ rows: [GitDiff.Row]) -> [String] { rows.map { "\($0.old?.text ?? "") | \($0.new?.text ?? "")" } }

        // The protocol's example: one removed line beside the first of two added ones.
        let example = try XCTUnwrap(try decode(GitDiff.self, Self.diffJSON).hunks.first)
        let rows = example.sideBySideRows()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].old, rows[0].new, "an unchanged line sits on both sides")
        XCTAssertEqual(rows[1].old?.old, 11)
        XCTAssertEqual(rows[1].new?.new, 11)
        XCTAssertNil(rows[2].old, "the second added line has nothing beside it")
        XCTAssertEqual(rows[2].new?.new, 12)
        XCTAssertEqual(rows[3].old?.text, "}")

        // More removed than added: the leftovers have an empty right side.
        XCTAssertEqual(texts(hunk([line(.removed, "a"), line(.removed, "b"), line(.removed, "c"), line(.added, "A"), line(.context, "x")]).sideBySideRows()),
                       ["a | A", "b | ", "c | ", "x | x"])
        // Only added, only removed, and two changes with an unchanged line between them.
        XCTAssertEqual(texts(hunk([line(.added, "A"), line(.added, "B")]).sideBySideRows()), [" | A", " | B"])
        XCTAssertEqual(texts(hunk([line(.removed, "a")]).sideBySideRows()), ["a | "])
        XCTAssertEqual(texts(hunk([line(.removed, "a"), line(.added, "A"), line(.context, "x"), line(.removed, "b"), line(.added, "B")]).sideBySideRows()),
                       ["a | A", "x | x", "b | B"])
        // Added before removed (git never writes it so): not paired, nothing lost.
        XCTAssertEqual(texts(hunk([line(.added, "A"), line(.removed, "a")]).sideBySideRows()), [" | A", "a | "])
        XCTAssertTrue(hunk([]).sideBySideRows().isEmpty)
    }

    func testDisplayShowsWhatWouldHide() {
        XCTAssertEqual(DiffText.display("let x = 1"), "let x = 1")
        XCTAssertEqual(DiffText.display("\tindented"), "\tindented", "a tab stays")
        XCTAssertEqual(DiffText.display("\u{1B}[31mred\u{1B}[0m"), "\u{241B}[31mred\u{241B}[0m", "ESC is shown, so no sequence runs")
        XCTAssertEqual(DiffText.display("ding\u{07}"), "ding\u{2407}")
        XCTAssertEqual(DiffText.display("a\u{00}b\u{7F}c\r"), "a\u{2400}b\u{2421}c\u{240D}")
        XCTAssertEqual(DiffText.display("next\u{85}line"), "next<U+0085>line", "a C1 control")
        XCTAssertEqual(DiffText.display("user\u{202E}txt.exe"), "user<U+202E>txt.exe", "a right-to-left override can't reorder the name")
        XCTAssertEqual(DiffText.display("a\u{200E}b\u{200F}c\u{2066}d\u{2069}e\u{061C}f\u{FEFF}g"),
                       "a<U+200E>b<U+200F>c<U+2066>d<U+2069>e<U+061C>f<U+FEFF>g")
        XCTAssertEqual(DiffText.display("naïve café 日本語 🙂"), "naïve café 日本語 🙂", "other text is untouched")
        XCTAssertEqual(DiffText.display(""), "")
        for value in Array(0x00 ... 0x9F) + [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x061C, 0xFEFF] {
            guard value != 0x09, let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            let shown = DiffText.display(String(Character(scalar)))
            let changed = value < 0x20 || (0x7F ... 0x9F).contains(value) || value > 0x9F
            XCTAssertEqual(shown.unicodeScalars.contains(scalar), !changed, "U+\(String(value, radix: 16))")
        }
    }

    func testWorktreeLeftBehind() {
        let stays = "(the worktree /Users/me/Projects/clotho-fix-login on the new branch fix/login was created and is still there)"
        let spawn = BackendError(code: "spawn_failed", message: "spawning [\"nope\"]: No such file or directory (os error 2) \(stays)")
        let closed = BackendError(code: "not_found", message: "no workspace 4 \(stays)")
        let plain = BackendError(code: "not_found", message: "no workspace 4")
        XCTAssertTrue(spawn.worktreeLeftBehind)
        XCTAssertTrue(closed.worktreeLeftBehind)
        XCTAssertFalse(plain.worktreeLeftBehind, "nothing was made")
        XCTAssertFalse(BackendError(code: "worktree_exists", message: "/x already exists").worktreeLeftBehind)
        XCTAssertFalse((CancellationError() as Error).worktreeLeftBehind)
        XCTAssertEqual(spawn.gitErrorCode, .spawnFailed)
        XCTAssertEqual(closed.gitErrorCode, .notFound)
        XCTAssertNil(BackendError(code: "stale", message: "").gitErrorCode)
        XCTAssertEqual(Set(GitErrorCode.allCases.map(\.rawValue)), [
            "not_found", "not_a_repo", "no_git", "git_unsupported", "timeout", "git_failed", "bad_request", "bad_path", "not_changed",
            "worktree_unsupported", "worktree_name", "worktree_exists", "branch_exists", "bad_base", "spawn_failed",
        ])

        XCTAssertEqual(GitText.worktreeError(spawn),
                       "The worktree was created and is still there (/Users/me/Projects/clotho-fix-login), but its Tab couldn't be opened: "
                           + "spawning [\"nope\"]: No such file or directory (os error 2).")
        XCTAssertEqual(GitText.worktreeError(closed),
                       "The worktree was created and is still there (/Users/me/Projects/clotho-fix-login), but its Tab couldn't be opened: no workspace 4.")
        XCTAssertFalse(GitText.worktreeError(plain).contains("still there"))
        // A path with spaces, and a message without the daemon's form.
        let spaced = BackendError(code: "spawn_failed", message: "no shell (the worktree /tmp/my repo-a on the new branch a was created and is still there)")
        XCTAssertTrue(GitText.worktreeError(spaced).contains("(/tmp/my repo-a)"))
        XCTAssertEqual(GitText.worktreeError(BackendError(code: "spawn_failed", message: "holder did not answer")),
                       "The worktree was created and is still there, but its Tab couldn't be opened: holder did not answer.")
    }

    func testTheWordsForEveryReasonAndError() {
        var all: [String] = [GitText.readingChanges, GitText.unreadable]
        for reason in ["pending", "no_git", "git_unsupported", "unsafe", "timeout", "too_large", "partial_clone", "error", "new_reason", nil] {
            all.append(GitText.reason(reason, machine: "devbox"))
        }
        for reason in ["no_merge_base", "timeout", "too_large", "partial_clone", "error", "new_reason"] {
            all.append(GitText.branchReason(reason) ?? "")
        }
        let codes = GitErrorCode.allCases.map(\.rawValue) + ["disconnected", "internal", "unknown_method"]
        for code in codes {
            let error = BackendError(code: code, message: "nope is not a commit here")
            all.append(GitText.diffError(error, machine: "devbox"))
            all.append(GitText.worktreeError(error))
        }
        all.append(GitText.diffError(CancellationError(), machine: "devbox"))
        all.append(GitText.worktreeError(CancellationError()))
        for text in all {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("Session"), text)
            XCTAssertFalse(text.contains("session"), text)
            XCTAssertTrue(text.hasSuffix(".") || text.hasSuffix("…"), text)
            XCTAssertFalse(text.hasSuffix(".."), text)
        }

        XCTAssertEqual(GitText.reason("git_unsupported", machine: "devbox"),
                       "The git on devbox is older than 2.31, or this repository keeps its refs in a reftable.")
        XCTAssertEqual(GitText.reason("unsafe", machine: "devbox"), "Git refuses this repository because another user owns it.")
        XCTAssertEqual(GitText.reason("timeout", machine: "devbox"), "Git took too long in this repository.")
        XCTAssertEqual(GitText.reason("too_large", machine: "devbox"), "There are too many changed files to list.")
        XCTAssertEqual(GitText.reason("partial_clone", machine: "devbox"),
                       "This is a partial clone, and the comparison needs objects it doesn't have. Clotho never fetches them.")
        XCTAssertNil(GitText.branchReason(nil))
        XCTAssertNil(GitText.branchReason("no_base"), "on the base branch there is nothing to say")
        XCTAssertEqual(GitText.branchReason("no_merge_base"), "This branch shares no history with the base branch.")
        XCTAssertEqual(GitText.branchReason("timeout"), "Git took too long in this repository.")

        func diff(_ code: String) -> String { GitText.diffError(BackendError(code: code, message: "m"), machine: "this Mac") }
        XCTAssertEqual(diff("not_a_repo"), "This pane isn't in a git repository.")
        XCTAssertEqual(diff("not_changed"), "This file has no changes any more.")
        XCTAssertEqual(diff("bad_path"), "Clotho can't ask for this file by its name.")
        XCTAssertEqual(diff("disconnected"), "Not connected to this Mac.")
        XCTAssertEqual(diff("no_git"), "Git isn't installed on this Mac.")
        XCTAssertEqual(diff("git_failed"), "Couldn't read the changes.")

        func worktree(_ code: String, _ message: String) -> String { GitText.worktreeError(BackendError(code: code, message: message)) }
        XCTAssertEqual(worktree("worktree_exists", "/Users/me/Projects/clotho-fix already exists"),
                       "A file or folder is already there: /Users/me/Projects/clotho-fix already exists.")
        XCTAssertEqual(worktree("branch_exists", "the branch fix already exists"), "A branch with that name already exists.")
        XCTAssertEqual(worktree("worktree_name", "…"),
                       "A name is 1 to 100 letters, digits, '.', '_', '-' or '/', and must be a valid branch name.")
        XCTAssertEqual(worktree("bad_base", "nope is not a commit here"), "nope is not a commit here.")
        XCTAssertEqual(worktree("worktree_unsupported", "…"), "This repository has no main work tree to put a worktree beside.")
        XCTAssertEqual(worktree("git_failed", "fatal: could not lock\u{1B}[0m"), "Git couldn't make the worktree: fatal: could not lock\u{241B}[0m.",
                       "git's own message, with nothing invisible in it")
    }
}

/// FakeBackend's canned changes, diffs, worktrees and agent history, which the apps' tests and renders
/// are built on.
final class FakeBackendGitTests: XCTestCase {
    private func expect(_ code: String, _ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("\(what) succeeded")
        } catch {
            XCTAssertEqual((error as? BackendError)?.code, code, what)
        }
    }

    private func started(_ features: [String] = ["git.changes", "worktree"]) async throws -> (FakeBackend, CreatedWorkspace) {
        let fake = FakeBackend(extraFeatures: features)
        try await fake.start()
        let created = try await fake.createWorkspace(name: "git", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        return (fake, created)
    }

    func testCannedChangesAndDiffs() async throws {
        let (fake, created) = try await started()
        defer { fake.stop() }
        let session: SessionBackend = fake
        let pane = created.pane

        await expect("not_a_repo", "changes before any are set") { _ = try await session.gitChanges(pane, limit: nil) }
        await expect("not_found", "an unknown pane") { _ = try await session.gitChanges(9999, limit: nil) }

        let changes = try JSONDecoder().decode(GitChanges.self, from: Data(GitChangesTests.changesJSON.utf8))
        fake.setChanges(pane, .success(changes))
        fake.setGit(pane, PaneGit(repo: "clotho", root: changes.root, branch: changes.branch, head: changes.head, changes: changes.summary))
        let listed = try await session.gitChanges(pane, limit: 500)
        XCTAssertEqual(listed, changes)
        let state = try await fake.getState()
        XCTAssertEqual(state.pane(pane)?.git?.changes?.total.files, 10, "setGit carries the summary")

        let diff = try JSONDecoder().decode(GitDiff.self, from: Data(GitChangesTests.diffJSON.utf8))
        fake.setDiff(pane, path: "src/login.rs", group: .uncommitted, .success(diff))
        fake.setDiff(pane, path: "big.bin", group: .branch, .failure(BackendError(code: "timeout", message: "git took too long")))
        let got = try await session.gitDiff(pane, path: "src/login.rs", group: .uncommitted, oldPath: nil, context: 3)
        XCTAssertEqual(got, diff)
        await expect("not_changed", "the same file in the other group") {
            _ = try await session.gitDiff(pane, path: "src/login.rs", group: .branch, oldPath: nil, context: nil)
        }
        await expect("timeout", "a canned error") { _ = try await session.gitDiff(pane, path: "big.bin", group: .branch, oldPath: "old.bin", context: nil) }
        await expect("not_found", "an unknown pane") { _ = try await session.gitDiff(9999, path: "a", group: .branch, oldPath: nil, context: nil) }

        fake.setChanges(pane, .failure(BackendError(code: "git_failed", message: "fatal: bad object")))
        await expect("git_failed", "a canned error") { _ = try await session.gitChanges(pane, limit: nil) }

        XCTAssertEqual(fake.gitChangesCalls, [pane, 9999, pane, pane])
        XCTAssertEqual(fake.gitDiffRequests.map(\.path), ["src/login.rs", "src/login.rs", "big.bin", "a"])
        XCTAssertEqual(fake.gitDiffRequests[0], FakeBackend.DiffRequest(pane: pane, path: "src/login.rs", group: .uncommitted, oldPath: nil, context: 3))
        XCTAssertEqual(fake.gitDiffRequests[2].oldPath, "old.bin")
    }

    /// The fake's change token: on the list and on the pane together, moved on request, and a diff
    /// that answers `not_changed`.
    func testChangeTokenAndNotChanged() async throws {
        let (fake, created) = try await started(["git.changes"])
        defer { fake.stop() }
        let pane = created.pane
        let collector = FakeBackendTests.Collector()
        let reader = Task { for await event in fake.events { collector.add(event) } }
        defer { reader.cancel() }

        var changes = try JSONDecoder().decode(GitChanges.self, from: Data(GitChangesTests.changesJSON.utf8))
        changes.token = "1111111111111111"
        fake.setChanges(pane, .success(changes))
        fake.setGit(pane, PaneGit(repo: "clotho", root: changes.root, branch: changes.branch, head: changes.head, changes: changes.summary))
        var state = try await fake.getState()
        XCTAssertEqual(state.pane(pane)?.git?.changes?.token, "1111111111111111")
        var listed = try await fake.gitChanges(pane, limit: nil)
        XCTAssertEqual(listed.token, state.pane(pane)?.git?.changes?.token, "the list's token is the pane's")

        // Moved: a new token on both, the counts as they were, and a `pane` event.
        let moved = fake.moveChangesToken(pane)
        XCTAssertNotEqual(moved, "1111111111111111")
        XCTAssertEqual(moved.count, 16)
        state = try await fake.getState()
        listed = try await fake.gitChanges(pane, limit: nil)
        XCTAssertEqual(state.pane(pane)?.git?.changes?.token, moved)
        XCTAssertEqual(listed.token, moved)
        XCTAssertEqual(state.pane(pane)?.git?.changes?.counts, changes.summary.counts, "only the token moved")
        XCTAssertEqual(listed.uncommitted, changes.uncommitted)
        let deadline = Date().addingTimeInterval(5)
        func tokens() -> [String?] {
            collector.all.compactMap { event -> String?? in
                if case let .pane(found, _) = event, found.id == pane { return .some(found.git?.changes?.token) }
                return nil
            }
        }
        while tokens().last != .some(moved), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(tokens().last, .some(moved), "a pane event brings it")

        // Again, and to a token of the caller's.
        XCTAssertNotEqual(fake.moveChangesToken(pane), moved)
        XCTAssertEqual(fake.moveChangesToken(pane, to: "2222222222222222"), "2222222222222222")
        state = try await fake.getState()
        XCTAssertEqual(state.pane(pane)?.git?.changes?.token, "2222222222222222")
        // A pane with no changes set takes no harm.
        XCTAssertEqual(fake.moveChangesToken(9999, to: "x"), "x")

        // `not_changed` on request, for a file that had a diff.
        let diff = try JSONDecoder().decode(GitDiff.self, from: Data(GitChangesTests.diffJSON.utf8))
        fake.setDiff(pane, path: "src/login.rs", group: .uncommitted, .success(diff))
        let got = try await fake.gitDiff(pane, path: "src/login.rs", group: .uncommitted, oldPath: nil, context: nil)
        XCTAssertEqual(got, diff)
        fake.setDiffNotChanged(pane, path: "src/login.rs", group: .uncommitted)
        await expect("not_changed", "the file went back to what it was") {
            _ = try await fake.gitDiff(pane, path: "src/login.rs", group: .uncommitted, oldPath: nil, context: nil)
        }
    }

    func testGitDelay() async throws {
        let (fake, created) = try await started()
        defer { fake.stop() }
        fake.setChanges(created.pane, .success(GitChanges(root: "/repo", uncommitted: .init(files: []))))
        fake.gitDelay = 0.3
        let start = Date()
        _ = try await fake.gitChanges(created.pane, limit: nil)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
        let before = Date()
        await expect("not_changed", "a diff, after the delay too") {
            _ = try await fake.gitDiff(created.pane, path: "a", group: .uncommitted, oldPath: nil, context: nil)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(before), 0.25)
    }

    func testWorktreeTab() async throws {
        let (fake, created) = try await started()
        defer { fake.stop() }
        let session: SessionBackend = fake
        // The repository is the one the pane in that folder reports.
        fake.setGit(created.pane, PaneGit(repo: "clotho", root: "/Users/me/Projects/clotho", remote: "ahmad/clotho", branch: "main", head: "a1b2c3d"))
        let spawn = SpawnOptions(command: ["/bin/sh"], cwd: "/tmp")

        fake.worktreeDelay = 0.3
        let start = Date()
        let tab = try await session.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "fix/login", base: "origin/main"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "a checkout takes its time")
        XCTAssertEqual(tab.worktree, CreatedWorktree(path: "/Users/me/Projects/clotho-fix-login", branch: "fix/login", head: "a1b2c3d"))
        var state = try await fake.getState()
        XCTAssertEqual(state.workspace(created.workspace)?.tabs.map(\.id), [created.tab, tab.tab], "a normal Tab")
        XCTAssertEqual(state.focus.pane, tab.pane)
        let git = try XCTUnwrap(state.pane(tab.pane)?.git)
        XCTAssertEqual(git.repo, "clotho")
        XCTAssertEqual(git.root, "/Users/me/Projects/clotho-fix-login")
        XCTAssertEqual(git.branch, "fix/login")
        XCTAssertEqual(git.worktree, PaneGit.Worktree(name: "clotho-fix-login", path: "../clotho-fix-login"))
        XCTAssertEqual(git.changes?.isEmpty, true, "a fresh worktree: zeros, not nil")
        XCTAssertEqual(git.changes?.branch?.base, "origin/main")

        // An error: after the delay, and nothing is made.
        fake.worktreeDelay = 0.2
        fake.worktreeError = BackendError(code: "branch_exists", message: "the branch fix/login already exists")
        let before = Date()
        await expect("branch_exists", "the canned error") {
            _ = try await session.createTab(in: created.workspace, spawn: spawn, worktree: WorktreeRequest(name: "fix/login"))
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(before), 0.15)
        state = try await fake.getState()
        XCTAssertEqual(state.workspace(created.workspace)?.tabs.count, 2)

        fake.worktreeDelay = 0
        fake.worktreeError = nil
        await expect("bad_request", "no cwd") {
            _ = try await session.createTab(in: created.workspace, spawn: SpawnOptions(command: ["/bin/sh"]), worktree: WorktreeRequest(name: "x"))
        }
        await expect("not_found", "an unknown Workspace") {
            _ = try await session.createTab(in: 9999, spawn: spawn, worktree: WorktreeRequest(name: "x"))
        }
        // Without a pane to say which repository: the folder itself.
        let workspace = try await session.createWorkspace(name: "side", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/usr"),
                                                          worktree: WorktreeRequest(name: "try"))
        XCTAssertEqual(workspace.worktree?.path, "/usr-try")
        XCTAssertEqual(workspace.worktree?.branch, "try")
        XCTAssertEqual(fake.worktreeRequests.map(\.name), ["fix/login", "fix/login", "x", "try"])
    }

    func testAgentHistory() async throws {
        let (fake, created) = try await started(["agent.history"])
        defer { fake.stop() }
        let session: SessionBackend = fake
        let empty = try await session.agentHistory(created.pane, limit: nil, since: nil)
        XCTAssertEqual(empty.entries, [])
        let entries = [
            AgentHistoryEntry(at: 100, event: "state", kind: "claude", state: "running"),
            AgentHistoryEntry(at: 200, event: "update", kind: "claude", state: "running", message: "Reading the tests"),
            AgentHistoryEntry(at: 300, event: "state", kind: "claude", state: "done", from: "running"),
        ]
        fake.setAgentHistory(created.pane, entries)
        let all = try await session.agentHistory(created.pane, limit: nil, since: nil)
        XCTAssertEqual(all.pane, created.pane)
        XCTAssertEqual(all.entries, entries)
        let last = try await session.agentHistory(created.pane, limit: 2, since: nil)
        XCTAssertEqual(last.entries.map(\.at), [200, 300])
        let newer = try await session.agentHistory(created.pane, limit: nil, since: 200)
        XCTAssertEqual(newer.entries.map(\.at), [300])
        await expect("not_found", "an unknown pane") { _ = try await session.agentHistory(9999, limit: nil, since: nil) }
    }
}
