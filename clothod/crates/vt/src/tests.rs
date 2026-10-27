use super::*;

/// Feed `input` to a terminal, snapshot it, feed the snapshot to a fresh terminal of the same
/// size, and require identical state. Also checks that a terminal that already has content
/// (a client reattaching) converges to the same state.
fn roundtrip(cols: u16, rows: u16, input: &[u8]) {
    let mut a = Vt::new(cols, rows);
    a.feed(input);
    let snap = a.snapshot(None);

    let mut b = Vt::new(cols, rows);
    b.feed(&snap);
    let (da, db) = (a.state_dump(), b.state_dump());
    if da != db {
        let i = da.lines().zip(db.lines()).position(|(x, y)| x != y).unwrap_or(0);
        let (x, y) = (da.lines().nth(i).unwrap_or(""), db.lines().nth(i).unwrap_or(""));
        let (cx, cy): (Vec<_>, Vec<_>) = (x.split(" Cell ").collect(), y.split(" Cell ").collect());
        let col = cx.iter().zip(&cy).position(|(p, q)| p != q).unwrap_or(0);
        panic!(
            "state differs at dump line {i}, cell {col}\nexpected: {}\nactual:   {}\nline: {}\nsnapshot: {:?}",
            cx.get(col).unwrap_or(&""),
            cy.get(col).unwrap_or(&""),
            x.split(':').next().unwrap_or(""),
            String::from_utf8_lossy(&snap)
        );
    }

    let mut c = Vt::new(cols, rows);
    c.feed(b"\x1b[31mjunk\x1b[?1049h\x1b[5;10rmore\x1b]2;old\x07\x1b[?2004h");
    c.feed(&snap);
    assert_eq!(c.screen_text(), a.screen_text(), "dirty terminal did not converge");
    assert_eq!(c.cursor(), a.cursor());

    // A snapshot of the copy must reproduce the same state again (a daemon restarted twice).
    let mut d = Vt::new(cols, rows);
    d.feed(&b.snapshot(None));
    assert!(d.state_dump() == da, "second-generation snapshot differs");
}

#[test]
fn plain_and_colors() {
    roundtrip(40, 10, b"hello\r\n\x1b[1;31mred bold\x1b[0m normal \x1b[38;5;200mindexed\x1b[48;2;10;20;30m rgb bg \x1b[0m\r\n\x1b[3;4;9mstyled\x1b[0m");
}

#[test]
fn underline_styles_and_colors() {
    roundtrip(40, 6, b"\x1b[4:3;58;2;255;0;0mcurly\x1b[0m \x1b[4:2;58;5;33mdouble\x1b[0m \x1b[2;7;8mdim-inv-hid\x1b[0m");
}

#[test]
fn erase_with_background_keeps_color() {
    roundtrip(20, 5, b"\x1b[44mblue line\x1b[K\r\n\x1b[0mplain\r\n\x1b[42m\x1b[2K");
}

#[test]
fn wrapped_lines_and_scrollback() {
    let mut input = Vec::new();
    for i in 0..300 {
        input.extend_from_slice(format!("line {i} {}\r\n", "x".repeat(i % 50)).as_bytes());
    }
    roundtrip(20, 8, &input);
}

#[test]
fn wide_and_combining_chars() {
    roundtrip(11, 5, "abc漢字テスト😀wide at edge 漢漢漢漢漢漢\r\ne\u{301}combining x\u{20dd}".as_bytes());
}

#[test]
fn pending_wrap_cursor() {
    roundtrip(10, 4, b"0123456789");
    roundtrip(10, 4, "abcdefgh漢".as_bytes());
}

#[test]
fn alt_screen_with_primary_content() {
    let mut input = Vec::new();
    for i in 0..40 {
        input.extend_from_slice(format!("shell {i}\r\n").as_bytes());
    }
    input.extend_from_slice(b"$ vim\x1b[?1049h\x1b[H\x1b[2J\x1b[1;1H~\r\n~\r\n\x1b[7m status \x1b[0m\x1b[2;3H");
    roundtrip(30, 10, &input);
}

#[test]
fn scroll_region_origin_and_saved_cursor() {
    roundtrip(30, 10, b"top\x1b[3;8r\x1b[5;5Hin region\x1b7\x1b[1;1Hmoved");
    roundtrip(30, 10, b"\x1b[2;6r\x1b[?6h\x1b[3;4Hrel");
}

#[test]
fn modes_title_palette_cursor_style() {
    roundtrip(
        30,
        6,
        b"\x1b[?1h\x1b=\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b[?25l\x1b[5 q\x1b]2;my title\x07\x1b]4;1;rgb:12/34/56\x1b\\\x1b]11;rgb:ff/ff/ee\x07text\x1b[?7l\x1b[4h",
    );
}

#[test]
fn hyperlinks() {
    roundtrip(30, 4, b"see \x1b]8;id=x1;https://example.com\x1b\\link\x1b]8;;\x1b\\ and \x1b]8;;https://a.b\x07anon\x1b]8;;\x07 end");
}

#[test]
fn pen_and_link_left_open() {
    roundtrip(30, 4, b"\x1b[1;32mstill green \x1b]8;;https://x.y\x1b\\");
}

#[test]
fn history_limit() {
    let mut a = Vt::new(20, 5);
    for i in 0..100 {
        a.feed(format!("{i}\r\n").as_bytes());
    }
    let mut b = Vt::new(20, 5);
    b.feed(&a.snapshot(Some(10)));
    assert_eq!(b.screen_text(), a.screen_text());
    assert_eq!(b.term.grid().history_size(), 10);
}

#[test]
fn replies_to_queries() {
    let mut vt = Vt::new(80, 24);
    let ev = vt.feed(b"ab\x1b[6n\x1b[c");
    assert_eq!(ev[0], VtEvent::Reply(b"\x1b[1;3R".to_vec()));
    assert!(matches!(&ev[1], VtEvent::Reply(r) if r.starts_with(b"\x1b[?")));
}

#[test]
fn osc7_cwd() {
    let mut vt = Vt::new(80, 24);
    let ev = vt.feed(b"\x1b]7;file://host/Users/me/my%20dir\x07");
    assert_eq!(ev, vec![VtEvent::Cwd("/Users/me/my dir".into())]);
}

#[test]
fn snapshot_mid_sync_update_includes_held_bytes() {
    let mut a = Vt::new(20, 4);
    a.feed(b"before\x1b[?2026h\r\nduring");
    let mut b = Vt::new(20, 4);
    b.feed(&a.snapshot(None));
    assert_eq!(b.screen_text()[1], "during");
}

/// Random mixes of text and escape sequences. Each must survive a snapshot round trip.
#[test]
fn randomized_roundtrips() {
    const PIECES: &[&str] = &[
        "abc", "hello world ", "漢字", "😀", "e\u{301}", "\r\n", "\n", "\r", "\t", "\x08",
        "\x1b[1m", "\x1b[0m", "\x1b[31m", "\x1b[44m", "\x1b[38;5;123m", "\x1b[48;2;1;2;3m", "\x1b[4:3m",
        "\x1b[7m", "\x1b[K", "\x1b[1K", "\x1b[2K", "\x1b[J", "\x1b[2J", "\x1b[H", "\x1b[3;5H", "\x1b[10;1H",
        "\x1b[A", "\x1b[2B", "\x1b[5C", "\x1b[D", "\x1b[2L", "\x1b[M", "\x1b[3P", "\x1b[2@", "\x1b[S", "\x1b[T",
        "\x1b7", "\x1b8", "\x1b[2;6r", "\x1b[r", "\x1bM", "\x1bD", "\x1bE", "\x1b[?1049h", "\x1b[?1049l",
        "\x1b[?47h", "\x1b[?47l", "\x1b[?25l", "\x1b[?25h", "\x1b[?7l", "\x1b[?7h", "\x1b[?6h", "\x1b[?6l",
        "\x1b[4h", "\x1b[4l", "\x1b]2;t\x07", "\x1b]8;;http://x\x1b\\", "\x1b]8;;\x1b\\", "\x1b[?2004h",
        "\x1b[?1000h", "\x1b[3 q", "\x1b[X", "\x1b[3X", "\x1b[s", "\x1b[u", "\x1b[3g", "\x1b[20G",
        "0123456789012345678901234567890",
    ];
    let seed0: u64 = std::env::var("VT_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0x9e3779b97f4a7c15);
    let mut seed = seed0;
    let mut next = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let rounds = std::env::var("VT_ROUNDS").ok().and_then(|v| v.parse().ok()).unwrap_or(3000);
    let mut gated = 0;
    for round in 0..rounds {
        let mut input = String::new();
        let n = 5 + next() % 120;
        for _ in 0..n {
            input.push_str(PIECES[(next() % PIECES.len() as u64) as usize]);
        }
        // Origin mode plus a cursor restore can leave the cursor outside the scroll region,
        // which CUP cannot express (known gap, no real application does it).
        if input.contains("\x1b[?6h") && (input.contains("\x1b8") || input.contains("\x1b[u") || input.contains("\x1b[?1049l")) {
            continue;
        }
        let (cols, rows) = (8 + (next() % 30) as u16, 3 + (next() % 12) as u16);
        // Known, accepted gap (see lib docs); skipped explicitly so it can't hide anything else.
        let mut probe = Vt::new(cols, rows);
        probe.feed(input.as_bytes());
        if probe.has_unrepresentable_wide_pair() {
            gated += 1;
            continue;
        }
        let result = std::panic::catch_unwind(|| roundtrip(cols, rows, input.as_bytes()));
        if let Err(e) = result {
            let _ = std::fs::write(std::env::temp_dir().join(format!("vt-fail-{cols}x{rows}.bin")), &input);
            panic!(
                "round {round} ({cols}x{rows}) of seed {seed0} failed; reproduce with VT_SEED={seed0} VT_ROUNDS={}\ninput {:?}: {:?}",
                round + 1,
                input,
                e.downcast_ref::<String>()
            );
        }
    }
    assert!(gated * 1000 < rounds, "{gated} of {rounds} rounds hit the gated case");
}

#[test]
#[ignore]
fn debug_case() {
    let input = std::fs::read(std::env::var("VT_CASE").unwrap()).unwrap();
    let cols: u16 = std::env::var("VT_COLS").unwrap().parse().unwrap();
    let rows: u16 = std::env::var("VT_ROWS").unwrap().parse().unwrap();
    let mut a = Vt::new(cols, rows);
    a.feed(&input);
    let snap = a.snapshot(None);
    let mut b = Vt::new(cols, rows);
    if std::env::var("VT_DIRTY").is_ok() {
        b.feed(b"\x1b[31mjunk\x1b[?1049h\x1b[5;10rmore\x1b]2;old\x07\x1b[?2004h");
    }
    b.feed(&snap);
    println!("{:?}", String::from_utf8_lossy(&snap));
    for (name, vt) in [("A", &a), ("B", &b)] {
        let g = vt.term.grid();
        println!("{name}: history {}", g.history_size());
        for l in g.topmost_line().0..=g.bottommost_line().0 {
            let row = &g[Line(l)];
            let s: String = (0..g.columns()).map(|c| {
                let f = row[Column(c)].flags;
                if f.contains(Flags::WIDE_CHAR_SPACER) { '_' } else if f.contains(Flags::LEADING_WIDE_CHAR_SPACER) { '<' } else if row[Column(c)].c == ' ' { '.' } else if row[Column(c)].c == '\t' { 'T' } else { row[Column(c)].c }
            }).collect();
            println!("{l:4} {s}{}", if row[Column(g.columns() - 1)].flags.contains(Flags::WRAPLINE) { " W" } else { "" });
            let bgs: String = (0..g.columns()).map(|c| match row[Column(c)].bg { Color::Named(NamedColor::Background) => '.', _ => 'B' }).collect();
            println!("     {bgs}");
        }
    }
}

#[test]
fn queries_inside_a_sync_update_are_answered_when_it_is_applied() {
    let mut vt = Vt::new(80, 24);
    assert!(vt.feed(b"\x1b[?2026h\x1b[6n\x1b[c").is_empty(), "held while the update is open");
    let ev = vt.flush_sync();
    assert!(ev.iter().any(|e| matches!(e, VtEvent::Reply(r) if r == b"\x1b[1;1R")), "{ev:?}");
    assert!(vt.flush_sync().is_empty(), "answered once");

    // A snapshot applies the held bytes too; their replies come out of take_events, once.
    let mut vt = Vt::new(80, 24);
    vt.feed(b"\x1b[?2026h\x1b[6n");
    vt.snapshot(None);
    assert_eq!(vt.take_events().len(), 1);
    assert!(vt.feed(b"x").is_empty());
}

#[test]
fn tracks_kitty_flags_per_screen_and_through_snapshots() {
    let mut vt = Vt::new(80, 24);
    vt.feed(b"\x1b[>1u");
    assert_eq!(vt.input_modes().kitty, 1);
    vt.feed(b"\x1b[=8;2u");
    assert_eq!(vt.input_modes().kitty, 9);
    vt.feed(b"\x1b[?1049h");
    assert_eq!(vt.input_modes().kitty, 0, "the alternate screen has its own stack");
    vt.feed(b"\x1b[>8u");
    let mut b = Vt::new(80, 24);
    b.feed(&vt.snapshot(None));
    assert_eq!(b.input_modes().kitty, 8, "a rebuilt VT keeps the flags");
    vt.feed(b"\x1b[?1049l");
    assert_eq!(vt.input_modes().kitty, 9);
    vt.feed(b"\x1b[<u");
    assert_eq!(vt.input_modes().kitty, 0);
    vt.feed(b"\x1b[?1h\x1b[?2004h");
    let m = vt.input_modes();
    assert!(m.app_cursor && m.bracketed_paste);
}

#[test]
fn osc52_store_becomes_a_clipboard_event() {
    let mut vt = Vt::new(80, 24);
    // "héllo\n" in base64, BEL- and ST-terminated, and split across feeds.
    let ev = vt.feed(b"\x1b]52;c;aMOpbGxvCg==\x07");
    assert_eq!(ev, vec![VtEvent::Clipboard { selection: false, text: "héllo\n".into() }]);
    assert!(vt.feed(b"\x1b]52;c;aMOp").is_empty());
    let ev = vt.feed(b"bGxvCg==\x1b\\");
    assert_eq!(ev, vec![VtEvent::Clipboard { selection: false, text: "héllo\n".into() }]);
    // An empty target means the clipboard; `p` and `s` are the selection.
    assert_eq!(vt.feed(b"\x1b]52;;eA==\x07"), vec![VtEvent::Clipboard { selection: false, text: "x".into() }]);
    assert_eq!(vt.feed(b"\x1b]52;p;eA==\x07"), vec![VtEvent::Clipboard { selection: true, text: "x".into() }]);
    // Not base64, or not UTF-8: nothing.
    assert!(vt.feed(b"\x1b]52;c;!!!\x07").is_empty());
    assert!(vt.feed(b"\x1b]52;c;/w==\x07").is_empty());
    // Nothing reaches the screen.
    assert!(vt.screen_text().iter().all(|l| l.trim().is_empty()));
}

#[test]
fn osc52_reads_are_never_answered() {
    for scrollback in [DEFAULT_SCROLLBACK, 10] {
        let mut vt = Vt::with_scrollback(80, 24, scrollback);
        vt.set_scrollback(scrollback + 1); // rebuilds the term config
        vt.take_events(); // set_options re-announces the title
        let ev = vt.feed(b"\x1b]52;c;?\x07");
        assert!(ev.is_empty(), "{ev:?}");
        assert!(vt.feed(b"\x1b]52;p;?\x1b\\").is_empty());
    }
}

/// An OSC that never ends must not grow the terminal without bound: past MAX_OSC it is dropped
/// whole (nothing dispatched, no bell), and the terminal works normally after its terminator.
#[test]
fn an_endless_osc_is_dropped_not_buffered() {
    for end in [&b"\x07"[..], b"\x1b\\"] {
        let mut vt = Vt::new(20, 3);
        let mut events = vt.feed(b"\x1b]0;");
        let chunk = vec![b'A'; 1 << 20];
        for _ in 0..(MAX_OSC >> 20) + 2 {
            events.extend(vt.feed(&chunk));
        }
        assert!(vt.guard.buf.capacity() <= MAX_OSC + 1, "held {} bytes", vt.guard.buf.capacity());
        events.extend(vt.feed(end));
        events.extend(vt.feed(b"\x1b]2;ok\x07hi"));
        assert_eq!(events, vec![VtEvent::Title(Some("ok".into()))], "nothing from the dropped OSC, not even a bell");
        assert_eq!(vt.screen_text()[0].trim_end(), "hi");
    }
}

/// OSC strings split across feeds, back to back, and ended every way vte ends them still work.
#[test]
fn osc_guard_keeps_normal_sequences_intact() {
    let input: &[u8] = b"a\x1b]2;one\x07b\x1b]2;two\x1b\\c\x1b]7;file://h/tmp\x1b\\\x1b]2;three\x18d\x1b[1me\x1b";
    for split in 0..input.len() {
        let mut vt = Vt::new(20, 3);
        let mut ev = vt.feed(&input[..split]);
        ev.extend(vt.feed(&input[split..]));
        let titles: Vec<_> = ev.iter().filter_map(|e| if let VtEvent::Title(t) = e { t.clone() } else { None }).collect();
        assert_eq!(titles, ["one", "two", "three"], "split at {split}");
        assert_eq!(vt.cwd(), Some("/tmp"));
        assert_eq!(vt.screen_text()[0].trim_end(), "abcde", "split at {split}");
    }
}

/// Titles keep no control characters (C1 ones like U+009C would end the OSC early in a client
/// that honours them) and are capped; an OSC 7 cwd with control characters is ignored.
#[test]
fn titles_and_cwds_are_printable_and_bounded() {
    let mut vt = Vt::new(20, 3);
    vt.feed("\x1b]2;a\u{9c}b\u{9b}2Jc\x7fd\x07".as_bytes());
    assert_eq!(vt.title(), Some("ab2Jcd"));
    vt.feed(format!("\x1b]2;{}\x07", "x".repeat(MAX_TITLE * 2)).as_bytes());
    assert_eq!(vt.title().unwrap().chars().count(), MAX_TITLE);
    vt.feed(b"\x1b]7;file://h/ok\x07");
    vt.feed(b"\x1b]7;file://h/bad%0Aline\x07");
    assert_eq!(vt.cwd(), Some("/ok"));
    let snap = vt.snapshot(None);
    assert!(!String::from_utf8_lossy(&snap).contains('\u{9c}'));
}

fn found(vt: &Vt, q: &str, regex: bool, case: bool) -> Vec<(i32, usize, i32, usize, String)> {
    let r = vt.search(q, regex, case, None, 100, std::time::Duration::from_secs(5)).unwrap();
    r.matches.into_iter().map(|m| (m.start.line, m.start.col, m.end.line, m.end.col, m.text)).collect()
}

#[test]
fn search_finds_matches_in_scrollback_and_screen_newest_first() {
    let mut vt = Vt::with_scrollback(20, 3, 100);
    vt.feed(b"alpha Error one\r\nbeta\r\nerror two\r\ngamma\r\nERROR three");
    // 5 lines on a 3-row screen: rows 0..2 are "error two", "gamma", "ERROR three".
    assert_eq!(
        found(&vt, "error", false, false),
        vec![(2, 0, 2, 4, "ERROR".into()), (0, 0, 0, 4, "error".into()), (-2, 6, -2, 10, "Error".into())]
    );
    assert_eq!(found(&vt, "error", false, true), vec![(0, 0, 0, 4, "error".into())]);
    // Literal: regex metacharacters match themselves.
    vt.feed(b"\r\na.b (x) a+b");
    assert_eq!(found(&vt, "(x)", false, false).len(), 1);
    assert_eq!(found(&vt, "a.b", false, false).len(), 1);
    assert_eq!(found(&vt, "a.b", true, false).len(), 2, "regex: . matches +");
    assert_eq!(found(&vt, "t[a-z]o", true, false), vec![(-1, 6, -1, 8, "two".into())]);
    assert!(vt.search("(", true, false, None, 10, std::time::Duration::from_secs(1)).is_err());
}

#[test]
fn search_joins_soft_wraps_and_pages_with_before() {
    let mut vt = Vt::with_scrollback(10, 4, 1000);
    // "needle" wrapped over the row boundary: cols 7..9 then 0..2 of the next row.
    vt.feed(b"1234567nee\x1b[2;1Hdle rest");
    let m = vt.search("needle", false, false, None, 10, std::time::Duration::from_secs(1)).unwrap();
    // Not a soft wrap (cursor moved), so no match; a real wrap matches.
    assert!(m.matches.is_empty());
    let mut vt = Vt::with_scrollback(10, 4, 1000);
    vt.feed(b"1234567needle rest");
    let m = vt.search("needle", false, false, None, 10, std::time::Duration::from_secs(1)).unwrap();
    assert_eq!((m.matches[0].start, m.matches[0].end), (Pos { line: 0, col: 7 }, Pos { line: 1, col: 2 }));
    assert_eq!(m.matches[0].line_text, "1234567needle rest");

    let mut vt = Vt::with_scrollback(30, 5, 1000);
    for i in 0..50 {
        vt.feed(format!("line {i} hit\r\n").as_bytes());
    }
    let mut all = Vec::new();
    let mut before = None;
    loop {
        let r = vt.search("hit", false, false, before, 7, std::time::Duration::from_secs(1)).unwrap();
        all.extend(r.matches.iter().map(|m| m.line_text.clone()));
        match r.next {
            Some(n) => before = Some(n),
            None => break,
        }
    }
    let want: Vec<String> = (0..50).rev().map(|i| format!("line {i} hit")).collect();
    assert_eq!(all, want, "pages cover every match once, newest first");
}

#[test]
fn search_anchors_are_the_ends_of_the_text_on_a_line() {
    let mut vt = Vt::with_scrollback(20, 3, 100);
    vt.feed(b"row-1\r\nxrow-2\r\nrow-3  \r\n");
    let n = |q: &str| vt.search(q, true, false, None, 100, std::time::Duration::from_secs(1)).unwrap().matches.len();
    assert_eq!((n("^row-[0-9]+"), n("row-[0-9]+$"), n("^row-[0-9]+$")), (2, 3, 2));
    // Patterns that could match inside each other count once.
    assert_eq!(n("o*"), 3);
}

/// How long a search of a full scrollback takes (cargo test --release -- --ignored --nocapture).
#[test]
#[ignore]
fn search_latency_probe() {
    let mut vt = Vt::with_scrollback(120, 40, 50_000);
    let line: String = (0..118).map(|i| (b'a' + (i % 26) as u8) as char).collect();
    for i in 0..50_100 {
        vt.feed(format!("{i:06} {line}\r\n").as_bytes());
    }
    let small = Vt::new(20, 3);
    let t = Instant::now();
    small.search("x", false, false, None, 1, std::time::Duration::from_secs(1)).unwrap();
    eprintln!("empty terminal: {:?}", t.elapsed());
    for (q, regex) in [("no-such-text", false), ("004242", false), ("[0-9]{6} abc", true)] {
        let t = Instant::now();
        let r = vt.search(q, regex, false, None, 100, std::time::Duration::from_secs(10)).unwrap();
        eprintln!("{q:?} over {} lines: {} matches in {:?}", vt.history_len() + 40, r.matches.len(), t.elapsed());
    }
}
