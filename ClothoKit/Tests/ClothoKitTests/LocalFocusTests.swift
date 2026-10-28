@testable import ClothoKit
import ClothoFake
import XCTest

/// A click's focus shows at once, by the daemon's rules, and the daemon's states then confirm it.
@MainActor
final class LocalFocusTests: XCTestCase {
    /// Two workspaces: 1 with tabs 10 (pane 100) and 11 (panes 110, 111; 111 active), 2 with tab 20.
    private func model() -> ModelState {
        let split = Layout.split(id: 900, axis: .horizontal, ratio: 0.5, a: .pane(110), b: .pane(111))
        return ModelState(rev: 5, focus: Focus(workspace: 1, tab: 10, pane: 100), workspaces: [
            Workspace(id: 1, name: "One", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100)),
                                                 Tab(id: 11, activePane: 111, layout: split)], activeTab: 10),
            Workspace(id: 2, name: "Two", tabs: [Tab(id: 20, activePane: 200, layout: .pane(200))], activeTab: 20),
        ])
    }

    func testFocusingFollowsTheDaemonsRules() {
        let state = model()
        let tab = state.focusing(.tab(11))!
        XCTAssertEqual(tab.focus, Focus(workspace: 1, tab: 11, pane: 111), "a tab focuses its active pane")
        XCTAssertEqual(tab.workspace(1)?.activeTab, 11)
        let back = tab.focusing(.workspace(2))!.focusing(.workspace(1))!
        XCTAssertEqual(back.focus, Focus(workspace: 1, tab: 11, pane: 111), "a workspace returns to its active tab")
        let pane = state.focusing(.pane(110))!
        XCTAssertEqual(pane.focus, Focus(workspace: 1, tab: 11, pane: 110))
        XCTAssertEqual(pane.tab(11)?.activePane, 110)
        XCTAssertEqual(pane.workspace(1)?.activeTab, 11)
        var empty = state
        empty.workspaces[1].tabs = []
        empty.workspaces[1].activeTab = nil
        XCTAssertEqual(empty.focusing(.workspace(2))?.focus, Focus(workspace: 2), "an empty workspace")
        XCTAssertNil(state.focusing(.tab(99)))
        XCTAssertNil(state.focusing(.workspace(99)))
    }

    /// The focus shows before the daemon answers, and states sent before the daemon had it don't undo it.
    func testFocusShowsBeforeTheDaemonAnswers() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let sleep = SpawnOptions(command: ["/bin/sleep", "30"])
        let one = try await backend.createWorkspace(name: "One", spawn: sleep)
        let two = try await backend.createWorkspace(name: "Two", spawn: sleep)
        try await waitFor("both workspaces") { store.state.workspaces.count == 2 && store.state.focus.workspace == two.workspace }
        let before = store.state

        backend.focusDelay = 0.4
        var changes = 0
        store.onChange = { changes += 1 }
        let request = Task { try await store.focus(.workspace(one.workspace)) }
        try await waitFor("the local focus") { store.state.focus.workspace == one.workspace }
        XCTAssertEqual(store.state.focus, Focus(workspace: one.workspace, tab: one.tab, pane: one.pane))
        XCTAssertTrue(store.isFocusLocal)
        XCTAssertGreaterThan(changes, 0, "observers redraw at once")
        // A state the daemon sent before it had the focus: the local focus stays.
        store.apply(.state(before))
        XCTAssertEqual(store.state.focus.workspace, one.workspace)
        try await request.value
        try await waitFor("the daemon's confirmation") { !store.isFocusLocal }
        XCTAssertEqual(store.state.focus.workspace, one.workspace)
    }

    /// A refused focus puts the daemon's back and throws.
    func testRefusedFocusGoesBack() async throws {
        let store = ModelStore(backend: FakeBackend())
        store.apply(.state(model()))
        do {
            try await store.focus(.tab(11))
            XCTFail("the fake backend has no tab 11")
        } catch {}
        XCTAssertEqual(store.state.focus, Focus(workspace: 1, tab: 10, pane: 100))
        XCTAssertEqual(store.state.workspace(1)?.activeTab, 10)
        XCTAssertFalse(store.isFocusLocal)
    }

    /// A local focus doesn't hold forever: once its time is up, the daemon's states win again.
    func testUnconfirmedFocusLetsGo() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let sleep = SpawnOptions(command: ["/bin/sleep", "30"])
        let one = try await backend.createWorkspace(name: "One", spawn: sleep)
        let two = try await backend.createWorkspace(name: "Two", spawn: sleep)
        try await waitFor("both workspaces") { store.state.focus.workspace == two.workspace }
        let before = store.state
        let saved = ModelStore.localFocusTimeout
        ModelStore.localFocusTimeout = 0.1
        defer { ModelStore.localFocusTimeout = saved }
        backend.focusDelay = 5
        let request = Task { try await store.focus(.workspace(one.workspace)) }
        defer { request.cancel() }
        try await waitFor("the local focus") { store.state.focus.workspace == one.workspace }
        try await Task.sleep(nanoseconds: 200_000_000)
        store.apply(.state(before))
        XCTAssertEqual(store.state.focus.workspace, two.workspace, "the daemon's focus after the timeout")
        XCTAssertFalse(store.isFocusLocal)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
