import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// "Conflicting constraints detected" was logged by about forty tests (and by the app, at every launch and
/// for every pane in a repository): the Changes view's diff box is hidden at first, which collapses it to
/// no size, and its insets couldn't hold; and a pane's git strip was made with no frame. Both are laid out
/// so that nothing conflicts; what the user sees is the same.
///
/// These check the layout itself: with a conflict AppKit breaks one of the constraints, and a frame then
/// isn't what its constraints say. (Reading the log from inside the process isn't dependable: it is
/// written late and not always to stderr. To count the lines of a whole run, use
/// `OS_ACTIVITY_DT_MODE=YES swift test 2>&1 | grep -c "Conflicting constraints detected"`: it was 1395
/// for the suites that open the main window, and is 0.)
@MainActor
final class ConstraintLogTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func tearDown() { ChangesFixture.restore(saved) }

    /// Where a view is for layout: constraints place alignment rects, not frames (a button's and a
    /// label's differ by a few points).
    private func aligned(_ view: NSView) -> NSRect { view.alignmentRect(forFrame: view.frame) }

    /// Every inset of the diff box holds.
    private func assertInsetsHold(_ view: ChangesView, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let content = view.diffContent
        let button = aligned(view.openButton), title = aligned(view.diffTitle), area = aligned(view.diffArea)
        XCTAssertEqual(button.width, s(18), accuracy: 0.01, "the button's width, \(what)", file: file, line: line)
        XCTAssertEqual(button.height, s(18), accuracy: 0.01, "the button's height, \(what)", file: file, line: line)
        XCTAssertEqual(button.maxX, content.bounds.maxX - s(8), accuracy: 0.01, "the button's inset, \(what)", file: file, line: line)
        XCTAssertEqual(title.minX, s(10), accuracy: 0.01, "the title's inset, \(what)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.minX, title.maxX + s(6) - 0.01, "the gap between them, \(what)", file: file, line: line)
        XCTAssertEqual(area.minX, 1, accuracy: 0.01, "the diff's inset, \(what)", file: file, line: line)
        XCTAssertEqual(area.maxX, content.bounds.maxX, accuracy: 0.01, what, file: file, line: line)
        XCTAssertEqual(area.height, content.bounds.height - s(24), accuracy: 0.01, "the diff under its title row, \(what)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(content.frame.width, ChangesView.diffContentLeast.width, what, file: file, line: line)
        XCTAssertGreaterThanOrEqual(content.frame.height, ChangesView.diffContentLeast.height, what, file: file, line: line)
    }

    /// No file selected: the split view collapses the diff box to no size. Its content keeps a size its
    /// insets can hold (on main the box itself held them, at 0×0, and couldn't).
    func testTheCollapsedDiffBoxKeepsItsInsets() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = ChangesView(model: ChangesModel())
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        let box = try XCTUnwrap(view.diffContent.superview)
        XCTAssertTrue(box.isHidden, "the box is collapsed")
        XCTAssertLessThan(box.frame.height, ChangesView.diffContentLeast.height, "to less than its content needs")
        assertInsetsHold(view, "collapsed")
        // Narrow and short too: less than an inspector can be.
        window.setContentSize(NSSize(width: 150, height: 120))
        window.contentView?.layoutSubtreeIfNeeded()
        assertInsetsHold(view, "collapsed and narrow")
    }

    /// In the app: a pane in a repository with changes, the inspector on Changes, a file selected (the
    /// diff box shown: its content is exactly the box, so nothing moved) and let go again.
    func testShownTheDiffBoxIsExactlyWhatItWas() async throws {
        saved = ChangesFixture.prepare(features: "git.changes,worktree,agent.mute,peek")
        let app = ChangesFixture.launch()
        defer { ChangesFixture.quit(app) }
        try await ChangesFixture.wait("a pane") { app.store.focusedPane != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        let pane = try XCTUnwrap(app.store.focusedPane?.id)
        let key = PaneKey(machine: AppDelegate.localKey, pane: pane)
        ChangesFixture.fill(fake, pane)
        try await ChangesFixture.wait("the strip") { app.paneHosts[key]?.gitStrip != nil }
        app.showInspector(.changes, takeKeyboard: false)
        try await ChangesFixture.wait("the list") { !app.changesModel.files.isEmpty }
        app.window.contentView?.layoutSubtreeIfNeeded()
        let changes = try XCTUnwrap(app.fileSidebar?.changesView)
        let box = try XCTUnwrap(changes.diffContent.superview)
        assertInsetsHold(changes, "before a file is selected")

        app.changesModel.select(ChangesFixture.daemon, group: .uncommitted)
        try await ChangesFixture.wait("the diff") { if case .loaded = app.changesModel.diff { true } else { false } }
        app.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(box.isHidden)
        XCTAssertEqual(changes.diffContent.frame, box.bounds, "shown, the content is exactly its box")
        assertInsetsHold(changes, "shown")

        app.changesModel.select(nil, group: .uncommitted)
        app.window.contentView?.layoutSubtreeIfNeeded()
        assertInsetsHold(changes, "collapsed again")

        // The pane's git strip has its place from the start, and the host's layout keeps it there.
        let host = try XCTUnwrap(app.paneHosts[key])
        let strip = try XCTUnwrap(host.gitStrip)
        XCTAssertEqual(strip.frame, PaneHostView.gitStripFrame(in: host.bounds))
    }

    /// A git strip is made with its frame, never with none.
    func testAGitStripIsMadeWithAFrame() {
        XCTAssertEqual(PaneHostView.gitStripFrame(in: NSRect(x: 0, y: 0, width: 600, height: 400)),
                       NSRect(x: 0, y: 400 - GitStrip.height, width: 600, height: GitStrip.height))
        let unsized = PaneHostView.gitStripFrame(in: .zero)
        XCTAssertGreaterThan(unsized.width, 0, "room for its insets before the pane has a size")
        XCTAssertEqual(unsized.height, GitStrip.height)
    }
}
