@testable import ClothoKit
import XCTest

/// A pane's git info as clothod sends it (feature `git`), and the strings the apps show and search.
final class PaneGitTests: XCTestCase {
    private func decode(_ json: String) throws -> Pane {
        try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    }

    func testDecodesTheDaemonsShape() throws {
        let pane = try decode("""
        {"id": 3, "cols": 80, "rows": 24, "seq": 0, "git": {"repo": "clotho", "root": "/Users/a/Projects/clotho-fix",
         "remote": "ahmad/clotho", "branch": "fix-login", "head": "a1b2c3d",
         "worktree": {"name": "fix-login", "path": "../clotho-fix"},
         "pr": {"number": 42, "state": "draft", "draft": true, "url": "https://github.com/ahmad/clotho/pull/42", "title": "Fix login"},
         "pr_reason": null}}
        """)
        let git = try XCTUnwrap(pane.git)
        XCTAssertEqual(git.worktree, PaneGit.Worktree(name: "fix-login", path: "../clotho-fix"))
        XCTAssertEqual(git.pr?.state, .draft)
        XCTAssertEqual(git.short, "fix-login · #42")
        XCTAssertEqual(git.summary, "clotho · fix-login · fix-login")
        XCTAssertEqual(git.searchText, "fix-login fix-login #42")
        XCTAssertNil(try decode(#"{"id": 1, "cols": 80, "rows": 24, "seq": 0}"#).git, "outside a repo")
        XCTAssertNil(try decode(#"{"id": 1, "cols": 80, "rows": 24, "seq": 0, "git": null}"#).git)
    }

    func testDetachedUnknownStatesAndReasons() throws {
        let pane = try decode("""
        {"id": 3, "cols": 80, "rows": 24, "seq": 0, "git": {"repo": "clotho", "branch": null, "head": "a1b2c3d",
         "worktree": null, "pr": {"number": 7, "state": "queued"}, "pr_reason": "something_new"}}
        """)
        let git = try XCTUnwrap(pane.git)
        XCTAssertEqual(git.place, "@a1b2c3d", "detached shows the commit")
        XCTAssertNil(git.pr?.state, "an unknown state doesn't break decoding")
        XCTAssertEqual(git.prReason, "something_new")
        XCTAssertEqual(git.summary, "clotho · @a1b2c3d")
        // Round trip, as the cached model stores it.
        let again = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(again.git?.place, "@a1b2c3d")
    }

    // MARK: changes (feature `git.changes`, clothod 0.1.32)

    private typealias Branch = PaneGit.Changes.BranchCount

    private func gitWith(_ fields: String) throws -> PaneGit {
        let pane = try decode(#"{"id": 3, "cols": 80, "rows": 24, "seq": 0, "git": {"repo": "clotho", "branch": "fix-login", "head": "a1b2c3d", \#(fields)}}"#)
        return try XCTUnwrap(pane.git)
    }

    /// The example from docs/protocol.md ("Changes").
    func testDecodesChanges() throws {
        let git = try gitWith("""
        "changes": {"uncommitted": {"files": 3, "added": 40, "removed": 2},
                    "branch": {"base": "origin/main", "commits": 4, "files": 7, "added": 120, "removed": 30},
                    "reason": null},
        "changes_reason": null
        """)
        let changes = try XCTUnwrap(git.changes)
        XCTAssertEqual(changes.uncommitted, .init(files: 3, added: 40, removed: 2))
        XCTAssertEqual(changes.branch, PaneGit.Changes.BranchCount(base: "origin/main", commits: 4, files: 7, added: 120, removed: 30))
        XCTAssertNil(changes.reason)
        XCTAssertNil(git.changesReason)
        XCTAssertEqual(changes.total.files, 10)
        XCTAssertEqual(changes.total.added, 160)
        XCTAssertEqual(changes.total.removed, 32)
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(ChangeCountText.strip(changes), "+160 \u{2212}32 · 10 files")
        XCTAssertEqual(ChangeCountText.spoken(changes), "160 lines added, 32 removed, in 10 files")
        // Round trip, as the cached model stores it.
        XCTAssertEqual(try JSONDecoder().decode(PaneGit.self, from: JSONEncoder().encode(git)), git)
    }

    func testLinesNotCountedAndNoBranchGroup() throws {
        let uncounted = try XCTUnwrap(try gitWith("""
        "changes": {"uncommitted": {"files": 1200, "added": null, "removed": null},
                    "branch": {"base": "main", "commits": 1, "files": 2, "added": 5, "removed": 1}, "reason": null}
        """).changes)
        XCTAssertNil(uncounted.uncommitted.added)
        XCTAssertEqual(uncounted.total.files, 1202)
        XCTAssertNil(uncounted.total.added, "one group's lines weren't counted, so the sum isn't known")
        XCTAssertNil(uncounted.total.removed)
        XCTAssertEqual(ChangeCountText.strip(uncounted), "1202 files")
        XCTAssertEqual(ChangeCountText.spoken(uncounted), "1202 files changed")

        let failed = try XCTUnwrap(try gitWith(#""changes": {"uncommitted": {"files": 1, "added": 1, "removed": 0}, "branch": null, "reason": "timeout"}"#).changes)
        XCTAssertNil(failed.branch)
        XCTAssertEqual(failed.reason, "timeout")
        XCTAssertEqual(failed.total.files, 1)
        XCTAssertEqual(failed.total.added, 1)
        XCTAssertEqual(ChangeCountText.strip(failed), "+1 \u{2212}0 · 1 file")
        XCTAssertEqual(ChangeCountText.spoken(failed), "1 line added, 0 removed, in 1 file")
    }

    func testNoChangesAndEveryReason() throws {
        for reason in ["pending", "no_git", "git_unsupported", "unsafe", "timeout", "too_large", "partial_clone", "error", "something_new"] {
            let git = try gitWith(#""changes": null, "changes_reason": "\#(reason)""#)
            XCTAssertNil(git.changes, reason)
            XCTAssertEqual(git.changesReason, reason)
            XCTAssertNil(ChangeCountText.strip(git.changes))
            XCTAssertFalse(GitText.reason(reason, machine: "devbox").isEmpty)
        }
        XCTAssertEqual(GitText.reason("pending", machine: "devbox"), "Reading changes…")
        XCTAssertEqual(GitText.reason("no_git", machine: "devbox"), "Git isn't installed on devbox.")
        XCTAssertEqual(GitText.reason("something_new", machine: "devbox"), "Couldn't read the changes.")
        XCTAssertEqual(GitText.reason(nil, machine: "devbox"), "Couldn't read the changes.")
        // An older daemon sends neither field.
        let older = try gitWith(#""worktree": null"#)
        XCTAssertNil(older.changes)
        XCTAssertNil(older.changesReason)
    }

    /// A shape this client can't read is no changes, and never loses the pane or the rest of its git.
    func testMalformedChangesLeaveTheRestIntact() throws {
        for changes in [#""soon""#, "7", "[]", #"{"uncommitted": 3}"#, #"{"branch": {"base": "main"}}"#, #"{"uncommitted": {"files": "many"}}"#] {
            let git = try gitWith(#""worktree": {"name": "fix", "path": "../fix"}, "changes": \#(changes), "changes_reason": 5, "pr_reason": "none""#)
            XCTAssertNil(git.changes, changes)
            XCTAssertNil(git.changesReason, "a reason that isn't a string")
            XCTAssertEqual(git.branch, "fix-login")
            XCTAssertEqual(git.worktree?.name, "fix")
            XCTAssertEqual(git.prReason, "none")
        }
        // The whole state still decodes around it.
        let state = try JSONDecoder().decode(ModelState.self, from: Data("""
        {"rev": 1, "focus": {}, "workspaces": [], "panes": [
          {"id": 3, "cols": 80, "rows": 24, "seq": 0, "git": {"repo": "clotho", "branch": "main", "changes": {"uncommitted": []}}},
          {"id": 4, "cols": 80, "rows": 24, "seq": 0}]}
        """.utf8))
        XCTAssertEqual(state.panes.count, 2)
        XCTAssertEqual(state.pane(3)?.git?.repo, "clotho")
        XCTAssertNil(state.pane(3)?.git?.changes)
    }

    // MARK: the change token (feature `git.changes.token`, clothod 0.1.33)

    func testDecodesTheToken() throws {
        let git = try gitWith("""
        "changes": {"uncommitted": {"files": 3, "added": 40, "removed": 2},
                    "branch": {"base": "origin/main", "commits": 4, "files": 7, "added": 120, "removed": 30},
                    "reason": null, "token": "9c1e5b0a77d2f431"},
        "changes_reason": null
        """)
        let changes = try XCTUnwrap(git.changes)
        XCTAssertEqual(changes.token, "9c1e5b0a77d2f431")
        XCTAssertEqual(changes.uncommitted, PaneGit.Changes.Count(files: 3, added: 40, removed: 2))
        XCTAssertEqual(changes.branch?.files, 7)

        // A daemon without the feature: no token, and the rest as before.
        let older = try XCTUnwrap(try gitWith(#""changes": {"uncommitted": {"files": 3, "added": 40, "removed": 2}}"#).changes)
        XCTAssertNil(older.token)
        XCTAssertNil(try XCTUnwrap(try gitWith(#""changes": {"uncommitted": {"files": 1}, "token": null}"#).changes).token)
        XCTAssertNil(PaneGit.Changes(uncommitted: .init(files: 1)).token, "the init's default")

        // Round trip, as the cached model stores it.
        let again = try JSONDecoder().decode(PaneGit.Changes.self, from: JSONEncoder().encode(changes))
        XCTAssertEqual(again, changes)
        XCTAssertEqual(again.token, "9c1e5b0a77d2f431")
    }

    /// The token is part of `==` (a moved token is a change); `counts` is what is drawn, without it.
    func testCountsIgnoreTheToken() {
        let branch = Branch(base: "origin/main", commits: 3, files: 4, added: 100, removed: 30)
        let one = PaneGit.Changes(uncommitted: .init(files: 2, added: 28, removed: 2), branch: branch, token: "aaaaaaaaaaaaaaaa")
        let two = PaneGit.Changes(uncommitted: .init(files: 2, added: 28, removed: 2), branch: branch, token: "bbbbbbbbbbbbbbbb")
        let none = PaneGit.Changes(uncommitted: .init(files: 2, added: 28, removed: 2), branch: branch)
        XCTAssertNotEqual(one, two)
        XCTAssertNotEqual(one, none)
        XCTAssertEqual(one.counts, two.counts)
        XCTAssertEqual(one.counts, none)
        XCTAssertNil(one.counts.token)
        XCTAssertEqual(none.counts, none)
        XCTAssertEqual(ChangeCountText.strip(one), ChangeCountText.strip(two), "the same is drawn")
        let more = PaneGit.Changes(uncommitted: .init(files: 3, added: 28, removed: 2), branch: branch, token: "aaaaaaaaaaaaaaaa")
        XCTAssertNotEqual(one.counts, more.counts, "a count that differs still does")
    }

    func testTotalIsEmptyAndTheCountForms() {
        // A fresh worktree: a branch group of zeros, not nil.
        let fresh = PaneGit.Changes(uncommitted: .init(files: 0, added: 0, removed: 0),
                                    branch: Branch(base: "main", commits: 0, files: 0, added: 0, removed: 0))
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(fresh.total.files, 0)
        XCTAssertEqual(fresh.total.added, 0)
        XCTAssertNil(ChangeCountText.strip(fresh), "nothing to show at 0 files")
        XCTAssertNil(ChangeCountText.spoken(fresh))
        XCTAssertTrue(PaneGit.Changes(uncommitted: .init(files: 0)).isEmpty)
        XCTAssertFalse(PaneGit.Changes(uncommitted: .init(files: 0), branch: Branch(base: "main", commits: 1, files: 2)).isEmpty)
        XCTAssertFalse(PaneGit.Changes(uncommitted: .init(files: 1)).isEmpty)

        // The mockup's strip: 2 uncommitted and 4 on the branch.
        let both = PaneGit.Changes(uncommitted: .init(files: 2, added: 28, removed: 2),
                                   branch: Branch(base: "origin/main", commits: 3, files: 4, added: 100, removed: 30))
        XCTAssertEqual(ChangeCountText.strip(both), "+128 \u{2212}32 · 6 files")
        XCTAssertEqual(ChangeCountText.spoken(both), "128 lines added, 32 removed, in 6 files")

        XCTAssertEqual(ChangeCountText.files(1), "1 file")
        XCTAssertEqual(ChangeCountText.files(6), "6 files")
        XCTAssertEqual(ChangeCountText.files(0), "0 files")
        XCTAssertEqual(ChangeCountText.lines(added: 128, removed: 32), "+128 \u{2212}32")
        XCTAssertNil(ChangeCountText.lines(added: nil, removed: 3))
        XCTAssertNil(ChangeCountText.lines(added: nil, removed: nil))
        XCTAssertEqual(ChangeCountText.strip(PaneGit.Changes(uncommitted: .init(files: 1, added: 0, removed: 4))), "+0 \u{2212}4 · 1 file")
        XCTAssertEqual(ChangeCountText.strip(PaneGit.Changes(uncommitted: .init(files: 1))), "1 file")
        XCTAssertEqual(ChangeCountText.spoken(PaneGit.Changes(uncommitted: .init(files: 1))), "1 file changed")
        XCTAssertNil(ChangeCountText.strip(nil))
    }
}
