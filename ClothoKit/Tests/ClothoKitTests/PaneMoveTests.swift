import ClothoFake
import XCTest
@testable import ClothoKit

/// pane.move and tab.join (feature `pane.move`, clothod 0.1.26; ⌘↩ in ⌘P). One sequence runs through
/// FakeBackend and through a real clothod, and each step must come out the same: every tab's layout (by
/// which pane is where, splits' axes and ratios), active panes and tabs, and the focus.
extension ClothodBackendTests {
    /// Workspace "one": tab A (a | a2, split right), tab B (b), tab C (c). Then:
    /// 1. a2 beside c, down, focus false: A is just a; C is c over a2; focus stays.
    /// 2. B joined beside a, right, focus true: B goes; A is a | b; focus on b.
    /// 3. a beside b, left, focus false: a leaves A and comes back on b's left in a new split; focus stays on b.
    static func paneMoveScenario(_ backend: SessionBackend) async throws -> [String] {
        let sh = SpawnOptions(command: ["/bin/sh"], cwd: "/tmp")
        let one = try await backend.createWorkspace(name: "one", spawn: sh)
        let a = one.pane
        let a2 = try await backend.split(a, direction: .right, ratio: 0.6, spawn: sh).pane
        let b = try await backend.createTab(in: one.workspace, spawn: sh)
        let c = try await backend.createTab(in: one.workspace, spawn: sh)
        let names: [PaneID: String] = [a: "a", a2: "a2", b.pane: "b", c.pane: "c"]
        let tabs: [TabID: String] = [one.tab: "A", b.tab: "B", c.tab: "C"]

        func layout(_ node: Layout) -> String {
            switch node {
            case let .pane(id): return names[id] ?? "?"
            case let .split(_, axis, ratio, x, y): return "(\(layout(x)) \(axis == .horizontal ? "|" : "/")\(String(format: "%.2f", ratio)) \(layout(y)))"
            }
        }
        func shape() async throws -> String {
            let state = try await backend.getState()
            let workspaces = state.workspaces.map { w in
                "\(w.name) active \(w.activeTab.flatMap { tabs[$0] } ?? "-"): " + w.tabs.map { t in
                    "\(tabs[t.id] ?? "?")=\(layout(t.layout))@\(names[t.activePane] ?? "?")"
                }.joined(separator: " ")
            }
            return workspaces.joined(separator: "; ") + " focus \(state.focus.tab.flatMap { tabs[$0] } ?? "-")/\(state.focus.pane.flatMap { names[$0] } ?? "-")"
        }

        var steps = [try await shape()]
        try await backend.move(.pane(a2, beside: c.pane, direction: .down, ratio: nil, focus: false))
        steps.append(try await shape())
        try await backend.move(.tabJoin(b.tab, beside: a, direction: .right, ratio: 0.7, focus: true))
        steps.append(try await shape())
        try await backend.move(.pane(a, beside: b.pane, direction: .left, ratio: nil, focus: false))
        steps.append(try await shape())
        return steps
    }

    func testPaneMoveAndTabJoinMatchTheDaemon() async throws {
        let backend = makeBackend()
        defer { backend.stop() }
        try await backend.start()
        let hello = try XCTUnwrap(backend.lastHello)
        try XCTSkipUnless(hello.features.contains(.paneMove), "this clothod predates pane.move")
        let daemon = try await Self.paneMoveScenario(backend)

        let fake = FakeBackend()
        defer { fake.stop() }
        try await fake.start()
        let faked = try await Self.paneMoveScenario(fake)

        XCTAssertEqual(daemon.count, 4)
        for (step, (d, f)) in zip(daemon, faked).enumerated() {
            XCTAssertEqual(f, d, "step \(step)")
        }
        // The expected shapes, spelled out (from the daemon's own result).
        XCTAssertTrue(daemon[1].contains("A=a@a"), daemon[1])
        XCTAssertTrue(daemon[1].contains("C=(c /0.50 a2)"), daemon[1])
        XCTAssertTrue(daemon[2].contains("A=(a |0.70 b)@b"), daemon[2])
        XCTAssertFalse(daemon[2].contains("B="), "the joined tab is gone")
        XCTAssertTrue(daemon[2].hasSuffix("focus A/b"), daemon[2])
    }

    func testPaneMoveErrors() async throws {
        let fake = FakeBackend()
        defer { fake.stop() }
        try await fake.start()
        let sh = SpawnOptions(command: ["/bin/sh"], cwd: "/tmp")
        let one = try await fake.createWorkspace(name: "one", spawn: sh)
        let other = try await fake.createTab(in: one.workspace, spawn: sh)
        do {
            try await fake.move(.pane(one.pane, beside: one.pane, direction: .right, ratio: nil, focus: true))
            XCTFail("a pane beside itself")
        } catch let error as BackendError { XCTAssertEqual(error.code, "bad_request") }
        do {
            try await fake.move(.tabJoin(other.tab, beside: other.pane, direction: .right, ratio: nil, focus: true))
            XCTFail("a tab beside its own pane")
        } catch let error as BackendError { XCTAssertEqual(error.code, "bad_request") }
        do {
            try await fake.move(.pane(one.pane, beside: 9999, direction: .right, ratio: nil, focus: true))
            XCTFail("an unknown pane")
        } catch let error as BackendError { XCTAssertEqual(error.code, "not_found") }
        XCTAssertTrue(MoveRequest.pane(1, beside: 2, direction: .right, ratio: nil, focus: true).isDaemonOnly)
        let state = try await fake.getState()
        XCTAssertNil(state.moving(.tabJoin(other.tab, beside: one.pane, direction: .right, ratio: nil, focus: true)),
                     "no local preview: the new split's id is the daemon's")
    }
}
