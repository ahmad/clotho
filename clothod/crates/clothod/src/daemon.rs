//! The logic process: model, one headless VT per pane, and the client protocol
//! (docs/protocol.md). PTYs live in the holder; this process can be killed and restarted at any
//! time and rebuilds itself from the holder's snapshots and buffers.
//!
//! Lock order: model -> panes map -> pane -> clients map. Nothing that holds a pane lock takes
//! the model lock.

use std::collections::{HashMap, VecDeque};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use clotho_holder::Ring;
use clotho_proto::holder::{ExitStatus, FromHolder, PaneInfo, ToHolder, HOLDER_PROTOCOL, HOLDER_PROTOCOL_MIN};
use clotho_proto::{platform, read_frame, Frame, PROTOCOL, PROTOCOL_MIN};
use clotho_vt::{Vt, VtEvent};
use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;
use clotho_proto::listen::HealingListener;
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot, Notify};

use crate::model::{Direction, Model};

pub const SOCKET_NAME: &str = "clothod.sock";

/// Prefix of the error (and log line) when the running holder is too old or too new.
pub const INCOMPATIBLE: &str = "incompatible holder";
/// Exit code of `clothod serve` / `clothod start` in that case.
pub const EXIT_INCOMPATIBLE: i32 = 3;

/// The holder's output buffer per pane (recovery replays from it).
const RING_CAPACITY: usize = clotho_holder::RING_CAPACITY;
/// Largest gap a reconnecting client gets as replayed output instead of a snapshot.
const REPLAY_LIMIT: u64 = 1 << 20;
/// Default scrollback lines in a client snapshot.
const DEFAULT_SCROLLBACK: usize = 1000;
/// Push a VT snapshot to the holder once this much output piled up since the last one. Must stay
/// well under the holder's buffer so the snapshot's seq is still buffered on restart.
const SNAPSHOT_FORCE: u64 = 2 << 20;
/// ...or this much, after the pane has been quiet for a moment.
const SNAPSHOT_SOFT: u64 = 256 << 10;
/// ...or any amount after this long.
const SNAPSHOT_MAX_AGE: Duration = Duration::from_secs(30);
/// A client's queued output above which its pane streams pause (then resync with a snapshot).
const CLIENT_HIGH: usize = 8 << 20;
const CLIENT_LOW: usize = 1 << 20;
/// Output frame size when replaying.
const CHUNK: usize = 256 << 10;
/// Replies and events queued for a client that has stopped reading: past this the connection
/// is dropped (the client reconnects and resyncs) rather than growing serve without bound. A
/// half-open connection (a phone that went away) never reads again, and events keep coming.
const CONTROL_MAX: usize = 64 << 20;

fn control_max() -> usize {
    std::env::var("CLOTHOD_TEST_CONTROL_MAX").ok().and_then(|v| v.parse().ok()).unwrap_or(CONTROL_MAX)
}

enum Msg {
    Control(Vec<u8>),
    Output(Vec<u8>),
}

pub(crate) struct Client {
    id: u64,
    tx: mpsc::UnboundedSender<Msg>,
    /// File transfer frames: written only when nothing else is queued, so terminals stay
    /// responsive during transfers (docs/protocol.md, Files).
    file_tx: mpsc::UnboundedSender<Vec<u8>>,
    /// Bytes of pane output queued but not yet written to the socket.
    queued: AtomicUsize,
    /// The queue went over CLIENT_HIGH and hasn't drained below CLIENT_LOW since. A pane that
    /// stops sending to a lagging client lets the queue dip under CLIENT_HIGH while the socket
    /// takes some of it, so `queued` alone would let a subscribe in that window replay.
    full: AtomicBool,
    /// Bytes of replies and events queued (not limited; for `debug.stats`).
    control_queued: AtomicUsize,
    events: AtomicBool,
    /// Said hello as an app or other real client, not one of clothod's own probes
    /// (`clothod-*`: upgrade, status, ps, report). Only these keep an exit-mode instance alive.
    real: AtomicBool,
    /// This connection's fs.* transfer streams.
    pub(crate) fs: crate::fs::Streams,
    /// Set (and `kill` notified) when the client fell too far behind: the connection ends.
    dropped: AtomicBool,
    kill: tokio::sync::Notify,
    control_max: usize,
    /// The `client` string from `hello` and the connecting process, for the log.
    name: Mutex<String>,
    peer_pid: Option<u32>,
    /// The client's terminal colors (`hello.colors`, `client.colors`) and when it set them (the
    /// daemon's `colors_seq`): applications in the panes it uses query these.
    colors: Mutex<Option<(Arc<clotho_vt::Palette>, u64)>>,
}

impl Client {
    /// How the log names this connection: `client 12 (clotho-ios/1.2, pid 4242)`.
    fn label(&self) -> String {
        let name = self.name.lock().unwrap().clone();
        let name = if name.is_empty() { "no hello".into() } else { name };
        match self.peer_pid {
            Some(pid) => format!("client {} ({name}, pid {pid})", self.id),
            None => format!("client {} ({name})", self.id),
        }
    }

    fn control(&self, frame: Vec<u8>) {
        if self.dropped.load(Ordering::Relaxed) {
            return;
        }
        let queued = self.control_queued.fetch_add(frame.len(), Ordering::Relaxed) + frame.len();
        if queued > self.control_max {
            if !self.dropped.swap(true, Ordering::SeqCst) {
                eprintln!("clothod: client {}: {queued} bytes of replies and events unread; dropping the connection", self.id);
                self.kill.notify_one();
            }
            return;
        }
        let _ = self.tx.send(Msg::Control(frame));
    }

    pub(crate) fn json(&self, v: Value) {
        self.control(Frame::Json(v).encode());
    }

    /// Queue a FILE_DATA frame (lowest priority).
    pub(crate) fn file(&self, frame: Vec<u8>) {
        let _ = self.file_tx.send(frame);
    }

    /// An event only this connection gets (fs.ack, fs.done, fs.error).
    pub(crate) fn event(&self, event: &str, data: Value) {
        self.json(json!({"event": event, "data": data}));
    }

    fn output(&self, frame: Vec<u8>) {
        self.queued.fetch_add(frame.len(), Ordering::Relaxed);
        let _ = self.tx.send(Msg::Output(frame));
    }
}

/// Frames for the holder, with the bytes queued but not yet written (`debug.stats`).
#[derive(Clone)]
struct HolderTx {
    tx: mpsc::UnboundedSender<Vec<u8>>,
    queued: Arc<AtomicUsize>,
}

impl HolderTx {
    fn send(&self, buf: Vec<u8>) -> std::result::Result<(), mpsc::error::SendError<Vec<u8>>> {
        self.queued.fetch_add(buf.len(), Ordering::Relaxed);
        self.tx.send(buf)
    }
}

struct Sub {
    client: Arc<Client>,
    lagging: bool,
    viewport: Option<(u16, u16)>,
}

/// A coding agent in a pane (docs/protocol.md, "Agents").
#[derive(Clone, PartialEq)]
struct Agent {
    kind: String,
    state: String,
    /// "hook" or "detected".
    source: &'static str,
    message: Option<String>,
    /// Unix seconds when `state` last changed.
    since: f64,
    attention: bool,
    session: Option<String>,
    /// The agent's process (group), watched to clear the agent when it exits.
    pid: Option<u32>,
    /// `state` is detection's guess from output alone (busy = running, quiet = waiting), not
    /// a hook's report or Claude's title. A guess never raises or clears `attention`: opening
    /// a pane resizes it, and the app's redraw would read as "running".
    guess: bool,
    /// The user muted this agent (`agent.mute`): nothing raises its attention (or pushes)
    /// until they unmute it. Lasts for this agent; a new agent in the pane starts unmuted.
    muted: bool,
    /// The last rise of `attention` was quiet: a turn ended (`done`) while the user was at the
    /// pane, so no push went out and clients don't notify either. Kept until the next rise.
    quiet: bool,
    /// What the user asked in the current turn (first line of the prompt they typed), if they
    /// typed it: a turn started by another agent's message or a finished task has none.
    prompt: Option<String>,
    /// The last tool the agent used in this turn ("Bash") and its key input ("npm test").
    tool: Option<String>,
    tool_input: Option<String>,
    /// Unix seconds when the current turn started (its prompt, or work after a turn ended).
    turn_started: Option<f64>,
    /// Permission requests waiting for an answer from a client (`agent.decide`), oldest first.
    requests: Vec<Request>,
    /// A small model's rewrite of `message` for notifications (crate::summary), for this state
    /// and message; `summary` falls back to the message cleaned of Markdown.
    rewrite: Option<String>,
    /// A rewrite is under way: `summary` may still change.
    rewrite_pending: bool,
}

/// A tool call the agent asks permission for, answerable from a client (`agent.decide`) while
/// its hook (`clothod report --claude-permission`) waits.
#[derive(Debug, Clone, PartialEq)]
struct Request {
    id: String,
    tool: String,
    summary: Option<String>,
    /// Hash of the tool call (name and input): a PostToolUse for the same call retires it.
    key: String,
}

/// The waiting hook's side of a request: where its answer goes.
struct Pending {
    tx: tokio::sync::oneshot::Sender<Value>,
    client: u64,
}

impl Agent {
    /// Whether `other` is the same agent (session) as this one, so that what the user set on
    /// it carries over: same kind, and the same process or the same hook session.
    /// What both know decides: the process if both have one, else the hook session, else
    /// (nothing to tell them apart) the kind alone.
    fn same_as(&self, kind: &str, pid: Option<u32>, session: Option<&str>) -> bool {
        if self.kind != kind {
            return false;
        }
        match ((self.pid, pid), (self.session.as_deref(), session)) {
            ((Some(a), Some(b)), _) => a == b,
            (_, (Some(a), Some(b))) => a == b,
            _ => true,
        }
    }
}

const AGENT_STATES: [&str; 5] = ["starting", "running", "waiting", "done", "error"];

/// Detected agents count as running while output arrived this recently.
const AGENT_ACTIVE: Duration = Duration::from_millis(1500);

/// A client's colors: `{foreground, background, cursor?, ansi?: [16]}`, each `#rrggbb`.
fn parse_palette(v: &Value) -> std::result::Result<clotho_vt::Palette, String> {
    let o = v.as_object().ok_or("not an object")?;
    if let Some(k) = o.keys().find(|k| !["foreground", "background", "cursor", "ansi"].contains(&k.as_str())) {
        return Err(format!("unknown key `{k}`"));
    }
    let rgb = |v: &Value, what: &str| -> std::result::Result<clotho_vt::Rgb, String> {
        let s = v.as_str().filter(|s| s.len() == 7 && s.starts_with('#') && s[1..].bytes().all(|b| b.is_ascii_hexdigit()));
        let s = s.ok_or_else(|| format!("{what} must be \"#rrggbb\""))?;
        let h = |i: usize| u8::from_str_radix(&s[i..i + 2], 16).unwrap();
        Ok(clotho_vt::Rgb { r: h(1), g: h(3), b: h(5) })
    };
    let need = |k: &str| o.get(k).ok_or_else(|| format!("missing {k}")).and_then(|v| rgb(v, k));
    let ansi = match o.get("ansi") {
        None | Some(Value::Null) => None,
        Some(a) => {
            let a = a.as_array().filter(|a| a.len() == 16).ok_or("ansi must have 16 colors")?;
            let mut out = [clotho_vt::Rgb { r: 0, g: 0, b: 0 }; 16];
            for (i, c) in a.iter().enumerate() {
                out[i] = rgb(c, &format!("ansi[{i}]"))?;
            }
            Some(out)
        }
    };
    Ok(clotho_vt::Palette {
        foreground: need("foreground")?,
        background: need("background")?,
        cursor: o.get("cursor").filter(|c| !c.is_null()).map(|c| rgb(c, "cursor")).transpose()?,
        ansi,
    })
}

/// A line in clothod.log, with the time (UTC): what closed panes and answered requests, which
/// clients don't log anywhere else.
fn log(msg: impl std::fmt::Display) {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let (secs, ms) = (t.as_secs() as i64, t.subsec_millis());
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = secs.div_euclid(86400) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    let sod = secs.rem_euclid(86400);
    eprintln!("clothod: {y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{ms:03}Z {msg}", sod / 3600, sod / 60 % 60, sod % 60);
}

/// Whether input is the user's typing, not a terminal report (focus in/out, mouse).
fn typed(data: &[u8]) -> bool {
    !(data == b"\x1b[I" || data == b"\x1b[O" || data.starts_with(b"\x1b[<") || data.starts_with(b"\x1b[M"))
}

fn unix_now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Claude Code's title glyph: Some(true) for a spinner (working), Some(false) for ✳ (idle),
/// None if the title has neither.
fn title_activity(title: Option<&str>) -> Option<bool> {
    let c = title?.trim_start().chars().next()?;
    match c {
        '✳' => Some(false),
        '\u{2800}'..='\u{28ff}' | '✶' | '✻' | '✽' | '✢' | '·' => Some(true),
        _ => None,
    }
}

/// Whether the agent process that ran a reporter (`pid`, a hook's `clothod report`) is itself run
/// by another agent in the pane (led by `leader`): two agent processes among its ancestors with
/// something else between them. Directly chained agent processes are one agent (`node .../codex`
/// running the native `codex-<target>`).
fn nested_agent(pid: u32, leader: u32) -> bool {
    let mut agents = 0;
    let mut in_agent = false;
    for p in platform::ancestors(pid, leader) {
        let agent = agent_kind(&platform::process_names(p)).is_some();
        if agent && !in_agent {
            agents += 1;
        }
        in_agent = agent;
    }
    agents >= 2
}

fn agent_kind(names: &[String]) -> Option<&'static str> {
    for n in names {
        let n = n.to_ascii_lowercase();
        if n == "claude" || n.starts_with("claude-") || n == "claude.exe" {
            return Some("claude");
        }
        if n == "codex" || n.starts_with("codex-") {
            return Some("codex");
        }
    }
    None
}

impl Agent {
    /// A hook-reported agent as `json` stored it in the pane meta. Its permission requests are
    /// not kept: their hooks were connected to the previous process, and have given up.
    fn from_saved(v: &Value) -> Option<Agent> {
        let text = |k: &str| v.get(k).and_then(Value::as_str).map(String::from);
        let flag = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
        let state = text("state").filter(|s| AGENT_STATES.contains(&s.as_str()))?;
        Some(Agent {
            kind: text("kind")?,
            state,
            source: "hook",
            message: text("message"),
            since: v.get("since").and_then(Value::as_f64).unwrap_or_else(unix_now),
            attention: flag("attention"),
            session: text("session").filter(|s| crate::layout::safe_session(s)),
            pid: v.get("pid").and_then(Value::as_u64).and_then(|p| u32::try_from(p).ok()),
            guess: false,
            muted: flag("muted"),
            quiet: flag("quiet"),
            prompt: text("prompt"),
            tool: text("tool"),
            tool_input: text("tool_input"),
            turn_started: v.get("turn_started").and_then(Value::as_f64),
            requests: Vec::new(),
            rewrite: None,
            rewrite_pending: false,
        })
    }

    fn json(&self) -> Value {
        json!({
            "kind": self.kind,
            "state": self.state,
            "source": self.source,
            "message": self.message,
            "since": self.since,
            "attention": self.attention,
            "muted": self.muted,
            "quiet": self.quiet,
            "prompt": self.prompt,
            "tool": self.tool,
            "tool_input": self.tool_input,
            "turn_started": self.turn_started,
            "requests": self.requests.iter().map(|r| json!({"id": r.id, "tool": r.tool, "summary": r.summary})).collect::<Vec<_>>(),
            "session": self.session,
            "summary": self.summary(),
            "summary_pending": self.rewrite_pending,
        })
    }

    /// The notification text: the rewrite, else the message cleaned of Markdown.
    fn summary(&self) -> Option<String> {
        self.rewrite.clone().or_else(|| self.message.as_deref().map(crate::summary::plain).filter(|t| !t.is_empty()))
    }

    /// What the rewrite is made from.
    fn summary_input(&self) -> crate::summary::Input {
        let waiting = self.state == "waiting";
        let req = self.requests.last().filter(|_| waiting);
        crate::summary::Input {
            kind: self.kind.clone(),
            state: self.state.clone(),
            message: self.message.clone(),
            prompt: self.prompt.clone(),
            tool: req.map(|r| r.tool.clone()).or(self.tool.clone()).filter(|_| waiting),
            tool_input: req.map(|r| r.summary.clone()).unwrap_or(self.tool_input.clone()).filter(|_| waiting),
            permission: req.is_some(),
        }
    }

    /// What a Live Activity following it shows (None: nothing it can show).
    fn live(&self) -> Option<crate::push::Live> {
        let state = match self.state.as_str() {
            "starting" | "running" => "running",
            s @ ("waiting" | "done" | "error") => s,
            _ => return None,
        };
        let since = self.since as u64;
        // Waiting on a permission request: what it asks about, as the alert says it.
        let req = self.requests.last().filter(|_| state == "waiting");
        let (tool, detail) = match (state, req) {
            (_, Some(r)) => (Some(r.tool.clone()), r.summary.clone()),
            ("running" | "waiting", None) => (self.tool.clone(), self.tool_input.clone()),
            _ => (None, None),
        };
        let msg = self.summary().filter(|_| state != "running");
        Some(crate::push::Live { kind: self.kind.clone(), state: state.into(), since, started: self.turn_started.map(|t| t as u64).unwrap_or(since), tool, detail, msg })
    }
}

struct Pane {
    id: u64,
    agent: Option<Agent>,
    pid: u32,
    command: Vec<String>,
    cols: u16,
    rows: u16,
    vt: Vt,
    /// After a restart: the muted agent this pane had (kind, pid, session), applied when that
    /// same agent shows up again.
    muted_agent: Option<(String, Option<u32>, Option<String>)>,
    /// Its scrollback was asked for at spawn (`scrollback_lines`); otherwise it follows the
    /// daemon's setting, also when that changes.
    own_scrollback: bool,
    /// Output position the VT has consumed.
    vt_seq: u64,
    ring: Ring,
    /// Resizes still to apply while replaying recovered output: (seq, cols, rows).
    replay_resizes: Vec<(u64, u16, u16)>,
    title: Option<String>,
    cwd: Option<String>,
    exited: Option<ExitStatus>,
    subs: HashMap<u64, Sub>,
    last_input_client: Option<u64>,
    /// The client whose viewport sets the pane's size: the one that focused it last
    /// (`pane.focus`, or `pane.subscribe` with a viewport). See "Resize" in docs/protocol.md.
    size_client: Option<u64>,
    /// The client that last typed in or subscribed to the pane: its colors are the ones
    /// applications here get (`pane_palette`).
    colors_client: Option<u64>,
    /// When a client last typed in (or sent focus or mouse reports to) the pane: whether the
    /// user is at it right now (`user_present`).
    last_input_at: Option<Instant>,
    /// The hooks waiting on this pane's agent's permission requests, by request id.
    pending: HashMap<String, Pending>,
    snap_seq: u64,
    snap_at: Instant,
    last_output: Instant,
    /// The shell's working directory as last told to clients, when it doesn't report one
    /// itself (OSC 7): polled once a second so a `cd` shows up without other activity.
    polled_cwd: Option<String>,
    /// What its agents did, oldest first (`agent.history`), at most HISTORY_MAX entries; kept
    /// across serve restarts in the pane meta.
    history: VecDeque<Value>,
    /// Brought back after a restart (`{at, agent, session}`, docs/protocol.md "Restore after
    /// restart") until a client dismisses it or the user types in the pane.
    restored: Option<Value>,
    /// When detection last read the session of the pane's Claude Code (`claude_session_of`).
    session_probe: Option<Instant>,
    /// The cwd git info was last looked up for, where its work tree is, and the `git` field
    /// (docs/protocol.md, "Git").
    git_cwd: Option<String>,
    git_loc: Option<crate::git::Location>,
    git: Option<Value>,
}

/// A client that sent input to a pane it shows within this long means the user is at that pane:
/// a turn that ends then raises attention there, but sends no push to the phone.
const PRESENCE: Duration = Duration::from_secs(60);

fn presence() -> Duration {
    std::env::var("CLOTHOD_TEST_PRESENCE_MS").ok().and_then(|v| v.parse().ok()).map(Duration::from_millis).unwrap_or(PRESENCE)
}

/// A request id no one can guess from another (the socket is the user's alone; this keeps a
/// stale id from ever naming a newer request).
fn request_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    static N: AtomicU64 = AtomicU64::new(0);
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u64(N.fetch_add(1, Ordering::Relaxed));
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
    format!("{:016x}", h.finish())
}

/// Longest prompt line and tool description kept for an agent's turn (chars).
const AGENT_PROMPT_MAX: usize = 120;
const AGENT_TOOL_MAX: usize = 160;
const AGENT_TOOL_NAME_MAX: usize = 64;

/// Entries kept per pane by `agent.history`.
const HISTORY_MAX: usize = 200;
/// Longest agent message kept in history (chars).
const HISTORY_MESSAGE: usize = 300;

/// The fields that make two history entries the same (`at` and `event` aside).
fn history_key(e: &Value) -> [&Value; 8] {
    ["kind", "state", "message", "session", "source", "guess", "attention", "muted"].map(|k| e.get(k).unwrap_or(&Value::Null))
}

impl Pane {
    /// Log the pane's agent as it is now, unless nothing that matters changed.
    fn record(&mut self, event: &str, from: Option<&str>, gone: Option<&Agent>) {
        let a = self.agent.as_ref().or(gone);
        let Some(a) = a else { return };
        let message = a.message.as_ref().filter(|_| gone.is_none()).map(|m| m.chars().take(HISTORY_MESSAGE).collect::<String>());
        let e = json!({
            "at": unix_now(), "event": event, "kind": a.kind,
            "state": if gone.is_some() { Value::Null } else { json!(a.state) },
            "from": from, "message": message, "session": a.session, "pid": a.pid,
            "source": a.source, "guess": a.guess, "attention": gone.is_none() && a.attention, "muted": a.muted,
        });
        if self.history.back().is_some_and(|last| history_key(last) == history_key(&e)) {
            return;
        }
        if self.history.len() == HISTORY_MAX {
            self.history.pop_front();
        }
        self.history.push_back(e);
    }
}

impl Pane {
    /// Retire the agent's requests that `which` picks: their hooks exit with no decision, so
    /// the agent's own dialog (which shows all along) takes over. True if any went.
    fn retire(&mut self, which: impl Fn(&Request) -> bool) -> bool {
        let Some(a) = self.agent.as_mut() else {
            for (_, p) in self.pending.drain() {
                let _ = p.tx.send(json!({"retired": true}));
            }
            return false;
        };
        let before = a.requests.len();
        let pending = &mut self.pending;
        a.requests.retain(|r| {
            if !which(r) {
                return true;
            }
            if let Some(p) = pending.remove(&r.id) {
                let _ = p.tx.send(json!({"retired": true}));
            }
            false
        });
        a.requests.len() != before
    }

    /// A client showing this pane sent it input within `presence()`.
    fn user_present(&self) -> bool {
        self.last_input_at.is_some_and(|at| at.elapsed() < presence()) && self.last_input_client.is_some_and(|c| self.subs.contains_key(&c))
    }

    fn new(info: &PaneInfo, scrollback: usize, own_scrollback: bool) -> Pane {
        Pane {
            id: info.pane,
            agent: None,
            pid: info.pid,
            command: info.command.clone(),
            cols: info.cols,
            rows: info.rows,
            vt: Vt::with_scrollback(info.cols, info.rows, scrollback),
            muted_agent: None,
            own_scrollback,
            vt_seq: info.seq_start,
            ring: {
                // Only for replays to clients, which are capped at REPLAY_LIMIT (the holder
                // keeps the longer buffer for recovery).
                let mut r = Ring::new(REPLAY_LIMIT as usize);
                r.reset(info.seq_start);
                r
            },
            replay_resizes: Vec::new(),
            title: None,
            cwd: None,
            exited: info.exited,
            subs: HashMap::new(),
            last_input_client: None,
            size_client: None,
            colors_client: None,
            last_input_at: None,
            pending: HashMap::new(),
            snap_seq: 0,
            snap_at: Instant::now(),
            last_output: Instant::now(),
            polled_cwd: None,
            history: VecDeque::new(),
            restored: None,
            session_probe: None,
            git_cwd: None,
            git_loc: None,
            git: None,
        }
    }

    fn json(&self) -> Value {
        let cwd = self
            .cwd
            .clone()
            .or_else(|| platform::process_cwd(self.pid).map(|p| p.to_string_lossy().into_owned()));
        json!({
            "id": self.id,
            "cols": self.cols,
            "rows": self.rows,
            "pid": self.pid,
            "command": self.command,
            "title": self.title,
            "cwd": cwd,
            "seq": self.ring.end(),
            "exited": self.exited,
            "scrollback_lines": self.vt.scrollback(),
            "agent": self.agent.as_ref().map(Agent::json),
            "restored": self.restored,
            "git": self.git,
        })
    }
}

pub struct Daemon {
    dir: PathBuf,
    instance: String,
    /// Install id of this program (computed once).
    build: String,
    /// The holder's welcome: pid, version, protocol, exe (reported in `hello`).
    holder_info: Value,
    holder: HolderTx,
    model: Mutex<Model>,
    rev: AtomicU64,
    panes: Mutex<HashMap<u64, Arc<Mutex<Pane>>>>,
    /// Spawns waiting for the holder, with the scrollback their pane asked for.
    spawns: Mutex<HashMap<u64, (oneshot::Sender<Result<PaneInfo, String>>, Option<usize>)>>,
    /// Lines of history a pane keeps unless its spawn asked otherwise (config `scrollback_lines`,
    /// changed at runtime by `settings.set`).
    scrollback: AtomicUsize,
    /// Per-pane settings from the stored state, for rebuilding those panes during recovery:
    /// (lines, asked for at spawn).
    recovered_scrollback: HashMap<u64, (usize, bool)>,
    next_req: AtomicU64,
    clients: Mutex<HashMap<u64, Arc<Client>>>,
    next_client: AtomicU64,
    /// Replies from the VTs go to the PTYs only once recovery is done.
    live: AtomicBool,
    dirty: AtomicBool,
    stop: Notify,
    shutdown_all: AtomicBool,
    had_real_client: AtomicBool,
    /// Orders `client.colors` calls: the latest setter's colors apply where no client is using
    /// a pane.
    colors_seq: AtomicU64,
    push: Arc<crate::push::Push>,
    /// Each pane's workspace name and tab title, for push alerts (refreshed with every persist,
    /// so reading it never needs the model's lock while a pane's is held).
    places: Mutex<HashMap<u64, (Option<u64>, Option<String>, Option<String>)>>,
    /// The saved layout file, if this instance keeps one.
    layout: Option<LayoutWriter>,
    git: Mutex<GitCache>,
    /// At most this many `gh` lookups at once.
    gh_slots: Arc<tokio::sync::Semaphore>,
    /// Notification text rewrites (crate::summary; setting `notification_rewrite`).
    summary: Arc<crate::summary::Summarizer>,
    /// This daemon, for tasks that come back to it later.
    me: std::sync::OnceLock<std::sync::Weak<Daemon>>,
}

/// Work trees panes are in, and pull request lookups, shared by every pane on them.
#[derive(Default)]
struct GitCache {
    /// By git dir: what was last read.
    repos: HashMap<PathBuf, crate::git::Info>,
    /// By (owner/name, branch).
    prs: HashMap<(String, String), PrEntry>,
}

struct PrEntry {
    /// `None` until the first lookup ends.
    result: Option<Result<Option<crate::git::Pr>, &'static str>>,
    at: Instant,
    running: bool,
}

/// A branch's PR is looked up again at most this often, and only while a client shows a pane
/// on it.
fn pr_refresh() -> Duration {
    std::env::var("CLOTHOD_TEST_PR_REFRESH_MS").ok().and_then(|v| v.parse().ok()).map(Duration::from_millis).unwrap_or(Duration::from_secs(300))
}
const GH_TIMEOUT: Duration = Duration::from_secs(5);

/// Writes the layout file (`crate::layout`) when it changes: debounced, and held back for a
/// while after a pane exits, so a shutdown that ends the shells before clothod doesn't save an
/// emptied layout over the real one.
struct LayoutWriter {
    path: PathBuf,
    host: String,
    runtime_dir: String,
    st: Mutex<LayoutState>,
}

#[derive(Default)]
struct LayoutState {
    /// Off until a restore (if any) is done, so the empty model of a fresh start isn't saved.
    enabled: bool,
    written: Option<crate::layout::Saved>,
    pending: Option<(crate::layout::Saved, Instant)>,
    last_exit: Option<Instant>,
    /// Agent sessions the file had for panes of an adopted holder, by pane: kept while an agent
    /// of that kind without a session of its own (a detected one) is in the pane. A serve
    /// before 0.1.22 didn't keep agents across restarts, so after upgrading from one this is
    /// all that knows them until each agent's next hook.
    hints: HashMap<u64, crate::layout::SavedAgent>,
    /// Until then a pane without an agent keeps its hint: detection hasn't looked yet.
    hints_until: Option<Instant>,
    /// Each pane's last saved agent, and since when the pane has had none (`agent_gone_quiet`).
    agents: HashMap<u64, (crate::layout::SavedAgent, Option<Instant>)>,
}

/// A layout change is written once nothing changed for this long.
const LAYOUT_DEBOUNCE: Duration = Duration::from_millis(500);
/// And not until this long after a pane exited.
const LAYOUT_EXIT_QUIET: Duration = Duration::from_secs(5);

/// A pane's agent stays in the file this long after it left a shell that lives on. A reboot or
/// logout ends the agents first (they quit on the SIGTERM; an interactive shell ignores it)
/// and clothod a moment later: the session must survive that. An agent the user quits is
/// forgotten once this has passed.
fn agent_gone_quiet() -> Duration {
    std::env::var("CLOTHOD_TEST_AGENT_GONE_MS").ok().and_then(|v| v.parse().ok()).map(Duration::from_millis).unwrap_or(Duration::from_secs(10))
}

/// Detection reads a Claude Code's session record at most this often.
const CLAUDE_SESSION_PROBE: Duration = Duration::from_secs(5);

impl LayoutWriter {
    fn offer(&self, saved: crate::layout::Saved) {
        let mut st = self.st.lock().unwrap();
        if !st.enabled || st.written.as_ref() == Some(&saved) || st.pending.as_ref().is_some_and(|p| p.0 == saved) {
            return;
        }
        st.pending = Some((saved, Instant::now()));
    }

    /// Whether an agent's time in the file after it left is up (the layout must be offered
    /// again to drop it: nothing else may change).
    fn agent_gone_due(&self) -> bool {
        let quiet = agent_gone_quiet();
        self.st.lock().unwrap().agents.values().any(|(_, gone)| gone.is_some_and(|t| t.elapsed() >= quiet))
    }

    /// Remove the saved layout and write no more (the daemon is shutting down).
    fn forget(&self) {
        let mut st = self.st.lock().unwrap();
        st.enabled = false;
        st.pending = None;
        crate::layout::forget(&self.path);
        log(format_args!("layout: forgot {}", self.path.display()));
    }

    /// Write what's pending if it settled (or `now`, skipping the debounce), unless a pane
    /// exited recently.
    fn flush(&self, now: bool) {
        let mut st = self.st.lock().unwrap();
        let Some((_, at)) = st.pending.as_ref() else { return };
        if !now && at.elapsed() < LAYOUT_DEBOUNCE {
            return;
        }
        if st.last_exit.is_some_and(|e| e.elapsed() < LAYOUT_EXIT_QUIET) {
            return;
        }
        let (saved, _) = st.pending.take().unwrap();
        let mut out = saved.clone();
        out.saved_at = unix_now();
        match serde_json::to_string(&out).map_err(std::io::Error::other).and_then(|t| crate::layout::write(&self.path, &t)) {
            Ok(()) => st.written = Some(saved),
            Err(e) => log(format_args!("layout: writing {} failed: {e}", self.path.display())),
        }
    }
}

#[derive(Debug)]
struct RpcError {
    code: &'static str,
    message: String,
}

fn err(code: &'static str, message: impl Into<String>) -> RpcError {
    RpcError { code, message: message.into() }
}

impl From<anyhow::Error> for RpcError {
    fn from(e: anyhow::Error) -> Self {
        err("internal", format!("{e:#}"))
    }
}

type RpcResult = std::result::Result<Value, RpcError>;

/// Spawn options shared by every method that creates a pane.
struct SpawnOpts {
    command: Vec<String>,
    cwd: Option<String>,
    env: Vec<(String, String)>,
    cols: u16,
    rows: u16,
    scrollback: Option<usize>,
}

fn default_shell() -> Vec<String> {
    let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
    vec![shell, "-l".into()]
}

impl SpawnOpts {
    fn from_params(p: &Value) -> std::result::Result<SpawnOpts, RpcError> {
        let command = match p.get("command") {
            None | Some(Value::Null) => default_shell(),
            Some(Value::Array(a)) => {
                let cmd: Option<Vec<String>> = a.iter().map(|v| v.as_str().map(String::from)).collect();
                cmd.filter(|c| !c.is_empty()).ok_or_else(|| err("bad_request", "command must be a non-empty array of strings"))?
            }
            _ => return Err(err("bad_request", "command must be an array")),
        };
        // The client's own extras; the terminal's variables are added for every spawn
        // (`pane_env`).
        let mut env = Vec::new();
        if let Some(Value::Object(m)) = p.get("env") {
            for (k, v) in m {
                if let Some(v) = v.as_str() {
                    env.push((k.clone(), v.to_string()));
                }
            }
        }
        Ok(SpawnOpts {
            command,
            cwd: p.get("cwd").and_then(Value::as_str).map(String::from),
            env,
            cols: p.get("cols").and_then(Value::as_u64).map_or(80, |v| v.clamp(2, 1000) as u16),
            rows: p.get("rows").and_then(Value::as_u64).map_or(24, |v| v.clamp(1, 1000) as u16),
            scrollback: match p.get("scrollback_lines") {
                None | Some(Value::Null) => None,
                Some(v) => Some(v.as_u64().filter(|n| *n as usize <= crate::config::MAX_SCROLLBACK).ok_or_else(|| {
                    err("bad_request", format!("scrollback_lines must be 0..={}", crate::config::MAX_SCROLLBACK))
                })? as usize),
            },
        })
    }
}

/// What every pane's process gets on top of the holder's environment, whichever way it was
/// started (a client's new tab or split, a restore after a restart, an agent resumed there):
/// what a terminal sets. The daemon may have been started by launchd or systemd at login with a
/// bare environment, so nothing here may come from it alone. A spawn's own `env` goes after,
/// and wins.
fn pane_env(extra: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut env = vec![
        ("TERM".to_string(), "xterm-256color".to_string()),
        ("COLORTERM".into(), "truecolor".into()),
        ("TERM_PROGRAM".into(), "clotho".into()),
        ("TERM_PROGRAM_VERSION".into(), env!("CARGO_PKG_VERSION").into()),
    ];
    // A locale, as Terminal and other terminals set one: the daemon's own if it has one, else
    // a UTF-8 one (without it, programs fall back to ASCII).
    let has = |k: &str| std::env::var(k).is_ok_and(|v| !v.is_empty());
    if !["LANG", "LC_ALL", "LC_CTYPE"].iter().any(|k| has(k)) {
        env.push(("LANG".into(), default_lang().to_string()));
    }
    env.extend(extra);
    env
}

/// The UTF-8 locale for panes when the daemon has none: on macOS the user's region (as Terminal
/// does), else en_US.UTF-8; on Linux C.UTF-8 (in glibc and musl).
fn default_lang() -> &'static str {
    static LANG: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    LANG.get_or_init(|| {
        if cfg!(target_os = "macos") {
            let region = std::process::Command::new("/usr/bin/defaults")
                .args(["read", "-g", "AppleLocale"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().split('@').next().unwrap_or_default().to_string())
                .map(|r| format!("{r}.UTF-8"))
                .filter(|l| Path::new("/usr/share/locale").join(l).is_dir());
            region.unwrap_or_else(|| "en_US.UTF-8".into())
        } else {
            "C.UTF-8".into()
        }
    })
}

fn param_u64(p: &Value, key: &str) -> std::result::Result<u64, RpcError> {
    p.get(key).and_then(Value::as_u64).ok_or_else(|| err("bad_request", format!("missing integer param `{key}`")))
}

/// A position (`index`): a non-negative integer; past the end is clamped by the caller.
fn param_index(p: &Value) -> std::result::Result<usize, RpcError> {
    let i = p.get("index").and_then(Value::as_u64).ok_or_else(|| err("bad_request", "index must be a non-negative integer"))?;
    Ok(usize::try_from(i).unwrap_or(usize::MAX))
}

fn param_size(p: &Value) -> std::result::Result<(u16, u16), RpcError> {
    let cols = param_u64(p, "cols")?.clamp(2, 1000) as u16;
    let rows = param_u64(p, "rows")?.clamp(1, 1000) as u16;
    Ok((cols, rows))
}

pub fn socket_path(dir: &Path) -> PathBuf {
    dir.join(SOCKET_NAME)
}

/// Run the daemon in `dir` until stopped.
pub async fn serve(dir: PathBuf) -> Result<()> {
    platform::check_socket_path(&socket_path(&dir)).map_err(anyhow::Error::msg)?;
    platform::check_socket_path(&clotho_holder::socket_path(&dir)).map_err(anyhow::Error::msg)?;
    // The lock keeps a second serve out from the start. The socket is bound only once the
    // holder accepted us: a connectable socket tells `start` the daemon is up, which must not
    // happen for a serve that is about to refuse an incompatible holder and exit.
    let lock_path = dir.join("clothod.lock");
    let lock = clotho_proto::listen::lock(&lock_path).map_err(|e| anyhow!("clothod is already running in {} ({e})", dir.display()))?;
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    // A holder that is shutting down may still accept and then close without a welcome; retry.
    // A holder running another build that can upgrade in place is upgraded to ours first, so
    // the machine runs one build (shells are kept: same process, same PTYs).
    let own_exe = std::env::current_exe()?;
    let own_build = platform::build_id(&own_exe).unwrap_or_default();
    let mut attempt = 0;
    let mut tried_upgrade = false;
    let (mut hrd, mut hwr, first) = loop {
        let stream = connect_holder(&dir).await?;
        let (mut rd, mut wr) = stream.into_split();
        let hello = ToHolder::Hello { protocol: HOLDER_PROTOCOL, version: Some(env!("CARGO_PKG_VERSION").into()) };
        wr.write_all(&Frame::Json(serde_json::to_value(&hello)?).encode()).await?;
        let f = match read_frame(&mut rd).await {
            Ok(Some(f)) => f,
            Ok(None) | Err(_) if attempt < 25 => {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
            other => bail!("expected welcome from holder, got {other:?}"),
        };
        let upgradable = match &f {
            Frame::Json(v) => match serde_json::from_value::<FromHolder>(v.clone()) {
                Ok(FromHolder::Welcome { build: Some(b), upgrade_formats, .. }) => !upgrade_formats.is_empty() && b != own_build,
                _ => false,
            },
            _ => false,
        };
        if upgradable && !tried_upgrade && std::env::var_os("CLOTHOD_NO_HOLDER_UPGRADE").is_none() {
            tried_upgrade = true;
            let up = ToHolder::Upgrade { id: 1, exe: own_exe.to_string_lossy().into_owned() };
            wr.write_all(&Frame::Json(serde_json::to_value(&up)?).encode()).await?;
            // Success: the connection closes when the image is replaced. Failure: an Error.
            loop {
                match read_frame(&mut rd).await {
                    Ok(Some(Frame::Json(v))) => {
                        if let Ok(FromHolder::Error { id: 1, message }) = serde_json::from_value::<FromHolder>(v) {
                            eprintln!("clothod: holder kept its build: {message}");
                            break;
                        }
                    }
                    Ok(Some(_)) => {}
                    Ok(None) | Err(_) => {
                        eprintln!("clothod: holder upgraded itself in place to {own_build}");
                        break;
                    }
                }
            }
            continue; // reconnect: a fresh welcome (and recovery) from whichever image runs now
        }
        break (rd, wr, f);
    };
    let (htx, mut hrx) = mpsc::unbounded_channel::<Vec<u8>>();
    let htx = HolderTx { tx: htx, queued: Arc::new(AtomicUsize::new(0)) };
    let holder_queued = htx.queued.clone();
    let holder_writer = tokio::spawn(async move {
        while let Some(buf) = hrx.recv().await {
            // An empty buffer is the "flush and close" marker sent on exit.
            if buf.is_empty() || hwr.write_all(&buf).await.is_err() {
                break;
            }
            holder_queued.fetch_sub(buf.len(), Ordering::Relaxed);
        }
        let _ = hwr.shutdown().await;
    });

    let (instance, state, holder_info) = match Some(first) {
        Some(Frame::Json(v)) => match serde_json::from_value::<FromHolder>(v)? {
            FromHolder::Welcome { instance, state, pid, protocol, version, exe, build, upgrade_formats, namespace } => {
                // Outdated: not this build. Legacy holders (no in-place upgrade) stay so until
                // a full restart; the apps ask the user for it.
                let outdated = build.as_deref() != Some(own_build.as_str());
                let info = json!({"pid": pid, "version": version, "protocol": protocol, "exe": exe, "build": build,
                    "can_upgrade": !upgrade_formats.is_empty(), "outdated": outdated, "namespace": namespace});
                if !(HOLDER_PROTOCOL_MIN..=HOLDER_PROTOCOL).contains(&protocol) {
                    // Leave the holder and its shells alone: dropping the connection without
                    // sending anything else changes nothing there.
                    bail!(
                        "{INCOMPATIBLE}: the running PTY holder (pid {pid}, version {version}, holder protocol {protocol}, {}) \
                         cannot be driven by this clothod {} (holder protocols {HOLDER_PROTOCOL_MIN}..={HOLDER_PROTOCOL}). \
                         Its shells are untouched. To finish upgrading, restart sessions: `clothod shutdown` (ends every \
                         shell), then `clothod start`. Or keep using the old clothod: {}",
                        exe.as_deref().unwrap_or("unknown executable"),
                        env!("CARGO_PKG_VERSION"),
                        exe.as_deref().unwrap_or("?"),
                    );
                }
                eprintln!("clothod: connected to holder {pid} version {version} protocol {protocol} (instance {instance})");
                if let Some(ns) = platform::launchd_namespace() {
                    eprintln!("clothod: launchd namespace: serve {ns}, holder {}", namespace.as_deref().unwrap_or("unknown"));
                }
                (instance, state, info)
            }
            other => bail!("expected welcome from holder, got {other:?}"),
        },
        other => bail!("expected welcome from holder, got {other:?}"),
    };

    let scrollback = crate::config::scrollback_lines();
    let d = Arc::new(Daemon {
        dir: dir.clone(),
        instance,
        build: own_build.clone(),
        holder_info,
        holder: htx,
        model: Mutex::new(Model::default()),
        rev: AtomicU64::new(1),
        panes: Mutex::new(HashMap::new()),
        spawns: Mutex::new(HashMap::new()),
        scrollback: AtomicUsize::new(scrollback),
        recovered_scrollback: state
            .as_ref()
            .and_then(|s| s.get("meta"))
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(id, v)| {
                        let n = (v.get("scrollback_lines")?.as_u64()? as usize).min(crate::config::MAX_SCROLLBACK);
                        // State from before `scrollback_own`: a pane with another value than
                        // the config's asked for it.
                        let own = v.get("scrollback_own").and_then(Value::as_bool).unwrap_or(n != scrollback);
                        Some((id.parse().ok()?, (n, own)))
                    })
                    .collect()
            })
            .unwrap_or_default(),
        next_req: AtomicU64::new(1),
        clients: Mutex::new(HashMap::new()),
        next_client: AtomicU64::new(1),
        live: AtomicBool::new(false),
        dirty: AtomicBool::new(false),
        stop: Notify::new(),
        shutdown_all: AtomicBool::new(false),
        had_real_client: AtomicBool::new(false),
        colors_seq: AtomicU64::new(0),
        // Ephemeral (test) instances keep registrations with themselves, so they go away together.
        places: Mutex::new(HashMap::new()),
        push: crate::push::Push::load(&if platform::ephemeral().is_some() { dir.clone() } else { platform::log_dir(&dir) }),
        git: Mutex::new(GitCache::default()),
        gh_slots: Arc::new(tokio::sync::Semaphore::new(2)),
        summary: crate::summary::Summarizer::new(&dir, crate::config::notification_rewrite()),
        me: std::sync::OnceLock::new(),
        layout: crate::layout::path().map(|path| LayoutWriter {
            path,
            host: platform::hostname(),
            runtime_dir: dir.to_string_lossy().into_owned(),
            st: Mutex::new(LayoutState::default()),
        }),
    });
    let _ = d.me.set(Arc::downgrade(&d));

    // Recovery: panes with their snapshots and buffered output, up to `ready`.
    let started = Instant::now();
    loop {
        let frame = read_frame(&mut hrd).await?.ok_or_else(|| anyhow!("holder closed during recovery"))?;
        if let Frame::Json(v) = &frame {
            if matches!(serde_json::from_value::<FromHolder>(v.clone()), Ok(FromHolder::Ready)) {
                break;
            }
        }
        d.on_holder_frame(frame);
    }
    // A holder that never had a serve (it has no state, and no panes) means a fresh start: the
    // machine rebooted, or the holder died. Then, and only then, bring back the saved layout.
    // restore_model gives the holder a state right away, so a serve that starts after this one
    // (a crash mid-restore) adopts the holder instead of restoring a second time.
    let fresh = state.is_none() && d.panes.lock().unwrap().is_empty();
    let saved = match (&d.layout, fresh) {
        (Some(w), true) => match crate::layout::load(&w.path, &w.host, Path::new(&w.runtime_dir)) {
            crate::layout::Loaded::Ok(s) => Some(s),
            crate::layout::Loaded::Missing => None,
            crate::layout::Loaded::NotOurs(why) => {
                log(format_args!("layout: not restoring {}: {why}", w.path.display()));
                None
            }
            crate::layout::Loaded::Corrupt(to) => {
                log(format_args!("layout: {} was unreadable; moved it to {}", w.path.display(), to.display()));
                None
            }
        },
        _ => None,
    };
    if let (Some(w), false) = (&d.layout, fresh) {
        if let crate::layout::Loaded::Ok(s) = crate::layout::load(&w.path, &w.host, Path::new(&w.runtime_dir)) {
            let mut st = w.st.lock().unwrap();
            st.hints = s.panes.into_iter().filter_map(|(id, p)| Some((id.parse().ok()?, p.agent?))).collect();
            st.hints_until = Some(Instant::now() + Duration::from_secs(5));
        }
    }
    d.restore_model(state);
    // Replay may end inside a synchronized update. Apply it now and drop what it produced:
    // replies to replayed queries were answered by the previous process (or never will be),
    // and must not reach the application a second time once we are live.
    for p in d.panes.lock().unwrap().values() {
        let mut p = p.lock().unwrap();
        let dropped = p.vt.flush_sync();
        if dropped.iter().any(|e| matches!(e, VtEvent::Reply(_))) {
            eprintln!("clothod: pane {}: dropped replies to replayed queries", p.id);
        }
        if let Some(t) = p.vt.title() {
            p.title = Some(t.to_string());
        }
    }
    d.live.store(true, Ordering::SeqCst);
    let n = d.panes.lock().unwrap().len();
    eprintln!("clothod: recovered {n} panes in {:?}", started.elapsed());

    let reader = {
        let d = d.clone();
        tokio::spawn(async move {
            loop {
                match read_frame(&mut hrd).await {
                    Ok(Some(frame)) => d.on_holder_frame(frame),
                    Ok(None) => {
                        eprintln!("clothod: holder closed the connection");
                        break;
                    }
                    Err(e) => {
                        eprintln!("clothod: holder connection error: {e}");
                        break;
                    }
                }
            }
            // Without the holder there is nothing to serve. Exit; the next start reconnects
            // (or starts a fresh holder) and recovers.
            d.stop.notify_one();
        })
    };

    if let Some(saved) = saved {
        d.restore_layout(saved).await;
    }
    if let Some(w) = &d.layout {
        w.st.lock().unwrap().enabled = true;
        d.persist();
    }

    let sock = socket_path(&dir);
    let pid = format!("{}\n", std::process::id()).into_bytes();
    let mut listener = HealingListener::bind_locked(
        &sock,
        &lock_path,
        lock,
        vec![
            (dir.join("clothod.pid"), pid.clone()),
            (platform::log_dir(&dir).join("clothod.live"), pid),
            // For `clothod report` from panes whose environment doesn't name the socket.
            (platform::registry_dir().join(std::process::id().to_string()), sock.to_string_lossy().as_bytes().to_vec()),
        ],
    )
    .with_context(|| format!("binding {}", sock.display()))?;
    eprintln!("clothod {} listening on {}", std::process::id(), sock.display());

    tokio::spawn(ticker(d.clone()));

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let stream = accepted?;
                if platform::peer_uid(stream.as_raw_fd()) != Some(platform::current_uid()) {
                    continue;
                }
                let d = d.clone();
                tokio::spawn(async move { d.serve_client(stream).await });
            }
            _ = d.stop.notified() => break,
        }
    }

    if let Some(ms) = std::env::var("CLOTHOD_TEST_SLOW_EXIT_MS").ok().and_then(|v| v.parse().ok()) {
        // Tests: a daemon that is slow to go away after its socket is gone (many panes to
        // snapshot, a loaded machine), as an upgrade's start can find it.
        let _ = std::fs::remove_file(&sock);
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }
    listener.close();
    reader.abort();
    if d.shutdown_all.load(Ordering::SeqCst) {
        d.to_holder(&ToHolder::Shutdown);
    } else {
        // Leave the holder fresh snapshots so the next start replays little.
        let panes: Vec<_> = d.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            let mut p = p.lock().unwrap();
            if p.vt_seq != p.snap_seq {
                d.push_snapshot(&mut p);
            }
        }
        d.persist();
    }
    if let Some(w) = &d.layout {
        w.flush(true);
    }
    let _ = d.holder.send(Vec::new());
    let _ = tokio::time::timeout(Duration::from_secs(5), holder_writer).await;
    if d.shutdown_all.load(Ordering::SeqCst) && platform::ephemeral().is_some() {
        // Temporary instance: leave nothing behind once the holder is gone.
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && clotho_proto::listen::lock(&dir.join("holder.lock")).is_err() {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
    Ok(())
}

async fn connect_holder(dir: &Path) -> Result<UnixStream> {
    let sock = clotho_holder::socket_path(dir);
    if let Ok(s) = UnixStream::connect(&sock).await {
        return Ok(s);
    }
    // A holder that lost its socket (temp cleaner) is told to rebind rather than replaced:
    // a second holder would orphan the first one's shells.
    if let Some(pid) = clotho_proto::listen::live_instance(&platform::log_dir(dir).join("holder.live")) {
        eprintln!("clothod: holder {pid} is running but its socket is gone; asking it to rebind");
        clotho_proto::listen::poke(pid);
    } else {
        spawn_holder(dir)?;
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match UnixStream::connect(&sock).await {
            Ok(s) => return Ok(s),
            Err(e) if Instant::now() > deadline => return Err(e).context("holder did not come up"),
            Err(_) => tokio::time::sleep(Duration::from_millis(20)).await,
        }
    }
}

/// Start `clothod holder` detached from us (own session, stdio to a log file).
fn spawn_holder(dir: &Path) -> Result<()> {
    let exe = std::env::current_exe()?;
    let log_dir = platform::log_dir(dir);
    platform::ensure_private_dir(&log_dir)?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(log_dir.join("holder.log"))?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("holder").arg("--runtime-dir").arg(dir);
    crate::detach(&mut cmd, log)?;
    cmd.spawn().context("starting holder")?;
    Ok(())
}

/// Largest OSC 52 copy passed on to clients, in bytes of UTF-8 text. Bigger ones are dropped
/// (and logged), not truncated: a partial copy would paste wrong without anyone noticing.
const MAX_CLIPBOARD: usize = 1 << 20;

/// A pane's application set the clipboard (OSC 52): tell every client attached to the pane.
fn send_clipboard(p: &Pane, selection: bool, text: &str) {
    if text.is_empty() || p.subs.is_empty() {
        return;
    }
    if text.len() > MAX_CLIPBOARD {
        eprintln!("clothod: pane {}: dropped a {} byte OSC 52 copy (limit {MAX_CLIPBOARD})", p.id, text.len());
        return;
    }
    let target = if selection { "selection" } else { "clipboard" };
    let frame = Frame::Json(json!({"event": "pane.clipboard", "data": {"pane": p.id, "target": target, "text": text}})).encode();
    for s in p.subs.values() {
        s.client.control(frame.clone());
    }
}

impl Daemon {
    fn to_holder(&self, msg: &ToHolder) {
        let v = serde_json::to_value(msg).expect("holder messages serialize");
        let _ = self.holder.send(Frame::Json(v).encode());
    }

    fn pane(&self, id: u64) -> Option<Arc<Mutex<Pane>>> {
        self.panes.lock().unwrap().get(&id).cloned()
    }

    fn event_clients(&self) -> Vec<Arc<Client>> {
        self.clients.lock().unwrap().values().filter(|c| c.events.load(Ordering::Relaxed)).cloned().collect()
    }

    fn broadcast(&self, event: &str, data: Value) {
        let frame = Frame::Json(json!({"event": event, "data": data})).encode();
        for c in self.event_clients() {
            c.control(frame.clone());
        }
    }

    fn next_rev(&self) -> u64 {
        self.rev.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// `pane` event for event subscribers, plus the pane's own subscribers (they need `exited`).
    fn pane_event(&self, p: &Pane) {
        let mut data = p.json();
        data["rev"] = json!(self.next_rev());
        let frame = Frame::Json(json!({"event": "pane", "data": data})).encode();
        let mut sent = Vec::new();
        for c in self.event_clients() {
            sent.push(c.id);
            c.control(frame.clone());
        }
        for s in p.subs.values() {
            if !sent.contains(&s.client.id) {
                s.client.control(frame.clone());
            }
        }
        self.dirty.store(true, Ordering::Relaxed);
    }

    fn state_json(&self) -> Value {
        let model = self.model.lock().unwrap();
        let panes: Vec<Value> = model
            .panes()
            .iter()
            .filter_map(|id| self.pane(*id))
            .map(|p| p.lock().unwrap().json())
            .collect();
        json!({
            "rev": self.rev.load(Ordering::SeqCst),
            "focus": model.focus,
            "workspaces": model.workspaces,
            "panes": panes,
        })
    }

    /// Model changed: tell event subscribers and persist.
    fn model_changed(&self) {
        self.next_rev();
        self.broadcast("state", self.state_json());
        self.persist();
    }

    /// Store the model (and pane titles/cwds) in the holder.
    fn persist(&self) {
        self.dirty.store(false, Ordering::Relaxed);
        let model = self.model.lock().unwrap().clone();
        *self.places.lock().unwrap() = model
            .workspaces
            .iter()
            .flat_map(|w| w.tabs.iter().flat_map(move |t| t.panes().into_iter().map(move |p| (p, (Some(w.id), Some(w.name.clone()), t.title.clone())))))
            .collect();
        let meta: HashMap<String, Value> = self
            .panes
            .lock()
            .unwrap()
            .iter()
            .map(|(id, p)| {
                let p = p.lock().unwrap();
                let muted = p.agent.as_ref().filter(|a| a.muted).map(|a| json!({"kind": a.kind, "pid": a.pid, "session": a.session}))
                    .or_else(|| p.muted_agent.as_ref().map(|(k, pid, s)| json!({"kind": k, "pid": pid, "session": s})));
                (id.to_string(), json!({"title": p.title, "cwd": p.cwd, "scrollback_lines": p.vt.scrollback(), "scrollback_own": p.own_scrollback,
                    "agent_muted": muted, "agent_history": p.history, "restored": p.restored,
                    "agent": p.agent.as_ref().filter(|a| a.source == "hook" && a.pid.is_some()).map(|a| {
                        let mut j = a.json();
                        j["pid"] = json!(a.pid);
                        j
                    })}))
            })
            .collect();
        if let Some(w) = &self.layout {
            w.offer(self.saved_layout(&model, w));
        }
        let state = json!({"model": model, "meta": meta});
        self.to_holder(&ToHolder::SetState { state });
    }

    /// The layout file's view of `model`: structure, and each pane's cwd, command, size and
    /// resumable agent session.
    fn saved_layout(&self, model: &Model, w: &LayoutWriter) -> crate::layout::Saved {
        let mut panes = HashMap::new();
        for id in model.panes() {
            let Some(p) = self.pane(id) else { continue };
            let p = p.lock().unwrap();
            let cwd = p.cwd.clone().or_else(|| p.polled_cwd.clone()).or_else(|| platform::process_cwd(p.pid).map(|c| c.to_string_lossy().into_owned()));
            let mut agent = p
                .agent
                .as_ref()
                .filter(|a| matches!(a.kind.as_str(), "claude" | "codex"))
                .map(|a| crate::layout::SavedAgent { kind: a.kind.clone(), session: a.session.clone().filter(|s| crate::layout::safe_session(s)) });
            let has_session = agent.as_ref().is_some_and(|a| a.session.is_some());
            {
                let mut st = w.st.lock().unwrap();
                if !st.hints.is_empty() {
                    let early = st.hints_until.is_some_and(|t| Instant::now() < t);
                    match (&p.agent, has_session) {
                        // Its own session (a hook reported one): the hint is done.
                        (Some(_), true) => {
                            st.hints.remove(&id);
                        }
                        (Some(a), false) => {
                            if st.hints.get(&id).is_some_and(|h| h.kind == a.kind) {
                                agent = st.hints.get(&id).cloned();
                            } else {
                                st.hints.remove(&id);
                            }
                        }
                        (None, _) if early => agent = st.hints.get(&id).cloned(),
                        (None, _) => {
                            st.hints.remove(&id);
                        }
                    }
                }
                match &agent {
                    // The same agent, there all along since its session was known (a restored
                    // one starting again without hooks): it keeps that session.
                    Some(a) if a.session.is_none() && st.agents.get(&id).is_some_and(|(k, gone)| gone.is_none() && k.kind == a.kind && k.session.is_some()) => {
                        agent = st.agents.get(&id).map(|(k, _)| k.clone());
                    }
                    Some(a) => {
                        st.agents.insert(id, (a.clone(), None));
                    }
                    None => {
                        let quiet = agent_gone_quiet();
                        if let Some((a, gone)) = st.agents.get_mut(&id) {
                            if gone.get_or_insert_with(Instant::now).elapsed() < quiet {
                                agent = Some(a.clone());
                            } else {
                                st.agents.remove(&id);
                            }
                        }
                    }
                }
            }
            panes.insert(id.to_string(), crate::layout::SavedPane { cwd, command: p.command.clone(), cols: p.cols, rows: p.rows, agent });
        }
        w.st.lock().unwrap().agents.retain(|id, _| panes.contains_key(&id.to_string()));
        crate::layout::Saved {
            version: crate::layout::VERSION,
            host: w.host.clone(),
            runtime_dir: w.runtime_dir.clone(),
            saved_at: 0.0,
            model: model.clone(),
            panes,
        }
    }

    /// Bring back a saved layout into a fresh holder: a new shell per pane in its cwd, typing
    /// the resume line for a pane whose agent had a session. Panes that fail to start are left
    /// out; nothing is retried.
    async fn restore_layout(self: &Arc<Self>, saved: crate::layout::Saved) {
        let at = unix_now();
        let mut model = saved.model;
        let mut map = HashMap::new();
        let mut resumed = 0;
        // Panes per (agent kind, cwd): an agent without a known session is continued (its latest
        // conversation in that folder) only if no other saved pane had that kind there, with a
        // session or without; otherwise two panes could open the same conversation.
        let mut sharing: HashMap<(String, String), usize> = HashMap::new();
        for sp in saved.panes.values() {
            if let (Some(a), Some(cwd)) = (&sp.agent, &sp.cwd) {
                *sharing.entry((a.kind.clone(), cwd.clone())).or_default() += 1;
            }
        }
        for old in model.panes() {
            let sp = saved.panes.get(&old.to_string()).cloned().unwrap_or_default();
            let cwd = sp.cwd.clone().filter(|c| Path::new(c).is_dir());
            let alone = |kind: &str| cwd.as_ref().is_some_and(|c| sharing.get(&(kind.to_string(), c.clone())) == Some(&1));
            let command = if crate::layout::is_shell(&sp.command) { sp.command } else { default_shell() };
            let (cols, rows) = if sp.cols >= 2 && sp.rows >= 2 { (sp.cols, sp.rows) } else { (80, 24) };
            let opts = SpawnOpts { command, cwd: cwd.clone(), env: Vec::new(), cols, rows, scrollback: None };
            let new = match self.spawn_pane(opts).await {
                Ok(n) => n,
                Err(e) => {
                    log(format_args!("layout: pane {old} not restored: {}", e.message));
                    continue;
                }
            };
            map.insert(old, new);
            let mut continued = false;
            let line = sp.agent.as_ref().and_then(|a| {
                crate::layout::resume_line(a).or_else(|| {
                    // Only in the saved cwd itself (never $HOME instead), and alone there.
                    let l = crate::layout::continue_line(&a.kind).filter(|_| a.session.is_none() && alone(&a.kind))?;
                    continued = true;
                    Some(l.to_string())
                })
            });
            let agent = sp.agent.filter(|_| line.is_some());
            if let (Some(a), Some(w)) = (&agent, &self.layout) {
                // Kept while it starts again, as after an agent left (a second reboot soon after).
                w.st.lock().unwrap().agents.insert(new, (a.clone(), None));
            }
            if let Some(p) = self.pane(new) {
                p.lock().unwrap().restored = Some(json!({"at": at, "agent": agent.as_ref().map(|a| &a.kind), "session": agent.as_ref().and_then(|a| a.session.as_ref()), "continued": continued}));
            }
            if let Some(line) = line {
                resumed += 1;
                let d = self.clone();
                tokio::spawn(async move { d.type_when_ready(new, line).await });
            }
        }
        model.remap_panes(&map);
        let n = model.panes().len();
        *self.model.lock().unwrap() = model;
        self.model_changed();
        log(format_args!("layout: restored {n} panes ({resumed} resuming an agent) in {} workspaces, saved at {}", self.model.lock().unwrap().workspaces.len(), saved.saved_at as u64));
    }

    /// Type `line` into a new pane once its shell is up: it printed (a prompt) and went quiet,
    /// or 5 s passed.
    async fn type_when_ready(&self, pane: u64, line: String) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let Some(p) = self.pane(pane) else { return };
            let p = p.lock().unwrap();
            if p.exited.is_some() {
                return;
            }
            if (p.ring.end() > 0 && p.last_output.elapsed() >= Duration::from_millis(300)) || Instant::now() >= deadline {
                break;
            }
        }
        let _ = self.holder.send(Frame::Input { pane, data: line.into_bytes() }.encode());
    }

    fn restore_model(&self, state: Option<Value>) {
        let state = state.unwrap_or(Value::Null);
        let mut model: Model = state.get("model").cloned().and_then(|m| serde_json::from_value(m).ok()).unwrap_or_default();
        if let Some(Value::Object(meta)) = state.get("meta") {
            for (id, m) in meta {
                let Some(p) = id.parse().ok().and_then(|id| self.pane(id)) else { continue };
                let mut p = p.lock().unwrap();
                if p.title.is_none() {
                    p.title = m.get("title").and_then(Value::as_str).map(String::from);
                }
                if p.cwd.is_none() {
                    p.cwd = m.get("cwd").and_then(Value::as_str).map(String::from);
                }
                p.restored = m.get("restored").filter(|r| r.is_object()).cloned();
                // The hook-reported agent, while its process lives: a restart (an upgrade) keeps
                // what it reported, its session above all, instead of waiting for its next hook.
                // Taken back as it was, without events or pushes: nothing changed.
                if p.agent.is_none() {
                    if let Some(a) = m.get("agent").and_then(Agent::from_saved).filter(|a| a.pid.is_some_and(platform::process_alive)) {
                        if a.muted {
                            p.muted_agent = None;
                        }
                        p.agent = Some(a);
                    }
                }
                if let Some(a) = m.get("agent_muted").filter(|a| a.is_object()) {
                    if let Some(kind) = a.get("kind").and_then(Value::as_str) {
                        let pid = a.get("pid").and_then(Value::as_u64).map(|v| v as u32);
                        // Only while that process lives: otherwise it's gone, and so is the mute.
                        if pid.is_none_or(platform::process_alive) {
                            p.muted_agent = Some((kind.into(), pid, a.get("session").and_then(Value::as_str).map(String::from)));
                        }
                    }
                }
                if let Some(Value::Array(h)) = m.get("agent_history") {
                    let skip = h.len().saturating_sub(HISTORY_MAX);
                    let mut restored: VecDeque<Value> = h.iter().skip(skip).filter(|e| e.is_object()).cloned().collect();
                    // Anything logged since this serve started comes after.
                    restored.extend(p.history.drain(..));
                    while restored.len() > HISTORY_MAX {
                        restored.pop_front();
                    }
                    p.history = restored;
                }
                // Recovery built the VT with the default; a pane spawned with its own keeps it.
                if let Some(n) = m.get("scrollback_lines").and_then(Value::as_u64) {
                    if p.own_scrollback {
                        p.vt.set_scrollback((n as usize).min(crate::config::MAX_SCROLLBACK));
                    }
                }
            }
        }
        let held: Vec<(u64, bool)> = {
            let panes = self.panes.lock().unwrap();
            panes.iter().map(|(id, p)| (*id, p.lock().unwrap().exited.is_some())).collect()
        };
        // Panes the model lost track of (e.g. spawned just before a crash) get their own tabs.
        for (id, exited) in &held {
            if *exited {
                model.remove_pane(*id);
                self.panes.lock().unwrap().remove(id);
                self.to_holder(&ToHolder::Forget { pane: *id });
            } else if !model.contains_pane(*id) {
                let ws = match model.workspaces.iter().find(|w| w.name == "recovered") {
                    Some(w) => w.id,
                    None => model.create_workspace(Some("recovered".into()), *id).0,
                };
                if !model.contains_pane(*id) {
                    model.create_tab(ws, *id);
                }
            }
        }
        for id in model.panes() {
            if !held.iter().any(|(h, _)| *h == id) {
                model.remove_pane(id);
            }
        }
        *self.model.lock().unwrap() = model;
        self.persist();
    }

    // ---- holder side -------------------------------------------------------------------

    fn on_holder_frame(&self, frame: Frame) {
        match frame {
            Frame::Output { pane, seq, data } => match self.pane(pane) {
                Some(p) => self.on_output(&mut p.lock().unwrap(), seq, &data),
                None => eprintln!("clothod: dropped {} bytes of output for unknown pane {pane} at {seq}", data.len()),
            },
            Frame::Snapshot { pane, seq, cols, rows, data } => {
                // Only during recovery: the stored snapshot to rebuild the VT from.
                if let Some(p) = self.pane(pane) {
                    let mut p = p.lock().unwrap();
                    if seq >= p.ring.start() && seq <= p.ring.start() + RING_CAPACITY as u64 {
                        let mut vt = Vt::with_scrollback(cols, rows, p.vt.scrollback());
                        vt.feed(&data);
                        p.vt = vt;
                        p.vt_seq = seq;
                        p.snap_seq = seq;
                        p.title = p.vt.title().map(String::from);
                        p.replay_resizes.retain(|r| r.0 > seq);
                    } else {
                        eprintln!("clothod: pane {pane}: stored snapshot at {seq} is outside the buffer, replaying buffer only");
                    }
                }
            }
            Frame::Json(v) => match serde_json::from_value::<FromHolder>(v) {
                Ok(msg) => self.on_holder_msg(msg),
                Err(e) => eprintln!("clothod: bad message from holder: {e}"),
            },
            _ => {}
        }
    }

    fn on_holder_msg(&self, msg: FromHolder) {
        match msg {
            FromHolder::Pane(info) => {
                // Recovery: the VT starts blank at the buffer start, at the size the buffer's
                // oldest bytes were written at; a stored snapshot (next frame) replaces it.
                // A pane that follows the setting gets the current one, which may have changed
                // since it was stored.
                let (scrollback, own) = match self.recovered_scrollback.get(&info.pane) {
                    Some(&(n, true)) => (n, true),
                    _ => (self.scrollback.load(Ordering::Relaxed), false),
                };
                let mut p = Pane::new(&info, scrollback, own);
                let start = info.seq_start;
                let initial = info.resizes.iter().filter(|r| r.0 <= start).last().copied();
                if let Some((_, c, r)) = initial {
                    p.vt = Vt::with_scrollback(c, r, scrollback);
                }
                p.replay_resizes = info.resizes.iter().filter(|r| r.0 > start).copied().collect();
                p.snap_seq = start;
                self.panes.lock().unwrap().insert(info.pane, Arc::new(Mutex::new(p)));
            }
            FromHolder::Spawned { id, pane } => {
                let waiter = self.spawns.lock().unwrap().remove(&id);
                let own = waiter.as_ref().and_then(|w| w.1);
                let mut p = Pane::new(&pane, own.unwrap_or_else(|| self.scrollback.load(Ordering::Relaxed)), own.is_some());
                // Its applications may ask for colors before anyone types in it.
                self.refresh_palette(&mut p);
                self.panes.lock().unwrap().insert(pane.pane, Arc::new(Mutex::new(p)));
                if let Some((tx, _)) = waiter {
                    let _ = tx.send(Ok(pane));
                }
            }
            FromHolder::Error { id, message } => {
                if let Some((tx, _)) = self.spawns.lock().unwrap().remove(&id) {
                    let _ = tx.send(Err(message));
                }
            }
            FromHolder::Exited { pane, status } => self.on_exit(pane, status),
            FromHolder::Welcome { .. } | FromHolder::Ready => {}
        }
    }

    fn on_output(&self, p: &mut Pane, seq: u64, data: &[u8]) {
        let (mut seq, mut data) = (seq, data);
        let end = p.ring.end();
        if seq < end {
            // Overlap (can only happen around recovery): keep what is new.
            let skip = (end - seq) as usize;
            if skip >= data.len() {
                return;
            }
            data = &data[skip..];
            seq = end;
        } else if seq > end {
            eprintln!("clothod: pane {}: output gap {end}..{seq}", p.id);
            p.ring.reset(seq);
            p.vt_seq = p.vt_seq.max(seq);
        }
        p.ring.push(data);
        p.last_output = Instant::now();

        // Feed the VT what it hasn't seen, applying recorded resizes at their positions.
        let mut events = Vec::new();
        let mut pos = seq;
        while pos < seq + data.len() as u64 {
            if pos < p.vt_seq {
                pos = p.vt_seq.min(seq + data.len() as u64);
                continue;
            }
            let mut upto = seq + data.len() as u64;
            while let Some(&(rseq, cols, rows)) = p.replay_resizes.first() {
                if rseq <= pos {
                    p.vt.resize(cols, rows);
                    p.replay_resizes.remove(0);
                } else {
                    upto = upto.min(rseq);
                    break;
                }
            }
            let slice = &data[(pos - seq) as usize..(upto - seq) as usize];
            events.extend(p.vt.feed(slice));
            pos = upto;
            p.vt_seq = upto;
        }
        self.on_vt_events(p, events);

        if !p.subs.is_empty() {
            let frame = Frame::Output { pane: p.id, seq, data: data.to_vec() }.encode();
            let mut lagged = Vec::new();
            for (cid, s) in p.subs.iter_mut() {
                if s.lagging {
                    continue;
                }
                if s.client.queued.load(Ordering::Relaxed) > CLIENT_HIGH {
                    s.client.full.store(true, Ordering::Relaxed);
                    s.lagging = true;
                    lagged.push(*cid);
                    continue;
                }
                s.client.output(frame.clone());
            }
            for cid in lagged {
                self.watch_lagging(p.id, cid);
            }
        }

        if self.live.load(Ordering::Relaxed) && p.vt_seq - p.snap_seq >= SNAPSHOT_FORCE {
            self.push_snapshot(p);
        }
    }

    fn on_vt_events(&self, p: &mut Pane, events: Vec<VtEvent>) {
        let live = self.live.load(Ordering::Relaxed);
        let mut changed = false;
        for ev in events {
            match ev {
                VtEvent::Reply(bytes) => {
                    // Replies to queries in replayed output were answered long ago.
                    if live {
                        let _ = self.holder.send(Frame::Input { pane: p.id, data: bytes }.encode());
                    }
                }
                VtEvent::Title(t) => {
                    if p.title != t {
                        p.title = t;
                        changed = true;
                    }
                }
                VtEvent::Cwd(c) => {
                    if p.cwd.as_deref() != Some(&c) {
                        p.cwd = Some(c);
                        changed = true;
                    }
                }
                VtEvent::Bell if p.agent.as_ref().is_some_and(|a| a.source == "detected") => {
                    // A real terminal bell from a detected agent: it wants the user.
                    if live {
                        let mut a = p.agent.clone().unwrap();
                        if a.state != "waiting" {
                            a.state = "waiting".into();
                            a.message = None;
                            a.guess = false;
                            self.set_agent(p, Some(a.clone()));
                        }
                        a.attention = true;
                        self.set_agent(p, Some(a));
                        self.broadcast("bell", json!({"pane": p.id}));
                    }
                }
                VtEvent::Bell => {
                    if live {
                        self.broadcast("bell", json!({"pane": p.id}));
                    }
                }
                // Replayed output after a restart copied long ago: never again.
                VtEvent::Clipboard { selection, text } => {
                    if live {
                        send_clipboard(p, selection, &text);
                    }
                }
            }
        }
        if changed && live {
            self.pane_event(p);
        }
    }

    /// Snapshot a pane's VT. Taking it applies a held synchronized update, whose replies (to
    /// live queries) go out like any others.
    fn snapshot(&self, p: &mut Pane, scrollback: Option<usize>) -> Vec<u8> {
        let data = p.vt.snapshot(scrollback);
        let events = p.vt.take_events();
        self.on_vt_events(p, events);
        data
    }

    fn push_snapshot(&self, p: &mut Pane) {
        let data = self.snapshot(p, None);
        let frame = Frame::Snapshot { pane: p.id, seq: p.vt_seq, cols: p.vt.cols(), rows: p.vt.rows(), data };
        let _ = self.holder.send(frame.encode());
        p.snap_seq = p.vt_seq;
        p.snap_at = Instant::now();
    }

    fn on_exit(&self, pane: u64, status: ExitStatus) {
        let Some(p) = self.pane(pane) else { return };
        let place = self.model.lock().unwrap().locate(pane);
        let how = match status {
            ExitStatus::Code(c) => format!("exit status {c}"),
            ExitStatus::Signal(s) => format!("signal {s}"),
        };
        match place {
            Some((ws, tab)) => log(format_args!("pane {pane} ended ({how}); its tab {tab} in workspace {ws} loses it")),
            None => log(format_args!("pane {pane} ended ({how})")),
        }
        {
            let mut p = p.lock().unwrap();
            p.exited = Some(status);
            self.pane_event(&p);
        }
        self.panes.lock().unwrap().remove(&pane);
        if let Some(w) = &self.layout {
            w.st.lock().unwrap().last_exit = Some(Instant::now());
        }
        self.push.pane_gone(pane);
        self.to_holder(&ToHolder::Forget { pane });
        let removed = self.model.lock().unwrap().remove_pane(pane);
        if removed {
            self.model_changed();
        }
    }

    /// A client fell behind on a pane: once its queue drains, send a fresh snapshot.
    fn watch_lagging(&self, pane: u64, client: u64) {
        let Some(p) = self.pane(pane) else { return };
        let c = self.clients.lock().unwrap().get(&client).cloned();
        let Some(c) = c else { return };
        let holder = self.holder.clone();
        tokio::spawn(async move {
            while c.queued.load(Ordering::Relaxed) > CLIENT_LOW {
                if c.tx.is_closed() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            let mut p = p.lock().unwrap();
            let p = &mut *p;
            let mut clips = Vec::new();
            if let Some(s) = p.subs.get_mut(&client) {
                if s.lagging {
                    s.lagging = false;
                    s.client.json(json!({"event": "pane.resync", "data": {"pane": p.id}}));
                    let data = p.vt.snapshot(Some(DEFAULT_SCROLLBACK));
                    for ev in p.vt.take_events() {
                        match ev {
                            VtEvent::Reply(bytes) => {
                                let _ = holder.send(Frame::Input { pane: p.id, data: bytes }.encode());
                            }
                            // From a held synchronized update the snapshot just applied: live.
                            VtEvent::Clipboard { selection, text } => clips.push((selection, text)),
                            _ => {}
                        }
                    }
                    let frame = Frame::Snapshot { pane: p.id, seq: p.vt_seq, cols: p.vt.cols(), rows: p.vt.rows(), data };
                    s.client.output(frame.encode());
                }
            }
            for (selection, text) in clips {
                send_clipboard(p, selection, &text);
            }
        });
    }

    fn resize(&self, p: &mut Pane, cols: u16, rows: u16) {
        if (cols, rows) == (p.cols, p.rows) {
            return;
        }
        p.cols = cols;
        p.rows = rows;
        p.vt.resize(cols, rows);
        let seq = p.vt_seq;
        self.to_holder(&ToHolder::Resize { pane: p.id, cols, rows, seq });
        let frame = Frame::Json(json!({"event": "pane.resized", "data": {"pane": p.id, "cols": cols, "rows": rows, "seq": seq}})).encode();
        for s in p.subs.values() {
            s.client.control(frame.clone());
        }
        let mut data = p.json();
        data["rev"] = json!(self.next_rev());
        self.broadcast("pane", data);
    }

    /// The client whose viewport sets the size, while it still shows the pane.
    fn size_owner(p: &Pane) -> Option<u64> {
        p.size_client.filter(|c| p.subs.contains_key(c))
    }

    /// `client` focused the pane: its viewport (if it gave one) becomes the pane's size.
    fn focus_size(&self, p: &mut Pane, client: u64) {
        p.size_client = Some(client);
        if let Some((cols, rows)) = p.subs.get(&client).and_then(|s| s.viewport) {
            self.resize(p, cols, rows);
        }
    }

    /// `client` gave a new viewport: it resizes the pane only if that client owns the size, or
    /// nobody showing the pane does (then it takes it). Anyone else's is only recorded.
    fn apply_viewport_policy(&self, p: &mut Pane, client: u64) {
        match Self::size_owner(p) {
            Some(owner) if owner != client => {}
            _ => self.focus_size(p, client),
        }
    }

    fn input(&self, client: u64, pane: u64, data: Vec<u8>) {
        let Some(p) = self.pane(pane) else { return };
        let mut p = p.lock().unwrap();
        // Input never clears an agent's attention: opening a pane alone sends focus reports and
        // mouse motion. A reply makes the agent work again, and that clears it (set_agent).
        // Input marks the user present, but never picks the size: focus does (`pane.focus`).
        p.last_input_at = Some(Instant::now());
        p.last_input_client = Some(client);
        self.use_colors_of(&mut p, client);
        // The user typing in a restored pane has seen it: the note goes (stored at once, so a
        // serve restart doesn't bring it back).
        let seen = p.restored.is_some() && typed(&data);
        if seen {
            p.restored = None;
            self.pane_event(&p);
        }
        let _ = self.holder.send(Frame::Input { pane, data }.encode());
        drop(p);
        if seen {
            self.persist();
        }
    }

    /// The colors applications in the pane get when they ask (OSC 4/10/11/12): those of the
    /// client last using it (typing or subscribing), else of the client that set colors last,
    /// else none (the terminal's dark defaults). Only connected clients count.
    fn pane_palette(&self, p: &Pane) -> Option<Arc<clotho_vt::Palette>> {
        let clients = self.clients.lock().unwrap();
        let colors = |c: &Arc<Client>| c.colors.lock().unwrap().clone();
        if let Some(c) = p.colors_client.and_then(|id| clients.get(&id)).and_then(colors) {
            return Some(c.0);
        }
        clients.values().filter_map(colors).max_by_key(|c| c.1).map(|c| c.0)
    }

    /// Apply the pane's palette to its terminal; an application that asked for mode 2031 is
    /// told when that switches between dark and light.
    fn refresh_palette(&self, p: &mut Pane) {
        let palette = self.pane_palette(p);
        if let Some(note) = p.vt.set_palette(palette) {
            self.on_vt_events(p, vec![VtEvent::Reply(note)]);
        }
    }

    fn use_colors_of(&self, p: &mut Pane, client: u64) {
        if p.colors_client != Some(client) {
            p.colors_client = Some(client);
            self.refresh_palette(p);
        }
    }

    fn refresh_palettes(&self) {
        let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            self.refresh_palette(&mut p.lock().unwrap());
        }
    }

    /// `hello.colors` / `client.colors`: null clears them.
    fn set_client_colors(&self, client: &Client, v: Option<&Value>) -> std::result::Result<(), RpcError> {
        let palette = match v {
            None | Some(Value::Null) => None,
            Some(v) => Some(Arc::new(parse_palette(v).map_err(|e| err("bad_request", format!("colors: {e}")))?)),
        };
        let seq = self.colors_seq.fetch_add(1, Ordering::Relaxed) + 1;
        *client.colors.lock().unwrap() = palette.map(|p| (p, seq));
        self.refresh_palettes();
        Ok(())
    }

    // ---- periodic work -----------------------------------------------------------------

    /// Replace a pane's agent. A new state gets a fresh `since` and, for waiting/done/error,
    /// `attention`. Sends `pane` (any change) and `agent` (appeared, gone, or new state).
    fn set_agent(&self, p: &mut Pane, mut new: Option<Agent>) {
        if new.is_none() {
            // The agent went away: nothing is left to answer its requests.
            p.retire(|_| true);
            for (_, pend) in p.pending.drain() {
                let _ = pend.tx.send(json!({"retired": true}));
            }
        }
        let old = p.agent.clone();
        let from = old.as_ref().map(|a| a.state.clone());
        let mut rewrite = None;
        if let Some(a) = new.as_mut() {
            // Muting belongs to this agent: kept while it's the same one, restored after a
            // restart when it shows up again, gone with a new one.
            let restored = p.muted_agent.take().is_some_and(|(kind, pid, session)| {
                Agent { kind, pid, session, ..a.clone() }.same_as(&a.kind, a.pid, a.session.as_deref())
            });
            a.muted = restored || old.as_ref().is_some_and(|o| o.muted && o.same_as(&a.kind, a.pid, a.session.as_deref()));
            let changed = old.as_ref().map(|o| &o.state) != Some(&a.state);
            // A hook taking over from detection is news even in the same state: detection often
            // reads a quiet agent as waiting before its hook says it waits for permission.
            let hook_took_over = a.source == "hook" && old.as_ref().is_some_and(|o| o.source != "hook");
            let had = old.as_ref().is_some_and(|o| o.attention);
            if changed || hook_took_over {
                // Raised only by exact signals: a hook's report of waiting/done/error, or a BEL
                // (handled by the caller). Cleared only by the agent working again, told by a
                // hook or by Claude's title, never by a guess from output (or by input: the
                // user looking at a pane sends focus and mouse reports; see `input`). Also
                // cleared by agent.ack and when the agent goes away.
                let raise = a.source == "hook" && matches!(a.state.as_str(), "waiting" | "done" | "error");
                let working = !a.guess && matches!(a.state.as_str(), "running" | "starting");
                a.attention = raise || (had && !working);
            }
            if a.muted {
                // Nothing raises a muted agent's attention (hooks, BEL), so it never pushes.
                a.attention = false;
            }
            // A turn that ends while the user is at the pane needs no push or notification:
            // they see it end. Waiting (a permission prompt, a question) and errors always do:
            // the user may have stepped away right after typing, and the agent is stuck until
            // they answer.
            let rose = a.attention && !old.as_ref().is_some_and(|o| o.attention);
            a.quiet = if rose { a.state == "done" && p.user_present() } else { old.as_ref().is_some_and(|o| o.quiet) };
            a.since = match &old {
                Some(o) if !changed => o.since,
                _ => unix_now(),
            };
            // A rewrite belongs to its state and message: kept while they are, gone with them.
            match old.as_ref().filter(|o| o.state == a.state && o.message == a.message && o.since == a.since) {
                Some(o) => (a.rewrite, a.rewrite_pending) = (o.rewrite.clone(), o.rewrite_pending),
                None => (a.rewrite, a.rewrite_pending) = (None, false),
            }
            // Each rise that notifies gets its text rewritten (crate::summary).
            if rose && !a.quiet {
                rewrite = self.summary.start(a.summary_input());
                a.rewrite = None;
                a.rewrite_pending = rewrite.is_some();
            }
        }
        if new == old {
            return;
        }
        p.agent = new;
        if let (Some(rx), Some(a)) = (rewrite.clone(), p.agent.as_ref()) {
            self.await_rewrite(p.id, a, rx);
        }
        // Live Activities following this pane: kind, state, times, and the detail a
        // notification carries (the tool and its input; the summary when it waits or ends).
        self.push.agent(p.id, p.agent.as_ref().and_then(Agent::live));
        match (&old, &p.agent) {
            (Some(o), None) => p.record("gone", Some(&o.state), Some(o)),
            // Detection's output-only guesses flip with every redraw: an agent's arrival is
            // logged, its guessed states are not.
            (Some(o), Some(a)) if a.guess && o.guess && o.kind == a.kind => {}
            (_, Some(a)) => {
                let event = if from.as_deref() != Some(a.state.as_str()) {
                    "state"
                } else if old.as_ref().is_some_and(|o| o.attention != a.attention) {
                    "attention"
                } else {
                    "update"
                };
                p.record(event, from.as_deref(), None);
            }
            (None, None) => {}
        }
        let attention = |a: &Option<Agent>| a.as_ref().is_some_and(|a| a.attention);
        if attention(&old) != attention(&p.agent) {
            let (workspace_id, workspace, tab) = self.places.lock().unwrap().get(&p.id).cloned().unwrap_or_default();
            let dir = p.cwd.clone().or_else(|| p.agent.as_ref().and_then(|a| a.pid).and_then(platform::process_cwd).map(|c| c.display().to_string()));
            let dir = dir.and_then(|d| std::path::Path::new(&d).file_name().map(|n| n.to_string_lossy().into_owned()));
            let alert = p.agent.as_ref().map(|a| crate::push::Alert {
                kind: a.kind.clone(),
                state: a.state.clone(),
                message: a.message.clone(),
                since: a.since,
                prompt: a.prompt.clone(),
                // A permission request says exactly what it asks about, and can be answered.
                tool: a.requests.last().map(|r| r.tool.clone()).or(a.tool.clone()).filter(|_| a.state == "waiting"),
                tool_input: a.requests.last().map(|r| r.summary.clone()).unwrap_or(a.tool_input.clone()).filter(|_| a.state == "waiting"),
                request: a.requests.last().map(|r| r.id.clone()).filter(|_| a.state == "waiting"),
                duration: a.turn_started.filter(|_| a.state != "waiting").map(|t| (a.since - t).max(0.0).round() as u64),
                workspace_id,
                workspace,
                tab,
                project: dir,
                summary: a.summary(),
            });
            let quiet = p.agent.as_ref().is_some_and(|a| a.quiet);
            self.push.attention(p.id, attention(&p.agent), alert, quiet, rewrite);
        }
        // A state change, or attention newly raised in the same state (a hook taking over).
        let transition = from.as_deref() != p.agent.as_ref().map(|a| a.state.as_str()) || (!attention(&old) && attention(&p.agent));
        self.pane_event(p);
        if transition {
            self.broadcast("agent", json!({"pane": p.id, "agent": p.agent.as_ref().map(Agent::json), "from": from}));
        }
    }

    /// When the rewrite started for `a` ends: its text becomes the agent's `summary` (a `pane`
    /// event, and Live Activities follow), if the agent is still in that state with that message.
    /// A failed rewrite only clears `summary_pending`.
    fn await_rewrite(&self, pane: u64, a: &Agent, mut rx: tokio::sync::watch::Receiver<Option<String>>) {
        let Some(me) = self.me.get().and_then(std::sync::Weak::upgrade) else { return };
        let (state, message, since) = (a.state.clone(), a.message.clone(), a.since);
        tokio::spawn(async move {
            let text = rx.wait_for(Option::is_some).await.ok().and_then(|v| v.clone());
            let Some(pp) = me.pane(pane) else { return };
            let mut p = pp.lock().unwrap();
            let Some(a) = p.agent.as_mut().filter(|a| a.state == state && a.message == message && a.since == since && a.rewrite_pending) else { return };
            a.rewrite_pending = false;
            a.rewrite = text;
            let live = a.live();
            me.push.agent(pane, live);
            me.pane_event(&p);
        });
    }

    /// `agent.mute`: set or clear the pane's agent's `muted`. Muting clears attention.
    fn mute(&self, p: &mut Pane, on: bool) {
        let Some(old) = p.agent.clone() else { return };
        if old.muted == on {
            return;
        }
        let mut a = old.clone();
        a.muted = on;
        if on {
            a.attention = false;
        }
        p.agent = Some(a);
        p.record(if on { "mute" } else { "unmute" }, Some(&old.state), None);
        if old.attention && on {
            self.push.attention(p.id, false, None, false, None);
        }
        self.pane_event(p);
        self.broadcast("agent", json!({"pane": p.id, "agent": p.agent.as_ref().map(Agent::json), "from": old.state}));
    }

    /// Detection (no hooks): who is in the foreground of the pane's terminal, and is it busy.
    fn detect_agent(&self, p: &mut Pane) {
        if p.exited.is_some() {
            return;
        }
        // Hook-reported agents: only clear them once their process is gone.
        if let Some(a) = p.agent.as_ref().filter(|a| a.source == "hook") {
            if a.pid.is_some_and(|pid| !platform::process_alive(pid)) {
                self.set_agent(p, None);
            }
            return;
        }
        let fg = platform::foreground(p.pid).filter(|f| f.pgrp != p.pid);
        let kind = fg.as_ref().and_then(|f| agent_kind(&f.names));
        match (kind, p.agent.clone()) {
            (None, Some(_)) => self.set_agent(p, None),
            (None, None) => {}
            (Some(kind), current) => {
                let busy = p.last_output.elapsed() < AGENT_ACTIVE;
                let mut a = current.filter(|a| a.kind == kind).unwrap_or(Agent {
                    kind: kind.into(),
                    state: "starting".into(),
                    source: "detected",
                    message: None,
                    since: unix_now(),
                    attention: false,
                    session: None,
                    pid: fg.as_ref().map(|f| f.pgrp),
                    guess: false,
                    muted: false,
                    quiet: false,
                    prompt: None,
                    tool: None,
                    tool_input: None,
                    turn_started: None,
                    requests: Vec::new(),
                    rewrite: None,
                    rewrite_pending: false,
                });
                // Another process of that kind (quit and started again): not the same agent.
                let pgrp = fg.as_ref().map(|f| f.pgrp);
                if a.pid != pgrp {
                    a.pid = pgrp;
                    a.session = None;
                    p.session_probe = None;
                }
                // No hook tells a detected Claude Code's session: its own record does.
                if kind == "claude" && p.session_probe.is_none_or(|t| t.elapsed() >= CLAUDE_SESSION_PROBE) {
                    p.session_probe = Some(Instant::now());
                    if let Some(s) = a.pid.and_then(crate::agents::claude_session_of) {
                        a.session = Some(s);
                    }
                }
                let fresh = a.state == "starting" && p.agent.is_none();
                if !fresh {
                    // Claude Code's title says it best: a spinner glyph while it works, ✳ when
                    // idle. Otherwise quiet after activity reads as waiting (a BEL also sets it).
                    let (state, guess) = match (kind, title_activity(p.title.as_deref())) {
                        ("claude", Some(working)) => (if working { "running" } else { "waiting" }, false),
                        _ => (if busy { "running" } else { "waiting" }, true),
                    };
                    if a.state != state {
                        a.state = state.into();
                        a.message = None;
                    }
                    a.guess = guess;
                }
                self.set_agent(p, Some(a));
            }
        }
    }

    fn agent_report(&self, p: &Value) -> RpcResult {
        self.agent_report_with(p, None)
    }

    /// `agent.permission`: the agent asks permission for a tool call. It waits like a report of
    /// `waiting` with that tool, and adds a request whose answer goes to `rx` (sent back to the
    /// waiting hook when a client decides, or `{"retired": true}`).
    fn agent_permission(&self, client: u64, p: &Value) -> std::result::Result<tokio::sync::oneshot::Receiver<Value>, RpcError> {
        let tool = p.get("tool").and_then(Value::as_str).map(|t| clotho_vt::printable(t, AGENT_TOOL_NAME_MAX)).filter(|t| !t.is_empty()).ok_or_else(|| err("bad_request", "missing tool"))?;
        let key = p.get("key").and_then(Value::as_str).map(|k| clotho_vt::printable(k, 64)).filter(|k| !k.is_empty()).ok_or_else(|| err("bad_request", "missing key"))?;
        let summary = p.get("tool_input").and_then(Value::as_str).map(|t| clotho_vt::printable(t, AGENT_TOOL_MAX)).filter(|t| !t.is_empty());
        let id = request_id();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let mut params = p.clone();
        params["state"] = json!("waiting");
        let r = self.agent_report_with(&params, Some((Request { id, tool, summary, key }, Pending { tx, client })))?;
        if r.get("ignored").is_some() {
            return Err(err("ignored", "nested agent"));
        }
        Ok(rx)
    }

    /// `agent.decide`: answer a pending request. Only the one the id names, only once.
    fn agent_decide(&self, p: &Value) -> RpcResult {
        let pane = param_u64(p, "pane")?;
        let id = p.get("request").and_then(Value::as_str).ok_or_else(|| err("bad_request", "missing request"))?;
        let decision = p.get("decision").and_then(Value::as_str).filter(|d| matches!(*d, "allow" | "deny")).ok_or_else(|| err("bad_request", "decision must be allow or deny"))?;
        let message = p.get("message").and_then(Value::as_str).map(|m| clotho_vt::printable(m, 300)).filter(|m| !m.is_empty());
        let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
        let mut pp = pp.lock().unwrap();
        let stale = || err("stale", "that request was already answered or is gone");
        let pend = pp.pending.remove(id).ok_or_else(stale)?;
        if let Some(mut a) = pp.agent.clone() {
            a.requests.retain(|r| r.id != id);
            self.set_agent(&mut pp, Some(a));
        }
        pend.tx.send(json!({"decision": decision, "message": message})).map_err(|_| stale())?;
        Ok(json!({}))
    }

    /// A client went away: requests whose hook waited on it can't be answered any more.
    fn retire_client_requests(&self, client: u64) {
        let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            let mut p = p.lock().unwrap();
            let gone: Vec<String> = p.pending.iter().filter(|(_, v)| v.client == client).map(|(k, _)| k.clone()).collect();
            if gone.is_empty() {
                continue;
            }
            for id in &gone {
                p.pending.remove(id);
            }
            if let Some(mut a) = p.agent.clone() {
                a.requests.retain(|r| !gone.contains(&r.id));
                self.set_agent(&mut p, Some(a));
            }
        }
    }

    fn agent_report_with(&self, p: &Value, request: Option<(Request, Pending)>) -> RpcResult {
        let pane = param_u64(p, "pane")?;
        let state = p.get("state").and_then(Value::as_str).ok_or_else(|| err("bad_request", "missing state"))?;
        let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
        let mut pp = pp.lock().unwrap();
        // A pane id can exist in several daemons; the reporter proves it runs in this one's pane.
        if let Some(pid) = p.get("pid").and_then(Value::as_u64) {
            if !platform::process_in_session(pid as u32, pp.pid) {
                return Err(err("wrong_pane", format!("process {pid} is not in pane {pane} of this daemon")));
            }
        }
        // An agent run by the pane's agent (`claude -p` from a tool, an SDK app it is testing,
        // `codex exec`) has hooks too, and they report into this pane: they are not the agent the
        // user talks to, so their turns and exits must not move its state or push.
        if let Some(pid) = p.get("pid").and_then(Value::as_u64) {
            if nested_agent(pid as u32, pp.pid) {
                return Ok(json!({"ignored": "nested"}));
            }
        }
        // The turn moved on: requests it settled (the user answered in the terminal: a
        // PostToolUse for that very call), or all of them (a new prompt, the turn's end).
        if let Some(r) = p.get("retire").and_then(Value::as_str) {
            pp.retire(|q| r == "all" || q.key == r);
        }
        if state == "clear" {
            self.set_agent(&mut pp, None);
            return Ok(json!({}));
        }
        if !AGENT_STATES.contains(&state) {
            return Err(err("bad_request", format!("unknown agent state `{state}`")));
        }
        // Bounded: these go into every agent event, the history and push records.
        let kind = p.get("kind").and_then(Value::as_str).map(|k| clotho_vt::printable(k, 64));
        let prev = pp.agent.clone().filter(|a| a.source == "hook");
        // The agent is whatever owns the terminal while it reports.
        let pid = platform::foreground(pp.pid).map(|f| f.pgrp).filter(|g| *g != pp.pid).or(prev.as_ref().and_then(|a| a.pid));
        // The turn: a prompt starts one (empty: one the user didn't type); so does work after the
        // agent stopped. A new session starts afresh. Bounded like every reported text.
        let text = |k: &str, max: usize| p.get(k).and_then(Value::as_str).map(|t| clotho_vt::printable(t, max));
        let asked = text("prompt", AGENT_PROMPT_MAX);
        let fresh = state == "starting";
        let resumed = state == "running" && prev.as_ref().is_none_or(|a| !matches!(a.state.as_str(), "running" | "waiting"));
        let new_turn = asked.is_some() || resumed || fresh;
        let prompt = match asked {
            Some(q) => Some(q).filter(|q| !q.is_empty()),
            None if new_turn => None,
            None => prev.as_ref().and_then(|a| a.prompt.clone()),
        };
        // A tool report brings both (the input may be absent); otherwise the turn's last stays.
        // An empty tool clears it (a wait that isn't about a tool).
        let (tool, tool_input) = match text("tool", AGENT_TOOL_NAME_MAX) {
            Some(t) if t.is_empty() => (None, None),
            Some(t) => (Some(t), text("tool_input", AGENT_TOOL_MAX).filter(|t| !t.is_empty())),
            None if new_turn => (None, None),
            None => (prev.as_ref().and_then(|a| a.tool.clone()), prev.as_ref().and_then(|a| a.tool_input.clone())),
        };
        let turn_started = if fresh { None } else if new_turn { Some(unix_now()) } else { prev.as_ref().and_then(|a| a.turn_started) };
        let a = Agent {
            kind: kind.or(prev.as_ref().map(|a| a.kind.clone())).unwrap_or_else(|| "other".into()),
            state: state.into(),
            source: "hook",
            message: p.get("message").and_then(Value::as_str).filter(|m| !m.is_empty()).map(|m| m.chars().take(500).collect()),
            since: 0.0,
            attention: prev.as_ref().map(|a| a.attention).unwrap_or(false),
            // Only ids that are safe to type back as a resume line (layout::safe_session) are
            // kept; anything else is as if none was sent.
            session: p.get("session").and_then(Value::as_str).filter(|s| crate::layout::safe_session(s)).map(String::from).or(prev.and_then(|a| a.session)),
            pid,
            guess: false,
            muted: false,
            quiet: false,
            prompt,
            tool,
            tool_input,
            turn_started,
            requests: match request {
                Some((r, pend)) => {
                    pp.pending.insert(r.id.clone(), pend);
                    pp.agent.as_ref().map(|a| a.requests.clone()).unwrap_or_default().into_iter().chain([r]).collect()
                }
                None => pp.agent.as_ref().map(|a| a.requests.clone()).unwrap_or_default(),
            },
            rewrite: None,
            rewrite_pending: false,
        };
        self.set_agent(&mut pp, Some(a));
        Ok(json!({}))
    }

    fn tick(self: &Arc<Self>, snapshot_check: bool) {
        let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            let mut p = p.lock().unwrap();
            let events = p.vt.flush_expired_sync();
            if !events.is_empty() {
                self.on_vt_events(&mut p, events);
            }
            if snapshot_check && self.live.load(Ordering::Relaxed) {
                self.detect_agent(&mut p);
                // Shells that don't report their directory (OSC 7; macOS zsh by default): a
                // `cd` changes nothing else the daemon sees, so look.
                if p.cwd.is_none() && p.exited.is_none() {
                    let now = platform::process_cwd(p.pid).map(|c| c.to_string_lossy().into_owned());
                    if now.is_some() && now != p.polled_cwd {
                        let first = p.polled_cwd.is_none();
                        p.polled_cwd = now;
                        if !first {
                            self.pane_event(&p);
                        }
                    }
                }
            }
            if snapshot_check {
                let behind = p.vt_seq - p.snap_seq;
                let quiet = p.last_output.elapsed() > Duration::from_millis(500);
                if behind > 0 && ((behind >= SNAPSHOT_SOFT && quiet) || p.snap_at.elapsed() >= SNAPSHOT_MAX_AGE) {
                    self.push_snapshot(&mut p);
                }
            }
        }
        if snapshot_check && self.live.load(Ordering::Relaxed) {
            self.refresh_git();
        }
        if snapshot_check && (self.dirty.load(Ordering::Relaxed) || self.layout.as_ref().is_some_and(|w| w.agent_gone_due())) {
            self.persist();
        }
        if let Some(w) = &self.layout {
            w.flush(false);
        }
    }

    /// Once a second: find each pane's work tree when its cwd changed, read every work tree in
    /// use once (HEAD, the branch's ref, origin), start PR lookups that are due, and send a
    /// `pane` event for every pane whose `git` changed.
    fn refresh_git(self: &Arc<Self>) {
        use crate::git;
        // Panes: (id, location, shown by a client).
        let mut panes: Vec<(u64, Option<git::Location>, bool)> = Vec::new();
        for p in self.panes.lock().unwrap().values().cloned().collect::<Vec<_>>() {
            let mut p = p.lock().unwrap();
            if p.exited.is_some() {
                continue;
            }
            let cwd = p.cwd.clone().or_else(|| p.polled_cwd.clone());
            if cwd != p.git_cwd {
                p.git_loc = cwd.as_deref().and_then(|c| git::locate(Path::new(c)));
                p.git_cwd = cwd;
            }
            panes.push((p.id, p.git_loc.clone(), !p.subs.is_empty()));
        }
        let mut views: HashMap<PathBuf, Value> = HashMap::new();
        {
            let mut cache = self.git.lock().unwrap();
            let mut seen = std::collections::HashSet::new();
            for (_, loc, _) in &panes {
                let Some(loc) = loc else { continue };
                if !seen.insert(loc.gitdir.clone()) {
                    continue;
                }
                let head = std::fs::read_to_string(loc.gitdir.join("HEAD")).unwrap_or_default();
                let info = git::info(loc, &head);
                cache.repos.insert(loc.gitdir.clone(), info.clone());
                let shown = panes.iter().any(|(_, l, shown)| *shown && l.as_ref().is_some_and(|l| l.gitdir == loc.gitdir));
                let (pr, reason) = match (&info.remote, &info.branch) {
                    (None, _) => (None, Some("no_remote")),
                    (_, None) => (None, Some("detached")),
                    _ if info.default_branch => (None, Some("default_branch")),
                    (Some(remote), Some(branch)) => {
                        let key = (remote.clone(), branch.clone());
                        let due = match cache.prs.get(&key) {
                            None => true,
                            Some(e) => !e.running && shown && e.at.elapsed() >= pr_refresh(),
                        };
                        if due {
                            let entry = cache.prs.entry(key.clone()).or_insert(PrEntry { result: None, at: Instant::now(), running: false });
                            entry.running = true;
                            let d = self.clone();
                            tokio::spawn(async move { d.lookup_pr(key).await });
                        }
                        match cache.prs.get(&(remote.clone(), branch.clone())).and_then(|e| e.result.clone()) {
                            None => (None, Some("pending")),
                            Some(Ok(Some(pr))) => (Some(pr.json()), None),
                            Some(Ok(None)) => (None, Some("none")),
                            Some(Err(r)) => (None, Some(r)),
                        }
                    }
                };
                views.insert(
                    loc.gitdir.clone(),
                    json!({
                        "repo": info.repo, "root": info.root, "remote": info.remote, "branch": info.branch, "head": info.head,
                        "worktree": info.worktree.as_ref().map(|(name, path)| json!({"name": name, "path": path})),
                        "pr": pr, "pr_reason": reason,
                    }),
                );
            }
            cache.repos.retain(|k, _| seen.contains(k));
            // Lookups nobody has needed for an hour go (results only: a running one stays).
            cache.prs.retain(|_, e| e.running || e.at.elapsed() < Duration::from_secs(3600));
        }
        for (id, loc, _) in panes {
            let view = loc.and_then(|l| views.get(&l.gitdir).cloned());
            let Some(p) = self.pane(id) else { continue };
            let mut p = p.lock().unwrap();
            if p.git != view {
                p.git = view;
                self.pane_event(&p);
            }
        }
    }

    /// One `gh` lookup (at most two at once); the next refresh_git shows its result.
    async fn lookup_pr(self: Arc<Self>, key: (String, String)) {
        let result = match self.gh_slots.clone().acquire_owned().await {
            Ok(_slot) => crate::git::lookup_pr(&key.0, &key.1, GH_TIMEOUT).await,
            Err(_) => Err("gh_error"),
        };
        // No gh at all is the normal case on many machines: not worth a line every refresh.
        match &result {
            Err(r) if *r != "no_gh" => log(format_args!("git: no PR for {} {}: {r}", key.0, clotho_vt::printable(&key.1, 80))),
            _ => {}
        }
        let mut cache = self.git.lock().unwrap();
        cache.prs.insert(key, PrEntry { result: Some(result), at: Instant::now(), running: false });
    }

    // ---- clients -----------------------------------------------------------------------

    async fn serve_client(self: Arc<Self>, stream: UnixStream) {
        let id = self.next_client.fetch_add(1, Ordering::Relaxed);
        let peer_pid = stream.peer_cred().ok().and_then(|c| c.pid()).and_then(|p| u32::try_from(p).ok());
        let (mut rd, mut wr) = stream.into_split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Msg>();
        let (file_tx, mut file_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let client = Arc::new(Client {
            id,
            tx,
            file_tx,
            queued: AtomicUsize::new(0),
            full: AtomicBool::new(false),
            control_queued: AtomicUsize::new(0),
            events: AtomicBool::new(false),
            real: AtomicBool::new(false),
            fs: Default::default(),
            dropped: AtomicBool::new(false),
            kill: tokio::sync::Notify::new(),
            control_max: control_max(),
            name: Mutex::new(String::new()),
            peer_pid,
            colors: Mutex::new(None),
        });
        self.clients.lock().unwrap().insert(id, client.clone());

        let writer = {
            let client = client.clone();
            tokio::spawn(async move {
                loop {
                    // Biased: replies, events and pane output always go before file data.
                    let (buf, out) = tokio::select! {
                        biased;
                        msg = rx.recv() => match msg {
                            Some(Msg::Control(b)) => (b, Some(&client.control_queued)),
                            Some(Msg::Output(b)) => (b, Some(&client.queued)),
                            None => break,
                        },
                        Some(b) = file_rx.recv() => (b, None),
                    };
                    if wr.write_all(&buf).await.is_err() {
                        break;
                    }
                    if let Some(counter) = out {
                        let left = counter.fetch_sub(buf.len(), Ordering::Relaxed) - buf.len();
                        if std::ptr::eq(counter, &client.queued) && left <= CLIENT_LOW {
                            client.full.store(false, Ordering::Relaxed);
                        }
                    }
                }
            })
        };

        let mut hello = false;
        loop {
            let read = tokio::select! {
                r = read_frame(&mut rd) => r,
                _ = client.kill.notified() => break,
            };
            let frame = match read {
                Ok(Some(f)) => f,
                Ok(None) => break,
                Err(e) => {
                    eprintln!("clothod: client {id}: {e}");
                    break;
                }
            };
            match frame {
                Frame::Json(v) => {
                    let req_id = v.get("id").cloned().unwrap_or(Value::Null);
                    let method = v.get("method").and_then(Value::as_str).unwrap_or("").to_string();
                    let params = v.get("params").cloned().unwrap_or(json!({}));
                    // Credit for a read stream; without an id it is fire and forget.
                    if method == "fs.ack" && req_id.is_null() && hello {
                        crate::fs::ack(&client, &params);
                        continue;
                    }
                    let result = if !hello && method != "hello" {
                        Err(err("handshake_required", "send hello first"))
                    } else if method == "agent.permission" {
                        // Answered when a client decides (or the request is retired): the read
                        // loop goes on meanwhile, so the hook going away is noticed.
                        match self.agent_permission(id, &params) {
                            Ok(rx) => {
                                let c = client.clone();
                                let req_id = req_id.clone();
                                tokio::spawn(async move {
                                    let v = rx.await.unwrap_or(json!({"retired": true}));
                                    c.json(json!({"id": req_id, "result": v}));
                                });
                                continue;
                            }
                            Err(e) => Err(e),
                        }
                    } else if method == "pane.subscribe" {
                        // Sends its own reply, ordered before the pane's frames.
                        match self.subscribe(&client, req_id.clone(), &params) {
                            Ok(()) => continue,
                            Err(e) => Err(e),
                        }
                    } else {
                        let r = self.request(&client, &method, &params).await;
                        if method == "hello" && r.is_ok() {
                            hello = true;
                            let name = params.get("client").and_then(Value::as_str).unwrap_or("");
                            *client.name.lock().unwrap() = clotho_vt::printable(name, 64);
                            if !name.starts_with("clothod-") {
                                client.real.store(true, Ordering::SeqCst);
                                self.had_real_client.store(true, Ordering::SeqCst);
                            }
                        }
                        r
                    };
                    let started = match (&result, method.as_str()) {
                        (Ok(v), "fs.read") => Some(v.clone()),
                        _ => None,
                    };
                    let reply = match result {
                        Ok(v) => json!({"id": req_id, "result": v}),
                        Err(e) => json!({"id": req_id, "error": {"code": e.code, "message": e.message}}),
                    };
                    client.json(reply);
                    // A read's data may only follow its reply.
                    if let Some(v) = started {
                        crate::fs::replied(&client, &v);
                    }
                    if method == "daemon.stop" || method == "daemon.shutdown" {
                        // Let the reply go out first.
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        self.stop.notify_one();
                    }
                }
                Frame::Input { pane, data } if hello => self.input(id, pane, data),
                Frame::FileData { stream, offset, flags, data } if hello => crate::fs::data(&client, stream, offset, flags, data),
                _ => {}
            }
        }

        // Transfers end with the connection (part files of resumable writes are kept).
        crate::fs::close_all(&client);
        let none_left = {
            let mut clients = self.clients.lock().unwrap();
            clients.remove(&id);
            !clients.values().any(|c| c.real.load(Ordering::SeqCst))
        };
        // Only real clients count: `start` probes readiness with a bare connect, and `upgrade`
        // talks to a fresh serve before the apps have reconnected to it.
        if none_left && self.had_real_client.load(Ordering::SeqCst) && platform::ephemeral() == Some(platform::Ephemeral::Exit) {
            eprintln!("clothod: last client of an ephemeral (exit) instance left; shutting down");
            self.shutdown_all.store(true, Ordering::SeqCst);
            self.stop.notify_one();
        }
        let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            let mut p = p.lock().unwrap();
            p.subs.remove(&id);
            // Its colors go with it: the pane falls back to another client's, or the defaults.
            if p.colors_client == Some(id) {
                p.colors_client = None;
            }
            self.refresh_palette(&mut p);
        }
        self.retire_client_requests(id);
        drop(client);
        writer.abort();
    }

    async fn request(&self, client: &Arc<Client>, method: &str, p: &Value) -> RpcResult {
        match method {
            "hello" => {
                let proto = p.get("protocol").and_then(Value::as_u64).unwrap_or(0) as u32;
                if !(PROTOCOL_MIN..=PROTOCOL).contains(&proto) {
                    return Err(err(
                        "protocol_mismatch",
                        format!("client protocol {proto}; this daemon supports {PROTOCOL_MIN}..={PROTOCOL}"),
                    ));
                }
                if let Some(c) = p.get("colors") {
                    self.set_client_colors(client, Some(c))?;
                }
                Ok(json!({
                    "protocol": proto,
                    "protocol_min": PROTOCOL_MIN,
                    "protocol_max": PROTOCOL,
                    // What this build supports, since builds share a version number. Clients
                    // check these instead of probing.
                    "features": ["pane.keys", "agents", "agent.report.pid", "ping", "split.set_ratio", "fs", "push", "pane.clipboard", "settings", "service", "agent.mute", "pane.search", "agent.history", "agent.decide", "push.activity", "client.colors", "restore", "move", "git", "pane.move", "pane.focus", "summary"],
                    "daemon": "clothod",
                    "version": env!("CARGO_PKG_VERSION"),
                    "instance": self.instance,
                    "pid": std::process::id(),
                    "machine": {"hostname": platform::hostname(), "os": platform::OS_NAME, "arch": std::env::consts::ARCH,
                        "home": std::env::var("HOME").unwrap_or_default()},
                    "exe": std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()),
                    "holder": self.holder_info,
                    "holder_outdated": self.holder_info["outdated"],
                    // macOS: serve's launchd namespace; `holder.namespace` is the shells'.
                    "namespace": platform::launchd_namespace(),
                    "build": self.build,
                }))
            }
            "ping" => Ok(json!({})),
            "client.colors" => {
                let colors = p.get("colors").ok_or_else(|| err("bad_request", "missing colors (null clears them)"))?;
                self.set_client_colors(client, Some(colors))?;
                Ok(json!({}))
            }
            "debug.stats" => {
                let mut v = self.stats();
                if p.get("maps").and_then(Value::as_bool).unwrap_or(false) {
                    v["maps"] = big_mappings();
                }
                Ok(v)
            }
            m if m.starts_with("fs.") => crate::fs::request(&self.fs_ctx(), client, m, p).await.map_err(|e| err(e.code, e.message)),
            m if m.starts_with("push.") => self.push.request(m, p).await.map_err(|e| err(e.code, e.message)),
            "agent.report" => self.agent_report(p),
            "agent.decide" => {
                let r = self.agent_decide(p);
                let what = format!("pane {} request {} {}", p["pane"], p["request"], p["decision"]);
                match &r {
                    Ok(_) => log(format_args!("{} answered {what}", client.label())),
                    Err(e) => log(format_args!("{} could not answer {what}: {}", client.label(), e.code)),
                }
                r
            }
            "agent.ack" => {
                let pane = param_u64(p, "pane")?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let mut pp = pp.lock().unwrap();
                if let Some(mut a) = pp.agent.clone() {
                    a.attention = false;
                    self.set_agent(&mut pp, Some(a));
                }
                Ok(json!({}))
            }
            "agent.mute" => {
                let pane = param_u64(p, "pane")?;
                let on = p.get("muted").and_then(Value::as_bool).ok_or_else(|| err("bad_request", "muted must be true or false"))?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let mut pp = pp.lock().unwrap();
                if pp.agent.is_none() {
                    return Err(err("not_found", format!("no agent in pane {pane}")));
                }
                self.mute(&mut pp, on);
                let agent = pp.agent.as_ref().map(Agent::json);
                drop(pp);
                // Stored with the pane at once (persist locks every pane, so not while holding
                // this one), so a restart, an upgrade or a crash keeps it.
                self.persist();
                Ok(json!({"agent": agent}))
            }
            "state.get" => Ok(self.state_json()),
            "events.subscribe" => {
                client.events.store(true, Ordering::SeqCst);
                // The reply goes out after this returns; queue the state event behind it.
                let state = self.state_json();
                let c = client.clone();
                tokio::spawn(async move { c.json(json!({"event": "state", "data": state})) });
                Ok(json!({}))
            }
            "events.unsubscribe" => {
                client.events.store(false, Ordering::SeqCst);
                Ok(json!({}))
            }
            "workspace.create" => {
                let opts = SpawnOpts::from_params(p)?;
                let pane = self.spawn_pane(opts).await?;
                let name = p.get("name").and_then(Value::as_str).map(String::from);
                let (ws, tab) = self.model.lock().unwrap().create_workspace(name, pane);
                self.model_changed();
                Ok(json!({"workspace": ws, "tab": tab, "pane": pane}))
            }
            "workspace.move" => {
                let ws = param_u64(p, "workspace")?;
                let index = param_index(p)?;
                let r = self.model.lock().unwrap().move_workspace(ws, index);
                let (index, changed) = r.ok_or_else(|| err("not_found", format!("no workspace {ws}")))?;
                if changed {
                    self.model_changed();
                }
                Ok(json!({"index": index}))
            }
            "tab.move" => {
                let tab = param_u64(p, "tab")?;
                let dest = match p.get("workspace") {
                    None | Some(Value::Null) => None,
                    Some(v) => Some(v.as_u64().ok_or_else(|| err("bad_request", "workspace must be an id"))?),
                };
                let index = param_index(p)?;
                let focus = match p.get("focus") {
                    None | Some(Value::Null) => false,
                    Some(v) => v.as_bool().ok_or_else(|| err("bad_request", "focus must be a boolean"))?,
                };
                let r = self.model.lock().unwrap().move_tab(tab, dest, index, focus);
                let (ws, index, changed) = r.ok_or_else(|| match dest {
                    Some(w) => err("not_found", format!("no tab {tab} or workspace {w}")),
                    None => err("not_found", format!("no tab {tab}")),
                })?;
                if changed {
                    self.model_changed();
                }
                Ok(json!({"workspace": ws, "index": index}))
            }
            "pane.move" | "tab.join" => {
                let to = param_u64(p, "to_pane")?;
                let dir = match p.get("direction") {
                    None | Some(Value::Null) => Direction::Right,
                    Some(v) => v
                        .as_str()
                        .and_then(Direction::parse)
                        .ok_or_else(|| err("bad_request", "direction must be right, down, left or up"))?,
                };
                let ratio = match p.get("ratio") {
                    None | Some(Value::Null) => 0.5,
                    Some(v) => v.as_f64().ok_or_else(|| err("bad_request", "ratio must be a number"))?,
                };
                let focus = match p.get("focus") {
                    None | Some(Value::Null) => true,
                    Some(v) => v.as_bool().ok_or_else(|| err("bad_request", "focus must be a boolean"))?,
                };
                let (what, id) = if method == "pane.move" { ("pane", param_u64(p, "pane")?) } else { ("tab", param_u64(p, "tab")?) };
                let r = {
                    let mut m = self.model.lock().unwrap();
                    if what == "pane" {
                        m.move_pane(id, to, dir, ratio, focus)
                    } else {
                        m.join_tab(id, to, dir, ratio, focus)
                    }
                };
                let (ws, tab, split) = r.map_err(|e| match e {
                    crate::model::MoveError::NotFound => err("not_found", format!("no {what} {id} or pane {to}")),
                    crate::model::MoveError::Same => err("bad_request", format!("pane {to} is in the {what} being moved")),
                })?;
                log(format_args!("{} moved {what} {id} beside pane {to}", client.label()));
                self.model_changed();
                Ok(json!({"workspace": ws, "tab": tab, "split": split}))
            }
            "workspace.rename" => {
                let ws = param_u64(p, "workspace")?;
                let name = p.get("name").and_then(Value::as_str).ok_or_else(|| err("bad_request", "missing name"))?;
                if !self.model.lock().unwrap().rename_workspace(ws, name.into()) {
                    return Err(err("not_found", format!("no workspace {ws}")));
                }
                self.model_changed();
                Ok(json!({}))
            }
            "workspace.close" => {
                let ws = param_u64(p, "workspace")?;
                let panes = self.model.lock().unwrap().close_workspace(ws).ok_or_else(|| err("not_found", format!("no workspace {ws}")))?;
                log(format_args!("{} closed workspace {ws} (panes {panes:?})", client.label()));
                self.hang_up(&panes);
                self.model_changed();
                Ok(json!({}))
            }
            "tab.create" => {
                let ws = param_u64(p, "workspace")?;
                if self.model.lock().unwrap().workspace(ws).is_none() {
                    return Err(err("not_found", format!("no workspace {ws}")));
                }
                let pane = self.spawn_pane(SpawnOpts::from_params(p)?).await?;
                let tab = self.model.lock().unwrap().create_tab(ws, pane);
                let Some(tab) = tab else {
                    self.hang_up(&[pane]);
                    return Err(err("not_found", format!("no workspace {ws}")));
                };
                self.model_changed();
                Ok(json!({"tab": tab, "pane": pane}))
            }
            "tab.rename" => {
                let tab = param_u64(p, "tab")?;
                let title = p.get("title").and_then(Value::as_str).map(String::from);
                if !self.model.lock().unwrap().rename_tab(tab, title) {
                    return Err(err("not_found", format!("no tab {tab}")));
                }
                self.model_changed();
                Ok(json!({}))
            }
            "tab.close" => {
                let tab = param_u64(p, "tab")?;
                let panes = self.model.lock().unwrap().close_tab(tab).ok_or_else(|| err("not_found", format!("no tab {tab}")))?;
                log(format_args!("{} closed tab {tab} (panes {panes:?})", client.label()));
                self.hang_up(&panes);
                self.model_changed();
                Ok(json!({}))
            }
            "pane.split" => {
                let pane = param_u64(p, "pane")?;
                let dir = p.get("direction").and_then(Value::as_str).and_then(Direction::parse).unwrap_or(Direction::Right);
                let ratio = p.get("ratio").and_then(Value::as_f64).unwrap_or(0.5);
                if !self.model.lock().unwrap().contains_pane(pane) {
                    return Err(err("not_found", format!("no pane {pane}")));
                }
                let mut opts = SpawnOpts::from_params(p)?;
                if let Some(src) = self.pane(pane) {
                    let src = src.lock().unwrap();
                    // New panes start at the source pane's size until a client sets a viewport.
                    if p.get("cols").is_none() {
                        opts.cols = src.cols;
                        opts.rows = src.rows;
                    }
                    if opts.cwd.is_none() {
                        opts.cwd = src.json()["cwd"].as_str().map(String::from);
                    }
                }
                let new = self.spawn_pane(opts).await?;
                let split = self.model.lock().unwrap().split(pane, new, dir, ratio);
                let Some(split) = split else {
                    self.hang_up(&[new]);
                    return Err(err("not_found", format!("no pane {pane}")));
                };
                self.model_changed();
                Ok(json!({"pane": new, "split": split}))
            }
            "pane.close" => {
                let pane = param_u64(p, "pane")?;
                if !self.model.lock().unwrap().remove_pane(pane) {
                    return Err(err("not_found", format!("no pane {pane}")));
                }
                log(format_args!("{} closed pane {pane}", client.label()));
                self.hang_up(&[pane]);
                self.model_changed();
                Ok(json!({}))
            }
            "split.set_ratio" => {
                let split = param_u64(p, "split")?;
                let ratio = p.get("ratio").and_then(Value::as_f64).ok_or_else(|| err("bad_request", "missing ratio"))?;
                if !self.model.lock().unwrap().set_ratio(split, ratio) {
                    return Err(err("not_found", format!("no split {split}")));
                }
                self.model_changed();
                Ok(json!({}))
            }
            "focus" => {
                let ok = {
                    let mut m = self.model.lock().unwrap();
                    if let Some(pane) = p.get("pane").and_then(Value::as_u64) {
                        m.focus_pane(pane)
                    } else if let Some(tab) = p.get("tab").and_then(Value::as_u64) {
                        m.focus_tab(tab)
                    } else if let Some(ws) = p.get("workspace").and_then(Value::as_u64) {
                        m.focus_workspace(ws)
                    } else {
                        return Err(err("bad_request", "focus needs pane, tab or workspace"));
                    }
                };
                if !ok {
                    return Err(err("not_found", "no such pane, tab or workspace"));
                }
                self.model_changed();
                Ok(json!({}))
            }
            "pane.unsubscribe" => {
                let pane = param_u64(p, "pane")?;
                if let Some(pp) = self.pane(pane) {
                    pp.lock().unwrap().subs.remove(&client.id);
                }
                Ok(json!({}))
            }
            "pane.viewport" => {
                let pane = param_u64(p, "pane")?;
                let size = param_size(p)?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let mut pp = pp.lock().unwrap();
                if let Some(s) = pp.subs.get_mut(&client.id) {
                    s.viewport = Some(size);
                }
                self.apply_viewport_policy(&mut pp, client.id);
                Ok(json!({}))
            }
            "pane.focus" => {
                let pane = param_u64(p, "pane")?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let mut pp = pp.lock().unwrap();
                if !pp.subs.contains_key(&client.id) {
                    return Err(err("bad_request", format!("not subscribed to pane {pane}")));
                }
                self.focus_size(&mut pp, client.id);
                self.use_colors_of(&mut pp, client.id);
                Ok(json!({"cols": pp.cols, "rows": pp.rows}))
            }
            "pane.resize" => {
                let pane = param_u64(p, "pane")?;
                let (cols, rows) = param_size(p)?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                self.resize(&mut pp.lock().unwrap(), cols, rows);
                Ok(json!({}))
            }
            "pane.dismiss_restored" => {
                let pane = param_u64(p, "pane")?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let mut pp = pp.lock().unwrap();
                if pp.restored.take().is_some() {
                    self.pane_event(&pp);
                    drop(pp);
                    self.persist();
                }
                Ok(json!({}))
            }
            "pane.input" => {
                let pane = param_u64(p, "pane")?;
                let data = p.get("data").and_then(Value::as_str).ok_or_else(|| err("bad_request", "missing data"))?;
                if self.pane(pane).is_none() {
                    return Err(err("not_found", format!("no pane {pane}")));
                }
                self.input(client.id, pane, data.as_bytes().to_vec());
                Ok(json!({}))
            }
            "pane.keys" => {
                // Named keys encoded for the pane's current modes; text pasted (bracketed when
                // the application asked for it). Counts as input, like typing.
                let pane = param_u64(p, "pane")?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let modes = pp.lock().unwrap().vt.input_modes();
                let mut bytes = Vec::new();
                if let Some(text) = p.get("text").and_then(Value::as_str) {
                    bytes.extend(clotho_vt::encode_text(modes, text, true));
                }
                for k in p.get("keys").and_then(Value::as_array).into_iter().flatten() {
                    let k = k.as_str().ok_or_else(|| err("bad_request", "keys must be strings"))?;
                    bytes.extend(clotho_vt::encode_key(modes, k).map_err(|e| err("bad_request", e))?);
                }
                if !bytes.is_empty() {
                    self.input(client.id, pane, bytes);
                }
                Ok(json!({}))
            }
            "agent.history" => {
                let pane = param_u64(p, "pane")?;
                let limit = p["limit"].as_u64().unwrap_or(HISTORY_MAX as u64).clamp(1, HISTORY_MAX as u64) as usize;
                let since = p["since"].as_f64();
                let session = p["session"].as_str();
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let pp = pp.lock().unwrap();
                let picked: Vec<&Value> = pp
                    .history
                    .iter()
                    .filter(|e| since.is_none_or(|t| e["at"].as_f64().is_some_and(|at| at > t)))
                    .filter(|e| session.is_none_or(|s| e["session"].as_str() == Some(s)))
                    .collect();
                let entries: Vec<&Value> = picked[picked.len().saturating_sub(limit)..].to_vec();
                Ok(json!({"pane": pane, "entries": entries, "max": HISTORY_MAX}))
            }
            "pane.search" => {
                let pane = param_u64(p, "pane")?;
                let query = p["query"].as_str().ok_or_else(|| err("bad_request", "missing query"))?;
                let limit = p["limit"].as_u64().unwrap_or(100).clamp(1, 1000) as usize;
                let before = match p.get("before") {
                    None | Some(Value::Null) => None,
                    Some(b) => match (b["line"].as_i64(), b["col"].as_u64()) {
                        (Some(line), Some(col)) => Some(clotho_vt::Pos { line: line as i32, col: col as usize }),
                        _ => return Err(err("bad_request", "before must be {line, col}")),
                    },
                };
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let pp = pp.lock().unwrap();
                // The pane's output waits while this runs: bounded, with `next` to go on.
                let r = pp
                    .vt
                    .search(query, p["regex"].as_bool().unwrap_or(false), p["case_sensitive"].as_bool().unwrap_or(false), before, limit, Duration::from_millis(200))
                    .map_err(|e| err("bad_request", e))?;
                let pos = |q: clotho_vt::Pos| json!({"line": q.line, "col": q.col});
                let matches: Vec<Value> =
                    r.matches.iter().map(|m| json!({"start": pos(m.start), "end": pos(m.end), "text": m.text, "line_text": m.line_text})).collect();
                Ok(json!({"seq": pp.vt_seq, "cols": pp.cols, "rows": pp.rows, "history": pp.vt.history_len(), "matches": matches, "next": r.next.map(pos)}))
            }
            "pane.text" => {
                let pane = param_u64(p, "pane")?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let pp = pp.lock().unwrap();
                let (col, row) = pp.vt.cursor();
                let m = pp.vt.input_modes();
                Ok(json!({"lines": pp.vt.screen_text(), "cursor": [col, row], "cols": pp.cols, "rows": pp.rows, "seq": pp.vt_seq,
                    "modes": {"kitty_flags": m.kitty, "bracketed_paste": m.bracketed_paste, "app_cursor": m.app_cursor, "app_keypad": m.app_keypad}}))
            }
            m if m.starts_with("service.") => {
                let (dir, op) = (self.dir.clone(), m["service.".len()..].to_string());
                // launchctl / systemctl can take a moment; keep them off the runtime threads.
                let r = tokio::task::spawn_blocking(move || crate::service::request(&dir, &op))
                    .await
                    .map_err(|e| err("internal", e.to_string()))?
                    .map_err(|e| err(e.code, e.message))?;
                if m != "service.status" {
                    self.broadcast("service", r.clone());
                }
                Ok(r)
            }
            "settings.get" => Ok(self.settings_json()),
            "settings.set" => self.set_settings(p),
            "daemon.stop" => Ok(json!({})),
            "daemon.shutdown" => {
                // `forget`: the saved layout goes too, so the next start is empty.
                if p.get("forget").and_then(Value::as_bool) == Some(true) {
                    if let Some(w) = &self.layout {
                        w.forget();
                    }
                }
                self.shutdown_all.store(true, Ordering::SeqCst);
                Ok(json!({}))
            }
            _ => Err(err("unknown_method", format!("unknown method `{method}`"))),
        }
    }

    fn settings_json(&self) -> Value {
        json!({
            "scrollback_lines": self.scrollback.load(Ordering::Relaxed),
            "notification_rewrite": self.summary.enabled(),
            "limits": {"scrollback_lines": {"min": 0, "max": crate::config::MAX_SCROLLBACK, "default": crate::config::DEFAULT_SCROLLBACK}},
            "config": crate::config::path().map(|p| p.to_string_lossy().into_owned()),
        })
    }

    /// `settings.set`: validate everything, store it in config.toml, then apply it. Panes that
    /// follow the setting change now (shrinking drops their oldest history), and so do panes
    /// created from here on; panes spawned with their own `scrollback_lines` keep it.
    fn set_settings(&self, p: &Value) -> RpcResult {
        let Some(obj) = p.as_object() else { return Err(err("bad_request", "params must be an object")) };
        if let Some(k) = obj.keys().find(|k| !["scrollback_lines", "notification_rewrite"].contains(&k.as_str())) {
            return Err(err("bad_request", format!("unknown setting `{k}`")));
        }
        let rewrite = match obj.get("notification_rewrite") {
            None => None,
            Some(v) => Some(v.as_bool().ok_or_else(|| err("bad_request", "notification_rewrite must be true or false"))?),
        };
        let max = crate::config::MAX_SCROLLBACK;
        let lines = match obj.get("scrollback_lines") {
            None => None,
            Some(v) => Some(
                v.as_u64().filter(|n| *n as usize <= max).ok_or_else(|| err("bad_request", format!("scrollback_lines must be an integer 0..={max}")))?
                    as usize,
            ),
        };
        if let Some(on) = rewrite {
            crate::config::set_notification_rewrite(on).map_err(|e| err("config_failed", e))?;
            self.summary.set_enabled(on);
        }
        let mut changed = Vec::new();
        if let Some(n) = lines {
            crate::config::set_scrollback_lines(n).map_err(|e| err("config_failed", e))?;
            let old = self.scrollback.swap(n, Ordering::Relaxed);
            if old != n {
                eprintln!("clothod: scrollback_lines {old} -> {n}");
            }
            let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
            for p in panes {
                let mut p = p.lock().unwrap();
                if !p.own_scrollback && p.vt.scrollback() != n {
                    p.vt.set_scrollback(n);
                    // set_options repeats the title; nothing else is pending here.
                    let events = p.vt.take_events();
                    self.on_vt_events(&mut p, events);
                    changed.push(p.id);
                    self.pane_event(&p);
                }
            }
        }
        if !changed.is_empty() {
            // Stored snapshots are cut to the new length at the next push; the scrollback
            // itself is part of the pane meta.
            self.persist();
        }
        let v = self.settings_json();
        self.broadcast("settings", v.clone());
        let mut r = v;
        r["applied_panes"] = json!(changed);
        Ok(r)
    }

    fn subscribe(&self, client: &Arc<Client>, req_id: Value, p: &Value) -> std::result::Result<(), RpcError> {
        let pane = param_u64(p, "pane")?;
        let have = p.get("have_seq").and_then(Value::as_u64);
        let scrollback = p.get("scrollback").and_then(Value::as_u64).map_or(DEFAULT_SCROLLBACK, |v| v as usize);
        let viewport = match p.get("viewport") {
            Some(v) if v.is_object() => Some(param_size(v)?),
            _ => None,
        };
        let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
        let mut pp = pp.lock().unwrap();
        let pp = &mut *pp;
        // A viewport may resize the pane. Do it before the subscriber is added and before the
        // reply: the reply carries the new size, so this client gets no `pane.resized` for it.
        // A subscribe with a viewport is a focus: this client now owns the size.
        if let Some((cols, rows)) = viewport {
            pp.size_client = Some(client.id);
            self.resize(pp, cols, rows);
        }
        // A connection that already has a full queue (a reconnect resubscribing many panes at
        // once) gets this pane's snapshot only once it has drained, like a lagging client: the
        // bytes queued per connection stay bounded instead of every pane's replay or snapshot
        // piling up at the same moment.
        let defer = client.queued.load(Ordering::Relaxed) > CLIENT_HIGH || client.full.load(Ordering::Relaxed);
        if defer {
            client.full.store(true, Ordering::Relaxed);
        }
        pp.subs.insert(client.id, Sub { client: client.clone(), lagging: defer, viewport });
        self.use_colors_of(pp, client.id);

        let end = pp.vt_seq;
        let mode = match have {
            _ if defer => "snapshot",
            Some(h) if h == end => "live",
            Some(h) if h >= pp.ring.start() && h < end && end - h <= REPLAY_LIMIT => "replay",
            _ => "snapshot",
        };
        let from = if mode == "replay" { have.unwrap() } else { end };
        client.json(json!({"id": req_id, "result": {"mode": mode, "seq": from, "cols": pp.cols, "rows": pp.rows}}));
        match mode {
            "replay" => {
                let data = pp.ring.since(from).unwrap_or_default();
                for (i, chunk) in data.chunks(CHUNK).enumerate() {
                    let seq = from + (i * CHUNK) as u64;
                    client.output(Frame::Output { pane, seq, data: chunk.to_vec() }.encode());
                }
            }
            "snapshot" if defer => self.watch_lagging(pane, client.id),
            "snapshot" => {
                let data = self.snapshot(pp, Some(scrollback));
                client.output(Frame::Snapshot { pane, seq: end, cols: pp.vt.cols(), rows: pp.vt.rows(), data }.encode());
            }
            _ => {}
        }
        Ok(())
    }

    async fn spawn_pane(&self, opts: SpawnOpts) -> std::result::Result<u64, RpcError> {
        let id = self.next_req.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.spawns.lock().unwrap().insert(id, (tx, opts.scrollback));
        self.to_holder(&ToHolder::Spawn {
            id,
            command: opts.command,
            cwd: opts.cwd,
            env: pane_env(opts.env),
            cols: opts.cols,
            rows: opts.rows,
        });
        match tokio::time::timeout(Duration::from_secs(10), rx).await {
            Ok(Ok(Ok(info))) => Ok(info.pane),
            Ok(Ok(Err(msg))) => Err(err("spawn_failed", msg)),
            _ => {
                self.spawns.lock().unwrap().remove(&id);
                Err(err("spawn_failed", "holder did not answer"))
            }
        }
    }

    /// SIGHUP the panes; SIGKILL whatever is still there 3 s later.
    fn hang_up(&self, panes: &[u64]) {
        for &pane in panes {
            self.to_holder(&ToHolder::Kill { pane, signal: "HUP".into() });
        }
        let panes = panes.to_vec();
        let holder = self.holder.clone();
        let live: Vec<_> = panes.iter().filter_map(|id| self.pane(*id).map(|p| (*id, p))).collect();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(3)).await;
            for (id, p) in live {
                if p.lock().unwrap().exited.is_none() && Arc::strong_count(&p) > 1 {
                    let msg = ToHolder::Kill { pane: id, signal: "KILL".into() };
                    let _ = holder.send(Frame::Json(serde_json::to_value(&msg).unwrap()).encode());
                }
            }
            let _ = panes;
        });
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Queue and buffer sizes, for finding where memory goes (the soak logs these).
    fn stats(&self) -> Value {
        let clients: Vec<Value> = self
            .clients
            .lock()
            .unwrap()
            .values()
            .map(|c| json!({"id": c.id, "queued": c.queued.load(Ordering::Relaxed), "control_queued": c.control_queued.load(Ordering::Relaxed)}))
            .collect();
        let panes: Vec<Value> = self
            .panes
            .lock()
            .unwrap()
            .values()
            .map(|p| {
                let p = p.lock().unwrap();
                json!({"id": p.id, "ring": p.ring.end() - p.ring.start(), "history": p.vt.history_len(), "subs": p.subs.len(),
                    "lagging": p.subs.values().filter(|s| s.lagging).count(), "replay_resizes": p.replay_resizes.len()})
            })
            .collect();
        let (heap, heap_peak) = crate::alloc::heap();
        // Linux: how the kernel counts this process's memory (LazyFree: freed by the allocator
        // with MADV_FREE, still in RSS until the kernel needs it). Not readable from outside
        // when the process isn't dumpable.
        let smaps: serde_json::Map<String, Value> = std::fs::read_to_string("/proc/self/smaps_rollup")
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let (k, v) = l.split_once(':')?;
                let kib: u64 = v.trim().strip_suffix(" kB")?.trim().parse().ok()?;
                Some((k.to_string(), json!(kib)))
            })
            .collect();
        json!({"heap": heap, "heap_peak": heap_peak, "smaps_kib": smaps, "holder_queued": self.holder.queued.load(Ordering::Relaxed), "clients": clients, "panes": panes})
    }

    fn fs_ctx(&self) -> crate::fs::Ctx {
        crate::fs::Ctx { state_dir: platform::log_dir(&self.dir) }
    }
}

/// Linux: this process's mappings with the most RSS (from /proc/self/smaps), and a count of
/// mappings by size, for finding memory outside the Rust heap.
fn big_mappings() -> Value {
    let text = std::fs::read_to_string("/proc/self/smaps").unwrap_or_default();
    let mut maps: Vec<(u64, u64, String)> = Vec::new(); // (rss KiB, size KiB, header)
    let mut cur: Option<(u64, u64, String)> = None;
    for line in text.lines() {
        let first = line.split_whitespace().next().unwrap_or("");
        if first.contains('-') && !first.ends_with(':') {
            if let Some(m) = cur.take() {
                maps.push(m);
            }
            cur = Some((0, 0, line.to_string()));
        } else if let Some(m) = cur.as_mut() {
            let kib = |l: &str| l.split_whitespace().nth(1).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
            if line.starts_with("Rss:") {
                m.0 = kib(line);
            } else if line.starts_with("Size:") {
                m.1 = kib(line);
            }
        }
    }
    maps.extend(cur);
    let count = maps.len();
    let mut by_size: std::collections::BTreeMap<u64, (u64, u64)> = Default::default();
    for m in &maps {
        let e = by_size.entry(m.1).or_default();
        e.0 += 1;
        e.1 += m.0;
    }
    let mut sizes: Vec<_> = by_size.into_iter().collect();
    sizes.sort_by_key(|(_, (_, rss))| std::cmp::Reverse(*rss));
    maps.sort_by_key(|m| std::cmp::Reverse(m.0));
    json!({
        "count": count,
        "top": maps.iter().take(8).map(|m| json!({"rss_kib": m.0, "size_kib": m.1, "map": m.2})).collect::<Vec<_>>(),
        "by_size": sizes.iter().take(8).map(|(size, (n, rss))| json!({"size_kib": size, "count": n, "rss_kib": rss})).collect::<Vec<_>>(),
    })
}

async fn ticker(d: Arc<Daemon>) {
    let mut n: u64 = 0;
    let mut interval = tokio::time::interval(Duration::from_millis(100));
    let mut idle_since: Option<Instant> = None;
    loop {
        interval.tick().await;
        n += 1;
        d.tick(n % 10 == 0);
        // Ephemeral (temporary) instances end themselves once unused.
        if n % 10 == 0 {
            if let Some(platform::Ephemeral::Idle(after)) = platform::ephemeral() {
                let unused = d.clients.lock().unwrap().is_empty() && d.panes.lock().unwrap().is_empty();
                match (unused, idle_since) {
                    (false, _) => idle_since = None,
                    (true, None) => idle_since = Some(Instant::now()),
                    (true, Some(t)) if t.elapsed() >= after => {
                        eprintln!("clothod: ephemeral instance unused for {after:?}; shutting down");
                        d.shutdown_all.store(true, Ordering::SeqCst);
                        d.stop.notify_one();
                    }
                    _ => {}
                }
            }
        }
    }
}
