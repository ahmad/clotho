import ClothoKit
@testable import Clotho
import SwiftTerm
import XCTest

/// The phone's saved copy of each machine (docs/ios-redesign.md, phase 1).
@MainActor
final class SavedStateTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private let machine = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "SavedStateTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func cached(panes: [PaneID], lastSeen: Date = Date(timeIntervalSince1970: 1_761_512_345)) -> CachedMachineState {
        var state = ModelState()
        state.panes = panes.map { Pane(id: $0, cols: 80, rows: 24) }
        return CachedMachineState(state: state, lastSeen: lastSeen, daemonVersion: "0.1.13", instance: "abc",
                                  featureNames: ["push", "agent.decide"])
    }

    private func screen(_ text: String = "hello") -> SavedScreen {
        SavedScreen(cols: 80, rows: 24, ansi: text, cursorCol: 0, cursorRow: 0, saved: Date(timeIntervalSince1970: 1_761_512_345))
    }

    func testModelRoundTrips() {
        let saved = SavedState(root: root, defaults: defaults)
        let model = cached(panes: [1, 2])
        saved.save(model, for: machine)
        XCTAssertEqual(SavedState(root: root, defaults: defaults).load(machine), model, "read back by a fresh instance, as after a relaunch")
        XCTAssertEqual(SavedState(root: root, defaults: defaults).load(machine)?.features, [.push, .agentDecide])
        XCTAssertNil(saved.load(UUID()))
    }

    func testFilesAreProtectedAndNotBackedUp() throws {
        let saved = SavedState(root: root, defaults: defaults)
        saved.save(cached(panes: [1]), for: machine)
        saved.saveScreen(screen(), pane: 1, on: machine)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath }
        XCTAssertEqual(files.count, 2)
        for file in files {
            let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
            #if targetEnvironment(simulator)
            // The simulator has no Data Protection and reports none; a device must report complete.
            XCTAssertTrue(protection == nil || protection == .complete, file.lastPathComponent)
            #else
            XCTAssertEqual(protection, .complete, file.lastPathComponent)
            #endif
        }
    }

    func testScreensAndTheSwitch() {
        let saved = SavedState(root: root, defaults: defaults)
        XCTAssertTrue(saved.keepPreviews, "on by default")
        saved.saveScreen(screen("one"), pane: 1, on: machine)
        XCTAssertEqual(saved.screen(1, on: machine)?.ansi, "one")
        XCTAssertTrue(saved.hasScreen(1, on: machine))

        saved.keepPreviews = false
        XCTAssertNil(saved.screen(1, on: machine))
        saved.keepPreviews = true
        XCTAssertNil(saved.screen(1, on: machine), "turning it off deleted the screens")

        saved.keepPreviews = false
        saved.saveScreen(screen("two"), pane: 2, on: machine)
        saved.keepPreviews = true
        XCTAssertNil(saved.screen(2, on: machine), "nothing is saved while off")
    }

    func testGonePanesLoseTheirScreens() {
        let saved = SavedState(root: root, defaults: defaults)
        saved.saveScreen(screen(), pane: 1, on: machine)
        saved.saveScreen(screen(), pane: 2, on: machine)
        saved.save(cached(panes: [2]), for: machine)
        XCTAssertNil(saved.screen(1, on: machine))
        XCTAssertNotNil(saved.screen(2, on: machine))
    }

    func testScreensAreCappedPerMachine() {
        let saved = SavedState(root: root, defaults: defaults)
        for pane in 1...(SavedState.maxScreens + 5) { saved.saveScreen(screen(), pane: PaneID(pane), on: machine) }
        let dir = root.appendingPathComponent("screens/\(machine.uuidString)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, SavedState.maxScreens)
    }

    func testDeletingAMachineRemovesItsCopy() {
        let saved = SavedState(root: root, defaults: defaults)
        let other = UUID()
        saved.save(cached(panes: [1]), for: machine)
        saved.saveScreen(screen(), pane: 1, on: machine)
        saved.save(cached(panes: [1]), for: other)
        saved.delete(machine)
        XCTAssertNil(SavedState(root: root, defaults: defaults).load(machine))
        XCTAssertNil(saved.screen(1, on: machine))
        XCTAssertNotNil(SavedState(root: root, defaults: defaults).load(other))
    }

    func testLastSeenText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MachineConnection.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(MachineConnection.ago(now.addingTimeInterval(-180), now: now), "3m ago")
        XCTAssertEqual(MachineConnection.ago(now.addingTimeInterval(-7300), now: now), "2h ago")
        XCTAssertEqual(MachineConnection.ago(now.addingTimeInterval(-3 * 86400), now: now), "3d ago")
    }
}

/// The screen capture (SwiftTerm cells → escape sequences → another terminal) keeps text, colours and the cursor.
final class ScreenCaptureTests: XCTestCase {
    private final class Quiet: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func terminal(cols: Int = 40, rows: Int = 6, _ delegate: Quiet) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows))
    }

    private func feed(_ t: Terminal, _ text: String) { t.feed(byteArray: Array(text.utf8)) }

    private func text(_ t: Terminal, row: Int) -> String {
        // The second half of a wide character (width 0) isn't a character of its own.
        (0..<t.cols).compactMap { t.getCharData(col: $0, row: row) }.filter { $0.width > 0 }.map { String(t.getCharacter(for: $0)) }
            .joined().replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces)
    }

    func testRoundTripKeepsTextColoursAndCursor() {
        let d = Quiet()
        let source = terminal(d)
        feed(source, "plain line\r\n\u{1b}[1;31mbold red\u{1b}[0m and \u{1b}[38;5;208morange\u{1b}[0m\r\n")
        feed(source, "\u{1b}[48;2;10;20;30mtrue bg\u{1b}[0m 世界\r\n$ ")
        let screen = ScreenCapture.capture(source)
        XCTAssertEqual(screen.cols, 40)
        XCTAssertEqual(screen.rows, 6)
        XCTAssertEqual(screen.cursorRow, 3)
        XCTAssertEqual(screen.cursorCol, 2)

        let target = terminal(d)
        feed(target, "old content that must go\r\n")
        target.feed(byteArray: Array(ScreenCapture.replay(screen)))
        for row in 0..<4 { XCTAssertEqual(text(target, row: row), text(source, row: row), "row \(row)") }
        XCTAssertEqual(text(target, row: 1), "bold red and orange")
        XCTAssertEqual(text(target, row: 2), "true bg 世界")
        for (col, row) in [(0, 1), (13, 1), (0, 2)] {
            XCTAssertEqual(target.getCharData(col: col, row: row)?.attribute, source.getCharData(col: col, row: row)?.attribute,
                           "attribute at \(col),\(row)")
        }
        XCTAssertEqual(target.getCursorLocation().x, 2)
        XCTAssertEqual(target.getCursorLocation().y, 3)
    }

    /// A `pane.text` preview: plain lines, with anything that could act as an escape sequence dropped.
    func testPlainPreviewCannotInjectEscapes() {
        let paneText = PaneText(lines: ["$ ls", "evil \u{1b}]52;c;cGF3bmVk\u{07}\u{1b}[2Jstill here", "\u{9b}31mcsi"], cursorCol: 2, cursorRow: 2,
                            cols: 40, rows: 3, seq: 9)
        let screen = ScreenCapture.plain(paneText)
        XCTAssertFalse(screen.ansi.dropFirst(4).contains("\u{1b}"), "only the leading reset is an escape")
        XCTAssertFalse(screen.ansi.contains("\u{9b}"))
        let d = Quiet()
        let target = terminal(rows: 3, d)
        target.feed(byteArray: Array(ScreenCapture.replay(screen)))
        XCTAssertEqual(text(target, row: 0), "$ ls")
        XCTAssertEqual(text(target, row: 1), "evil ]52;c;cGF3bmVk[2Jstill here")
        XCTAssertEqual(text(target, row: 2), "31mcsi")
    }

    func testCaptureIsTheBottomScreenAfterScrolling() {
        let d = Quiet()
        let source = terminal(rows: 3, d)
        for i in 1...10 { feed(source, "line \(i)\r\n") }
        feed(source, "$ ")
        let target = terminal(rows: 3, d)
        target.feed(byteArray: Array(ScreenCapture.replay(ScreenCapture.capture(source))))
        XCTAssertEqual(text(target, row: 0), "line 9")
        XCTAssertEqual(text(target, row: 1), "line 10")
        XCTAssertEqual(text(target, row: 2), "$")
    }
}
