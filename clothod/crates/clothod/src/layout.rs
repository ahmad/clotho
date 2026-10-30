//! The saved layout: workspaces, tabs, split trees and each pane's cwd (and agent session), kept
//! in a file in the user's data dir so a reboot (or a holder that died) can bring them back.
//! The holder keeps the live state across serve restarts and upgrades; this file only matters
//! when a serve starts a fresh holder (docs/protocol.md, "Restore after restart").

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::Model;
use clotho_proto::platform;

/// The file's format. A newer one (a downgrade) is left alone and not restored.
pub const VERSION: u32 = 1;

/// Where the layout lives, or `None` when this instance keeps none: ephemeral (test)
/// instances never read or write one, unless `$CLOTHOD_LAYOUT_FILE` names a file (tests).
pub fn path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("CLOTHOD_LAYOUT_FILE").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    if platform::ephemeral().is_some() {
        return None;
    }
    Some(platform::state_dir().join("layout.json"))
}

/// The layout file `clothod shutdown --forget` may delete for the instance in `runtime_dir`: one
/// that instance owns. A file named by `$CLOTHOD_LAYOUT_FILE` (tests name their own), else the
/// user's file only when `runtime_dir` is the machine's default instance and this isn't an
/// ephemeral run. A test instance's dir never reaches the user's layout.
pub fn owned_path(runtime_dir: &Path) -> Option<PathBuf> {
    forget_target(
        runtime_dir,
        &platform::default_runtime_dir(),
        std::env::var_os("CLOTHOD_LAYOUT_FILE").filter(|p| !p.is_empty()).map(PathBuf::from),
        platform::ephemeral().is_some(),
        platform::state_dir(),
    )
}

fn forget_target(runtime_dir: &Path, default: &Path, explicit: Option<PathBuf>, ephemeral: bool, state_dir: PathBuf) -> Option<PathBuf> {
    if explicit.is_some() {
        return explicit;
    }
    (runtime_dir == default && !ephemeral).then(|| state_dir.join("layout.json"))
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Saved {
    pub version: u32,
    /// Whose layout this is: the machine and the runtime dir of the instance that wrote it.
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub runtime_dir: String,
    #[serde(default)]
    pub saved_at: f64,
    #[serde(default)]
    pub model: Model,
    /// By pane id (as in `model`).
    #[serde(default)]
    pub panes: HashMap<String, SavedPane>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct SavedPane {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub command: Vec<String>,
    #[serde(default)]
    pub cols: u16,
    #[serde(default)]
    pub rows: u16,
    /// The agent the pane ran and its session, to resume.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<SavedAgent>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct SavedAgent {
    pub kind: String,
    /// None when no session was known (since 0.1.25): the agent may be continued instead
    /// (`continue_line`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

#[derive(Debug, PartialEq)]
pub enum Loaded {
    Missing,
    /// Written by another machine or instance, or by a newer clothod: not restored.
    NotOurs(String),
    /// Unreadable: moved aside to this path.
    Corrupt(PathBuf),
    Ok(Saved),
}

/// Read the layout at `path` if it belongs to the instance in `runtime_dir` on `host`. A file that
/// doesn't parse is moved aside (`<name>.corrupt-<unix secs>`) so it is neither read again nor
/// overwritten unseen.
pub fn load(path: &Path, host: &str, runtime_dir: &Path) -> Loaded {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Loaded::Missing,
        Err(_) => return aside(path),
    };
    let saved: Saved = match serde_json::from_slice::<Value>(&bytes).ok().and_then(migrate).and_then(|v| serde_json::from_value(v).ok()) {
        Some(s) => s,
        None => return aside(path),
    };
    if saved.version > VERSION {
        return Loaded::NotOurs(format!("format {} is newer than {VERSION}", saved.version));
    }
    if saved.host != host || saved.runtime_dir != runtime_dir.to_string_lossy() {
        return Loaded::NotOurs(format!("written by {} for {}", saved.host, saved.runtime_dir));
    }
    Loaded::Ok(saved)
}

/// Bring an older file up to the current format. (Version 1 is the first: a file without a
/// version is not one of ours.)
fn migrate(v: Value) -> Option<Value> {
    match v.get("version").and_then(Value::as_u64) {
        Some(_) if v.is_object() => Some(v),
        _ => None,
    }
}

fn aside(path: &Path) -> Loaded {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(format!(".corrupt-{secs}"));
    let to = path.with_file_name(name);
    let _ = std::fs::rename(path, &to);
    Loaded::Corrupt(to)
}

/// Write `text` to `path` atomically: a private temp file next to it, synced, renamed over it.
pub fn write(path: &Path, text: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        platform::ensure_private_dir(dir)?;
    }
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(format!(".tmp-{}", std::process::id()));
    let tmp = path.with_file_name(name);
    let res = (|| {
        let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if res.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    res
}

/// Remove the layout file (`clothod shutdown --forget`).
pub fn forget(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// A session id safe to type into a shell: what Claude Code and Codex use (UUIDs). It starts
/// with a letter or digit, so it can never read as a flag (`--dangerously-skip-permissions`).
/// Ids that fail this are never stored (agents::report, the daemon's agent.report).
pub fn safe_session(s: &str) -> bool {
    s.len() <= 128
        && s.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The line that resumes `agent` in a shell, if it is one we know how to resume.
pub fn resume_line(agent: &SavedAgent) -> Option<String> {
    let session = agent.session.as_deref().filter(|s| safe_session(s))?;
    match agent.kind.as_str() {
        // Bound to its flag (`--resume` takes an optional value), and after `--` for Codex: the
        // id is never parsed as anything but the session.
        "claude" => Some(format!("claude --resume={session}\r")),
        "codex" => Some(format!("codex resume -- {session}\r")),
        _ => None,
    }
}

/// The line that continues the latest conversation of an agent of `kind` in the shell's cwd,
/// for an agent whose session wasn't known. Only used where that is unambiguous (the daemon's
/// restore decides).
pub fn continue_line(kind: &str) -> Option<&'static str> {
    match kind {
        "claude" => Some("claude --continue\r"),
        "codex" => Some("codex resume --last\r"),
        _ => None,
    }
}

/// Whether `command` runs a shell (one we can type a resume line into).
pub fn is_shell(command: &[String]) -> bool {
    let Some(first) = command.first() else { return false };
    let name = Path::new(first).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let name = name.trim_start_matches('-');
    ["sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh"].contains(&name)
}

#[cfg(test)]
mod tests {
    #[test]
    fn forget_only_deletes_the_targets_own_layout() {
        use std::path::{Path, PathBuf};
        let (def, test, state) = (Path::new("/rt/clothod"), Path::new("/tmp/clt-x/rt"), PathBuf::from("/home/u/.local/state/clothod"));
        let mine = Some(PathBuf::from("/home/u/.local/state/clothod/layout.json"));
        assert_eq!(super::forget_target(def, def, None, false, state.clone()), mine, "the default instance forgets the user's layout");
        assert_eq!(super::forget_target(test, def, None, false, state.clone()), None, "a test dir never reaches it");
        assert_eq!(super::forget_target(def, def, None, true, state.clone()), None, "nor an ephemeral run");
        let own = Some(PathBuf::from("/tmp/clt-x/layout.json"));
        assert_eq!(super::forget_target(test, def, own.clone(), true, state), own, "a file the test named");
    }

    use super::*;
    use crate::model::Direction;

    fn sample() -> Saved {
        let mut m = Model::default();
        let (ws, _) = m.create_workspace(Some("alpha".into()), 1);
        m.split(1, 2, Direction::Right, 0.3);
        let tab = m.create_tab(ws, 3).unwrap();
        m.rename_tab(tab, Some("logs".into()));
        let mut panes = HashMap::new();
        panes.insert("1".into(), SavedPane { cwd: Some("/tmp".into()), command: vec!["/bin/zsh".into(), "-l".into()], cols: 80, rows: 24, agent: Some(SavedAgent { kind: "claude".into(), session: Some("abc-123".into()) }) });
        panes.insert("2".into(), SavedPane { cwd: None, command: vec![], cols: 80, rows: 24, agent: None });
        Saved { version: VERSION, host: "h".into(), runtime_dir: "/run/x".into(), saved_at: 1.0, model: m, panes }
    }

    #[test]
    fn saves_and_loads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/layout.json");
        let s = sample();
        write(&path, &serde_json::to_string(&s).unwrap()).unwrap();
        assert_eq!(load(&path, "h", Path::new("/run/x")), Loaded::Ok(s));
        // Nothing left over from the atomic write.
        assert_eq!(std::fs::read_dir(path.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn missing_file() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(&dir.path().join("layout.json"), "h", Path::new("/r")), Loaded::Missing);
    }

    #[test]
    fn corrupt_files_are_moved_aside() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("layout.json");
        for bad in ["{not json", "[]", "{\"model\": {}}", "{\"version\": 1, \"model\": 7}"] {
            std::fs::write(&path, bad).unwrap();
            let Loaded::Corrupt(to) = load(&path, "h", Path::new("/r")) else { panic!("{bad} not corrupt") };
            assert!(!path.exists(), "{bad}");
            assert_eq!(std::fs::read_to_string(&to).unwrap(), bad);
            std::fs::remove_file(to).unwrap();
        }
    }

    #[test]
    fn other_instances_and_newer_formats_are_not_restored() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("layout.json");
        write(&path, &serde_json::to_string(&sample()).unwrap()).unwrap();
        assert!(matches!(load(&path, "other", Path::new("/run/x")), Loaded::NotOurs(_)));
        assert!(matches!(load(&path, "h", Path::new("/run/y")), Loaded::NotOurs(_)));
        let mut newer = sample();
        newer.version = VERSION + 1;
        write(&path, &serde_json::to_string(&newer).unwrap()).unwrap();
        assert!(matches!(load(&path, "h", Path::new("/run/x")), Loaded::NotOurs(_)));
        // Left in place, not moved aside.
        assert!(path.exists());
    }

    #[test]
    fn a_minimal_version_1_file_loads() {
        // The fields after `version` were all optional from the start: an old or hand-trimmed
        // file still restores what it has.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("layout.json");
        let text = r#"{"version": 1, "host": "h", "runtime_dir": "/r",
            "model": {"next_id": 3, "workspaces": [{"id": 1, "name": "w", "tabs": [{"id": 2, "title": null, "active_pane": 5, "layout": {"type": "pane", "pane": 5}}]}], "focus": {}},
            "panes": {"5": {}}}"#;
        std::fs::write(&path, text).unwrap();
        let Loaded::Ok(s) = load(&path, "h", Path::new("/r")) else { panic!() };
        assert_eq!(s.model.panes(), vec![5]);
        assert_eq!(s.panes["5"], SavedPane::default());
    }

    #[test]
    fn resume_lines() {
        let a = |k: &str, s: &str| SavedAgent { kind: k.into(), session: Some(s.into()) };
        assert_eq!(resume_line(&SavedAgent { kind: "claude".into(), session: None }), None);
        assert_eq!(continue_line("claude"), Some("claude --continue\r"));
        assert_eq!(continue_line("codex"), Some("codex resume --last\r"));
        assert_eq!(continue_line("other"), None);
        assert_eq!(resume_line(&a("claude", "24e0052b-aa")).as_deref(), Some("claude --resume=24e0052b-aa\r"));
        assert_eq!(resume_line(&a("codex", "0199a-b")).as_deref(), Some("codex resume -- 0199a-b\r"));
        assert_eq!(resume_line(&a("other", "x")), None);
        for bad in ["", "a b", "x;rm -rf ~", "$(id)", "a\rb", &"x".repeat(129), "--dangerously-skip-permissions", "-c", "-", "_x", "--"] {
            assert_eq!(resume_line(&a("claude", bad)), None, "{bad:?}");
        }
        assert!(is_shell(&["/bin/zsh".into(), "-l".into()]) && is_shell(&["-bash".into()]) && is_shell(&["fish".into()]));
        assert!(!is_shell(&["claude".into()]) && !is_shell(&[]));
    }
}
