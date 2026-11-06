import AppKit
import ClothoKit
import XCTest
@testable import Clotho

final class ImagePasteDecisionTests: XCTestCase {
    private func action(_ key: ImagePaste.Key, remote: Bool, text: Bool, image: Bool, agent: Bool) -> ImagePaste.Action {
        ImagePaste.action(.init(key: key, remote: remote, hasText: text, hasImage: image, agent: agent))
    }

    func testCommandVPastesAnImageAsAFileWhereverThePaneIs() {
        for remote in [true, false] {
            for agent in [true, false] {
                XCTAssertEqual(action(.command, remote: remote, text: false, image: true, agent: agent), .imageFile)
            }
        }
    }

    func testCommandVPastesTextWhenThereIsAny() {
        for remote in [true, false] {
            XCTAssertEqual(action(.command, remote: remote, text: true, image: true, agent: true), .terminal, "text wins")
            XCTAssertEqual(action(.command, remote: remote, text: true, image: false, agent: false), .terminal)
            XCTAssertEqual(action(.command, remote: remote, text: false, image: false, agent: true), .terminal)
        }
    }

    func testControlVOnlyForARemoteAgentWithAnImage() {
        XCTAssertEqual(action(.control, remote: true, text: false, image: true, agent: true), .imageFile)
        XCTAssertEqual(action(.control, remote: true, text: true, image: true, agent: true), .imageFile)
        // Otherwise ^V goes to the pane: vim, shells, a local agent reading the Mac's clipboard itself.
        XCTAssertEqual(action(.control, remote: true, text: false, image: true, agent: false), .terminal)
        XCTAssertEqual(action(.control, remote: true, text: true, image: false, agent: true), .terminal)
        XCTAssertEqual(action(.control, remote: false, text: false, image: true, agent: true), .terminal)
        XCTAssertEqual(action(.control, remote: false, text: false, image: true, agent: false), .terminal)
    }

    func testNames() {
        let date = Date(timeIntervalSince1970: 1_793_200_000) // 2026-10-28 15:06:40 UTC
        XCTAssertEqual(ImagePaste.imageName(date, id: "a1b2c3"), "20261028-150640-a1b2c3.png")
        XCTAssertEqual(ImagePaste.remoteFolder(home: "/home/user"), "/home/user/.cache/clotho/paste")
        XCTAssertEqual(ImagePaste.remoteFolder(home: "/"), "/.cache/clotho/paste")
        let id = ImagePaste.newID()
        XCTAssertEqual(id.count, 6)
        XCTAssertNotEqual(id, ImagePaste.newID())
        XCTAssertTrue(ImagePaste.localFolder.hasSuffix("/paste"))
    }

    func testTypedPathsEscapeLikeTerminalDrops() {
        XCTAssertEqual(ImagePaste.typed("/home/a/.cache/clotho/paste/x.png"), "/home/a/.cache/clotho/paste/x.png")
        XCTAssertEqual(ImagePaste.typed("/tmp/My Shot (1).png"), "/tmp/My\\ Shot\\ \\(1\\).png")
        XCTAssertEqual(ImagePaste.typed("/tmp/it's"), "/tmp/it\\'s")
    }

    func testExpiredAfterAWeek() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func entry(_ name: String, age: TimeInterval) throws -> FileEntry {
            let json = """
            {"name":"\(name)","path":"/p/\(name)","type":"file","link":false,"size":1,"mtime":\(now.timeIntervalSince1970 - age),
             "mtime_ns":"0","mode":420,"hidden":false}
            """
            return try JSONDecoder().decode(FileEntry.self, from: Data(json.utf8))
        }
        let entries = [try entry("new.png", age: 3600), try entry("old.png", age: 8 * 86400), try entry("edge.png", age: 6.9 * 86400)]
        XCTAssertEqual(ImagePaste.expired(entries, now: now), ["/p/old.png"])
    }
}

/// The clipboard checks, on a private pasteboard (never the user's).
final class ImagePasteClipboardTests: XCTestCase {
    func testReadsImagesAndText() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("clotho-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertFalse(ImagePaste.hasImage(board))
        XCTAssertFalse(ImagePaste.hasText(board))

        // A TIFF (what many apps put there) comes out as PNG.
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.clearContents()
        board.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        XCTAssertTrue(ImagePaste.hasImage(board))
        XCTAssertFalse(ImagePaste.hasText(board))
        let png = try XCTUnwrap(ImagePaste.png(board))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        board.clearContents()
        board.setString("hello", forType: .string)
        XCTAssertTrue(ImagePaste.hasText(board))
        XCTAssertFalse(ImagePaste.hasImage(board))
    }
}
