//! clothod, the Clotho session daemon. One binary, two processes: `clothod holder` owns the PTYs
//! (crate `clotho-holder`) and `clothod serve` is the logic daemon (this crate).

pub mod agents;
pub mod alloc;
pub mod config;
pub mod daemon;
pub mod fs;
pub mod push;
pub mod service;
pub mod summary;
pub mod git;
pub mod launchd;
pub mod layout;
pub mod model;

use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

/// Make `cmd` start in its own session with stdin closed and output appended to `log`, so it
/// survives its parent and the parent's terminal.
pub fn detach(cmd: &mut Command, log: std::fs::File) -> std::io::Result<()> {
    cmd.stdin(Stdio::null()).stdout(Stdio::from(log.try_clone()?)).stderr(Stdio::from(log));
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(())
}

/// A command for starting the daemon so it survives the end of the login session that started
/// it (an SSH session, typically).
///
/// `setsid` (see [`detach`]) is enough on macOS and on Linux with logind's default
/// `KillUserProcesses=no`. With `KillUserProcesses=yes`, logind kills everything in the
/// session's scope at logout, so the daemon is started as a transient systemd user unit
/// instead, outside the session. That only outlives the session if lingering is enabled for the
/// user; [`clotho_proto::platform::session_survival_warning`] says so when it isn't.
pub fn session_independent_command(exe: &std::path::Path) -> Command {
    if clotho_proto::platform::needs_systemd_unit() {
        let mut cmd = Command::new("systemd-run");
        cmd.args(["--user", "--collect", "--quiet", "-p", "KillMode=process", "--"]).arg(exe);
        return cmd;
    }
    Command::new(exe)
}

/// Replace `path` with `data` atomically (a reader sees the old file or the new one), keeping
/// the old file's permissions: a user's 0600 config must not come back world-readable. A new
/// file gets 0644 less the umask. The temp file is created exclusively, never through a link.
pub fn write_atomic(path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let dir = path.parent().unwrap_or(std::path::Path::new("."));
    std::fs::create_dir_all(dir)?;
    let mode = std::fs::metadata(path).map(|m| m.mode() & 0o7777).ok();
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let tmp = dir.join(format!(".{name}.clotho-tmp-{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let result = (|| {
        let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
        let m = mode.unwrap_or(0o644 & !crate::fs::umask());
        f.set_permissions(std::fs::Permissions::from_mode(m))?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    /// Rewriting a private file (config.toml, ~/.claude/settings.json) keeps it private.
    #[test]
    fn write_atomic_keeps_the_files_mode() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("settings.json");
        std::fs::write(&p, "{}").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
        super::write_atomic(&p, b"{\"a\":1}").unwrap();
        assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "{\"a\":1}");
        let new = dir.path().join("new.toml");
        super::write_atomic(&new, b"x").unwrap();
        assert_eq!(std::fs::metadata(&new).unwrap().permissions().mode() & 0o777, 0o644 & !crate::fs::umask());
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2, "no temp file left");
    }
}
