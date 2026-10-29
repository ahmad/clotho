import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The sidebar lists each workspace's tabs under it: they collapse and expand (remembered), a tab row
/// selects its tab, and the arrow keys walk the rows.
@MainActor
final class SidebarTabsTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarView!

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        makeSidebar()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        window.close()
    }

    private func makeSidebar() {
        sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
    }

    /// Workspace 1 ("Platform") with tabs 10 and 11 (11 waiting, focused); workspace 2 ("Docs") with tab 20.
    private func group(selectedTab: TabID? = 11, selected: WorkspaceID? = 1) -> SidebarGroup {
        SidebarGroup(key: "local", title: "This Mac", status: (nil, nil),
                     workspaces: [Workspace(id: 1, name: "Platform", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100)),
                                                                             Tab(id: 11, activePane: 110, layout: .pane(110))]),
                                  Workspace(id: 2, name: "Docs", tabs: [Tab(id: 20, activePane: 200, layout: .pane(200))])],
                     selected: selected, isConnected: true, isLocal: true, badges: [1: .systemOrange],
                     tabs: [1: [SidebarTab(id: 10, title: "zsh", custom: nil, badge: nil),
                                SidebarTab(id: 11, title: "claude", custom: nil, badge: .systemOrange)],
                            2: [SidebarTab(id: 20, title: "notes", custom: "notes", badge: .systemGreen)]],
                     selectedTab: selectedTab)
    }

    private func update(_ group: SidebarGroup? = nil) {
        sidebar.update(agents: [], unreachable: [], groups: [group ?? self.group()])
        sidebar.layoutSubtreeIfNeeded()
    }

    private var rows: [SidebarRow] {
        func find(_ view: NSView) -> [SidebarRow] { view.subviews.flatMap { ($0 as? SidebarRow).map { [$0] } ?? find($0) } }
        return find(sidebar).sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
    }

    private var titles: [String] { rows.map { ($0 is TabRow ? "  " : "") + $0.label.stringValue } }

    func testTabsListUnderTheirWorkspace() {
        update()
        XCTAssertEqual(titles, ["Platform", "  zsh", "  claude", "Docs", "  notes"])
        let platform = rows[0], claude = rows[2]
        XCTAssertTrue(claude.isSelected, "the focused tab carries the selection")
        XCTAssertFalse(platform.isSelected)
        XCTAssertTrue(platform.holdsSelection, "its workspace a lighter tint")
        XCTAssertTrue(platform.badge.isHidden, "an expanded workspace leaves the dots to its tabs")
        XCTAssertFalse(claude.badge.isHidden)
        XCTAssertTrue(rows[1].badge.isHidden, "a tab with nothing running has no dot")
    }

    /// A click changes only the selection, and the rows there are take it (no rebuild); anything else
    /// rebuilds them.
    func testSelectionMovesWithoutRebuilding() {
        update()
        let before = rows
        update(group(selectedTab: 20, selected: 2))
        XCTAssertTrue(zip(before, rows).allSatisfy { $0 === $1 }, "the same rows")
        XCTAssertTrue(rows[4].isSelected, "notes selected")
        XCTAssertFalse(rows[2].isSelected)
        XCTAssertFalse(rows[0].holdsSelection)
        XCTAssertTrue(rows[3].holdsSelection, "Docs holds it now")

        var renamed = group(selectedTab: 20, selected: 2)
        renamed.tabs[2] = [SidebarTab(id: 20, title: "todo", custom: "todo", badge: .systemGreen)]
        update(renamed)
        XCTAssertFalse(rows[4] === before[4], "a new title rebuilds")
        XCTAssertEqual(titles.last, "  todo")
        XCTAssertTrue(rows[4].isSelected)
    }

    func testCollapseHidesTabsAndRaisesTheMostUrgentDot() throws {
        update()
        sidebar.setExpanded(false, "local", 1)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(titles, ["Platform", "Docs", "  notes"])
        let platform = rows[0]
        XCTAssertTrue(platform.isSelected, "collapsed, the workspace takes the selection")
        XCTAssertFalse(platform.badge.isHidden, "and shows its waiting tab's dot")
        XCTAssertEqual(platform.badge.layer?.backgroundColor, NSColor.systemOrange.cgColor)
        XCTAssertEqual(platform.chevron?.isExpanded, false)

        // Remembered across launches.
        makeSidebar()
        update()
        XCTAssertEqual(titles, ["Platform", "Docs", "  notes"])

        sidebar.setExpanded(true, "local", 1)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(titles, ["Platform", "  zsh", "  claude", "Docs", "  notes"])
    }

    func testCollapseAndExpandAll() {
        update()
        sidebar.setAllExpanded(false)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(titles, ["Platform", "Docs"])
        // Option-click on a chevron: every workspace follows.
        rows[1].onToggle?(true)
        sidebar.layoutSubtreeIfNeeded()
        let expectation = expectation(description: "chevron animation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(titles, ["Platform", "  zsh", "  claude", "Docs", "  notes"])
    }

    func testClickingATabRowSelectsThatTab() throws {
        update()
        var selected: [(MachineKey, TabID)] = [], workspaces: [WorkspaceID] = []
        sidebar.onSelectTab = { selected.append(($0, $1)) }
        sidebar.onSelect = { workspaces.append($1) }
        let notes = rows[4]
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: notes.convert(NSPoint(x: notes.bounds.midX, y: notes.bounds.midY), to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let hit = window.contentView?.superview?.hitTest(event.locationInWindow)
        XCTAssertTrue(hit === notes || hit?.isDescendant(of: notes) == true, "the click lands on the tab row")
        notes.mouseDown(with: event)
        XCTAssertEqual(selected.map(\.1), [20])
        XCTAssertEqual(selected.first?.0, "local")
        XCTAssertEqual(workspaces, [])
    }

    func testRenamingATabRowInPlace() {
        update()
        var renamed: [(TabID, String)] = []
        sidebar.onRenameTab = { renamed.append(($1, $2)) }
        sidebar.beginRenameTab("local", 20)
        let field = rows[4].subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
        XCTAssertEqual(field?.stringValue, "notes", "starts from the tab's own name")
        field?.stringValue = "release notes"
        rows[4].endEditing(commit: true)
        XCTAssertEqual(renamed.map(\.0), [20])
        XCTAssertEqual(renamed.map(\.1), ["release notes"])
        XCTAssertEqual(rows[4].label.stringValue, "release notes", "shown at once")
    }

    func testArrowKeysWalkTheRows() throws {
        update()
        var went: [String] = []
        sidebar.onSelect = { went.append("ws \($1)") }
        sidebar.onSelectTab = { went.append("tab \($1)") }
        sidebar.takeKeyboard()
        XCTAssertTrue(sidebar.hasKeyboard)
        XCTAssertEqual(sidebar.cursor, .tab("local", 1, 11), "starts on the selected row")
        XCTAssertTrue(rows[2].showsCursor)
        func press(_ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "",
                                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            sidebar.keyDown(with: event)
        }
        try press(125)  // ↓ to Docs
        try press(125)  // ↓ to notes
        try press(125)  // ↓ stays at the end
        try press(123)  // ← from a tab to its workspace
        try press(123)  // ← collapses Docs
        XCTAssertFalse(sidebar.isExpanded("local", 2))
        try press(124)  // → expands it
        XCTAssertTrue(sidebar.isExpanded("local", 2))
        try press(124)  // → into its first tab
        try press(126)  // ↑ back to Docs
        XCTAssertEqual(went, ["ws 2", "tab 20", "ws 2", "tab 20", "ws 2"])
        XCTAssertEqual(sidebar.cursor, .workspace("local", 2))
        var toTerminal = false
        sidebar.onFocusTerminal = { toTerminal = true }
        try press(53)  // Esc
        XCTAssertTrue(toTerminal)
    }

    /// A click on empty sidebar space never takes the keyboard from the terminal.
    func testSidebarTakesTheKeyboardOnlyWhenAsked() {
        update()
        XCTAssertFalse(sidebar.acceptsFirstResponder)
        sidebar.takeKeyboard()
        XCTAssertTrue(sidebar.acceptsFirstResponder)
        window.makeFirstResponder(nil)
        XCTAssertFalse(sidebar.acceptsFirstResponder, "until it's given back")
    }
}
