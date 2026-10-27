//! Soak test: hours of load on one (ephemeral) instance. Opt in with
//! `CLOTHOD_SOAK_SECS=3600 cargo test --release -p clothod --test soak -- --nocapture`.
//!
//! - 20 panes: 3 printing as fast as they can, the rest in bursts
//! - 3 subscribed clients, every frame checked for seq continuity
//! - every 5 s one client drops and resumes with have_seq (replay or snapshot)
//! - every 200 ms a byte typed into a `cat` pane, the echo timed (input-to-output latency)
//! - halfway: an in-place upgrade to another build under all of that
//! - every 10 s: RSS of serve and holder
//!
//! Prints a summary (and appends it to target/soak-<timestamp>.json).

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use clotho::{Client, Screen};
use clotho_proto::Frame;
use serde_json::{json, Value};

fn bin() -> String {
    std::env::var("CLOTHOD_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_clothod").into())
}

struct Instance {
    root: tempfile::TempDir,
    serve: Option<Child>,
}

impl Instance {
    fn dir(&self) -> PathBuf {
        self.root.path().join("run")
    }

    fn cmd(&self, exe: &str, args: &[&str]) -> Command {
        let mut c = Command::new(exe);
        c.args(args)
            .arg("--runtime-dir")
            .arg(self.dir())
            // exit: if this run dies, its clients vanish and the instance ends itself (with
            // busy panes, an idle timeout never would).
            .env("CLOTHOD_EPHEMERAL", "exit")
            .env("CLOTHOD_STATE_DIR", self.root.path().join("state"))
            .env("CLOTHOD_INSTALL_DIR", self.root.path().join("bin"))
            .env("CLOTHOD_REGISTRY_DIR", self.root.path().join("registry"));
        c
    }

    fn start(&mut self) {
        let log = std::fs::File::create(self.root.path().join("serve.log")).unwrap();
        let child = self.cmd(&bin(), &["serve"]).stdin(Stdio::null()).stdout(log.try_clone().unwrap()).stderr(log).spawn().unwrap();
        self.serve = Some(child);
        let deadline = Instant::now() + Duration::from_secs(15);
        while std::os::unix::net::UnixStream::connect(self.dir().join("clothod.sock")).is_err() {
            assert!(Instant::now() < deadline, "daemon did not start");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn pid(&self, name: &str) -> Option<u32> {
        std::fs::read_to_string(self.dir().join(name)).ok()?.trim().parse().ok()
    }
}

impl Drop for Instance {
    fn drop(&mut self) {
        let _ = self.cmd(&bin(), &["shutdown"]).output();
        if let Some(mut c) = self.serve.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn rss_kb(pid: u32) -> u64 {
    let out = Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().ok();
    out.and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok()).unwrap_or(0)
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

/// A subscribed client following every pane, draining its connection continuously in its own
/// task (Screen::apply panics on any seq gap). Stopping it returns (bytes seen, seq per pane).
struct Follower {
    stop: tokio::sync::oneshot::Sender<()>,
    task: tokio::task::JoinHandle<(u64, HashMap<u64, u64>)>,
}

impl Follower {
    async fn start(dir: &std::path::Path, panes: &[u64], have: Option<&HashMap<u64, u64>>, modes: &mut HashMap<String, u64>) -> Follower {
        let mut c = Client::connect(dir).await.unwrap();
        let mut screens: HashMap<u64, Screen> = HashMap::new();
        for &p in panes {
            let mut params = json!({"pane": p});
            if let Some(h) = have.and_then(|h| h.get(&p)) {
                params["have_seq"] = json!(h);
            }
            let r = c.request("pane.subscribe", params).await.unwrap();
            *modes.entry(r["mode"].as_str().unwrap().to_string()).or_default() += 1;
            // Replay continues at have_seq; every later frame must continue exactly there.
            let mut sc = Screen::new(p, r["cols"].as_u64().unwrap() as u16, r["rows"].as_u64().unwrap() as u16);
            sc.seq = r["seq"].as_u64().unwrap();
            screens.insert(p, sc);
        }
        let (stop, mut stopped) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let mut bytes = 0u64;
            loop {
                tokio::select! {
                    _ = &mut stopped => break,
                    f = c.recv() => {
                        let Some(f) = f else { break };
                        let pane = match &f {
                            Frame::Output { pane, data, .. } => { bytes += data.len() as u64; Some(*pane) }
                            Frame::Snapshot { pane, .. } => Some(*pane),
                            Frame::Json(v) => v["data"]["pane"].as_u64(),
                            _ => None,
                        };
                        if let Some(sc) = pane.and_then(|p| screens.get_mut(&p)) {
                            sc.apply(&f);
                        }
                    }
                }
            }
            (bytes, screens.into_iter().map(|(p, sc)| (p, sc.seq)).collect())
        });
        Follower { stop, task }
    }

    async fn stop(self) -> (u64, HashMap<u64, u64>) {
        let _ = self.stop.send(());
        self.task.await.expect("follower saw a seq gap or crashed")
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn soak() {
    let Some(secs) = std::env::var("CLOTHOD_SOAK_SECS").ok().and_then(|s| s.parse::<u64>().ok()) else {
        eprintln!("CLOTHOD_SOAK_SECS not set; skipping");
        return;
    };
    let total = Duration::from_secs(secs);
    let mut inst = Instance { root: tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap(), serve: None };
    inst.start();
    let dir = inst.dir();
    let mut ctl = Client::connect(&dir).await.unwrap();

    // Load: 3 firehoses, 16 bursty panes, 1 echo pane for latency.
    let mut panes = Vec::new();
    let spawn = |cmd: &str| json!({"command": ["/bin/sh", "-c", cmd], "cols": 120, "rows": 40});
    for _ in 0..3 {
        let r = ctl.request("workspace.create", spawn("yes 'firehose line 0123456789 abcdefghijklmnopqrstuvwxyz'")).await.unwrap();
        panes.push(r["pane"].as_u64().unwrap());
    }
    for i in 0..16 {
        let cmd = format!("i=0; while :; do i=$((i+1)); printf '\\033[1;3{c}mburst %d pane {i}\\033[0m\\n' $i; seq 1 200; sleep 0.{d}; done", c = i % 7, d = 2 + i % 7);
        let r = ctl.request("workspace.create", spawn(&cmd)).await.unwrap();
        panes.push(r["pane"].as_u64().unwrap());
    }
    let echo = ctl.request("workspace.create", spawn("stty raw -echo; exec cat")).await.unwrap()["pane"].as_u64().unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;

    let mut modes: HashMap<String, u64> = HashMap::new();
    let mut followers = Vec::new();
    for _ in 0..3 {
        followers.push(Follower::start(&dir, &panes, None, &mut modes).await);
    }
    // The latency client watches only the echo pane.
    let mut lat = Client::connect(&dir).await.unwrap();
    lat.request("pane.subscribe", json!({"pane": echo})).await.unwrap();

    let holder_pid = inst.pid("holder.pid").unwrap();
    let start = Instant::now();
    let mut latencies: Vec<f64> = Vec::new();
    let mut latencies_upgrade: Vec<f64> = Vec::new();
    let (mut max_rss_serve, mut max_rss_holder) = (0u64, 0u64);
    let mut rss_samples = Vec::new();
    let mut reconnects = 0u64;
    let mut upgraded = false;
    let mut upgrade_secs = 0.0;
    let mut last_rss = Instant::now() - Duration::from_secs(60);
    let mut last_reconnect = Instant::now();
    let mut total_bytes = 0u64;
    let mut n = 0u64;

    while start.elapsed() < total {
        n += 1;
        // Latency probe: one byte, wait for its echo.
        let marker = [b'a' + (n % 26) as u8];
        let t0 = Instant::now();
        lat.input(echo, &marker);
        let deadline = t0 + Duration::from_secs(10);
        let mut got = false;
        while Instant::now() < deadline {
            match tokio::time::timeout(Duration::from_millis(50), lat.recv()).await {
                Ok(Some(Frame::Output { data, .. })) if data.contains(&marker[0]) => {
                    got = true;
                    break;
                }
                Ok(Some(_)) | Err(_) => {}
                Ok(None) => break,
            }
        }
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        if got {
            if upgraded && upgrade_secs > 0.0 && start.elapsed().as_secs_f64() - upgrade_secs < 10.0 {
                latencies_upgrade.push(ms);
            } else {
                latencies.push(ms);
            }
        } else {
            latencies.push(10_000.0);
        }

        // Reconnect storm: replace the oldest follower, resuming from what it had.
        if last_reconnect.elapsed() >= Duration::from_secs(5) {
            last_reconnect = Instant::now();
            let old = followers.remove(0);
            let (bytes, had) = old.stop().await;
            total_bytes += bytes;
            followers.push(Follower::start(&dir, &panes, Some(&had), &mut modes).await);
            reconnects += 1;
        }

        // Halfway: upgrade serve and holder in place, under load.
        if !upgraded && start.elapsed() >= total / 2 {
            upgraded = true;
            upgrade_secs = start.elapsed().as_secs_f64();
            let v2 = inst.root.path().join("v2-clothod");
            let mut data = std::fs::read(bin()).unwrap();
            data.extend_from_slice(b"\0soak-upgrade\0");
            std::fs::write(&v2, data).unwrap();
            std::fs::set_permissions(&v2, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
            let t = Instant::now();
            let out = inst.cmd(v2.to_str().unwrap(), &["upgrade"]).output().unwrap();
            inst.serve.take(); // replaced; Drop uses shutdown
            assert!(out.status.success(), "upgrade under load: {}", String::from_utf8_lossy(&out.stderr));
            eprintln!("soak: in-place upgrade under load took {:?}", t.elapsed());
            assert_eq!(inst.pid("holder.pid"), Some(holder_pid), "same holder after the upgrade");
            // Everyone reconnects after a serve switch.
            let mut fresh = Vec::new();
            for f in followers.drain(..) {
                let (bytes, had) = f.stop().await;
                total_bytes += bytes;
                fresh.push(Follower::start(&dir, &panes, Some(&had), &mut modes).await);
            }
            followers = fresh;
            lat = Client::connect(&dir).await.unwrap();
            lat.request("pane.subscribe", json!({"pane": echo})).await.unwrap();
            ctl = Client::connect(&dir).await.unwrap();
        }

        if last_rss.elapsed() >= Duration::from_secs(10) {
            last_rss = Instant::now();
            let (s, h) = (inst.pid("clothod.pid").map(rss_kb).unwrap_or(0), rss_kb(holder_pid));
            max_rss_serve = max_rss_serve.max(s);
            max_rss_holder = max_rss_holder.max(h);
            rss_samples.push((start.elapsed().as_secs(), s, h));
            eprintln!("soak: {:>5}s rss serve {s} KiB holder {h} KiB, {reconnects} reconnects, {} probes", start.elapsed().as_secs(), latencies.len());
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    for f in followers.drain(..) {
        total_bytes += f.stop().await.0;
    }
    // The daemon's view: total output produced across panes.
    let state = ctl.request("state.get", json!({})).await.unwrap();
    let produced: u64 = state["panes"].as_array().unwrap().iter().map(|p| p["seq"].as_u64().unwrap_or(0)).sum();
    latencies.sort_by(|a, b| a.partial_cmp(b).unwrap());
    latencies_upgrade.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let elapsed = start.elapsed().as_secs_f64();
    let summary = json!({
        "platform": format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH),
        "seconds": elapsed.round(),
        "panes": panes.len() + 1,
        "followers": 3,
        "produced_bytes": produced,
        "produced_mb_per_s": (produced as f64 / elapsed / 1e6 * 100.0).round() / 100.0,
        "delivered_bytes_to_followers": total_bytes,
        "reconnects": reconnects,
        "resume_modes": modes,
        "latency_ms": {"p50": percentile(&latencies, 0.5), "p95": percentile(&latencies, 0.95), "p99": percentile(&latencies, 0.99), "max": latencies.last(), "probes": latencies.len()},
        "latency_after_upgrade_ms": {"p50": percentile(&latencies_upgrade, 0.5), "max": latencies_upgrade.last(), "probes": latencies_upgrade.len()},
        "max_rss_kib": {"serve": max_rss_serve, "holder": max_rss_holder},
        "rss_first_last_kib": {"first": rss_samples.first(), "last": rss_samples.last()},
        "upgraded_in_place_at_s": upgrade_secs.round(),
    });
    println!("SOAK SUMMARY {}", serde_json::to_string_pretty(&summary).unwrap());
    let out = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target").join(format!("soak-{}.json", chrono_free_stamp()));
    let _ = std::fs::write(out, serde_json::to_vec_pretty(&summary).unwrap());
    let _: Value = summary;
}

fn chrono_free_stamp() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}
