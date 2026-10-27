import UIKit

/// Hardware-keyboard keys SwiftTerm leaves alone in legacy keyboard mode (no kitty flags, which is how
/// Claude Code and Codex run, since clothod doesn't advertise the kitty protocol), sent the way iTerm2,
/// Ghostty and kitty send them, as the Mac app does:
/// - Shift-Return: ESC CR, a newline in agent prompts (a bare CR submits).
/// - ⌘← / ⌘→: ^A / ^E, start and end of the line.
/// - ⌘⌫: ^U, delete to the start of the line.
/// With kitty flags set, SwiftTerm encodes every key itself (Shift-Return as CSI 13;2u).
enum EditingKeys {
    /// A newline in an agent's prompt, for the key bar: what Shift-Return sends.
    static func newline(kitty: Bool) -> [UInt8] {
        kitty ? Array("\u{1b}[13;2u".utf8) : [0x1b, 0x0d]
    }

    /// The bytes for a key with exactly these modifiers, or nil to leave it to SwiftTerm.
    static func bytes(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags, kitty: Bool) -> [UInt8]? {
        guard !kitty else { return nil }
        let held = modifiers.intersection([.shift, .control, .alternate, .command])
        switch (keyCode, held) {
        case (.keyboardReturnOrEnter, .shift), (.keypadEnter, .shift): return newline(kitty: false)
        case (.keyboardLeftArrow, .command): return [0x01]
        case (.keyboardRightArrow, .command): return [0x05]
        case (.keyboardDeleteOrBackspace, .command): return [0x15]
        default: return nil
        }
    }
}
