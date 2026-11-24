//! `clothod report` (called by agent hooks, or by hand with `--state`) and `clothod hooks`
//! (installs those hooks into the agents' configuration). docs/protocol.md, "Agents".

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

/// The words `clothod report` takes as a state: the agent states, and `clear` (no agent).
const REPORT_STATES: [&str; 6] = ["starting", "running", "waiting", "done", "error", "clear"];

const REPORT_FLAGS: [&str; 10] =
    ["--state", "--agent", "--kind", "--message", "--tail", "--session", "--needs-user", "--claude-hook", "--gemini-hook", "--codex-notify"];

const REPORT_USAGE: &str = "usage: clothod report --state <starting|running|waiting|done|error|clear> [--kind NAME] [--message TEXT] [--needs-user yes|no] [--tail TEXT]";

/// Why a by-hand `clothod report --state ...` failed: its exit status and what it prints.
#[derive(Debug, PartialEq)]
struct Failure {
    code: i32,
    message: String,
}

fn usage(what: impl std::fmt::Display) -> Failure {
    Failure { code: 2, message: format!("{what}\n{REPORT_USAGE}") }
}

fn failed(message: impl Into<String>) -> Failure {
    Failure { code: 1, message: message.into() }
}

/// A payload `clothod report` reads for an agent's own hook.
#[derive(Debug, PartialEq)]
enum HookInput {
    /// `--claude-hook`: Claude Code's hook JSON on stdin.
    Claude,
    /// `--gemini-hook`: Gemini CLI's hook JSON on stdin.
    Gemini,
    /// `--codex-notify <JSON>`: Codex's notify payload, the next argument.
    Codex(String),
}

/// `clothod report`'s arguments.
#[derive(Debug, Default, PartialEq)]
struct ReportArgs {
    state: Option<String>,
    kind: Option<String>,
    message: Option<String>,
    session: Option<String>,
    tail: Option<String>,
    needs_user: Option<bool>,
    hook: Option<HookInput>,
    /// The state was given as `--state`: the form people and scripts type, which says what went
    /// wrong. Every other form is a hook's, and silent.
    by_hand: bool,
}

/// Read `clothod report`'s arguments, in any order. A bare word is the state only if it is a
/// state word, so `report --kind mytool --state waiting` never reads `mytool` as the state.
/// What can't be read (an unknown state or flag, a flag without its value) is an error with
/// `--state` and skipped without it: installed hooks must keep working whatever a newer agent
/// passes them.
fn parse_report(args: &[String]) -> Result<ReportArgs, Failure> {
    let mut r = ReportArgs { by_hand: args.iter().any(|a| a == "--state"), ..Default::default() };
    let mut bad: Option<String> = None;
    let mut flagged: Option<String> = None;
    let mut it = args.iter().peekable();
    while let Some(a) = it.next() {
        // The next argument, unless it is one of our flags: `--kind --state waiting` is a kind
        // left out, not a kind called `--state`.
        let mut value = |bad: &mut Option<String>| {
            let v = it.next_if(|v| !REPORT_FLAGS.contains(&v.as_str())).cloned();
            if v.is_none() {
                bad.get_or_insert(format!("{a} needs a value"));
            }
            v
        };
        match a.as_str() {
            "--state" => flagged = value(&mut bad),
            "--agent" | "--kind" => r.kind = value(&mut bad),
            "--message" => r.message = value(&mut bad),
            "--tail" => r.tail = value(&mut bad),
            "--session" => r.session = value(&mut bad).filter(|s| safe_session(s)),
            "--needs-user" => match value(&mut bad).as_deref() {
                Some("yes") => r.needs_user = Some(true),
                Some("no") => r.needs_user = Some(false),
                Some(v) => {
                    bad.get_or_insert(format!("--needs-user takes yes or no, not `{v}`"));
                }
                None => {}
            },
            "--claude-hook" => r.hook = Some(HookInput::Claude),
            "--gemini-hook" => r.hook = Some(HookInput::Gemini),
            "--codex-notify" => r.hook = Some(HookInput::Codex(it.next().cloned().unwrap_or_else(|| "{}".into()))),
            s if !s.starts_with("--") && r.state.is_none() && REPORT_STATES.contains(&s) => r.state = Some(s.into()),
            s => {
                bad.get_or_insert(format!("unexpected argument `{s}`"));
            }
        }
    }
    if !r.by_hand {
        return Ok(r);
    }
    if let Some(b) = bad {
        return Err(usage(b));
    }
    match flagged {
        Some(s) if REPORT_STATES.contains(&s.as_str()) => r.state = Some(s),
        Some(s) => return Err(usage(format!("unknown state `{s}`"))),
        None => {}
    }
    Ok(r)
}

/// `clothod report ...`: tell the daemon what the agent in this pane is doing.
///
/// Hooks run it on every agent event (a bare state word, `--claude-hook`, `--gemini-hook`,
/// `--codex-notify`), so in those forms it is quick, never prints, and always "succeeds":
/// outside clotho or with no daemon it just does nothing. `--state` is the form to type or
/// script: it prints what went wrong and exits 2 for a usage error, 1 when the report didn't
/// reach the pane's daemon or the daemon refused it.
pub fn report(args: &[String]) -> i32 {
    if args.first().map(String::as_str) == Some("--claude-permission") {
        let _ = try_permission();
        return 0;
    }
    let by_hand = args.iter().any(|a| a == "--state");
    match try_report(args, std::env::var("CLOTHO_PANE").ok(), daemon_sockets) {
        Err(f) if by_hand => {
            eprintln!("clothod report: {}", f.message);
            f.code
        }
        _ => 0,
    }
}

/// The JSON a hook wrote to stdin.
fn stdin_json() -> Option<Value> {
    let mut input = String::new();
    std::io::stdin().take(1 << 20).read_to_string(&mut input).ok()?;
    serde_json::from_str(&input).ok()
}

/// `pane` is `$CLOTHO_PANE`; `sockets` lists the daemons to try (only called once there is
/// something to send).
fn try_report(args: &[String], pane: Option<String>, sockets: impl FnOnce() -> Vec<PathBuf>) -> Result<(), Failure> {
    let ReportArgs { mut state, mut kind, mut message, mut session, tail, needs_user, hook, by_hand } = parse_report(args)?;
    let pane = match pane.as_deref().map(str::parse::<u64>) {
        Some(Ok(p)) => p,
        Some(Err(_)) => return Err(failed("CLOTHO_PANE is not a pane id")),
        None => return Err(failed("not in a Clotho pane (CLOTHO_PANE is not set)")),
    };
    // Turn context: what the user asked, the tool in use (agent.report's prompt/tool/tool_input).
    let mut extra: Vec<(&str, String)> = Vec::new();
    match hook {
        Some(HookInput::Claude) => {
            let Some(v) = stdin_json() else { return Ok(()) };
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
        Some(HookInput::Gemini) => {
            let Some(v) = stdin_json() else { return Ok(()) };
            let Some((s, m, e)) = gemini_hook(&v) else { return Ok(()) };
            state = Some(s.into());
            kind = Some("gemini".into());
            message = m;
            extra = e;
        }
        Some(HookInput::Codex(payload)) => {
            let Ok(v) = serde_json::from_str::<Value>(&payload) else { return Ok(()) };
            if v["type"] != "agent-turn-complete" {
                return Ok(());
            }
            state = Some("done".into());
            kind = Some("codex".into());
            // The thread is the session `codex resume <id>` takes (Codex 0.164's payload
            // carries it as "thread-id").
            session = v["thread-id"].as_str().filter(|s| safe_session(s)).map(String::from);
            let reply = v["last-assistant-message"].as_str();
            message = reply.map(|m| one_line(m, RESULT_MAX));
            extra.extend(reply.and_then(reply_tail).map(|t| ("tail", t)));
            // The user's messages in this turn, oldest first: the last one is what they asked.
            let asked = v["input-messages"].as_array().and_then(|m| m.last()).and_then(Value::as_str).map(user_prompt);
            extra.extend(asked.map(|q| ("prompt", q)));
        }
        None => {}
    }
    let Some(state) = state else { return Ok(()) };
    let mut params = json!({"pane": pane, "state": state, "pid": std::process::id()});
    for (k, v) in [("kind", kind), ("message", message), ("session", session), ("tail", tail)] {
        if let Some(v) = v {
            params[k] = json!(v);
        }
    }
    if let Some(n) = needs_user {
        params["needs_user"] = json!(n);
    }
    for (k, v) in extra {
        params[k] = json!(v);
    }
    // What the last daemon that answered said against the report.
    let mut refused: Option<String> = None;
    for sock in sockets() {
        match send_report(&sock, "agent.report", &params, Some(Duration::from_millis(500))) {
            Ok(Ok(_)) => return Ok(()),
            Ok(Err(e)) => {
                let text = e["message"].as_str().unwrap_or("the daemon refused the report").to_string();
                // Another daemon's pane (the id isn't its own, or this process isn't in it): try
                // the next. Anything else is this daemon's answer.
                let elsewhere = matches!(e["code"].as_str(), Some("wrong_pane" | "not_found"));
                if by_hand && !elsewhere {
                    return Err(failed(text));
                }
                refused = Some(text);
            }
            Err(_) => {}
        }
    }
    Err(failed(refused.unwrap_or_else(|| "no clothod reachable".into())))
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
        let Ok(Ok(r)) = send_report(&sock, "agent.permission", &params, None) else { continue };
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
/// Longest end of a reply sent (agent.report's `tail`), in chars: where a long reply asks its
/// question or says what's left, which the first RESULT_MAX chars miss.
const TAIL_MAX: usize = 600;

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

/// The end of a reply longer than RESULT_MAX: its last TAIL_MAX chars, on one line. None for a
/// shorter reply, whose message is already the whole of it.
fn reply_tail(text: &str) -> Option<String> {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars = line.chars().count();
    if chars <= RESULT_MAX {
        return None;
    }
    let start = line.char_indices().nth(chars.saturating_sub(TAIL_MAX)).map_or(0, |(i, _)| i);
    Some(line[start..].to_string())
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
        "Bash" | "run_shell_command" => "command",
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
        "Stop" => {
            let reply = v["last_assistant_message"].as_str();
            let mut e = vec![("retire", "all".into())];
            e.extend(reply.and_then(reply_tail).map(|t| ("tail", t)));
            (reply.map(|m| one_line(m, RESULT_MAX)).filter(|m| !m.is_empty()), e)
        }
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

/// What a Gemini CLI hook event reports: the state, a message, and agent.report's prompt / tool
/// / tool_input / tail. None for events that say nothing about the agent's state. The payload
/// is Gemini CLI's hook input (its docs/hooks/reference.md): `hook_event_name` with `prompt`
/// (BeforeAgent), `tool_name` and `tool_input` (BeforeTool, AfterTool), `prompt_response`
/// (AfterAgent) or `message` (Notification, whose one type is a tool's permission prompt).
#[allow(clippy::type_complexity)]
fn gemini_hook(v: &Value) -> Option<(&'static str, Option<String>, Vec<(&'static str, String)>)> {
    Some(match v["hook_event_name"].as_str().unwrap_or("") {
        "SessionStart" => ("starting", None, vec![]),
        "BeforeAgent" => ("running", None, vec![("prompt", v["prompt"].as_str().map(user_prompt).unwrap_or_default())]),
        "BeforeTool" => {
            let mut e = Vec::new();
            if let Some(name) = v["tool_name"].as_str() {
                e.push(("tool", name.chars().take(64).collect()));
                e.extend(tool_input(name, &v["tool_input"]).map(|i| ("tool_input", i)));
            }
            ("running", None, e)
        }
        // The tool ran: a wait for its permission is over.
        "AfterTool" => ("running", None, vec![]),
        "AfterAgent" => {
            let reply = v["prompt_response"].as_str();
            let e = reply.and_then(reply_tail).map(|t| ("tail", t)).into_iter().collect();
            ("done", reply.map(|m| one_line(m, RESULT_MAX)).filter(|m| !m.is_empty()), e)
        }
        "Notification" => ("waiting", v["message"].as_str().map(|m| one_line(m, RESULT_MAX)).filter(|m| !m.is_empty()), vec![]),
        "SessionEnd" => ("clear", None, vec![]),
        _ => return None,
    })
}

/// One attempt: Ok(Ok(result)) if this daemon took the request, Ok(Err(error)) if it refused it
/// (another daemon's pane, typically): the reply's `error`, with its `code` and `message`.
fn send_report(socket: &Path, method: &str, params: &Value, timeout: Option<Duration>) -> Result<std::result::Result<Value, Value>> {
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
                return Ok(v.get("result").cloned().ok_or_else(|| v.get("error").cloned().unwrap_or(Value::Null)));
            }
        }
    }
}

// ---- sessions of agents without hooks --------------------------------------------------------

/// Where Claude Code keeps its per-process records (`<pid>.json`): `$CLAUDE_CONFIG_DIR/sessions`,
/// or `~/.claude/sessions`.
fn claude_sessions_dir() -> Option<PathBuf> {
    let base = std::env::var_os("CLAUDE_CONFIG_DIR").filter(|d| !d.is_empty()).map(PathBuf::from).or_else(|| home().ok().map(|h| h.join(".claude")))?;
    Some(base.join("sessions"))
}

/// The session of the running Claude Code with this pid, from the record Claude Code keeps for
/// it (`<pid>.json`: `pid`, `sessionId`, `cwd`), for an agent found by detection, which no hook
/// told its session. Read only. The record must name this pid and the process's own cwd (a
/// stale record of a dead process whose pid was reused never matches), and the id must be one
/// clothod would type; anything else (no record, another format) is `None`.
pub fn claude_session_of(pid: u32) -> Option<String> {
    claude_session_in(&claude_sessions_dir()?, pid, &platform::process_cwd(pid)?)
}

fn claude_session_in(dir: &Path, pid: u32, cwd: &Path) -> Option<String> {
    let mut text = String::new();
    std::fs::File::open(dir.join(format!("{pid}.json"))).ok()?.take(64 * 1024).read_to_string(&mut text).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let named = v.get("pid").and_then(|p| p.as_u64().or_else(|| p.as_str()?.parse().ok()));
    if named != Some(pid as u64) {
        return None;
    }
    let canon = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    if canon(Path::new(v.get("cwd")?.as_str()?)) != canon(cwd) {
        return None;
    }
    v.get("sessionId")?.as_str().filter(|s| safe_session(s)).map(String::from)
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

/// Gemini CLI's user settings, whose `hooks` object has Claude Code's shape (its
/// docs/hooks/index.md).
fn gemini_settings() -> Result<PathBuf> {
    Ok(home()?.join(".gemini").join("settings.json"))
}

/// Our own file among Copilot CLI's user-level hook files: it loads every `*.json` in
/// `$COPILOT_HOME/hooks/`, by default `~/.copilot/hooks/` (GitHub's hooks reference).
fn copilot_hooks_file() -> Result<PathBuf> {
    let base = match std::env::var_os("COPILOT_HOME").filter(|d| !d.is_empty()) {
        Some(d) => PathBuf::from(d),
        None => home()?.join(".copilot"),
    };
    Ok(base.join("hooks").join("clotho.json"))
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

/// Gemini CLI events and their matcher. Each runs its command through the shell with the
/// event's JSON on stdin, in Gemini's own environment (so `$CLOTHO_PANE` is there).
const GEMINI_EVENTS: [(&str, Option<&str>); 7] = [
    ("SessionStart", None),
    ("BeforeAgent", None),
    ("BeforeTool", Some("*")),
    ("AfterTool", Some("*")),
    ("AfterAgent", None),
    ("Notification", None),
    ("SessionEnd", None),
];

fn gemini_snippet() -> Value {
    let mut hooks = Map::new();
    for (event, matcher) in GEMINI_EVENTS {
        let mut group = Map::new();
        if let Some(m) = matcher {
            group.insert("matcher".into(), json!(m));
        }
        group.insert("hooks".into(), json!([{"name": "clotho", "type": "command", "command": report_command("--gemini-hook")}]));
        hooks.insert(event.into(), json!([Value::Object(group)]));
    }
    json!({"hooks": hooks})
}

/// Copilot CLI events, the state each reports, and a matcher (on a notification's type: only
/// the two that wait for the user). The state is an argument, so nothing is read from stdin.
/// `errorOccurred` is left out: nothing says the error ended the turn.
const COPILOT_EVENTS: [(&str, &str, Option<&str>); 7] = [
    ("sessionStart", "starting", None),
    ("userPromptSubmitted", "running", None),
    ("preToolUse", "running", None),
    ("postToolUse", "running", None),
    ("notification", "waiting", Some("permission_prompt|elicitation_dialog")),
    ("agentStop", "done", None),
    ("sessionEnd", "clear", None),
];

/// How long Copilot lets one of our hooks run, in seconds (a report takes milliseconds).
const COPILOT_TIMEOUT_S: u64 = 5;

/// The whole of our Copilot hooks file. Every command ends in `true`: Copilot denies a tool
/// call whose `preToolUse` hook fails.
fn copilot_snippet() -> Value {
    let mut hooks = Map::new();
    for (event, state, matcher) in COPILOT_EVENTS {
        let mut hook = json!({"type": "command", "bash": report_command(&format!("{state} --agent copilot")), "timeoutSec": COPILOT_TIMEOUT_S});
        if let Some(m) = matcher {
            hook["matcher"] = json!(m);
        }
        hooks.insert(event.into(), json!([hook]));
    }
    json!({"version": 1, "hooks": hooks})
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

/// Remove our entries from a settings object (Claude Code's, or Gemini CLI's: the same shape);
/// returns whether anything changed. A group, an event or the `hooks` object goes only when
/// removing ours emptied it: what the user left empty stays as it was.
fn claude_remove(settings: &mut Value) -> bool {
    let Some(hooks) = settings.get_mut("hooks").and_then(Value::as_object_mut) else { return false };
    let mut changed = false;
    let mut emptied: Vec<String> = Vec::new();
    for (event, groups) in hooks.iter_mut() {
        let Some(groups) = groups.as_array_mut() else { continue };
        let mut event_changed = false;
        groups.retain_mut(|g| {
            let Some(list) = g.get_mut("hooks").and_then(Value::as_array_mut) else { return true };
            let before = list.len();
            list.retain(|h| !is_ours(h));
            event_changed |= list.len() != before;
            list.len() == before || !list.is_empty()
        });
        if event_changed && groups.is_empty() {
            emptied.push(event.clone());
        }
        changed |= event_changed;
    }
    for event in emptied {
        hooks.shift_remove(&event);
    }
    if changed && hooks.is_empty() {
        settings.as_object_mut().unwrap().shift_remove("hooks");
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
    hooks_status(settings, &claude_snippet())
}

/// The same for any settings file of that shape: `snippet` is what install would add now.
fn hooks_status(settings: &Value, snippet: &Value) -> &'static str {
    if !claude_installed(settings) {
        "not installed"
    } else if claude_ours(settings) == claude_ours(snippet) {
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
    install_hooks(&claude_settings()?, &claude_snippet())
}

fn uninstall_claude() -> Result<String> {
    uninstall_hooks(&claude_settings()?)
}

/// Merge `snippet`'s hooks into the settings file at `path` (Claude Code's, or Gemini CLI's),
/// keeping everything else in it, after a backup.
fn install_hooks(path: &Path, snippet: &Value) -> Result<String> {
    let mut settings = read_json(path)?;
    if !settings.is_object() {
        bail!("{} is not a JSON object; not touching it", path.display());
    }
    let before = settings.clone();
    // Re-adding replaces our old entries (a changed command after an upgrade), keeps the rest.
    claude_remove(&mut settings);
    let hooks = settings.as_object_mut().unwrap().entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().with_context(|| format!("\"hooks\" in {} is not an object; not touching it", path.display()))?;
    for (event, groups) in snippet["hooks"].as_object().unwrap() {
        let list = hooks.entry(event.clone()).or_insert_with(|| json!([]));
        let list = list.as_array_mut().with_context(|| format!("hooks.{event} is not an array; not touching it"))?;
        list.extend(groups.as_array().unwrap().iter().cloned());
    }
    if settings == before {
        return Ok(format!("{}: already installed", path.display()));
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    backup(path)?;
    write_atomic(path, format!("{}\n", serde_json::to_string_pretty(&settings)?).as_bytes())?;
    Ok(format!("{}: installed", path.display()))
}

fn uninstall_hooks(path: &Path) -> Result<String> {
    if !path.exists() {
        return Ok(format!("{}: not installed", path.display()));
    }
    let mut settings = read_json(path)?;
    if !claude_remove(&mut settings) {
        return Ok(format!("{}: not installed", path.display()));
    }
    backup(path)?;
    write_atomic(path, format!("{}\n", serde_json::to_string_pretty(&settings)?).as_bytes())?;
    Ok(format!("{}: uninstalled", path.display()))
}

/// Whether a Copilot hooks file is the one we wrote: all its commands are ours.
fn copilot_is_ours(file: &Value) -> bool {
    let mut commands = file["hooks"].as_object().into_iter().flat_map(|h| h.values()).flat_map(|l| l.as_array().into_iter().flatten()).peekable();
    commands.peek().is_some() && commands.all(|h| h["bash"].as_str().is_some_and(|c| c.contains(MARKER)))
}

/// "installed", "outdated" or "not installed" for the Copilot hooks file at `path`.
fn copilot_status(path: &Path) -> &'static str {
    match read_json(path) {
        Ok(f) if f == copilot_snippet() => "installed",
        Ok(f) if copilot_is_ours(&f) => "outdated",
        _ => "not installed",
    }
}

/// Write our Copilot hooks file. It is ours alone, so the user's other hook files are never
/// read or changed; a file of that name that isn't ours is left alone.
fn install_copilot(path: &Path) -> Result<String> {
    let ours = copilot_snippet();
    if path.exists() {
        let current = read_json(path)?;
        if current == ours {
            return Ok(format!("{}: already installed", path.display()));
        }
        if !copilot_is_ours(&current) {
            bail!("{} is not clotho's; not touching it", path.display());
        }
        backup(path)?;
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    write_atomic(path, format!("{}\n", serde_json::to_string_pretty(&ours)?).as_bytes())?;
    Ok(format!("{}: installed", path.display()))
}

fn uninstall_copilot(path: &Path) -> Result<String> {
    if !path.exists() || !read_json(path).is_ok_and(|f| copilot_is_ours(&f)) {
        return Ok(format!("{}: not installed", path.display()));
    }
    std::fs::remove_file(path)?;
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

/// The agents `clothod hooks` knows: those whose own documentation confirms where hooks are
/// configured, which events there are, and how the command is run.
const HOOK_AGENTS: &str = "claude|codex|gemini|copilot";

/// `clothod hooks <print|install|uninstall|status> [claude|codex|gemini|copilot]`.
/// `install_self` makes sure `<base>/current` exists (the hooks call it).
pub fn hooks(args: &[String], install_self: impl Fn() -> Result<()>) -> Result<()> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    let agent = args.get(1).map(String::as_str);
    match (action, agent) {
        ("print", Some("claude")) => println!("{}", serde_json::to_string_pretty(&claude_snippet())?),
        ("print", Some("gemini")) => println!("{}", serde_json::to_string_pretty(&gemini_snippet())?),
        ("print", Some("copilot")) => println!("{}", serde_json::to_string_pretty(&copilot_snippet())?),
        ("print", Some("codex")) => {
            let mut doc = toml_edit::DocumentMut::new();
            set_notify(&mut doc, Some(vec!["/bin/sh".into(), "-c".into(), codex_script(), CODEX_ARG0.into()]));
            print!("{doc}");
        }
        ("install", Some(a @ ("claude" | "codex" | "gemini" | "copilot"))) => {
            install_self()?;
            let done = match a {
                "claude" => install_claude()?,
                "codex" => install_codex()?,
                "gemini" => install_hooks(&gemini_settings()?, &gemini_snippet())?,
                _ => install_copilot(&copilot_hooks_file()?)?,
            };
            println!("{done}");
        }
        ("uninstall", Some("claude")) => println!("{}", uninstall_claude()?),
        ("uninstall", Some("codex")) => println!("{}", uninstall_codex()?),
        ("uninstall", Some("gemini")) => println!("{}", uninstall_hooks(&gemini_settings()?)?),
        ("uninstall", Some("copilot")) => println!("{}", uninstall_copilot(&copilot_hooks_file()?)?),
        ("status", _) => {
            // `outdated`: installed by an older clothod; `hooks install` brings it up to date.
            let claude = read_json(&claude_settings()?).map(|s| claude_status(&s)).unwrap_or("not installed");
            let codex = codex_status(read_toml(&codex_config()?).ok().and_then(|d| codex_notify(&d)).as_deref());
            let gemini = read_json(&gemini_settings()?).map(|s| hooks_status(&s, &gemini_snippet())).unwrap_or("not installed");
            println!("claude: {claude}");
            println!("codex: {codex}");
            println!("gemini: {gemini}");
            println!("copilot: {}", copilot_status(&copilot_hooks_file()?));
        }
        _ => bail!("usage: clothod hooks <print|install|uninstall> <{HOOK_AGENTS}>, or clothod hooks status"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn claude_session_records_must_match_the_process() {
        let dir = std::env::temp_dir().join(format!("clothod-unit-sessions-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cwd = std::env::temp_dir();
        let write = |pid: u32, v: Value| std::fs::write(dir.join(format!("{pid}.json")), v.to_string()).unwrap();
        let c = cwd.to_string_lossy();
        write(10, json!({"pid": 10, "sessionId": "d151d209-1192-4acc-8667-80be46e13a93", "cwd": c}));
        assert_eq!(claude_session_in(&dir, 10, &cwd).as_deref(), Some("d151d209-1192-4acc-8667-80be46e13a93"));
        // Another pid's record (a reused file name), another cwd, or an id clothod won't type.
        write(11, json!({"pid": 12, "sessionId": "abc", "cwd": c}));
        write(13, json!({"pid": 13, "sessionId": "abc", "cwd": "/nonexistent-elsewhere"}));
        write(14, json!({"pid": 14, "sessionId": "-rf", "cwd": c}));
        write(15, json!({"pid": 15, "cwd": c}));
        std::fs::write(dir.join("16.json"), "not json").unwrap();
        for pid in [11, 13, 14, 15, 16, 17] {
            assert_eq!(claude_session_in(&dir, pid, &cwd), None, "pid {pid}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

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
        // A reply longer than that also sends its end (where the question usually is), on one
        // line, at most TAIL_MAX chars; the message is still the start.
        let tail_of = |e: &[(&'static str, String)]| e.iter().find(|(k, _)| *k == "tail").map(|(_, t)| t.clone());
        let asks = json!({"hook_event_name": "Stop", "last_assistant_message": format!("Started.\n{}\n\nShould I push\nthe branch?", "word ".repeat(200))});
        let (m, e) = claude_hook_context(&asks);
        assert!(m.unwrap().starts_with("Started. word"));
        assert_eq!(e[0], ("retire", "all".to_string()));
        let tail = tail_of(&e).unwrap();
        assert!(tail.ends_with("word Should I push the branch?"), "{tail}");
        assert_eq!(tail.chars().count(), TAIL_MAX);
        // Between RESULT_MAX and TAIL_MAX the tail is the whole reply; at RESULT_MAX or under
        // there is none (whitespace doesn't count: the reply is measured collapsed).
        assert_eq!(reply_tail(&"a".repeat(RESULT_MAX + 1)).unwrap().chars().count(), RESULT_MAX + 1);
        assert_eq!(reply_tail(&"a".repeat(RESULT_MAX)), None);
        assert_eq!(reply_tail(&format!("{}\n\n   {}", "a".repeat(100), " \n".repeat(400))), None);
        assert_eq!(tail_of(&ctx(r#"{"hook_event_name":"Stop","last_assistant_message":"Done.\n\n- one\n- two"}"#).1), None);
        assert_eq!(tail_of(&ctx(r#"{"hook_event_name":"Stop"}"#).1), None);
        // Multi-byte text is cut between chars, never inside one.
        let wide = reply_tail(&format!("{}né?", "é".repeat(1000))).unwrap();
        assert_eq!(wide.chars().count(), TAIL_MAX);
        assert!(wide.starts_with('é') && wide.ends_with("éné?"));
        assert_eq!(reply_tail(&"日本 ".repeat(400)).unwrap().chars().count(), TAIL_MAX);
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

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn report_arguments_in_any_order() {
        let parse = |args: &[&str]| parse_report(&strings(args));
        // By hand: `--state`, with the kind before or after it. `mytool` is never the state.
        let want = ReportArgs { state: Some("waiting".into()), kind: Some("mytool".into()), by_hand: true, ..Default::default() };
        assert_eq!(parse(&["--kind", "mytool", "--state", "waiting"]), Ok(want));
        let r = parse(&["--state", "waiting", "--kind", "mytool", "--message", "Deploy?", "--needs-user", "yes", "--tail", "the end"]).unwrap();
        assert_eq!((r.state.as_deref(), r.kind.as_deref(), r.by_hand), (Some("waiting"), Some("mytool"), true));
        assert_eq!((r.message.as_deref(), r.tail.as_deref(), r.needs_user), (Some("Deploy?"), Some("the end"), Some(true)));
        assert_eq!(parse(&["--needs-user", "no", "--state", "done"]).unwrap().needs_user, Some(false));
        assert_eq!(parse(&["--state", "clear"]).unwrap().state.as_deref(), Some("clear"));
        // The hooks' form: a bare state word, before or after the flags; `--agent` is `--kind`.
        for args in [["running", "--agent", "copilot"], ["--agent", "copilot", "running"], ["--kind", "copilot", "running"]] {
            let r = parse(&args).unwrap();
            assert_eq!((r.state.as_deref(), r.kind.as_deref(), r.by_hand), (Some("running"), Some("copilot"), false), "{args:?}");
        }
        assert_eq!(parse(&["done", "--needs-user", "no"]).unwrap().needs_user, Some(false));
        // A bare word that isn't a state is not one, and the first state word wins.
        assert_eq!(parse(&["mytool", "waiting", "done"]).unwrap().state.as_deref(), Some("waiting"));
        assert_eq!(parse(&["--session", "24e0052b-aa", "done"]).unwrap().session.as_deref(), Some("24e0052b-aa"));
        assert_eq!(parse(&["--session", "--resume", "done"]).unwrap().session, None);
        // The agents' own payloads.
        assert_eq!(parse(&["--claude-hook"]).unwrap().hook, Some(HookInput::Claude));
        assert_eq!(parse(&["--gemini-hook"]).unwrap().hook, Some(HookInput::Gemini));
        assert_eq!(parse(&["--codex-notify", "{\"type\":\"x\"}"]).unwrap().hook, Some(HookInput::Codex("{\"type\":\"x\"}".into())));
    }

    #[test]
    fn report_usage_errors_only_in_the_state_form() {
        let parse = |args: &[&str]| parse_report(&strings(args));
        // With `--state`: exit 2 and the usage.
        for args in [
            &["--state", "bogus"][..],
            &["--state"],
            &["--state", "waiting", "--needs-user", "maybe"],
            &["--state", "waiting", "--needs-user"],
            &["--state", "waiting", "--frobnicate"],
            &["--state", "waiting", "mytool"],
            &["--kind", "--state", "waiting"],
        ] {
            let e = parse(args).unwrap_err();
            assert_eq!(e.code, 2, "{args:?}");
            assert!(e.message.contains("usage: clothod report --state"), "{args:?}: {}", e.message);
        }
        assert!(parse(&["--state", "bogus"]).unwrap_err().message.starts_with("unknown state `bogus`"));
        // Without it (a hook's call): never an error. A bad state is no state, so nothing is sent.
        assert_eq!(parse(&["bogus"]), Ok(ReportArgs::default()));
        assert_eq!(parse(&["bogus", "--agent", "x", "--frobnicate", "--needs-user", "maybe"]).unwrap().state, None);
        assert_eq!(parse(&["running", "--future-flag", "--message"]).unwrap().state.as_deref(), Some("running"));
        let r = parse(&["--message", "--agent", "copilot", "done"]).unwrap();
        assert_eq!((r.message, r.kind.as_deref(), r.state.as_deref()), (None, Some("copilot"), Some("done")));
    }

    #[test]
    fn report_by_hand_says_why_it_failed_and_hooks_stay_silent() {
        let none = Vec::new;
        let run = |args: &[&str], pane: Option<&str>| try_report(&strings(args), pane.map(String::from), none);
        assert_eq!(run(&["--state", "waiting"], None), Err(failed("not in a Clotho pane (CLOTHO_PANE is not set)")));
        assert_eq!(run(&["--state", "waiting"], Some("7")), Err(failed("no clothod reachable")));
        assert_eq!(run(&["--state", "waiting"], Some("x")).unwrap_err().code, 1);
        // Usage comes first: it is wrong wherever it is typed.
        assert_eq!(run(&["--state", "bogus"], None).unwrap_err().code, 2);
        // A socket nobody listens on is no daemon.
        let dir = tempfile::tempdir().unwrap();
        let dead = dir.path().join("clothod.sock");
        assert_eq!(try_report(&strings(&["--state", "done"]), Some("7".into()), || vec![dead]), Err(failed("no clothod reachable")));
        // The hooks' forms fail the same way inside, and `report` turns that into exit 0 without
        // a word: only `--state` asks to be told.
        assert!(run(&["waiting"], None).is_err());
        assert_eq!(run(&["bogus"], Some("7")), Ok(()));
    }

    /// Payloads as Gemini CLI's docs/hooks/reference.md gives them.
    #[test]
    fn gemini_hook_events() {
        let hook = |j: &str| gemini_hook(&serde_json::from_str(j).unwrap());
        let base = r#""session_id":"s1","transcript_path":"/t.json","cwd":"/tmp/p","timestamp":"2026-01-01T00:00:00Z""#;
        let ev = |rest: &str| format!("{{{base},{rest}}}");
        assert_eq!(hook(&ev(r#""hook_event_name":"SessionStart","source":"startup""#)), Some(("starting", None, vec![])));
        assert_eq!(hook(&ev(r#""hook_event_name":"BeforeAgent","prompt":"\n fix the build\nand test""#)), Some(("running", None, vec![("prompt", "fix the build".to_string())])));
        assert_eq!(
            hook(&ev(r#""hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"description":"Run","command":"npm  test"}"#)),
            Some(("running", None, vec![("tool", "run_shell_command".to_string()), ("tool_input", "npm test".to_string())]))
        );
        assert_eq!(hook(&ev(r#""hook_event_name":"AfterTool","tool_name":"read_file","tool_input":{},"tool_response":{}"#)), Some(("running", None, vec![])));
        assert_eq!(hook(&ev(r#""hook_event_name":"AfterAgent","prompt":"hi","prompt_response":"Done.\n\n- one","stop_hook_active":false"#)), Some(("done", Some("Done. - one".to_string()), vec![])));
        let long = hook(&ev(&format!(r#""hook_event_name":"AfterAgent","prompt_response":"{}Push it?""#, "word ".repeat(200)))).unwrap();
        assert_eq!(long.1.unwrap().chars().count(), RESULT_MAX);
        assert!(long.2[0].0 == "tail" && long.2[0].1.ends_with("Push it?"));
        assert_eq!(
            hook(&ev(r#""hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow run_shell_command?","details":{}"#)),
            Some(("waiting", Some("Allow run_shell_command?".to_string()), vec![]))
        );
        assert_eq!(hook(&ev(r#""hook_event_name":"SessionEnd","reason":"exit""#)), Some(("clear", None, vec![])));
        // Events that say nothing about the agent's state.
        for quiet in ["BeforeModel", "AfterModel", "BeforeToolSelection", "PreCompress", ""] {
            assert_eq!(hook(&ev(&format!(r#""hook_event_name":"{quiet}""#))), None, "{quiet}");
        }
    }

    fn backups(dir: &Path, name: &str) -> usize {
        std::fs::read_dir(dir).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().starts_with(&format!("{name}.clotho-backup-"))).count()
    }

    /// Gemini CLI's settings.json: installed into a temp home, never the real one.
    #[test]
    fn gemini_hooks_install_is_idempotent_and_uninstall_restores() {
        let snippet = gemini_snippet();
        // What `hooks print gemini` shows: every event runs our command, tool events for any tool.
        for (event, matcher) in GEMINI_EVENTS {
            let group = &snippet["hooks"][event][0];
            assert_eq!(group["matcher"].as_str(), matcher, "{event}");
            assert_eq!(group["hooks"][0]["type"], "command", "{event}");
            let command = group["hooks"][0]["command"].as_str().unwrap();
            assert!(command.contains("report --gemini-hook") && command.ends_with(MARKER), "{event}: {command}");
        }
        assert_eq!(snippet["hooks"].as_object().unwrap().len(), GEMINI_EVENTS.len());

        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join(".gemini");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        // The user's own: other settings, a hook on an event we also use, one we don't, and an
        // event they left empty.
        let original = r#"{
  "theme": "GitHub",
  "hooks": {
    "AfterAgent": [
      {
        "hooks": [
          {
            "name": "mine",
            "type": "command",
            "command": "echo mine"
          }
        ]
      }
    ],
    "BeforeModel": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo model"
          }
        ]
      }
    ],
    "PreCompress": []
  },
  "model": {
    "name": "gemini-pro"
  }
}
"#;
        std::fs::write(&path, original).unwrap();
        let status = |p: &Path| hooks_status(&read_json(p).unwrap(), &gemini_snippet());
        assert_eq!(status(&path), "not installed");
        assert!(install_hooks(&path, &snippet).unwrap().ends_with(": installed"));
        assert_eq!(backups(&dir, "settings.json"), 1, "a backup of the user's file");
        let once = std::fs::read_to_string(&path).unwrap();
        assert!(install_hooks(&path, &snippet).unwrap().ends_with(": already installed"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), once, "idempotent");
        assert_eq!(status(&path), "installed");
        let s = read_json(&path).unwrap();
        assert_eq!((&s["theme"], &s["model"]["name"]), (&json!("GitHub"), &json!("gemini-pro")));
        let after = s["hooks"]["AfterAgent"].as_array().unwrap();
        assert_eq!(after.len(), 2);
        assert_eq!(after[0]["hooks"][0]["command"], "echo mine", "the user's hook kept, and first");
        assert!(is_ours(&after[1]["hooks"][0]));
        assert_eq!(s["hooks"]["BeforeModel"][0]["hooks"][0]["command"], "echo model");
        for (event, _) in GEMINI_EVENTS {
            assert_eq!(claude_ours(&s).get(event).map(Vec::len), Some(1), "{event}");
        }
        // An older clothod's command is outdated, and install replaces it in place.
        std::fs::write(&path, once.replace("report --gemini-hook", "report --gemini-hook --old")).unwrap();
        assert_eq!(status(&path), "outdated");
        assert!(install_hooks(&path, &snippet).unwrap().ends_with(": installed"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), once);
        assert!(uninstall_hooks(&path).unwrap().ends_with(": uninstalled"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original, "uninstall restores the file");
        assert_eq!(status(&path), "not installed");
        assert!(uninstall_hooks(&path).unwrap().ends_with(": not installed"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);

        // No settings yet: install makes the file (and its directory), uninstall leaves `{}`.
        let fresh = home.path().join("fresh").join(".gemini").join("settings.json");
        assert_eq!(hooks_status(&read_json(&fresh).unwrap(), &snippet), "not installed");
        assert!(uninstall_hooks(&fresh).unwrap().ends_with(": not installed"));
        assert!(!fresh.exists());
        assert!(install_hooks(&fresh, &snippet).unwrap().ends_with(": installed"));
        assert_eq!(read_json(&fresh).unwrap(), snippet);
        uninstall_hooks(&fresh).unwrap();
        assert_eq!(read_json(&fresh).unwrap(), json!({}));
        // A file that isn't what we expect is left as it is.
        std::fs::write(&fresh, "[1, 2]").unwrap();
        assert!(install_hooks(&fresh, &snippet).is_err());
        std::fs::write(&fresh, "{ not json").unwrap();
        assert!(install_hooks(&fresh, &snippet).is_err() && uninstall_hooks(&fresh).is_err());
        assert_eq!(std::fs::read_to_string(&fresh).unwrap(), "{ not json");
    }

    /// Copilot CLI's user-level hooks directory: our own file there, in a temp home.
    #[test]
    fn copilot_hooks_install_is_idempotent_and_uninstall_removes_only_ours() {
        let snippet = copilot_snippet();
        // What `hooks print copilot` shows.
        assert_eq!(snippet["version"], 1);
        assert_eq!(snippet["hooks"].as_object().unwrap().len(), COPILOT_EVENTS.len());
        for (event, state, matcher) in COPILOT_EVENTS {
            let hook = &snippet["hooks"][event][0];
            assert_eq!((&hook["type"], &hook["timeoutSec"]), (&json!("command"), &json!(COPILOT_TIMEOUT_S)), "{event}");
            assert_eq!(hook["matcher"].as_str(), matcher, "{event}");
            let command = hook["bash"].as_str().unwrap();
            assert!(command.contains(&format!("report {state} --agent copilot; true")) && command.ends_with(MARKER), "{event}: {command}");
            // What the command passes is the hooks' silent form, with that state and kind.
            let r = parse_report(&strings(&[state, "--agent", "copilot"])).unwrap();
            assert_eq!((r.state.as_deref(), r.kind.as_deref(), r.by_hand), (Some(state), Some("copilot"), false));
        }

        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join(".copilot").join("hooks");
        let path = dir.join("clotho.json");
        assert_eq!(copilot_status(&path), "not installed");
        assert!(uninstall_copilot(&path).unwrap().ends_with(": not installed"));
        // The user's own hook file, next to where ours goes.
        std::fs::create_dir_all(&dir).unwrap();
        let theirs = dir.join("notification-hooks.json");
        let original = "{\n  \"version\": 1,\n  \"hooks\": {\"agentStop\": [{\"type\": \"command\", \"bash\": \"echo mine\"}]}\n}\n";
        std::fs::write(&theirs, original).unwrap();
        assert!(install_copilot(&path).unwrap().ends_with(": installed"));
        let once = std::fs::read_to_string(&path).unwrap();
        assert_eq!(read_json(&path).unwrap(), snippet);
        assert!(install_copilot(&path).unwrap().ends_with(": already installed"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), once, "idempotent");
        assert_eq!(copilot_status(&path), "installed");
        assert_eq!(backups(&dir, "clotho.json"), 0, "nothing of the user's was replaced");
        // An older clothod's file is outdated; install backs it up and replaces it.
        std::fs::write(&path, once.replace("--agent copilot", "--agent copilot --old")).unwrap();
        assert_eq!(copilot_status(&path), "outdated");
        assert!(install_copilot(&path).unwrap().ends_with(": installed"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), once);
        assert_eq!(backups(&dir, "clotho.json"), 1);
        assert!(uninstall_copilot(&path).unwrap().ends_with(": uninstalled"));
        assert!(!path.exists());
        assert_eq!(copilot_status(&path), "not installed");
        assert_eq!(std::fs::read_to_string(&theirs).unwrap(), original, "the user's hook file untouched");
        // A file of our name that isn't ours is never written over or removed.
        std::fs::write(&path, original).unwrap();
        assert_eq!(copilot_status(&path), "not installed");
        assert!(install_copilot(&path).is_err());
        assert!(uninstall_copilot(&path).unwrap().ends_with(": not installed"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    /// Removing ours leaves what the user had as it was, empty lists included.
    #[test]
    fn removing_our_hooks_keeps_what_the_user_left_empty() {
        let mut s = json!({"hooks": {"Stop": [], "PreToolUse": [{"matcher": "*", "hooks": []}], "disabled": ["x"]}, "model": "opus"});
        let before = s.clone();
        assert!(!claude_remove(&mut s));
        assert_eq!(s, before);
        let snippet = claude_snippet();
        for (event, groups) in snippet["hooks"].as_object().unwrap() {
            let list = s["hooks"].as_object_mut().unwrap().entry(event.clone()).or_insert_with(|| json!([]));
            list.as_array_mut().unwrap().extend(groups.as_array().unwrap().iter().cloned());
        }
        assert_eq!(claude_status(&s), "installed");
        assert!(claude_remove(&mut s));
        assert_eq!(s["hooks"]["PreToolUse"], before["hooks"]["PreToolUse"]);
        assert_eq!(s["hooks"]["disabled"], json!(["x"]));
        assert_eq!(s["hooks"].as_object().unwrap().len(), 2, "`Stop` held only ours after install, so it goes: {s}");
    }
}
