use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clotho_proto::{platform, read_frame, write_frame, Frame};
use serde_json::json;
use tokio::net::UnixStream;

// mimalloc on Linux, the system allocator on macOS (clothod::alloc), counting live bytes for
// `debug.stats`.
#[global_allocator]
static GLOBAL: clothod::alloc::Counting = clothod::alloc::Counting(clothod::alloc::INNER);

const USAGE: &str = "usage: clothod <command> [--runtime-dir DIR]

commands:
  serve      run the daemon in the foreground (starts the PTY holder if needed)

Only the default runtime dir holds a persistent instance. Anything else (tests, experiments)
needs --ephemeral[=SECS|exit]: it ends itself, and removes its dir, after SECS (default 600)
with no clients and no panes, or when its last client disconnects (exit).

  start      start the daemon in the background unless it is running; wait until it accepts
  stop       stop the daemon; shells keep running in the holder
  shutdown   stop the daemon, the holder and every shell
  holder     run the PTY holder in the foreground (normally started by `serve`)
  status     print what is running: versions, pids, executables, sockets
             --print-socket: print only the client socket path (use this, don't compute it)
  upgrade    install this binary, then switch the running daemon to it (stop + start, shells
             are kept), retrying if something else restarts an older one; verifies the result
  install    copy this binary to the versioned install dir (unless there) and print its path
             --print-path: only print the path    --prune: also delete versions no daemon runs
  bridge     start the daemon if needed, then relay stdin/stdout to its socket (for
             `ssh host clothod bridge`). Exit codes as for `start`.
  report <state> [--agent K] [--message M] [--session S] | --claude-hook | --codex-notify JSON
             tell the daemon what the agent in this pane does (for agent hooks; silent, exit 0)
  hooks print|install|uninstall claude|codex, hooks status
             agent status hooks in ~/.claude/settings.json / ~/.codex/config.toml
  ps         list every clothod process of this user (role, runtime dir, build, pid, age);
             anything not belonging to the default instance is marked extra
  build-id [FILE]
             print the install id (<version>-<hash>) of FILE, or of this binary
  version    print the version and build id

The runtime dir (sockets, locks) defaults to $CLOTHOD_RUNTIME_DIR or the OS default.";

fn main() {
    clothod::alloc::tune();
    match run() {
        Ok(()) => {}
        Err(e) => {
            eprintln!("clothod: {e:#}");
            let incompatible = format!("{e:#}").contains(clothod::daemon::INCOMPATIBLE);
            std::process::exit(if incompatible { clothod::daemon::EXIT_INCOMPATIBLE } else { 1 });
        }
    }
}

fn run() -> Result<()> {
    // Agent hooks: no runtime, no argument checks, never an error (see agents::report).
    let all: Vec<String> = std::env::args().skip(1).collect();
    if all.first().map(String::as_str) == Some("report") {
        std::process::exit(clothod::agents::report(&all[1..]));
    }
    if all.first().map(String::as_str) == Some("hooks") {
        let dir = platform::runtime_dir();
        // Hooks call <base>/current/clothod; make sure there is one (without adding a version).
        return clothod::agents::hooks(&all[1..], || {
            if platform::install_base().join("current").join("clothod").is_file() {
                Ok(())
            } else {
                install(&dir, false, false)
            }
        });
    }
    let mut args = std::env::args().skip(1);
    let mut command = None;
    let mut dir: Option<PathBuf> = None;
    let mut flags = Vec::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--runtime-dir" => dir = Some(args.next().context("--runtime-dir needs a value")?.into()),
            "--print-path" | "--prune" | "--quiet" | "--print-socket" | "--print-builds" => flags.push(a),
            e if e == "--ephemeral" || e.starts_with("--ephemeral=") => {
                // Inherited by everything this starts (serve, holder); see platform::ephemeral.
                let v = e.strip_prefix("--ephemeral=").unwrap_or("1");
                std::env::set_var("CLOTHOD_EPHEMERAL", v);
            }
            "--resume-fd" => {
                flags.push(a);
                flags.push(args.next().context("--resume-fd needs a value")?);
            }
            _ if command.as_deref() == Some("build-id") => flags.push(a),
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(());
            }
            _ if command.is_none() => command = Some(a),
            _ => bail!("unexpected argument `{a}`\n\n{USAGE}"),
        }
    }
    let dir = dir.unwrap_or_else(platform::runtime_dir);
    let rt = tokio::runtime::Runtime::new()?;
    match command.as_deref().unwrap_or("serve") {
        "serve" => {
            platform::check_instance_allowed(&dir).map_err(anyhow::Error::msg)?;
            rt.block_on(clothod::daemon::serve(dir))
        }
        "holder" => {
            let resume = flags.iter().position(|f| f == "--resume-fd").and_then(|i| flags.get(i + 1)).and_then(|v| v.parse().ok());
            rt.block_on(clotho_holder::run(&dir, resume))
        }
        "holder-formats" => {
            // State formats this build's holder can resume from (in-place holder upgrades).
            // Tests can pretend otherwise with a file in the runtime dir.
            match std::fs::read_to_string(dir.join("CLOTHOD_TEST_HOLDER_FORMATS")) {
                Ok(f) => println!("{}", f.trim()),
                Err(_) => println!("{}", clotho_holder::STATE_FORMAT),
            }
            Ok(())
        }
        "start" => rt.block_on(start(dir, false)),
        "bridge" => rt.block_on(bridge(dir)),
        "build-id" => {
            let file = flags.iter().find(|f| !f.starts_with("--")).map(PathBuf::from);
            println!("{}", build_id(&file.map_or_else(std::env::current_exe, Ok)?)?);
            Ok(())
        }
        "stop" => rt.block_on(call(dir, "daemon.stop")),
        "shutdown" => rt.block_on(call(dir, "daemon.shutdown")),
        "status" if flags.iter().any(|f| f == "--print-socket") => {
            // Clients ask instead of computing the path themselves.
            println!("{}", clothod::daemon::socket_path(&dir).display());
            Ok(())
        }
        "status" if flags.iter().any(|f| f == "--print-builds") => {
            // Machine-readable: what actually runs (serve=<build>, holder=<build>,
            // holder_outdated=true|false); nothing if no daemon answers.
            if let Some((_, serve, holder, capable)) = rt.block_on(running_builds(&dir)) {
                println!("serve={serve}\nholder={holder}\nholder_can_upgrade={capable}\nholder_outdated={}", holder != serve);
            }
            Ok(())
        }
        "status" => rt.block_on(status(dir)),
        "install" => install(&dir, flags.iter().any(|f| f == "--print-path"), flags.iter().any(|f| f == "--prune")),
        "upgrade" => rt.block_on(upgrade(dir)),
        "ps" => {
            ps();
            Ok(())
        }
        "version" => {
            println!("clothod {} ({})", env!("CARGO_PKG_VERSION"), build_id(&std::env::current_exe()?)?);
            Ok(())
        }
        other => bail!("unknown command `{other}`\n\n{USAGE}"),
    }
}

async fn connect(dir: &std::path::Path) -> std::io::Result<UnixStream> {
    UnixStream::connect(clothod::daemon::socket_path(dir)).await
}

async fn start(dir: PathBuf, quiet: bool) -> Result<()> {
    platform::check_socket_path(&clothod::daemon::socket_path(&dir)).map_err(anyhow::Error::msg)?;
    platform::check_instance_allowed(&dir).map_err(anyhow::Error::msg)?;
    if connect(&dir).await.is_ok() {
        if !quiet {
            println!("clothod already running ({})", clothod::daemon::socket_path(&dir).display());
        }
        return Ok(());
    }
    // Running, but its socket was deleted (temp cleaner): have it rebind instead of starting a
    // second daemon.
    if let Some(pid) = clotho_proto::listen::live_instance(&platform::log_dir(&dir).join("clothod.live")) {
        clotho_proto::listen::poke(pid);
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if connect(&dir).await.is_ok() {
                if !quiet {
                    println!("clothod running, socket restored ({})", clothod::daemon::socket_path(&dir).display());
                }
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        bail!("clothod (pid {pid}) is running but its socket {} did not come back", clothod::daemon::socket_path(&dir).display());
    }
    if let Some(warning) = platform::session_survival_warning() {
        eprintln!("clothod: warning: {warning}");
    }
    let log_dir = platform::log_dir(&dir);
    platform::ensure_private_dir(&log_dir)?;
    let log_path = log_dir.join("clothod.log");
    let log = std::fs::OpenOptions::new().create(true).append(true).open(&log_path)?;
    let mut cmd = clothod::session_independent_command(&std::env::current_exe()?);
    cmd.arg("serve").arg("--runtime-dir").arg(&dir);
    let log_start = std::fs::metadata(&log_path).map(|m| m.len()).unwrap_or(0);
    clothod::detach(&mut cmd, log)?;
    // With a systemd unit, the command we run is systemd-run, which exits once the unit started
    // (and the daemon's output goes to the journal, not our log).
    let via_systemd = platform::needs_systemd_unit();
    let mut child = cmd.spawn().context("starting clothod")?;
    let mut launcher_done = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if connect(&dir).await.is_ok() {
            if !quiet {
                println!("clothod started ({})", clothod::daemon::socket_path(&dir).display());
            }
            return Ok(());
        }
        if launcher_done {
            tokio::time::sleep(Duration::from_millis(25)).await;
            continue;
        }
        if let Some(status) = child.try_wait()? {
            if via_systemd && status.success() {
                launcher_done = true;
                continue;
            }
            // It exited: show why (its error is the last thing it logged).
            let log = std::fs::read(&log_path).unwrap_or_default();
            let tail = String::from_utf8_lossy(&log[(log_start as usize).min(log.len())..]).trim().to_string();
            if status.code() == Some(clothod::daemon::EXIT_INCOMPATIBLE) {
                eprintln!("{tail}");
                std::process::exit(clothod::daemon::EXIT_INCOMPATIBLE);
            }
            bail!("clothod exited ({status}):\n{tail}");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    bail!("clothod did not start; see {}", log_path.display())
}

async fn call(dir: PathBuf, method: &str) -> Result<()> {
    let mut s = match connect(&dir).await {
        Ok(s) => s,
        Err(_) if method == "daemon.shutdown" => return shutdown_holder(&dir).await,
        Err(_) => {
            println!("clothod is not running");
            return Ok(());
        }
    };
    let hello = json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "clothod-cli"}});
    write_frame(&mut s, &Frame::Json(hello)).await?;
    write_frame(&mut s, &Frame::Json(json!({"id": 2, "method": method}))).await?;
    while let Some(f) = read_frame(&mut s).await? {
        if let Frame::Json(v) = f {
            if v["id"] == 2 {
                if let Some(e) = v.get("error") {
                    bail!("{method}: {e}");
                }
                break;
            }
        }
    }
    // Wait for the daemon (and on shutdown the holder) to go away, so a `start` right after
    // gets a fresh instance rather than a dying one.
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && connect(&dir).await.is_ok() {
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    if method == "daemon.shutdown" {
        wait_holder_gone(&dir).await;
    }
    println!("{method}: done");
    Ok(())
}

async fn status(dir: PathBuf) -> Result<()> {
    let sock = clothod::daemon::socket_path(&dir);
    println!("this binary: clothod {} ({})", env!("CARGO_PKG_VERSION"), std::env::current_exe()?.display());
    if let Ok(mut s) = connect(&dir).await {
        let hello = json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "clothod-status"}});
        write_frame(&mut s, &Frame::Json(hello)).await?;
        if let Some(Frame::Json(v)) = read_frame(&mut s).await? {
            let r = &v["result"];
            let h = &r["holder"];
            println!("daemon: running, pid {}, version {}, {} ({})", r["pid"], r["version"].as_str().unwrap_or("?"), r["exe"].as_str().unwrap_or("?"), sock.display());
            println!(
                "holder: running, pid {}, version {}, holder protocol {}, {}",
                h["pid"],
                h["version"].as_str().unwrap_or("?"),
                h["protocol"],
                h["exe"].as_str().unwrap_or("?")
            );
            println!("instance: {}", r["instance"].as_str().unwrap_or("?"));
            return Ok(());
        }
    }
    let running = false;
    // Connecting to the holder would look like a new logic process; check its lock instead.
    let holder = std::fs::File::open(dir.join("holder.lock"))
        .map(|f| nix::fcntl::Flock::lock(f, nix::fcntl::FlockArg::LockSharedNonblock).is_err())
        .unwrap_or(false);
    println!("daemon: {} ({})", if running { "running" } else { "stopped" }, sock.display());
    match (holder, std::fs::read_to_string(dir.join("holder.pid")).ok().and_then(|p| p.trim().parse::<u32>().ok())) {
        (true, Some(pid)) => {
            let exe = platform::process_exe(pid).map(|p| p.display().to_string()).unwrap_or_else(|| "?".into());
            println!("holder: running, pid {pid}, {exe}");
        }
        (true, None) => println!("holder: running"),
        (false, _) => println!("holder: stopped"),
    }
    Ok(())
}

/// `shutdown` with no logic process: tell the holder directly (shells end with it).
async fn shutdown_holder(dir: &std::path::Path) -> Result<()> {
    use clotho_proto::holder::{ToHolder, HOLDER_PROTOCOL};
    let Ok(mut s) = UnixStream::connect(clotho_holder::socket_path(dir)).await else {
        println!("clothod is not running");
        return Ok(());
    };
    for msg in [ToHolder::Hello { protocol: HOLDER_PROTOCOL, version: Some(env!("CARGO_PKG_VERSION").into()) }, ToHolder::Shutdown] {
        write_frame(&mut s, &Frame::Json(serde_json::to_value(msg)?)).await?;
    }
    wait_holder_gone(dir).await;
    println!("daemon.shutdown: holder stopped");
    Ok(())
}

/// FNV-1a over the file: identifies a build, so two builds with one version number get
/// separate install dirs. Not a security measure.
fn build_id(path: &std::path::Path) -> Result<String> {
    Ok(platform::build_id(path)?)
}

/// `clothod install`: put this binary at `<install_base>/<version>-<hash>/clothod` (atomically)
/// and print that path. Clients install their bundled binary this way and run it from there,
/// so replacing the bundle never touches a running holder's executable.
fn install(dir: &std::path::Path, print_only: bool, prune: bool) -> Result<()> {
    let target = install_path(dir, print_only, prune)?;
    println!("{}", target.display());
    Ok(())
}

/// Installed version dirs (`<version>-<hash>`) under `base`.
fn installed_versions(base: &std::path::Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(base)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n != "current" && !n.starts_with('.') && base.join(n).join("clothod").is_file())
        .collect();
    v.sort();
    v
}

/// Copy this binary to `<base>/<id>/clothod` (atomically) unless it is there. Doesn't touch
/// `current` or other versions.
fn place_self(base: &std::path::Path) -> Result<(String, PathBuf)> {
    let exe = std::env::current_exe()?;
    let id = build_id(&exe)?;
    let target = base.join(&id).join("clothod");
    if !target.exists() {
        std::fs::create_dir_all(base.join(&id))?;
        let tmp = base.join(&id).join(format!(".clothod.{}", std::process::id()));
        std::fs::copy(&exe, &tmp)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
        std::fs::rename(&tmp, &target)?;
    }
    Ok((id, target))
}

/// Delete every version dir except `keep_id` and any build a live clothod process of this user
/// runs (which only a full restart can retire).
fn remove_other_versions(base: &std::path::Path, keep_id: &str) {
    // Only a serve or holder keeps a version: it may exec its binary again. Anything else (an
    // app's `bridge` that reconnected from the old build mid-upgrade, a `report` from a hook)
    // runs fine from a deleted file, and keeping its version would leave two installed.
    let daemons = || -> Vec<PathBuf> {
        clothod_processes()
            .into_iter()
            .filter(|p| p.args.get(1).is_some_and(|a| a == "serve" || a == "holder"))
            .filter_map(|p| p.exe)
            .collect()
    };
    // A daemon that just switched can still show its old executable for a moment.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let live = daemons();
        let mut kept = false;
        for v in installed_versions(base) {
            if v == keep_id {
                continue;
            }
            let bin = base.join(&v).join("clothod");
            if live.iter().any(|l| same_file(l, &bin)) {
                kept = true;
                continue;
            }
            let _ = std::fs::remove_dir_all(base.join(&v));
        }
        if !kept || std::time::Instant::now() >= deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// `clothod install`: one version per machine. Installs this build only if nothing is
/// installed yet (or it already is); a different installed version means `upgrade`, which
/// switches the running daemon and removes the old one.
fn install_path(_dir: &std::path::Path, print_only: bool, prune: bool) -> Result<PathBuf> {
    let base = platform::install_base();
    let id = build_id(&std::env::current_exe()?)?;
    let target = base.join(&id).join("clothod");
    if print_only {
        return Ok(target);
    }
    let others: Vec<String> = installed_versions(&base).into_iter().filter(|v| *v != id).collect();
    if !target.exists() && !others.is_empty() {
        bail!(
            "clothod {} is installed; installing {id} as well would leave two versions. \
             Use `clothod upgrade` to switch to this build (shells are kept).",
            others.join(", ")
        );
    }
    place_self(&base)?;
    point_current_at(&base, &id)?;
    if prune {
        remove_other_versions(&base, &id);
    }
    Ok(target)
}

/// `clothod bridge`: the remote end of `ssh host clothod bridge`. Makes sure the daemon runs,
/// then copies bytes between stdio and the daemon socket until either side closes. Nothing but
/// protocol bytes may ever go to stdout.
async fn bridge(dir: PathBuf) -> Result<()> {
    start(dir.clone(), true).await?;
    let sock = connect(&dir).await.context("connecting to clothod")?;
    let (mut srd, mut swr) = sock.into_split();
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let up = async {
        let r = tokio::io::copy(&mut stdin, &mut swr).await;
        let _ = tokio::io::AsyncWriteExt::shutdown(&mut swr).await;
        r
    };
    let down = async {
        let r = tokio::io::copy(&mut srd, &mut stdout).await;
        let _ = tokio::io::AsyncWriteExt::flush(&mut stdout).await;
        r
    };
    // Either direction ending ends the bridge: the client hung up, or the daemon went away.
    // Exit right here: the runtime would otherwise wait at shutdown for the blocking thread that
    // reads stdin, keeping ssh (and the client's view of the link) alive after the daemon died.
    let daemon_gone = tokio::select! {
        _ = up => false,
        _ = down => true,
    };
    if daemon_gone {
        eprintln!("clothod bridge: the daemon closed the connection");
        std::process::exit(EXIT_DAEMON_GONE);
    }
    std::process::exit(0);
}

/// `clothod bridge` exit code when the daemon side closed (the client should reconnect).
const EXIT_DAEMON_GONE: i32 = 2;

/// Until the holder's lock is free (it exited), up to 5 s.
async fn wait_holder_gone(dir: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let held = std::fs::File::open(dir.join("holder.lock"))
            .map(|f| nix::fcntl::Flock::lock(f, nix::fcntl::FlockArg::LockSharedNonblock).is_err())
            .unwrap_or(false);
        if !held {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// `<base>/current` -> `<id>` (relative, replaced atomically): a path that always runs the
/// newest installed build. Agent hooks call `<base>/current/clothod report`.
fn point_current_at(base: &std::path::Path, id: &str) -> Result<()> {
    let link = base.join("current");
    if std::fs::read_link(&link).ok().as_deref() == Some(std::path::Path::new(id)) {
        return Ok(());
    }
    let tmp = base.join(format!(".current.{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    std::os::unix::fs::symlink(id, &tmp)?;
    std::fs::rename(&tmp, &link)?;
    Ok(())
}


fn same_file(a: &std::path::Path, b: &std::path::Path) -> bool {
    a.canonicalize().ok().zip(b.canonicalize().ok()).is_some_and(|(x, y)| x == y)
}

/// The daemon's own build and its holder's, from `hello`: (serve exe, serve build, holder
/// build, holder can upgrade in place).
async fn running_builds(dir: &std::path::Path) -> Option<(PathBuf, String, String, bool)> {
    let mut s = connect(dir).await.ok()?;
    let hello = json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "clothod-upgrade"}});
    write_frame(&mut s, &Frame::Json(hello)).await.ok()?;
    let v = match tokio::time::timeout(Duration::from_secs(5), read_frame(&mut s)).await {
        Ok(Ok(Some(Frame::Json(v)))) => v,
        _ => return None,
    };
    let r = &v["result"];
    Some((
        PathBuf::from(r["exe"].as_str()?),
        r["build"].as_str().unwrap_or_default().to_string(),
        r["holder"]["build"].as_str().unwrap_or_default().to_string(),
        r["holder"]["can_upgrade"].as_bool().unwrap_or(false),
    ))
}

/// Make `exe` the running logic process (its start upgrades a capable holder to it), retrying
/// if something else revives another build. Returns whether the holder runs `exe` too.
async fn switch_to(dir: &std::path::Path, exe: &std::path::Path) -> Result<bool> {
    let want = build_id(exe)?;
    // Count only stops of another build: a daemon that holds the lock but is still starting
    // (slow on a loaded machine) isn't reachable yet, so wait for it rather than give up.
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    let mut attempt = 0;
    while attempt < 5 && std::time::Instant::now() < deadline {
        match running_builds(dir).await {
            Some((cur, _, holder, _)) if same_file(&cur, exe) => {
                // Started by us (or already right): the holder followed unless it can't.
                return Ok(holder == want);
            }
            Some((cur, ..)) => {
                attempt += 1;
                eprintln!("clothod: switching from {} (attempt {attempt})", cur.display());
                call(dir.to_path_buf(), "daemon.stop").await?;
            }
            None => {}
        }
        // Start the new build right away to keep the window for a racing old `start` small.
        let status = std::process::Command::new(exe).arg("start").arg("--runtime-dir").arg(dir).stdout(std::process::Stdio::null()).status()?;
        if status.code() == Some(clothod::daemon::EXIT_INCOMPATIBLE) {
            std::process::exit(clothod::daemon::EXIT_INCOMPATIBLE);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    bail!("another clothod keeps getting started; {} is installed but not running", exe.display())
}

/// `clothod upgrade`: move this machine to this build, all or nothing. Install it next to the
/// current one, switch serve (whose start upgrades a capable holder in place, shells kept),
/// verify, then make it the only installed version. On failure, go back to the old build and
/// remove the new one.
async fn upgrade(dir: PathBuf) -> Result<()> {
    let base = platform::install_base();
    let had = installed_versions(&base);
    let old_current = std::fs::read_link(base.join("current")).ok();
    let (id, target) = place_self(&base)?;
    let before = running_builds(&dir).await;

    let result: Result<bool> = async {
        let holder_followed = switch_to(&dir, &target).await?;
        if dir.join("CLOTHOD_TEST_FAIL_UPGRADE").exists() {
            bail!("injected failure (test)");
        }
        // Under load the new serve can take a while to answer (recovering every pane, moving
        // the holder in place), so wait for the switch to settle before judging it.
        let deadline = std::time::Instant::now() + Duration::from_secs(60);
        let after = loop {
            let after = running_builds(&dir).await;
            let settled = after.as_ref().is_some_and(|a| !same_file(&a.0, &target) || !a.3 || a.2 == id);
            if settled || std::time::Instant::now() >= deadline {
                break after;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        };
        let after = after.context("daemon not reachable after the switch")?;
        anyhow::ensure!(same_file(&after.0, &target), "serve runs {}, not {}", after.0.display(), target.display());
        if after.3 {
            anyhow::ensure!(after.2 == id, "holder runs {}, not {id}", after.2);
        }
        Ok(holder_followed && after.2 == id)
    }
    .await;

    match result {
        Ok(holder_current) => {
            point_current_at(&base, &id)?;
            remove_other_versions(&base, &id);
            println!("running {}", target.display());
            if !holder_current {
                if let Some((_, _, hb, false)) = running_builds(&dir).await {
                    eprintln!(
                        "clothod: the holder still runs {hb}, which predates in-place upgrades; it keeps all shells \
                         alive, and a one-time full restart (`clothod shutdown`, ends every shell) moves it to {id}"
                    );
                }
            }
            Ok(())
        }
        Err(e) => {
            // Roll back: the old serve again (its start moves a capable holder back), old
            // `current`, and the new build gone unless it was there before.
            if let Some((old_exe, ..)) = &before {
                if old_exe.exists() && !same_file(old_exe, &target) {
                    let _ = switch_to(&dir, old_exe).await;
                }
            }
            if let Some(old) = &old_current {
                let _ = point_current_at(&base, &old.to_string_lossy());
            }
            if !had.contains(&id) {
                let _ = std::fs::remove_dir_all(base.join(&id));
            }
            bail!("upgrade to {id} failed, rolled back: {e:#}")
        }
    }
}

/// This user's clothod processes (by executable name).
fn clothod_processes() -> Vec<platform::ProcInfo> {
    platform::own_processes()
        .into_iter()
        .filter(|p| p.exe.as_ref().and_then(|e| e.file_name()).is_some_and(|n| n.to_string_lossy().starts_with("clothod")))
        .collect()
}

/// What an instance's daemon says about its own processes: pid -> build, from `hello`
/// (serve's own build, and the holder's as it reported it). Unlike hashing the file on disk,
/// this is right after the file was replaced or the holder upgraded in place.
fn reported_builds(runtime: &std::path::Path) -> HashMap<u32, String> {
    use std::io::{Read, Write};
    let mut out = HashMap::new();
    let Ok(mut s) = std::os::unix::net::UnixStream::connect(runtime.join("clothod.sock")) else { return out };
    let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
    let hello = json!({"id": 1, "method": "hello", "params": {"protocol": clotho_proto::PROTOCOL, "client": "clothod-ps"}});
    if s.write_all(&Frame::Json(hello).encode()).is_err() {
        return out;
    }
    let mut len = [0u8; 4];
    if s.read_exact(&mut len).is_err() {
        return out;
    }
    let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
    if s.read_exact(&mut body).is_err() {
        return out;
    }
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body[1..]) {
        let r = &v["result"];
        if let (Some(pid), Some(b)) = (r["pid"].as_u64(), r["build"].as_str()) {
            out.insert(pid as u32, b.to_string());
        }
        if let (Some(pid), Some(b)) = (r["holder"]["pid"].as_u64(), r["holder"]["build"].as_str()) {
            out.insert(pid as u32, b.to_string());
        }
    }
    out
}

/// `clothod ps`.
fn ps() {
    let default = platform::default_runtime_dir();
    let mut reported: HashMap<PathBuf, HashMap<u32, String>> = HashMap::new();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let mut rows = Vec::new();
    for p in clothod_processes() {
        let role = p.args.get(1).cloned().unwrap_or_default();
        if role == "ps" || role.is_empty() {
            continue;
        }
        let runtime = p
            .args
            .iter()
            .position(|a| a == "--runtime-dir")
            .and_then(|i| p.args.get(i + 1))
            .map(PathBuf::from)
            .unwrap_or_else(|| default.clone());
        let exe = p.exe.clone().unwrap_or_default();
        let known = reported.entry(runtime.clone()).or_insert_with(|| reported_builds(&runtime));
        let build = match known.get(&p.pid) {
            Some(b) => b.clone(),
            // Nobody answered for it: all we know is where it lives (an install dir names the
            // build) or what the file holds now.
            None => match exe.parent().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().into_owned()) {
                Some(dir) if dir.contains('-') && dir.chars().next().is_some_and(|c| c.is_ascii_digit()) => format!("{dir} (on disk)"),
                _ => build_id(&exe).map(|b| format!("?-{} (on disk)", b.rsplit('-').next().unwrap_or(""))).unwrap_or_else(|_| "(deleted)".into()),
            },
        };
        let age = p.started.map(|s| now.saturating_sub(s)).unwrap_or(0);
        let age = if age >= 3600 { format!("{}h{:02}m", age / 3600, age % 3600 / 60) } else { format!("{}m{:02}s", age / 60, age % 60) };
        let extra = if runtime == default { "" } else { "  EXTRA" };
        rows.push(format!("{:>7}  {:<7} {:>7}  {:<30} {}  {}{extra}", p.pid, role, age, build, runtime.display(), exe.display()));
    }
    println!("{:>7}  {:<7} {:>7}  {:<30} {}  {}", "PID", "ROLE", "AGE", "BUILD", "RUNTIME", "EXE");
    for r in rows {
        println!("{r}");
    }
}
