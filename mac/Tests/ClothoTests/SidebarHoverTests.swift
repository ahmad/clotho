import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// Sidebar hover follows the pointer: at most the row under it shows hover, whatever events AppKit sends
/// or fails to send while rows move, scroll or are rebuilt, and nothing does once the pointer has left.
@MainActor
final class SidebarHoverTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarView!

    override func setUp() {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        UserDefaults.standard.removeObject(forKey: "CollapsedMachines")
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar = SidebarView(frame: window.contentView!.bounds)
        window.contentView = sidebar
    }

    override func tearDown() {
        Pointer.simulation = .off
        UserDefaults.standard.removeObject(forKey: "CollapsedWorkspaces")
        window.close()
    }

    /// Workspaces `ids`, one tab each; the first is selected.
    private func group(_ ids: [WorkspaceID]) -> SidebarGroup {
        let workspaces = ids.map { id in
            Workspace(id: id, name: "Workspace \(id)", tabs: [Tab(id: TabID(id * 10), activePane: PaneID(id * 100), layout: .pane(PaneID(id * 100)))])
        }
        return SidebarGroup(key: "local", title: "This Mac", status: (nil, nil), workspaces: workspaces,
                            selected: ids.first ?? 1, isConnected: true, isLocal: true, badges: [:])
    }

    private func update(_ ids: [WorkspaceID]) {
        sidebar.update(agents: [], unreachable: [], groups: [group(ids)])
        sidebar.layoutSubtreeIfNeeded()
        settle()
    }

    /// Lets the deferred refresh after an update run.
    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func all<T>(_ type: T.Type) -> [T] {
        func find(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + find($0) } }
        return find(sidebar).compactMap { $0 as? T }
    }

    private var rows: [SidebarRow] { all(SidebarRow.self) }
    private var hovered: [ChromeItem] { all(ChromeItem.self).filter(\.isHovering) }
    private var anythingHovered: Bool { all(HoverRefreshing.self).contains { $0.isHovering } }

    /// The pointer, fixed at `point` in window coordinates.
    private func point(_ point: NSPoint) { Pointer.simulation = .at(window.convertPoint(toScreen: point)) }

    /// The row whose visible part is under `point` (window coordinates).
    private func row(at point: NSPoint) -> SidebarRow? {
        rows.first { Pointer.visiblePart(of: $0).contains($0.convert(point, from: nil)) }
    }

    private func entered() -> NSEvent {
        NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    func testOnlyTheRowUnderAStillPointerHovers() throws {
        update([1, 2, 3])
        let target = rows.first { $0.label.stringValue == "Workspace 2" }!
        let fixed = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        point(fixed)
        sidebar.refreshHover()
        XCTAssertEqual(hovered.map(\.label.stringValue), ["Workspace 2"])

        // Late or spurious enter events, as AppKit sends while rows slide under the pointer: each is
        // checked against where the pointer is.
        rows.forEach { $0.mouseEntered(with: entered()) }
        XCTAssertEqual(hovered.map(\.label.stringValue), ["Workspace 2"])

        // Workspace 1 closes: every row below it moves up under the still pointer.
        update([2, 3])
        let now = try XCTUnwrap(row(at: fixed))
        XCTAssertNotEqual(now.label.stringValue, "Workspace 2", "a different row is under the pointer now")
        XCTAssertEqual(hovered.map(\.label.stringValue), [now.label.stringValue])

        // A rebuild with a workspace added on top moves everything down.
        update([4, 5, 2, 3])
        XCTAssertLessThanOrEqual(hovered.count, 1)
        XCTAssertEqual(hovered.first.map(\.label.stringValue), row(at: fixed)?.label.stringValue)

        // Scrolling moves rows under it too.
        update(Array(1...40))
        let clip = try XCTUnwrap(all(NSClipView.self).first { $0.documentView?.frame.height ?? 0 > $0.bounds.height })
        clip.scroll(to: NSPoint(x: 0, y: s(150)))
        XCTAssertLessThanOrEqual(hovered.count, 1)
        XCTAssertEqual(hovered.first.map(\.label.stringValue), row(at: fixed)?.label.stringValue)
        XCTAssertNotNil(row(at: fixed), "the pointer is over a row")
    }

    /// The bug: a row's visibleRect reaches past its bounds (macOS 14+), so a refresh with the pointer over
    /// one row lit them all.
    func testARowsVisiblePartIsWithinItsBounds() {
        update([1, 2, 3])
        for row in rows {
            XCTAssertTrue(row.bounds.contains(Pointer.visiblePart(of: row)) || Pointer.visiblePart(of: row).isEmpty)
        }
        let target = rows[1]
        point(target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil))
        rows.forEach { $0.updateTrackingAreas() }
        XCTAssertEqual(hovered.count, 1, "only the row under the pointer")
    }

    func testNothingHoversOnceThePointerLeaves() {
        update([1, 2, 3])
        let target = rows[2]
        point(target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil))
        sidebar.refreshHover()
        XCTAssertEqual(hovered.count, 1)

        // The pointer leaves for the terminal and the exit never arrives: the backstop clears it.
        Pointer.simulation = .away
        settle(0.8)
        XCTAssertFalse(anythingHovered, "no hover after the pointer has gone, even without an exit event")

        // Stale hover on every row (the reported bug), cleared by the window losing focus.
        rows.forEach { $0.setHovering(true) }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(anythingHovered)

        // ... and by the app going to the background.
        rows.forEach { $0.setHovering(true) }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(anythingHovered)

        // ... and by a selection move (the fast path) or a rebuild.
        rows.forEach { $0.setHovering(true) }
        update([1, 2, 3])
        XCTAssertFalse(anythingHovered)
    }
}
