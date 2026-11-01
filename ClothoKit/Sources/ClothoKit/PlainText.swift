import Foundation

/// Agents write Markdown; notifications, the Live Activity and one-line rows show plain text. This turns
/// a Claude or Codex reply into clean text: no `**`, backticks, `#` or link syntax, list items as "• ",
/// code kept as its text, HTML entities unescaped, blank lines and runs of spaces collapsed. One line
/// per block, joined with "\n"; `AgentNotice.clip` and `oneLine` flatten it further where needed.
public enum PlainText {
    /// `markdown` as plain text (see the type's comment).
    public static func fromMarkdown(_ markdown: String) -> String {
        var lines: [String] = []
        var fence: Substring?
        var lastBlank = true
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // ``` or ~~~ fences: the code's text stays, as it is, without the fence lines.
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil; continue }
                let code = String(raw).trimmingCharacters(in: .whitespaces)
                if !code.isEmpty { lines.append(code); lastBlank = false }
                continue
            }
            if let marker = fenceMarker(trimmed) { fence = marker; continue }
            guard let line = block(trimmed) else {
                if !lastBlank { lastBlank = true }
                continue
            }
            let text = collapse(entities(inline(line)))
            if text.isEmpty { continue }
            lines.append(text)
            lastBlank = false
        }
        return lines.joined(separator: "\n")
    }

    /// `fromMarkdown` on one line: blocks joined with spaces.
    public static func oneLine(_ markdown: String) -> String {
        fromMarkdown(markdown).split(separator: "\n").joined(separator: " ")
    }

    // MARK: Blocks

    private static func fenceMarker(_ line: String) -> Substring? {
        for mark in ["```", "~~~"] where line.hasPrefix(mark) {
            let run = line.prefix { $0 == mark.first }
            return run
        }
        return nil
    }

    /// One line's block syntax: headings, quotes, list markers, rules and table separators. Nil for a
    /// line with nothing left (blank, a rule).
    private static func block(_ line: String) -> String? {
        var line = line
        if line.isEmpty { return nil }
        // Blockquotes, nested too: "> > text".
        while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if line.isEmpty { return nil }
        // Rules: ---, ***, ___ (3 or more, spaces allowed).
        let compact = line.filter { $0 != " " }
        if compact.count >= 3, let first = compact.first, "-*_".contains(first), compact.allSatisfy({ $0 == first }) { return nil }
        // Headings: "## Title ##".
        if let groups = match(#"^#{1,6}(?:\s+(.*?))?(?:\s+#+)?\s*$"#, line) {
            let title = groups[1] ?? ""
            return title.isEmpty ? nil : title
        }
        // Tables: separator rows go, cells join with " · ".
        if line.hasPrefix("|") {
            if match(#"^[\s:\-|]+$"#, line) != nil { return nil }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return cells.joined(separator: " · ")
        }
        // Lists: "- ", "* ", "+ " become "• "; task boxes go; numbered items keep their number.
        if let groups = match(#"^[-*+]\s+(?:\[[ xX]\]\s+)?(.*)$"#, line) { return "• " + (groups[1] ?? "") }
        if let groups = match(#"^(\d{1,3})[.)]\s+(.*)$"#, line) { return "\(groups[1] ?? ""). " + (groups[2] ?? "") }
        return line
    }

    // MARK: Inline

    /// Code spans, links, images, emphasis and escapes. Code spans are set aside first, so what's in
    /// them stays as written.
    private static func inline(_ text: String) -> String {
        var spans: [String] = []
        // `code`, ``code with ` inside``.
        var line = replace(#"(`+)(.+?)\1"#, in: text) { groups in
            spans.append((groups[2] ?? "").trimmingCharacters(in: .whitespaces))
            return "\u{E000}\(spans.count - 1)\u{E001}"
        }
        let rules: [(String, String)] = [
            // Images and links keep their text: ![alt](url), [text](url "title"), [text][ref].
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
            // Autolinks: <https://…> → the address.
            (#"<((?:https?|mailto):[^>\s]+)>"#, "$1"),
            // Simple HTML tags (<br>, <b>, </details>…).
            (#"</?[a-zA-Z][a-zA-Z0-9]*(?:\s[^<>]*)?/?>"#, " "),
            // Emphasis: ***x***, **x**, __x__, *x*, _x_ (underscores only at word edges, so snake_case
            // stays; a lone * between digits stays too), ~~x~~.
            (#"\*\*\*(\S(?:.*?\S)?)\*\*\*"#, "$1"),
            (#"\*\*(\S(?:.*?\S)?)\*\*"#, "$1"),
            (#"(?<![\w\\])__(\S(?:.*?\S)?)__(?!\w)"#, "$1"),
            (#"(?<![\w*\\])\*(\S(?:.*?\S)?)\*(?![\w*])"#, "$1"),
            (#"(?<![\w\\])_(\S(?:.*?\S)?)_(?!\w)"#, "$1"),
            (#"~~(\S(?:.*?\S)?)~~"#, "$1"),
            // Backslash escapes: \* \_ \# \[ …
            (#"\\([\\`*_{}\[\]()#+\-.!|>~<])"#, "$1"),
        ]
        for (pattern, template) in rules { line = replace(pattern, in: line, template: template) }
        // The code spans back.
        return replace("\u{E000}(\\d+)\u{E001}", in: line) { groups in
            Int(groups[1] ?? "").flatMap { spans.indices.contains($0) ? spans[$0] : nil } ?? ""
        }
    }

    // MARK: Regular expressions (ICU's, for lookbehind; cached)

    private static let cache = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        if let cached = cache.object(forKey: pattern as NSString) { return cached }
        let compiled = try! NSRegularExpression(pattern: pattern)
        cache.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }

    /// The whole match's groups (0 is the match), or nil.
    private static func match(_ pattern: String, _ text: String) -> [String?]? {
        let ns = text as NSString
        guard let result = regex(pattern).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<result.numberOfRanges).map { i in
            let range = result.range(at: i)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    private static func replace(_ pattern: String, in text: String, template: String) -> String {
        let ns = text as NSString
        return regex(pattern).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String?]) -> String) -> String {
        let ns = text as NSString
        var out = "", last = 0
        for result in regex(pattern).matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: result.range.location - last))
            out += transform((0..<result.numberOfRanges).map { i in
                let range = result.range(at: i)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            })
            last = result.range.location + result.range.length
        }
        return out + ns.substring(from: last)
    }

    /// Runs of spaces and tabs become one space; the ends are trimmed.
    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    // MARK: Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "hellip": "…", "mdash": "—",
        "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "copy": "©", "reg": "®", "trade": "™", "times": "×", "rarr": "→", "larr": "←",
    ]

    /// HTML entities: named ones (&amp; &lt; &nbsp; …) and numeric ones (&#39; &#x2014;). Unknown names stay.
    static func entities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return replace(#"&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});"#, in: text) { groups in
            let whole = groups[0] ?? "", name = groups[1] ?? ""
            if name.hasPrefix("#") {
                let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = name.dropFirst(hex ? 2 : 1)
                if let value = UInt32(digits, radix: hex ? 16 : 10), value != 0, let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
                return whole
            }
            return named[name] ?? named[name.lowercased()] ?? whole
        }
    }
}
