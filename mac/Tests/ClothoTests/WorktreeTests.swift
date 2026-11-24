import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// New Tab in a Worktree…, in the real main window on the fake backend: where it's offered, the prompt
/// in the command bar, the wait while the worktree is made, and every error in plain words.
@MainActor
final class WorktreeTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func tearDown() { ChangesFixture.restore(saved) }

    private func launch() async throws -> (AppDelegate, FakeBackend, PaneID) {
        saved = ChangesFixture.prepare(features: "git.changes,worktree")
        let app = ChangesFixture.launch()
        try await ChangesFixture.wait("a pane with a folder") { app.store.focusedPane?.cwd != nil }
        let fake = try XCTUnwrap(app.store.backend as? FakeBackend)
        return (app, fake, try XCTUnwrap(app.store.focusedPane?.id))
    }

    private func inRepo(_ app: AppDelegate, _ fake: FakeBackend, _ pane: PaneID) async throws {
        fake.setGit(pane, PaneGit(repo: "clotho", root: "/p/clotho", branch: "main", head: "a1b2c3d"))
        try await ChangesFixture.wait("git on the pane") { app.store.focusedPane?.git != nil }
    }

    private func command(_ bar: QuickOpenOverlay, _ control: NSTextField, _ selector: Selector) -> Bool {
        bar.control(control, textView: control.currentEditor() as? NSTextView ?? NSTextView(), doCommandBy: selector)
    }

    /// Esc as the window delivers it: a key down to whatever has the keyboard.
    private func pressEsc(_ app: AppDelegate) throws {
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: app.window.windowNumber, context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        try XCTUnwrap(app.window.firstResponder).keyDown(with: esc)
    }

    private func noticeButtons(_ app: AppDelegate) -> [String] {
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        return app.noticeBar.map { buttons($0).map(\.title).filter { !$0.isEmpty } } ?? []
    }

    func testThePromptAsksForANameAndCreatesTheTab() async throws {
        let (app, fake, pane) = try await launch()
        defer { ChangesFixture.quit(app) }
        let item = try XCTUnwrap(AppDelegate.makeMainMenu().items.first { $0.submenu?.title == "File" }?.submenu?.items
            .first { $0.action == #selector(AppDelegate.newWorktreeTab(_:)) }, "File › New Tab in a Worktree…")
        XCTAssertEqual(item.title, "New Tab in a Worktree…")
        XCTAssertEqual(item.keyEquivalent, "t")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option], "⌥⌘T")
        // Outside a repository the command isn't there.
        XCTAssertFalse(app.validateMenuItem(item))
        try await inRepo(app, fake, pane)
        XCTAssertTrue(app.validateMenuItem(item))

        app.newWorktreeTab(nil)
        let bar = try XCTUnwrap(app.quickOpen)
        let subject = try XCTUnwrap(bar.naming)
        XCTAssertEqual(subject.pane, pane)
        XCTAssertEqual(subject.repo, "clotho")
        let field = bar.fieldForTesting
        XCTAssertEqual(field.placeholderString, "Branch name for the new worktree")
        XCTAssertEqual(field.accessibilityLabel(), "Worktree branch name")
        XCTAssertEqual(bar.baseField.placeholderString, "HEAD of main")
        XCTAssertFalse(bar.namingPreview.stringValue.isEmpty)
        XCTAssertEqual(bar.footerText, "↩ create    ⇥ base    esc close", "opened from the menu: Esc closes the bar")
        // Return with no name does nothing.
        XCTAssertTrue(command(bar, field, #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(fake.worktreeRequests.isEmpty)
        // The preview says what will be made.
        bar.setWorktreeName("fix/login")
        XCTAssertEqual(bar.namingPreview.stringValue, "Creates ../clotho-fix-login on the new branch fix/login, from HEAD of main.")
        bar.setWorktreeName("fix/login", base: "origin/main")
        XCTAssertEqual(bar.namingPreview.stringValue, "Creates ../clotho-fix-login on the new branch fix/login, from origin/main.")
        // Tab goes to the base and back.
        XCTAssertTrue(command(bar, field, #selector(NSResponder.insertTab(_:))))
        XCTAssertNotNil(bar.baseField.currentEditor(), "the base has the keyboard")
        XCTAssertTrue(command(bar, bar.baseField, #selector(NSResponder.insertBacktab(_:))))
        XCTAssertNotNil(field.currentEditor())

        // Creating takes a while: the bar says so, the tab bar spins, and the window stays usable.
        fake.worktreeDelay = 0.5
        let tabs = app.store.focusedWorkspace?.tabs.count ?? 0
        XCTAssertTrue(command(bar, field, #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(bar.isCreating)
        XCTAssertEqual(bar.namingStatus.stringValue, "Creating the worktree… A big repository can take a couple of minutes.")
        XCTAssertFalse(field.isEnabled)
        XCTAssertFalse(bar.baseField.isEnabled)
        // The fields are off, so the bar itself has the keyboard: that is where Esc arrives.
        XCTAssertTrue(app.window.firstResponder === bar, "the bar holds the keyboard while the fields are off")
        XCTAssertEqual(app.tabBar.busyText, "Creating worktree clotho-fix-login…")
        XCTAssertFalse(app.tabBar.busySpinner.isHidden)
        XCTAssertEqual(app.tabBar.busySpinner.accessibilityLabel(), "Creating worktree clotho-fix-login…")
        // A second ask while one runs makes nothing more.
        bar.submitWorktree()
        app.createWorktreeTab(subject, name: "another", base: nil)
        XCTAssertTrue(bar.isCreating, "still showing the first")
        // Esc puts the bar away; the work goes on.
        try pressEsc(app)
        XCTAssertNil(app.quickOpen)
        XCTAssertNotNil(app.worktreeCreation)
        try await fake.renameTab(try XCTUnwrap(app.store.focusedTab?.id), title: "still usable")
        try await ChangesFixture.wait("the rename, during the checkout") { app.store.focusedTab?.title == "still usable" }
        // Asked again meanwhile: the prompt shows the one under way.
        app.newWorktreeTab(nil)
        let again = try XCTUnwrap(app.quickOpen)
        XCTAssertTrue(again.isCreating)
        XCTAssertEqual(again.fieldForTesting.stringValue, "fix/login")
        XCTAssertTrue(app.window.firstResponder === again, "Esc reaches this one too")
        again.submitWorktree()
        // Done: the bar closes, the new Tab is focused, in the worktree.
        try await ChangesFixture.wait("the worktree's Tab") { app.store.focusedWorkspace?.tabs.count == tabs + 1 && app.worktreeCreation == nil }
        XCTAssertEqual(fake.worktreeRequests, [WorktreeRequest(name: "fix/login", base: "origin/main")], "one worktree was asked for")
        XCTAssertNil(app.quickOpen, "the bar closed")
        XCTAssertNil(app.tabBar.busyText)
        XCTAssertTrue(app.tabBar.busySpinner.isHidden)
        try await ChangesFixture.wait("the pane in the worktree") { app.store.focusedPane?.git?.worktree?.name == "clotho-fix-login" }
        XCTAssertEqual(app.store.focusedPane?.git?.branch, "fix/login")
        XCTAssertNil(app.noticeBar)
    }

    func testEveryErrorIsSaidInPlainWords() async throws {
        let (app, fake, pane) = try await launch()
        defer { ChangesFixture.quit(app) }
        try await inRepo(app, fake, pane)
        let left = "(the worktree /p/clotho-x on the new branch x was created and is still there)"
        let cases: [(BackendError, String)] = [
            (BackendError(code: "worktree_exists", message: "/p/clotho-x is already there"), "A file or folder is already there: /p/clotho-x is already there."),
            (BackendError(code: "branch_exists", message: "x"), "A branch with that name already exists."),
            (BackendError(code: "worktree_name", message: "bad"), "A name is 1 to 100 letters, digits, '.', '_', '-' or '/', and must be a valid branch name."),
            (BackendError(code: "bad_base", message: "nope is not a commit here"), "nope is not a commit here."),
            (BackendError(code: "worktree_unsupported", message: "bare"), "This repository has no main work tree to put a worktree beside."),
            (BackendError(code: "git_failed", message: "fatal: \u{1b}[31mno"), "Git couldn't make the worktree: fatal: \u{241B}[31mno."),
            (BackendError(code: "timeout", message: "t"), "Git took too long, so no worktree was made."),
            (BackendError(code: "no_git", message: "g"), "Git isn't installed on \(ComputerName.current)."),
            (BackendError(code: "not_found", message: "no workspace 9"), "The Workspace is gone, so no worktree was made."),
            (BackendError(code: "spawn_failed", message: "no such command \(left)"),
             "The worktree was created and is still there (/p/clotho-x), but its Tab couldn't be opened: no such command."),
            (BackendError(code: "not_found", message: "workspace 3 was closed \(left)"),
             "The worktree was created and is still there (/p/clotho-x), but its Tab couldn't be opened: workspace 3 was closed."),
            (BackendError(code: "disconnected", message: "gone"), "The connection to \(ComputerName.current) dropped. The worktree may still have been created."),
        ]
        for (error, words) in cases {
            XCTAssertFalse(words.contains("Session"))
            // With the bar open: under the fields, which keep what was typed.
            fake.worktreeError = error
            app.newWorktreeTab(nil)
            let bar = try XCTUnwrap(app.quickOpen)
            bar.setWorktreeName("x", base: "nope")
            bar.submitWorktree()
            try await ChangesFixture.wait("\(error.code) shown") { bar.namingError != nil }
            XCTAssertEqual(bar.namingError, words, error.code)
            XCTAssertEqual(bar.namingStatus.stringValue, words)
            XCTAssertFalse(bar.isCreating)
            XCTAssertTrue(bar.fieldForTesting.isEnabled)
            XCTAssertEqual(bar.fieldForTesting.stringValue, "x", "the name is still there to fix")
            XCTAssertEqual(bar.baseField.stringValue, "nope")
            XCTAssertNil(app.noticeBar, "said in the bar, not twice")
            XCTAssertNil(app.tabBar.busyText)
            bar.dismiss()

            // With the bar put away: a notice. Edit… reopens the prompt, except when the worktree was
            // made or may have been.
            fake.worktreeDelay = 0.15
            app.newWorktreeTab(nil)
            let hidden = try XCTUnwrap(app.quickOpen)
            hidden.setWorktreeName("x", base: "nope")
            hidden.submitWorktree()
            hidden.cancel()
            XCTAssertNil(app.quickOpen)
            try await ChangesFixture.wait("\(error.code) as a notice") { app.noticeBar != nil }
            let leftBehind = error.worktreeLeftBehind || error.code == "disconnected"
            XCTAssertEqual(noticeButtons(app).contains("Edit…"), !leftBehind, "\(error.code): no blind retry once the worktree may exist")
            fake.worktreeDelay = 0
            app.hideNotice()
        }
        XCTAssertEqual(app.store.focusedWorkspace?.tabs.count, 1, "no Tab was made by any of them")

        // Edit… brings the prompt back with what was typed.
        fake.worktreeError = BackendError(code: "branch_exists", message: "x")
        fake.worktreeDelay = 0.15
        app.newWorktreeTab(nil)
        app.quickOpen?.setWorktreeName("x", base: "nope")
        app.quickOpen?.submitWorktree()
        app.quickOpen?.cancel()
        try await ChangesFixture.wait("the notice") { app.noticeBar != nil }
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        try XCTUnwrap(buttons(try XCTUnwrap(app.noticeBar)).first { $0.title == "Edit…" }).performClick(nil)
        XCTAssertNil(app.noticeBar)
        let bar = try XCTUnwrap(app.quickOpen)
        XCTAssertNotNil(bar.naming)
        XCTAssertEqual(bar.fieldForTesting.stringValue, "x")
        XCTAssertEqual(bar.baseField.stringValue, "nope")
    }
}
