import ClothoKit
import Foundation
import SwiftTerm

/// A terminal's visible screen as escape sequences that draw it again (SavedScreen), and back.
enum ScreenCapture {
    /// The screen as the pane last showed it (the bottom of the buffer unless the user had scrolled back),
    /// row by row, with an SGR sequence wherever the colours or style change.
    static func capture(_ terminal: Terminal, now: Date = Date()) -> SavedScreen {
        var out = "\u{1b}[0m"
        var current: Attribute?
        for row in 0..<terminal.rows {
            if row > 0 { out += "\r\n" }
            var line = ""
            // Trailing cells in the default style are left out; the screen is cleared before drawing.
            var pending = ""
            var skipNext = false
            for col in 0..<terminal.cols {
                guard let cell = cellAt(terminal, col: col, row: row) else { continue }
                // The cell after a wide character is its second half, drawn by it.
                if skipNext || cell.width == 0 {
                    skipNext = false
                    continue
                }
                skipNext = cell.width > 1
                let attribute = cell.attribute
                let character = terminal.getCharacter(for: cell)
                let blank = (character == " " || character == "\u{0}") && isPlain(attribute)
                if blank {
                    pending += " "
                    continue
                }
                line += pending
                pending = ""
                if attribute != current {
                    line += sgr(attribute)
                    current = attribute
                }
                line += character == "\u{0}" ? " " : String(character)
            }
            out += line
        }
        out += "\u{1b}[0m"
        let cursor = terminal.getCursorLocation()
        return SavedScreen(cols: terminal.cols, rows: terminal.rows, ansi: out,
                           cursorCol: cursor.x, cursorRow: cursor.y, saved: now)
    }

    /// A preview from the daemon's plain text of a pane (`pane.text`), for panes this phone never showed.
    /// Control characters are dropped, so pane text can't add escape sequences of its own.
    static func plain(_ text: PaneText, now: Date = Date()) -> SavedScreen {
        let lines = text.lines.prefix(max(1, text.rows)).map { line in
            String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f && !(0x80..<0xa0).contains($0.value) }))
        }
        return SavedScreen(cols: text.cols, rows: text.rows, ansi: "\u{1b}[0m" + lines.joined(separator: "\r\n"),
                           cursorCol: text.cursorCol, cursorRow: text.cursorRow, saved: now)
    }

    /// What to feed a fresh terminal of the screen's size to show it: clear, draw, put the cursor back.
    static func replay(_ screen: SavedScreen) -> Data {
        Data(("\u{1b}[0m\u{1b}[H\u{1b}[2J" + screen.ansi + "\u{1b}[\(screen.cursorRow + 1);\(screen.cursorCol + 1)H").utf8)
    }

    /// A cell of the displayed screen (rows count from its top; SwiftTerm's `getLine` follows the scroll position).
    private static func cellAt(_ terminal: Terminal, col: Int, row: Int) -> CharData? {
        terminal.getCharData(col: col, row: row)
    }

    /// No style and the default colours (a cleared cell's background is either default).
    private static func isPlain(_ attribute: Attribute) -> Bool {
        guard attribute.style.isEmpty, case .defaultColor = attribute.fg else { return false }
        switch attribute.bg {
        case .defaultColor, .defaultInvertedColor: return true
        default: return false
        }
    }

    /// `ESC [ 0 ; … m` for an attribute: style flags, then foreground and background.
    static func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let style = attribute.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes += color(attribute.fg, foreground: true)
        codes += color(attribute.bg, foreground: false)
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    private static func color(_ color: Attribute.Color, foreground: Bool) -> [String] {
        switch color {
        case .ansi256(let code):
            if code < 8 { return [String(Int(code) + (foreground ? 30 : 40))] }
            if code < 16 { return [String(Int(code) - 8 + (foreground ? 90 : 100))] }
            return [foreground ? "38" : "48", "5", String(code)]
        case .trueColor(let red, let green, let blue):
            return [foreground ? "38" : "48", "2", String(red), String(green), String(blue)]
        case .defaultColor, .defaultInvertedColor:
            return []
        }
    }
}
