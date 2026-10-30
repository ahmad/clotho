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

        host.git = git
        host.isFocusedPane = true
        host.layoutSubtreeIfNeeded()
        let strip = try XCTUnwrap(host.gitStrip)
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.summary.stringValue, "clotho · fix-login · fix-login")
        XCTAssertEqual(strip.frame.maxY, host.bounds.maxY, accuracy: 0.5, "at the bottom (the host is flipped)")
        let inRepo = host.fittedSize()
        XCTAssertLessThan(inRepo.rows, outside.rows, "room for the strip")
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

    func testCommandBarFindsByBranchWorktreeAndPR() {
        let tab = CommandBarEntry(item: QuickOpenItem(kind: .tab, title: "zsh", subtitle: "MacBook · Platform · \(git.searchText)", id: "tab|local|1"), tier: 2)
        let other = CommandBarEntry(item: QuickOpenItem(kind: .tab, title: "vim", subtitle: "MacBook · Platform", id: "tab|local|2"), tier: 2)
        for query in ["#42", "42", "fix-login", "fixlog"] {
            XCTAssertEqual(CommandBar.results(all: [tab, other], current: [], query: query).map(\.entry.item.id), ["tab|local|1"], query)
        }
    }
}
