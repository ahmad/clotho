import ClothoKit
import SwiftUI
import XCTest
@testable import Clotho

/// The pane's git strip (clothod 0.1.23's `git`): what it says, which pull request links open, and renders of
/// each pull request state for review.
@MainActor
final class GitStripTests: XCTestCase {
    private func git(_ state: PaneGit.PullRequest.State?, url: String? = "https://github.com/example/clotho/pull/42") -> PaneGit {
        PaneGit(repo: "clotho", root: "/Users/user/Projects/clotho-ios", remote: "example/clotho", branch: "ios/git-strip",
                head: "a1b2c3d", worktree: .init(name: "clotho-ios", path: "../clotho-ios"),
                pr: .init(number: 42, state: state, url: url, title: "iPhone: git info under the pane"))
    }

    func testOnlyGitHubPullRequestsOpen() {
        XCTAssertEqual(GitStrip.url(of: git(.open).pr!)?.absoluteString, "https://github.com/example/clotho/pull/42")
        XCTAssertNil(GitStrip.url(of: git(.open, url: "http://github.com/example/clotho/pull/42").pr!))
        XCTAssertNil(GitStrip.url(of: git(.open, url: "https://github.com.evil.example/x").pr!))
        XCTAssertNil(GitStrip.url(of: git(.open, url: "javascript:alert(1)").pr!))
        XCTAssertNil(GitStrip.url(of: git(.open, url: nil).pr!))
    }

    func testSaysRepoBranchAndWorktree() {
        XCTAssertEqual(git(.open).summary, "clotho · ios/git-strip · clotho-ios")
        let detached = PaneGit(repo: "clotho", branch: nil, head: "a1b2c3d")
        XCTAssertEqual(detached.summary, "clotho · @a1b2c3d")
        XCTAssertEqual(GitStrip.describe(.merged).word, "merged")
        XCTAssertEqual(GitStrip.describe(nil).word, "")
    }

    func testRendersEachState() throws {
        let cases: [(String, PaneGit)] = [
            ("open", git(.open)), ("draft", git(.draft)), ("merged", git(.merged)), ("closed", git(.closed)),
            ("no pr", PaneGit(repo: "clotho", branch: "main", head: "a1b2c3d", prReason: "default_branch")),
            ("detached", PaneGit(repo: "clotho", branch: nil, head: "a1b2c3d", prReason: "detached")),
        ]
        for (name, git) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let view = GitStrip(git: git)
                    .frame(width: 390)
                    .background(Color(.systemBackground))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
                XCTAssertEqual(image.size.height, GitStrip.height, name)
                let shot = XCTAttachment(image: image)
                shot.name = "git strip \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    // The restored-pane note's three wordings (clothod 0.1.21 and 0.1.25), for review.
    func testRendersTheRestoredNote() throws {
        let cases: [(String, PaneRestore)] = [
            ("plain", PaneRestore(at: 0)),
            ("resumed", PaneRestore(at: 0, agent: "claude", session: "0d6f2c1e")),
            ("continued", PaneRestore(at: 0, agent: "claude", continued: true)),
        ]
        XCTAssertEqual(cases[0].1.note, "Restored after restart")
        XCTAssertEqual(cases[1].1.note, "Restored after restart · resumed Claude session")
        XCTAssertEqual(cases[2].1.note, "Continued the latest conversation in this folder")
        for (name, restore) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let view = RestoredNote(restore: restore) {}
                    .frame(width: 390, height: 80, alignment: .topTrailing)
                    .background(Color(scheme == .light ? .white : .black))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let shot = XCTAttachment(image: try XCTUnwrap(renderer.uiImage, name))
                shot.name = "restored note \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }
}
