import AppKit
import XCTest
@testable import Clotho

/// The saved-machine list behind Manage Machines and the sidebar's order, in a private defaults suite.
final class MachineListTests: XCTestCase {
    private var suite = ""
    private var saved: UserDefaults!

    override func setUp() {
        suite = "clotho-machines-test-\(UUID().uuidString)"
        saved = Machine.store
        Machine.store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        Machine.store.removePersistentDomain(forName: suite)
        Machine.store = saved
    }

    private var names: [String] { Machine.all().map(\.label) }

    func testAddEditRemove() throws {
        XCTAssertEqual(Machine.all().count, 1, "only this Mac")
        XCTAssertTrue(Machine.all()[0].isLocal)
        let imac = Machine.add(label: "imac", target: "macbook@imac")
        let big = Machine.add(label: "", target: "ahmad@devbox")
        XCTAssertEqual(Array(names.dropFirst()), ["imac", "ahmad@devbox"], "a blank name falls back to the target")

        let edited = Machine.update(try XCTUnwrap(big.id), label: "devbox", target: "ahmad@devbox.tail")
        XCTAssertEqual(edited.id, big.id, "editing keeps the id, so its settings and connection key stay")
        XCTAssertEqual(Machine.all().last?.target, "ahmad@devbox.tail")
        XCTAssertEqual(Machine.all().last?.label, "devbox")

        Machine.remove(try XCTUnwrap(imac.id))
        XCTAssertEqual(Array(names.dropFirst()), ["devbox"])
    }

    func testReorderKeepsThisMacFirst() throws {
        let a = Machine.add(label: "a", target: "a"), b = Machine.add(label: "b", target: "b"), c = Machine.add(label: "c", target: "c")
        Machine.move(try XCTUnwrap(c.id), to: 0)
        XCTAssertEqual(Array(names.dropFirst()), ["c", "a", "b"])
        Machine.move(try XCTUnwrap(c.id), to: 99)
        XCTAssertEqual(Array(names.dropFirst()), ["a", "b", "c"])
        Machine.move(try XCTUnwrap(a.id), to: 1)
        XCTAssertEqual(Array(names.dropFirst()), ["b", "a", "c"])
        XCTAssertTrue(Machine.all()[0].isLocal)
        _ = b
    }

    func testThisMacIsNotEditable() {
        XCTAssertFalse(Machine.local.isEditable)
        XCTAssertTrue(Machine.add(label: "x", target: "x").isEditable)
    }

    /// Table rows count this Mac first; dropping above a row maps to a saved-machine index.
    func testDropRowToSavedIndex() {
        // Rows: 0 Mac, 1 a, 2 b, 3 c.
        XCTAssertEqual(MachineManagerController.savedIndex(dropRow: 1, from: 3), 0, "c to the top")
        XCTAssertEqual(MachineManagerController.savedIndex(dropRow: 4, from: 1), 2, "a to the end")
        XCTAssertEqual(MachineManagerController.savedIndex(dropRow: 0, from: 2), 0, "never above this Mac")
        XCTAssertEqual(MachineManagerController.savedIndex(dropRow: 3, from: 1), 1, "a below b")
    }
}

/// The sidebar's footer stays pinned to the bottom, and the outline button is styled and placed as asked.
@MainActor
final class SidebarFooterTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testFooterIsPinnedToTheBottom() {
        for height in [CGFloat(500), 900] {
            let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: height))
            sidebar.layoutSubtreeIfNeeded()
            XCTAssertEqual(sidebar.footer.frame.minY, 0, "at the bottom (y up), whatever the height")
            XCTAssertEqual(sidebar.footer.frame.height, SidebarFooter.height, accuracy: 0.5)
            XCTAssertEqual(sidebar.footer.frame.width, 220)
        }
    }

    func testOutlineButtonStyle() {
        let button = OutlineButton(title: "Create Workspace", symbol: "plus")
        button.frame = NSRect(x: 0, y: 0, width: 180, height: OutlineButton.height)
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.layer?.borderWidth, 1)
        XCTAssertEqual(button.layer?.cornerRadius ?? 0, s(6), accuracy: 0.01)
        XCTAssertEqual(button.layer?.backgroundColor, nil, "no fill")
        XCTAssertEqual(button.label.font?.pointSize ?? 0, s(12), accuracy: 0.01)
        let rest = button.layer?.borderColor
        button.setHovering(true)
        XCTAssertNotEqual(button.layer?.borderColor, rest, "hover brightens the border")
        XCTAssertEqual(button.label.textColor, Theme.foreground)
    }

    func testOutlineButtonScalesWithZoom() {
        let saved = UIScale.factor
        defer { UIScale.factor = saved }
        UIScale.factor = 1.4
        XCTAssertEqual(OutlineButton.height, 26 * 1.4, accuracy: 0.001)
        XCTAssertEqual(OutlineButton(title: "x", symbol: "plus").label.font?.pointSize ?? 0, 12 * 1.4, accuracy: 0.01)
    }
}
