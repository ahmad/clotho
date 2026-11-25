import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// A pane's progress (clothod 0.1.33, `pane.progress`) as a thin bar on its Tab, its header, its agent's
/// row and card: the colours, the widths, what VoiceOver hears, and that a progress that moves every
/// second never builds a Tab, a row or a card again.
@MainActor
final class ProgressBarTests: XCTestCase {
    private var window: NSWindow!
    private var savedMotion: (() -> Bool)!
    private var savedScale: CGFloat = 1

    override func setUp() {
        _ = NSApplication.shared
        savedMotion = AgentMarkView.reducesMotion
        savedScale = UIScale.factor
        AgentMarkView.reducesMotion = { false }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() {
        AgentMarkView.reducesMotion = savedMotion
        UIScale.factor = savedScale
        window.close()
    }

    private var steps: [CGFloat] {
        var steps = [UIScale.range.lowerBound]
        while let last = steps.last, last < UIScale.range.upperBound { steps.append(UIScale.next(last, steps: 1)) }
        return steps
    }

    private func bar(_ progress: PaneProgress?, width: CGFloat = 200) -> ProgressBarView {
        let bar = ProgressBarView(progress)
        bar.frame = NSRect(x: 10, y: 10, width: width, height: ProgressBarView.height)
        window.contentView?.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    func testTheFillIsThePercentOfTheWidth() {
        XCTAssertEqual(bar(PaneProgress(state: .running, percent: 0)).fillFrame.width, 0)
        XCTAssertEqual(bar(PaneProgress(state: .running, percent: 40)).fillFrame.width, 80)
        XCTAssertEqual(bar(PaneProgress(state: .running, percent: 100)).fillFrame.width, 200)
        XCTAssertEqual(bar(PaneProgress(state: .error, percent: 55)).fillFrame.width, 110)
        let running = bar(PaneProgress(state: .running, percent: 40))
        XCTAssertFalse(running.isSliding)
        XCTAssertFalse(running.isHidden)
        running.progress = PaneProgress(state: .running, percent: 41)
        XCTAssertEqual(running.fillFrame.width, 82, "in place")
        running.progress = nil
        XCTAssertTrue(running.isHidden, "no progress, no bar")
        XCTAssertNil(running.accessibilityValue())
    }

    func testEachStatesColourIsThePalettes() {
        for appearance in [ClothoPalette.Appearance.light, .dark] {
            let palette = ClothoPalette.for(appearance)
            XCTAssertEqual(PaneProgress.State.running.barHex(for: appearance), palette.accent)
            XCTAssertEqual(PaneProgress.State.indeterminate.barHex(for: appearance), palette.accent)
            XCTAssertEqual(PaneProgress.State.error.barHex(for: appearance), palette.ansi[1])
            XCTAssertEqual(PaneProgress.State.paused.barHex(for: appearance), palette.ansi[3])
        }
        XCTAssertEqual(PaneProgress.State.running.barColor, Theme.accent)
        XCTAssertEqual(PaneProgress.State.error.barColor, Theme.danger)
        XCTAssertEqual(PaneProgress.State.paused.barColor, Theme.caution)
    }

    func testAnIndeterminateBarSlidesUnlessMotionIsReduced() {
        let moving = bar(PaneProgress(state: .indeterminate))
        XCTAssertTrue(moving.isIndeterminate)
        XCTAssertTrue(moving.isSliding)
        XCTAssertEqual(moving.fillFrame.width, 60, "a segment")
        AgentMarkView.reducesMotion = { true }
        let still = bar(PaneProgress(state: .indeterminate))
        XCTAssertFalse(still.isSliding, "Reduce Motion: nothing moves")
        XCTAssertEqual(still.fillFrame.width, 200, "the whole width, still")
        XCTAssertEqual(still.fillOpacity, ProgressBarView.stillOpacity)
        // A state that came with no percent is drawn the same way.
        XCTAssertTrue(bar(PaneProgress(state: .paused)).isIndeterminate)
        // With a percent again it stops.
        moving.progress = PaneProgress(state: .running, percent: 10)
        XCTAssertFalse(moving.isSliding)
    }

    func testVoiceOverReadsProgressFortyPercent() {
        let view = bar(PaneProgress(state: .running, percent: 40))
        XCTAssertEqual(view.accessibilityRole(), .progressIndicator)
        XCTAssertEqual(view.accessibilityLabel(), "Progress")
        XCTAssertEqual(view.accessibilityValue() as? String, "40 percent")
        XCTAssertEqual([view.accessibilityLabel(), view.accessibilityValue() as? String].compactMap { $0 }.joined(separator: " "), "Progress 40 percent")
        XCTAssertEqual(ProgressBarView.spokenValue(PaneProgress(state: .error, percent: 55)), "55 percent, error")
        XCTAssertEqual(ProgressBarView.spokenValue(PaneProgress(state: .paused, percent: 70)), "70 percent, paused")
        XCTAssertEqual(ProgressBarView.spokenValue(PaneProgress(state: .indeterminate)), "in progress")
        XCTAssertNil(view.hitTest(NSPoint(x: 15, y: 11)), "a click goes to what is under it")
    }

    // MARK: Where it shows

    private typealias TabSpec = (id: TabID, title: String, custom: String?, maximized: Bool, mark: AgentMark?, agent: String?)

    private func tabBar(width: CGFloat = 600) -> TabBarView {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: width, height: TabBarView.height))
        window.contentView?.addSubview(bar)
        let tabs: [TabSpec] = [(1, "alerts", nil, false, .working, "Claude Code"), (2, "build", nil, false, nil, nil), (3, "site", nil, false, nil, nil)]
        bar.update(tabs: tabs, selected: 1)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    func testProgressOnATabNeverBuildsTheTabsAgain() {
        let bar = tabBar()
        let before = bar.progressBars
        XCTAssertEqual(before.count, 3, "every tab has the bar's place")
        XCTAssertTrue(before.values.allSatisfy(\.isHidden))
        let items = before.mapValues { ObjectIdentifier($0.superview!) }
        for percent in [10, 40, 90] {
            bar.setProgress([2: PaneProgress(state: .running, percent: percent)])
            XCTAssertEqual(bar.progressBars.mapValues { ObjectIdentifier($0.superview!) }, items, "the same tabs")
            XCTAssertTrue(bar.progressBars[2] === before[2])
            XCTAssertEqual(bar.progressBars[2]?.progress?.percent, percent)
        }
        XCTAssertEqual(before[2]?.superview?.accessibilityValue() as? String, "Progress 90 percent", "the tab's value, not its label")
        XCTAssertEqual(before[2]?.superview?.accessibilityLabel(), "build")
        XCTAssertEqual(before[1]?.superview?.accessibilityLabel(), "alerts, Working (Claude Code)")
        XCTAssertTrue(before[1]!.isHidden)

        // While a name is edited updates are held; progress still lands on the tab being renamed.
        bar.beginRename(2)
        XCTAssertTrue(bar.isEditing)
        bar.setProgress([2: PaneProgress(state: .error, percent: 95)])
        XCTAssertEqual(before[2]?.progress, PaneProgress(state: .error, percent: 95))
        XCTAssertTrue(bar.isEditing, "the edit goes on")
        XCTAssertTrue(bar.progressBars[2] === before[2])

        bar.setProgress([:])
        XCTAssertTrue(before[2]!.isHidden)
        XCTAssertNil(before[2]?.superview?.accessibilityValue() as? String)
    }

    func testARebuiltTabBarKeepsItsProgress() {
        let bar = tabBar()
        bar.setProgress([3: PaneProgress(state: .paused, percent: 70)])
        let tabs: [TabSpec] = [(1, "alerts", nil, false, nil, nil), (3, "site two", nil, false, nil, nil)]
        bar.update(tabs: tabs, selected: 3)
        XCTAssertEqual(bar.progressBars[3]?.progress, PaneProgress(state: .paused, percent: 70))
        XCTAssertEqual(bar.progressBars.count, 2)
    }

    private func entry(_ pane: PaneID, _ state: AgentInfo.State = .running) -> AgentEntry {
        AgentEntry(machine: "local", machineName: "devbox", pane: pane, workspace: Workspace(id: 1, name: "clotho", tabs: []),
                   tab: Tab(id: TabID(pane), activePane: pane, layout: .pane(pane)), paneTitle: "zsh", tabTitle: "alerts",
                   info: AgentInfo(kind: "gemini", state: state, source: "hook", message: "Running the suite", since: 100, attention: state != .running),
                   canReply: false)
    }

    func testProgressOnASidebarRowNeverBuildsTheRowsAgain() {
        let savedExpanded = UserDefaults.standard.object(forKey: SidebarView.workingExpandedKey)
        defer { UserDefaults.standard.set(savedExpanded, forKey: SidebarView.workingExpandedKey) }
        UserDefaults.standard.set(true, forKey: SidebarView.workingExpandedKey)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 236, height: 300))
        window.contentView?.addSubview(sidebar)
        let group = SidebarGroup(key: "local", title: "devbox", status: (nil, nil),
                                 workspaces: [Workspace(id: 1, name: "clotho", tabs: [Tab(id: 1, activePane: 1, layout: .pane(1))])],
                                 selected: 1, isConnected: true, isLocal: true, marks: [:])
        sidebar.update(agents: [entry(1, .waiting), entry(2)], groups: [group])
        sidebar.layoutSubtreeIfNeeded()
        let rows = sidebar.agentRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.progressBar.isHidden })
        let key = PaneKey(machine: "local", pane: 2)
        for percent in [5, 50, 100] {
            sidebar.setProgress([key: PaneProgress(state: .running, percent: percent)])
            XCTAssertTrue(zip(sidebar.agentRows, rows).allSatisfy { $0 === $1 }, "the same rows")
        }
        XCTAssertEqual(rows[1].progressBar.progress?.percent, 100)
        XCTAssertTrue(rows[0].progressBar.isHidden, "only the pane that has it")
        // A rebuild (another agent arrives) brings the progress with it.
        sidebar.update(agents: [entry(1, .waiting), entry(2), entry(3)], groups: [group])
        let again = sidebar.agentRows
        XCTAssertEqual(again.count, 3)
        XCTAssertEqual(again.first { $0.progressBar.progress != nil }?.progressBar.progress?.percent, 100)
        sidebar.setProgress([:])
        XCTAssertTrue(sidebar.agentRows.allSatisfy { $0.progressBar.isHidden })
    }

    func testProgressIsNotPartOfACardsContent() throws {
        let card = try XCTUnwrap(OverviewCard(entry(1)))
        let view = OverviewCardView(card: card)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: OverviewCardView.height)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.progressBar.isHidden)
        XCTAssertNil(view.accessibilityValue())
        view.progress = PaneProgress(state: .running, percent: 40)
        XCTAssertEqual(view.card, card, "the card is what it was")
        XCTAssertEqual(view.accessibilityValue() as? String, "Progress 40 percent")
        XCTAssertEqual(view.progressBar.isAccessibilityElement(), false, "the card is one element")
        XCTAssertEqual(view.progressBar.frame.minY, view.footer.frame.minY, "along the footer's top edge, over its rule")
        XCTAssertEqual(view.progressBar.frame.width, 298, "inside the card's outline")
    }

    /// The bar never changes a height or leaves its host, at any zoom, in a narrow pane, Tab and sidebar.
    func testTheBarStaysInsideItsHostAtEveryZoom() throws {
        XCTAssertEqual(steps.count, 9)
        let progress = PaneProgress(state: .running, percent: 40)
        for factor in steps {
            UIScale.factor = factor
            let what = "\(Int(factor * 100)) %"
            XCTAssertGreaterThanOrEqual(ProgressBarView.height, 1.5, what)

            for width in [120, 600] as [CGFloat] {
                let header = PaneHeader()
                header.frame = NSRect(x: 0, y: 0, width: width, height: PaneHeader.height)
                header.show(PaneChrome(agent: entry(1).info, cwd: "/tmp/project", progress: progress))
                header.layoutSubtreeIfNeeded()
                XCTAssertEqual(header.frame.height, PaneHeader.height, "the header's height is its own, \(what)")
                XCTAssertTrue(header.bounds.contains(header.progressBar.frame), "\(what) at \(width)")
                XCTAssertEqual(header.progressBar.frame.maxY, header.bounds.maxY, what)
                XCTAssertFalse(header.progressBar.isHidden)
                header.show(PaneChrome(agent: nil, command: ["/bin/zsh"], progress: progress))
                XCTAssertFalse(header.progressBar.isHidden, "a pane with no agent has it too")
                header.show(PaneChrome(command: ["/bin/zsh"]))
                XCTAssertTrue(header.progressBar.isHidden)
            }

            // Three tabs at their least width fit a 460 pt bar at the largest zoom.
            for width in [460, 900] as [CGFloat] {
                let bar = tabBar(width: width)
                bar.setProgress([1: progress, 2: progress, 3: progress])
                bar.layoutSubtreeIfNeeded()
                for (id, view) in bar.progressBars {
                    let item = try XCTUnwrap(view.superview as? ChromeItem)
                    XCTAssertTrue(item.bounds.contains(view.frame), "tab \(id), \(what) at \(width)")
                    XCTAssertGreaterThan(view.frame.width, 0, "tab \(id), \(what) at \(width)")
                    XCTAssertLessThanOrEqual(view.frame.maxX, item.closeButton.frame.minX, "before the close button's room")
                    XCTAssertGreaterThanOrEqual(view.frame.minX, TabBarView.dotSlot - 1, "after the mark's slot")
                    XCTAssertFalse(view.frame.intersects(item.label.frame), "under the title, never over it: \(what) at \(width)")
                }
                bar.removeFromSuperview()
            }

            for width in [220, 420] as [CGFloat] {
                let card = OverviewCardView(card: try XCTUnwrap(OverviewCard(entry(1))))
                card.frame = NSRect(x: 0, y: 0, width: width, height: OverviewCardView.height)
                card.progress = progress
                card.layoutSubtreeIfNeeded()
                XCTAssertTrue(card.body.bounds.contains(card.progressBar.frame), what)
                XCTAssertFalse(card.progressBar.frame.intersects(card.footer.convert(card.branch.frame, to: card.body)), "clear of the footer's text, \(what)")
                // The symbol and the dim line share a row, inside the card, and neither is cut short.
                XCTAssertLessThanOrEqual(card.kindGlyph.frame.maxX, card.sub.frame.minX, what)
                XCTAssertTrue(card.body.bounds.contains(card.kindGlyph.frame), what)
                XCTAssertGreaterThanOrEqual(card.sub.frame.height, card.sub.cell?.cellSize.height ?? .infinity, "the dim line has its height, \(what)")
                XCTAssertLessThanOrEqual(card.kindGlyph.frame.height, card.sub.frame.height, what)
                XCTAssertLessThanOrEqual(card.sub.frame.maxX, card.body.bounds.maxX - 1, what)
            }
        }
    }
}
