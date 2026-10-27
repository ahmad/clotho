//! `clotho`: a small test client for clothod. Attach to panes from a real terminal, script input,
//! inspect state, and exercise resume.

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use clotho::{Client, Screen};
use clotho_proto::Frame;
use serde_json::{json, Value};

const USAGE: &str = "usage: clotho [--runtime-dir DIR] [--host SSH-TARGET] <command>

commands:
  ls                          show workspaces, tabs, panes
  new [--name N] [--cwd D] [-- CMD ARGS...]
                              new workspace with one pane; prints the pane id
  tab <workspace> [-- CMD...] new tab in a workspace
  split <pane> [right|down|left|up] [-- CMD...]
  attach <pane>               attach this terminal (detach: Ctrl-\\)
  send <pane> <text>          type text (\\r, \\n, \\t, \\e and \\xNN escapes work)
  send <pane> [text] --key K  paste text, then press keys (enter, tab, esc, up, ctrl+c, f5...),
                              encoded for the pane's modes
  text <pane>                 print the pane's screen as the daemon sees it
  close <pane>                hang up a pane
  resume <pane> <have_seq>    subscribe with have_seq and report what comes back
  watch                       print events
  stop | shutdown             stop the daemon (shutdown also ends all shells)
  status                      versions, pids, executables
  probe | install             (with --host) show what the host has / install the bundled build
  upgrade                     (with --host) install the bundled build and switch the host's
                              daemon to it; shells are kept

The daemon is started on demand. With --host, everything runs on that machine over ssh
(docs/remote.md): clotho probes it, installs the right build from dist/ if missing, and talks to
`clothod bridge`. --remote-runtime-dir / --remote-install-dir isolate a test instance there.
$CLOTHO_SSH replaces `ssh -T` (e.g. to add -o options); $CLOTHO_DIST points at dist/.";

fn unescape(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 1 < b.len() {
            i += 1;
            match b[i] {
                b'r' => out.push(b'\r'),
                b'n' => out.push(b'\n'),
                b't' => out.push(b'\t'),
                b'e' => out.push(0x1b),
                b'\\' => out.push(b'\\'),
                b'x' if i + 2 < b.len() => {
                    if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                        out.push(v);
                        i += 2;
                    }
                }
                other => {
                    out.push(b'\\');
                    out.push(other);
                }
            }
        } else {
            out.push(b[i]);
        }
        i += 1;
    }
    out
}

/// Split args at `--`: (options, command).
fn split_command(args: &[String]) -> (Vec<String>, Option<Vec<String>>) {
    match args.iter().position(|a| a == "--") {
        Some(i) => (args[..i].to_vec(), Some(args[i + 1..].to_vec())),
        None => (args.to_vec(), None),
    }
}

fn opt(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn term_size() -> (u16, u16) {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(1, libc::TIOCGWINSZ as _, &mut ws) } == 0 && ws.ws_col > 0 {
        (ws.ws_col, ws.ws_row)
    } else {
        (80, 24)
    }
}

fn spawn_params(cmd: Option<Vec<String>>, cwd: Option<String>) -> Value {
    let (cols, rows) = term_size();
    let mut p = json!({"cols": cols, "rows": rows});
    if let Some(c) = cmd {
        p["command"] = json!(c);
    }
    if let Some(d) = cwd {
        p["cwd"] = json!(d);
    }
    p
}

fn take_opt(args: &mut Vec<String>, name: &str) -> Result<Option<String>> {
    match args.iter().position(|a| a == name) {
        Some(i) => {
            let v = args.get(i + 1).with_context(|| format!("{name} needs a value"))?.clone();
            args.drain(i..i + 2);
            Ok(Some(v))
        }
        None => Ok(None),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let dir: Option<PathBuf> = take_opt(&mut args, "--runtime-dir")?.map(PathBuf::from);
    let host = take_opt(&mut args, "--host")?;
    let remote_runtime = take_opt(&mut args, "--remote-runtime-dir")?;
    let remote_install = take_opt(&mut args, "--remote-install-dir")?;
    let dir = dir.unwrap_or_else(clotho::default_runtime_dir);
    let Some(cmd) = args.first().cloned() else {
        println!("{USAGE}");
        return Ok(());
    };
    let rest = &args[1..];
    if cmd == "-h" || cmd == "--help" || cmd == "help" {
        println!("{USAGE}");
        return Ok(());
    }

    // Remote: docs/remote.md (probe, install, bridge over ssh).
    let remote = match &host {
        Some(h) => {
            let mut r = clotho::remote::Remote::new(h)?;
            if let Some(d) = &remote_runtime {
                r = r.with_env("CLOTHOD_RUNTIME_DIR", d.as_str());
            }
            if let Some(d) = &remote_install {
                r = r.with_env("CLOTHOD_INSTALL_DIR", d.as_str());
            }
            Some(r)
        }
        None => None,
    };
    if let Some(r) = &remote {
        match cmd.as_str() {
            "probe" => {
                let p = r.probe().await?;
                let mut keys: Vec<_> = p.fields.iter().collect();
                keys.sort();
                for (k, v) in keys {
                    println!("{k}={v}");
                }
                return Ok(());
            }
            "upgrade" => {
                println!("running {}", r.upgrade().await?);
                return Ok(());
            }
            "install" | "stop" | "shutdown" | "status" => {
                let p = r.probe().await?;
                let path = r.ensure_installed_once(&p).await?;
                if cmd == "install" {
                    println!("{path}");
                    return Ok(());
                }
                let (code, out, err) = r.clothod(&path, &cmd).await?;
                print!("{out}");
                eprint!("{err}");
                std::process::exit(code.unwrap_or(1));
            }
            _ => {}
        }
    } else if cmd == "stop" || cmd == "shutdown" {
        let status = std::process::Command::new(clotho::clothod_binary()).arg(&cmd).arg("--runtime-dir").arg(&dir).status()?;
        std::process::exit(status.code().unwrap_or(1));
    }

    // Keep the ssh bridge process alive as long as the client.
    let mut _session_child = None;
    let mut c = match &remote {
        Some(r) => {
            let session = r.connect().await?;
            let warnings = session.stderr.lock().unwrap().clone();
            for l in warnings.lines().filter(|l| l.contains("warning")) {
                eprintln!("{}: {l}", r.host);
            }
            _session_child = Some(session.child);
            session.client
        }
        None => Client::connect_or_start(&dir).await?,
    };
    let pane_arg = |i: usize| -> Result<u64> { rest.get(i).context("missing pane id")?.parse().context("pane id must be a number") };

    match cmd.as_str() {
        "ls" => print_tree(&c.request("state.get", json!({})).await?),
        "new" => {
            let (opts, command) = split_command(rest);
            let mut p = spawn_params(command, opt(&opts, "--cwd"));
            if let Some(n) = opt(&opts, "--name") {
                p["name"] = json!(n);
            }
            let r = c.request("workspace.create", p).await?;
            println!("{}", r["pane"]);
        }
        "tab" => {
            let (opts, command) = split_command(rest);
            let ws: u64 = opts.first().context("missing workspace id")?.parse()?;
            let mut p = spawn_params(command, None);
            p["workspace"] = json!(ws);
            println!("{}", c.request("tab.create", p).await?["pane"]);
        }
        "split" => {
            let (opts, command) = split_command(rest);
            let pane: u64 = opts.first().context("missing pane id")?.parse()?;
            let mut p = spawn_params(command, None);
            p.as_object_mut().unwrap().remove("cols");
            p.as_object_mut().unwrap().remove("rows");
            p["pane"] = json!(pane);
            p["direction"] = json!(opts.get(1).map(String::as_str).unwrap_or("right"));
            println!("{}", c.request("pane.split", p).await?["pane"]);
        }
        "send" => {
            let pane = pane_arg(0)?;
            let mut keys = Vec::new();
            let mut text = None;
            let mut it = rest[1..].iter();
            while let Some(a) = it.next() {
                if a == "--key" {
                    keys.push(it.next().context("--key needs a key name")?.clone());
                } else {
                    text = Some(a.clone());
                }
            }
            if keys.is_empty() {
                let text = text.context("missing text")?;
                c.request("pane.input", json!({"pane": pane, "data": String::from_utf8_lossy(&unescape(&text))})).await?;
            } else {
                // Text is pasted, keys are encoded for the pane's modes (pane.keys).
                let mut p = json!({"pane": pane, "keys": keys});
                if let Some(t) = text {
                    p["text"] = json!(t);
                }
                c.request("pane.keys", p).await?;
            }
        }
        "text" => {
            let t = c.request("pane.text", json!({"pane": pane_arg(0)?})).await?;
            println!("# size {}x{} cursor {} seq {} modes {}", t["cols"], t["rows"], t["cursor"], t["seq"], t["modes"]);
            for l in t["lines"].as_array().into_iter().flatten() {
                println!("{}", l.as_str().unwrap_or(""));
            }
        }
        "close" => {
            c.request("pane.close", json!({"pane": pane_arg(0)?})).await?;
        }
        "resume" => {
            let pane = pane_arg(0)?;
            let have: u64 = rest.get(1).context("missing have_seq")?.parse()?;
            let r = c.request("pane.subscribe", json!({"pane": pane, "have_seq": have})).await?;
            println!("mode {} seq {} size {}x{}", r["mode"], r["seq"], r["cols"], r["rows"]);
            let deadline = tokio::time::Instant::now() + Duration::from_millis(300);
            let mut bytes = 0;
            while let Ok(Some(f)) = tokio::time::timeout_at(deadline, c.recv()).await {
                match f {
                    Frame::Output { seq, data, .. } => {
                        println!("OUTPUT seq {seq} len {}", data.len());
                        bytes += data.len();
                    }
                    Frame::Snapshot { seq, cols, rows, data, .. } => println!("SNAPSHOT seq {seq} {cols}x{rows} len {}", data.len()),
                    _ => {}
                }
            }
            println!("{bytes} output bytes");
        }
        "watch" => {
            c.request("events.subscribe", json!({})).await?;
            while let Some(f) = c.recv().await {
                if let Frame::Json(v) = f {
                    println!("{v}");
                }
            }
        }
        "attach" => attach(&mut c, pane_arg(0)?).await?,
        _ => bail!("unknown command `{cmd}`\n\n{USAGE}"),
    }
    Ok(())
}

fn print_tree(state: &Value) {
    let panes: std::collections::HashMap<u64, &Value> =
        state["panes"].as_array().into_iter().flatten().filter_map(|p| Some((p["id"].as_u64()?, p))).collect();
    fn node(n: &Value, panes: &std::collections::HashMap<u64, &Value>, depth: usize) {
        let pad = "  ".repeat(depth);
        if n["type"] == "pane" {
            let id = n["pane"].as_u64().unwrap_or(0);
            let p = panes.get(&id);
            let title = p.and_then(|p| p["title"].as_str()).unwrap_or("");
            let cwd = p.and_then(|p| p["cwd"].as_str()).unwrap_or("");
            let size = p.map(|p| format!("{}x{}", p["cols"], p["rows"])).unwrap_or_default();
            println!("{pad}pane {id}  {size}  {title}  {cwd}");
        } else {
            println!("{pad}split {} {} {:.2}", n["id"], n["axis"].as_str().unwrap_or(""), n["ratio"].as_f64().unwrap_or(0.5));
            node(&n["a"], panes, depth + 1);
            node(&n["b"], panes, depth + 1);
        }
    }
    for w in state["workspaces"].as_array().into_iter().flatten() {
        println!("workspace {} {}", w["id"], w["name"].as_str().unwrap_or(""));
        for t in w["tabs"].as_array().into_iter().flatten() {
            println!("  tab {} {}", t["id"], t["title"].as_str().unwrap_or(""));
            node(&t["layout"], &panes, 2);
        }
    }
}

struct RawMode(libc::termios);

impl RawMode {
    fn enter() -> Result<RawMode> {
        unsafe {
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut t) != 0 {
                bail!("stdin is not a terminal");
            }
            let saved = t;
            libc::cfmakeraw(&mut t);
            libc::tcsetattr(0, libc::TCSANOW, &t);
            Ok(RawMode(saved))
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(0, libc::TCSANOW, &self.0);
        }
        // Undo modes the pane may have turned on in our terminal.
        let mut out = std::io::stdout();
        let _ = out.write_all(b"\x1b[?1049l\x1b[0m\x1b[?25h\x1b[?1l\x1b>\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?1004l\x1b[r\r\n[detached]\r\n");
        let _ = out.flush();
    }
}

async fn attach(c: &mut Client, pane: u64) -> Result<()> {
    use tokio::io::AsyncReadExt;
    let (cols, rows) = term_size();
    c.request("pane.subscribe", json!({"pane": pane, "viewport": {"cols": cols, "rows": rows}})).await?;
    let _raw = RawMode::enter()?;
    let mut stdin = tokio::io::stdin();
    let mut winch = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;
    let mut buf = [0u8; 4096];
    let mut screen = Screen::new(pane, cols, rows);
    // Our terminal answers queries in the pane's output; the daemon already did. Drop those
    // answers so the application doesn't get them twice (see ReplyFilter).
    let mut filter = clotho::ReplyFilter::new();
    loop {
        let esc_timeout = async {
            if filter.has_pending() {
                tokio::time::sleep(Duration::from_millis(30)).await
            } else {
                std::future::pending::<()>().await
            }
        };
        tokio::select! {
            n = stdin.read(&mut buf) => {
                let n = n?;
                if n == 0 {
                    break;
                }
                // Ctrl-\ detaches.
                let (data, detach) = match buf[..n].iter().position(|&b| b == 0x1c) {
                    Some(i) => (&buf[..i], true),
                    None => (&buf[..n], false),
                };
                let forward = filter.input(data);
                if !forward.is_empty() {
                    c.input(pane, &forward);
                }
                if detach {
                    break;
                }
            }
            _ = esc_timeout => {
                let held = filter.flush();
                c.input(pane, &held);
            }
            _ = winch.recv() => {
                let (cols, rows) = term_size();
                c.request("pane.viewport", json!({"pane": pane, "cols": cols, "rows": rows})).await?;
            }
            f = c.recv() => {
                let Some(f) = f else { break };
                let mut out = std::io::stdout();
                match &f {
                    Frame::Snapshot { data, .. } | Frame::Output { data, .. } => {
                        filter.saw_output(data);
                        out.write_all(data)?;
                        out.flush()?;
                    }
                    Frame::Json(v) if v["event"] == "pane" && v["data"]["id"] == pane && !v["data"]["exited"].is_null() => {
                        screen.apply(&f);
                        break;
                    }
                    _ => {}
                }
                screen.apply(&f);
            }
        }
    }
    Ok(())
}
