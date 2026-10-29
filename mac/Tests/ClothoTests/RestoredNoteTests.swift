import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// A pane brought back after a restart shows a quiet note over its top right, which takes no rows (the
/// terminal keeps its size); × clears it on the daemon for every device, and the find bar takes its place
/// while open.
@MainActor
final class RestoredNoteTests: XCTestCase {
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

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func host() async throws -> (PaneHostView, PaneID) {
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        try await waitFor("the pane") { store.state.pane(created.pane) != nil }
        let host = PaneHostView(pane: store.state.pane(created.pane)!, store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return (host, created.pane)
    }

    func testNoteText() {
        XCTAssertEqual(PaneRestore(at: 1).note, "Restored after restart")
        XCTAssertEqual(PaneRestore(at: 1, agent: "claude", session: "abc").note, "Restored after restart · resumed Claude session")
        XCTAssertEqual(PaneRestore(at: 1, agent: "codex", session: "x").note, "Restored after restart · resumed Codex session")
    }

    func testShowsWithoutResizingAndDismissesEverywhere() async throws {
        let (host, pane) = try await host()
        XCTAssertNil(host.restoredNote, "a normal pane has no note")

        backend.setRestored(pane, PaneRestore(at: 1, agent: "claude", session: "s1"))
        try await waitFor("the mark") { store.state.pane(pane)?.restored != nil }
        // Let the pane take the host's size (subscribe, viewport) before comparing.
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let terminalFrame = host.terminal.frame
        host.restored = store.state.pane(pane)?.restored
        host.layoutSubtreeIfNeeded()
        let note = try XCTUnwrap(host.restoredNote)
        XCTAssertEqual(note.label.stringValue, "Restored after restart · resumed Claude session")
        XCTAssertEqual(host.terminal.frame, terminalFrame, "the note takes no rows")
        XCTAssertGreaterThan(note.frame.midX, host.bounds.midX, "top right")
        XCTAssertLessThan(note.frame.minY, 20, "at the top (the host is flipped)")

        // The find bar takes its place, and gives it back.
        host.showFind()
        XCTAssertNil(host.restoredNote)
        host.hideFind()
        XCTAssertNotNil(host.restoredNote)

        // ×: gone here at once, and the daemon clears the mark for every device.
        host.restoredNote!.closeButton.performClick(nil)
        XCTAssertNil(host.restoredNote)
        try await waitFor("the daemon's clear") { store.state.pane(pane)?.restored == nil }
        host.restored = store.state.pane(pane)?.restored
        XCTAssertNil(host.restoredNote)
    }

    /// Typing in the pane clears the mark (the daemon does it; the fake mirrors it), but focus and mouse
    /// reports don't.
    func testTypingClearsItButReportsDont() async throws {
        let (_, pane) = try await host()
        backend.setRestored(pane, PaneRestore(at: 1))
        try await waitFor("the mark") { store.state.pane(pane)?.restored != nil }
        backend.sendInput(pane, Data("\u{1b}[I".utf8))
        backend.sendInput(pane, Data("\u{1b}[<0;3;4M".utf8))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(store.state.pane(pane)?.restored, "focus and mouse reports aren't typing")
        backend.sendInput(pane, Data("l".utf8))
        try await waitFor("typing clears it") { store.state.pane(pane)?.restored == nil }
    }
}
