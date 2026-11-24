//! Notification text: when an agent's attention rises, a small model (Claude Haiku, through the
//! machine's own `claude` login) rewrites what the agent said into one or two plain sentences
//! for a lock screen (PLAN.md, "Notification text"). Pushes are sealed on this machine, so this
//! happens here, before sealing. It never blocks or drops anything: the push waits at most
//! `push_wait()` for it, and without it the cleaned original ([`plain`]) is used.
//!
//! Safety: the helper runs from a private empty directory in Claude Code's safe mode, with the
//! user setting source only. Safe mode turns off hooks, plugins, MCP servers, skills and
//! CLAUDE.md, while the login works as usual: it comes from the user settings' `env` block or
//! from the credentials file or keychain. (The project and local sources alone, used before,
//! left a machine that logs in through its user settings with no login at all.) A Claude Code
//! too old to know `--safe-mode` gets those earlier arguments instead (`legacy`). No tools, no
//! session history, a clean environment (no CLOTHO_* pane variables, no ANTHROPIC_* or other
//! keys from the daemon's own environment), at most `SLOTS` at a time. It is not in any pane, so
//! agent detection never sees it. An ephemeral (test) instance never runs the real `claude`:
//! only a program named by `$CLOTHOD_SUMMARIZER`, which tests set to a fake.
//!
//! Each real run sets the rewrite's health ([`Health`], `notification_rewrite_health` in the
//! settings), and a change of health is logged once, so a rewrite that fails every time is
//! visible instead of silently falling back.
//!
//! For a finished turn the same call also labels it ([`Rewrite::needs_user`]): does the reply
//! end by needing the user, or is it plainly done. [`needs_user_guess`] is the fallback from
//! the text alone.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{watch, Semaphore};

/// What the model is told. Short on purpose: the input says what kind of moment it is.
pub const SYSTEM: &str = "You rewrite a coding agent's status into a phone notification. \
Reply with only the notification text: plain text, no Markdown, no quotes, no preamble, \
one or two short sentences, at most 160 characters. State what the agent did or what it needs \
from the user, in its own terms; never comment on the message or on what it leaves out. \
Keep a question as a question. For a permission request, say plainly what it wants to do; the \
exact command is shown next to your text. When the input asks for a label line, your first \
line is that label alone (NEEDS_USER or DONE) and the notification text follows on the next line.";

/// Added to the input for a finished turn: the label line ([`Rewrite::needs_user`]).
const LABEL: &str = "First line of your reply: exactly NEEDS_USER if the agent's message ends by \
asking the user something, waits on their decision, or says it is blocked; otherwise exactly \
DONE. Then the notification text on the next line.";

/// Rewrites running at once; more wait their turn (within the time limit).
const SLOTS: usize = 2;
/// Rewrites remembered, by their input.
const CACHE: usize = 128;
/// Longest rewrite kept, in characters (the model is asked for 160).
const MAX_CHARS: usize = 200;
/// Each input text is cut to this many characters before it goes to the model.
const MAX_INPUT: usize = 2000;
/// The end of the agent's message (`Input::tail`) is cut to its last this many characters.
const MAX_TAIL: usize = 600;
/// Most of the helper's stderr read (the reason a run failed is its first line).
const MAX_STDERR: u64 = 4 << 10;
/// A failure reason's line from the helper is cut to this many characters.
const MAX_REASON: usize = 120;
/// What `claude -p` prints as its answer, at exit 0, when it could not ask the model, and the
/// fixed reason for each. Never the output itself: at exit 0 that may be message text.
/// Looked for only in a line that has the shape of such an error ([`error_answer`]): a good
/// rewrite may say any of these ("Added rate limit handling to the API client.").
const ERROR_MARKERS: &[(&str, &str)] = &[
    ("/login", "claude said: not logged in"),
    ("api error", "claude said: api error"),
    ("credit balance", "claude said: credit balance"),
    ("invalid api key", "claude said: invalid api key"),
    ("rate limit", "claude said: rate limit"),
];
/// How `claude -p`'s own errors begin (lower case), and the reason when the line has no marker.
const ERROR_PREFIXES: &[(&str, &str)] = &[
    ("api error", "claude said: api error"),
    ("invalid api key", "claude said: invalid api key"),
    ("not logged in", "claude said: not logged in"),
    ("please run /login", "claude said: not logged in"),
    ("credit balance is too low", "claude said: credit balance"),
    ("rate limit reached", "claude said: rate limit"),
    ("rate limit exceeded", "claude said: rate limit"),
];
/// An answer without its label that is one line of at most this many characters may be an error.
const MAX_ERROR_LINE: usize = 200;

/// Whether the helper's answer (at exit 0) is `claude`'s own error instead of a rewrite, and
/// the fixed reason if so. Only claude's error shapes count:
/// - a first line that begins like one of its errors ("API Error: …", "Invalid API key · …",
///   "Not logged in · …"), for any answer;
/// - when a label was asked for (`labelled`) and the answer has none: a single short line with
///   one of the markers in it (the model would have put the label first).
///
/// An answer that is a label line followed by text is the model's, never an error, whatever
/// the text says.
fn error_answer(answer: &str, labelled: bool) -> Option<&'static str> {
    if labelled {
        let (label, body) = split_label(answer);
        if label.is_some() && !body.trim().is_empty() {
            return None;
        }
    }
    let mut lines = answer.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.next()?.to_lowercase();
    let single = lines.next().is_none();
    let marker = || ERROR_MARKERS.iter().find(|(m, _)| first.contains(m)).map(|(_, why)| *why);
    if let Some((_, why)) = ERROR_PREFIXES.iter().find(|(p, _)| first.starts_with(p)) {
        return Some(marker().unwrap_or(why));
    }
    if labelled && single && first.chars().count() <= MAX_ERROR_LINE {
        return marker();
    }
    None
}

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
    /// The end of the agent's last reply (`agent.report`'s `tail`): `message` may be cut, and
    /// whether the user is needed shows at the end.
    pub tail: Option<String>,
}

/// A rewrite: the notification text and, for a finished turn, the model's label.
#[derive(Clone, Debug, PartialEq)]
pub struct Rewrite {
    pub text: String,
    /// The reply ends by asking the user something, waits on their decision or is blocked
    /// (true), or is plainly done (false). None: the answer had no label line.
    pub needs_user: Option<bool>,
}

/// Whether rewrites work on this machine, from the last real run.
#[derive(Clone, Debug, PartialEq)]
pub enum Health {
    /// No run yet.
    Unknown,
    Ok,
    /// Why the last run failed.
    Failing(String),
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
        if let Some(t) = self.tail.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
            s += &format!("The end of the agent's message:\n{}\n", last_chars(t, MAX_TAIL));
        }
        if self.labelled() {
            s += LABEL;
            s.push('\n');
        }
        s
    }

    /// The model is asked for a label line (a finished turn).
    fn labelled(&self) -> bool {
        self.state == "done"
    }
}

/// The last `n` characters of `t`.
fn last_chars(t: &str, n: usize) -> &str {
    match t.char_indices().rev().nth(n.saturating_sub(1)) {
        Some((i, _)) if n > 0 => &t[i..],
        _ => t,
    }
}

/// The model's answer for a finished turn: if its first non-empty line is `NEEDS_USER` or
/// `DONE` (any case), that is the label and the rest is the text. Otherwise there is no label
/// and the whole answer is the text.
fn split_label(answer: &str) -> (Option<bool>, &str) {
    let rest = answer.trim_start();
    let (first, after) = rest.split_once('\n').unwrap_or((rest, ""));
    let label = first.trim().trim_matches(['*', '`']);
    if label.eq_ignore_ascii_case("NEEDS_USER") {
        (Some(true), after)
    } else if label.eq_ignore_ascii_case("DONE") {
        (Some(false), after)
    } else {
        (None, answer)
    }
}

/// Phrases that say the agent waits on the user ([`needs_user_guess`]), lower case, matched
/// as whole words.
const NEEDS_USER_PHRASES: &[&str] = &[
    "let me know", "should i", "do you want", "would you like", "which option", "please confirm",
    "waiting for your", "need your", "i need you to", "blocked", "can't proceed", "cannot proceed",
    "unable to proceed",
];

/// A guess, from the text alone, at whether a finished turn needs the user: the fallback when
/// the model gave no label. Conservative: true only on a clear signal at the end of the reply,
/// which is `tail`, or else `message` when it is short enough (under 300 characters) not to
/// have been cut. A cut message has no visible end, so false.
pub fn needs_user_guess(message: Option<&str>, tail: Option<&str>) -> bool {
    fn some(t: Option<&str>) -> Option<&str> {
        t.map(str::trim).filter(|t| !t.is_empty())
    }
    let Some(end) = some(tail).or_else(|| some(message).filter(|m| m.chars().count() < 300)) else { return false };
    let end = end.trim_end_matches(|c: char| c.is_whitespace() || matches!(c, '*' | '_' | '`' | '~' | '"' | '\'' | '“' | '”' | '‘' | '’' | '»'));
    if end.ends_with(['?', '？']) {
        return true;
    }
    let last = last_chars(end, 200).to_lowercase().replace('’', "'");
    NEEDS_USER_PHRASES.iter().any(|p| {
        last.match_indices(p).any(|(i, _)| {
            let word = |c: Option<char>| c.is_some_and(char::is_alphanumeric);
            !word(last[..i].chars().next_back()) && !word(last[i + p.len()..].chars().next())
        })
    })
}

/// The line to log when the health goes from `old` to `new`: a failure once per distinct
/// reason, and the recovery. None when nothing changed.
fn health_change(old: &Health, new: &Health) -> Option<String> {
    match (old, new) {
        (_, Health::Failing(why)) if old != new => Some(format!("notification rewrite failing: {why}; using the original text")),
        (Health::Failing(_), Health::Ok) => Some("notification rewrite works again".into()),
        _ => None,
    }
}

fn unix_now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub struct Summarizer {
    enabled: AtomicBool,
    /// Where each run gets its own empty directory (the instance's runtime dir).
    dir: PathBuf,
    slots: Semaphore,
    cache: Mutex<(HashMap<String, Rewrite>, VecDeque<String>)>,
    next: AtomicU64,
    /// This `claude` does not know `--safe-mode`: use the earlier arguments (set at the first
    /// such answer, for the life of the process).
    legacy: AtomicBool,
    /// The last real run's result and when it ended (unix seconds).
    health: Mutex<(Health, f64)>,
    /// Health changes logged (tests).
    logged: AtomicU64,
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
            legacy: AtomicBool::new(false),
            health: Mutex::new((Health::Unknown, 0.0)),
            logged: AtomicU64::new(0),
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

    /// The last real run's result (cache hits don't count).
    pub fn health(&self) -> Health {
        self.health.lock().unwrap().0.clone()
    }

    /// `notification_rewrite_health` in the settings: `{"state", "reason", "at"}`. `off` when
    /// the setting is off, `unavailable` when there is no program to run, else `unknown` (no
    /// run yet), `ok`, or `failing` with its reason. `at` is when that run ended.
    pub fn health_json(&self) -> Value {
        self.health_json_for(program().is_some())
    }

    /// `available`: there is a program to run.
    fn health_json_for(&self, available: bool) -> Value {
        let fixed = |state: &str| json!({"state": state, "reason": null, "at": null});
        if !self.enabled() {
            return fixed("off");
        }
        if !available {
            return fixed("unavailable");
        }
        let (health, at) = self.health.lock().unwrap().clone();
        match health {
            Health::Unknown => fixed("unknown"),
            Health::Ok => json!({"state": "ok", "reason": null, "at": at}),
            Health::Failing(why) => json!({"state": "failing", "reason": why, "at": at}),
        }
    }

    /// Record a real run's result, and log it if the health changed.
    fn set_health(&self, new: Health) {
        let line = {
            let mut h = self.health.lock().unwrap();
            let line = health_change(&h.0, &new);
            *h = (new, unix_now());
            line
        };
        if let Some(line) = line {
            self.logged.fetch_add(1, Ordering::Relaxed);
            crate::log::line(&line);
        }
    }

    /// Start a rewrite, if it is on and there is a program to run. The receiver gets
    /// `Some(rewrite)` when it succeeds; on failure (or the time limit) its sender is dropped
    /// (the reason is in the health, and logged when it changes).
    pub fn start(self: &Arc<Self>, input: Input) -> Option<watch::Receiver<Option<Rewrite>>> {
        if !self.enabled() || !input.useful() {
            return None;
        }
        let program = program()?;
        let (tx, rx) = watch::channel(None);
        let me = self.clone();
        tokio::spawn(async move {
            if let Ok(r) = me.rewrite(&program, &input).await {
                let _ = tx.send(Some(r));
            }
        });
        Some(rx)
    }

    /// Rewrite `input` with `program` (cached by input), within the time limit. The error is
    /// the reason, as the health reports it.
    pub async fn rewrite(&self, program: &Path, input: &Input) -> Result<Rewrite, String> {
        let key = input.prompt_text();
        if let Some(r) = self.cache.lock().unwrap().0.get(&key) {
            return Ok(r.clone());
        }
        let result = tokio::time::timeout(self.limit, async {
            let _slot = self.slots.acquire().await.map_err(|_| "closed".to_string())?;
            self.runs.fetch_add(1, Ordering::Relaxed);
            self.run(program, &key, input.labelled()).await
        })
        .await
        .unwrap_or_else(|_| Err(format!("no answer within {:?}", self.limit)));
        self.set_health(match &result {
            Ok(_) => Health::Ok,
            Err(why) => Health::Failing(why.clone()),
        });
        let text = result?;
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

    /// One rewrite. A `claude` that turns out not to know `--safe-mode` is run again, once,
    /// with the earlier arguments, and from then on only with those.
    async fn run(&self, program: &Path, prompt: &str, labelled: bool) -> Result<Rewrite, String> {
        if !self.legacy.load(Ordering::Relaxed) {
            match self.run_once(program, prompt, labelled, false).await {
                Err(why) if no_safe_mode(&why) => self.legacy.store(true, Ordering::Relaxed),
                r => return r,
            }
        }
        self.run_once(program, prompt, labelled, true).await
    }

    async fn run_once(&self, program: &Path, prompt: &str, labelled: bool, legacy: bool) -> Result<Rewrite, String> {
        let n = self.next.fetch_add(1, Ordering::Relaxed);
        let cwd = Scratch::new(self.dir.join(format!("summary-{}-{n}", std::process::id()))).map_err(|e| format!("no scratch dir: {e}"))?;
        let mut cmd = tokio::process::Command::new(program);
        cmd.args(args(legacy))
            .current_dir(&cwd.0)
            .env_clear()
            .envs(environment(program))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .process_group(0);
        let mut child = cmd.spawn().map_err(|e| format!("can't run {}: {e}", program.display()))?;
        let mut stdin = child.stdin.take().unwrap();
        let prompt = prompt.to_string();
        let writer = tokio::spawn(async move {
            let _ = stdin.write_all(prompt.as_bytes()).await;
        });
        // Both pipes are read together (a full one would block the helper), each up to its
        // bound, and closed after it.
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let (stdout, stderr) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
        let (read, _) = tokio::join!(
            async { stdout.take(16 << 10).read_to_end(&mut out).await },
            async { stderr.take(MAX_STDERR).read_to_end(&mut err).await },
        );
        read.map_err(|e| e.to_string())?;
        let _ = writer.await;
        let status = child.wait().await.map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&out);
        if !status.success() {
            // Why: the first line it printed, on stderr or else stdout ("Not logged in · …").
            let err = String::from_utf8_lossy(&err);
            let line = [&err, &text].iter().find_map(|t| t.lines().map(|l| clotho_vt::printable(l.trim(), MAX_REASON)).find(|l| !l.is_empty()));
            let exit = match status.code() {
                Some(code) => format!("exit {code}"),
                None => status.to_string(),
            };
            return Err(match line {
                Some(line) => format!("{exit}: {line}"),
                None => exit,
            });
        }
        // `claude -p` prints its errors (not logged in, out of credit) as its answer.
        if let Some(why) = error_answer(&text, labelled) {
            return Err(why.to_string());
        }
        let (needs_user, body) = if labelled { split_label(&text) } else { (None, &*text) };
        let text = shorten(&plain(body), MAX_CHARS);
        if text.is_empty() {
            return Err("empty answer".into());
        }
        Ok(Rewrite { text, needs_user })
    }
}

/// A failed run's reason says this `claude` is too old for `--safe-mode`
/// ("exit 1: error: unknown option '--safe-mode'").
fn no_safe_mode(why: &str) -> bool {
    let why = why.to_lowercase();
    why.starts_with("exit ") && why.contains("unknown option") && why.contains("safe-mode")
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

/// The helper's arguments. `legacy`: for a Claude Code without `--safe-mode`, the project and
/// local setting sources only (no user settings, so no hooks or plugins, and no login from
/// the settings' `env` block either).
fn args(legacy: bool) -> Vec<String> {
    let sources: &[&str] = if legacy { &["--setting-sources", "project,local"] } else { &["--safe-mode", "--setting-sources", "user"] };
    let rest = [
        "-p",
        "--model",
        "haiku",
        "--no-session-persistence",
        "--tools",
        "",
        "--strict-mcp-config",
        "--no-chrome",
        "--output-format",
        "text",
        "--system-prompt",
        SYSTEM,
    ];
    sources.iter().chain(rest.iter()).map(|s| s.to_string()).collect()
}

/// A clean environment: what `claude` needs to find its login, nothing from panes
/// (CLOTHO_*), no API keys or ANTHROPIC_* from the daemon's environment (the login comes from
/// the user settings' `env` block, or the credentials file or keychain).
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
            tail: None,
        };
        let p = i.prompt_text();
        assert!(p.contains("asks permission") && p.contains("Tool: Bash") && p.contains("Tool input: npm test") && p.contains("The user had asked: run the tests"), "{p}");
        assert!(i.useful());
        assert!(!Input { state: "done".into(), ..Default::default() }.useful());
        assert!(Input { state: "waiting".into(), tool: Some("Bash".into()), ..Default::default() }.useful());
        let long = Input { state: "done".into(), message: Some("x".repeat(10_000)), ..Default::default() };
        assert!(long.prompt_text().len() < MAX_INPUT + 200 + LABEL.len());
        assert!(!p.contains("NEEDS_USER"), "only a finished turn is labelled: {p}");
    }

    #[test]
    fn the_tail_reaches_the_prompt_and_is_bounded() {
        let i = Input { tail: Some("  Should I push it?\n".into()), ..input("I fixed the test.") };
        let p = i.prompt_text();
        assert!(p.contains("The agent's message:\nI fixed the test.\nThe end of the agent's message:\nShould I push it?\n"), "{p}");
        assert!(p.contains("NEEDS_USER") && p.contains("DONE"), "a finished turn asks for the label: {p}");
        assert_ne!(p, input("I fixed the test.").prompt_text(), "the tail is part of the cache key");
        // A long tail keeps its end, on a character boundary.
        let long = Input { tail: Some(format!("{}é the very end?", "é".repeat(5000))), ..input("m") };
        let p = long.prompt_text();
        let tail = p.split("The end of the agent's message:\n").nth(1).unwrap().lines().next().unwrap();
        assert_eq!(tail.chars().count(), MAX_TAIL);
        assert!(tail.ends_with("the very end?"), "{tail}");
        // No tail, or a blank one: no such section. Other states get the tail but no label.
        assert!(!input("m").prompt_text().contains("The end of"));
        assert!(!Input { tail: Some(" \n".into()), ..input("m") }.prompt_text().contains("The end of"));
        let waiting = Input { state: "waiting".into(), tail: Some("Which one?".into()), ..input("m") }.prompt_text();
        assert!(waiting.contains("The end of the agent's message:\nWhich one?") && !waiting.contains("NEEDS_USER"), "{waiting}");
        assert_eq!(last_chars("héllo", 2), "lo");
        assert_eq!(last_chars("héllo", 4), "éllo");
        assert_eq!(last_chars("héllo", 9), "héllo");
    }

    #[test]
    fn the_label_line_is_parsed_and_optional() {
        let cases = [
            ("NEEDS_USER\nShould it push the branch?", Some(true), "Should it push the branch?"),
            ("DONE\nAll tests pass.", Some(false), "All tests pass."),
            ("\n  needs_user  \nWhich option do you want?", Some(true), "Which option do you want?"),
            ("done\r\nFixed.", Some(false), "Fixed."),
            ("**Done**\nFixed.", Some(false), "Fixed."),
            ("DONE\n\nFixed the test.\nPushed it.", Some(false), "Fixed the test. Pushed it."),
            ("All tests pass.", None, "All tests pass."),
            ("Done with the refactor.\nAll green.", None, "Done with the refactor. All green."),
            ("Fixed.\nDONE", None, "Fixed. DONE"),
            ("DONE", Some(false), ""),
        ];
        for (answer, label, text) in cases {
            let (l, t) = split_label(answer);
            assert_eq!((l, plain(t).as_str()), (label, text), "{answer:?}");
        }
    }

    #[tokio::test]
    async fn the_label_comes_back_with_the_text() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Summarizer::new(tmp.path(), true);
        let needs = fake(tmp.path(), "needs", "cat > /dev/null; echo NEEDS_USER; echo '**Should it push?**'");
        assert_eq!(s.rewrite(&needs, &input("a")).await.unwrap(), Rewrite { text: "Should it push?".into(), needs_user: Some(true) });
        assert_eq!(s.rewrite(&needs, &input("a")).await.unwrap().needs_user, Some(true), "the cache keeps the label");
        let done = fake(tmp.path(), "done", "cat > /dev/null; echo done; echo Fixed.");
        assert_eq!(s.rewrite(&done, &input("b")).await.unwrap(), Rewrite { text: "Fixed.".into(), needs_user: Some(false) });
        // An old-style answer (no label line) is all text.
        let plain = fake(tmp.path(), "plain", "cat > /dev/null; echo Fixed.");
        assert_eq!(s.rewrite(&plain, &input("c")).await.unwrap(), Rewrite { text: "Fixed.".into(), needs_user: None });
        // Only a finished turn is labelled: elsewhere a first line of "Done" is text.
        let waiting = Input { state: "waiting".into(), ..input("d") };
        assert_eq!(s.rewrite(&done, &waiting).await.unwrap(), Rewrite { text: "done Fixed.".into(), needs_user: None });
        // A label with no text is no rewrite.
        let bare = fake(tmp.path(), "bare", "cat > /dev/null; echo DONE");
        assert_eq!(s.rewrite(&bare, &input("e")).await.unwrap_err(), "empty answer");
    }

    #[test]
    fn the_heuristic_is_conservative() {
        let cut = format!("{} Should I", "x".repeat(291));
        assert_eq!(cut.chars().count(), 300);
        let long_q = format!("{} Which one?", "x".repeat(400));
        let far = format!("Let me know. {}", "All of it is done. ".repeat(12));
        let cases: &[(Option<&str>, Option<&str>, bool)] = &[
            // A trailing question, also under Markdown marks and quotes.
            (Some("I fixed the test. Should it be pushed?"), None, true),
            (Some("Want me to **push it?**\n"), None, true),
            (Some("It asks: \"overwrite the file?\""), None, true),
            (None, Some("…and which of the two do you prefer?"), true),
            // A phrase near the end.
            (Some("Both work. Let me know which you prefer."), None, true),
            (Some("I'm blocked on the missing API key."), None, true),
            (Some("I can’t proceed without the password."), None, true),
            (None, Some("I need you to run the migration first."), true),
            // Plain statements, and words that only contain a phrase.
            (Some("All 61 tests pass. The flaky test is fixed."), None, false),
            (Some("Is it fixed? Yes: all tests pass."), None, false),
            (Some("I unblocked the build and pushed."), None, false),
            (Some("Should it fail, the retry takes over."), None, false),
            // A phrase long before the end is not a signal.
            (Some(&far), None, false),
            (None, Some(&far), false),
            // A cut message has no visible end; its tail does.
            (Some(&cut), None, false),
            (Some(&long_q), None, false),
            (Some(&long_q), Some("Which one?"), true),
            (Some("Should I push?"), Some("No questions left. Pushed."), false),
            // No text.
            (None, None, false),
            (Some(""), Some("  \n"), false),
            (Some("**"), None, false),
        ];
        for (message, tail, want) in cases {
            assert_eq!(needs_user_guess(*message, *tail), *want, "{message:?} {tail:?}");
        }
    }

    #[test]
    fn the_real_claude_is_locked_down() {
        let a = args(false);
        for want in ["-p", "--safe-mode", "--no-session-persistence", "--strict-mcp-config", "--no-chrome"] {
            assert!(a.iter().any(|x| x == want), "{want}");
        }
        let after = |a: &[String], k: &str| a[a.iter().position(|x| x == k).unwrap() + 1].clone();
        assert_eq!(after(&a, "--model"), "haiku");
        assert_eq!(after(&a, "--setting-sources"), "user");
        assert_eq!(after(&a, "--tools"), "", "no tools at all");
        assert_eq!(after(&a, "--system-prompt"), SYSTEM);
        // For a claude without --safe-mode: the same, less the user's settings.
        let old = args(true);
        assert!(!old.iter().any(|x| x == "--safe-mode"));
        assert_eq!(after(&old, "--setting-sources"), "project,local");
        assert_eq!(old.len(), a.len() - 1);
        assert!(old.iter().all(|x| a.contains(x) || x == "project,local"));
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
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap().text, "Tests pass. All 61 green.");
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap().text, "Tests pass. All 61 green.");
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
        let long = format!("Not logged in · Please run /login {}", "x".repeat(200));
        let cases = [
            // A failed exit: the first line it printed, stderr before stdout, cut to 120.
            ("exit1", "echo 'some text'; exit 1".to_string(), "exit 1: some text".to_string()),
            ("notin", "echo 'Not logged in · Please run /login'; echo more; exit 1".into(), "exit 1: Not logged in · Please run /login".into()),
            ("long", format!("echo; echo '{long}'; exit 1"), format!("exit 1: {}", long.chars().take(120).collect::<String>())),
            ("stderr", "echo 'on stdout'; echo >&2; echo '  Error: no credentials  ' >&2; exit 2".into(), "exit 2: Error: no credentials".into()),
            ("silent", "exit 3".into(), "exit 3".into()),
            ("noisy", "head -c 100000 /dev/zero | tr '\\0' e >&2; exit 1".into(), format!("exit 1: {}", "e".repeat(120))),
            // An answer at exit 0 that is an error message: a fixed reason, none of its text.
            ("login", "echo 'Invalid API key · Please run /login'; echo 'the secret plan'".into(), "claude said: not logged in".into()),
            ("api", "echo 'API Error: 500 the secret plan'".into(), "claude said: api error".into()),
            ("credit", "echo 'Credit balance is too low'".into(), "claude said: credit balance".into()),
            ("key", "echo 'Invalid API key'".into(), "claude said: invalid api key".into()),
            ("rate", "echo 'Rate limit reached, the secret plan'".into(), "claude said: rate limit".into()),
            ("empty", "echo '   '".into(), "empty answer".into()),
        ];
        for (name, body, want) in cases {
            let why = s.rewrite(&fake(tmp.path(), name, &format!("cat > /dev/null; {body}")), &input(name)).await.unwrap_err();
            assert_eq!(why, want, "{name}");
            assert_eq!(s.health(), Health::Failing(want), "{name}");
        }
        let why = s.rewrite(Path::new("/nonexistent/claude"), &input("x")).await.unwrap_err();
        assert!(why.starts_with("can't run /nonexistent/claude"), "{why}");
    }

    /// Only claude's own error shapes are errors: a rewrite may talk about rate limits, API
    /// errors, logins, credit and keys.
    #[test]
    fn a_rewrite_that_mentions_an_error_is_not_one() {
        // A label followed by text is the model's answer, whatever it says.
        for answer in [
            "DONE\nAdded rate limit handling to the API client.",
            "NEEDS_USER\nIt hit an API error and asks whether to retry.",
            "done\nThe /login page now rejects an invalid API key.",
            "**DONE**\n\nRate limit reached is now shown as a banner.",
            "DONE\nAPI Error: 500 is retried three times now.",
            "NEEDS_USER\nYour credit balance check is ready for review.",
        ] {
            assert_eq!(error_answer(answer, true), None, "{answer:?}");
        }
        // No label was asked for (waiting, error): only claude's own beginnings count.
        for answer in ["Asks permission to edit the rate limit config.", "It stopped on an API error in the upload step.", "Wants to open the /login route."] {
            assert_eq!(error_answer(answer, false), None, "{answer:?}");
        }
        // Several lines without a label and without an error's beginning: text.
        assert_eq!(error_answer("Added the retry.\nThe rate limit is handled too.", true), None);
        let long = format!("{} rate limit", "word ".repeat(40));
        assert_eq!(error_answer(&long, true), None, "not a short line");

        // claude's errors, with and without a label asked for.
        for labelled in [true, false] {
            for (answer, why) in [
                ("API Error: 529 overloaded", "claude said: api error"),
                ("API Error: 429 rate limit exceeded", "claude said: api error"),
                ("Invalid API key · Please run /login", "claude said: not logged in"),
                ("Invalid API key", "claude said: invalid api key"),
                ("Not logged in", "claude said: not logged in"),
                ("  Credit balance is too low\n", "claude said: credit balance"),
                ("Rate limit reached\nTry again later.", "claude said: rate limit"),
            ] {
                assert_eq!(error_answer(answer, labelled), Some(why), "{answer:?} labelled={labelled}");
            }
        }
        // A label was asked for and there is none: one short line with a marker is an error.
        assert_eq!(error_answer("Your credit balance is too low.", true), Some("claude said: credit balance"));
        assert_eq!(error_answer("Your credit balance is too low.", false), None);
        // A label alone has no text: not excused (it ends as an empty answer).
        assert_eq!(error_answer("DONE", true), None);
        assert_eq!(error_answer("", true), None);
    }

    /// The whole path: a labelled rewrite that mentions an error is the text, and the health is ok.
    #[tokio::test]
    async fn a_good_rewrite_is_not_a_failed_run() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Summarizer::new(tmp.path(), true);
        let f = fake(tmp.path(), "ok", "cat > /dev/null; echo DONE; echo 'Added rate limit handling to the API client.'");
        let r = s.rewrite(&f, &input("rate")).await.unwrap();
        assert_eq!((r.text.as_str(), r.needs_user), ("Added rate limit handling to the API client.", Some(false)));
        assert_eq!(s.health(), Health::Ok);
        // Not labelled (it waits): the same.
        let waits = Input { state: "waiting".into(), ..input("may it") };
        let f = fake(tmp.path(), "waits", "cat > /dev/null; echo 'Asks to change the rate limit after an API error.'");
        assert_eq!(s.rewrite(&f, &waits).await.unwrap().text, "Asks to change the rate limit after an API error.");
        assert_eq!(s.health(), Health::Ok);
    }

    #[tokio::test]
    async fn health_follows_runs_and_logs_once_per_reason() {
        let tmp = tempfile::tempdir().unwrap();
        let mode = tmp.path().join("mode");
        let f = fake(tmp.path(), "fake", &format!("cat > /dev/null; if [ -e {0} ]; then echo \"$(cat {0})\" >&2; exit 1; fi; echo ok", mode.display()));
        let s = Summarizer::new(tmp.path(), true);
        let logged = || s.logged.load(Ordering::Relaxed);
        assert_eq!((s.health(), logged()), (Health::Unknown, 0));
        assert_eq!(s.health_json_for(true), json!({"state": "unknown", "reason": null, "at": null}));

        std::fs::write(&mode, "Not logged in").unwrap();
        let failing = Health::Failing("exit 1: Not logged in".into());
        assert!(s.rewrite(&f, &input("a")).await.is_err());
        assert_eq!((s.health(), logged()), (failing.clone(), 1));
        assert!(s.rewrite(&f, &input("b")).await.is_err());
        assert_eq!((s.health(), logged()), (failing.clone(), 1), "the same reason is logged once");
        let j = s.health_json_for(true);
        assert_eq!((j["state"].as_str(), j["reason"].as_str()), (Some("failing"), Some("exit 1: Not logged in")));
        assert!((j["at"].as_f64().unwrap() - unix_now()).abs() < 60.0, "{j}");

        std::fs::write(&mode, "Out of credit").unwrap();
        assert!(s.rewrite(&f, &input("c")).await.is_err());
        assert_eq!((s.health(), logged()), (Health::Failing("exit 1: Out of credit".into()), 2), "a new reason is logged");

        std::fs::remove_file(&mode).unwrap();
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap().text, "ok", "a failure is not cached");
        assert_eq!((s.health(), logged()), (Health::Ok, 3), "the recovery is logged");
        assert_eq!(s.rewrite(&f, &input("d")).await.unwrap().text, "ok");
        assert_eq!((s.health(), logged()), (Health::Ok, 3));
        let j = s.health_json_for(true);
        assert_eq!((j["state"].as_str(), j["reason"].is_null(), j["at"].is_f64()), (Some("ok"), true, true), "{j}");

        // A cache hit is not a run: it leaves the health alone.
        std::fs::write(&mode, "Not logged in").unwrap();
        let runs = s.runs.load(Ordering::Relaxed);
        assert_eq!(s.rewrite(&f, &input("d")).await.unwrap().text, "ok");
        assert_eq!((s.health(), logged(), s.runs.load(Ordering::Relaxed)), (Health::Ok, 3, runs));

        // No program to run, and off, win over the last run.
        assert_eq!(s.health_json_for(false), json!({"state": "unavailable", "reason": null, "at": null}));
        s.set_enabled(false);
        assert_eq!(s.health_json_for(true), json!({"state": "off", "reason": null, "at": null}));
        assert_eq!(s.health_json(), json!({"state": "off", "reason": null, "at": null}));

        // The lines themselves.
        let fail = |why: &str| Health::Failing(why.into());
        assert_eq!(health_change(&Health::Unknown, &fail("x")).unwrap(), "notification rewrite failing: x; using the original text");
        assert_eq!(health_change(&Health::Ok, &fail("x")).unwrap(), "notification rewrite failing: x; using the original text");
        assert_eq!(health_change(&fail("x"), &fail("y")).unwrap(), "notification rewrite failing: y; using the original text");
        assert_eq!(health_change(&fail("x"), &Health::Ok).unwrap(), "notification rewrite works again");
        for (old, new) in [(fail("x"), fail("x")), (Health::Unknown, Health::Ok), (Health::Ok, Health::Ok)] {
            assert_eq!(health_change(&old, &new), None, "{old:?} {new:?}");
        }
    }

    #[tokio::test]
    async fn an_old_claude_without_safe_mode_falls_back() {
        let tmp = tempfile::tempdir().unwrap();
        let log = tmp.path().join("log");
        // Like commander: the complaint on stderr, exit 1, before reading anything.
        let old = format!("echo \"$*\" >> {}; case \" $* \" in *' --safe-mode '*) echo \"error: unknown option '--safe-mode'\" >&2; exit 1;; esac; cat > /dev/null", log.display());
        let f = fake(tmp.path(), "old", &format!("{old}; echo Fixed."));
        let s = Summarizer::new(tmp.path(), true);
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap().text, "Fixed.");
        assert_eq!(s.health(), Health::Ok, "the health is the legacy run's own result");
        assert_eq!(s.rewrite(&f, &input("b")).await.unwrap().text, "Fixed.");
        let l = std::fs::read_to_string(&log).unwrap();
        let runs: Vec<&str> = l.lines().collect();
        assert_eq!(runs.len(), 3, "one refused try, then legacy runs only: {l}");
        assert!(runs[0].contains("--safe-mode --setting-sources user"), "{l}");
        assert!(runs[1..].iter().all(|r| !r.contains("--safe-mode") && r.contains("--setting-sources project,local")), "{l}");
        assert_eq!(s.runs.load(Ordering::Relaxed), 2, "the retry is part of its run");

        // The legacy run's failure is reported as it is (and there is one retry, not a loop).
        let f = fake(tmp.path(), "old-out", &format!("{old}; echo 'Not logged in · Please run /login'; exit 1"));
        let s = Summarizer::new(tmp.path(), true);
        assert_eq!(s.rewrite(&f, &input("a")).await.unwrap_err(), "exit 1: Not logged in · Please run /login");
        assert_eq!(s.health(), Health::Failing("exit 1: Not logged in · Please run /login".into()));
        assert_eq!(s.logged.load(Ordering::Relaxed), 1, "the refused option itself is not logged");

        // Another failure that mentions neither is no reason to fall back.
        assert!(no_safe_mode("exit 1: error: unknown option '--safe-mode'"));
        assert!(!no_safe_mode("exit 1: error: unknown option '--no-chrome'"));
        assert!(!no_safe_mode("claude said: api error"));
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
            assert_eq!(h.await.unwrap().unwrap().text, "ok");
        }
        let (mut now, mut most) = (0, 0);
        for l in std::fs::read_to_string(&log).unwrap().lines() {
            now += if l == "start" { 1 } else { -1 };
            most = most.max(now);
        }
        assert_eq!(most, 2);
    }
}
