import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Every pane has a header: the agent's chip (or the program's name) on the left, the folder on the
/// right, the × at its trailing end on hover. A pane whose agent needs the user has an amber outline.
@MainActor
final class PaneHeaderTests: XCTestCase {
    private var window: NSWindow!
    private var backend: FakeBackend!
    private var store: ModelStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var since: Double { now.timeIntervalSince1970 }

    override func setUp() async throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        backend = FakeBackend(extraFeatures: ["agent.mute", "agent.history", "agent.decide"])
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

    private func host(width: CGFloat = 700) async throws -> (PaneHostView, PaneID) {
        let created = try await backend.createWorkspace(name: "One", spawn: SpawnOptions(command: ["/bin/sleep", "30"]))
        try await waitFor("the pane") { store.state.pane(created.pane) != nil }
        let host = PaneHostView(pane: store.state.pane(created.pane)!, store: store, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.appearance = NSAppearance(named: .aqua)
        host.header.now = { [now] in now }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return (host, created.pane)
    }

    /// Puts an agent in the pane through the fake daemon, and gives the host what a sync would.
    private func show(_ agent: AgentInfo?, in host: PaneHostView, _ pane: PaneID, cwd: String? = "/Users/me/Projects/clotho",
                      home: String? = "/Users/me") async throws {
        var agent = agent
        let token = UUID().uuidString
        agent?.session = token
        backend.setAgent(pane, agent)
        try await waitFor("the agent") { store.state.pane(pane)?.agent?.session == agent?.session }
        host.chrome = PaneChrome(agent: store.state.pane(pane)?.agent, command: store.state.pane(pane)?.command, cwd: cwd, home: home,
                                 canDecide: store.features.contains(.agentDecide))
        host.refreshElapsed()
        host.layoutSubtreeIfNeeded()
    }

    private func resolved(_ color: NSColor, in view: NSView) -> CGColor {
        var result = color.cgColor
        view.withAppearance { result = color.cgColor }
        return result
    }

    private func assertSame(_ a: CGColor?, _ b: CGColor, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = a?.components ?? [], y = b.components ?? []
        XCTAssertEqual(x.count, y.count, message, file: file, line: line)
        for (p, q) in zip(x, y) { XCTAssertEqual(p, q, accuracy: 0.01, message, file: file, line: line) }
    }

    func testChipTextTintAndTime() async throws {
        let (host, pane) = try await host()
        let header = host.header, chip = header.chip

        try await show(AgentInfo(kind: "claude", state: .waiting, source: "hook", since: since - 150), in: host, pane)
        XCTAssertFalse(chip.isHidden)
        XCTAssertTrue(header.program.isHidden, "the chip takes the program's place")
        XCTAssertEqual(chip.text, "Claude · Needs you")
        XCTAssertEqual(chip.title, "Claude · Needs you")
        XCTAssertEqual(chip.mark, .needsYou)
        assertSame(chip.layer?.backgroundColor, AgentMark.needsYou.tint(for: .light).cgColor, "the amber tint")
        XCTAssertEqual(header.elapsed.stringValue, "waiting 2 min")
        XCTAssertFalse(header.elapsed.isHidden)
        XCTAssertEqual(chip.accessibilityLabel(), "Claude: Needs you, waiting 2 minutes")
        XCTAssertGreaterThanOrEqual(header.elapsed.frame.minX, chip.frame.maxX, "the time follows the chip")

        try await show(AgentInfo(kind: "codex", state: .running, since: since - 400), in: host, pane)
        XCTAssertEqual(chip.text, "Codex · Working")
        XCTAssertEqual(chip.mark, .working)
        assertSame(chip.layer?.backgroundColor, AgentMark.working.tint(for: .light).cgColor, "the accent tint")
        XCTAssertEqual(header.elapsed.stringValue, "6 min")
        XCTAssertEqual(chip.accessibilityLabel(), "Codex: Working, 6 minutes")
        // The app's clock moves it on.
        header.now = { [now] in now.addingTimeInterval(120) }
        host.refreshElapsed()
        XCTAssertEqual(header.elapsed.stringValue, "8 min")
        header.now = { [now] in now }

        try await show(AgentInfo(kind: "claude", state: .done, source: "hook", since: since - 30, needsUser: false), in: host, pane)
        XCTAssertEqual(chip.text, "Claude · Done")
        XCTAssertEqual(chip.mark, .done)
        assertSame(chip.layer?.backgroundColor, AgentMark.done.tint(for: .light).cgColor, "the green tint")
        XCTAssertEqual(header.elapsed.stringValue, "", "no time for a finished turn")
        XCTAssertTrue(header.elapsed.isHidden)
        XCTAssertEqual(chip.accessibilityLabel(), "Claude: Done")

        try await show(AgentInfo(kind: "claude", state: .error, source: "hook", since: since - 30), in: host, pane)
        XCTAssertEqual(chip.text, "Claude · Error")
        XCTAssertEqual(chip.mark, .error)
        assertSame(chip.layer?.backgroundColor, AgentMark.error.tint(for: .light).cgColor, "the red tint")

        // No mark: a plain dim chip with the state's word.
        try await show(AgentInfo(kind: "claude", state: .waiting, since: since - 600, attention: false), in: host, pane)
        XCTAssertEqual(chip.text, "Claude · Idle")
        XCTAssertNil(chip.mark)
        assertSame(chip.layer?.backgroundColor, resolved(Theme.pill, in: chip), "a plain chip")
        XCTAssertEqual(header.elapsed.stringValue, "")

        try await show(AgentInfo(kind: "claude", state: .done, source: "hook", since: since - 5, settling: true), in: host, pane)
        XCTAssertEqual(chip.text, "Claude · Done")
        XCTAssertNil(chip.mark, "a settling agent has no mark")
        XCTAssertEqual(chip.symbol, "sparkle", "the kind's symbol leads the name")
        XCTAssertNotNil(chip.image)

        // Muted: a crossed bell.
        try await show(AgentInfo(kind: "claude", state: .waiting, source: "hook", since: since - 5, muted: true), in: host, pane)
        XCTAssertTrue(chip.isMuted)
        XCTAssertNotNil(chip.image)
        XCTAssertNil(chip.mark)
        XCTAssertEqual(chip.accessibilityLabel(), "Claude: Idle, muted")
        XCTAssertGreaterThanOrEqual(chip.frame.width, chip.intrinsicContentSize.width - 0.5, "room for the bell")
    }

    func testAShellPaneShowsItsProgramAndFolder() async throws {
        let (host, pane) = try await host()
        let header = host.header
        try await show(nil, in: host, pane)
        XCTAssertTrue(header.chip.isHidden)
        XCTAssertFalse(header.program.isHidden)
        XCTAssertEqual(header.program.stringValue, "sleep", "the spawn command's name")
        XCTAssertEqual(PaneChrome(command: ["/bin/zsh", "-l"]).program, "zsh")
        XCTAssertEqual(PaneChrome(command: ["-zsh"]).program, "zsh")
        XCTAssertEqual(PaneChrome(command: nil).program, "shell")
        XCTAssertEqual(PaneChrome(command: []).program, "shell")
        // With room to spare, each label has all its cell asks for: nothing draws as "…".
        for label in [header.program, header.folder] {
            let needs = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).width
            XCTAssertGreaterThanOrEqual(label.frame.width, needs, "\(label.stringValue) shows whole")
        }

        XCTAssertEqual(header.folder.stringValue, "~/Projects/clotho")
        XCTAssertEqual(header.folder.accessibilityLabel(), "Folder ~/Projects/clotho")
        XCTAssertEqual(header.folder.toolTip, "/Users/me/Projects/clotho")
        XCTAssertFalse(header.folder.isHidden)
        XCTAssertGreaterThan(header.folder.frame.midX, header.bounds.midX, "on the right")
        XCTAssertLessThanOrEqual(header.folder.frame.maxX, host.closeButtonFrame.minX, "it ends before the ×'s room")
        XCTAssertEqual(PaneChrome(cwd: "/Users/me", home: "/Users/me").folder, "~")
        XCTAssertEqual(PaneChrome(cwd: "/Users/mest/x", home: "/Users/me").folder, "/Users/mest/x", "another folder that only starts alike")
        XCTAssertEqual(PaneChrome(cwd: "/srv/www", home: nil).folder, "/srv/www", "the whole path when the home isn't known")
        XCTAssertNil(PaneChrome(cwd: nil, home: "/Users/me").folder)

        // A long folder loses its head, never its end, and never reaches the ×.
        let long = "/Users/me/" + (1...30).map { "folder-\($0)" }.joined(separator: "/")
        try await show(nil, in: host, pane, cwd: long)
        XCTAssertEqual(header.folder.lineBreakMode, .byTruncatingHead)
        XCTAssertLessThan(header.folder.frame.width, header.folder.intrinsicContentSize.width, "truncated")
        XCTAssertLessThanOrEqual(header.folder.frame.maxX, host.closeButtonFrame.minX)
        XCTAssertGreaterThanOrEqual(header.folder.frame.minX, header.program.frame.maxX, "not over the program's name")
    }

    func testTheCloseButtonIsInTheHeaderAndMovesNothing() async throws {
        let (host, pane) = try await host()
        try await show(AgentInfo(kind: "claude", state: .running, since: since - 400), in: host, pane)
        let header = host.header
        XCTAssertEqual(header.frame, NSRect(x: 0, y: 0, width: host.bounds.width, height: PaneHeader.height), "full width, at the top")
        XCTAssertEqual(host.terminal.frame.minY, PaneHeader.height + PaneHostView.padding, accuracy: 0.5, "the terminal starts under it")
        let frames = [header.chip.frame, header.elapsed.frame, header.folder.frame]
        let size = host.fittedSize()

        host.onClose = {}
        XCTAssertTrue(header.frame.contains(host.closeButtonFrame), "the ×'s place is inside the header")
        XCTAssertEqual(host.closeButtonFrame.midY, header.frame.midY, accuracy: 0.5, "centred")
        XCTAssertTrue(host.closeCorner.contains(host.closeButtonFrame), "and inside the corner that shows it")
        XCTAssertEqual(host.closeCorner.size, NSSize(width: 72, height: 44))
        host.setCornerHover(true)
        host.layoutSubtreeIfNeeded()
        let close = try XCTUnwrap(host.closeButton)
        XCTAssertEqual(close.frame, host.closeButtonFrame)
        XCTAssertEqual([header.chip.frame, header.elapsed.frame, header.folder.frame], frames, "nothing moves on hover")
        XCTAssertFalse(close.frame.intersects(header.folder.frame))
        XCTAssertEqual(host.fittedSize(), size, "it takes no rows")
    }

    /// Narrowing a pane: the time goes first, then the folder; the chip keeps its whole width.
    func testTheTimeHidesBeforeTheFolderInANarrowPane() async throws {
        let (host, pane) = try await host()
        try await show(AgentInfo(kind: "claude", state: .waiting, source: "hook", since: since - 150), in: host, pane)
        let header = host.header
        var states: [(width: CGFloat, time: Bool, folder: Bool)] = []
        for width in stride(from: CGFloat(700), through: 160, by: -10) {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            states.append((width, !header.elapsed.isHidden, !header.folder.isHidden))
            XCTAssertGreaterThanOrEqual(header.chip.frame.width, header.chip.intrinsicContentSize.width - 0.5, "the chip never clips (\(width))")
            XCTAssertLessThanOrEqual(header.chip.frame.maxX, host.closeButtonFrame.minX, "\(width)")
            if !header.elapsed.isHidden {
                XCTAssertGreaterThanOrEqual(header.elapsed.frame.minX, header.chip.frame.maxX, "\(width)")
                XCTAssertFalse(header.folder.isHidden, "the time never outlasts the folder (\(width))")
                XCTAssertLessThanOrEqual(header.elapsed.frame.maxX, header.folder.frame.minX, "\(width)")
            }
            if !header.folder.isHidden {
                XCTAssertGreaterThanOrEqual(header.folder.frame.minX, header.chip.frame.maxX, "\(width)")
                XCTAssertLessThanOrEqual(header.folder.frame.maxX, host.closeButtonFrame.minX, "never under the × (\(width))")
            }
        }
        XCTAssertTrue(states.first!.time && states.first!.folder, "a wide pane shows both")
        XCTAssertFalse(states.last!.time, "the time is gone at 160 pt")
        XCTAssertTrue(states.contains { !$0.time && $0.folder }, "the time goes while the folder still shows: \(states)")
        // Once gone, each stays gone as the pane narrows further.
        XCTAssertEqual(states.map(\.time), states.map(\.time).sorted { $0 && !$1 })
        XCTAssertEqual(states.map(\.folder), states.map(\.folder).sorted { $0 && !$1 })
    }

    /// Muted, idle and resolved agents have no inbox row: the chip's menu is where Unmute and History… are.
    func testTheChipOpensTheAgentMenu() async throws {
        // The app's own store for this one (a fake backend feeds one store).
        store.stop()
        backend = FakeBackend(extraFeatures: ["agent.mute", "agent.history"])
        let app = AppDelegate()
        let connection = MachineConnection(machine: .local, backend: backend)
        app.connections[AppDelegate.localKey] = connection
        store = connection.store
        try await store.start()
        let (host, pane) = try await host()
        host.agentMenu = { app.agentMenu(machine: AppDelegate.localKey, pane: pane, canReply: false) }
        try await show(AgentInfo(kind: "claude", state: .running, source: "hook", muted: true), in: host, pane)
        let titles = try XCTUnwrap(host.header.chip.onMenu?()).items.map(\.title)
        XCTAssertTrue(titles.contains("Unmute"), "\(titles)")
        XCTAssertFalse(titles.contains("Mute"), "\(titles)")
        XCTAssertTrue(titles.contains("History…"), "\(titles)")
    }

    func testTheAmberOutlineShowsOnlyForNeedsYou() async throws {
        let (host, pane) = try await host()
        try await show(AgentInfo(kind: "claude", state: .running, since: since), in: host, pane)
        XCTAssertFalse(host.showsNeedsYouOutline)
        XCTAssertTrue(host.outline.isHidden, "a working agent has none")

        try await show(AgentInfo(kind: "claude", state: .waiting, source: "hook", since: since), in: host, pane)
        XCTAssertTrue(host.showsNeedsYouOutline)
        XCTAssertFalse(host.outline.isHidden)
        XCTAssertEqual(host.outline.borderWidth, 1.5)
        XCTAssertEqual(host.outline.frame, host.bounds, "at the pane's edge without the focus ring")
        XCTAssertGreaterThan(host.outline.zPosition, 0, "above the content")
        XCTAssertEqual(host.layer?.borderColor?.alpha, 0, "no focus ring")
        for (appearance, palette) in [(NSAppearance.Name.aqua, ClothoPalette.light), (.darkAqua, .dark)] {
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            assertSame(host.outline.borderColor, NSColor(hex: palette.ansi[3]).cgColor, "the palette's amber in \(appearance.rawValue)")
        }

        // With the focus ring: the ring stays the layer's border, the amber line sits 1 pt inside it.
        host.isFocusedPane = true
        host.showsFocusRing = true
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.outline.frame, host.bounds.insetBy(dx: 1, dy: 1))
        XCTAssertFalse(host.outline.isHidden)
        XCTAssertGreaterThan(host.layer?.borderColor?.alpha ?? 0, 0, "the focus ring shows too")
        for (appearance, palette) in [(NSAppearance.Name.aqua, ClothoPalette.light), (.darkAqua, .dark)] {
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            assertSame(host.outline.borderColor, NSColor(hex: palette.ansi[3]).cgColor, "the palette's amber in \(appearance.rawValue)")
        }

        try await show(AgentInfo(kind: "claude", state: .done, source: "hook", since: since, needsUser: false), in: host, pane)
        XCTAssertTrue(host.outline.isHidden, "Done has none")
        try await show(nil, in: host, pane)
        XCTAssertTrue(host.outline.isHidden)
    }

    /// New panes start at the size they'll be shown at (`spawnOptions`): under a header.
    func testANewPanesSizeCountsTheHeader() async throws {
        let (host, _) = try await host()
        let size = CGSize(width: 800, height: 600)
        let fitted = host.fittedSize(in: size)
        XCTAssertEqual(fitted.rows, Int((size.height - PaneHeader.height - PaneHostView.padding * 2) / host.cellSize.height))
        // This pane's own strip and ask bar aren't the new pane's.
        host.git = PaneGit(repo: "clotho", root: "/p/clotho", remote: nil, branch: "main", head: "a1b2c3d", worktree: nil, pr: nil)
        XCTAssertEqual(host.fittedSize(in: size), fitted)
    }
}
