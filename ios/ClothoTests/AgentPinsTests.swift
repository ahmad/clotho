import ClothoKit
import XCTest
@testable import Clotho

/// Pinned agents (AgentPins): kept per machine and pane, across relaunches, and dropped with their pane or agent.
@MainActor
final class AgentPinsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AgentPinsTests-\(UUID().uuidString)"
    private let devbox = UUID(), imac = UUID()

    override func setUp() { defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func row(_ machine: UUID, _ pane: PaneID, _ state: AgentInfo.State, attention: Bool, since: Double,
                     needsUser: Bool? = nil) -> AgentRow {
        AgentRow(machineID: machine, machineName: "m", pane: pane, tab: 1, workspace: "w", title: "t",
                 info: AgentInfo(kind: "claude", state: state, since: since, attention: attention, needsUser: needsUser))
    }

    func testPinsSurviveARelaunch() {
        let pins = AgentPins(defaults: defaults)
        pins.setPinned(true, machine: devbox, pane: 7)
        XCTAssertTrue(AgentPins(defaults: defaults).isPinned(machine: devbox, pane: 7), "a new instance (a relaunch) forgot the pin")
        XCTAssertFalse(AgentPins(defaults: defaults).isPinned(machine: imac, pane: 7), "pins are per machine")
        pins.setPinned(false, machine: devbox, pane: 7)
        XCTAssertFalse(AgentPins(defaults: defaults).isPinned(machine: devbox, pane: 7))
    }

    func testPinnedRowsGoFirstByGroup() {
        let pins = AgentPins(defaults: defaults)
        let old = row(devbox, 1, .running, attention: false, since: 100)
        let resolved = row(devbox, 2, .done, attention: false, since: 300)
        let asking = row(imac, 3, .waiting, attention: true, since: 250, needsUser: true)
        let other = row(imac, 4, .waiting, attention: true, since: 400)
        let finished = row(devbox, 5, .done, attention: true, since: 200, needsUser: false)
        let justFinished = row(devbox, 6, .done, attention: true, since: 350)
        let failed = row(imac, 7, .error, attention: true, since: 50, needsUser: true)
        let question = row(imac, 8, .done, attention: true, since: 150, needsUser: true)
        let all = [old, resolved, asking, other, finished, justFinished, failed, question]
        all.filter { $0.pane != 4 }.forEach(pins.toggle)
        let split = pins.split(all)
        XCTAssertEqual(split.pinned.map(\.pane), [7, 8, 3, 6, 5, 2, 1],
                       "needs you with the longest wait first, then done and the rest, each newest first")
        XCTAssertEqual(split.rest.map(\.pane), [4], "a pinned agent isn't repeated below")
    }

    func testAPinGoesWithItsPaneOrAgent() {
        let pins = AgentPins(defaults: defaults)
        pins.setPinned(true, machine: devbox, pane: 7)
        pins.setPinned(true, machine: devbox, pane: 8)
        pins.setPinned(true, machine: imac, pane: 7)
        // devbox's pane 8 closed (or its agent left); pane 7 still has one. imac isn't judged.
        pins.prune(machine: devbox, agentPanes: [7, 9])
        XCTAssertTrue(pins.isPinned(machine: devbox, pane: 7))
        XCTAssertFalse(pins.isPinned(machine: devbox, pane: 8))
        XCTAssertTrue(pins.isPinned(machine: imac, pane: 7), "another machine's pins stay")
        XCTAssertFalse(AgentPins(defaults: defaults).isPinned(machine: devbox, pane: 8), "the drop is saved")
    }
}
