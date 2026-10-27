//! Encoding named keys and text for an application, the way a terminal would given the modes
//! the application set (DECCKM, keypad, bracketed paste, kitty keyboard flags). Lets clients
//! say "Enter" instead of guessing bytes (`pane.keys` in docs/protocol.md).

/// Modes that change what a key sends.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InputModes {
    /// DECCKM: cursor keys send SS3 sequences.
    pub app_cursor: bool,
    /// DECKPAM.
    pub app_keypad: bool,
    /// ?2004: pasted text is wrapped in ESC[200~ ... ESC[201~.
    pub bracketed_paste: bool,
    /// Kitty keyboard protocol flags (1 disambiguate, 2 event types, 4 alternate keys, 8 all keys
    /// as escape codes, 16 associated text).
    pub kitty: u8,
}

const DISAMBIGUATE: u8 = 1;
const ALL_AS_ESCAPES: u8 = 8;

/// Text as the application should receive it (typed or pasted). `paste` wraps it when the
/// application asked for bracketed paste.
pub fn encode_text(modes: InputModes, text: &str, paste: bool) -> Vec<u8> {
    if paste && modes.bracketed_paste {
        // A stray end marker inside the text would end the paste early.
        let clean = text.replace("\x1b[201~", "");
        format!("\x1b[200~{clean}\x1b[201~").into_bytes()
    } else {
        text.as_bytes().to_vec()
    }
}

/// One key like `enter`, `ctrl+c`, `shift+tab`, `alt+left`, `f5`, or a single character.
pub fn encode_key(modes: InputModes, key: &str) -> Result<Vec<u8>, String> {
    let lower = key.to_ascii_lowercase();
    let mut parts: Vec<&str> = lower.split('+').collect();
    let name = parts.pop().filter(|n| !n.is_empty()).ok_or_else(|| format!("bad key `{key}`"))?;
    let (mut shift, mut alt, mut ctrl) = (false, false, false);
    for m in parts {
        match m {
            "shift" => shift = true,
            "alt" | "option" | "meta" => alt = true,
            "ctrl" | "control" => ctrl = true,
            _ => return Err(format!("unknown modifier `{m}` in `{key}`")),
        }
    }
    // xterm/kitty modifier parameter: 1 + shift + 2*alt + 4*ctrl.
    let modp = 1 + shift as u8 + 2 * alt as u8 + 4 * ctrl as u8;
    let kitty = modes.kitty & (DISAMBIGUATE | ALL_AS_ESCAPES) != 0;
    let csi_u = |code: u32| if modp > 1 { format!("\x1b[{code};{modp}u") } else { format!("\x1b[{code}u") };

    // Keys that legacy encoding sends as single bytes.
    let legacy_byte = match name {
        "enter" | "return" => Some((13u32, b'\r')),
        "tab" => Some((9, b'\t')),
        "backspace" => Some((127, 0x7f)),
        "escape" | "esc" => Some((27, 0x1b)),
        "space" => Some((32, b' ')),
        _ => None,
    };
    if let Some((code, byte)) = legacy_byte {
        // Kitty: Esc (and anything modified) is disambiguated; Enter/Tab/Backspace only with
        // "report all keys as escape codes".
        let as_escape = kitty && (modes.kitty & ALL_AS_ESCAPES != 0 || code == 27 || modp > 1);
        if as_escape {
            return Ok(csi_u(code).into_bytes());
        }
        return Ok(match (name, shift, ctrl) {
            ("tab", true, _) => b"\x1b[Z".to_vec(),
            ("space", _, true) => vec![0],
            ("backspace", _, true) => vec![0x08],
            _ => {
                let mut v = Vec::new();
                if alt {
                    v.push(0x1b);
                }
                v.push(byte);
                v
            }
        });
    }

    // Cursor and editing keys.
    let ss3_or_csi = |c: char| -> Vec<u8> {
        if modp > 1 {
            format!("\x1b[1;{modp}{c}").into_bytes()
        } else if modes.app_cursor {
            format!("\x1bO{c}").into_bytes()
        } else {
            format!("\x1b[{c}").into_bytes()
        }
    };
    let tilde = |n: u32| -> Vec<u8> {
        if modp > 1 { format!("\x1b[{n};{modp}~") } else { format!("\x1b[{n}~") }.into_bytes()
    };
    let f1_4 = |c: char| -> Vec<u8> {
        if modp > 1 { format!("\x1b[1;{modp}{c}") } else { format!("\x1bO{c}") }.into_bytes()
    };
    let seq = match name {
        "up" => ss3_or_csi('A'),
        "down" => ss3_or_csi('B'),
        "right" => ss3_or_csi('C'),
        "left" => ss3_or_csi('D'),
        "home" => ss3_or_csi('H'),
        "end" => ss3_or_csi('F'),
        "insert" => tilde(2),
        "delete" => tilde(3),
        "pageup" => tilde(5),
        "pagedown" => tilde(6),
        "f1" => f1_4('P'),
        "f2" => f1_4('Q'),
        "f3" => f1_4('R'),
        "f4" => f1_4('S'),
        "f5" => tilde(15),
        "f6" => tilde(17),
        "f7" => tilde(18),
        "f8" => tilde(19),
        "f9" => tilde(20),
        "f10" => tilde(21),
        "f11" => tilde(23),
        "f12" => tilde(24),
        _ => Vec::new(),
    };
    if !seq.is_empty() {
        return Ok(seq);
    }

    // A single character, possibly with modifiers.
    let mut chars = key.rsplit('+').next().unwrap_or("").chars();
    let (Some(c), None) = (chars.next(), chars.next()) else {
        return Err(format!("unknown key `{key}`"));
    };
    if kitty && (ctrl || alt || modes.kitty & ALL_AS_ESCAPES != 0) {
        return Ok(csi_u(c.to_ascii_lowercase() as u32).into_bytes());
    }
    let mut out = Vec::new();
    if alt {
        out.push(0x1b);
    }
    if ctrl {
        let l = c.to_ascii_lowercase();
        let byte = match l {
            'a'..='z' => l as u8 - b'a' + 1,
            '@' | '2' => 0,
            '[' | '3' => 0x1b,
            '\\' | '4' => 0x1c,
            ']' | '5' => 0x1d,
            '^' | '6' => 0x1e,
            '_' | '7' | '/' => 0x1f,
            '?' | '8' => 0x7f,
            _ => return Err(format!("can't encode `{key}`")),
        };
        out.push(byte);
    } else {
        let c = if shift { c.to_ascii_uppercase() } else { c };
        let mut buf = [0u8; 4];
        out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn k(modes: InputModes, key: &str) -> Vec<u8> {
        encode_key(modes, key).unwrap()
    }

    #[test]
    fn legacy_and_modes() {
        let m = InputModes::default();
        assert_eq!(k(m, "enter"), b"\r");
        assert_eq!(k(m, "ctrl+c"), [3]);
        assert_eq!(k(m, "alt+x"), b"\x1bx");
        assert_eq!(k(m, "shift+tab"), b"\x1b[Z");
        assert_eq!(k(m, "up"), b"\x1b[A");
        assert_eq!(k(m, "ctrl+right"), b"\x1b[1;5C");
        assert_eq!(k(m, "f5"), b"\x1b[15~");
        assert_eq!(k(InputModes { app_cursor: true, ..m }, "up"), b"\x1bOA");
        assert!(encode_key(m, "hyper+x").is_err());
        assert!(encode_key(m, "nope").is_err());
    }

    #[test]
    fn kitty_flags() {
        let d = InputModes { kitty: 1, ..Default::default() };
        assert_eq!(k(d, "enter"), b"\r", "disambiguate alone keeps Enter legacy");
        assert_eq!(k(d, "escape"), b"\x1b[27u");
        assert_eq!(k(d, "shift+enter"), b"\x1b[13;2u");
        assert_eq!(k(d, "ctrl+c"), b"\x1b[99;5u");
        let all = InputModes { kitty: 1 | 8, ..Default::default() };
        assert_eq!(k(all, "enter"), b"\x1b[13u");
        assert_eq!(k(all, "tab"), b"\x1b[9u");
        assert_eq!(k(all, "backspace"), b"\x1b[127u");
        assert_eq!(k(all, "a"), b"\x1b[97u");
        assert_eq!(k(all, "space"), b"\x1b[32u");
        assert_eq!(k(d, "space"), b" ");
    }

    #[test]
    fn paste() {
        let m = InputModes { bracketed_paste: true, ..Default::default() };
        assert_eq!(encode_text(m, "a\nb", true), b"\x1b[200~a\nb\x1b[201~");
        assert_eq!(encode_text(m, "x\x1b[201~y", true), b"\x1b[200~xy\x1b[201~");
        assert_eq!(encode_text(InputModes::default(), "a\nb", true), b"a\nb");
        assert_eq!(encode_text(m, "abc", false), b"abc");
    }
}
