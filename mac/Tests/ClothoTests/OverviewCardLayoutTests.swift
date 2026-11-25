import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// A card's text at every step of View ▸ Zoom (80 % to 160 %): a message that takes two lines has the
/// room its cell needs for two and shows both, and every one-line label has its line's height.
@MainActor
final class OverviewCardLayoutTests: XCTestCase {
    private var window: NSWindow!
    private var savedScale: CGFloat = 1

    override func setUp() {
        _ = NSApplication.shared
        savedScale = UIScale.factor
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() {
        UIScale.factor = savedScale
        window.close()
    }

    /// Every step of the zoom, as View ▸ Zoom In goes through them.
    private var steps: [CGFloat] {
        var steps = [UIScale.range.lowerBound]
        while let last = steps.last, last < UIScale.range.upperBound { steps.append(UIScale.next(last, steps: 1)) }
        return steps
    }

    private func card(message: String) throws -> OverviewCard {
        let now = Date(timeIntervalSince1970: 10_000)
        let entry = AgentEntry(machine: "local", machineName: "devbox", pane: 1, workspace: Workspace(id: 1, name: "notes", tabs: []),
                               tab: Tab(id: 101, activePane: 1, layout: .pane(1)), paneTitle: "zsh", tabTitle: "plan",
                               info: AgentInfo(kind: "claude", state: .done, source: "hook", message: message, since: now.timeIntervalSince1970 - 680,
                                               attention: true, needsUser: true),
                               canReply: false)
        let git = PaneGit(repo: "clotho", root: "/tmp", branch: "clear-alerts", head: "a1b2c3d",
                          changes: .init(uncommitted: .init(files: 6, added: 128, removed: 32), branch: nil))
        let source = OverviewSource(features: ["local": [.git, .gitChanges, .peek]], git: [PaneKey(machine: "local", pane: 1): git])
        return try XCTUnwrap(OverviewCard(entry, source: source, now: now))
    }

    private func show(_ card: OverviewCard, width: CGFloat) -> OverviewCardView {
        let view = OverviewCardView(card: card)
        view.setPeek(["  B keeps the old flow and adds a", "  switch. Which should I build?"])
        view.frame = CGRect(x: 20, y: 20, width: width, height: OverviewCardView.height)
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Whether the label draws anything in each of the two halves of its height where a line of two sits:
    /// the top two fifths and the bottom two fifths.
    private func inked(_ label: NSTextField) throws -> (first: Bool, second: Bool) {
        let rep = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
        label.cacheDisplay(in: label.bounds, to: rep)
        let data = try XCTUnwrap(rep.bitmapData)
        let bytes = rep.bitsPerPixel / 8
        // Row 0 is the top row.
        func drawn(_ rows: Range<Int>) -> Bool {
            for y in rows {
                for offset in 0..<(rep.pixelsWide * bytes) where data[y * rep.bytesPerRow + offset] != 0 { return true }
            }
            return false
        }
        let high = rep.pixelsHigh
        return (drawn(0..<(high * 2 / 5)), drawn((high * 3 / 5)..<high))
    }

    private static let long = "Asks which option to build, A or B: A replaces the old flow and B keeps it and adds a switch in Settings."

    func testATwoLineMessageShowsBothLinesAtEveryZoom() throws {
        XCTAssertEqual(steps.map { Int(($0 * 100).rounded()) }, [80, 90, 100, 110, 120, 130, 140, 150, 160])
        for factor in steps {
            UIScale.factor = factor
            let percent = "\(Int((factor * 100).rounded())) %"
            // The narrowest card, and a wide one.
            for width in [s(250), s(420)] {
                let view = show(try card(message: Self.long), width: width)
                let message = view.message
                XCTAssertFalse(message.isHidden)
                // What a wrapping label of that font needs for two lines, and for one.
                let two = NSTextField(wrappingLabelWithString: "one\ntwo")
                two.font = message.font
                let twoLines = try XCTUnwrap(two.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 10000)).height)
                let one = NSTextField(wrappingLabelWithString: "one")
                one.font = message.font
                let oneLine = try XCTUnwrap(one.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 10000)).height)
                let wanted = try XCTUnwrap(message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 10000)).height)
                XCTAssertGreaterThan(twoLines, oneLine)
                XCTAssertGreaterThanOrEqual(wanted, twoLines, "the message takes two lines or more, \(percent)")
                XCTAssertGreaterThanOrEqual(message.frame.height, twoLines, "room for two lines, \(percent) at \(width)")
                XCTAssertLessThan(message.frame.height, twoLines + oneLine, "and no third, \(percent)")
                let ink = try inked(message)
                XCTAssertTrue(ink.first, "the first line is drawn, \(percent) at \(width)")
                XCTAssertTrue(ink.second, "the second line is drawn, \(percent) at \(width)")
                // Nothing runs into what is under it.
                XCTAssertLessThanOrEqual(message.frame.maxY, view.sub.frame.minY + 0.01, percent)
                XCTAssertLessThanOrEqual(view.sub.frame.maxY, view.peek.frame.minY + 0.01, percent)
                XCTAssertLessThanOrEqual(view.peek.frame.maxY, view.footer.frame.minY + 0.01, percent)
            }
        }
    }

    /// A message of one line keeps one line's height, and the dim line sits right under it.
    func testAOneLineMessageKeepsOneLine() throws {
        for factor in steps {
            UIScale.factor = factor
            let view = show(try card(message: "Both pages build."), width: s(250))
            let two = OverviewCardView.twoLineHeight(of: view.message, width: view.message.frame.width)
            XCTAssertGreaterThan(view.message.frame.height, 0)
            XCTAssertLessThan(view.message.frame.height, two, "\(factor)")
            XCTAssertEqual(view.sub.frame.minY, view.message.frame.maxY + OverviewCardView.pad(1))
        }
    }

    /// How many pixel rows of the label have something drawn in them.
    private func inkedRows(_ label: NSView) throws -> Int {
        let rep = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
        label.cacheDisplay(in: label.bounds, to: rep)
        let data = try XCTUnwrap(rep.bitmapData)
        let bytes = rep.bitsPerPixel / 8
        return (0..<rep.pixelsHigh).filter { y in (0..<(rep.pixelsWide * bytes)).contains { data[y * rep.bytesPerRow + $0] != 0 } }.count
    }

    /// The label draws every pixel row of its glyphs: as many as it draws with room to spare under it
    /// (the same label in the same place, made taller for the count).
    private func assertNothingCut(_ label: NSTextField, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(label.superview?.isFlipped, true, "its top stays where it is", file: file, line: line)
        let frame = label.frame
        let drawn = try inkedRows(label)
        label.frame.size.height = frame.height + 40
        let whole = try inkedRows(label)
        label.frame = frame
        XCTAssertGreaterThan(whole, 0, what, file: file, line: line)
        XCTAssertEqual(drawn, whole, "glyph rows drawn of \u{201C}\(label.stringValue)\u{201D}, \(what)", file: file, line: line)
    }

    /// The one-line labels (the place, the age, the dim line, the peek's two rows, the branch, the counts)
    /// are as tall as their cells need at every zoom and both widths, and sit whole inside their blocks.
    func testOneLineLabelsHaveTheirLinesHeightAtEveryZoom() throws {
        for factor in steps {
            UIScale.factor = factor
            for width in [s(250), s(420)] {
                let view = show(try card(message: Self.long), width: width)
                let what = "\(Int((factor * 100).rounded())) % at \(width)"
                XCTAssertFalse(view.peek.isHidden)
                XCTAssertEqual(view.frame.height, OverviewCardView.height)
                XCTAssertEqual(OverviewCardView.height, OverviewCardView.height.rounded(), "whole points, \(what)")
                for label in [view.place, view.age, view.sub, view.branch, view.counts] + view.peekRows {
                    XCTAssertFalse(label.stringValue.isEmpty)
                    let needs = try XCTUnwrap(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10000, height: 10000)).height)
                    XCTAssertGreaterThanOrEqual(label.frame.height, needs, "\u{201C}\(label.stringValue)\u{201D}, \(what)")
                    XCTAssertEqual(label.frame.minY, label.frame.minY.rounded(), "on a whole point, \(what)")
                    XCTAssertTrue(label.superview?.bounds.contains(label.frame) == true, "\u{201C}\(label.stringValue)\u{201D} inside its block, \(what)")
                }
                // The two lines the card keeps room for are the message's own.
                XCTAssertLessThanOrEqual(OverviewCardView.twoLineHeight(of: view.message, width: view.message.frame.width),
                                         OverviewCardView.textHeight(OverviewCardView.messageFont, lines: 2), what)
                // The blocks: one under the other, inside the card.
                XCTAssertLessThanOrEqual(view.place.frame.maxY, view.message.frame.minY, what)
                XCTAssertLessThanOrEqual(view.message.frame.maxY, view.sub.frame.minY, what)
                XCTAssertLessThanOrEqual(view.sub.frame.maxY, view.peek.frame.minY, what)
                XCTAssertLessThanOrEqual(view.peekRows[0].frame.maxY, view.peekRows[1].frame.minY, what)
                XCTAssertEqual(view.peek.frame.maxY, view.footer.frame.minY, what)
                XCTAssertEqual(view.footer.frame.maxY, view.bounds.maxY, what)
                XCTAssertTrue(view.bounds.contains(view.peek.frame) && view.bounds.contains(view.footer.frame), what)
            }
        }
    }

    /// Drawn: no pixel row of a glyph is cut in the title row, the dim line, the peek's rows or the
    /// footer, at every zoom (80 % and 90 % were where rows were short).
    func testNoGlyphRowIsCutAtAnyZoom() throws {
        for factor in steps {
            UIScale.factor = factor
            for width in [s(250), s(420)] {
                // Two lines and no more at either width, so a taller label draws nothing else.
                let view = show(try card(message: "Asks which (gjpqy) option to build, A or B [gjpqy]?"), width: width)
                view.message.maximumNumberOfLines = 2
                // Letters with tails and tall ones. No box-drawing characters: those fill a terminal's
                // row and past it by design.
                view.setPeek(["  gjpqy (Which) [should] I build?", "  Updated with 9 additions, gjpqy"])
                view.layoutSubtreeIfNeeded()
                let what = "\(Int((factor * 100).rounded())) % at \(width)"
                for label in [view.place, view.age, view.sub, view.branch, view.counts] + view.peekRows {
                    try assertNothingCut(label, what)
                }
                try assertNothingCut(view.message, what)
                let short = show(try card(message: "Both pages build, gjpqy."), width: width)
                XCTAssertEqual(short.message.frame.height, OverviewCardView.textHeight(OverviewCardView.messageFont), what)
                try assertNothingCut(short.message, what)
            }
        }
    }

    /// The Overview's own lines the same way: the title, the line saying why a key did nothing, the
    /// filter, Back and a lane's header are as tall as their cells need, inside their rows, and drawn whole.
    func testTheTitleRowAndLaneHeadersHaveTheirHeightAtEveryZoom() throws {
        window.setContentSize(NSSize(width: 1500, height: 500))
        let overview = OverviewView(frame: NSRect(x: 0, y: 0, width: 1500, height: 500))
        window.contentView?.addSubview(overview)
        defer { overview.showNote(nil) }
        let card = try card(message: Self.long)
        overview.update(lanes: [(lane: card.lane, cards: [card])])
        func needs(_ control: NSControl) throws -> CGFloat {
            try XCTUnwrap(control.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10000, height: 10000)).height)
        }
        for factor in steps {
            UIScale.factor = factor
            let what = "\(Int((factor * 100).rounded())) %"
            overview.applyScale()
            overview.showNote(AppDelegate.besideSameTab)
            overview.layoutSubtreeIfNeeded()
            for control in [overview.titleLabel, overview.noteLabel, overview.filterField, overview.backButton] as [NSControl] {
                XCTAssertGreaterThanOrEqual(control.frame.height, try needs(control), "\(type(of: control)) \u{201C}\(control.stringValue)\u{201D}, \(what)")
                XCTAssertGreaterThanOrEqual(control.frame.minY, 0, what)
                XCTAssertLessThanOrEqual(control.frame.maxY, OverviewView.titleHeight, "in the title row, \(what)")
            }
            XCTAssertGreaterThanOrEqual(overview.filterField.frame.height, overview.filterField.intrinsicContentSize.height, what)
            XCTAssertLessThan(overview.noteLabel.frame.maxY, OverviewView.titleHeight, "the line fits after the title here")
            try assertNothingCut(overview.titleLabel, what)
            try assertNothingCut(overview.noteLabel, what)

            let lane = try XCTUnwrap(overview.laneViews[card.lane])
            let view = try XCTUnwrap(overview.cardViews[card.key])
            XCTAssertGreaterThanOrEqual(lane.header.frame.height, try needs(lane.header), "the lane's header, \(what)")
            XCTAssertTrue(lane.bounds.contains(lane.header.frame), what)
            XCTAssertLessThanOrEqual(lane.header.frame.maxY, view.frame.minY, what)
            XCTAssertEqual(view.frame.minY, view.frame.minY.rounded(), "the card starts on a whole point, \(what)")
            XCTAssertEqual(lane.frame.minY, lane.frame.minY.rounded(), what)
            XCTAssertEqual(view.frame.height, OverviewCardView.height, what)
            try assertNothingCut(lane.header, what)
        }
    }
}
