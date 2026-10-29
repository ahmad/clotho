import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Tabs share the bar in equal widths that depend only on how many there are and how wide the bar is:
/// selecting a tab, an agent's dot coming or going, or a pane retitling itself never moves them.
@MainActor
final class TabBarWidthTests: XCTestCase {
    private var window: NSWindow!
    private var bar: TabBarView!

    override func setUp() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        bar = TabBarView(frame: window.contentView!.bounds)
        bar.autoresizingMask = [.width]
        window.contentView!.addSubview(bar)
    }

    override func tearDown() {
        window.close()
    }

    private typealias TabSpec = (id: TabID, title: String, custom: String?, maximized: Bool, badge: NSColor?)

    private func show(_ titles: [String], badges: [Int: NSColor] = [:], selected: TabID = 1) -> [NSRect] {
        let tabs: [TabSpec] = titles.enumerated().map { (TabID($0.offset + 1), $0.element, nil, false, badges[$0.offset]) }
        bar.update(tabs: tabs, selected: selected)
        bar.layoutSubtreeIfNeeded()
        return bar.tabFrames
    }

    func testWidthsDontFollowSelectionDotsOrTitles() {
        let start = show(["zsh", "zsh", "zsh"])
        XCTAssertEqual(Set(start.map(\.width)).count, 1, "equal widths")
        XCTAssertEqual(show(["zsh", "zsh", "zsh"], selected: 3), start, "selecting another tab")
        XCTAssertEqual(show(["zsh", "zsh", "zsh"], badges: [1: .systemOrange], selected: 3), start, "an agent's dot")
        XCTAssertEqual(show(["zsh", "zsh", "✳ cargo test --workspace --all-features"], selected: 3), start, "a long retitle")
        XCTAssertEqual(show(["zsh", "zsh", "✳ Claude Code"], badges: [2: .systemBlue], selected: 2), start, "and back")
    }

    /// Widths change only with the number of tabs or the bar's width, within a minimum and maximum.
    func testWidthsFollowTabCountAndBarWidth() {
        let one = show(["zsh"])
        XCTAssertEqual(one[0].width, TabBarView.maxTabWidth, "a few tabs stop at the maximum")
        let many = show(Array(repeating: "zsh", count: 9))
        XCTAssertLessThan(many[0].width, TabBarView.maxTabWidth)
        XCTAssertGreaterThanOrEqual(many[0].width, TabBarView.minTabWidth)
        XCTAssertEqual(Set(many.map(\.width)).count, 1)
        window.setContentSize(NSSize(width: 700, height: 40))
        bar.layoutSubtreeIfNeeded()
        XCTAssertLessThan(bar.tabFrames[0].width, many[0].width, "a narrower window, narrower tabs")
    }

    /// The title has the same room with or without a dot, and truncates inside the tab.
    func testTitlesKeepTheirPlaceAndTruncate() throws {
        _ = show(["zsh", "a very long title that will not fit in a tab of this width at all"], badges: [0: .systemOrange])
        let items = bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].label.frame.minX, items[1].label.frame.minX, accuracy: 0.5, "a dot doesn't move the title")
        XCTAssertLessThanOrEqual(items[1].label.frame.maxX, items[1].closeButton.frame.minX)
    }
}
