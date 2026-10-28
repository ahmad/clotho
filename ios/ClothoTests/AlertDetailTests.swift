import ClothoKit
import CryptoKit
@testable import Clotho
import UserNotifications
import XCTest

/// Alert detail (clothod 0.1.13): what the push extension and the app's own banner show, through ClothoKit's
/// AgentNotice (its rules are tested in ClothoKit; these cover the iOS paths: record → notification, threading,
/// the size cap, and the banner matching the push).
final class AlertDetailTests: XCTestCase {
    private let machine = UUID(uuidString: "00000000-0000-0000-0000-00000000C10D")!
    private var label: String { PushLabel.make(machine: machine, name: "devbox") }

    /// Seals `record` like clothod (padded with "pad" to `padTo` bytes when given) and opens it the way the
    /// extension does.
    private func deliver(_ record: [String: Any], padTo: Int? = nil) throws -> (UNNotificationContent, ciphertext: String) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let collapse = PushLabel.collapseID(label: label, pane: 7)
        var record = record
        if let padTo {
            let unpadded = try JSONSerialization.data(withJSONObject: record).count + #","pad":"""#.count
            XCTAssertLessThanOrEqual(unpadded, padTo, "the test record must fit before padding")
            record["pad"] = String(repeating: " ", count: padTo - unpadded)
        }
        let plain = try JSONSerialization.data(withJSONObject: record)
        if let padTo { XCTAssertEqual(plain.count, padTo) }
        var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: PushAlert.suite, info: PushAlert.info)
        let sealed = (sender.encapsulatedKey + (try sender.seal(plain, authenticating: Data(collapse.utf8)))).base64EncodedString()
        let content = UNMutableNotificationContent()
        content.title = "Clotho"
        content.body = "An agent needs you"
        content.threadIdentifier = collapse
        content.userInfo = ["e": sealed]
        return (try XCTUnwrap(PushAlert.decrypt(content, key: key)), sealed)
    }

    private func record(_ extra: [String: Any]) -> [String: Any] {
        ["v": 1, "m": label, "p": 7, "k": "claude", "t": 1761512345.5].merging(extra) { $1 }
    }

    func testDoneWithDetail() throws {
        let (out, _) = try deliver(record(["s": "done", "msg": "All 214 tests pass.", "w": "Platform", "wid": 3,
                                           "tb": "cargo test", "pj": "api-server", "q": "run the tests", "d": 245]))
        XCTAssertEqual(out.title, "Platform · Claude finished")
        XCTAssertEqual(out.subtitle, "devbox · api-server · 4m")
        XCTAssertEqual(out.body, "All 214 tests pass.")
        XCTAssertEqual(out.threadIdentifier, machine.uuidString + "/3", "threaded by workspace")
        XCTAssertEqual((out.userInfo["pane"] as? NSNumber)?.uint64Value, 7)
    }

    func testPermissionWaitAndQuestion() throws {
        let permission = try deliver(record(["s": "waiting", "msg": "Claude needs your permission to use Bash",
                                             "w": "Platform", "wid": 3, "tool": "Bash", "cmd": "npm test"])).0
        XCTAssertEqual(permission.title, "Platform · Claude is waiting")
        XCTAssertEqual(permission.body, "Allow Bash: npm test?")
        // tool/cmd are the turn's last tool: a question isn't about it.
        let question = try deliver(record(["s": "waiting", "msg": "Which database should I use?", "w": "Platform",
                                           "tool": "Bash", "cmd": "ls"])).0
        XCTAssertEqual(question.body, "Which database should I use?")
        XCTAssertEqual(question.threadIdentifier, machine.uuidString + "/Platform", "the name when there's no id")
    }

    /// An older daemon's record: today's text, threaded by machine.
    func testOlderRecordReadsAsBefore() throws {
        let (out, _) = try deliver(record(["s": "waiting", "msg": "Allow cargo test --release?"]))
        XCTAssertEqual(out.title, "Claude is waiting on devbox")
        XCTAssertEqual(out.subtitle, "")
        XCTAssertEqual(out.body, "Allow cargo test --release?")
        XCTAssertEqual(out.threadIdentifier, machine.uuidString)
        // No message: the prompt, then the tab title.
        XCTAssertEqual(try deliver(record(["s": "done", "q": "run the tests", "tb": "cargo test"])).0.body, "run the tests")
        XCTAssertEqual(try deliver(record(["s": "done", "tb": "cargo test"])).0.body, "cargo test")
    }

    /// A record at clothod's 2048-byte cap with every field at its size limit (msg 400, q 240, cmd 240,
    /// w/tb/tool 96 bytes): it fits the relay's 3,000 characters and renders.
    func testRecordAtTheCap() throws {
        let (out, sealed) = try deliver(record([
            "s": "done", "msg": "All 214 tests pass. " + String(repeating: "I changed the retry logic. ", count: 14),
            "w": String(repeating: "W", count: 96), "wid": 3, "tb": String(repeating: "t", count: 96), "pj": "api-server",
            "q": String(repeating: "fix the failing tests ", count: 10), "tool": String(repeating: "T", count: 96),
            "cmd": String(repeating: "c", count: 240), "d": 245,
        ]), padTo: 2048)
        XCTAssertLessThanOrEqual(sealed.count, 3000, "the relay's ciphertext limit")
        XCTAssertEqual(Data(base64Encoded: sealed)?.count, 32 + 2048 + 16)
        XCTAssertEqual(out.title, String(repeating: "W", count: 96) + " · Claude finished")
        XCTAssertEqual(out.subtitle, "devbox · api-server · 4m")
        XCTAssertTrue(out.body.hasPrefix("All 214 tests pass. I changed the retry logic."))
        XCTAssertLessThanOrEqual(out.body.count, AgentNotice.bodyLimit + 1)
    }

    /// The app's own banner for the same rise reads like the push and replaces it (same identifier and thread).
    @MainActor
    func testForegroundBannerMatchesThePush() throws {
        let m = Machine(id: machine, name: "devbox", host: "devbox", user: "ahmad")
        let running = AgentInfo(kind: "claude", state: .running, source: "hook", attention: false)
        let done = AgentInfo(kind: "claude", state: .done, source: "hook", message: "All 214 tests pass.", since: 1000,
                             attention: true, prompt: "run the tests", turnStarted: 755)
        let place = AgentNotifier.Place(workspace: "Platform", workspaceID: 3, tab: "cargo test", cwd: "/home/ahmad/api-server")
        let banner = try XCTUnwrap(AgentNotifier.banner(machine: m, pane: 7, place: place, before: running, after: done))
        let push = try deliver(record(["s": "done", "msg": "All 214 tests pass.", "w": "Platform", "wid": 3,
                                       "tb": "cargo test", "pj": "api-server", "q": "run the tests", "d": 245])).0
        XCTAssertEqual(banner.content.title, push.title)
        XCTAssertEqual(banner.content.subtitle, push.subtitle)
        XCTAssertEqual(banner.content.body, push.body)
        XCTAssertEqual(banner.content.threadIdentifier, push.threadIdentifier)
        XCTAssertEqual(banner.identifier, PushLabel.collapseID(label: label, pane: 7))
    }

    /// Parallel permission requests: the banner asks about the oldest, as the push for that wait does.
    @MainActor
    func testBannerAsksAboutTheOldestRequest() throws {
        let m = Machine(id: machine, name: "devbox", host: "devbox", user: "ahmad")
        let running = AgentInfo(kind: "claude", state: .running, source: "hook", attention: false)
        let waiting = AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Claude needs your permission to use Bash",
                                attention: true, tool: "Read", toolInput: "README.md",
                                requests: [PermissionRequest(id: "a1", tool: "Bash", summary: "npm test"),
                                           PermissionRequest(id: "b2", tool: "Read", summary: "README.md")])
        let place = AgentNotifier.Place(workspace: "Platform", workspaceID: 3, tab: "cargo test")
        let banner = try XCTUnwrap(AgentNotifier.banner(machine: m, pane: 7, place: place, before: running, after: waiting))
        XCTAssertEqual(banner.content.body, "Allow Bash: npm test?")
    }
}

/// Phase 4: what a notification lets the user do (docs/ios-redesign.md).
final class AlertActionTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(AlertActions.category(state: "waiting", request: "a1b2"), AlertActions.permissionCategory)
        XCTAssertEqual(AlertActions.category(state: "waiting", request: nil), AlertActions.replyCategory, "a question takes a reply")
        XCTAssertEqual(AlertActions.category(state: "done", request: nil), AlertActions.replyCategory)
        XCTAssertEqual(AlertActions.category(state: "done", request: "a1b2"), AlertActions.replyCategory, "a stale id on a finished turn")
        XCTAssertEqual(AlertActions.category(state: "error", request: nil), "")
        let permission = AlertActions.categories.first { $0.identifier == AlertActions.permissionCategory }
        let allow = permission?.actions.first { $0.identifier == AlertActions.allow }
        XCTAssertTrue(allow?.options.contains(.authenticationRequired) == true, "Allow needs the phone unlocked")
        XCTAssertTrue(permission?.actions.contains { $0 is UNTextInputNotificationAction && $0.identifier == AlertActions.denyWithReason } == true)
    }

    /// A push with `rq` from clothod becomes an actionable alert carrying the request id.
    func testPushWithRequestIsActionable() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let machine = UUID()
        let label = PushLabel.make(machine: machine, name: "devbox")
        let collapse = PushLabel.collapseID(label: label, pane: 7)
        let alert = PushAlert(m: label, p: 7, k: "claude", s: "waiting", msg: "Claude needs your permission to use Bash",
                              w: "Platform", wid: 3, tool: "Bash", cmd: "npm test", rq: "9f1c2d3e4a5b6c7d")
        let content = UNMutableNotificationContent()
        content.threadIdentifier = collapse
        content.userInfo = ["e": try PushAlert.seal(alert, collapseID: collapse, to: key.publicKey)]
        let out = try XCTUnwrap(PushAlert.decrypt(content, key: key))
        XCTAssertEqual(out.categoryIdentifier, AlertActions.permissionCategory)
        XCTAssertEqual(out.userInfo["request"] as? String, "9f1c2d3e4a5b6c7d")
        XCTAssertEqual(out.body, "Allow Bash: npm test?")

        // An older daemon's waiting alert (no rq): a reply, no request.
        let old = PushAlert(m: label, p: 7, k: "claude", s: "waiting", msg: "Which database?")
        content.userInfo = ["e": try PushAlert.seal(old, collapseID: collapse, to: key.publicKey)]
        let plain = try XCTUnwrap(PushAlert.decrypt(content, key: key))
        XCTAssertEqual(plain.categoryIdentifier, AlertActions.replyCategory)
        XCTAssertNil(plain.userInfo["request"])
    }

    /// The app's own banner for a permission wait carries the oldest request, like the push.
    @MainActor
    func testBannerCarriesTheRequest() throws {
        let m = Machine(name: "devbox", host: "devbox", user: "ahmad")
        let running = AgentInfo(kind: "claude", state: .running, source: "hook", attention: false)
        let waiting = AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Claude needs your permission to use Bash",
                                attention: true, requests: [PermissionRequest(id: "a1", tool: "Bash", summary: "npm test"),
                                                            PermissionRequest(id: "b2", tool: "Read", summary: "x")])
        let banner = try XCTUnwrap(AgentNotifier.banner(machine: m, pane: 7, place: .init(workspace: "Platform", workspaceID: 3, tab: "t"),
                                                        before: running, after: waiting))
        XCTAssertEqual(banner.content.categoryIdentifier, AlertActions.permissionCategory)
        XCTAssertEqual(banner.content.userInfo["request"] as? String, "a1")
    }
}

/// Phase 6: the "Needs you" widget's summary (no text, newest first, at most 12; an alert's agent replaces
/// the same pane's).
final class AgentsSummaryTests: XCTestCase {
    private func agent(_ pane: UInt64, since: Double, machine: UUID = UUID(uuidString: "00000000-0000-0000-0000-00000000C10D")!) -> AgentsSummary.Agent {
        AgentsSummary.Agent(machine: machine, machineName: "devbox", pane: pane, workspace: "Platform", kind: "claude",
                            state: "waiting", since: since)
    }

    func testNewestFirstAndCapped() {
        let many = (0..<20).map { agent(UInt64($0), since: Double($0)) }
        let summary = AgentsSummary(updated: 1, agents: many).normalized()
        XCTAssertEqual(summary.agents.count, AgentsSummary.maxAgents)
        XCTAssertEqual(summary.agents.first?.pane, 19)
    }

    func testAnAlertReplacesTheSamePane() {
        let summary = AgentsSummary(updated: 1, agents: [agent(7, since: 10), agent(8, since: 20)])
        var newer = agent(7, since: 30)
        newer.state = "done"
        let merged = summary.adding(newer, now: 31)
        XCTAssertEqual(merged.agents.map(\.pane), [7, 8])
        XCTAssertEqual(merged.agents.first?.state, "done")
        XCTAssertEqual(merged.updated, 31)
    }

    func testRoundTripsThroughTheKeychain() {
        let original = AgentsSummary.load()
        defer { _ = original.save() }
        let summary = AgentsSummary(updated: 42, agents: [agent(3, since: 40)])
        XCTAssertTrue(summary.save())
        XCTAssertEqual(AgentsSummary.load(), summary)
        XCTAssertFalse(summary.save(), "an unchanged summary isn't written (or the widget reloaded) again")
    }
}

#if LIVE_ACTIVITIES
/// Phase 6: the Live Activity's content is exactly what the relay sends (docs/push.md, "Live Activities").
final class AgentActivityTests: XCTestCase {
    func testDecodesTheRelaysContentState() throws {
        // The relay's aps["content-state"], as relay.test.js builds it.
        let json = #"{"state":"running","kind":"claude","since":1761512300,"started":1761512200}"#
        let state = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state, .init(state: "running", kind: "claude", since: 1761512300, started: 1761512200))
        XCTAssertEqual(state.verb, "is working")
        XCTAssertFalse(state.isOver)
        // And back: the same four keys, nothing more.
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["kind", "since", "started", "state"])
    }

    @MainActor
    func testFirstContentMapsLikeClothod() {
        let starting = AgentInfo(kind: "Claude", state: .starting, since: 100)
        XCTAssertEqual(MachineConnection.activityState(starting),
                       .init(state: "running", kind: "claude", since: 100, started: 100), "started falls back to since")
        let waiting = AgentInfo(kind: "codex", state: .waiting, since: 200, turnStarted: 150)
        XCTAssertEqual(MachineConnection.activityState(waiting), .init(state: "waiting", kind: "codex", since: 200, started: 150))
    }

    // "Live Activity detail" (2026-10-28): the tool, the command or file, and the message.
    func testDecodesOldAndNewContentState() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(AgentActivityAttributes.ContentState.self,
                                     from: Data(#"{"state":"done","kind":"claude","since":300,"started":200}"#.utf8))
        XCTAssertNil(old.tool); XCTAssertNil(old.detail); XCTAssertNil(old.msg)
        XCTAssertEqual(old.headline, "Claude finished")
        XCTAssertNil(old.messageLine)

        // As relay.test.js passes it through.
        let json = #"{"state":"waiting","kind":"claude","since":1761512300,"started":1761512200,"tool":"Bash","detail":"rm -rf build — ünïcødé 🚀","msg":"Claude needs your permission to use Bash"}"#
        let new = try decoder.decode(AgentActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(new, .init(state: "waiting", kind: "claude", since: 1761512300, started: 1761512200, tool: "Bash",
                                  detail: "rm -rf build — ünïcødé 🚀", msg: "Claude needs your permission to use Bash"))
        XCTAssertEqual(new.headline, "Claude wants to use Bash")
        XCTAssertEqual(new.detailLine, "rm -rf build — ünïcødé 🚀")
        XCTAssertEqual(new.messageLine, "Claude needs your permission to use Bash")
        // Unknown keys from a later clothod don't break it.
        let later = try decoder.decode(AgentActivityAttributes.ContentState.self,
                                       from: Data(#"{"state":"running","kind":"codex","since":1,"started":1,"tool":"Edit","future":1}"#.utf8))
        XCTAssertEqual(later.headline, "Codex is running Edit")
        XCTAssertEqual(later.compactTool, "Edit")
        XCTAssertEqual(AgentActivityAttributes.ContentState(state: "running", kind: "claude", since: 1, started: 1,
                                                            tool: "mcp__github__create_pr").compactTool, "create_pr")
        XCTAssertNil(old.compactTool)
    }

    func testTextShowsOnlyWhereItApplies() {
        var state = AgentActivityAttributes.ContentState(state: "running", kind: "claude", since: 1, started: 1,
                                                          tool: "Bash", detail: "cargo test\n  --all", msg: "stale")
        XCTAssertEqual(state.detailLine, "cargo test --all", "one line")
        XCTAssertNil(state.messageLine, "no message while running")
        state.state = "done"
        XCTAssertNil(state.detailLine, "no command once it's over")
        XCTAssertEqual(state.messageLine, "stale")
        XCTAssertEqual(state.headline, "Claude finished")
    }

    func testAttributesFromAnEarlierBuildDecode() throws {
        let id = UUID()
        let old = try JSONDecoder().decode(AgentActivityAttributes.self, from: Data(#"{"machine":"\#(id.uuidString)","pane":7}"#.utf8))
        XCTAssertEqual(old.machine, id)
        XCTAssertEqual(old.pane, 7)
        XCTAssertNil(old.place)
        XCTAssertNil(old.prompt)

        let new = AgentActivityAttributes(machine: id, pane: 7, machineName: "devbox", workspace: "Clotho", tab: "orchestrator",
                                          prompt: "Fix the timer")
        XCTAssertEqual(new.place, "devbox · Clotho / orchestrator")
        XCTAssertEqual(AgentActivityAttributes(machine: id, pane: 7, machineName: "devbox").place, "devbox")
        let back = try JSONDecoder().decode(AgentActivityAttributes.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(back.place, new.place)
        XCTAssertEqual(back.prompt, "Fix the timer")
    }

    func testLineTruncates() {
        XCTAssertNil(AgentActivityAttributes.line("  \n "))
        XCTAssertEqual(AgentActivityAttributes.line("a\tb\n\nc"), "a b c")
        let cut = AgentActivityAttributes.line(String(repeating: "x", count: 200), max: 120)
        XCTAssertEqual(cut?.count, 120)
        XCTAssertEqual(cut?.last, "…")
    }

    @MainActor
    func testFirstContentCarriesTheDetail() {
        let running = AgentInfo(kind: "claude", state: .running, message: "earlier", since: 100, tool: "Bash", toolInput: "make\ntest")
        XCTAssertEqual(MachineConnection.activityState(running),
                       .init(state: "running", kind: "claude", since: 100, started: 100, tool: "Bash", detail: "make test"))
        let asking = AgentInfo(kind: "claude", state: .waiting, since: 200, tool: "Read", toolInput: "x",
                               requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "rm -rf build")])
        let state = MachineConnection.activityState(asking)
        XCTAssertEqual(state.tool, "Bash", "the request's tool, as the alert shows")
        XCTAssertEqual(state.detail, "rm -rf build")
        XCTAssertEqual(state.msg, PermissionRequest(id: "r1", tool: "Bash", summary: "rm -rf build").question)
        let done = AgentInfo(kind: "claude", state: .done, message: "All tests pass.", since: 300, tool: "Bash")
        XCTAssertEqual(MachineConnection.activityState(done),
                       .init(state: "done", kind: "claude", since: 300, started: 300, msg: "All tests pass."))
    }
}
#endif
