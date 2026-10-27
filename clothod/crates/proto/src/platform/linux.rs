use std::path::PathBuf;

/// Not `$XDG_RUNTIME_DIR`: it is unset in non-interactive SSH sessions (so a bridge and a login
/// shell would disagree on the socket path and start two daemons), and logind deletes it when
/// the user's last session ends unless lingering is on, which would orphan a daemon meant to
/// outlive the session. `runtime_dir` falls back to `/tmp/clothod-<uid>` (ownership checked).
pub fn runtime_base() -> Option<PathBuf> {
    None
}

pub fn state_base() -> PathBuf {
    super::env_dir("XDG_STATE_HOME").unwrap_or_else(|| super::default_home().join(".local/state"))
}

pub fn process_cwd(pid: u32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

pub fn peer_uid(fd: std::os::fd::RawFd) -> Option<u32> {
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_PEERCRED, (&mut cred as *mut libc::ucred).cast(), &mut len)
    };
    (rc == 0).then_some(cred.uid)
}

pub fn data_base() -> PathBuf {
    super::env_dir("XDG_DATA_HOME").unwrap_or_else(|| super::default_home().join(".local/share"))
}

pub fn process_exe(pid: u32) -> Option<PathBuf> {
    // A replaced binary shows up as "<path> (deleted)".
    let p = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let s = p.to_string_lossy();
    Some(PathBuf::from(s.strip_suffix(" (deleted)").unwrap_or(&s)))
}

fn command_output(cmd: &str, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(cmd).args(args).stderr(std::process::Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// logind's KillUserProcesses, if logind is there to ask.
pub fn kill_user_processes() -> Option<bool> {
    let v = command_output(
        "busctl",
        &["get-property", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "KillUserProcesses"],
    )?;
    Some(v.ends_with("true"))
}

pub fn have_systemd_run() -> bool {
    command_output("systemd-run", &["--version"]).is_some()
}

pub fn linger() -> Option<bool> {
    let user = std::env::var("USER").ok()?;
    let v = command_output("loginctl", &["show-user", &user, "-p", "Linger", "--value"])?;
    Some(v == "yes")
}

/// The terminal's foreground process group, from `tpgid` in /proc/<pid>/stat.
pub fn terminal_pgrp(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // Fields after the parenthesized comm: state ppid pgrp session tty_nr tpgid ...
    let rest = &stat[stat.rfind(')')? + 2..];
    let tpgid: i64 = rest.split_whitespace().nth(5)?.parse().ok()?;
    (tpgid > 0).then_some(tpgid as u32)
}

pub fn process_name(pid: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/comm")).ok().map(|s| s.trim().to_string())
}

pub fn process_args(pid: u32) -> Vec<String> {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|b| b.split(|&c| c == 0).filter(|a| !a.is_empty()).map(|a| String::from_utf8_lossy(a).into_owned()).collect())
        .unwrap_or_default()
}

pub fn parent_pid(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat[stat.rfind(')')? + 2..].split_whitespace().nth(1)?.parse().ok()
}

pub fn own_processes(uid: u32) -> Vec<super::ProcInfo> {
    use std::os::unix::fs::MetadataExt;
    let btime: Option<u64> = std::fs::read_to_string("/proc/stat")
        .ok()
        .and_then(|s| s.lines().find_map(|l| l.strip_prefix("btime ").and_then(|v| v.trim().parse().ok())));
    let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    let Ok(dir) = std::fs::read_dir("/proc") else { return Vec::new() };
    dir.flatten()
        .filter_map(|e| {
            let pid: u32 = e.file_name().to_str()?.parse().ok()?;
            if e.metadata().ok()?.uid() != uid {
                return None;
            }
            let started = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok().and_then(|s| {
                let rest = &s[s.rfind(')')? + 2..];
                let start: u64 = rest.split_whitespace().nth(19)?.parse().ok()?;
                Some(btime? + start / ticks)
            });
            Some(super::ProcInfo { pid, exe: process_exe(pid), args: process_args(pid), started })
        })
        .collect()
}
