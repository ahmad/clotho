//! Everything that differs between macOS and Linux lives here (and in the per-OS files).
//!
//! Clients start the daemon on demand with `clothod start`; start at login (a LaunchAgent or a
//! systemd user unit running `clothod start`) is `clothod::service`.

use std::path::{Path, PathBuf};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as os;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as os;

/// `sockaddr_un.sun_path` is 104 bytes on macOS and 108 on Linux, NUL included.
#[cfg(target_os = "macos")]
pub const MAX_SOCKET_PATH: usize = 103;
#[cfg(not(target_os = "macos"))]
pub const MAX_SOCKET_PATH: usize = 107;

pub const OS_NAME: &str = if cfg!(target_os = "macos") { "macos" } else { "linux" };

fn uid() -> u32 {
    unsafe { libc::getuid() }
}

fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn home() -> PathBuf {
    env_dir("HOME").unwrap_or_else(|| PathBuf::from("/"))
}

/// Directory for sockets and locks: `$CLOTHOD_RUNTIME_DIR`, else `<per-user temp dir>/clothod`
/// on macOS, else `/tmp/clothod-<uid>` (always on Linux, see `linux::runtime_base`; on macOS
/// when the default would make socket paths too long).
pub fn runtime_dir() -> PathBuf {
    if let Some(dir) = env_dir("CLOTHOD_RUNTIME_DIR") {
        return dir;
    }
    let dir = os::runtime_base().map(|b| b.join("clothod"));
    match dir {
        // Leave room for the longest socket name ("clothod.sock" / "holder.sock").
        Some(d) if d.as_os_str().len() + "/clothod.sock".len() <= MAX_SOCKET_PATH => d,
        _ => PathBuf::from(format!("/tmp/clothod-{}", uid())),
    }
}

/// Socket paths longer than the OS allows fail deep inside bind/connect with an unhelpful
/// error, so check up front.
pub fn check_socket_path(path: &Path) -> Result<(), String> {
    let len = path.as_os_str().len();
    if len > MAX_SOCKET_PATH {
        return Err(format!(
            "socket path {} is {len} bytes; {OS_NAME} allows at most {MAX_SOCKET_PATH}. \
             Use a shorter runtime dir (CLOTHOD_RUNTIME_DIR or --runtime-dir).",
            path.display()
        ));
    }
    Ok(())
}

/// Where a daemon using `runtime_dir` writes its logs: `$CLOTHOD_STATE_DIR`, else the runtime
/// dir itself when it is not the default (so isolated instances don't share logs), else
/// [`state_dir`].
pub fn log_dir(runtime_dir: &Path) -> PathBuf {
    if let Some(dir) = env_dir("CLOTHOD_STATE_DIR") {
        return dir;
    }
    let default = {
        // The default as if CLOTHOD_RUNTIME_DIR were unset.
        let base = os::runtime_base().map(|b| b.join("clothod"));
        match base {
            Some(d) if d.as_os_str().len() + "/clothod.sock".len() <= MAX_SOCKET_PATH => d,
            _ => PathBuf::from(format!("/tmp/clothod-{}", uid())),
        }
    };
    if runtime_dir != default {
        return runtime_dir.to_path_buf();
    }
    state_dir()
}

/// The runtime dir a daemon uses when nothing overrides it (`$CLOTHOD_RUNTIME_DIR` ignored):
/// the machine's one real instance.
pub fn default_runtime_dir() -> PathBuf {
    let dir = os::runtime_base().map(|b| b.join("clothod"));
    match dir {
        Some(d) if d.as_os_str().len() + "/clothod.sock".len() <= MAX_SOCKET_PATH => d,
        _ => PathBuf::from(format!("/tmp/clothod-{}", uid())),
    }
}

/// Directory for logs and other persistent state.
pub fn state_dir() -> PathBuf {
    if let Some(dir) = env_dir("CLOTHOD_STATE_DIR") {
        return dir;
    }
    os::state_base().join("clothod")
}

/// Create `dir` (and parents) and make it private to this user. Refuses a directory (or
/// symlink) owned by someone else, which matters for `/tmp/clothod-<uid>`.
pub fn ensure_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    std::fs::create_dir_all(dir)?;
    let meta = std::fs::symlink_metadata(dir)?;
    if !meta.is_dir() || meta.uid() != uid() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("{} is not a directory owned by uid {}; refusing to use it", dir.display(), uid()),
        ));
    }
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

/// Base directory for installed daemon binaries: `<base>/<version>-<hash>/clothod`.
/// `~/Library/Application Support/clothod/bin` on macOS, `~/.local/share/clothod/bin` on Linux.
pub fn install_base() -> PathBuf {
    if let Some(dir) = env_dir("CLOTHOD_INSTALL_DIR") {
        return dir;
    }
    os::data_base().join("clothod").join("bin")
}

/// Executable path of a running process.
pub fn process_exe(pid: u32) -> Option<PathBuf> {
    os::process_exe(pid)
}

/// Current working directory of a process (fallback when the shell sends no OSC 7).
pub fn process_cwd(pid: u32) -> Option<PathBuf> {
    os::process_cwd(pid)
}

pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return String::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// uid of the process on the other end of a Unix socket.
pub fn peer_uid(fd: std::os::fd::RawFd) -> Option<u32> {
    os::peer_uid(fd)
}

pub fn current_uid() -> u32 {
    uid()
}

pub(crate) fn default_home() -> PathBuf {
    home()
}

/// True when the session manager kills a user's processes at logout and a systemd user unit is
/// the way out (Linux, `KillUserProcesses=yes`, `systemd-run` available).
pub fn needs_systemd_unit() -> bool {
    os::kill_user_processes() == Some(true) && os::have_systemd_run()
}

/// Why sessions might not survive logout, if they might not.
pub fn session_survival_warning() -> Option<String> {
    if os::kill_user_processes() != Some(true) {
        return None;
    }
    if !os::have_systemd_run() {
        return Some("logind kills user processes at logout (KillUserProcesses=yes) and systemd-run is missing; \
                     shells end when you log out".into());
    }
    if os::linger() != Some(true) {
        return Some(format!(
            "logind kills user processes at logout (KillUserProcesses=yes) and lingering is off, so the \
             systemd user manager (and clothod with it) stops when your last session ends. Run \
             `loginctl enable-linger {}` to keep shells across logouts.",
            std::env::var("USER").unwrap_or_default()
        ));
    }
    None
}

/// What is running in the foreground of a pane's terminal: `pid` is the pane's first process
/// (its session leader).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Foreground {
    /// Foreground process group of the terminal.
    pub pgrp: u32,
    /// Names that identify it: executable and argv[0..2] basenames (for `node .../claude`).
    pub names: Vec<String>,
}

pub fn foreground(pid: u32) -> Option<Foreground> {
    let pgrp = os::terminal_pgrp(pid)?;
    let mut names = Vec::new();
    if let Some(exe) = os::process_exe(pgrp) {
        names.extend(exe.file_name().map(|n| n.to_string_lossy().into_owned()));
    }
    names.extend(os::process_name(pgrp));
    for a in os::process_args(pgrp).into_iter().take(2) {
        if let Some(n) = Path::new(&a).file_name() {
            names.push(n.to_string_lossy().into_owned());
        }
    }
    names.dedup();
    Some(Foreground { pgrp, names })
}

pub fn process_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// Where each running daemon registers its socket (`<pid>` -> socket path), so `clothod report`
/// can find the daemon a pane belongs to when nothing in the pane's environment says.
/// `$CLOTHOD_REGISTRY_DIR` overrides it (tests).
pub fn registry_dir() -> PathBuf {
    env_dir("CLOTHOD_REGISTRY_DIR").unwrap_or_else(|| os::state_base().join("clothod").join("instances"))
}

/// True if `pid` runs in the session led by `leader` or descends from it: "this process is in
/// that pane".
pub fn process_in_session(pid: u32, leader: u32) -> bool {
    if unsafe { libc::getsid(pid as libc::pid_t) } == leader as libc::pid_t {
        return true;
    }
    let mut p = pid;
    for _ in 0..64 {
        if p == leader {
            return true;
        }
        match os::parent_pid(p) {
            Some(pp) if pp > 1 && pp != p => p = pp,
            _ => return false,
        }
    }
    false
}

/// A process of this user.
#[derive(Debug, Clone)]
pub struct ProcInfo {
    pub pid: u32,
    pub exe: Option<PathBuf>,
    pub args: Vec<String>,
    /// Start time, unix seconds.
    pub started: Option<u64>,
}

/// Every process owned by this user (for `clothod ps` and `install --prune`).
pub fn own_processes() -> Vec<ProcInfo> {
    os::own_processes(uid())
}

/// Install id of an executable: `<version>-<hash of its bytes>` (FNV-1a; identifies a build,
/// not a security measure). Builds of one version get different ids.
pub fn build_id(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    // Streamed: serve hashes its own executable at startup, and a debug build is >100 MB.
    let mut f = std::fs::File::open(path)?;
    let mut buf = vec![0u8; 256 << 10];
    let mut h: u64 = 0xcbf29ce484222325;
    loop {
        let n = match f.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        for &b in &buf[..n] {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
    }
    Ok(format!("{}-{:012x}", env!("CARGO_PKG_VERSION"), h >> 16))
}

/// How a non-default (temporary) instance ends itself. Set with `--ephemeral[=SECS|exit]`,
/// carried to child processes in `$CLOTHOD_EPHEMERAL`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ephemeral {
    /// Shut down after this long with no clients and no panes.
    Idle(std::time::Duration),
    /// Shut down when the last client disconnects.
    Exit,
}

pub const EPHEMERAL_DEFAULT_SECS: u64 = 600;

pub fn ephemeral() -> Option<Ephemeral> {
    let v = std::env::var("CLOTHOD_EPHEMERAL").ok().filter(|v| !v.is_empty())?;
    Some(match v.as_str() {
        "exit" => Ephemeral::Exit,
        "1" | "true" | "yes" => Ephemeral::Idle(std::time::Duration::from_secs(EPHEMERAL_DEFAULT_SECS)),
        n => Ephemeral::Idle(std::time::Duration::from_secs(n.parse().unwrap_or(EPHEMERAL_DEFAULT_SECS))),
    })
}

/// Only the default runtime dir may hold a persistent instance; anything else must be
/// ephemeral (one instance per machine).
pub fn check_instance_allowed(runtime_dir: &Path) -> Result<(), String> {
    if runtime_dir == default_runtime_dir() || ephemeral().is_some() {
        return Ok(());
    }
    Err(format!(
        "{} is not this machine's clothod instance ({}). Only the default instance is persistent; \
         a temporary one needs --ephemeral (or CLOTHOD_EPHEMERAL=SECS|exit).",
        runtime_dir.display(),
        default_runtime_dir().display()
    ))
}
