import ClothoKit
import Foundation

// The Overview's model: one card per agent with a mark, on every machine, in three lanes (Needs you,
// Working, Done), with the filter and the grid's arrow-key moves. Nothing here draws: the view lays the
// cards out with `OverviewLayout` and fills them from `OverviewCard`.

/// What the Overview knows beyond the agents themselves: each machine's features, and each pane's git.
struct OverviewSource {
    var features: [MachineKey: Set<Hello.Feature>] = [:]
    /// The panes' git as their daemons report it. A card only shows what its machine's features allow.
    var git: [PaneKey: PaneGit] = [:]
}

/// One agent's card.
struct OverviewCard: Equatable {
    let key: PaneKey
    let lane: AgentStatusGroup
    /// Needs you holds `.needsYou` and `.error`.
    let mark: AgentMark
    /// "workspace › tab"; the pane's title, or the agent's name, for an agent outside any tab.
    let place: String
    /// "2 min" in Needs you and Working, "23 min ago" in Done; empty when the daemon gave no time.
    let age: String
    /// What the agent asks or last said. A permission ask names the tool and its input ("Allow Bash: npm test").
    let message: String?
    /// "devbox · Claude", then " · took 8 min" on a finished turn and " · muted".
    let sub: String
    /// The machine sends the last lines of the pane's screen (feature `peek`).
    let hasPeek: Bool
    /// The branch (or "@commit" when detached); nil outside a repo, or when the machine has no `git`.
    let branch: String?
    /// How much changed in the work tree, only from a machine with `git.changes`.
    let changes: PaneGit.Changes?
    let canMute: Bool
    /// The agent's attention is raised, so Resolve has something to clear.
    let canResolve: Bool
    let isMuted: Bool
    let tab: TabID?

    let machineName: String
    let workspace: String?
    let tabTitle: String?
    /// "Claude", "Codex".
    let agent: String
    /// "Claude Code": the filter matches it too.
    let agentFullName: String
    /// How long the finished turn took, as the sub line says it ("8 min"); nil when not known.
    let took: String?

    static let noRepo = "no repo"

    /// The branch as the card shows it.
    var branchText: String { branch ?? Self.noRepo }

    /// Nil for an agent with no mark (idle, resolved, settling, or muted and not running): it has no card.
    init?(_ entry: AgentEntry, source: OverviewSource = OverviewSource(), now: Date = Date()) {
        let info = entry.info
        guard let mark = info.mark, let lane = info.activeStatusGroup else { return nil }
        let key = PaneKey(machine: entry.machine, pane: entry.pane)
        let features = source.features[entry.machine] ?? []
        // The rule of `AppDelegate.git(_:in:)`: nothing of git shows against a daemon without the feature.
        let git = features.contains(.git) ? source.git[key] : nil
        self.key = key
        self.lane = lane
        self.mark = mark
        place = entry.place.isEmpty ? (entry.paneTitle ?? info.kindName) : entry.place
        let elapsed = Self.elapsed(since: info.since, now: now)
        age = lane == .done ? elapsed.map { "\($0) ago" } ?? "" : elapsed ?? ""
        let said = info.inboxText
        message = said?.isEmpty == false ? said : nil
        agent = info.shortKindName
        agentFullName = info.kindName
        took = lane == .done ? info.turnDuration.flatMap { Self.time(seconds: Int($0.rounded())) } : nil
        isMuted = info.isMuted
        sub = [entry.machineName, agent, took.map { "took \($0)" }, isMuted ? "muted" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        hasPeek = features.contains(.peek)
        branch = git?.place
        changes = features.contains(.gitChanges) ? git?.changes : nil
        canMute = entry.canMute
        canResolve = info.needsAttention
        tab = entry.tab?.id
        machineName = entry.machineName
        workspace = entry.workspace?.name
        tabTitle = entry.tabTitle
    }

    /// The buckets of `AgentMark.elapsedText`: "<1 min", "2 min", "3 h", "2 d".
    static func time(seconds: Int) -> String {
        switch max(0, seconds) {
        case ..<60: return "<1 min"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86400: return "\(seconds / 3600) h"
        default: return "\(seconds / 86400) d"
        }
    }

    /// How long ago `since` was; nil when the daemon gave no time.
    static func elapsed(since: Double?, now: Date) -> String? {
        since.map { time(seconds: Int(max(0, now.timeIntervalSince1970 - $0))) }
    }

    /// The whole card for VoiceOver, without the peek: "Needs you: clotho › alerts. Allow Bash: cargo test.
    /// devbox, Claude. Waiting 2 min. Branch main. 128 lines added, 32 removed, in 6 files."
    var spoken: String {
        var parts = ["\(mark.label): \(place)"]
        if let message { parts.append(message) }
        parts.append([machineName, agent].joined(separator: ", ") + (isMuted ? ", muted" : ""))
        if !age.isEmpty {
            switch lane {
            case .needsYou: parts.append("Waiting \(age)")
            case .working: parts.append("Working \(age)")
            case .done: parts.append(["Finished \(age)", took.map { "took \($0)" }].compactMap { $0 }.joined(separator: ", "))
            }
        }
        parts.append(branch.map { "Branch \($0)" } ?? "No repo")
        if let counts = ChangeCountText.spoken(changes) { parts.append(counts) }
        return parts.map(Self.sentence).joined(separator: " ")
    }

    /// Ends with one full stop, unless the text already ends a sentence.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }
}

enum OverviewModel {
    /// The lanes in the order they are on screen.
    static let laneOrder: [AgentStatusGroup] = [.needsYou, .working, .done]

    /// The lanes with their cards, by `AgentInbox.sections`: Needs you (failed agents with it, the longest
    /// wait first), then Working and Done (the most recent first). A lane with no card is left out, and an
    /// agent with no mark has no card.
    static func lanes(_ entries: [AgentEntry], source: OverviewSource = OverviewSource(),
                      now: Date = Date()) -> [(lane: AgentStatusGroup, cards: [OverviewCard])] {
        let sections = AgentInbox.sections(entries)
        return laneOrder.compactMap { lane in
            let members: [AgentEntry]
            switch lane {
            case .needsYou: members = sections.needsYou
            case .working: members = sections.working
            case .done: members = sections.done
            }
            let cards = members.compactMap { OverviewCard($0, source: source, now: now) }
            return cards.isEmpty ? nil : (lane, cards)
        }
    }

    /// Every lane's cards in reading order.
    static func cards(_ lanes: [(lane: AgentStatusGroup, cards: [OverviewCard])]) -> [OverviewCard] {
        lanes.flatMap(\.cards)
    }

    /// "Overview · 6 agents on 2 machines": every card (before the filter) and the machines they are on.
    static func title(cards: [OverviewCard]) -> String {
        guard !cards.isEmpty else { return "Overview · no agents" }
        let machines = Set(cards.map(\.key.machine)).count
        return "Overview · \(cards.count) \(cards.count == 1 ? "agent" : "agents") on \(machines) \(machines == 1 ? "machine" : "machines")"
    }

    /// The cards a query leaves. Its state words (`CommandBar.stateFilter`: "needs", "needs you", "working",
    /// "done") pick marks; every other word must be in the machine's, workspace's or tab's name, the branch
    /// or the agent's name, in any case. An empty query leaves every card.
    static func filter(_ cards: [OverviewCard], query: String) -> [OverviewCard] {
        let state = CommandBar.stateFilter(query)
        let words = state.rest.split(whereSeparator: \.isWhitespace)
        guard !state.marks.isEmpty || !words.isEmpty else { return cards }
        return cards.filter { card in
            guard state.marks.isEmpty || state.marks.contains(card.mark) else { return false }
            let fields = [card.machineName, card.workspace, card.tabTitle, card.branch, card.agent, card.agentFullName].compactMap { $0 }
            return words.allSatisfy { word in fields.contains { $0.range(of: word, options: .caseInsensitive) != nil } }
        }
    }

    /// The filter over lanes; a lane it empties is left out.
    static func filter(_ lanes: [(lane: AgentStatusGroup, cards: [OverviewCard])],
                       query: String) -> [(lane: AgentStatusGroup, cards: [OverviewCard])] {
        lanes.compactMap { lane in
            let cards = filter(lane.cards, query: query)
            return cards.isEmpty ? nil : (lane.lane, cards)
        }
    }

    /// The panes to peek at on each machine that can (`peek`), in id order. A machine without the feature,
    /// or with no card, isn't in the result.
    static func peekWanted(cards: [OverviewCard]) -> [MachineKey: [PaneID]] {
        Dictionary(grouping: cards.filter(\.hasPeek), by: \.key.machine)
            .mapValues { Array(Set($0.map(\.key.pane))).sorted() }
    }
}

/// The Overview's grid: each lane is a header and rows of equal cards, as many to a row as fit.
struct OverviewLayout: Equatable {
    /// Between the grid and the view's left and right edges.
    var sideInset: CGFloat = 18
    /// Between cards, across and down.
    var gap: CGFloat = 10
    /// A card is never narrower than this while more than one fits.
    var minCardWidth: CGFloat = 250
    var cardHeight: CGFloat = 132
    /// A lane's title row, above its cards.
    var headerHeight: CGFloat = 28
    /// Between a lane's last row and the next lane's header.
    var laneGap: CGFloat = 14

    enum Direction { case left, right, up, down }

    /// Where everything goes, top down (y grows downwards): a header and the card frames for each lane.
    struct Frames: Equatable {
        var headers: [CGRect]
        var cards: [[CGRect]]
        /// The content's height.
        var height: CGFloat
    }

    /// How many cards fit in a row: 4 at 1140 pt, and never fewer than one.
    func columns(width: CGFloat) -> Int {
        guard width.isFinite, minCardWidth + gap > 0 else { return 1 }
        return max(1, Int(((width - 2 * sideInset + gap) / (minCardWidth + gap)).rounded(.down)))
    }

    /// The cards share the row's width evenly, in whole points.
    func cardWidth(width: CGFloat) -> CGFloat {
        guard width.isFinite else { return minCardWidth }
        let columns = CGFloat(self.columns(width: width))
        return max(0, ((width - 2 * sideInset - gap * (columns - 1)) / columns).rounded(.down))
    }

    /// The frames for lanes of these sizes at a width.
    func frames(lanes counts: [Int], width: CGFloat) -> Frames {
        let columns = self.columns(width: width)
        let cardWidth = self.cardWidth(width: width)
        var result = Frames(headers: [], cards: [], height: 0)
        var y: CGFloat = 0
        for (lane, count) in counts.enumerated() {
            if lane > 0 { y += laneGap }
            result.headers.append(CGRect(x: sideInset, y: y, width: max(0, width - 2 * sideInset), height: headerHeight))
            y += headerHeight
            let rows = (max(0, count) + columns - 1) / columns
            result.cards.append((0..<max(0, count)).map { index in
                CGRect(x: sideInset + CGFloat(index % columns) * (cardWidth + gap),
                       y: y + CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
            })
            y += CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * gap
        }
        result.height = y
        return result
    }

    /// Where an arrow key takes the selection. `index` and the result count cards in reading order across
    /// all lanes (of the sizes in `lanes`). Left and right walk that order, over lane boundaries. Up and
    /// down go to the same column of the row above or below, also in the next lane, or to that row's last
    /// card when it is shorter. At an edge the selection stays.
    static func move(from index: Int, direction: Direction, in lanes: [Int], columns: Int) -> Int {
        let total = lanes.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return 0 }
        let index = min(max(0, index), total - 1)
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(total - 1, index + 1)
        case .up, .down:
            let rows = self.rows(lanes: lanes, columns: columns)
            guard let row = rows.firstIndex(where: { $0.contains(index) }) else { return index }
            let target = direction == .up ? row - 1 : row + 1
            guard rows.indices.contains(target) else { return index }
            return rows[target].lowerBound + min(index - rows[row].lowerBound, rows[target].count - 1)
        }
    }

    /// The grid's rows as ranges of reading-order indices: each lane starts a new row.
    static func rows(lanes: [Int], columns: Int) -> [Range<Int>] {
        let columns = max(1, columns)
        var rows: [Range<Int>] = []
        var start = 0
        for count in lanes where count > 0 {
            let end = start + count
            while start < end {
                rows.append(start..<min(end, start + columns))
                start += columns
            }
            start = end
        }
        return rows
    }

    /// The selection once the cards changed (a re-sort, a card gone, a new filter): the same pane where it
    /// is now, else the card nearest the old position, else the first. Nil when there is no card.
    static func selectionAfter(change keys: [PaneKey], selected: PaneKey?, at index: Int?) -> Int? {
        guard !keys.isEmpty else { return nil }
        if let selected, let kept = keys.firstIndex(of: selected) { return kept }
        return min(max(0, index ?? 0), keys.count - 1)
    }
}
