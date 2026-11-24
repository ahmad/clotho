import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// A workspace row: its name in line with the machine's, then on the trailing edge its agents chip and its
/// tab count; under the pointer a + (New Tab) takes the tab count's place and the chip stays.
@MainActor
final class WorkspaceRowTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func laidOut(_ title: String, mark: AgentMarkCount? = AgentMarkCount(mark: .done, count: 1), tabs: Int = 3,
                         width: CGFloat = 240) -> WorkspaceRow {
        let row = WorkspaceRow()
        row.label.stringValue = title
        row.onNewTab = {}
        row.set(mark: mark, tabs: tabs)
        row.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func rect(_ view: NSView) -> NSRect { view.alignmentRect(forFrame: view.frame) }

    func testTheChipSaysTheMostUrgentStateAndItsCount() {
        for (mark, count, content) in [(AgentMark.needsYou, 2, AgentChip.Content.count(2)), (.error, 1, .count(1)),
                                       (.working, 3, .count(3)), (.done, 2, .check)] {
            let row = laidOut("clotho", mark: AgentMarkCount(mark: mark, count: count))
            XCTAssertFalse(row.badge.isHidden)
            XCTAssertEqual(row.badge.value, AgentMarkCount(mark: mark, count: count))
            XCTAssertEqual(AgentChip.content(row.badge.value), content, "\(mark)")
            XCTAssertEqual(row.badge.label.isHidden, mark == .done)
            XCTAssertEqual(row.badge.check.isHidden, mark != .done, "a check for finished agents, a number for the rest")
            if mark != .done { XCTAssertEqual(row.badge.label.stringValue, "\(count)") }
        }
        XCTAssertTrue(laidOut("clotho", mark: nil).badge.isHidden, "no agents with a mark: no chip")
    }

    /// The workspace's mark is its most urgent agent's (what the sidebar passes the row).
    func testMostUrgentWins() {
        let agent = { (state: AgentInfo.State, attention: Bool?) in AgentInfo(kind: "claude", state: state, source: "hook", attention: attention) }
        let mixed = [agent(.running, nil), agent(.done, true), agent(.waiting, true), agent(.running, nil), agent(.waiting, true)]
        XCTAssertEqual(AgentMark.summary(of: mixed), AgentMarkCount(mark: .needsYou, count: 2))
        XCTAssertEqual(AgentMark.summary(of: [agent(.running, nil), agent(.error, true), agent(.done, true)]), AgentMarkCount(mark: .error, count: 1))
        XCTAssertEqual(AgentMark.summary(of: [agent(.running, nil), agent(.done, true), agent(.running, nil)]), AgentMarkCount(mark: .done, count: 1))
        XCTAssertEqual(AgentMark.summary(of: [agent(.running, nil), agent(.running, nil)]), AgentMarkCount(mark: .working, count: 2))
        XCTAssertNil(AgentMark.summary(of: [agent(.done, false)]))
    }

    func testTheTabCountSitsOnTheTrailingEdgeAfterTheChip() {
        let row = laidOut("A")
        XCTAssertEqual(row.tabCount.stringValue, "3 tabs")
        XCTAssertEqual(row.tabCount.textColor, Theme.dimText)
        XCTAssertEqual(rect(row.tabCount).maxX, 240 - s(8), accuracy: 0.5)
        XCTAssertEqual(row.tabCount.frame.midY, row.bounds.midY, accuracy: 1)
        XCTAssertEqual(row.badge.frame.maxX, rect(row.tabCount).minX - s(6), accuracy: 0.5, "[chip] [N tabs]")
        XCTAssertEqual(row.badge.frame.midY, row.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(laidOut("A", tabs: 1).tabCount.stringValue, "1 tab")
    }

    func testDigitsOnlyWhenNarrow() {
        let narrow = laidOut("clotho", width: 134)
        XCTAssertTrue(narrow.isCompact)
        XCTAssertEqual(narrow.tabCount.stringValue, "3")
        XCTAssertEqual(narrow.tabCount.toolTip, "3 tabs")
        XCTAssertEqual(narrow.tabCount.accessibilityLabel(), "3 tabs")
        XCTAssertEqual(narrow.accessibilityLabel(), "clotho, 1 done, 3 tabs")
        XCTAssertLessThanOrEqual(narrow.badge.frame.maxX, narrow.tabCount.frame.minX)
        XCTAssertLessThanOrEqual(narrow.label.frame.maxX, narrow.badge.frame.minX)
        XCTAssertEqual(laidOut("clotho", width: 179).tabCount.stringValue, "3")
        XCTAssertEqual(laidOut("clotho", width: 180).tabCount.stringValue, "3 tabs")
        // It follows the row's width.
        narrow.frame.size.width = 220
        narrow.layoutSubtreeIfNeeded()
        XCTAssertEqual(narrow.tabCount.stringValue, "3 tabs")
        XCTAssertEqual(rect(narrow.tabCount).maxX, 220 - s(8), accuracy: 0.5)
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(laidOut("clotho", mark: AgentMarkCount(mark: .needsYou, count: 1)).accessibilityLabel(), "clotho, 1 needs you, 3 tabs")
        XCTAssertEqual(laidOut("clotho", mark: AgentMarkCount(mark: .working, count: 2), tabs: 1).accessibilityLabel(), "clotho, 2 working, 1 tab")
        XCTAssertEqual(laidOut("clotho", mark: nil).accessibilityLabel(), "clotho, 3 tabs")
        XCTAssertTrue(laidOut("clotho").isAccessibilityElement())
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

    func testLongNamesTruncateBeforeTheChip() {
        let long = String(repeating: "Platform ", count: 10)
        let row = laidOut(long, width: 200)
        XCTAssertLessThanOrEqual(rect(row.label).maxX, row.badge.frame.minX - s(6) + 0.5)
        XCTAssertGreaterThan(row.label.frame.width, 40, "and still shows")
        // With no chip the name runs up to the tab count.
        let plain = laidOut(long, mark: nil, width: 200)
        XCTAssertLessThanOrEqual(rect(plain.label).maxX, rect(plain.tabCount).minX - s(8) + 0.5)
        XCTAssertGreaterThan(plain.label.frame.maxX, row.label.frame.maxX)
        // Narrow, with a two-digit chip.
        let narrow = laidOut(long, mark: AgentMarkCount(mark: .needsYou, count: 12), tabs: 14, width: 134)
        XCTAssertLessThanOrEqual(rect(narrow.label).maxX, narrow.badge.frame.minX)
        XCTAssertGreaterThan(narrow.label.frame.width, 30)
    }

    func testPlusOnlyOnHoverInTheTabCountsPlace() {
        for width in [240, 134] as [CGFloat] {
            let row = laidOut("Platform", width: width)
            row.isSelected = true
            row.layoutSubtreeIfNeeded()
            XCTAssertTrue(row.newTabButton.isHidden, "selected but not hovered: no +")
            XCTAssertFalse(row.tabCount.isHidden)
            XCTAssertFalse(row.badge.isHidden)
            let before = (row.label.frame, row.badge.frame, row.tabCount.frame)
            row.setHovering(true)
            row.layoutSubtreeIfNeeded()
            XCTAssertFalse(row.newTabButton.isHidden)
            XCTAssertEqual(row.newTabButton.accessibilityLabel(), "New Tab")
            XCTAssertTrue(row.tabCount.isHidden, "the + takes the tab count's place")
            XCTAssertFalse(row.badge.isHidden, "the chip stays")
            XCTAssertEqual(row.newTabButton.frame.midX, width - SidebarRow.buttonInset, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(row.newTabButton.frame.minX, before.1.maxX, "clear of the chip")
            XCTAssertLessThanOrEqual(row.newTabButton.frame.maxX, width)
            XCTAssertEqual(row.label.frame, before.0, "hovering moves nothing")
            XCTAssertEqual(row.badge.frame, before.1)
            let visible = row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            XCTAssertEqual(visible.map { $0.accessibilityLabel() }, ["New Tab"], "no close button on a workspace")
            row.setHovering(false)
            XCTAssertTrue(row.newTabButton.isHidden)
            XCTAssertFalse(row.tabCount.isHidden)
            XCTAssertEqual(row.tabCount.frame, before.2)
        }
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
