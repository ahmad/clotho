import AppKit
import XCTest
@testable import Clotho

/// Workspace rows read like machine headers: the status dot right after the name, the tab count pinned to
/// the trailing edge, and the close button only under the pointer, in the count's place.
@MainActor
final class WorkspaceRowTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func row(_ name: String, count: String = "2", badge: NSColor? = .systemGreen, width: CGFloat = 240) -> WorkspaceRow {
        let row = WorkspaceRow()
        row.label.stringValue = name
        row.detail.stringValue = count
        row.onClose = {}
        row.setBadge(badge)
        row.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        row.layoutSubtreeIfNeeded()
        return row
    }

    func testDotSitsRightAfterTheName() {
        let row = row("Resolve")
        let label = row.label.alignmentRect(forFrame: row.label.frame)
        XCTAssertEqual(row.badge.frame.minX, label.maxX + s(6), accuracy: 0.5, "the machine header's 6 pt gap")
        XCTAssertEqual(row.badge.frame.size, NSSize(width: s(6), height: s(6)))
        XCTAssertEqual(row.badge.frame.midY, row.label.frame.midY, accuracy: 0.5)
        XCTAssertLessThan(row.badge.frame.maxX, row.bounds.width / 2, "next to a short name, not at the far end")
    }

    func testCountsLineUpOnTheTrailingEdge() {
        let short = row("A", count: "2"), long = row("A much longer workspace name", count: "12", badge: nil)
        let edge = { (row: WorkspaceRow) in row.detail.alignmentRect(forFrame: row.detail.frame).maxX }
        XCTAssertEqual(edge(short), 240 - WorkspaceRow.trailingInset, accuracy: 0.5)
        XCTAssertEqual(edge(short), edge(long), accuracy: 0.5)
    }

    func testLongNamesTruncateBeforeTheDot() {
        let row = row(String(repeating: "Platform ", count: 10), count: "12", width: 200)
        XCTAssertLessThanOrEqual(row.label.frame.maxX, row.badge.frame.minX)
        XCTAssertLessThanOrEqual(row.badge.frame.maxX, row.detail.frame.minX)
        let noDot = self.row(String(repeating: "Platform ", count: 10), count: "12", badge: nil, width: 200)
        XCTAssertLessThanOrEqual(noDot.label.frame.maxX, noDot.detail.frame.minX)
        XCTAssertGreaterThan(noDot.label.frame.width, row.label.frame.width, "no room is kept for a hidden dot")
    }

    func testCloseOnlyOnHoverInTheCountsPlace() {
        let row = row("Platform")
        row.isSelected = true
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.closeButton.isHidden, "selected but not hovered: no close button")
        XCTAssertFalse(row.detail.isHidden)
        let before = (row.label.frame, row.badge.frame, row.detail.frame)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.closeButton.isHidden)
        XCTAssertTrue(row.detail.isHidden, "the × takes the count's place")
        XCTAssertTrue(row.closeButton.frame.intersects(before.2))
        XCTAssertEqual(row.label.frame, before.0, "hovering moves nothing")
        XCTAssertEqual(row.badge.frame, before.1)
        XCTAssertEqual(row.detail.frame, before.2)
        row.setHovering(false)
        XCTAssertTrue(row.closeButton.isHidden)
        XCTAssertFalse(row.detail.isHidden)
    }

    func testRenameHidesCloseAndKeepsCount() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [], backing: .buffered, defer: true)
        let row = row("Platform")
        window.contentView = row
        row.setHovering(true)
        row.beginEditing("Platform") { _ in }
        XCTAssertTrue(row.closeButton.isHidden)
        XCTAssertFalse(row.detail.isHidden)
        row.endEditing(commit: false)
    }
}
