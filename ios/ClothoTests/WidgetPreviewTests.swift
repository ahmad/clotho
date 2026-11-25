import ClothoKit
import SwiftUI
import WidgetKit
import XCTest
@testable import Clotho

/// Renders the "Needs you" widget's sizes as images (attached to the test), for review: WidgetKit itself
/// can't be driven from XCUITest. Also checks each size renders at its usual point size.
@MainActor
final class WidgetPreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_512_345)

    private var entry: NeedsYouEntry {
        let machine = UUID(uuidString: "00000000-0000-0000-0000-00000000C10D")!
        return NeedsYouEntry(date: now, summary: AgentsSummary(updated: now.timeIntervalSince1970, agents: [
            .init(machine: machine, machineName: "devbox", pane: 7, workspace: "Platform", kind: "claude", state: "waiting",
                  since: now.timeIntervalSince1970 - 120),
            .init(machine: machine, machineName: "devbox", pane: 9, workspace: "api-server", kind: "codex", state: "error",
                  since: now.timeIntervalSince1970 - 900),
            .init(machine: UUID(), machineName: "imac", pane: 3, workspace: "Notes", kind: "claude", state: "done",
                  since: now.timeIntervalSince1970 - 4000, needsUser: false),
        ]))
    }

    private func agent(_ state: String, _ needsUser: Bool?, kind: String = "claude") -> AgentsSummary.Agent {
        .init(machine: UUID(), machineName: "devbox", pane: 1, workspace: "Platform", kind: kind, state: state,
              since: now.timeIntervalSince1970, needsUser: needsUser)
    }

    /// Every number counts only the agents that need the user; a plain Done is listed but not counted.
    func testCountsLeaveOutPlainDone() {
        XCTAssertEqual(entry.summary.agents.count, 3)
        XCTAssertEqual(entry.summary.needingYou, 2)
        XCTAssertEqual(NeedsYouView.heading(2), "2 need you")
        XCTAssertEqual(NeedsYouView.heading(1), "1 needs you")
        XCTAssertEqual(NeedsYouView.heading(0), "No agents need you")
        let onlyDone = AgentsSummary(updated: 1, agents: [agent("done", false)])
        XCTAssertEqual(onlyDone.needingYou, 0)
        // Done without the flag (an older daemon) and done that needs the user both count.
        XCTAssertEqual(AgentsSummary(updated: 1, agents: [agent("done", nil), agent("done", true)]).needingYou, 2)
        XCTAssertEqual(AgentsSummary.empty.needingYou, 0)
    }

    /// ClothoKit's wording by `needsUser`; without it, by the state as before.
    func testWordingByNeedsUser() {
        XCTAssertEqual(NeedsYouView.what(agent("waiting", true)), "Claude needs you")
        XCTAssertEqual(NeedsYouView.what(agent("error", true, kind: "codex")), "Codex needs you")
        XCTAssertEqual(NeedsYouView.what(agent("done", true)), "Claude needs you")
        XCTAssertEqual(NeedsYouView.what(agent("done", false)), "Claude is done")
        XCTAssertEqual(NeedsYouView.what(agent("waiting", nil)), "Claude is waiting")
        XCTAssertEqual(NeedsYouView.what(agent("done", nil)), "Claude finished")
        XCTAssertEqual(NeedsYouView.what(agent("error", nil, kind: "codex")), "Codex hit an error")
    }

    /// Any kind (clothod 0.1.33): a kind ClothoKit's table knows by its name and symbol, one it doesn't by its
    /// own text, and "other" as "Agent", both with the generic symbol. The symbol is the table's, never a
    /// name made from the kind.
    func testRowsNameAndDrawAnyKind() throws {
        XCTAssertEqual(NeedsYouView.what(agent("waiting", true, kind: "copilot")), "Copilot needs you")
        XCTAssertEqual(NeedsYouView.symbol(agent("waiting", true, kind: "copilot")), "eyeglasses")
        XCTAssertEqual(NeedsYouView.what(agent("done", false, kind: "gemini")), "Gemini is done")
        XCTAssertEqual(NeedsYouView.symbol(agent("done", false, kind: "gemini")), "sparkles")
        XCTAssertEqual(NeedsYouView.symbol(agent("waiting", true)), "sparkle")
        XCTAssertEqual(NeedsYouView.what(agent("error", true, kind: "deploy")), "deploy needs you")
        XCTAssertEqual(NeedsYouView.symbol(agent("error", true, kind: "deploy")), AgentKind.genericSymbol)
        XCTAssertEqual(NeedsYouView.what(agent("done", nil, kind: "other")), "Agent finished")
        XCTAssertEqual(NeedsYouView.symbol(agent("done", nil, kind: "other")), AgentKind.genericSymbol)
        XCTAssertEqual(NeedsYouView.what(agent("waiting", true, kind: "")), "Agent needs you")
        // A kind that is itself a symbol's name still draws the generic one.
        XCTAssertEqual(NeedsYouView.symbol(agent("waiting", true, kind: "star.fill")), AgentKind.genericSymbol)
        XCTAssertEqual(NeedsYouView.what(agent("waiting", true, kind: "star.fill")), "star.fill needs you")
        // Every symbol a row can draw exists.
        for kind in ["claude", "codex", "opencode", "gemini", "copilot", "aider", "amp", "cursor", "other", "deploy"] {
            XCTAssertNotNil(UIImage(systemName: AgentKind.of(kind).symbolName), kind)
        }

        let machine = UUID(uuidString: "00000000-0000-0000-0000-00000000C10D")!
        let kinds = NeedsYouEntry(date: now, summary: AgentsSummary(updated: now.timeIntervalSince1970, agents: [
            .init(machine: machine, machineName: "devbox", pane: 7, workspace: "Platform", kind: "copilot", state: "waiting",
                  since: now.timeIntervalSince1970 - 120, needsUser: true),
            .init(machine: machine, machineName: "devbox", pane: 9, workspace: "Releases", kind: "deploy", state: "error",
                  since: now.timeIntervalSince1970 - 900, needsUser: true),
            .init(machine: machine, machineName: "devbox", pane: 3, workspace: "Notes", kind: "other", state: "done",
                  since: now.timeIntervalSince1970 - 4000, needsUser: false),
        ]))
        for (family, size, name) in [(WidgetFamily.systemSmall, CGSize(width: 170, height: 170), "small"),
                                     (.systemMedium, CGSize(width: 364, height: 170), "medium")] {
            for scheme in [ColorScheme.light, .dark] {
                let view = NeedsYouView(entry: kinds, family: family).padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
                XCTAssertEqual(image.size, size, name)
                let shot = XCTAttachment(image: image)
                shot.name = "widget kinds \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    /// A summary stored by an older app or extension has no `needsUser`: it still decodes, and reads as before.
    func testOldSummaryDecodes() throws {
        let json = #"{"updated":42,"agents":[{"machine":"00000000-0000-0000-0000-00000000C10D","machineName":"devbox","pane":7,"workspace":"Platform","kind":"claude","state":"done","since":40}]}"#
        let summary = try JSONDecoder().decode(AgentsSummary.self, from: Data(json.utf8))
        let old = try XCTUnwrap(summary.agents.first)
        XCTAssertNil(old.needsUser)
        XCTAssertEqual(summary.needingYou, 1)
        XCTAssertEqual(NeedsYouView.what(old), "Claude finished")
        // And what this app writes without the flag is what the older one reads: no key.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(summary), as: UTF8.self).contains("needsUser"))
        var flagged = old
        flagged.needsUser = false
        let back = try JSONDecoder().decode(AgentsSummary.Agent.self, from: try JSONEncoder().encode(flagged))
        XCTAssertEqual(back.needsUser, false)
    }

    /// Only plain Done agents: they list under "No agents need you", and the numbers read 0.
    func testOnlyPlainDoneRenders() throws {
        let done = NeedsYouEntry(date: now, summary: AgentsSummary(updated: 1, agents: [agent("done", false)]))
        for family in [WidgetFamily.systemSmall, .accessoryRectangular, .accessoryCircular] {
            XCTAssertNotNil(ImageRenderer(content: NeedsYouView(entry: done, family: family).frame(width: 170, height: 170)).uiImage)
        }
    }

    func testRendersEverySize() throws {
        let sizes: [(WidgetFamily, CGSize, String)] = [
            (.systemSmall, CGSize(width: 170, height: 170), "small"),
            (.systemMedium, CGSize(width: 364, height: 170), "medium"),
            (.accessoryRectangular, CGSize(width: 172, height: 76), "lock screen rectangular"),
            (.accessoryCircular, CGSize(width: 76, height: 76), "lock screen circular"),
        ]
        for (family, size, name) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let view = NeedsYouView(entry: entry, family: family)
                    .padding(family == .systemSmall || family == .systemMedium ? 16 : 4)
                    .frame(width: size.width, height: size.height)
                    .background(family == .systemSmall || family == .systemMedium ? Color(.secondarySystemBackground) : Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: family == .accessoryCircular ? 38 : 20))
                    .environment(\.colorScheme, family == .accessoryRectangular || family == .accessoryCircular ? .dark : scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
                XCTAssertEqual(image.size, size, name)
                let shot = XCTAttachment(image: image)
                shot.name = "widget \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    func testEmptyWidgetSaysSo() throws {
        let empty = NeedsYouEntry(date: now, summary: .empty)
        XCTAssertNotNil(ImageRenderer(content: NeedsYouView(entry: empty, family: .systemSmall).frame(width: 170, height: 170)).uiImage)
    }

    #if LIVE_ACTIVITIES
    // The Live Activity's lock screen, with the detail (2026-10-28), for review.
    func testRendersTheLiveActivity() throws {
        let attributes = AgentActivityAttributes(machine: UUID(), pane: 7, machineName: "devbox", workspace: "Clotho",
                                                 tab: "orchestrator", prompt: "Make the Live Activity show what Claude is doing")
        let started = Int(Date().timeIntervalSince1970) - 754
        let states: [(String, AgentActivityAttributes.ContentState)] = [
            ("running", .init(state: "running", kind: "claude", since: started + 700, started: started, tool: "Bash",
                              detail: "cd ios && ./build.sh test -only-testing:ClothoTests/AgentActivityTests")),
            ("waiting", .init(state: "waiting", kind: "claude", since: started + 700, started: started, tool: "Bash",
                              detail: "rm -rf ios/build", msg: "Claude needs your permission to use Bash")),
            ("done", .init(state: "done", kind: "claude", since: started + 754, started: started,
                           msg: "The Live Activity now shows the tool, the command and the last message, and the timer sits on the right.")),
            ("old clothod", .init(state: "running", kind: "claude", since: started, started: started)),
        ]
        for (name, state) in states {
            for scheme in [ColorScheme.light, .dark] {
                let view = AgentActivityLockScreen(attributes: attributes, state: state)
                    .frame(width: 364)
                    .background(Color(.secondarySystemBackground))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
                XCTAssertEqual(image.size.width, 364, name)
                let shot = XCTAttachment(image: image)
                shot.name = "live activity \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    /// The Live Activity names any kind as the rest of the app does. Its `kind` is the relay's fit of the
    /// agent's (`AgentActivityAttributes.relayKind`), only ever shown as text.
    func testLiveActivityNamesAnyKind() throws {
        func state(_ kind: String, _ state: String, tool: String? = nil, msg: String? = nil) -> AgentActivityAttributes.ContentState {
            .init(state: state, kind: kind, since: 2, started: 1, tool: tool, msg: msg)
        }
        XCTAssertEqual(state("claude", "running").name, "Claude")
        XCTAssertEqual(state("copilot", "running").name, "Copilot")
        XCTAssertEqual(state("copilot", "running", tool: "Bash").headline, "Copilot is running Bash")
        XCTAssertEqual(state("copilot", "waiting", tool: "Edit").headline, "Copilot wants to use Edit")
        XCTAssertEqual(state("deploy", "running").name, "deploy")
        XCTAssertEqual(state("deploy", "done").headline, "deploy finished")
        XCTAssertEqual(state("claude-code", "error").headline, "claude-code hit an error")
        XCTAssertEqual(state("other", "running").name, "Agent")
        XCTAssertEqual(state("other", "waiting").headline, "Agent is waiting for you")
        XCTAssertEqual(state("other", "running").headline, "Agent is working")
        // A coding agent's message is Markdown; any other kind's shows as typed.
        XCTAssertEqual(state("copilot", "done", msg: "**All** tests pass.").messageLine, "All tests pass.")
        XCTAssertEqual(state("deploy", "done", msg: "**All**\ttests pass.").messageLine, "**All** tests pass.")
        XCTAssertEqual(state("other", "waiting", msg: "press `enter`").messageLine, "press `enter`")
        XCTAssertNil(state("other", "running", msg: "x").messageLine)

        let attributes = AgentActivityAttributes(machine: UUID(), pane: 7, machineName: "devbox", workspace: "Releases", tab: "deploy")
        let started = Int(Date().timeIntervalSince1970) - 90
        let shown: [(String, AgentActivityAttributes.ContentState)] = [
            ("copilot", .init(state: "running", kind: "copilot", since: started + 60, started: started, tool: "Bash", detail: "npm test")),
            ("unknown kind", .init(state: "done", kind: "deploy", since: started + 90, started: started, msg: "deployed **v1.4** to `prod`")),
            ("other", .init(state: "waiting", kind: "other", since: started + 80, started: started, msg: "Press enter to continue")),
        ]
        for (name, content) in shown {
            let view = AgentActivityLockScreen(attributes: attributes, state: content)
                .frame(width: 364)
                .background(Color(.secondarySystemBackground))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
            XCTAssertEqual(image.size.width, 364, name)
            let shot = XCTAttachment(image: image)
            shot.name = "live activity kind \(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// The first content's kind is the one clothod sends next (`Live::content` in clothod's push.rs).
    func testLiveActivityKindFitsTheRelay() {
        XCTAssertEqual(AgentActivityAttributes.relayKind("claude"), "claude")
        XCTAssertEqual(AgentActivityAttributes.relayKind("Claude Code"), "claude-code")
        XCTAssertEqual(AgentActivityAttributes.relayKind("9lives"), "other")
        XCTAssertEqual(AgentActivityAttributes.relayKind(""), "other")
        XCTAssertEqual(AgentActivityAttributes.relayKind("\u{FC}n\u{EF}"), "other")
        XCTAssertEqual(AgentActivityAttributes.relayKind("nightly.backup"), "nightly-backup")
        XCTAssertEqual(AgentActivityAttributes.relayKind(String(repeating: "a", count: 40)).count, 32)
        // What it then reads as.
        XCTAssertEqual(AgentInfo.shortName(ofKind: AgentActivityAttributes.relayKind("Claude Code")), "claude-code")
        XCTAssertEqual(AgentInfo.shortName(ofKind: AgentActivityAttributes.relayKind("9lives")), "Agent")
    }

    /// The user saw the timer centred: a timer Text fills the width it's given and centres in it. Rendered in
    /// the lock screen's 84 pt slot, its ink must end at the slot's right edge, running or finished.
    func testTimerHugsTheRightEdge() throws {
        let started = Int(Date().timeIntervalSince1970) - 75
        for state in [AgentActivityAttributes.ContentState(state: "running", kind: "claude", since: started, started: started),
                      .init(state: "done", kind: "claude", since: started + 75, started: started)] {
            let view = ActivityTimer(state: state).font(.title3.monospacedDigit()).foregroundStyle(.black)
                .frame(width: 84, height: 30, alignment: .trailing).background(.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let (left, right) = try XCTUnwrap(Self.inkColumns(image), state.state)
            XCTAssertGreaterThanOrEqual(right, 84 - 4, "\(state.state): the time ends at the right edge")
            XCTAssertGreaterThan(left, 20, "\(state.state): and doesn't start at the left (\(left)–\(right))")
        }
    }

    /// The first and last columns with any dark pixel.
    private static func inkColumns(_ image: CGImage) -> (Int, Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let dark = (0..<width).filter { x in (0..<height).contains { y in pixels[(y * width + x) * 4] < 128 } }
        guard let first = dark.first, let last = dark.last else { return nil }
        return (first, last + 1)
    }
    #endif
}
