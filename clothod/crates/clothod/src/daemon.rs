//! The logic process: model, one headless VT per pane, and the client protocol
//! (docs/protocol.md). PTYs live in the holder; this process can be killed and restarted at any
//! time and rebuilds itself from the holder's snapshots and buffers.
//!
//! Lock order: model -> panes map -> pane -> clients map. Nothing that holds a pane lock takes
//! the model lock.

use std::collections::HashMap;
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

/// Output kept for client replay. Matches the holder's buffer.
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

enum Msg {
    Control(Vec<u8>),
    Output(Vec<u8>),
}

struct Client {
    id: u64,
    tx: mpsc::UnboundedSender<Msg>,
    /// Bytes of pane output queued but not yet written to the socket.
    queued: AtomicUsize,
    events: AtomicBool,
}

impl Client {
    fn control(&self, frame: Vec<u8>) {
        let _ = self.tx.send(Msg::Control(frame));
    }

    fn json(&self, v: Value) {
        self.control(Frame::Json(v).encode());
    }

    fn output(&self, frame: Vec<u8>) {
        self.queued.fetch_add(frame.len(), Ordering::Relaxed);
        let _ = self.tx.send(Msg::Output(frame));
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
}

const AGENT_STATES: [&str; 5] = ["starting", "running", "waiting", "done", "error"];

/// Detected agents count as running while output arrived this recently.
const AGENT_ACTIVE: Duration = Duration::from_millis(1500);

fn unix_now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
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
    fn json(&self) -> Value {
        json!({
            "kind": self.kind,
            "state": self.state,
            "source": self.source,
            "message": self.message,
            "since": self.since,
            "attention": self.attention,
            "session": self.session,
        })
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
    snap_seq: u64,
    snap_at: Instant,
    last_output: Instant,
}

impl Pane {
    fn new(info: &PaneInfo) -> Pane {
        Pane {
            id: info.pane,
            agent: None,
            pid: info.pid,
            command: info.command.clone(),
            cols: info.cols,
            rows: info.rows,
            vt: Vt::new(info.cols, info.rows),
            vt_seq: info.seq_start,
            ring: {
                let mut r = Ring::new(RING_CAPACITY);
                r.reset(info.seq_start);
                r
            },
            replay_resizes: Vec::new(),
            title: None,
            cwd: None,
            exited: info.exited,
            subs: HashMap::new(),
            last_input_client: None,
            snap_seq: 0,
            snap_at: Instant::now(),
            last_output: Instant::now(),
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
            "agent": self.agent.as_ref().map(Agent::json),
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
    holder: mpsc::UnboundedSender<Vec<u8>>,
    model: Mutex<Model>,
    rev: AtomicU64,
    panes: Mutex<HashMap<u64, Arc<Mutex<Pane>>>>,
    spawns: Mutex<HashMap<u64, oneshot::Sender<Result<PaneInfo, String>>>>,
    next_req: AtomicU64,
    clients: Mutex<HashMap<u64, Arc<Client>>>,
    next_client: AtomicU64,
    /// Replies from the VTs go to the PTYs only once recovery is done.
    live: AtomicBool,
    dirty: AtomicBool,
    stop: Notify,
    shutdown_all: AtomicBool,
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
        let mut env = vec![
            ("TERM".to_string(), "xterm-256color".to_string()),
            ("COLORTERM".into(), "truecolor".into()),
            ("TERM_PROGRAM".into(), "clotho".into()),
        ];
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
        })
    }
}

fn param_u64(p: &Value, key: &str) -> std::result::Result<u64, RpcError> {
    p.get(key).and_then(Value::as_u64).ok_or_else(|| err("bad_request", format!("missing integer param `{key}`")))
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
    let holder_writer = tokio::spawn(async move {
        while let Some(buf) = hrx.recv().await {
            // An empty buffer is the "flush and close" marker sent on exit.
            if buf.is_empty() || hwr.write_all(&buf).await.is_err() {
                break;
            }
        }
        let _ = hwr.shutdown().await;
    });

    let (instance, state, holder_info) = match Some(first) {
        Some(Frame::Json(v)) => match serde_json::from_value::<FromHolder>(v)? {
            FromHolder::Welcome { instance, state, pid, protocol, version, exe, build, upgrade_formats } => {
                // Outdated: not this build. Legacy holders (no in-place upgrade) stay so until
                // a full restart; the apps ask the user for it.
                let outdated = build.as_deref() != Some(own_build.as_str());
                let info = json!({"pid": pid, "version": version, "protocol": protocol, "exe": exe, "build": build,
                    "can_upgrade": !upgrade_formats.is_empty(), "outdated": outdated});
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
                (instance, state, info)
            }
            other => bail!("expected welcome from holder, got {other:?}"),
        },
        other => bail!("expected welcome from holder, got {other:?}"),
    };

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
        next_req: AtomicU64::new(1),
        clients: Mutex::new(HashMap::new()),
        next_client: AtomicU64::new(1),
        live: AtomicBool::new(false),
        dirty: AtomicBool::new(false),
        stop: Notify::new(),
        shutdown_all: AtomicBool::new(false),
    });

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
        let meta: HashMap<String, Value> = self
            .panes
            .lock()
            .unwrap()
            .iter()
            .map(|(id, p)| {
                let p = p.lock().unwrap();
                (id.to_string(), json!({"title": p.title, "cwd": p.cwd}))
            })
            .collect();
        let state = json!({"model": model, "meta": meta});
        self.to_holder(&ToHolder::SetState { state });
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
                        let mut vt = Vt::new(cols, rows);
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
                let mut p = Pane::new(&info);
                let start = info.seq_start;
                let initial = info.resizes.iter().filter(|r| r.0 <= start).last().copied();
                if let Some((_, c, r)) = initial {
                    p.vt = Vt::new(c, r);
                }
                p.replay_resizes = info.resizes.iter().filter(|r| r.0 > start).copied().collect();
                p.snap_seq = start;
                self.panes.lock().unwrap().insert(info.pane, Arc::new(Mutex::new(p)));
            }
            FromHolder::Spawned { id, pane } => {
                let p = Pane::new(&pane);
                self.panes.lock().unwrap().insert(pane.pane, Arc::new(Mutex::new(p)));
                if let Some(tx) = self.spawns.lock().unwrap().remove(&id) {
                    let _ = tx.send(Ok(pane));
                }
            }
            FromHolder::Error { id, message } => {
                if let Some(tx) = self.spawns.lock().unwrap().remove(&id) {
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
        {
            let mut p = p.lock().unwrap();
            p.exited = Some(status);
            self.pane_event(&p);
        }
        self.panes.lock().unwrap().remove(&pane);
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
            if let Some(s) = p.subs.get_mut(&client) {
                if s.lagging {
                    s.lagging = false;
                    s.client.json(json!({"event": "pane.resync", "data": {"pane": p.id}}));
                    let data = p.vt.snapshot(Some(DEFAULT_SCROLLBACK));
                    for ev in p.vt.take_events() {
                        if let VtEvent::Reply(bytes) = ev {
                            let _ = holder.send(Frame::Input { pane: p.id, data: bytes }.encode());
                        }
                    }
                    let frame = Frame::Snapshot { pane: p.id, seq: p.vt_seq, cols: p.vt.cols(), rows: p.vt.rows(), data };
                    s.client.output(frame.encode());
                }
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

    /// Apply the "last typer's viewport wins" rule after something changed for `client`.
    fn apply_viewport_policy(&self, p: &mut Pane, client: u64) {
        let owner = p.last_input_client.filter(|c| p.subs.contains_key(c));
        if owner.is_some() && owner != Some(client) {
            return;
        }
        if let Some((cols, rows)) = p.subs.get(&client).and_then(|s| s.viewport) {
            self.resize(p, cols, rows);
        }
    }

    fn input(&self, client: u64, pane: u64, data: Vec<u8>) {
        let Some(p) = self.pane(pane) else { return };
        let mut p = p.lock().unwrap();
        if p.agent.as_ref().is_some_and(|a| a.attention) {
            let mut a = p.agent.clone().unwrap();
            a.attention = false;
            self.set_agent(&mut p, Some(a));
        }
        if p.last_input_client != Some(client) {
            p.last_input_client = Some(client);
            self.apply_viewport_policy(&mut p, client);
        }
        let _ = self.holder.send(Frame::Input { pane, data }.encode());
    }

    // ---- periodic work -----------------------------------------------------------------

    /// Replace a pane's agent. A new state gets a fresh `since` and, for waiting/done/error,
    /// `attention`. Sends `pane` (any change) and `agent` (appeared, gone, or new state).
    fn set_agent(&self, p: &mut Pane, mut new: Option<Agent>) {
        let old = p.agent.clone();
        let from = old.as_ref().map(|a| a.state.clone());
        if let Some(a) = new.as_mut() {
            if old.as_ref().map(|o| &o.state) != Some(&a.state) {
                a.since = unix_now();
                // Only exact signals ask for the user: a hook's report, or a BEL (handled by the
                // caller). Detection's "quiet, so waiting" is a guess; it must not notify.
                a.attention = a.source == "hook" && matches!(a.state.as_str(), "waiting" | "done" | "error");
            } else if let Some(o) = &old {
                a.since = o.since;
            }
        }
        if new == old {
            return;
        }
        p.agent = new;
        let transition = from.as_deref() != p.agent.as_ref().map(|a| a.state.as_str());
        self.pane_event(p);
        if transition {
            self.broadcast("agent", json!({"pane": p.id, "agent": p.agent.as_ref().map(Agent::json), "from": from}));
        }
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
                });
                let fresh = a.state == "starting" && p.agent.is_none();
                if !fresh {
                    // Quiet after activity reads as waiting for the user; a BEL also sets it.
                    let state = if busy { "running" } else { "waiting" };
                    if a.state != state {
                        a.state = state.into();
                        a.message = None;
                    }
                }
                self.set_agent(p, Some(a));
            }
        }
    }

    fn agent_report(&self, p: &Value) -> RpcResult {
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
        if state == "clear" {
            self.set_agent(&mut pp, None);
            return Ok(json!({}));
        }
        if !AGENT_STATES.contains(&state) {
            return Err(err("bad_request", format!("unknown agent state `{state}`")));
        }
        let kind = p.get("kind").and_then(Value::as_str).map(String::from);
        let prev = pp.agent.clone().filter(|a| a.source == "hook");
        // The agent is whatever owns the terminal while it reports.
        let pid = platform::foreground(pp.pid).map(|f| f.pgrp).filter(|g| *g != pp.pid).or(prev.as_ref().and_then(|a| a.pid));
        let a = Agent {
            kind: kind.or(prev.as_ref().map(|a| a.kind.clone())).unwrap_or_else(|| "other".into()),
            state: state.into(),
            source: "hook",
            message: p.get("message").and_then(Value::as_str).filter(|m| !m.is_empty()).map(|m| m.chars().take(500).collect()),
            since: 0.0,
            attention: prev.as_ref().map(|a| a.attention).unwrap_or(false),
            session: p.get("session").and_then(Value::as_str).map(String::from).or(prev.and_then(|a| a.session)),
            pid,
        };
        self.set_agent(&mut pp, Some(a));
        Ok(json!({}))
    }

    fn tick(&self, snapshot_check: bool) {
        let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            let mut p = p.lock().unwrap();
            let events = p.vt.flush_expired_sync();
            if !events.is_empty() {
                self.on_vt_events(&mut p, events);
            }
            if snapshot_check && self.live.load(Ordering::Relaxed) {
                self.detect_agent(&mut p);
            }
            if snapshot_check {
                let behind = p.vt_seq - p.snap_seq;
                let quiet = p.last_output.elapsed() > Duration::from_millis(500);
                if behind > 0 && ((behind >= SNAPSHOT_SOFT && quiet) || p.snap_at.elapsed() >= SNAPSHOT_MAX_AGE) {
                    self.push_snapshot(&mut p);
                }
            }
        }
        if snapshot_check && self.dirty.load(Ordering::Relaxed) {
            self.persist();
        }
    }

    // ---- clients -----------------------------------------------------------------------

    async fn serve_client(self: Arc<Self>, stream: UnixStream) {
        let id = self.next_client.fetch_add(1, Ordering::Relaxed);
        let (mut rd, mut wr) = stream.into_split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Msg>();
        let client = Arc::new(Client { id, tx, queued: AtomicUsize::new(0), events: AtomicBool::new(false) });
        self.clients.lock().unwrap().insert(id, client.clone());

        let writer = {
            let client = client.clone();
            tokio::spawn(async move {
                while let Some(msg) = rx.recv().await {
                    let (buf, out) = match msg {
                        Msg::Control(b) => (b, false),
                        Msg::Output(b) => (b, true),
                    };
                    if wr.write_all(&buf).await.is_err() {
                        break;
                    }
                    if out {
                        client.queued.fetch_sub(buf.len(), Ordering::Relaxed);
                    }
                }
            })
        };

        let mut hello = false;
        loop {
            let frame = match read_frame(&mut rd).await {
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
                    let result = if !hello && method != "hello" {
                        Err(err("handshake_required", "send hello first"))
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
                        }
                        r
                    };
                    let reply = match result {
                        Ok(v) => json!({"id": req_id, "result": v}),
                        Err(e) => json!({"id": req_id, "error": {"code": e.code, "message": e.message}}),
                    };
                    client.json(reply);
                    if method == "daemon.stop" || method == "daemon.shutdown" {
                        // Let the reply go out first.
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        self.stop.notify_one();
                    }
                }
                Frame::Input { pane, data } if hello => self.input(id, pane, data),
                _ => {}
            }
        }

        let none_left = {
            let mut clients = self.clients.lock().unwrap();
            clients.remove(&id);
            clients.is_empty()
        };
        // Only real clients count: `start` probes readiness with a bare connect.
        if none_left && hello && platform::ephemeral() == Some(platform::Ephemeral::Exit) {
            eprintln!("clothod: last client of an ephemeral (exit) instance left; shutting down");
            self.shutdown_all.store(true, Ordering::SeqCst);
            self.stop.notify_one();
        }
        let panes: Vec<_> = self.panes.lock().unwrap().values().cloned().collect();
        for p in panes {
            p.lock().unwrap().subs.remove(&id);
        }
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
                Ok(json!({
                    "protocol": proto,
                    "protocol_min": PROTOCOL_MIN,
                    "protocol_max": PROTOCOL,
                    // What this build supports, since builds share a version number. Clients
                    // check these instead of probing.
                    "features": ["pane.keys", "agents", "agent.report.pid", "ping", "split.set_ratio"],
                    "daemon": "clothod",
                    "version": env!("CARGO_PKG_VERSION"),
                    "instance": self.instance,
                    "pid": std::process::id(),
                    "machine": {"hostname": platform::hostname(), "os": platform::OS_NAME, "arch": std::env::consts::ARCH},
                    "exe": std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()),
                    "holder": self.holder_info,
                    "holder_outdated": self.holder_info["outdated"],
                    "build": self.build,
                }))
            }
            "ping" => Ok(json!({})),
            "agent.report" => self.agent_report(p),
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
            "pane.resize" => {
                let pane = param_u64(p, "pane")?;
                let (cols, rows) = param_size(p)?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                self.resize(&mut pp.lock().unwrap(), cols, rows);
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
            "pane.text" => {
                let pane = param_u64(p, "pane")?;
                let pp = self.pane(pane).ok_or_else(|| err("not_found", format!("no pane {pane}")))?;
                let pp = pp.lock().unwrap();
                let (col, row) = pp.vt.cursor();
                let m = pp.vt.input_modes();
                Ok(json!({"lines": pp.vt.screen_text(), "cursor": [col, row], "cols": pp.cols, "rows": pp.rows, "seq": pp.vt_seq,
                    "modes": {"kitty_flags": m.kitty, "bracketed_paste": m.bracketed_paste, "app_cursor": m.app_cursor, "app_keypad": m.app_keypad}}))
            }
            "daemon.stop" => Ok(json!({})),
            "daemon.shutdown" => {
                self.shutdown_all.store(true, Ordering::SeqCst);
                Ok(json!({}))
            }
            _ => Err(err("unknown_method", format!("unknown method `{method}`"))),
        }
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
        let owner = pp.last_input_client.filter(|c| pp.subs.contains_key(c) && *c != client.id);
        if let (None, Some((cols, rows))) = (owner, viewport) {
            self.resize(pp, cols, rows);
        }
        pp.subs.insert(client.id, Sub { client: client.clone(), lagging: false, viewport });

        let end = pp.vt_seq;
        let mode = match have {
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
        self.spawns.lock().unwrap().insert(id, tx);
        self.to_holder(&ToHolder::Spawn {
            id,
            command: opts.command,
            cwd: opts.cwd,
            env: opts.env,
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
