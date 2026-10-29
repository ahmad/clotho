import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// New Workspace is make + rename in one action: the rename opens on the new workspace's row once the
/// daemon lists it, with the default name selected; Return names it, Esc keeps the default, and the
/// terminal gets the keyboard back either way.
@MainActor
final class NewWorkspaceRenameTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarView!
    private var renamed: [(MachineKey, WorkspaceID, String)] = []
    private var endedEditing = 0

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
        sidebar.onRename = { [weak self] in self?.renamed.append(($0, $1, $2)) }
        sidebar.onEditingEnded = { [weak self] in self?.endedEditing += 1 }
    }

    override func tearDown() {
        window.close()
    }

    /// Workspaces `ids` on this Mac, one tab each; `title` is every tab's title.
    private func update(_ ids: [WorkspaceID], title: String = "zsh") {
        var tabs: [WorkspaceID: [SidebarTab]] = [:]
        var workspaces: [Workspace] = []
        for id in ids {
            let tab = TabID(id * 10)
            workspaces.append(Workspace(id: id, name: "Workspace \(id)", tabs: [Tab(id: tab, activePane: PaneID(tab), layout: .pane(PaneID(tab)))]))
            tabs[id] = [SidebarTab(id: tab, title: title, custom: nil, badge: nil)]
        }
        let group = SidebarGroup(key: "local", title: "This Mac", status: (nil, nil), workspaces: workspaces, selected: ids.last,
                                 isConnected: true, isLocal: true, badges: [:], tabs: tabs, selectedTab: ids.last.map { TabID($0 * 10) })
        sidebar.update(agents: [], unreachable: [], groups: [group])
        sidebar.layoutSubtreeIfNeeded()
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    private func row(_ name: String) -> ChromeItem? {
        func find(_ view: NSView) -> [WorkspaceRow] { view.subviews.flatMap { ($0 as? WorkspaceRow).map { [$0] } ?? find($0) } }
        return find(sidebar).first { $0.label.stringValue == name || $0.editor != nil && name == "*editing*" }
    }

    private var editingRow: ChromeItem? { row("*editing*") }

    /// The daemon answers before its model arrives (a remote round trip): the rename waits for the row,
    /// survives a rebuild in between, and opens with the whole default name selected.
    func testRenameOpensWhenTheWorkspaceIsListed() throws {
        update([1])
        sidebar.renameWhenListed("local", 2)
        settle()
        XCTAssertNil(editingRow, "nothing to rename until the daemon lists it")
        update([1], title: "vim")  // a rebuild for something else in between
        settle()
        XCTAssertNil(editingRow)
        update([1, 2])
        settle()
        let editing = try XCTUnwrap(editingRow, "the new row is being renamed")
        let field = try XCTUnwrap(editing.editor)
        XCTAssertEqual(field.stringValue, "Workspace 2")
        let editor = try XCTUnwrap(field.currentEditor())
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 11), "the default name is selected, to type over")

        // More model updates while typing (the new shell's title, focus) don't rebuild the field away.
        update([1, 2], title: "zsh — ~")
        settle()
        XCTAssertTrue(editing.editor === field)
        XCTAssertTrue(editingRow === editing)

        // Typing then Return names it, and the terminal takes the keyboard.
        editor.insertText("Platform")
        XCTAssertTrue(editing.control(field, textView: editor as! NSTextView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(renamed.map(\.2), ["Platform"])
        XCTAssertEqual(renamed.map(\.1), [2])
        XCTAssertEqual(endedEditing, 1, "the terminal gets the keyboard")
        XCTAssertNil(editingRow)
    }

    /// The daemon's model arrives first: the rename opens at once.
    func testRenameOpensAtOnceWhenTheRowIsThere() {
        update([1, 2])
        sidebar.renameWhenListed("local", 2)
        settle()
        XCTAssertEqual(editingRow?.editor?.stringValue, "Workspace 2")
    }

    /// Esc keeps the default name, and the terminal still gets the keyboard, even when the sidebar had it.
    func testEscKeepsTheDefault() throws {
        update([1])
        sidebar.takeKeyboard()
        sidebar.renameWhenListed("local", 2)
        update([1, 2])
        settle()
        let editing = try XCTUnwrap(editingRow)
        let field = try XCTUnwrap(editing.editor)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Half typed")
        XCTAssertTrue(editing.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(renamed.isEmpty, "Esc keeps the default")
        XCTAssertEqual(row("Workspace 2")?.isEditing, false)
        XCTAssertEqual(endedEditing, 1, "the terminal, not the sidebar, takes the keyboard after a new workspace's rename")
    }

    /// An empty name keeps the default too.
    func testEmptyNameKeepsTheDefault() throws {
        update([1, 2])
        sidebar.renameWhenListed("local", 2)
        settle()
        let editing = try XCTUnwrap(editingRow)
        let field = try XCTUnwrap(editing.editor)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        _ = editing.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(renamed.isEmpty)
    }
}
