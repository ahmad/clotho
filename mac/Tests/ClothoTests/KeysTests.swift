import AppKit
import SwiftTerm
import XCTest
@testable import Clotho

/// Collects what a terminal view sends to the pane.
private final class Recorder: NSObject, TerminalViewDelegate {
    var sent: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class EditingKeyTests: XCTestCase {
    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let characters = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 51: 0x7f, 48: 0x09][Int(keyCode)]
            .flatMap { UnicodeScalar($0).map(String.init) } ?? "\r"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: keyCode)!
    }

    override func setUp() {
        // SwiftTerm offers ⌘ keys to the main menu first.
        _ = NSApplication.shared
    }

    private func terminal() -> (PaneTerminalView, Recorder) {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        return (view, recorder)
    }

    func testShiftReturnSendsEscCRInLegacyMode() {
        let (view, recorder) = terminal()
        XCTAssertTrue(view.sendEditingKey(key(36, .shift)))
        XCTAssertEqual(recorder.sent, [0x1b, 0x0d])
        // Keypad Enter carries the numeric pad flag too.
        recorder.sent = []
        XCTAssertTrue(view.sendEditingKey(key(76, [.shift, .numericPad])))
        XCTAssertEqual(recorder.sent, [0x1b, 0x0d])
        // Caps Lock doesn't count as a modifier.
        recorder.sent = []
        XCTAssertTrue(view.sendEditingKey(key(36, [.shift, .capsLock])))
        XCTAssertEqual(recorder.sent, [0x1b, 0x0d])
    }

    func testCommandArrowsAndDeleteEditTheLine() {
        let (view, recorder) = terminal()
        // Arrow keys carry the function and numeric pad flags.
        for (code, bytes) in [(UInt16(123), [UInt8(0x01)]), (124, [0x05]), (51, [0x15])] {
            recorder.sent = []
            XCTAssertTrue(view.sendEditingKey(key(code, [.command, .function, .numericPad])), "key \(code)")
            XCTAssertEqual(recorder.sent, bytes, "key \(code)")
        }
        // Option-arrows are SwiftTerm's (ESC b / ESC f), and ⌘⌥/⌘⇧/⌃⌘ arrows are menu shortcuts.
        for modifiers: NSEvent.ModifierFlags in [[.option], [.command, .option], [.command, .shift], [.command, .control], [.shift]] {
            XCTAssertFalse(view.sendEditingKey(key(123, modifiers)))
        }
    }

    /// The gap this fills: SwiftTerm sends nothing for ⌘← in legacy mode.
    func testSwiftTermAloneSendsNothingForCommandLeft() {
        let (view, recorder) = terminal()
        view.keyDown(with: key(123, [.command, .function, .numericPad]))
        XCTAssertEqual(recorder.sent, [])
    }

    func testOtherReturnsAreLeftToTheTerminal() {
        let (view, recorder) = terminal()
        XCTAssertFalse(view.sendEditingKey(key(36, [])), "plain Return stays CR, from SwiftTerm")
        XCTAssertFalse(view.sendEditingKey(key(36, [.command, .shift])), "⌘⇧↩ is Maximize Pane")
        XCTAssertFalse(view.sendEditingKey(key(36, [.control])), "⌃↩ renames the workspace")
        XCTAssertFalse(view.sendEditingKey(key(36, [.shift, .option])))
        XCTAssertFalse(view.sendEditingKey(key(48, .shift)), "Shift-Tab")
        XCTAssertEqual(recorder.sent, [])
    }

    /// With kitty keyboard flags on, SwiftTerm encodes the key itself, as CSI 13;2u.
    func testKittyModeIsLeftToSwiftTerm() {
        let (view, recorder) = terminal()
        view.feedFromBackend(Data("\u{1b}[>1u".utf8))
        XCTAssertEqual(view.keyboardEnhancementFlags.rawValue, 1)
        XCTAssertFalse(view.sendEditingKey(key(36, .shift)))
        view.keyDown(with: key(36, .shift))
        XCTAssertEqual(String(decoding: recorder.sent, as: UTF8.self), "\u{1b}[13;2u")
    }

    /// The bug this works around: on its own, SwiftTerm sends Shift-Return as a bare CR in legacy mode.
    func testSwiftTermAloneSendsCRForShiftReturn() {
        let (view, recorder) = terminal()
        view.keyDown(with: key(36, .shift))
        XCTAssertEqual(recorder.sent, [0x0d])
    }

    func testPlainReturnFromSwiftTermIsCR() {
        let (view, recorder) = terminal()
        view.keyDown(with: key(36, []))
        XCTAssertEqual(recorder.sent, [0x0d])
    }
}

final class HeldTitlesTests: XCTestCase {
    func testHeldUntilTheModelChanges() {
        var held = HeldTitles<Int>()
        XCTAssertNil(held.title(for: 1, model: "old"))
        held.hold(1, from: "old", to: "new")
        XCTAssertEqual(held.title(for: 1, model: "old"), "new", "the model hasn't caught up")
        XCTAssertNil(held.title(for: 1, model: "new"), "the model has it")
        XCTAssertNil(held.title(for: 1, model: "old"), "let go once the model moved")
    }

    func testRenamingAgainKeepsTheModelsTitle() {
        var held = HeldTitles<Int>()
        held.hold(1, from: nil, to: "a")
        held.hold(1, from: "a", to: "b")
        XCTAssertEqual(held.title(for: 1, model: nil), "b")
    }
}

/// Copy and paste go through the Edit menu's copy: and paste: to SwiftTerm, which uses the general
/// pasteboard. These save and restore whatever was on it.
@MainActor
final class ClipboardTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        _ = NSApplication.shared
        saved = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    func testPasteSendsTheClipboard() {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo pasted", forType: .string)
        view.paste(view)
        // SwiftTerm hands pasted bytes to the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(String(decoding: recorder.sent, as: UTF8.self), "echo pasted")
        // Bracketed paste when the app asked for it.
        recorder.sent = []
        view.feedFromBackend(Data("\u{1b}[?2004h".utf8))
        view.paste(view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(String(decoding: recorder.sent, as: UTF8.self), "\u{1b}[200~echo pasted\u{1b}[201~")
    }

    func testCopyPutsTheSelectionOnTheClipboard() {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feedFromBackend(Data("hello clotho".utf8))
        view.selectAll(nil)
        XCTAssertTrue(view.validateUserInterfaceItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")))
        view.copy(view)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello clotho")
    }
}

/// With mouse reporting on, plain drags go to the app; Option and Shift drags select text here.
@MainActor
final class MouseSelectionTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func drag(_ view: PaneTerminalView, _ modifiers: NSEvent.ModifierFlags) {
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 150), modifierFlags: modifiers, timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 10))
        view.mouseDragged(with: event(.leftMouseDragged, 120))
        view.mouseDragged(with: event(.leftMouseDragged, 250))
        view.mouseUp(with: event(.leftMouseUp, 250))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func setUpView() -> (PaneTerminalView, Recorder) {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        view.feedFromBackend(Data("some text the agent printed\r\n\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        return (view, recorder)
    }

    private func hasSelection(_ view: PaneTerminalView) -> Bool {
        view.validateUserInterfaceItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    }

    func testPlainDragGoesToTheApp() {
        let (view, recorder) = setUpView()
        drag(view, [])
        XCTAssertTrue(String(decoding: recorder.sent, as: UTF8.self).hasPrefix("\u{1b}[<0;"), "an SGR mouse report")
        XCTAssertFalse(hasSelection(view))
    }

    func testOptionDragSelects() {
        let (view, recorder) = setUpView()
        drag(view, .option)
        XCTAssertEqual(recorder.sent, [], "nothing reported to the app")
        XCTAssertTrue(hasSelection(view))
        XCTAssertTrue(view.allowMouseReporting, "reporting comes back after the press")
        // And the next plain drag goes to the app again.
        drag(view, [])
        XCTAssertFalse(recorder.sent.isEmpty)
    }

    func testShiftDragSelects() {
        let (view, recorder) = setUpView()
        drag(view, .shift)
        XCTAssertEqual(recorder.sent, [])
        XCTAssertTrue(hasSelection(view))
    }
}

/// Right-click and Ctrl-click open the pane menu even while the app takes the mouse; nothing of
/// that click reaches the app. Option-right-click still goes to the app.
@MainActor
final class PaneMenuClickTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func click(_ view: PaneTerminalView, _ down: NSEvent.EventType, _ up: NSEvent.EventType,
                       _ modifiers: NSEvent.ModifierFlags = []) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 150), modifierFlags: modifiers, timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        switch down {
        case .rightMouseDown: view.rightMouseDown(with: event(down))
        default: view.mouseDown(with: event(down))
        }
        switch up {
        case .rightMouseUp: view.rightMouseUp(with: event(up))
        default: view.mouseUp(with: event(up))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    /// A pane whose app turned on mouse reporting (or not), and a count of menu requests.
    private func setUpView(reporting: Bool = true) -> (PaneTerminalView, Recorder, () -> Int) {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        var menus = 0
        view.contextMenu = { menus += 1; return nil }
        if reporting { view.feedFromBackend(Data("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8)) }
        return (view, recorder, { menus })
    }

    private func sent(_ recorder: Recorder) -> String { String(decoding: recorder.sent, as: UTF8.self) }

    func testRightClickOpensTheMenuAndSendsNothing() {
        let (view, recorder, menus) = setUpView()
        click(view, .rightMouseDown, .rightMouseUp)
        XCTAssertEqual(menus(), 1)
        XCTAssertEqual(recorder.sent, [])
    }

    func testControlClickOpensTheMenuAndSendsNothing() {
        let (view, recorder, menus) = setUpView()
        click(view, .leftMouseDown, .leftMouseUp, .control)
        XCTAssertEqual(menus(), 1)
        XCTAssertEqual(recorder.sent, [])
        // The next plain click is reported whole, press and release.
        click(view, .leftMouseDown, .leftMouseUp)
        XCTAssertTrue(sent(recorder).hasPrefix("\u{1b}[<0;"), sent(recorder))
        XCTAssertTrue(sent(recorder).hasSuffix("m"), "the release is reported too: \(sent(recorder))")
        XCTAssertEqual(menus(), 1)
    }

    /// The menu's tracking can eat the release; a later click must still be reported whole.
    func testAMenuClickWithoutItsReleaseDoesntEatTheNextOne() {
        let (view, recorder, _) = setUpView()
        view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 150), modifierFlags: .control,
                                                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        click(view, .leftMouseDown, .leftMouseUp)
        XCTAssertTrue(sent(recorder).hasPrefix("\u{1b}[<0;") && sent(recorder).hasSuffix("m"), sent(recorder))
    }

    func testLeftClickIsStillReported() {
        let (view, recorder, menus) = setUpView()
        click(view, .leftMouseDown, .leftMouseUp)
        XCTAssertTrue(sent(recorder).hasPrefix("\u{1b}[<0;"), sent(recorder))
        XCTAssertEqual(menus(), 0)
    }

    func testOptionRightClickGoesToTheApp() {
        let (view, recorder, menus) = setUpView()
        click(view, .rightMouseDown, .rightMouseUp, .option)
        XCTAssertEqual(menus(), 0)
        // Reported with Alt (+8), press and release. A real right-click is button 2 (<10); a synthetic
        // event has no button number, so SwiftTerm reports button 0 (<8).
        XCTAssertNotNil(sent(recorder).range(of: #"^\x1b\[<(8|10);\d+;\d+M\x1b\[<(8|10);\d+;\d+m$"#, options: .regularExpression),
                        sent(recorder))
    }

    func testRightClickWithoutReportingOpensTheMenu() {
        let (view, recorder, menus) = setUpView(reporting: false)
        click(view, .rightMouseDown, .rightMouseUp)
        XCTAssertEqual(menus(), 1)
        XCTAssertEqual(recorder.sent, [])
    }
}
