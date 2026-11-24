import AppKit
import ClothoKit

// What the Changes view and the centre diff show (clothod 0.1.32, feature `git.changes`): the work tree
// of one pane, its two lists of changed files, the selected file and its diff. One per window.
//
// It follows the focused pane the way Files does. With no file selected, a new focused pane is followed
// at once. With a file selected it stays on that work tree when the focus moves to another (or to no
// repository), and the view offers "Follow Pane"; a pane in the same work tree never unpins it.
//
// Replies come back in any order, so every fetch carries the epoch of its target and a reply for an
// older one is dropped. At most one list request and one diff request are out at a time; a newer need
// waits for the one in flight. The list is read again when the pane's summary or HEAD changes (a commit
// sends two events a second apart: they become one read). An edit that keeps the counts sends no event,
// so the selected file's diff is asked again every few seconds while it shows, and never sooner than
// ten times what the last reply took: a slow repository isn't run in a loop. Nothing is asked while
// neither view shows.

@MainActor
final class ChangesModel {
    /// The pane whose work tree is listed.
    struct Target: Equatable {
        var machine: MachineKey
        /// The machine as the user knows it, for the words ("Git isn't installed on devbox.").
        var machineName: String
        var pane: PaneID
        var git: PaneGit?
        /// The machine's daemon lists changes (`git.changes`).
        var featureOn: Bool
        var connected: Bool
    }

    enum ListState: Equatable {
        /// No pane, or a machine that can't list changes.
        case none
        case notARepo
        /// The summary isn't known: the reason's words, and whether it is still being read.
        case unknown(String, pending: Bool)
        case empty
        case loading
        case loaded(GitChanges)
        case failed(String)
    }

    enum DiffState: Equatable {
        case none
        case loading
        case loaded(GitDiff)
        case failed(String)
        /// A file whose name can't be sent back (`diffable: false`): never asked for.
        case undiffable
    }

    struct Selection: Equatable {
        var group: GitChangeGroup
        var path: String
        var oldPath: String?
    }

    private(set) var target: Target?
    /// The focused pane, as last told; the target unless pinned elsewhere.
    private(set) var focused: Target?
    private(set) var list = ListState.none
    private(set) var selection: Selection?
    private(set) var diff = DiffState.none
    /// False while the list stays on a work tree the focused pane isn't in.
    var following: Bool { target?.machine == focused?.machine && target?.pane == focused?.pane }

    /// The backend of a machine, and a pane's git there (nil once the pane is gone).
    var backend: (MachineKey) -> SessionBackend? = { _ in nil }
    var paneGit: (MachineKey, PaneID) -> (exists: Bool, git: PaneGit?) = { _, _ in (false, nil) }
    var now: () -> Date = Date.init
    var isAppActive: () -> Bool = { NSApp.isActive }
    /// The seconds between two asks for the selected file's diff, at least.
    var pollInterval: TimeInterval = 5
    /// Off in tests, which call `pollTick` themselves.
    var pollsByTimer = true
    /// How long summary changes are gathered before the list is read again.
    var coalesce: TimeInterval = 0.3

    private var observers: [() -> Void] = []
    /// Called after every change of what there is to show.
    func observe(_ observer: @escaping () -> Void) { observers.append(observer) }
    private func changed() { observers.forEach { $0() } }

    /// Whether the Changes view or the centre diff shows. Nothing is fetched otherwise; what was missed
    /// is fetched when one shows again.
    var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible {
                if listStale { reloadList() } else if selection != nil { reloadDiff(quiet: true) }
                startPolling()
            } else {
                pollTimer?.invalidate()
                pollTimer = nil
            }
        }
    }

    /// Bumped whenever the target's pane changes: replies from before are dropped.
    private var epoch = 0
    private var listInFlight = false
    private var listQueued = false
    private var listStale = false
    private var diffInFlight = false
    private var diffQueued = false
    private var coalescing: DispatchWorkItem?
    private var pollTimer: Timer?
    private(set) var lastDiffDuration: TimeInterval = 0
    private var lastDiffReply = Date.distantPast
    /// The diff counts that last sent the list for a reload, so a list and a diff that disagree for good
    /// (it happens with filters) don't go round.
    private var lastMismatch: String?

    // MARK: The target

    /// The focused pane now (every sync; cheap when nothing moved). Nil: no pane.
    func setFocused(_ new: Target?) {
        let wasFollowing = following
        let before = target
        defer {
            // Pinned or let go without the target itself changing: the view's Follow Pane comes or goes.
            if following != wasFollowing, target == before { changed() }
        }
        focused = new
        var next = new
        if let current = target, selection != nil, current.machine != new?.machine || current.pane != new?.pane {
            let sameTree = new != nil && current.machine == new?.machine && current.git?.root != nil && current.git?.root == new?.git?.root
            let there = paneGit(current.machine, current.pane)
            if !sameTree, there.exists {
                // Pinned: the list stays on its work tree, with that pane's own news.
                next = current
                next?.git = there.git
                if current.machine == new?.machine, let new {
                    next?.connected = new.connected
                    next?.featureOn = new.featureOn
                }
            }
        }
        apply(next)
    }

    /// "Follow Pane": back to the focused pane's work tree.
    func followAgain() {
        selection = nil
        diff = .none
        apply(focused)
        changed()
    }

    private func apply(_ new: Target?) {
        let old = target
        guard new != old else { return }
        target = new
        let moved = old?.machine != new?.machine || old?.pane != new?.pane
        if moved {
            epoch += 1
            let sameTree = old?.machine == new?.machine && old?.git?.root != nil && old?.git?.root == new?.git?.root
            if !sameTree {
                selection = nil
                diff = .none
                list = .none
            }
            coalescing?.cancel()
            resolve(reload: .now)
        } else if old?.git?.changes != new?.git?.changes || old?.git?.head != new?.git?.head || old?.git?.changesReason != new?.git?.changesReason
            || old?.git?.root != new?.git?.root {
            resolve(reload: .soon)
        } else if old?.connected != new?.connected || old?.featureOn != new?.featureOn {
            resolve(reload: .now)
        } else {
            // The branch, a pull request: nothing of ours.
            return
        }
        changed()
    }

    private enum Reload { case now, soon }

    /// What the target's summary alone says, and whether the list has to be read.
    private func resolve(reload: Reload) {
        guard let target, target.featureOn else { return clear(.none) }
        guard let git = target.git else { return clear(.notARepo) }
        guard let changes = git.changes else {
            let pending = git.changesReason == "pending" || git.changesReason == nil
            return clear(.unknown(GitText.reason(git.changesReason ?? "pending", machine: target.machineName), pending: pending))
        }
        guard !changes.isEmpty else { return clear(.empty) }
        switch list {
        case .loaded, .loading: break
        default: list = .loading
        }
        switch reload {
        case .now: reloadList()
        case .soon:
            coalescing?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadList() }
            coalescing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + coalesce, execute: work)
        }
    }

    private func clear(_ state: ListState) {
        coalescing?.cancel()
        list = state
        selection = nil
        diff = .none
        listStale = false
    }

    // MARK: The list

    /// The Refresh button: the list, then the selected file's diff.
    func refresh() {
        guard let target, target.featureOn, target.git != nil else { return }
        if case .loaded = list {} else { list = .loading }
        reloadList()
        changed()
    }

    private func reloadList() {
        coalescing?.cancel()
        coalescing = nil
        guard let target, target.featureOn, target.git != nil else { return }
        guard isVisible else { return listStale = true }
        guard !listInFlight else { return listQueued = true }
        guard let backend = backend(target.machine) else {
            list = .failed(GitText.diffError(BackendError(code: "disconnected", message: ""), machine: target.machineName))
            return changed()
        }
        listStale = false
        listInFlight = true
        let asked = epoch
        let pane = target.pane
        let machine = target.machineName
        Task { @MainActor [weak self] in
            let result: Result<GitChanges, Error>
            do { result = .success(try await backend.gitChanges(pane, limit: nil)) } catch { result = .failure(error) }
            guard let self else { return }
            listInFlight = false
            if asked == epoch { gotList(result, machine: machine) }
            if listQueued || asked != epoch {
                listQueued = false
                reloadList()
            }
        }
    }

    private func gotList(_ result: Result<GitChanges, Error>, machine: String) {
        switch result {
        case let .success(changes):
            list = .loaded(changes)
            if let selection {
                if let file = Self.file(selection, in: changes) {
                    self.selection = Selection(group: selection.group, path: file.path, oldPath: file.oldPath)
                    if file.diffable { reloadDiff(quiet: true) } else { diff = .undiffable }
                } else {
                    self.selection = nil
                    diff = .none
                }
            }
        case let .failure(error):
            // The summary is the newer word when it says there is nothing to list.
            if error.gitErrorCode == .notARepo { clear(.notARepo) } else { list = .failed(GitText.diffError(error, machine: machine)) }
        }
        changed()
    }

    static func file(_ selection: Selection, in changes: GitChanges) -> GitChangedFile? {
        let files = selection.group == .uncommitted ? changes.uncommitted.files : changes.branchChanges?.files ?? []
        return files.first { $0.path == selection.path }
    }

    /// The selected file's row in the list.
    var selectedFile: GitChangedFile? {
        guard let selection, case let .loaded(changes) = list else { return nil }
        return Self.file(selection, in: changes)
    }

    /// Every file listed, top to bottom, with its group.
    var files: [(file: GitChangedFile, group: GitChangeGroup)] {
        guard case let .loaded(changes) = list else { return [] }
        return changes.uncommitted.files.map { ($0, .uncommitted) } + (changes.branchChanges?.files ?? []).map { ($0, .branch) }
    }

    // MARK: The selection and its diff

    func select(_ file: GitChangedFile?, group: GitChangeGroup) {
        guard let file else {
            guard selection != nil else { return }
            selection = nil
            diff = .none
            // Nothing holds the list on its work tree any more.
            if !following { apply(focused) }
            return changed()
        }
        let new = Selection(group: group, path: file.path, oldPath: file.oldPath)
        guard new != selection else { return }
        selection = new
        lastMismatch = nil
        if file.diffable {
            diff = .loading
            reloadDiff(quiet: false)
        } else {
            diff = .undiffable
        }
        startPolling()
        changed()
    }

    /// The file `by` rows from the selected one (the centre diff's ↑ and ↓).
    func step(by: Int) {
        let all = files
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.group == selection?.group && $0.file.path == selection?.path }
        let next = min(max((index ?? -1) + by, 0), all.count - 1)
        select(all[next].file, group: all[next].group)
    }

    private func reloadDiff(quiet: Bool) {
        guard let target, let selection, isVisible, selectedFile?.diffable != false else { return }
        guard !diffInFlight else { return diffQueued = true }
        guard let backend = backend(target.machine) else {
            diff = .failed(GitText.diffError(BackendError(code: "disconnected", message: ""), machine: target.machineName))
            return changed()
        }
        diffInFlight = true
        let asked = (epoch, selection)
        let started = now()
        let machine = target.machineName
        let pane = target.pane
        Task { @MainActor [weak self] in
            let result: Result<GitDiff, Error>
            do {
                result = .success(try await backend.gitDiff(pane, path: selection.path, group: selection.group, oldPath: selection.oldPath, context: nil))
            } catch { result = .failure(error) }
            guard let self else { return }
            diffInFlight = false
            lastDiffReply = now()
            lastDiffDuration = max(0, lastDiffReply.timeIntervalSince(started))
            if asked.0 == epoch, asked.1 == self.selection { gotDiff(result, machine: machine) }
            if diffQueued || asked.1 != self.selection {
                diffQueued = false
                reloadDiff(quiet: asked.1 == self.selection)
            }
        }
    }

    private func gotDiff(_ result: Result<GitDiff, Error>, machine: String) {
        switch result {
        case let .success(new):
            let before = diff
            diff = .loaded(new)
            // The file changed since the list was read: its row's counts are old, and so may others be.
            if !new.truncated, !new.binary, let file = selectedFile, let added = file.added, let removed = file.removed,
               added != new.added || removed != new.removed {
                let mismatch = "\(selection?.group.rawValue ?? "")|\(new.path)|\(new.added)|\(new.removed)"
                if mismatch != lastMismatch {
                    lastMismatch = mismatch
                    reloadList()
                }
            }
            if before == diff { return }
        case let .failure(error):
            diff = .failed(GitText.diffError(error, machine: machine))
            // The file isn't changed any more: the list is old. Once per answer, so a list and a diff
            // that keep disagreeing don't send each other round.
            let gone = "gone|\(selection?.group.rawValue ?? "")|\(selection?.path ?? "")"
            if error.gitErrorCode == .notChanged, gone != lastMismatch {
                lastMismatch = gone
                reloadList()
            }
        }
        changed()
    }

    // MARK: Polling the selected file

    private func startPolling() {
        guard isVisible, pollTimer == nil, pollsByTimer else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.pollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// When the selected file's diff may next be asked for by the clock: `pollInterval` after the last
    /// reply, and no sooner than ten times what that reply took.
    var nextPoll: Date { lastDiffReply.addingTimeInterval(max(pollInterval, lastDiffDuration * 10)) }

    /// Asks for the selected file's diff again when it's due. Returns whether it asked (tests).
    @discardableResult
    func pollTick() -> Bool {
        guard isVisible, isAppActive(), selection != nil, selectedFile?.diffable == true, !diffInFlight, now() >= nextPoll else { return false }
        if case .loading = diff { return false }
        reloadDiff(quiet: true)
        return true
    }

    // MARK: Paths

    /// The file's full path on its machine: the root, then the path, joined as text. Nil for anything
    /// that could leave the work tree (an absolute path, a `..` or empty component) or that Clotho only
    /// has a display form of.
    static func absolutePath(root: String, file: GitChangedFile) -> String? {
        guard file.diffable, root.hasPrefix("/"), !file.path.isEmpty, !file.path.hasPrefix("/") else { return nil }
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return nil }
        guard !file.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return (root.hasSuffix("/") ? root : root + "/") + file.path
    }

    /// The summary line: "6 files vs main" with a branch group, else "2 uncommitted files".
    static func summary(_ changes: PaneGit.Changes) -> String {
        if let branch = changes.branch { return "\(ChangeCountText.files(changes.total.files)) vs \(DiffText.display(branch.base))" }
        return changes.uncommitted.files == 1 ? "1 uncommitted file" : "\(changes.uncommitted.files) uncommitted files"
    }

    /// The same per group, for the tooltip and VoiceOver: "Uncommitted: 2 files, +14 −5. On this branch,
    /// vs main: 4 files, +114 −27."
    static func breakdown(_ changes: PaneGit.Changes) -> String {
        func count(_ files: Int, _ added: Int?, _ removed: Int?) -> String {
            [ChangeCountText.files(files), ChangeCountText.lines(added: added, removed: removed)].compactMap { $0 }.joined(separator: ", ")
        }
        var parts = ["Uncommitted: \(count(changes.uncommitted.files, changes.uncommitted.added, changes.uncommitted.removed))"]
        if let branch = changes.branch {
            parts.append("On this branch, vs \(DiffText.display(branch.base)): \(count(branch.files, branch.added, branch.removed))")
        }
        return parts.joined(separator: ". ") + "."
    }
}
