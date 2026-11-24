import ClothoKit
import XCTest
@testable import Clotho

/// `client.active` goes to each daemon with `alerts` while the user is really at the app: Clotho in front,
/// keyboard or mouse used in the last minute, at most once per machine per interval.
@MainActor
final class UserPresenceTests: XCTestCase {
    private var front = true
    private var idle: TimeInterval = 1
    private var clock = Date(timeIntervalSince1970: 1000)
    private var targets: [UserPresence.Target] = []
    private var sent: [MachineKey] = []

    private func target(_ key: MachineKey, connected: Bool = true, features: Set<Hello.Feature> = [.agents, .alerts]) -> UserPresence.Target {
        UserPresence.Target(key: key, connected: connected, features: features)
    }

    private func presence() -> UserPresence {
        front = true
        idle = 1
        clock = Date(timeIntervalSince1970: 1000)
        targets = [target("local")]
        sent = []
        let presence = UserPresence(isFront: { [unowned self] in self.front }, idleSeconds: { [unowned self] in self.idle },
                                    machines: { [unowned self] in self.targets }, send: { [unowned self] in self.sent.append($0) })
        presence.now = { [unowned self] in self.clock }
        return presence
    }

    func testSendsWhenFrontAndActive() {
        let presence = presence()
        presence.check()
        XCTAssertEqual(sent, ["local"])
        XCTAssertEqual(presence.sent, 1)
    }

    func testNothingWhenIdle() {
        let presence = presence()
        idle = UserPresence.idleLimit
        presence.check()
        idle = 600
        presence.check()
        XCTAssertEqual(sent, [], "keyboard and mouse quiet for a minute: the user isn't here")
        idle = UserPresence.idleLimit - 1
        presence.check()
        XCTAssertEqual(sent, ["local"])
    }

    /// `isFront` is the app active with its window key; either one missing answers false.
    func testNothingInTheBackground() {
        let presence = presence()
        front = false
        presence.check()
        clock += 120
        presence.check()
        XCTAssertEqual(sent, [])
        front = true
        presence.check()
        XCTAssertEqual(sent, ["local"], "sent once the app is in front again")
    }

    func testOncePerMachinePerInterval() {
        let presence = presence()
        targets = [target("local"), target("remote")]
        // The app became active, the window key, and the timer fired, all at once.
        for _ in 0..<5 { presence.check() }
        XCTAssertEqual(sent.sorted(), ["local", "remote"])
        clock += UserPresence.minGap - 1
        presence.check()
        XCTAssertEqual(sent.count, 2, "not again inside the interval")
        // The next tick of the timer.
        clock = Date(timeIntervalSince1970: 1000 + UserPresence.interval)
        presence.check()
        presence.check()
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent.suffix(2).sorted(), ["local", "remote"])
        XCTAssertLessThan(UserPresence.minGap, UserPresence.interval, "every tick of the timer sends")
    }

    func testOnlyConnectedMachinesWithAlerts() {
        let presence = presence()
        targets = [target("old", features: [.agents, .paneKeys]), target("none", features: []),
                   target("away", connected: false), target("new")]
        presence.check()
        XCTAssertEqual(sent, ["new"])
    }

    /// A machine that dropped and came back hears at once: its daemon may be a new one.
    func testAReconnectedMachineHearsAgain() {
        let presence = presence()
        presence.check()
        clock += 10
        targets = [target("local", connected: false)]
        presence.check()
        targets = [target("local")]
        presence.check()
        XCTAssertEqual(sent, ["local", "local"])
    }

    /// The real idle clock answers without a permission prompt or an event monitor.
    func testSystemIdleSecondsAnswers() {
        XCTAssertGreaterThanOrEqual(UserPresence.systemIdleSeconds(), 0)
    }
}
