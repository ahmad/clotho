import AppKit
import XCTest
@testable import Clotho

/// Sidebar rows: the workspace's chevron and name, tabs indented under it, and every row's status dot
/// pinned to one trailing edge, where the close button takes its place under the pointer.
@MainActor
final class WorkspaceRowTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func laidOut<Row: SidebarRow>(_ row: Row, _ title: String, badge: NSColor? = .systemGreen, width: CGFloat = 240) -> Row {
        row.label.stringValue = title
        row.onClose = {}
        row.setBadge(badge)
        row.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        row.layoutSubtreeIfNeeded()
        return row
    }

    func testDotsLineUpOnTheTrailingEdge() {
        let workspace = laidOut(WorkspaceRow(expanded: false), "A")
        let tab = laidOut(TabRow(), "A much longer tab title")
        XCTAssertEqual(workspace.badge.frame.midX, 240 - SidebarRow.dotInset, accuracy: 0.5)
        XCTAssertEqual(tab.badge.frame.midX, workspace.badge.frame.midX, accuracy: 0.5)
        XCTAssertEqual(tab.badge.frame.midY, tab.bounds.midY, accuracy: 0.5)
    }

    /// The first click into a background window selects, as in Finder's sidebar, instead of only
    /// bringing the window forward.
    func testRowsTakeTheFirstClick() {
        XCTAssertTrue(WorkspaceRow().acceptsFirstMouse(for: nil))
        XCTAssertTrue(TabRow().acceptsFirstMouse(for: nil))
    }

    func testTabsIndentPastTheWorkspaceName() {
        let workspace = laidOut(WorkspaceRow(), "Platform")
        let tab = laidOut(TabRow(), "zsh")
        // Constraints place the alignment rect, which NSTextField keeps a little inside its frame.
        XCTAssertEqual(workspace.label.alignmentRect(forFrame: workspace.label.frame).minX, MachineHeader.nameInset, accuracy: 1,
                       "in line with the machine's name")
        XCTAssertGreaterThan(tab.label.frame.minX, workspace.label.frame.minX + s(6), "past the guide's arm")
        XCTAssertLessThan(tab.label.font!.pointSize, workspace.label.font!.pointSize, "tabs a touch smaller")
        XCTAssertNotNil(workspace.chevron)
        XCTAssertNil(tab.chevron)
        XCTAssertLessThan(workspace.chevron!.frame.maxX, workspace.label.frame.minX)
    }

    func testLongTitlesTruncateBeforeTheDot() {
        let row = laidOut(TabRow(), String(repeating: "Platform ", count: 10), width: 200)
        XCTAssertLessThan(row.label.frame.maxX, row.badge.frame.minX)
        let noDot = laidOut(TabRow(), String(repeating: "Platform ", count: 10), badge: nil, width: 200)
        XCTAssertEqual(noDot.label.frame.maxX, row.label.frame.maxX, accuracy: 0.5, "titles end at one edge, dot or not")
    }

    func testCloseOnlyOnHoverInTheDotsPlace() {
        let row = laidOut(TabRow(), "zsh")
        row.isSelected = true
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.closeButton.isHidden, "selected but not hovered: no close button")
        XCTAssertFalse(row.badge.isHidden)
        let before = (row.label.frame, row.badge.frame)
        row.setHovering(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.closeButton.isHidden)
        XCTAssertTrue(row.badge.isHidden, "the × takes the dot's place")
        XCTAssertEqual(row.closeButton.frame.midX, before.1.midX, accuracy: 0.5)
        XCTAssertEqual(row.label.frame, before.0, "hovering moves nothing")
        row.setHovering(false)
        XCTAssertTrue(row.closeButton.isHidden)
        XCTAssertFalse(row.badge.isHidden)
        // No dot: hovering shows only the ×, and leaving shows nothing.
        let plain = laidOut(TabRow(), "zsh", badge: nil)
        XCTAssertTrue(plain.badge.isHidden)
        plain.setHovering(true)
        XCTAssertTrue(plain.badge.isHidden)
    }

    func testRenameHidesClose() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [], backing: .buffered, defer: true)
        let row = laidOut(WorkspaceRow(), "Platform")
        row.onNewTab = {}
        window.contentView = row
        row.setHovering(true)
        XCTAssertFalse(row.closeButton.isHidden, "the + shows on hover")
        row.beginEditing("Platform") { _ in }
        XCTAssertTrue(row.closeButton.isHidden)
        row.endEditing(commit: false)
    }

    /// The chevron's column toggles (Option: every workspace); the rest of the row selects.
    func testChevronTogglesAndTheRowSelects() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [], backing: .buffered, defer: true)
        let row = laidOut(WorkspaceRow(), "Platform")
        window.contentView = row
        var toggles: [Bool] = [], clicks = 0
        row.onToggle = { toggles.append($0) }
        row.onClick = { clicks += 1 }
        func click(x: CGFloat, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: row.convert(NSPoint(x: x, y: 14), to: nil),
                                                         modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            row.mouseDown(with: event)
        }
        try click(x: s(17))
        try click(x: s(17), .option)
        try click(x: 120)
        XCTAssertEqual(toggles, [false, true])
        XCTAssertEqual(clicks, 1)
    }
}
