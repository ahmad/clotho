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
    /// Where the part-file registry lives.
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
    /// Reads: what the client acknowledged.
    acked: AtomicU64,
    wake: Notify,
    cancelled: AtomicBool,
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
    if let Some(Handle::Write(_, tx)) = client.fs.map.lock().unwrap().get(&stream) {
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
    let ctl = Arc::new(Ctl { acked: AtomicU64::new(offset), wake: Notify::new(), cancelled: AtomicBool::new(false) });
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

/// Part files of resumable writes: part path -> (source fingerprint, created unix secs).
fn registry_path(ctx: &Ctx) -> PathBuf {
    ctx.state_dir.join("fs-parts.json")
}

fn load_parts(ctx: &Ctx) -> HashMap<String, (String, u64)> {
    std::fs::read(registry_path(ctx)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_parts(ctx: &Ctx, parts: &HashMap<String, (String, u64)>) {
    let _ = clotho_proto::platform::ensure_private_dir(&ctx.state_dir);
    if let Ok(b) = serde_json::to_vec(parts) {
        let tmp = registry_path(ctx).with_extension("tmp");
        if std::fs::write(&tmp, b).is_ok() {
            let _ = std::fs::rename(tmp, registry_path(ctx));
        }
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

static PARTS_LOCK: Mutex<()> = Mutex::new(());

/// Record (or forget, with `None`) a kept part file; also expire old ones.
fn note_part(ctx: &Ctx, part: &Path, source: Option<&str>) {
    let _g = PARTS_LOCK.lock().unwrap();
    let mut parts = load_parts(ctx);
    let now = now_secs();
    parts.retain(|p, (_, created)| {
        let keep = now.saturating_sub(*created) < PART_TTL_SECS;
        if !keep {
            let _ = std::fs::remove_file(p);
        }
        keep
    });
    let key = part.to_string_lossy().into_owned();
    match source {
        Some(s) => {
            parts.insert(key, (s.to_string(), now));
        }
        None => {
            parts.remove(&key);
        }
    }
    save_parts(ctx, &parts);
}

fn part_source(ctx: &Ctx, part: &Path) -> Option<String> {
    let _g = PARTS_LOCK.lock().unwrap();
    load_parts(ctx).get(&*part.to_string_lossy()).map(|(s, _)| s.clone())
}

fn write(ctx: &Ctx, client: &Arc<Client>, p: &Value) -> R<Value> {
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
    let mode = p["mode"].as_u64().map(|m| m as u32 & 0o7777).or(existing.as_ref().map(|m| m.mode() & 0o7777));
    let set_mtime_ns = parse_ns(p.get("mtime_ns"))?;
    let upload_id: Option<String> = p["upload_id"]
        .as_str()
        .map(|u| u.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').take(64).collect::<String>())
        .filter(|u| !u.is_empty());
    let source = p["source"].as_str().unwrap_or("").to_string();
    let tag = upload_id.clone().unwrap_or_else(|| format!("{}-{}", std::process::id(), now_secs()));
    let mut part_name = OsString::from(".");
    part_name.push(&name);
    part_name.push(format!(".clotho-part-{tag}"));
    let part = dir.join(part_name);

    // Resume only the same upload of the same source data.
    let mut offset = 0;
    if upload_id.is_some() {
        if let Ok(m) = std::fs::metadata(&part) {
            if part_source(ctx, &part).as_deref() == Some(source.as_str()) {
                offset = m.len();
            }
        }
    }
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(offset == 0)
        .open(&part)
        .map_err(|e| io_err(e, &part))?;
    if upload_id.is_some() {
        note_part(ctx, &part, Some(&source));
    }

    let (_, window) = stream_params(p);
    let ctl = Arc::new(Ctl { acked: AtomicU64::new(offset), wake: Notify::new(), cancelled: AtomicBool::new(false) });
    let (tx, mut rx) = mpsc::unbounded_channel::<Chunk>();
    let id = client.fs.open(Handle::Write(ctl.clone(), tx)).inspect_err(|_| {
        if upload_id.is_none() {
            let _ = std::fs::remove_file(&part);
        }
    })?;

    let client = client.clone();
    let ctx = Ctx { state_dir: ctx.state_dir.clone() };
    tokio::spawn(async move {
        let file = Arc::new(file);
        let mut written = offset;
        let mut last_ack = offset;
        let finish: Result<Value, FsError> = loop {
            let Some(chunk) = rx.recv().await else {
                // Cancelled or connection gone.
                break Err(err("cancelled", ""));
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
        match finish {
            Ok(entry) => {
                if upload_id.is_some() {
                    note_part(&ctx, &part, None);
                }
                client.event("fs.done", json!({"stream": id, "entry": entry}));
            }
            Err(e) => {
                // Keep a resumable part file unless the data itself was rejected.
                let keep = upload_id.is_some() && matches!(e.code, "cancelled" | "io_error" | "no_space");
                if !keep {
                    let _ = std::fs::remove_file(&part);
                    if upload_id.is_some() {
                        note_part(&ctx, &part, None);
                    }
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
    mode: Option<u32>,
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
    if let Some(m) = mode {
        std::fs::set_permissions(part, std::fs::Permissions::from_mode(m)).map_err(|e| io_err(e, part))?;
    }
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
