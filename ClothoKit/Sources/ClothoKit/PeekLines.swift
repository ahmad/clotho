import Foundation

/// Picks the rows of a peek (`SessionEvent.peek`) worth showing on a card: the last rows of real
/// output, without the input box and hints an agent's screen ends with.
public enum PeekLines {
    /// How many lines to ask the daemon for (`peekSubscribe`), so that something is left to show
    /// once an input box and its hints are cut.
    public static let requested = 8

    /// How far from the end an input box's last row can be: hint rows may sit under it.
    static let boxReach = 5

    /// The last `count` rows of `lines` (oldest first) that say something:
    /// - an input box near the end (a rule or box-top row, its rows, a rule or box-bottom row) goes,
    ///   with every row under it;
    /// - then trailing rows of only box-drawing characters and spaces go, and trailing empty prompts
    ///   (">", "❯", "›", also between a box's sides).
    /// Empty when nothing is left. The text itself is untouched: draw it through `DiffText.display`.
    public static func pick(_ lines: [String], count: Int = 2) -> [String] {
        var rows = lines
        if let box = inputBoxStart(rows) { rows.removeSubrange(box...) }
        while let last = rows.last, isChrome(last) || isEmptyPrompt(last) { rows.removeLast() }
        return Array(rows.suffix(max(count, 0)))
    }

    /// Where the input box at the end of `rows` starts: the nearest border row above a closing border
    /// row that is within the last `boxReach` rows, with the prompt's rows between them.
    static func inputBoxStart(_ rows: [String]) -> Int? {
        let borders = rows.indices.filter { isBorder(rows[$0]) }
        guard let bottom = borders.last(where: { $0 >= rows.count - boxReach }),
              let top = borders.last(where: { $0 < bottom - 1 }) else { return nil }
        // Only an input box: its first row is the prompt (a table or a framed message has none), and
        // what is typed runs a few rows at most.
        let inside = rows[(top + 1) ..< bottom]
        guard inside.count <= boxReach, let first = inside.first, isPrompt(first) else { return nil }
        return top
    }

    static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool { (0x2500 ... 0x257F).contains(scalar.value) }

    /// Only box-drawing characters and spaces, or nothing.
    static func isChrome(_ row: String) -> Bool {
        row.unicodeScalars.allSatisfy { isBoxDrawing($0) || $0 == " " }
    }

    /// A rule ("────") or a box's top or bottom ("╭──╮", "╰──╯"): chrome with at least three
    /// horizontal strokes.
    static func isBorder(_ row: String) -> Bool {
        isChrome(row) && row.unicodeScalars.filter { $0 == "\u{2500}" || $0 == "\u{2501}" || $0 == "\u{2550}" }.count >= 3
    }

    /// The row without spaces and a box's sides around it, when it has sides.
    static func unboxed(_ row: String) -> String {
        var text = row.trimmingCharacters(in: .whitespaces)[...]
        while let first = text.unicodeScalars.first, isBoxDrawing(first) { text = text.dropFirst() }
        while let last = text.unicodeScalars.last, isBoxDrawing(last) { text = text.dropLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static let promptMarks: [Character] = [">", "❯", "›"]

    /// Starts with a prompt mark, alone or followed by a space: "> ", "❯ fix the test".
    static func isPrompt(_ row: String) -> Bool {
        let text = unboxed(row)
        guard let first = text.first, promptMarks.contains(first) else { return false }
        return text.count == 1 || text.dropFirst().first == " "
    }

    /// A prompt mark with nothing typed after it.
    static func isEmptyPrompt(_ row: String) -> Bool {
        let text = unboxed(row)
        return text.count == 1 && promptMarks.contains(text.first!)
    }
}
