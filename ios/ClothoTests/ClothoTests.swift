import ClothoKit
@testable import Clotho
import XCTest

final class ClothoTests: XCTestCase {
    func testFingerprintMatchesSSHKeygen() {
        // `ssh-keygen -lf` on this key prints SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test"
        XCTAssertEqual(HostKeys.fingerprint(key), "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
    }

    func testMachineRoundTrips() throws {
        let machine = Machine(name: "devbox", host: "devbox", user: "ahmad", devDirs: true)
        let data = try JSONEncoder.iso.encode([machine])
        let decoded = try JSONDecoder.iso.decode([Machine].self, from: data)
        XCTAssertEqual(decoded.first?.endpoint, machine.endpoint)
        XCTAssertEqual(decoded.first?.devDirs, true)
    }

    /// Reply only on a hook-reported waiting agent that still wants attention.
    func testReplyOnlyForHookWaitingWithAttention() {
        func row(_ state: AgentInfo.State, _ source: String?, _ attention: Bool?) -> AgentRow {
            AgentRow(machineID: UUID(), machineName: "m", pane: 1, tab: 1, workspace: "w", title: "t",
                     info: AgentInfo(kind: "claude", state: state, source: source, attention: attention))
        }
        XCTAssertTrue(row(.waiting, "hook", true).acceptsReply)
        XCTAssertFalse(row(.waiting, "hook", false).acceptsReply, "already answered or acked")
        XCTAssertFalse(row(.waiting, "detected", true).acceptsReply, "detected agent (bell)")
        XCTAssertFalse(row(.waiting, "detected", nil).acceptsReply, "quiet output read as waiting")
        XCTAssertFalse(row(.running, "hook", true).acceptsReply)
        XCTAssertFalse(row(.done, "hook", true).acceptsReply)
    }

    /// Pane copies (OSC 52) reach the pasteboard only for the clipboard target, from a visible pane, with text.
    func testPaneClipboardRules() {
        var written: [String] = []
        let pasteboard: PaneClipboard.Target = { written.append($0) }
        XCTAssertTrue(PaneClipboard.copy("hi", selection: false, visible: true, to: pasteboard))
        XCTAssertFalse(PaneClipboard.copy("bg", selection: false, visible: false, to: pasteboard), "pane not on screen")
        XCTAssertFalse(PaneClipboard.copy("x11", selection: true, visible: true, to: pasteboard), "no primary selection on iOS")
        XCTAssertFalse(PaneClipboard.copy("", selection: false, visible: true, to: pasteboard), "empty copy")
        XCTAssertEqual(written, ["hi"])
    }

    /// Hardware keys sent as the Mac app sends them, only in legacy keyboard mode.
    func testEditingKeys() {
        func keys(_ code: UIKeyboardHIDUsage, _ mods: UIKeyModifierFlags, kitty: Bool = false) -> [UInt8]? {
            EditingKeys.bytes(keyCode: code, modifiers: mods, kitty: kitty)
        }
        XCTAssertEqual(keys(.keyboardReturnOrEnter, .shift), [0x1b, 0x0d])
        XCTAssertEqual(keys(.keypadEnter, [.shift, .numericPad]), [0x1b, 0x0d], "keypad Enter carries numericPad")
        XCTAssertEqual(keys(.keyboardLeftArrow, .command), [0x01])
        XCTAssertEqual(keys(.keyboardRightArrow, .command), [0x05])
        XCTAssertEqual(keys(.keyboardDeleteOrBackspace, .command), [0x15])
        XCTAssertNil(keys(.keyboardReturnOrEnter, []), "plain Return submits")
        XCTAssertNil(keys(.keyboardReturnOrEnter, [.shift, .command]))
        XCTAssertNil(keys(.keyboardLeftArrow, [.command, .shift]), "⌘⇧← is left to SwiftTerm")
        XCTAssertNil(keys(.keyboardReturnOrEnter, .shift, kitty: true), "kitty mode: SwiftTerm sends CSI 13;2u")
        XCTAssertNil(keys(.keyboardLeftArrow, .command, kitty: true))
        XCTAssertEqual(EditingKeys.newline(kitty: false), [0x1b, 0x0d])
        XCTAssertEqual(EditingKeys.newline(kitty: true), Array("\u{1b}[13;2u".utf8))
    }

    func testImagePasteNamesFoldersAndExpiry() {
        XCTAssertTrue(ImagePaste.shouldPasteImage(hasText: false, hasImage: true))
        XCTAssertFalse(ImagePaste.shouldPasteImage(hasText: true, hasImage: true), "text wins")
        XCTAssertFalse(ImagePaste.shouldPasteImage(hasText: false, hasImage: false))
        let date = Date(timeIntervalSince1970: 1_793_115_662) // 2026-10-27 15:41:02 UTC
        XCTAssertEqual(ImagePaste.imageName(date, id: "a1b2c3"), "20261027-154102-a1b2c3.png")
        XCTAssertEqual(ImagePaste.newID().count, 6)
        XCTAssertEqual(ImagePaste.remoteFolder(home: "/home/me"), "/home/me/.cache/clotho/paste")
        XCTAssertEqual(ImagePaste.remoteFolder(home: "/Users/me/"), "/Users/me/.cache/clotho/paste")
        XCTAssertEqual(ImagePaste.typed("/Users/a b/(x).png"), "/Users/a\\ b/\\(x\\).png")
        let now = Date()
        func entry(_ name: String, age: TimeInterval) -> FileEntry {
            FileEntry(name: name, path: "/p/" + name, type: .file, size: 1, mtime: now.timeIntervalSince1970 - age,
                      mtimeNs: "0", mode: 0o644, hidden: false)
        }
        XCTAssertEqual(ImagePaste.expired([entry("old", age: 8 * 86400), entry("new", age: 86400)], now: now), ["/p/old"])
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).jpegData(withCompressionQuality: 1) { _ in }
        XCTAssertEqual(ImagePaste.png(pixel)?.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]), "JPEG becomes PNG")
    }

    /// The Agents list: only agents with the daemon's attention on top, everything else folded under Quiet.
    func testAgentsSplitByAttention() {
        func row(_ pane: PaneID, _ state: AgentInfo.State, _ attention: Bool?) -> AgentRow {
            AgentRow(machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, machineName: "m", pane: pane, tab: 1,
                     workspace: "w", title: "t", info: AgentInfo(kind: "claude", state: state, source: "hook", attention: attention))
        }
        let parts = AgentRow.split([row(1, .running, nil), row(2, .done, true), row(3, .waiting, false),
                                    row(4, .waiting, true), row(5, .error, true), row(6, .done, false)])
        XCTAssertEqual(parts.attention.map(\.pane), [4, 5, 2], "waiting, then errors, then finished")
        XCTAssertEqual(parts.quiet.map(\.pane), [3, 1, 6], "running, idle and resolved agents")
    }
}
