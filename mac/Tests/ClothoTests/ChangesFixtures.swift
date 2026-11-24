import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The app in this process on the fake backend, and a work tree with changes, for the tests of the
/// inspector, the centre diff, the worktree prompt and their review images.
@MainActor
enum ChangesFixture {
    static let keys = ["Backend", "FakeFeatures", "FakeAgents", "AgentNotifications", "HideSidebar", "SidebarWidth", Theme.Mode.defaultsKey,
                       OnboardingController.doneKey, "LaunchInBackground", "StartFullScreen", AppDelegate.showFileSidebarKey, "FileSidebarWidth",
                       "OpenFilesInApps", FileSidebarView.kindKey, ChangesView.splitKey, SidebarView.workingExpandedKey,
                       "NSWindow Frame ClothoMainWindow", "SkipCloseConfirm.Pane"]

    /// Saves the defaults a launch touches and sets them for a quiet in-process app. Returns what to restore.
    static func prepare(features: String) -> [String: Any] {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in keys { saved[key] = defaults.object(forKey: key) }
        defaults.set("fake", forKey: "Backend")
        defaults.set(features, forKey: "FakeFeatures")
        defaults.set(false, forKey: "FakeAgents")
        defaults.set(false, forKey: "AgentNotifications")
        defaults.set(false, forKey: "HideSidebar")
        defaults.set(false, forKey: "StartFullScreen")
        defaults.set(true, forKey: OnboardingController.doneKey)
        defaults.set(true, forKey: "LaunchInBackground")
        defaults.set(false, forKey: "OpenFilesInApps")
        for key in [AppDelegate.showFileSidebarKey, "FileSidebarWidth", FileSidebarView.kindKey, ChangesView.splitKey,
                    "NSWindow Frame ClothoMainWindow", "SkipCloseConfirm.Pane"] {
            defaults.removeObject(forKey: key)
        }
        return saved
    }

    static func restore(_ saved: [String: Any]) {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    static func launch() -> AppDelegate {
        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return app
    }

    static func quit(_ app: AppDelegate) {
        app.quickOpen?.dismiss()
        app.hideNotice()
        app.window?.orderOut(nil)
        app.connections.values.forEach { $0.store.stop() }
    }

    static func wait(_ what: String, seconds: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static let root = "/tmp/clotho"
    static let daemon = GitChangedFile(path: "clothod/src/daemon.rs", status: .modified, added: 12, removed: 4)
    static let e2e = GitChangedFile(path: "clothod/tests/e2e.rs", status: .modified, added: 2, removed: 1)
    static let branchDaemon = GitChangedFile(path: "clothod/src/daemon.rs", status: .modified, added: 49, removed: 14)
    static let push = GitChangedFile(path: "clothod/src/push.rs", status: .modified, added: 38, removed: 11)
    static let logFile = GitChangedFile(path: "clothod/src/log.rs", status: .added, added: 20, removed: 0)
    static let moved = GitChangedFile(path: "clothod/src/notify/summary.rs", oldPath: "clothod/src/summary.rs", status: .renamed, added: 6, removed: 2)
    static let logo = GitChangedFile(path: "mac/Resources/AppIcon.png", status: .modified, binary: true)
    static let gone = GitChangedFile(path: "docs/old-notes.md", status: .deleted, added: 0, removed: 31)
    static let odd = GitChangedFile(path: "notes/caf\u{FFFD}.txt", status: .untracked, diffable: false)

    /// Two uncommitted files and a branch of four commits, as in the mockup, plus a rename, a binary
    /// file, a deleted one and one whose name can't be sent.
    static var changes: GitChanges {
        GitChanges(root: root, branch: "clothod/clear-alerts", head: "a1b2c3d",
                   uncommitted: .init(files: [daemon, e2e], added: 14, removed: 5),
                   branchChanges: .init(base: "main", baseHead: "9f8e7d6", mergeBase: "9f8e7d6", commits: 4,
                                        files: [branchDaemon, logFile, moved, push, gone, logo, odd], total: 19, added: 113, removed: 58, truncated: true))
    }

    static func git(_ changes: PaneGit.Changes?, reason: String? = nil) -> PaneGit {
        PaneGit(repo: "clotho", root: root, branch: "clothod/clear-alerts", head: "a1b2c3d",
                pr: .init(number: 58, state: .open, url: "https://github.com/ahmad/clotho/pull/58", title: "Clear alerts"),
                changes: changes, changesReason: reason)
    }

    static var daemonDiff: GitDiff {
        GitDiff(path: daemon.path, status: .modified, added: 12, removed: 4, hunks: [
            .init(oldStart: 2044, oldLines: 9, newStart: 2044, newLines: 9, header: "fn at_mac_hold", lines: [
                .init(kind: .context, old: 2044, new: 2044, text: "fn at_mac_hold(&self, p: &Pane) -> bool {"),
                .init(kind: .context, old: 2045, new: 2045, text: "    let seen = self.desktop_seen();"),
                .init(kind: .removed, old: 2046, text: "    seen.at.elapsed() < at_mac()"),
                .init(kind: .removed, old: 2047, text: "        && seen.pane != Some(p.id)"),
                .init(kind: .added, new: 2046, text: "    seen.at.elapsed() < at_mac()"),
                .init(kind: .added, new: 2047, text: "        && !p.user_present()"),
                .init(kind: .context, old: 2048, new: 2048, text: "}"),
                .init(kind: .context, old: 2049, new: 2049, text: ""),
                .init(kind: .context, old: 2050, new: 2050, text: "fn input(&self, c: &Client, data: &[u8]) {"),
                .init(kind: .removed, old: 2051, text: "    if c.is_mac() {"),
                .init(kind: .added, new: 2051, text: "    if c.is_mac() && typed(data) { // only what the user typed counts, never a terminal's own reply to a query"),
                .init(kind: .context, old: 2052, new: 2052, text: "        self.mark_desktop_seen();"),
            ]),
            .init(oldStart: 2306, oldLines: 2, newStart: 2306, newLines: 10, lines: [
                .init(kind: .context, old: 2306, new: 2306, text: "    }"),
                .init(kind: .added, new: 2307, text: "    // A finished turn settles first: it"),
                .init(kind: .added, new: 2308, text: "    // alerts only if the agent stays idle."),
                .init(kind: .added, new: 2309, text: "    if a.state == \"done\" {"),
                .init(kind: .added, new: 2310, text: "        self.arm_settle(p, settle());\u{1b}[0m"),
                .init(kind: .added, new: 2311, text: "    }"),
                .init(kind: .context, old: 2307, new: 2312, text: "}", noNewline: true),
            ]),
        ])
    }

    /// The work tree's changes on `pane`: the summary, the list, and a diff for most files.
    static func fill(_ fake: FakeBackend, _ pane: PaneID) {
        fake.setChanges(pane, .success(changes))
        fake.setDiff(pane, path: daemon.path, group: .uncommitted, .success(daemonDiff))
        var long = daemonDiff
        long.path = branchDaemon.path
        long.added = 49
        long.removed = 14
        long.truncated = true
        fake.setDiff(pane, path: branchDaemon.path, group: .branch, .success(long))
        fake.setDiff(pane, path: logo.path, group: .branch, .success(GitDiff(path: logo.path, status: .modified, binary: true)))
        fake.setDiff(pane, path: moved.path, group: .branch, .success(GitDiff(path: moved.path, oldPath: moved.oldPath, status: .renamed)))
        fake.setDiff(pane, path: push.path, group: .branch, .failure(BackendError(code: "timeout", message: "git took too long")))
        fake.setGit(pane, git(changes.summary))
    }
}
