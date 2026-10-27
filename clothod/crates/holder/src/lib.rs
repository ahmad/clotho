//! The PTY holder: a small process that owns the PTYs so the logic daemon can restart or upgrade
//! without killing shells.
//!
//! It forks and execs pane processes, holds the PTY master fds, handles resize, keeps a
//! seq-numbered output buffer per pane and stores the latest VT snapshot the logic daemon pushes.
//! It has no terminal emulator. See `clotho_proto::holder` for its protocol.
//!
//! Keep this crate small and its protocol backward compatible: a running holder outlives many
//! logic daemon versions.

use std::collections::{HashMap, VecDeque};
use std::fs::File;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use clotho_proto::holder::{ExitStatus, FromHolder, PaneInfo, ToHolder, HOLDER_PROTOCOL};
use clotho_proto::listen::HealingListener;
use clotho_proto::{platform, read_frame, Frame};
use tokio::io::unix::AsyncFd;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::sync::mpsc;

/// Output kept per pane. The logic daemon pushes a snapshot well before this fills (see
/// clothod's snapshot policy), so a restart always finds its snapshot's seq still buffered.
pub const RING_CAPACITY: usize = 4 << 20;

/// Live output frames queued for the logic connection before pane readers wait (backpressure).
const LOGIC_QUEUE: usize = 1024;

pub const SOCKET_NAME: &str = "holder.sock";

/// How long an ephemeral instance's holder waits without a logic process before ending itself.
const EPHEMERAL_ALONE: std::time::Duration = std::time::Duration::from_secs(60);

pub struct Ring {
    buf: VecDeque<u8>,
    /// seq of `buf[0]`.
    start: u64,
    cap: usize,
}

impl Ring {
    pub fn new(cap: usize) -> Self {
        Ring { buf: VecDeque::new(), start: 0, cap }
    }

    pub fn start(&self) -> u64 {
        self.start
    }

    pub fn end(&self) -> u64 {
        self.start + self.buf.len() as u64
    }

    pub fn push(&mut self, data: &[u8]) {
        self.buf.extend(data);
        if self.buf.len() > self.cap {
            let drop = self.buf.len() - self.cap;
            self.buf.drain(..drop);
            self.start += drop as u64;
        }
    }

    /// Bytes from `seq` to the end, or `None` if `seq` is no longer (or not yet) buffered.
    pub fn since(&self, seq: u64) -> Option<Vec<u8>> {
        if seq < self.start || seq > self.end() {
            return None;
        }
        let skip = (seq - self.start) as usize;
        Some(self.buf.iter().skip(skip).copied().collect())
    }

    /// Restart the ring at `seq` (empty). Used when the logic side recovers mid-stream.
    pub fn reset(&mut self, seq: u64) {
        self.buf.clear();
        self.start = seq;
    }
}

/// The logic connection's two queues. Control messages (welcome, recovery, replies) go first
/// and never block. Live output goes through a bounded queue whose sends wait: when the logic
/// process falls behind, pane readers stop reading their PTYs and the programs block on write,
/// like on any slow terminal, instead of the holder dropping output or the connection.
///
/// Fairness: each pane may have only a few frames in that queue at once (a permit travels with
/// each frame and is released once it is written), so one pane printing flat out can't keep the
/// queue full and delay every other pane's output behind it.
#[derive(Clone)]
struct Sink {
    live: mpsc::Sender<(Vec<u8>, Option<tokio::sync::OwnedSemaphorePermit>)>,
    ctrl: mpsc::UnboundedSender<Vec<u8>>,
}

/// Frames one pane may have queued for the logic process at a time.
const PANE_IN_FLIGHT: usize = 4;

struct Snapshot {
    seq: u64,
    cols: u16,
    rows: u16,
    data: Vec<u8>,
}

struct Pane {
    id: u64,
    pid: u32,
    command: Vec<String>,
    master: Arc<AsyncFd<OwnedFd>>,
    cols: u16,
    rows: u16,
    ring: Ring,
    resizes: Vec<(u64, u16, u16)>,
    snapshot: Option<Snapshot>,
    /// Reader hit EOF; together with `status` this means the pane is done.
    eof: bool,
    status: Option<ExitStatus>,
    exited_sent: bool,
    input: mpsc::UnboundedSender<Vec<u8>>,
    /// The logic connection this pane streams to.
    sink: Option<(u64, Sink)>,
}

impl Pane {
    fn info(&self) -> PaneInfo {
        PaneInfo {
            pane: self.id,
            pid: self.pid,
            command: self.command.clone(),
            cols: self.cols,
            rows: self.rows,
            seq_start: self.ring.start(),
            seq_end: self.ring.end(),
            resizes: self.resizes.clone(),
            exited: if self.exited_sent || (self.eof && self.status.is_some()) { self.status } else { None },
        }
    }

    /// Once the output is all read and the process reaped: tell the logic process, behind the
    /// pane's last output (same queue, queued after the reader's last send completed).
    fn maybe_finish(&mut self) {
        if self.eof && !self.exited_sent {
            if let Some(status) = self.status {
                self.exited_sent = true;
                if let Some((_, sink)) = self.sink.clone() {
                    let msg = json_frame(&FromHolder::Exited { pane: self.id, status });
                    tokio::spawn(async move {
                        let _ = sink.live.send((msg, None)).await;
                    });
                }
            }
        }
    }
}

pub struct Holder {
    dir: PathBuf,
    instance: String,
    /// Install id of this program image.
    build: String,
    /// In-place upgrade requests, handled by the accept loop (it owns the listener).
    upgrades: mpsc::UnboundedSender<(String, tokio::sync::oneshot::Sender<String>)>,
    panes: Mutex<HashMap<u64, Arc<Mutex<Pane>>>>,
    pids: Mutex<HashMap<u32, u64>>,
    next_pane: AtomicU64,
    state: Mutex<Option<serde_json::Value>>,
    /// Current logic connection: (id, task to abort when replaced).
    conn: Mutex<Option<(u64, tokio::task::AbortHandle)>>,
    next_conn: AtomicU64,
    shutdown: tokio::sync::Notify,
}

fn json_frame(msg: &FromHolder) -> Vec<u8> {
    Frame::Json(serde_json::to_value(msg).expect("holder messages serialize")).encode()
}

fn random_instance() -> String {
    let mut bytes = [0u8; 8];
    if File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes)).is_err() {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        bytes = ((t.as_nanos() as u64) ^ ((std::process::id() as u64) << 32)).to_be_bytes();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl Holder {

    fn pane(&self, id: u64) -> Option<Arc<Mutex<Pane>>> {
        self.panes.lock().unwrap().get(&id).cloned()
    }
}

/// Run the holder in `dir` until it is told to shut down. Returns an error if another holder
/// already runs there.
/// State format an in-place upgrade hands over (see [`exec_upgrade`]). A holder only execs a
/// program whose `holder-formats` lists it.
pub const STATE_FORMAT: u32 = 1;

/// Run the holder in `dir` until it is told to shut down. Returns an error if another holder
/// already runs there. With `resume_fd`, take over the state a previous program image of this
/// process handed over (in-place upgrade) instead of starting empty.
pub async fn run(dir: &Path, resume_fd: Option<RawFd>) -> Result<()> {
    platform::check_socket_path(&dir.join(SOCKET_NAME)).map_err(anyhow::Error::msg)?;
    let pid = format!("{}\n", std::process::id()).into_bytes();
    let sock = dir.join(SOCKET_NAME);
    let files = vec![(dir.join("holder.pid"), pid.clone()), (platform::log_dir(dir).join("holder.live"), pid)];

    // A hangup from the terminal that started us must not kill the panes.
    unsafe {
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    let (upgrades, mut upgrade_rx) = mpsc::unbounded_channel();
    let build = std::env::current_exe().ok().and_then(|e| platform::build_id(&e).ok()).unwrap_or_default();
    let (holder, mut listener) = match resume_fd {
        None => {
            let listener = HealingListener::bind(&sock, &dir.join("holder.lock"), files)
                .map_err(|e| anyhow::anyhow!("another holder is running in {} ({e})", dir.display()))?;
            let holder = Arc::new(Holder {
                dir: dir.to_path_buf(),
                instance: random_instance(),
                build,
                upgrades,
                panes: Mutex::new(HashMap::new()),
                pids: Mutex::new(HashMap::new()),
                next_pane: AtomicU64::new(1),
                state: Mutex::new(None),
                conn: Mutex::new(None),
                next_conn: AtomicU64::new(1),
                shutdown: tokio::sync::Notify::new(),
            });
            (holder, listener)
        }
        Some(fd) => resume(dir, fd, build, upgrades, files)?,
    };
    // The previous image blocked SIGUSR1 across execve; our handler exists now.
    unblock_usr1();
    eprintln!("clothod holder {} listening on {} (instance {})", std::process::id(), sock.display(), holder.instance);

    tokio::spawn(reap_children(holder.clone()));

    // An ephemeral instance's holder also ends itself if no logic process talks to it for a
    // while (a killed test, say), so temporary instances can't pile up.
    let ephemeral = platform::ephemeral().is_some();
    let mut alone_since = std::time::Instant::now();
    let mut check = tokio::time::interval(std::time::Duration::from_secs(5));
    let mut cleanup = false;
    loop {
        tokio::select! {
            _ = check.tick(), if ephemeral => {
                if holder.conn.lock().unwrap().is_some() {
                    alone_since = std::time::Instant::now();
                } else if alone_since.elapsed() >= EPHEMERAL_ALONE {
                    eprintln!("holder: ephemeral instance without a logic process for {:?}; shutting down", EPHEMERAL_ALONE);
                    cleanup = true;
                    break;
                }
            }
            accepted = listener.accept() => {
                let stream = accepted?;
                if platform::peer_uid(stream.as_raw_fd()) != Some(platform::current_uid()) {
                    continue;
                }
                start_conn(&holder, stream);
            }
            _ = holder.shutdown.notified() => break,
            Some((exe, reply)) = upgrade_rx.recv() => {
                // Only returns if the upgrade didn't happen.
                let why = exec_upgrade(&holder, &listener, &exe);
                eprintln!("holder: in-place upgrade to {exe} failed: {why}");
                let _ = reply.send(why);
            }
        }
    }

    // Stop being reachable first, so a new serve can't connect to a holder that is going away
    // (it would get no welcome).
    listener.close();

    // Hang up everything, give processes a moment to exit, then go.
    let panes: Vec<_> = holder.panes.lock().unwrap().values().cloned().collect();
    for p in &panes {
        let p = p.lock().unwrap();
        signal_pane(p.pid, libc::SIGHUP);
    }
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    for p in &panes {
        let p = p.lock().unwrap();
        if p.status.is_none() {
            signal_pane(p.pid, libc::SIGKILL);
        }
    }
    if cleanup {
        let _ = std::fs::remove_dir_all(dir);
    }
    Ok(())
}

fn start_conn(holder: &Arc<Holder>, stream: UnixStream) {
    let conn = holder.next_conn.fetch_add(1, Ordering::Relaxed);
    let h = holder.clone();
    let (handle_tx, handle_rx) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        let Ok(handle) = handle_rx.await else { return };
        if let Err(e) = serve_conn(&h, conn, handle, stream).await {
            eprintln!("holder: logic connection {conn} ended: {e:#}");
        }
        // Stop streaming to this connection.
        for p in h.panes.lock().unwrap().values() {
            let mut p = p.lock().unwrap();
            if p.sink.as_ref().is_some_and(|(c, _)| *c == conn) {
                p.sink = None;
            }
        }
    });
    let _ = handle_tx.send(task.abort_handle());
}

async fn serve_conn(holder: &Arc<Holder>, conn: u64, abort: tokio::task::AbortHandle, stream: UnixStream) -> Result<()> {
    let (mut rd, mut wr) = stream.into_split();
    let (live, mut live_rx) = mpsc::channel(LOGIC_QUEUE);
    let (ctrl, mut ctrl_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let tx = Sink { live, ctrl };
    let writer = tokio::spawn(async move {
        loop {
            // Control first: a pane's recovery frames are queued before its live output can be.
            let (buf, permit) = tokio::select! {
                biased;
                Some(b) = ctrl_rx.recv() => (b, None),
                Some((b, permit)) = live_rx.recv() => (b, permit),
                else => break,
            };
            if wr.write_all(&buf).await.is_err() {
                break;
            }
            drop(permit); // the pane may queue another frame
        }
    });
    struct AbortOnDrop(tokio::task::JoinHandle<()>);
    impl Drop for AbortOnDrop {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let _writer = AbortOnDrop(writer);

    // Handshake.
    // Any hello gets a welcome; the logic process decides if it can drive this holder.
    match read_frame(&mut rd).await? {
        Some(Frame::Json(v)) => match serde_json::from_value::<ToHolder>(v)? {
            ToHolder::Hello { protocol, version } => {
                eprintln!("holder: logic connection {conn}: protocol {protocol}, version {}", version.as_deref().unwrap_or("?"));
            }
            _ => anyhow::bail!("expected hello"),
        },
        _ => anyhow::bail!("expected hello"),
    }
    // Only a connection that completed the handshake replaces the current logic connection.
    let old = holder.conn.lock().unwrap().replace((conn, abort));
    if let Some((_, old)) = old {
        old.abort();
    }
    let welcome = FromHolder::Welcome {
        build: Some(holder.build.clone()),
        upgrade_formats: vec![STATE_FORMAT],
        protocol: test_override(&holder.dir, "CLOTHOD_TEST_HOLDER_PROTOCOL").and_then(|v| v.parse().ok()).unwrap_or(HOLDER_PROTOCOL),
        version: test_override(&holder.dir, "CLOTHOD_TEST_HOLDER_VERSION").unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string()),
        exe: std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()),
        instance: holder.instance.clone(),
        pid: std::process::id(),
        state: holder.state.lock().unwrap().clone(),
    };
    tx.ctrl.send(json_frame(&welcome))?;

    // Recovery: each pane's info, stored snapshot and buffer, then switch it to live streaming
    // to this connection, all under the pane's lock so no output slips in between.
    let mut ids: Vec<u64> = holder.panes.lock().unwrap().keys().copied().collect();
    ids.sort();
    for id in ids {
        let Some(pane) = holder.pane(id) else { continue };
        let mut p = pane.lock().unwrap();
        let mut frames = json_frame(&FromHolder::Pane(p.info()));
        if let Some(s) = &p.snapshot {
            frames.extend(
                Frame::Snapshot { pane: id, seq: s.seq, cols: s.cols, rows: s.rows, data: s.data.clone() }.encode(),
            );
        }
        let start = p.ring.start();
        let data = p.ring.since(start).unwrap_or_default();
        for (i, chunk) in data.chunks(1 << 20).enumerate() {
            let seq = start + (i << 20) as u64;
            frames.extend(Frame::Output { pane: id, seq, data: chunk.to_vec() }.encode());
        }
        // Queued (never blocking) under the pane's lock, before the pane streams live to us.
        tx.ctrl.send(frames)?;
        p.sink = Some((conn, tx.clone()));
    }
    tx.ctrl.send(json_frame(&FromHolder::Ready))?;

    while let Some(frame) = read_frame(&mut rd).await? {
        match frame {
            Frame::Input { pane, data } => {
                if let Some(p) = holder.pane(pane) {
                    let _ = p.lock().unwrap().input.send(data);
                }
            }
            Frame::Snapshot { pane, seq, cols, rows, data } => {
                if let Some(p) = holder.pane(pane) {
                    let mut p = p.lock().unwrap();
                    if seq <= p.ring.end() {
                        p.snapshot = Some(Snapshot { seq, cols, rows, data });
                    }
                }
            }
            Frame::Json(v) => {
                let msg: ToHolder = match serde_json::from_value(v) {
                    Ok(m) => m,
                    Err(e) => {
                        eprintln!("holder: bad request: {e}");
                        continue;
                    }
                };
                handle(holder, conn, &tx, msg).await;
            }
            _ => {}
        }
    }
    Ok(())
}

async fn handle(holder: &Arc<Holder>, conn: u64, tx: &Sink, msg: ToHolder) {
    match msg {
        ToHolder::Hello { .. } => {}
        ToHolder::Spawn { id, command, cwd, env, cols, rows } => {
            // On success `spawn` queues the reply itself, before any output can be.
            if let Err(e) = spawn(holder, conn, tx, id, command, cwd, env, cols, rows) {
                let _ = tx.ctrl.send(json_frame(&FromHolder::Error { id, message: format!("{e:#}") }));
            }
        }
        ToHolder::Resize { pane, cols, rows, seq } => {
            if let Some(p) = holder.pane(pane) {
                let mut p = p.lock().unwrap();
                if let Err(e) = set_winsize(p.master.get_ref().as_raw_fd(), cols, rows) {
                    eprintln!("holder: resize pane {pane}: {e}");
                }
                p.cols = cols;
                p.rows = rows;
                let seq = seq.min(p.ring.end());
                p.resizes.push((seq, cols, rows));
                let start = p.ring.start();
                // Keep the last resize before the buffer start: it gives the size of the
                // oldest buffered bytes.
                while p.resizes.len() > 1 && p.resizes[1].0 <= start {
                    p.resizes.remove(0);
                }
            }
        }
        ToHolder::Kill { pane, signal } => {
            if let Some(p) = holder.pane(pane) {
                let pid = p.lock().unwrap().pid;
                let sig = match signal.as_str() {
                    "KILL" => libc::SIGKILL,
                    "TERM" => libc::SIGTERM,
                    "INT" => libc::SIGINT,
                    _ => libc::SIGHUP,
                };
                signal_pane(pid, sig);
            }
        }
        ToHolder::Forget { pane } => {
            let removed = holder.panes.lock().unwrap().remove(&pane);
            if let Some(p) = removed {
                let pid = p.lock().unwrap().pid;
                holder.pids.lock().unwrap().remove(&pid);
            }
        }
        ToHolder::SetState { state } => {
            *holder.state.lock().unwrap() = Some(state);
        }
        ToHolder::Shutdown => holder.shutdown.notify_one(),
        ToHolder::Upgrade { id, exe } => {
            let (reply, answer) = tokio::sync::oneshot::channel();
            if holder.upgrades.send((exe, reply)).is_ok() {
                // On success this process image is gone and the answer never comes.
                let message = answer.await.unwrap_or_else(|_| "holder is shutting down".into());
                let _ = tx.ctrl.send(json_frame(&FromHolder::Error { id, message }));
            }
        }
    }
}

/// Test hooks for upgrade tests (pretend to be another holder version): the environment
/// variable, or a file of that name in the runtime dir (so a test can change it while the
/// holder runs).
fn test_override(dir: &Path, name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .or_else(|| std::fs::read_to_string(dir.join(name)).ok())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn signal_pane(pid: u32, sig: libc::c_int) {
    // Panes run in their own session, so the pid is also the process group id.
    unsafe {
        if libc::killpg(pid as libc::pid_t, sig) != 0 {
            libc::kill(pid as libc::pid_t, sig);
        }
    }
}

fn set_winsize(fd: RawFd, cols: u16, rows: u16) -> std::io::Result<()> {
    let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    let rc = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ as _, &ws) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

fn set_nonblocking_cloexec(fd: RawFd) -> std::io::Result<()> {
    unsafe {
        let fl = libc::fcntl(fd, libc::F_GETFL);
        if fl < 0 || libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK) < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let fd_fl = libc::fcntl(fd, libc::F_GETFD);
        if fd_fl < 0 || libc::fcntl(fd, libc::F_SETFD, fd_fl | libc::FD_CLOEXEC) < 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn spawn(
    holder: &Arc<Holder>,
    conn: u64,
    tx: &Sink,
    req: u64,
    command: Vec<String>,
    cwd: Option<String>,
    env: Vec<(String, String)>,
    cols: u16,
    rows: u16,
) -> Result<PaneInfo> {
    anyhow::ensure!(!command.is_empty(), "empty command");
    let (cols, rows) = (cols.max(2), rows.max(1));
    let ws = nix::pty::Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    let pty = nix::pty::openpty(&ws, None).context("openpty")?;
    set_nonblocking_cloexec(pty.master.as_raw_fd())?;

    let id = holder.next_pane.fetch_add(1, Ordering::Relaxed);
    let mut cmd = Command::new(&command[0]);
    cmd.args(&command[1..]);
    let dir = cwd.map(PathBuf::from).filter(|d| d.is_dir()).unwrap_or_else(|| {
        std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
    });
    cmd.current_dir(dir);
    // For `clothod report` (agent hooks): the daemon this pane belongs to. Before the caller's
    // env, which may override it.
    cmd.env("CLOTHOD_SOCKET", holder.dir.join("clothod.sock"));
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.env("CLOTHO_PANE", id.to_string());
    cmd.env_remove("CLOTHOD_EPHEMERAL");
    let slave = File::from(pty.slave);
    cmd.stdin(Stdio::from(slave.try_clone()?));
    cmd.stdout(Stdio::from(slave.try_clone()?));
    cmd.stderr(Stdio::from(slave));
    unsafe {
        cmd.pre_exec(|| {
            // Only async-signal-safe calls between fork and exec.
            for sig in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGPIPE, libc::SIGCHLD, libc::SIGTSTP, libc::SIGTTIN, libc::SIGTTOU] {
                libc::signal(sig, libc::SIG_DFL);
            }
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    // Hold the pids lock across spawn so the reaper cannot see the pid before we record it.
    let mut pids = holder.pids.lock().unwrap();
    let child = cmd.spawn().with_context(|| format!("spawning {:?}", command))?;
    let pid = child.id();
    // The reaper owns waiting; dropping Child does not wait or kill.
    drop(child);
    pids.insert(pid, id);
    drop(pids);
    drop(cmd); // closes our copies of the slave fd, so EOF arrives when the child side closes

    // SAFETY: the OwnedFd is owned by the AsyncFd and never closed or replaced while registered.
    let master = Arc::new(unsafe { AsyncFd::register(pty.master) }.map_err(|e| anyhow::anyhow!("registering pty: {e}"))?);
    let (input_tx, input_rx) = mpsc::unbounded_channel();
    let pane = Pane {
        id,
        pid,
        command,
        master: master.clone(),
        cols,
        rows,
        ring: Ring::new(RING_CAPACITY),
        resizes: vec![(0, cols, rows)],
        snapshot: None,
        eof: false,
        status: None,
        exited_sent: false,
        input: input_tx,
        sink: Some((conn, tx.clone())),
    };
    let info = pane.info();
    // The logic process must learn about the pane before its first output, so the reply goes
    // into the queue before the reader starts.
    tx.ctrl.send(json_frame(&FromHolder::Spawned { id: req, pane: info.clone() })).map_err(|_| anyhow::anyhow!("logic connection gone"))?;
    let pane = Arc::new(Mutex::new(pane));
    holder.panes.lock().unwrap().insert(id, pane.clone());
    tokio::spawn(read_pty(holder.clone(), pane.clone(), master.clone()));
    tokio::spawn(write_pty(master, input_rx));
    Ok(info)
}

async fn read_pty(holder: Arc<Holder>, pane: Arc<Mutex<Pane>>, master: Arc<AsyncFd<OwnedFd>>) {
    let mut buf = vec![0u8; 64 * 1024];
    let in_flight = Arc::new(tokio::sync::Semaphore::new(PANE_IN_FLIGHT));
    loop {
        let mut guard = match master.readable().await {
            Ok(g) => g,
            Err(_) => break,
        };
        let res = guard.try_io(|fd| {
            let n = unsafe { libc::read(fd.get_ref().as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if n < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(n as usize)
            }
        });
        match res {
            Err(_would_block) => continue,
            // EOF, or EIO once the last slave fd is closed (Linux and macOS).
            Ok(Ok(0)) | Ok(Err(_)) => break,
            Ok(Ok(n)) => {
                // Buffer and pick the destination under the lock (recovery switches it there),
                // then wait for room outside it: this is the backpressure.
                let (frame, sink) = {
                    let mut p = pane.lock().unwrap();
                    let seq = p.ring.end();
                    p.ring.push(&buf[..n]);
                    (Frame::Output { pane: p.id, seq, data: buf[..n].to_vec() }.encode(), p.sink.clone())
                };
                if let Some((_, sink)) = sink {
                    if let Ok(permit) = in_flight.clone().acquire_owned().await {
                        let _ = sink.live.send((frame, Some(permit))).await;
                    }
                }
            }
        }
    }
    let _ = &holder;
    let mut p = pane.lock().unwrap();
    p.eof = true;
    p.maybe_finish();
}

async fn write_pty(master: Arc<AsyncFd<OwnedFd>>, mut rx: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(data) = rx.recv().await {
        let mut off = 0;
        while off < data.len() {
            let mut guard = match master.writable().await {
                Ok(g) => g,
                Err(_) => return,
            };
            let res = guard.try_io(|fd| {
                let n = unsafe { libc::write(fd.get_ref().as_raw_fd(), data[off..].as_ptr().cast(), data.len() - off) };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            });
            match res {
                Err(_would_block) => continue,
                Ok(Ok(n)) => off += n,
                Ok(Err(_)) => return,
            }
        }
    }
}

async fn reap_children(holder: Arc<Holder>) {
    let mut sigchld = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("holder: cannot watch SIGCHLD: {e}");
            return;
        }
    };
    loop {
        // Reap first: a child may have exited before the handler was installed. Only pane
        // processes: waitpid(-1) would also reap children spawned elsewhere in the holder (the
        // `holder-formats` probe of an upgrade), whose own wait then fails with ECHILD.
        let known: Vec<(u32, u64)> = holder.pids.lock().unwrap().iter().map(|(p, id)| (*p, *id)).collect();
        for (pid, id) in known {
            let mut status = 0;
            let r = unsafe { libc::waitpid(pid as libc::pid_t, &mut status, libc::WNOHANG) };
            if r <= 0 {
                continue;
            }
            let exit = if libc::WIFEXITED(status) {
                ExitStatus::Code(libc::WEXITSTATUS(status))
            } else if libc::WIFSIGNALED(status) {
                ExitStatus::Signal(libc::WTERMSIG(status))
            } else {
                continue;
            };
            holder.pids.lock().unwrap().remove(&pid);
            if let Some(pane) = holder.pane(id) {
                let mut p = pane.lock().unwrap();
                p.status = Some(exit);
                p.maybe_finish();
            }
        }
        // Also every second: a pane whose child exited before its pid was recorded has had
        // its SIGCHLD already.
        tokio::select! {
            r = sigchld.recv() => if r.is_none() { return },
            _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => {}
        }
    }
}

/// Socket path of the holder in `dir`.
pub fn socket_path(dir: &Path) -> PathBuf {
    dir.join(SOCKET_NAME)
}

#[cfg(test)]
mod tests {
    use super::Ring;

    #[test]
    fn ring_drops_oldest() {
        let mut r = Ring::new(4);
        r.push(b"abc");
        r.push(b"def");
        assert_eq!((r.start(), r.end()), (2, 6));
        assert_eq!(r.since(3).unwrap(), b"def");
        assert_eq!(r.since(1), None);
        assert_eq!(r.since(6).unwrap(), b"");
        assert_eq!(r.since(7), None);
    }
}

// ---- in-place upgrade ------------------------------------------------------------------------

fn set_cloexec(fd: RawFd, on: bool) {
    unsafe {
        let fl = libc::fcntl(fd, libc::F_GETFD);
        if fl >= 0 {
            let fl = if on { fl | libc::FD_CLOEXEC } else { fl & !libc::FD_CLOEXEC };
            libc::fcntl(fd, libc::F_SETFD, fl);
        }
    }
}

fn usr1_mask(how: libc::c_int) {
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGUSR1);
        libc::pthread_sigmask(how, &set, std::ptr::null_mut());
    }
}

fn unblock_usr1() {
    usr1_mask(libc::SIG_UNBLOCK);
}

/// Replace this program image with `exe`, keeping the process (pid, children, PTY fds,
/// listening socket, lock) and handing the rest of the state over in an unlinked file whose fd
/// survives execve. Returns why it didn't happen; on success it doesn't return.
fn exec_upgrade(holder: &Holder, listener: &HealingListener, exe: &str) -> String {
    // The target must understand our state format.
    // ETXTBSY: on Linux a just-written binary can't be executed while any process (a child
    // forked elsewhere, between fork and exec) still holds it open for writing. That passes.
    let probe = || {
        let mut tries = 0;
        loop {
            match Command::new(exe).arg("holder-formats").arg("--runtime-dir").arg(&holder.dir).output() {
                Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) && tries < 20 => {
                    tries += 1;
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                r => return r,
            }
        }
    };
    match probe() {
        Ok(o) if o.status.success() && String::from_utf8_lossy(&o.stdout).split_whitespace().any(|f| f == STATE_FORMAT.to_string()) => {}
        Ok(o) => {
            return format!(
                "{exe} can't take over this holder (state format {STATE_FORMAT}; it supports: {})",
                String::from_utf8_lossy(&o.stdout).trim()
            )
        }
        Err(e) => return format!("{exe}: {e}"),
    }
    let exec_path = match std::fs::read_to_string(holder.dir.join("CLOTHOD_TEST_EXEC_FAIL")) {
        Ok(_) => "/nonexistent/clothod".to_string(), // test hook: make execve fail
        Err(_) => exe.to_string(),
    };

    // Freeze the panes: with every pane locked no reader can consume PTY output, so what the
    // state file holds is exactly what was read; the rest waits in the kernel for the new image.
    let mut panes: Vec<_> = holder.panes.lock().unwrap().values().cloned().collect();
    panes.sort_by_key(|p| p.lock().unwrap().id);
    let guards: Vec<_> = panes.iter().map(|p| p.lock().unwrap()).collect();

    let (listener_fd, lock_fd) = listener.fds();
    let mut header = serde_json::json!({
        "format": STATE_FORMAT,
        "instance": holder.instance,
        "next_pane": holder.next_pane.load(Ordering::SeqCst),
        "state": *holder.state.lock().unwrap(),
        "listener_fd": listener_fd,
        "lock_fd": lock_fd,
        "panes": [],
    });
    let mut body = Vec::new();
    for p in &guards {
        header["panes"].as_array_mut().unwrap().push(serde_json::json!({
            "pane": p.id, "pid": p.pid, "command": p.command, "cols": p.cols, "rows": p.rows,
            "master_fd": p.master.get_ref().as_raw_fd(), "seq_start": p.ring.start(), "resizes": p.resizes,
            "eof": p.eof, "status": p.status, "exited_sent": p.exited_sent, "has_snapshot": p.snapshot.is_some(),
        }));
        let start = p.ring.start();
        body.extend(Frame::Output { pane: p.id, seq: start, data: p.ring.since(start).unwrap_or_default() }.encode());
        if let Some(sn) = &p.snapshot {
            body.extend(Frame::Snapshot { pane: p.id, seq: sn.seq, cols: sn.cols, rows: sn.rows, data: sn.data.clone() }.encode());
        }
    }
    let state_path = holder.dir.join(format!(".holder-state.{}", std::process::id()));
    let mut file = match std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&state_path) {
        Ok(f) => f,
        Err(e) => return format!("state file: {e}"),
    };
    let _ = std::fs::remove_file(&state_path);
    let mut data = Frame::Json(header).encode();
    data.extend(body);
    use std::io::{Seek, Write};
    if let Err(e) = file.write_all(&data).and_then(|_| file.seek(std::io::SeekFrom::Start(0)).map(|_| ())) {
        return format!("writing state: {e}");
    }

    let state_fd = file.as_raw_fd();
    let mut inherited: Vec<RawFd> = vec![state_fd, listener_fd];
    inherited.extend(lock_fd);
    inherited.extend(guards.iter().map(|p| p.master.get_ref().as_raw_fd()));
    for &fd in &inherited {
        set_cloexec(fd, false);
    }
    // Our SIGUSR1 handler doesn't survive execve and the default action is to exit: hold the
    // signal blocked (the mask is inherited) until the new image has its handler.
    usr1_mask(libc::SIG_BLOCK);
    let mut cmd = Command::new(&exec_path);
    cmd.arg("holder").arg("--runtime-dir").arg(&holder.dir).arg("--resume-fd").arg(state_fd.to_string());
    let mut err = cmd.exec();
    for _ in 0..20 {
        if err.raw_os_error() != Some(libc::ETXTBSY) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
        err = cmd.exec();
    }

    // Still here: execve failed. Undo and carry on as before.
    for &fd in &inherited {
        if fd != state_fd {
            set_cloexec(fd, true);
        }
    }
    usr1_mask(libc::SIG_UNBLOCK);
    drop(guards);
    format!("exec {exec_path}: {err}")
}

/// Rebuild a holder from the state a previous image handed over in `fd`.
#[allow(clippy::type_complexity)]
fn resume(
    dir: &Path,
    fd: RawFd,
    build: String,
    upgrades: mpsc::UnboundedSender<(String, tokio::sync::oneshot::Sender<String>)>,
    files: Vec<(PathBuf, Vec<u8>)>,
) -> Result<(Arc<Holder>, HealingListener)> {
    use std::os::fd::FromRawFd;
    let mut file = unsafe { File::from_raw_fd(fd) };
    let header = match clotho_proto::frame::read_frame_sync(&mut file)? {
        Some(Frame::Json(v)) => v,
        _ => anyhow::bail!("resume: no state header"),
    };
    anyhow::ensure!(header["format"] == STATE_FORMAT, "resume: unknown state format {}", header["format"]);
    let listener_fd = header["listener_fd"].as_i64().context("listener_fd")? as RawFd;
    let lock_fd = header["lock_fd"].as_i64().map(|f| f as RawFd);
    for f in [Some(listener_fd), lock_fd].into_iter().flatten() {
        set_cloexec(f, true);
    }
    let sock = dir.join(SOCKET_NAME);
    let listener = unsafe { HealingListener::from_inherited(&sock, &dir.join("holder.lock"), listener_fd, lock_fd, files)? };
    let holder = Arc::new(Holder {
        dir: dir.to_path_buf(),
        instance: header["instance"].as_str().unwrap_or_default().to_string(),
        build,
        upgrades,
        panes: Mutex::new(HashMap::new()),
        pids: Mutex::new(HashMap::new()),
        next_pane: AtomicU64::new(header["next_pane"].as_u64().unwrap_or(1)),
        state: Mutex::new(Some(header["state"].clone()).filter(|v| !v.is_null())),
        conn: Mutex::new(None),
        next_conn: AtomicU64::new(1),
        shutdown: tokio::sync::Notify::new(),
    });

    // Frames in pane order: each pane's buffer, then its snapshot if it had one.
    let mut rings: HashMap<u64, (u64, Vec<u8>)> = HashMap::new();
    let mut snaps: HashMap<u64, Snapshot> = HashMap::new();
    while let Some(frame) = clotho_proto::frame::read_frame_sync(&mut file)? {
        match frame {
            Frame::Output { pane, seq, data } => {
                rings.insert(pane, (seq, data));
            }
            Frame::Snapshot { pane, seq, cols, rows, data } => {
                snaps.insert(pane, Snapshot { seq, cols, rows, data });
            }
            _ => {}
        }
    }
    drop(file);

    for ph in header["panes"].as_array().cloned().unwrap_or_default() {
        let id = ph["pane"].as_u64().context("pane id")?;
        let master_fd = ph["master_fd"].as_i64().context("master_fd")? as RawFd;
        set_nonblocking_cloexec(master_fd)?;
        let owned = unsafe { OwnedFd::from_raw_fd(master_fd) };
        // SAFETY: the fd came across execve for this pane only; the AsyncFd owns it from now on.
        let master = Arc::new(unsafe { AsyncFd::register(owned) }.map_err(|e| anyhow::anyhow!("registering pty: {e}"))?);
        let (seq_start, data) = rings.remove(&id).unwrap_or((0, Vec::new()));
        let mut ring = Ring::new(RING_CAPACITY);
        ring.reset(seq_start);
        ring.push(&data);
        let (input_tx, input_rx) = mpsc::unbounded_channel();
        let pid = ph["pid"].as_u64().unwrap_or(0) as u32;
        let eof = ph["eof"].as_bool().unwrap_or(false);
        let pane = Pane {
            id,
            pid,
            command: serde_json::from_value(ph["command"].clone()).unwrap_or_default(),
            master: master.clone(),
            cols: ph["cols"].as_u64().unwrap_or(80) as u16,
            rows: ph["rows"].as_u64().unwrap_or(24) as u16,
            ring,
            resizes: serde_json::from_value(ph["resizes"].clone()).unwrap_or_default(),
            snapshot: snaps.remove(&id),
            eof,
            status: serde_json::from_value(ph["status"].clone()).unwrap_or(None),
            exited_sent: ph["exited_sent"].as_bool().unwrap_or(false),
            input: input_tx,
            sink: None,
        };
        let pane = Arc::new(Mutex::new(pane));
        holder.panes.lock().unwrap().insert(id, pane.clone());
        holder.pids.lock().unwrap().insert(pid, id);
        if !eof {
            tokio::spawn(read_pty(holder.clone(), pane.clone(), master.clone()));
        }
        tokio::spawn(write_pty(master, input_rx));
    }
    eprintln!("holder {}: resumed {} panes after in-place upgrade (instance {})", std::process::id(), holder.panes.lock().unwrap().len(), holder.instance);
    Ok((holder, listener))
}
