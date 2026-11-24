import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The find bar stays inside its pane: in a narrow one the count truncates first, then the field shrinks to
/// its minimum, and every button stays whole.
@MainActor
final class FindBarTests: XCTestCase {
    private var window: NSWindow!
    private var backend: FakeBackend!
    private var store: ModelStore!

    override func setUp() async throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        backend = FakeBackend()
        store = ModelStore(backend: backend)
        try await store.start()
    }

    override func tearDown() async throws {
        store.stop()
        window.close()
    }

    /// A pane with its find bar up, a query typed and a count showing.
    private func hostWithFind() async throws -> (PaneHostView, PaneFindBar) {
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        let deadline = Date().addingTimeInterval(5)
        while store.state.pane(created.pane) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let host = PaneHostView(pane: try XCTUnwrap(store.state.pane(created.pane)), store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView!.addSubview(host)
        host.showFind()
        let bar = try XCTUnwrap(host.search?.bar)
        bar.field.stringValue = "error"
        bar.setStatus("12 of 340", error: false)
        host.layoutSubtreeIfNeeded()
        return (host, bar)
    }

    private func resize(_ host: PaneHostView, to width: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in
            if let button = sub as? NSButton, !(sub.superview is NSSearchField) { return [button] }
            return sub is NSSearchField ? [] : buttons(in: sub)
        }
    }

    private func status(in bar: PaneFindBar) -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            for sub in view.subviews {
                if sub is NSSearchField || sub is NSButton { continue }
                if let label = sub as? NSTextField { return label }
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(bar)
    }

    /// The narrowest pane the whole bar fits in: its narrowest self, the padding on the left, and the room
    /// kept clear of the pane's × on the right.
    private func minimumPaneWidth(_ host: PaneHostView, _ bar: PaneFindBar) -> CGFloat {
        resize(host, to: 100)
        return (bar.frame.width + PaneHostView.padding + PaneFindBar.trailingInset).rounded(.up)
    }

    private func assertInside(_ host: PaneHostView, _ bar: PaneFindBar, width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        resize(host, to: width)
        let what = "at \(Int(width)) pt"
        XCTAssertGreaterThanOrEqual(bar.frame.minX, PaneHostView.padding - 0.5, "inside the pane's left padding \(what)", file: file, line: line)
        XCTAssertEqual(bar.frame.maxX, width - PaneFindBar.trailingInset, accuracy: 0.5, "clear of the × \(what)", file: file, line: line)
        let all = buttons(in: bar)
        XCTAssertEqual(all.count, 5, "Aa, .*, older, newer, close", file: file, line: line)
        for button in all {
            let frame = button.convert(button.bounds, to: bar)
            XCTAssertTrue(bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(button.toolTip ?? "?") inside the bar \(what): \(frame)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.width, button.intrinsicContentSize.width - 0.5, "\(button.toolTip ?? "?") whole \(what)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.width, 20, "\(button.toolTip ?? "?") whole \(what)", file: file, line: line)
        }
        // No two controls overlap.
        let frames = ([bar.field] + all).map { $0.convert($0.bounds, to: bar) }.sorted { $0.minX < $1.minX }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "controls side by side \(what)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(bar.field.frame.width, PaneFindBar.fieldMinWidth - 0.5, "the field's minimum \(what)", file: file, line: line)
        XCTAssertLessThanOrEqual(bar.field.frame.width, PaneFindBar.fieldWidth + 0.5, file: file, line: line)
    }

    func testTheBarStaysInsideThePaneAtEveryWidth() async throws {
        let (host, bar) = try await hostWithFind()
        let label = try XCTUnwrap(status(in: bar))
        let minimum = minimumPaneWidth(host, bar)
        // The app has no minimum pane width of its own (a split's share goes down to 5%), so the bar's own
        // minimum is the one that counts: it has to be small.
        XCTAssertLessThanOrEqual(minimum, 300, "the bar fits a pane this narrow")

        assertInside(host, bar, width: 600)
        XCTAssertEqual(bar.field.frame.width, PaneFindBar.fieldWidth, accuracy: 0.5, "the whole field while there is room")
        XCTAssertGreaterThanOrEqual(label.frame.width, PaneFindBar.statusWidth - 0.5, "and the count's room")
        let natural = bar.frame.width

        // 426 pt was where the bar's left edge used to meet the pane's.
        assertInside(host, bar, width: 430)
        XCTAssertEqual(bar.field.frame.width, PaneFindBar.fieldWidth, accuracy: 0.5)

        assertInside(host, bar, width: 400)
        XCTAssertLessThan(bar.frame.width, natural, "narrower than it would like to be")
        XCTAssertEqual(bar.field.frame.width, PaneFindBar.fieldWidth, accuracy: 0.5, "the count gives way before the field does")
        XCTAssertLessThan(label.frame.width, PaneFindBar.statusWidth)

        assertInside(host, bar, width: 320)
        XCTAssertLessThan(bar.field.frame.width, PaneFindBar.fieldWidth, "then the field shrinks")
        XCTAssertLessThanOrEqual(label.frame.width, 4.5, "with the count gone (a label keeps its 2 pt insets)")

        assertInside(host, bar, width: minimum)
        XCTAssertEqual(bar.field.frame.width, PaneFindBar.fieldMinWidth, accuracy: 1, "the field at its minimum")

        // Narrower than the buttons themselves: they stay whole and at the right, and the pane clips the field.
        resize(host, to: minimum - 60)
        XCTAssertEqual(bar.frame.maxX, host.bounds.width - PaneFindBar.trailingInset, accuracy: 0.5)
        XCTAssertEqual(bar.field.frame.width, PaneFindBar.fieldMinWidth, accuracy: 1)
        for button in buttons(in: bar) {
            XCTAssertTrue(host.bounds.contains(button.convert(button.bounds, to: host)), "\(button.toolTip ?? "?") still in the pane")
        }

        // And back.
        assertInside(host, bar, width: 600)
        XCTAssertEqual(bar.frame.width, natural, accuracy: 0.5)
    }

    /// Review images of the find bar in a narrow pane, light and dark. Runs only with CLOTHO_SNAPSHOT_DIR set.
    func testSnapshotsForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        let saved = NSApp.appearance
        defer {
            NSApp.appearance = saved
            Theme.followAppAppearance()
        }
        let (host, bar) = try await hostWithFind()
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            Theme.followAppAppearance()
            window.appearance = NSApp.appearance
            host.viewDidChangeEffectiveAppearance()
            bar.viewDidChangeEffectiveAppearance()
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no image") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/findbar-narrow-\(name).png"))
        }
    }
}
