@testable import ClothoKit
import XCTest

/// A pane's `progress` as clothod sends it (feature `pane.progress`, 0.1.33), what is said for it, and
/// which one a Tab shows.
final class PaneProgressTests: XCTestCase {
    private func pane(_ progress: String) throws -> Pane {
        try JSONDecoder().decode(Pane.self, from: Data(#"{"id": 3, "cols": 80, "rows": 24, "seq": 7, "title": "build", "progress": \#(progress)}"#.utf8))
    }

    func testDecodesEachState() throws {
        XCTAssertEqual(try pane(#"{"state": "running", "percent": 40}"#).progress, PaneProgress(state: .running, percent: 40))
        XCTAssertEqual(try pane(#"{"state": "error", "percent": 55}"#).progress, PaneProgress(state: .error, percent: 55))
        XCTAssertEqual(try pane(#"{"state": "paused", "percent": 70}"#).progress, PaneProgress(state: .paused, percent: 70))
        XCTAssertEqual(try pane(#"{"state": "indeterminate", "percent": null}"#).progress, PaneProgress(state: .indeterminate))
        XCTAssertEqual(try pane(#"{"state": "running", "percent": null}"#).progress, PaneProgress(state: .running))
        XCTAssertEqual(try pane(#"{"state": "error"}"#).progress, PaneProgress(state: .error))
        XCTAssertNil(try pane("null").progress)
        let without = try JSONDecoder().decode(Pane.self, from: Data(#"{"id": 3, "cols": 80, "rows": 24, "seq": 0}"#.utf8))
        XCTAssertNil(without.progress, "a daemon without the feature")
        XCTAssertEqual(PaneProgress.State.allCases.map(\.rawValue), ["running", "error", "indeterminate", "paused"])
    }

    func testOddValues() throws {
        XCTAssertEqual(try pane(#"{"state": "exploding", "percent": 12}"#).progress, PaneProgress(state: .running, percent: 12), "an unknown state reads running")
        XCTAssertEqual(try pane(#"{"state": 4, "percent": 12}"#).progress, PaneProgress(state: .running, percent: 12))
        XCTAssertEqual(try pane(#"{"percent": 12}"#).progress, PaneProgress(state: .running, percent: 12))
        XCTAssertEqual(try pane(#"{"state": "running", "percent": 140}"#).progress?.percent, 100)
        XCTAssertEqual(try pane(#"{"state": "running", "percent": -3}"#).progress?.percent, 0)
        XCTAssertNil(try pane(#"{"state": "indeterminate", "percent": 30}"#).progress?.percent, "never a percent for indeterminate")
        XCTAssertEqual(try pane(#"{"state": "paused", "percent": "half"}"#).progress, PaneProgress(state: .paused))
        XCTAssertEqual(try pane(#"{"state": "running", "percent": 40, "eta": 12}"#).progress, PaneProgress(state: .running, percent: 40))
        XCTAssertEqual(PaneProgress(state: .running, percent: 140).percent, 100)
        XCTAssertNil(PaneProgress(state: .indeterminate, percent: 30).percent)
    }

    /// A shape this client can't read is no progress, and never loses the pane or the state around it.
    func testMalformedProgressLeavesThePaneAndTheState() throws {
        for progress in [#""soon""#, "7", "[]", "true", "[40]"] {
            let read = try pane(progress)
            XCTAssertNil(read.progress, progress)
            XCTAssertEqual(read.id, 3)
            XCTAssertEqual(read.seq, 7)
            XCTAssertEqual(read.title, "build")
        }
        let state = try JSONDecoder().decode(ModelState.self, from: Data("""
        {"rev": 5, "focus": {"workspace": 1, "tab": 2, "pane": 3},
         "workspaces": [{"id": 1, "name": "main", "active_tab": 2, "tabs": [
            {"id": 2, "title": null, "active_pane": 3, "layout": {"type": "pane", "pane": 3}}]}],
         "panes": [
          {"id": 3, "cols": 80, "rows": 24, "seq": 0, "progress": "40%",
           "agent": {"kind": "other", "state": "waiting", "source": "osc", "attention": true}},
          {"id": 4, "cols": 80, "rows": 24, "seq": 0, "progress": {"state": "paused", "percent": 70}},
          {"id": 5, "cols": 80, "rows": 24, "seq": 0}]}
        """.utf8))
        XCTAssertEqual(state.rev, 5)
        XCTAssertEqual(state.panes.count, 3)
        XCTAssertNil(state.pane(3)?.progress)
        XCTAssertEqual(state.pane(3)?.agent?.source, "osc", "the rest of the pane is read")
        XCTAssertEqual(state.pane(4)?.progress, PaneProgress(state: .paused, percent: 70))
        XCTAssertNil(state.pane(5)?.progress)
    }

    func testRoundTripAndFraction() throws {
        let pane = Pane(id: 1, cols: 80, rows: 24, progress: PaneProgress(state: .error, percent: 55))
        let again = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(again, pane)
        XCTAssertNil(Pane(id: 1, cols: 80, rows: 24).progress, "the init's default")
        XCTAssertEqual(PaneProgress(state: .running, percent: 40).fraction, 0.4)
        XCTAssertEqual(PaneProgress(state: .running, percent: 100).fraction, 1)
        XCTAssertEqual(PaneProgress(state: .running, percent: 0).fraction, 0)
        XCTAssertNil(PaneProgress(state: .indeterminate).fraction)
        XCTAssertNil(PaneProgress(state: .running).fraction)
    }

    func testSpokenText() {
        XCTAssertEqual(PaneProgress(state: .running, percent: 40).spokenText, "Progress 40 percent")
        XCTAssertEqual(PaneProgress(state: .error, percent: 55).spokenText, "Progress 55 percent, error")
        XCTAssertEqual(PaneProgress(state: .paused, percent: 70).spokenText, "Progress 70 percent, paused")
        XCTAssertEqual(PaneProgress(state: .indeterminate).spokenText, "Progress, in progress")
        XCTAssertEqual(PaneProgress(state: .running).spokenText, "Progress, in progress")
        XCTAssertEqual(PaneProgress(state: .error).spokenText, "Progress, error")
        XCTAssertEqual(PaneProgress(state: .paused).spokenText, "Progress, paused")
    }

    func testForTab() {
        let running = PaneProgress(state: .running, percent: 40)
        let paused = PaneProgress(state: .paused, percent: 70)
        let failed = PaneProgress(state: .error, percent: 55)
        let later = PaneProgress(state: .error, percent: 90)
        XCTAssertNil(PaneProgress.forTab([]))
        XCTAssertEqual(PaneProgress.forTab([running]), running)
        XCTAssertEqual(PaneProgress.forTab([paused, running]), paused, "the first in layout order")
        XCTAssertEqual(PaneProgress.forTab([running, paused, failed, later]), failed, "an error first, and the first of those")
        XCTAssertEqual(PaneProgress.forTab([failed, running]), failed)
    }

    /// A cached model never brings a progress back: a bar must not show for a machine that isn't connected.
    func testTheCacheDropsProgress() throws {
        let live = ModelState(rev: 3, focus: Focus(), workspaces: [Workspace(id: 1, name: "w", tabs: [Tab(id: 2, activePane: 3, layout: .pane(3))])],
                              panes: [Pane(id: 3, cols: 80, rows: 24, cwd: "/srv", progress: PaneProgress(state: .running, percent: 40))])
        let cached = CachedMachineState(state: live, lastSeen: Date(timeIntervalSince1970: 100), daemonVersion: "0.1.33", instance: "a",
                                        featureNames: ["pane.progress"])
        XCTAssertNil(cached.state.pane(3)?.progress)
        XCTAssertEqual(cached.state.pane(3)?.cwd, "/srv", "the rest is kept")
        XCTAssertEqual(cached.features, [.paneProgress])
        let again = try JSONDecoder().decode(CachedMachineState.self, from: JSONEncoder().encode(cached))
        XCTAssertEqual(again, cached)

        // A cache file that has one all the same (written before this rule, or by hand).
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cached)) as? [String: Any])
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        var panes = try XCTUnwrap(state["panes"] as? [[String: Any]])
        panes[0]["progress"] = ["state": "running", "percent": 40] as [String: Any]
        state["panes"] = panes
        object["state"] = state
        let read = try JSONDecoder().decode(CachedMachineState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(read.state.pane(3)?.progress)
        XCTAssertEqual(read, cached)
    }
}
