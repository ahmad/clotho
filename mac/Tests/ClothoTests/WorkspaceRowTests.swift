import AppKit
import XCTest
@testable import Clotho

/// A workspace row: its name in line with the machine's, its most urgent agent's dot pinned to the trailing
/// edge, and under the pointer a + (New Tab) in the dot's place.
@MainActor
final class WorkspaceRowTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func laidOut(_ title: String, badge: NSColor? = .systemGreen, width: CGFloat = 240) -> WorkspaceRow {
        let row = WorkspaceRow()
        row.label.stringValue = title
        row.onNewTab = {}
        row.setBadge(badge)
        row.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        row.layoutSubtreeIfNeeded()
        return row
    }

    func testTheDotSitsOnTheTrailingEdge() {
        let row = laidOut("A")
        XCTAssertEqual(row.badge.frame.midX, 240 - SidebarRow.dotInset, accuracy: 0.5)
        XCTAssertEqual(row.badge.frame.midY, row.bounds.midY, accuracy: 0.5)
    }

    /// The first click into a background window selects, as in Finder's sidebar, instead of only
    /// bringing the window forward.
    func testRowsTakeTheFirstClick() {
        XCTAssertTrue(WorkspaceRow().acceptsFirstMouse(for: nil))
    }

    func testNamesLineUpWithTheMachine() {
        let row = laidOut("Platform")
        // Constraints place the alignment rect, which NSTextField keeps a little inside its frame.
        XCTAssertEqual(row.label.alignmentRect(forFrame: row.label.frame).minX, MachineHeader.nameInset, accuracy: 1,
                       "in line with the machine's name")
    }

    func testLongNamesTruncateBeforeTheDot() {
        let row = laidOut(String(repeating: "Platform ", count: 10), width: 200)
        XCTAssertLessThan(row.label.frame.maxX, row.badge.frame.minX)
        let noDot = laidOut(String(repeating: "Platform ", count: 10), badge: nil, width: 200)
        XCTAssertEqual(noDot.label.frame.maxX, row.label.frame.maxX, accuracy: 0.5, "names end at one edge, dot or not")
    }

    func testPlusOnlyOnHoverInTheDotsPlace() {
        let row = laidOut("Platform")
        row.isSelected = true
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.newTabButton.isHidden, "selected but not hovered: no +")
        XCTAssertFalse(row.badge.isHidden)
        let before = (row.label.frame, row.badge.frame)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.newTabButton.isHidden)
        XCTAssertEqual(row.newTabButton.accessibilityLabel(), "New Tab")
        XCTAssertTrue(row.badge.isHidden, "the + takes the dot's place")
        XCTAssertEqual(row.newTabButton.frame.midX, before.1.midX, accuracy: 0.5)
        XCTAssertEqual(row.label.frame, before.0, "hovering moves nothing")
        let visible = row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(visible.map { $0.accessibilityLabel() }, ["New Tab"], "no close button on a workspace")
        row.setHovering(false)
        XCTAssertTrue(row.newTabButton.isHidden)
        XCTAssertFalse(row.badge.isHidden)
    }

    func testRenameHidesThePlus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [], backing: .buffered, defer: true)
        let row = laidOut("Platform")
        window.contentView = row
        row.setHovering(true)
        XCTAssertFalse(row.newTabButton.isHidden, "the + shows on hover")
        row.beginEditing("Platform") { _ in }
        XCTAssertTrue(row.newTabButton.isHidden)
        row.endEditing(commit: false)
    }
}
