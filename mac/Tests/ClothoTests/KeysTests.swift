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
final class ShiftReturnTests: XCTestCase {
    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode)!
    }

    private func terminal() -> (PaneTerminalView, Recorder) {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        return (view, recorder)
    }

    func testShiftReturnSendsEscCRInLegacyMode() {
        let (view, recorder) = terminal()
        XCTAssertTrue(view.sendShiftReturn(key(36, .shift)))
        XCTAssertEqual(recorder.sent, [0x1b, 0x0d])
        // Keypad Enter carries the numeric pad flag too.
        recorder.sent = []
        XCTAssertTrue(view.sendShiftReturn(key(76, [.shift, .numericPad])))
        XCTAssertEqual(recorder.sent, [0x1b, 0x0d])
        // Caps Lock doesn't count as a modifier.
        recorder.sent = []
        XCTAssertTrue(view.sendShiftReturn(key(36, [.shift, .capsLock])))
        XCTAssertEqual(recorder.sent, [0x1b, 0x0d])
    }

    func testOtherReturnsAreLeftToTheTerminal() {
        let (view, recorder) = terminal()
        XCTAssertFalse(view.sendShiftReturn(key(36, [])), "plain Return stays CR, from SwiftTerm")
        XCTAssertFalse(view.sendShiftReturn(key(36, [.command, .shift])), "⌘⇧↩ is Maximize Pane")
        XCTAssertFalse(view.sendShiftReturn(key(36, [.control])), "⌃↩ renames the workspace")
        XCTAssertFalse(view.sendShiftReturn(key(36, [.shift, .option])))
        XCTAssertFalse(view.sendShiftReturn(key(48, .shift)), "Shift-Tab")
        XCTAssertEqual(recorder.sent, [])
    }

    /// With kitty keyboard flags on, SwiftTerm encodes the key itself, as CSI 13;2u.
    func testKittyModeIsLeftToSwiftTerm() {
        let (view, recorder) = terminal()
        view.feedFromBackend(Data("\u{1b}[>1u".utf8))
        XCTAssertEqual(view.keyboardEnhancementFlags.rawValue, 1)
        XCTAssertFalse(view.sendShiftReturn(key(36, .shift)))
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
