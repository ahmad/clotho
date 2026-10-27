//! `clothod report` (called by agent hooks) and `clothod hooks` (installs those hooks into the
//! agents' configuration). docs/protocol.md, "Agents".

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use clotho_proto::{platform, Frame};
use serde_json::{json, Map, Value};

/// Marks the hook entries `clothod hooks install` adds, so they can be found and removed.
const MARKER: &str = "# clotho-agent-status";
/// `$0` of the Codex notify wrapper; marks it as ours.
const CODEX_ARG0: &str = "clotho-notify";

/// `clothod report ...`: tell the daemon what the agent in this pane is doing. Hooks run this
/// on every agent event, so it is quick, never prints, and always "succeeds": outside clotho or
/// with no daemon it just does nothing.
pub fn report(args: &[String]) -> i32 {
    let _ = try_report(args);
    0
}

fn try_report(args: &[String]) -> Result<()> {
    let Some(pane) = std::env::var("CLOTHO_PANE").ok().and_then(|p| p.parse::<u64>().ok()) else { return Ok(()) };
    let mut state: Option<String> = None;
    let mut kind: Option<String> = None;
    let mut message: Option<String> = None;
    let mut session: Option<String> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--agent" => kind = it.next().cloned(),
            "--message" => message = it.next().cloned(),
            "--session" => session = it.next().cloned(),
            "--claude-hook" => {
                let mut input = String::new();
                std::io::stdin().take(1 << 20).read_to_string(&mut input)?;
                let v: Value = serde_json::from_str(&input)?;
                let s = match v["hook_event_name"].as_str().unwrap_or("") {
                    "SessionStart" => "starting",
                    "UserPromptSubmit" | "PreToolUse" | "PostToolUse" => "running",
                    "Notification" => "waiting",
                    "Stop" => "done",
                    "SessionEnd" => "clear",
                    _ => return Ok(()),
                };
                state = Some(s.into());
                kind = Some("claude".into());
                message = v["message"].as_str().map(String::from);
                session = v["session_id"].as_str().map(String::from);
            }
            "--codex-notify" => {
                let v: Value = serde_json::from_str(it.next().map(String::as_str).unwrap_or("{}"))?;
                if v["type"] != "agent-turn-complete" {
                    return Ok(());
                }
                state = Some("done".into());
                kind = Some("codex".into());
                message = v["last-assistant-message"].as_str().map(|m| m.chars().take(300).collect());
            }
            s if !s.starts_with("--") && state.is_none() => state = Some(s.into()),
            _ => {}
        }
    }
    let Some(state) = state else { return Ok(()) };
    let mut params = json!({"pane": pane, "state": state, "pid": std::process::id()});
    for (k, v) in [("kind", kind), ("message", message), ("session", session)] {
        if let Some(v) = v {
            params[k] = json!(v);
        }
    }
    // The pane's daemon: named by the pane's environment (newer holders), else the default
    // socket, else any registered daemon. Each checks `pid` is really in its pane and refuses
    // otherwise, so a pane id that exists in two daemons can't be reported to the wrong one.
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(s) = std::env::var_os("CLOTHOD_SOCKET").filter(|s| !s.is_empty()) {
        candidates.push(s.into());
    }
    candidates.push(platform::runtime_dir().join("clothod.sock"));
    if let Ok(entries) = std::fs::read_dir(platform::registry_dir()) {
        let mut registered: Vec<(u32, PathBuf)> = entries
            .flatten()
            .filter_map(|e| Some((e.file_name().to_str()?.parse().ok()?, PathBuf::from(std::fs::read_to_string(e.path()).ok()?.trim()))))
            .filter(|(pid, _)| platform::process_alive(*pid))
            .collect();
        registered.sort();
        candidates.extend(registered.into_iter().map(|(_, s)| s));
    }
    let mut seen = Vec::new();
    for sock in candidates {
        if seen.contains(&sock) {
            continue;
        }
        seen.push(sock.clone());
        if let Ok(true) = send_report(&sock, &params) {
            return Ok(());
        }
    }
    Ok(())
}

/// One attempt: Ok(true) if this daemon took the report.
fn send_report(socket: &Path, params: &Value) -> Result<bool> {
    let mut s = UnixStream::connect(socket)?;
    s.set_read_timeout(Some(Duration::from_millis(500)))?;
    s.set_write_timeout(Some(Duration::from_millis(500)))?;
    let hello = json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "clothod-report"}});
    let mut out = Frame::Json(hello).encode();
    out.extend(Frame::Json(json!({"id": 2, "method": "agent.report", "params": params})).encode());
    s.write_all(&out)?;
    // Wait for the reply: it says whether this was the right daemon, and keeps quick
    // successive hooks in order.
    loop {
        let mut len = [0u8; 4];
        s.read_exact(&mut len)?;
        let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
        s.read_exact(&mut body)?;
        if body.first() == Some(&clotho_proto::frame::T_JSON) {
            let v: Value = serde_json::from_slice(&body[1..])?;
            if v["id"] == 2 {
                return Ok(v.get("result").is_some());
            }
        }
    }
}

// ---- hooks ---------------------------------------------------------------------------------

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from).context("HOME is not set")
}

/// The command every hook runs: the newest installed clothod (`<base>/current`), only inside a
/// clotho pane, never failing. `$CLOTHOD_REPORT` overrides the binary (tests, dev builds).
fn report_command(args: &str) -> String {
    report_command_for(&platform::install_base().join("current").join("clothod"), args)
}

fn report_command_for(bin: &Path, args: &str) -> String {
    format!(
        r#"c=${{CLOTHOD_REPORT:-}}; [ -n "$c" ] || c={}; [ -n "$CLOTHO_PANE" ] && [ -x "$c" ] && "$c" report {args}; true {MARKER}"#,
        sh_quote(&bin.to_string_lossy())
    )
}

/// One shell word in single quotes: the install path is spliced into hook commands, and a home
/// directory may contain `"`, `$` or backquotes.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn claude_settings() -> Result<PathBuf> {
    Ok(home()?.join(".claude").join("settings.json"))
}

fn codex_config() -> Result<PathBuf> {
    Ok(home()?.join(".codex").join("config.toml"))
}

/// Claude Code events and their matcher (tool events need one).
const CLAUDE_EVENTS: [(&str, Option<&str>); 6] = [
    ("SessionStart", None),
    ("UserPromptSubmit", None),
    ("PreToolUse", Some("*")),
    ("Notification", None),
    ("Stop", None),
    ("SessionEnd", None),
];

fn claude_snippet() -> Value {
    let cmd = report_command("--claude-hook");
    let mut hooks = Map::new();
    for (event, matcher) in CLAUDE_EVENTS {
        let mut group = Map::new();
        if let Some(m) = matcher {
            group.insert("matcher".into(), json!(m));
        }
        group.insert("hooks".into(), json!([{"type": "command", "command": cmd}]));
        hooks.insert(event.into(), json!([Value::Object(group)]));
    }
    json!({"hooks": hooks})
}

fn codex_script() -> String {
    // Codex appends its JSON payload as the last argument. Any earlier arguments are the
    // user's own notify program, which runs after us with the payload.
    let bin = platform::install_base().join("current").join("clothod");
    format!(
        r#"for a; do j=$a; done; c=${{CLOTHOD_REPORT:-}}; [ -n "$c" ] || c={}; [ -n "$CLOTHO_PANE" ] && [ -x "$c" ] && "$c" report --codex-notify "$j"; [ $# -gt 1 ] && exec "$@"; exit 0"#,
        sh_quote(&bin.to_string_lossy())
    )
}

fn is_ours(hook: &Value) -> bool {
    hook["command"].as_str().is_some_and(|c| c.contains(MARKER))
}

fn backup(path: &Path) -> Result<()> {
    if path.exists() {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
        std::fs::copy(path, path.with_file_name(format!("{}.clotho-backup-{t}", path.file_name().unwrap().to_string_lossy())))?;
    }
    Ok(())
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    Ok(crate::write_atomic(path, data)?)
}

fn read_json(path: &Path) -> Result<Value> {
    match std::fs::read(path) {
        Ok(b) if b.iter().all(u8::is_ascii_whitespace) => Ok(json!({})),
        Ok(b) => serde_json::from_slice(&b).with_context(|| format!("{} is not valid JSON; not touching it", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(e) => Err(e.into()),
    }
}

/// Remove our entries from a Claude settings object; returns whether anything changed.
fn claude_remove(settings: &mut Value) -> bool {
    let Some(hooks) = settings.get_mut("hooks").and_then(Value::as_object_mut) else { return false };
    let mut changed = false;
    for groups in hooks.values_mut() {
        let Some(groups) = groups.as_array_mut() else { continue };
        for g in groups.iter_mut() {
            if let Some(list) = g.get_mut("hooks").and_then(Value::as_array_mut) {
                let before = list.len();
                list.retain(|h| !is_ours(h));
                changed |= list.len() != before;
            }
        }
        groups.retain(|g| g.get("hooks").and_then(Value::as_array).is_none_or(|l| !l.is_empty()));
    }
    hooks.retain(|_, groups| groups.as_array().is_none_or(|g| !g.is_empty()));
    if hooks.is_empty() {
        settings.as_object_mut().unwrap().remove("hooks");
    }
    changed
}

fn claude_installed(settings: &Value) -> bool {
    settings["hooks"].as_object().is_some_and(|h| {
        h.values().flat_map(|g| g.as_array().into_iter().flatten()).any(|g| g["hooks"].as_array().is_some_and(|l| l.iter().any(is_ours)))
    })
}

fn install_claude() -> Result<String> {
    let path = claude_settings()?;
    let mut settings = read_json(&path)?;
    if !settings.is_object() {
        bail!("{} is not a JSON object; not touching it", path.display());
    }
    let before = settings.clone();
    // Re-adding replaces our old entries (a changed command after an upgrade), keeps the rest.
    claude_remove(&mut settings);
    let snippet = claude_snippet();
    let hooks = settings.as_object_mut().unwrap().entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().context("\"hooks\" in settings.json is not an object; not touching it")?;
    for (event, groups) in snippet["hooks"].as_object().unwrap() {
        let list = hooks.entry(event.clone()).or_insert_with(|| json!([]));
        let list = list.as_array_mut().with_context(|| format!("hooks.{event} is not an array; not touching it"))?;
        list.extend(groups.as_array().unwrap().iter().cloned());
    }
    if settings == before {
        return Ok(format!("{}: already installed", path.display()));
    }
    backup(&path)?;
    write_atomic(&path, format!("{}\n", serde_json::to_string_pretty(&settings)?).as_bytes())?;
    Ok(format!("{}: installed", path.display()))
}

fn uninstall_claude() -> Result<String> {
    let path = claude_settings()?;
    if !path.exists() {
        return Ok(format!("{}: not installed", path.display()));
    }
    let mut settings = read_json(&path)?;
    if !claude_remove(&mut settings) {
        return Ok(format!("{}: not installed", path.display()));
    }
    backup(&path)?;
    write_atomic(&path, format!("{}\n", serde_json::to_string_pretty(&settings)?).as_bytes())?;
    Ok(format!("{}: uninstalled", path.display()))
}

fn read_toml(path: &Path) -> Result<toml_edit::DocumentMut> {
    match std::fs::read_to_string(path) {
        Ok(s) => s.parse().with_context(|| format!("{} is not valid TOML; not touching it", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(toml_edit::DocumentMut::new()),
        Err(e) => Err(e.into()),
    }
}

/// `notify` as a list of strings, if set.
fn codex_notify(doc: &toml_edit::DocumentMut) -> Option<Vec<String>> {
    let arr = doc.get("notify")?.as_array()?;
    Some(arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
}

fn codex_is_ours(notify: &[String]) -> bool {
    notify.get(3).map(String::as_str) == Some(CODEX_ARG0)
}

fn set_notify(doc: &mut toml_edit::DocumentMut, notify: Option<Vec<String>>) {
    match notify {
        Some(n) => {
            let mut arr = toml_edit::Array::new();
            for s in n {
                arr.push(s);
            }
            doc["notify"] = toml_edit::value(arr);
        }
        None => {
            doc.remove("notify");
        }
    }
}

fn install_codex() -> Result<String> {
    let path = codex_config()?;
    let mut doc = read_toml(&path)?;
    let current = codex_notify(&doc);
    // Chain to the user's own program (unwrapping our old wrapper first, after an upgrade).
    let user = match &current {
        Some(n) if codex_is_ours(n) => n[4..].to_vec(),
        Some(n) => n.clone(),
        None => Vec::new(),
    };
    let mut ours = vec!["/bin/sh".to_string(), "-c".into(), codex_script(), CODEX_ARG0.into()];
    ours.extend(user);
    if current.as_ref() == Some(&ours) {
        return Ok(format!("{}: already installed", path.display()));
    }
    set_notify(&mut doc, Some(ours));
    backup(&path)?;
    write_atomic(&path, doc.to_string().as_bytes())?;
    Ok(format!("{}: installed", path.display()))
}

fn uninstall_codex() -> Result<String> {
    let path = codex_config()?;
    let mut doc = read_toml(&path)?;
    match codex_notify(&doc) {
        Some(n) if codex_is_ours(&n) => {
            let user = n[4..].to_vec();
            set_notify(&mut doc, (!user.is_empty()).then_some(user));
            backup(&path)?;
            write_atomic(&path, doc.to_string().as_bytes())?;
            Ok(format!("{}: uninstalled", path.display()))
        }
        _ => Ok(format!("{}: not installed", path.display())),
    }
}

/// `clothod hooks <print|install|uninstall|status> [claude|codex]`. `install_self` makes sure
/// `<base>/current` exists (the hooks call it).
pub fn hooks(args: &[String], install_self: impl Fn() -> Result<()>) -> Result<()> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    let agent = args.get(1).map(String::as_str);
    match (action, agent) {
        ("print", Some("claude")) => println!("{}", serde_json::to_string_pretty(&claude_snippet())?),
        ("print", Some("codex")) => {
            let mut doc = toml_edit::DocumentMut::new();
            set_notify(&mut doc, Some(vec!["/bin/sh".into(), "-c".into(), codex_script(), CODEX_ARG0.into()]));
            print!("{doc}");
        }
        ("install", Some(a @ ("claude" | "codex"))) => {
            install_self()?;
            println!("{}", if a == "claude" { install_claude()? } else { install_codex()? });
        }
        ("uninstall", Some("claude")) => println!("{}", uninstall_claude()?),
        ("uninstall", Some("codex")) => println!("{}", uninstall_codex()?),
        ("status", _) => {
            let claude = read_json(&claude_settings()?).map(|s| claude_installed(&s)).unwrap_or(false);
            let codex = read_toml(&codex_config()?).ok().and_then(|d| codex_notify(&d)).is_some_and(|n| codex_is_ours(&n));
            println!("claude: {}", if claude { "installed" } else { "not installed" });
            println!("codex: {}", if codex { "installed" } else { "not installed" });
        }
        _ => bail!("usage: clothod hooks <print|install|uninstall> <claude|codex>, or clothod hooks status"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The install path is one shell word whatever it contains: a home directory with quotes,
    /// `$(...)` or backquotes must neither break the hook nor run anything.
    #[test]
    fn hook_command_quotes_the_install_path() {
        let dir = tempfile::tempdir().unwrap();
        let weird = dir.path().join("it's \"$(touch pwned)\" `touch pwned2` ${HOME}");
        std::fs::create_dir_all(&weird).unwrap();
        let bin = weird.join("clothod");
        let out = dir.path().join("ran");
        std::fs::write(&bin, format!("#!/bin/sh\necho \"$@\" > '{}'\n", out.display())).unwrap();
        std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        let cmd = report_command_for(&bin, "--claude-hook");
        let st = std::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .current_dir(dir.path())
            .env("CLOTHO_PANE", "1")
            .env_remove("CLOTHOD_REPORT")
            .status()
            .unwrap();
        assert!(st.success());
        assert_eq!(std::fs::read_to_string(&out).unwrap().trim(), "report --claude-hook");
        assert!(!dir.path().join("pwned").exists() && !dir.path().join("pwned2").exists());
        // $CLOTHOD_REPORT still overrides it.
        let other = dir.path().join("other");
        std::fs::write(&other, format!("#!/bin/sh\necho other > '{}'\n", out.display())).unwrap();
        std::fs::set_permissions(&other, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        std::process::Command::new("sh").arg("-c").arg(&cmd).env("CLOTHO_PANE", "1").env("CLOTHOD_REPORT", &other).status().unwrap();
        assert_eq!(std::fs::read_to_string(&out).unwrap().trim(), "other");
    }
}
