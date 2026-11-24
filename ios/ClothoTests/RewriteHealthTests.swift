import ClothoKit
@testable import Clotho
import XCTest

/// The line under a machine's "Summarize agent messages" switch (`SettingsView.healthCaption`): only a rewrite
/// that isn't working says anything, and only on a daemon with the `alerts` feature.
final class RewriteHealthTests: XCTestCase {
    private func health(_ state: RewriteHealth.State, reason: String? = nil, alerts: Bool = true) -> (text: String, failing: Bool)? {
        SettingsView.healthCaption(RewriteHealth(state: state, reason: reason, at: 1761512345), alerts: alerts)
    }

    func testFailingWithAReason() throws {
        let caption = try XCTUnwrap(health(.failing, reason: "exit 1: Not logged in · Please run /login"))
        XCTAssertEqual(caption.text, "Not working: exit 1: Not logged in · Please run /login")
        XCTAssertTrue(caption.failing)
    }

    func testAMultiLineReasonComesOutOnOneLine() throws {
        let caption = try XCTUnwrap(health(.failing, reason: "  exit 1:\n\tNot logged in\r\n\n  Please run /login \n"))
        XCTAssertEqual(caption.text, "Not working: exit 1: Not logged in Please run /login")
        XCTAssertTrue(caption.failing)
    }

    func testFailingWithoutAReason() throws {
        for reason in [nil, "", " \n "] as [String?] {
            let caption = try XCTUnwrap(health(.failing, reason: reason))
            XCTAssertEqual(caption.text, "Not working")
            XCTAssertTrue(caption.failing)
        }
    }

    func testUnavailable() throws {
        let caption = try XCTUnwrap(health(.unavailable))
        XCTAssertEqual(caption.text, "Claude Code wasn't found on this machine")
        XCTAssertFalse(caption.failing)
    }

    func testWorkingOffAndUnknownSayNothing() {
        for state in [RewriteHealth.State.ok, .unknown, .off] {
            XCTAssertNil(health(state, reason: "left over"), "\(state)")
        }
        XCTAssertNil(SettingsView.healthCaption(nil, alerts: true))
    }

    func testNothingWithoutTheAlertsFeature() {
        for state in RewriteHealth.State.allCases {
            XCTAssertNil(health(state, reason: "exit 1", alerts: false), "\(state)")
        }
        XCTAssertNil(SettingsView.healthCaption(nil, alerts: false))
    }
}
