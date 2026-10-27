//! Headless terminal for clothod.
//!
//! Wraps `alacritty_terminal` and adds the one thing the daemon needs that a GUI terminal does
//! not: [`Vt::snapshot`], which serializes the full terminal state (scrollback, screen, alternate
//! screen, cursor, pen, modes, title, palette overrides, scroll region) into an ANSI byte stream.
//! Feeding that stream into a fresh terminal of the same size reproduces the state. The daemon
//! sends it to clients that need a full screen, and pushes it to the PTY holder so a restarted
//! daemon can rebuild the VT without the whole output history.
//!
//! Known gaps (state a snapshot does not carry): G0-G3 charset designations, custom tab stops,
//! the title stack, the kitty keyboard mode stack below its top entry, and a WRAPLINE flag on the
//! bottom screen row (it can only be set by wrapping onto a following row, which would scroll),
//! the spacer flag on cells whose wide character was erased (they come back as spaces), and a
//! cursor outside the scroll region while origin mode is on, and the tab marker and WRAPLINE flag
//! of the cell under a pending-wrap cursor, and the tab marker at the end of a soft-wrapped row. None of these change what is rendered.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::term::ClipboardType;
use alacritty_terminal::grid::{Dimensions, Grid};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags, Hyperlink};
use alacritty_terminal::term::{Config, Osc52, Term, TermMode};
use alacritty_terminal::vte;
use alacritty_terminal::vte::ansi::{
    Color, CursorShape, CursorStyle, NamedColor, Processor, Rgb, StdSyncHandler,
};

/// Lines of scrollback each pane keeps. Clients keep their own (deeper) history; this is what a
/// new client's snapshot can start from (1000 lines by default), so more is mostly memory: each
/// line costs cols × 24 bytes in the grid.
pub const DEFAULT_SCROLLBACK: usize = 2_000;

/// Longest OSC string (the bytes between `ESC ]` and its terminator) the terminal accepts: room
/// for an OSC 52 copy of 1 MiB (base64) and its prefix. vte buffers an OSC string without limit
/// until it ends, so a pane printing `ESC ] 0 ;` and then endless bytes (a hostile file, a
/// binary blob) would grow serve without bound. Longer ones are dropped whole, never cut short.
pub const MAX_OSC: usize = (1 << 20) / 3 * 4 + 4 + 4096;

/// Longest title kept (in chars); longer ones are cut. Titles go out in every pane event.
pub const MAX_TITLE: usize = 1024;

/// Longest OSC 7 working directory kept (in bytes); longer ones are ignored.
pub const MAX_CWD: usize = 4096;

/// Something the terminal produced besides screen changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VtEvent {
    /// Bytes the terminal answers back to the application (DSR, DA, color queries...).
    Reply(Vec<u8>),
    /// Window title changed (`None` = reset).
    Title(Option<String>),
    /// Working directory reported through OSC 7.
    Cwd(String),
    Bell,
    /// The application set the clipboard with OSC 52 (`ESC ] 52 ; c ; <base64> BEL|ST`): the
    /// decoded text, unbounded here (the daemon caps it). `selection` is true for the `p`/`s`
    /// targets (primary selection) and false for `c` (or none given). OSC 52 reads (`?`) never
    /// produce anything: the terminal is copy-only, so an application can't read the clipboard.
    Clipboard { selection: bool, text: String },
}

#[derive(Clone, Default)]
struct Listener(Arc<Mutex<Vec<Event>>>);

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        self.0.lock().unwrap().push(event);
    }
}

struct Size {
    cols: usize,
    rows: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// Tracks the little state `Term` keeps private but a snapshot needs: the scroll region. It also
/// picks up OSC 7, which `Term` ignores.
struct Tracker {
    /// Kitty keyboard flags stacks (main screen, alternate screen), tracked here because the
    /// daemon's Term has kitty support off on purpose: it doesn't advertise it (clients encode
    /// keys the legacy way), but an application may still push flags unasked, and
    /// `encode_keys` has to follow them.
    kitty: [Vec<u8>; 2],
    alt: bool,
    rows: usize,
    /// Zero-based `start..end` (end exclusive); `None` is the full screen.
    region: Option<(usize, usize)>,
    cwd: Option<String>,
}

impl vte::Perform for Tracker {
    fn csi_dispatch(&mut self, params: &vte::Params, intermediates: &[u8], ignore: bool, action: char) {
        if ignore {
            return;
        }
        let first = params.iter().next().map(|p| p[0]).unwrap_or(0);
        let screen = self.alt as usize;
        match (intermediates, action) {
            // Kitty keyboard: CSI > flags u (push), CSI < n u (pop), CSI = flags ; mode u (set).
            (b">", 'u') => {
                let stack = &mut self.kitty[screen];
                if stack.len() >= 16 {
                    stack.remove(0);
                }
                stack.push(first as u8 & 0x1f);
                return;
            }
            (b"<", 'u') => {
                let n = (first as usize).max(1);
                let stack = &mut self.kitty[screen];
                stack.truncate(stack.len().saturating_sub(n));
                return;
            }
            (b"=", 'u') => {
                let mode = params.iter().nth(1).map(|p| p[0]).unwrap_or(1);
                let stack = &mut self.kitty[screen];
                let cur = stack.last().copied().unwrap_or(0);
                let flags = first as u8 & 0x1f;
                let new = match mode {
                    2 => cur | flags,
                    3 => cur & !flags,
                    _ => flags,
                };
                match stack.last_mut() {
                    Some(top) => *top = new,
                    None => stack.push(new),
                }
                return;
            }
            (b"?", 'h' | 'l') => {
                for p in params.iter() {
                    if matches!(p[0], 47 | 1047 | 1049) {
                        self.alt = action == 'h';
                        if self.alt {
                            self.kitty[1].clear();
                        }
                    }
                }
                return;
            }
            _ => {}
        }
        if !intermediates.is_empty() || action != 'r' {
            return;
        }
        // Mirrors alacritty's DECSTBM handling so the two never disagree.
        let mut it = params.iter().map(|p| p[0] as usize);
        let top = it.next().filter(|&v| v != 0).unwrap_or(1);
        let bottom = it.next().filter(|&v| v != 0).unwrap_or(self.rows);
        if top >= bottom {
            return;
        }
        let start = (top - 1).min(self.rows);
        let end = bottom.min(self.rows);
        self.region = if start == 0 && end == self.rows { None } else { Some((start, end)) };
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        if byte == b'c' && intermediates.is_empty() {
            self.region = None;
            self.kitty = [Vec::new(), Vec::new()];
            self.alt = false;
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if params.first() == Some(&&b"7"[..]) && params.len() > 1 {
            let url = params[1..].join(&b';');
            let cwd = cwd_from_osc7(&String::from_utf8_lossy(&url));
            if cwd.len() <= MAX_CWD && !cwd.chars().any(char::is_control) {
                self.cwd = Some(cwd);
            }
        }
    }
}

/// `file://host/path` -> `/path` (percent-decoded). Anything else is returned as-is.
fn cwd_from_osc7(url: &str) -> String {
    let path = match url.strip_prefix("file://") {
        Some(rest) => rest.find('/').map_or("/", |i| &rest[i..]),
        None => url,
    };
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&path[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Holds back OSC strings until they end, so the parsers only ever see whole ones of at most
/// [`MAX_OSC`] bytes (see there). Its idea of "inside an OSC" matches vte's: `ESC ]` starts one
/// from any state, and BEL, CAN, SUB or ESC ends it.
#[derive(Default)]
struct OscGuard {
    state: OscState,
    /// The OSC so far, from its `]` (the `ESC` already went to the parsers).
    buf: Vec<u8>,
}

#[derive(Default, Clone, Copy, PartialEq, Debug)]
enum OscState {
    #[default]
    Ground,
    /// An `ESC` went through; a `]` now would start an OSC.
    Esc,
    /// Inside an OSC, held back in `buf`.
    Osc,
    /// Inside an OSC that went over [`MAX_OSC`]: dropping it up to its terminator.
    Drop,
}

/// What to feed the parsers: borrowed runs of the input, or bytes the guard released.
enum Piece<'a> {
    Input(&'a [u8]),
    Owned(Vec<u8>),
}

impl OscGuard {
    fn filter<'a>(&mut self, bytes: &'a [u8]) -> Vec<Piece<'a>> {
        let mut out = Vec::new();
        // Start of the run of input not yet emitted, if passing through.
        let mut run = 0;
        for (i, &b) in bytes.iter().enumerate() {
            match self.state {
                OscState::Ground | OscState::Esc => {
                    if self.state == OscState::Esc && b == b']' {
                        if run < i {
                            out.push(Piece::Input(&bytes[run..i]));
                        }
                        self.buf.clear();
                        self.buf.push(b']');
                        self.state = OscState::Osc;
                        run = i + 1;
                    } else {
                        self.state = if b == 0x1b { OscState::Esc } else { OscState::Ground };
                    }
                }
                OscState::Osc | OscState::Drop => {
                    let end = matches!(b, 0x07 | 0x18 | 0x1a | 0x1b);
                    if self.state == OscState::Osc {
                        if end {
                            let mut whole = std::mem::take(&mut self.buf);
                            whole.push(b);
                            out.push(Piece::Owned(whole));
                        } else if self.buf.len() >= MAX_OSC {
                            self.buf = Vec::new();
                            self.state = OscState::Drop;
                        } else {
                            self.buf.push(b);
                        }
                    } else if end {
                        // The parsers sit in Escape since the dropped OSC's ESC: CAN takes them
                        // back to ground without dispatching anything (a BEL would ring).
                        out.push(Piece::Owned(if b == 0x1b { vec![0x18, 0x1b] } else { vec![0x18] }));
                    }
                    if end {
                        self.state = if b == 0x1b { OscState::Esc } else { OscState::Ground };
                    }
                    run = i + 1;
                }
            }
        }
        if matches!(self.state, OscState::Ground | OscState::Esc) && run < bytes.len() {
            out.push(Piece::Input(&bytes[run..]));
        }
        if self.buf.capacity() > 64 << 10 && self.buf.is_empty() {
            self.buf = Vec::new();
        }
        out
    }
}

/// `s` without control characters (C0, DEL, C1), cut to `max` chars: what a title shows.
pub fn printable(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).take(max).collect()
}

/// Copy-only OSC 52, stated rather than left to alacritty's default: a pane may set the
/// clipboard but must never read it (a load would reply with the user's clipboard contents).
fn term_config(scrollback: usize) -> Config {
    Config { scrolling_history: scrollback, osc52: Osc52::OnlyCopy, ..Config::default() }
}

pub struct Vt {
    term: Term<Listener>,
    processor: Processor<StdSyncHandler>,
    listener: Listener,
    tracker: Tracker,
    parser: vte::Parser,
    guard: OscGuard,
    title: Option<String>,
    scrollback: usize,
}

impl Vt {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self::with_scrollback(cols, rows, DEFAULT_SCROLLBACK)
    }

    pub fn with_scrollback(cols: u16, rows: u16, scrollback: usize) -> Self {
        let (cols, rows) = (cols.max(2) as usize, rows.max(1) as usize);
        let listener = Listener::default();
        let term = Term::new(term_config(scrollback), &Size { cols, rows }, listener.clone());
        Vt {
            term,
            processor: Processor::new(),
            listener,
            tracker: Tracker { kitty: [Vec::new(), Vec::new()], alt: false, rows, region: None, cwd: None },
            parser: vte::Parser::new(),
            guard: OscGuard::default(),
            title: None,
            scrollback,
        }
    }

    /// Change how many lines of history this pane keeps (dropping the oldest if it shrinks).
    pub fn set_scrollback(&mut self, scrollback: usize) {
        if scrollback != self.scrollback {
            self.scrollback = scrollback;
            self.term.set_options(term_config(scrollback));
        }
    }

    pub fn cols(&self) -> u16 {
        self.term.columns() as u16
    }

    pub fn rows(&self) -> u16 {
        self.term.screen_lines() as u16
    }

    pub fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    pub fn cwd(&self) -> Option<&str> {
        self.tracker.cwd.as_deref()
    }

    /// Feed PTY output. Returns replies for the application and other notable events.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<VtEvent> {
        let cwd_before = self.tracker.cwd.clone();
        for piece in self.guard.filter(bytes) {
            let b = match &piece {
                Piece::Input(b) => b,
                Piece::Owned(b) => &b[..],
            };
            self.parser.advance(&mut self.tracker, b);
            self.processor.advance(&mut self.term, b);
        }
        let mut events = self.drain_events();
        if self.tracker.cwd != cwd_before {
            if let Some(cwd) = &self.tracker.cwd {
                events.push(VtEvent::Cwd(cwd.clone()));
            }
        }
        events
    }

    /// Apply output held back by a synchronized update that has run past its timeout. The
    /// daemon calls this periodically, since nothing else drives the timeout.
    pub fn flush_expired_sync(&mut self) -> Vec<VtEvent> {
        let expired = self
            .processor
            .sync_timeout()
            .sync_timeout()
            .is_some_and(|deadline| Instant::now() >= deadline);
        if expired {
            self.processor.stop_sync(&mut self.term);
        }
        self.drain_events()
    }

    /// Apply any output held back by a synchronized update now, and return what that (and
    /// anything else queued) produced. The daemon calls this when replay ends and drops the
    /// result: replies to replayed queries were answered before.
    pub fn flush_sync(&mut self) -> Vec<VtEvent> {
        if self.processor.sync_bytes_count() > 0 || self.processor.sync_timeout().sync_timeout().is_some() {
            self.processor.stop_sync(&mut self.term);
        }
        self.drain_events()
    }

    /// Events queued since the last call (e.g. replies produced while [`Vt::snapshot`] applied a
    /// held synchronized update).
    pub fn take_events(&mut self) -> Vec<VtEvent> {
        self.drain_events()
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        let (cols, rows) = (cols.max(2) as usize, rows.max(1) as usize);
        self.term.resize(Size { cols, rows });
        self.tracker.rows = rows;
        self.tracker.region = None;
    }

    fn drain_events(&mut self) -> Vec<VtEvent> {
        let events = std::mem::take(&mut *self.listener.0.lock().unwrap());
        let mut out = Vec::new();
        for event in events {
            match event {
                Event::PtyWrite(s) => out.push(VtEvent::Reply(s.into_bytes())),
                Event::ColorRequest(index, format) => {
                    let rgb = self.term.colors()[index].unwrap_or_else(|| default_color(index));
                    out.push(VtEvent::Reply(format(rgb).into_bytes()));
                }
                Event::TextAreaSizeRequest(format) => {
                    let size = WindowSize {
                        num_lines: self.rows(),
                        num_cols: self.cols(),
                        cell_width: 8,
                        cell_height: 16,
                    };
                    out.push(VtEvent::Reply(format(size).into_bytes()));
                }
                Event::Title(t) => {
                    let t = printable(&t, MAX_TITLE);
                    self.title = Some(t.clone());
                    out.push(VtEvent::Title(Some(t)));
                }
                Event::ResetTitle => {
                    self.title = None;
                    out.push(VtEvent::Title(None));
                }
                Event::Bell => out.push(VtEvent::Bell),
                Event::ClipboardStore(ty, text) => {
                    out.push(VtEvent::Clipboard { selection: ty == ClipboardType::Selection, text })
                }
                _ => {}
            }
        }
        out
    }

    /// The modes that decide how keys must be encoded for the application.
    pub fn input_modes(&self) -> InputModes {
        let mode = *self.term.mode();
        InputModes {
            app_cursor: mode.contains(TermMode::APP_CURSOR),
            app_keypad: mode.contains(TermMode::APP_KEYPAD),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            kitty: self.tracker.kitty[self.tracker.alt as usize].last().copied().unwrap_or(0),
        }
    }

    /// Visible screen as text, one string per row, trailing spaces trimmed.
    pub fn screen_text(&self) -> Vec<String> {
        let grid = self.term.grid();
        (0..grid.screen_lines())
            .map(|l| {
                let row = &grid[Line(l as i32)];
                let mut s = String::new();
                for c in 0..grid.columns() {
                    let cell = &row[Column(c)];
                    if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
                        if is_orphan_spacer(grid, Line(l as i32), c) {
                            s.push(' ');
                        }
                        continue;
                    }
                    s.push(cell.c);
                    if let Some(zw) = cell.zerowidth() {
                        s.extend(zw);
                    }
                }
                s.trim_end().to_string()
            })
            .collect()
    }

    /// Cursor position as (column, line) on the visible screen.
    pub fn cursor(&self) -> (usize, usize) {
        let p = self.term.grid().cursor.point;
        (p.column.0, p.line.0 as usize)
    }

    /// Serialize the full terminal state as ANSI bytes. Feeding the result into a fresh terminal
    /// (or a client terminal after reset) of the same size reproduces this state.
    ///
    /// `max_history` limits how many scrollback lines are included (`None` = all).
    pub fn snapshot(&mut self, max_history: Option<usize>) -> Vec<u8> {
        // Bytes held back by a synchronized update are part of the state the snapshot's seq
        // claims, so they have to be applied first.
        if self.processor.sync_bytes_count() > 0 || self.processor.sync_timeout().sync_timeout().is_some() {
            self.processor.stop_sync(&mut self.term);
            // Replies this produced stay queued until `take_events`.
        }

        let mut w = Writer::default();
        w.raw("\x1bc\x1b[H\x1b[2J\x1b[3J");

        let colors = self.term.colors();
        for i in 0..256 {
            if let Some(rgb) = colors[i] {
                w.raw(&format!("\x1b]4;{i};{}\x1b\\", xcolor(rgb)));
            }
        }
        for (index, osc) in [(NamedColor::Foreground, 10), (NamedColor::Background, 11), (NamedColor::Cursor, 12)] {
            if let Some(rgb) = colors[index] {
                w.raw(&format!("\x1b]{osc};{}\x1b\\", xcolor(rgb)));
            }
        }

        let mode = *self.term.mode();
        if mode.contains(TermMode::ALT_SCREEN) {
            // Term only exposes the active grid. Swapping twice is a no-op for the state (see
            // swap_alt: leaving alt does no reset), but entering alt again clears the alternate
            // grid, so it is cloned first and put back.
            let alt = self.term.grid().clone();
            self.term.swap_alt();
            let primary = self.term.grid().clone();
            self.term.swap_alt();
            *self.term.grid_mut() = alt.clone();

            w.grid_lines(&primary, max_history);
            w.cursor_to(&primary, true, None);
            w.pen_to(&primary.cursor.template);
            w.raw("\x1b[?1049h");
            // Entering alt clears it with the pen's background; clear again with a plain pen.
            w.reset_pen();
            w.raw("\x1b[2J\x1b[H");
            w.grid_lines(&alt, Some(0));
            w.saved_cursor(&alt);
        } else {
            let grid = self.term.grid();
            w.grid_lines(grid, max_history);
            w.saved_cursor(grid);
        }

        // Modes. Defaults after RIS: cursor shown, autowrap on, alternate scroll on.
        let private = [
            (TermMode::APP_CURSOR, 1),
            (TermMode::MOUSE_REPORT_CLICK, 1000),
            (TermMode::MOUSE_DRAG, 1002),
            (TermMode::MOUSE_MOTION, 1003),
            (TermMode::FOCUS_IN_OUT, 1004),
            (TermMode::UTF8_MOUSE, 1005),
            (TermMode::SGR_MOUSE, 1006),
            (TermMode::BRACKETED_PASTE, 2004),
        ];
        for (flag, n) in private {
            if mode.contains(flag) {
                w.raw(&format!("\x1b[?{n}h"));
            }
        }
        if !mode.contains(TermMode::ALTERNATE_SCROLL) {
            w.raw("\x1b[?1007l");
        }
        if !mode.contains(TermMode::SHOW_CURSOR) {
            w.raw("\x1b[?25l");
        }
        if mode.contains(TermMode::APP_KEYPAD) {
            w.raw("\x1b=");
        }
        if mode.contains(TermMode::LINE_FEED_NEW_LINE) {
            w.raw("\x1b[20h");
        }
        let kitty = self.tracker.kitty[self.tracker.alt as usize].last().copied().unwrap_or(0);
        if kitty != 0 {
            w.raw(&format!("\x1b[={kitty};1u"));
        }
        let style = self.term.cursor_style();
        if style != CursorStyle::default() {
            let n = match (style.shape, style.blinking) {
                (CursorShape::Underline, true) => 3,
                (CursorShape::Underline, false) => 4,
                (CursorShape::Beam, true) => 5,
                (CursorShape::Beam, false) => 6,
                (_, true) => 1,
                (_, false) => 2,
            };
            w.raw(&format!("\x1b[{n} q"));
        }
        if let Some(title) = &self.title {
            w.raw(&format!("\x1b]2;{title}\x1b\\"));
        }

        // Scroll region, origin mode and the cursor go last: DECSTBM and DECOM home the cursor.
        let region = self.tracker.region;
        if let Some((start, end)) = region {
            w.raw(&format!("\x1b[{};{}r", start + 1, end));
        }
        let origin = mode.contains(TermMode::ORIGIN);
        if origin {
            w.raw("\x1b[?6h");
        }
        let origin_top = if origin { region.map_or(0, |r| r.0) } else { 0 };
        w.cursor_to(self.term.grid(), true, Some(origin_top));
        w.pen_to(&self.term.grid().cursor.template);
        if !mode.contains(TermMode::LINE_WRAP) {
            w.raw("\x1b[?7l");
        }
        if mode.contains(TermMode::INSERT) {
            w.raw("\x1b[4h");
        }
        w.out
    }

    /// Canonical description of the full state, for tests comparing two terminals.
    pub fn state_dump(&mut self) -> String {
        use std::fmt::Write as _;
        let mut s = String::new();
        let mode = *self.term.mode();
        let dump_grid = |s: &mut String, g: &Grid<Cell>| {
            let _ = writeln!(s, "history={} cursor={:?} wrap={} template={:?}", g.history_size(), g.cursor.point, g.cursor.input_needs_wrap, g.cursor.template);
            for l in g.topmost_line().0..=g.bottommost_line().0 {
                let row = &g[Line(l)];
                let cells: Vec<String> = (0..g.columns())
                    .map(|c| {
                        let mut cell = row[Column(c)].clone();
                        if g.cursor.input_needs_wrap && Line(l) == g.cursor.point.line && c + 1 == g.columns() {
                            // Known gap: recreating pending wrap reprints this cell, which drops a
                            // tab marker, WRAPLINE and a leading-spacer flag.
                            if cell.c == '\t' {
                                cell.c = ' ';
                            }
                            cell.flags.remove(Flags::WRAPLINE | Flags::LEADING_WIDE_CHAR_SPACER);
                        }
                        if cell.zerowidth().is_none_or(|z| z.is_empty()) && cell.underline_color().is_none() && cell.hyperlink().is_none() {
                            cell.extra = None; // empty extra storage is the same as none
                        }
                        if c + 1 < g.columns() {
                            // Only meaningful in the last column; DCH/ICH can shift it elsewhere.
                            cell.flags.remove(Flags::WRAPLINE);
                        }
                        if cell.c == '\t' && c + 1 == g.columns() && cell.flags.contains(Flags::WRAPLINE) {
                            cell.c = ' '; // known gap: tab marker at the end of a wrapped row
                        }

                        if l == g.bottommost_line().0 {
                            cell.flags.remove(Flags::WRAPLINE); // known gap, see module docs
                        }
                        if cell.flags.intersects(Flags::LEADING_WIDE_CHAR_SPACER | Flags::WIDE_CHAR_SPACER) && !is_orphan_spacer(g, Line(l), c) {
                            // Spacers are drawn as part of their wide char; their own attributes
                            // depend on how the char got there and are never visible.
                            let keep = cell.flags & (Flags::LEADING_WIDE_CHAR_SPACER | Flags::WIDE_CHAR_SPACER | Flags::WRAPLINE);
                            cell = Cell::default();
                            cell.flags = keep;
                        }
                        if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
                            cell.c = ' '; // never rendered; a tab can leave '\t' here
                        }
                        if is_orphan_spacer(g, Line(l), c) {
                            cell.flags.remove(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
                        }
                        format!("{cell:?}")
                    })
                    .collect();
                let _ = writeln!(s, "{l}: {}", cells.join(" "));
            }
        };
        if mode.contains(TermMode::ALT_SCREEN) {
            let alt = self.term.grid().clone();
            self.term.swap_alt();
            let primary = self.term.grid().clone();
            self.term.swap_alt();
            *self.term.grid_mut() = alt.clone();
            let _ = writeln!(s, "primary:");
            dump_grid(&mut s, &primary);
            let _ = writeln!(s, "alt saved={:?}", alt.saved_cursor.point);
            dump_grid(&mut s, &alt);
        } else {
            let g = self.term.grid();
            let _ = writeln!(s, "primary saved={:?}", g.saved_cursor.point);
            dump_grid(&mut s, g);
        }
        let _ = writeln!(s, "mode={mode:?} title={:?} region={:?} style={:?}", self.title, self.tracker.region, self.term.cursor_style());
        let colors = self.term.colors();
        for i in 0..alacritty_terminal::term::color::COUNT {
            if let Some(c) = colors[i] {
                let _ = writeln!(s, "color {i} = {c:?}");
            }
        }
        s
    }

    /// True if the state contains a shape the snapshot cannot recreate (see module docs): a
    /// wide char in the last column right after another wide char whose spacer it replaced.
    /// Used by tests to gate the known gap explicitly.
    pub fn has_unrepresentable_wide_pair(&mut self) -> bool {
        let check = |g: &Grid<Cell>| {
            let cols = g.columns();
            cols >= 2
                && (g.topmost_line().0..=g.bottommost_line().0).any(|l| {
                    let row = &g[Line(l)];
                    row[Column(cols - 1)].flags.contains(Flags::WIDE_CHAR) && row[Column(cols - 2)].flags.contains(Flags::WIDE_CHAR)
                })
        };
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            let alt = self.term.grid().clone();
            self.term.swap_alt();
            let primary = self.term.grid().clone();
            self.term.swap_alt();
            *self.term.grid_mut() = alt.clone();
            check(&primary) || check(&alt)
        } else {
            check(self.term.grid())
        }
    }

    pub fn scrollback(&self) -> usize {
        self.scrollback
    }

    /// Lines of history currently above the screen.
    pub fn history_len(&self) -> usize {
        self.term.grid().history_size()
    }
}


fn xcolor(c: Rgb) -> String {
    format!("rgb:{:02x}/{:02x}/{:02x}", c.r, c.g, c.b)
}

/// Colors reported to applications that query a palette entry nobody has set: the xterm
/// palette, with a dark default foreground and background.
pub fn default_color(index: usize) -> Rgb {
    const BASE: [(u8, u8, u8); 16] = [
        (0x00, 0x00, 0x00), (0xcd, 0x00, 0x00), (0x00, 0xcd, 0x00), (0xcd, 0xcd, 0x00),
        (0x00, 0x00, 0xee), (0xcd, 0x00, 0xcd), (0x00, 0xcd, 0xcd), (0xe5, 0xe5, 0xe5),
        (0x7f, 0x7f, 0x7f), (0xff, 0x00, 0x00), (0x00, 0xff, 0x00), (0xff, 0xff, 0x00),
        (0x5c, 0x5c, 0xff), (0xff, 0x00, 0xff), (0x00, 0xff, 0xff), (0xff, 0xff, 0xff),
    ];
    let (r, g, b) = match index {
        0..=15 => BASE[index],
        16..=231 => {
            let i = index - 16;
            let level = |v: usize| if v == 0 { 0 } else { (55 + v * 40) as u8 };
            (level(i / 36), level((i / 6) % 6), level(i % 6))
        }
        232..=255 => {
            let v = (8 + (index - 232) * 10) as u8;
            (v, v, v)
        }
        257 => (0x1e, 0x1e, 0x1e),
        _ => (0xd8, 0xd8, 0xd8),
    };
    Rgb { r, g, b }
}

/// Rendition state the writer has put into the output stream.
#[derive(PartialEq, Clone)]
struct Pen {
    fg: Color,
    bg: Color,
    flags: Flags,
    underline: Option<Color>,
}

impl Default for Pen {
    fn default() -> Self {
        Pen {
            fg: Color::Named(NamedColor::Foreground),
            bg: Color::Named(NamedColor::Background),
            flags: Flags::empty(),
            underline: None,
        }
    }
}

const SGR_FLAGS: Flags = Flags::BOLD
    .union(Flags::DIM)
    .union(Flags::ITALIC)
    .union(Flags::ALL_UNDERLINES)
    .union(Flags::INVERSE)
    .union(Flags::HIDDEN)
    .union(Flags::STRIKEOUT);

impl Pen {
    fn of(cell: &Cell) -> Pen {
        Pen { fg: cell.fg, bg: cell.bg, flags: cell.flags & SGR_FLAGS, underline: cell.underline_color() }
    }

    fn sgr(&self) -> String {
        let mut p = vec!["0".to_string()];
        let f = self.flags;
        for (flag, code) in [
            (Flags::BOLD, "1"),
            (Flags::DIM, "2"),
            (Flags::ITALIC, "3"),
            (Flags::UNDERLINE, "4"),
            (Flags::DOUBLE_UNDERLINE, "4:2"),
            (Flags::UNDERCURL, "4:3"),
            (Flags::DOTTED_UNDERLINE, "4:4"),
            (Flags::DASHED_UNDERLINE, "4:5"),
            (Flags::INVERSE, "7"),
            (Flags::HIDDEN, "8"),
            (Flags::STRIKEOUT, "9"),
        ] {
            if f.contains(flag) {
                p.push(code.into());
            }
        }
        if let Some(c) = color_sgr(self.fg, 30) {
            p.push(c);
        }
        if let Some(c) = color_sgr(self.bg, 40) {
            p.push(c);
        }
        match self.underline {
            Some(Color::Indexed(i)) => p.push(format!("58;5;{i}")),
            Some(Color::Spec(c)) => p.push(format!("58;2;{};{};{}", c.r, c.g, c.b)),
            _ => {}
        }
        format!("\x1b[{}m", p.join(";"))
    }
}

/// SGR parameters for a color. `base` is 30 for foreground, 40 for background.
fn color_sgr(color: Color, base: u16) -> Option<String> {
    match color {
        Color::Named(n) => {
            let n = n as usize;
            match n {
                0..=7 => Some(format!("{}", base as usize + n)),
                8..=15 => Some(format!("{}", base as usize + 60 + n - 8)),
                _ => None, // default (39/49) is what SGR 0 already set
            }
        }
        Color::Indexed(i) => Some(format!("{};5;{i}", base + 8)),
        Color::Spec(c) => Some(format!("{};2;{};{};{}", base + 8, c.r, c.g, c.b)),
    }
}

#[derive(Default)]
struct Writer {
    out: Vec<u8>,
    pen: Pen,
    link: Option<Hyperlink>,
}

impl Writer {
    fn raw(&mut self, s: &str) {
        self.out.extend_from_slice(s.as_bytes());
    }

    fn pen_to(&mut self, cell: &Cell) {
        let pen = Pen::of(cell);
        if pen != self.pen {
            let sgr = pen.sgr();
            self.raw(&sgr);
            self.pen = pen;
        }
        let link = cell.hyperlink();
        if link != self.link {
            match &link {
                Some(l) => {
                    let s = format!("\x1b]8;id={};{}\x1b\\", l.id(), l.uri());
                    self.raw(&s);
                }
                None => self.raw("\x1b]8;;\x1b\\"),
            }
            self.link = link;
        }
    }

    fn reset_pen(&mut self) {
        if self.pen != Pen::default() {
            self.raw("\x1b[0m");
            self.pen = Pen::default();
        }
        if self.link.is_some() {
            self.raw("\x1b]8;;\x1b\\");
            self.link = None;
        }
    }

    fn cell(&mut self, cell: &Cell) {
        self.pen_to(cell);
        let mut buf = [0u8; 4];
        self.out.extend_from_slice(cell.c.encode_utf8(&mut buf).as_bytes());
        if let Some(zw) = cell.zerowidth() {
            for c in zw {
                self.out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            }
        }
    }

    /// Write scrollback (up to `max_history` lines) and screen, top to bottom, starting with the
    /// cursor at home on a cleared screen. Lines above the screen scroll into history.
    fn grid_lines(&mut self, grid: &Grid<Cell>, max_history: Option<usize>) {
        let history = grid.history_size().min(max_history.unwrap_or(usize::MAX));
        let first = -(history as i32);
        let last = grid.screen_lines() as i32 - 1;
        let cols = grid.columns();
        let mut prev_wrapped = false;
        for l in first..=last {
            let row = &grid[Line(l)];
            let wrapped = row[Column(cols - 1)].flags.contains(Flags::WRAPLINE);
            let end = if wrapped {
                cols
            } else {
                let used = (0..cols).rev().find(|&c| !is_blank(&row[Column(c)])).map_or(0, |c| c + 1);
                // The previous row's WRAPLINE is only set once a character wraps onto this one.
                if prev_wrapped { used.max(1) } else { used }
            };
            let continuation = prev_wrapped;
            prev_wrapped = wrapped;
            // A wide char in the last column (ICH pushed its spacer off the row) would wrap if
            // printed there. Print it one column early and insert a blank before it, before the
            // cells left of it are written. This needs the cursor on this row: at the start, or
            // on a continuation row after its first cell (until then the cursor is still
            // pending-wrap on the previous row).
            let last_col_wide = cols > 2 && end == cols && !wrapped
                && row[Column(cols - 1)].flags.contains(Flags::WIDE_CHAR);
            let mut placed = false;
            for c in 0..end {
                // The cursor is at column c only if c is not the spacer half of a wide char.
                let at_c = !row[Column(c)].flags.contains(Flags::WIDE_CHAR_SPACER) || is_orphan_spacer(grid, Line(l), c);
                if last_col_wide && !placed && (c > 0 || !continuation) && at_c {
                    self.reset_pen();
                    self.raw(&format!("\x1b[{}G", cols - 1));
                    let wide = row[Column(cols - 1)].clone();
                    self.cell(&wide);
                    self.reset_pen();
                    self.raw(&format!("\x1b[{}G\x1b[@\x1b[{}G", cols - 1, c + 1));
                    placed = true;
                }
                let orphan_copy;
                let mut cell = &row[Column(c)];
                if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
                    if !is_orphan_spacer(grid, Line(l), c) {
                        continue; // the wide character before (or after) it recreates it
                    }
                    // Its wide character is gone (erased or shifted). Write a space to keep the
                    // columns aligned (known gap: a tab marker on it is dropped).
                    let mut plain = cell.clone();
                    plain.c = ' ';
                    plain.flags.remove(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
                    orphan_copy = plain;
                    cell = &orphan_copy;
                    self.cell(cell);
                    continue;
                }
                if cell.c == '\t' && !(wrapped && c + 1 == cols) {
                    // alacritty marks the cell where a tab started with '\t' (for copying). Write
                    // the cell's attributes with a space, then replay the tab from that column.
                    let mut space = cell.clone();
                    space.c = ' ';
                    self.cell(&space);
                    self.raw(&format!("\x1b[{}G\t\x1b[{}G", c + 1, c + 2));
                    continue;
                }
                if cell.c == '\t' {
                    // Last column of a wrapped row: replaying the tab would lose the pending wrap
                    // the next row needs, so write a space (known gap: the tab marker).
                    let mut space = cell.clone();
                    space.c = ' ';
                    self.cell(&space);
                    continue;
                }
                if c + 1 == cols && last_col_wide {
                    continue; // placed before the row, see above
                }
                self.cell(cell);
                if cell.flags.contains(Flags::WIDE_CHAR)
                    && c + 1 < cols
                    && !row[Column(c + 1)].flags.contains(Flags::WIDE_CHAR_SPACER)
                {
                    // A wide char whose spacer was overwritten. ECH removes the spacer printing
                    // created without touching the wide char; the next cell is then written as is.
                    self.reset_pen();
                    self.raw(&format!("\x1b[{}G\x1b[X", c + 2));
                }
            }
            if continuation && end < cols {
                // Wrapping onto this row at the bottom scrolled in a line filled with the pen's
                // background; clear what the row does not cover.
                self.reset_pen();
                self.raw("\x1b[K");
            }
            if l != last && !wrapped {
                // Reset first: a newline at the bottom scrolls in a line filled with the pen's
                // background.
                self.reset_pen();
                self.raw("\r\n");
            }
        }
        self.reset_pen();
    }

    fn saved_cursor(&mut self, grid: &Grid<Cell>) {
        let saved = &grid.saved_cursor;
        self.raw(&format!("\x1b[{};{}H", saved.point.line.0 + 1, saved.point.column.0 + 1));
        self.pen_to(&saved.template);
        self.raw("\x1b7");
        self.reset_pen();
    }

    /// Move to the grid's cursor. With `pending_wrap`, an `input_needs_wrap` cursor is recreated
    /// by reprinting the cell under it. `origin_top` makes the move relative to the scroll region.
    fn cursor_to(&mut self, grid: &Grid<Cell>, pending_wrap: bool, origin_top: Option<usize>) {
        let cur = &grid.cursor;
        let top = origin_top.unwrap_or(0) as i32;
        let line = cur.point.line.0 - top + 1;
        if pending_wrap && cur.input_needs_wrap {
            let row = &grid[cur.point.line];
            let mut col = cur.point.column;
            let orphan = is_orphan_spacer(grid, cur.point.line, col.0);
            if row[col].flags.contains(Flags::WIDE_CHAR_SPACER) && !orphan {
                col -= 1;
            }
            self.raw(&format!("\x1b[{};{}H", line, col.0 + 1));
            let mut cell = row[col].clone();
            if orphan {
                cell.c = ' ';
                cell.flags.remove(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
            }
            if cell.c == '\t' {
                cell.c = ' '; // a tab here would be a line break (known gap)
            }
            self.cell(&cell);
            self.reset_pen();
        } else {
            self.raw(&format!("\x1b[{};{}H", line, cur.point.column.0 + 1));
        }
    }
}

/// A spacer whose wide character no longer exists: a WIDE_CHAR_SPACER not preceded by a wide char,
/// or a LEADING_WIDE_CHAR_SPACER whose row does not continue with a wide char.
fn is_orphan_spacer(grid: &Grid<Cell>, line: Line, col: usize) -> bool {
    let cell = &grid[line][Column(col)];
    if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
        col == 0 || !grid[line][Column(col - 1)].flags.contains(Flags::WIDE_CHAR)
    } else if cell.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER) {
        col + 1 != grid.columns()
            || line >= grid.bottommost_line()
            || !grid[Line(line.0 + 1)][Column(0)].flags.contains(Flags::WIDE_CHAR)
    } else {
        false
    }
}

fn is_blank(cell: &Cell) -> bool {
    cell.c == ' '
        && cell.fg == Color::Named(NamedColor::Foreground)
        && cell.bg == Color::Named(NamedColor::Background)
        && (cell.flags - Flags::WRAPLINE).is_empty()
        && cell.zerowidth().is_none()
        && cell.underline_color().is_none()
        && cell.hyperlink().is_none()
}

pub mod keys;
pub use keys::{encode_key, encode_text, InputModes};

#[cfg(test)]
mod tests;
