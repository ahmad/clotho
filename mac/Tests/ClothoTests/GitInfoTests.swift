import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Git info in the four places: the tab bar's suffix (never moving tab widths), the sidebar's branch, the
/// pane's strip (room kept whether focused or not; the PR opens on GitHub only), and ⌘P's search.
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

    func testTabSuffixKeepsWidths() throws {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        window.contentView!.addSubview(bar)
        let tabs: [(id: TabID, title: String, custom: String?, maximized: Bool, badge: NSColor?)] = [(1, "zsh", nil, false, nil), (2, "vim", nil, false, nil)]
        bar.update(tabs: tabs, selected: 1)
        bar.layoutSubtreeIfNeeded()
        let plain = bar.tabFrames
        bar.update(tabs: tabs, selected: 1, gits: [1: git.short])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.tabFrames, plain, "the suffix never changes a tab's width")
        let items = bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem }
        XCTAssertEqual(items[0].gitSuffix?.stringValue, "fix-login · #42")
        XCTAssertNil(items[1].gitSuffix)
        let suffix = try XCTUnwrap(items[0].gitSuffix)
        XCTAssertLessThanOrEqual(items[0].label.frame.maxX, suffix.frame.minX, "the title ends before the suffix")
    }

    func testSidebarShowsTheBranch() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        window.contentView!.addSubview(sidebar)
        let workspaces = [Workspace(id: 1, name: "Platform", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100))])]
        sidebar.update(agents: [], unreachable: [], groups: [SidebarGroup(key: "local", title: "This Mac", status: (nil, nil), workspaces: workspaces,
                                                                         selected: 1, isConnected: true, isLocal: true, badges: [:], branches: [1: "main"])])
        sidebar.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(sidebar.workspaceRows(of: "local").first?.row as? WorkspaceRow)
        XCTAssertEqual(row.branch?.stringValue, "main")
        XCTAssertGreaterThanOrEqual(row.branch!.frame.minX, row.label.frame.maxX, "after the name")
        // Without the feature (no branches), no branch.
        sidebar.update(agents: [], unreachable: [], groups: [SidebarGroup(key: "local", title: "This Mac", status: (nil, nil), workspaces: workspaces,
                                                                         selected: 1, isConnected: true, isLocal: true, badges: [:])])
        XCTAssertNil((sidebar.workspaceRows(of: "local").first?.row as? WorkspaceRow)?.branch)
    }

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
