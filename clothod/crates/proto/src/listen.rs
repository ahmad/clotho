//! A Unix socket listener that survives temp cleaners.
//!
//! The runtime dir lives under /tmp (Linux) or the per-user temp dir (macOS), and both get
//! pruned by age: systemd-tmpfiles after ~10 days, macOS after ~3 days without access. A daemon
//! idle that long would lose its socket, and the next client would start a second daemon and
//! orphan the first one's shells. So the listener:
//! - touches the dir, the socket and its companion files every hour, so age-based cleaners
//!   skip them;
//! - every 10 s, and at once on SIGUSR1, checks that the socket path is still its socket, and
//!   if the path is gone, recreates the dir and rebinds, rewriting the pid file and re-taking
//!   the lock.
//!
//! `clothod start` sends SIGUSR1 to a live instance instead of starting a second one. It finds
//! it through `<name>.live` in the state dir, which cleaners don't touch. Only builds that
//! handle SIGUSR1 write that file, so an older build is never signalled.

use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use tokio::net::{UnixListener, UnixStream};

use crate::platform;

const CHECK_EVERY: Duration = Duration::from_secs(10);
const TOUCH_EVERY: Duration = Duration::from_secs(3600);

pub struct HealingListener {
    path: PathBuf,
    listener: UnixListener,
    ino: u64,
    /// `name.lock` next to the socket, held for the process's life.
    lock_path: PathBuf,
    _lock: Option<nix_lock::Lock>,
    /// Files to rewrite after the dir was recreated: (path, contents).
    files: Vec<(PathBuf, Vec<u8>)>,
    last_touch: Instant,
    usr1: Option<tokio::signal::unix::Signal>,
}

pub use nix_lock::Lock;

/// Take `path`'s exclusive lock, failing at once if another process holds it.
pub fn lock(path: &Path) -> io::Result<Lock> {
    if let Some(d) = path.parent() {
        platform::ensure_private_dir(d)?;
    }
    nix_lock::try_lock(path).map_err(|e| io::Error::new(io::ErrorKind::AddrInUse, format!("{} is held by another process ({e})", path.display())))
}

/// Exclusive non-blocking flock without pulling nix into this crate.
mod nix_lock {
    use std::fs::File;
    use std::os::fd::AsRawFd;

    /// An exclusive flock on a file, held until dropped.
    pub struct Lock(pub(super) File);

    pub fn try_lock(path: &std::path::Path) -> std::io::Result<Lock> {
        let f = File::create(path)?;
        if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Lock(f))
    }
}

/// Set atime and mtime of `path` to now (works for sockets and directories too).
pub fn touch(path: &Path) {
    if let Ok(c) = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()) {
        unsafe {
            libc::utimensat(libc::AT_FDCWD, c.as_ptr(), std::ptr::null(), 0);
        }
    }
}

impl HealingListener {
    /// Take `lock_path` (failing if another process holds it), bind `path`, and write `files`.
    pub fn bind(path: &Path, lock_path: &Path, files: Vec<(PathBuf, Vec<u8>)>) -> io::Result<HealingListener> {
        let lock = lock(lock_path)?;
        HealingListener::bind_locked(path, lock_path, lock, files)
    }

    /// Like [`HealingListener::bind`], with the lock already taken (so a process can hold it
    /// before it is ready to accept connections).
    pub fn bind_locked(path: &Path, lock_path: &Path, lock: Lock, files: Vec<(PathBuf, Vec<u8>)>) -> io::Result<HealingListener> {
        let dir = path.parent().unwrap_or(Path::new("/"));
        platform::ensure_private_dir(dir)?;
        // The handler must exist before the pid files that invite SIGUSR1 do (its default
        // action would kill us).
        let usr1 = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::user_defined1()).ok();
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        let ino = std::fs::symlink_metadata(path)?.ino();
        for (p, data) in &files {
            if let Some(d) = p.parent() {
                let _ = platform::ensure_private_dir(d);
            }
            let _ = std::fs::write(p, data);
        }
        Ok(HealingListener {
            path: path.to_path_buf(),
            listener,
            ino,
            lock_path: lock_path.to_path_buf(),
            _lock: Some(lock),
            files,
            last_touch: Instant::now(),
            usr1,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The listening socket's fd and the lock file's fd (to hand over across `execve`).
    pub fn fds(&self) -> (std::os::fd::RawFd, Option<std::os::fd::RawFd>) {
        use std::os::fd::AsRawFd;
        (self.listener.as_raw_fd(), self._lock.as_ref().map(|l| l.0.as_raw_fd()))
    }

    /// Take over a listener (and lock) inherited across `execve` from a previous process
    /// image, with the files it maintains.
    ///
    /// # Safety
    /// `listener_fd` must be a listening Unix socket and `lock_fd` (if any) an open file this
    /// process now owns; nothing else may use or close them.
    pub unsafe fn from_inherited(
        path: &Path,
        lock_path: &Path,
        listener_fd: std::os::fd::RawFd,
        lock_fd: Option<std::os::fd::RawFd>,
        files: Vec<(PathBuf, Vec<u8>)>,
    ) -> io::Result<HealingListener> {
        use std::os::fd::FromRawFd;
        let usr1 = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::user_defined1()).ok();
        let std_listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(listener_fd) };
        std_listener.set_nonblocking(true)?;
        let listener = UnixListener::from_std(std_listener)?;
        // The socket's path inode, if the path still exists (otherwise `maintain` rebinds).
        let ino = std::fs::symlink_metadata(path).map(|m| m.ino()).unwrap_or(0);
        let lock = lock_fd.map(|fd| nix_lock::Lock(unsafe { std::fs::File::from_raw_fd(fd) }));
        for (p, data) in &files {
            let _ = std::fs::write(p, data);
        }
        Ok(HealingListener {
            path: path.to_path_buf(),
            listener,
            ino,
            lock_path: lock_path.to_path_buf(),
            _lock: lock,
            files,
            last_touch: Instant::now(),
            usr1,
        })
    }

    /// Stop listening and remove the socket and our files, but only where they are still ours:
    /// a successor may already have bound the same path.
    pub fn close(self) {
        let still_ours = std::fs::symlink_metadata(&self.path).map(|m| m.ino() == self.ino).unwrap_or(false);
        drop(self.listener);
        if still_ours {
            let _ = std::fs::remove_file(&self.path);
        }
        for (p, data) in &self.files {
            if std::fs::read(p).ok().as_deref() == Some(data.as_slice()) {
                let _ = std::fs::remove_file(p);
            }
        }
    }

    pub async fn accept(&mut self) -> io::Result<UnixStream> {
        loop {
            let usr1 = async {
                match self.usr1.as_mut() {
                    Some(s) => {
                        s.recv().await;
                    }
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                r = self.listener.accept() => return r.map(|(s, _)| s),
                _ = tokio::time::sleep(CHECK_EVERY) => self.maintain(),
                _ = usr1 => self.maintain(),
            }
        }
    }

    /// Rebind if the socket path is gone; touch everything now and then.
    pub fn maintain(&mut self) {
        let ours = std::fs::symlink_metadata(&self.path).map(|m| m.ino() == self.ino);
        match ours {
            Ok(true) => {}
            Ok(false) => {
                // Something else is bound there. Another instance? Don't fight over it.
                eprintln!("clothod: {} is no longer our socket; leaving it alone", self.path.display());
            }
            Err(_) => {
                if let Err(e) = self.rebind() {
                    eprintln!("clothod: rebinding {}: {e}", self.path.display());
                } else {
                    eprintln!("clothod: {} was deleted; rebound it", self.path.display());
                }
            }
        }
        if self.last_touch.elapsed() >= TOUCH_EVERY {
            self.touch_all();
        }
    }

    fn rebind(&mut self) -> io::Result<()> {
        let dir = self.path.parent().unwrap_or(Path::new("/")).to_path_buf();
        platform::ensure_private_dir(&dir)?;
        // The old lock file went with the dir; take a fresh one so a racing `serve` still sees
        // it held.
        if !self.lock_path.exists() {
            self._lock = nix_lock::try_lock(&self.lock_path).ok();
        }
        let listener = UnixListener::bind(&self.path)?;
        self.ino = std::fs::symlink_metadata(&self.path)?.ino();
        self.listener = listener;
        for (p, data) in &self.files {
            if !p.exists() {
                let _ = std::fs::write(p, data);
            }
        }
        self.touch_all();
        Ok(())
    }

    fn touch_all(&mut self) {
        self.last_touch = Instant::now();
        if let Some(dir) = self.path.parent() {
            touch(dir);
        }
        touch(&self.path);
        touch(&self.lock_path);
        for (p, _) in &self.files {
            touch(p);
        }
    }
}

/// A live process recorded in `pid_file`, if it is a clothod (and not us).
pub fn live_instance(pid_file: &Path) -> Option<u32> {
    let pid: u32 = std::fs::read_to_string(pid_file).ok()?.trim().parse().ok()?;
    if pid == std::process::id() || unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
        return None;
    }
    let exe = platform::process_exe(pid)?;
    let name = exe.file_name()?.to_string_lossy().into_owned();
    // Installed builds are named clothod; tests and dev builds may differ only in directory.
    name.starts_with("clothod").then_some(pid)
}

/// Ask a live instance to check (and rebind) its socket now.
pub fn poke(pid: u32) {
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGUSR1);
    }
}
