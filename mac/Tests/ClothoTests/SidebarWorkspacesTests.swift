import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The sidebar lists workspaces only (their tabs are in the tab bar and ⌘P): each with its most urgent
/// agent's dot, a + for a new tab on hover, and Close in its right-click menu. The arrow keys walk them.
@MainActor
final class SidebarWorkspacesTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarView!

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
    }

    override func tearDown() {
        window.close()
    }

    /// "Platform" (1) with two tabs, its agent waiting; "Docs" (2) with one tab.
    private func group(selected: WorkspaceID? = 1, workspaces: Bool = true, docsName: String = "Docs") -> SidebarGroup {
        let platform = Workspace(id: 1, name: "Platform", tabs: [Tab(id: 10, activePane: 100, layout: .pane(100)),
                                                                 Tab(id: 11, activePane: 110, layout: .pane(110))])
        let docs = Workspace(id: 2, name: docsName, tabs: [Tab(id: 20, activePane: 200, layout: .pane(200))])
        return SidebarGroup(key: "local", title: "This Mac", status: (nil, nil), workspaces: workspaces ? [platform, docs] : [],
                            selected: selected, isConnected: true, isLocal: true, badges: [1: .systemOrange])
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

    func testWorkspacesOnlyWithTheirAgentsDot() {
        update()
        XCTAssertEqual(rows.map(\.label.stringValue), ["Platform", "Docs"], "no tab rows")
        XCTAssertTrue(rows.allSatisfy { $0 is WorkspaceRow })
        XCTAssertTrue(rows[0].isSelected)
        XCTAssertFalse(rows[0].badge.isHidden, "Platform's waiting agent shows")
        XCTAssertTrue(rows[1].badge.isHidden, "Docs has nothing running")
        XCTAssertEqual(rows[0].toolTip, "2 tabs")
        XCTAssertTrue(all(NSView.self).allSatisfy { !String(describing: type(of: $0)).contains("Toggle") }, "no [+]/[−] toggles")
    }

    /// A click changes only the selection, and the rows there are take it (no rebuild); anything else
    /// rebuilds them.
    func testSelectionMovesWithoutRebuilding() {
        update()
        let before = rows
        update(group(selected: 2))
        XCTAssertTrue(zip(before, rows).allSatisfy { $0 === $1 }, "the same rows")
        XCTAssertTrue(rows[1].isSelected)
        XCTAssertFalse(rows[0].isSelected)
        update(group(selected: 2, docsName: "Notes"))
        XCTAssertFalse(rows[1] === before[1], "a new name rebuilds")
        XCTAssertEqual(rows[1].label.stringValue, "Notes")
        XCTAssertTrue(rows[1].isSelected)
    }

    /// Under the pointer a workspace shows only a + (a new tab there).
    func testWorkspacePlusMakesATab() throws {
        var asked: [(MachineKey, WorkspaceID)] = []
        sidebar.onNewTab = { asked.append(($0, $1)) }
        update()
        let docs = try XCTUnwrap(rows.first { $0.label.stringValue == "Docs" } as? WorkspaceRow)
        XCTAssertTrue(docs.newTabButton.isHidden, "hidden at rest")
        docs.setHovering(true)
        XCTAssertFalse(docs.newTabButton.isHidden, "shown under the pointer")
        docs.newTabButton.performClick(nil)
        XCTAssertEqual(asked.map(\.0), ["local"])
        XCTAssertEqual(asked.map(\.1), [2])
    }

    /// Right-click on a workspace: New Tab, Rename Workspace, and Close Workspace… (which asks first).
    func testWorkspaceMenuCloses() throws {
        var closed: [(MachineKey, WorkspaceID)] = [], newTabs = 0
        sidebar.onClose = { closed.append(($0, $1)) }
        sidebar.onNewTab = { _, _ in newTabs += 1 }
        update()
        let docs = try XCTUnwrap(rows.first { $0.label.stringValue == "Docs" } as? WorkspaceRow)
        let menu = try XCTUnwrap(docs.contextMenu?())
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["New Tab", "Rename Workspace", "Highlight", "Close Workspace…"])
        let close = try XCTUnwrap(menu.items.first { $0.title == "Close Workspace…" })
        _ = close.target?.perform(close.action, with: close)
        XCTAssertEqual(closed.map(\.1), [2])
        let newTab = try XCTUnwrap(menu.items.first)
        _ = newTab.target?.perform(newTab.action, with: newTab)
        XCTAssertEqual(newTabs, 1)
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

    func testArrowKeysWalkTheWorkspaces() throws {
        update()
        var went: [WorkspaceID] = []
        sidebar.onSelect = { went.append($1) }
        sidebar.takeKeyboard()
        XCTAssertTrue(sidebar.hasKeyboard)
        XCTAssertEqual(sidebar.cursor, .workspace("local", 1), "starts on the selected row")
        XCTAssertTrue(rows[0].showsCursor)
        func press(_ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "",
                                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            sidebar.keyDown(with: event)
        }
        try press(125)  // ↓ to Docs
        try press(125)  // ↓ stays at the end
        try press(126)  // ↑ back to Platform
        XCTAssertEqual(went, [2, 1])
        XCTAssertEqual(sidebar.cursor, .workspace("local", 1))
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
