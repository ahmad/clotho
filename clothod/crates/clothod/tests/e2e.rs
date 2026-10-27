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
    }
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

#[tokio::test]
async fn detach_reattach_gets_the_exact_screen() {
    let env = Env::new();
    let mut c1 = env.client().await;
    let pane = new_pane(&c1, sh()).await;
    let (r, mut s1) = subscribe(&mut c1, pane, None).await;
    assert_eq!(r["mode"], "snapshot");

    c1.input(pane, b"echo before-app\r");
    wait_for_text(&c1, pane, T, |l| l.iter().any(|l| l == "before-app")).await.unwrap();
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
    wait_for_text(&c2, pane, T, |l| l.iter().any(|l| l == "before-app") && l.iter().all(|l| !l.contains("placed") && !l.contains("line two"))).await.unwrap();
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
    wait_for_text(&c, p1, T, |l| l.iter().any(|l| l == "alive-42")).await.unwrap();
    sync(&mut c, &mut s1b).await.unwrap();
    assert_matches_daemon(&c, &s1b).await;
    let (lines, _) = daemon_text(&c, p1).await;
    assert!(lines.iter().any(|l| l.contains("one")), "primary screen from before the restart: {lines:?}");

    c.input(p2, b"go\r");
    wait_for_text(&c, p2, T, |l| l.iter().any(|l| l == "during-down")).await.unwrap();
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
    wait_for_text(&c, p, Duration::from_secs(2), |l| l.iter().any(|l| l == "printed-while-down")).await.unwrap();
}

#[tokio::test]
async fn restart_after_heavy_output_uses_the_pushed_snapshot() {
    let mut env = Env::new();
    let mut c = env.client().await;
    let p = new_pane(&c, sh()).await;
    // ~6 MB: more than the 4 MiB buffer, so recovery has to start from a pushed snapshot.
    c.input(p, b"i=0; while [ $i -lt 60000 ]; do echo \"line $i $(printf '%0.sx' 1 2 3 4 5 6 7 8 9 0)xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"; i=$((i+1)); done; echo done-$((1+1))\r");
    wait_for_text(&c, p, Duration::from_secs(120), |l| l.iter().any(|l| l == "done-2")).await.unwrap();
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
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "first")).await.unwrap();
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
    wait_for_text(&reference, p, T, |l| l.iter().any(|l| l == "missed-5")).await.unwrap();
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
    wait_for_text(&reference, p, T, |l| l.iter().any(|l| l == "big-done")).await.unwrap();
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
async fn last_typer_sets_the_size() {
    let env = Env::new();
    let a = env.client().await;
    let p = new_pane(&a, sh()).await;
    let b = env.client().await;
    a.request("pane.subscribe", json!({"pane": p, "viewport": {"cols": 100, "rows": 30}})).await.unwrap();
    let r = b.request("pane.subscribe", json!({"pane": p, "viewport": {"cols": 60, "rows": 20}})).await.unwrap();
    // Nobody typed yet: the latest subscriber's viewport wins.
    assert_eq!((r["cols"].as_u64(), r["rows"].as_u64()), (Some(60), Some(20)));
    a.input(p, b"stty size\r");
    wait_for_text(&a, p, T, |l| l.iter().any(|l| l == "30 100")).await.unwrap();
    b.input(p, b"stty size\r");
    wait_for_text(&b, p, T, |l| l.iter().any(|l| l == "20 60")).await.unwrap();
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
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "vim-exited")).await.unwrap();
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
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "kept-23")).await.unwrap();

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
    wait_for_text(&c, p, T, |l| l.iter().any(|x| x == "y-2")).await.unwrap();
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
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "still-42")).await.unwrap();
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
    wait_for_text(&c, p, T, |l| l.iter().any(|x| x == "z-5")).await.unwrap();
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
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "survived-2")).await.unwrap();
    drop(c);

    // The holder's socket went too. A restarted serve finds the holder through the state dir
    // and has it rebind, instead of starting a second holder.
    env.kill();
    env.start();
    let c = env.client().await;
    assert_eq!(c.hello["instance"], instance, "same holder after serve restart");
    c.input(p, b"echo again-$Z\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "again-survived-2")).await.unwrap();
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
        wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "fresh")).await.unwrap();
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
        r#"sh -c '"{b}" report running --agent claude --session s1; sleep 0.3; "{b}" report waiting --message "May I run ls?"; read x; "{b}" report done; sleep 60'"#
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

    // Acknowledging clears attention (state unchanged).
    c.request("agent.ack", json!({"pane": p})).await.unwrap();
    let a = pane_agent(&c, p).await;
    assert_eq!((a["state"].clone(), a["attention"].clone()), (json!("waiting"), json!(false)));

    // Answering (input) moves it on; `done` sets attention again; input clears it.
    c.input(p, b"y\r");
    let a = wait_agent(&c, p, "done", |a| a["state"] == "done").await;
    assert_eq!(a["attention"], true);
    c.input(p, b"\r");
    wait_agent(&c, p, "attention cleared by input", |a| a["attention"] == false).await;

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
    assert_eq!(s["hooks"]["PermissionRequest"], orig["hooks"]["PermissionRequest"], "PermissionRequest is not ours to touch");
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
    wait_for_text(&c, p, T, |l| l.iter().any(|x| x == "u-2")).await.unwrap();
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

    let v2 = upgraded_copy(&env);
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
    assert_eq!(c.hello["instance"], instance, "same holder");
    c.input(p, b"echo $U\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "kept-9")).await.unwrap();
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
    let lines = wait_for_text(c, p, T, |l| l.iter().any(|l| l.starts_with("shellpid="))).await.unwrap();
    let pid = lines.iter().find_map(|l| l.strip_prefix("shellpid=")).unwrap().to_string();
    (p, pid)
}

async fn assert_shell_alive(c: &Client, p: u64, pid: &str) {
    c.input(p, b"echo $V-$$\r");
    let want = format!("alive-42-{pid}");
    wait_for_text(c, p, T, |l| l.iter().any(|l| *l == want)).await.unwrap();
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
    wait_for_text(&c, p2, T, |l| l.iter().any(|l| l == "fresh")).await.unwrap();
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
