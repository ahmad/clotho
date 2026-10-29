import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Drag to reorder: where a drop lands in the tab bar and the sidebar, what's refused, and that the
/// bar keeps the pressed tab's view through a click so it can be dragged.
@MainActor
final class DragTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() {
        window.close()
    }

    func testPayloadRoundTripsAndInsertionIndex() {
        let payload = ChromeDrag.Payload(kind: .tab, machine: "devbox-key", id: 42, workspace: 7)
        XCTAssertEqual(ChromeDrag.Payload(encoded: payload.encoded), payload)
        XCTAssertNil(ChromeDrag.Payload(encoded: "nonsense"))
        XCTAssertEqual(ChromeDrag.insertionIndex(at: 5, middles: [10, 20, 30]), 0)
        XCTAssertEqual(ChromeDrag.insertionIndex(at: 25, middles: [10, 20, 30]), 2)
        XCTAssertEqual(ChromeDrag.insertionIndex(at: 99, middles: [10, 20, 30]), 3)
    }

    // MARK: Tab bar

    private func bar(_ ids: [TabID], selected: TabID) -> TabBarView {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        window.contentView!.addSubview(bar)
        bar.machine = "local"
        bar.workspace = 1
        bar.update(tabs: ids.map { ($0, "tab \($0)", nil, false, nil) }, selected: selected)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func point(_ bar: TabBarView, x: CGFloat) -> NSPoint { bar.convert(NSPoint(x: x, y: 20), to: nil) }

    func testTabDropPositions() throws {
        let bar = bar([10, 11, 12], selected: 10)
        let frames = try [10, 11, 12].map { try XCTUnwrap(bar.frameOfTab($0)) }
        let dragging = ChromeDrag.Payload(kind: .tab, machine: "local", id: 10, workspace: 1)
        // Past the last tab's middle: to the end (index 2 among the other two).
        let end = try XCTUnwrap(bar.tabDrop(dragging, at: point(bar, x: frames[2].maxX - 2)))
        XCTAssertEqual(end.index, 2)
        XCTAssertEqual(end.lineX, frames[2].maxX + s(2), accuracy: 1, "the line just after the last tab")
        // Between 11 and 12.
        XCTAssertEqual(bar.tabDrop(dragging, at: point(bar, x: frames[2].minX + 2))?.index, 1)
        // Over its own place: nothing.
        XCTAssertNil(bar.tabDrop(dragging, at: point(bar, x: frames[0].midX)))
        XCTAssertNil(bar.tabDrop(dragging, at: point(bar, x: frames[1].minX + 2)), "before 11 is where it is")
        // Another machine's or another workspace's tab: nothing.
        XCTAssertNil(bar.tabDrop(ChromeDrag.Payload(kind: .tab, machine: "devbox", id: 10, workspace: 1), at: point(bar, x: frames[2].maxX)))
        XCTAssertNil(bar.tabDrop(ChromeDrag.Payload(kind: .tab, machine: "local", id: 10, workspace: 2), at: point(bar, x: frames[2].maxX)))
        XCTAssertNil(bar.tabDrop(ChromeDrag.Payload(kind: .workspace, machine: "local", id: 1, workspace: 1), at: point(bar, x: frames[2].maxX)))
    }

    /// A click selects on mouse-down; the bar must keep that tab's view so a drag can start from it.
    func testSelectingKeepsTheTabViews() throws {
        let bar = bar([10, 11, 12], selected: 10)
        let before = bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem }
        bar.update(tabs: [10, 11, 12].map { ($0, "tab \($0)", nil, false, nil) }, selected: 11)
        let after = bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem }
        XCTAssertEqual(before.map(ObjectIdentifier.init), after.map(ObjectIdentifier.init), "the same views")
        XCTAssertEqual(after.map(\.isSelected), [false, true, false])
        // A title change still rebuilds.
        bar.update(tabs: [10, 11, 12].map { ($0, "renamed \($0)", nil, false, nil) }, selected: 11)
        let rebuilt = bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem }
        XCTAssertEqual(rebuilt.map(\.label.stringValue), ["renamed 10", "renamed 11", "renamed 12"])
    }

    /// Without the daemon's `move`, nothing drags.
    func testNothingDragsWithoutTheFeature() throws {
        let bar = bar([10, 11], selected: 10)
        let item = try XCTUnwrap(bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? ChromeItem }.first)
        bar.canDrag = { false }
        XCTAssertNil(item.dragPayload?())
        bar.canDrag = { true }
        XCTAssertEqual(item.dragPayload?(), ChromeDrag.Payload(kind: .tab, machine: "local", id: 10, workspace: 1))
    }

    // MARK: Sidebar

    private func sidebar() -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        window.contentView!.addSubview(sidebar)
        func group(_ key: String, _ title: String, _ ids: [WorkspaceID]) -> SidebarGroup {
            let workspaces = ids.map { Workspace(id: $0, name: "W\($0)", tabs: [Tab(id: TabID($0 * 10), activePane: PaneID($0 * 10), layout: .pane(PaneID($0 * 10)))]) }
            return SidebarGroup(key: key, title: title, status: (nil, nil), workspaces: workspaces, selected: ids.first,
                                isConnected: true, isLocal: key == "local", badges: [:])
        }
        sidebar.update(agents: [], unreachable: [], groups: [group("local", "This Mac", [1, 2, 3]), group("devbox", "devbox", [7, 8])])
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func center(_ sidebar: SidebarView, _ machine: MachineKey, _ id: WorkspaceID, dy: CGFloat = 0) -> NSPoint {
        let row = sidebar.workspaceRows(of: machine).first { $0.id == id }!.row
        let frame = row.convert(row.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY + dy)
    }

    func testWorkspaceReorder() throws {
        let sidebar = sidebar()
        let w1 = ChromeDrag.Payload(kind: .workspace, machine: "local", id: 1, workspace: 1)
        let rowHeight = sidebar.workspaceRows(of: "local")[0].row.frame.height
        // Below W3's middle (window y runs up): to the end.
        guard case .reorder("local", 1, 2, _, _, _)? = sidebar.drop(w1, at: center(sidebar, "local", 3, dy: -rowHeight / 3)) else {
            return XCTFail("W1 below W3 goes to the end")
        }
        // Between W2 and W3: index 1.
        guard case .reorder("local", 1, 1, _, _, _)? = sidebar.drop(w1, at: center(sidebar, "local", 3, dy: rowHeight / 3)) else {
            return XCTFail("W1 between W2 and W3")
        }
        // Over its own place, or over the other machine's rows: nothing.
        XCTAssertNil(sidebar.drop(w1, at: center(sidebar, "local", 1)))
        XCTAssertNil(sidebar.drop(w1, at: center(sidebar, "devbox", 8)), "workspaces stay on their machine")
    }

    func testTabOntoWorkspace() throws {
        let sidebar = sidebar()
        let tab = ChromeDrag.Payload(kind: .tab, machine: "local", id: 10, workspace: 1)
        guard case .moveTab("local", 10, 2, _)? = sidebar.drop(tab, at: center(sidebar, "local", 2)) else {
            return XCTFail("a tab onto another workspace of its machine")
        }
        XCTAssertNil(sidebar.drop(tab, at: center(sidebar, "local", 1)), "its own workspace")
        XCTAssertNil(sidebar.drop(tab, at: center(sidebar, "devbox", 7)), "another machine: no drop target")
    }
}
