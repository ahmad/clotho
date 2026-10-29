import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The sidebar's tree: guide lines from a workspace's [+]/[−] to its tabs, crisp 1-pixel lines at every
/// zoom, a + on the workspace row for a new tab, and a quiet + in the machine header for a workspace.
@MainActor
final class SidebarTreeTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarView!
    private var zoom = UIScale.factor

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        UIScale.factor = zoom
        window.close()
    }

    /// Workspace 1 ("Platform") with tabs 10, 11 and 12; workspace 2 ("Docs") with tab 20.
    private func group(workspaces: Bool = true) -> SidebarGroup {
        let platform = Workspace(id: 1, name: "Platform", tabs: [10, 11, 12].map { Tab(id: $0, activePane: PaneID($0 * 10), layout: .pane(PaneID($0 * 10))) })
        let docs = Workspace(id: 2, name: "Docs", tabs: [Tab(id: 20, activePane: 200, layout: .pane(200))])
        return SidebarGroup(key: "local", title: "This Mac", status: (nil, nil), workspaces: workspaces ? [platform, docs] : [],
                            selected: 1, isConnected: true, isLocal: true, badges: [:],
                            tabs: [1: [10, 11, 12].map { SidebarTab(id: $0, title: "tab \($0)", custom: nil, badge: nil) },
                                   2: [SidebarTab(id: 20, title: "notes", custom: nil, badge: nil)]],
                            selectedTab: 11)
    }

    private func update(_ group: SidebarGroup? = nil) {
        sidebar.update(agents: [], unreachable: [], groups: [group ?? self.group()])
        sidebar.layoutSubtreeIfNeeded()
    }

    private func all<T: NSView>(_ type: T.Type) -> [T] {
        func find(_ view: NSView) -> [T] { view.subviews.flatMap { ($0 as? T).map { [$0] } ?? find($0) } }
        return find(sidebar).sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
    }

    private var rows: [SidebarRow] { all(SidebarRow.self) }

    /// The guide segments in window coordinates.
    private func guides(_ row: SidebarRow) -> [NSRect] { row.guideRects.map { row.convert($0, to: nil) } }

    func testTabsHangOffTheirWorkspace() throws {
        update()
        let platform = try XCTUnwrap(rows.first as? WorkspaceRow)
        let tabs = rows[1...3].compactMap { $0 as? TabRow }
        XCTAssertEqual(tabs.map(\.isLastChild), [false, false, true])
        // One vertical column, from under the toggle down through every tab.
        let stem = try XCTUnwrap(guides(platform).first)
        let columns = Set(([stem] + tabs.map { guides($0)[0] }).map(\.minX))
        XCTAssertEqual(columns.count, 1, "every segment in the same pixel column")
        let toggle = try XCTUnwrap(platform.chevron)
        XCTAssertEqual(stem.midX, toggle.convert(NSPoint(x: toggle.bounds.midX, y: 0), to: nil).x, accuracy: 1, "under the toggle's centre")
        // The segments join with no gap: each tab's line starts where the row above ends.
        var bottom = stem.minY
        for tab in tabs {
            let line = guides(tab)[0]
            XCTAssertEqual(line.maxY, bottom, accuracy: 0.01, "joins the line above")
            bottom = line.minY
        }
        // ├ for middle tabs (the line runs on), └ for the last (it stops at the arm).
        let rowFrames = tabs.map { $0.convert($0.bounds, to: nil) }
        XCTAssertEqual(guides(tabs[0])[0].minY, rowFrames[0].minY, accuracy: 0.01)
        XCTAssertEqual(guides(tabs[2])[0].minY, guides(tabs[2])[1].minY, accuracy: 0.01, "the last line ends on its arm")
        // The arm reaches toward the title and stops short of it.
        for tab in tabs {
            let arm = guides(tab)[1]
            XCTAssertEqual(arm.midY, tab.convert(NSPoint(x: 0, y: tab.bounds.midY), to: nil).y, accuracy: 1)
            XCTAssertLessThan(arm.maxX, tab.convert(tab.label.frame, to: nil).minX)
        }
    }

    /// A click on the toggle reaches the row (which toggles, and takes a background window's first click).
    func testToggleClicksGoToTheRow() throws {
        update()
        let platform = try XCTUnwrap(rows.first as? WorkspaceRow)
        let toggle = try XCTUnwrap(platform.chevron)
        let point = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: platform.superview)
        XCTAssertTrue(platform.hitTest(point) === platform)
    }

    func testCollapsedWorkspaceDrawsNoStem() throws {
        update()
        sidebar.setExpanded(false, "local", 1)
        sidebar.layoutSubtreeIfNeeded()
        let platform = try XCTUnwrap(rows.first as? WorkspaceRow)
        XCTAssertEqual(platform.chevron?.isExpanded, false)
        XCTAssertTrue(platform.guideRects.isEmpty)
    }

    /// Every line is one device pixel wide, on whole pixels, at each zoom level.
    func testLinesAreOnePixelAtEveryZoom() throws {
        for zoom in [CGFloat(0.8), 1, 1.3] as [CGFloat] {
            UIScale.factor = zoom
            sidebar = SidebarView(frame: window.contentView!.bounds)
            window.contentView = sidebar
            update()
            let scale = window.backingScaleFactor
            // Each tab's line meets the line of the row above, with no gap or overlap.
            for (above, row) in zip(rows, rows.dropFirst()) where row is TabRow {
                let line = try XCTUnwrap(guides(row).first), upper = try XCTUnwrap(guides(above).first)
                XCTAssertEqual(line.maxY * scale, upper.minY * scale, accuracy: 0.01, "zoom \(zoom): \(row.label.stringValue) joins")
            }
            for row in rows {
                for rect in row.guideRects + (row.chevron?.rects ?? []) {
                    let pixels = row.convertToBacking(rect)
                    XCTAssertEqual(min(pixels.width, pixels.height), 1, accuracy: 0.01, "zoom \(zoom): 1 px lines")
                    let inWindow = row.convert(rect, to: nil)
                    XCTAssertEqual((inWindow.minX * scale).rounded(), inWindow.minX * scale, accuracy: 0.01, "zoom \(zoom): on whole pixels")
                    XCTAssertEqual((inWindow.minY * scale).rounded(), inWindow.minY * scale, accuracy: 0.01, "zoom \(zoom): on whole pixels")
                }
            }
        }
    }

    func testToggleShowsMinusWhenOpenAndPlusWhenClosed() {
        let toggle = TreeToggle(expanded: true)
        toggle.frame = NSRect(x: 0, y: 0, width: TreeToggle.size, height: TreeToggle.size)
        XCTAssertEqual(toggle.rects.count, 5, "the box and a minus")
        toggle.setExpanded(false, animated: false)
        XCTAssertEqual(toggle.rects.count, 6, "and the plus's bar")
    }

    /// A workspace row's + shows under the pointer, beside close, and makes a tab in that workspace.
    func testWorkspacePlusMakesATab() throws {
        var asked: [(MachineKey, WorkspaceID)] = []
        sidebar.onNewTab = { asked.append(($0, $1)) }
        update()
        let docs = try XCTUnwrap(rows.first { $0.label.stringValue == "Docs" } as? WorkspaceRow)
        XCTAssertTrue(docs.newTabButton.isHidden, "hidden at rest")
        docs.setHovering(true)
        XCTAssertFalse(docs.newTabButton.isHidden, "shown under the pointer")
        XCTAssertFalse(docs.closeButton.isHidden)
        XCTAssertLessThan(docs.newTabButton.frame.maxX, docs.closeButton.frame.minX + 1, "just before close")
        XCTAssertLessThan(docs.label.frame.maxX, docs.newTabButton.frame.minX, "the name stops before it")
        docs.newTabButton.performClick(nil)
        XCTAssertEqual(asked.map(\.0), ["local"])
        XCTAssertEqual(asked.map(\.1), [2])
        docs.setHovering(false)
        XCTAssertTrue(docs.newTabButton.isHidden)
        // Tab rows have no +.
        XCTAssertFalse(rows.contains { $0 is TabRow && $0.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "New Tab" } })
    }

    /// New Workspace is a quiet + in the machine's header; only a machine with no workspaces lists a row
    /// for it.
    func testQuietNewWorkspace() throws {
        var asked: [MachineKey] = []
        sidebar.onCreateWorkspace = { asked.append($0) }
        update()
        let header = try XCTUnwrap(all(MachineHeader.self).first { $0.newWorkspaceButton?.isHidden == false })
        let plus = try XCTUnwrap(header.newWorkspaceButton)
        XCTAssertFalse(plus.isBright, "dim at rest")
        plus.setHovering(true)
        XCTAssertTrue(plus.isBright, "brighter under the pointer")
        plus.performClick(nil)
        XCTAssertEqual(asked, ["local"])
        XCTAssertNotNil(plus.toolTip?.range(of: "⌘N"), "the tooltip names the shortcut")
        let newWorkspaceRows = { self.all(ChromeItem.self).filter { $0.label.stringValue == "New Workspace" } }
        XCTAssertTrue(newWorkspaceRows().isEmpty, "no row while it has workspaces")

        update(group(workspaces: false))
        let row = try XCTUnwrap(newWorkspaceRows().first, "an empty machine lists one")
        row.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                              clickCount: 1, pressure: 1)))
        XCTAssertEqual(asked, ["local", "local"])
    }
}
