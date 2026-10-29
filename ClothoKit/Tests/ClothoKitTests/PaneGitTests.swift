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
}
