//! Notification text: when an agent's attention rises, a small model (Claude Haiku, through the
//! machine's own `claude` login) rewrites what the agent said into one or two plain sentences
//! for a lock screen (PLAN.md, "Notification text"). Pushes are sealed on this machine, so this
//! happens here, before sealing. It never blocks or drops anything: the push waits at most
//! `push_wait()` for it, and without it the cleaned original ([`plain`]) is used.
//!
//! Safety: the helper runs from a private empty directory, with only the project and local
//! setting sources (the user's settings, hooks, plugins and MCP servers stay out), no tools, no
//! session history, a clean environment (no CLOTHO_* pane variables, no API keys), at most
//! `SLOTS` at a time. It is not in any pane, so agent detection never sees it. An ephemeral
//! (test) instance never runs the real `claude`: only a program named by
//! `$CLOTHOD_SUMMARIZER`, which tests set to a fake.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{watch, Semaphore};

/// What the model is told. Short on purpose: the input says what kind of moment it is.
pub const SYSTEM: &str = "You rewrite a coding agent's status into a phone notification. \
Reply with only the notification text: plain text, no Markdown, no quotes, no preamble, \
one or two short sentences, at most 160 characters. State what the agent did or what it needs \
from the user, in its own terms; never comment on the message or on what it leaves out. \
Keep a question as a question. For a permission request, say plainly what it wants to do; the \
exact command is shown next to your text.";

/// Rewrites running at once; more wait their turn (within the time limit).
const SLOTS: usize = 2;
/// Rewrites remembered, by their input.
const CACHE: usize = 128;
/// Longest rewrite kept, in characters (the model is asked for 160).
const MAX_CHARS: usize = 200;
/// Each input text is cut to this many characters before it goes to the model.
const MAX_INPUT: usize = 2000;

/// How long a push waits for the rewrite before it goes with the cleaned original.
pub fn push_wait() -> Duration {
    ms_env("CLOTHOD_SUMMARY_WAIT_MS").unwrap_or(Duration::from_secs(6))
}

/// How long a rewrite may take at all (a late one still reaches the model, `agent.summary`).
fn default_limit() -> Duration {
    ms_env("CLOTHOD_SUMMARY_TIMEOUT_MS").unwrap_or(Duration::from_secs(30))
}

fn ms_env(k: &str) -> Option<Duration> {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).map(Duration::from_millis)
}

/// What the model gets: the moment (kind, state) and the agent's words.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Input {
    pub kind: String,
    pub state: String,
    pub message: Option<String>,
    pub prompt: Option<String>,
    pub tool: Option<String>,
    pub tool_input: Option<String>,
    /// Waiting on a permission request (not a question).
    pub permission: bool,
}

impl Input {
    /// Worth a rewrite: something the agent said, or a tool it asks about.
    pub fn useful(&self) -> bool {
        let some = |t: &Option<String>| t.as_deref().is_some_and(|t| !t.trim().is_empty());
        some(&self.message) || (self.state == "waiting" && some(&self.tool))
    }

    /// The user message: labelled lines, each text cut to MAX_INPUT.
    pub fn prompt_text(&self) -> String {
        let cut = |t: &str| t.chars().take(MAX_INPUT).collect::<String>();
        let moment = match (self.state.as_str(), self.permission) {
            ("waiting", true) => "waiting: asks permission to use a tool",
            ("waiting", false) => "waiting: needs an answer from the user",
            ("done", _) => "done: finished its turn",
            ("error", _) => "error: stopped with an error",
            (s, _) => s,
        };
        let mut s = format!("Agent: {}\nState: {moment}\n", cut(&self.kind));
        for (label, t) in [("The user had asked", &self.prompt), ("Tool", &self.tool), ("Tool input", &self.tool_input)] {
            if let Some(t) = t.as_deref().filter(|t| !t.trim().is_empty()) {
                s += &format!("{label}: {}\n", cut(t.trim()));
            }
        }
        if let Some(m) = self.message.as_deref().filter(|t| !t.trim().is_empty()) {
            s += &format!("The agent's message:\n{}\n", cut(m.trim()));
        }
        s
    }
}

pub struct Summarizer {
    enabled: AtomicBool,
    /// Where each run gets its own empty directory (the instance's runtime dir).
    dir: PathBuf,
    slots: Semaphore,
    cache: Mutex<(HashMap<String, String>, VecDeque<String>)>,
    next: AtomicU64,
    /// How long one rewrite may take, waiting for a slot included.
    pub limit: Duration,
    /// Runs started (for `clothod status`-style checks and tests).
    pub runs: AtomicU64,
}

impl Summarizer {
    pub fn new(dir: &Path, enabled: bool) -> Arc<Summarizer> {
        Arc::new(Summarizer {
            enabled: AtomicBool::new(enabled),
            dir: dir.to_path_buf(),
            slots: Semaphore::new(SLOTS),
            cache: Mutex::new((HashMap::new(), VecDeque::new())),
            next: AtomicU64::new(1),
            limit: default_limit(),
            runs: AtomicU64::new(0),
        })
    }

    pub fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    pub fn set_enabled(&self, on: bool) {
        self.enabled.store(on, Ordering::Relaxed);
    }

    /// Start a rewrite, if it is on and there is a program to run. The receiver gets
    /// `Some(text)` when it succeeds; on failure (or the time limit) its sender is dropped.
    pub fn start(self: &Arc<Self>, input: Input) -> Option<watch::Receiver<Option<String>>> {
        if !self.enabled() || !input.useful() {
            return None;
        }
        let program = program()?;
        let (tx, rx) = watch::channel(None);
        let me = self.clone();
        tokio::spawn(async move {
            match me.rewrite(&program, &input).await {
                Ok(t) => {
                    let _ = tx.send(Some(t));
                }
                Err(why) => eprintln!("clothod: notification rewrite failed ({why}); using the original text"),
            }
        });
        Some(rx)
    }

    /// Rewrite `input` with `program` (cached by input), within the time limit.
    pub async fn rewrite(&self, program: &Path, input: &Input) -> Result<String, String> {
        let key = input.prompt_text();
        if let Some(t) = self.cache.lock().unwrap().0.get(&key) {
            return Ok(t.clone());
        }
        let text = tokio::time::timeout(self.limit, async {
            let _slot = self.slots.acquire().await.map_err(|_| "closed".to_string())?;
            self.runs.fetch_add(1, Ordering::Relaxed);
            self.run(program, &key).await
        })
        .await
        .map_err(|_| format!("no answer within {:?}", self.limit))??;
        let mut c = self.cache.lock().unwrap();
        if c.0.insert(key.clone(), text.clone()).is_none() {
            c.1.push_back(key);
            while c.1.len() > CACHE {
                if let Some(old) = c.1.pop_front() {
                    c.0.remove(&old);
                }
            }
        }
        Ok(text)
    }

    async fn run(&self, program: &Path, prompt: &str) -> Result<String, String> {
        let n = self.next.fetch_add(1, Ordering::Relaxed);
        let cwd = Scratch::new(self.dir.join(format!("summary-{}-{n}", std::process::id()))).map_err(|e| format!("no scratch dir: {e}"))?;
        let mut cmd = tokio::process::Command::new(program);
        cmd.args(args())
            .current_dir(&cwd.0)
            .env_clear()
            .envs(environment(program))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .process_group(0);
        let mut child = cmd.spawn().map_err(|e| format!("can't run {}: {e}", program.display()))?;
        let mut stdin = child.stdin.take().unwrap();
        let prompt = prompt.to_string();
        let writer = tokio::spawn(async move {
            let _ = stdin.write_all(prompt.as_bytes()).await;
        });
        let mut out = Vec::new();
        child.stdout.take().unwrap().take(16 << 10).read_to_end(&mut out).await.map_err(|e| e.to_string())?;
        let _ = writer.await;
        let status = child.wait().await.map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(format!("exit {status}"));
        }
        let text = String::from_utf8_lossy(&out);
        // `claude -p` prints its errors (not logged in, out of credit) as its answer.
        let lower = text.to_lowercase();
        if ["/login", "api error", "credit balance", "invalid api key", "rate limit"].iter().any(|e| lower.contains(e)) {
            return Err("claude reported an error".into());
        }
        let text = shorten(&plain(&text), MAX_CHARS);
        if text.is_empty() {
            return Err("empty answer".into());
        }
        Ok(text)
    }
}

/// An empty private directory, removed with everything in it when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(path: PathBuf) -> std::io::Result<Scratch> {
        use std::os::unix::fs::DirBuilderExt;
        let _ = std::fs::remove_dir_all(&path);
        std::fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Scratch(path))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn args() -> Vec<String> {
    [
        "-p",
        "--model",
        "haiku",
        "--setting-sources",
        "project,local",
        "--no-session-persistence",
        "--tools",
        "",
        "--strict-mcp-config",
        "--no-chrome",
        "--output-format",
        "text",
        "--system-prompt",
        SYSTEM,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// A clean environment: what `claude` needs to find its login, nothing from panes
/// (CLOTHO_*), no API keys (it uses the login, not a key).
fn environment(program: &Path) -> Vec<(String, String)> {
    const KEEP: &[&str] = &[
        "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
        "CLAUDE_CONFIG_DIR",
    ];
    let mut env: Vec<(String, String)> = KEEP.iter().filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v))).collect();
    let mut path = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
    if let Some(d) = program.parent() {
        path = format!("{}:{path}", d.display());
    }
    env.push(("PATH".into(), path));
    // No auto-updates, telemetry or other side traffic from a background helper.
    env.push(("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(), "1".into()));
    env
}

/// The program to run: `$CLOTHOD_SUMMARIZER` if set (tests: a fake), else, outside ephemeral
/// instances, the user's `claude` (on PATH, or where its installers put it).
pub fn program() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("CLOTHOD_SUMMARIZER").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    if clotho_proto::platform::ephemeral().is_some() {
        return None;
    }
    find_claude()
}

fn find_claude() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Some(h) = &home {
        dirs.push(h.join(".local/bin"));
        dirs.push(h.join(".claude/local"));
    }
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from));
    dirs.into_iter().map(|d| d.join("claude")).find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// At most `max` characters, cut at a word and ended with "…" when cut.
pub fn shorten(t: &str, max: usize) -> String {
    if t.chars().count() <= max {
        return t.to_string();
    }
    let head: String = t.chars().take(max - 1).collect();
    let cut = head.rfind(' ').filter(|&i| i > max / 2).map_or(head.as_str(), |i| &head[..i]);
    format!("{}…", cut.trim_end_matches([' ', ',', ';', ':', '.']))
}

/// Markdown to plain text for a notification: no emphasis or code marks, no fences, link or
/// image syntax (the text stays), list items as "• ", whitespace collapsed to single spaces (one
/// line). Heading lines ("## Summary") go, unless the text has nothing else.
pub fn plain(md: &str) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut headings: Vec<String> = Vec::new();
    for line in md.lines() {
        let t = line.trim();
        if t.starts_with("```") || t.starts_with("~~~") {
            continue;
        }
        if t.chars().all(|c| matches!(c, '-' | '*' | '_' | '=' | ' ')) && t.len() >= 3 {
            continue; // rules and setext underlines
        }
        let t = t.trim_start_matches('>').trim_start();
        if let Some(i) = t.find(|c| c != '#').filter(|&i| i > 0 && i <= 6 && t[i..].starts_with(' ')) {
            let h = inline(t[i..].trim());
            if !h.is_empty() {
                headings.push(h);
            }
            continue;
        }
        let (bullet, t) = list_item(t);
        let t = inline(t);
        if t.is_empty() {
            continue;
        }
        parts.push(if bullet { format!("• {t}") } else { t });
    }
    if parts.is_empty() {
        parts = headings;
    }
    parts.join(" ").split_whitespace().collect::<Vec<_>>().join(" ")
}

/// "- x", "* x", "+ x", "1. x", "1) x", "- [ ] x" → (true, "x").
fn list_item(t: &str) -> (bool, &str) {
    let rest = if let Some(r) = t.strip_prefix("- ").or_else(|| t.strip_prefix("* ")).or_else(|| t.strip_prefix("+ ")) {
        Some(r)
    } else {
        let digits = t.chars().take_while(char::is_ascii_digit).count();
        (digits > 0 && digits < 4).then(|| &t[digits..]).and_then(|r| r.strip_prefix(". ").or_else(|| r.strip_prefix(") ")))
    };
    match rest {
        Some(r) => {
            let r = r.trim_start();
            let r = ["[ ] ", "[x] ", "[X] "].iter().find_map(|p| r.strip_prefix(p)).unwrap_or(r);
            (true, r)
        }
        None => (false, t),
    }
}

/// Inline Markdown: `code`, **bold**, *em*, __bold__, _em_, ~~strike~~, [text](url),
/// ![alt](url), <https://autolinks>. Underscores inside words (snake_case) stay.
fn inline(t: &str) -> String {
    let c: Vec<char> = t.chars().collect();
    let mut out = String::with_capacity(t.len());
    let mut i = 0;
    while i < c.len() {
        match c[i] {
            '`' => {
                // A code span: its text as is.
                let ticks = c[i..].iter().take_while(|&&x| x == '`').count();
                let start = i + ticks;
                let close = (start..c.len()).find(|&j| c[j..].iter().take_while(|&&x| x == '`').count() == ticks);
                match close {
                    Some(j) => {
                        out.extend(c[start..j].iter());
                        i = j + ticks;
                    }
                    None => i += ticks,
                }
            }
            '!' if c.get(i + 1) == Some(&'[') => i += 1,
            '[' => match link(&c, i) {
                Some((text, end)) => {
                    out += &inline(&text);
                    i = end;
                }
                None => {
                    out.push('[');
                    i += 1;
                }
            },
            '<' if c[i + 1..].starts_with(&['h', 't', 't', 'p']) => match c[i..].iter().position(|&x| x == '>') {
                Some(n) => {
                    out.extend(c[i + 1..i + n].iter());
                    i += n + 1;
                }
                None => {
                    out.push('<');
                    i += 1;
                }
            },
            '*' | '~' => i += 1,
            '_' => {
                let inside = i > 0 && c[i - 1].is_alphanumeric() && c.get(i + 1).is_some_and(|x| x.is_alphanumeric());
                if inside {
                    out.push('_');
                }
                i += 1;
            }
            '\\' if c.get(i + 1).is_some_and(|x| x.is_ascii_punctuation()) => {
                out.push(c[i + 1]);
                i += 2;
            }
            ch => {
                out.push(ch);
                i += 1;
            }
        }
    }
    out
}

/// `[text](url)` at `i`: its text and the index after it.
fn link(c: &[char], i: usize) -> Option<(String, usize)> {
    let mut depth = 0;
    let mut j = i;
    let close = loop {
        match c.get(j)? {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    break j;
                }
            }
            _ => {}
        }
        j += 1;
    };
    if c.get(close + 1) != Some(&'(') {
        return None;
    }
    let end = (close + 2..c.len()).find(|&k| c[k] == ')')?;
    Some((c[i + 1..close].iter().collect(), end + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_becomes_plain_text() {
        let cases = [
            ("**All 61 tests pass.** I fixed `push.rs`.", "All 61 tests pass. I fixed push.rs."),
            ("## Summary\n\nDone.", "Done."),
            ("# Only a heading", "Only a heading"),
            ("- one\n- two\n* three\n1. four\n2) five\n- [x] six", "• one • two • three • four • five • six"),
            ("See [the PR](https://github.com/a/b/pull/1) and ![img](x.png).", "See the PR and img."),
            ("```rust\nfn main() {}\n```\nok", "fn main() {} ok"),
            ("_em_ and __bold__ and snake_case_name and ~~old~~", "em and bold and snake_case_name and old"),
            ("> quoted\n\n---\nafter", "quoted after"),
            ("a\t\tb\n\n\nc   d", "a b c d"),
            ("Use `a*b` and ``x ` y``", "Use a*b and x ` y"),
            ("<https://example.com> \\*not em\\*", "https://example.com *not em*"),
            ("Title\n=====\ntext", "Title text"),
            ("#hashtag stays, # heading goes", "#hashtag stays, # heading goes"),
            ("[unclosed and (paren)", "[unclosed and (paren)"),
            ("", ""),
        ];
        for (md, want) in cases {
            assert_eq!(plain(md), want, "{md:?}");
        }
    }

    #[test]
    fn shorten_cuts_at_a_word() {
        assert_eq!(shorten("short", 10), "short");
        let s = shorten("The tests all pass now, and the flaky one is fixed for good this time.", 40);
        assert!(s.chars().count() <= 40 && s.ends_with('…') && !s.contains("  "), "{s}");
        assert_eq!(shorten(&"é".repeat(50), 10).chars().count(), 10);
    }

    #[test]
    fn the_prompt_says_what_kind_of_moment_it_is() {
        let i = Input {
            kind: "claude".into(),
            state: "waiting".into(),
            message: Some("Claude needs your permission to use Bash".into()),
            prompt: Some("run the tests".into()),
            tool: Some("Bash".into()),
            tool_input: Some("npm test".into()),
            permission: true,
        };
        let p = i.prompt_text();
        assert!(p.contains("asks permission") && p.contains("Tool: Bash") && p.contains("Tool input: npm test") && p.contains("The user had asked: run the tests"), "{p}");
        assert!(i.useful());
        assert!(!Input { state: "done".into(), ..Default::default() }.useful());
        assert!(Input { state: "waiting".into(), tool: Some("Bash".into()), ..Default::default() }.useful());
        let long = Input { state: "done".into(), message: Some("x".repeat(10_000)), ..Default::default() };
        assert!(long.prompt_text().len() < MAX_INPUT + 200);
    }

    #[test]
    fn the_real_claude_is_locked_down() {
        let a = args();
        for want in ["-p", "--no-session-persistence", "--strict-mcp-config", "--no-chrome"] {
            assert!(a.iter().any(|x| x == want), "{want}");
        }
        let after = |k: &str| a[a.iter().position(|x| x == k).unwrap() + 1].clone();
        assert_eq!(after("--model"), "haiku");
        assert_eq!(after("--setting-sources"), "project,local");
        assert_eq!(after("--tools"), "", "no tools at all");
        std::env::set_var("CLOTHO_PANE", "7");
        std::env::set_var("ANTHROPIC_API_KEY", "sk-test");
        let env = environment(Path::new("/x/bin/claude"));
        assert!(env.iter().all(|(k, _)| !k.starts_with("CLOTHO") && k != "ANTHROPIC_API_KEY"), "{env:?}");
        assert!(env.iter().any(|(k, v)| k == "PATH" && v.starts_with("/x/bin:")));
    }

    fn fake(dir: &Path, name: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let p = dir.join(name);
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    fn input(msg: &str) -> Input {
        Input { kind: "claude".into(), state: "done".into(), message: Some(msg.into()), ..Default::default() }
    }

    #[tokio::test]
    async fn rewrites_are_cleaned_cached_and_run_in_an_empty_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let log = tmp.path().join("log");
        let f = fake(tmp.path(), "fake", &format!("cat > /dev/null; ls -A >> {0}; pwd >> {0}; env | grep -c CLOTHO_ >> {0}; echo '**Tests pass.** All `61` green.'", log.display()));
        let s = Summarizer::new(tmp.path(), true);
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap(), "Tests pass. All 61 green.");
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap(), "Tests pass. All 61 green.");
        assert_eq!(s.runs.load(Ordering::Relaxed), 1, "the second came from the cache");
        let l = std::fs::read_to_string(&log).unwrap();
        let lines: Vec<&str> = l.lines().collect();
        assert!(lines[0].contains("summary-"), "an empty cwd (ls printed nothing): {l}");
        assert_eq!(lines[1], "0", "no CLOTHO_ variables: {l}");
        assert!(std::fs::read_dir(tmp.path()).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().starts_with("summary-")), "the scratch dir is gone");
    }

    #[tokio::test]
    async fn failures_are_errors_never_text() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Summarizer::new(tmp.path(), true);
        for (name, body) in [
            ("exit1", "echo 'some text'; exit 1"),
            ("empty", "echo '   '"),
            ("login", "echo 'Invalid API key · Please run /login'"),
        ] {
            assert!(s.rewrite(&fake(tmp.path(), name, body), &input(name)).await.is_err(), "{name}");
        }
        assert!(s.rewrite(Path::new("/nonexistent/claude"), &input("x")).await.is_err());
    }

    #[tokio::test]
    async fn a_slow_rewrite_times_out_and_is_killed() {
        let tmp = tempfile::tempdir().unwrap();
        let mark = tmp.path().join("still-running");
        let f = fake(tmp.path(), "hang", &format!("cat > /dev/null; sleep 2; touch {}; echo late", mark.display()));
        let mut s = Summarizer::new(tmp.path(), true);
        Arc::get_mut(&mut s).unwrap().limit = Duration::from_millis(300);
        let t = std::time::Instant::now();
        assert!(s.rewrite(&f, &input("x")).await.unwrap_err().contains("no answer"));
        assert!(t.elapsed() < Duration::from_secs(1));
        tokio::time::sleep(Duration::from_millis(2500)).await;
        assert!(!mark.exists(), "the helper was killed, not left running");
    }

    #[tokio::test]
    async fn at_most_two_run_at_once() {
        let tmp = tempfile::tempdir().unwrap();
        let log = tmp.path().join("log");
        let f = fake(tmp.path(), "slow", &format!("cat > /dev/null; echo start >> {0}; sleep 0.4; echo end >> {0}; echo ok", log.display()));
        let s = Summarizer::new(tmp.path(), true);
        let all: Vec<_> = (0..5).map(|n| {
            let (s, f) = (s.clone(), f.clone());
            tokio::spawn(async move { s.rewrite(&f, &input(&format!("m{n}"))).await })
        }).collect();
        for h in all {
            assert_eq!(h.await.unwrap().unwrap(), "ok");
        }
        let (mut now, mut most) = (0, 0);
        for l in std::fs::read_to_string(&log).unwrap().lines() {
            now += if l == "start" { 1 } else { -1 };
            most = most.max(now);
        }
        assert_eq!(most, 2);
    }
}
