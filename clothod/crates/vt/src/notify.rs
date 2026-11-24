//! Notification, progress and status sequences: OSC 9, OSC 99 (kitty), OSC 777;notify and
//! OSC 7501 (Program Status Protocol).
//!
//! [`parse`] is pure and works on the whole raw OSC the guard releases (see `OscGuard`), not on
//! vte's `osc_dispatch`: vte keeps 16 parameters, which would cut a 777 body with many
//! semicolons. The terminal never answers any of these (no OSC 99 query, activation or close
//! reports, no 7501 reply): the daemon decides what to do with a 7501 query.

use crate::printable;

/// Longest OSC (without its `]` and terminator) read as one of these. Longer ones are ignored
/// whole.
pub const MAX_NOTIFY_OSC: usize = 4096;

/// Longest notification title or 7501 `title` kept, in chars.
pub const MAX_NOTIFY_TITLE: usize = 100;

/// Longest notification body or 7501 `msg` kept, in chars.
pub const MAX_NOTIFY_BODY: usize = 300;

/// Most unfinished OSC 99 notifications (ids) held at once, and the most bytes they hold together
/// (ids included). The oldest are dropped first.
const MAX_PENDING_IDS: usize = 8;
const MAX_PENDING_BYTES: usize = 4096;

/// The progress an application reports with `OSC 9 ; 4`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub state: ProgressState,
    /// 0..=100. `None` when the application gave none, and always for `Indeterminate`.
    pub percent: Option<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressState {
    Running,
    Error,
    Indeterminate,
    Paused,
}

/// One OSC 7501 report (Program Status Protocol 0.4). Text fields are decoded, free of control
/// characters and bounded.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Psp {
    pub state: Option<PspState>,
    /// `permission`, `question` or `auth`: why the program is blocked.
    pub kind: Option<String>,
    /// The reporting program's name, as sent (the daemon normalises it).
    pub app: Option<String>,
    pub msg: Option<String>,
    pub title: Option<String>,
    /// 0..=100.
    pub progress: Option<u8>,
    /// `OSC 7501 ; ?`: the program asks whether the terminal speaks the protocol. Nothing else
    /// is set then.
    pub query: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PspState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
    Clear,
}

/// What [`parse`] read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Osc {
    /// A whole notification (OSC 9 or OSC 777;notify), cleaned and bounded.
    Notify { title: Option<String>, body: Option<String> },
    Progress(Option<Progress>),
    Status(Psp),
    /// One OSC 99 escape code: a piece of a notification, which [`Pending`] puts together.
    Kitty(KittyChunk),
}

/// One OSC 99 escape code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KittyChunk {
    /// The `i` key, with only the characters kitty allows in an identifier. Empty: none given.
    id: String,
    /// `d` is missing or not 0: the notification is complete.
    done: bool,
    part: KittyPart,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum KittyPart {
    Title(Vec<u8>),
    Body(Vec<u8>),
    /// `icon` or `buttons`: nothing to show, but it may be the piece that completes one.
    NoText,
    /// `close`: forget what is held for the id.
    Close,
    /// Base64 that doesn't decode: the notification it belongs to is discarded.
    Bad,
}

/// Read one raw OSC as the guard releases it: from its `]` to its terminator (BEL, or the ESC
/// of ST). `None` for every other OSC, for one ended another way (CAN, SUB), for one over
/// [`MAX_NOTIFY_OSC`] bytes, and for one with nothing to report.
pub fn parse(raw_osc: &[u8]) -> Option<Osc> {
    let s = raw_osc.strip_prefix(b"]")?;
    let (&end, s) = s.split_last()?;
    if !matches!(end, 0x07 | 0x1b) || s.len() > MAX_NOTIFY_OSC {
        return None;
    }
    let (num, rest) = split_once(s, b';')?;
    match num {
        b"9" => parse_9(rest),
        b"99" => parse_99(rest).map(Osc::Kitty),
        b"777" => parse_777(rest),
        b"7501" => parse_7501(rest).map(Osc::Status),
        _ => None,
    }
}

fn split_once(s: &[u8], at: u8) -> Option<(&[u8], &[u8])> {
    let i = memchr::memchr(at, s)?;
    Some((&s[..i], &s[i + 1..]))
}

/// `bytes` as cleaned text of at most `max` chars; `None` when nothing is left.
fn text(bytes: &[u8], max: usize) -> Option<String> {
    let t = printable(&String::from_utf8_lossy(bytes), max);
    let t = t.trim();
    (!t.is_empty()).then(|| t.to_string())
}

fn notify(title: Option<String>, body: Option<String>) -> Option<Osc> {
    (title.is_some() || body.is_some()).then_some(Osc::Notify { title, body })
}

/// A decimal number of 1 to 3 digits.
fn small_number(s: &[u8]) -> Option<u16> {
    if s.is_empty() || s.len() > 3 || !s.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(s).ok()?.parse().ok()
}

/// OSC 9: `9;4;st[;pr]` is progress, the other ConEmu commands (`9;1` to `9;12`) are ignored,
/// and anything else is a notification body (iTerm2's form).
fn parse_9(rest: &[u8]) -> Option<Osc> {
    let first = rest.split(|&b| b == b';').next().unwrap_or(rest);
    if first.len() <= 2 {
        if let Some(n @ 1..=12) = small_number(first) {
            return if n == 4 { parse_progress(&rest[first.len()..]) } else { None };
        }
    }
    notify(None, text(rest, MAX_NOTIFY_BODY))
}

/// The `;st[;pr]` after `9;4`. A state that isn't 0 to 4 is ignored.
fn parse_progress(rest: &[u8]) -> Option<Osc> {
    let mut it = rest.strip_prefix(b";")?.split(|&b| b == b';');
    let state = match it.next()? {
        b"0" => return Some(Osc::Progress(None)),
        b"1" => ProgressState::Running,
        b"2" => ProgressState::Error,
        b"3" => ProgressState::Indeterminate,
        b"4" => ProgressState::Paused,
        _ => return None,
    };
    let percent = match state {
        ProgressState::Indeterminate => None,
        _ => it.next().and_then(percent),
    };
    Some(Osc::Progress(Some(Progress { state, percent })))
}

/// A decimal number clamped to 0..=100; `None` when it isn't one.
fn percent(s: &[u8]) -> Option<u8> {
    if s.is_empty() || !s.iter().all(u8::is_ascii_digit) {
        return None;
    }
    // More digits than fit are still over 100.
    Some(std::str::from_utf8(s).ok()?.parse::<u32>().unwrap_or(u32::MAX).min(100) as u8)
}

/// OSC 777: only `notify;title;body`, the body being everything after the title's `;`.
fn parse_777(rest: &[u8]) -> Option<Osc> {
    let rest = rest.strip_prefix(b"notify;")?;
    let (title, body) = split_once(rest, b';').unwrap_or((rest, b""));
    notify(text(title, MAX_NOTIFY_TITLE), text(body, MAX_NOTIFY_BODY))
}

/// OSC 99: `metadata;payload`, the metadata being colon-separated `k=v`. Keys other than `p`,
/// `e`, `d` and `i` are ignored (the notification is always shown: `o` isn't honoured), and so
/// are the payload types that ask the terminal something (`?`, `alive`) and unknown ones.
fn parse_99(rest: &[u8]) -> Option<KittyChunk> {
    let (meta, payload) = split_once(rest, b';')?;
    let (mut p, mut base64, mut done, mut id) = (&b"title"[..], false, true, String::new());
    for kv in meta.split(|&b| b == b':') {
        let Some((k, v)) = split_once(kv, b'=') else { continue };
        match k {
            b"p" => p = v,
            b"e" => {
                base64 = match v {
                    b"0" => false,
                    b"1" => true,
                    _ => return None,
                }
            }
            b"d" => done = v != b"0",
            b"i" => {
                id = v.iter().filter(|b| b.is_ascii_alphanumeric() || b"_-+.".contains(b)).take(64).map(|&b| b as char).collect()
            }
            _ => {}
        }
    }
    let part = match p {
        b"title" | b"body" => match if base64 { base64_decode(payload) } else { Some(payload.to_vec()) } {
            Some(data) if p == b"title" => KittyPart::Title(data),
            Some(data) => KittyPart::Body(data),
            None => KittyPart::Bad,
        },
        b"icon" | b"buttons" => KittyPart::NoText,
        b"close" => KittyPart::Close,
        _ => return None,
    };
    Some(KittyChunk { id, done, part })
}

/// OSC 7501: `?`, or `key=value(:key=value)*`. Unknown keys are ignored, and so is a `kind` or
/// `progress` with a value outside the protocol. A report with an `id` (a sub-task's record) is
/// ignored whole. The whole report is discarded for an unknown
/// `state`, for `msg` or `title` that isn't base64 of UTF-8, and for any control character in
/// its text.
fn parse_7501(rest: &[u8]) -> Option<Psp> {
    if rest == b"?" {
        return Some(Psp { query: true, ..Psp::default() });
    }
    let mut psp = Psp::default();
    let clean = |bytes: Vec<u8>, max: usize| -> Option<Option<String>> {
        let s = String::from_utf8(bytes).ok()?;
        if s.chars().any(char::is_control) {
            return None;
        }
        Some(text(s.as_bytes(), max))
    };
    for kv in rest.split(|&b| b == b':') {
        let Some((k, v)) = split_once(kv, b'=') else { continue };
        match k {
            b"state" => {
                psp.state = Some(match v {
                    b"idle" => PspState::Idle,
                    b"working" => PspState::Working,
                    b"done" => PspState::Done,
                    b"blocked" => PspState::Blocked,
                    b"error" => PspState::Error,
                    b"clear" => PspState::Clear,
                    _ => return None,
                })
            }
            b"kind" => {
                psp.kind = matches!(v, b"permission" | b"question" | b"auth").then(|| String::from_utf8_lossy(v).into_owned())
            }
            b"app" => psp.app = clean(v.to_vec(), MAX_NOTIFY_TITLE)?,
            b"msg" => psp.msg = clean(base64_decode(v)?, MAX_NOTIFY_BODY)?,
            b"title" => psp.title = clean(base64_decode(v)?, MAX_NOTIFY_TITLE)?,
            b"progress" => psp.progress = small_number(v).filter(|&n| n <= 100).map(|n| n as u8),
            // A record below the root (a sub-task): only the root record is kept, so a
            // sub-task's state or its `clear` must not pass for the program's.
            b"id" if !v.is_empty() => return None,
            _ => {}
        }
    }
    (psp != Psp::default()).then_some(psp)
}

/// Standard base64 (RFC 4648), with or without its padding. `None` for anything else.
fn base64_decode(s: &[u8]) -> Option<Vec<u8>> {
    let pad = s.iter().rev().take_while(|&&b| b == b'=').count();
    let s = &s[..s.len() - pad];
    if pad > 2 || s.len() % 4 == 1 || (pad > 0 && (s.len() + pad) % 4 != 0) {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for &b in s {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// OSC 99 notifications not yet complete (`d=0`), by id. Bounded: see [`MAX_PENDING_IDS`].
#[derive(Default)]
pub struct Pending {
    /// Oldest first.
    notes: Vec<Note>,
}

#[derive(Default)]
struct Note {
    id: String,
    title: Vec<u8>,
    body: Vec<u8>,
    /// A piece of it was bad base64: it is dropped, without an event, when it completes.
    bad: bool,
}

impl Note {
    fn size(&self) -> usize {
        self.id.len() + self.title.len() + self.body.len()
    }
}

impl Pending {
    /// Add one escape code. Returns the notification (title, body) it completes, if it has any
    /// text.
    pub fn add(&mut self, chunk: KittyChunk) -> Option<(Option<String>, Option<String>)> {
        let held = self.notes.iter().position(|n| n.id == chunk.id);
        if chunk.part == KittyPart::Close {
            held.map(|i| self.notes.remove(i));
            return None;
        }
        let mut note = held.map(|i| self.notes.remove(i)).unwrap_or_else(|| Note { id: chunk.id, ..Note::default() });
        match chunk.part {
            KittyPart::Title(t) => note.title.extend_from_slice(&t),
            KittyPart::Body(b) => note.body.extend_from_slice(&b),
            KittyPart::Bad => note.bad = true,
            KittyPart::NoText | KittyPart::Close => {}
        }
        if !chunk.done {
            if note.bad {
                // Only the marker is kept, so its later pieces are dropped with it.
                note.title = Vec::new();
                note.body = Vec::new();
            }
            self.notes.push(note);
            while self.notes.len() > MAX_PENDING_IDS || self.notes.iter().map(Note::size).sum::<usize>() > MAX_PENDING_BYTES {
                self.notes.remove(0);
            }
            return None;
        }
        if note.bad {
            return None;
        }
        let (title, body) = (text(&note.title, MAX_NOTIFY_TITLE), text(&note.body, MAX_NOTIFY_BODY));
        (title.is_some() || body.is_some()).then_some((title, body))
    }

    pub fn clear(&mut self) {
        self.notes.clear();
    }

    #[cfg(test)]
    pub(crate) fn held(&self) -> (usize, usize) {
        (self.notes.len(), self.notes.iter().map(Note::size).sum())
    }
}
