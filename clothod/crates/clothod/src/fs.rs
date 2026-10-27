//! File access for clients (docs/protocol.md, "Files"): metadata calls, and transfers as
//! FILE_DATA streams with credit-based flow control. Writes are atomic (part file, fsync,
//! rename) and resumable by `upload_id`.

use std::collections::HashMap;
use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{FileExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use base64::Engine;
use clotho_proto::frame::FILE_FIN;
use clotho_proto::Frame;
use serde_json::{json, Value};
use tokio::sync::{mpsc, Notify};

use crate::daemon::Client;

/// Per-connection limit on open streams.
const MAX_STREAMS: usize = 16;
const DEFAULT_CHUNK: u64 = 256 << 10;
const DEFAULT_WINDOW: u64 = 4 << 20;
/// Part files of interrupted resumable writes are deleted after this long.
const PART_TTL_SECS: u64 = 24 * 3600;

pub(crate) struct Ctx {
    /// The instance's state dir (where 0.1.10 and earlier kept a part-file registry).
    pub state_dir: PathBuf,
}

pub(crate) struct FsError {
    pub code: &'static str,
    pub message: String,
}

type R<T> = Result<T, FsError>;

fn err(code: &'static str, message: impl Into<String>) -> FsError {
    FsError { code, message: message.into() }
}

fn io_err(e: std::io::Error, path: &Path) -> FsError {
    let code = match e.raw_os_error() {
        Some(libc::ENOENT) => "not_found",
        Some(libc::EEXIST) => "exists",
        Some(libc::EACCES) | Some(libc::EPERM) => "permission_denied",
        Some(libc::ENOTDIR) => "not_a_directory",
        Some(libc::EISDIR) => "is_a_directory",
        Some(libc::ENOTEMPTY) => "not_empty",
        Some(libc::EXDEV) => "cross_device",
        Some(libc::ENOSPC) | Some(libc::EDQUOT) => "no_space",
        Some(libc::EROFS) => "read_only",
        _ => "io_error",
    };
    err(code, format!("{}: {e}", path.display()))
}

// ---- paths and entries --------------------------------------------------------------------

fn b64() -> base64::engine::GeneralPurpose {
    base64::engine::general_purpose::STANDARD
}

/// A path parameter: `<key>_raw` (base64 bytes) or `<key>` (absolute, `~` or `~/…`).
fn path_param(p: &Value, key: &str) -> R<PathBuf> {
    if let Some(raw) = p.get(format!("{key}_raw")).and_then(Value::as_str) {
        let bytes = b64().decode(raw).map_err(|_| err("bad_request", format!("{key}_raw is not base64")))?;
        let path = PathBuf::from(OsString::from_vec(bytes));
        if !path.is_absolute() {
            return Err(err("bad_request", format!("{key}_raw must be an absolute path")));
        }
        return Ok(path);
    }
    let s = p.get(key).and_then(Value::as_str).ok_or_else(|| err("bad_request", format!("missing `{key}`")))?;
    let home = || std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
    if s == "~" {
        Ok(home())
    } else if let Some(rest) = s.strip_prefix("~/") {
        Ok(home().join(rest))
    } else if s.starts_with('/') {
        Ok(PathBuf::from(s))
    } else {
        Err(err("bad_request", format!("`{s}`: paths are absolute or start with ~/ (not ~user, not relative)")))
    }
}

fn mtime_ns(m: &std::fs::Metadata) -> i128 {
    m.mtime() as i128 * 1_000_000_000 + m.mtime_nsec() as i128
}

fn parse_ns(v: Option<&Value>) -> R<Option<i128>> {
    match v {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => s.parse().map(Some).map_err(|_| err("bad_request", format!("bad nanoseconds `{s}`"))),
        Some(Value::Number(n)) => n.as_i64().map(|n| Some(n as i128)).ok_or_else(|| err("bad_request", "bad nanoseconds")),
        _ => Err(err("bad_request", "nanoseconds must be a decimal string")),
    }
}

fn entry(path: &Path) -> R<Value> {
    let lmeta = std::fs::symlink_metadata(path).map_err(|e| io_err(e, path))?;
    let link = lmeta.file_type().is_symlink();
    let target = link.then(|| std::fs::read_link(path).ok()).flatten();
    // For links: what they point to; a dangling link keeps its own metadata.
    let meta = if link { std::fs::metadata(path).ok() } else { Some(lmeta.clone()) };
    let m = meta.as_ref().unwrap_or(&lmeta);
    let kind = match &meta {
        Some(m) if m.is_dir() => "dir",
        Some(m) if m.is_file() => "file",
        _ => "other",
    };
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    let ns = mtime_ns(m);
    let mut e = json!({
        "name": name,
        "path": path.to_string_lossy(),
        "type": kind,
        "link": link,
        "target": target.map(|t| t.to_string_lossy().into_owned()),
        "size": m.len(),
        "mtime": ns as f64 / 1e9,
        "mtime_ns": ns.to_string(),
        "mode": m.mode() & 0o7777,
        "hidden": name.starts_with('.'),
    });
    if path.to_str().is_none() {
        e["path_raw"] = json!(b64().encode(path.as_os_str().as_bytes()));
    }
    Ok(e)
}

/// No NUL in the first 8 KiB: probably text.
fn sniff_text(path: &Path) -> bool {
    let Ok(f) = std::fs::File::open(path) else { return false };
    let mut buf = vec![0u8; 8192];
    let n = f.read_at(&mut buf, 0).unwrap_or(0);
    !buf[..n].contains(&0)
}

// ---- streams -----------------------------------------------------------------------------

#[derive(Default)]
pub(crate) struct Streams {
    map: Mutex<HashMap<u64, Handle>>,
    next: AtomicU64,
    /// Read streams waiting for their reply to go out before sending data.
    pending_start: Mutex<HashMap<u64, Arc<Notify>>>,
}

enum Handle {
    Read(Arc<Ctl>),
    Write(Arc<Ctl>, mpsc::UnboundedSender<Chunk>),
}

struct Ctl {
    /// Reads: what the client acknowledged. Writes: what reached the file.
    acked: AtomicU64,
    wake: Notify,
    cancelled: AtomicBool,
    /// Writes: the flow-control window; data past `acked + window` is a broken client.
    window: u64,
    /// Writes: the client sent past its window, or another stream took the part file over.
    failed: Mutex<Option<&'static str>>,
}

impl Ctl {
    fn new(at: u64, window: u64) -> Arc<Ctl> {
        Arc::new(Ctl { acked: AtomicU64::new(at), wake: Notify::new(), cancelled: AtomicBool::new(false), window, failed: Mutex::new(None) })
    }
}

struct Chunk {
    offset: u64,
    fin: bool,
    data: Vec<u8>,
}

impl Streams {
    fn open(&self, h: Handle) -> R<u64> {
        let mut map = self.map.lock().unwrap();
        if map.len() >= MAX_STREAMS {
            return Err(err("too_many_streams", format!("at most {MAX_STREAMS} streams per connection")));
        }
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        map.insert(id, h);
        Ok(id)
    }

    fn close(&self, id: u64) {
        self.map.lock().unwrap().remove(&id);
    }
}

/// `fs.ack {stream, offset}` from the client: credit for a read stream.
pub(crate) fn ack(client: &Arc<Client>, p: &Value) {
    let (Some(id), Some(off)) = (p["stream"].as_u64(), p["offset"].as_u64()) else { return };
    if let Some(Handle::Read(ctl)) = client.fs.map.lock().unwrap().get(&id) {
        ctl.acked.fetch_max(off, Ordering::SeqCst);
        ctl.wake.notify_one();
    }
}

/// A FILE_DATA frame from the client: data for a write stream.
pub(crate) fn data(client: &Arc<Client>, stream: u64, offset: u64, flags: u8, data: Vec<u8>) {
    let mut map = client.fs.map.lock().unwrap();
    if let Some(Handle::Write(ctl, tx)) = map.get(&stream) {
        // Queued data is memory: a client ignoring its window (more than one window ahead of
        // the disk) loses the stream instead of growing serve.
        let end = offset.saturating_add(data.len() as u64);
        if end > ctl.acked.load(Ordering::SeqCst).saturating_add(2 * ctl.window) {
            *ctl.failed.lock().unwrap() = Some("window_exceeded");
            map.remove(&stream);
            return;
        }
        let _ = tx.send(Chunk { offset, fin: flags & FILE_FIN != 0, data });
    }
}

/// The reply to `fs.read` went out: its data may follow now (data must not overtake it).
pub(crate) fn replied(client: &Arc<Client>, result: &Value) {
    if let Some(id) = result["stream"].as_u64() {
        if let Some(n) = client.fs.pending_start.lock().unwrap().remove(&id) {
            n.notify_one();
        }
    }
}

/// The connection ended: stop its streams (resumable writes keep their part files).
pub(crate) fn close_all(client: &Arc<Client>) {
    let handles: Vec<Handle> = client.fs.map.lock().unwrap().drain().map(|(_, h)| h).collect();
    for h in handles {
        match h {
            Handle::Read(ctl) | Handle::Write(ctl, _) => {
                ctl.cancelled.store(true, Ordering::SeqCst);
                ctl.wake.notify_one();
            }
        }
    }
}

// ---- requests ----------------------------------------------------------------------------

pub(crate) async fn request(ctx: &Ctx, client: &Arc<Client>, method: &str, p: &Value) -> R<Value> {
    match method {
        "fs.stat" => {
            let path = path_param(p, "path")?;
            let mut e = entry(&path)?;
            if e["type"] == "file" {
                e["text"] = json!(sniff_text(&path));
            }
            Ok(e)
        }
        "fs.list" => list(p),
        "fs.mkdir" => {
            let path = path_param(p, "path")?;
            let r = if p["parents"].as_bool().unwrap_or(false) { std::fs::create_dir_all(&path) } else { std::fs::create_dir(&path) };
            r.map_err(|e| io_err(e, &path))?;
            entry(&path)
        }
        "fs.setattr" => {
            let path = path_param(p, "path")?;
            if let Some(mode) = p["mode"].as_u64() {
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode as u32 & 0o7777)).map_err(|e| io_err(e, &path))?;
            }
            if let Some(ns) = parse_ns(p.get("mtime_ns"))? {
                set_mtime(&path, ns).map_err(|e| io_err(e, &path))?;
            }
            entry(&path)
        }
        "fs.rename" => {
            let (from, to) = (path_param(p, "from")?, path_param(p, "to")?);
            if !p["overwrite"].as_bool().unwrap_or(false) && std::fs::symlink_metadata(&to).is_ok() {
                return Err(err("exists", format!("{} exists", to.display())));
            }
            std::fs::rename(&from, &to).map_err(|e| io_err(e, &from))?;
            entry(&to)
        }
        "fs.remove" => {
            let path = path_param(p, "path")?;
            let meta = std::fs::symlink_metadata(&path).map_err(|e| io_err(e, &path))?;
            let r = if meta.is_dir() {
                if p["recursive"].as_bool().unwrap_or(false) { std::fs::remove_dir_all(&path) } else { std::fs::remove_dir(&path) }
            } else {
                std::fs::remove_file(&path)
            };
            r.map_err(|e| io_err(e, &path))?;
            Ok(json!({}))
        }
        "fs.statfs" => {
            let path = path_param(p, "path")?;
            let c = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| err("bad_request", "NUL in path"))?;
            let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
            if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
                return Err(io_err(std::io::Error::last_os_error(), &path));
            }
            let f = st.f_frsize as u64;
            Ok(json!({"total": st.f_blocks as u64 * f, "free": st.f_bfree as u64 * f, "available": st.f_bavail as u64 * f}))
        }
        "fs.read" => read(client, p),
        "fs.write" => write(ctx, client, p),
        "fs.ack" => {
            ack(client, p);
            Ok(json!({}))
        }
        "fs.cancel" => {
            let id = p["stream"].as_u64().ok_or_else(|| err("bad_request", "missing stream"))?;
            let h = client.fs.map.lock().unwrap().remove(&id);
            match h {
                Some(Handle::Read(ctl)) => {
                    ctl.cancelled.store(true, Ordering::SeqCst);
                    ctl.wake.notify_one();
                    client.event("fs.done", json!({"stream": id, "cancelled": true}));
                }
                // The writer task notices the closed channel, cleans up and reports.
                Some(Handle::Write(ctl, _tx)) => {
                    ctl.cancelled.store(true, Ordering::SeqCst);
                }
                None => return Err(err("not_found", format!("no stream {id}"))),
            }
            Ok(json!({}))
        }
        _ => Err(err("bad_request", format!("unknown method `{method}`"))),
    }
}

fn set_mtime(path: &Path, ns: i128) -> std::io::Result<()> {
    let c = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    let times = [
        libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_OMIT },
        libc::timespec { tv_sec: ns.div_euclid(1_000_000_000) as _, tv_nsec: ns.rem_euclid(1_000_000_000) as _ },
    ];
    if unsafe { libc::utimensat(libc::AT_FDCWD, c.as_ptr(), times.as_ptr(), 0) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

fn list(p: &Value) -> R<Value> {
    let dir = path_param(p, "path")?;
    let limit = p["limit"].as_u64().unwrap_or(1000).clamp(1, 10_000) as usize;
    let hidden = p["hidden"].as_bool().unwrap_or(true);
    let after: Option<Vec<u8>> = match p["cursor"].as_str() {
        Some(c) => Some(b64().decode(c).map_err(|_| err("bad_request", "bad cursor"))?),
        None => None,
    };
    let rd = std::fs::read_dir(&dir).map_err(|e| io_err(e, &dir))?;
    let mut names: Vec<OsString> = rd.flatten().map(|e| e.file_name()).collect();
    names.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    let mut entries = Vec::new();
    let mut next = None;
    for name in names {
        let bytes = name.as_bytes();
        if after.as_deref().is_some_and(|a| bytes <= a) || (!hidden && bytes.starts_with(b".")) {
            continue;
        }
        if entries.len() == limit {
            // More to come: continue after the last one returned.
            next = entries.last().map(|(n, _): &(Vec<u8>, Value)| b64().encode(n));
            break;
        }
        // Gone between readdir and stat: skip it.
        if let Ok(e) = entry(&dir.join(&name)) {
            entries.push((bytes.to_vec(), e));
        }
    }
    Ok(json!({"dir": entry(&dir)?, "entries": entries.into_iter().map(|(_, e)| e).collect::<Vec<_>>(), "next": next}))
}

fn stream_params(p: &Value) -> (u64, u64) {
    let chunk = p["chunk"].as_u64().unwrap_or(DEFAULT_CHUNK).clamp(4 << 10, 1 << 20);
    let window = p["window"].as_u64().unwrap_or(DEFAULT_WINDOW).clamp(chunk, 64 << 20);
    (chunk, window)
}

fn read(client: &Arc<Client>, p: &Value) -> R<Value> {
    let path = path_param(p, "path")?;
    let file = std::fs::File::open(&path).map_err(|e| io_err(e, &path))?;
    let meta = file.metadata().map_err(|e| io_err(e, &path))?;
    if meta.is_dir() {
        return Err(err("is_a_directory", format!("{} is a directory", path.display())));
    }
    let (size, ns) = (meta.len(), mtime_ns(&meta));
    if p["expect_size"].as_u64().is_some_and(|s| s != size) || parse_ns(p.get("expect_mtime_ns"))?.is_some_and(|m| m != ns) {
        return Err(err("changed", format!("{} changed since it was first read", path.display())));
    }
    let offset = p["offset"].as_u64().unwrap_or(0);
    if offset > size {
        return Err(err("bad_request", format!("offset {offset} is past the end ({size})")));
    }
    let end = p["length"].as_u64().map_or(size, |l| size.min(offset.saturating_add(l)));
    let (chunk, window) = stream_params(p);
    let ctl = Ctl::new(offset, window);
    let id = client.fs.open(Handle::Read(ctl.clone()))?;
    let start = Arc::new(Notify::new());
    client.fs.pending_start.lock().unwrap().insert(id, start.clone());
    let client = client.clone();
    tokio::spawn(async move {
        start.notified().await;
        let file = Arc::new(file);
        let mut pos = offset;
        loop {
            if ctl.cancelled.load(Ordering::SeqCst) {
                break;
            }
            if pos >= end {
                // Unchanged while we read it? Otherwise the client would get a mix.
                let now = std::fs::metadata(&path).ok().map(|m| (m.len(), mtime_ns(&m)));
                if now != Some((size, ns)) {
                    client.event("fs.error", json!({"stream": id, "code": "changed", "message": format!("{} changed during the read", path.display())}));
                } else {
                    client.file(Frame::FileData { stream: id, offset: pos, flags: FILE_FIN, data: Vec::new() }.encode());
                }
                break;
            }
            let acked = ctl.acked.load(Ordering::SeqCst);
            if pos >= acked + window {
                ctl.wake.notified().await;
                continue;
            }
            let n = chunk.min(end - pos).min(acked + window - pos) as usize;
            let (f, at) = (file.clone(), pos);
            let res = tokio::task::spawn_blocking(move || {
                let mut buf = vec![0u8; n];
                let got = f.read_at(&mut buf, at)?;
                buf.truncate(got);
                Ok::<_, std::io::Error>(buf)
            })
            .await;
            match res {
                Ok(Ok(buf)) if !buf.is_empty() => {
                    let len = buf.len() as u64;
                    client.file(Frame::FileData { stream: id, offset: pos, flags: 0, data: buf }.encode());
                    pos += len;
                }
                Ok(Ok(_)) => {
                    client.event("fs.error", json!({"stream": id, "code": "changed", "message": format!("{} got shorter during the read", path.display())}));
                    break;
                }
                Ok(Err(e)) => {
                    let e = io_err(e, &path);
                    client.event("fs.error", json!({"stream": id, "code": e.code, "message": e.message}));
                    break;
                }
                Err(_) => break,
            }
        }
        client.fs.close(id);
    });
    Ok(json!({"stream": id, "size": size, "mtime_ns": ns.to_string(), "offset": offset}))
}

// ---- writes ------------------------------------------------------------------------------

/// The process umask, read once at startup ([`init_umask`]): new files without a requested mode
/// get `0666 & !umask`, as `open` would have given them.
static UMASK: std::sync::OnceLock<u32> = std::sync::OnceLock::new();

/// Read the umask. Call before any other thread starts: reading it means setting it.
pub fn init_umask() {
    let m = unsafe { libc::umask(0o077) };
    unsafe { libc::umask(m) };
    let _ = UMASK.set(m as u32);
}

pub(crate) fn umask() -> u32 {
    UMASK.get().copied().unwrap_or(0o022)
}

fn default_mode() -> u32 {
    0o666 & !umask()
}

/// Writes in progress, by part file, across all connections: a resumed write of the same part
/// takes over from one still open on a connection that went half-open (nothing tells serve it
/// died, and its stream would hold the part forever).
static ACTIVE: Mutex<Option<HashMap<PathBuf, Arc<Ctl>>>> = Mutex::new(None);

/// Part files older than this are swept from a directory a write goes to.
const SWEEP_EVERY_SECS: u64 = 3600;
static SWEPT: Mutex<Option<HashMap<PathBuf, u64>>> = Mutex::new(None);

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Delete this user's part files in `dir` untouched for [`PART_TTL_SECS`] (at most hourly per
/// dir). Part files live next to their target, so this finds them wherever the instance that
/// wrote them went (a private instance's state dies with it).
fn sweep(dir: &Path, keep: &Path) {
    let now = now_secs();
    {
        let mut g = SWEPT.lock().unwrap();
        let swept = g.get_or_insert_with(HashMap::new);
        if swept.get(dir).is_some_and(|t| now.saturating_sub(*t) < SWEEP_EVERY_SECS) {
            return;
        }
        swept.insert(dir.to_path_buf(), now);
    }
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let uid = clotho_proto::platform::current_uid();
    for e in rd.flatten() {
        let name = e.file_name();
        let b = name.as_bytes();
        if !b.starts_with(b".") || !b.windows(13).any(|w| w == b".clotho-part-") {
            continue;
        }
        let path = e.path();
        let Ok(m) = std::fs::symlink_metadata(&path) else { continue };
        if path != keep && m.is_file() && m.uid() == uid && now.saturating_sub(m.mtime().max(0) as u64) >= PART_TTL_SECS {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// Open (or create) a part file, never following a symlink and only ever ours: in a shared
/// directory (/tmp) someone else could have put a link or file at a predictable part name.
/// Returns the file and how much of it is already there (`resume`), else an empty new file.
fn open_part(part: &Path, resume: bool) -> std::io::Result<(std::fs::File, u64)> {
    use std::os::unix::fs::OpenOptionsExt;
    if resume {
        let f = std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NOFOLLOW).open(part);
        match f {
            Ok(f) => {
                let m = f.metadata()?;
                if m.is_file() && m.uid() == clotho_proto::platform::current_uid() && m.nlink() == 1 {
                    return Ok((f, m.len()));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => {}
        }
    }
    // Not resumable: the name itself goes (a link, not what it points to), then a fresh file
    // only we can read until it is complete.
    match std::fs::remove_file(part) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(part)?;
    Ok((f, 0))
}

/// Sweep and part-name parts of `source`: the first 12 hex digits of its SHA-256.
fn source_tag(source: &str) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(source.as_bytes())[..6].iter().map(|b| format!("{b:02x}")).collect()
}

/// Forget `ctl` as the writer of `part`, unless another stream took it over.
fn release(part: &Path, ctl: &Arc<Ctl>) {
    let mut g = ACTIVE.lock().unwrap();
    if let Some(m) = g.as_mut() {
        if m.get(part).is_some_and(|c| Arc::ptr_eq(c, ctl)) {
            m.remove(part);
        }
    }
}

fn write(ctx: &Ctx, client: &Arc<Client>, p: &Value) -> R<Value> {
    // 0.1.10 and earlier kept a registry of part files in the state dir; parts are now found
    // by name.
    let _ = std::fs::remove_file(ctx.state_dir.join("fs-parts.json"));
    let requested = path_param(p, "path")?;
    // Writing through a symlink writes its target (the link survives).
    let target = match std::fs::symlink_metadata(&requested) {
        Ok(m) if m.file_type().is_symlink() => std::fs::canonicalize(&requested).map_err(|e| io_err(e, &requested))?,
        _ => requested.clone(),
    };
    let (dir, name) = match (target.parent(), target.file_name()) {
        (Some(d), Some(n)) => (d.to_path_buf(), n.to_os_string()),
        _ => return Err(err("bad_request", format!("{} is not a file path", target.display()))),
    };
    if !dir.is_dir() {
        return Err(err("not_found", format!("{} does not exist", dir.display())));
    }
    let existing = std::fs::metadata(&target).ok();
    if existing.as_ref().is_some_and(|m| m.is_dir()) {
        return Err(err("is_a_directory", format!("{} is a directory", target.display())));
    }
    let overwrite = p["overwrite"].as_bool().unwrap_or(false);
    if existing.is_some() && !overwrite {
        return Err(err("exists", format!("{} exists", target.display())));
    }
    let expect = parse_ns(p.get("expect_mtime_ns"))?;
    if let Some(want) = expect {
        if existing.as_ref().map(mtime_ns) != Some(want) {
            return Err(err("conflict", format!("{} changed since it was read", target.display())));
        }
    }
    let size = p["size"].as_u64();
    let mode = p["mode"].as_u64().map(|m| m as u32 & 0o7777).or(existing.as_ref().map(|m| m.mode() & 0o7777)).unwrap_or_else(default_mode);
    let set_mtime_ns = parse_ns(p.get("mtime_ns"))?;
    let upload_id: Option<String> = p["upload_id"]
        .as_str()
        .map(|u| u.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').take(64).collect::<String>())
        .filter(|u| !u.is_empty());
    let source = p["source"].as_str().unwrap_or("");
    // A resumable part is named by its upload and its source, so only the same upload of the
    // same data resumes it, whichever instance (or build) wrote it.
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let tag = match &upload_id {
        Some(u) => format!("{u}-{}", source_tag(source)),
        None => format!("{}-{}-{}", std::process::id(), now_secs(), SEQ.fetch_add(1, Ordering::Relaxed)),
    };
    let mut part_name = OsString::from(".");
    part_name.push(&name);
    part_name.push(format!(".clotho-part-{tag}"));
    let part = dir.join(part_name);
    sweep(&dir, &part);

    let (_, window) = stream_params(p);
    // Take the part over from a stream still writing it (its connection went half-open), before
    // opening it, so that stream no longer touches it.
    let ctl = Ctl::new(0, window);
    {
        let mut g = ACTIVE.lock().unwrap();
        if let Some(old) = g.get_or_insert_with(HashMap::new).insert(part.clone(), ctl.clone()) {
            *old.failed.lock().unwrap() = Some("superseded");
            old.wake.notify_one();
        }
    }
    let (file, offset) = match open_part(&part, upload_id.is_some()) {
        Ok(f) => f,
        Err(e) => {
            release(&part, &ctl);
            return Err(io_err(e, &part));
        }
    };
    ctl.acked.store(offset, Ordering::SeqCst);
    let (tx, mut rx) = mpsc::unbounded_channel::<Chunk>();
    let id = match client.fs.open(Handle::Write(ctl.clone(), tx)) {
        Ok(id) => id,
        Err(e) => {
            release(&part, &ctl);
            if upload_id.is_none() {
                let _ = std::fs::remove_file(&part);
            }
            return Err(e);
        }
    };

    let client = client.clone();
    let resumable = upload_id.is_some();
    tokio::spawn(async move {
        let file = Arc::new(file);
        let mut written = offset;
        let mut last_ack = offset;
        let finish: Result<Value, FsError> = loop {
            let chunk = tokio::select! {
                c = rx.recv() => c,
                _ = ctl.wake.notified() => None,
            };
            let Some(chunk) = chunk else {
                let failed = *ctl.failed.lock().unwrap();
                break Err(match failed {
                    Some("superseded") => err("superseded", "another write of this upload took over"),
                    Some(code) => err(code, format!("data past the stream's window ({window} bytes beyond {written})")),
                    // Cancelled or connection gone.
                    None => err("cancelled", ""),
                });
            };
            if chunk.offset != written {
                break Err(err("bad_request", format!("data at {} but the stream is at {written}", chunk.offset)));
            }
            if !chunk.data.is_empty() {
                let (f, at, data) = (file.clone(), written, chunk.data);
                let len = data.len() as u64;
                match tokio::task::spawn_blocking(move || f.write_all_at(&data, at)).await {
                    Ok(Ok(())) => written += len,
                    Ok(Err(e)) => break Err(io_err(e, &part)),
                    Err(_) => break Err(err("io_error", "write task failed")),
                }
                ctl.acked.store(written, Ordering::SeqCst);
            }
            if written - last_ack >= window / 4 || (chunk.fin && written != last_ack) {
                client.event("fs.ack", json!({"stream": id, "offset": written}));
                last_ack = written;
            }
            if chunk.fin {
                break finish_write(&file, &part, &target, size, written, mode, set_mtime_ns, overwrite, expect);
            }
        };
        client.fs.close(id);
        let superseded = matches!(&finish, Err(e) if e.code == "superseded");
        if !superseded {
            release(&part, &ctl);
        }
        match finish {
            Ok(entry) => client.event("fs.done", json!({"stream": id, "entry": entry})),
            Err(e) => {
                // Keep a resumable part file unless the data itself was rejected (and always
                // when another stream has it now).
                let keep = superseded || (resumable && matches!(e.code, "cancelled" | "io_error" | "no_space" | "window_exceeded"));
                if !keep {
                    let _ = std::fs::remove_file(&part);
                }
                if e.code == "cancelled" {
                    if ctl.cancelled.load(Ordering::SeqCst) {
                        client.event("fs.done", json!({"stream": id, "cancelled": true}));
                    }
                } else {
                    client.event("fs.error", json!({"stream": id, "code": e.code, "message": e.message}));
                }
            }
        }
    });
    Ok(json!({"stream": id, "offset": offset, "window": window}))
}

#[allow(clippy::too_many_arguments)]
fn finish_write(
    file: &std::fs::File,
    part: &Path,
    target: &Path,
    size: Option<u64>,
    written: u64,
    mode: u32,
    mtime: Option<i128>,
    overwrite: bool,
    expect: Option<i128>,
) -> Result<Value, FsError> {
    if let Some(want) = size {
        if want != written {
            return Err(err("bad_request", format!("{written} bytes written, {want} announced")));
        }
    }
    file.set_len(written).map_err(|e| io_err(e, part))?;
    file.sync_all().map_err(|e| io_err(e, part))?;
    std::fs::set_permissions(part, std::fs::Permissions::from_mode(mode)).map_err(|e| io_err(e, part))?;
    if let Some(ns) = mtime {
        set_mtime(part, ns).map_err(|e| io_err(e, part))?;
    }
    // Checked again at the end: someone may have written the target meanwhile.
    let existing = std::fs::metadata(target).ok();
    if existing.is_some() && !overwrite {
        return Err(err("exists", format!("{} exists", target.display())));
    }
    if let Some(want) = expect {
        if existing.as_ref().map(mtime_ns) != Some(want) {
            return Err(err("conflict", format!("{} changed while it was being written", target.display())));
        }
    }
    std::fs::rename(part, target).map_err(|e| io_err(e, target))?;
    entry(target)
}
