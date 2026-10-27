//! Reference implementation of docs/remote.md: probe a host over SSH, install the right clothod
//! build if it is missing, and run `clothod bridge` to get a [`Client`] over the SSH channel.
//! Uses the system `ssh`, so `~/.ssh/config`, agents and ControlMaster all apply.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};

use crate::Client;

/// docs/remote.md, step 1. Keep in sync with the spec.
pub const PROBE_SCRIPT: &str = r#"echo "clothod-probe=1"
os=$(uname -s); arch=$(uname -m)
case "$os" in Linux) os=linux ;; Darwin) os=macos ;; *) os=$(echo "$os" | tr 'A-Z' 'a-z') ;; esac
case "$arch" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; esac
echo "os=$os"
echo "arch=$arch"
if [ -n "${CLOTHOD_INSTALL_DIR:-}" ]; then base=$CLOTHOD_INSTALL_DIR
elif [ "$os" = macos ]; then base="$HOME/Library/Application Support/clothod/bin"
else base="${XDG_DATA_HOME:-$HOME/.local/share}/clothod/bin"; fi
echo "base=$base"
installed=""
for d in "$base"/*/; do n=$(basename "$d"); [ "$n" != current ] && [ -x "${d}clothod" ] && installed="$installed $n"; done
echo "installed=${installed# }"
fallback="${TMPDIR:-/tmp}/clothod-bin-$(id -u)"
echo "fallback_base=$fallback"
installed=""
for d in "$fallback"/*/; do [ -x "${d}clothod" ] && installed="$installed $(basename "$d")"; done
echo "fallback_installed=${installed# }"
if [ -n "${CLOTHOD_RUNTIME_DIR:-}" ]; then rt=$CLOTHOD_RUNTIME_DIR
elif [ "$os" = macos ]; then rt="$(getconf DARWIN_USER_TEMP_DIR)clothod"
else rt="/tmp/clothod-$(id -u)"; fi
cur=$(readlink "$base/current" 2>/dev/null)
echo "current=$cur"
echo "runtime=$rt"
pid=$(cat "$rt/clothod.pid" 2>/dev/null)
if [ -S "$rt/clothod.sock" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  echo "daemon=running"
  echo "daemon_pid=$pid"
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || ps -o comm= -p "$pid" 2>/dev/null)
  echo "daemon_exe=${exe% (deleted)}"
  [ -x "$base/$cur/clothod" ] && echo "daemon_build=$("$base/$cur/clothod" status --print-builds 2>/dev/null | sed -n 's/^serve=//p')"
else
  echo "daemon=stopped"
fi
hpid=$(cat "$rt/holder.pid" 2>/dev/null)
if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
  echo "holder_pid=$hpid"
  hexe=$(readlink "/proc/$hpid/exe" 2>/dev/null || ps -o comm= -p "$hpid" 2>/dev/null)
  echo "holder_exe=${hexe% (deleted)}"
  [ -x "$base/$cur/clothod" ] && echo "holder_build=$("$base/$cur/clothod" status --print-builds 2>/dev/null | sed -n 's/^holder=//p')"
fi
if mkdir -p "$base" 2>/dev/null && [ -w "$base" ]; then echo "writable=yes"; else echo "writable=no"; fi
"#;

/// docs/remote.md, step 2: `sh -c INSTALL_SCRIPT sh <id> <base>` with the binary on stdin.
pub const INSTALL_SCRIPT: &str = r#"set -u
id=$1; base=$2
d="$base/$id"
t="$d/.clothod.$$.tmp"
mkdir -p "$d" 2>/dev/null || { echo "clothod-install: cannot create $d" >&2; exit 5; }
trap 'rm -f "$t"' EXIT
cat > "$t" || { echo "clothod-install: cannot write $t (disk full or read-only?)" >&2; exit 5; }
chmod 755 "$t" || exit 5
got=$("$t" build-id 2>/dev/null) || { echo "clothod-install: the uploaded binary does not run here (wrong platform, or noexec mount)" >&2; exit 4; }
[ "$got" = "$id" ] || { echo "clothod-install: uploaded binary is $got, expected $id (truncated upload?)" >&2; exit 4; }
mv -f "$t" "$d/clothod" || exit 5
trap - EXIT
echo "installed=$d/clothod"
"#;

/// Exit code of `clothod bridge|start` when the remote holder is incompatible.
pub const EXIT_INCOMPATIBLE: i32 = 3;

/// Single-quote for a POSIX shell.
pub fn sq(s: &str) -> String {
    format!("'{}'", s.replace('\'', r#"'\''"#))
}

#[derive(Debug, Clone)]
pub struct Probe {
    pub fields: HashMap<String, String>,
}

impl Probe {
    pub fn get(&self, k: &str) -> &str {
        self.fields.get(k).map(String::as_str).unwrap_or("")
    }

    /// `<os>-<arch>`, the key into `dist/manifest.json`.
    pub fn platform(&self) -> String {
        format!("{}-{}", self.get("os"), self.get("arch"))
    }

    pub fn installed(&self) -> Vec<&str> {
        self.get("installed").split_whitespace().collect()
    }

    pub fn fallback_installed(&self) -> Vec<&str> {
        self.get("fallback_installed").split_whitespace().collect()
    }

    pub fn daemon_running(&self) -> bool {
        self.get("daemon") == "running"
    }
}

#[derive(Debug, Clone)]
pub struct Build {
    pub platform: String,
    pub id: String,
    pub file: PathBuf,
}

/// A remote host and how to reach it.
#[derive(Debug, Clone)]
pub struct Remote {
    pub host: String,
    /// The ssh command and its options (default `ssh -T`; `$CLOTHO_SSH` overrides, split on
    /// whitespace).
    pub ssh: Vec<String>,
    /// Environment for every remote command (`CLOTHOD_RUNTIME_DIR`, `CLOTHOD_INSTALL_DIR`).
    pub env: Vec<(String, String)>,
    /// Directory with `manifest.json` from scripts/dist.sh.
    pub dist: PathBuf,
}

/// A live connection to a remote daemon through `clothod bridge`.
pub struct Session {
    pub client: Client,
    pub child: Child,
    /// The bridge's stderr so far.
    pub stderr: Arc<Mutex<String>>,
    pub path: String,
}

pub fn default_dist() -> Option<PathBuf> {
    if let Some(d) = std::env::var_os("CLOTHO_DIST") {
        return Some(d.into());
    }
    // Next to the binary (an installed client), or the workspace's dist/ (target/<profile>/clotho).
    let exe = std::env::current_exe().ok()?;
    exe.ancestors().skip(1).take(4).map(|a| a.join("dist")).find(|d| d.join("manifest.json").is_file())
}

impl Remote {
    pub fn new(host: &str) -> Result<Remote> {
        let ssh = match std::env::var("CLOTHO_SSH") {
            Ok(s) if !s.trim().is_empty() => s.split_whitespace().map(String::from).collect(),
            _ => vec!["ssh".into(), "-T".into()],
        };
        let dist = default_dist().ok_or_else(|| anyhow!("no clothod dist/ found; run clothod/scripts/dist.sh or set CLOTHO_DIST"))?;
        Ok(Remote { host: host.into(), ssh, env: Vec::new(), dist })
    }

    /// `env K='v' ... <cmd>` (or just `cmd`).
    fn remote_command(&self, cmd: &str) -> String {
        if self.env.is_empty() {
            return cmd.to_string();
        }
        let vars: Vec<String> = self.env.iter().map(|(k, v)| format!("{k}={}", sq(v))).collect();
        format!("env {} {cmd}", vars.join(" "))
    }

    fn ssh(&self, cmd: &str) -> Command {
        let mut c = Command::new(&self.ssh[0]);
        c.args(&self.ssh[1..]).arg(&self.host).arg(self.remote_command(cmd));
        c
    }

    /// Run a command on the host; returns (exit code, stdout, stderr).
    async fn run(&self, cmd: &str, stdin: Option<Vec<u8>>) -> Result<(Option<i32>, String, String)> {
        let mut c = self.ssh(cmd);
        c.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = c.spawn().with_context(|| format!("running {}", self.ssh[0]))?;
        if let Some(data) = stdin {
            let mut si = child.stdin.take().unwrap();
            tokio::spawn(async move {
                let _ = si.write_all(&data).await;
                let _ = si.shutdown().await;
            });
        }
        let out = child.wait_with_output().await?;
        Ok((out.status.code(), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned()))
    }

    pub async fn probe(&self) -> Result<Probe> {
        let (code, out, err) = self.run("sh -s", Some(PROBE_SCRIPT.as_bytes().to_vec())).await?;
        if code == Some(255) {
            bail!("ssh {}: {}", self.host, err.trim());
        }
        let fields: HashMap<String, String> =
            out.lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_string(), v.to_string())).collect();
        if fields.get("clothod-probe").map(String::as_str) != Some("1") {
            bail!("{} did not answer the probe (not a POSIX shell host?):\n{out}{err}", self.host);
        }
        Ok(Probe { fields })
    }

    /// The bundled build for the probed platform.
    pub fn build_for(&self, probe: &Probe) -> Result<Build> {
        let manifest: Value = serde_json::from_slice(&std::fs::read(self.dist.join("manifest.json"))?)?;
        let platform = probe.platform();
        let b = manifest["builds"].get(&platform).ok_or_else(|| anyhow!("{}: unsupported platform {platform}", self.host))?;
        Ok(Build {
            platform,
            id: b["id"].as_str().unwrap_or_default().to_string(),
            file: self.dist.join(b["file"].as_str().unwrap_or_default()),
        })
    }

    /// The installed build to use on the host: `current` (one version per machine), or the
    /// only installed one.
    pub fn installed_path(&self, probe: &Probe) -> Option<String> {
        let cur = probe.get("current");
        if !cur.is_empty() && probe.installed().contains(&cur) {
            return Some(format!("{}/{cur}/clothod", probe.get("base")));
        }
        match probe.installed().as_slice() {
            [only] => Some(format!("{}/{only}/clothod", probe.get("base"))),
            _ => None,
        }
    }

    /// The installed build, or (first install only) the bundled one installed now. Never adds a
    /// second version: that is `upgrade`.
    pub async fn ensure_installed_once(&self, probe: &Probe) -> Result<String> {
        if let Some(p) = self.installed_path(probe) {
            return Ok(p);
        }
        let build = self.build_for(probe)?;
        let path = self.ensure_installed(probe, &build).await?;
        // Make it `current`.
        let (code, _, err) = self.clothod(&path, "install").await?;
        anyhow::ensure!(code == Some(0), "{}: install: {}", self.host, err.trim());
        Ok(path)
    }

    /// `upgrade`: bring the bundled build over (if missing) and switch the host to it, all or
    /// nothing; afterwards it is the host's only version. Returns its path.
    pub async fn upgrade(&self) -> Result<String> {
        let probe = self.probe().await?;
        let build = self.build_for(&probe)?;
        let path = self.ensure_installed(&probe, &build).await?;
        let (code, out, err) = self.clothod(&path, "upgrade").await?;
        if code == Some(EXIT_INCOMPATIBLE) {
            bail!("{}: restart sessions to finish upgrading: {}", self.host, err.trim());
        }
        anyhow::ensure!(code == Some(0), "{}: upgrade failed: {}", self.host, err.trim());
        Ok(out.lines().find_map(|l| l.strip_prefix("running ")).unwrap_or(&path).to_string())
    }

    /// Upload `build` unless it is there; returns the remote path of its `clothod`. Callers
    /// follow up with `install` (first install) or `upgrade`.
    pub async fn ensure_installed(&self, probe: &Probe, build: &Build) -> Result<String> {
        if probe.installed().contains(&build.id.as_str()) {
            return Ok(format!("{}/{}/clothod", probe.get("base"), build.id));
        }
        if probe.fallback_installed().contains(&build.id.as_str()) {
            return Ok(format!("{}/{}/clothod", probe.get("fallback_base"), build.id));
        }
        let data = std::fs::read(&build.file).with_context(|| format!("reading {}", build.file.display()))?;
        let mut last = String::new();
        // Default location (twice: exit 4 may be a truncated upload), then the fallback.
        for (base, attempt) in [(probe.get("base"), 0), (probe.get("base"), 1), (probe.get("fallback_base"), 2)] {
            let cmd = format!("sh -c {} sh {} {}", sq(INSTALL_SCRIPT), sq(&build.id), sq(base));
            let (code, out, err) = self.run(&cmd, Some(data.clone())).await?;
            if code == Some(0) {
                if let Some(path) = out.lines().find_map(|l| l.strip_prefix("installed=")) {
                    return Ok(path.to_string());
                }
            }
            last = format!("exit {code:?}: {}", err.trim());
            match (code, attempt) {
                (Some(4), 0) => continue,
                (Some(5), 0 | 1) => continue,
                (Some(4), 1) => break,
                _ if attempt == 2 => break,
                _ => break,
            }
        }
        bail!("installing clothod {} on {} failed: {last}", build.id, self.host)
    }

    /// Probe, install on first use, and connect through `clothod bridge` of the host's
    /// installed build (whatever version that is; switching is `upgrade`).
    pub async fn connect(&self) -> Result<Session> {
        let probe = self.probe().await?;
        let path = self.ensure_installed_once(&probe).await?;
        self.bridge(&path).await
    }

    /// Start `clothod bridge` and return the ssh process with its stdin/stdout taken out (for
    /// callers that put something between them and the client, like a test's throttled link).
    pub fn bridge_raw(&self, path: &str) -> Result<(Child, tokio::process::ChildStdout, tokio::process::ChildStdin, Arc<Mutex<String>>)> {
        let mut c = self.ssh(&format!("{} bridge", sq(path)));
        // Not kill_on_drop: the ssh process lives as long as the client holds its stdin, so
        // dropping the Child handle alone must not cut the link.
        c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = c.spawn().with_context(|| format!("running {}", self.ssh[0]))?;
        let stderr = Arc::new(Mutex::new(String::new()));
        let mut err_lines = tokio::io::BufReader::new(child.stderr.take().unwrap()).lines();
        let e = stderr.clone();
        tokio::spawn(async move {
            while let Ok(Some(line)) = err_lines.next_line().await {
                let mut e = e.lock().unwrap();
                e.push_str(&line);
                e.push('\n');
            }
        });
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        Ok((child, stdout, stdin, stderr))
    }

    /// `clothod bridge` from an installed `path`.
    pub async fn bridge(&self, path: &str) -> Result<Session> {
        let (mut child, stdout, stdin, stderr) = self.bridge_raw(path)?;
        match Client::over(stdout, stdin).await {
            Ok(client) => Ok(Session { client, child, stderr, path: path.to_string() }),
            Err(e) => {
                let status = child.wait().await?;
                // Let the stderr reader finish.
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                let msg = stderr.lock().unwrap().trim().to_string();
                if status.code() == Some(EXIT_INCOMPATIBLE) {
                    bail!("{}: restart sessions to finish upgrading: {msg}", self.host);
                }
                bail!("{}: clothod bridge failed ({status}): {msg} ({e})", self.host)
            }
        }
    }

    /// Run `<path> <subcommand>` on the host (stop, shutdown, status...).
    pub async fn clothod(&self, path: &str, args: &str) -> Result<(Option<i32>, String, String)> {
        self.run(&format!("{} {args}", sq(path)), None).await
    }

    pub fn with_env(mut self, k: &str, v: impl Into<String>) -> Remote {
        self.env.push((k.into(), v.into()));
        self
    }

    pub fn dist(&self) -> &Path {
        &self.dist
    }
}
