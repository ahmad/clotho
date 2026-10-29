@testable import ClothoKit
import ClothoFake
import XCTest

/// Moves show at once, by the daemon's rules (protocol.md, "Moving tabs and workspaces"), and the
/// daemon's states then confirm them.
@MainActor
final class LocalMoveTests: XCTestCase {
    /// Workspaces 1 (tabs 10, 11, 12; 11 active and focused), 2 (tab 20), 3 (no tabs).
    private func model() -> ModelState {
        ModelState(rev: 5, focus: Focus(workspace: 1, tab: 11, pane: 110), workspaces: [
            Workspace(id: 1, name: "One", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100)),
                                                 Tab(id: 11, activePane: 110, layout: .pane(110)),
                                                 Tab(id: 12, activePane: 120, layout: .pane(120))], activeTab: 11),
            Workspace(id: 2, name: "Two", tabs: [Tab(id: 20, activePane: 200, layout: .pane(200))], activeTab: 20),
            Workspace(id: 3, name: "Three", tabs: [], activeTab: nil),
        ])
    }

    private func order(_ state: ModelState) -> String {
        state.workspaces.map { w in "\(w.id):\(w.activeTab.map(String.init) ?? "-")[" + w.tabs.map { String($0.id) }.joined(separator: ",") + "]" }
            .joined(separator: " ") + " focus \(state.focus.tab.map(String.init) ?? "-")"
    }

    func testWorkspaceMoves() {
        let state = model()
        XCTAssertEqual(order(state.moving(.workspace(3, index: 0))!), "3:-[] 1:11[10,11,12] 2:20[20] focus 11")
        XCTAssertEqual(order(state.moving(.workspace(1, index: 99))!), "2:20[20] 3:-[] 1:11[10,11,12] focus 11", "clamped")
        XCTAssertEqual(state.moving(.workspace(1, index: 0)), state, "no change")
        XCTAssertNil(state.moving(.workspace(9, index: 0)))
        XCTAssertNil(state.moving(.workspace(1, index: -1)))
    }

    func testTabRules() {
        let state = model()
        // A reorder: only the order changes.
        XCTAssertEqual(order(state.moving(.tab(12, workspace: nil, index: 0, focus: false))!), "1:11[12,10,11] 2:20[20] 3:-[] focus 11")
        // Across, not focused, not active: the destination keeps its active tab.
        XCTAssertEqual(order(state.moving(.tab(10, workspace: 2, index: 1, focus: false))!), "1:11[11,12] 2:20[20,10] 3:-[] focus 11")
        // Across, the focused and active tab: the source's active tab is the one before; the focus follows.
        let followed = state.moving(.tab(11, workspace: 2, index: 0, focus: false))!
        XCTAssertEqual(order(followed), "1:10[10,12] 2:11[11,20] 3:-[] focus 11")
        XCTAssertEqual(followed.focus, Focus(workspace: 2, tab: 11, pane: 110))
        // The first tab, active: the new first becomes active (no tab before it).
        var first = state
        first.workspaces[0].activeTab = 10
        first.focus = Focus(workspace: 2, tab: 20, pane: 200)
        XCTAssertEqual(order(first.moving(.tab(10, workspace: 2, index: 0, focus: false))!), "1:11[11,12] 2:20[10,20] 3:-[] focus 20")
        // Into an empty workspace: it becomes that workspace's active tab, but the focus stays.
        XCTAssertEqual(order(state.moving(.tab(12, workspace: 3, index: 0, focus: false))!), "1:11[10,11] 2:20[20] 3:12[12] focus 11")
        // With focus: it's focused and active where it lands.
        let focused = state.moving(.tab(20, workspace: 1, index: 1, focus: true))!
        XCTAssertEqual(order(focused), "1:20[10,20,11,12] 2:-[] 3:-[] focus 20")
        XCTAssertEqual(focused.focus, Focus(workspace: 1, tab: 20, pane: 200))
        XCTAssertNil(state.moving(.tab(99, workspace: nil, index: 0, focus: false)))
        XCTAssertNil(state.moving(.tab(10, workspace: 9, index: 0, focus: false)))
    }

    func testAMoveShowsAtOnceAndOutlastsOlderStates() async throws {
        let backend = FakeBackend()
        let store = ModelStore(backend: backend)
        defer { store.stop() }
        try await store.start()
        let sleep = SpawnOptions(command: ["/bin/sleep", "30"])
        let one = try await backend.createWorkspace(name: "One", spawn: sleep)
        let two = try await backend.createWorkspace(name: "Two", spawn: sleep)
        try await waitFor { store.state.workspaces.count == 2 }
        let before = store.state

        let id = try XCTUnwrap(store.showMove(.workspace(two.workspace, index: 0)))
        XCTAssertEqual(store.state.workspaces.map(\.id), [two.workspace, one.workspace], "at once")
        XCTAssertTrue(store.isMoveLocal)
        store.apply(.state(before))
        XCTAssertEqual(store.state.workspaces.map(\.id), [two.workspace, one.workspace], "an older state keeps it")
        try await store.sendMove(.workspace(two.workspace, index: 0), id: id)
        let daemon = try await backend.getState()
        XCTAssertEqual(daemon.workspaces.first?.id, two.workspace, "the daemon made the same move")
        try await Task.sleep(nanoseconds: UInt64((ModelStore.localFocusGrace + 0.2) * 1e9))
        store.apply(.state(daemon))
        XCTAssertFalse(store.isMoveLocal)
        XCTAssertEqual(store.state.workspaces.map(\.id), [two.workspace, one.workspace], "the daemon's state has it")
    }

    /// A refused move puts the daemon's state back and throws.
    func testRefusedMoveGoesBack() async throws {
        let store = ModelStore(backend: FakeBackend())
        store.apply(.state(model()))
        do {
            try await store.move(.tab(10, workspace: 2, index: 0, focus: false))
            XCTFail("the fake backend has no tab 10")
        } catch {}
        XCTAssertEqual(store.state, model())
        XCTAssertFalse(store.isMoveLocal)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
