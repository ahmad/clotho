//! clothod, the Clotho session daemon. One binary, two processes: `clothod holder` owns the PTYs
//! (crate `clotho-holder`) and `clothod serve` is the logic daemon (this crate).

pub mod agents;
pub mod config;
pub mod daemon;
pub(crate) mod fs;
pub mod push;
pub mod model;

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
