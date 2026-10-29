//! `clothod report` (called by agent hooks) and `clothod hooks` (installs those hooks into the
//! agents' configuration). docs/protocol.md, "Agents".

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use clotho_proto::{platform, Frame};
use serde_json::{json, Map, Value};

use crate::layout::safe_session;

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
    if args.first().map(String::as_str) == Some("--claude-permission") {
        return try_permission();
    }
    let Some(pane) = std::env::var("CLOTHO_PANE").ok().and_then(|p| p.parse::<u64>().ok()) else { return Ok(()) };
    let mut state: Option<String> = None;
    let mut kind: Option<String> = None;
    let mut message: Option<String> = None;
    let mut session: Option<String> = None;
    // Turn context: what the user asked, the tool in use (agent.report's prompt/tool/tool_input).
    let mut extra: Vec<(&str, String)> = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--agent" => kind = it.next().cloned(),
            "--message" => message = it.next().cloned(),
            "--session" => session = it.next().cloned().filter(|s| safe_session(s)),
            "--claude-hook" => {
                let mut input = String::new();
                std::io::stdin().take(1 << 20).read_to_string(&mut input)?;
                let v: Value = serde_json::from_str(&input)?;
                let Some(s) = claude_hook_state(&v) else { return Ok(()) };
                state = Some(s.into());
                kind = Some("claude".into());
                message = v["message"].as_str().map(String::from);
                session = v["session_id"].as_str().filter(|s| safe_session(s)).map(String::from);
                let (m, e) = claude_hook_context(&v);
                if m.is_some() {
                    message = m;
                }
                extra = e;
            }
            "--codex-notify" => {
                let v: Value = serde_json::from_str(it.next().map(String::as_str).unwrap_or("{}"))?;
                if v["type"] != "agent-turn-complete" {
                    return Ok(());
                }
                state = Some("done".into());
                kind = Some("codex".into());
                // The thread is the session `codex resume <id>` takes (Codex 0.164's payload
                // carries it as "thread-id").
                session = v["thread-id"].as_str().filter(|s| safe_session(s)).map(String::from);
                message = v["last-assistant-message"].as_str().map(|m| one_line(m, RESULT_MAX));
                // The user's messages in this turn, oldest first: the last one is what they asked.
                let asked = v["input-messages"].as_array().and_then(|m| m.last()).and_then(Value::as_str).map(user_prompt);
                extra.extend(asked.map(|q| ("prompt", q)));
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
    for (k, v) in extra {
        params[k] = json!(v);
    }
    for sock in daemon_sockets() {
        if let Ok(Some(_)) = send_report(&sock, "agent.report", &params, Some(Duration::from_millis(500))) {
            return Ok(());
        }
    }
    Ok(())
}

/// `clothod report --claude-permission`, Claude Code's PermissionRequest hook: ask the pane's
/// daemon, which shows the request to the apps, and wait for a decision. Print Claude's
/// answer for allow or deny; print nothing (Claude's own dialog, on screen all along, decides)
/// when the request is retired, the user answered in the terminal, or there's no daemon.
fn try_permission() -> Result<()> {
    let Some(pane) = std::env::var("CLOTHO_PANE").ok().and_then(|p| p.parse::<u64>().ok()) else { return Ok(()) };
    let mut input = String::new();
    std::io::stdin().take(1 << 20).read_to_string(&mut input)?;
    let v: Value = serde_json::from_str(&input)?;
    let Some(tool) = v["tool_name"].as_str() else { return Ok(()) };
    let mut params = json!({"pane": pane, "pid": std::process::id(), "kind": "claude", "tool": tool.chars().take(64).collect::<String>(), "key": tool_key(tool, &v["tool_input"])});
    if let Some(i) = tool_input(tool, &v["tool_input"]) {
        params["tool_input"] = json!(i);
    }
    if let Some(s) = v["session_id"].as_str().filter(|s| safe_session(s)) {
        params["session"] = json!(s);
    }
    for sock in daemon_sockets() {
        // No time limit: the answer comes when someone decides. Claude ends the hook at its
        // timeout, and the daemon notices the connection go.
        let Ok(Some(r)) = send_report(&sock, "agent.permission", &params, None) else { continue };
        let behavior = r["decision"].as_str().filter(|d| matches!(*d, "allow" | "deny"));
        if let Some(b) = behavior {
            let mut decision = json!({"behavior": b});
            if let Some(m) = r["message"].as_str().filter(|_| b == "deny") {
                decision["message"] = json!(m);
            }
            println!("{}", json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}));
        }
        return Ok(());
    }
    Ok(())
}

/// Identifies one tool call: its name and input. PermissionRequest and PostToolUse carry the
/// same two, so the call the user answered in the terminal retires its request.
fn tool_key(name: &str, input: &Value) -> String {
    use sha2::Digest;
    let h = sha2::Sha256::digest(format!("{name}\n{input}").as_bytes());
    h.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// The pane's daemon: named by the pane's environment (newer holders), else the default socket,
/// else any registered daemon. Each checks `pid` is really in its pane and refuses otherwise, so
/// a pane id that exists in two daemons can't be reported to the wrong one.
fn daemon_sockets() -> Vec<PathBuf> {
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
    candidates.retain(|s| {
        let new = !seen.contains(s);
        seen.push(s.clone());
        new
    });
    candidates
}

/// Claude Code's text for its idle reminder, for builds that don't send `notification_type`.
const CLAUDE_IDLE_MESSAGE: &str = "Claude is waiting for your input";

/// The state a Claude Code hook event reports, or None for events that say nothing new about
/// whether the agent needs the user (they leave its state, and attention, as they are).
fn claude_hook_state(v: &Value) -> Option<&'static str> {
    Some(match v["hook_event_name"].as_str().unwrap_or("") {
        // Compaction (auto or /compact) is the same session carrying on, not a new one: it
        // must not clear a raised attention for the next reminder to raise it again.
        "SessionStart" if v["source"] == "compact" => return None,
        "SessionStart" => "starting",
        "UserPromptSubmit" | "PreToolUse" | "PostToolUse" => "running",
        // Only a prompt the user must answer waits: permission and elicitation dialogs (and
        // types newer than this build, to be safe). `idle_prompt` repeats, a minute later, a turn
        // end the user was already told about; `auth_success` needs nothing.
        "Notification" => match v["notification_type"].as_str() {
            Some("idle_prompt" | "auth_success") => return None,
            None if v["message"] == CLAUDE_IDLE_MESSAGE => return None,
            _ => "waiting",
        },
        "Stop" => "done",
        "SessionEnd" => "clear",
        _ => return None,
    })
}

/// Longest result (an agent's last reply), prompt line and tool input sent, in chars.
const RESULT_MAX: usize = 300;
const PROMPT_MAX: usize = 120;
const TOOL_INPUT_MAX: usize = 160;

/// `text` on one line: whitespace runs (newlines too) become one space; at most `max` chars.
fn one_line(text: &str, max: usize) -> String {
    let mut out = String::new();
    for w in text.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(w);
        if out.chars().count() >= max {
            break;
        }
    }
    out.chars().take(max).collect()
}

/// The first line of a prompt the user typed, or "" for one the agent's app injected (another
/// agent's message, a finished background task): "" tells the daemon the turn has no prompt,
/// rather than show the wrapper's text.
fn user_prompt(prompt: &str) -> String {
    let t = prompt.trim_start();
    let injected = t.starts_with('<') || ["<cross-session-message", "<task-notification", "<teammate-message"].iter().any(|w| prompt.contains(w));
    if injected {
        return String::new();
    }
    one_line(t.lines().find(|l| !l.trim().is_empty()).unwrap_or(""), PROMPT_MAX)
}

/// A tool call's key input: the command, the file, the pattern, the URL... else its first text.
fn tool_input(name: &str, input: &Value) -> Option<String> {
    let key = match name {
        "Bash" => "command",
        "Read" | "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => "file_path",
        "Glob" | "Grep" => "pattern",
        "WebFetch" => "url",
        "WebSearch" => "query",
        "Task" | "Agent" => "description",
        _ => "",
    };
    let text = input.get(key).and_then(Value::as_str).or_else(|| input.as_object()?.values().find_map(Value::as_str))?;
    Some(one_line(text, TOOL_INPUT_MAX))
}

/// The turn context in a Claude Code hook's payload: a message that replaces the hook's own
/// (the reply a turn ended with), and agent.report's prompt / tool / tool_input.
fn claude_hook_context(v: &Value) -> (Option<String>, Vec<(&'static str, String)>) {
    match v["hook_event_name"].as_str().unwrap_or("") {
        "UserPromptSubmit" => (None, vec![("prompt", v["prompt"].as_str().map(user_prompt).unwrap_or_default()), ("retire", "all".into())]),
        // The call ran: the user allowed it (here or in the terminal), so its request is done.
        "PostToolUse" => (None, v["tool_name"].as_str().map(|t| vec![("retire", tool_key(t, &v["tool_input"]))]).unwrap_or_default()),
        "PreToolUse" => {
            let Some(name) = v["tool_name"].as_str() else { return (None, vec![]) };
            let mut e = vec![("tool", name.chars().take(64).collect())];
            e.extend(tool_input(name, &v["tool_input"]).map(|i| ("tool_input", i)));
            (None, e)
        }
        // Only a permission prompt is about the tool in use: any other wait (a question)
        // clears it, so the phone never offers to allow a tool the question isn't about.
        "Notification" if !is_permission(v) => (None, vec![("tool", String::new())]),
        "Stop" => (v["last_assistant_message"].as_str().map(|m| one_line(m, RESULT_MAX)).filter(|m| !m.is_empty()), vec![("retire", "all".into())]),
        _ => (None, vec![]),
    }
}

/// A Notification asking permission for a tool: `permission_prompt`, or (older Claude Code,
/// no type) a message that says so.
fn is_permission(v: &Value) -> bool {
    match v["notification_type"].as_str() {
        Some(t) => t == "permission_prompt",
        None => v["message"].as_str().is_some_and(|m| m.contains("permission")),
    }
}

/// One attempt: Ok(Some(result)) if this daemon took the request, Ok(None) if it refused it
/// (another daemon's pane).
fn send_report(socket: &Path, method: &str, params: &Value, timeout: Option<Duration>) -> Result<Option<Value>> {
    let mut s = UnixStream::connect(socket)?;
    s.set_read_timeout(timeout)?;
    s.set_write_timeout(Some(Duration::from_millis(500)))?;
    let hello = json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "clothod-report"}});
    let mut out = Frame::Json(hello).encode();
    out.extend(Frame::Json(json!({"id": 2, "method": method, "params": params})).encode());
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
                return Ok(v.get("result").cloned());
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
const CLAUDE_EVENTS: [(&str, Option<&str>); 8] = [
    ("SessionStart", None),
    ("UserPromptSubmit", None),
    ("PreToolUse", Some("*")),
    ("PostToolUse", Some("*")),
    ("PermissionRequest", Some("*")),
    ("Notification", None),
    ("Stop", None),
    ("SessionEnd", None),
];

/// How long Claude lets the PermissionRequest hook wait for an answer from a phone or the app.
/// Its own dialog shows all the while, so a long wait costs nothing: at the end Claude stops
/// the hook and the dialog stays.
const PERMISSION_TIMEOUT_S: u64 = 3600;

fn claude_snippet() -> Value {
    let mut hooks = Map::new();
    for (event, matcher) in CLAUDE_EVENTS {
        let mut group = Map::new();
        if let Some(m) = matcher {
            group.insert("matcher".into(), json!(m));
        }
        let hook = if event == "PermissionRequest" {
            json!({"type": "command", "command": report_command("--claude-permission"), "timeout": PERMISSION_TIMEOUT_S})
        } else {
            json!({"type": "command", "command": report_command("--claude-hook")})
        };
        group.insert("hooks".into(), json!([hook]));
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

/// Our hook commands in `settings`, by event (and matcher): what install would put there now
/// is `claude_ours(&claude_snippet())`.
fn claude_ours(settings: &Value) -> std::collections::BTreeMap<String, Vec<(Option<String>, String)>> {
    let mut out = std::collections::BTreeMap::new();
    for (event, groups) in settings["hooks"].as_object().into_iter().flatten() {
        for g in groups.as_array().into_iter().flatten() {
            for h in g["hooks"].as_array().into_iter().flatten().filter(|h| is_ours(h)) {
                out.entry(event.clone()).or_insert_with(Vec::new).push((g["matcher"].as_str().map(String::from), h["command"].as_str().unwrap_or("").to_string()));
            }
        }
    }
    out
}

/// "installed", "outdated" (ours, but not what this build would install: an older command)
/// or "not installed".
fn claude_status(settings: &Value) -> &'static str {
    if !claude_installed(settings) {
        "not installed"
    } else if claude_ours(settings) == claude_ours(&claude_snippet()) {
        "installed"
    } else {
        "outdated"
    }
}

/// `installed`, `outdated` or `not installed`; ` (chained)` when ours runs inside another
/// program's notify (Codex Computer Use wraps the notify it finds as `--previous-notify <JSON>`).
fn codex_status(notify: Option<&[String]>) -> String {
    let current = |n: &[String]| n[..4] == ["/bin/sh".to_string(), "-c".into(), codex_script(), CODEX_ARG0.into()];
    match notify {
        Some(n) if codex_is_ours(n) => (if current(n) { "installed" } else { "outdated" }).into(),
        Some(n) => match codex_chained(n) {
            Some((_, inner)) => format!("{} (chained)", if current(&inner) { "installed" } else { "outdated" }),
            None => "not installed".into(),
        },
        None => "not installed".into(),
    }
}

/// Ours inside another program's notify: `… --previous-notify <JSON array of ours>`. Returns
/// where the JSON is and what it holds.
fn codex_chained(notify: &[String]) -> Option<(usize, Vec<String>)> {
    let i = notify.iter().position(|a| a == "--previous-notify")? + 1;
    let inner: Vec<String> = serde_json::from_str(notify.get(i)?).ok()?;
    codex_is_ours(&inner).then_some((i, inner))
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
    // Ours inside another program's notify: bring it up to date where it is, rather than wrap
    // that program (which would then call ours twice).
    if let Some((i, inner)) = current.as_deref().and_then(codex_chained) {
        let mut ours = vec!["/bin/sh".to_string(), "-c".into(), codex_script(), CODEX_ARG0.into()];
        ours.extend(inner[4..].iter().cloned());
        if inner == ours {
            return Ok(format!("{}: already installed (chained)", path.display()));
        }
        let mut n = current.unwrap();
        n[i] = serde_json::to_string(&ours)?;
        set_notify(&mut doc, Some(n));
        backup(&path)?;
        write_atomic(&path, doc.to_string().as_bytes())?;
        return Ok(format!("{}: installed (chained)", path.display()));
    }
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
        // Chained: what ours chained to takes its place, or the option goes.
        Some(mut n) if codex_chained(&n).is_some() => {
            let (i, inner) = codex_chained(&n).unwrap();
            if inner.len() > 4 {
                n[i] = serde_json::to_string(&inner[4..])?;
            } else {
                n.drain(i - 1..=i);
            }
            set_notify(&mut doc, Some(n));
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
            // `outdated`: installed by an older clothod; `hooks install` brings it up to date.
            let claude = read_json(&claude_settings()?).map(|s| claude_status(&s)).unwrap_or("not installed");
            let codex = codex_status(read_toml(&codex_config()?).ok().and_then(|d| codex_notify(&d)).as_deref());
            println!("claude: {claude}");
            println!("codex: {codex}");
        }
        _ => bail!("usage: clothod hooks <print|install|uninstall> <claude|codex>, or clothod hooks status"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_payloads_give_the_turns_context() {
        let ctx = |j: &str| claude_hook_context(&serde_json::from_str(j).unwrap());
        // The prompt's first non-empty line, bounded; injected prompts give "" (no prompt).
        assert_eq!(ctx(r#"{"hook_event_name":"UserPromptSubmit","prompt":"\n  fix the build\nand test"}"#).1, vec![("prompt", "fix the build".to_string()), ("retire", "all".to_string())]);
        // A call that ran retires its permission request (same name and input as the request);
        // the turn's end retires them all.
        let post = ctx(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}"#).1;
        assert_eq!(post, vec![("retire", tool_key("Bash", &json!({"command": "npm test"})))]);
        assert_ne!(tool_key("Bash", &json!({"command": "npm test"})), tool_key("Bash", &json!({"command": "npm test "})));
        assert_eq!(ctx(r#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#).1, vec![("retire", "all".to_string())]);
        assert_eq!(user_prompt(&"é".repeat(500)).chars().count(), PROMPT_MAX);
        for injected in ["Another Claude session sent a message:\n<cross-session-message from=\"x\">hi</cross-session-message>", "<task-notification>\n<task-id>b1</task-id>", "<command-name>/compact</command-name>"] {
            assert_eq!(user_prompt(injected), "", "{injected}");
        }
        assert_eq!(user_prompt("/compact"), "/compact");
        // A tool's key input.
        let tool = |name: &str, input: &str| tool_input(name, &serde_json::from_str(input).unwrap());
        assert_eq!(tool("Bash", r#"{"command":"npm  test\n&& ls","description":"Run"}"#).as_deref(), Some("npm test && ls"));
        assert_eq!(tool("Edit", r#"{"file_path":"/a/b.rs","old_string":"x"}"#).as_deref(), Some("/a/b.rs"));
        assert_eq!(tool("mcp__ember__send", r#"{"text":"hello"}"#).as_deref(), Some("hello"));
        assert_eq!(tool("Bash", "{}"), None);
        assert_eq!(ctx(r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}"#).1, vec![("tool", "Bash".to_string()), ("tool_input", "npm test".to_string())]);
        // The reply a turn ended with, on one line, at most RESULT_MAX chars.
        let (m, _) = ctx(r#"{"hook_event_name":"Stop","last_assistant_message":"Done.\n\n- one\n- two"}"#);
        assert_eq!(m.as_deref(), Some("Done. - one - two"));
        let long = format!(r#"{{"hook_event_name":"Stop","last_assistant_message":"{}"}}"#, "word ".repeat(200));
        assert_eq!(ctx(&long).0.unwrap().chars().count(), RESULT_MAX);
        // A permission prompt keeps the turn's tool; any other wait clears it.
        assert!(ctx(r#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#).1.is_empty());
        assert!(ctx(r#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#).1.is_empty());
        assert_eq!(ctx(r#"{"hook_event_name":"Notification","message":"Claude needs your input","notification_type":"elicitation_dialog"}"#).1, vec![("tool", String::new())]);
    }

    /// Payloads as Claude Code 2.1.312 sends them (logged from a real session; paths and ids
    /// shortened): which events move the agent's state and which leave it alone.
    #[test]
    fn claude_hook_events_that_need_the_user() {
        let state = |j: &str| claude_hook_state(&serde_json::from_str(j).unwrap());
        let base = r#""session_id":"24e0052b","transcript_path":"/t.jsonl","cwd":"/tmp/p""#;
        let ev = |rest: &str| format!("{{{base},{rest}}}");
        assert_eq!(state(&ev(r#""hook_event_name":"SessionStart","source":"startup","model":"claude-haiku-5-5""#)), Some("starting"));
        assert_eq!(state(&ev(r#""hook_event_name":"SessionStart","source":"resume""#)), Some("starting"));
        assert_eq!(state(&ev(r#""hook_event_name":"SessionStart","source":"clear""#)), Some("starting"));
        assert_eq!(state(&ev(r#""hook_event_name":"UserPromptSubmit","prompt_id":"2816","permission_mode":"auto","prompt":"Reply with just: ok""#)), Some("running"));
        assert_eq!(state(&ev(r#""hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"touch x"}"#)), Some("running"));
        assert_eq!(state(&ev(r#""hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok","background_tasks":[]"#)), Some("done"));
        assert_eq!(state(&ev(r#""hook_event_name":"SessionEnd","reason":"prompt_input_exit""#)), Some("clear"));
        // Needs the user: a permission or elicitation prompt, and a type this build doesn't know.
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)), Some("waiting"));
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Claude needs your input","notification_type":"elicitation_dialog""#)), Some("waiting"));
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Something new","notification_type":"some_future_type""#)), Some("waiting"));
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Claude needs your permission to use Bash""#)), Some("waiting"));
        // Doesn't: the idle reminder a minute after a turn ends (with or without its type), a
        // login notice, compaction (manual or auto: PreCompact, then SessionStart "compact"),
        // and subagents finishing.
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt""#)), None);
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Claude is waiting for your input""#)), None);
        assert_eq!(state(&ev(r#""hook_event_name":"Notification","message":"Logged in","notification_type":"auth_success""#)), None);
        assert_eq!(state(&ev(r#""hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null"#)), None);
        assert_eq!(state(&ev(r#""hook_event_name":"SessionStart","source":"compact","model":"claude-haiku-5-5""#)), None);
        assert_eq!(state(&ev(r#""hook_event_name":"SubagentStop","agent_id":"a237","agent_type":"","stop_hook_active":false"#)), None);
    }

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
