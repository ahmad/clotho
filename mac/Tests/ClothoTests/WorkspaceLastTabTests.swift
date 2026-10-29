import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Going to a workspace (a sidebar click, or a workspace row in ⌘P) lands on its last active tab, the way
/// both go: `focusNow(.workspace)`, which shows the model's `active_tab` at once (LocalFocus) and sends the
/// focus to the daemon. When that tab has closed, it's the tab the daemon picked instead, else the first.
@MainActor
final class WorkspaceLastTabTests: XCTestCase {
    private let sleep = SpawnOptions(command: ["/bin/sleep", "30"])

    /// What `focusNow` does: the local focus at once, then the daemon's.
    private func go(_ store: ModelStore, _ target: FocusTarget) async throws {
        XCTAssertTrue(store.showFocus(target))
        try await store.sendFocus(target)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAWorkspaceOpensAtItsLastActiveTab() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let one = try await backend.createWorkspace(name: "One", spawn: sleep)
        let second = try await backend.createTab(in: one.workspace, spawn: sleep)
        let third = try await backend.createTab(in: one.workspace, spawn: sleep)
        let two = try await backend.createWorkspace(name: "Two", spawn: sleep)
        try await waitFor("the tabs") { store.state.workspaces.count == 2 && store.state.focus.workspace == two.workspace }

        // In One, the middle tab was the last used; then over to Two.
        try await go(store, .tab(second.tab))
        try await go(store, .workspace(two.workspace))
        XCTAssertEqual(store.state.focus.tab, two.tab)

        // Back to One: the middle tab, not the first, both at once and once the daemon confirms.
        XCTAssertTrue(store.showFocus(.workspace(one.workspace)))
        XCTAssertEqual(store.state.focus.tab, second.tab, "shown at once")
        try await store.sendFocus(.workspace(one.workspace))
        try await waitFor("the daemon's focus") { !store.isFocusLocal }
        XCTAssertEqual(store.state.focus, Focus(workspace: one.workspace, tab: second.tab, pane: second.pane))

        // The last one changes with use.
        try await go(store, .tab(third.tab))
        try await go(store, .workspace(two.workspace))
        try await go(store, .workspace(one.workspace))
        XCTAssertEqual(store.state.focus.tab, third.tab)
    }

    func testAClosedLastTabFallsBack() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let one = try await backend.createWorkspace(name: "One", spawn: sleep)
        let second = try await backend.createTab(in: one.workspace, spawn: sleep)
        let two = try await backend.createWorkspace(name: "Two", spawn: sleep)
        try await waitFor("the tabs") { store.state.workspaces.count == 2 && store.state.focus.workspace == two.workspace }
        try await go(store, .tab(second.tab))
        try await go(store, .workspace(two.workspace))

        // The last tab closes while the user is elsewhere: One opens at a tab that's still there.
        try await backend.closeTab(second.tab)
        try await waitFor("the close") { store.state.tab(second.tab) == nil }
        try await go(store, .workspace(one.workspace))
        XCTAssertEqual(store.state.focus, Focus(workspace: one.workspace, tab: one.tab, pane: one.pane))
    }

    /// A model whose last tab is gone but still named (as from an older daemon): the first tab.
    func testAStaleLastTabMeansTheFirst() {
        let state = ModelState(rev: 1, focus: Focus(workspace: 2, tab: 20, pane: 200), workspaces: [
            Workspace(id: 1, name: "One", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100)),
                                                 Tab(id: 11, activePane: 110, layout: .pane(110))], activeTab: 99),
            Workspace(id: 2, name: "Two", tabs: [Tab(id: 20, activePane: 200, layout: .pane(200))], activeTab: 20),
        ])
        XCTAssertEqual(state.focusing(.workspace(1))?.focus, Focus(workspace: 1, tab: 10, pane: 100))
        var known = state
        known.workspaces[0].activeTab = 11
        XCTAssertEqual(known.focusing(.workspace(1))?.focus, Focus(workspace: 1, tab: 11, pane: 110))
    }
}
