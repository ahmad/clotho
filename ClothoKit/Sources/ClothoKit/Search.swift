import Foundation

// Scrollback search (`pane.search`) and agent history (`agent.history`), clothod 0.1.11 (protocol.md,
// "Searching scrollback" and "Agent history").

/// A cell in snapshot coordinates: line 0 is the top screen row, negative lines are scrollback (-1 the
/// newest); col counts cells, so a wide character takes two.
public struct CellPosition: Codable, Hashable, Sendable, Comparable {
    public var line: Int
    public var col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }

    public static func < (a: CellPosition, b: CellPosition) -> Bool { (a.line, a.col) < (b.line, b.col) }
}

public struct PaneSearchOptions: Sendable, Equatable {
    /// Rust regex syntax when true; plain text otherwise.
    public var regex = false
    public var caseSensitive = false
    /// 1…1000 (the daemon's default is 100).
    public var limit: Int?
    /// Continues a search: the previous result's `next`, while `seq` is unchanged.
    public var before: CellPosition?

    public init(regex: Bool = false, caseSensitive: Bool = false, limit: Int? = nil, before: CellPosition? = nil) {
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.limit = limit
        self.before = before
    }
}

public struct PaneSearchMatch: Codable, Hashable, Sendable {
    /// Inclusive cells. A match can run over a soft wrap, onto the next line.
    public var start: CellPosition
    public var end: CellPosition
    public var text: String
    /// The whole logical line it's in (soft wraps joined).
    public var lineText: String

    enum CodingKeys: String, CodingKey { case start, end, text, lineText = "line_text" }

    public init(start: CellPosition, end: CellPosition, text: String, lineText: String) {
        self.start = start
        self.end = end
        self.text = text
        self.lineText = lineText
    }
}

public struct PaneSearchResult: Codable, Equatable, Sendable {
    /// The positions are as of this seq.
    public var seq: UInt64
    public var cols: Int
    public var rows: Int
    /// Scrollback lines the daemon holds: line -history is the oldest it can search.
    public var history: Int
    /// Newest first.
    public var matches: [PaneSearchMatch]
    /// Where to continue (as `before`), or nil once the search reached the top.
    public var next: CellPosition?

    public init(seq: UInt64, cols: Int, rows: Int, history: Int, matches: [PaneSearchMatch], next: CellPosition?) {
        self.seq = seq
        self.cols = cols
        self.rows = rows
        self.history = history
        self.matches = matches
        self.next = next
    }
}

/// One change in an agent's life, as `agent.history` records it.
public struct AgentHistoryEntry: Codable, Equatable, Sendable {
    public enum Event: String, Sendable {
        case state, attention, update, mute, unmute, gone, unknown
    }

    /// Unix time, seconds.
    public var at: Double
    public var eventName: String
    public var kind: String?
    public var stateName: String?
    public var fromName: String?
    public var message: String?
    public var session: String?
    public var pid: Int32?
    public var source: String?
    /// Detected from output rather than reported by the agent.
    public var guess: Bool?
    public var attention: Bool?
    public var muted: Bool?

    enum CodingKeys: String, CodingKey {
        case at, eventName = "event", kind, stateName = "state", fromName = "from", message, session, pid, source, guess, attention, muted
    }

    public var event: Event { Event(rawValue: eventName) ?? .unknown }
    /// The state after this entry (nil when the agent is gone).
    public var state: AgentInfo.State? { stateName.map { AgentInfo.State(rawValue: $0) ?? .unknown } }
    /// The state before it, for state changes.
    public var from: AgentInfo.State? { fromName.map { AgentInfo.State(rawValue: $0) ?? .unknown } }
    public var date: Date { Date(timeIntervalSince1970: at) }

    public init(at: Double, event: String, kind: String? = nil, state: String? = nil, from: String? = nil, message: String? = nil,
                session: String? = nil, pid: Int32? = nil, source: String? = nil, guess: Bool? = nil, attention: Bool? = nil,
                muted: Bool? = nil) {
        self.at = at
        eventName = event
        self.kind = kind
        stateName = state
        fromName = from
        self.message = message
        self.session = session
        self.pid = pid
        self.source = source
        self.guess = guess
        self.attention = attention
        self.muted = muted
    }
}

public struct AgentHistory: Codable, Equatable, Sendable {
    public var pane: PaneID
    /// How many entries the daemon keeps per pane.
    public var max: Int
    /// Oldest first.
    public var entries: [AgentHistoryEntry]

    public init(pane: PaneID, max: Int, entries: [AgentHistoryEntry]) {
        self.pane = pane
        self.max = max
        self.entries = entries
    }
}
