import ClothoFake
import XCTest
@testable import ClothoKit

/// pane.focus (feature `pane.focus`, clothod 0.1.28): the pane takes the viewport of the client that
/// focused it most recently. A subscribe with a viewport counts as a focus; typing doesn't.
extension ClothodBackendTests {
    func testPaneFocusTakesTheFocusingClientsViewport() async throws {
        let mac = makeBackend(), phone = makeBackend()
        defer { mac.stop(); phone.stop() }
        try await mac.start()
        try await phone.start()
        let hello = try XCTUnwrap(mac.lastHello)
        try XCTSkipUnless(hello.features.contains(.paneFocus), "this clothod predates pane.focus")

        let created = try await mac.createWorkspace(name: "focus", spawn: SpawnOptions(command: ["/bin/sh"], cwd: "/tmp"))
        func size() async throws -> String {
            let state = try await mac.getState()
            let pane = try XCTUnwrap(state.pane(created.pane))
            return "\(pane.cols)x\(pane.rows)"
        }
        func waitForSize(_ expected: String, _ what: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            var now = try await size()
            while now != expected, Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
                now = try await size()
            }
            XCTAssertEqual(now, expected, what)
        }

        _ = try await mac.subscribe(created.pane, haveSeq: nil, scrollback: 0, viewport: Size(cols: 100, rows: 30))
        try await waitForSize("100x30", "the Mac's viewport")
        _ = try await phone.subscribe(created.pane, haveSeq: nil, scrollback: 0, viewport: Size(cols: 40, rows: 12))
        try await waitForSize("40x12", "the phone opening the pane focuses it")

        // Typing on the Mac doesn't take the size back.
        mac.sendInput(created.pane, Data("echo typed\n".utf8))
        try await Task.sleep(nanoseconds: 500_000_000)
        let typed = try await size()
        XCTAssertEqual(typed, "40x12", "typing doesn't pick the size")

        try await mac.focusPane(created.pane)
        try await waitForSize("100x30", "focusing on the Mac")
        try await phone.focusPane(created.pane)
        try await waitForSize("40x12", "focusing on the phone")
    }

    @MainActor
    func testPaneFocusWithoutTheFeatureDoesNothing() async throws {
        // Not connected: no hello, so no feature, and no request goes out.
        let backend = makeBackend()
        try await backend.focusPane(1)
        let fake = FakeBackend()
        defer { fake.stop() }
        try await fake.start()
        let created = try await fake.createWorkspace(name: "w", spawn: SpawnOptions(command: ["/bin/sh"]))
        let store = ModelStore(backend: fake)
        try await store.focusPane(created.pane)
        XCTAssertEqual(fake.focusedPanes, [created.pane])
        do {
            try await fake.focusPane(9999)
            XCTFail("an unknown pane")
        } catch let error as BackendError { XCTAssertEqual(error.code, "not_found") }
    }
}
