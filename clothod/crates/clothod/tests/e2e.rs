//! End-to-end tests: real `clothod serve` and `clothod holder` processes, real shells, and the
//! protocol client from the `clotho` crate.

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use clotho::{wait_for_text, Client, Screen};
use clotho_proto::Frame;
use serde_json::{json, Value};

const T: Duration = Duration::from_secs(15);

struct Env {
    dir: tempfile::TempDir,
    daemon: Option<Child>,
}

impl Env {
    fn new() -> Env {
        let mut env = Env::empty();
        env.start();
        env
    }

    /// No daemon started yet.
    fn empty() -> Env {
        static SWEEP: std::sync::Once = std::sync::Once::new();
        SWEEP.call_once(|| {
            // Test instances are temporary: they end themselves when unused (and are shut down
            // by Drop). Everything started from here inherits this.
            std::env::set_var("CLOTHOD_EPHEMERAL", "60");
            // Never the user's real gh (and GitHub login): tests that want one use a stub.
            std::env::set_var("CLOTHOD_GH", "/nonexistent/gh");
            sweep_stale_test_instances();
        });
        // Short path: Unix socket paths are limited to ~104 bytes.
        let dir = tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap();
        std::fs::create_dir_all(dir.path().join("run")).unwrap();
        Env { dir, daemon: None }
    }

    /// The runtime dir (sockets, locks).
    fn path(&self) -> PathBuf {
        self.dir.path().join("run")
    }

    /// The state dir (logs, `*.live`), outside the runtime dir as in real installs.
    fn state(&self) -> PathBuf {
        self.dir.path().join("state")
    }

    fn start(&mut self) {
        let bin = std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into());
        self.start_with(&bin, &[]);
    }

    /// Run `clothod serve` from `bin`, expecting it to exit; returns (exit code, its log).
    fn run_serve_expect_exit(&self, bin: &str) -> (Option<i32>, String) {
        let out = Command::new(bin)
            .arg("serve")
            .arg("--runtime-dir")
            .arg(self.path())
            .env("CLOTHOD_STATE_DIR", self.state())
            .stdin(Stdio::null())
            .output()
            .unwrap();
        (out.status.code(), String::from_utf8_lossy(&out.stderr).into_owned())
    }

    fn start_with(&mut self, bin: &str, env: &[(&str, &str)]) {
        let log = std::fs::OpenOptions::new().create(true).append(true).open(self.dir.path().join("serve.log")).unwrap();
        // CLOTHOD_BIN lets cross-built test binaries run on another machine.
        let mut cmd = Command::new(bin);
        cmd.arg("serve").arg("--runtime-dir").arg(self.path()).env("CLOTHOD_STATE_DIR", self.state());
        // Keep test daemons (and `report` in their panes) away from the user's real ones.
        cmd.env("CLOTHOD_RUNTIME_DIR", self.path()).env("CLOTHOD_REGISTRY_DIR", self.dir.path().join("registry"));
        // Never the user's ~/.config/clothod/config.toml.
        cmd.env("CLOTHOD_CONFIG", self.dir.path().join("config.toml"));
        // Never the user's ~/.claude (detection reads Claude Code's session records there).
        cmd.env("CLAUDE_CONFIG_DIR", self.dir.path().join("claude-config"));
        for (k, v) in env {
            cmd.env(k, v);
        }
        let child = cmd
            .stdin(Stdio::null())
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap();
        self.daemon = Some(child);
        let deadline = Instant::now() + T;
        while std::os::unix::net::UnixStream::connect(self.path().join("clothod.sock")).is_err() {
            assert!(Instant::now() < deadline, "daemon did not start:\n{}", self.log());
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// SIGKILL the logic process (the holder and shells keep running).
    fn kill(&mut self) {
        if let Some(mut c) = self.daemon.take() {
            c.kill().unwrap();
            c.wait().unwrap();
        }
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.dir.path().join("serve.log")).unwrap_or_default()
    }

    async fn client(&self) -> Client {
        Client::connect(&self.path()).await.unwrap()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        self.kill();
        if let Ok(pid) = std::fs::read_to_string(self.state().join("holder.live")).or_else(|_| std::fs::read_to_string(self.path().join("holder.pid"))) {
            if let Ok(pid) = pid.trim().parse::<i32>() {
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        }
        // Every process of this instance must be gone before the temp dir is: a daemon this
        // test didn't start itself (after an upgrade, or a login unit's) would otherwise heal
        // its socket by recreating the dir, and leave an empty /tmp/clt* behind when it ends.
        let dir = self.path().to_string_lossy().into_owned();
        let ours = || -> Vec<u32> {
            clotho_proto::platform::own_processes()
                .into_iter()
                .filter(|p| p.pid != std::process::id() && p.args.windows(2).any(|w| w[0] == "--runtime-dir" && w[1] == dir))
                .map(|p| p.pid)
                .collect()
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut signal = libc::SIGTERM;
        loop {
            let left = ours();
            if left.is_empty() {
                break;
            }
            if Instant::now() >= deadline {
                signal = libc::SIGKILL;
            }
            for pid in &left {
                unsafe { libc::kill(*pid as i32, signal) };
            }
            if signal == libc::SIGKILL {
                std::thread::sleep(Duration::from_millis(100));
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

/// `want` is a line of the screen. Output can also land on the prompt line (`$ want`), when
/// input arrives before the shell has printed its prompt and the terminal echoes it early.
/// A line of a command's output, as the screen shows it. Under load the shell can start after
/// the typed line was echoed and draw its prompt right before the output (`$ out`), so waits on
/// command output match with or without that prompt.
fn has_line(lines: &[String], want: &str) -> bool {
    lines.iter().any(|l| output(l) == want)
}

/// `line` without a prompt the shell drew late in front of it.
fn output(line: &str) -> &str {
    line.strip_prefix("$ ").unwrap_or(line)
}

/// Spawn options plus a request's own params.
fn with(mut opts: Value, params: Value) -> Value {
    for (k, v) in params.as_object().unwrap() {
        opts[k] = v.clone();
    }
    opts
}

fn sh() -> Value {
    json!({"command": ["/bin/sh"], "env": {"PS1": "$ ", "ENV": ""}, "cols": 80, "rows": 24})
}

/// vim, or the minimal vim many Linux installs ship.
fn vim() -> Option<&'static str> {
    ["vim", "vim.tiny", "vi"].into_iter().find(|v| have(v) && Command::new(v).arg("--version").output().is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("VIM")))
}

fn have(cmd: &str) -> bool {
    Command::new("sh").arg("-c").arg(format!("command -v {cmd}")).stdout(Stdio::null()).status().is_ok_and(|s| s.success())
}

async fn new_pane(c: &Client, params: Value) -> u64 {
    c.request("workspace.create", params).await.unwrap()["pane"].as_u64().unwrap()
}

async fn daemon_seq(c: &Client, pane: u64) -> u64 {
    c.request("pane.text", json!({"pane": pane})).await.unwrap()["seq"].as_u64().unwrap()
}

/// Receive frames into `screen` until it has caught up with the daemon's seq for the pane and
/// the pane has been quiet for a moment.
async fn sync(c: &mut Client, screen: &mut Screen) -> Result<()> {
    let deadline = Instant::now() + T;
    loop {
        let target = daemon_seq(c, screen.pane).await;
        while screen.seq < target {
            match tokio::time::timeout(Duration::from_millis(500), c.recv()).await {
                Ok(Some(f)) => {
                    screen.apply(&f);
                }
                Ok(None) => bail!("disconnected"),
                Err(_) => {}
            }
            if Instant::now() > deadline {
                bail!("screen stuck at {} (daemon at {target})", screen.seq);
            }
        }
        while let Some(f) = c.try_recv() {
            screen.apply(&f);
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
        if daemon_seq(c, screen.pane).await == screen.seq {
            return Ok(());
        }
    }
}

async fn daemon_text(c: &Client, pane: u64) -> (Vec<String>, Value) {
    let t = c.request("pane.text", json!({"pane": pane})).await.unwrap();
    let lines = t["lines"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_string()).collect();
    (lines, t["cursor"].clone())
}

async fn subscribe(c: &mut Client, pane: u64, have: Option<u64>) -> (Value, Screen) {
    let mut p = json!({"pane": pane});
    if let Some(h) = have {
        p["have_seq"] = json!(h);
    }
    let r = c.request("pane.subscribe", p).await.unwrap();
    let mut screen = Screen::new(pane, r["cols"].as_u64().unwrap() as u16, r["rows"].as_u64().unwrap() as u16);
    screen.seq = r["seq"].as_u64().unwrap();
    (r, screen)
}

fn assert_same_screen(a: &Screen, b: &Screen) {
    assert_eq!(a.text(), b.text(), "screens differ");
    assert_eq!(a.vt.cursor(), b.vt.cursor(), "cursors differ");
}

async fn assert_matches_daemon(c: &Client, s: &Screen) {
    let (lines, cursor) = daemon_text(c, s.pane).await;
    assert_eq!(s.text(), lines, "client screen differs from the daemon's");
    assert_eq!(json!([s.vt.cursor().0, s.vt.cursor().1]), cursor);
}

const FULLSCREEN_APP: &str = r#"printf '\033[?1049h\033[H\033[2J\033[1;37;44m TOP \033[0m\n\033[31mred\033[0m and \033[1mbold\033[0m\n\033[5;10H\033[7mplaced\033[0m\033[3;1H'; cat"#;

/// `clear` after a command line that wrapped: a fresh subscribe's snapshot shows only what
/// followed the clear, as the daemon's screen does (the cleared rows are scrollback).
#[tokio::test]
async fn a_snapshot_after_clear_shows_only_the_screen() {
    let env = Env::new();
    let c = env.client().await;
    let mut params = sh();
    params["cols"] = json!(30);
    params["rows"] = json!(10);
    let p = new_pane(&c, params).await;
    c.input(p, format!("mkdir -p /tmp/{0} && cd /tmp/{0} && clear; printf 'saved screen 42\\n'; cd /\r", "x".repeat(40)).as_bytes());
    wait_for_text(&c, p, T, |l| has_line(l, "saved screen 42")).await.unwrap();
    let (lines, _) = daemon_text(&c, p).await;
    assert_eq!(lines[0], "saved screen 42", "clear left the command line on screen: {lines:?}");
    let mut fresh = env.client().await;
    let (_, mut s) = subscribe(&mut fresh, p, None).await;
    sync(&mut fresh, &mut s).await.unwrap();
    assert_matches_daemon(&fresh, &s).await;
    drop(c);
    let _ = std::fs::remove_dir(format!("/tmp/{}", "x".repeat(40)));
}

/// A shell that doesn't report its directory (no OSC 7, like macOS zsh): a `cd` alone, with no
/// other activity in the pane, still reaches clients as a `pane` event with the new cwd.
#[tokio::test]
async fn a_cd_shows_up_without_osc7() {
    let env = Env::new();
    let mut c = env.client().await;
    c.request("events.subscribe", json!({})).await.unwrap();
    let p = new_pane(&c, sh()).await;
    let dir = env.dir.path().join("somewhere").canonicalize().unwrap_or_else(|_| {
        std::fs::create_dir_all(env.dir.path().join("somewhere")).unwrap();
        env.dir.path().join("somewhere").canonicalize().unwrap()
    });
    tokio::time::sleep(Duration::from_millis(1500)).await;
    while c.try_recv().is_some() {}
    c.input(p, format!("cd '{}'\r", dir.display()).as_bytes());
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match tokio::time::timeout(Duration::from_millis(200), c.recv()).await {
            Ok(Some(Frame::Json(v))) if v["event"] == "pane" && v["data"]["id"] == p && v["data"]["cwd"] == json!(dir.display().to_string()) => break,
            Ok(None) => panic!("disconnected"),
            _ => {}
        }
        assert!(Instant::now() < deadline, "no pane event with cwd {}", dir.display());
    }
}

#[tokio::test]
async fn detach_reattach_gets_the_exact_screen() {
    let env = Env::new();
    let mut c1 = env.client().await;
    let pane = new_pane(&c1, sh()).await;
    let (r, mut s1) = subscribe(&mut c1, pane, None).await;
    assert_eq!(r["mode"], "snapshot");

    c1.input(pane, b"echo before-app\r");
    wait_for_text(&c1, pane, T, |l| has_line(l, "before-app")).await.unwrap();
    let vim = vim();
    if let Some(vim) = vim {
        c1.input(pane, format!("{vim} -u NONE -i NONE -N -n /tmp/clotho-e2e-scratch.txt\r").as_bytes());
        wait_for_text(&c1, pane, T, |l| l.last().is_some_and(|l| l.contains("clotho-e2e-scratch"))).await.unwrap();
        c1.input(pane, b"ihello from vim\x1boline two\x1b:set number\r");
        wait_for_text(&c1, pane, T, |l| l.iter().any(|l| l.contains("2 line two"))).await.unwrap();
    } else {
        c1.input(pane, format!("{FULLSCREEN_APP}\r").as_bytes());
        wait_for_text(&c1, pane, T, |l| l.iter().any(|l| l.contains("placed"))).await.unwrap();
    }
    sync(&mut c1, &mut s1).await.unwrap();
    assert_matches_daemon(&c1, &s1).await;

    // Detach (drop the connection), reattach from a fresh client: same screen.
    let seq = s1.seq;
    drop(c1);
    let mut c2 = env.client().await;
    let (r, mut s2) = subscribe(&mut c2, pane, None).await;
    assert_eq!(r["mode"], "snapshot");
    sync(&mut c2, &mut s2).await.unwrap();
    assert_eq!(s2.seq, seq);
    assert_same_screen(&s1, &s2);
    assert_eq!(s2.snapshots, 1);

    // Leaving the full-screen app restores the primary screen from the snapshot's state.
    if vim.is_some() {
        c2.input(pane, b":q!\r");
    } else {
        c2.input(pane, b"\x04");
        c2.input(pane, b"printf '\\033[?1049l'\r");
    }
    wait_for_text(&c2, pane, T, |l| has_line(l, "before-app") && l.iter().all(|l| !l.contains("placed") && !l.contains("line two"))).await.unwrap();
    sync(&mut c2, &mut s2).await.unwrap();
    assert_matches_daemon(&c2, &s2).await;
}

#[tokio::test]
async fn killing_the_logic_process_keeps_shells_and_screens() {
    let mut env = Env::new();
    let mut c = env.client().await;
    let p1 = new_pane(&c, sh()).await;
    let mut p2_params = sh();
    p2_params["command"] = json!(["/bin/sh", "-c", "read x; echo during-down; exec cat"]);
    let p2 = new_pane(&c, p2_params).await;
    c.request("pane.split", json!({"pane": p1, "direction": "down", "command": ["/bin/sh"], "env": {"PS1": "$ "}})).await.unwrap();

    c.input(p1, b"echo one; ");
    c.input(p1, FULLSCREEN_APP.as_bytes());
    c.input(p1, b"\r");
    wait_for_text(&c, p1, T, |l| l.iter().any(|l| l.contains("placed"))).await.unwrap();
    let (_, mut s1) = subscribe(&mut c, p1, None).await;
    sync(&mut c, &mut s1).await.unwrap();
    let before = daemon_text(&c, p1).await;
    let state_before = c.request("state.get", json!({})).await.unwrap();

    env.kill();
    drop(c);
    assert!(std::os::unix::net::UnixStream::connect(env.path().join("clothod.sock")).is_err(), "daemon should be gone");

    env.start();
    let mut c = env.client().await;
    let state = c.request("state.get", json!({})).await.unwrap();
    assert_eq!(state["workspaces"], state_before["workspaces"], "model survives restart");
    assert_eq!(daemon_text(&c, p1).await, before, "screen survives restart");

    // A client that was attached before resumes without a snapshot: the buffer came back too.
    let (r, mut s1b) = subscribe(&mut c, p1, Some(s1.seq)).await;
    assert_eq!(r["mode"], "live");
    s1b.vt = s1.vt;
    c.input(p1, b"\x04"); // end `cat`
    c.input(p1, b"printf '\\033[?1049l'; echo alive-$((40+2))\r");
    wait_for_text(&c, p1, T, |l| has_line(l, "alive-42")).await.unwrap();
    sync(&mut c, &mut s1b).await.unwrap();
    assert_matches_daemon(&c, &s1b).await;
    let (lines, _) = daemon_text(&c, p1).await;
    assert!(lines.iter().any(|l| l.contains("one")), "primary screen from before the restart: {lines:?}");

    c.input(p2, b"go\r");
    wait_for_text(&c, p2, T, |l| has_line(l, "during-down")).await.unwrap();
}

#[tokio::test]
async fn output_while_the_logic_process_is_down_is_kept() {
    let mut env = Env::new();
    let c = env.client().await;
    let mut params = sh();
    params["command"] = json!(["/bin/sh", "-c", "sleep 1; echo printed-while-down; exec cat"]);
    let p = new_pane(&c, params).await;
    drop(c);
    env.kill();
    tokio::time::sleep(Duration::from_millis(1500)).await;
    env.start();
    let c = env.client().await;
    wait_for_text(&c, p, Duration::from_secs(2), |l| has_line(l, "printed-while-down")).await.unwrap();
}

#[tokio::test]
async fn restart_after_heavy_output_uses_the_pushed_snapshot() {
    let mut env = Env::new();
    let mut c = env.client().await;
    let p = new_pane(&c, sh()).await;
    // ~6 MB: more than the 4 MiB buffer, so recovery has to start from a pushed snapshot.
    // One process, not a fork per line: under Rosetta the shell is translated too, and 60000
    // forks alone outlast the timeout.
    c.input(p, b"awk 'BEGIN { for (i = 0; i < 60000; i++) printf \"line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n\", i }'; echo done-$((1+1))\r");
    wait_for_text(&c, p, Duration::from_secs(120), |l| has_line(l, "done-2")).await.unwrap();
    let (_, mut s) = subscribe(&mut c, p, None).await;
    sync(&mut c, &mut s).await.unwrap();
    let seq = daemon_seq(&c, p).await;
    assert!(seq > 5 << 20, "expected > 5 MiB of output, got {seq}");
    let before = daemon_text(&c, p).await;
    drop(c);
    env.kill();
    env.start();
    let c = env.client().await;
    assert_eq!(daemon_text(&c, p).await, before);
    assert!(env.log().contains("recovered 1 panes"));
    assert!(!env.log().contains("outside the buffer"), "{}", env.log());
}

#[tokio::test]
async fn resume_sends_only_missed_output_or_a_snapshot() {
    let env = Env::new();
    let mut reference = env.client().await;
    let p = new_pane(&reference, sh()).await;
    let (_, mut full) = subscribe(&mut reference, p, Some(0)).await;
    assert_eq!(full.seq, 0);

    let mut c = env.client().await;
    let (_, mut s) = subscribe(&mut c, p, None).await;
    c.input(p, b"echo first\r");
    wait_for_text(&c, p, T, |l| has_line(l, "first")).await.unwrap();
    sync(&mut c, &mut s).await.unwrap();
    let n = s.seq;
    drop(c);

    // Up to date: nothing to send.
    let mut c = env.client().await;
    let (r, _) = subscribe(&mut c, p, Some(n)).await;
    assert_eq!(r["mode"], "live");
    drop(c);

    // Small gap: exactly the missed bytes.
    reference.input(p, b"for i in 1 2 3 4 5; do echo missed-$i; done\r");
    wait_for_text(&reference, p, T, |l| has_line(l, "missed-5")).await.unwrap();
    sync(&mut reference, &mut full).await.unwrap();
    let mut c = env.client().await;
    let (r, mut resumed) = subscribe(&mut c, p, Some(n)).await;
    assert_eq!(r["mode"], "replay");
    assert_eq!(r["seq"], n);
    resumed.vt = clotho_vt::Vt::new(80, 24);
    resumed.vt.feed(&full.output[..n as usize]);
    sync(&mut c, &mut resumed).await.unwrap();
    assert_eq!(resumed.output, full.output[n as usize..], "replay must be exactly the missed bytes");
    assert_eq!(resumed.snapshots, 0);
    assert_matches_daemon(&c, &resumed).await;
    drop(c);

    // Large gap (> 1 MiB): a snapshot instead.
    reference.input(p, b"head -c 1500000 /dev/zero | tr '\\0' 'y'; echo; echo big-done\r");
    wait_for_text(&reference, p, T, |l| has_line(l, "big-done")).await.unwrap();
    let mut c = env.client().await;
    let (r, mut resumed) = subscribe(&mut c, p, Some(n)).await;
    assert_eq!(r["mode"], "snapshot");
    sync(&mut c, &mut resumed).await.unwrap();
    assert_eq!(resumed.snapshots, 1);
    assert!(resumed.output.len() < 4096, "no bulk replay after a snapshot");
    assert_matches_daemon(&c, &resumed).await;

    // A seq from the future (stale cache from another instance): snapshot.
    let mut c2 = env.client().await;
    let (r, _) = subscribe(&mut c2, p, Some(u64::MAX / 2)).await;
    assert_eq!(r["mode"], "snapshot");
}

#[tokio::test]
async fn the_last_client_to_focus_sets_the_size() {
    let env = Env::new();
    let a = env.client().await;
    assert!(a.hello["features"].as_array().unwrap().iter().any(|f| f == "pane.focus"));
    let p = new_pane(&a, sh()).await;
    let b = env.client().await;
    a.request("pane.subscribe", json!({"pane": p, "viewport": {"cols": 100, "rows": 30}})).await.unwrap();
    let r = b.request("pane.subscribe", json!({"pane": p, "viewport": {"cols": 60, "rows": 20}})).await.unwrap();
    // A subscribe with a viewport is a focus: the latest subscriber's viewport wins.
    assert_eq!((r["cols"].as_u64(), r["rows"].as_u64()), (Some(60), Some(20)));
    // Typing doesn't take the size (it used to: the last typer won).
    a.input(p, b"stty size\r");
    wait_for_text(&a, p, T, |l| has_line(l, "20 60")).await.unwrap();
    // Focusing does, and the reply carries the size.
    let r = a.request("pane.focus", json!({"pane": p})).await.unwrap();
    assert_eq!((r["cols"].as_u64(), r["rows"].as_u64()), (Some(100), Some(30)));
    b.input(p, b"clear; stty size\r");
    wait_for_text(&b, p, T, |l| has_line(l, "30 100")).await.unwrap();
    // A viewport from a client that doesn't own the size is only recorded...
    b.request("pane.viewport", json!({"pane": p, "cols": 70, "rows": 25})).await.unwrap();
    // ...one from the owner resizes (a window resize, a rotation).
    a.request("pane.viewport", json!({"pane": p, "cols": 90, "rows": 28})).await.unwrap();
    a.input(p, b"clear; stty size\r");
    wait_for_text(&a, p, T, |l| has_line(l, "28 90")).await.unwrap();
    // b focusing brings in the viewport it recorded.
    let r = b.request("pane.focus", json!({"pane": p})).await.unwrap();
    assert_eq!((r["cols"].as_u64(), r["rows"].as_u64()), (Some(70), Some(25)));
    a.input(p, b"clear; stty size\r");
    wait_for_text(&a, p, T, |l| has_line(l, "25 70")).await.unwrap();
    // pane.resize still forces a size, and the owner stays the owner.
    a.request("pane.resize", json!({"pane": p, "cols": 50, "rows": 15})).await.unwrap();
    b.request("pane.viewport", json!({"pane": p, "cols": 72, "rows": 26})).await.unwrap();
    a.input(p, b"clear; stty size\r");
    wait_for_text(&a, p, T, |l| has_line(l, "26 72")).await.unwrap();
    // When the owner stops showing the pane, the next viewport takes the size.
    b.request("pane.unsubscribe", json!({"pane": p})).await.unwrap();
    a.request("pane.viewport", json!({"pane": p, "cols": 80, "rows": 24})).await.unwrap();
    a.input(p, b"clear; stty size\r");
    wait_for_text(&a, p, T, |l| has_line(l, "24 80")).await.unwrap();
    // Errors: a pane this client doesn't show, a pane that doesn't exist.
    let e = b.request("pane.focus", json!({"pane": p})).await.unwrap_err();
    assert!(e.to_string().contains("bad_request"), "{e}");
    let e = a.request("pane.focus", json!({"pane": 999_999})).await.unwrap_err();
    assert!(e.to_string().contains("not_found"), "{e}");
}

#[tokio::test]
async fn pane_resized_reaches_the_other_subscriber_on_focus() {
    let env = Env::new();
    let a = env.client().await;
    let p = new_pane(&a, sh()).await;
    let mut b = env.client().await;
    a.request("pane.subscribe", json!({"pane": p, "viewport": {"cols": 100, "rows": 30}})).await.unwrap();
    b.request("pane.subscribe", json!({"pane": p, "viewport": {"cols": 60, "rows": 20}})).await.unwrap();
    a.request("pane.focus", json!({"pane": p})).await.unwrap();
    let deadline = Instant::now() + T;
    loop {
        let f = tokio::time::timeout(deadline - Instant::now(), b.recv()).await.expect("no pane.resized").expect("closed");
        if let Frame::Json(v) = f {
            if v["event"] == "pane.resized" && v["data"]["pane"] == p && v["data"]["cols"] == 100 && v["data"]["rows"] == 30 {
                break;
            }
        }
    }
}

#[tokio::test]
async fn model_commands_and_events() {
    let env = Env::new();
    let mut c = env.client().await;
    assert_eq!(c.hello["protocol"], 1);
    assert!(c.hello["instance"].as_str().is_some_and(|s| s.len() == 16));
    c.request("events.subscribe", json!({})).await.unwrap();
    let first = tokio::time::timeout(T, c.recv()).await.unwrap().unwrap();
    assert!(matches!(&first, Frame::Json(v) if v["event"] == "state"));

    let r = c.request("workspace.create", json!({"name": "main", "command": ["/bin/sh"]})).await.unwrap();
    let (ws, p1) = (r["workspace"].as_u64().unwrap(), r["pane"].as_u64().unwrap());
    let r = c.request("pane.split", json!({"pane": p1, "direction": "right", "command": ["/bin/sh"]})).await.unwrap();
    let (p2, split) = (r["pane"].as_u64().unwrap(), r["split"].as_u64().unwrap());
    c.request("split.set_ratio", json!({"split": split, "ratio": 0.3})).await.unwrap();
    let t2 = c.request("tab.create", json!({"workspace": ws, "command": ["/bin/sh"]})).await.unwrap()["tab"].as_u64().unwrap();
    c.request("focus", json!({"pane": p1})).await.unwrap();
    c.request("focus", json!({"workspace": ws})).await.unwrap();
    let s = c.request("state.get", json!({})).await.unwrap();
    assert_eq!(s["focus"]["pane"], p1, "workspace focus returns to its last tab: {s}");
    let layout = &s["workspaces"][0]["tabs"][0]["layout"];
    assert_eq!(layout["ratio"], 0.3);
    assert_eq!(layout["b"]["pane"], p2);

    // A pane whose process exits leaves the layout.
    c.input(p2, b"exit\r");
    let deadline = Instant::now() + T;
    loop {
        let s = c.request("state.get", json!({})).await.unwrap();
        if s["workspaces"][0]["tabs"][0]["layout"]["type"] == "pane" {
            break;
        }
        assert!(Instant::now() < deadline, "pane did not leave the layout");
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    c.request("tab.close", json!({"tab": t2})).await.unwrap();
    let err = c.request("pane.split", json!({"pane": 999})).await.unwrap_err();
    assert!(err.to_string().contains("not_found"), "{err}");

    // Events arrived for all of that, and a pane event carries `exited`.
    let mut saw_exit = false;
    let mut states = 0;
    while let Ok(Some(f)) = tokio::time::timeout(Duration::from_millis(300), c.recv()).await {
        if let Frame::Json(v) = f {
            if v["event"] == "state" {
                states += 1;
            }
            if v["event"] == "pane" && v["data"]["id"] == p2 && !v["data"]["exited"].is_null() {
                saw_exit = true;
            }
        }
    }
    assert!(saw_exit);
    assert!(states >= 6, "got {states} state events");
}

#[tokio::test]
async fn handshake_is_required() {
    let env = Env::new();
    let mut s = tokio::net::UnixStream::connect(env.path().join("clothod.sock")).await.unwrap();
    clotho_proto::write_frame(&mut s, &Frame::Json(json!({"id": 1, "method": "state.get"}))).await.unwrap();
    let Some(Frame::Json(v)) = clotho_proto::read_frame(&mut s).await.unwrap() else { panic!() };
    assert_eq!(v["error"]["code"], "handshake_required");
    clotho_proto::write_frame(&mut s, &Frame::Json(json!({"id": 2, "method": "hello", "params": {"protocol": 99}}))).await.unwrap();
    let Some(Frame::Json(v)) = clotho_proto::read_frame(&mut s).await.unwrap() else { panic!() };
    assert_eq!(v["error"]["code"], "protocol_mismatch");
}

#[tokio::test]
async fn vim_survives_a_logic_restart() {
    let Some(vim) = vim() else {
        eprintln!("vim not installed; skipping");
        return;
    };
    let mut env = Env::new();
    let mut c = env.client().await;
    let p = new_pane(&c, sh()).await;
    c.input(p, format!("{vim} -u NONE -i NONE -N -n\r").as_bytes());
    wait_for_text(&c, p, T, |l| l.iter().filter(|l| l.as_str() == "~").count() > 10).await.unwrap();
    c.input(p, b"iedited before the restart\x1b:set number\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l.contains("1 edited before the restart"))).await.unwrap();
    let (_, mut s) = subscribe(&mut c, p, None).await;
    sync(&mut c, &mut s).await.unwrap();
    drop(c);
    env.kill();
    env.start();

    let mut c = env.client().await;
    let (r, mut s2) = subscribe(&mut c, p, None).await;
    assert_eq!(r["mode"], "snapshot");
    sync(&mut c, &mut s2).await.unwrap();
    assert_same_screen(&s, &s2);
    // vim is alive and still in the same state.
    c.input(p, b"oand after\x1b");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l.contains("2 and after"))).await.unwrap();
    c.input(p, b":q!\r");
    wait_for_text(&c, p, T, |l| !l.iter().any(|l| l == "~")).await.unwrap();
    c.input(p, b"echo vim-exited\r");
    wait_for_text(&c, p, T, |l| has_line(l, "vim-exited")).await.unwrap();
}

/// The daemon's VT answers terminal queries. A restart replays old output, including queries,
/// and those must not be answered again (an app reading a stray CPR as keys can misfire).
#[tokio::test]
async fn restart_does_not_answer_replayed_queries_again() {
    let mut env = Env::new();
    let c = env.client().await;
    let rec = env.path().join("received");
    // Queries outside and inside an unterminated synchronized update. Everything the app
    // receives on stdin goes to `rec`.
    let script = format!(
        r#"stty raw -echo; printf '\033[6n\033[?2026h\033[c\033]11;?\007\033[6n'; exec cat > {}"#,
        rec.display()
    );
    let mut params = sh();
    params["command"] = json!(["/bin/sh", "-c", script]);
    let p = new_pane(&c, params).await;

    // Live: the first CPR right away, the rest when the sync update times out. Each once.
    let deadline = Instant::now() + T;
    let first = loop {
        let got = std::fs::read(&rec).unwrap_or_default();
        if got.iter().filter(|&&b| b == 0x1b).count() >= 4 {
            break got;
        }
        assert!(Instant::now() < deadline, "replies never arrived: {:?}", String::from_utf8_lossy(&got));
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(std::fs::read(&rec).unwrap(), first, "answered more than once while live");
    assert_eq!(String::from_utf8_lossy(&first).matches('R').count(), 2, "two CPRs: {:?}", String::from_utf8_lossy(&first));

    // Restart twice, once with no snapshot pushed yet (everything replayed from the buffer).
    for _ in 0..2 {
        drop(env.client().await);
        env.kill();
        env.start();
        let c = env.client().await;
        let _ = daemon_seq(&c, p).await;
        tokio::time::sleep(Duration::from_millis(600)).await;
        assert_eq!(
            String::from_utf8_lossy(&std::fs::read(&rec).unwrap()),
            String::from_utf8_lossy(&first),
            "replayed queries were answered again"
        );
    }
}

/// Output written the instant a pane starts must not be lost (the holder used to be able to
/// send it before telling the daemon the pane exists).
#[tokio::test]
async fn first_output_of_a_new_pane_is_kept() {
    let env = Env::new();
    let mut c = env.client().await;
    let mut panes = Vec::new();
    for i in 0..30 {
        let mut params = sh();
        params["command"] = json!(["/bin/sh", "-c", format!("printf 'early-{i}'; exec cat")]);
        panes.push((i, new_pane(&c, params).await));
    }
    for (i, p) in panes {
        wait_for_text(&c, p, T, |l| l.first().is_some_and(|l| l == &format!("early-{i}"))).await.unwrap();
        let (_, mut s) = subscribe(&mut c, p, Some(0)).await;
        sync(&mut c, &mut s).await.unwrap();
        assert_eq!(s.output, format!("early-{i}").as_bytes());
    }
}

fn test_bin() -> String {
    std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into())
}

/// A second copy of the binary at another path, standing in for an upgraded install.
fn upgraded_copy(env: &Env) -> String {
    let dir = env.path().join("v2");
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("clothod");
    std::fs::copy(test_bin(), &p).unwrap();
    p.to_string_lossy().into_owned()
}

/// Upgrade: an old holder (pretending to be 0.0.9) keeps its shells while a new serve from a
/// different executable adopts it.
#[tokio::test]
async fn new_serve_adopts_an_older_compatible_holder() {
    let mut env = Env::empty();
    env.start_with(&test_bin(), &[("CLOTHOD_TEST_HOLDER_VERSION", "0.0.9")]);
    let mut c = env.client().await;
    let p = new_pane(&c, sh()).await;
    c.input(p, b"X=kept-$((20+3)); ");
    c.input(p, FULLSCREEN_APP.as_bytes());
    c.input(p, b"\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l.contains("placed"))).await.unwrap();
    let (_, mut s) = subscribe(&mut c, p, None).await;
    sync(&mut c, &mut s).await.unwrap();
    drop(c);
    env.kill();

    let v2 = upgraded_copy(&env);
    env.start_with(&v2, &[]);
    let mut c = env.client().await;
    assert_eq!(c.hello["holder"]["version"], "0.0.9");
    assert_eq!(c.hello["holder"]["exe"].as_str().map(|e| std::path::Path::new(e).canonicalize().unwrap()), Some(std::path::Path::new(&test_bin()).canonicalize().unwrap()));
    assert_eq!(c.hello["exe"].as_str().map(|e| std::path::Path::new(e).canonicalize().unwrap()), Some(std::path::Path::new(&v2).canonicalize().unwrap()));
    let (_, mut s2) = subscribe(&mut c, p, None).await;
    sync(&mut c, &mut s2).await.unwrap();
    assert_same_screen(&s, &s2);
    c.input(p, b"\x04printf '\\033[?1049l'; echo $X\r");
    wait_for_text(&c, p, T, |l| has_line(l, "kept-23")).await.unwrap();

    let status = Command::new(&v2).arg("status").arg("--runtime-dir").arg(env.path()).output().unwrap();
    let status = String::from_utf8_lossy(&status.stdout);
    assert!(status.contains("version 0.0.9") && status.contains("holder protocol 1"), "{status}");
}

/// Upgrade to a serve that cannot drive the running holder: it refuses with a clear error and
/// exit code 3, and the holder and its shells are untouched.
#[tokio::test]
async fn incompatible_holder_is_refused_and_left_alone() {
    let mut env = Env::new();
    let c = env.client().await;
    let p = new_pane(&c, sh()).await;
    c.input(p, b"Y=still-$((40+2)); echo y-$((1+1))\r");
    // The command was run and the next prompt is drawn.
    wait_for_text(&c, p, T, |l| has_line(l, "y-2")).await.unwrap();
    let before = daemon_text(&c, p).await;
    drop(c);
    env.kill();

    // The holder now claims a protocol this serve does not know.
    std::fs::write(env.path().join("CLOTHOD_TEST_HOLDER_PROTOCOL"), "99").unwrap();
    let (code, log) = env.run_serve_expect_exit(&test_bin());
    assert_eq!(code, Some(3), "{log}");
    assert!(log.contains("incompatible holder") && log.contains("holder protocol 99") && log.contains("shells are untouched"), "{log}");
    assert!(log.contains("clothod shutdown"), "says how to finish the upgrade: {log}");
    let start = Command::new(test_bin()).arg("start").arg("--runtime-dir").arg(env.path()).env("CLOTHOD_STATE_DIR", env.state()).output().unwrap();
    assert_eq!(start.status.code(), Some(3), "start reports it too: {}", String::from_utf8_lossy(&start.stderr));
    assert!(String::from_utf8_lossy(&start.stderr).contains("incompatible holder"));

    // Back to a compatible holder: the shell and its screen survived.
    std::fs::remove_file(env.path().join("CLOTHOD_TEST_HOLDER_PROTOCOL")).unwrap();
    env.start();
    let c = env.client().await;
    assert_eq!(daemon_text(&c, p).await, before);
    c.input(p, b"echo $Y\r");
    wait_for_text(&c, p, T, |l| has_line(l, "still-42")).await.unwrap();
}

#[test]
fn install_puts_the_binary_in_a_versioned_dir() {
    let env = Env::empty();
    let base = env.path().join("install");
    let run = |args: &[&str]| {
        let out = Command::new(test_bin()).args(args).env("CLOTHOD_INSTALL_DIR", &base).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    let printed = run(&["install", "--print-path"]);
    assert!(!std::path::Path::new(&printed).exists(), "--print-path does not install");
    let path = run(&["install"]);
    assert_eq!(path, printed);
    let dir = std::path::Path::new(&path).parent().unwrap().file_name().unwrap().to_string_lossy().into_owned();
    assert!(dir.starts_with(concat!(env!("CARGO_PKG_VERSION"), "-")), "{dir}");
    assert_eq!(std::fs::read(&path).unwrap(), std::fs::read(test_bin()).unwrap());
    assert_eq!(run(&["install"]), path, "idempotent");
    // Prune removes other versions but keeps this one.
    std::fs::create_dir_all(base.join("0.0.1-aaaaaaaaaaaa")).unwrap();
    std::fs::write(base.join("0.0.1-aaaaaaaaaaaa/clothod"), b"old").unwrap();
    run(&["install", "--prune", "--runtime-dir", env.path().to_str().unwrap()]);
    assert!(!base.join("0.0.1-aaaaaaaaaaaa").exists());
    assert!(std::path::Path::new(&path).exists());
    // Mid-upgrade: another version is installed and `current` points at it. Installing this
    // (already present) build must not move `current` back: only `upgrade` moves it.
    std::fs::create_dir_all(base.join("9.9.9-bbbbbbbbbbbb")).unwrap();
    std::fs::write(base.join("9.9.9-bbbbbbbbbbbb/clothod"), b"newer").unwrap();
    std::fs::remove_file(base.join("current")).unwrap();
    std::os::unix::fs::symlink("9.9.9-bbbbbbbbbbbb", base.join("current")).unwrap();
    assert_eq!(run(&["install"]), path);
    assert_eq!(std::fs::read_link(base.join("current")).unwrap().to_string_lossy(), "9.9.9-bbbbbbbbbbbb");
}

/// Temp cleaners may delete the runtime dir under a running daemon. The next client must reach
/// the same daemon and holder (shells intact) instead of starting new ones.
#[tokio::test]
async fn deleted_runtime_dir_heals_without_a_second_daemon() {
    let mut env = Env::new();
    let c = env.client().await;
    let instance = c.hello["instance"].clone();
    let pid = c.hello["pid"].clone();
    let p = new_pane(&c, sh()).await;
    // Wait on printed output, not prompt layout (typeahead echo varies under load).
    c.input(p, b"Z=survived-$((1+1)); echo z-$((2+3))\r");
    wait_for_text(&c, p, T, |l| has_line(l, "z-5")).await.unwrap();
    drop(c);

    std::fs::remove_dir_all(env.path()).unwrap();
    assert!(Client::connect(&env.path()).await.is_err());

    // What a client does when it can't connect: `clothod start`.
    let start = Command::new(test_bin()).arg("start").arg("--runtime-dir").arg(env.path()).env("CLOTHOD_STATE_DIR", env.state()).output().unwrap();
    assert!(start.status.success(), "{}", String::from_utf8_lossy(&start.stderr));
    assert!(String::from_utf8_lossy(&start.stdout).contains("socket restored"), "{}", String::from_utf8_lossy(&start.stdout));
    let c = env.client().await;
    assert_eq!(c.hello["instance"], instance, "same holder");
    assert_eq!(c.hello["pid"], pid, "same daemon");
    c.input(p, b"echo $Z\r");
    wait_for_text(&c, p, T, |l| has_line(l, "survived-2")).await.unwrap();
    drop(c);

    // The holder's socket went too. A restarted serve finds the holder through the state dir
    // and has it rebind, instead of starting a second holder.
    env.kill();
    env.start();
    let c = env.client().await;
    assert_eq!(c.hello["instance"], instance, "same holder after serve restart");
    c.input(p, b"echo again-$Z\r");
    wait_for_text(&c, p, T, |l| has_line(l, "again-survived-2")).await.unwrap();
}

/// `shutdown` then `start` back to back gets a fresh, working instance (not the dying holder).
#[tokio::test]
async fn shutdown_then_start_back_to_back() {
    let mut env = Env::new();
    let c = env.client().await;
    let first = c.hello["instance"].clone();
    new_pane(&c, sh()).await;
    drop(c);
    env.daemon.take(); // `shutdown` stops it; don't kill it in Drop
    for round in 0..15 {
        let run = |cmd: &str| Command::new(test_bin()).arg(cmd).arg("--runtime-dir").arg(env.path()).env("CLOTHOD_STATE_DIR", env.state()).output().unwrap();
        let down = run("shutdown");
        assert!(down.status.success(), "round {round}: {}", String::from_utf8_lossy(&down.stderr));
        let up = run("start");
        assert!(up.status.success(), "round {round}: start failed: {}", String::from_utf8_lossy(&up.stderr));
        if round % 3 == 1 {
            continue; // start then shutdown with nobody connecting in between
        }
        let c = Client::connect(&env.path()).await.unwrap();
        assert_ne!(c.hello["instance"], first, "a new holder");
        let p = new_pane(&c, sh()).await;
        c.input(p, b"echo fresh\r");
        wait_for_text(&c, p, T, |l| has_line(l, "fresh")).await.unwrap();
    }
}

// ---- agents ------------------------------------------------------------------------------

async fn pane_agent(c: &Client, pane: u64) -> Value {
    let s = c.request("state.get", json!({})).await.unwrap();
    s["panes"].as_array().unwrap().iter().find(|p| p["id"] == pane).map(|p| p["agent"].clone()).unwrap_or(Value::Null)
}

async fn wait_agent(c: &Client, pane: u64, what: &str, cond: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + T;
    loop {
        let a = pane_agent(c, pane).await;
        if cond(&a) {
            return a;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}; agent is {a}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// `agent` events received so far.
fn agent_events(c: &mut Client) -> Vec<Value> {
    let mut out = Vec::new();
    while let Some(f) = c.try_recv() {
        if let Frame::Json(v) = f {
            if v["event"] == "agent" {
                out.push(v["data"].clone());
            }
        }
    }
    out
}

#[tokio::test]
async fn agent_hook_reports_attention_and_clearing() {
    let env = Env::new();
    let mut c = env.client().await;
    c.request("events.subscribe", json!({})).await.unwrap();
    let p = new_pane(&c, sh()).await;
    // A stand-in agent: reports like hooks would, from inside its own process group.
    let b = test_bin();
    let script = format!(
        r#"sh -c '"{b}" report running --agent claude --session s1; sleep 0.3; "{b}" report waiting --message "May I run ls?"; read x; "{b}" report running; sleep 0.3; "{b}" report done; sleep 60'"#
    );
    c.input(p, format!("{script}\r").as_bytes());

    let a = wait_agent(&c, p, "waiting", |a| a["state"] == "waiting").await;
    assert_eq!(a["kind"], "claude");
    assert_eq!(a["source"], "hook");
    assert_eq!(a["message"], "May I run ls?");
    assert_eq!(a["session"], "s1", "session kept across reports");
    assert_eq!(a["attention"], true);
    let since = a["since"].as_f64().unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    assert!((now - since).abs() < 30.0, "since is unix seconds: {since}");

    let ev = agent_events(&mut c);
    let states: Vec<(Value, Value)> = ev.iter().map(|e| (e["from"].clone(), e["agent"]["state"].clone())).collect();
    assert!(states.contains(&(Value::Null, json!("running"))), "{ev:?}");
    assert!(states.contains(&(json!("running"), json!("waiting"))), "{ev:?}");

    // Looking at the pane is not resolving it: what an app sends when the pane is opened
    // (focus-in, SGR mouse motion) and other input, by frame or by pane.input, leave it set.
    c.input(p, b"\x1b[I");
    c.input(p, b"\x1b[<35;10;5M\x1b[<35;11;5M");
    c.request("pane.input", json!({"pane": p, "data": "\x1b[O"})).await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let a = pane_agent(&c, p).await;
    assert_eq!((a["state"].clone(), a["attention"].clone()), (json!("waiting"), json!(true)), "input must not clear attention");

    // Answering makes the agent work again (its hook reports running), and that clears it.
    c.input(p, b"y\r");
    let a = wait_agent(&c, p, "running again", |a| a["state"] == "running").await;
    assert_eq!(a["attention"], false, "working again clears attention");
    // `done` raises it again; input leaves it; acknowledging clears it (state unchanged).
    let a = wait_agent(&c, p, "done", |a| a["state"] == "done").await;
    assert_eq!(a["attention"], true);
    c.input(p, b"\x1b[I");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(pane_agent(&c, p).await["attention"], true);
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    let a = pane_agent(&c, p).await;
    assert_eq!((a["state"].clone(), a["attention"].clone()), (json!("done"), json!(false)));

    // The agent exits: the field clears and an `agent` event says so.
    agent_events(&mut c);
    c.input(p, b"\x03");
    wait_agent(&c, p, "cleared", |a| a.is_null()).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let ev = agent_events(&mut c);
    assert!(ev.iter().any(|e| e["agent"].is_null() && e["from"] == "done"), "{ev:?}");

    // `report clear` (SessionEnd) clears too.
    c.input(p, format!(r#"sh -c '"{b}" report waiting --agent codex; "{b}" report clear; sleep 60'"#).as_bytes());
    c.input(p, b"\r");
    let deadline = Instant::now() + T;
    loop {
        let ev = agent_events(&mut c);
        if ev.iter().any(|e| e["agent"].is_null() && e["from"] == "waiting") {
            break;
        }
        assert!(Instant::now() < deadline, "no clear");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(pane_agent(&c, p).await.is_null());
}

#[tokio::test]
async fn hook_command_works_in_panes_from_older_holders() {
    let env = Env::new();
    let mut c = env.client().await;
    c.request("events.subscribe", json!({})).await.unwrap();
    // The hook command calls <install base>/current/clothod; install there first.
    let base = env.dir.path().join("bin");
    let run = |args: &[&str]| {
        let out = Command::new(test_bin()).args(args).env("CLOTHOD_INSTALL_DIR", &base).env("HOME", env.dir.path()).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    run(&["install"]);
    assert!(base.join("current/clothod").is_file(), "current link");
    let snippet: Value = serde_json::from_str(&run(&["hooks", "print", "claude"])).unwrap();
    let cmd = snippet["hooks"]["Notification"][0]["hooks"][0]["command"].as_str().unwrap().to_string();
    assert!(cmd.contains(&base.join("current/clothod").display().to_string()), "{cmd}");

    // A pane like one from a pre-agent holder: no CLOTHOD_SOCKET. `report` finds the daemon
    // through the default resolution (here CLOTHOD_RUNTIME_DIR, as a dev instance would set).
    let mut params = sh();
    params["env"]["CLOTHOD_SOCKET"] = json!("");
    params["env"]["CLOTHOD_RUNTIME_DIR"] = json!(env.path());
    let p = new_pane(&c, params).await;
    let hook_input = r#"{"hook_event_name":"Notification","message":"Claude needs your permission","session_id":"abc"}"#;
    let line = format!("printf '%s' '{hook_input}' | sh -c '{}'\r", cmd.replace('\'', r"'\''"));
    c.input(p, line.as_bytes());
    let deadline = Instant::now() + T;
    loop {
        let ev = agent_events(&mut c);
        if let Some(e) = ev.iter().find(|e| e["agent"]["state"] == "waiting") {
            assert_eq!(e["agent"]["kind"], "claude");
            assert_eq!(e["agent"]["message"], "Claude needs your permission");
            assert_eq!(e["agent"]["session"], "abc");
            break;
        }
        assert!(Instant::now() < deadline, "hook report never arrived");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // Outside clotho the hook command does nothing, quickly and quietly.
    let t0 = Instant::now();
    let out = Command::new("sh").arg("-c").arg(&cmd).env_remove("CLOTHO_PANE").stdin(Stdio::null()).output().unwrap();
    assert!(out.status.success() && out.stdout.is_empty() && out.stderr.is_empty());
    let out = Command::new(test_bin()).args(["report", "running"]).env_remove("CLOTHO_PANE").output().unwrap();
    assert!(out.status.success() && out.stdout.is_empty() && out.stderr.is_empty());
    let out = Command::new(test_bin()).args(["report", "running"]).env("CLOTHO_PANE", "1").env("CLOTHOD_SOCKET", "/nonexistent/x.sock").output().unwrap();
    assert!(out.status.success() && out.stdout.is_empty() && out.stderr.is_empty(), "no daemon: still silent");
    assert!(t0.elapsed() < Duration::from_millis(500), "{:?}", t0.elapsed());
}

#[tokio::test]
async fn detects_an_agent_without_hooks() {
    let env = Env::new();
    let c = env.client().await;
    let p = new_pane(&c, sh()).await;
    // A `claude` in the foreground. A script, so it shows up the way `node .../claude` does:
    // the interpreter runs with the agent's path in argv. (Copies of system binaries don't
    // run on macOS.)
    let fake = env.dir.path().join("claude");
    std::fs::write(&fake, "#!/bin/sh\nsleep 4; printf '\\007'; sleep \"$@\"\n").unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    c.input(p, format!("{} 60\r", fake.display()).as_bytes());
    let a = wait_agent(&c, p, "detected claude", |a| a["kind"] == "claude").await;
    assert_eq!(a["source"], "detected");
    // Silent since it started: reads as waiting, but a guess like that must not notify.
    let a = wait_agent(&c, p, "waiting", |a| a["state"] == "waiting").await;
    assert_eq!(a["attention"], false, "quiet output alone raises no attention");
    // A terminal bell from the agent does.
    wait_agent(&c, p, "attention after BEL", |a| a["attention"] == true && a["state"] == "waiting").await;
    c.input(p, b"\x03");
    wait_agent(&c, p, "cleared when it exits", |a| a.is_null()).await;
}

/// Mute: the user keeps an agent from ever asking for attention again, until they unmute it.
/// It lasts for that agent, through a restart of the logic process, and not for the next one.
#[tokio::test]
async fn a_muted_agent_never_asks_for_attention_until_unmuted_or_replaced() {
    let mut env = Env::new();
    let mut c = env.client().await;
    assert!(c.hello["features"].as_array().unwrap().contains(&json!("agent.mute")), "{}", c.hello);
    c.request("events.subscribe", json!({})).await.unwrap();
    let p = new_pane(&c, sh()).await;
    let b = test_bin();
    let script = format!(
        r#"sh -c '"{b}" report running --agent claude --session m1; "{b}" report waiting --agent claude --message Q1; read a; "{b}" report done --agent claude; read b; "{b}" report waiting --agent claude --message Q2; read c; "{b}" report done --agent claude; sleep 60'"#
    );
    c.input(p, format!("{script}\r").as_bytes());
    let a = wait_agent(&c, p, "waiting", |a| a["state"] == "waiting").await;
    assert_eq!((a["attention"].clone(), a["muted"].clone()), (json!(true), json!(false)));

    // Muting clears attention, and says so in an `agent` event.
    agent_events(&mut c);
    c.request("agent.mute", json!({"pane": p, "muted": true})).await.unwrap();
    let a = pane_agent(&c, p).await;
    assert_eq!((a["attention"].clone(), a["muted"].clone()), (json!(false), json!(true)), "{a}");
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(agent_events(&mut c).iter().any(|e| e["agent"]["muted"] == true), "an agent event");
    // `done` while muted: the state moves on, attention stays down.
    c.input(p, b"a\r");
    let a = wait_agent(&c, p, "done", |a| a["state"] == "done").await;
    assert_eq!((a["attention"].clone(), a["muted"].clone()), (json!(false), json!(true)), "{a}");

    // A restart of the logic process (as in an upgrade) keeps it for this agent (hooks always
    // say which agent they are, as `report --claude-hook` does).
    drop(c);
    env.kill();
    env.start();
    let c = env.client().await;
    c.input(p, b"b\r");
    let a = wait_agent(&c, p, "Q2", |a| a["message"] == "Q2").await;
    assert_eq!((a["state"].clone(), a["attention"].clone(), a["muted"].clone()), (json!("waiting"), json!(false), json!(true)), "{a}");

    // Unmuted: the next `done` asks for attention again.
    c.request("agent.mute", json!({"pane": p, "muted": false})).await.unwrap();
    assert_eq!(pane_agent(&c, p).await["muted"], false);
    c.input(p, b"c\r");
    let a = wait_agent(&c, p, "done again", |a| a["state"] == "done").await;
    assert_eq!(a["attention"], true, "{a}");

    // Mute it, then it exits: the next agent in the pane starts unmuted.
    c.request("agent.mute", json!({"pane": p, "muted": true})).await.unwrap();
    c.input(p, b"\x03");
    wait_agent(&c, p, "gone", |a| a.is_null()).await;
    c.input(p, format!(r#"sh -c '"{b}" report waiting --agent claude --message new; sleep 60'"#).as_bytes());
    c.input(p, b"\r");
    let a = wait_agent(&c, p, "a new agent", |a| a["message"] == "new").await;
    assert_eq!((a["attention"].clone(), a["muted"].clone()), (json!(true), json!(false)), "{a}");

    // Errors.
    let q = new_pane(&c, sh()).await;
    let e = c.request("agent.mute", json!({"pane": q, "muted": true})).await.unwrap_err();
    assert!(e.to_string().contains("not_found"), "{e}");
    let e = c.request("agent.mute", json!({"pane": p})).await.unwrap_err();
    assert!(e.to_string().contains("bad_request"), "{e}");
}

#[tokio::test]
async fn a_muted_agent_sends_no_push() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    register(&c, "phone", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    let report = |state: &str| c.request("agent.report", json!({"pane": p, "state": state, "kind": "claude"}));
    report("running").await.unwrap();
    report("waiting").await.unwrap();
    relay.next();
    c.request("agent.mute", json!({"pane": p, "muted": true})).await.unwrap();
    report("running").await.unwrap();
    report("done").await.unwrap();
    report("running").await.unwrap();
    report("error").await.unwrap();
    relay.none_for(Duration::from_millis(1500));
    // Unmuted, it pushes again.
    c.request("agent.mute", json!({"pane": p, "muted": false})).await.unwrap();
    report("running").await.unwrap();
    report("done").await.unwrap();
    assert_eq!(opened(&relay.next().1)["s"], "done");
}

/// A turn that ends while the user is at the pane (a client showing it sent input lately)
/// raises attention there but sends no push; waiting still pushes, and so does a turn that ends
/// after the user went quiet, or when the input came from a client not showing the pane.
#[tokio::test]
async fn a_turn_that_ends_while_the_user_is_at_the_pane_does_not_push() {
    let relay = FakeRelay::start();
    let mut env = Env::empty();
    env.start_with(&std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into()), &[("CLOTHOD_TEST_PUSH_FAST", "1"), ("CLOTHOD_TEST_PRESENCE_MS", "1500")]);
    let c = env.client().await;
    let other = env.client().await;
    register(&c, "phone", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    c.request("pane.subscribe", json!({"pane": p})).await.unwrap();
    let report = |state: &str| c.request("agent.report", json!({"pane": p, "state": state, "kind": "claude"}));

    report("running").await.unwrap();
    c.request("pane.input", json!({"pane": p, "data": "\x1b[I"})).await.unwrap();
    report("done").await.unwrap();
    let a = pane_agent(&c, p).await;
    assert_eq!((a["attention"].clone(), a["quiet"].clone()), (json!(true), json!(true)), "raised for the app to show, quietly: {a}");
    relay.none_for(Duration::from_millis(1200));
    // `quiet` describes the last rise: it stays through an ack until attention rises again.
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    assert_eq!(pane_agent(&c, p).await["quiet"], true);

    // Asked something while the user is there: pushed (they may have just stepped away).
    report("running").await.unwrap();
    c.request("pane.input", json!({"pane": p, "data": "y"})).await.unwrap();
    report("waiting").await.unwrap();
    assert_eq!(opened(&relay.next().1)["s"], "waiting");
    assert_eq!(pane_agent(&c, p).await["quiet"], false, "waiting is never quiet");

    // Quiet for longer than the presence window: the turn's end pushes.
    report("running").await.unwrap();
    tokio::time::sleep(Duration::from_millis(1600)).await;
    report("done").await.unwrap();
    assert_eq!(opened(&relay.next().1)["s"], "done");
    assert_eq!(pane_agent(&c, p).await["quiet"], false);

    // Input from a client that isn't showing the pane says nothing about the user.
    report("running").await.unwrap();
    other.request("pane.input", json!({"pane": p, "data": "z"})).await.unwrap();
    tokio::time::sleep(Duration::from_millis(1100)).await;
    report("done").await.unwrap();
    assert_eq!(opened(&relay.next().1)["s"], "done");
}

/// What a push tells about the turn, from Claude Code's real hook payloads through
/// `clothod report --claude-hook`: the prompt the user typed, the tool a permission prompt is
/// about, the reply the turn ended with, how long it took, and where (workspace, tab, project).
#[tokio::test]
async fn pushes_carry_the_turns_details() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    register(&c, "phone", &relay.url).await;
    let proj = env.dir.path().join("my-project");
    std::fs::create_dir_all(&proj).unwrap();
    let mut params = sh();
    params["cwd"] = json!(proj.display().to_string());
    params["name"] = json!("Work");
    let r = c.request("workspace.create", params).await.unwrap();
    let (p, ws, tab) = (r["pane"].as_u64().unwrap(), r["workspace"].as_u64().unwrap(), r["tab"].as_u64().unwrap());
    c.request("tab.rename", json!({"tab": tab, "title": "api"})).await.unwrap();

    // Each line is one hook event, as Claude Code 2.1.312 sends them; the stand-in agent feeds
    // them to the hook command one by one, waiting for a line on the terminal between steps.
    let events = env.dir.path().join("events");
    std::fs::create_dir_all(&events).unwrap();
    let base = r#""session_id":"s1","transcript_path":"/t.jsonl","cwd":"/p","permission_mode":"default""#;
    let steps: [&[&str]; 4] = [
        &[
            r#""hook_event_name":"UserPromptSubmit","prompt":"fix the failing build\nthen run the tests""#,
            r#""hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"}"#,
            r#""hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#,
        ],
        &[
            r#""hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}"#,
            r#""hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"The build is fixed.\n\nAll 12 tests pass.","background_tasks":[]"#,
        ],
        &[
            r#""hook_event_name":"UserPromptSubmit","prompt":"Another Claude session sent a message:\n<cross-session-message from=\"x\">hi</cross-session-message>""#,
            r#""hook_event_name":"Notification","message":"Claude needs your input","notification_type":"elicitation_dialog""#,
        ],
        &[r#""hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok","background_tasks":[]"#],
    ];
    let b = test_bin();
    let mut script = String::new();
    for (i, step) in steps.iter().enumerate() {
        if i > 0 {
            script.push_str("read x; ");
        }
        for (j, e) in step.iter().enumerate() {
            let f = events.join(format!("{i}-{j}.json"));
            std::fs::write(&f, format!("{{{base},{e}}}")).unwrap();
            script.push_str(&format!("'{b}' report --claude-hook < '{}'; ", f.display()));
        }
    }
    let file = env.dir.path().join("agent.sh");
    std::fs::write(&file, format!("{script}sleep 60\n")).unwrap();
    c.input(p, format!("sh '{}'\r", file.display()).as_bytes());

    let a = wait_agent(&c, p, "waiting", |a| a["state"] == "waiting").await;
    assert_eq!(a["prompt"], "fix the failing build", "the first line: {a}");
    assert_eq!((a["tool"].clone(), a["tool_input"].clone()), (json!("Bash"), json!("npm test")));
    let started = a["turn_started"].as_f64().unwrap();
    let r = opened(&relay.next().1);
    assert_eq!((r["s"].clone(), r["msg"].clone()), (json!("waiting"), json!("Claude needs your permission to use Bash")));
    assert_eq!((r["tool"].clone(), r["cmd"].clone(), r["q"].clone()), (json!("Bash"), json!("npm test"), json!("fix the failing build")));
    assert_eq!((r["w"].clone(), r["wid"].clone(), r["tb"].clone(), r["pj"].clone()), (json!("Work"), json!(ws), json!("api"), json!("my-project")));
    assert!(r.get("d").is_none(), "no duration while waiting: {r}");

    // Allowed: the turn ends with Claude's reply, on one line, and how long the turn took.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    c.input(p, b"\r");
    let a = wait_agent(&c, p, "done", |a| a["state"] == "done").await;
    assert_eq!(a["message"], "The build is fixed. All 12 tests pass.");
    assert_eq!(a["turn_started"].as_f64(), Some(started), "the same turn");
    let r = opened(&relay.next().1);
    assert_eq!((r["s"].clone(), r["msg"].clone(), r["q"].clone()), (json!("done"), json!("The build is fixed. All 12 tests pass."), json!("fix the failing build")));
    assert!(r["d"].as_u64().unwrap() <= 30, "{r}");
    assert!(r.get("tool").is_none() && r.get("cmd").is_none(), "the tool belongs to the wait: {r}");

    // A turn another agent's message started has no prompt (never the wrapper), and a question
    // is not about the last tool.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    c.input(p, b"\r");
    let a = wait_agent(&c, p, "asking", |a| a["state"] == "waiting").await;
    assert!(a["prompt"].is_null() && a["tool"].is_null() && a["tool_input"].is_null(), "{a}");
    assert!(a["turn_started"].as_f64().unwrap() >= started);
    let r = opened(&relay.next().1);
    assert_eq!(r["msg"], "Claude needs your input");
    assert!(r.get("q").is_none() && r.get("tool").is_none(), "{r}");
}

/// Runs Claude Code hook payloads through `clothod report` in a pane: `steps` are shell lines,
/// `{hook NAME PAYLOAD}` placeholders already expanded by `hook_line`.
fn hook_line(dir: &std::path::Path, name: &str, mode: &str, payload: &str, out: Option<&str>) -> String {
    let f = dir.join(format!("{name}.json"));
    std::fs::write(&f, payload).unwrap();
    let redirect = out.map(|o| format!(" > '{}'", dir.join(o).display())).unwrap_or_default();
    format!("'{}' report {mode} < '{}'{redirect}", test_bin(), f.display())
}

fn permission_payload(command: &str) -> String {
    json!({"session_id": "s1", "transcript_path": "/t.jsonl", "cwd": "/p", "prompt_id": "p1", "permission_mode": "default",
        "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": command, "description": "run it"},
        "permission_suggestions": [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]}).to_string()
}

fn post_tool_payload(command: &str) -> String {
    json!({"session_id": "s1", "transcript_path": "/t.jsonl", "cwd": "/p", "hook_event_name": "PostToolUse", "tool_name": "Bash",
        "tool_input": {"command": command, "description": "run it"}, "tool_response": {"stdout": "", "stderr": ""}}).to_string()
}

async fn wait_file(f: &std::path::Path) -> String {
    let deadline = Instant::now() + T;
    loop {
        if let Ok(s) = std::fs::read_to_string(f) {
            if s.ends_with('\n') || s == "done" {
                return s;
            }
        }
        assert!(Instant::now() < deadline, "no {}", f.display());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Two tool calls ask permission at once (parallel calls): each is a request of its own,
/// answerable from a client exactly once, and only the one its id names gets the answer.
#[tokio::test]
async fn permission_requests_are_answered_once_and_only_by_id() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    register(&c, "phone", &relay.url).await;
    let dir = env.dir.path().join("perm");
    std::fs::create_dir_all(&dir).unwrap();
    let a = hook_line(&dir, "a", "--claude-permission", &permission_payload("npm test"), Some("a.out"));
    let b = hook_line(&dir, "b", "--claude-permission", &permission_payload("rm -rf build"), Some("b.out"));
    let script = dir.join("agent.sh");
    std::fs::write(&script, format!("({a}; echo done >> '{d}/a.end') & sleep 0.3; ({b}; echo done >> '{d}/b.end') & wait; sleep 60\n", d = dir.display())).unwrap();
    let p = new_pane(&c, sh()).await;
    c.input(p, format!("sh '{}'\r", script.display()).as_bytes());

    let ag = wait_agent(&c, p, "two requests", |a| a["requests"].as_array().is_some_and(|r| r.len() == 2)).await;
    assert_eq!((ag["state"].clone(), ag["attention"].clone()), (json!("waiting"), json!(true)));
    let reqs = ag["requests"].as_array().unwrap().clone();
    assert_eq!((reqs[0]["tool"].clone(), reqs[0]["summary"].clone()), (json!("Bash"), json!("npm test")));
    assert_eq!(reqs[1]["summary"], "rm -rf build");
    let (ra, rb) = (reqs[0]["id"].as_str().unwrap().to_string(), reqs[1]["id"].as_str().unwrap().to_string());
    assert_ne!(ra, rb);
    // The push for the wait can be acted on: it names the request.
    let r = opened(&relay.next().1);
    assert_eq!((r["s"].clone(), r["rq"].clone(), r["tool"].clone(), r["cmd"].clone()), (json!("waiting"), json!(ra), json!("Bash"), json!("npm test")));

    // Allow the second: only its hook answers; the first still waits.
    c.request("agent.decide", json!({"pane": p, "request": rb, "decision": "allow"})).await.unwrap();
    let out = wait_file(&dir.join("b.out")).await;
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!(v, json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}));
    wait_file(&dir.join("b.end")).await;
    let ag = pane_agent(&c, p).await;
    assert_eq!(ag["requests"].as_array().unwrap().len(), 1);
    assert_eq!(ag["requests"][0]["id"], json!(ra));
    assert!(std::fs::read_to_string(dir.join("a.out")).unwrap().is_empty(), "the other request got nothing");

    // A double tap is stale, and nothing more is printed.
    let e = c.request("agent.decide", json!({"pane": p, "request": rb, "decision": "deny"})).await.unwrap_err();
    assert!(e.to_string().contains("stale"), "{e}");
    let e = c.request("agent.decide", json!({"pane": p, "request": ra, "decision": "maybe"})).await.unwrap_err();
    assert!(e.to_string().contains("bad_request"), "{e}");

    // Deny the first, with a reason for Claude.
    c.request("agent.decide", json!({"pane": p, "request": ra, "decision": "deny", "message": "Not on main"})).await.unwrap();
    let v: Value = serde_json::from_str(wait_file(&dir.join("a.out")).await.trim()).unwrap();
    assert_eq!(v["hookSpecificOutput"]["decision"], json!({"behavior": "deny", "message": "Not on main"}));
    wait_file(&dir.join("a.end")).await;
    assert_eq!(std::fs::read_to_string(dir.join("b.out")).unwrap().lines().count(), 1, "one answer per request");
    assert!(pane_agent(&c, p).await["requests"].as_array().unwrap().is_empty());
}

/// clothod.log says who closed what, how panes ended and who answered which request: clients
/// keep no record, so this is the only way to tell after the fact.
#[tokio::test]
async fn the_log_names_who_closed_and_answered() {
    let env = Env::new();
    let c = env.client().await;
    let me = std::process::id();
    let ws = c.request("workspace.create", sh()).await.unwrap();
    let (w, p1) = (ws["workspace"].as_u64().unwrap(), ws["pane"].as_u64().unwrap());
    let t2 = c.request("tab.create", with(sh(), json!({"workspace": w}))).await.unwrap();
    let p2 = t2["pane"].as_u64().unwrap();
    let p3 = c.request("pane.split", with(sh(), json!({"pane": p1}))).await.unwrap()["pane"].as_u64().unwrap();
    c.request("pane.close", json!({"pane": p3})).await.unwrap();
    c.request("tab.close", json!({"tab": t2["tab"]})).await.unwrap();
    c.input(p1, b"exit 3\r");
    let ws2 = c.request("workspace.create", sh()).await.unwrap();
    let e = c.request("agent.decide", json!({"pane": ws2["pane"], "request": "0123", "decision": "allow"})).await.unwrap_err();
    assert!(e.to_string().contains("stale"), "{e}");
    c.request("workspace.close", json!({"workspace": ws2["workspace"]})).await.unwrap();
    let who = format!("(clotho-cli/{}, pid {me})", env!("CARGO_PKG_VERSION"));
    let want = [
        format!("{who} closed pane {p3}"),
        format!("{who} closed tab {} (panes [{p2}])", t2["tab"]),
        format!("pane {p1} ended (exit status 3); its tab {} in workspace {w} loses it", ws["tab"]),
        format!("{who} could not answer pane {} request \"0123\" \"allow\": stale", ws2["pane"]),
        format!("{who} closed workspace {} (panes [{}])", ws2["workspace"], ws2["pane"]),
        format!("pane {} ended (signal 1)", ws2["pane"]),
    ];
    let deadline = Instant::now() + T;
    loop {
        let log = env.log();
        let missing: Vec<_> = want.iter().filter(|w| !log.contains(w.as_str())).collect();
        if missing.is_empty() {
            assert!(log.lines().filter(|l| l.contains(" closed ") || l.contains(" ended ")).all(|l| l.contains("Z ")), "timestamped:\n{log}");
            break;
        }
        assert!(Instant::now() < deadline, "missing {missing:?} in:\n{log}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The user answers in the terminal (Claude's own dialog shows all along): the call's
/// PostToolUse retires its request, and a tap on the phone afterwards is stale. Another call's
/// PostToolUse (a subagent's) leaves an unrelated request alone; the turn's end retires the rest,
/// and a hook that goes away (Claude's timeout) takes its request with it.
#[tokio::test]
async fn requests_answered_in_the_terminal_go_stale() {
    let env = Env::new();
    let c = env.client().await;
    let dir = env.dir.path().join("perm");
    std::fs::create_dir_all(&dir).unwrap();
    let d = dir.display();
    let ask_x = hook_line(&dir, "x", "--claude-permission", &permission_payload("make x"), Some("x.out"));
    let ask_y = hook_line(&dir, "y", "--claude-permission", &permission_payload("make y"), Some("y.out"));
    let ask_z = hook_line(&dir, "z", "--claude-permission", &permission_payload("make z"), Some("z.out"));
    let post_x = hook_line(&dir, "px", "--claude-hook", &post_tool_payload("make x"), None);
    let post_other = hook_line(&dir, "po", "--claude-hook", &post_tool_payload("ls"), None);
    let stop = hook_line(&dir, "stop", "--claude-hook", &json!({"session_id": "s1", "hook_event_name": "Stop", "last_assistant_message": "ok"}).to_string(), None);
    let script = dir.join("agent.sh");
    std::fs::write(
        &script,
        format!(
            "({ask_x}; echo done > '{d}/x.end') & ({ask_y}; echo done > '{d}/y.end') & read a; {post_x}; {post_other}; read b; {stop}; read c; {ask_z} & echo $! > '{d}/z.pid'; wait; sleep 60\n"
        ),
    )
    .unwrap();
    let p = new_pane(&c, sh()).await;
    c.input(p, format!("sh '{}'\r", script.display()).as_bytes());
    let ag = wait_agent(&c, p, "two requests", |a| a["requests"].as_array().is_some_and(|r| r.len() == 2)).await;
    let id_of = |cmd: &str| ag["requests"].as_array().unwrap().iter().find(|r| r["summary"] == cmd).unwrap()["id"].as_str().unwrap().to_string();
    let (x, y) = (id_of("make x"), id_of("make y"));

    // Answered in the terminal: x ran (its PostToolUse), and a subagent's other call ran too.
    c.input(p, b"\r");
    assert_eq!(wait_file(&dir.join("x.end")).await, "done\n");
    assert!(std::fs::read_to_string(dir.join("x.out")).unwrap().is_empty(), "a retired request prints nothing");
    let e = c.request("agent.decide", json!({"pane": p, "request": x, "decision": "allow"})).await.unwrap_err();
    assert!(e.to_string().contains("stale"), "{e}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let ag = pane_agent(&c, p).await;
    assert_eq!(ag["requests"].as_array().unwrap().iter().map(|r| r["id"].clone()).collect::<Vec<_>>(), vec![json!(y)], "an unrelated call leaves y: {ag}");

    // The turn ends: what's left is retired.
    c.input(p, b"\r");
    wait_file(&dir.join("y.end")).await;
    assert!(std::fs::read_to_string(dir.join("y.out")).unwrap().is_empty());
    let e = c.request("agent.decide", json!({"pane": p, "request": y, "decision": "allow"})).await.unwrap_err();
    assert!(e.to_string().contains("stale"), "{e}");

    // A hook that goes away (Claude's timeout ends it) takes its request with it.
    c.input(p, b"\r");
    let ag = wait_agent(&c, p, "request z", |a| a["requests"].as_array().is_some_and(|r| r.len() == 1)).await;
    let z = ag["requests"][0]["id"].as_str().unwrap().to_string();
    let pid: i32 = wait_file(&dir.join("z.pid")).await.trim().parse().unwrap();
    unsafe { libc::kill(pid, libc::SIGTERM) };
    let ag = wait_agent(&c, p, "z gone", |a| a["requests"].as_array().is_some_and(|r| r.is_empty())).await;
    assert_eq!(ag["state"], "waiting");
    let e = c.request("agent.decide", json!({"pane": p, "request": z, "decision": "allow"})).await.unwrap_err();
    assert!(e.to_string().contains("stale"), "{e}");
}

/// An agent the pane's agent runs (an SDK app under test, `claude -p` from a tool) has hooks
/// too: its reports reach this pane but must not move the pane's agent or push.
#[tokio::test]
async fn agents_run_by_the_panes_agent_do_not_report_into_it() {
    let relay = FakeRelay::start();
    let env = push_env();
    let mut c = env.client().await;
    register(&c, "phone", &relay.url).await;
    c.request("events.subscribe", json!({})).await.unwrap();
    let b = test_bin();
    let dir = env.dir.path().join("agents");
    let marker = dir.join("inner-ran");
    for d in ["outer", "inner"] {
        std::fs::create_dir_all(dir.join(d)).unwrap();
    }
    use std::os::unix::fs::PermissionsExt;
    let script = |name: &str, body: String| {
        let f = dir.join(name).join("claude");
        std::fs::write(&f, format!("#!/bin/sh\n{body}")).unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o755)).unwrap();
        f.display().to_string()
    };
    // The inner agent runs under a shell its parent started (as a tool would run it), reports
    // a whole session of its own, and exits.
    let inner = script("inner", format!("'{b}' report starting --agent claude --session child\n'{b}' report running\n'{b}' report done\n'{b}' report clear\ntrue\n"));
    let outer = script(
        "outer",
        format!("'{b}' report running --agent claude --session parent\nsh -c \"'{inner}'; true\"\ntouch '{}'\nread x\n'{b}' report done\nsleep 60\n", marker.display()),
    );
    let p = new_pane(&c, sh()).await;
    c.input(p, format!("'{outer}'\r").as_bytes());
    let deadline = Instant::now() + T;
    while !marker.exists() {
        assert!(Instant::now() < deadline, "the inner agent never ran");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    let a = pane_agent(&c, p).await;
    assert_eq!((a["state"].clone(), a["session"].clone(), a["attention"].clone()), (json!("running"), json!("parent"), json!(false)), "{a}");
    let ev = agent_events(&mut c);
    assert!(!ev.iter().any(|e| e["agent"]["session"] == "child" || e["agent"].is_null()), "{ev:?}");
    relay.none_for(Duration::from_millis(500));
    // The pane's own agent still reports.
    c.input(p, b"\r");
    let a = wait_agent(&c, p, "done", |a| a["state"] == "done").await;
    assert_eq!((a["session"].clone(), a["attention"].clone()), (json!("parent"), json!(true)));
    assert_eq!(opened(&relay.next().1)["s"], "done");
}

/// Detection without hooks guesses from output: busy is running, quiet is waiting. Opening a
/// pane resizes it and the app redraws, which reads as "running". A guess must never clear the
/// attention a BEL raised; only acknowledging it (or the agent leaving) does.
#[tokio::test]
async fn a_detected_agents_output_guess_never_clears_attention() {
    let env = Env::new();
    let c = env.client().await;
    let p = new_pane(&c, sh()).await;
    let fake = env.dir.path().join("codex");
    std::fs::write(&fake, "#!/bin/sh\nsleep 3; printf '\\007'; read x; i=0; while [ $i -lt 40 ]; do echo redraw-$i; i=$((i+1)); done; sleep \"$@\"\n").unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    c.input(p, format!("{} 60\r", fake.display()).as_bytes());
    wait_agent(&c, p, "attention after BEL", |a| a["kind"] == "codex" && a["attention"] == true).await;
    // The redraw: a burst of output, guessed as running, then quiet again.
    c.input(p, b"\r");
    let a = wait_agent(&c, p, "guessed running", |a| a["state"] == "running").await;
    assert_eq!(a["attention"], true, "a guess doesn't clear attention: {a}");
    let a = wait_agent(&c, p, "guessed waiting", |a| a["state"] == "waiting").await;
    assert_eq!(a["attention"], true, "{a}");
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    assert_eq!(pane_agent(&c, p).await["attention"], false);
    c.input(p, b"\x03");
    wait_agent(&c, p, "cleared when it exits", |a| a.is_null()).await;
}

#[tokio::test]
async fn a_hook_report_raises_attention_after_detection_guessed_the_same_state() {
    let env = Env::new();
    let mut c = env.client().await;
    let p = new_pane(&c, sh()).await;
    // A quiet `claude` that detection reads as waiting; then its hook says it waits for
    // permission.
    let fake = env.dir.path().join("claude");
    let b = test_bin();
    std::fs::write(&fake, format!("#!/bin/sh\nsleep 4; \"{b}\" report waiting --agent claude --message \"Allow ls?\"; sleep \"$@\"\n")).unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    c.request("events.subscribe", json!({})).await.unwrap();
    c.input(p, format!("{} 60\r", fake.display()).as_bytes());
    let a = wait_agent(&c, p, "detected waiting", |a| a["state"] == "waiting").await;
    assert_eq!((a["source"].clone(), a["attention"].clone()), (json!("detected"), json!(false)), "{a}");
    let a = wait_agent(&c, p, "the hook's report", |a| a["source"] == "hook").await;
    assert_eq!((a["state"].clone(), a["attention"].clone(), a["message"].clone()), (json!("waiting"), json!(true), json!("Allow ls?")), "{a}");
    let ev = agent_events(&mut c);
    assert!(ev.iter().any(|e| e["from"] == "waiting" && e["agent"]["attention"] == true), "an agent event says so: {ev:?}");
    c.input(p, b"\x03");
    wait_agent(&c, p, "cleared when it exits", |a| a.is_null()).await;
}

#[test]
fn hooks_install_is_idempotent_and_uninstall_restores() {
    let env = Env::empty();
    let home = env.dir.path().join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    let settings = home.join(".claude/settings.json");
    let original = r#"{
  "model": "opus",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo mine"
          }
        ]
      }
    ]
  }
}
"#;
    std::fs::write(&settings, original).unwrap();
    let config = home.join(".codex/config.toml");
    let codex_original = "model = \"o3\"\nnotify = [\"echo\", \"user-notify\"]\n\n[profiles.fast]\nmodel = \"o4-mini\"\n";
    std::fs::write(&config, codex_original).unwrap();

    let run = |args: &[&str]| {
        let out = Command::new(test_bin()).args(args).env("HOME", &home).env("CLOTHOD_INSTALL_DIR", env.dir.path().join("bin")).output().unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    assert!(run(&["hooks", "status"]).contains("claude: not installed"));
    assert!(run(&["hooks", "install", "claude"]).contains("installed"));
    assert!(run(&["hooks", "install", "claude"]).contains("already installed"), "idempotent");
    let s: Value = serde_json::from_str(&std::fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(s["model"], "opus");
    let stop = s["hooks"]["Stop"].as_array().unwrap();
    assert!(stop.iter().any(|g| g["hooks"][0]["command"] == "echo mine"), "user hook kept");
    assert_eq!(stop.iter().filter(|g| g["hooks"][0]["command"].as_str().unwrap().contains("report --claude-hook")).count(), 1);
    for ev in ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "SessionEnd"] {
        assert_eq!(s["hooks"][ev].as_array().map(Vec::len), Some(1), "{ev}");
    }
    assert!(std::fs::read_dir(home.join(".claude")).unwrap().flatten().any(|e| e.file_name().to_string_lossy().starts_with("settings.json.clotho-backup-")));
    assert!(run(&["hooks", "status"]).contains("claude: installed"));
    run(&["hooks", "uninstall", "claude"]);
    assert_eq!(std::fs::read_to_string(&settings).unwrap(), original, "uninstall restores the file");

    // Codex: one notify program, so ours wraps the user's and calls it afterwards.
    run(&["hooks", "install", "codex"]);
    assert!(run(&["hooks", "install", "codex"]).contains("already installed"));
    let doc: toml_edit::DocumentMut = std::fs::read_to_string(&config).unwrap().parse().unwrap();
    let notify: Vec<String> = doc["notify"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
    assert_eq!(&notify[notify.len() - 2..], ["echo", "user-notify"]);
    assert_eq!(doc["profiles"]["fast"]["model"].as_str(), Some("o4-mini"));
    // The wrapper chains: the user's program still gets the payload (and we stay silent).
    let out = Command::new(&notify[0]).args(&notify[1..]).arg(r#"{"type":"agent-turn-complete"}"#).env_remove("CLOTHO_PANE").output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), r#"user-notify {"type":"agent-turn-complete"}"#);
    run(&["hooks", "uninstall", "codex"]);
    let doc: toml_edit::DocumentMut = std::fs::read_to_string(&config).unwrap().parse().unwrap();
    let restored: Vec<&str> = doc["notify"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert_eq!(restored, ["echo", "user-notify"]);
    assert_eq!(doc["model"].as_str(), Some("o3"));
}

/// Panes from older holders have no CLOTHOD_SOCKET. `report` must still reach the daemon the
/// pane belongs to, and never another daemon that happens to have a pane with the same id.
#[tokio::test]
async fn report_reaches_the_right_daemon_without_clothod_socket() {
    let registry = tempfile::Builder::new().prefix("clreg").tempdir_in("/tmp").unwrap();
    let reg = registry.path().to_str().unwrap().to_string();
    let mut a = Env::empty();
    a.start_with(&test_bin(), &[("CLOTHOD_REGISTRY_DIR", &reg)]);
    let mut b = Env::empty();
    b.start_with(&test_bin(), &[("CLOTHOD_REGISTRY_DIR", &reg)]);
    let ca = a.client().await;
    let cb = b.client().await;
    let pa = new_pane(&ca, sh()).await;
    let a_path = a.path();
    let bin = test_bin();
    let stand_in = |extra: &str| format!(r#"sh -c '"{bin}" report waiting --agent claude --message "{extra}"; sleep 60'"#);

    // B's pane 1, with no CLOTHOD_SOCKET and a "default" socket that is A's: A has a pane 1
    // too, refuses (the reporter isn't in it), and the registry leads to B.
    let mut params = sh();
    params["env"]["CLOTHOD_SOCKET"] = json!("");
    params["env"]["CLOTHOD_RUNTIME_DIR"] = json!(a_path);
    let pb = new_pane(&cb, params).await;
    assert_eq!(pa, pb, "same pane id in both daemons");
    cb.input(pb, format!("{}\r", stand_in("via registry")).as_bytes());
    let got = wait_agent(&cb, pb, "report in B", |x| x["state"] == "waiting").await;
    assert_eq!(got["message"], "via registry");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(pane_agent(&ca, pa).await.is_null(), "A must not take B's report");
    cb.input(pb, b"\x03");
    wait_agent(&cb, pb, "cleared", |x| x.is_null()).await;

    // A stale CLOTHOD_SOCKET naming the wrong daemon: refused there, found anyway.
    let mut params = sh();
    params["env"]["CLOTHOD_SOCKET"] = json!(a_path.join("clothod.sock"));
    let pb2 = new_pane(&cb, params).await;
    let _ = new_pane(&ca, sh()).await; // A gets a pane with that id too
    cb.input(pb2, format!("{}\r", stand_in("wrong socket")).as_bytes());
    let got = wait_agent(&cb, pb2, "report in B", |x| x["state"] == "waiting").await;
    assert_eq!(got["message"], "wrong socket");
    assert!(pane_agent(&ca, pb2).await.is_null());

    // And the plain case: default socket is the pane's daemon.
    let mut params = sh();
    params["env"]["CLOTHOD_SOCKET"] = json!("");
    params["env"]["CLOTHOD_RUNTIME_DIR"] = json!(b.path());
    let pb3 = new_pane(&cb, params).await;
    cb.input(pb3, format!("{}\r", stand_in("default")).as_bytes());
    wait_agent(&cb, pb3, "report in B", |x| x["message"] == "default").await;
}

/// `pane.keys` encodes for the application's modes: kitty flags, bracketed paste.
#[tokio::test]
async fn pane_keys_follow_the_applications_modes() {
    let env = Env::new();
    let c = env.client().await;
    let rec = env.dir.path().join("keys");
    let mut params = sh();
    // Kitty "disambiguate + all keys as escapes", then record raw input.
    params["command"] = json!(["/bin/sh", "-c", format!(r#"printf '\033[>9u'; stty raw -echo; printf ready; exec cat > {}"#, rec.display())]);
    let p = new_pane(&c, params).await;
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l.contains("ready"))).await.unwrap();
    c.request("pane.keys", json!({"pane": p, "text": "hi", "keys": ["enter", "escape", "ctrl+c"]})).await.unwrap();
    let deadline = Instant::now() + T;
    let expected = b"hi\x1b[13u\x1b[27u\x1b[99;5u";
    loop {
        let got = std::fs::read(&rec).unwrap_or_default();
        if got == expected {
            break;
        }
        assert!(Instant::now() < deadline, "got {:?}", String::from_utf8_lossy(&got));
        tokio::time::sleep(Duration::from_millis(30)).await;
    }

    // Legacy app with bracketed paste: text is wrapped, Enter is CR.
    let rec2 = env.dir.path().join("keys2");
    let mut params = sh();
    params["command"] = json!(["/bin/sh", "-c", format!(r#"printf '\033[?2004h'; stty raw -echo; printf ready; exec cat > {}"#, rec2.display())]);
    let p2 = new_pane(&c, params).await;
    wait_for_text(&c, p2, T, |l| l.iter().any(|l| l.contains("ready"))).await.unwrap();
    c.request("pane.keys", json!({"pane": p2, "text": "a\nb", "keys": ["enter"]})).await.unwrap();
    let deadline = Instant::now() + T;
    loop {
        let got = std::fs::read(&rec2).unwrap_or_default();
        if got == b"\x1b[200~a\nb\x1b[201~\r" {
            break;
        }
        assert!(Instant::now() < deadline, "got {:?}", String::from_utf8_lossy(&got));
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    let e = c.request("pane.keys", json!({"pane": p2, "keys": ["hyper+q"]})).await.unwrap_err();
    assert!(e.to_string().contains("bad_request"), "{e}");
}

/// The `clotho` test client binary (built next to clothod; `CLOTHO_BIN` overrides).
fn clotho_bin() -> String {
    if let Ok(b) = std::env::var("CLOTHO_BIN") {
        return b;
    }
    let p = std::path::Path::new(&test_bin()).with_file_name("clotho");
    if !p.exists() {
        let ok = Command::new(env!("CARGO")).args(["build", "-p", "clotho", "--bin", "clotho"]).status().unwrap().success();
        assert!(ok, "building clotho");
    }
    p.to_string_lossy().into_owned()
}

/// Colour queries (OSC 10/11, mode 2031) are answered with the colours of the client using the
/// pane: the one that last typed in it, else the last to set colours, else the dark defaults;
/// with mode 2031 on, the application hears when they flip between dark and light.
#[tokio::test]
async fn color_queries_follow_the_clients_colors() {
    let env = Env::new();
    let light = json!({"foreground": "#1d1d1f", "background": "#FFFFFF", "cursor": "#0a84ff", "ansi": ["#000000", "#c41a16", "#007400", "#826b28", "#0000ff", "#a90d91", "#3e8087", "#e5e5e5", "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff"]});
    let a = env.client().await;
    let hello = a.request("hello", json!({"protocol": 1, "client": "test-a", "colors": light})).await.unwrap();
    assert!(hello["features"].as_array().unwrap().contains(&json!("client.colors")));
    let b = env.client().await;
    for bad in [json!({"background": "#fff"}), json!({"foreground": "#000000"}), json!({"foreground": "#000000", "background": "#ffffff", "ansi": ["#000000"]}), json!({"foreground": "#000000", "background": "#ffffff", "extra": 1}), json!("dark")] {
        let e = b.request("client.colors", json!({"colors": bad})).await.unwrap_err();
        assert!(e.to_string().contains("bad_request"), "{bad}: {e}");
    }
    assert!(b.request("hello", json!({"protocol": 1, "client": "test-b", "colors": {"background": "#zzzzzz"}})).await.is_err());

    // The application turns on mode 2031, then asks whenever the test says so; everything the
    // terminal answers lands in `rec`.
    let dir = env.dir.path();
    let rec = dir.join("rec");
    let mut params = sh();
    params["command"] = json!([
        "/bin/sh",
        "-c",
        format!(
            r#"stty raw -echo; exec 3<&0; cat <&3 > '{rec}' & printf '\033[?2031h'; for i in 1 2 3 4; do while [ ! -e "{d}/go$i" ]; do sleep 0.02; done; printf '\033]11;?\007\033[?996n'; done; wait"#,
            rec = rec.display(),
            d = dir.display()
        )
    ]);
    let p = new_pane(&b, params).await;
    // What arrived since the last call (`seen` bytes were returned before) once it has `want`.
    async fn wait_for(rec: &std::path::Path, seen: &mut usize, want: String) -> String {
        let got = |from: usize| String::from_utf8_lossy(&std::fs::read(rec).unwrap_or_default()[from..]).into_owned();
        let deadline = Instant::now() + T;
        while !got(*seen).contains(&want) {
            assert!(Instant::now() < deadline, "never got {want:?}: {:?}", got(*seen));
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let new = got(*seen);
        *seen += new.len();
        new
    }
    let mut seen = 0;
    let ask = |n: u32| std::fs::write(dir.join(format!("go{n}")), "").unwrap();
    let light_answer = "\x1b]11;rgb:ffff/ffff/ffff\x07\x1b[?997;2n".to_string();

    // Nobody uses the pane yet: the last client to set colours, A (light).
    ask(1);
    wait_for(&rec, &mut seen, light_answer.clone()).await;

    // B sets dark colours: now the latest, so the pane flips and the application is told.
    b.request("client.colors", json!({"colors": {"foreground": "#eeeeee", "background": "#101010"}})).await.unwrap();
    wait_for(&rec, &mut seen, "\x1b[?997;1n".into()).await;

    // A types in the pane: its colours again.
    a.request("pane.input", json!({"pane": p, "data": "x"})).await.unwrap();
    // The report (switching to A's colours) reaches the PTY just before the "x": wait for both.
    let from = seen;
    wait_for(&rec, &mut seen, "\x1b[?997;2n".into()).await;
    let mut again = from;
    wait_for(&rec, &mut again, "x".into()).await;
    seen = seen.max(again);
    ask(2);
    wait_for(&rec, &mut seen, light_answer).await;

    // A goes: back to B's.
    drop(a);
    wait_for(&rec, &mut seen, "\x1b[?997;1n".into()).await;
    ask(3);
    wait_for(&rec, &mut seen, "\x1b]11;rgb:1010/1010/1010\x07\x1b[?997;1n".into()).await;

    // B clears its colours: the defaults, still dark, so no notification.
    b.request("client.colors", json!({"colors": null})).await.unwrap();
    ask(4);
    let all = wait_for(&rec, &mut seen, "\x1b]11;rgb:1e1e/1e1e/1e1e\x07\x1b[?997;1n".into()).await;
    assert_eq!(all, "\x1b]11;rgb:1e1e/1e1e/1e1e\x07\x1b[?997;1n", "no flip report on the way: {all:?}");
}

/// `clotho attach` shows pane output in a real terminal, which answers the queries in it. Those
/// answers must not be forwarded: the daemon already answered, and e.g. a kitty `CSI ? u`
/// answer would switch Claude Code's keyboard protocol. The outer terminal here is another
/// clothod pane (its VT answers like a real terminal would).
#[tokio::test]
async fn attach_does_not_forward_the_outer_terminals_replies() {
    let env = Env::new();
    let c = env.client().await;
    let rec = env.dir.path().join("received");
    let mut params = sh();
    params["command"] = json!([
        "/bin/sh",
        "-c",
        format!(r#"stty raw -echo; printf ready; sleep 2; printf '\033[c\033[6n\033]11;?\007\033[?u'; exec cat > {}"#, rec.display())
    ]);
    let p = new_pane(&c, params).await;
    let outer = new_pane(&c, sh()).await;
    c.input(outer, format!("CLOTHOD_RUNTIME_DIR={} {} attach {p}\r", env.path().display(), clotho_bin()).as_bytes());
    wait_for_text(&c, outer, T, |l| l.iter().any(|l| l.contains("ready"))).await.unwrap();
    tokio::time::sleep(Duration::from_millis(3000)).await;
    let got = String::from_utf8_lossy(&std::fs::read(&rec).unwrap_or_default()).into_owned();
    // Exactly one answer per query: the daemon's.
    assert_eq!(got.matches("\x1b[?6c").count(), 1, "{got:?}");
    assert_eq!(got.matches('R').count(), 1, "{got:?}");
    assert_eq!(got.matches("]11;").count(), 1, "{got:?}");
    // Keys typed in the outer terminal still arrive.
    c.input(outer, b"hello\x1b[A");
    let deadline = Instant::now() + T;
    loop {
        let got = std::fs::read(&rec).unwrap_or_default();
        if got.ends_with(b"hello\x1b[A") {
            break;
        }
        assert!(Instant::now() < deadline, "keys lost: {:?}", String::from_utf8_lossy(&got));
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
}

/// A realistic settings file: other tools' hooks, including a PermissionRequest hook with a
/// matcher, on events we also use and on ones we don't. Install must leave them intact and in
/// order; uninstall must give back the exact file.
#[test]
fn hooks_install_keeps_other_tools_hooks_in_order() {
    let env = Env::empty();
    let home = env.dir.path().join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let settings = home.join(".claude/settings.json");
    let original = r#"{
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ]
  },
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/opt/othertool/bin/hook permission-request",
            "timeout": 600
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/othertool/bin/hook notify"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/opt/othertool/bin/hook pre-bash"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "echo hi"
  }
}
"#;
    std::fs::write(&settings, original).unwrap();
    let run = |args: &[&str]| {
        let out = Command::new(test_bin()).args(args).env("HOME", &home).env("CLOTHOD_INSTALL_DIR", env.dir.path().join("bin")).output().unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
    };
    run(&["hooks", "install", "claude"]);
    let s: Value = serde_json::from_str(&std::fs::read_to_string(&settings).unwrap()).unwrap();
    // Top-level key order kept.
    let keys: Vec<&str> = s.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(keys, ["permissions", "hooks", "statusLine"]);
    // Existing events keep their position and come first; ours are appended after.
    let events: Vec<&str> = s["hooks"].as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(&events[..3], ["PermissionRequest", "Notification", "PreToolUse"]);
    // The other tool's entries are untouched and still first within their events.
    let orig: Value = serde_json::from_str(original).unwrap();
    assert_eq!(s["hooks"]["PermissionRequest"][0], orig["hooks"]["PermissionRequest"][0], "the other tool's PermissionRequest hook stays first");
    let ours = &s["hooks"]["PermissionRequest"][1];
    assert_eq!(ours["matcher"], "*");
    assert!(ours["hooks"][0]["command"].as_str().unwrap().contains("report --claude-permission"));
    assert_eq!(ours["hooks"][0]["timeout"], 3600, "Claude's dialog shows meanwhile; the phone may answer within the hour");
    assert_eq!(s["hooks"]["Notification"][0], orig["hooks"]["Notification"][0]);
    assert_eq!(s["hooks"]["PreToolUse"][0], orig["hooks"]["PreToolUse"][0]);
    assert!(s["hooks"]["Notification"][1]["hooks"][0]["command"].as_str().unwrap().contains("report --claude-hook"));
    assert_eq!(s["permissions"], orig["permissions"]);
    assert_eq!(s["statusLine"], orig["statusLine"]);
    run(&["hooks", "uninstall", "claude"]);
    assert_eq!(std::fs::read_to_string(&settings).unwrap(), original);
}

/// `clothod upgrade` switches the running logic process to the new build, keeps the holder and
/// shells, and wins against something (an app reconnecting) that restarts the old build.
#[tokio::test]
async fn upgrade_switches_builds_despite_an_old_restarter() {
    let mut env = Env::new();
    let c = env.client().await;
    let instance = c.hello["instance"].clone();
    let p = new_pane(&c, sh()).await;
    c.input(p, b"U=kept-$((3*3)); echo u-$((1+1))\r");
    wait_for_text(&c, p, T, |l| has_line(l, "u-2")).await.unwrap();
    drop(c);
    env.daemon.take(); // from here the daemon is replaced; don't kill by handle in Drop

    // The racer: whenever the daemon is unreachable, start the old build again.
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let racer = {
        let (stop, dir, state) = (stop.clone(), env.path(), env.state());
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                if std::os::unix::net::UnixStream::connect(dir.join("clothod.sock")).is_err() {
                    let _ = Command::new(test_bin()).arg("start").arg("--runtime-dir").arg(&dir).env("CLOTHOD_STATE_DIR", &state).output();
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        })
    };

    // Another build (other bytes, so another id): upgrades are judged by build, not path.
    let (v2, id2) = other_build(&env, "v2");
    let base = env.dir.path().join("bin");
    let out = Command::new(&v2)
        .arg("upgrade")
        .arg("--runtime-dir")
        .arg(env.path())
        .env("CLOTHOD_STATE_DIR", env.state())
        .env("CLOTHOD_INSTALL_DIR", &base)
        .output()
        .unwrap();
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    racer.join().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let installed = stdout.lines().last().and_then(|l| l.strip_prefix("running ")).unwrap_or_else(|| panic!("{stdout}")).to_string();
    eprintln!("upgrade output: {stdout}{}", String::from_utf8_lossy(&out.stderr));
    assert!(installed.starts_with(&base.display().to_string()), "{installed}");

    let c = env.client().await;
    let exe = std::path::Path::new(c.hello["exe"].as_str().unwrap()).canonicalize().unwrap();
    assert_eq!(exe, std::path::Path::new(&installed).canonicalize().unwrap(), "the upgraded build runs");
    assert_eq!((c.hello["build"].clone(), c.hello["holder"]["build"].clone()), (json!(id2), json!(id2)));
    assert_eq!(c.hello["instance"], instance, "same holder");
    c.input(p, b"echo $U\r");
    wait_for_text(&c, p, T, |l| has_line(l, "kept-9")).await.unwrap();
}

/// What the Mac app does when its connection drops: `<install dir>/current/clothod start`, about
/// a second later. On macbook this restarted the old build in the middle of both the 0.1.6 and
/// the 0.1.7 upgrade, which then needed a second attempt. An upgrade must win the first time.
#[tokio::test]
async fn upgrade_is_not_undone_by_a_client_restarting_current() {
    let mut env = Env::empty();
    let base = env.dir.path().join("bin");
    // The machine's install: the old build, and `current` pointing at it.
    let (v1, id1) = other_build(&env, "v1");
    let out = clothod_cmd(&env, &v1, &["install"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let current = base.join("current/clothod");
    env.start_with(&current.to_string_lossy(), &[("CLOTHOD_INSTALL_DIR", &base.to_string_lossy())]);
    let c = env.client().await;
    assert_eq!(c.hello["build"], id1);
    let (p, shell) = live_shell(&c).await;
    let holder = holder_pid(&env);
    drop(c);
    env.daemon.take();

    // The client: whenever the daemon is unreachable, start it through `current`, at once.
    // Stopped by its guard even when an assert fails: left running, it would recreate the test's
    // dir after it is gone.
    struct Racer(std::sync::Arc<std::sync::atomic::AtomicBool>, Option<std::thread::JoinHandle<()>>);
    impl Drop for Racer {
        fn drop(&mut self) {
            self.0.store(true, std::sync::atomic::Ordering::Relaxed);
            if let Some(t) = self.1.take() {
                let _ = t.join();
            }
        }
    }
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let starts = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let client = {
        let (stop, starts, dir, state, current, base, bundled) = (stop.clone(), starts.clone(), env.path(), env.state(), current.clone(), base.clone(), v1.clone());
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                if std::os::unix::net::UnixStream::connect(dir.join("clothod.sock")).is_err() {
                    // As the Mac app does before each start: install its bundled build (the
                    // one being upgraded from), which must leave `current` alone.
                    let _ = Command::new(&bundled).arg("install").env("CLOTHOD_INSTALL_DIR", &base).output();
                    let o = Command::new(&current)
                        .arg("start")
                        .arg("--runtime-dir")
                        .arg(&dir)
                        .env("CLOTHOD_STATE_DIR", &state)
                        .env("CLOTHOD_INSTALL_DIR", &base)
                        .output()
                        .unwrap();
                    starts.lock().unwrap().push(format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)));
                }
                std::thread::sleep(Duration::from_millis(5));
            }
        })
    };
    let racer = Racer(stop.clone(), Some(client));

    // Several upgrades in a row: the race is a matter of timing, and each round is a chance.
    let mut last = String::new();
    for round in 2..8 {
        let (v, id) = other_build(&env, &format!("v{round}"));
        let out = clothod_cmd(&env, &v, &["upgrade"]);
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        assert!(out.status.success(), "round {round}: {stderr}");
        assert!(!stderr.contains("attempt 2"), "round {round}: the client restarted the old build mid-upgrade: {stderr}");
        let c = env.client().await;
        assert_eq!((c.hello["build"].clone(), c.hello["holder"]["build"].clone()), (json!(id), json!(id)), "round {round}");
        assert_eq!(holder_pid(&env), holder);
        assert_shell_alive(&c, p, &shell).await;
        assert_eq!(versions(&env), vec![id.clone(), "current".to_string()]);
        last = id;
    }
    drop(racer);
    assert!(!last.is_empty() && last != id1);
}

/// Leftovers of earlier runs killed before Drop could clean up: clothod processes of ours
/// serving a /tmp/clt* runtime dir for over an hour. Never touches any other instance.
fn sweep_stale_test_instances() {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    for p in clotho_proto::platform::own_processes() {
        let is_clothod = p.exe.as_ref().and_then(|e| e.file_name()).is_some_and(|n| n.to_string_lossy().starts_with("clothod"));
        let dir = p.args.iter().position(|a| a == "--runtime-dir").and_then(|i| p.args.get(i + 1)).cloned();
        let (Some(dir), true) = (dir, is_clothod) else { continue };
        let old = p.started.is_some_and(|s| now.saturating_sub(s) > 3600);
        if dir.starts_with("/tmp/clt") && old {
            eprintln!("sweeping stale test instance {} ({dir})", p.pid);
            unsafe { libc::kill(p.pid as i32, libc::SIGTERM) };
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}

// ---- one version per machine -------------------------------------------------------------

/// A different build of clothod (same code, other bytes, so another install id).
fn other_build(env: &Env, name: &str) -> (String, String) {
    let dir = env.dir.path().join(name);
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("clothod");
    let mut data = std::fs::read(test_bin()).unwrap();
    data.extend_from_slice(format!("\0clotho-test-build-{name}\0").as_bytes());
    std::fs::write(&p, data).unwrap();
    std::fs::set_permissions(&p, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let id = clotho_proto::platform::build_id(&p).unwrap();
    (p.to_string_lossy().into_owned(), id)
}

fn holder_pid(env: &Env) -> u32 {
    std::fs::read_to_string(env.path().join("holder.pid")).unwrap().trim().parse().unwrap()
}

fn clothod_cmd(env: &Env, bin: &str, args: &[&str]) -> std::process::Output {
    Command::new(bin)
        .args(args)
        .arg("--runtime-dir")
        .arg(env.path())
        .env("CLOTHOD_STATE_DIR", env.state())
        .env("CLOTHOD_INSTALL_DIR", env.dir.path().join("bin"))
        .env("CLOTHOD_REGISTRY_DIR", env.dir.path().join("registry"))
        .env("CLOTHOD_RUNTIME_DIR", env.path())
        .output()
        .unwrap()
}

fn versions(env: &Env) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(env.dir.path().join("bin"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.'))
        .collect();
    v.sort();
    v
}

/// A shell with a variable set, its pid and the screen, for checking nothing was lost.
async fn live_shell(c: &Client) -> (u64, String) {
    let p = new_pane(c, sh()).await;
    c.input(p, b"V=alive-$((6*7)); echo shellpid=$$\r");
    let lines = wait_for_text(c, p, T, |l| l.iter().any(|l| output(l).starts_with("shellpid="))).await.unwrap();
    let pid = lines.iter().find_map(|l| output(l).strip_prefix("shellpid=")).unwrap().to_string();
    (p, pid)
}

async fn assert_shell_alive(c: &Client, p: u64, pid: &str) {
    c.input(p, b"echo $V-$$\r");
    let want = format!("alive-42-{pid}");
    wait_for_text(c, p, T, |l| has_line(l, &want)).await.unwrap();
}

#[tokio::test]
async fn upgrade_moves_serve_and_holder_in_place_and_keeps_one_version() {
    let mut env = Env::new();
    let c = env.client().await;
    let instance = c.hello["instance"].clone();
    let (p, shell) = live_shell(&c).await;
    let before = daemon_text(&c, p).await;
    let holder = holder_pid(&env);
    drop(c);
    env.daemon.take();

    let (v2, id2) = other_build(&env, "v2");
    let out = clothod_cmd(&env, &v2, &["upgrade"]);
    let holder_log = || std::fs::read_to_string(env.state().join("holder.log")).unwrap_or_default();
    assert!(out.status.success(), "{}\nholder log:\n{}", String::from_utf8_lossy(&out.stderr), holder_log());
    let c = env.client().await;
    assert_eq!(c.hello["build"], id2, "serve runs the new build");
    assert_eq!(c.hello["holder"]["build"], id2, "the holder too, upgraded in place");
    assert_eq!(c.hello["holder_outdated"], false);
    assert_eq!(c.hello["instance"], instance);
    assert_eq!(holder_pid(&env), holder, "same holder process");
    assert_eq!(daemon_text(&c, p).await, before, "screen kept");
    assert_shell_alive(&c, p, &shell).await;
    assert_eq!(versions(&env), vec![id2.clone(), "current".to_string()], "exactly one version");

    // And again to a third build: the previous one goes away.
    let (v3, id3) = other_build(&env, "v3");
    let out = clothod_cmd(&env, &v3, &["upgrade"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let c = env.client().await;
    assert_eq!(c.hello["holder"]["build"], id3);
    assert_eq!(holder_pid(&env), holder);
    assert_shell_alive(&c, p, &shell).await;
    assert_eq!(versions(&env), vec![id3, "current".to_string()]);
}

/// The old serve can take a while to exit after its socket is gone (snapshots of many panes,
/// a loaded machine). The upgrade's start waits for it rather than ask it to rebind its socket
/// (it is leaving), so the upgrade neither stalls nor reports a socket that "did not come back".
#[tokio::test]
async fn upgrade_waits_for_a_slow_exit_without_false_alarms() {
    let mut env = Env::empty();
    env.start_with(&test_bin(), &[("CLOTHOD_TEST_SLOW_EXIT_MS", "2000")]);
    let c = env.client().await;
    let (p, shell) = live_shell(&c).await;
    let holder = holder_pid(&env);
    drop(c);
    env.daemon.take();
    let (v2, id2) = other_build(&env, "v2");
    let t = Instant::now();
    let out = clothod_cmd(&env, &v2, &["upgrade"]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    assert!(!stderr.contains("did not come back"), "a false alarm: {stderr}");
    assert_eq!(stderr.matches("attempt").count(), 1, "{stderr}");
    assert!(t.elapsed() < Duration::from_secs(15), "{:?}", t.elapsed());
    let c = env.client().await;
    assert_eq!(c.hello["build"], id2);
    assert_eq!(holder_pid(&env), holder, "same holder");
    assert_shell_alive(&c, p, &shell).await;
}

#[tokio::test]
async fn holder_refuses_an_incompatible_target_and_survives_exec_failure() {
    let mut env = Env::new();
    let c = env.client().await;
    let (p, shell) = live_shell(&c).await;
    let holder = holder_pid(&env);
    let old_build = c.hello["holder"]["build"].clone();
    drop(c);

    // A target that can't read this holder's state: refused, the holder keeps running.
    env.kill();
    std::fs::write(env.path().join("CLOTHOD_TEST_HOLDER_FORMATS"), "99").unwrap();
    let (v2, _) = other_build(&env, "v2");
    env.start_with(&v2, &[]);
    let c = env.client().await;
    assert_eq!(c.hello["holder"]["build"], old_build, "holder kept its build");
    assert_eq!(c.hello["holder_outdated"], true);
    assert_eq!(holder_pid(&env), holder);
    assert_shell_alive(&c, p, &shell).await;
    drop(c);
    std::fs::remove_file(env.path().join("CLOTHOD_TEST_HOLDER_FORMATS")).unwrap();

    // execve fails: the holder carries on as before.
    env.kill();
    std::fs::write(env.path().join("CLOTHOD_TEST_EXEC_FAIL"), "").unwrap();
    let (v3, _) = other_build(&env, "v3");
    env.start_with(&v3, &[]);
    let c = env.client().await;
    assert_eq!(c.hello["holder"]["build"], old_build);
    assert_eq!(holder_pid(&env), holder);
    assert_shell_alive(&c, p, &shell).await;
    let p2 = new_pane(&c, sh()).await; // and it still works
    c.input(p2, b"echo fresh\r");
    wait_for_text(&c, p2, T, |l| has_line(l, "fresh")).await.unwrap();
    drop(c);
    std::fs::remove_file(env.path().join("CLOTHOD_TEST_EXEC_FAIL")).unwrap();

    // Without the hooks the next serve does upgrade it.
    env.kill();
    let (v4, id4) = other_build(&env, "v4");
    env.start_with(&v4, &[]);
    let c = env.client().await;
    assert_eq!(c.hello["holder"]["build"], id4);
    assert_eq!(holder_pid(&env), holder);
    assert_shell_alive(&c, p, &shell).await;
}

#[tokio::test]
async fn failed_upgrade_rolls_back_to_the_old_version() {
    let mut env = Env::empty();
    // The old build, installed and running from its install dir as on a real machine.
    let (v1, id1) = other_build(&env, "v1");
    let out = clothod_cmd(&env, &v1, &["install"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let v1_installed = String::from_utf8_lossy(&out.stdout).trim().to_string();
    env.start_with(&v1_installed, &[]);
    let c = env.client().await;
    let (p, shell) = live_shell(&c).await;
    let holder = holder_pid(&env);
    drop(c);
    env.daemon.take();

    let (v2, id2) = other_build(&env, "v2");
    assert!(!clothod_cmd(&env, &v2, &["install"]).status.success(), "install alone never adds a second version");
    std::fs::write(env.path().join("CLOTHOD_TEST_FAIL_UPGRADE"), "").unwrap();
    let out = clothod_cmd(&env, &v2, &["upgrade"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("rolled back"), "{}", String::from_utf8_lossy(&out.stderr));
    std::fs::remove_file(env.path().join("CLOTHOD_TEST_FAIL_UPGRADE")).unwrap();

    assert_eq!(versions(&env), vec![id1.clone(), "current".to_string()], "only the old version left");
    assert_eq!(std::fs::read_link(env.dir.path().join("bin/current")).unwrap().to_string_lossy(), id1);
    let c = env.client().await;
    assert_eq!(c.hello["build"], id1, "old serve back");
    assert_eq!(
        c.hello["holder"]["build"],
        id1,
        "holder moved back in place\nupgrade stderr: {}\nserve log: {}\nholder log: {}",
        String::from_utf8_lossy(&out.stderr),
        std::fs::read_to_string(env.state().join("clothod.log")).unwrap_or_default(),
        std::fs::read_to_string(env.state().join("holder.log")).unwrap_or_default()
    );
    assert_eq!(holder_pid(&env), holder);
    assert_shell_alive(&c, p, &shell).await;
    let _ = id2;
}

#[test]
fn only_the_default_instance_may_be_persistent() {
    let dir = tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap();
    let out = Command::new(test_bin())
        .args(["start", "--runtime-dir"])
        .arg(dir.path())
        .env_remove("CLOTHOD_EPHEMERAL")
        .env("CLOTHOD_STATE_DIR", dir.path().join("state"))
        .output()
        .unwrap();
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("Only the default instance is persistent") && err.contains("--ephemeral"), "{err}");
    assert!(!dir.path().join("clothod.sock").exists());
}

#[tokio::test]
async fn ephemeral_instances_clean_up_after_themselves() {
    // exit: ends when its last client leaves, panes and all.
    let root = tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap();
    let dir = root.path().join("run");
    let start = |mode: &str| {
        let out = Command::new(test_bin())
            .args(["start", "--runtime-dir"])
            .arg(&dir)
            .arg(format!("--ephemeral={mode}"))
            .env_remove("CLOTHOD_EPHEMERAL")
            .env("CLOTHOD_STATE_DIR", root.path().join("state"))
            .env("CLOTHOD_REGISTRY_DIR", root.path().join("registry"))
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    };
    // Async waits: the dropped client's tasks must get to run for its socket to close.
    let gone = |what: &'static str| {
        let dir = dir.clone();
        async move {
            let deadline = Instant::now() + Duration::from_secs(10);
            while dir.exists() {
                assert!(Instant::now() < deadline, "{what}: {} still there", dir.display());
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    };
    start("exit");
    // clothod's own probes (status here; upgrade does the same) come and go without ending it.
    let st = Command::new(test_bin()).args(["status", "--runtime-dir"]).arg(&dir).env("CLOTHOD_STATE_DIR", root.path().join("state")).output().unwrap();
    assert!(st.status.success(), "{}", String::from_utf8_lossy(&st.stderr));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(dir.join("clothod.sock").exists(), "a probe is not the last client");
    let c = Client::connect(&dir).await.unwrap();
    let holder: u32 = std::fs::read_to_string(dir.join("holder.pid")).unwrap().trim().parse().unwrap();
    new_pane(&c, sh()).await;
    drop(c);
    gone("exit mode").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!clotho_proto::platform::process_alive(holder), "holder gone too");

    // idle: ends after N seconds with no clients and no panes.
    start("2");
    let c = Client::connect(&dir).await.unwrap();
    let p = new_pane(&c, sh()).await;
    drop(c);
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert!(dir.exists(), "a pane keeps it alive");
    let c = Client::connect(&dir).await.unwrap();
    c.request("pane.close", json!({"pane": p})).await.unwrap();
    drop(c);
    gone("idle mode").await;
}

// ---- files (fs.*) -----------------------------------------------------------------------

fn fs_err(e: anyhow::Error) -> String {
    e.to_string()
}

/// A scratch directory for fs tests (under the test's temp dir).
fn fs_root(env: &Env) -> PathBuf {
    let d = env.dir.path().join("files");
    std::fs::create_dir_all(&d).unwrap();
    d.canonicalize().unwrap()
}

#[tokio::test]
async fn fs_metadata_listing_and_errors() {
    let env = Env::new();
    let c = env.client().await;
    assert!(c.hello["features"].as_array().unwrap().iter().any(|f| f == "fs"));
    assert!(c.hello["machine"]["home"].as_str().is_some_and(|h| !h.is_empty()));
    let root = fs_root(&env);
    let r = root.to_str().unwrap();

    let d = c.request("fs.mkdir", json!({"path": format!("{r}/a/b"), "parents": true})).await.unwrap();
    assert_eq!(d["type"], "dir");
    std::fs::write(root.join("a/b/notes.txt"), "hello\n").unwrap();
    std::fs::write(root.join("a/bin.dat"), [0u8, 1, 2]).unwrap();
    std::os::unix::fs::symlink(root.join("a/b"), root.join("a/link-to-b")).unwrap();
    std::os::unix::fs::symlink(root.join("nowhere"), root.join("a/dangling")).unwrap();
    std::fs::write(root.join("a/.hidden"), "").unwrap();

    let st = c.request("fs.stat", json!({"path": format!("{r}/a/b/notes.txt")})).await.unwrap();
    assert_eq!((st["type"].clone(), st["size"].clone(), st["text"].clone()), (json!("file"), json!(6), json!(true)));
    assert!(st["mtime_ns"].as_str().unwrap().parse::<i128>().is_ok());
    let st = c.request("fs.stat", json!({"path": format!("{r}/a/bin.dat")})).await.unwrap();
    assert_eq!(st["text"], false);

    let l = c.request("fs.list", json!({"path": format!("{r}/a")})).await.unwrap();
    let names: Vec<&str> = l["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, [".hidden", "b", "bin.dat", "dangling", "link-to-b"]);
    let get = |n: &str| l["entries"].as_array().unwrap().iter().find(|e| e["name"] == n).unwrap().clone();
    assert_eq!((get("link-to-b")["type"].clone(), get("link-to-b")["link"].clone()), (json!("dir"), json!(true)), "a link to a dir is a dir");
    assert_eq!((get("dangling")["type"].clone(), get("dangling")["link"].clone()), (json!("other"), json!(true)));
    assert_eq!(l["dir"]["type"], "dir");
    let l = c.request("fs.list", json!({"path": format!("{r}/a"), "hidden": false})).await.unwrap();
    assert_eq!(l["entries"].as_array().unwrap().len(), 4);

    // Paging: stable, complete, no repeats.
    for i in 0..25 {
        std::fs::write(root.join(format!("a/b/f{i:02}")), "").unwrap();
    }
    let (mut all, mut cursor) = (Vec::new(), Value::Null);
    loop {
        let mut p = json!({"path": format!("{r}/a/b"), "limit": 10});
        if !cursor.is_null() {
            p["cursor"] = cursor.clone();
        }
        let page = c.request("fs.list", p).await.unwrap();
        all.extend(page["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap().to_string()));
        cursor = page["next"].clone();
        if cursor.is_null() {
            break;
        }
    }
    assert_eq!(all.len(), 26);
    let mut sorted = all.clone();
    sorted.sort();
    assert_eq!(all, sorted);

    // setattr, rename, remove, statfs.
    let e = c.request("fs.setattr", json!({"path": format!("{r}/a/bin.dat"), "mtime_ns": "1700000000123456789", "mode": 0o600})).await.unwrap();
    assert_eq!((e["mtime_ns"].clone(), e["mode"].clone()), (json!("1700000000123456789"), json!(0o600)));
    let e = fs_err(c.request("fs.rename", json!({"from": format!("{r}/a/bin.dat"), "to": format!("{r}/a/b/notes.txt")})).await.unwrap_err());
    assert!(e.contains("exists"), "{e}");
    c.request("fs.rename", json!({"from": format!("{r}/a/bin.dat"), "to": format!("{r}/a/moved.dat")})).await.unwrap();
    let e = fs_err(c.request("fs.remove", json!({"path": format!("{r}/a/b")})).await.unwrap_err());
    assert!(e.contains("not_empty"), "{e}");
    c.request("fs.remove", json!({"path": format!("{r}/a/link-to-b")})).await.unwrap();
    assert!(root.join("a/b/notes.txt").exists(), "removing a link doesn't follow it");
    c.request("fs.remove", json!({"path": format!("{r}/a/b"), "recursive": true})).await.unwrap();
    assert!(!root.join("a/b").exists());
    let sf = c.request("fs.statfs", json!({"path": r})).await.unwrap();
    assert!(sf["total"].as_u64().unwrap() > 0 && sf["available"].as_u64().unwrap() <= sf["total"].as_u64().unwrap());

    // Path rules and error codes.
    for bad in ["~root/x", "relative/x"] {
        let e = fs_err(c.request("fs.stat", json!({"path": bad})).await.unwrap_err());
        assert!(e.contains("bad_request"), "{bad}: {e}");
    }
    let home = c.request("fs.stat", json!({"path": "~"})).await.unwrap();
    assert_eq!(home["type"], "dir");
    let e = fs_err(c.request("fs.stat", json!({"path": format!("{r}/missing")})).await.unwrap_err());
    assert!(e.contains("not_found"), "{e}");

    // Raw (non-UTF-8) names, where the filesystem allows them (not APFS).
    use std::os::unix::ffi::OsStrExt;
    let odd = root.join(std::ffi::OsStr::from_bytes(b"odd-\xff-name"));
    if std::fs::write(&odd, "x").is_ok() {
        let l = c.request("fs.list", json!({"path": r})).await.unwrap();
        let e = l["entries"].as_array().unwrap().iter().find(|e| e.get("path_raw").is_some()).expect("raw entry").clone();
        let st = c.request("fs.stat", json!({"path_raw": e["path_raw"]})).await.unwrap();
        assert_eq!(st["size"], 1);
    }
}

/// Read a stream into memory, acking as it goes (fire-and-forget acks every quarter window).
async fn read_stream(c: &mut Client, stream: u64, start: u64, window: u64) -> Result<Vec<u8>, String> {
    let mut data = Vec::new();
    let mut pos = start;
    let mut acked = start;
    loop {
        let f = tokio::time::timeout(T, c.recv()).await.map_err(|_| "timeout".to_string())?.ok_or("closed")?;
        match f {
            Frame::FileData { stream: s, offset, flags, data: d } if s == stream => {
                assert_eq!(offset, pos, "contiguous");
                pos += d.len() as u64;
                data.extend_from_slice(&d);
                if flags & clotho_proto::frame::FILE_FIN != 0 {
                    return Ok(data);
                }
                if pos - acked >= window / 4 {
                    c.send(Frame::Json(json!({"method": "fs.ack", "params": {"stream": stream, "offset": pos}})));
                    acked = pos;
                }
            }
            Frame::Json(v) if v["event"] == "fs.error" && v["data"]["stream"] == stream => return Err(v["data"]["code"].as_str().unwrap().into()),
            _ => {}
        }
    }
}

fn pattern(n: usize) -> Vec<u8> {
    (0..n).map(|i| (i * 7 % 251) as u8).collect()
}

#[tokio::test]
async fn fs_read_streams_with_flow_control_and_guards() {
    let env = Env::new();
    let mut c = env.client().await;
    let root = fs_root(&env);
    let content = pattern(3 << 20);
    std::fs::write(root.join("big.bin"), &content).unwrap();
    let path = root.join("big.bin").to_string_lossy().into_owned();

    let r = c.request("fs.read", json!({"path": path, "chunk": 65536, "window": 1 << 20})).await.unwrap();
    assert_eq!(r["size"], content.len());
    let got = read_stream(&mut c, r["stream"].as_u64().unwrap(), 0, 1 << 20).await.unwrap();
    assert_eq!(got, content);

    // Without acks the daemon stops at the window.
    let r = c.request("fs.read", json!({"path": path, "chunk": 65536, "window": 262144})).await.unwrap();
    let id = r["stream"].as_u64().unwrap();
    let mut seen = 0usize;
    while let Ok(Some(f)) = tokio::time::timeout(Duration::from_millis(500), c.recv()).await {
        if let Frame::FileData { stream, data, .. } = f {
            if stream == id {
                seen += data.len();
            }
        }
    }
    assert_eq!(seen, 262144, "exactly one window without acks");
    c.request("fs.cancel", json!({"stream": id})).await.unwrap();

    // Ranges, and resume guards.
    let r = c.request("fs.read", json!({"path": path, "offset": 1000, "length": 5000})).await.unwrap();
    let got = read_stream(&mut c, r["stream"].as_u64().unwrap(), 1000, DEFAULT_WINDOW_TEST).await.unwrap();
    assert_eq!(got, content[1000..6000]);
    let mtime = r_mtime(&c, &path).await;
    let ok = c.request("fs.read", json!({"path": path, "offset": 5, "length": 1, "expect_size": content.len(), "expect_mtime_ns": mtime})).await;
    assert!(ok.is_ok());
    let e = fs_err(c.request("fs.read", json!({"path": path, "offset": 5, "expect_size": 12})).await.unwrap_err());
    assert!(e.contains("changed"), "{e}");
}

const DEFAULT_WINDOW_TEST: u64 = 4 << 20;

async fn r_mtime(c: &Client, path: &str) -> Value {
    c.request("fs.stat", json!({"path": path})).await.unwrap()["mtime_ns"].clone()
}

/// Send `data` as a write stream from `from`, returning the fs.done (or fs.error) event data.
async fn write_stream(c: &mut Client, stream: u64, from: u64, data: &[u8], chunk: usize, fin: bool) -> Value {
    let mut pos = from as usize;
    while pos < data.len() {
        let end = (pos + chunk).min(data.len());
        c.send(Frame::FileData { stream, offset: pos as u64, flags: 0, data: data[pos..end].to_vec() });
        pos = end;
    }
    if !fin {
        return Value::Null;
    }
    c.send(Frame::FileData { stream, offset: pos as u64, flags: clotho_proto::frame::FILE_FIN, data: Vec::new() });
    loop {
        let f = tokio::time::timeout(T, c.recv()).await.expect("fs.done").expect("open");
        if let Frame::Json(v) = f {
            if (v["event"] == "fs.done" || v["event"] == "fs.error") && v["data"]["stream"] == stream {
                return v;
            }
        }
    }
}

#[tokio::test]
async fn fs_atomic_writes_conflicts_and_resume() {
    let env = Env::new();
    let mut c = env.client().await;
    let root = fs_root(&env);
    let target = root.join("up.bin");
    let path = target.to_string_lossy().into_owned();
    let content = pattern(2 << 20);

    // Upload with mode and mtime kept; the target appears only after FIN.
    let r = c
        .request("fs.write", json!({"path": path, "size": content.len(), "mode": 0o755, "mtime_ns": "1600000000000000000", "chunk": 65536}))
        .await
        .unwrap();
    let id = r["stream"].as_u64().unwrap();
    write_stream(&mut c, id, 0, &content[..1 << 20], 65536, false).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!target.exists(), "no partial target");
    let done = write_stream(&mut c, id, 1 << 20, &content, 65536, true).await;
    assert_eq!(done["event"], "fs.done", "{done}");
    assert_eq!(std::fs::read(&target).unwrap(), content);
    let e = &done["data"]["entry"];
    assert_eq!((e["mode"].clone(), e["mtime_ns"].clone()), (json!(0o755), json!("1600000000000000000")));
    assert!(std::fs::read_dir(&root).unwrap().flatten().all(|e| !e.file_name().to_string_lossy().contains("clotho-part")), "no part file left");

    // Existing target: exists without overwrite; conflict if it changed since read.
    let err1 = fs_err(c.request("fs.write", json!({"path": path})).await.unwrap_err());
    assert!(err1.contains("exists"), "{err1}");
    let err2 = fs_err(c.request("fs.write", json!({"path": path, "overwrite": true, "expect_mtime_ns": "1"})).await.unwrap_err());
    assert!(err2.contains("conflict"), "{err2}");

    // Resume: half an upload, the connection drops, a new one continues from the part file.
    let big = pattern(3 << 20);
    let params = json!({"path": root.join("resume.bin"), "size": big.len(), "upload_id": "abc123", "source": "v1", "chunk": 65536});
    let r = c.request("fs.write", params.clone()).await.unwrap();
    assert_eq!(r["offset"], 0);
    write_stream(&mut c, r["stream"].as_u64().unwrap(), 0, &big[..1 << 20], 65536, false).await;
    // Let the daemon write it before the connection goes.
    let deadline = Instant::now() + T;
    loop {
        if let Some(Frame::Json(v)) = c.try_recv() {
            if v["event"] == "fs.ack" && v["data"]["offset"].as_u64() == Some(1 << 20) {
                break;
            }
        }
        assert!(Instant::now() < deadline, "no ack");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    drop(c);
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut c = env.client().await;
    let r = c.request("fs.write", params.clone()).await.unwrap();
    assert_eq!(r["offset"], 1 << 20, "resumes where it left off");
    let done = write_stream(&mut c, r["stream"].as_u64().unwrap(), 1 << 20, &big, 65536, true).await;
    assert_eq!(done["event"], "fs.done", "{done}");
    assert_eq!(std::fs::read(root.join("resume.bin")).unwrap(), big);

    // A different source restarts at 0.
    let mut p2 = params.clone();
    p2["path"] = json!(root.join("resume2.bin"));
    let r = c.request("fs.write", p2.clone()).await.unwrap();
    write_stream(&mut c, r["stream"].as_u64().unwrap(), 0, &big[..65536], 65536, false).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    c.request("fs.cancel", json!({"stream": r["stream"]})).await.unwrap();
    p2["source"] = json!("v2");
    let r = c.request("fs.write", p2).await.unwrap();
    assert_eq!(r["offset"], 0, "the local data changed: start over");
    c.request("fs.cancel", json!({"stream": r["stream"]})).await.unwrap();

    // Cancelling a write without upload_id leaves nothing behind.
    let r = c.request("fs.write", json!({"path": root.join("gone.bin")})).await.unwrap();
    write_stream(&mut c, r["stream"].as_u64().unwrap(), 0, b"partial", 7, false).await;
    c.request("fs.cancel", json!({"stream": r["stream"]})).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(std::fs::read_dir(&root).unwrap().flatten().all(|e| !e.file_name().to_string_lossy().contains("gone.bin")));

    // Writing through a symlink replaces the target's contents, not the link.
    std::fs::write(root.join("real.txt"), "old").unwrap();
    std::os::unix::fs::symlink(root.join("real.txt"), root.join("alias.txt")).unwrap();
    let r = c.request("fs.write", json!({"path": root.join("alias.txt"), "overwrite": true})).await.unwrap();
    let done = write_stream(&mut c, r["stream"].as_u64().unwrap(), 0, b"new", 3, true).await;
    assert_eq!(done["event"], "fs.done", "{done}");
    assert!(std::fs::symlink_metadata(root.join("alias.txt")).unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read_to_string(root.join("real.txt")).unwrap(), "new");
}

/// Terminal output must not wait behind a big transfer.
#[tokio::test]
async fn fs_transfers_do_not_stall_terminals() {
    let env = Env::new();
    let mut c = env.client().await;
    let root = fs_root(&env);
    std::fs::write(root.join("huge.bin"), pattern(48 << 20)).unwrap();
    let p = new_pane(&c, sh()).await;
    let (_, mut s) = subscribe(&mut c, p, None).await;
    sync(&mut c, &mut s).await.unwrap();
    // A big window queues a lot of file data at once.
    let _r = c.request("fs.read", json!({"path": root.join("huge.bin"), "window": 48 << 20, "chunk": 1 << 20})).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let t0 = Instant::now();
    c.input(p, b"echo prio-$((2+2))\r");
    loop {
        let f = tokio::time::timeout(T, c.recv()).await.unwrap().unwrap();
        if let Frame::Output { data, .. } = &f {
            if String::from_utf8_lossy(data).contains("prio-4") {
                break;
            }
        }
    }
    let waited = t0.elapsed();
    assert!(waited < Duration::from_millis(1500), "pane output waited {waited:?} behind file data");
}

/// A detected Claude Code reads its state from the title glyph: spinner = running, ✳ = idle.
#[tokio::test]
async fn detected_claude_state_follows_its_title_glyph() {
    let env = Env::new();
    let c = env.client().await;
    let p = new_pane(&c, sh()).await;
    let fake = env.dir.path().join("claude");
    // Working (spinner) while silent for 4 s, then idle (✳).
    std::fs::write(&fake, "#!/bin/sh\nprintf '\\033]0;\\342\\240\\213 Fixing tests\\007'\nsleep 4\nprintf '\\033]0;\\342\\234\\263 Fixing tests\\007'\nsleep 60\n").unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    c.input(p, format!("{}\r", fake.display()).as_bytes());
    wait_agent(&c, p, "detected", |a| a["kind"] == "claude").await;
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let a = pane_agent(&c, p).await;
    assert_eq!(a["state"], "running", "spinner title means running, though nothing is printed: {a}");
    wait_agent(&c, p, "idle after ✳", |a| a["state"] == "waiting").await;
    let a = pane_agent(&c, p).await;
    assert_eq!(a["attention"], false, "a guess never raises attention");
    let t = c.request("state.get", json!({})).await.unwrap()["panes"][0]["title"].clone();
    assert_eq!(t, "✳ Fixing tests", "the raw title is kept");
    c.input(p, b"\x03");
}

/// Programs printing as fast as they can (`yes`, `cat` of a huge file) must slow down, not
/// break the daemon: the holder stops reading their PTYs while the daemon is behind.
#[tokio::test]
async fn firehose_output_applies_backpressure_instead_of_failing() {
    let env = Env::new();
    let c = env.client().await;
    for _ in 0..3 {
        let mut p = sh();
        p["command"] = json!(["/bin/sh", "-c", "yes firehose-0123456789-abcdefghijklmnopqrstuvwxyz"]);
        new_pane(&c, p).await;
    }
    tokio::time::sleep(Duration::from_secs(3)).await;
    // Still responsive: new panes, input, output.
    let p = new_pane(&c, sh()).await;
    c.input(p, b"echo alive-$((3*4))\r");
    wait_for_text(&c, p, T, |l| has_line(l, "alive-12")).await.unwrap();
    assert!(!env.log().contains("holder closed the connection"), "{}", env.log());
    let s = c.request("state.get", json!({})).await.unwrap();
    assert!(s["panes"][0]["seq"].as_u64().unwrap() > 1 << 20, "the firehose did run");
}

/// A connection whose queue is full when it subscribes (a reconnect resubscribing many panes)
/// gets the reply at once and the pane's snapshot only once it has drained: memory per
/// connection stays bounded.
#[tokio::test]
async fn subscribing_with_a_full_queue_defers_the_snapshot() {
    use clotho_proto::{read_frame, write_frame};
    let env = Env::new();
    let c = env.client().await;
    let mut fire = sh();
    fire["command"] = json!(["/bin/sh", "-c", "yes firehose-0123456789-abcdefghijklmnopqrstuvwxyz"]);
    let a = new_pane(&c, fire).await;
    let mut quiet = sh();
    quiet["command"] = json!(["/bin/sh", "-c", "printf b-ready; exec cat"]);
    let b = new_pane(&c, quiet).await;
    wait_for_text(&c, b, T, |l| l.first().is_some_and(|l| l == "b-ready")).await.unwrap();

    let mut s = tokio::net::UnixStream::connect(env.path().join("clothod.sock")).await.unwrap();
    write_frame(&mut s, &Frame::Json(json!({"id": 1, "method": "hello", "params": {"protocol": 1}}))).await.unwrap();
    let Some(Frame::Json(v)) = read_frame(&mut s).await.unwrap() else { panic!() };
    assert!(v["result"].is_object(), "{v}");
    write_frame(&mut s, &Frame::Json(json!({"id": 2, "method": "pane.subscribe", "params": {"pane": a}}))).await.unwrap();
    // Don't read: the firehose fills this connection's queue. Wait until the daemon says so
    // (a fixed wait was too short under a loaded parallel run).
    let full_by = Instant::now() + Duration::from_secs(60);
    loop {
        let stats = c.request("debug.stats", json!({})).await.unwrap();
        let lagging = stats["panes"].as_array().unwrap().iter().any(|p| p["id"] == a && p["lagging"].as_u64() > Some(0));
        if lagging {
            break;
        }
        assert!(Instant::now() < full_by, "the queue never filled: {stats}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    write_frame(&mut s, &Frame::Json(json!({"id": 3, "method": "pane.subscribe", "params": {"pane": b, "have_seq": 0}}))).await.unwrap();

    let (mut replied, mut resync) = (false, false);
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        assert!(Instant::now() < deadline, "no deferred snapshot (replied {replied}, resync {resync})");
        match tokio::time::timeout(Duration::from_secs(10), read_frame(&mut s)).await.unwrap().unwrap().unwrap() {
            Frame::Json(v) if v["id"] == 3 => {
                assert_eq!(v["result"]["mode"], "snapshot", "a full queue gets no replay: {v}");
                replied = true;
            }
            Frame::Json(v) if v["event"] == "pane.resync" && v["data"]["pane"] == b => {
                assert!(replied, "resync after the reply");
                resync = true;
            }
            Frame::Snapshot { pane, data, .. } if pane == b => {
                assert!(resync, "the snapshot comes after the queue drained, with pane.resync");
                assert!(String::from_utf8_lossy(&data).contains("b-ready"));
                break;
            }
            Frame::Output { pane, .. } => assert_ne!(pane, b, "no output for b before its snapshot"),
            _ => {}
        }
    }
}

/// History lines in a pane's snapshot (lines above the screen).
async fn history_lines(c: &mut Client, pane: u64) -> usize {
    let (_, mut s) = subscribe(c, pane, None).await;
    sync(c, &mut s).await.unwrap();
    s.vt.history_len()
}

#[tokio::test]
async fn scrollback_comes_from_the_config_and_can_be_set_per_pane() {
    let mut env = Env::empty();
    std::fs::write(env.dir.path().join("config.toml"), "# test\nscrollback_lines = 50\n").unwrap();
    env.start();
    let mut c = env.client().await;
    let print = |n: u32| {
        let mut p = sh();
        p["command"] = json!(["/bin/sh", "-c", format!("i=0; while [ $i -lt {n} ]; do echo row-$i; i=$((i+1)); done; echo printed; exec cat")]);
        p["rows"] = json!(10);
        p
    };
    let a = new_pane(&c, print(300)).await;
    let mut own = print(300);
    own["scrollback_lines"] = json!(120);
    let b = new_pane(&c, own).await;
    for p in [a, b] {
        wait_for_text(&c, p, T, |l| has_line(l, "printed")).await.unwrap();
    }
    let s = c.request("state.get", json!({})).await.unwrap();
    let lines = |p: u64| s["panes"].as_array().unwrap().iter().find(|x| x["id"] == p).unwrap()["scrollback_lines"].clone();
    assert_eq!((lines(a), lines(b)), (json!(50), json!(120)));
    assert_eq!(history_lines(&mut c, a).await, 50);
    assert_eq!(history_lines(&mut c, b).await, 120);

    // A pane's own setting survives a restart of the logic process.
    drop(c);
    env.kill();
    env.start();
    let mut c = env.client().await;
    let s = c.request("state.get", json!({})).await.unwrap();
    let lines = |p: u64| s["panes"].as_array().unwrap().iter().find(|x| x["id"] == p).unwrap()["scrollback_lines"].clone();
    assert_eq!((lines(a), lines(b)), (json!(50), json!(120)));
    assert_eq!(history_lines(&mut c, b).await, 120);

    let mut bad = sh();
    bad["scrollback_lines"] = json!(-1);
    let e = c.request("workspace.create", bad).await.unwrap_err();
    assert!(e.to_string().contains("bad_request"), "{e}");
}

async fn pane_scrollback(c: &Client, pane: u64) -> Value {
    let s = c.request("state.get", json!({})).await.unwrap();
    s["panes"].as_array().unwrap().iter().find(|x| x["id"] == pane).unwrap()["scrollback_lines"].clone()
}

/// A shell-free pane that prints `n` numbered rows, then waits.
fn rows_pane(n: u32) -> Value {
    let mut p = sh();
    p["command"] = json!(["/bin/sh", "-c", format!("i=0; while [ $i -lt {n} ]; do echo row-$i; i=$((i+1)); done; echo printed; exec cat")]);
    p["rows"] = json!(10);
    p
}

#[tokio::test]
async fn scrollback_setting_changes_at_runtime_and_persists() {
    let mut env = Env::empty();
    let config = env.dir.path().join("config.toml");
    std::fs::write(&config, "# mine, keep me\nscrollback_lines = 50 # old\nother = \"x\"\n").unwrap();
    env.start();
    let mut c = env.client().await;
    assert!(c.hello["features"].as_array().unwrap().contains(&json!("settings")), "{}", c.hello);
    let g = c.request("settings.get", json!({})).await.unwrap();
    assert_eq!(g["scrollback_lines"], 50);
    assert_eq!(g["limits"]["scrollback_lines"]["default"], 2000);
    let max = g["limits"]["scrollback_lines"]["max"].as_u64().unwrap();
    assert_eq!(g["config"], json!(config.to_string_lossy()));

    let a = new_pane(&c, rows_pane(300)).await;
    let mut own = rows_pane(300);
    own["scrollback_lines"] = json!(120);
    let b = new_pane(&c, own).await;
    for p in [a, b] {
        wait_for_text(&c, p, T, |l| has_line(l, "printed")).await.unwrap();
    }
    assert_eq!(history_lines(&mut c, a).await, 50);

    let mut watcher = env.client().await;
    watcher.request("events.subscribe", json!({})).await.unwrap();
    while watcher.try_recv().is_some() {}

    // Down: the pane that follows the setting loses its oldest rows now; the one spawned with
    // its own value keeps it.
    let r = c.request("settings.set", json!({"scrollback_lines": 30})).await.unwrap();
    assert_eq!(r["scrollback_lines"], 30);
    assert_eq!(r["applied_panes"], json!([a]));
    assert_eq!((pane_scrollback(&c, a).await, pane_scrollback(&c, b).await), (json!(30), json!(120)));
    assert_eq!(history_lines(&mut c, a).await, 30);
    assert_eq!(history_lines(&mut c, b).await, 120);
    let text = std::fs::read_to_string(&config).unwrap();
    assert!(text.contains("# mine, keep me") && text.contains("other = \"x\"") && text.contains("scrollback_lines = 30"), "{text}");
    let deadline = Instant::now() + T;
    let ev = loop {
        match tokio::time::timeout(Duration::from_millis(200), watcher.recv()).await {
            Ok(Some(Frame::Json(v))) if v["event"] == "settings" => break v["data"].clone(),
            _ => assert!(Instant::now() < deadline, "no settings event"),
        }
    };
    assert_eq!(ev["scrollback_lines"], 30);

    // New panes get it.
    let n = new_pane(&c, rows_pane(100)).await;
    assert_eq!(pane_scrollback(&c, n).await, json!(30));
    // Up again: room for more, nothing comes back.
    let r = c.request("settings.set", json!({"scrollback_lines": 200})).await.unwrap();
    assert_eq!(r["applied_panes"].as_array().unwrap().len(), 2);
    assert_eq!(pane_scrollback(&c, a).await, json!(200));
    assert_eq!(history_lines(&mut c, a).await, 30);

    // Invalid values change nothing.
    for bad in [json!({"scrollback_lines": -1}), json!({"scrollback_lines": max + 1}), json!({"scrollback_lines": "9"}), json!({"bogus": 1})] {
        let e = c.request("settings.set", bad.clone()).await.unwrap_err();
        assert!(e.to_string().contains("bad_request"), "{bad}: {e}");
    }
    assert_eq!(c.request("settings.get", json!({})).await.unwrap()["scrollback_lines"], 200);
    assert!(std::fs::read_to_string(&config).unwrap().contains("scrollback_lines = 200"));

    // A restart of the logic process reads it back; who follows the setting is kept.
    drop(c);
    drop(watcher);
    env.kill();
    env.start();
    let c = env.client().await;
    assert_eq!(c.request("settings.get", json!({})).await.unwrap()["scrollback_lines"], 200);
    c.request("settings.set", json!({"scrollback_lines": 40})).await.unwrap();
    assert_eq!((pane_scrollback(&c, a).await, pane_scrollback(&c, b).await), (json!(40), json!(120)));

    // A config file it can't parse is never overwritten.
    std::fs::write(&config, "scrollback_lines = [oops\n").unwrap();
    let e = c.request("settings.set", json!({"scrollback_lines": 60})).await.unwrap_err();
    assert!(e.to_string().contains("config_failed"), "{e}");
    assert_eq!(std::fs::read_to_string(&config).unwrap(), "scrollback_lines = [oops\n");
    assert_eq!(c.request("settings.get", json!({})).await.unwrap()["scrollback_lines"], 40);
}

/// Memory of one full pane at a given scrollback (not a test: `cargo test -p clothod --test
/// e2e scrollback_memory -- --ignored --nocapture`, CLOTHOD_PROBE_LINES=50000).
#[tokio::test]
#[ignore]
async fn scrollback_memory_probe() {
    let lines: u64 = std::env::var("CLOTHOD_PROBE_LINES").ok().and_then(|v| v.parse().ok()).unwrap_or(50_000);
    let env = Env::new();
    let c = env.client().await;
    c.request("settings.set", json!({"scrollback_lines": lines})).await.unwrap();
    let rss = |pid: u32| -> u64 {
        let o = Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().unwrap();
        String::from_utf8_lossy(&o.stdout).trim().parse::<u64>().unwrap_or(0) / 1024
    };
    let serve = c.hello["pid"].as_u64().unwrap() as u32;
    let holder = holder_pid(&env);
    let base = c.request("debug.stats", json!({})).await.unwrap()["heap"].as_u64().unwrap();
    eprintln!("before: serve heap {} MB, rss {} MB, holder rss {} MB", base >> 20, rss(serve), rss(holder));
    let mut p = sh();
    // 120 columns of text per row, as many rows as the scrollback plus a screen.
    p["command"] = json!(["/bin/sh", "-c", format!("i=0; while [ $i -lt {} ]; do printf '%0120d\\n' $i; i=$((i+1)); done; echo printed; exec cat", lines + 60)]);
    p["cols"] = json!(120);
    p["rows"] = json!(40);
    let pane = new_pane(&c, p).await;
    wait_for_text(&c, pane, Duration::from_secs(600), |l| has_line(l, "printed")).await.unwrap();
    // Let the snapshot push to the holder happen.
    tokio::time::sleep(Duration::from_secs(8)).await;
    let st = c.request("debug.stats", json!({})).await.unwrap();
    let heap = st["heap"].as_u64().unwrap();
    eprintln!(
        "{lines} lines x 120 cols, full: serve heap {} MB (+{} MB), peak {} MB, rss {} MB; holder rss {} MB; history {}",
        heap >> 20,
        (heap - base) >> 20,
        st["heap_peak"].as_u64().unwrap() >> 20,
        rss(serve),
        rss(holder),
        st["panes"][0]["history"]
    );
}

// ---- start at login ------------------------------------------------------------------------

/// A login unit for one test instance: its own label and unit dir, and the test's install dir,
/// so the user's own unit (and daemon) are never touched. Removed on drop, pass or fail.
struct TestUnit {
    label: String,
    vars: Vec<(String, String)>,
    runtime: PathBuf,
}

impl TestUnit {
    fn new(env: &Env) -> TestUnit {
        static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let label = if cfg!(target_os = "macos") {
            format!("nyc.amin.clotho.clt-test-{}-{n}", std::process::id())
        } else {
            format!("clt-test-{}-{n}", std::process::id())
        };
        let home = env.dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let mut vars = vec![
            ("CLOTHOD_SERVICE_LABEL".to_string(), label.clone()),
            ("HOME".into(), home.to_string_lossy().into_owned()),
            ("CLOTHOD_INSTALL_DIR".into(), env.dir.path().join("bin").to_string_lossy().into_owned()),
        ];
        if cfg!(target_os = "macos") {
            // Where it would go for this HOME; explicit, so a daemon the unit starts (with the
            // real HOME from launchd) finds the same file.
            vars.push(("CLOTHOD_SERVICE_DIR".into(), home.join("Library/LaunchAgents").to_string_lossy().into_owned()));
        } else {
            // The user manager only reads units from its own search path; the runtime unit dir
            // is in it and goes away with the manager. Lingering is the user's call (install
            // refuses without it); the test checks the mechanics.
            let dir = PathBuf::from(format!("/run/user/{}/systemd/user", unsafe { libc::getuid() }));
            std::fs::create_dir_all(&dir).unwrap();
            vars.push(("CLOTHOD_SERVICE_DIR".into(), dir.to_string_lossy().into_owned()));
            vars.push(("CLOTHOD_TEST_ASSUME_LINGER".into(), "1".into()));
        }
        TestUnit { label, vars, runtime: env.path() }
    }

    fn vars(&self) -> Vec<(&str, &str)> {
        self.vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect()
    }

    /// `bin args --runtime-dir <test instance>`, with everything that makes it this instance.
    fn cmd(&self, env: &Env, bin: &str, args: &[&str]) -> std::process::Output {
        let mut cmd = Command::new(bin);
        cmd.args(args).arg("--runtime-dir").arg(env.path()).env("CLOTHOD_STATE_DIR", env.state());
        cmd.env("CLOTHOD_REGISTRY_DIR", env.dir.path().join("registry")).env("CLOTHOD_CONFIG", env.dir.path().join("config.toml"));
        cmd.env("CLOTHOD_RUNTIME_DIR", env.path());
        for (k, v) in &self.vars {
            cmd.env(k, v);
        }
        cmd.output().unwrap()
    }

    /// How often the service manager has run the unit, and whether the last run succeeded.
    fn runs(&self) -> (String, bool) {
        if cfg!(target_os = "macos") {
            let out = manager(&["print", &format!("gui/{}/{}", unsafe { libc::getuid() }, self.label)]);
            let field = |k: &str| out.lines().find_map(|l| l.trim().strip_prefix(k).map(|v| v.trim().to_string())).unwrap_or_default();
            (field("runs = "), field("last exit code = ") == "0")
        } else {
            let out = manager(&["show", &format!("{}.service", self.label), "-p", "ActiveEnterTimestampMonotonic", "-p", "Result"]);
            let field = |k: &str| out.lines().find_map(|l| l.strip_prefix(k).map(String::from)).unwrap_or_default();
            (field("ActiveEnterTimestampMonotonic="), field("Result=") == "success")
        }
    }

    /// What logging in does: the service manager runs the unit.
    fn trigger(&self) {
        let out = if cfg!(target_os = "macos") {
            manager(&["kickstart", &format!("gui/{}/{}", unsafe { libc::getuid() }, self.label)])
        } else {
            manager(&["restart", &format!("{}.service", self.label)])
        };
        eprintln!("trigger: {out}");
    }
}

impl Drop for TestUnit {
    fn drop(&mut self) {
        let mut cmd = Command::new(test_bin());
        cmd.args(["service", "uninstall", "--runtime-dir"]).arg(&self.runtime);
        for (k, v) in &self.vars {
            cmd.env(k, v);
        }
        let _ = cmd.output();
    }
}

/// launchctl (macOS) or `systemctl --user` (Linux); stdout and stderr together.
fn manager(args: &[&str]) -> String {
    let mut cmd = if cfg!(target_os = "macos") {
        Command::new("launchctl")
    } else {
        let mut c = Command::new("systemctl");
        c.arg("--user");
        if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
            c.env("XDG_RUNTIME_DIR", format!("/run/user/{}", unsafe { libc::getuid() }));
        }
        c
    };
    let o = cmd.args(args).output().unwrap();
    format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))
}

/// pids of `clothod serve` processes for this runtime dir.
fn serve_pids(env: &Env) -> Vec<u32> {
    let dir = env.path().to_string_lossy().into_owned();
    clotho_proto::platform::own_processes()
        .into_iter()
        .filter(|p| p.args.get(1).is_some_and(|a| a == "serve") && p.args.windows(2).any(|w| w[0] == "--runtime-dir" && w[1] == dir))
        .map(|p| p.pid)
        .collect()
}

async fn wait_serve(env: &Env, what: &str, cond: impl Fn(&Value) -> bool) -> Client {
    let deadline = Instant::now() + T;
    loop {
        if let Ok(c) = Client::connect(&env.path()).await {
            if cond(&c.hello) {
                return c;
            }
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn login_unit_adopts_the_daemon_never_fights_upgrades_and_uninstall_keeps_it() {
    let mut env = Env::empty();
    let unit = TestUnit::new(&env);
    // The unit runs <install dir>/current/clothod, as on a real machine.
    let out = unit.cmd(&env, &test_bin(), &["install"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    // A healthy daemon (in the login session): the unit adopts it. (Started from an SSH session
    // on macOS it would be moved instead; see a_start_in_the_login_session_moves_a_stuck_serve.)
    let mut vars = unit.vars();
    vars.push(("CLOTHOD_TEST_NAMESPACE", "Aqua"));
    env.start_with(&test_bin(), &vars);
    let c = env.client().await;
    assert!(c.hello["features"].as_array().unwrap().contains(&json!("service")), "{}", c.hello);
    let (p, shell) = live_shell(&c).await;
    let serve = c.hello["pid"].clone();
    let holder = holder_pid(&env);

    let s = c.request("service.status", json!({})).await.unwrap();
    assert_eq!((s["installed"].clone(), s["loaded"].clone(), s["label"].clone()), (json!(false), json!(false), json!(unit.label)), "{s}");

    // Install: the unit runs `clothod start` now, which finds this daemon and leaves it alone.
    let s = c.request("service.install", json!({})).await.unwrap();
    assert_eq!((s["installed"].clone(), s["loaded"].clone(), s["up_to_date"].clone()), (json!(true), json!(true), json!(true)), "{s}");
    let file = std::fs::read_to_string(s["file"].as_str().unwrap()).unwrap();
    let current = env.dir.path().join("bin/current/clothod").to_string_lossy().into_owned();
    assert!(file.contains(&current) && file.contains(&env.path().to_string_lossy().into_owned()), "{file}");
    let deadline = Instant::now() + T;
    let first = loop {
        let r = unit.runs();
        if r.1 && !r.0.is_empty() && r.0 != "0" {
            break r.0;
        }
        assert!(Instant::now() < deadline, "the unit didn't run (or failed): {r:?}\n{}", std::fs::read_to_string(env.state().join("service.log")).unwrap_or_default());
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    assert_eq!(env.client().await.hello["pid"], serve, "adopted, not replaced");
    assert_eq!(serve_pids(&env).len(), 1, "one instance");
    drop(c);
    env.daemon.take(); // replaced from here on

    // Upgrade with the unit installed: serve and holder move, and the unit never runs again.
    let (v2, id2) = other_build(&env, "v2");
    let out = unit.cmd(&env, &v2, &["upgrade"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let c = env.client().await;
    assert_eq!((c.hello["build"].clone(), c.hello["holder"]["build"].clone()), (json!(id2), json!(id2)));
    assert_eq!(holder_pid(&env), holder, "same holder");
    assert_shell_alive(&c, p, &shell).await;
    assert_eq!(unit.runs().0, first, "the unit stayed out of the upgrade");
    assert_eq!(serve_pids(&env).len(), 1);
    let s = c.request("service.status", json!({})).await.unwrap();
    assert_eq!(s["up_to_date"], true, "`current` moved; the unit needs no rewrite: {s}");

    // A login while it runs: still one instance, the same one.
    let upgraded = c.hello["pid"].clone();
    unit.trigger();
    let deadline = Instant::now() + T;
    while unit.runs().0 == first {
        assert!(Instant::now() < deadline, "the unit didn't run again");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(unit.runs().1, "{:?}", unit.runs());
    assert_eq!(env.client().await.hello["pid"], upgraded);
    assert_eq!(serve_pids(&env).len(), 1);

    // A login with the daemon stopped starts the installed (current) build; shells kept.
    drop(c);
    let out = unit.cmd(&env, &test_bin(), &["stop"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    // `stop` returns once the socket is gone; the process exits a moment later.
    let deadline = Instant::now() + T;
    while !serve_pids(&env).is_empty() {
        assert!(Instant::now() < deadline, "serve still running after stop: {:?}", serve_pids(&env));
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    unit.trigger();
    let c = wait_serve(&env, "the unit to start the daemon", |h| h["build"] == json!(id2)).await;
    assert_eq!(holder_pid(&env), holder);
    assert_shell_alive(&c, p, &shell).await;
    assert_eq!(serve_pids(&env).len(), 1);

    // Uninstall: the unit goes, the daemon stays.
    let started = c.hello["pid"].clone();
    let s = c.request("service.uninstall", json!({})).await.unwrap();
    assert_eq!((s["installed"].clone(), s["loaded"].clone()), (json!(false), json!(false)), "{s}");
    assert!(!std::path::Path::new(s["file"].as_str().unwrap()).exists());
    tokio::time::sleep(Duration::from_millis(500)).await;
    c.request("ping", json!({})).await.unwrap();
    assert_eq!(env.client().await.hello["pid"], started);
    assert_shell_alive(&c, p, &shell).await;
    // Idempotent, and the CLI says the same.
    c.request("service.uninstall", json!({})).await.unwrap();
    let out = unit.cmd(&env, &test_bin(), &["service", "status"]);
    let v: Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|_| panic!("{}", String::from_utf8_lossy(&out.stderr)));
    assert_eq!(v["installed"], false);

    // Never somebody else's file.
    let file = PathBuf::from(s["file"].as_str().unwrap());
    std::fs::write(&file, "not ours\n").unwrap();
    let e = c.request("service.install", json!({})).await.unwrap_err();
    assert!(e.to_string().contains("conflict"), "{e}");
    let e = c.request("service.uninstall", json!({})).await.unwrap_err();
    assert!(e.to_string().contains("conflict"), "{e}");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "not ours\n");
    std::fs::remove_file(&file).unwrap();
    let _ = unit.cmd(&env, &test_bin(), &["shutdown"]);
}

#[test]
fn a_test_instance_cannot_touch_the_users_login_unit() {
    let env = Env::empty();
    for op in ["status", "install", "uninstall"] {
        let out = Command::new(test_bin()).args(["service", op, "--runtime-dir"]).arg(env.path()).env_remove("CLOTHOD_SERVICE_LABEL").output().unwrap();
        assert!(!out.status.success(), "{op}");
        assert!(String::from_utf8_lossy(&out.stderr).contains("needs its own CLOTHOD_SERVICE_LABEL"), "{}", String::from_utf8_lossy(&out.stderr));
    }
}

// ---- push --------------------------------------------------------------------------------

/// A stand-in relay on 127.0.0.1: answers `POST /v1/push` with the next queued status (200 when
/// none is queued) and hands each request's JSON body to the test.
struct FakeRelay {
    url: String,
    statuses: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<u16>>>,
    bodies: std::sync::mpsc::Receiver<(Instant, Value)>,
}

impl FakeRelay {
    fn start() -> FakeRelay {
        use std::io::{BufRead, BufReader, Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://127.0.0.1:{}", l.local_addr().unwrap().port());
        let statuses = std::sync::Arc::new(std::sync::Mutex::new(std::collections::VecDeque::new()));
        let (tx, bodies) = std::sync::mpsc::channel();
        let st = statuses.clone();
        std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(mut s) = s else { return };
                let mut r = BufReader::new(s.try_clone().unwrap());
                let (mut line, mut len) = (String::new(), 0usize);
                r.read_line(&mut line).unwrap();
                let activity = line.starts_with("POST /v1/activity ");
                assert!(line.starts_with("POST /v1/push ") || activity, "{line}");
                loop {
                    line.clear();
                    r.read_line(&mut line).unwrap();
                    if line.trim().is_empty() {
                        break;
                    }
                    if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        len = v.trim().parse().unwrap();
                    }
                }
                let mut body = vec![0; len];
                r.read_exact(&mut body).unwrap();
                let status = st.lock().unwrap().pop_front().unwrap_or(200);
                let mut body: Value = serde_json::from_slice(&body).unwrap();
                if activity {
                    body["_path"] = json!("/v1/activity");
                }
                let _ = tx.send((Instant::now(), body));
                let _ = write!(s, "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}");
            }
        });
        FakeRelay { url, statuses, bodies }
    }

    fn queue(&self, statuses: &[u16]) {
        self.statuses.lock().unwrap().extend(statuses);
    }

    fn next(&self) -> (Instant, Value) {
        self.bodies.recv_timeout(T).expect("a push reached the relay")
    }

    /// The next Live Activity post, skipping alerts.
    fn next_activity(&self) -> (Instant, Value) {
        let deadline = Instant::now() + T;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let b = self.bodies.recv_timeout(left).expect("an activity update reached the relay");
            if b.1["_path"] == "/v1/activity" {
                return b;
            }
        }
    }

    fn no_activity_for(&self, d: Duration) {
        let deadline = Instant::now() + d;
        while let Ok(b) = self.bodies.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            assert!(b.1["_path"] != "/v1/activity", "unexpected activity post {b:?}");
        }
    }

    fn none_for(&self, d: Duration) {
        if let Ok(b) = self.bodies.recv_timeout(d) {
            panic!("unexpected push {b:?}");
        }
    }
}

// The iOS side's test key pair (docs/push.md).
const PUSH_SK: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";
const PUSH_PK: &str = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=";

fn push_env() -> Env {
    let mut env = Env::empty();
    env.start_with(&std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into()), &[("CLOTHOD_TEST_PUSH_FAST", "1")]);
    env
}

async fn register(c: &Client, device: &str, relay: &str) {
    let r = json!({"device": device, "handle": format!("handle-{device}"), "key": PUSH_PK, "label": format!("00000000-0000-0000-0000-00000000C10D {device}"), "relay": relay, "env": "sandbox"});
    c.request("push.register", r).await.unwrap();
}

async fn push_devices(c: &Client) -> Vec<Value> {
    c.request("push.list", json!({})).await.unwrap()["devices"].as_array().unwrap().clone()
}

fn opened(body: &Value) -> Value {
    let plain = clothod::push::open(PUSH_SK, body["ciphertext"].as_str().unwrap(), body["collapse_id"].as_str().unwrap().as_bytes()).expect("sealed to the phone's key");
    serde_json::from_slice(&plain).unwrap()
}

/// An activity push token: 64 hex characters.
fn tok(seed: &str) -> String {
    seed.repeat(64).chars().take(64).collect()
}

async fn activities(c: &Client) -> Vec<Value> {
    c.request("push.list", json!({})).await.unwrap()["activities"].as_array().unwrap().clone()
}

/// A Live Activity body: the relay's contract (ios/relay, /v1/activity): kind, state and times,
/// and only the optional detail keys besides.
fn activity_body(b: &Value, event: &str, state: &str) -> Value {
    assert_eq!(b["_path"], "/v1/activity", "{b}");
    assert_eq!((b["event"].as_str(), b["content"]["state"].as_str(), b["env"].as_str()), (Some(event), Some(state), Some("sandbox")), "{b}");
    let mut keys: Vec<&str> = b.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort();
    let want: &[&str] = if event == "end" { &["_path", "content", "dismiss", "env", "event", "handle", "timestamp", "token"] } else { &["_path", "content", "env", "event", "handle", "stale", "timestamp", "token"] };
    assert_eq!(keys, want, "{b}");
    let content = b["content"].as_object().unwrap();
    for k in ["kind", "since", "started", "state"] {
        assert!(content.contains_key(k), "{k}: {b}");
    }
    for (k, v) in content {
        assert!(["kind", "since", "started", "state", "tool", "detail", "msg"].contains(&k.as_str()), "{k}: {b}");
        if ["tool", "detail", "msg"].contains(&k.as_str()) {
            assert!(v.as_str().is_some_and(|t| !t.is_empty() && !t.chars().any(char::is_control)), "{k}: {b}");
        }
    }
    for k in ["since", "started"] {
        assert!(content[k].is_u64(), "{k} is unix seconds: {b}");
    }
    let ts = b["timestamp"].as_u64().unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    assert!(ts + 5 >= now && ts <= now + 5, "{b}");
    let until = if event == "end" { b["dismiss"].as_u64().unwrap() } else { b["stale"].as_u64().unwrap() };
    assert_eq!(until - ts, if event == "end" { 300 } else { 900 }, "{b}");
    b["content"].clone()
}

/// The phone follows an agent: an update at once, then at most one per gap (the latest state
/// wins), `end` at once when the turn is over, and the token is gone after it.
#[tokio::test]
async fn live_activities_follow_the_agent() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    let hello = c.request("hello", json!({"protocol": 1})).await.unwrap();
    assert!(hello["features"].as_array().unwrap().contains(&json!("push.activity")));
    register(&c, "d1", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    for (params, code) in [
        (json!({"pane": p, "device": "d1", "token": "not hex"}), "bad_request"),
        (json!({"pane": p, "device": "d1", "token": "ab".repeat(101)}), "bad_request"),
        (json!({"pane": p, "device": "d1", "token": "ab".repeat(31)}), "bad_request"),
        (json!({"pane": p, "device": "d1", "token": tok("ab"), "env": "staging"}), "bad_request"),
        (json!({"pane": p, "device": "nobody", "token": tok("ab")}), "not_found"),
    ] {
        let e = c.request("push.activity", params.clone()).await.unwrap_err();
        assert!(e.to_string().contains(code), "{params}: {e}");
    }
    let report = |state: &str, prompt: Option<&str>| {
        let mut r = json!({"pane": p, "state": state, "kind": "claude", "message": "secret text", "tool": "Bash", "tool_input": "rm -rf secret"});
        if let Some(q) = prompt {
            r["prompt"] = json!(q);
        }
        c.request("agent.report", r)
    };
    report("running", Some("a secret prompt")).await.unwrap();
    let started = pane_agent(&c, p).await["turn_started"].as_f64().unwrap() as u64;

    c.request("push.activity", json!({"pane": p, "device": "d1", "token": tok("ABCDEF")})).await.unwrap();
    let (t0, b) = relay.next_activity();
    let content = activity_body(&b, "update", "running");
    assert_eq!((b["handle"].as_str(), b["token"].as_str()), (Some("handle-d1"), Some(tok("ABCDEF").as_str())));
    assert_eq!((content["kind"].as_str(), content["started"].as_u64()), (Some("claude"), Some(started)));
    // The detail a notification carries: the tool and its input while running, not the
    // message (that's for waiting and the end), never the prompt.
    assert_eq!((content["tool"].as_str(), content["detail"].as_str()), (Some("Bash"), Some("rm -rf secret")));
    assert!(content.get("msg").is_none() && !b.to_string().contains("a secret prompt"), "{b}");
    assert_eq!(activities(&c).await.len(), 1);

    // Within the gap: held, then sent with the latest state.
    report("waiting", None).await.unwrap();
    let (t1, b) = relay.next_activity();
    assert!(t1 - t0 >= Duration::from_millis(900), "coalesced: {:?}", t1 - t0);
    let content = activity_body(&b, "update", "waiting");
    assert_eq!((content["tool"].as_str(), content["msg"].as_str()), (Some("Bash"), Some("secret text")));
    assert_eq!(content["started"].as_u64(), Some(started), "the turn's clock goes on");
    assert!(content["since"].as_u64().unwrap() >= started);
    let ts1 = b["timestamp"].as_u64().unwrap();
    report("running", None).await.unwrap();
    report("waiting", None).await.unwrap();
    report("running", None).await.unwrap();
    let (t2, b) = relay.next_activity();
    assert!(t2 - t1 >= Duration::from_millis(900), "coalesced: {:?}", t2 - t1);
    activity_body(&b, "update", "running");
    assert!(b["timestamp"].as_u64().unwrap() > ts1, "timestamps only grow: {b}");
    relay.no_activity_for(Duration::from_millis(1500));

    // The turn ends: at once, not held by the gap.
    report("waiting", None).await.unwrap();
    let (tw, b) = relay.next_activity();
    activity_body(&b, "update", "waiting");
    report("done", None).await.unwrap();
    let (t3, b) = relay.next_activity();
    let content = activity_body(&b, "end", "done");
    assert_eq!(content["started"].as_u64(), Some(started));
    assert_eq!((content.get("tool"), content["msg"].as_str()), (None, Some("secret text")), "the end: its message, no tool");
    assert!(t3 - tw < Duration::from_millis(700), "an end isn't held by the gap: {:?}", t3 - tw);
    assert!(activities(&c).await.is_empty(), "an ended activity's token is gone");
    report("running", Some("next")).await.unwrap();
    relay.no_activity_for(Duration::from_millis(1500));
}

/// A running turn's tool changes send updates too, held to the gap like state changes, with
/// the latest always sent; a change of nothing shown sends nothing.
#[tokio::test]
async fn live_activities_follow_the_tool() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    register(&c, "d1", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    let tool = |tool: &str, input: &str| c.request("agent.report", json!({"pane": p, "state": "running", "kind": "claude", "tool": tool, "tool_input": input}));
    c.request("agent.report", json!({"pane": p, "state": "running", "kind": "claude", "prompt": "go"})).await.unwrap();
    c.request("push.activity", json!({"pane": p, "device": "d1", "token": tok("ab")})).await.unwrap();
    let (t0, b) = relay.next_activity();
    let content = activity_body(&b, "update", "running");
    assert!(content.get("tool").is_none() && content.get("detail").is_none(), "no tool yet: {content}");

    tool("Read", "src/main.rs").await.unwrap();
    tool("Edit", "src/main.rs").await.unwrap();
    tool("Bash", "cargo test && echo done").await.unwrap();
    let (t1, b) = relay.next_activity();
    assert!(t1 - t0 >= Duration::from_millis(900), "held to the gap: {:?}", t1 - t0);
    let content = activity_body(&b, "update", "running");
    assert_eq!((content["tool"].as_str(), content["detail"].as_str()), (Some("Bash"), Some("cargo test && echo done")), "the latest: {content}");
    relay.no_activity_for(Duration::from_millis(1500));

    // The same tool again: nothing new to show.
    tool("Bash", "cargo test && echo done").await.unwrap();
    relay.no_activity_for(Duration::from_millis(1500));
    tool("Write", "notes.md").await.unwrap();
    let content = activity_body(&relay.next_activity().1, "update", "running");
    assert_eq!((content["tool"].as_str(), content["detail"].as_str()), (Some("Write"), Some("notes.md")));
    c.request("agent.report", json!({"pane": p, "state": "clear"})).await.unwrap();
    activity_body(&relay.next_activity().1, "end", "running");
}

/// Tokens go on a 410, after Apple's 8 hours, with their device's registration and with their
/// pane (which ends them); they survive a daemon restart; a pane without an agent waits for one.
#[tokio::test]
async fn live_activity_tokens_come_and_go() {
    let relay = FakeRelay::start();
    let mut env = push_env();
    let c = env.client().await;
    register(&c, "d1", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    async fn report(c: &Client, p: u64, state: &str) {
        c.request("agent.report", json!({"pane": p, "state": state, "kind": "codex"})).await.unwrap();
    }

    // No agent yet: kept, and the first one is sent when it shows up.
    c.request("push.activity", json!({"pane": p, "device": "d1", "token": tok("aa")})).await.unwrap();
    relay.no_activity_for(Duration::from_millis(500));
    report(&c, p, "running").await;
    let b = relay.next_activity().1;
    assert_eq!(activity_body(&b, "update", "running")["kind"], "codex");

    // A restart keeps the token.
    drop(c);
    env.kill();
    env.start_with(&std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into()), &[("CLOTHOD_TEST_PUSH_FAST", "1")]);
    let c = env.client().await;
    assert_eq!(activities(&c).await.len(), 1, "survives a restart");

    // 410: the activity ended on the phone. (Running raises no alert, which would take the 410.)
    relay.queue(&[410]);
    report(&c, p, "running").await;
    activity_body(&relay.next_activity().1, "update", "running");
    let deadline = Instant::now() + T;
    while !activities(&c).await.is_empty() {
        assert!(Instant::now() < deadline, "a 410 drops the token");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // Unregistering the phone takes its activities.
    c.request("push.activity", json!({"pane": p, "device": "d1", "token": tok("bb")})).await.unwrap();
    activity_body(&relay.next_activity().1, "update", "running");
    c.request("push.unregister", json!({"device": "d1"})).await.unwrap();
    assert!(activities(&c).await.is_empty());
    register(&c, "d1", &relay.url).await;

    // A closed pane ends its activity with the last state it had.
    c.request("push.activity", json!({"pane": p, "device": "d1", "token": tok("cc")})).await.unwrap();
    activity_body(&relay.next_activity().1, "update", "running");
    c.request("pane.close", json!({"pane": p})).await.unwrap();
    let b = relay.next_activity().1;
    assert_eq!(b["token"], tok("cc"));
    activity_body(&b, "end", "running");
    assert!(activities(&c).await.is_empty());

    // push.activity_end only forgets: nothing is sent.
    let p2 = new_pane(&c, sh()).await;
    c.request("agent.report", json!({"pane": p2, "state": "running", "kind": "claude"})).await.unwrap();
    c.request("push.activity", json!({"pane": p2, "device": "d1", "token": tok("dd")})).await.unwrap();
    activity_body(&relay.next_activity().1, "update", "running");
    c.request("push.activity_end", json!({"pane": p2, "device": "d1"})).await.unwrap();
    c.request("agent.report", json!({"pane": p2, "state": "done", "kind": "claude"})).await.unwrap();
    relay.no_activity_for(Duration::from_millis(800));
    assert!(activities(&c).await.is_empty());
}

#[tokio::test]
async fn live_activities_end_after_eight_hours() {
    let relay = FakeRelay::start();
    let mut env = Env::empty();
    env.start_with(&std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into()), &[("CLOTHOD_TEST_PUSH_FAST", "1"), ("CLOTHOD_TEST_ACTIVITY_TTL_MS", "1500")]);
    let c = env.client().await;
    register(&c, "d1", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    c.request("agent.report", json!({"pane": p, "state": "running", "kind": "claude"})).await.unwrap();
    c.request("push.activity", json!({"pane": p, "device": "d1", "token": tok("ee")})).await.unwrap();
    activity_body(&relay.next_activity().1, "update", "running");
    tokio::time::sleep(Duration::from_millis(1700)).await;
    assert!(activities(&c).await.is_empty(), "listed only while Apple keeps it");
    c.request("agent.report", json!({"pane": p, "state": "waiting", "kind": "claude"})).await.unwrap();
    relay.no_activity_for(Duration::from_millis(1500));
}

#[tokio::test]
async fn push_registrations_are_private_and_validated() {
    let env = push_env();
    let c = env.client().await;
    let hello = c.request("hello", json!({"protocol": 1})).await.unwrap();
    assert!(hello["features"].as_array().unwrap().contains(&json!("push")));
    let base = json!({"device": "d1", "handle": "h", "key": PUSH_PK, "label": "L", "relay": "https://relay.example"});
    for (k, v) in [("key", "bm90IGEga2V5"), ("relay", "http://relay.example"), ("env", "staging"), ("device", "")] {
        let mut p = base.clone();
        p[k] = json!(v);
        let e = c.request("push.register", p).await.unwrap_err();
        assert!(e.to_string().contains("bad_request"), "{k}: {e}");
    }
    c.request("push.register", base.clone()).await.unwrap();
    register(&c, "d2", "http://127.0.0.1:9").await;
    // Registering again replaces.
    let mut again = base.clone();
    again["label"] = json!("L2");
    c.request("push.register", again).await.unwrap();
    let devices = push_devices(&c).await;
    assert_eq!(devices.len(), 2, "{devices:?}");
    let d1 = devices.iter().find(|d| d["device"] == "d1").unwrap();
    assert_eq!(d1["label"], "L2");
    assert!(d1.get("handle").is_none() && d1.get("key").is_none(), "list never shows secrets: {d1}");

    // Ephemeral instances keep registrations in their runtime dir, private to the user.
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(env.path().join("push.json")).unwrap();
    assert_eq!(meta.permissions().mode() & 0o777, 0o600);

    c.request("push.unregister", json!({"device": "d1"})).await.unwrap();
    assert_eq!(push_devices(&c).await.len(), 1);
    let e = c.request("push.test", json!({"device": "nope"})).await.unwrap_err();
    assert!(e.to_string().contains("not_found"), "{e}");
}

#[tokio::test]
async fn attention_pushes_a_sealed_alert_at_most_once_per_interval() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    register(&c, "phone", &relay.url).await;
    let p = new_pane(&c, sh()).await;
    let report = |state: &str, msg: &str| c.request("agent.report", json!({"pane": p, "state": state, "kind": "claude", "message": msg}));

    report("running", "").await.unwrap();
    relay.none_for(Duration::from_millis(300));
    // The first push is sent during this report: the pane's interval counts from no earlier than
    // here (its arrival at the relay can be later, by however long that delivery took).
    let asked = Instant::now();
    report("waiting", "Allow cargo test --release?").await.unwrap();
    let (_, body) = relay.next();
    let label = "00000000-0000-0000-0000-00000000C10D phone";
    assert_eq!(body["handle"], "handle-phone");
    assert_eq!(body["collapse_id"], clothod::push::collapse_id(label, p));
    let alert = opened(&body);
    assert_eq!(alert["v"], 1);
    assert_eq!(alert["m"], label);
    assert_eq!(alert["p"], p);
    assert_eq!((alert["k"].as_str(), alert["s"].as_str()), (Some("claude"), Some("waiting")));
    assert_eq!(alert["msg"], "Allow cargo test --release?");
    assert!(alert["t"].as_f64().unwrap() > 1.7e9);

    // Still waiting: no second push. Acked, then asked again right away: it waits out the
    // pane's interval (1 s with CLOTHOD_TEST_PUSH_FAST) and carries the latest state.
    relay.none_for(Duration::from_millis(200));
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    report("running", "").await.unwrap();
    report("error", "it broke").await.unwrap();
    let (second, body) = relay.next();
    assert!(second - asked >= Duration::from_millis(1000), "{:?}", second - asked);
    assert_eq!(opened(&body)["s"], "error");

    // Cleared before the delayed push was due: nothing goes out.
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    report("running", "").await.unwrap();
    report("waiting", "again").await.unwrap();
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    relay.none_for(Duration::from_millis(1500));
}

#[tokio::test]
async fn relay_errors_retry_block_or_remove_the_registration() {
    let relay = FakeRelay::start();
    let env = push_env();
    let c = env.client().await;
    register(&c, "phone", &relay.url).await;

    // Unavailable, then fine: retried with backoff.
    relay.queue(&[503, 429]);
    c.request("push.test", json!({"device": "phone"})).await.unwrap_err();
    relay.next();
    let p = new_pane(&c, sh()).await;
    c.request("agent.report", json!({"pane": p, "state": "waiting", "kind": "codex"})).await.unwrap();
    let (a, _) = relay.next();
    let (b, body) = relay.next();
    assert!(b - a >= Duration::from_millis(90), "backoff between tries");
    assert_eq!(opened(&body)["k"], "codex");
    assert!(push_devices(&c).await[0]["last_error"].is_null(), "a success clears last_error");

    // 403: kept, marked, and skipped until the phone registers again.
    relay.queue(&[403]);
    let e = c.request("push.test", json!({"device": "phone"})).await.unwrap_err();
    assert!(e.to_string().contains("relay_error"), "{e}");
    relay.next();
    assert!(push_devices(&c).await[0]["last_error"].as_str().unwrap().contains("403"));
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    c.request("agent.report", json!({"pane": p, "state": "running"})).await.unwrap();
    tokio::time::sleep(Duration::from_millis(1100)).await;
    c.request("agent.report", json!({"pane": p, "state": "done"})).await.unwrap();
    relay.none_for(Duration::from_millis(500));
    register(&c, "phone", &relay.url).await;
    c.request("push.test", json!({"device": "phone"})).await.unwrap();
    assert_eq!(opened(&relay.next().1)["k"], "clotho");

    // 410: the phone's token is gone, so is the registration.
    relay.queue(&[410]);
    c.request("push.test", json!({"device": "phone"})).await.unwrap_err();
    relay.next();
    assert!(push_devices(&c).await.is_empty());
}

/// `pane.clipboard` events for `pane` that arrive within `wait`.
async fn clipboard_events(c: &mut Client, pane: u64, wait: Duration) -> Vec<Value> {
    let mut out = Vec::new();
    let deadline = Instant::now() + wait;
    while let Ok(Some(f)) = tokio::time::timeout(deadline.saturating_duration_since(Instant::now()), c.recv()).await {
        if let Frame::Json(v) = f {
            if v["event"] == "pane.clipboard" && v["data"]["pane"] == pane {
                out.push(v["data"].clone());
            }
        }
    }
    out
}

#[tokio::test]
async fn osc52_copies_reach_the_panes_clients_and_reads_are_not_answered() {
    let mut env = Env::new();
    let mut c = env.client().await;
    let hello = c.request("hello", json!({"protocol": 1, "client": "test"})).await.unwrap();
    assert!(hello["features"].as_array().unwrap().contains(&json!("pane.clipboard")));
    let rec = env.path().join("received");
    // Waits for one key, then: a BEL-terminated copy, an ST-terminated one to the selection, a
    // clipboard read, one copy of exactly the size limit and one a byte over it. Whatever the app
    // reads afterwards goes to `rec`.
    let big = |n: usize| format!("head -c {n} /dev/zero | tr '\\0' a | base64 | tr -d '\\n'");
    let script = format!(
        r#"stty raw -echo; head -c1 >/dev/null
printf '\033]52;c;aMOpbGxvCg==\007\033]52;p;d29ybGQ=\033\\\033]52;c;?\007'
printf '\033]52;c;%s\007' "$({})"
printf '\033]52;c;%s\007' "$({})"
printf done; exec cat > {}"#,
        big(1 << 20),
        big((1 << 20) + 1),
        rec.display()
    );
    let mut params = sh();
    params["command"] = json!(["/bin/sh", "-c", script]);
    let p = new_pane(&c, params).await;

    // A second connection that only watches events, not the pane, gets nothing.
    let mut watcher = env.client().await;
    watcher.request("events.subscribe", json!({})).await.unwrap();
    let (_, mut screen) = subscribe(&mut c, p, None).await;
    c.input(p, b"x");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l.contains("done"))).await.unwrap();

    let got = clipboard_events(&mut c, p, Duration::from_secs(2)).await;
    assert_eq!(got.len(), 3, "BEL copy, ST copy, the one at the limit: {:?}", got.iter().map(|e| e["text"].as_str().map(str::len)).collect::<Vec<_>>());
    assert_eq!(got[0], json!({"pane": p, "target": "clipboard", "text": "héllo\n"}));
    assert_eq!(got[1], json!({"pane": p, "target": "selection", "text": "world"}));
    assert_eq!(got[2]["text"].as_str().unwrap().len(), 1 << 20);
    assert!(env.log().contains("dropped a 1048577 byte OSC 52 copy"), "{}", env.log());
    assert!(clipboard_events(&mut watcher, p, Duration::from_millis(200)).await.is_empty());

    // The read got no answer: the app received nothing.
    c.input(p, b"z");
    let deadline = Instant::now() + T;
    while std::fs::read(&rec).unwrap_or_default().is_empty() {
        assert!(Instant::now() < deadline, "input never arrived");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(std::fs::read(&rec).unwrap(), b"z", "the clipboard read was answered");

    // Replaying the output (resubscribing from 0) and restarting the daemon copy nothing again.
    let _ = subscribe(&mut c, p, Some(0)).await;
    sync(&mut c, &mut screen).await.ok();
    assert!(clipboard_events(&mut c, p, Duration::from_millis(500)).await.is_empty(), "replay re-sent copies");
    drop(c);
    drop(watcher);
    env.kill();
    env.start();
    let mut c = env.client().await;
    let _ = subscribe(&mut c, p, Some(0)).await;
    assert!(clipboard_events(&mut c, p, Duration::from_secs(1)).await.is_empty(), "restart re-sent copies");
}

/// Wait for the fs.ack of `stream` reaching `offset`, returning the other frames seen.
async fn wait_ack(c: &mut Client, stream: u64, offset: u64) {
    let deadline = Instant::now() + T;
    loop {
        if let Some(Frame::Json(v)) = c.try_recv() {
            if v["event"] == "fs.ack" && v["data"]["stream"] == stream && v["data"]["offset"].as_u64() >= Some(offset) {
                return;
            }
        }
        assert!(Instant::now() < deadline, "no ack for {offset}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// The fs.error / fs.done event for `stream`, if one comes within `wait`.
async fn stream_end(c: &mut Client, stream: u64, wait: Duration) -> Option<Value> {
    let deadline = Instant::now() + wait;
    while Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(50), c.recv()).await {
            Ok(Some(Frame::Json(v))) if (v["event"] == "fs.error" || v["event"] == "fs.done") && v["data"]["stream"] == stream => return Some(v),
            Ok(None) => return None,
            _ => {}
        }
    }
    None
}

fn part_files(dir: &std::path::Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.to_string_lossy().contains(".clotho-part-")).collect()
}

/// The slow-link failure (docs/security.md, Transfers): a connection goes half-open mid-upload,
/// the client resumes on a new one while the old stream is still open, and the instance that
/// held the upload goes away entirely (a private instance's state dir with it). The upload
/// still resumes from what reached the disk, and the part file is private until it's done.
#[tokio::test]
async fn fs_resume_takes_over_a_half_open_stream_and_outlives_the_instance() {
    use std::os::unix::fs::PermissionsExt;
    let files = tempfile::Builder::new().prefix("clt-files").tempdir_in("/tmp").unwrap();
    let root = files.path().canonicalize().unwrap();
    let big = pattern(3 << 20);
    let params = json!({"path": root.join("big.bin"), "size": big.len(), "upload_id": "u-1", "source": "size+mtime", "chunk": 65536});

    let env = Env::new();
    let mut old = env.client().await;
    let r = old.request("fs.write", params.clone()).await.unwrap();
    let s_old = r["stream"].as_u64().unwrap();
    write_stream(&mut old, s_old, 0, &big[..1 << 20], 65536, false).await;
    wait_ack(&mut old, s_old, 1 << 20).await;
    let parts = part_files(&root);
    assert_eq!(parts.len(), 1, "{parts:?}");
    assert_eq!(std::fs::metadata(&parts[0]).unwrap().permissions().mode() & 0o777, 0o600, "a part file is private while it is written");

    // `old` goes silent (half-open: serve can't tell). A new connection resumes anyway.
    let mut c = env.client().await;
    let r = c.request("fs.write", params.clone()).await.unwrap();
    assert_eq!(r["offset"], 1 << 20, "resumes while the old stream is still open");
    let s = r["stream"].as_u64().unwrap();
    let ended = stream_end(&mut old, s_old, T).await.expect("the old stream ends");
    assert_eq!((ended["event"].clone(), ended["data"]["code"].clone()), (json!("fs.error"), json!("superseded")), "{ended}");
    write_stream(&mut c, s, 1 << 20, &big[..2 << 20], 65536, false).await;
    wait_ack(&mut c, s, 2 << 20).await;
    // Data the superseded stream still sends goes nowhere.
    old.send(Frame::FileData { stream: s_old, offset: 1 << 20, flags: 0, data: vec![0xEE; 65536] });

    // The whole instance goes, with its runtime and state dirs.
    drop((old, c));
    drop(env);
    let env = Env::new();
    let mut c = env.client().await;
    let r = c.request("fs.write", params.clone()).await.unwrap();
    assert_eq!(r["offset"], 2 << 20, "a new instance resumes the part file");
    let done = write_stream(&mut c, r["stream"].as_u64().unwrap(), 2 << 20, &big, 65536, true).await;
    assert_eq!(done["event"], "fs.done", "{done}");
    assert_eq!(std::fs::read(root.join("big.bin")).unwrap(), big);
    assert!(part_files(&root).is_empty());
    // No mode asked for: the umask decides, as for any new file.
    std::fs::write(root.join("plain"), "x").unwrap();
    let want = std::fs::metadata(root.join("plain")).unwrap().permissions().mode() & 0o777;
    assert_eq!(std::fs::metadata(root.join("big.bin")).unwrap().permissions().mode() & 0o777, want);

    // Another source under the same upload id doesn't resume: different part.
    let mut p2 = params.clone();
    p2["path"] = json!(root.join("big2.bin"));
    let r = c.request("fs.write", p2.clone()).await.unwrap();
    write_stream(&mut c, r["stream"].as_u64().unwrap(), 0, &big[..65536], 65536, false).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    c.request("fs.cancel", json!({"stream": r["stream"]})).await.unwrap();
    p2["source"] = json!("changed");
    let r = c.request("fs.write", p2).await.unwrap();
    assert_eq!(r["offset"], 0);
    c.request("fs.cancel", json!({"stream": r["stream"]})).await.unwrap();
}

/// In a shared directory, someone may plant a link where a part file will go. The write must
/// replace the link, never write through it.
#[tokio::test]
async fn fs_part_files_never_follow_links() {
    use sha2::Digest;
    let env = Env::new();
    let mut c = env.client().await;
    let root = fs_root(&env);
    let victim = root.join("victim");
    std::fs::write(&victim, "precious").unwrap();
    let tag: String = sha2::Sha256::digest(b"src")[..6].iter().map(|b| format!("{b:02x}")).collect();
    let part = root.join(format!(".up.bin.clotho-part-u9-{tag}"));
    std::os::unix::fs::symlink(&victim, &part).unwrap();
    let r = c.request("fs.write", json!({"path": root.join("up.bin"), "upload_id": "u9", "source": "src"})).await.unwrap();
    assert_eq!(r["offset"], 0, "a link is not a part file to resume");
    let done = write_stream(&mut c, r["stream"].as_u64().unwrap(), 0, b"data", 4, true).await;
    assert_eq!(done["event"], "fs.done", "{done}");
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "precious");
    assert_eq!(std::fs::read_to_string(root.join("up.bin")).unwrap(), "data");
    assert!(std::fs::symlink_metadata(&part).is_err());
}

/// A client sending far past its write window loses the stream instead of queueing in serve.
#[tokio::test]
async fn fs_write_past_the_window_fails_the_stream() {
    let env = Env::new();
    let mut c = env.client().await;
    let root = fs_root(&env);
    let r = c.request("fs.write", json!({"path": root.join("w.bin"), "window": 4 << 20, "chunk": 65536, "upload_id": "w1"})).await.unwrap();
    let s = r["stream"].as_u64().unwrap();
    c.send(Frame::FileData { stream: s, offset: 0, flags: 0, data: vec![1; 65536] });
    c.send(Frame::FileData { stream: s, offset: 9 << 20, flags: 0, data: vec![1; 65536] });
    let ended = stream_end(&mut c, s, T).await.expect("stream ends");
    assert_eq!(ended["data"]["code"], "window_exceeded", "{ended}");
    assert_eq!(part_files(&root).len(), 1, "what reached the disk is kept for a resume");
}

/// A client that stops reading (a phone gone half-open) must not grow serve: past the control
/// queue limit its connection is dropped, and everyone else carries on.
#[tokio::test]
async fn a_client_that_stops_reading_is_dropped() {
    use std::io::{Read, Write};
    let mut env = Env::empty();
    let bin = std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into());
    env.start_with(&bin, &[("CLOTHOD_TEST_CONTROL_MAX", "1048576")]);
    let mut stuck = std::os::unix::net::UnixStream::connect(env.path().join("clothod.sock")).unwrap();
    // Now: macOS refuses (EINVAL) to set it on a socket the peer has closed.
    stuck.set_read_timeout(Some(T)).unwrap();
    let mut out = Frame::Json(json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "stuck"}})).encode();
    out.extend(Frame::Json(json!({"id": 2, "method": "events.subscribe", "params": {}})).encode());
    stuck.write_all(&out).unwrap();
    let c = env.client().await;
    let ws = c.request("workspace.create", json!({"name": "w"})).await.unwrap();
    let id = ws["workspace"].as_u64().or(ws["id"].as_u64()).unwrap_or(1);
    let name = "n".repeat(2000);
    let deadline = Instant::now() + T;
    while !env.log().contains("dropping the connection") {
        assert!(Instant::now() < deadline, "never dropped:\n{}", env.log());
        for i in 0..50 {
            let _ = c.request("workspace.rename", json!({"workspace": id, "name": format!("{name}{i}")})).await;
        }
    }
    // The stuck client gets what was queued, then EOF.
    let mut sink = Vec::new();
    assert!(stuck.read_to_end(&mut sink).is_ok(), "the connection ends");
    let stats = c.request("debug.stats", json!({})).await.unwrap();
    assert_eq!(stats["clients"].as_array().unwrap().len(), 1, "{stats}");
}

/// Deeply nested JSON is refused (serde_json's recursion limit), not a stack overflow.
#[tokio::test]
async fn deeply_nested_json_closes_only_that_connection() {
    use std::io::{Read, Write};
    let env = Env::new();
    let mut s = std::os::unix::net::UnixStream::connect(env.path().join("clothod.sock")).unwrap();
    s.set_read_timeout(Some(T)).unwrap();
    let mut body = vec![clotho_proto::frame::T_JSON];
    body.extend(std::iter::repeat_n(b'[', 1 << 20));
    let mut frame = (body.len() as u32).to_be_bytes().to_vec();
    frame.extend(body);
    s.write_all(&frame).unwrap();
    let mut sink = Vec::new();
    let _ = s.read_to_end(&mut sink);
    let c = env.client().await;
    c.request("ping", json!({})).await.unwrap();
}

/// A pane printing an OSC that never ends (`cat` of a hostile file) costs serve at most
/// MAX_OSC, not the size of the output; the pane works normally afterwards.
#[tokio::test]
async fn an_endless_osc_does_not_grow_serve() {
    let env = Env::new();
    let mut c = env.client().await;
    let p = new_pane(&c, sh()).await;
    let (_, mut s) = subscribe(&mut c, p, None).await;
    sync(&mut c, &mut s).await.unwrap();
    let before = c.request("debug.stats", json!({})).await.unwrap()["heap_peak"].as_u64().unwrap();
    c.input(p, b"printf '\\033]0;'; head -c 100000000 /dev/zero | tr '\\0' A; printf '\\007'; echo osc-$((6*7))\r");
    // Drain what comes (the output itself may be split anywhere, or arrive as a snapshot) and
    // watch the daemon's screen for the end.
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut peak = 0;
    loop {
        while let Some(f) = c.try_recv() {
            if let Frame::Json(v) = &f {
                assert!(v["event"] != "pane" || v["data"]["title"].is_null(), "no title from the dropped OSC");
            }
        }
        let st = c.request("debug.stats", json!({})).await.unwrap();
        peak = peak.max(st["heap_peak"].as_u64().unwrap());
        let t = c.request("pane.text", json!({"pane": p})).await.unwrap();
        if t["lines"].as_array().unwrap().iter().any(|l| l.as_str().is_some_and(|l| output(l) == "osc-42")) {
            break;
        }
        assert!(Instant::now() < deadline, "the pane never finished: {t}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let st = c.request("debug.stats", json!({})).await.unwrap();
    let grew = st["heap_peak"].as_u64().unwrap().max(peak).saturating_sub(before);
    eprintln!("endless OSC of 100 MB: heap peak {before} -> {} (+{} KiB)", before + grew, grew >> 10);
    assert!(grew < 48 << 20, "serve grew {} MiB on a 100 MB OSC", grew >> 20);
}

/// `pane.search` over scrollback and screen, newest first, positions in snapshot coordinates
/// (0 = top screen row, negative = scrollback), paged with `before`.
#[tokio::test]
async fn pane_search_finds_scrollback_matches_in_snapshot_coordinates() {
    let env = Env::new();
    let mut c = env.client().await;
    let mut params = sh();
    params["rows"] = json!(10);
    let p = new_pane(&c, params).await;
    let (_, mut s) = subscribe(&mut c, p, None).await;
    // `start` first: a prompt drawn late lands in front of it, not in front of a row searched for.
    c.input(p, b"echo start; for i in $(seq 1 60); do echo row-$i; done; echo Done-Marker\r");
    wait_for_text(&c, p, T, |l| has_line(l, "Done-Marker")).await.unwrap();
    sync(&mut c, &mut s).await.unwrap();

    let r = c.request("pane.search", json!({"pane": p, "query": "row-1"})).await.unwrap();
    // row-1, row-10..19: newest first.
    let texts: Vec<&str> = r["matches"].as_array().unwrap().iter().map(|m| m["line_text"].as_str().unwrap()).collect();
    assert_eq!(texts.first(), Some(&"row-19"), "{r}");
    assert_eq!(texts.last(), Some(&"row-1"), "{r}");
    assert!(texts.iter().all(|t| *t == "row-1" || t.starts_with("row-1")), "{texts:?}");
    assert_eq!(texts.len(), 11);
    assert!(r["next"].is_null());

    // Same coordinates as a snapshot at that seq: the screen line `line` (>= 0) is that text.
    let marker = c.request("pane.search", json!({"pane": p, "query": "done-marker"})).await.unwrap();
    let m = &marker["matches"][0];
    let line = m["start"]["line"].as_i64().unwrap();
    assert!(line >= 0, "{marker}");
    let screen = c.request("pane.text", json!({"pane": p})).await.unwrap();
    assert_eq!(screen["lines"][line as usize], "Done-Marker");
    assert_eq!(marker["seq"], screen["seq"]);
    // A scrollback match: -k is the k-th line above the screen.
    let r40 = c.request("pane.search", json!({"pane": p, "query": "row-40", "case_sensitive": true})).await.unwrap();
    let l40 = r40["matches"][0]["start"]["line"].as_i64().unwrap();
    let l41 = c.request("pane.search", json!({"pane": p, "query": "row-41"})).await.unwrap()["matches"][0]["start"]["line"].as_i64().unwrap();
    assert_eq!(l41, l40 + 1);
    assert!(c.request("pane.search", json!({"pane": p, "query": "DONE-MARKER", "case_sensitive": true})).await.unwrap()["matches"].as_array().unwrap().is_empty());

    // Regex, paging.
    let mut all = 0;
    let mut before = Value::Null;
    loop {
        let r = c.request("pane.search", json!({"pane": p, "query": "^row-[0-9]+$", "regex": true, "limit": 7, "before": before})).await.unwrap();
        all += r["matches"].as_array().unwrap().len();
        if r["next"].is_null() {
            break;
        }
        before = r["next"].clone();
    }
    assert_eq!(all, 60, "every row once");
    let e = fs_err(c.request("pane.search", json!({"pane": p, "query": "(", "regex": true})).await.unwrap_err());
    assert!(e.contains("bad_request"), "{e}");
}

async fn history(c: &Client, params: Value) -> Vec<Value> {
    c.request("agent.history", params).await.unwrap()["entries"].as_array().unwrap().clone()
}

/// `agent.history`: a bounded log of what a pane's agents did (transitions, messages,
/// attention, mute, ack, departure), kept across serve restarts.
#[tokio::test]
async fn agent_history_logs_transitions_and_survives_a_restart() {
    let mut env = Env::new();
    let c = env.client().await;
    assert!(c.hello["features"].as_array().unwrap().contains(&json!("agent.history")), "{}", c.hello);
    let p = new_pane(&c, sh()).await;
    assert!(history(&c, json!({"pane": p})).await.is_empty());
    let b = test_bin();
    let script = format!(
        r#"sh -c '"{b}" report running --agent claude --session s1; "{b}" report waiting --agent claude --session s1 --message "Allow rm?"; read a; "{b}" report running --agent claude --session s1; "{b}" report done --agent claude --session s1; read b; "{b}" report clear --agent claude --session s1; sleep 60'"#
    );
    c.input(p, format!("{script}\r").as_bytes());
    wait_agent(&c, p, "waiting", |a| a["state"] == "waiting").await;
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    c.request("agent.mute", json!({"pane": p, "muted": true})).await.unwrap();
    let h = history(&c, json!({"pane": p})).await;
    let brief: Vec<(String, Value, Value, Value)> =
        h.iter().map(|e| (e["event"].as_str().unwrap().to_string(), e["state"].clone(), e["attention"].clone(), e["muted"].clone())).collect();
    assert_eq!(
        brief,
        vec![
            ("state".into(), json!("running"), json!(false), json!(false)),
            ("state".into(), json!("waiting"), json!(true), json!(false)),
            ("attention".into(), json!("waiting"), json!(false), json!(false)),
            ("mute".into(), json!("waiting"), json!(false), json!(true)),
        ],
        "{h:#?}"
    );
    assert_eq!(h[1]["message"], "Allow rm?");
    assert_eq!(h[1]["from"], "running");
    assert!(h.iter().all(|e| e["session"] == "s1" && e["kind"] == "claude" && e["source"] == "hook"));
    let t1 = h[1]["at"].as_f64().unwrap();
    assert!(h.windows(2).all(|w| w[0]["at"].as_f64() <= w[1]["at"].as_f64()));

    // Across a restart of the logic process.
    drop(c);
    env.kill();
    env.start();
    let c = env.client().await;
    assert_eq!(history(&c, json!({"pane": p})).await.len(), 4);
    c.input(p, b"a\r");
    wait_agent(&c, p, "done", |a| a["state"] == "done").await;
    c.input(p, b"b\r");
    wait_agent(&c, p, "gone", |a| a.is_null()).await;
    let h = history(&c, json!({"pane": p})).await;
    let states: Vec<Value> = h.iter().map(|e| e["state"].clone()).collect();
    assert_eq!(&states[4..], &[json!("running"), json!("done"), Value::Null], "{h:#?}");
    assert_eq!(h.last().unwrap()["event"], "gone");
    // Filters: since, limit, session.
    assert_eq!(history(&c, json!({"pane": p, "since": t1})).await.len(), h.len() - 2);
    assert_eq!(history(&c, json!({"pane": p, "limit": 2})).await, h[h.len() - 2..].to_vec());
    assert!(history(&c, json!({"pane": p, "session": "other"})).await.is_empty());
    let e = c.request("agent.history", json!({"pane": 999})).await.unwrap_err();
    assert!(e.to_string().contains("not_found"), "{e}");
}

/// Codex Computer Use wraps the notify it finds: `[client, "turn-ended", "--previous-notify",
/// "<JSON of ours>"]`. Ours still runs (the client calls it), so status says so, install updates
/// it in place instead of wrapping the client, and uninstall unwraps it.
#[test]
fn a_codex_notify_chained_inside_another_client_counts_as_installed() {
    let env = Env::empty();
    let home = env.dir.path().join("home");
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    let bin_dir = env.dir.path().join("bin");
    let old_bin = bin_dir.join("current").join("clothod");
    let config = home.join(".codex/config.toml");
    let client = "/Applications/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient";
    let write = |notify: &[String]| {
        let mut doc: toml_edit::DocumentMut = "model = \"gpt\"\n".parse().unwrap();
        let mut arr = toml_edit::Array::new();
        for s in notify {
            arr.push(s.as_str());
        }
        doc["notify"] = toml_edit::value(arr);
        std::fs::write(&config, doc.to_string()).unwrap();
    };
    let read = || -> Vec<String> {
        let doc: toml_edit::DocumentMut = std::fs::read_to_string(&config).unwrap().parse().unwrap();
        assert_eq!(doc["model"].as_str(), Some("gpt"), "the rest is kept");
        doc.get("notify").and_then(|n| n.as_array()).map(|a| a.iter().map(|v| v.as_str().unwrap().to_string()).collect()).unwrap_or_default()
    };
    let run = |args: &[&str]| {
        let out = Command::new(test_bin()).args(args).env("HOME", &home).env("CLOTHOD_INSTALL_DIR", &bin_dir).output().unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    // As on the user's Mac: an older build's notify (0.1.10's quoting), escaped the way the
    // client writes JSON ("\/").
    let old_script = format!(r#"for a; do j=$a; done; c="${{CLOTHOD_REPORT:-{}}}"; [ -n "$CLOTHO_PANE" ] && [ -x "$c" ] && "$c" report --codex-notify "$j"; [ $# -gt 1 ] && exec "$@"; exit 0"#, old_bin.display());
    let inner = serde_json::to_string(&["/bin/sh", "-c", old_script.as_str(), "clotho-notify"]).unwrap().replace('/', "\\/");
    write(&[client.into(), "turn-ended".into(), "--previous-notify".into(), inner]);
    assert!(run(&["hooks", "status"]).contains("codex: outdated (chained)"));

    assert!(run(&["hooks", "install", "codex"]).contains(": installed (chained)"));
    let n = read();
    assert_eq!(n.len(), 4, "not wrapped again: {n:?}");
    assert_eq!((n[0].as_str(), n[1].as_str(), n[2].as_str()), (client, "turn-ended", "--previous-notify"));
    let ours: Vec<String> = serde_json::from_str(&n[3]).unwrap();
    assert_eq!((ours.len(), ours[0].as_str(), ours[3].as_str()), (4, "/bin/sh", "clotho-notify"));
    assert!(!ours[2].contains(r#"c="${CLOTHOD_REPORT"#), "brought up to date: {}", ours[2]);
    assert!(run(&["hooks", "status"]).contains("codex: installed (chained)"));
    assert!(run(&["hooks", "install", "codex"]).contains("already installed (chained)"));

    // Uninstall: the client stays, without a previous notify.
    assert!(run(&["hooks", "uninstall", "codex"]).contains(": uninstalled"));
    assert_eq!(read(), [client, "turn-ended"]);
    assert!(run(&["hooks", "status"]).contains("codex: not installed"));

    // Ours chaining the user's own program, inside the client: uninstall leaves that program.
    let inner = serde_json::to_string(&["/bin/sh", "-c", "x", "clotho-notify", "echo", "mine"]).unwrap();
    write(&[client.into(), "turn-ended".into(), "--previous-notify".into(), inner]);
    assert!(run(&["hooks", "status"]).contains("codex: outdated (chained)"));
    run(&["hooks", "uninstall", "codex"]);
    let n = read();
    assert_eq!(serde_json::from_str::<Vec<String>>(&n[3]).unwrap(), ["echo", "mine"]);
}

/// Hooks installed by 0.1.10 (the install path spliced in double quotes, docs/security.md
/// finding 6) show as `outdated`, and `hooks install` replaces them in place, keeping the
/// user's own hooks and Codex's chained notify program.
#[test]
fn hooks_from_an_older_build_are_outdated_and_reinstall_replaces_them() {
    let env = Env::empty();
    let home = env.dir.path().join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    let bin_dir = env.dir.path().join("bin");
    let old_bin = bin_dir.join("current").join("clothod");
    let marker = "# clotho-agent-status";
    let old_cmd = format!(r#"c="${{CLOTHOD_REPORT:-{}}}"; [ -n "$CLOTHO_PANE" ] && [ -x "$c" ] && "$c" report --claude-hook; true {marker}"#, old_bin.display());
    let ours = |matcher: Option<&str>| {
        let mut g = json!({"hooks": [{"type": "command", "command": old_cmd}]});
        if let Some(m) = matcher {
            g["matcher"] = json!(m);
        }
        g
    };
    let settings = home.join(".claude/settings.json");
    let old = json!({"model": "opus", "hooks": {
        "SessionStart": [ours(None)], "UserPromptSubmit": [ours(None)], "PreToolUse": [ours(Some("*"))],
        "Notification": [ours(None)], "SessionEnd": [ours(None)],
        "Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}, ours(None)],
    }});
    std::fs::write(&settings, serde_json::to_string_pretty(&old).unwrap()).unwrap();
    let old_script = format!(r#"for a; do j=$a; done; c="${{CLOTHOD_REPORT:-{}}}"; [ -n "$CLOTHO_PANE" ] && [ -x "$c" ] && "$c" report --codex-notify "$j"; [ $# -gt 1 ] && exec "$@"; exit 0"#, old_bin.display());
    let config = home.join(".codex/config.toml");
    let mut doc = toml_edit::DocumentMut::new();
    let mut arr = toml_edit::Array::new();
    for s in ["/bin/sh", "-c", old_script.as_str(), "clotho-notify", "echo", "user-notify"] {
        arr.push(s);
    }
    doc["notify"] = toml_edit::value(arr);
    std::fs::write(&config, doc.to_string()).unwrap();

    let run = |args: &[&str]| {
        let out = Command::new(test_bin()).args(args).env("HOME", &home).env("CLOTHOD_INSTALL_DIR", &bin_dir).output().unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    let st = run(&["hooks", "status"]);
    assert!(st.contains("claude: outdated") && st.contains("codex: outdated"), "{st}");
    assert!(run(&["hooks", "install", "claude"]).contains(": installed"));
    assert!(run(&["hooks", "install", "codex"]).contains(": installed"));
    let st = run(&["hooks", "status"]);
    assert!(st.contains("claude: installed") && st.contains("codex: installed"), "{st}");
    assert!(run(&["hooks", "install", "claude"]).contains("already installed"));
    assert!(run(&["hooks", "install", "codex"]).contains("already installed"));

    let s: Value = serde_json::from_str(&std::fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(s["model"], "opus");
    let all: Vec<&str> = s["hooks"].as_object().unwrap().values().flat_map(|g| g.as_array().unwrap()).flat_map(|g| g["hooks"].as_array().unwrap()).map(|h| h["command"].as_str().unwrap()).collect();
    assert!(all.contains(&"echo mine"), "user hook kept");
    assert!(!all.iter().any(|c| c.contains(r#"c="${CLOTHOD_REPORT"#)), "no old command left: {all:?}");
    assert_eq!(all.iter().filter(|c| c.contains(marker)).count(), 8, "one of ours per event");
    let doc: toml_edit::DocumentMut = std::fs::read_to_string(&config).unwrap().parse().unwrap();
    let notify: Vec<String> = doc["notify"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
    assert_eq!(notify.len(), 6, "{notify:?}");
    assert_eq!(&notify[3..], ["clotho-notify", "echo", "user-notify"], "still chains the user's program once");
    assert!(!notify[2].contains(r#"c="${CLOTHOD_REPORT"#));
}


// ---- restore after restart ---------------------------------------------------------------

/// An instance that keeps a layout file (in its own data dir, never the user's), with stand-in
/// `claude` and `codex` on PATH that record how they were run.
struct RestoreEnv {
    env: Env,
    vars: Vec<(String, String)>,
}

impl RestoreEnv {
    fn new() -> RestoreEnv {
        let env = Env::empty();
        let stubs = env.dir.path().join("stubs");
        std::fs::create_dir_all(&stubs).unwrap();
        let rec = env.dir.path().join("agents.rec");
        for name in ["claude", "codex"] {
            let f = stubs.join(name);
            std::fs::write(&f, format!("#!/bin/sh\necho \"{name} $* in $PWD\" >> '{}'\n", rec.display())).unwrap();
            std::fs::set_permissions(&f, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        }
        let path = format!("{}:{}", stubs.display(), std::env::var("PATH").unwrap_or_default());
        let vars = vec![
            ("CLOTHOD_LAYOUT_FILE".to_string(), env.dir.path().join("data/layout.json").display().to_string()),
            ("PATH".to_string(), path),
        ];
        let mut r = RestoreEnv { env, vars };
        r.start();
        r
    }

    fn start(&mut self) {
        let vars: Vec<(&str, &str)> = self.vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        self.env.start_with(&test_bin(), &vars);
    }

    fn layout(&self) -> Option<Value> {
        std::fs::read_to_string(self.env.dir.path().join("data/layout.json")).ok().and_then(|t| serde_json::from_str(&t).ok())
    }

    /// The machine restarts: serve and holder die at once, the runtime dir is wiped, and a
    /// fresh daemon starts.
    fn reboot(&mut self) {
        let holder = holder_pid(&self.env);
        self.env.kill();
        unsafe { libc::kill(holder as i32, libc::SIGKILL) };
        let deadline = Instant::now() + T;
        while clotho_proto::platform::process_alive(holder) {
            assert!(Instant::now() < deadline, "holder {holder} still running");
            std::thread::sleep(Duration::from_millis(20));
        }
        std::fs::remove_dir_all(self.env.path()).unwrap();
        std::fs::create_dir_all(self.env.path()).unwrap();
        self.start();
    }

    fn rec(&self) -> String {
        std::fs::read_to_string(self.env.dir.path().join("agents.rec")).unwrap_or_default()
    }

    /// Wait until the saved layout satisfies `cond`.
    async fn wait_layout(&self, what: &str, cond: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + T;
        loop {
            if let Some(l) = self.layout().filter(|l| cond(l)) {
                return l;
            }
            assert!(Instant::now() < deadline, "layout never {what}: {:?}", self.layout());
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// A stand-in agent in `pane` that reports through the real hook commands with `session`,
    /// then stays (as the agent process the hook reports from would).
    async fn agent(&self, c: &Client, pane: u64, kind: &str, session: &str) {
        let b = test_bin();
        let line = match kind {
            "claude" => {
                let f = self.env.dir.path().join(format!("hook-{pane}.json"));
                let payload = json!({"session_id": session, "transcript_path": "/t.jsonl", "cwd": "/p", "hook_event_name": "UserPromptSubmit", "prompt": "hi"});
                std::fs::write(&f, payload.to_string()).unwrap();
                format!("'{b}' report --claude-hook < '{}'", f.display())
            }
            _ => {
                let payload = json!({"type": "agent-turn-complete", "thread-id": session, "turn-id": "t1", "cwd": "/p", "input-messages": ["hi"], "last-assistant-message": "ok"});
                format!("'{b}' report --codex-notify '{payload}'")
            }
        };
        let script = self.env.dir.path().join(format!("agent-{pane}.sh"));
        std::fs::write(&script, format!("{line}\nexec sleep 120\n")).unwrap();
        c.input(pane, format!("sh '{}'\r", script.display()).as_bytes());
        wait_agent(c, pane, "the agent's session", |a| a["session"] == session).await;
    }
}

fn pane_of(state: &Value, id: u64) -> &Value {
    state["panes"].as_array().unwrap().iter().find(|p| p["id"] == id).unwrap_or_else(|| panic!("no pane {id} in {state}"))
}

/// A canonical path (macOS: /tmp is /private/tmp), as a shell's cwd reads.
fn real(p: &std::path::Path) -> String {
    std::fs::canonicalize(p).unwrap().display().to_string()
}

/// A reboot: serve and holder die at once (and with the holder, every shell), and the
/// runtime dir is wiped. The next start brings back the workspaces, tabs, splits, focus and
/// cwds from the layout file, resumes the agents that had a session, and does it only once.
#[tokio::test]
async fn a_restart_restores_the_layout_and_resumes_agents() {
    let mut r = RestoreEnv::new();
    let c = r.env.client().await;
    let dirs: Vec<_> = ["a", "b", "c"].iter().map(|n| r.env.dir.path().join("work").join(n)).collect();
    for d in &dirs {
        std::fs::create_dir_all(d).unwrap();
    }
    let at = |i: usize| with(sh(), json!({"cwd": dirs[i].display().to_string()}));
    let w1 = c.request("workspace.create", with(at(0), json!({"name": "alpha"}))).await.unwrap();
    let (p1, ws1, t1) = (w1["pane"].as_u64().unwrap(), w1["workspace"].as_u64().unwrap(), w1["tab"].as_u64().unwrap());
    c.request("tab.rename", json!({"tab": t1, "title": "build"})).await.unwrap();
    let p2 = c.request("pane.split", with(at(1), json!({"pane": p1, "direction": "right", "ratio": 0.3}))).await.unwrap()["pane"].as_u64().unwrap();
    let w2 = c.request("workspace.create", with(at(2), json!({"name": "beta"}))).await.unwrap();
    let p3 = w2["pane"].as_u64().unwrap();
    let t3 = c.request("tab.create", with(at(0), json!({"workspace": w2["workspace"]}))).await.unwrap();
    c.request("tab.rename", json!({"tab": t3["tab"], "title": "logs"})).await.unwrap();
    r.agent(&c, p1, "claude", "1f0e5d2c-claude-session").await;
    r.agent(&c, p2, "codex", "019a2b3c-codex-thread").await;
    c.request("focus", json!({"pane": p2})).await.unwrap();
    let before = c.request("state.get", json!({})).await.unwrap();
    assert_eq!(before["focus"]["pane"], p2);
    let instance = c.hello["instance"].clone();

    let saved = r
        .wait_layout("saved with both sessions and the focus", |l| {
            let s = l.to_string();
            s.contains("1f0e5d2c-claude-session") && s.contains("019a2b3c-codex-thread") && l["model"]["focus"]["pane"] == p2
        })
        .await;
    assert_eq!(saved["version"], 1);
    assert_eq!(saved["panes"][p3.to_string()]["cwd"], real(&dirs[2]));
    drop(c);

    // The reboot.
    let holder = holder_pid(&r.env);
    r.env.kill();
    unsafe { libc::kill(holder as i32, libc::SIGKILL) };
    let deadline = Instant::now() + T;
    while clotho_proto::platform::process_alive(holder) {
        assert!(Instant::now() < deadline, "holder {holder} still running");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::fs::remove_dir_all(r.env.path()).unwrap();
    std::fs::create_dir_all(r.env.path()).unwrap();
    r.start();

    let c = r.env.client().await;
    assert_ne!(c.hello["instance"], instance, "a fresh holder");
    assert!(c.hello["features"].as_array().unwrap().contains(&json!("restore")), "{}", c.hello);
    let after = c.request("state.get", json!({})).await.unwrap();
    // Same structure: names, titles, order, split and ratio, active tabs; new pane ids.
    let names: Vec<_> = after["workspaces"].as_array().unwrap().iter().map(|w| w["name"].clone()).collect();
    assert_eq!(names, vec![json!("alpha"), json!("beta")]);
    let tabs = |s: &Value, w: usize| -> Vec<Value> { s["workspaces"][w]["tabs"].as_array().unwrap().iter().map(|t| t["title"].clone()).collect() };
    assert_eq!(tabs(&after, 0), vec![json!("build")]);
    assert_eq!(tabs(&after, 1), vec![Value::Null, json!("logs")]);
    let layout = &after["workspaces"][0]["tabs"][0]["layout"];
    assert_eq!((layout["type"].clone(), layout["axis"].clone(), layout["ratio"].clone()), (json!("split"), json!("horizontal"), json!(0.3)));
    assert_eq!(after["workspaces"][0]["id"], ws1, "workspace ids are the saved ones");
    let (n1, n2) = (layout["a"]["pane"].as_u64().unwrap(), layout["b"]["pane"].as_u64().unwrap());
    let n3 = after["workspaces"][1]["tabs"][0]["layout"]["pane"].as_u64().unwrap();
    let n4 = after["workspaces"][1]["tabs"][1]["layout"]["pane"].as_u64().unwrap();
    assert_eq!(after["focus"]["pane"], n2, "focus came back");
    assert_eq!(after["workspaces"][0]["tabs"][0]["active_pane"], n2);
    assert_eq!(after["panes"].as_array().unwrap().len(), 4, "{after}");

    // Each pane: a fresh shell in its cwd, marked restored; the agents' panes resumed theirs.
    for (id, dir) in [(n1, 0), (n2, 1), (n3, 2), (n4, 0)] {
        let deadline = Instant::now() + T;
        loop {
            let s = c.request("state.get", json!({})).await.unwrap();
            if pane_of(&s, id)["cwd"] == real(&dirs[dir]) {
                break;
            }
            assert!(Instant::now() < deadline, "pane {id} cwd: {}", pane_of(&s, id));
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
    let restored = |id: u64| pane_of(&after, id)["restored"].clone();
    assert_eq!((restored(n1)["agent"].clone(), restored(n1)["session"].clone()), (json!("claude"), json!("1f0e5d2c-claude-session")));
    assert_eq!((restored(n2)["agent"].clone(), restored(n2)["session"].clone()), (json!("codex"), json!("019a2b3c-codex-thread")));
    for id in [n3, n4] {
        assert!(restored(id)["at"].as_f64().is_some() && restored(id)["agent"].is_null(), "{}", restored(id));
    }
    let deadline = Instant::now() + T;
    while r.rec().lines().count() < 2 {
        assert!(Instant::now() < deadline, "agents not resumed: {:?}\n{}", r.rec(), r.env.log());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let mut rec: Vec<String> = r.rec().lines().map(String::from).collect();
    rec.sort();
    assert_eq!(
        rec,
        vec![format!("claude --resume=1f0e5d2c-claude-session in {}", real(&dirs[0])), format!("codex resume -- 019a2b3c-codex-thread in {}", real(&dirs[1]))]
    );
    // The shell stays when the agent exits.
    c.input(n1, b"echo still-here\r");
    wait_for_text(&c, n1, T, |l| has_line(l, "still-here")).await.unwrap();

    // The note goes when a client dismisses it, or the user types in the pane (n1 just did);
    // focus reports don't count.
    c.input(n3, b"\x1b[I");
    c.request("pane.dismiss_restored", json!({"pane": n2})).await.unwrap();
    c.request("pane.dismiss_restored", json!({"pane": n2})).await.unwrap();
    assert!(c.request("pane.dismiss_restored", json!({"pane": 999_999})).await.unwrap_err().to_string().contains("not_found"));
    let s = c.request("state.get", json!({})).await.unwrap();
    assert!(pane_of(&s, n1)["restored"].is_null() && pane_of(&s, n2)["restored"].is_null());
    assert!(pane_of(&s, n3)["restored"].is_object() && pane_of(&s, n4)["restored"].is_object(), "{s}");

    // The file now holds the new live state.
    r.wait_layout("rewritten with the new panes", |l| l["model"]["focus"]["pane"] == n2 && l["panes"].get(n4.to_string()).is_some()).await;
    drop(c);

    // A serve restart adopts the holder: nothing restored again, nothing typed again, and the
    // restored mark survives where it wasn't dismissed.
    r.env.kill();
    r.start();
    let c = r.env.client().await;
    let again = c.request("state.get", json!({})).await.unwrap();
    let ids = |s: &Value| -> Vec<u64> { let mut v: Vec<u64> = s["panes"].as_array().unwrap().iter().map(|p| p["id"].as_u64().unwrap()).collect(); v.sort(); v };
    assert_eq!(ids(&again), ids(&after));
    assert!(pane_of(&again, n3)["restored"].is_object() && pane_of(&again, n2)["restored"].is_null(), "{again}");
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(r.rec().lines().count(), 2, "{}", r.rec());
    assert!(!r.env.log().contains("not restoring"), "{}", r.env.log());
    drop(c);

    // `shutdown --forget` ends everything and deletes the saved layout: nothing to restore.
    r.env.daemon.take();
    let out = Command::new(test_bin())
        .args(["shutdown", "--forget", "--runtime-dir"])
        .arg(r.env.path())
        .env("CLOTHOD_STATE_DIR", r.env.state())
        .env("CLOTHOD_RUNTIME_DIR", r.env.path())
        .envs(r.vars.iter().map(|(k, v)| (k, v)))
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert!(r.layout().is_none(), "layout still there: {:?}", r.layout());
    std::fs::create_dir_all(r.env.path()).unwrap();
    r.start();
    let c = r.env.client().await;
    assert!(c.request("state.get", json!({})).await.unwrap()["workspaces"].as_array().unwrap().is_empty());
}

/// A reboot ends the agents first: Claude and Codex quit on the SIGTERM at once, while an
/// interactive shell ignores it and clothod lives on for a moment. The agent's end must not
/// cost the pane its session: it is resumed after the restart. An agent the user quits, with
/// the shell staying on, is forgotten once that has lasted a while (shortened here).
#[tokio::test]
async fn an_agent_that_ends_just_before_a_reboot_is_still_resumed() {
    let mut r = RestoreEnv::new();
    r.vars.push(("CLOTHOD_TEST_AGENT_GONE_MS".into(), "3000".into()));
    r.env.kill();
    r.start();
    let c = r.env.client().await;
    let dir = r.env.dir.path().join("work");
    std::fs::create_dir_all(&dir).unwrap();
    let cwd = json!({"cwd": dir.display().to_string()});
    let w = c.request("workspace.create", with(with(sh(), cwd.clone()), json!({"name": "w"}))).await.unwrap();
    let (p1, ws) = (w["pane"].as_u64().unwrap(), w["workspace"].clone());
    let p2 = c.request("tab.create", with(with(sh(), cwd), json!({"workspace": ws}))).await.unwrap()["pane"].as_u64().unwrap();
    r.agent(&c, p1, "claude", "aaaa1111-ends-at-reboot").await;
    r.agent(&c, p2, "codex", "bbbb2222-quit-by-user").await;
    r.wait_layout("saved with both sessions", |l| {
        let s = l.to_string();
        s.contains("aaaa1111-ends-at-reboot") && s.contains("bbbb2222-quit-by-user")
    })
    .await;

    // The user quits p2's agent; its shell stays. After the quiet time the file forgets it.
    c.input(p2, b"\x03");
    wait_agent(&c, p2, "p2's agent to end", |a| a.is_null()).await;
    r.wait_layout("without p2's session", |l| !l.to_string().contains("bbbb2222-quit-by-user")).await;

    // The reboot: p1's agent ends, clothod sees it, and dies 1.5 s later (past the debounce).
    c.input(p1, b"\x03");
    wait_agent(&c, p1, "p1's agent to end", |a| a.is_null()).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert!(r.layout().unwrap().to_string().contains("aaaa1111-ends-at-reboot"), "{:?}", r.layout());
    drop(c);
    r.reboot();

    let c = r.env.client().await;
    let deadline = Instant::now() + T;
    while r.rec().lines().count() < 1 {
        assert!(Instant::now() < deadline, "not resumed: {:?}\n{}", r.layout(), r.env.log());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(r.rec().trim(), format!("claude --resume=aaaa1111-ends-at-reboot in {}", real(&dir)));
    let s = c.request("state.get", json!({})).await.unwrap();
    let marks: Vec<Value> = s["panes"].as_array().unwrap().iter().map(|p| p["restored"]["agent"].clone()).collect();
    assert_eq!(marks.iter().filter(|m| **m == json!("claude")).count(), 1, "{s}");
    assert_eq!(marks.iter().filter(|m| m.is_null()).count(), 1, "{s}");
}

/// A Claude Code found by detection (no hooks) has its session read from its own record
/// (`$CLAUDE_CONFIG_DIR/sessions/<pid>.json`), and is resumed after a reboot. A record for
/// another pid or cwd is ignored.
#[tokio::test]
async fn a_detected_claude_is_resumed_from_its_session_record() {
    let mut r = RestoreEnv::new();
    let c = r.env.client().await;
    let dir = r.env.dir.path().join("work");
    let fake = r.env.dir.path().join("fake");
    let sessions = r.env.dir.path().join("claude-config/sessions");
    for d in [&dir, &fake, &sessions] {
        std::fs::create_dir_all(d).unwrap();
    }
    // A stand-in Claude Code, not on PATH (the resume line runs the recording stub): writes
    // its record as Claude Code does, then stays in the foreground.
    let claude = fake.join("claude");
    std::fs::write(
        &claude,
        format!(
            "#!/bin/sh\nprintf '{{\"pid\": %s, \"sessionId\": \"%s\", \"cwd\": \"%s\"}}' $$ \"$1\" \"$PWD\" > '{}'/$$.json\nsleep 120\n",
            sessions.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&claude, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let w = c.request("workspace.create", with(with(sh(), json!({"cwd": dir.display().to_string()})), json!({"name": "w"}))).await.unwrap();
    let p = w["pane"].as_u64().unwrap();
    c.input(p, format!("'{}' dddd4444-detected\r", claude.display()).as_bytes());
    let a = wait_agent(&c, p, "a detected claude with its session", |a| a["session"] == "dddd4444-detected").await;
    assert_eq!(a["kind"], "claude");
    r.wait_layout("saved with the detected session", |l| l.to_string().contains("dddd4444-detected")).await;
    drop(c);
    r.reboot();
    let _c = r.env.client().await;
    let deadline = Instant::now() + T;
    while r.rec().lines().count() < 1 {
        assert!(Instant::now() < deadline, "not resumed: {:?}\n{}", r.layout(), r.env.log());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(r.rec().trim(), format!("claude --resume=dddd4444-detected in {}", real(&dir)));
}

/// An agent whose session wasn't known is continued (`claude --continue`, `codex resume
/// --last`: the latest conversation in its folder) only when no other saved pane had that kind
/// of agent in that folder, with a session or without. Two in one folder both get bare shells,
/// and so does one next to a pane with a known session.
#[tokio::test]
async fn agents_without_a_session_are_continued_only_when_unambiguous() {
    let mut r = RestoreEnv::new();
    let c = r.env.client().await;
    let root = r.env.dir.path().to_path_buf();
    let (alone, shared, known, fake) = (root.join("alone"), root.join("shared"), root.join("known"), root.join("fake"));
    for d in [&alone, &shared, &known, &fake] {
        std::fs::create_dir_all(d).unwrap();
    }
    // Stand-ins found by detection, with no hooks and no session record: never on PATH (the
    // restore's lines run the recording stubs).
    for kind in ["claude", "codex"] {
        let f = fake.join(kind);
        std::fs::write(&f, "#!/bin/sh\nsleep 120\n").unwrap();
        std::fs::set_permissions(&f, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    }
    let w = c.request("workspace.create", with(with(sh(), json!({"cwd": alone.display().to_string()})), json!({"name": "w"}))).await.unwrap();
    let ws = w["workspace"].clone();
    let tab_in = |d: &std::path::Path| with(with(sh(), json!({"cwd": d.display().to_string()})), json!({"workspace": ws}));
    let a = w["pane"].as_u64().unwrap();
    let pane = |d: std::path::PathBuf| {
        let req = tab_in(&d);
        let c = &c;
        async move { c.request("tab.create", req).await.unwrap()["pane"].as_u64().unwrap() }
    };
    let (f, b, b2, k, k2) = (pane(alone.clone()).await, pane(shared.clone()).await, pane(shared.clone()).await, pane(known.clone()).await, pane(known.clone()).await);
    let detected = |p: u64, kind: &str| c.input(p, format!("'{}'\r", fake.join(kind).display()).as_bytes());
    detected(a, "claude");
    detected(f, "codex");
    detected(b, "claude");
    detected(b2, "claude");
    detected(k2, "claude");
    r.agent(&c, k, "claude", "eeee5555-known").await;
    for (p, kind) in [(a, "claude"), (f, "codex"), (b, "claude"), (b2, "claude"), (k2, "claude")] {
        wait_agent(&c, p, "a detected agent", |x| x["kind"] == kind).await;
    }
    r.wait_layout("saved with six agents", |l| l["panes"].as_object().unwrap().values().filter(|p| p.get("agent").is_some()).count() == 6).await;
    let saved = r.layout().unwrap();
    assert!(saved["panes"][a.to_string()]["agent"].get("session").is_none(), "{saved}");
    drop(c);
    r.reboot();

    let c = r.env.client().await;
    let deadline = Instant::now() + T;
    while r.rec().lines().count() < 3 {
        assert!(Instant::now() < deadline, "not resumed: {:?}\n{}", r.rec(), r.env.log());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let mut rec: Vec<String> = r.rec().lines().map(String::from).collect();
    rec.sort();
    assert_eq!(
        rec,
        vec![
            format!("claude --continue in {}", real(&alone)),
            format!("claude --resume=eeee5555-known in {}", real(&known)),
            format!("codex resume --last in {}", real(&alone)),
        ]
    );
    let s = c.request("state.get", json!({})).await.unwrap();
    let marks: Vec<Value> = s["panes"].as_array().unwrap().iter().map(|p| p["restored"].clone()).collect();
    let count = |agent: Value, session: Value, continued: bool| marks.iter().filter(|m| m["agent"] == agent && m["session"] == session && m["continued"] == continued).count();
    assert_eq!(count(json!("claude"), Value::Null, true), 1, "{s}");
    assert_eq!(count(json!("codex"), Value::Null, true), 1, "{s}");
    assert_eq!(count(json!("claude"), json!("eeee5555-known"), false), 1, "{s}");
    assert_eq!(count(Value::Null, Value::Null, false), 3, "bare shells: both in the shared folder, the guess next to the known one; {s}");
}

/// What must never restore: a serve that adopts a running holder (a crash, an in-place
/// upgrade) restores nothing and duplicates nothing; a corrupt file is moved aside; an
/// ordinary ephemeral instance keeps no layout file at all.
#[tokio::test]
async fn adopting_the_holder_never_restores() {
    let mut r = RestoreEnv::new();
    let c = r.env.client().await;
    let p = new_pane(&c, sh()).await;
    let q = c.request("pane.split", with(sh(), json!({"pane": p, "direction": "down"}))).await.unwrap()["pane"].as_u64().unwrap();
    // An id that could read as a flag is never stored, from a hook or from agent.report.
    let f = r.env.dir.path().join("bad-hook.json");
    std::fs::write(&f, json!({"session_id": "--dangerously-skip-permissions", "hook_event_name": "UserPromptSubmit", "prompt": "hi"}).to_string()).unwrap();
    c.input(q, format!("'{}' report --claude-hook < '{}'\r", test_bin(), f.display()).as_bytes());
    let a = wait_agent(&c, q, "the hook's report", |a| a["state"] == "running").await;
    assert!(a["session"].is_null(), "{a}");
    c.request("agent.report", json!({"pane": q, "state": "waiting", "kind": "codex", "session": "-c"})).await.unwrap();
    let a = wait_agent(&c, q, "agent.report", |a| a["state"] == "waiting").await;
    assert!(a["session"].is_null(), "{a}");
    c.request("agent.report", json!({"pane": q, "state": "clear"})).await.unwrap();
    r.agent(&c, p, "claude", "aaaa-bbbb").await;
    r.wait_layout("saved", |l| l.to_string().contains("aaaa-bbbb")).await;
    assert!(!r.layout().unwrap().to_string().contains("dangerously"));
    let instance = c.hello["instance"].clone();
    let before = c.request("state.get", json!({})).await.unwrap();
    drop(c);

    let check = |s: &Value, what: &str| {
        let ids: Vec<_> = s["panes"].as_array().unwrap().iter().map(|x| x["id"].clone()).collect();
        assert_eq!(ids.len(), 2, "{what}: {s}");
        assert!(ids.contains(&json!(p)) && ids.contains(&json!(q)), "{what}: {s}");
        assert_eq!(s["workspaces"], before["workspaces"], "{what}");
        assert!(s["panes"].as_array().unwrap().iter().all(|x| x["restored"].is_null()), "{what}: {s}");
    };
    // Crash and restart.
    r.env.kill();
    r.start();
    let c = r.env.client().await;
    assert_eq!(c.hello["instance"], instance);
    check(&c.request("state.get", json!({})).await.unwrap(), "after a restart");
    // The hook-reported agent is kept across the restart, session and all, at once (not only
    // after its next hook).
    let a = pane_agent(&c, p).await;
    assert_eq!((a["kind"].clone(), a["session"].clone(), a["source"].clone()), (json!("claude"), json!("aaaa-bbbb"), json!("hook")), "{a}");
    drop(c);

    // In-place upgrade.
    r.env.daemon.take();
    let (v2, id2) = other_build(&r.env, "v2");
    let out = Command::new(&v2)
        .arg("upgrade")
        .arg("--runtime-dir")
        .arg(r.env.path())
        .env("CLOTHOD_STATE_DIR", r.env.state())
        .env("CLOTHOD_INSTALL_DIR", r.env.dir.path().join("bin"))
        .env("CLOTHOD_REGISTRY_DIR", r.env.dir.path().join("registry"))
        .env("CLOTHOD_RUNTIME_DIR", r.env.path())
        .envs(r.vars.iter().map(|(k, v)| (k, v)))
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let c = r.env.client().await;
    assert_eq!((c.hello["build"].clone(), c.hello["instance"].clone()), (json!(id2), instance));
    check(&c.request("state.get", json!({})).await.unwrap(), "after an upgrade");
    assert_eq!(pane_agent(&c, p).await["session"], "aaaa-bbbb");
    assert!(r.layout().unwrap().to_string().contains("aaaa-bbbb"), "the layout still resumes it");
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(r.rec(), "", "nothing resumed");
    drop(c);
    let _ = clothod_cmd(&r.env, &v2, &["shutdown"]);

    // A corrupt file at a fresh start: moved aside, nothing restored, and a new one written.
    let data = r.env.dir.path().join("data");
    std::fs::write(data.join("layout.json"), "{\"version\": 1, \"model\": ").unwrap();
    let deadline = Instant::now() + T;
    while std::os::unix::net::UnixStream::connect(r.env.path().join("clothod.sock")).is_ok() {
        assert!(Instant::now() < deadline, "did not shut down");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // The exiting temporary instance removes its runtime dir after the socket closes: wait
    // for that, or a new dir made now could be removed under the next start.
    while r.env.path().exists() {
        assert!(Instant::now() < deadline, "runtime dir not removed");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    std::fs::create_dir_all(r.env.path()).unwrap();
    r.start();
    let c = r.env.client().await;
    let s = c.request("state.get", json!({})).await.unwrap();
    assert!(s["workspaces"].as_array().unwrap().is_empty(), "{s}");
    let aside: Vec<_> = std::fs::read_dir(&data).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.starts_with("layout.json.corrupt-")).collect();
    assert_eq!(aside.len(), 1, "{aside:?}");
    new_pane(&c, sh()).await;
    r.wait_layout("rewritten", |l| l["model"]["workspaces"].as_array().is_some_and(|w| w.len() == 1)).await;
    drop(c);

    // An ephemeral instance without CLOTHOD_LAYOUT_FILE writes nothing anywhere.
    let plain = Env::new();
    let c = plain.client().await;
    new_pane(&c, sh()).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let mut found = Vec::new();
    for d in [plain.dir.path().to_path_buf()] {
        for e in walk(&d) {
            if e.file_name().is_some_and(|n| n.to_string_lossy().starts_with("layout")) {
                found.push(e);
            }
        }
    }
    assert!(found.is_empty(), "{found:?}");
}

fn walk(d: &std::path::Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
        let p = e.path();
        if e.file_type().is_ok_and(|t| t.is_dir()) {
            out.extend(walk(&p));
        } else {
            out.push(p);
        }
    }
    out
}

// ---- moving tabs and workspaces ------------------------------------------------------------

/// The next `state` event (skipping other frames), or `None` if none comes within `wait`.
async fn next_state(c: &mut Client, wait: Duration) -> Option<Value> {
    let deadline = Instant::now() + wait;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match tokio::time::timeout(left, c.recv()).await {
            Ok(Some(Frame::Json(v))) if v["event"] == "state" => return Some(v["data"].clone()),
            Ok(Some(_)) => {}
            _ => return None,
        }
    }
}

fn tab_order(s: &Value) -> Vec<(Value, Vec<Value>)> {
    s["workspaces"].as_array().unwrap().iter().map(|w| (w["name"].clone(), w["tabs"].as_array().unwrap().iter().map(|t| t["id"].clone()).collect())).collect()
}

/// Drag to reorder: workspaces and tabs move, also into another workspace, with their panes
/// and shells as they were. Every client sees each move live; a move to the same place sends
/// nothing; the saved layout follows.
#[tokio::test]
async fn tabs_and_workspaces_move_and_every_client_sees_it() {
    let r = RestoreEnv::new();
    let a = r.env.client().await;
    let mut b = r.env.client().await;
    assert!(a.hello["features"].as_array().unwrap().contains(&json!("move")), "{}", a.hello);
    let w1 = a.request("workspace.create", with(sh(), json!({"name": "one"}))).await.unwrap();
    let (ws1, t1, p1) = (w1["workspace"].as_u64().unwrap(), w1["tab"].as_u64().unwrap(), w1["pane"].as_u64().unwrap());
    let t2 = a.request("tab.create", with(sh(), json!({"workspace": ws1}))).await.unwrap()["tab"].as_u64().unwrap();
    let w2 = a.request("workspace.create", with(sh(), json!({"name": "two"}))).await.unwrap();
    let (ws2, t3) = (w2["workspace"].as_u64().unwrap(), w2["tab"].as_u64().unwrap());
    let ws3 = a.request("workspace.create", with(sh(), json!({"name": "three"}))).await.unwrap()["workspace"].as_u64().unwrap();
    // A shell in t1 to check it survives the moves.
    a.input(p1, b"V=kept; echo shellpid=$$\r");
    let lines = wait_for_text(&a, p1, T, |l| l.iter().any(|l| output(l).starts_with("shellpid="))).await.unwrap();
    let pid = lines.iter().find_map(|l| output(l).strip_prefix("shellpid=")).unwrap().to_string();
    b.request("events.subscribe", json!({})).await.unwrap();
    next_state(&mut b, T).await.expect("the initial state");

    // Workspaces: clamped to the end, then to the front.
    assert_eq!(a.request("workspace.move", json!({"workspace": ws1, "index": 99})).await.unwrap(), json!({"index": 2}));
    let s = next_state(&mut b, T).await.expect("a state event for the move");
    let names: Vec<_> = tab_order(&s).into_iter().map(|o| o.0).collect();
    assert_eq!(names, vec![json!("two"), json!("three"), json!("one")]);
    // The same place: nothing changes, and no event.
    let rev = s["rev"].clone();
    assert_eq!(a.request("workspace.move", json!({"workspace": ws1, "index": 2})).await.unwrap(), json!({"index": 2}));
    assert!(next_state(&mut b, Duration::from_millis(500)).await.is_none(), "a no-op sends nothing");
    assert_eq!(a.request("state.get", json!({})).await.unwrap()["rev"], rev);

    // A tab within its workspace, then the focused one into another workspace: focus follows.
    a.request("focus", json!({"tab": t1})).await.unwrap();
    next_state(&mut b, T).await;
    assert_eq!(a.request("tab.move", json!({"tab": t1, "index": 1})).await.unwrap(), json!({"workspace": ws1, "index": 1}));
    let s = next_state(&mut b, T).await.unwrap();
    assert_eq!(tab_order(&s)[2].1, vec![json!(t2), json!(t1)]);
    assert_eq!(a.request("tab.move", json!({"tab": t1, "workspace": ws2, "index": 0})).await.unwrap(), json!({"workspace": ws2, "index": 0}));
    let s = next_state(&mut b, T).await.unwrap();
    assert_eq!(tab_order(&s)[0].1, vec![json!(t1), json!(t3)]);
    assert_eq!(s["focus"], json!({"workspace": ws2, "tab": t1, "pane": p1}));
    assert_eq!(s["workspaces"][0]["active_tab"], t1);
    assert_eq!(s["workspaces"][2]["active_tab"], t2, "the source keeps a tab active");
    // The last tab out, unfocused: its workspace stays, empty; focus stays where it is.
    assert_eq!(a.request("tab.move", json!({"tab": t2, "workspace": ws3, "index": 0, "focus": false})).await.unwrap(), json!({"workspace": ws3, "index": 0}));
    let s = next_state(&mut b, T).await.unwrap();
    assert_eq!(tab_order(&s)[2], (json!("one"), vec![]));
    assert!(s["workspaces"][2]["active_tab"].is_null());
    assert_eq!(s["focus"]["tab"], t1);
    assert_ne!(s["workspaces"][1]["active_tab"], json!(t2), "destination's active tab unchanged");
    // focus: true takes the focus along.
    a.request("tab.move", json!({"tab": t2, "workspace": ws1, "index": 0, "focus": true})).await.unwrap();
    let s = next_state(&mut b, T).await.unwrap();
    assert_eq!(s["focus"]["tab"], t2);
    assert_eq!(s["workspaces"][2]["active_tab"], t2);

    // Errors, and nothing moved by them.
    for (m, params, code) in [
        ("tab.move", json!({"tab": 999_999, "index": 0}), "not_found"),
        ("tab.move", json!({"tab": t1, "workspace": 999_999, "index": 0}), "not_found"),
        ("tab.move", json!({"tab": t1, "index": -1}), "bad_request"),
        ("tab.move", json!({"tab": t1}), "bad_request"),
        ("tab.move", json!({"tab": t1, "index": 0, "focus": "yes"}), "bad_request"),
        ("workspace.move", json!({"workspace": 999_999, "index": 0}), "not_found"),
        ("workspace.move", json!({"workspace": ws1, "index": 1.5}), "bad_request"),
    ] {
        let e = a.request(m, params.clone()).await.unwrap_err().to_string();
        assert!(e.contains(code), "{m} {params}: {e}");
    }
    assert!(next_state(&mut b, Duration::from_millis(300)).await.is_none(), "errors send nothing");

    // The moved tab's shell is the same one, with its state.
    a.input(p1, b"echo $V-$$\r");
    wait_for_text(&a, p1, T, |l| has_line(l, &format!("kept-{pid}"))).await.unwrap();
    // The saved layout follows.
    r.wait_layout("with the moved tabs", |l| {
        let ws = &l["model"]["workspaces"];
        ws[0]["name"] == "two" && ws[0]["tabs"][0]["id"] == t1 && ws[2]["tabs"][0]["id"] == t2
    })
    .await;
}

/// ⌘↩ in ⌘P: a live pane, or a whole tab, moves into a split beside another pane, also across
/// tabs and workspaces. The shells and agents are the same ones; an emptied tab closes and its
/// workspace stays; every client sees each move; the saved layout follows, and a reboot
/// restores the new arrangement with the moved agent resumed.
#[tokio::test]
async fn panes_and_tabs_move_beside_another_pane() {
    let mut r = RestoreEnv::new();
    let a = r.env.client().await;
    let mut b = r.env.client().await;
    assert!(a.hello["features"].as_array().unwrap().contains(&json!("pane.move")), "{}", a.hello);
    let w1 = a.request("workspace.create", with(sh(), json!({"name": "one"}))).await.unwrap();
    let (ws1, t1, p1) = (w1["workspace"].as_u64().unwrap(), w1["tab"].as_u64().unwrap(), w1["pane"].as_u64().unwrap());
    let t2r = a.request("tab.create", with(sh(), json!({"workspace": ws1}))).await.unwrap();
    let (t2, p2) = (t2r["tab"].as_u64().unwrap(), t2r["pane"].as_u64().unwrap());
    let w2 = a.request("workspace.create", with(sh(), json!({"name": "two"}))).await.unwrap();
    let (ws2, t3, p3) = (w2["workspace"].as_u64().unwrap(), w2["tab"].as_u64().unwrap(), w2["pane"].as_u64().unwrap());
    let p4 = a.request("pane.split", with(sh(), json!({"pane": p3, "direction": "down"}))).await.unwrap()["pane"].as_u64().unwrap();
    r.agent(&a, p1, "claude", "move-sess-1").await;
    b.request("events.subscribe", json!({})).await.unwrap();
    next_state(&mut b, T).await.expect("the initial state");
    let leaf = |n: &Value| n["pane"].clone();

    // A pane into another workspace's tab: its own tab closes, focus follows it.
    let reply = a.request("pane.move", json!({"pane": p1, "to_pane": p3, "direction": "right", "ratio": 0.4})).await.unwrap();
    assert_eq!((reply["workspace"].as_u64(), reply["tab"].as_u64()), (Some(ws2), Some(t3)), "{reply}");
    let s = next_state(&mut b, T).await.expect("a state event for the move");
    assert_eq!(tab_order(&s), vec![(json!("one"), vec![json!(t2)]), (json!("two"), vec![json!(t3)])]);
    let l = &s["workspaces"][1]["tabs"][0]["layout"];
    assert_eq!((l["axis"].clone(), leaf(&l["b"])), (json!("vertical"), json!(p4)), "{l}");
    assert_eq!((l["a"]["axis"].clone(), l["a"]["ratio"].clone(), l["a"]["id"].clone()), (json!("horizontal"), json!(0.4), reply["split"].clone()));
    assert_eq!((leaf(&l["a"]["a"]), leaf(&l["a"]["b"])), (json!(p3), json!(p1)));
    assert_eq!(s["focus"], json!({"workspace": ws2, "tab": t3, "pane": p1}));
    assert_eq!(s["workspaces"][0]["active_tab"], t2);
    assert_eq!(pane_of(&s, p1)["agent"]["session"], "move-sess-1", "the agent moved with its pane");
    assert!(s["workspaces"][0]["tabs"].as_array().unwrap().iter().all(|t| t["id"] != t1));

    // A whole tab, its split as it is, beside a pane in another tab; focus: false leaves focus.
    let t4r = a.request("tab.create", with(sh(), json!({"workspace": ws1}))).await.unwrap();
    let (t4, p5) = (t4r["tab"].as_u64().unwrap(), t4r["pane"].as_u64().unwrap());
    let p6 = a.request("pane.split", with(sh(), json!({"pane": p5, "direction": "right", "ratio": 0.7}))).await.unwrap()["pane"].as_u64().unwrap();
    a.input(p5, b"V=kept; echo shellpid=$$\r");
    let lines = wait_for_text(&a, p5, T, |l| l.iter().any(|l| output(l).starts_with("shellpid="))).await.unwrap();
    let pid = lines.iter().find_map(|l| output(l).strip_prefix("shellpid=")).unwrap().to_string();
    a.request("focus", json!({"pane": p1})).await.unwrap();
    while next_state(&mut b, Duration::from_millis(300)).await.is_some() {}
    a.request("tab.join", json!({"tab": t4, "to_pane": p2, "direction": "down", "focus": false})).await.unwrap();
    let s = next_state(&mut b, T).await.unwrap();
    assert_eq!(tab_order(&s)[0], (json!("one"), vec![json!(t2)]));
    let l = &s["workspaces"][0]["tabs"][0]["layout"];
    assert_eq!((l["axis"].clone(), leaf(&l["a"])), (json!("vertical"), json!(p2)), "{l}");
    assert_eq!((l["b"]["ratio"].clone(), leaf(&l["b"]["a"]), leaf(&l["b"]["b"])), (json!(0.7), json!(p5), json!(p6)), "the tab's split as it was");
    assert_eq!(s["focus"], json!({"workspace": ws2, "tab": t3, "pane": p1}), "focus stayed");

    // Within one tab: p4 goes to p1's left.
    a.request("pane.move", json!({"pane": p4, "to_pane": p1, "direction": "left"})).await.unwrap();
    let s = next_state(&mut b, T).await.unwrap();
    let l = &s["workspaces"][1]["tabs"][0]["layout"];
    assert_eq!((leaf(&l["a"]), l["axis"].clone(), leaf(&l["b"]["a"]), leaf(&l["b"]["b"])), (json!(p3), json!("horizontal"), json!(p4), json!(p1)), "{l}");
    assert_eq!(s["focus"]["pane"], p4);

    // The last tab of a workspace: the workspace stays, empty.
    a.request("tab.join", json!({"tab": t2, "to_pane": p3, "direction": "down", "focus": false})).await.unwrap();
    let s = next_state(&mut b, T).await.unwrap();
    assert_eq!(tab_order(&s), vec![(json!("one"), vec![]), (json!("two"), vec![json!(t3)])]);
    assert!(s["workspaces"][0]["active_tab"].is_null());
    assert_eq!(s["focus"], json!({"workspace": ws2, "tab": t3, "pane": p4}));
    assert_eq!(s["panes"].as_array().unwrap().len(), 6, "every pane still there");

    // Errors, and nothing moved by them.
    for (m, params, code) in [
        ("pane.move", json!({"pane": p1, "to_pane": p1}), "bad_request"),
        ("pane.move", json!({"pane": 999_999, "to_pane": p1}), "not_found"),
        ("pane.move", json!({"pane": p1, "to_pane": 999_999}), "not_found"),
        ("pane.move", json!({"pane": p1, "to_pane": p3, "direction": "sideways"}), "bad_request"),
        ("pane.move", json!({"pane": p1, "to_pane": p3, "focus": "yes"}), "bad_request"),
        ("pane.move", json!({"pane": p1}), "bad_request"),
        ("tab.join", json!({"tab": t3, "to_pane": p3}), "bad_request"),
        ("tab.join", json!({"tab": t1, "to_pane": p3}), "not_found"),
    ] {
        let e = a.request(m, params.clone()).await.unwrap_err().to_string();
        assert!(e.contains(code), "{m} {params}: {e}");
    }
    assert!(next_state(&mut b, Duration::from_millis(300)).await.is_none(), "errors send nothing");

    // The moved shell is the same one, with its state.
    a.input(p5, b"echo $V-$$\r");
    wait_for_text(&a, p5, T, |l| has_line(l, &format!("kept-{pid}"))).await.unwrap();

    // The saved layout follows, and a reboot brings the new arrangement back.
    r.wait_layout("with the moved panes", |l| {
        let ws = &l["model"]["workspaces"];
        ws[0]["tabs"].as_array().is_some_and(|t| t.is_empty()) && ws[1]["tabs"][0]["layout"]["b"]["b"]["pane"] == p1 && l["model"]["focus"]["pane"] == p4
    })
    .await;
    drop((a, b));
    r.reboot();
    let c = r.env.client().await;
    let s = c.request("state.get", json!({})).await.unwrap();
    assert_eq!(tab_order(&s).iter().map(|t| (t.0.clone(), t.1.len())).collect::<Vec<_>>(), vec![(json!("one"), 0), (json!("two"), 1)]);
    let l = &s["workspaces"][1]["tabs"][0]["layout"];
    let shape = |n: &Value| n["type"] == "split";
    assert!(shape(l) && shape(&l["a"]) && shape(&l["a"]["b"]) && shape(&l["a"]["b"]["b"]) && shape(&l["b"]), "{l}");
    assert_eq!(l["a"]["b"]["b"]["ratio"], 0.7);
    let (n1, n4) = (l["b"]["b"]["pane"].as_u64().unwrap(), l["b"]["a"]["pane"].as_u64().unwrap());
    assert_eq!(s["focus"]["pane"], n4, "focus came back");
    assert_eq!((pane_of(&s, n1)["restored"]["agent"].clone(), pane_of(&s, n1)["restored"]["session"].clone()), (json!("claude"), json!("move-sess-1")), "{s}");
    let deadline = Instant::now() + T;
    while !r.rec().contains("claude --resume=move-sess-1") {
        assert!(Instant::now() < deadline, "the moved agent was not resumed: {}", r.rec());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Upgrading from a serve that didn't keep agents across restarts (0.1.21): the adopted holder
/// knows no sessions, only layout.json does. They stay in the file while that kind of agent
/// still runs in the pane, and go where it doesn't.
#[tokio::test]
async fn an_adopting_serve_keeps_the_files_sessions_for_running_agents() {
    let mut r = RestoreEnv::new();
    let c = r.env.client().await;
    let w = c.request("workspace.create", sh()).await.unwrap();
    let (p, tab) = (w["pane"].as_u64().unwrap(), w["tab"].as_u64().unwrap());
    let q = c.request("pane.split", with(sh(), json!({"pane": p, "direction": "right"}))).await.unwrap()["pane"].as_u64().unwrap();
    // A "claude" that detection sees (no hook, so no session).
    let sleepy = r.env.dir.path().join("sleepy");
    std::fs::create_dir_all(&sleepy).unwrap();
    std::fs::write(sleepy.join("claude"), "sleep 120\n").unwrap();
    c.input(p, format!("sh '{}'\r", sleepy.join("claude").display()).as_bytes());
    wait_agent(&c, p, "a detected claude", |a| a["kind"] == "claude" && a["source"] == "detected").await;
    r.wait_layout("saved", |l| l["panes"].get(p.to_string()).is_some() && l["panes"].get(q.to_string()).is_some()).await;
    drop(c);

    // What a 0.1.21 serve left: sessions in the file for both panes, none in the holder.
    r.env.kill();
    let path = r.env.dir.path().join("data/layout.json");
    let mut l: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    l["panes"][p.to_string()]["agent"] = json!({"kind": "claude", "session": "hint-1"});
    l["panes"][q.to_string()]["agent"] = json!({"kind": "claude", "session": "hint-2"});
    std::fs::write(&path, l.to_string()).unwrap();
    r.start();
    let c = r.env.client().await;
    tokio::time::sleep(Duration::from_millis(5500)).await;
    // Any change saves the layout again.
    c.request("tab.rename", json!({"tab": tab, "title": "x"})).await.unwrap();
    let l = r
        .wait_layout("kept p's session, dropped q's", |l| l["model"]["workspaces"][0]["tabs"][0]["title"] == "x" && l["panes"][q.to_string()]["agent"].is_null())
        .await;
    assert_eq!(l["panes"][p.to_string()]["agent"], json!({"kind": "claude", "session": "hint-1"}), "{l}");
    // Once the agent leaves, so does its session.
    c.input(p, b"\x03");
    wait_agent(&c, p, "no agent", |a| a.is_null()).await;
    c.request("tab.rename", json!({"tab": tab, "title": "y"})).await.unwrap();
    r.wait_layout("dropped p's session", |l| l["model"]["workspaces"][0]["tabs"][0]["title"] == "y" && l["panes"][p.to_string()]["agent"].is_null()).await;
}

// ---- client commands against the wrong or a stuck instance ------------------------------

/// A daemon that accepts but never answers (stopped, wedged, exiting): `status`, `stop` and
/// `shutdown` give up after the client timeout and exit non-zero, and `shutdown` doesn't go
/// around it to the holder.
#[tokio::test]
async fn client_commands_fail_fast_against_a_daemon_that_never_answers() {
    let env = Env::new();
    let serve = env.daemon.as_ref().unwrap().id();
    let holder = holder_pid(&env);
    unsafe { libc::kill(serve as i32, libc::SIGSTOP) };
    for cmd in ["status", "stop", "shutdown"] {
        let started = Instant::now();
        let out = Command::new(test_bin())
            .args([cmd, "--runtime-dir"])
            .arg(env.path())
            .env("CLOTHOD_STATE_DIR", env.state())
            .env("CLOTHOD_RUNTIME_DIR", env.path())
            .env("CLOTHOD_CLIENT_TIMEOUT", "1")
            .output()
            .unwrap();
        let took = started.elapsed();
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(!out.status.success(), "{cmd} succeeded against a stopped daemon");
        assert!(err.contains("did not answer within 1 s"), "{cmd}: {err}");
        assert!(took < Duration::from_secs(5), "{cmd} took {took:?}");
    }
    assert!(clotho_proto::platform::process_alive(holder), "shutdown went around the daemon to the holder");
    unsafe { libc::kill(serve as i32, libc::SIGCONT) };
}

/// `clothod ps` shows the runtime dir a process really uses: one set only through
/// $CLOTHOD_RUNTIME_DIR (as clients and tests run `shutdown`, `bridge`, …) is that dir and
/// EXTRA, never the default.
#[tokio::test]
async fn ps_shows_a_runtime_dir_set_in_the_environment() {
    let env = Env::new();
    let mut bridge = Command::new(test_bin())
        .arg("bridge")
        .env("CLOTHOD_RUNTIME_DIR", env.path())
        .env("CLOTHOD_STATE_DIR", env.state())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid = bridge.id().to_string();
    let dir = env.path().display().to_string();
    let deadline = Instant::now() + T;
    let row = loop {
        let out = Command::new(test_bin()).arg("ps").env_remove("CLOTHOD_RUNTIME_DIR").output().unwrap();
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        if let Some(row) = text.lines().find(|l| l.split_whitespace().next() == Some(pid.as_str())) {
            break row.to_string();
        }
        assert!(Instant::now() < deadline, "bridge {pid} not in ps:\n{text}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert!(row.contains(" bridge ") && row.contains(&format!(" {dir} ")) && row.ends_with("EXTRA"), "{row}");
    drop(bridge.stdin.take());
    let _ = bridge.kill();
    let _ = bridge.wait();
}

/// `shutdown --forget` aimed at a test instance's dir, from a process that isn't ephemeral and
/// names no layout file (a client's cleanup), deletes no layout but its own: here the "user's"
/// layout in the state dir it would otherwise reach stays.
#[tokio::test]
async fn shutdown_forget_never_deletes_another_instances_layout() {
    let mut env = Env::new();
    let user_state = env.dir.path().join("user-state");
    std::fs::create_dir_all(&user_state).unwrap();
    let user_layout = user_state.join("layout.json");
    std::fs::write(&user_layout, r#"{"version":1,"host":"h","runtime_dir":"/default"}"#).unwrap();
    env.daemon.take();
    let out = Command::new(test_bin())
        .args(["shutdown", "--forget"])
        .env_remove("CLOTHOD_EPHEMERAL")
        .env_remove("CLOTHOD_LAYOUT_FILE")
        .env("CLOTHOD_RUNTIME_DIR", env.path())
        .env("CLOTHOD_STATE_DIR", &user_state)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(user_layout.exists(), "a test dir's shutdown --forget deleted another instance's layout");
}

// ---- git ---------------------------------------------------------------------------------

const GIT_SHA: &str = "0123456789abcdef0123456789abcdef01234567";

fn put(p: &std::path::Path, s: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, s).unwrap();
}

async fn pane_git(c: &Client, pane: u64) -> Value {
    let s = c.request("state.get", json!({})).await.unwrap();
    pane_of(&s, pane)["git"].clone()
}

async fn wait_git(c: &Client, pane: u64, what: &str, cond: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + T;
    loop {
        let g = pane_git(c, pane).await;
        if cond(&g) {
            return g;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}; git is {g}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Git info from files: a repo, a branch switch seen live (also as a `pane` event), detached,
/// the default branch, a linked worktree sharing the repo's PR lookup, cd out of the repo; PRs
/// from a stub gh, with its failures, cached and refreshed only while a client shows the pane.
#[tokio::test]
async fn panes_show_git_and_pull_requests() {
    let mut env = Env::empty();
    let root = env.dir.path().join("work");
    let main = root.join("proj");
    put(&main.join(".git/HEAD"), "ref: refs/heads/feature\n");
    // As a shell's cwd reads (macOS: /tmp is /private/tmp).
    let main = std::fs::canonicalize(&main).unwrap();
    put(&main.join(".git/config"), "[remote \"origin\"]\n\turl = git@github.com:ahmad/clotho.git\n");
    for b in ["feature", "nopr", "broken", "main"] {
        put(&main.join(".git/refs/heads").join(b), &format!("{GIT_SHA}\n"));
    }
    std::fs::create_dir_all(main.join("src")).unwrap();
    let calls = env.dir.path().join("gh.calls");
    let stub = env.dir.path().join("gh");
    put(
        &stub,
        &format!(
            r#"#!/bin/sh
echo "$*" >> '{}'
for a; do b=$a; done
case "$b" in
  feature) echo '{{"number": 42, "state": "OPEN", "isDraft": false, "url": "https://github.com/ahmad/clotho/pull/42", "title": "Fix the\u001b[31m login"}}' ;;
  broken) echo "error connecting to api.github.com" >&2; exit 1 ;;
  *) echo "no pull requests found for branch \"$b\"" >&2; exit 1 ;;
esac
"#,
            calls.display()
        ),
    );
    std::fs::set_permissions(&stub, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let n_calls = || std::fs::read_to_string(&calls).unwrap_or_default().lines().count();
    env.start_with(&test_bin(), &[("CLOTHOD_GH", &stub.display().to_string()), ("CLOTHOD_TEST_PR_REFRESH_MS", "1500")]);
    let c = env.client().await;
    let mut ev = env.client().await;
    let p = new_pane(&c, with(sh(), json!({"cwd": main.join("src").display().to_string()}))).await;
    assert!(c.hello["features"].as_array().unwrap().contains(&json!("git")));

    let g = wait_git(&c, p, "the PR", |g| g["pr"].is_object()).await;
    assert_eq!(
        (g["repo"].clone(), g["root"].clone(), g["remote"].clone(), g["branch"].clone(), g["head"].clone(), g["worktree"].clone(), g["pr_reason"].clone()),
        (json!("proj"), json!(main.display().to_string()), json!("ahmad/clotho"), json!("feature"), json!("0123456"), Value::Null, Value::Null)
    );
    assert_eq!(g["pr"], json!({"number": 42, "state": "open", "draft": false, "url": "https://github.com/ahmad/clotho/pull/42", "title": "Fix the[31m login"}));
    let first = std::fs::read_to_string(&calls).unwrap();
    assert_eq!(first.trim(), "pr view --repo ahmad/clotho --json number,state,isDraft,url,title -- feature");
    // Nobody shows the pane: no refresh, however long.
    tokio::time::sleep(Duration::from_millis(4000)).await;
    assert_eq!(n_calls(), 1, "refreshed without a client showing the pane");
    // A client shows it: refreshed, but at most once per interval.
    c.request("pane.subscribe", json!({"pane": p})).await.unwrap();
    let t0 = Instant::now();
    tokio::time::sleep(Duration::from_millis(4500)).await;
    let n = n_calls();
    let max = 2 + (t0.elapsed().as_millis() / 1500) as usize;
    assert!((2..=max).contains(&n), "{n} lookups in {:?} (at most {max})", t0.elapsed());
    c.request("pane.unsubscribe", json!({"pane": p})).await.unwrap();

    // A branch switch is seen within about a second, and sent as a pane event.
    ev.request("events.subscribe", json!({})).await.unwrap();
    put(&main.join(".git/HEAD"), "ref: refs/heads/nopr\n");
    let switched = Instant::now();
    let deadline = Instant::now() + T;
    loop {
        let f = tokio::time::timeout(deadline.saturating_duration_since(Instant::now()), ev.recv()).await.expect("no pane event").unwrap();
        if let Frame::Json(v) = f {
            if v["event"] == "pane" && v["data"]["id"] == p && v["data"]["git"]["branch"] == "nopr" {
                break;
            }
        }
    }
    assert!(switched.elapsed() < Duration::from_millis(2500), "took {:?}", switched.elapsed());
    wait_git(&c, p, "no PR for nopr", |g| g["pr_reason"] == "none" && g["pr"].is_null()).await;
    put(&main.join(".git/HEAD"), "ref: refs/heads/broken\n");
    wait_git(&c, p, "gh failing", |g| g["pr_reason"] == "gh_error").await;
    put(&main.join(".git/HEAD"), "ref: refs/heads/main\n");
    wait_git(&c, p, "the default branch", |g| g["branch"] == "main" && g["pr_reason"] == "default_branch").await;
    put(&main.join(".git/HEAD"), &format!("{GIT_SHA}\n"));
    wait_git(&c, p, "detached", |g| g["branch"].is_null() && g["head"] == "0123456" && g["pr_reason"] == "detached").await;
    // A commit moves the branch's ref, not HEAD: head follows.
    put(&main.join(".git/HEAD"), "ref: refs/heads/feature\n");
    put(&main.join(".git/refs/heads/feature"), "fedcba9876543210fedcba9876543210fedcba98\n");
    wait_git(&c, p, "the new commit", |g| g["head"] == "fedcba9" && g["pr"]["number"] == 42).await;

    // A linked worktree: same repo name, its own root and branch, the cached PR (no lookup).
    let before = n_calls();
    let wt = root.join("proj-fix");
    put(&main.join(".git/worktrees/fix/HEAD"), "ref: refs/heads/feature\n");
    put(&main.join(".git/worktrees/fix/commondir"), "../..\n");
    put(&wt.join(".git"), "gitdir: ../proj/.git/worktrees/fix\n");
    let wt = std::fs::canonicalize(&wt).unwrap();
    let q = new_pane(&c, with(sh(), json!({"cwd": wt.display().to_string()}))).await;
    let g = wait_git(&c, q, "the worktree", |g| g["pr"].is_object()).await;
    assert_eq!((g["repo"].clone(), g["root"].clone(), g["branch"].clone()), (json!("proj"), json!(wt.display().to_string()), json!("feature")));
    assert_eq!(g["worktree"], json!({"name": "fix", "path": "../proj-fix"}));
    assert_eq!(n_calls(), before, "the PR came from the cache");
    assert!(!std::fs::read_to_string(&calls).unwrap().contains(" main"), "the default branch is never looked up");

    // cd out of the repo.
    c.input(p, b"cd /\r");
    wait_git(&c, p, "no repo", |g| g.is_null()).await;
    assert!(!r_log_has(&env, "panicked"));
    drop(c);
    drop(ev);
    env.kill();

    // No gh at all: the reason says so.
    let plain = Env::new();
    let c = plain.client().await;
    let p = new_pane(&c, with(sh(), json!({"cwd": main.display().to_string()}))).await;
    wait_git(&c, p, "no gh", |g| g["pr_reason"] == "no_gh").await;
}

fn r_log_has(env: &Env, s: &str) -> bool {
    env.log().contains(s)
}

/// macOS: a serve started from an SSH session with nobody logged in at the Mac is stuck in that
/// session's launchd namespace. A `start` from the login session (the login unit at console
/// login) moves serve there, keeping the holder and its shells; one from anywhere else, or
/// finding serve already in the login session, leaves it alone. (Namespaces are faked, so this
/// runs everywhere.)
#[tokio::test]
async fn a_start_in_the_login_session_moves_a_stuck_serve() {
    let mut env = Env::empty();
    env.start_with(&test_bin(), &[("CLOTHOD_TEST_NAMESPACE", "Background")]);
    env.daemon.take(); // replaced below
    let c = env.client().await;
    assert_eq!(c.hello["namespace"], "Background");
    let (serve, holder) = (c.hello["pid"].clone(), c.hello["holder"]["pid"].clone());
    let (p, shell) = live_shell(&c).await;
    drop(c);
    let start = |ns: &str| {
        Command::new(test_bin())
            .args(["start", "--runtime-dir"])
            .arg(env.path())
            .env("CLOTHOD_STATE_DIR", env.state())
            .env("CLOTHOD_RUNTIME_DIR", env.path())
            .env("CLOTHOD_REGISTRY_DIR", env.dir.path().join("registry"))
            .env("CLOTHOD_CONFIG", env.dir.path().join("config.toml"))
            .env("CLOTHOD_TEST_NAMESPACE", ns)
            .output()
            .unwrap()
    };
    // From another SSH session: nothing to gain, left alone.
    let out = start("Background");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(env.client().await.hello["pid"], serve, "a start from elsewhere leaves it");
    // From the login session: serve moves; the holder and the shell stay.
    let out = start("Aqua");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(String::from_utf8_lossy(&out.stderr).contains("restarting it in this login session"), "{}", String::from_utf8_lossy(&out.stderr));
    let c = env.client().await;
    assert_ne!(c.hello["pid"], serve, "serve moved");
    assert_eq!(c.hello["namespace"], "Aqua");
    assert_eq!(c.hello["holder"]["pid"], holder, "the holder stays");
    assert_shell_alive(&c, p, &shell).await;
    // Now healthy: the next start from the login session adopts it.
    let moved = c.hello["pid"].clone();
    drop(c);
    let out = start("Aqua");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(env.client().await.hello["pid"], moved, "adopted");
}
