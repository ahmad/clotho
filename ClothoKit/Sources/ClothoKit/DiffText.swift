import Foundation

/// Text from a repository (a diff's lines, file paths, git's messages) made safe to show. A diff line is
/// the file's own content, so it can hold escape sequences, other control characters, and the invisible
/// characters that reorder or hide text (docs/security.md, "For client authors"). Nothing is dropped:
/// each becomes something the reader can see. (`PlainText` is for Markdown and isn't used here.)
public enum DiffText {
    /// `text` with every control character as its control picture (ESC as "␛", NUL as "␀", DEL as "␡";
    /// the C1 controls, which have no picture, as "<U+0085>") and every bidi or invisible format
    /// control as "<U+202E>". Tab stays a tab. Everything else is unchanged.
    public static func display(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsPicture) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09:
                out.append(scalar)
            case 0x00 ... 0x1F:
                // U+2400 onwards: the pictures of the C0 controls, in order.
                out.append(Unicode.Scalar(0x2400 + scalar.value) ?? scalar)
            case 0x7F:
                out.append("\u{2421}")
            case _ where needsPicture(scalar):
                out.append(contentsOf: "<U+\(hex(scalar.value))>".unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whether `display` changes this scalar.
    static func needsPicture(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09: return false
        case 0x00 ... 0x1F, 0x7F ... 0x9F: return true
        case 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0x061C, 0xFEFF: return true
        default: return false
        }
    }

    private static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(4 - digits.count, 0)) + digits
    }
}
