//! Start at login (`clothod service install|uninstall|status`, and `service.*` requests): a
//! LaunchAgent on macOS, a systemd user unit on Linux.
//!
//! The unit is a trigger, not a supervisor. At login it runs `<install base>/current/clothod
//! start` once, which starts the daemon unless it already runs (then it exits 0, so a second
//! instance is impossible). Nothing restarts the daemon when it stops: no `KeepAlive`, no
//! `Restart=`. A restarter would fight `clothod upgrade`, which stops serve and starts the new
//! build, and stopping the unit must never stop the daemon either:
//! - macOS: `RunAtLoad`, `KeepAlive` false, `AbandonProcessGroup` (bootout leaves the daemon).
//! - Linux: `Type=oneshot`, `RemainAfterExit`, `KillMode=process` (stop and disable leave it).
//!   The unit file is a real file in a unit dir, never `systemctl link`ed: disabling a linked
//!   unit killed the processes it had started (systemd 255).
//!
//! Linux needs lingering: the user manager, and every process its units started (the daemon
//! included, `user@.service` has `KillMode=mixed`), stops when the user's last session ends.
//! Without lingering a daemon the unit started would die at logout, where one started on
//! demand by a client survives it (`KillUserProcesses=no`), so `install` refuses.
//!
//! `current` always names the installed build, so upgrades never need to rewrite the unit.

use std::path::{Path, PathBuf};
use std::process::Command;

use clotho_proto::platform;
use serde_json::{json, Value};

/// First line of every file we write; `uninstall` removes only files that start with it.
const MARKER: &str = "Written by `clothod service install`";

#[derive(Debug)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

fn error(code: &'static str, message: impl Into<String>) -> Error {
    Error { code, message: message.into() }
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Manager {
    Launchd,
    Systemd,
}

/// The login unit for the instance at `runtime_dir`.
#[derive(Debug)]
struct Unit {
    manager: Manager,
    /// launchd label, or systemd unit name without `.service`.
    label: String,
    file: PathBuf,
    /// The command it runs: `<install base>/current/clothod start [...]`.
    command: Vec<String>,
    env: Vec<(String, String)>,
    log: PathBuf,
}

pub fn default_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "nyc.amin.clotho.clothod"
    } else {
        "clothod"
    }
}

fn env_nonempty(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn unit(runtime_dir: &Path) -> Result<Unit> {
    let manager = if cfg!(target_os = "macos") { Manager::Launchd } else { Manager::Systemd };
    let default_instance = runtime_dir == platform::default_runtime_dir();
    // Tests: their own label, so they can never replace or remove the user's unit.
    let label = env_nonempty("CLOTHOD_SERVICE_LABEL").unwrap_or_else(|| default_label().to_string());
    if !default_instance && label == default_label() {
        return Err(error(
            "bad_request",
            format!("{} is not this machine's instance; a test instance needs its own CLOTHOD_SERVICE_LABEL", runtime_dir.display()),
        ));
    }
    if label.is_empty() || !label.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)) {
        return Err(error("bad_request", format!("bad service label `{label}`")));
    }
    let home = PathBuf::from(env_nonempty("HOME").ok_or_else(|| error("unsupported", "HOME is not set"))?);
    let dir = match env_nonempty("CLOTHOD_SERVICE_DIR") {
        Some(d) => PathBuf::from(d),
        None if manager == Manager::Launchd => home.join("Library/LaunchAgents"),
        None => env_nonempty("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config")).join("systemd/user"),
    };
    let file = dir.join(match manager {
        Manager::Launchd => format!("{label}.plist"),
        Manager::Systemd => format!("{label}.service"),
    });
    let exe = platform::install_base().join("current").join("clothod");
    let mut command = vec![exe.to_string_lossy().into_owned(), "start".into()];
    if !default_instance {
        command.extend(["--runtime-dir".into(), runtime_dir.to_string_lossy().into_owned()]);
    }
    // What makes this process's instance this instance, so the unit starts the same one (and,
    // for tests, a daemon it starts still manages the test's unit).
    let env = [
        "CLOTHOD_EPHEMERAL",
        "CLOTHOD_STATE_DIR",
        "CLOTHOD_CONFIG",
        "CLOTHOD_REGISTRY_DIR",
        "CLOTHOD_INSTALL_DIR",
        "CLOTHOD_SERVICE_LABEL",
        "CLOTHOD_SERVICE_DIR",
        "CLOTHOD_TEST_ASSUME_LINGER",
    ]
        .iter()
        .filter_map(|k| env_nonempty(k).map(|v| (k.to_string(), v)))
        .collect();
    let log = platform::log_dir(runtime_dir).join("service.log");
    Ok(Unit { manager, label, file, command, env, log })
}

// ---- file contents -----------------------------------------------------------------------

fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn plist(u: &Unit) -> String {
    let args: String = u.command.iter().map(|a| format!("\n    <string>{}</string>", xml(a))).collect();
    let env: String = u.env.iter().map(|(k, v)| format!("\n    <key>{}</key><string>{}</string>", xml(k), xml(v))).collect();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!-- {MARKER} (Start at login in the Clotho apps). It starts clothod at login unless it
     runs; it never restarts it. Remove it with `clothod service uninstall`. -->
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
"#,
        label = xml(&u.label),
        log = xml(&u.log.to_string_lossy()),
    )
}

/// One systemd word, quoted: `\` and `"` escaped, `%` and `$` doubled (specifiers, variables).
fn sd_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('%', "%%").replace('$', "$$"))
}

fn systemd_unit(u: &Unit) -> String {
    let exec: Vec<String> = u.command.iter().map(|a| sd_quote(a)).collect();
    let env: String = u.env.iter().map(|(k, v)| format!("Environment={}\n", sd_quote(&format!("{k}={v}")))).collect();
    format!(
        "# {MARKER} (Start at login in the Clotho apps).\n\
         # Remove it with `clothod service uninstall`.\n\
         [Unit]\n\
         Description=Clotho session daemon (clothod): start it at login unless it runs\n\
         \n\
         [Service]\n\
         # `clothod start` starts the daemon (or finds it running) and exits. The daemon must\n\
         # outlive this unit, and nothing may restart it: upgrades replace it in place.\n\
         Type=oneshot\n\
         RemainAfterExit=yes\n\
         KillMode=process\n\
         ExecStart={}\n\
         {env}\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        exec.join(" ")
    )
}

// ---- service managers ----------------------------------------------------------------------

fn run(cmd: &str, args: &[&str]) -> (bool, String) {
    let mut c = Command::new(cmd);
    c.args(args).stdin(std::process::Stdio::null());
    // `systemctl --user` finds the user manager through XDG_RUNTIME_DIR, which some SSH sessions
    // (and daemons started from them) lack.
    if cmd == "systemctl" && env_nonempty("XDG_RUNTIME_DIR").is_none() {
        let dir = format!("/run/user/{}", platform::current_uid());
        if Path::new(&dir).is_dir() {
            c.env("XDG_RUNTIME_DIR", dir);
        }
    }
    match c.output() {
        Ok(o) => {
            let mut text = String::from_utf8_lossy(&o.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&o.stderr));
            (o.status.success(), text.trim().to_string())
        }
        Err(e) => (false, format!("{cmd}: {e}")),
    }
}

fn gui_domain() -> String {
    format!("gui/{}", platform::current_uid())
}

fn systemctl(args: &[&str]) -> (bool, String) {
    let mut a = vec!["--user"];
    a.extend_from_slice(args);
    run("systemctl", &a)
}

/// Whether the manager currently has the unit (launchd: loaded; systemd: enabled).
fn loaded(u: &Unit) -> bool {
    match u.manager {
        Manager::Launchd => run("launchctl", &["print", &format!("{}/{}", gui_domain(), u.label)]).0,
        Manager::Systemd => systemctl(&["is-enabled", &format!("{}.service", u.label)]).1.lines().next() == Some("enabled"),
    }
}

fn linger() -> Option<bool> {
    if cfg!(target_os = "macos") {
        return None;
    }
    if env_nonempty("CLOTHOD_TEST_ASSUME_LINGER").is_some() {
        return Some(true);
    }
    let user = env_nonempty("USER").or_else(|| env_nonempty("LOGNAME"))?;
    let (ok, out) = run("loginctl", &["show-user", &user, "-p", "Linger", "--value"]);
    ok.then(|| out == "yes")
}

fn linger_message() -> String {
    let user = env_nonempty("USER").unwrap_or_else(|| "$USER".into());
    format!(
        "Start at login needs lingering on Linux: without it the systemd user manager stops when your last \
         session ends, and takes the daemon (and every shell) with it. Turn it on once with \
         `sudo loginctl enable-linger {user}`, then try again."
    )
}

/// Whether a unit can be managed here at all; the reason if not.
fn unavailable(u: &Unit) -> Option<String> {
    match u.manager {
        Manager::Launchd => None,
        Manager::Systemd => {
            let (ok, out) = systemctl(&["show-environment"]);
            (!ok).then(|| format!("no systemd user manager to talk to: {out}"))
        }
    }
}

fn ours(file: &Path) -> bool {
    std::fs::read_to_string(file).map(|t| t.contains(MARKER)).unwrap_or(false)
}

fn contents(u: &Unit) -> String {
    match u.manager {
        Manager::Launchd => plist(u),
        Manager::Systemd => systemd_unit(u),
    }
}

fn write_atomic(path: &Path, data: &str) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_file_name(format!(".{}.{}", path.file_name().unwrap_or_default().to_string_lossy(), std::process::id()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

// ---- the three operations ------------------------------------------------------------------

/// `installed`: the unit file is there (the daemon starts at the next login). `loaded`: the
/// service manager has it now. `up_to_date`: the file is what `install` would write now.
pub fn status(runtime_dir: &Path) -> Result<Value> {
    let u = unit(runtime_dir)?;
    let installed = u.file.is_file();
    let reason = unavailable(&u);
    let linger = linger();
    let mut needs = Vec::new();
    if linger == Some(false) {
        needs.push("linger");
    }
    Ok(json!({
        "supported": reason.is_none(),
        "manager": match u.manager { Manager::Launchd => "launchd", Manager::Systemd => "systemd" },
        "label": u.label,
        "file": u.file.to_string_lossy(),
        "installed": installed,
        "loaded": installed && reason.is_none() && loaded(&u),
        "up_to_date": installed && std::fs::read_to_string(&u.file).ok().as_deref() == Some(contents(&u).as_str()),
        "command": u.command,
        "linger": linger,
        "needs": needs,
        "message": reason.or_else(|| (linger == Some(false)).then(linger_message)),
    }))
}

/// Write the unit and register it. Idempotent: an installed unit is rewritten and reloaded.
/// Starting it now runs `clothod start`, which finds the daemon running (or starts it).
pub fn install(runtime_dir: &Path) -> Result<Value> {
    let u = unit(runtime_dir)?;
    if let Some(reason) = unavailable(&u) {
        return Err(error("unsupported", reason));
    }
    if u.manager == Manager::Systemd && linger() != Some(true) {
        return Err(error("needs_linger", linger_message()));
    }
    if !Path::new(&u.command[0]).is_file() {
        return Err(error("not_installed", format!("{} does not exist; install clothod first (`clothod install`)", u.command[0])));
    }
    if u.file.exists() && !ours(&u.file) {
        return Err(error("conflict", format!("{} exists and was not written by clothod; not replacing it", u.file.display())));
    }
    if let Some(dir) = u.log.parent() {
        let _ = platform::ensure_private_dir(dir);
    }
    write_atomic(&u.file, &contents(&u)).map_err(|e| error("service_failed", format!("{}: {e}", u.file.display())))?;
    let undo = |u: &Unit, why: String| -> Error {
        let _ = remove(u);
        error("service_failed", why)
    };
    match u.manager {
        Manager::Launchd => {
            let target = format!("{}/{}", gui_domain(), u.label);
            // Reload: bootstrap refuses a label that is already loaded.
            let _ = run("launchctl", &["bootout", &target]);
            // A label the user disabled (`launchctl disable`) won't load; this is the user
            // asking for it now. Only touch the override when there is one.
            let (_, disabled) = run("launchctl", &["print-disabled", &gui_domain()]);
            if disabled.lines().any(|l| l.contains(&format!("\"{}\"", u.label)) && l.contains("disabled")) {
                let _ = run("launchctl", &["enable", &target]);
            }
            let (ok, out) = run("launchctl", &["bootstrap", &gui_domain(), &u.file.to_string_lossy()]);
            if !ok {
                return Err(undo(&u, format!("launchctl bootstrap {}: {out}", gui_domain())));
            }
        }
        Manager::Systemd => {
            let name = format!("{}.service", u.label);
            let (ok, out) = systemctl(&["daemon-reload"]);
            if !ok {
                return Err(undo(&u, format!("systemctl --user daemon-reload: {out}")));
            }
            let (ok, out) = systemctl(&["enable", &name]);
            if !ok {
                return Err(undo(&u, format!("systemctl --user enable {name}: {out}")));
            }
            // Oneshot: returns once `clothod start` has finished.
            let (ok, out) = systemctl(&["start", &name]);
            if !ok {
                let (_, journal) = run("journalctl", &["--user", "-u", &name, "-n", "10", "--no-pager"]);
                return Err(undo(&u, format!("systemctl --user start {name}: {out}\n{journal}")));
            }
        }
    }
    status(runtime_dir)
}

/// Unregister and delete the unit. The daemon keeps running. Not installed is not an error.
pub fn uninstall(runtime_dir: &Path) -> Result<Value> {
    let u = unit(runtime_dir)?;
    if u.file.exists() && !ours(&u.file) {
        return Err(error("conflict", format!("{} was not written by clothod; not removing it", u.file.display())));
    }
    remove(&u).map_err(|e| error("service_failed", e))?;
    status(runtime_dir)
}

fn remove(u: &Unit) -> std::result::Result<(), String> {
    match u.manager {
        Manager::Launchd => {
            // Leaves the daemon: AbandonProcessGroup. "Not loaded" is fine.
            let _ = run("launchctl", &["bootout", &format!("{}/{}", gui_domain(), u.label)]);
        }
        Manager::Systemd => {
            let name = format!("{}.service", u.label);
            // Leaves the daemon: KillMode=process, and the unit's own process has exited.
            let _ = systemctl(&["disable", "--now", &name]);
        }
    }
    match std::fs::remove_file(&u.file) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("{}: {e}", u.file.display())),
    }
    if u.manager == Manager::Systemd {
        let _ = systemctl(&["daemon-reload"]);
        let _ = systemctl(&["reset-failed", &format!("{}.service", u.label)]);
    }
    Ok(())
}

/// `service.status|install|uninstall` (protocol) and `clothod service ...` (CLI).
pub fn request(runtime_dir: &Path, op: &str) -> Result<Value> {
    match op {
        "status" => status(runtime_dir),
        "install" => install(runtime_dir),
        "uninstall" => uninstall(runtime_dir),
        _ => Err(error("unknown_method", format!("unknown service operation `{op}`"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(manager: Manager) -> Unit {
        Unit {
            manager,
            label: "clt-x".into(),
            file: "/tmp/x".into(),
            command: vec!["/a b/cur rent/clothod".into(), "start".into()],
            env: vec![("CLOTHOD_CONFIG".into(), "/p/100%/$HOME/\"q\".toml".into())],
            log: "/l/<s>.log".into(),
        }
    }

    #[test]
    fn systemd_words_are_quoted() {
        let t = systemd_unit(&sample(Manager::Systemd));
        assert!(t.contains("ExecStart=\"/a b/cur rent/clothod\" \"start\"\n"), "{t}");
        assert!(t.contains("Environment=\"CLOTHOD_CONFIG=/p/100%%/$$HOME/\\\"q\\\".toml\"\n"), "{t}");
        assert!(t.contains("KillMode=process") && t.contains("Type=oneshot") && !t.contains("Restart="), "{t}");
        assert!(t.contains(MARKER));
    }

    #[test]
    fn plist_escapes_and_never_keeps_alive() {
        let t = plist(&sample(Manager::Launchd));
        assert!(t.contains("<string>/l/&lt;s&gt;.log</string>"), "{t}");
        assert!(t.contains("<key>KeepAlive</key><false/>") && t.contains("<key>AbandonProcessGroup</key><true/>"), "{t}");
        assert!(t.contains(MARKER));
    }
}
