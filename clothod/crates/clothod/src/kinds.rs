//! Agent kinds: the one table for which programs are agents, what a reported kind may be
//! called, and which kinds clothod can resume. docs/protocol.md, "Agents".
//!
//! Hooks (`clothod hooks`, see `agents.rs`) exist for claude, codex, gemini and copilot. The
//! other kinds are found by their process name only, and their state comes from the screen and
//! the terminal (BEL, OSC notifications):
//! - opencode and amp extend through plugins, which are code, not a config file to merge into;
//! - cursor's docs don't say its terminal agent runs the agent hooks of `hooks.json`;
//! - aider has no hooks. `aider --notifications` runs a desktop notifier where the machine has
//!   one (terminal-notifier or osascript, notify-send or zenity) and rings the terminal bell
//!   only where it has none, so the bell alone is not reliable. Its `--notifications-command`
//!   runs any shell command when aider next waits for input, so
//!   `aider --notifications-command 'clothod report done --agent aider'` reports each turn's end.

/// Kinds found by an exact process name: (name, kind). Cursor's terminal agent is
/// `cursor-agent`; its other name, `agent`, is too generic to match.
const NAMED: [(&str, &str); 6] =
    [("opencode", "opencode"), ("gemini", "gemini"), ("copilot", "copilot"), ("aider", "aider"), ("amp", "amp"), ("cursor-agent", "cursor")];

/// A program that runs a script named in its arguments: `node .../gemini`, `python .../aider`,
/// or a shell running a wrapper script that carries the agent's name (`#!/bin/sh` in a file
/// called `gemini`).
fn interpreter(name: &str) -> bool {
    matches!(name, "node" | "bun" | "deno" | "sh" | "bash" | "dash" | "zsh") || name.starts_with("python")
}

/// The agent a process is, from the names that identify it
/// ([`clotho_proto::platform::process_names`]: executable, process name, then argv[0..2]
/// basenames).
///
/// Claude and Codex match on any of the names (`node .../claude`, the native `claude.exe` and
/// `codex-<target>`). The other kinds match the process's own name (the first), or a later name
/// only after an interpreter's: `node .../gemini` is Gemini, `vim gemini` is not.
pub fn agent_kind(names: &[String]) -> Option<&'static str> {
    for n in names {
        let n = n.to_ascii_lowercase();
        if n == "claude" || n.starts_with("claude-") || n == "claude.exe" {
            return Some("claude");
        }
        if n == "codex" || n.starts_with("codex-") {
            return Some("codex");
        }
    }
    let mut interpreted = false;
    for (i, n) in names.iter().enumerate() {
        let n = n.to_ascii_lowercase();
        if i == 0 || interpreted {
            if let Some((_, kind)) = NAMED.iter().find(|(name, _)| *name == n) {
                return Some(kind);
            }
        }
        interpreted |= interpreter(&n);
    }
    None
}

/// Whether `kind` is one of the agents clothod knows by name. A report that names one is that
/// agent's (its hooks), whatever the process list shows; any other kind is a script's or a
/// tool's own.
pub fn known(kind: &str) -> bool {
    matches!(kind, "claude" | "codex") || NAMED.iter().any(|(_, k)| *k == kind)
}

/// Longest kind name, in bytes.
const KIND_MAX: usize = 32;

/// A reported kind as clothod stores, shows and logs it: lowercased, and `other` unless it is
/// 1 to 32 of `[a-z0-9._-]`. A kind is printed in the decision log, so it must not hold spaces
/// or anything else that could read as another field.
pub fn normalise(kind: &str) -> String {
    let k = kind.to_ascii_lowercase();
    let ok = (1..=KIND_MAX).contains(&k.len()) && k.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-'));
    if ok {
        k
    } else {
        "other".into()
    }
}

/// Whether clothod can type a line that resumes an agent of this kind
/// ([`crate::layout::resume_line`], [`crate::layout::continue_line`]). No other kind has a
/// resume command that is both verified and backed by a session id clothod learns.
pub fn resumable(kind: &str) -> bool {
    matches!(kind, "claude" | "codex")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind(names: &[&str]) -> Option<&'static str> {
        agent_kind(&names.iter().map(|n| n.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn claude_and_codex_match_as_before() {
        assert_eq!(kind(&["claude"]), Some("claude"));
        assert_eq!(kind(&["node", "claude"]), Some("claude"));
        assert_eq!(kind(&["claude.exe"]), Some("claude"));
        assert_eq!(kind(&["Claude"]), Some("claude"));
        assert_eq!(kind(&["claude-code"]), Some("claude"));
        assert_eq!(kind(&["codex"]), Some("codex"));
        assert_eq!(kind(&["codex-x86_64-unknown-linux-musl"]), Some("codex"));
        assert_eq!(kind(&["node", "MainThread", "node", "codex"]), Some("codex"));
        // Any position, as before: these two are not held to the interpreter rule.
        assert_eq!(kind(&["vim", "claude"]), Some("claude"));
        assert_eq!(kind(&["claudette"]), None);
        assert_eq!(kind(&["zsh", "-zsh"]), None);
        assert_eq!(kind(&[]), None);
        // Claude and Codex win over another kind's name in the same process.
        assert_eq!(kind(&["gemini", "codex"]), Some("codex"));
    }

    #[test]
    fn each_new_kind_matches_its_own_process_name() {
        for (name, k) in [("opencode", "opencode"), ("gemini", "gemini"), ("copilot", "copilot"), ("aider", "aider"), ("amp", "amp"), ("cursor-agent", "cursor")] {
            assert_eq!(kind(&[name]), Some(k), "{name}");
            assert_eq!(kind(&[name, "--model", "x"]), Some(k), "{name} with arguments");
            assert_eq!(kind(&[&name.to_uppercase()]), Some(k), "{name} in capitals");
        }
        // Cursor's other name is too generic, and a kind's name is matched whole.
        assert_eq!(kind(&["agent"]), None);
        assert_eq!(kind(&["cursor"]), None);
        assert_eq!(kind(&["amplify"]), None);
        assert_eq!(kind(&["gemini.py"]), None);
    }

    #[test]
    fn new_kinds_match_an_argument_only_after_an_interpreter() {
        assert_eq!(kind(&["node", "gemini"]), Some("gemini"));
        assert_eq!(kind(&["node", "MainThread", "node", "copilot"]), Some("copilot"));
        assert_eq!(kind(&["bun", "amp"]), Some("amp"));
        assert_eq!(kind(&["deno", "opencode"]), Some("opencode"));
        assert_eq!(kind(&["python", "aider"]), Some("aider"));
        // A script started by its `#!`: the executable is the interpreter, the process name the
        // script's.
        assert_eq!(kind(&["python3.12", "aider", "python3", "aider"]), Some("aider"));
        // A wrapper script: the shell is the executable.
        assert_eq!(kind(&["dash", "gemini", "sh"]), Some("gemini"));
        assert_eq!(kind(&["sh", "cursor-agent"]), Some("cursor"));
        assert_eq!(kind(&["zsh", "-zsh"]), None);
        assert_eq!(kind(&["bash", "-c"]), None);
        assert_eq!(kind(&["vim", "gemini"]), None);
        assert_eq!(kind(&["less", "aider"]), None);
        assert_eq!(kind(&["git", "amp"]), None);
        assert_eq!(kind(&["cat", "node", "gemini"]), Some("gemini"));
        assert_eq!(kind(&["node", "server.js"]), None);
    }

    #[test]
    fn normalise_keeps_a_plain_name_and_nothing_else() {
        assert_eq!(normalise("claude"), "claude");
        assert_eq!(normalise("my-tool_2.1"), "my-tool_2.1");
        assert_eq!(normalise("MyTool"), "mytool");
        assert_eq!(normalise(&"a".repeat(32)), "a".repeat(32));
        assert_eq!(normalise(&"a".repeat(33)), "other");
        for bad in ["", " ", "my tool", "x state=waiting", "a\nb", "é", "a/b", "a=b", "tool\u{1b}[31m"] {
            assert_eq!(normalise(bad), "other", "{bad:?}");
        }
    }

    #[test]
    fn only_claude_and_codex_resume() {
        assert!(resumable("claude") && resumable("codex"));
        for k in ["opencode", "gemini", "copilot", "aider", "amp", "cursor", "other", "mytool", ""] {
            assert!(!resumable(k), "{k}");
            assert_eq!(crate::layout::continue_line(k), None, "{k}");
            let saved = crate::layout::SavedAgent { kind: k.into(), session: Some("24e0052b-aa".into()) };
            assert_eq!(crate::layout::resume_line(&saved), None, "{k}");
        }
    }
}
