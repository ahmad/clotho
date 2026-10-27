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

    public init(kind: String, state: State, source: String? = nil, message: String? = nil, since: Double? = nil,
                attention: Bool? = nil, session: String? = nil) {
        self.kind = kind
        self.state = state
        self.source = source
        self.message = message
        self.since = since
        self.attention = attention
        self.session = session
    }

    public var isHookSourced: Bool { source == "hook" }
    public var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }
    /// The daemon raises `attention` only on real signals (a hook-reported waiting, done or error, or a
    /// bell from a detected agent) and clears it on ack or input. A detected agent that has merely gone
    /// quiet can be "waiting" without it, and doesn't need the user.
    public var needsAttention: Bool { attention == true }

    /// Waiting without attention: detected as quiet, which may only be a slow reply or a long build.
    public var isQuiet: Bool { state == .waiting && attention != true }
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

    public init(id: PaneID, cols: Int, rows: Int, pid: Int32? = nil, command: [String]? = nil, title: String? = nil,
                cwd: String? = nil, seq: UInt64 = 0, exited: PaneExit? = nil, agent: AgentInfo? = nil) {
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
