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

    /// The title says what the banner wants, from the daemon's `needs_user`, and where (AlertText.title); the
    /// body stays AgentNotice's.
    func testTitleSaysNeedsYouOrDone() throws {
        let asking = try agent(#"{"kind":"claude","state":"waiting","source":"hook","attention":true,"needs_user":true,"message":"Which database?"}"#)
        XCTAssertEqual(banner(nil, asking)?.content.title, "Needs you · Platform › cargo test")
        XCTAssertEqual(banner(nil, asking)?.content.body, "Which database?")
        let question = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"needs_user":true,"message":"Shall I push?"}"#)
        XCTAssertEqual(banner(nil, question)?.content.title, "Needs you · Platform › cargo test")
        let failed = try agent(#"{"kind":"claude","state":"error","source":"hook","attention":true,"needs_user":true}"#)
        XCTAssertEqual(banner(nil, failed)?.content.title, "Needs you · Platform › cargo test")
        let finished = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"needs_user":false,"message":"All tests pass"}"#)
        XCTAssertEqual(banner(nil, finished)?.content.title, "Done · Platform › cargo test")
        XCTAssertEqual(banner(nil, finished)?.content.body, "All tests pass")
        // An older daemon sends no needs_user: the title is AgentNotice's, as before.
        let older = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"message":"All tests pass"}"#)
        XCTAssertEqual(banner(nil, older)?.content.title,
                       AgentNotifier.notice(machine: machine, place: .init(workspace: "Platform", workspaceID: 3, tab: "cargo test"), agent: older).title)
        XCTAssertEqual(banner(nil, older)?.content.title, "Platform · Claude finished")
    }

    /// A turn that only finished is silent; anything the user has to act on, or from an older daemon, keeps its sound.
    func testOnlyAPlainDoneIsSilent() throws {
        let finished = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"needs_user":false}"#)
        let plain = try XCTUnwrap(banner(nil, finished), "a plain Done still shows a banner")
        XCTAssertNil(plain.content.sound)
        let question = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"needs_user":true}"#)
        XCTAssertNotNil(try XCTUnwrap(banner(nil, question)).content.sound, "done, but the user has to answer")
        let older = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true}"#)
        XCTAssertNotNil(try XCTUnwrap(banner(nil, older)).content.sound, "an older daemon: as before")
        let asking = try agent(#"{"kind":"claude","state":"waiting","source":"hook","attention":true,"needs_user":true}"#)
        XCTAssertNotNil(try XCTUnwrap(banner(nil, asking)).content.sound)
        let failed = try agent(#"{"kind":"claude","state":"error","source":"hook","attention":true,"needs_user":false}"#)
        XCTAssertNotNil(try XCTUnwrap(banner(nil, failed)).content.sound, "only done is ever silent")
    }

    /// A turn in the daemon's settle window hasn't asked for the user yet: no banner until attention rises.
    func testSettlingShowsNoBanner() throws {
        let running = try agent(#"{"kind":"claude","state":"running","source":"hook","attention":false}"#)
        let settling = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":false,"settling":true}"#)
        XCTAssertNil(banner(running, settling))
        let odd = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"settling":true,"needs_user":true}"#)
        XCTAssertNil(banner(running, odd), "settling wins, whatever else came with it")
        // The window ends: attention rises, and that is the rise the banner is for.
        let settled = try agent(#"{"kind":"claude","state":"done","source":"hook","attention":true,"needs_user":false}"#)
        XCTAssertNotNil(banner(settling, settled))
    }
}
