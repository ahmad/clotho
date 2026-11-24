import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Clotho

/// Which files "Open in Editor" shows in Finder instead of opening: the ones their default app would run.
final class OpenSafetyTests: XCTestCase {
    func testAFileItsDefaultAppWouldRunIsNotOpened() {
        // By kind, whatever the exec bit and whoever opens it.
        for name in ["x.command", "Deploy.COMMAND", "build/Thing.app", "setup.terminal", "clean.workflow", "run.tool", "install.pkg",
                     "lib.jar", "link.fileloc", "site.webloc", "site.inetloc"] {
            XCTAssertTrue(OpenSafety.runsWhenOpened(name: name, isExecutable: false, defaultApp: "com.apple.TextEdit"), name)
            XCTAssertTrue(OpenSafety.runsWhenOpened(name: name, isExecutable: true, defaultApp: nil), name)
        }
        // The exec bit and no editor: nothing opens it, or a terminal or a launcher does.
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "deploy", isExecutable: true, defaultApp: nil))
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "deploy", isExecutable: true, defaultApp: "com.apple.Terminal"))
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "run.sh", isExecutable: true, defaultApp: "com.googlecode.iterm2"))
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "run.py", isExecutable: true, defaultApp: "org.python.PythonLauncher"))
        // A terminal as the default app runs a script without the exec bit too (it asks a shell to).
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "run.sh", isExecutable: false, defaultApp: "com.apple.Terminal"))
    }

    func testAFileAnEditorOpensIsOpened() {
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "daemon.rs", isExecutable: false, defaultApp: "com.apple.dt.Xcode"))
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "daemon.rs", isExecutable: false, defaultApp: nil))
        // A script with the exec bit, when an editor is what opens it.
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "build.sh", isExecutable: true, defaultApp: "com.apple.TextEdit"))
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "README", isExecutable: false, defaultApp: "com.apple.TextEdit"))
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "notes.command.txt", isExecutable: false, defaultApp: "com.apple.TextEdit"))
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "logo.png", isExecutable: true, defaultApp: "com.apple.Preview"))
    }

    /// A file the system types as a program runs in Terminal when opened, whatever app claims it. A script
    /// with an extension has its own type, so an editor still opens it.
    func testAProgramIsNotOpenedWhateverItsDefaultApp() throws {
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "deploy", isExecutable: true, defaultApp: "com.apple.TextEdit", conformsToExecutable: true))
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "deploy", isExecutable: false, defaultApp: "com.apple.dt.Xcode", conformsToExecutable: true))
        XCTAssertTrue(OpenSafety.runsWhenOpened(name: "deploy", isExecutable: true, defaultApp: nil, conformsToExecutable: true))
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "build.sh", isExecutable: true, defaultApp: "com.apple.TextEdit", conformsToExecutable: false))
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "build.sh", isExecutable: true, defaultApp: "com.apple.TextEdit"))
        // As measured: a .sh is `public.shell-script`, which is not a `public.unix-executable`.
        let script = try XCTUnwrap(UTType(filenameExtension: "sh"))
        XCTAssertFalse(script.conforms(to: .unixExecutable), script.identifier)
    }

    /// An executable with no extension is a `public.unix-executable` on disk: the URL form reads that.
    func testAnExtensionlessExecutableOnDiskIsAProgram() throws {
        let folder = URL(fileURLWithPath: "/tmp/cmac-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func make(_ name: String, mode: Int) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        let tool = try make("deploy", mode: 0o755)
        XCTAssertEqual(try tool.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .unixExecutable), true)
        XCTAssertTrue(OpenSafety.runsWhenOpened(tool))
        // The type alone decides it here, not the absence of a default app.
        let script = try make("build.sh", mode: 0o755)
        XCTAssertEqual(try script.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .unixExecutable), false)
        XCTAssertFalse(OpenSafety.runsWhenOpened(name: "build.sh", isExecutable: true, defaultApp: "com.apple.TextEdit",
                                                 conformsToExecutable: false))
        XCTAssertFalse(OpenSafety.runsWhenOpened(try make("notes", mode: 0o644)), "no exec bit: plain data")
    }

    /// The files themselves, on this Mac: the exec bit is read from the file, through a symlink too.
    func testFilesOnDisk() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmac-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func make(_ name: String, executable: Bool) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            return url
        }
        XCTAssertTrue(OpenSafety.runsWhenOpened(try make("x.command", executable: true)))
        XCTAssertTrue(OpenSafety.runsWhenOpened(try make("plain.command", executable: false)))
        let tool = try make("deploy", executable: true)
        XCTAssertTrue(OpenSafety.runsWhenOpened(tool), "an executable with no editor")
        XCTAssertFalse(OpenSafety.runsWhenOpened(try make("notes.txt", executable: false)))
        let link = folder.appendingPathComponent("latest")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        XCTAssertTrue(OpenSafety.runsWhenOpened(link))
        XCTAssertFalse(OpenSafety.runsWhenOpened(folder), "a folder isn't an executable file")
    }

    func testMouseReportsAreTold() {
        func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(Array(text.utf8)) }
        for report in ["\u{1b}[<35;12;7M", "\u{1b}[<0;1;1m", "\u{1b}[35;12;7M", "\u{1b}[M#,("] {
            XCTAssertTrue(PaneTerminalView.isMouseReport(bytes(report)), report.debugDescription)
        }
        XCTAssertTrue(PaneTerminalView.isMouseReport([0x9b, 0x4d, 0x43, 0x2c, 0x28]), "8-bit CSI")
        // Keys, focus reports, pastes and replies are not.
        for other in ["a", "\r", "\u{1b}", "\u{1b}[A", "\u{1b}[I", "\u{1b}[O", "\u{1b}[1;5C", "\u{1b}[200~", "\u{1b}[12;40R", "\u{1b}[?1;2c",
                      "\u{1b}[<35;12M", "\u{1b}[35;12;7m", "\u{1b}[<a;b;cM", "M"] {
            XCTAssertFalse(PaneTerminalView.isMouseReport(bytes(other)), other.debugDescription)
        }
    }
}
