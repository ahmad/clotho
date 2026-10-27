import Foundation

/// Fuzzy matching for quick open: the query's characters must appear in order (case-insensitive), and
/// matches score higher at the start, at word starts and in runs. Both apps rank with this, so results
/// come in the same order everywhere.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public var score: Int
        /// Positions in the text (Character offsets) that matched, for highlighting.
        public var indices: [Int]
    }

    static let startBonus = 12
    static let boundaryBonus = 8
    static let runBonus = 6
    static let gapPenalty = 1
    static let maxGapPenalty = 4

    /// The best way `query` matches `text`, or nil if it doesn't. An empty query matches with score 0.
    public static func match(_ query: String, in text: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let original = Array(text)
        let hay = original.map { Character($0.lowercased()) }
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        guard needle.count <= hay.count else { return nil }

        // A word starts at the beginning, after a separator, or at a lower-to-upper case change.
        let separators: Set<Character> = [" ", "-", "_", "/", ".", ":", "@", "(", "["]
        let boundary: [Bool] = original.indices.map { j in
            j == 0 || separators.contains(original[j - 1]) || (original[j - 1].isLowercase && original[j].isUppercase)
        }

        // best[i][j]: the best score with needle[i] matched at hay[j]; from[i][j]: where needle[i-1] was.
        let unset = Int.min / 2
        var best = Array(repeating: Array(repeating: unset, count: hay.count), count: needle.count)
        var from = Array(repeating: Array(repeating: -1, count: hay.count), count: needle.count)
        for i in needle.indices {
            for j in hay.indices where hay[j] == needle[i] {
                var bonus = 1
                if j == 0 { bonus += startBonus }
                if boundary[j] { bonus += boundaryBonus }
                if i == 0 {
                    best[i][j] = bonus - min(j, maxGapPenalty) * gapPenalty
                    continue
                }
                for k in stride(from: j - 1, through: i - 1, by: -1) where best[i - 1][k] > unset {
                    let gap = j - k - 1
                    let score = best[i - 1][k] + bonus + (gap == 0 ? runBonus : -min(gap, maxGapPenalty) * gapPenalty)
                    if score > best[i][j] {
                        best[i][j] = score
                        from[i][j] = k
                    }
                }
            }
        }
        let last = needle.count - 1
        guard let end = hay.indices.max(by: { best[last][$0] < best[last][$1] }), best[last][end] > unset else { return nil }
        var indices = [end]
        var j = end
        for i in stride(from: last, to: 0, by: -1) {
            j = from[i][j]
            indices.insert(j, at: 0)
        }
        // Shorter texts win ties: "api" over "api-gateway-old" for "api".
        return Match(score: best[last][end] - hay.count / 8, indices: indices)
    }
}

/// Something quick open can jump to.
public struct QuickOpenItem: Hashable, Sendable {
    /// Also the tie-break order: agents first, then workspaces, tabs and machines.
    public enum Kind: Int, Comparable, Sendable {
        case agent, workspace, tab, machine
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    /// What's matched and shown, such as a workspace's name.
    public var title: String
    /// Where it is, such as "devbox" or "devbox › api"; matched too, but worth less.
    public var subtitle: String
    /// The caller's identifier for jumping to it.
    public var id: String

    public init(kind: Kind, title: String, subtitle: String = "", id: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.id = id
    }
}

public enum QuickOpen {
    public struct Result: Hashable, Sendable {
        public var item: QuickOpenItem
        public var score: Int
        /// Matched positions in `item.title` (empty when only the subtitle matched).
        public var titleIndices: [Int]
    }

    /// Matching only through the subtitle (a machine's name for its tabs) costs this much.
    static let subtitlePenalty = 20

    /// The items that match `query`, best first. With an empty query, all of them in the order given
    /// (callers pass most recent first). Equal scores keep kind order, then the order given.
    public static func rank(_ items: [QuickOpenItem], query: String, limit: Int = 50) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return items.prefix(limit).map { Result(item: $0, score: 0, titleIndices: []) }
        }
        var scored: [(result: Result, order: Int)] = []
        for (order, item) in items.enumerated() {
            if let match = FuzzyMatch.match(trimmed, in: item.title) {
                scored.append((Result(item: item, score: match.score, titleIndices: match.indices), order))
            } else if !item.subtitle.isEmpty, let match = FuzzyMatch.match(trimmed, in: item.subtitle + " " + item.title) {
                // "bb api" finds devbox's api workspace; highlight what landed in the title.
                let offset = item.subtitle.count + 1
                let inTitle = match.indices.filter { $0 >= offset }.map { $0 - offset }
                scored.append((Result(item: item, score: match.score - subtitlePenalty, titleIndices: inTitle), order))
            }
        }
        scored.sort {
            if $0.result.score != $1.result.score { return $0.result.score > $1.result.score }
            if $0.result.item.kind != $1.result.item.kind { return $0.result.item.kind < $1.result.item.kind }
            return $0.order < $1.order
        }
        return scored.prefix(limit).map(\.result)
    }
}
