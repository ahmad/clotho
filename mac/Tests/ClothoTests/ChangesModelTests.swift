import AppKit
import ClothoFake
import ClothoKit
import XCTest
@testable import Clotho

/// The model behind Changes, on the fake backend: what it follows, when it asks the daemon, and that a
/// late reply for another pane never shows.
@MainActor
final class ChangesModelTests: XCTestCase {
    private var fake: FakeBackend!
    private var model: ChangesModel!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var gits: [PaneID: PaneGit] = [:]
    private var notes = 0

    private let login = GitChangedFile(path: "src/login.rs", status: .modified, added: 12, removed: 2)
    private let renamed = GitChangedFile(path: "src/auth.rs", oldPath: "src/session.rs", status: .renamed, added: 0, removed: 0)
    private let odd = GitChangedFile(path: "odd?name", status: .untracked, diffable: false)

    override func setUp() async throws {
        _ = NSApplication.shared
        fake = FakeBackend(extraFeatures: ["git.changes", "worktree"])
        try await fake.start()
        model = ChangesModel()
        model.backend = { [weak self] _ in self?.fake }
        model.paneGit = { [weak self] _, pane in (self?.gits[pane] != nil, self?.gits[pane]) }
        model.now = { [weak self] in self?.clock ?? Date() }
        model.isAppActive = { true }
        model.coalesce = 0.15
        model.pollsByTimer = false
        model.observe { [weak self] in self?.notes += 1 }
    }

    override func tearDown() { fake.stop() }

    private func wait(_ what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A pane in a repository at `root`, with a list of `files` and a summary that agrees.
    private func pane(root: String, files: [GitChangedFile]) async throws -> PaneID {
        let created = try await fake.createWorkspace(name: root, spawn: SpawnOptions(command: ["/bin/sleep", "60"], cwd: "/tmp"))
        let changes = GitChanges(root: root, branch: "fix", head: "a1b2c3d", uncommitted: .init(files: files, added: 12, removed: 2))
        fake.setChanges(created.pane, .success(changes))
        gits[created.pane] = PaneGit(repo: "repo", root: root, branch: "fix", head: "a1b2c3d", changes: changes.summary)
        return created.pane
    }

    private func target(_ pane: PaneID, on: Bool = true) -> ChangesModel.Target {
        ChangesModel.Target(machine: "local", machineName: "this Mac", pane: pane, git: gits[pane], featureOn: on, connected: true)
    }

    private var loaded: GitChanges? {
        if case let .loaded(changes) = model.list { return changes }
        return nil
    }

    func testNothingIsAskedWhileItIsNotVisible() async throws {
        let one = try await pane(root: "/one", files: [login])
        model.setFocused(target(one))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fake.gitChangesCalls.isEmpty, "hidden: no request")
        XCTAssertEqual(model.list, .loading)
        model.isVisible = true
        try await wait("the list") { self.loaded != nil }
        XCTAssertEqual(fake.gitChangesCalls, [one], "asked once it shows")
        XCTAssertEqual(loaded?.uncommitted.files, [login])
    }

    func testTheSummaryAloneDecidesTheEmptyStates() async throws {
        let one = try await pane(root: "/one", files: [login])
        model.isVisible = true
        model.setFocused(nil)
        XCTAssertEqual(model.list, .none)
        gits[one] = nil
        model.setFocused(target(one))
        XCTAssertEqual(model.list, .notARepo)
        gits[one] = PaneGit(repo: "repo", root: "/one", branch: "fix", changesReason: "pending")
        model.setFocused(target(one))
        XCTAssertEqual(model.list, .unknown(GitText.readingChanges, pending: true))
        gits[one] = PaneGit(repo: "repo", root: "/one", branch: "fix", changesReason: "no_git")
        model.setFocused(target(one))
        XCTAssertEqual(model.list, .unknown("Git isn't installed on this Mac.", pending: false))
        gits[one] = PaneGit(repo: "repo", root: "/one", branch: "fix", changes: PaneGit.Changes(uncommitted: .init(files: 0, added: 0, removed: 0)))
        model.setFocused(target(one))
        XCTAssertEqual(model.list, .empty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fake.gitChangesCalls.isEmpty, "none of these needs the list")
        // A machine whose daemon doesn't list changes.
        model.setFocused(target(one, on: false))
        XCTAssertEqual(model.list, .none)
    }

    func testItFollowsUntilAFileIsSelectedThenStaysOnItsWorkTree() async throws {
        let one = try await pane(root: "/one", files: [login])
        let two = try await pane(root: "/two", files: [renamed])
        let oneAgain = try await pane(root: "/one", files: [login])
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("pane one's list") { self.loaded?.root == "/one" }
        // No selection: the next focused pane is followed at once.
        model.setFocused(target(two))
        XCTAssertEqual(model.target?.pane, two)
        XCTAssertTrue(model.following)
        try await wait("pane two's list") { self.loaded?.root == "/two" }
        // A file selected: another work tree doesn't take the list away.
        model.select(renamed, group: .uncommitted)
        model.setFocused(target(one))
        XCTAssertEqual(model.target?.pane, two, "pinned")
        XCTAssertFalse(model.following)
        XCTAssertEqual(loaded?.root, "/two")
        // Nor does no repository at all, or no pane.
        gits[one] = nil
        model.setFocused(target(one))
        XCTAssertEqual(model.target?.pane, two)
        model.setFocused(nil)
        XCTAssertEqual(model.target?.pane, two)
        // Follow Pane goes back.
        gits[one] = PaneGit(repo: "repo", root: "/one", branch: "fix", head: "a1b2c3d", changes: .init(uncommitted: .init(files: 1, added: 12, removed: 2)))
        model.setFocused(target(one))
        model.followAgain()
        XCTAssertEqual(model.target?.pane, one)
        XCTAssertTrue(model.following)
        XCTAssertNil(model.selection)
        try await wait("pane one's list again") { self.loaded?.root == "/one" }
        // A pane in the same work tree never unpins: the list goes with it, the selection stays.
        model.select(login, group: .uncommitted)
        model.setFocused(target(oneAgain))
        XCTAssertEqual(model.target?.pane, oneAgain)
        XCTAssertTrue(model.following)
        XCTAssertEqual(model.selection?.path, "src/login.rs")
        // The pinned pane exits: the focused one is followed.
        model.setFocused(target(two))
        XCTAssertEqual(model.target?.pane, oneAgain, "pinned again")
        gits[oneAgain] = nil
        model.setFocused(target(two))
        XCTAssertEqual(model.target?.pane, two)
        XCTAssertNil(model.selection)
    }

    func testAReplyForAnotherPaneIsDropped() async throws {
        let one = try await pane(root: "/one", files: [login])
        let two = try await pane(root: "/two", files: [renamed])
        fake.gitDelay = 0.3
        model.isVisible = true
        model.setFocused(target(one))
        try await Task.sleep(nanoseconds: 50_000_000)
        model.setFocused(target(two))
        try await wait("pane two's list") { self.loaded != nil }
        XCTAssertEqual(loaded?.root, "/two", "pane one's reply came first and was dropped")
        XCTAssertEqual(fake.gitChangesCalls, [one, two], "one request out at a time, the newer one after it")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(loaded?.root, "/two")
    }

    func testSummaryChangesBecomeOneRead() async throws {
        let one = try await pane(root: "/one", files: [login])
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("the list") { self.loaded != nil }
        XCTAssertEqual(fake.gitChangesCalls.count, 1)
        // A commit: the counts change, then HEAD, a moment apart.
        gits[one]?.changes = PaneGit.Changes(uncommitted: .init(files: 1, added: 3, removed: 0))
        model.setFocused(target(one))
        try await Task.sleep(nanoseconds: 50_000_000)
        gits[one]?.head = "b2c3d4e"
        model.setFocused(target(one))
        // The same again changes nothing.
        model.setFocused(target(one))
        try await wait("the reload") { self.fake.gitChangesCalls.count >= 2 }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fake.gitChangesCalls.count, 2, "exactly one more read")
        // The branch's pull request changing is nothing of ours.
        gits[one]?.prReason = "none"
        model.setFocused(target(one))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.gitChangesCalls.count, 2)
    }

    func testTheDiffIsAskedWithTheOldPathAndNeverForAnUndiffableFile() async throws {
        let one = try await pane(root: "/one", files: [login, renamed, odd])
        fake.setDiff(one, path: "src/auth.rs", group: .uncommitted, .success(GitDiff(path: "src/auth.rs", oldPath: "src/session.rs", status: .renamed)))
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("the list") { self.loaded != nil }
        model.select(renamed, group: .uncommitted)
        XCTAssertEqual(model.diff, .loading)
        try await wait("the diff") { if case .loaded = self.model.diff { true } else { false } }
        XCTAssertEqual(fake.gitDiffRequests.last, FakeBackend.DiffRequest(pane: one, path: "src/auth.rs", group: .uncommitted, oldPath: "src/session.rs"))
        let asked = fake.gitDiffRequests.count
        model.select(odd, group: .uncommitted)
        XCTAssertEqual(model.diff, .undiffable)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.gitDiffRequests.count, asked, "no request for a name that can't be sent")
        XCTAssertFalse(model.pollTick(), "and no poll")
    }

    func testAFileWithNoChangesAnyMoreReloadsTheList() async throws {
        let one = try await pane(root: "/one", files: [login])
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("the list") { self.loaded != nil }
        // The file was reverted meanwhile: the fake has no diff for it and says `not_changed`.
        fake.setChanges(one, .success(GitChanges(root: "/one", uncommitted: .init(files: [renamed]))))
        model.select(login, group: .uncommitted)
        try await wait("the list read again") { self.fake.gitChangesCalls.count == 2 }
        try await wait("the file gone from it") { self.loaded?.uncommitted.files == [self.renamed] }
        XCTAssertNil(model.selection, "the selection goes with its file")
        XCTAssertEqual(model.diff, .none)
    }

    func testAnErrorIsSaidInWordsAndRefreshAsksAgain() async throws {
        let one = try await pane(root: "/one", files: [login])
        fake.setChanges(one, .failure(BackendError(code: "timeout", message: "git took too long")))
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("the error") { self.model.list == .failed("Git took too long in this repository.") }
        fake.setChanges(one, .success(GitChanges(root: "/one", uncommitted: .init(files: [login]))))
        model.refresh()
        try await wait("the list") { self.loaded != nil }
        fake.setDiff(one, path: "src/login.rs", group: .uncommitted, .failure(BackendError(code: "bad_path", message: "no")))
        model.select(login, group: .uncommitted)
        try await wait("the diff's error") { self.model.diff == .failed("Clotho can't ask for this file by its name.") }
    }

    func testThePollWaitsFiveSecondsAndTenTimesTheLastReply() async throws {
        let one = try await pane(root: "/one", files: [login])
        let diff = GitDiff(path: "src/login.rs", status: .modified, added: 12, removed: 2,
                           hunks: [.init(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [.init(kind: .context, old: 1, new: 1, text: "x")])])
        fake.setDiff(one, path: "src/login.rs", group: .uncommitted, .success(diff))
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("the list") { self.loaded != nil }
        model.select(login, group: .uncommitted)
        try await wait("the diff") { self.model.diff == .loaded(diff) }
        let asked = fake.gitDiffRequests.count
        XCTAssertEqual(model.lastDiffDuration, 0, "the injected clock didn't move")
        XCTAssertFalse(model.pollTick(), "too soon")
        clock += 4.9
        XCTAssertFalse(model.pollTick())
        clock += 0.2
        model.isAppActive = { false }
        XCTAssertFalse(model.pollTick(), "not while the app is in the back")
        model.isAppActive = { true }
        model.isVisible = false
        XCTAssertFalse(model.pollTick(), "not while hidden")
        model.isVisible = true
        try await wait("the diff asked again as it shows") { self.fake.gitDiffRequests.count == asked + 1 }
        try await wait("that reply") { self.model.nextPoll > self.clock }
        clock += 5.1
        XCTAssertTrue(model.pollTick(), "due")
        try await wait("the poll's request") { self.fake.gitDiffRequests.count == asked + 2 }
        try await wait("its reply") { self.model.nextPoll > self.clock }
        XCTAssertEqual(model.diff, .loaded(diff), "the same diff: nothing redrawn")

        // A slow repository: the reply took 2 s, so the next ask is 20 s away.
        fake.gitDelay = 0.2
        clock += 5.1
        XCTAssertTrue(model.pollTick())
        try await Task.sleep(nanoseconds: 50_000_000)
        clock += 2
        try await wait("the slow reply") { self.model.lastDiffDuration >= 2 }
        XCTAssertEqual(model.nextPoll.timeIntervalSince(clock), 20, accuracy: 0.01)
        clock += 19
        XCTAssertFalse(model.pollTick(), "ten times the last reply")
        clock += 1.1
        XCTAssertTrue(model.pollTick())
    }

    // MARK: The change token (clothod 0.1.33, `git.changes.token`)

    private let loginDiff = GitDiff(path: "src/login.rs", status: .modified, added: 12, removed: 2,
                                    hunks: [.init(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [.init(kind: .context, old: 1, new: 1, text: "x")])])

    /// A pane whose list and summary carry the token "t1", shown, with `login` selected and its diff loaded.
    private func tokenPane() async throws -> PaneID {
        let one = try await pane(root: "/one", files: [login])
        fake.setDiff(one, path: "src/login.rs", group: .uncommitted, .success(loginDiff))
        moveToken(one, to: "t1")
        model.isVisible = true
        model.setFocused(tokenTarget(one))
        try await wait("the list") { self.loaded != nil }
        model.select(login, group: .uncommitted)
        try await wait("the diff") { self.model.diff == .loaded(self.loginDiff) }
        XCTAssertEqual(model.listToken, "t1")
        XCTAssertEqual(model.diffToken, "t1")
        return one
    }

    private func tokenTarget(_ pane: PaneID) -> ChangesModel.Target {
        var target = target(pane)
        target.tokenOn = true
        return target
    }

    /// The daemon's token moves: on the list it answers with, and (with `event`) in the pane's summary.
    private func moveToken(_ pane: PaneID, to token: String, event: Bool = true) {
        fake.moveChangesToken(pane, to: token)
        if event { gits[pane]?.changes?.token = token }
    }

    private func quiet() async throws { try await Task.sleep(nanoseconds: 400_000_000) }

    func testWithTheTokenNothingIsAskedByTheClock() async throws {
        let one = try await tokenPane()
        let lists = fake.gitChangesCalls.count, diffs = fake.gitDiffRequests.count
        clock += 600
        XCTAssertFalse(model.pollTick(), "no poll with the token")
        model.setFocused(tokenTarget(one))
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists)
        XCTAssertEqual(fake.gitDiffRequests.count, diffs)
    }

    func testAnotherTokenReloadsTheListAndTheOpenDiff() async throws {
        let one = try await tokenPane()
        let lists = fake.gitChangesCalls.count, diffs = fake.gitDiffRequests.count
        // An edit that keeps every count: only the token says so.
        moveToken(one, to: "t2")
        model.setFocused(tokenTarget(one))
        try await wait("the list read again") { self.fake.gitChangesCalls.count == lists + 1 }
        try await wait("the diff asked again") { self.fake.gitDiffRequests.count == diffs + 1 }
        try await wait("the tokens held") { self.model.listToken == "t2" && self.model.diffToken == "t2" }
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists + 1, "once")
        XCTAssertEqual(fake.gitDiffRequests.count, diffs + 1, "once")
    }

    func testTheSameTokenWithOtherNewsOfThePaneAsksNothing() async throws {
        let one = try await tokenPane()
        let lists = fake.gitChangesCalls.count, diffs = fake.gitDiffRequests.count
        gits[one]?.branch = "another"
        gits[one]?.pr = .init(number: 7, state: .open, url: "https://example.invalid/7", title: "x")
        model.setFocused(tokenTarget(one))
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists)
        XCTAssertEqual(fake.gitDiffRequests.count, diffs)
    }

    /// The reply to a Refresh brings the new token before the pane's event does: the event then asks nothing.
    func testAReplyThatAlreadyHasTheNewTokenMeansNoSecondAsk() async throws {
        let one = try await tokenPane()
        moveToken(one, to: "t2", event: false)
        let lists = fake.gitChangesCalls.count, diffs = fake.gitDiffRequests.count
        model.refresh()
        try await wait("the refreshed list") { self.model.listToken == "t2" }
        try await wait("its diff") { self.fake.gitDiffRequests.count == diffs + 1 && self.model.diffToken == "t2" }
        gits[one]?.changes?.token = "t2"
        model.setFocused(tokenTarget(one))
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists + 1, "the pane's event with the same token asks nothing")
        XCTAssertEqual(fake.gitDiffRequests.count, diffs + 1)
    }

    func testTheOpenDiffAnsweringNotChangedReadsTheListOnce() async throws {
        let one = try await tokenPane()
        let lists = fake.gitChangesCalls.count
        // The file went back to what it was: the token moved, the list no longer has it.
        fake.setChanges(one, .success(GitChanges(root: "/one", uncommitted: .init(files: [renamed]), token: "t2")))
        fake.setDiffNotChanged(one, path: "src/login.rs", group: .uncommitted)
        gits[one]?.changes?.token = "t2"
        model.setFocused(tokenTarget(one))
        try await wait("the file gone from the list") { self.loaded?.uncommitted.files == [self.renamed] }
        XCTAssertNil(model.selection)
        try await quiet()
        XCTAssertLessThanOrEqual(fake.gitChangesCalls.count, lists + 2, "the list isn't read in a loop")
    }

    func testNoSummaryKeepsNothingAsToday() async throws {
        let one = try await tokenPane()
        gits[one]?.changes = nil
        gits[one]?.changesReason = "timeout"
        model.setFocused(tokenTarget(one))
        XCTAssertEqual(model.list, .unknown(GitText.reason("timeout", machine: "this Mac"), pending: false), "the reason shows, as without the token")
    }

    func testShownAgainReloadsTheListOnlyWhenTheTokenMoved() async throws {
        let one = try await tokenPane()
        model.isVisible = false
        var lists = fake.gitChangesCalls.count, diffs = fake.gitDiffRequests.count
        model.isVisible = true
        try await wait("the open diff looked at again") { self.fake.gitDiffRequests.count == diffs + 1 }
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists, "the same token: the list stays")

        model.isVisible = false
        moveToken(one, to: "t2")
        model.setFocused(tokenTarget(one))
        try await quiet()
        (lists, diffs) = (fake.gitChangesCalls.count, fake.gitDiffRequests.count)
        model.isVisible = true
        try await wait("the list read again as it shows") { self.fake.gitChangesCalls.count == lists + 1 }
        try await wait("and the diff") { self.fake.gitDiffRequests.count == diffs + 1 }
    }

    func testComingBackLooksAgainButNotWhileARequestIsOut() async throws {
        let one = try await tokenPane()
        var lists = fake.gitChangesCalls.count, diffs = fake.gitDiffRequests.count
        // The app or its window came back: the fallback for an event that never arrived.
        model.revisit()
        try await wait("the open diff asked again") { self.fake.gitDiffRequests.count == diffs + 1 }
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists, "the token is the list's: it stays")

        // The pane's token moved and its event was missed by the model (it only sees it now).
        moveToken(one, to: "t3", event: false)
        fake.gitDelay = 0.3
        (lists, diffs) = (fake.gitChangesCalls.count, fake.gitDiffRequests.count)
        model.refresh()
        model.revisit()
        model.revisit()
        try await wait("the list") { self.model.listToken == "t3" }
        try await wait("the diff after it") { self.fake.gitDiffRequests.count == diffs + 1 }
        try await quiet()
        XCTAssertEqual(fake.gitChangesCalls.count, lists + 1, "nothing more was asked while the list was out")
        fake.gitDelay = 0

        // Hidden: nothing.
        model.isVisible = false
        diffs = fake.gitDiffRequests.count
        model.revisit()
        try await quiet()
        XCTAssertEqual(fake.gitDiffRequests.count, diffs)
    }

    func testAnotherPaneClearsTheHeldTokens() async throws {
        let one = try await tokenPane()
        let two = try await pane(root: "/two", files: [renamed])
        // The first pane is gone, so nothing pins the list to it.
        gits[one] = nil
        model.setFocused(tokenTarget(two))
        XCTAssertNil(model.diffToken)
        try await wait("the other list") { self.loaded?.root == "/two" }
        XCTAssertNil(model.listToken, "that list had no token")
        XCTAssertNil(model.selection)
    }

    /// A machine without the feature polls as before, whatever tokens there are.
    func testWithoutTheFeatureATokenChangesNothing() async throws {
        let one = try await pane(root: "/one", files: [login])
        fake.setDiff(one, path: "src/login.rs", group: .uncommitted, .success(loginDiff))
        model.isVisible = true
        model.setFocused(target(one))
        try await wait("the list") { self.loaded != nil }
        model.select(login, group: .uncommitted)
        try await wait("the diff") { self.model.diff == .loaded(self.loginDiff) }
        try await wait("that reply") { self.model.nextPoll > self.clock }
        clock += 5.1
        XCTAssertTrue(model.pollTick(), "polls as today")
    }

    func testPathsStayInsideTheWorkTree() {
        XCTAssertEqual(ChangesModel.absolutePath(root: "/repo", file: login), "/repo/src/login.rs")
        XCTAssertEqual(ChangesModel.absolutePath(root: "/repo/", file: login), "/repo/src/login.rs")
        for bad in ["../etc/passwd", "a/../../b", "/etc/passwd", "", "a//b", "./a", "a/\u{1b}[31m"] {
            XCTAssertNil(ChangesModel.absolutePath(root: "/repo", file: GitChangedFile(path: bad, status: .modified)), bad)
        }
        XCTAssertNil(ChangesModel.absolutePath(root: "/repo", file: odd), "only a display form of the name")
        XCTAssertNil(ChangesModel.absolutePath(root: "repo", file: login), "the root must be absolute")
    }

    func testSummaryWords() {
        let both = PaneGit.Changes(uncommitted: .init(files: 2, added: 14, removed: 5), branch: .init(base: "main", commits: 4, files: 4, added: 114, removed: 27))
        XCTAssertEqual(ChangesModel.summary(both), "6 files vs main")
        XCTAssertEqual(ChangesModel.breakdown(both), "Uncommitted: 2 files, +14 \u{2212}5. On this branch, vs main: 4 files, +114 \u{2212}27.")
        XCTAssertEqual(ChangesModel.summary(.init(uncommitted: .init(files: 2, added: 1, removed: 0))), "2 uncommitted files")
        XCTAssertEqual(ChangesModel.summary(.init(uncommitted: .init(files: 1))), "1 uncommitted file")
        XCTAssertEqual(ChangesModel.breakdown(.init(uncommitted: .init(files: 1))), "Uncommitted: 1 file.")
    }
}
