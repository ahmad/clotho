import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Git info lives in the pane's strip (room kept whether focused or not; the PR opens on GitHub only) and
/// in ⌘P's search; tab and workspace names carry none.
@MainActor
final class GitInfoTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() { window.close() }

    private let git = PaneGit(repo: "clotho", root: "/p/clotho-fix", remote: "ahmad/clotho", branch: "fix-login", head: "a1b2c3d",
                              worktree: .init(name: "fix-login", path: "../clotho-fix"),
                              pr: .init(number: 42, state: .open, url: "https://github.com/ahmad/clotho/pull/42", title: "Fix login"))

    func testStripKeepsItsRoomAndOpensOnlyGitHub() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        let deadline = Date().addingTimeInterval(5)
        while store.state.pane(created.pane) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let host = PaneHostView(pane: try XCTUnwrap(store.state.pane(created.pane)), store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let outside = host.fittedSize()
        let room = host.bounds.height - PaneHeader.height - PaneHostView.padding * 2
        XCTAssertEqual(outside.rows, Int(room / host.cellSize.height), "the rows under the header")

        host.git = git
        host.isFocusedPane = true
        host.layoutSubtreeIfNeeded()
        let strip = try XCTUnwrap(host.gitStrip)
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.summary.stringValue, "clotho · fix-login · fix-login")
        XCTAssertEqual(strip.frame.maxY, host.bounds.maxY, accuracy: 0.5, "at the bottom (the host is flipped)")
        let inRepo = host.fittedSize()
        XCTAssertLessThan(inRepo.rows, outside.rows, "room for the strip")
        XCTAssertEqual(inRepo.rows, Int((room - GitStrip.height) / host.cellSize.height), "less the header and the strip")
        host.isFocusedPane = false
        XCTAssertTrue(strip.isHidden, "only the focused pane shows it")
        XCTAssertEqual(host.fittedSize(), inRepo, "a focus change never resizes the shell")

        var opened: [URL] = []
        strip.open = { opened.append($0) }
        strip.pullRequest.performClick(nil)
        XCTAssertEqual(opened, [URL(string: "https://github.com/ahmad/clotho/pull/42")!])
        var other = git
        other.pr?.url = "file:///etc/passwd"
        host.git = other
        strip.pullRequest.performClick(nil)
        XCTAssertEqual(opened.count, 1, "only GitHub pages open")

        host.git = nil
        XCTAssertNil(host.gitStrip, "outside a repo, no strip")
        XCTAssertEqual(host.fittedSize(), outside)
    }

    /// The strip's change count: lines and files, files alone when the lines weren't counted, nothing
    /// when nothing changed; a click asks for the inspector; a narrow strip drops the files, then the count.
    func testStripShowsTheChangeCountAndGivesWayWhenNarrow() throws {
        let strip = GitStrip(frame: NSRect(x: 0, y: 0, width: 600, height: GitStrip.height))
        window.contentView!.addSubview(strip)
        var shown = 0
        strip.onShowChanges = { shown += 1 }
        func changes(_ files: Int, _ added: Int?, _ removed: Int?) -> PaneGit.Changes {
            PaneGit.Changes(uncommitted: .init(files: files, added: added, removed: removed))
        }
        var counted = git
        counted.changes = PaneGit.Changes(uncommitted: .init(files: 2, added: 14, removed: 5),
                                          branch: .init(base: "main", commits: 4, files: 4, added: 114, removed: 27))
        strip.show(counted)
        strip.layoutSubtreeIfNeeded()
        XCTAssertFalse(strip.changeCount.isHidden)
        XCTAssertEqual(strip.changeCount.attributedTitle.string, "+128 \u{2212}32 · 6 files", "both groups added up")
        XCTAssertEqual(strip.changeCount.accessibilityLabel(), "128 lines added, 32 removed, in 6 files. Show changes")
        XCTAssertEqual(strip.changeCount.accessibilityRole(), .button)
        XCTAssertEqual(strip.changeCount.frame.maxX, strip.bounds.maxX - s(10), accuracy: 0.5, "at the trailing edge")
        XCTAssertLessThanOrEqual(strip.pullRequest.frame.maxX, strip.changeCount.frame.minX - s(10) + 0.5, "the PR stays clear of it")
        XCTAssertEqual(strip.frame.height, GitStrip.height, "the strip is as tall as before")
        strip.changeCount.performClick(nil)
        XCTAssertEqual(shown, 1, "a click opens Changes")

        counted.changes = changes(1, 3, 0)
        strip.show(counted)
        XCTAssertEqual(strip.changeCount.attributedTitle.string, "+3 \u{2212}0 · 1 file")
        counted.changes = changes(6, nil, nil)
        strip.show(counted)
        XCTAssertEqual(strip.changeCount.attributedTitle.string, "6 files", "the lines weren't counted")
        XCTAssertEqual(strip.changeCount.accessibilityLabel(), "6 files changed. Show changes")
        counted.changes = changes(0, 0, 0)
        strip.show(counted)
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(strip.changeCount.isHidden, "nothing changed")
        strip.show(git)
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(strip.changeCount.isHidden, "a daemon that doesn't count sends no changes")

        // Narrow: the files go first, then the count; it never sits on the branch or the PR.
        counted.changes = changes(6, 128, 32)
        strip.show(counted)
        var forms: [GitStrip.CountForm] = []
        for width in stride(from: CGFloat(600), through: 60, by: -20) {
            strip.setFrameSize(NSSize(width: width, height: GitStrip.height))
            strip.layoutSubtreeIfNeeded()
            if forms.last != strip.countForm { forms.append(strip.countForm) }
            guard !strip.changeCount.isHidden else { continue }
            XCTAssertGreaterThanOrEqual(strip.changeCount.frame.minX, strip.icon.frame.maxX, "width \(width)")
            XCTAssertLessThanOrEqual(strip.changeCount.frame.maxX, strip.bounds.maxX, "width \(width)")
            if !strip.pullRequest.isHidden {
                XCTAssertLessThanOrEqual(strip.pullRequest.frame.maxX, strip.changeCount.frame.minX + 0.5, "width \(width)")
            }
            // With the PR beside it too, the branch keeps its few letters.
            XCTAssertFalse(strip.pullRequest.isHidden)
            XCTAssertGreaterThanOrEqual(strip.summary.frame.width, min(s(44), strip.summary.intrinsicContentSize.width) - 1,
                                        "the branch keeps its room, width \(width)")
        }
        XCTAssertEqual(forms, [.full, .linesOnly, .hidden])
    }

    /// Without a pull request the count sits beside the branch: the hidden PR takes no room and no gap,
    /// whether it never showed or showed and went.
    func testWithoutAPullRequestTheCountLeavesTheBranchItsRoom() throws {
        var counted = git
        counted.branch = "clothod/clear-alerts"
        counted.changes = PaneGit.Changes(uncommitted: .init(files: 6, added: 127, removed: 63))
        var plain = counted
        plain.pr = nil

        // Auto Layout ties alignment rects: a label's frame is a little wider than its text.
        func rect(_ view: NSView) -> NSRect { view.alignmentRect(forFrame: view.frame) }

        func sweep(_ strip: GitStrip, _ what: String) {
            var forms: [GitStrip.CountForm] = []
            for width in stride(from: CGFloat(600), through: 60, by: -10) {
                strip.setFrameSize(NSSize(width: width, height: GitStrip.height))
                strip.layoutSubtreeIfNeeded()
                if forms.last != strip.countForm { forms.append(strip.countForm) }
                XCTAssertTrue(strip.pullRequest.isHidden, what)
                let wanted = strip.summary.intrinsicContentSize.width
                guard !strip.changeCount.isHidden else {
                    // The count gone: the branch has the strip to its trailing edge, as before the count.
                    let room = strip.bounds.maxX - s(10) - rect(strip.summary).minX
                    XCTAssertGreaterThanOrEqual(rect(strip.summary).width, min(room, wanted) - 1, "\(what), width \(width)")
                    continue
                }
                XCTAssertGreaterThanOrEqual(rect(strip.summary).width, min(s(44), wanted) - 1,
                                            "the branch keeps its room, \(what), width \(width)")
                // Nothing but the gap stands between the branch and the count.
                let room = rect(strip.changeCount).minX - s(10) - rect(strip.summary).minX
                XCTAssertGreaterThanOrEqual(rect(strip.summary).width, min(room, wanted) - 1,
                                            "no blank gap where the PR would be, \(what), width \(width)")
                XCTAssertLessThanOrEqual(rect(strip.summary).maxX, rect(strip.changeCount).minX - s(10) + 0.5, "\(what), width \(width)")
            }
            XCTAssertEqual(forms, [.full, .linesOnly, .hidden], what)
        }

        let fresh = GitStrip(frame: NSRect(x: 0, y: 0, width: 600, height: GitStrip.height))
        window.contentView!.addSubview(fresh)
        fresh.show(plain)
        sweep(fresh, "no PR")

        let used = GitStrip(frame: NSRect(x: 0, y: 0, width: 600, height: GitStrip.height))
        window.contentView!.addSubview(used)
        used.show(counted)
        used.layoutSubtreeIfNeeded()
        XCTAssertFalse(used.pullRequest.isHidden)
        XCTAssertEqual(rect(used.pullRequest).minX, rect(used.summary).maxX + s(10), accuracy: 0.5, "the PR follows the branch")
        used.show(plain)
        sweep(used, "a PR shown, then gone")
        // And back: the PR returns to its place, clear of the count.
        used.setFrameSize(NSSize(width: 600, height: GitStrip.height))
        used.show(counted)
        used.layoutSubtreeIfNeeded()
        XCTAssertEqual(rect(used.pullRequest).minX, rect(used.summary).maxX + s(10), accuracy: 0.5)
        XCTAssertLessThanOrEqual(rect(used.pullRequest).maxX, rect(used.changeCount).minX - s(10) + 0.5)

        // No count and no PR: the branch runs to the trailing edge.
        var bare = plain
        bare.changes = nil
        bare.branch = String(repeating: "long-branch-name-", count: 20)
        used.setFrameSize(NSSize(width: 300, height: GitStrip.height))
        used.show(bare)
        used.layoutSubtreeIfNeeded()
        XCTAssertEqual(rect(used.summary).maxX, used.bounds.maxX - s(10), accuracy: 0.5)
    }

    func testCommandBarFindsByBranchWorktreeAndPR() {
        let tab = CommandBarEntry(item: QuickOpenItem(kind: .tab, title: "zsh", subtitle: "MacBook · Platform · \(git.searchText)", id: "tab|local|1"), tier: 2)
        let other = CommandBarEntry(item: QuickOpenItem(kind: .tab, title: "vim", subtitle: "MacBook · Platform", id: "tab|local|2"), tier: 2)
        for query in ["#42", "42", "fix-login", "fixlog"] {
            XCTAssertEqual(CommandBar.results(all: [tab, other], current: [], query: query).map(\.entry.item.id), ["tab|local|1"], query)
        }
    }
}
