@testable import Clotho
import SwiftTerm
import XCTest

/// Progress is drawn once, by Clotho (`ProgressStrip`). SwiftTerm's own OSC 9;4 bar must not show in a pane's
/// terminal as well.
@MainActor
final class TerminalProgressBarTests: XCTestCase {
    private func progressBars(in view: UIView) -> [UIView] {
        view.subviews.filter { String(describing: type(of: $0)).contains("ProgressBar") }
    }

    /// A plain SwiftTerm view still has the bar under the name the app looks for. If SwiftTerm renames or
    /// restructures it, this fails and the removal needs another look.
    func testSwiftTermStillHasTheBarUnderThisName() {
        let plain = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        XCTAssertTrue(plain.subviews.contains { String(describing: type(of: $0)) == PaneTerminalView.builtInProgressBarClass },
                      "\(plain.subviews.map { String(describing: type(of: $0)) })")
    }

    func testPaneTerminalHasNoBuiltInBar() {
        let terminal = PaneTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        XCTAssertNil(terminal.builtInProgressBar)
        XCTAssertEqual(progressBars(in: terminal).count, 0)
        XCTAssertNil(terminal.progressReportTimeout)
    }

    func testProgressReportsDrawNothingInTheTerminal() {
        let terminal = PaneTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let before = terminal.subviews.count
        for report in ["\u{1b}]9;4;1;40\u{07}", "\u{1b}]9;4;2;55\u{07}", "\u{1b}]9;4;3\u{07}", "\u{1b}]9;4;4;10\u{07}"] {
            terminal.feedFromBackend(Data(report.utf8))
            // SwiftTerm hands the report to the main queue.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertNil(terminal.builtInProgressBar, report)
            XCTAssertEqual(progressBars(in: terminal).count, 0, report)
            XCTAssertEqual(terminal.subviews.count, before, report)
        }
    }
}
