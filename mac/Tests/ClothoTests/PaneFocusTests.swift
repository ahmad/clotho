import ClothoKit
import XCTest
@testable import Clotho

/// One focus action sends one `pane.focus`, however many of its signals fire (first responder, window
/// key, app active, a click), and only for a pane that really has the user's focus.
@MainActor
final class PaneFocusTests: XCTestCase {
    func testOneActionSendsOneFocus() {
        var current: PaneKey? = PaneKey(machine: AppDelegate.localKey, pane: 7)
        var sent: [(PaneID, String)] = []
        var clock = Date(timeIntervalSince1970: 1000)
        let reporter = PaneFocusReporter(current: { current }) { key, reason in sent.append((key.pane, reason)) }
        reporter.now = { clock }

        // A click that activates the app: active, key, first responder, the click itself.
        for reason in ["app became active", "window became key", "pane took the keyboard", "click"] { reporter.note(reason) }
        reporter.flush()
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7], "one call for the whole action")
        XCTAssertEqual(sent.first?.1, "app became active", "named for what started it")

        // The same pane again right away is the same action.
        clock += 0.1
        reporter.note("click")
        reporter.flush()
        XCTAssertEqual(sent.count, 1)

        // Another pane (a tab switch) goes out at once.
        current = PaneKey(machine: AppDelegate.localKey, pane: 8)
        reporter.note("pane took the keyboard")
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7, 8])

        // Back in the same pane later (from the phone): a click sends again.
        clock += 5
        reporter.note("click")
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7, 8, 8])

        // Leaving and coming back quickly is still a new action.
        clock += 0.05
        reporter.forget()
        reporter.note("app became active")
        reporter.flush()
        XCTAssertEqual(sent.map(\.0), [7, 8, 8, 8])

        // Nothing focused (another window is key, a field has the keyboard): nothing sent.
        current = nil
        clock += 5
        reporter.note("window became key")
        reporter.flush()
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(reporter.sent, 4)
    }

    func testNotesCoalesceOnTheRunLoop() async throws {
        var sent = 0
        let reporter = PaneFocusReporter(current: { PaneKey(machine: AppDelegate.localKey, pane: 1) }) { _, _ in sent += 1 }
        for _ in 0..<20 { reporter.note("storm") }
        XCTAssertEqual(sent, 0, "not sent inside the action")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sent, 1)
    }
}
