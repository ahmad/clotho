import Foundation

// What changed in a pane's work tree (protocol.md, "Changes" and "Worktree Tabs"; feature `git.changes`
// and `worktree`, clothod 0.1.32): the two lists of files, one file's diff, the error codes, and the
// words the apps show for them, so the Mac and iOS say the same thing.

/// Which comparison a file or a diff belongs to.
public enum GitChangeGroup: String, Codable, Sendable, CaseIterable {
    /// The work tree against HEAD: staged, unstaged and untracked together.
    case uncommitted
    /// HEAD against the commit where it left the base branch.
    case branch
}

/// The `git.changes` reply: the changed files of a work tree, in two groups.
public struct GitChanges: Codable, Equatable, Sendable {
    /// The work tree's top level.
    public var root: String
    public var branch: String?
    public var head: String?
    public var uncommitted: Group
    /// Nil when there is nothing to compare; `branchReason` says why.
    public var branchChanges: BranchGroup?
    /// "no_base" (on the base branch, no base, or an unborn HEAD), "no_merge_base", or what failed
    /// ("timeout", "too_large", "partial_clone", "error"). See `GitText.branchReason`.
    public var branchReason: String?

    /// One group's files, sorted by path and cut at the request's limit. `total`, `added` and `removed`
    /// are for the whole group.
    public struct Group: Codable, Equatable, Sendable {
        public var files: [GitChangedFile]
        public var total: Int
        public var added: Int?
        public var removed: Int?
        public var truncated: Bool

        /// How many files the list leaves out.
        public var more: Int { max(total - files.count, 0) }

        public init(files: [GitChangedFile], total: Int? = nil, added: Int? = nil, removed: Int? = nil, truncated: Bool = false) {
            self.files = files
            self.total = total ?? files.count
            self.added = added
            self.removed = removed
            self.truncated = truncated
        }

        enum CodingKeys: String, CodingKey { case files, total, added, removed, truncated }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            files = try c.decodeIfPresent([GitChangedFile].self, forKey: .files) ?? []
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? files.count
            added = try c.decodeIfPresent(Int.self, forKey: .added)
            removed = try c.decodeIfPresent(Int.self, forKey: .removed)
            truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    /// The branch's group: the same, plus what it was compared with.
    public struct BranchGroup: Codable, Equatable, Sendable {
        /// The base's name to show ("origin/main").
        public var base: String
        /// The base's short sha.
        public var baseHead: String?
        /// The short sha of the commit where HEAD left the base.
        public var mergeBase: String?
        /// Commits on HEAD since then.
        public var commits: Int
        public var files: [GitChangedFile]
        public var total: Int
        public var added: Int?
        public var removed: Int?
        public var truncated: Bool

        /// How many files the list leaves out.
        public var more: Int { max(total - files.count, 0) }

        public init(base: String, baseHead: String? = nil, mergeBase: String? = nil, commits: Int, files: [GitChangedFile],
                    total: Int? = nil, added: Int? = nil, removed: Int? = nil, truncated: Bool = false) {
            self.base = base
            self.baseHead = baseHead
            self.mergeBase = mergeBase
            self.commits = commits
            self.files = files
            self.total = total ?? files.count
            self.added = added
            self.removed = removed
            self.truncated = truncated
        }

        enum CodingKeys: String, CodingKey {
            case base, baseHead = "base_head", mergeBase = "merge_base", commits, files, total, added, removed, truncated
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            base = try c.decode(String.self, forKey: .base)
            baseHead = try c.decodeIfPresent(String.self, forKey: .baseHead)
            mergeBase = try c.decodeIfPresent(String.self, forKey: .mergeBase)
            commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0
            files = try c.decodeIfPresent([GitChangedFile].self, forKey: .files) ?? []
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? files.count
            added = try c.decodeIfPresent(Int.self, forKey: .added)
            removed = try c.decodeIfPresent(Int.self, forKey: .removed)
            truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    public init(root: String, branch: String? = nil, head: String? = nil, uncommitted: Group, branchChanges: BranchGroup? = nil,
                branchReason: String? = nil) {
        self.root = root
        self.branch = branch
        self.head = head
        self.uncommitted = uncommitted
        self.branchChanges = branchChanges
        self.branchReason = branchReason
    }

    enum CodingKeys: String, CodingKey {
        case root, branch, head, uncommitted, branchChanges = "branch_changes", branchReason = "branch_reason"
    }

    /// The same counts as a pane's `git.changes` summary: the reply becomes the panes' summary on the
    /// daemon, so a list and the count beside it agree.
    public var summary: PaneGit.Changes {
        var branch: PaneGit.Changes.BranchCount?
        if let group = branchChanges {
            branch = PaneGit.Changes.BranchCount(base: group.base, commits: group.commits, files: group.total,
                                                 added: group.added, removed: group.removed)
        }
        let reason: String? = branch == nil && branchReason != "no_base" && branchReason != "no_merge_base" ? branchReason : nil
        return PaneGit.Changes(
            uncommitted: PaneGit.Changes.Count(files: uncommitted.total, added: uncommitted.added, removed: uncommitted.removed),
            branch: branch, reason: reason)
    }
}

/// One changed file in a group.
public struct GitChangedFile: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case added, modified, deleted, renamed, untracked, conflicted

        /// Never throws for a string: an unknown status reads as modified (protocol.md).
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .modified
        }

        /// The one-letter mark of a file row.
        public var letter: String {
            switch self {
            case .added: return "A"
            case .modified: return "M"
            case .deleted: return "D"
            case .renamed: return "R"
            case .untracked: return "U"
            case .conflicted: return "C"
            }
        }

        /// The same, said: for VoiceOver and tooltips.
        public var word: String {
            switch self {
            case .added: return "added"
            case .modified: return "modified"
            case .deleted: return "deleted"
            case .renamed: return "renamed"
            case .untracked: return "untracked"
            case .conflicted: return "conflicted"
            }
        }
    }

    /// Relative to the work tree's root. Exact when `diffable`; otherwise a form to show only.
    public var path: String
    /// Where a renamed file was; nil for anything else.
    public var oldPath: String?
    public var status: Status
    /// Lines; nil when they weren't counted (a binary file, or too many files).
    public var added: Int?
    public var removed: Int?
    /// Git treats it as binary (any file over 8 MiB included): there is no diff to show.
    public var binary: Bool
    /// False when the file's name can't be sent back as it is: `gitDiff` can't be asked for it.
    public var diffable: Bool

    public init(path: String, oldPath: String? = nil, status: Status, added: Int? = nil, removed: Int? = nil, binary: Bool = false,
                diffable: Bool = true) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.binary = binary
        self.diffable = diffable
    }

    enum CodingKeys: String, CodingKey { case path, oldPath = "old_path", status, added, removed, binary, diffable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .modified
        added = try c.decodeIfPresent(Int.self, forKey: .added)
        removed = try c.decodeIfPresent(Int.self, forKey: .removed)
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        diffable = try c.decodeIfPresent(Bool.self, forKey: .diffable) ?? true
    }

    /// The last path component, for a row's title.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// The `git.diff` reply: one file's diff as hunks.
public struct GitDiff: Codable, Equatable, Sendable {
    public var path: String
    public var oldPath: String?
    public var status: GitChangedFile.Status
    /// A binary file (or one over 8 MiB): no hunks.
    public var binary: Bool
    /// Cut at 1 MiB of patch or 20,000 lines: the hunks are whole lines up to there, and `added` and
    /// `removed` count only what is here.
    public var truncated: Bool
    public var added: Int
    public var removed: Int
    public var hunks: [Hunk]

    public struct Hunk: Codable, Equatable, Sendable {
        public var oldStart: Int
        public var oldLines: Int
        public var newStart: Int
        public var newLines: Int
        /// What git prints after the hunk's `@@` (usually the enclosing function), or empty.
        public var header: String
        public var lines: [Line]

        public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, header: String = "", lines: [Line]) {
            self.oldStart = oldStart
            self.oldLines = oldLines
            self.newStart = newStart
            self.newLines = newLines
            self.header = header
            self.lines = lines
        }

        enum CodingKeys: String, CodingKey {
            case oldStart = "old_start", oldLines = "old_lines", newStart = "new_start", newLines = "new_lines", header, lines
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            oldStart = try c.decodeIfPresent(Int.self, forKey: .oldStart) ?? 0
            oldLines = try c.decodeIfPresent(Int.self, forKey: .oldLines) ?? 0
            newStart = try c.decodeIfPresent(Int.self, forKey: .newStart) ?? 0
            newLines = try c.decodeIfPresent(Int.self, forKey: .newLines) ?? 0
            header = try c.decodeIfPresent(String.self, forKey: .header) ?? ""
            lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
        }

        /// The hunk for two columns, old on the left and new on the right. A run of removed lines
        /// followed by a run of added lines pairs up index by index, and what is left over of the longer
        /// run gets an empty other side. An unchanged line sits on both sides.
        public func sideBySideRows() -> [Row] {
            var rows: [Row] = []
            var index = 0
            while index < lines.count {
                if lines[index].kind == .context {
                    rows.append(Row(old: lines[index], new: lines[index]))
                    index += 1
                    continue
                }
                var removed: [Line] = [], added: [Line] = []
                while index < lines.count, lines[index].kind == .removed {
                    removed.append(lines[index])
                    index += 1
                }
                while index < lines.count, lines[index].kind == .added {
                    added.append(lines[index])
                    index += 1
                }
                for pair in 0 ..< max(removed.count, added.count) {
                    rows.append(Row(old: pair < removed.count ? removed[pair] : nil, new: pair < added.count ? added[pair] : nil))
                }
            }
            return rows
        }
    }

    public struct Line: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case context = " ", added = "+", removed = "-"

            /// Never throws for a string: an unknown type reads as an unchanged line.
            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .context
            }
        }

        public var kind: Kind
        /// Its line number in the old file; nil for an added line.
        public var old: Int?
        /// Its line number in the new file; nil for a removed line.
        public var new: Int?
        /// The line without its end. The file's own content: it may hold control characters and escape
        /// sequences, so show it through `DiffText.display`.
        public var text: String
        /// The file's last line, with no newline at its end.
        public var noNewline: Bool
        /// Cut at 2,000 characters.
        public var cut: Bool

        public init(kind: Kind, old: Int? = nil, new: Int? = nil, text: String, noNewline: Bool = false, cut: Bool = false) {
            self.kind = kind
            self.old = old
            self.new = new
            self.text = text
            self.noNewline = noNewline
            self.cut = cut
        }

        enum CodingKeys: String, CodingKey { case kind = "t", old, new, text, noNewline = "no_newline", cut }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .context
            old = try c.decodeIfPresent(Int.self, forKey: .old)
            new = try c.decodeIfPresent(Int.self, forKey: .new)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            noNewline = try c.decodeIfPresent(Bool.self, forKey: .noNewline) ?? false
            cut = try c.decodeIfPresent(Bool.self, forKey: .cut) ?? false
        }
    }

    /// One row of a side-by-side diff: the old file's line and the new file's, either of which may be
    /// missing.
    public struct Row: Equatable, Sendable {
        public var old: Line?
        public var new: Line?

        public init(old: Line?, new: Line?) {
            self.old = old
            self.new = new
        }
    }

    public init(path: String, oldPath: String? = nil, status: GitChangedFile.Status, binary: Bool = false, truncated: Bool = false,
                added: Int = 0, removed: Int = 0, hunks: [Hunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.binary = binary
        self.truncated = truncated
        self.added = added
        self.removed = removed
        self.hunks = hunks
    }

    enum CodingKeys: String, CodingKey { case path, oldPath = "old_path", status, binary, truncated, added, removed, hunks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status = try c.decodeIfPresent(GitChangedFile.Status.self, forKey: .status) ?? .modified
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        hunks = try c.decodeIfPresent([Hunk].self, forKey: .hunks) ?? []
    }
}

/// The error codes of `git.changes`, `git.diff` and a worktree create (protocol.md, "Changes" and
/// "Worktree Tabs"), from a BackendError.
public enum GitErrorCode: String, Sendable, CaseIterable {
    case notFound = "not_found", notARepo = "not_a_repo", noGit = "no_git", gitUnsupported = "git_unsupported"
    case timeout, gitFailed = "git_failed", badRequest = "bad_request", badPath = "bad_path", notChanged = "not_changed"
    case worktreeUnsupported = "worktree_unsupported", worktreeName = "worktree_name", worktreeExists = "worktree_exists"
    case branchExists = "branch_exists", badBase = "bad_base", spawnFailed = "spawn_failed"
}

public extension Error {
    /// The git or worktree error code, if this is one.
    var gitErrorCode: GitErrorCode? { (self as? BackendError).flatMap { GitErrorCode(rawValue: $0.code) } }

    /// A worktree create that failed after the worktree was made: the folder and its branch are still
    /// there, and the user must be told. True for `spawn_failed`, and for the `not_found` of a
    /// Workspace closed during the checkout, which only its message tells from a plain one.
    var worktreeLeftBehind: Bool {
        guard let error = self as? BackendError else { return false }
        switch GitErrorCode(rawValue: error.code) {
        case .spawnFailed: return true
        case .notFound: return error.message.contains(GitText.leftBehindMark)
        default: return false
        }
    }
}

/// The plain words for git's reasons and errors. `machine` is the caller's name for the machine ("this
/// Mac", "devbox").
public enum GitText {
    /// How the daemon ends the message of an error that left a worktree behind:
    /// "(the worktree <path> on the new branch <branch> was created and is still there)".
    static let leftBehindMark = "was created and is still there"

    public static let readingChanges = "Reading changes…"
    public static let unreadable = "Couldn't read the changes."

    /// Why a pane's `changes` is nil (`PaneGit.changesReason`).
    public static func reason(_ changesReason: String?, machine: String) -> String {
        switch changesReason ?? "" {
        case "pending": return readingChanges
        case "no_git": return "Git isn't installed on \(machine)."
        case "git_unsupported": return "The git on \(machine) is older than 2.31, or this repository keeps its refs in a reftable."
        case "unsafe": return "Git refuses this repository because another user owns it."
        case "timeout": return "Git took too long in this repository."
        case "too_large": return "There are too many changed files to list."
        case "partial_clone":
            return "This is a partial clone, and the comparison needs objects it doesn't have. Clotho never fetches them."
        default: return unreadable
        }
    }

    /// Why there is no branch group although there could be one (`GitChanges.branchReason`, or a
    /// summary's `reason`). Nil when there is nothing to say: no reason, or "no_base" (the pane is on
    /// the base branch, or the repository has none).
    public static func branchReason(_ reason: String?) -> String? {
        guard let reason, reason != "no_base" else { return nil }
        if reason == "no_merge_base" { return "This branch shares no history with the base branch." }
        // What failed: the same words as for the whole summary. No machine is named by these.
        let known = ["timeout", "too_large", "partial_clone"].contains(reason)
        return GitText.reason(known ? reason : "error", machine: "this machine")
    }

    /// A failed `gitChanges` or `gitDiff`.
    public static func diffError(_ error: Error, machine: String) -> String {
        if (error as? BackendError)?.code == "disconnected" { return "Not connected to \(machine)." }
        switch error.gitErrorCode {
        case .notARepo: return "This pane isn't in a git repository."
        case .notChanged: return "This file has no changes any more."
        case .badPath: return "Clotho can't ask for this file by its name."
        case .noGit: return reason("no_git", machine: machine)
        case .gitUnsupported: return reason("git_unsupported", machine: machine)
        case .timeout: return reason("timeout", machine: machine)
        default: return unreadable
        }
    }

    /// A failed worktree create (`createTab(in:spawn:worktree:)`). After an error that left the
    /// worktree behind it says so and names the folder.
    public static func worktreeError(_ error: Error, machine: String = "this machine") -> String {
        let message = clean((error as? BackendError)?.message ?? error.localizedDescription)
        if error.worktreeLeftBehind {
            let (why, path) = leftBehind(message)
            let place = path.map { " (\($0))" } ?? ""
            return "The worktree was created and is still there\(place), but its Tab couldn't be opened: \(sentence(why))"
        }
        if (error as? BackendError)?.code == "disconnected" { return "Not connected to \(machine)." }
        switch error.gitErrorCode {
        case .worktreeExists: return "A file or folder is already there: \(sentence(message))"
        case .branchExists: return "A branch with that name already exists."
        case .worktreeName: return "A name is 1 to 100 letters, digits, '.', '_', '-' or '/', and must be a valid branch name."
        case .badBase: return sentence(message)
        case .worktreeUnsupported: return "This repository has no main work tree to put a worktree beside."
        case .notARepo: return "That folder isn't in a git repository."
        case .noGit: return reason("no_git", machine: machine)
        case .gitUnsupported: return reason("git_unsupported", machine: machine)
        case .timeout: return "Git took too long, so no worktree was made."
        case .gitFailed: return "Git couldn't make the worktree: \(sentence(message))"
        case .notFound: return "The Workspace is gone, so no worktree was made."
        default: return "Couldn't make the worktree: \(sentence(message))"
        }
    }

    /// Splits a left-behind message into what went wrong and the worktree's folder (nil when the
    /// message doesn't have the daemon's form).
    static func leftBehind(_ message: String) -> (why: String, path: String?) {
        let opening = "(the worktree ", middle = " on the new branch "
        guard let start = message.range(of: opening, options: .backwards),
              let end = message.range(of: middle, options: .backwards, range: start.upperBound ..< message.endIndex) else {
            return (message, nil)
        }
        let why = message[..<start.lowerBound].trimmingCharacters(in: .whitespaces)
        return (why.isEmpty ? "the pane couldn't be started" : why, String(message[start.upperBound ..< end.lowerBound]))
    }

    /// A daemon message is shown inside ours: one line, nothing invisible.
    private static func clean(_ message: String) -> String {
        DiffText.display(message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
    }

    /// Ends with one full stop.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return "unknown error." }
        return ".!?".contains(last) ? text : text + "."
    }
}

/// How the apps write a count of changes, on the pane's strip and for VoiceOver.
public enum ChangeCountText {
    /// "+128 −32" (a real minus sign, U+2212), or nil when the lines weren't counted.
    public static func lines(added: Int?, removed: Int?) -> String? {
        guard let added, let removed else { return nil }
        return "+\(added) \u{2212}\(removed)"
    }

    /// "1 file", "6 files".
    public static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    /// Both groups together, for the pane's strip: "+128 −32 · 6 files", "6 files" when the lines
    /// weren't counted, nil when nothing changed (or nothing is known).
    public static func strip(_ changes: PaneGit.Changes?) -> String? {
        guard let total = changes?.total, total.files > 0 else { return nil }
        return [lines(added: total.added, removed: total.removed), files(total.files)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The same, said: "128 lines added, 32 removed, in 6 files", or "6 files changed" when the lines
    /// weren't counted. Nil when nothing changed (or nothing is known).
    public static func spoken(_ changes: PaneGit.Changes?) -> String? {
        guard let total = changes?.total, total.files > 0 else { return nil }
        guard let added = total.added, let removed = total.removed else { return "\(files(total.files)) changed" }
        return "\(added) \(added == 1 ? "line" : "lines") added, \(removed) removed, in \(files(total.files))"
    }
}
