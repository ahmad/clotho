import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Tabs share the bar in equal widths that depend only on how many there are and how wide the bar is:
/// selecting a tab, an agent's mark coming or going, or a pane retitling itself never moves them. The mark
/// sits in a slot that's always kept, and the bar's free space shows where the focused tab is.
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

    private typealias TabSpec = (id: TabID, title: String, custom: String?, maximized: Bool, mark: AgentMark?)

    private func show(_ titles: [String], marks: [Int: AgentMark] = [:], selected: TabID = 1) -> [NSRect] {
        let tabs: [TabSpec] = titles.enumerated().map { (TabID($0.offset + 1), $0.element, nil, false, marks[$0.offset]) }
        bar.update(tabs: tabs, selected: selected)
        bar.layoutSubtreeIfNeeded()
        return bar.tabFrames
    }

    private var items: [ChromeItem] { bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem } }

    func testWidthsDontFollowSelectionMarksOrTitles() {
        let start = show(["zsh", "zsh", "zsh"])
        XCTAssertEqual(Set(start.map(\.width)).count, 1, "equal widths")
        XCTAssertEqual(show(["zsh", "zsh", "zsh"], selected: 3), start, "selecting another tab")
        XCTAssertEqual(show(["zsh", "zsh", "zsh"], marks: [1: .needsYou], selected: 3), start, "an agent's mark")
        XCTAssertEqual(show(["zsh", "zsh", "✳ cargo test --workspace --all-features"], selected: 3), start, "a long retitle")
        XCTAssertEqual(show(["zsh", "zsh", "✳ Claude Code"], marks: [2: .working], selected: 2), start, "and back")
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

    /// The title has the same room with or without a mark, and truncates inside the tab.
    func testTitlesKeepTheirPlaceAndTruncate() throws {
        _ = show(["zsh", "a very long title that will not fit in a tab of this width at all"], marks: [0: .needsYou])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].label.frame.minX, items[1].label.frame.minX, accuracy: 0.5, "a mark doesn't move the title")
        XCTAssertLessThanOrEqual(items[1].label.frame.maxX, items[1].closeButton.frame.minX)
    }

    /// A tab's slot holds its most urgent agent's mark: a ring for a working agent, a dot for the rest.
    func testTheSlotHoldsTheMarkForEachState() throws {
        let plain = show(["a", "b", "c", "d", "plain"])
        let frames = show(["a", "b", "c", "d", "plain"], marks: [0: .needsYou, 1: .error, 2: .done, 3: .working])
        XCTAssertEqual(frames, plain, "marks don't change a tab's width")
        let marks = items.map { $0.subviews.compactMap { $0 as? AgentMarkView }.first }
        XCTAssertEqual(marks.map { $0?.mark }, [.needsYou, .error, .done, .working, nil])
        for (item, mark) in zip(items, marks) {
            guard let mark else { continue }
            XCTAssertEqual(mark.frame.size, NSSize(width: AgentMarkView.side, height: AgentMarkView.side))
            XCTAssertEqual(mark.frame.midY, item.bounds.midY, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(mark.frame.minX, 0)
            XCTAssertLessThanOrEqual(mark.frame.maxX, TabBarView.dotSlot, "inside the slot")
            XCTAssertLessThanOrEqual(mark.frame.maxX, item.label.frame.minX, "before the title")
        }
        XCTAssertEqual(items[0].label.frame.minX, items[4].label.frame.minX, accuracy: 0.5)
        // The state is in the tooltip and the accessibility label.
        XCTAssertEqual(items.map(\.toolTip), ["a, Needs you (⌘1)", "b, Error (⌘2)", "c, Done (⌘3)", "d, Working (⌘4)", "plain (⌘5)"])
        XCTAssertEqual(items.map { $0.accessibilityLabel() }, ["a, Needs you", "b, Error", "c, Done", "d, Working", "plain"])
    }

    /// The spinner after the + stays whole when the tabs fill the bar: they give up its room while it shows.
    func testTheBusySpinnerStaysInsideAFullBar() {
        for (width, count) in [(CGFloat(390), 2), (724, 7), (1000, 4)] {
            window.setContentSize(NSSize(width: width, height: 40))
            bar.busyText = nil
            let idle = show(Array(repeating: "zsh", count: count))
            bar.busyText = "Creating worktree clotho-fix-login…"
            bar.layoutSubtreeIfNeeded()
            let spinner = bar.busySpinner
            XCTAssertFalse(spinner.isHidden)
            XCTAssertGreaterThan(spinner.frame.width, 0)
            XCTAssertLessThanOrEqual(spinner.frame.maxX, bar.bounds.maxX, "\(count) tabs in \(width) pt")
            XCTAssertGreaterThanOrEqual(spinner.frame.minX, (bar.tabFrames.last?.maxX ?? 0), "after the tabs")
            // Done: the tabs have their widths back.
            bar.busyText = nil
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(bar.tabFrames, idle, "\(count) tabs in \(width) pt")
        }
    }

    /// "devbox › clotho › alerts", centred in the space after the +, only when it fits there with room to
    /// spare; clicks go through it to the bar.
    func testTheBreadcrumbShowsOnlyWhereItFits() throws {
        bar.breadcrumb = (machine: "devbox", workspace: "clotho", tab: "alerts")
        _ = show(["alerts", "zsh"])
        let label = bar.breadcrumbLabel
        XCTAssertEqual(label.stringValue, "devbox › clotho › alerts")
        XCTAssertFalse(label.isHidden)
        let plus = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertGreaterThanOrEqual(label.frame.minX, plus.frame.maxX + TabBarView.breadcrumbMargin - 0.5)
        XCTAssertLessThanOrEqual(label.frame.maxX, bar.bounds.maxX - TabBarView.breadcrumbMargin + 0.5)
        XCTAssertEqual(label.frame.midX, (plus.frame.maxX + bar.bounds.maxX) / 2, accuracy: 1, "centred in the free space")
        XCTAssertEqual(label.frame.midY, bar.bounds.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(label.frame.width, label.attributedStringValue.size().width, "all of it shows")
        XCTAssertTrue(bar.hitTest(NSPoint(x: label.frame.midX, y: label.frame.midY)) === bar, "a click there reaches the bar, which drags the window")
        // The workspace stands out; the rest is dim.
        let text = label.attributedStringValue
        let workspace = (text.string as NSString).range(of: "clotho")
        XCTAssertEqual(text.attribute(.foregroundColor, at: workspace.location, effectiveRange: nil) as? NSColor, Theme.foreground)
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.dimText)

        // More tabs: no room, so it's gone rather than squeezed.
        let before = show(Array(repeating: "zsh", count: 9))
        XCTAssertTrue(label.isHidden)
        bar.breadcrumb = nil
        XCTAssertEqual(show(Array(repeating: "zsh", count: 9)), before, "it never moves a tab")
        // Just short of fitting: hidden.
        bar.breadcrumb = (machine: "devbox", workspace: "clotho", tab: "alerts")
        _ = show(["alerts"])
        XCTAssertFalse(label.isHidden)
        let needed = plus.frame.maxX + label.frame.width + TabBarView.breadcrumbMargin * 2
        window.setContentSize(NSSize(width: needed - 4, height: 40))
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(label.isHidden)
        window.setContentSize(NSSize(width: needed + 4, height: 40))
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(label.isHidden)
        // No focused tab: nothing.
        bar.breadcrumb = nil
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(label.isHidden)
    }

    /// Review images of the bar with every mark and the breadcrumb, light and dark. Runs only with
    /// CLOTHO_SNAPSHOT_DIR set.
    func testSnapshotsForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        let saved = NSApp.appearance
        defer {
            NSApp.appearance = saved
            Theme.followAppAppearance()
        }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            Theme.followAppAppearance()
            window.appearance = NSApp.appearance
            bar.breadcrumb = (machine: "devbox", workspace: "clotho", tab: "alerts")
            _ = show(["alerts", "build", "tests", "deploy", "zsh"], marks: [0: .needsYou, 1: .error, 2: .done, 3: .working])
            bar.viewDidChangeEffectiveAppearance()
            for (label, tabs) in [("marks", 5), ("two", 2)] {
                if tabs == 2 { _ = show(["alerts", "zsh"], marks: [0: .needsYou]) }
                guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return XCTFail("no image") }
                bar.cacheDisplay(in: bar.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/tab-bar-\(label)-\(name).png"))
            }
        }
    }
}
