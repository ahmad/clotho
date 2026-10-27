//! Minimal async client for clothod (docs/protocol.md), used by the `clotho` test CLI and the
//! end-to-end tests.

pub mod remote;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use clotho_proto::{platform, read_frame, Frame};
use clotho_vt::Vt;
use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

pub struct Client {
    out: mpsc::UnboundedSender<Vec<u8>>,
    pending: Pending,
    /// Set by the reader when the stream ended; requests after that fail instead of waiting.
    closed: Arc<std::sync::atomic::AtomicBool>,
    /// The reader and writer tasks: aborted on drop so dropping the client closes the stream.
    tasks: Vec<tokio::task::AbortHandle>,
    next_id: AtomicU64,
    incoming: mpsc::UnboundedReceiver<Frame>,
    /// The daemon's `hello` reply.
    pub hello: Value,
}

pub fn socket_path(dir: &Path) -> PathBuf {
    dir.join("clothod.sock")
}

impl Client {
    pub async fn connect(dir: &Path) -> Result<Client> {
        platform::check_socket_path(&socket_path(dir)).map_err(anyhow::Error::msg)?;
        let stream = UnixStream::connect(socket_path(dir)).await.with_context(|| format!("connecting to clothod in {}", dir.display()))?;
        let (rd, wr) = stream.into_split();
        Client::over(rd, wr).await
    }

    /// Speak the protocol over any byte stream (a Unix socket, or an SSH bridge's stdio).
    pub async fn over<R, W>(mut rd: R, mut wr: W) -> Result<Client>
    where
        R: tokio::io::AsyncRead + Unpin + Send + 'static,
        W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let (out, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let writer = tokio::spawn(async move {
            while let Some(buf) = out_rx.recv().await {
                if wr.write_all(&buf).await.is_err() || wr.flush().await.is_err() {
                    break;
                }
            }
        });
        let pending: Pending = Arc::default();
        let (in_tx, incoming) = mpsc::unbounded_channel();
        let p = pending.clone();
        let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let cl = closed.clone();
        let reader = tokio::spawn(async move {
            while let Ok(Some(frame)) = read_frame(&mut rd).await {
                if let Frame::Json(v) = &frame {
                    if let Some(id) = v.get("id").and_then(Value::as_u64) {
                        if let Some(tx) = p.lock().unwrap().remove(&id) {
                            let _ = tx.send(v.clone());
                            continue;
                        }
                    }
                }
                if in_tx.send(frame).is_err() {
                    break;
                }
            }
            // Dropping the pending senders fails outstanding requests.
            let mut pending = p.lock().unwrap();
            cl.store(true, Ordering::SeqCst);
            pending.clear();
        });
        let tasks = vec![reader.abort_handle(), writer.abort_handle()];
        let mut c = Client { out, pending, closed, tasks, next_id: AtomicU64::new(1), incoming, hello: Value::Null };
        c.hello = c
            .request("hello", json!({"protocol": clotho_proto::PROTOCOL, "client": concat!("clotho-cli/", env!("CARGO_PKG_VERSION"))}))
            .await?;
        Ok(c)
    }

    /// Connect, starting the daemon with `clothod start` if it is not running.
    pub async fn connect_or_start(dir: &Path) -> Result<Client> {
        platform::check_socket_path(&socket_path(dir)).map_err(anyhow::Error::msg)?;
        if let Ok(c) = Client::connect(dir).await {
            return Ok(c);
        }
        let status = std::process::Command::new(clothod_binary())
            .arg("start")
            .arg("--runtime-dir")
            .arg(dir)
            .stdout(std::process::Stdio::null())
            .status()
            .context("running `clothod start`")?;
        if !status.success() {
            bail!("`clothod start` failed (its error is above; logs are in {})", platform::log_dir(dir).display());
        }
        Client::connect(dir).await
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        {
            // Checked under the same lock the reader takes when it ends, so a request can't be
            // registered after the final clear and wait forever.
            let mut pending = self.pending.lock().unwrap();
            if self.closed.load(Ordering::SeqCst) {
                bail!("connection closed before `{method}`");
            }
            pending.insert(id, tx);
        }
        let frame = Frame::Json(json!({"id": id, "method": method, "params": params}));
        self.out.send(frame.encode()).map_err(|_| anyhow!("connection closed"))?;
        let reply = rx.await.map_err(|_| anyhow!("connection closed before `{method}` replied"))?;
        if let Some(e) = reply.get("error") {
            bail!("{method}: {} ({})", e["message"].as_str().unwrap_or(""), e["code"].as_str().unwrap_or(""));
        }
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    }

    /// Send any frame (FILE_DATA for fs.write streams, notifications without an id).
    pub fn send(&self, frame: Frame) {
        let _ = self.out.send(frame.encode());
    }

    pub fn input(&self, pane: u64, data: &[u8]) {
        let _ = self.out.send(Frame::Input { pane, data: data.to_vec() }.encode());
    }

    /// Next frame that is not a reply (events, OUTPUT, SNAPSHOT). `None` once disconnected.
    pub async fn recv(&mut self) -> Option<Frame> {
        self.incoming.recv().await
    }

    pub fn try_recv(&mut self) -> Option<Frame> {
        self.incoming.try_recv().ok()
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        // The reader holds the stream's read half; ending it (and the writer, which stops once
        // its queue is flushed now that `out` is gone) closes the connection.
        if let Some(reader) = self.tasks.first() {
            reader.abort();
        }
    }
}

/// `clothod` next to this executable (or `$CLOTHOD_BIN`, or on `$PATH`).
pub fn clothod_binary() -> PathBuf {
    if let Some(p) = std::env::var_os("CLOTHOD_BIN") {
        return p.into();
    }
    if let Ok(exe) = std::env::current_exe() {
        for dir in exe.ancestors().skip(1).take(2) {
            let candidate = dir.join("clothod");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    PathBuf::from("clothod")
}

pub fn default_runtime_dir() -> PathBuf {
    platform::runtime_dir()
}

/// A client-side view of one pane: applies SNAPSHOT/OUTPUT/resize frames to a local VT the way
/// a real client renders them, and tracks the seq it has.
pub struct Screen {
    pub pane: u64,
    pub vt: Vt,
    /// Everything received up to here (`have_seq` for a resume).
    pub seq: u64,
    /// Output bytes received, in order (only OUTPUT, not snapshots).
    pub output: Vec<u8>,
    pub snapshots: usize,
}

impl Screen {
    pub fn new(pane: u64, cols: u16, rows: u16) -> Screen {
        Screen { pane, vt: Vt::new(cols, rows), seq: 0, output: Vec::new(), snapshots: 0 }
    }

    /// Apply a frame if it belongs to this pane. Panics on a seq gap: that is a protocol bug.
    pub fn apply(&mut self, frame: &Frame) -> bool {
        match frame {
            Frame::Snapshot { pane, seq, cols, rows, data } if *pane == self.pane => {
                self.vt = Vt::new(*cols, *rows);
                self.vt.feed(data);
                self.seq = *seq;
                self.snapshots += 1;
                true
            }
            Frame::Output { pane, seq, data } if *pane == self.pane => {
                assert_eq!(*seq, self.seq, "pane {pane}: output at {seq}, expected {}", self.seq);
                self.vt.feed(data);
                self.output.extend_from_slice(data);
                self.seq += data.len() as u64;
                true
            }
            Frame::Json(v) if v["event"] == "pane.resized" && v["data"]["pane"] == self.pane => {
                let d = &v["data"];
                self.vt.resize(d["cols"].as_u64().unwrap_or(80) as u16, d["rows"].as_u64().unwrap_or(24) as u16);
                true
            }
            _ => false,
        }
    }

    pub fn text(&self) -> Vec<String> {
        self.vt.screen_text()
    }
}

/// Wait until `cond` holds for the daemon's view of a pane (`pane.text`), up to `timeout`.
pub async fn wait_for_text(c: &Client, pane: u64, timeout: Duration, cond: impl Fn(&[String]) -> bool) -> Result<Vec<String>> {
    let deadline = Instant::now() + timeout;
    loop {
        let t = c.request("pane.text", json!({"pane": pane})).await?;
        let lines: Vec<String> = t["lines"].as_array().map(|a| a.iter().map(|l| l.as_str().unwrap_or("").to_string()).collect()).unwrap_or_default();
        if cond(&lines) {
            return Ok(lines);
        }
        if Instant::now() > deadline {
            bail!("timed out waiting for pane {pane}; screen:\n{}", lines.join("\n"));
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
}

/// Removes the outer terminal's replies from what `clotho attach` reads on stdin.
///
/// `attach` copies pane output to the real terminal, which answers the queries in it (DA,
/// DSR/CPR, OSC 10/11 colors, kitty `CSI ? u`, XTVERSION, window reports). The daemon already
/// answered them, so forwarding those answers as input would answer twice. Worse, a kitty
/// `CSI ? <flags> u` answer makes apps like Claude Code switch keyboard protocols. Real keys
/// never have these shapes, except a CPR (`CSI r;c R`) versus a modified F3 (`CSI 1;m R`), so
/// CPRs are only dropped shortly after the pane asked for one.
pub struct ReplyFilter {
    pending: Vec<u8>,
    cpr_until: Option<std::time::Instant>,
}

impl Default for ReplyFilter {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplyFilter {
    pub fn new() -> Self {
        ReplyFilter { pending: Vec::new(), cpr_until: None }
    }

    /// Note pane output going to the terminal (to expect a CPR after a `CSI 6n`).
    pub fn saw_output(&mut self, data: &[u8]) {
        if data.windows(3).any(|w| w == b"[6n") {
            self.cpr_until = Some(std::time::Instant::now() + Duration::from_secs(2));
        }
    }

    /// Feed stdin bytes; returns what to forward. An incomplete escape sequence at the end is
    /// held back until more input or [`ReplyFilter::flush`].
    pub fn input(&mut self, data: &[u8]) -> Vec<u8> {
        self.pending.extend_from_slice(data);
        let buf = std::mem::take(&mut self.pending);
        let mut out = Vec::new();
        let mut i = 0;
        while i < buf.len() {
            if buf[i] != 0x1b {
                out.push(buf[i]);
                i += 1;
                continue;
            }
            match seq_len(&buf[i..]) {
                None => {
                    // Incomplete: wait for the rest.
                    self.pending = buf[i..].to_vec();
                    break;
                }
                Some(n) => {
                    let seq = &buf[i..i + n];
                    if !self.is_reply(seq) {
                        out.extend_from_slice(seq);
                    }
                    i += n;
                }
            }
        }
        out
    }

    /// Bytes held back (a lone ESC is the Esc key once nothing follows it quickly).
    pub fn flush(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.pending)
    }

    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    fn is_reply(&mut self, seq: &[u8]) -> bool {
        match seq.get(1) {
            // OSC and DCS never come from keys.
            Some(b']') | Some(b'P') => true,
            Some(b'[') => {
                let body = &seq[2..];
                let fin = *body.last().unwrap_or(&0);
                let private = body.first().is_some_and(|b| matches!(b, b'?' | b'>' | b'='));
                match fin {
                    b'c' => true,                // DA1/DA2/DA3
                    b't' => true,                // window reports
                    b'y' if body.contains(&b'$') => true, // DECRPM
                    b'u' if body.first() == Some(&b'?') => true, // kitty flags
                    b'R' => {
                        let expected = self.cpr_until.is_some_and(|t| std::time::Instant::now() < t);
                        if expected && !private {
                            self.cpr_until = None;
                            true
                        } else {
                            private // CSI ? r;c R (DECXCPR) is always a reply
                        }
                    }
                    _ => false,
                }
            }
            _ => false,
        }
    }
}

/// Length of the escape sequence at the start of `b` (which starts with ESC), or None if it is
/// not complete yet.
fn seq_len(b: &[u8]) -> Option<usize> {
    let second = *b.get(1)?;
    match second {
        b'[' => {
            // CSI: parameters/intermediates until a final byte 0x40..=0x7e.
            b.iter().skip(2).position(|&c| (0x40..=0x7e).contains(&c)).map(|p| p + 3)
        }
        b']' | b'P' | b'_' | b'^' | b'X' => {
            // String: until BEL or ESC \.
            let mut i = 2;
            while i < b.len() {
                if b[i] == 0x07 {
                    return Some(i + 1);
                }
                if b[i] == 0x1b {
                    return if i + 1 < b.len() { Some(if b[i + 1] == b'\\' { i + 2 } else { i }) } else { None };
                }
                i += 1;
            }
            None
        }
        b'O' => b.get(2).map(|_| 3), // SS3 key
        _ => Some(2),                // ESC + key (alt+key) or ESC ESC
    }
}

#[cfg(test)]
mod filter_tests {
    use super::ReplyFilter;

    #[test]
    fn drops_replies_keeps_keys() {
        let mut f = ReplyFilter::new();
        f.saw_output(b"\x1b[6n");
        let input = b"a\x1b[?6c\x1b[1;1R\x1b]11;rgb:1e1e/1e1e/1e1e\x07\x1b[?7u\x1bP>|kitty\x1b\\\x1b[8;24;80t\x1b[?2004;1$yb\x1b[A\x1b[13u\x1bOP\x1bx\x1b[200~p\x1b[201~";
        assert_eq!(f.input(input), b"ab\x1b[A\x1b[13u\x1bOP\x1bx\x1b[200~p\x1b[201~".to_vec());
    }

    #[test]
    fn modified_f3_survives_without_a_cpr_request() {
        let mut f = ReplyFilter::new();
        assert_eq!(f.input(b"\x1b[1;5R"), b"\x1b[1;5R");
        f.saw_output(b"x\x1b[6ny");
        assert_eq!(f.input(b"\x1b[12;40R"), b"");
        assert_eq!(f.input(b"\x1b[1;5R"), b"\x1b[1;5R", "one CPR per request");
    }

    #[test]
    fn split_sequences_and_lone_escape() {
        let mut f = ReplyFilter::new();
        assert_eq!(f.input(b"x\x1b]11;rgb:00"), b"x");
        assert!(f.has_pending());
        assert_eq!(f.input(b"/00/00\x1b\\y"), b"y");
        assert_eq!(f.input(b"\x1b"), b"");
        assert_eq!(f.flush(), b"\x1b", "a lone Esc is a key");
    }
}
