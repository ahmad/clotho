//! macOS: start serve in the user's durable launchd domain (`gui/<uid>`), never in an SSH
//! session's. A process started from SSH lives in that session's bootstrap namespace
//! ("Background"); once the namespace is torn down, everything in it loses the system services
//! reached through it: DNS, the user database (`id -un`), TLS trust, the keychain. serve, the
//! holder it spawns and every shell would inherit that, so `start` launches serve as a one-off
//! launchd job in `gui/<uid>` instead (docs/remote.md, "macOS sessions").

use std::path::{Path, PathBuf};
use std::process::Command;

use clotho_proto::platform;

pub use platform::launchd_namespace as namespace;

fn gui_domain() -> String {
    format!("gui/{}", platform::current_uid())
}

/// Whether the user's login session domain exists (someone is logged in at the console).
pub fn gui_domain_exists() -> bool {
    Command::new("/bin/launchctl").args(["print", &gui_domain()]).output().is_ok_and(|o| o.status.success())
}

/// What `start` should do on this machine: launch serve through launchd, or detach it as is.
pub enum Launch {
    /// Already in the login session (the app, the login unit): detach as usual.
    Direct,
    /// In an SSH session with a console login present: through a launchd job in `gui/<uid>`.
    Launchd,
    /// In an SSH session and nobody logged in at the console: no durable domain is reachable
    /// without root. Detach as usual, with this warning.
    Stuck(String),
}

pub fn how() -> Launch {
    if !cfg!(target_os = "macos") {
        return Launch::Direct;
    }
    match namespace().as_deref() {
        Some("Aqua") | None => Launch::Direct,
        Some(ns) if gui_domain_exists() => {
            let _ = ns;
            Launch::Launchd
        }
        Some(ns) => Launch::Stuck(format!(
            "starting from a {ns} session with nobody logged in at this Mac: clothod and its shells \
             stay in this session's launchd namespace, and lose DNS, the keychain and user lookups \
             if it is torn down. Log in at the Mac (or let the app start clothod) to avoid that."
        )),
    }
}

/// A label for one launch attempt: unique, and never the login unit's
/// (`nyc.amin.clotho.clothod`).
pub fn attempt_label() -> String {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("nyc.amin.clotho.clothod.start.{}.{t:x}", std::process::id())
}

/// The environment serve gets: what clothod and shells need from ours, never an SSH session's
/// own (SSH_AUTH_SOCK and the like die with it).
fn job_env() -> Vec<(String, String)> {
    let keep = |k: &str| {
        k.starts_with("CLOTHOD_")
            || k.starts_with("LC_")
            || ["PATH", "SHELL", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR"].contains(&k)
    };
    let mut env: Vec<(String, String)> = std::env::vars().filter(|(k, _)| keep(k)).collect();
    env.sort();
    env
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

pub fn plist(label: &str, args: &[String], env: &[(String, String)], log: &Path) -> String {
    let args: String = args.iter().map(|a| format!("\n    <string>{}</string>", xml(a))).collect();
    let env: String = env.iter().map(|(k, v)| format!("\n    <key>{}</key><string>{}</string>", xml(k), xml(v))).collect();
    let log = xml(&log.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!-- clothod serve, started by `clothod start` from an SSH session so that it runs in the
     login session's launchd domain. Not a login item: it runs once and is replaced next time. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array>{args}
  </array>
  <key>EnvironmentVariables</key>
  <dict>{env}
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"#
    )
}

/// A one-off launchd job in `gui/<uid>` that runs `exe spawn-serve --runtime-dir dir`: it
/// detaches serve (in the login session's namespace) and exits. Drop it once serve is up, or
/// the attempt failed: the job and its plist go, serve stays (`AbandonProcessGroup`, and serve
/// is in its own session), as with the login unit.
pub struct Job {
    label: String,
    plist: PathBuf,
}

impl Job {
    pub fn launch(exe: &Path, dir: &Path, log: &Path) -> std::io::Result<Job> {
        let label = attempt_label();
        let plist_path = platform::log_dir(dir).join(format!("{label}.plist"));
        let args = vec![exe.to_string_lossy().into_owned(), "spawn-serve".into(), "--runtime-dir".into(), dir.to_string_lossy().into_owned()];
        crate::write_atomic(&plist_path, plist(&label, &args, &job_env(), log).as_bytes())?;
        let job = Job { label, plist: plist_path };
        let out = Command::new("/bin/launchctl").args(["bootstrap", &gui_domain()]).arg(&job.plist).output()?;
        if !out.status.success() {
            return Err(std::io::Error::other(format!("launchctl bootstrap {}: {}", gui_domain(), String::from_utf8_lossy(&out.stderr).trim())));
        }
        Ok(job)
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        let _ = Command::new("/bin/launchctl").args(["bootout", &format!("{}/{}", gui_domain(), self.label)]).output();
        let _ = std::fs::remove_file(&self.plist);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plists_escape_and_never_keep_alive() {
        let p = plist("l", &["/a b/<x>".into(), "serve".into()], &[("K".into(), "v&\"w".into())], Path::new("/l&g"));
        assert!(p.contains("<string>/a b/&lt;x&gt;</string>") && p.contains("<key>K</key><string>v&amp;&quot;w</string>"), "{p}");
        assert!(p.contains("<key>KeepAlive</key><false/>") && p.contains("<key>AbandonProcessGroup</key><true/>"));
        assert!(p.contains("<string>/l&amp;g</string>"));
    }

    #[test]
    fn labels_are_unique_and_never_the_login_units() {
        let a = attempt_label();
        std::thread::sleep(std::time::Duration::from_millis(2));
        assert_ne!(a, attempt_label());
        assert!(a.starts_with("nyc.amin.clotho.clothod.start.") && a != "nyc.amin.clotho.clothod");
    }

    #[test]
    fn the_job_never_gets_an_ssh_sessions_environment() {
        std::env::set_var("SSH_AUTH_SOCK", "/tmp/agent.1");
        std::env::set_var("CLOTHOD_TEST_X", "1");
        let env = job_env();
        assert!(!env.iter().any(|(k, _)| k.starts_with("SSH_")));
        assert!(env.iter().any(|(k, v)| k == "CLOTHOD_TEST_X" && v == "1"));
        std::env::remove_var("CLOTHOD_TEST_X");
    }
}
