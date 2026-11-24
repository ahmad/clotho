import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// Review images of the whole main window (the app launched in this process on the fake backend, as in
/// SidebarLayoutTests), with an agent in every state: a tab with three panes (one Needs you with a pending
/// "Allow Bash: cargo test -p clothod", one Working, one plain shell), tabs with an amber dot, a ring and
/// no mark, the sidebar's inbox with Needs you, Done and Working, then ⌘P with "needs" typed. Each in
/// light and dark, in a narrow window (760×520, the sidebar at 150) and a wide one (1280×800).
///
/// Runs only with CLOTHO_SNAPSHOT_DIR set. The window is drawn from its layers, never the screen.
@MainActor
final class UIRefreshRenderTests: XCTestCase {
    private let keys = ["Backend", "FakeFeatures", "FakeAgents", "AgentNotifications", "HideSidebar", "SidebarWidth",
                        Theme.Mode.defaultsKey, OnboardingController.doneKey, "LaunchInBackground", "StartFullScreen",
                        SidebarView.workingExpandedKey, "NSWindow Frame ClothoMainWindow"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        for key in keys { saved[key] = defaults.object(forKey: key) }
        defaults.set("fake", forKey: "Backend")
        // The fake answers permission requests and mutes, as clothod 0.1.31 does.
        defaults.set("agent.decide,agent.mute", forKey: "FakeFeatures")
        defaults.set(false, forKey: "FakeAgents")
        defaults.set(false, forKey: "AgentNotifications")
        defaults.set(false, forKey: "HideSidebar")
        defaults.set(false, forKey: "StartFullScreen")
        defaults.set(true, forKey: OnboardingController.doneKey)
        defaults.set(true, forKey: "LaunchInBackground")
        defaults.set(true, forKey: SidebarView.workingExpandedKey)
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    private func wait(_ what: String, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testWindowSnapshotsForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CLOTHO_SNAPSHOT_DIR"] else { throw XCTSkip("no CLOTHO_SNAPSHOT_DIR") }
        let savedAppearance = NSApp.appearance
        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            app.quickOpen?.dismiss()
            app.window?.orderOut(nil)
            app.connections.values.forEach { $0.store.stop() }
            NSApp.appearance = savedAppearance
            Theme.followAppAppearance()
        }
        try await wait("a workspace") { app.store.focusedWorkspace != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        XCTAssertTrue(app.store.features.contains(.agentDecide), "FakeFeatures reached the fake's hello")
        let first = app.store.state.workspaces.map(\.id)

        // "clotho": the tab "alerts" with a shell, an agent that needs the user and one that works; "build"
        // with a working agent; "zsh" with none.
        let now = Date().timeIntervalSince1970
        let sleep = SpawnOptions(command: ["/bin/sleep", "600"], cwd: "/tmp")
        let git = PaneGit(repo: "clotho", root: "/tmp", branch: "ui-refresh", head: "a1b2c3d")
        let clotho = try await fake.createWorkspace(name: "clotho", spawn: SpawnOptions(command: ["/bin/zsh", "-f"], cwd: "/tmp"))
        for id in first { try await fake.closeWorkspace(id) }
        try await fake.renameTab(clotho.tab, title: "alerts")
        let asking = try await fake.split(clotho.pane, direction: .right, ratio: nil, spawn: sleep).pane
        let working = try await fake.split(asking, direction: .down, ratio: nil, spawn: sleep).pane
        let request = PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test -p clothod")
        fake.setAgent(asking, AgentInfo(kind: "claude", state: .waiting, source: "hook", message: "Claude needs your permission to use Bash",
                                        since: now - 130, requests: [request]))
        fake.setAgent(working, AgentInfo(kind: "codex", state: .running, source: "hook", message: "Running the test suite", since: now - 380))
        fake.setGit(clotho.pane, git)
        fake.setGit(asking, git)
        let build = try await fake.createTab(in: clotho.workspace, spawn: sleep)
        try await fake.renameTab(build.tab, title: "build")
        fake.setAgent(build.pane, AgentInfo(kind: "claude", state: .running, source: "hook", message: "Editing Sources/Model.swift", since: now - 45))
        let zsh = try await fake.createTab(in: clotho.workspace, spawn: sleep)
        try await fake.renameTab(zsh.tab, title: "zsh")

        // "website": a finished turn that asks nothing (Done) and one that asks (Needs you).
        let website = try await fake.createWorkspace(name: "website", spawn: sleep)
        try await fake.renameTab(website.tab, title: "deploy")
        fake.setAgent(website.pane, AgentInfo(kind: "claude", state: .done, source: "hook", message: "All 212 tests pass.", since: now - 600,
                                              needsUser: false))
        let push = try await fake.createTab(in: website.workspace, spawn: sleep)
        try await fake.renameTab(push.tab, title: "fix-login")
        fake.setAgent(push.pane, AgentInfo(kind: "claude", state: .done, source: "hook", message: "The fix is committed. Should I push it?",
                                           since: now - 40, needsUser: true))
        try await wait("the agents") {
            let panes = app.store.state.panes
            return [asking, working, build.pane, website.pane, push.pane].allSatisfy { id in panes.first { $0.id == id }?.agent != nil }
        }

        let machine = AppDelegate.localKey
        func host(_ pane: PaneID) -> PaneHostView? { app.paneHosts[PaneKey(machine: machine, pane: pane)] }
        func settle() async throws {
            try await Task.sleep(nanoseconds: 150_000_000)
            app.window.contentView?.layoutSubtreeIfNeeded()
            app.window.displayIfNeeded()
        }

        for (size, sidebar, width, height, focused) in [("narrow", 150, 760, 520, asking), ("wide", 236, 1280, 800, clotho.pane)]
            as [(String, CGFloat, CGFloat, CGFloat, PaneID)] {
            app.window.setContentSize(NSSize(width: width, height: height))
            app.sidebarWidth.constant = sidebar
            // Narrow: the keyboard is in the pane that asks (the focus ring with the amber line inside it,
            // "Allow ⌘↩"). Wide: in the shell beside it (the amber line alone, a plain "Allow").
            try await fake.focus(.pane(focused))
            try await wait("the three panes shown, \(size)") {
                app.store.focusedPane?.id == focused && [clotho.pane, asking, working].allSatisfy { host($0)?.superview != nil }
            }
            for mode in [Theme.Mode.light, .dark] {
                app.setAppearance(mode)
                try await settle()
                app.appearanceChanged()
                try await settle()

                let bar = try XCTUnwrap(host(asking)?.askBar, "the ask bar, \(size) \(mode.rawValue)")
                // Every request starts off for `AskBar.settleDelay`: the pictures show the buttons on.
                try await wait("the ask bar's buttons") { bar.isEnabled }
                // The narrow window's pane has no room for all of it: the tool and the command stay.
                let fits = bar.label.stringValue == "Allow Bash: cargo test -p clothod"
                XCTAssertTrue(fits || bar.label.stringValue == "Bash: cargo test -p clothod", bar.label.stringValue)
                XCTAssertEqual(bar.label.lineBreakMode, .byTruncatingTail)
                if size == "wide" { XCTAssertTrue(fits, "all of it in a wide pane") }
                XCTAssertTrue(bar.allow.title == (focused == asking ? "Allow ⌘↩" : "Allow") || (!fits && bar.allow.title == "Allow"), bar.allow.title)
                XCTAssertEqual(host(asking)?.outline.isHidden, false, "the amber line")
                XCTAssertEqual(host(working)?.outline.isHidden, true)
                XCTAssertNil(host(clotho.pane)?.askBar)
                XCTAssertEqual(app.agentMark(machine: machine, panes: [build.pane])?.mark, .working)
                XCTAssertNil(app.agentMark(machine: machine, panes: [zsh.pane]))
                let inbox = AgentInbox.sections(app.agentEntries())
                XCTAssertEqual(inbox.needsYou.map(\.pane), [asking, push.pane], "the longest wait first")
                XCTAssertEqual(inbox.done.map(\.pane), [website.pane])
                XCTAssertEqual(inbox.working.map(\.pane), [build.pane, working], "the most recent first")

                saveSnapshot(of: app.container, to: "\(folder)/window-\(size)-\(mode.rawValue).png")

                // ⌘P with "needs" typed: the agents that need the user lead, under their header.
                app.showQuickOpen(nil)
                let overlay = try XCTUnwrap(app.quickOpen)
                overlay.setQuery("needs")
                // "⌥↩ Allow" is dimmed for `AskBar.settleDelay` when a request comes under the selection.
                try await wait("the footer's Allow hint") { !overlay.allowHintDimmed }
                try await settle()
                saveSnapshot(of: app.container, to: "\(folder)/window-\(size)-\(mode.rawValue)-cmdp-needs.png")
                overlay.cancel()
                try await wait("the command bar closed") { app.quickOpen == nil }
                // Esc goes back to where it was.
                try await fake.focus(.pane(focused))
            }
        }
    }
}
