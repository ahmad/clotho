//! End-to-end tests against a real remote host over SSH (docs/remote.md).
//!
//! Set `CLOTHO_TEST_SSH_HOST` (e.g. `ahmad@devbox`) to run them; without it they are skipped.
//! They need `dist/` (scripts/dist.sh), and use their own runtime and install dirs on the host
//! (`/tmp/clt-<tag>`), so they don't touch the host's real clothod.

use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use clotho::remote::{sq, Remote, Session};
use clotho::{wait_for_text, Client, Screen};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const T: Duration = Duration::from_secs(20);

struct Host {
    r: Remote,
    runtime: String,
    install: String,
}

fn host() -> Option<Host> {
    let h = std::env::var("CLOTHO_TEST_SSH_HOST").ok().filter(|h| !h.is_empty())?;
    // Unique per test: tests run in parallel and each one's Drop deletes its dirs.
    static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tag = format!("{:x}-{n}-{:x}", std::process::id(), rand_seed() as u64 & 0xffffff);
    let runtime = format!("/tmp/clt-{tag}");
    let install = format!("/tmp/clt-{tag}-bin");
    let mut r = Remote::new(&h).expect("dist/ (run scripts/dist.sh)");
    r.ssh.extend(["-o".into(), "BatchMode=yes".into()]);
    let r = r
        .with_env("CLOTHOD_RUNTIME_DIR", runtime.as_str())
        .with_env("CLOTHOD_INSTALL_DIR", install.as_str())
        // Temporary instance: ends itself if a run dies before Drop cleans up.
        .with_env("CLOTHOD_EPHEMERAL", "120");
    Some(Host { r, runtime, install })
}

fn rand_seed() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
}

impl Drop for Host {
    fn drop(&mut self) {
        // Stop everything this test started there and remove its dirs.
        let script = format!(
            "for b in {i}/*/clothod; do [ -x \"$b\" ] && env CLOTHOD_RUNTIME_DIR={rt} \"$b\" shutdown >/dev/null 2>&1 && break; done; rm -rf {rt} {i}",
            rt = sq(&self.runtime),
            i = sq(&self.install)
        );
        let _ = std::process::Command::new(&self.r.ssh[0]).args(&self.r.ssh[1..]).arg(&self.r.host).arg(script).status();
    }
}

macro_rules! need_host {
    () => {
        match host() {
            Some(h) => h,
            None => {
                eprintln!("CLOTHO_TEST_SSH_HOST not set; skipping");
                return;
            }
        }
    };
}

fn sh() -> Value {
    json!({"command": ["/bin/sh"], "env": {"PS1": "$ ", "ENV": ""}, "cols": 80, "rows": 24})
}

async fn daemon_seq(c: &Client, pane: u64) -> u64 {
    c.request("pane.text", json!({"pane": pane})).await.unwrap()["seq"].as_u64().unwrap()
}

async fn daemon_text(c: &Client, pane: u64) -> Vec<String> {
    let t = c.request("pane.text", json!({"pane": pane})).await.unwrap();
    t["lines"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_string()).collect()
}

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
        tokio::time::sleep(Duration::from_millis(200)).await;
        if daemon_seq(c, screen.pane).await == screen.seq {
            return Ok(());
        }
    }
}

async fn subscribe(c: &mut Client, pane: u64, have: Option<u64>) -> (Value, Screen) {
    let mut p = json!({"pane": pane});
    if let Some(h) = have {
        p["have_seq"] = json!(h);
    }
    let r = c.request("pane.subscribe", p).await.unwrap();
    let mut s = Screen::new(pane, r["cols"].as_u64().unwrap() as u16, r["rows"].as_u64().unwrap() as u16);
    s.seq = r["seq"].as_u64().unwrap();
    (r, s)
}

async fn new_pane(c: &Client) -> u64 {
    c.request("workspace.create", sh()).await.unwrap()["pane"].as_u64().unwrap()
}

/// Wait until a line starting with `prefix` is followed by a fresh prompt (match the last line
/// a command prints, or the command line itself if it prints nothing).
async fn ran(c: &Client, pane: u64, prefix: &str) {
    wait_for_text(c, pane, T, |l| l.iter().position(|x| x.starts_with(prefix)).is_some_and(|i| l.get(i + 1).is_some_and(|n| n == "$")))
        .await
        .unwrap();
}

/// install id as `clothod build-id` computes it.
fn build_id(version: &str, data: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{version}-{:012x}", h >> 16)
}

/// A dist/ whose build for `platform` differs (appended bytes): a new install id, like an
/// upgraded release.
fn upgraded_dist(r: &Remote, platform: &str) -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let manifest: Value = serde_json::from_slice(&std::fs::read(r.dist().join("manifest.json")).unwrap()).unwrap();
    let b = &manifest["builds"][platform];
    let mut data = std::fs::read(r.dist().join(b["file"].as_str().unwrap())).unwrap();
    data.extend_from_slice(b"\0clotho-test-upgrade\0");
    let version = manifest["version"].as_str().unwrap();
    let id = build_id(version, &data);
    std::fs::create_dir_all(tmp.path().join(platform)).unwrap();
    std::fs::write(tmp.path().join(platform).join("clothod"), &data).unwrap();
    let m = json!({"version": version, "builds": {platform: {"target": b["target"], "id": id, "size": data.len(), "file": format!("{platform}/clothod")}}});
    std::fs::write(tmp.path().join("manifest.json"), serde_json::to_vec(&m).unwrap()).unwrap();
    tmp
}

#[tokio::test]
async fn install_from_scratch_upgrade_and_incompatible_holder() {
    let h = need_host!();
    let probe = h.r.probe().await.unwrap();
    assert!(probe.installed().is_empty(), "clean install dir: {probe:?}");
    assert!(!probe.daemon_running());

    // Fresh install, first session.
    let Session { client: c, path: v1, .. } = h.r.connect().await.unwrap();
    assert!(v1.starts_with(&h.install), "{v1}");
    let probe = h.r.probe().await.unwrap();
    assert_eq!(probe.installed().len(), 1);
    assert!(probe.daemon_running());
    let p = new_pane(&c).await;
    c.input(p, b"V=kept-$((40+2))\r");
    ran(&c, p, "$ V=").await;
    let before = daemon_text(&c, p).await;

    // Upgrade to a new build: all or nothing, the holder moves in place, one version remains,
    // even with the app's session (a `clothod bridge` of the old build) still attached.
    let old_session = c;
    let holder_pid = h.r.probe().await.unwrap().get("holder_pid").to_string();
    let dist2 = upgraded_dist(&h.r, &probe.platform());
    let mut r2 = h.r.clone();
    r2.dist = dist2.path().to_path_buf();
    let b2 = r2.build_for(&r2.probe().await.unwrap()).unwrap();
    // Like an app: whenever its connection drops (the upgrade stops the old serve), it
    // reconnects right away with the old build's bridge, which can still be running when
    // the upgrade removes old versions.
    let reconnector = {
        let (r, v1) = (h.r.clone(), v1.clone());
        let lp = format!("version >/dev/null; end=$(( $(date +%s) + 12 )); while [ $(date +%s) -lt $end ]; do sleep 2 | {} bridge >/dev/null 2>&1; sleep 0.05; done", sq(&v1));
        tokio::spawn(async move { r.clothod(&v1, &lp).await })
    };
    tokio::time::sleep(Duration::from_secs(1)).await;
    let v2 = r2.upgrade().await.unwrap();
    reconnector.await.unwrap().unwrap();
    assert_ne!(v1, v2);
    let probe = r2.probe().await.unwrap();
    assert_eq!(probe.installed(), vec![b2.id.as_str()], "exactly one version on the host");
    drop(old_session);
    assert_eq!(probe.get("current"), b2.id);
    assert_eq!(probe.get("holder_pid"), holder_pid, "same holder process");
    let Session { client: c, .. } = r2.connect().await.unwrap();
    assert_eq!(c.hello["exe"], v2, "new logic process");
    assert_eq!(c.hello["holder"]["build"], b2.id, "holder upgraded in place");
    assert_eq!(c.hello["holder_outdated"], false);
    assert_eq!(daemon_text(&c, p).await, before, "screen kept across the upgrade");
    c.input(p, b"echo $V\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "kept-42")).await.unwrap();
    drop(c);

    // A build that can't drive the running holder: clear error, shells untouched.
    let rt = &h.runtime;
    let (code, _, err) = h.r.clothod(&v2, &format!("stop; printf 99 > {}/CLOTHOD_TEST_HOLDER_PROTOCOL", sq(rt))).await.unwrap();
    assert_eq!(code, Some(0), "{err}");
    let e = r2.bridge(&v2).await.err().expect("bridge must refuse").to_string();
    assert!(e.contains("restart sessions to finish upgrading") && e.contains("holder protocol 99"), "{e}");
    let (code, _, _) = h.r.clothod(&v2, &format!("version; rm {}/CLOTHOD_TEST_HOLDER_PROTOCOL", sq(rt))).await.unwrap();
    assert_eq!(code, Some(0));
    let Session { client: c, .. } = r2.bridge(&v2).await.unwrap();
    c.input(p, b"echo still-$V\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "still-kept-42")).await.unwrap();
}

#[tokio::test]
async fn killing_ssh_mid_session_then_resuming() {
    let h = need_host!();
    let Session { client: mut c, child: mut ssh, path, .. } = h.r.connect().await.unwrap();
    let p = new_pane(&c).await;
    let (_, mut s) = subscribe(&mut c, p, Some(0)).await;
    c.input(p, b"echo one\r");
    ran(&c, p, "one").await;
    sync(&mut c, &mut s).await.unwrap();

    // The link dies (laptop lid, network change): kill ssh outright.
    ssh.kill().await.unwrap();
    drop(c);

    // Output keeps coming while nobody is connected.
    let Session { client: other, .. } = h.r.bridge(&path).await.unwrap();
    other.input(p, b"for i in 1 2 3; do echo while-away-$i; done\r");
    ran(&other, p, "while-away-3").await;
    drop(other);

    // Reconnect and resume from what we had: just the missed bytes.
    let Session { client: mut c, .. } = h.r.bridge(&path).await.unwrap();
    let (r, mut resumed) = subscribe(&mut c, p, Some(s.seq)).await;
    assert_eq!(r["mode"], "replay");
    resumed.vt = s.vt;
    sync(&mut c, &mut resumed).await.unwrap();
    assert_eq!(resumed.text(), daemon_text(&c, p).await);
    assert!(resumed.text().iter().any(|l| l == "while-away-3"));
    assert_eq!(resumed.snapshots, 0);
}

#[tokio::test]
async fn shells_survive_the_ssh_session_ending() {
    let h = need_host!();
    let Session { client: c, child: mut ssh, path, .. } = h.r.connect().await.unwrap();
    let p = new_pane(&c).await;
    c.input(p, b"W=alive-$((7*6)); sleep 2; echo slept\r");
    drop(c);
    // Close our end and wait for ssh (and with it the remote session) to finish.
    let status = tokio::time::timeout(T, ssh.wait()).await.unwrap().unwrap();
    assert!(status.success() || status.code().is_some());

    // The daemon was started from that session; it and the shell must outlive it.
    let probe = h.r.probe().await.unwrap();
    assert!(probe.daemon_running(), "{probe:?}");
    let pid = probe.get("daemon_pid").to_string();
    // Not tied to the ended session: on Linux the daemon is in its own session (setsid).
    // Not tied to the ended session: the daemon was started with setsid, so it leads its own
    // process group, unlike the ssh session's shell (portable: macOS ps has no `sid`).
    let (_, out, _) = h.r.clothod(&path, &format!("version >/dev/null; ps -o pgid= -p {pid}; ps -o pgid= -p $$")).await.unwrap();
    let pgids: Vec<&str> = out.split_whitespace().collect();
    assert_eq!(pgids.len(), 2, "{out}");
    assert_eq!(pgids[0], pid, "daemon leads its own session: {out}");
    assert_ne!(pgids[0], pgids[1], "daemon shares the ssh session's group: {out}");
    let Session { client: c, .. } = h.r.bridge(&path).await.unwrap();
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "slept")).await.unwrap();
    c.input(p, b"echo $W\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "alive-42")).await.unwrap();
}

/// Move bytes in random small pieces with random delays: a slow, jittery link.
async fn throttled<R: AsyncReadExt + Unpin, W: AsyncWriteExt + Unpin>(mut r: R, mut w: W, mut seed: u64) {
    let mut buf = vec![0u8; 512];
    loop {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let want = 1 + (seed % 300) as usize;
        let n = match r.read(&mut buf[..want]).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if w.write_all(&buf[..n]).await.is_err() || w.flush().await.is_err() {
            break;
        }
        if seed % 4 == 0 {
            tokio::time::sleep(Duration::from_millis(seed % 7)).await;
        }
    }
    let _ = w.shutdown().await;
}

#[tokio::test]
async fn slow_flaky_link_keeps_order_and_resumes() {
    let h = need_host!();
    let Session { client: c, path, .. } = h.r.connect().await.unwrap();
    let p = new_pane(&c).await;
    drop(c);

    // Client <-> throttled pipe <-> ssh.
    let (mut ssh, out, inp, _) = h.r.bridge_raw(&path).unwrap();
    let (near, far) = tokio::io::duplex(1 << 16);
    let (far_rd, far_wr) = tokio::io::split(far);
    tokio::spawn(throttled(out, far_wr, 0x9e37));
    tokio::spawn(throttled(far_rd, inp, 0x79b9));
    let (near_rd, near_wr) = tokio::io::split(near);
    let mut c = Client::over(near_rd, near_wr).await.unwrap();
    let (_, mut s) = subscribe(&mut c, p, Some(0)).await;
    c.input(p, b"seq 1 3000; echo seq-done\r");
    ran(&c, p, "seq-done").await;
    // Screen::apply asserts every OUTPUT frame continues exactly where the last one ended.
    sync(&mut c, &mut s).await.unwrap();
    assert_eq!(s.text(), daemon_text(&c, p).await);

    // The link drops in the middle of a burst of output.
    c.input(p, b"seq 1 40000; echo burst-done\r");
    tokio::time::sleep(Duration::from_millis(300)).await;
    ssh.kill().await.unwrap();
    drop(c);
    let Session { client: mut c, .. } = h.r.bridge(&path).await.unwrap();
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "burst-done")).await.unwrap();
    let (r, mut resumed) = subscribe(&mut c, p, Some(s.seq)).await;
    assert!(r["mode"] == "replay" || r["mode"] == "snapshot", "{r}");
    if r["mode"] == "replay" {
        resumed.vt = s.vt;
    }
    sync(&mut c, &mut resumed).await.unwrap();
    assert_eq!(resumed.text(), daemon_text(&c, p).await);
}

/// The remote daemon dies under an active bridge: the bridge must end the SSH session at once
/// (not wait for a heartbeat), and reconnecting gets the same holder and shells back.
#[tokio::test]
async fn bridge_exits_when_the_daemon_dies_and_reconnect_resumes() {
    let h = need_host!();
    let Session { client: c, child: mut ssh, path, .. } = h.r.connect().await.unwrap();
    let instance = c.hello["instance"].clone();
    let p = new_pane(&c).await;
    c.input(p, b"K=back-$((2*21))\r");
    ran(&c, p, "$ K=").await;
    let serve = c.hello["pid"].as_u64().unwrap();

    let (code, _, err) = h.r.clothod(&path, &format!("version >/dev/null; kill -9 {serve}")).await.unwrap();
    assert_eq!(code, Some(0), "{err}");
    let t0 = Instant::now();
    let status = tokio::time::timeout(Duration::from_secs(5), ssh.wait()).await.expect("ssh did not end").unwrap();
    assert!(t0.elapsed() < Duration::from_secs(1), "bridge took {:?} to exit", t0.elapsed());
    assert_eq!(status.code(), Some(2), "bridge exit code");
    // The client sees the end of the stream too.
    let mut c = c;
    let end = tokio::time::timeout(Duration::from_secs(2), async { while c.recv().await.is_some() {} }).await;
    assert!(end.is_ok(), "client stream did not end");

    let Session { client: c, .. } = h.r.connect().await.unwrap();
    assert_eq!(c.hello["instance"], instance, "same holder");
    assert_ne!(c.hello["pid"].as_u64().unwrap(), serve, "new logic process");
    c.input(p, b"echo $K\r");
    wait_for_text(&c, p, T, |l| l.iter().any(|l| l == "back-42")).await.unwrap();
}

