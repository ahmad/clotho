import ClothoKit
import XCTest
@testable import Clotho

/// The local banner on an attention rise (AgentNotifier.banner), from agents decoded as the daemon sends them.
@MainActor
final class AgentBannerTests: XCTestCase {
    private let machine = Machine(name: "devbox", host: "devbox", user: "user")

    private func agent(_ json: String) throws -> AgentInfo {
        try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    }

    private func banner(_ before: AgentInfo?, _ after: AgentInfo?) -> UNNotificationRequest? {
        AgentNotifier.banner(machine: machine, pane: 7, place: .init(workspace: "Platform", workspaceID: 3, tab: "cargo test"),
                             before: before, after: after)
    }

    func testQuietDoneRiseShowsNoBanner() throws {
        let running = try agent(#"{"kind":"claude","state":"running","source":"hook","attention":false}"#)
        let quietDone = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"quiet":true}"#)
        XCTAssertNil(banner(running, quietDone), "the user was at the pane: no banner, as the daemon sends no push")
        XCTAssertTrue(quietDone.needsAttention, "it still badges and shows in the Agents list")
    }

    func testLoudRisesShowABanner() throws {
        let running = try agent(#"{"kind":"claude","state":"running","source":"hook","attention":false}"#)
        // An older daemon sends no "quiet": that means not quiet.
        let olderDone = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"message":"All tests pass"}"#)
        let request = try XCTUnwrap(banner(running, olderDone))
        XCTAssertEqual(request.content.body, "All tests pass")
        XCTAssertEqual(request.content.userInfo["pane"] as? PaneID, 7)

        let loudDone = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"quiet":false}"#)
        XCTAssertNotNil(banner(running, loudDone))
        let waiting = try agent(#"{"kind":"claude","state":"waiting","source":"hook","attention":true,"quiet":false,"message":"Allow edit?"}"#)
        XCTAssertNotNil(banner(running, waiting))
        XCTAssertNotNil(banner(nil, waiting), "a pane first seen already waiting")
    }

    func testOnlyARiseShowsABanner() throws {
        let waiting = try agent(#"{"kind":"claude","state":"waiting","source":"hook","attention":true}"#)
        let stillWaiting = try agent(#"{"kind":"claude","state":"waiting","source":"hook","attention":true,"message":"Allow edit?"}"#)
        XCTAssertNil(banner(waiting, stillWaiting), "attention was already up")
        let muted = try agent(#"{"kind":"claude","state":"waiting","source":"hook","attention":true,"muted":true}"#)
        XCTAssertNil(banner(nil, muted))
        let detected = try agent(#"{"kind":"claude","state":"waiting"}"#)
        XCTAssertNil(banner(nil, detected), "a detected agent gone quiet doesn't need the user")
        XCTAssertNil(banner(waiting, nil), "the agent went away")
    }
}
