import Foundation

// The model clothod owns: Machine (the daemon) > Workspace > Tab > split tree > Pane.
// Shapes and JSON names follow docs/protocol.md ("Model"). IDs are integers below 2^53, stable for the
// object's life and never reused within one daemon `instance`.

public typealias WorkspaceID = UInt64
public typealias TabID = UInt64
public typealias PaneID = UInt64
public typealias SplitID = UInt64

/// `horizontal` puts `a` left of `b`; `vertical` puts `a` above `b`.
public enum Axis: String, Codable, Sendable {
    case horizontal, vertical
}

/// Where `pane.split` puts the new pane relative to the existing one.
public enum Direction: String, Codable, Sendable, CaseIterable {
    case right, down, left, up

    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    /// True when the new pane becomes `b` (right or below).
    public var newPaneIsSecond: Bool { self == .right || self == .down }
}

/// A node of a tab's split tree: `{"type": "pane", "pane"}` or `{"type": "split", "id", "axis", "ratio", "a", "b"}`.
public indirect enum Layout: Equatable, Sendable {
    case pane(PaneID)
    /// `ratio` is `a`'s share, between 0.05 and 0.95.
    case split(id: SplitID, axis: Axis, ratio: Double, a: Layout, b: Layout)

    public static let ratioRange: ClosedRange<Double> = 0.05...0.95

    /// Panes in reading order (left to right, top to bottom).
    public var panes: [PaneID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let a, let b): return a.panes + b.panes
        }
    }

    public func contains(_ pane: PaneID) -> Bool { panes.contains(pane) }
}

extension Layout: Codable {
    private enum CodingKeys: String, CodingKey { case type, pane, id, axis, ratio, a, b }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(try c.decode(PaneID.self, forKey: .pane))
        case "split":
            self = .split(id: try c.decode(SplitID.self, forKey: .id), axis: try c.decode(Axis.self, forKey: .axis),
                          ratio: try c.decode(Double.self, forKey: .ratio),
                          a: try c.decode(Layout.self, forKey: .a), b: try c.decode(Layout.self, forKey: .b))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown layout node \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id):
            try c.encode("pane", forKey: .type)
            try c.encode(id, forKey: .pane)
        case let .split(id, axis, ratio, a, b):
            try c.encode("split", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }
}

/// How a pane's process ended: `{"code": 0}` or `{"signal": 9}`.
public struct PaneExit: Codable, Equatable, Sendable {
    public var code: Int32?
    public var signal: Int32?

    public init(code: Int32? = nil, signal: Int32? = nil) {
        self.code = code
        self.signal = signal
    }
}

/// A coding agent (Claude Code, Codex, …) running in a pane, as clothod reports it in the pane's `agent`
/// field. Draft shape from clothod-80; unknown fields and states are tolerated.
public struct AgentInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case starting, running, waiting, done, error
        /// A state this client doesn't know yet.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .unknown
        }
    }

    /// "claude", "codex", …
    public var kind: String
    public var state: State
    /// "hook" when the agent reports through `clothod hooks`, otherwise detected from the terminal.
    public var source: String?
    /// What the agent says it's doing or waiting for.
    public var message: String?
    /// When the state last changed, in seconds since 1970.
    public var since: Double?
    /// True until someone acknowledges a waiting, done or error state (`agent.ack`).
    public var attention: Bool?
    /// The agent's own session id, if it has one.
    public var session: String?
    /// Muted by the user (`agent.mute`): it stays quiet, whatever it does, until unmuted or until this
    /// agent session ends. Absent means not muted.
    public var muted: Bool?
    /// The wire's `quiet`: the last rise of `attention` happened while the user was at the pane (a turn
    /// ending into `done` within 60 s of their input there). It still counts as attention (badge, Agents
    /// panel), but no notification goes out for it. Kept until the next rise. Absent (older daemons)
    /// means false. Not `isQuiet`, which is about a detected agent going quiet.
    public var quietRise: Bool?
    /// The first line of what the user typed to start this turn (at most 120 characters); nil for turns
    /// nobody typed (a peer's message, a task waking it). For done, `message` is the agent's last reply.
    public var prompt: String?
    /// The last tool the agent used this turn ("Bash"), and its key input ("npm test", a file path, a
    /// pattern; at most 160 characters). For a permission wait, what it asks to run.
    public var tool: String?
    public var toolInput: String?
    /// When this turn began, in seconds since 1970.
    public var turnStarted: Double?
    /// Permission requests the agent waits on, oldest first (`agent.decide` answers one). Absent (older
    /// daemons, Codex) means none; see `pendingRequests`.
    public var requests: [PermissionRequest]?

    enum CodingKeys: String, CodingKey {
        case kind, state, source, message, since, attention, session, muted, prompt, tool, requests
        case quietRise = "quiet"
        case toolInput = "tool_input"
        case turnStarted = "turn_started"
    }

    public init(kind: String, state: State, source: String? = nil, message: String? = nil, since: Double? = nil,
                attention: Bool? = nil, session: String? = nil, muted: Bool? = nil, quietRise: Bool? = nil,
                prompt: String? = nil, tool: String? = nil, toolInput: String? = nil, turnStarted: Double? = nil,
                requests: [PermissionRequest]? = nil) {
        self.kind = kind
        self.state = state
        self.source = source
        self.message = message
        self.since = since
        self.attention = attention
        self.session = session
        self.muted = muted
        self.quietRise = quietRise
        self.prompt = prompt
        self.tool = tool
        self.toolInput = toolInput
        self.turnStarted = turnStarted
        self.requests = requests
    }

    /// The permission requests waiting for an answer; empty when none.
    public var pendingRequests: [PermissionRequest] { requests ?? [] }

    /// How long the turn took, once it ended (done or error): `since` minus `turnStarted`.
    public var turnDuration: TimeInterval? {
        guard state == .done || state == .error, let since, let turnStarted, since >= turnStarted else { return nil }
        return since - turnStarted
    }

    public var isMuted: Bool { muted == true }
    /// Whether this attention rise was quiet (see `quietRise`).
    public var isQuietRise: Bool { quietRise == true }

    /// Whether going from `before` to this calls for a notification: attention rose (false to true) into
    /// waiting, done or error, the agent isn't muted, and the rise wasn't quiet. Banners, pushes and the
    /// Mac's notifications all follow this; badges and the Agents panel follow `needsAttention`.
    public func notifiesRise(from before: AgentInfo?) -> Bool {
        needsAttention && before?.needsAttention != true && [.waiting, .done, .error].contains(state) && !isQuietRise
    }

    public var isHookSourced: Bool { source == "hook" }
    public var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }
    /// The daemon raises `attention` only on real signals (a hook-reported waiting, done or error, or a
    /// bell from a detected agent) and clears it on ack or input. A detected agent that has merely gone
    /// quiet can be "waiting" without it, and doesn't need the user.
    /// A muted agent never needs the user, whatever its attention says.
    public var needsAttention: Bool { attention == true && !isMuted }

    /// Waiting without attention: detected as quiet, which may only be a slow reply or a long build.
    public var isQuiet: Bool { state == .waiting && !needsAttention }
}

/// A tool call an agent asks permission for (an entry of `AgentInfo.requests`).
public struct PermissionRequest: Codable, Equatable, Sendable, Identifiable {
    /// The daemon's id for this request; it only ever names this one.
    public var id: String
    /// "Bash", "Edit", …
    public var tool: String
    /// Its key input ("npm test", a file path), or nil.
    public var summary: String?

    public init(id: String, tool: String, summary: String? = nil) {
        self.id = id
        self.tool = tool
        self.summary = summary
    }

    /// "Allow Bash: npm test?"
    public var question: String {
        let input = summary.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 }
        return "Allow \(tool)" + (input.map { ": \($0)" } ?? "") + "?"
    }
}

/// An answer to a permission request (`agent.decide`).
public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

public struct Pane: Codable, Equatable, Sendable, Identifiable {
    public var id: PaneID
    /// The PTY size.
    public var cols: Int
    public var rows: Int
    public var pid: Int32?
    public var command: [String]?
    /// From OSC 0/2; nil if never set.
    public var title: String?
    /// From OSC 7, falling back to the process's cwd; nil if unknown.
    public var cwd: String?
    /// The pane's output length so far.
    public var seq: UInt64
    /// Nil while the process runs.
    public var exited: PaneExit?
    public var agent: AgentInfo?
    /// Set when the daemon brought this pane back after a restart (`restore`); nil for a normal pane, and
    /// once dismissed (`pane.dismiss_restored`, or the user's first typing in it).
    public var restored: PaneRestore?
    /// The git work tree the pane's folder is in (feature `git`); nil outside one.
    public var git: PaneGit?

    public init(id: PaneID, cols: Int, rows: Int, pid: Int32? = nil, command: [String]? = nil, title: String? = nil,
                cwd: String? = nil, seq: UInt64 = 0, exited: PaneExit? = nil, agent: AgentInfo? = nil, restored: PaneRestore? = nil,
                git: PaneGit? = nil) {
        self.id = id
        self.cols = cols
        self.rows = rows
        self.pid = pid
        self.command = command
        self.title = title
        self.cwd = cwd
        self.seq = seq
        self.exited = exited
        self.agent = agent
        self.restored = restored
        self.git = git
    }
}

/// Where a pane is in git: its repo, branch (or detached commit), linked worktree and pull request.
public struct PaneGit: Codable, Equatable, Sendable {
    /// The repo's name, shared by all its worktrees.
    public var repo: String
    /// This worktree's top-level folder.
    public var root: String?
    /// "owner/name" when origin is on GitHub.
    public var remote: String?
    /// Nil when detached; `head` says where.
    public var branch: String?
    /// The short commit; nil for an unborn branch.
    public var head: String?
    /// A linked worktree; nil for the main one.
    public var worktree: Worktree?
    public var pr: PullRequest?
    /// Why `pr` is nil: "none", "pending", "default_branch", "detached", "no_remote", "no_gh", "gh_auth",
    /// "gh_error", "timeout"; others mean unknown.
    public var prReason: String?

    public struct Worktree: Codable, Equatable, Sendable {
        /// Its dir name under .git/worktrees.
        public var name: String
        /// Its root, relative to the main worktree's (absolute when that can't be said).
        public var path: String?

        public init(name: String, path: String? = nil) {
            self.name = name
            self.path = path
        }
    }

    enum CodingKeys: String, CodingKey {
        case repo, root, remote, branch, head, worktree, pr
        case prReason = "pr_reason"
    }

    public struct PullRequest: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case open, draft, merged, closed }
        public var number: Int
        /// Unknown states read as nil, so a newer daemon's don't break decoding. "draft" wins over open.
        public var state: State?
        public var url: String?
        /// One line, at most 120 characters.
        public var title: String?

        public init(number: Int, state: State?, url: String? = nil, title: String? = nil) {
            self.number = number
            self.state = state
            self.url = url
            self.title = title
        }

        enum CodingKeys: String, CodingKey { case number, state, url, title }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(number, forKey: .number)
            try c.encodeIfPresent(state?.rawValue, forKey: .state)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encodeIfPresent(title, forKey: .title)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            number = try c.decode(Int.self, forKey: .number)
            state = (try? c.decodeIfPresent(String.self, forKey: .state)).flatMap { State(rawValue: $0) }
            url = try c.decodeIfPresent(String.self, forKey: .url)
            title = try c.decodeIfPresent(String.self, forKey: .title)
        }
    }

    public init(repo: String, root: String? = nil, remote: String? = nil, branch: String?, head: String? = nil,
                worktree: Worktree? = nil, pr: PullRequest? = nil, prReason: String? = nil) {
        self.repo = repo
        self.root = root
        self.remote = remote
        self.branch = branch
        self.head = head
        self.worktree = worktree
        self.pr = pr
        self.prReason = prReason
    }

    /// The branch, or the detached commit ("@a1b2c3d").
    public var place: String { branch ?? head.map { "@\($0)" } ?? "detached" }

    /// Compact, for a tab or a sidebar row: "main · #42".
    public var short: String { [place, pr.map { "#\($0.number)" }].compactMap { $0 }.joined(separator: " · ") }

    /// For the pane's status strip, without the PR (shown on its own): "clotho · main · fix-login".
    public var summary: String { [repo, place, worktree?.name].compactMap { $0 }.joined(separator: " · ") }

    /// What ⌘P matches and shows as a subtitle: branch, worktree and PR number ("#42").
    public var searchText: String { [place, worktree?.name, pr.map { "#\($0.number)" }].compactMap { $0 }.joined(separator: " ") }
}

/// How a pane came back after a restart: a fresh shell in its folder, and the agent conversation the
/// daemon resumed in it, if any (`claude --resume <id>` or `codex resume <id>`). `continued` (clothod
/// 0.1.25) means it had no session id to name and continued the folder's latest conversation instead.
public struct PaneRestore: Codable, Equatable, Sendable {
    /// When it was restored, unix seconds.
    public var at: Double
    /// "claude" or "codex" when a conversation was resumed.
    public var agent: String?
    public var session: String?
    /// Continued the latest conversation in the folder rather than a named session.
    public var continued: Bool

    public init(at: Double, agent: String? = nil, session: String? = nil, continued: Bool = false) {
        self.at = at
        self.agent = agent
        self.session = session
        self.continued = continued
    }

    private enum CodingKeys: String, CodingKey { case at, agent, session, continued }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Double.self, forKey: .at)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        continued = try c.decodeIfPresent(Bool.self, forKey: .continued) ?? false
    }

    /// "Restored after restart", plus "· resumed Claude session" when one was; "Continued the latest
    /// conversation in this folder" when the daemon continued one without a session to name.
    public var note: String {
        let names = ["claude": "Claude", "codex": "Codex"]
        if continued { return "Continued the latest conversation in this folder" }
        guard let agent else { return "Restored after restart" }
        return "Restored after restart · resumed \(names[agent] ?? agent) session"
    }
}

public extension Pane {
    /// The title as people should see it. Claude Code (and others) prefix their terminal title with a
    /// status glyph, "✳ Fixing tests" or a spinner frame, which is noise in a list; only that leading
    /// symbol and its space are dropped. A bare "Claude Code" says less than the folder, so that shows
    /// the cwd's name instead.
    var displayTitle: String? { Self.displayTitle(title, cwd: cwd) }

    static func displayTitle(_ title: String?, cwd: String?) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        // Nothing but a glyph is no title at all.
        if text.unicodeScalars.count == 1, isStatusGlyph(text.unicodeScalars.first!) { return nil }
        if let first = text.unicodeScalars.first, isStatusGlyph(first) {
            let rest = text.unicodeScalars.dropFirst()
            if let next = rest.first, next.properties.isWhitespace {
                text = String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
            }
        }
        if text.isEmpty { return nil }
        if text == "Claude Code", let cwd, !cwd.isEmpty, cwd != "/" { return (cwd as NSString).lastPathComponent }
        return text
    }

    /// A single symbol a program puts before its title: Claude Code's ✳ ✶ ✻ ✽ ✢, braille spinners, · and *,
    /// and other symbol characters. Never a letter, digit or ordinary punctuation like "(" or "#".
    private static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2800...0x28FF: return true                  // braille (spinners)
        case 0x2700...0x27BF, 0x2600...0x26FF: return true  // dingbats, misc symbols (✳ ✶ ✻ ✽ ✢, ★)
        case 0x25A0...0x25FF: return true                   // geometric shapes (● ◐ ▶)
        default: break
        }
        if "·*•".unicodeScalars.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .mathSymbol: return scalar.value > 0x7F
        default: return false
        }
    }
}

public struct Tab: Codable, Equatable, Sendable, Identifiable {
    public var id: TabID
    /// Nil means "show the active pane's title".
    public var title: String?
    public var activePane: PaneID
    public var layout: Layout

    enum CodingKeys: String, CodingKey { case id, title, activePane = "active_pane", layout }

    public init(id: TabID, title: String? = nil, activePane: PaneID, layout: Layout) {
        self.id = id
        self.title = title
        self.activePane = activePane
        self.layout = layout
    }
}

public struct Workspace: Codable, Equatable, Sendable, Identifiable {
    public var id: WorkspaceID
    public var name: String
    public var tabs: [Tab]
    /// The last-focused tab, which focusing the workspace returns to.
    public var activeTab: TabID?

    enum CodingKeys: String, CodingKey { case id, name, tabs, activeTab = "active_tab" }

    public init(id: WorkspaceID, name: String, tabs: [Tab], activeTab: TabID? = nil) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTab = activeTab
    }
}

/// Shared by all clients: the daemon's notion of where the user is.
public struct Focus: Codable, Equatable, Sendable {
    public var workspace: WorkspaceID?
    public var tab: TabID?
    public var pane: PaneID?

    public init(workspace: WorkspaceID? = nil, tab: TabID? = nil, pane: PaneID? = nil) {
        self.workspace = workspace
        self.tab = tab
        self.pane = pane
    }
}

/// The body of `state.get` and the `state` event.
public struct ModelState: Codable, Equatable, Sendable {
    /// Goes up by one with every model change.
    public var rev: UInt64
    public var focus: Focus
    public var workspaces: [Workspace]
    public var panes: [Pane]

    public init(rev: UInt64 = 0, focus: Focus = Focus(), workspaces: [Workspace] = [], panes: [Pane] = []) {
        self.rev = rev
        self.focus = focus
        self.workspaces = workspaces
        self.panes = panes
    }

    public func workspace(_ id: WorkspaceID?) -> Workspace? { workspaces.first { $0.id == id } }
    public func pane(_ id: PaneID?) -> Pane? { panes.first { $0.id == id } }

    public func tab(_ id: TabID?) -> Tab? {
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// The workspace and tab whose layout holds `pane`.
    public func location(of pane: PaneID) -> (workspace: Workspace, tab: Tab)? {
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.layout.contains(pane) }) { return (workspace, tab) }
        }
        return nil
    }

    public func workspace(containing tab: TabID) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.id == tab } }
    }
}
