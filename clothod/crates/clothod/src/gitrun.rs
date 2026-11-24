//! The one way clothod runs git on a repository it doesn't trust: a resolved git binary, a
//! cleared environment, config overrides that switch off everything in the repo's config that
//! could run a program (hooks, filters, external diff, fsmonitor, pagers), plumbing commands
//! only, and a timeout, an output cap and a process-group kill on every call.

use std::collections::{BTreeSet, HashMap};
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, SystemTime};

use tokio::io::AsyncReadExt;

/// The most stderr an [`Output`] keeps, in bytes.
pub const MAX_STDERR: usize = 4096;

/// What every diff command (`diff-index`, `diff-tree`, `diff-files`) must carry: a repository's
/// `diff.<driver>.command` and `.textconv` can't be switched off by config (the driver names come
/// from `.gitattributes`), and a submodule's own config is not covered by the overrides here, so
/// git must never look inside one. `status` needs `--ignore-submodules=all` for the same reason.
pub const DIFF_FLAGS: [&str; 3] = ["--no-ext-diff", "--no-textconv", "--ignore-submodules=all"];

/// The oldest git the runner uses: `GIT_CONFIG_COUNT` came with 2.31.
const MIN_VERSION: (u32, u32) = (2, 31);
/// The bounds on the runner's own calls (`git version`, the config reads).
const PROBE: Limits = Limits { timeout: Duration::from_secs(5), max_stdout: 4096 };
const SCAN: Limits = Limits { timeout: Duration::from_secs(5), max_stdout: 1 << 20 };
/// The most filter and protocol names one repository's config may hold: each becomes a few
/// environment entries on every call.
const MAX_NAMES: usize = 256;

/// The bounds on one git call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The call is killed (its whole process group) when it runs longer than this.
    pub timeout: Duration,
    /// Stdout is cut at this many bytes; the call is then killed and [`Output::truncated`] set.
    pub max_stdout: usize,
}

/// What one git call produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    /// The exit code, or `None` when git was killed by a signal (as after truncation).
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    /// The first [`MAX_STDERR`] bytes, each line passed through `clotho_vt::printable` (the line
    /// breaks stay, so a caller can take git's first line).
    pub stderr: String,
    /// Stdout reached [`Limits::max_stdout`] and was cut there.
    pub truncated: bool,
}

/// Why a git call could not be made, or did not finish. A call that ran and exited non-zero is
/// not an error: see [`Output::code`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// No git binary on this machine.
    NoGit,
    /// The git here, or the repository, is one the runner can't use safely (the reason).
    Unsupported(String),
    /// The call ran past [`Limits::timeout`] and was killed.
    Timeout,
    /// Git could not be started (the OS error).
    Spawn(String),
    /// The repository's config could not be read or neutralised (the reason).
    Config(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NoGit => write!(f, "git is not installed"),
            Error::Unsupported(why) => write!(f, "git unsupported: {why}"),
            Error::Timeout => write!(f, "git timed out"),
            Error::Spawn(why) => write!(f, "could not run git: {why}"),
            Error::Config(why) => write!(f, "could not read the git config: {why}"),
        }
    }
}

impl std::error::Error for Error {}

/// The git binary to run, as an absolute path, or `None` when there is none: `$CLOTHOD_GIT`
/// (tests), else the first on PATH, else the usual install places (a daemon started at login may
/// have a short PATH). Never a path relative to anything: a repository can't supply its own git.
pub fn find_git() -> Option<PathBuf> {
    find_git_in(std::env::var_os("CLOTHOD_GIT"), std::env::var_os("PATH"))
}

fn find_git_in(over: Option<OsString>, path: Option<OsString>) -> Option<PathBuf> {
    if let Some(p) = over {
        let p = PathBuf::from(p);
        return (p.is_absolute() && is_exec(&p)).then_some(p);
    }
    let mut dirs: Vec<PathBuf> = path.map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    dirs.into_iter()
        .filter(|d| d.is_absolute())
        .map(|d| d.join("git"))
        .find(|p| is_exec(p) && !is_xcode_shim(p))
        .or_else(developer_git)
}

fn is_exec(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// macOS: `/usr/bin/git` is Xcode's shim, which may open an install dialog when there are no
/// developer tools. Never run it, however PATH names it.
fn is_xcode_shim(p: &Path) -> bool {
    cfg!(target_os = "macos") && std::fs::canonicalize(p).is_ok_and(|c| c == Path::new("/usr/bin/git"))
}

/// macOS: the git inside the active developer directory, or the Command Line Tools'.
fn developer_git() -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    static FOUND: Mutex<Option<PathBuf>> = Mutex::new(None);
    if let Some(p) = FOUND.lock().unwrap().clone() {
        return is_exec(&p).then_some(p);
    }
    let found = developer_dir()
        .map(|d| d.join("usr/bin/git"))
        .into_iter()
        .chain([PathBuf::from("/Library/Developer/CommandLineTools/usr/bin/git")])
        .find(|p| p.is_absolute() && is_exec(p))?;
    *FOUND.lock().unwrap() = Some(found.clone());
    Some(found)
}

/// What `/usr/bin/xcode-select -p` prints, run from `/` and killed after two seconds.
fn developer_dir() -> Option<PathBuf> {
    use std::io::Read;
    use std::os::unix::process::CommandExt;
    let mut child = std::process::Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .current_dir("/")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let pgid = child.id() as i32;
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if std::time::Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                kill_group(Some(pgid));
                let _ = child.wait();
                break None;
            }
        }
    };
    if !status?.success() {
        return None;
    }
    // The path is a line of a few dozen bytes: it fits the pipe, so reading after the exit is safe.
    let mut out = Vec::new();
    child.stdout.take()?.take(4096).read_to_end(&mut out).ok()?;
    let line = out.split(|b| *b == b'\n').next().unwrap_or_default();
    let dir = PathBuf::from(OsStr::from_bytes(line));
    dir.is_absolute().then_some(dir)
}

fn kill_group(pgid: Option<i32>) {
    if let Some(pgid) = pgid {
        // SAFETY: killpg only sends a signal. The group is the child's own (`process_group(0)`),
        // and it is only signalled while the child is unreaped, so the id can't have been reused.
        unsafe { libc::killpg(pgid, libc::SIGKILL) };
    }
}

/// Kills the child's process group if the call is dropped half way (the caller was cancelled).
struct GroupGuard(Option<i32>);

impl Drop for GroupGuard {
    fn drop(&mut self) {
        kill_group(self.0);
    }
}

type Env = Vec<(OsString, OsString)>;

/// Run `git <argv>` from `/` with exactly `env`, under `limits`: no stdin, its own process group,
/// stdout read in chunks up to the cap, stderr drained beside it, the group killed on a timeout or
/// at the cap, and the child always reaped.
async fn exec(git: &Path, argv: &[&OsStr], env: &Env, limits: Limits) -> Result<Output, Error> {
    let mut cmd = tokio::process::Command::new(git);
    cmd.args(argv)
        .current_dir("/")
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    cmd.process_group(0);
    let mut child = cmd.spawn().map_err(|e| Error::Spawn(e.to_string()))?;
    let mut guard = GroupGuard(child.id().map(|p| p as i32));
    let pgid = guard.0;
    let (mut out, mut err) = (child.stdout.take().expect("piped"), child.stderr.take().expect("piped"));
    let (mut stdout, mut stderr, mut truncated) = (Vec::new(), Vec::new(), false);

    let io = async {
        let read_out = async {
            let mut buf = vec![0u8; 64 * 1024];
            while let Ok(n @ 1..) = out.read(&mut buf).await {
                let room = limits.max_stdout - stdout.len();
                if n > room {
                    stdout.extend_from_slice(&buf[..room]);
                    truncated = true;
                    // Nothing more is wanted: stop git rather than let it fill the pipe.
                    kill_group(pgid);
                    break;
                }
                stdout.extend_from_slice(&buf[..n]);
            }
        };
        let read_err = async {
            let mut buf = [0u8; 4096];
            while let Ok(n @ 1..) = err.read(&mut buf).await {
                let room = MAX_STDERR - stderr.len();
                stderr.extend_from_slice(&buf[..n.min(room)]);
            }
        };
        tokio::join!(read_out, read_err);
        child.wait().await
    };
    let status = match tokio::time::timeout(limits.timeout, io).await {
        Ok(Ok(status)) => {
            guard.0 = None;
            status
        }
        waited => {
            kill_group(pgid);
            // SIGKILL can't be refused; the bound is only so that nothing here can wait for ever
            // (past it, tokio reaps the child in the background).
            let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
            guard.0 = None;
            return Err(match waited {
                Ok(Err(e)) => Error::Spawn(e.to_string()),
                _ => Error::Timeout,
            });
        }
    };
    let stderr = String::from_utf8_lossy(&stderr).lines().map(|l| clotho_vt::printable(l, MAX_STDERR)).collect::<Vec<_>>().join("\n");
    Ok(Output { code: status.code(), stdout, stderr, truncated })
}

fn os(s: &str) -> OsString {
    OsString::from(s)
}

/// The environment of the runner's own calls outside any repository.
fn probe_env() -> Env {
    let mut env = vec![(os("PATH"), os("/usr/bin:/bin")), (os("LC_ALL"), os("C")), (os("GIT_CONFIG_NOSYSTEM"), os("1")), (os("GIT_TERMINAL_PROMPT"), os("0"))];
    for name in ["HOME", "XDG_CONFIG_HOME"] {
        if let Some(v) = std::env::var_os(name) {
            env.push((os(name), v));
        }
    }
    env
}

/// The environment of every call in a repository: nothing of the daemon's own but HOME, no system
/// or global config, and overrides (which win over the repository's config and anything it
/// includes) for every setting that could run a program, reach the network or write to the repo.
fn repo_env(excludes: Option<&Path>, scan: &Scan) -> Env {
    let mut env: Env = [
        ("PATH", "/usr/bin:/bin"),
        ("LC_ALL", "C"),
        ("GIT_CONFIG_NOSYSTEM", "1"),
        ("GIT_CONFIG_GLOBAL", "/dev/null"),
        ("GIT_OPTIONAL_LOCKS", "0"),
        ("GIT_TERMINAL_PROMPT", "0"),
        ("GIT_NO_LAZY_FETCH", "1"),
        ("GIT_PAGER", "cat"),
        ("GIT_ASKPASS", "/bin/false"),
        ("GIT_EDITOR", ":"),
        ("GIT_ATTR_NOSYSTEM", "1"),
        ("GIT_NO_REPLACE_OBJECTS", "1"),
        ("GIT_LITERAL_PATHSPECS", "1"),
    ]
    .into_iter()
    .map(|(k, v)| (os(k), os(v)))
    .collect();
    if let Some(home) = std::env::var_os("HOME") {
        env.push((os("HOME"), home));
    }

    let mut config: Env = [
        ("core.fsmonitor", "false"),
        ("core.hooksPath", "/dev/null"),
        ("core.pager", "cat"),
        ("core.untrackedCache", "false"),
        ("diff.external", ""),
        ("diff.autoRefreshIndex", "false"),
        ("core.alternateRefsCommand", ""),
        ("core.sshCommand", "/bin/false"),
        ("core.gitProxy", ""),
        ("protocol.allow", "never"),
        ("credential.helper", ""),
        ("submodule.recurse", "false"),
        ("diff.ignoreSubmodules", "all"),
        ("status.submoduleSummary", "false"),
        ("log.showSignature", "false"),
        ("gpg.program", "/bin/false"),
        ("core.quotePath", "false"),
        ("core.bigFileThreshold", "8m"),
    ]
    .into_iter()
    .map(|(k, v)| (os(k), os(v)))
    .collect();
    if let Some(excludes) = excludes {
        config.push((os("core.excludesFile"), excludes.into()));
    }
    let key = |section: &str, name: &[u8], var: &str| OsString::from_vec([section.as_bytes(), b".", name, b".", var.as_bytes()].concat());
    for name in &scan.filters {
        for (var, value) in [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")] {
            config.push((key("filter", name, var), os(value)));
        }
    }
    // `protocol.<name>.allow` wins over `protocol.allow`, so each one the repo sets is set back.
    for name in &scan.protocols {
        config.push((key("protocol", name, "allow"), os("never")));
    }
    env.push((os("GIT_CONFIG_COUNT"), os(&config.len().to_string())));
    for (n, (k, v)) in config.into_iter().enumerate() {
        env.push((os(&format!("GIT_CONFIG_KEY_{n}")), k));
        env.push((os(&format!("GIT_CONFIG_VALUE_{n}")), v));
    }
    env
}

/// What a repository's config holds that the overrides have to name one by one.
#[derive(Debug, Default, PartialEq, Eq)]
struct Scan {
    /// Every `<name>` with a `filter.<name>.*` entry.
    filters: BTreeSet<Vec<u8>>,
    /// Every `<name>` with a `protocol.<name>.allow` entry.
    protocols: BTreeSet<Vec<u8>>,
    partial_clone: bool,
}

/// Read `git config --list -z` output: entries end in NUL and are `key\nvalue` (a key holds no
/// newline; a value may, so only the first one splits). Section and variable names arrive
/// lower-cased; the subsection (the name) is exact, and may hold dots, `=` or any other byte.
fn scan_config(list: &[u8]) -> Scan {
    let mut scan = Scan::default();
    let name = |key: &[u8], section: &[u8]| -> Option<(Vec<u8>, Vec<u8>)> {
        let rest = key.strip_prefix(section)?;
        let dot = rest.iter().rposition(|b| *b == b'.')?;
        (dot > 0).then(|| (rest[..dot].to_vec(), rest[dot + 1..].to_vec()))
    };
    for entry in list.split(|b| *b == 0) {
        let key = entry.split(|b| *b == b'\n').next().unwrap_or_default();
        if let Some((filter, _)) = name(key, b"filter.") {
            scan.filters.insert(filter);
        } else if let Some((protocol, var)) = name(key, b"protocol.") {
            if var == b"allow" {
                scan.protocols.insert(protocol);
            }
        } else if key == b"extensions.partialclone" {
            scan.partial_clone = true;
        } else if let Some((_, var)) = name(key, b"remote.") {
            scan.partial_clone |= var == b"promisor" || var == b"partialclonefilter";
        }
    }
    scan
}

/// The `major.minor` in `git version 2.39.5 (Apple Git-154)`.
fn parse_version(out: &[u8]) -> Option<(u32, u32)> {
    let text = String::from_utf8_lossy(out);
    let mut parts = text.strip_prefix("git version ")?.split(|c: char| !c.is_ascii_digit());
    Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?))
}

/// What is asked of a git binary once, not on every [`Repo::open`].
#[derive(Debug)]
struct GitInfo {
    version: (u32, u32),
    /// The user's own global `core.excludesFile`. Calls in a repository run without the global
    /// config, and this hands the user's global ignore file back to them.
    excludes: Option<PathBuf>,
}

/// One entry per binary and modification time: an upgraded git is asked again.
type InfoCache = HashMap<(PathBuf, Option<SystemTime>), Arc<GitInfo>>;
static INFO: LazyLock<Mutex<InfoCache>> = LazyLock::new(Default::default);

async fn git_info(git: &Path) -> Result<Arc<GitInfo>, Error> {
    let key = (git.to_path_buf(), std::fs::metadata(git).and_then(|m| m.modified()).ok());
    if let Some(info) = INFO.lock().unwrap().get(&key) {
        return Ok(info.clone());
    }
    let env = probe_env();
    let out = exec(git, &["version".as_ref()], &env, PROBE).await?;
    let version = parse_version(&out.stdout).filter(|_| out.code == Some(0)).ok_or_else(|| Error::Unsupported("git did not report its version".into()))?;
    let excludes = if version >= MIN_VERSION { global_excludes(git, &env).await? } else { None };
    let info = Arc::new(GitInfo { version, excludes });
    INFO.lock().unwrap().insert(key, info.clone());
    Ok(info)
}

/// The user's global ignore file, when it isn't where git looks without any config. The global
/// config is the user's own and trusted; it is read from `/`, away from any repository.
async fn global_excludes(git: &Path, env: &Env) -> Result<Option<PathBuf>, Error> {
    let args = ["config", "--global", "--includes", "--type=path", "-z", "--get", "core.excludesFile"].map(OsStr::new);
    let out = exec(git, &args, env, PROBE).await?;
    let value = out.stdout.split(|b| *b == 0).next().unwrap_or_default();
    let set = (out.code == Some(0) && !value.is_empty()).then(|| PathBuf::from(OsStr::from_bytes(value)));
    // Unset: git falls back to `$XDG_CONFIG_HOME/git/ignore`, and repository calls don't get
    // XDG_CONFIG_HOME (with only HOME git already finds `~/.config/git/ignore` by itself).
    let fallback = || std::env::var_os("XDG_CONFIG_HOME").filter(|x| !x.is_empty()).map(|x| PathBuf::from(x).join("git/ignore"));
    Ok(set.or_else(fallback).filter(|p| p.is_absolute()))
}

/// A repository opened for hardened git calls.
#[derive(Debug, Clone)]
pub struct Repo {
    root: PathBuf,
    partial_clone: bool,
    git: PathBuf,
    env: Arc<Env>,
}

impl Repo {
    /// Open the repository whose work tree root is `root`: find git, and scan the repo's config
    /// for what every later call has to override.
    pub async fn open(root: &Path) -> Result<Repo, Error> {
        // Off the runtime's threads: on a Mac without Homebrew this can wait on `xcode-select`.
        let git = tokio::task::spawn_blocking(find_git).await.map_err(|e| Error::Spawn(e.to_string()))?.ok_or(Error::NoGit)?;
        Repo::open_with(git, root).await
    }

    async fn open_with(git: PathBuf, root: &Path) -> Result<Repo, Error> {
        if !git.is_absolute() {
            return Err(Error::NoGit);
        }
        if !root.is_absolute() {
            return Err(Error::Unsupported("the repository path is not absolute".into()));
        }
        let info = git_info(&git).await?;
        if info.version < MIN_VERSION {
            let (major, minor) = info.version;
            return Err(Error::Unsupported(format!("git {major}.{minor} is older than {}.{}", MIN_VERSION.0, MIN_VERSION.1)));
        }
        let mut repo = Repo { root: root.to_path_buf(), partial_clone: false, git, env: Arc::new(repo_env(info.excludes.as_deref(), &Scan::default())) };
        // Listing the config only reads files (the repo's, and what it includes): it runs nothing.
        let out = repo.run(&["config", "--list", "-z"].map(OsStr::new), SCAN).await.map_err(|e| match e {
            Error::Timeout => Error::Config("reading it timed out".into()),
            e => e,
        })?;
        if out.truncated {
            return Err(Error::Config("it is too large".into()));
        }
        if out.code != Some(0) {
            return Err(Error::Config(out.stderr.lines().next().unwrap_or("git config failed").to_string()));
        }
        let scan = scan_config(&out.stdout);
        if scan.filters.len() + scan.protocols.len() > MAX_NAMES {
            return Err(Error::Config("it names too many filters".into()));
        }
        repo.partial_clone = scan.partial_clone;
        repo.env = Arc::new(repo_env(info.excludes.as_deref(), &scan));
        Ok(repo)
    }

    /// Run `git <args>` in the repository under `limits`. `args` must be a plumbing command.
    pub async fn run(&self, args: &[&OsStr], limits: Limits) -> Result<Output, Error> {
        let mut argv: Vec<&OsStr> = vec!["--no-pager".as_ref(), "--no-optional-locks".as_ref(), "-C".as_ref(), self.root.as_os_str()];
        argv.extend_from_slice(args);
        exec(&self.git, &argv, &self.env, limits).await
    }

    /// The work tree root this was opened with.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Whether the repository is a partial clone (it has a promisor remote), where a diff can
    /// need objects that aren't here. The runner never fetches them.
    pub fn partial_clone(&self) -> bool {
        self.partial_clone
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    const LIMITS: Limits = Limits { timeout: Duration::from_secs(20), max_stdout: 1 << 20 };

    /// The real git. These tests are the proof that a hostile repository runs nothing, so a
    /// machine without git fails them rather than skipping them.
    fn real_git() -> PathBuf {
        find_git_in(None, std::env::var_os("PATH")).expect("these tests need git installed")
    }

    fn tmp() -> tempfile::TempDir {
        tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap()
    }

    /// Test setup: git the ordinary way (the repo's config applies), but without the user's.
    fn git(dir: &Path, args: &[&str]) -> std::process::Output {
        let out = Command::new(real_git())
            .args(["-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "Test")
            .env("GIT_AUTHOR_EMAIL", "test@example.invalid")
            .env("GIT_AUTHOR_DATE", "2026-01-02T03:04:05Z")
            .env("GIT_COMMITTER_NAME", "Test")
            .env("GIT_COMMITTER_EMAIL", "test@example.invalid")
            .env("GIT_COMMITTER_DATE", "2026-01-02T03:04:05Z")
            .env("GIT_TERMINAL_PROMPT", "0")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        out
    }

    fn git_ok(dir: &Path, args: &[&str]) -> String {
        let out = git(dir, args);
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn write(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    /// An executable script. A shell writes it, so this process never holds it open for writing:
    /// a test on another thread that forks at that moment would make running it fail (ETXTBSY).
    fn script(p: &Path, body: &str) {
        use std::io::Write;
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        let mut sh = Command::new("/bin/sh").args(["-c", "cat > \"$1\" && chmod 755 \"$1\"", "sh"]).arg(p).stdin(Stdio::piped()).spawn().unwrap();
        sh.stdin.take().unwrap().write_all(body.as_bytes()).unwrap();
        assert!(sh.wait().unwrap().success());
    }

    fn append(p: &Path, s: &str) {
        let mut all = std::fs::read_to_string(p).unwrap();
        all.push_str(s);
        std::fs::write(p, all).unwrap();
    }

    fn copy_tree(from: &Path, to: &Path) {
        assert!(Command::new("/bin/cp").arg("-a").arg(from).arg(to).status().unwrap().success());
    }

    async fn run(repo: &Repo, args: &[&str]) -> Output {
        let args: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
        repo.run(&args, LIMITS).await.unwrap_or_else(|e| panic!("git {args:?}: {e}"))
    }

    async fn run_ok(repo: &Repo, args: &[&str]) -> String {
        let out = run(repo, args).await;
        assert_eq!(out.code, Some(0), "git {args:?}: {}", out.stderr);
        assert!(!out.truncated);
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn with_flags<'a>(head: &[&'a str], tail: &[&'a str]) -> Vec<&'a str> {
        [head, &DIFF_FLAGS, tail].concat()
    }

    /// The marker script and a hooks directory full of it. Returns the script and the marker it
    /// leaves when anything runs it.
    fn evil(tmp: &Path) -> (PathBuf, PathBuf) {
        let (evil, marker) = (tmp.join("evil.sh"), tmp.join("marker"));
        let body = format!("#!/bin/sh\necho \"ran $0 $*\" >> {}\nexit 0\n", marker.display());
        script(&evil, &body);
        for hook in ["post-checkout", "post-index-change", "pre-commit", "post-commit", "reference-transaction", "pre-auto-gc", "post-merge", "fsmonitor-watchman"] {
            script(&tmp.join("hooks").join(hook), &body);
        }
        (evil, marker)
    }

    #[tokio::test]
    async fn a_hostile_repo_runs_nothing_and_is_not_written() {
        let tmp = tmp();
        let root = tmp.path().join("repo");
        let (evil, marker) = evil(tmp.path());
        // `sh <script>`, not the script itself: see `script` for why nothing execs it directly.
        let e = format!("sh {}", evil.display());

        // An ordinary repo first (setup runs git the ordinary way): two branches, attributes
        // that name the filters and the diff driver, then every kind of change.
        std::fs::create_dir_all(&root).unwrap();
        git_ok(&root, &["init", "-q"]);
        write(&root.join(".gitattributes"), "* filter=evil diff=evil\n*.eq filter=a=b diff=evil\n");
        for f in ["tracked.txt", "touched.txt", "same.txt", "staged.txt", "weird.eq", "gone.txt"] {
            write(&root.join(f), &format!("{f} one\n"));
        }
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "one"]);
        git_ok(&root, &["checkout", "-q", "-b", "feat"]);
        write(&root.join("feat.txt"), "feat\n");
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "two"]);

        write(&root.join("tracked.txt"), "tracked.txt one\ndirty\n");
        write(&root.join("weird.eq"), "weird.eq one\ndirty\n");
        write(&root.join("gone.txt"), "gone.txt one\ndirty\n");
        write(&root.join("staged.txt"), "staged.txt one\nstaged\n");
        git_ok(&root, &["add", "staged.txt"]);
        write(&root.join("untracked.txt"), "untracked\n");
        // Stat-dirty: the same size with other bytes, and the same bytes with another mtime. Git
        // has to read both again to compare them, which is where a clean filter would run.
        let later = SystemTime::now() + Duration::from_secs(5);
        write(&root.join("same.txt"), "same.txt 111\n");
        write(&root.join("touched.txt"), "touched.txt one\n");
        for f in ["same.txt", "touched.txt"] {
            std::fs::File::options().write(true).open(root.join(f)).unwrap().set_modified(later).unwrap();
        }

        // Now the hostile config: everything that can name a program names the marker script.
        append(
            &root.join(".git/config"),
            &format!(
                "[include]\n\tpath = evil.inc\n\
                 [core]\n\tfsmonitor = {e}\n\tpager = {e}\n\thooksPath = {hooks}\n\tsshCommand = {e}\n\talternateRefsCommand = {e}\n\tuntrackedCache = true\n\
                 [diff]\n\texternal = {e}\n\
                 [diff \"evil\"]\n\tcommand = {e}\n\ttextconv = {e}\n\
                 [remote \"origin\"]\n\turl = ext::{e} %S\n\tpromisor = true\n\tpartialclonefilter = blob:none\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n\
                 [protocol \"ext\"]\n\tallow = always\n\
                 [extensions]\n\tpartialclone = origin\n",
                hooks = tmp.path().join("hooks").display()
            ),
        );
        write(
            &root.join(".git/evil.inc"),
            &format!(
                "[filter \"evil\"]\n\tclean = {e}\n\tsmudge = {e}\n\tprocess = {e}\n\trequired = true\n\
                 [filter \"a=b\"]\n\tclean = {e}\n\tsmudge = {e}\n\trequired = true\n\
                 [credential]\n\thelper = !{e}\n\
                 [gpg]\n\tprogram = {evil}\n\
                 [log]\n\tshowSignature = true\n\
                 [status]\n\tsubmoduleSummary = true\n",
                evil = evil.display()
            ),
        );

        // The control: in a copy, git the ordinary way does run the script. Without this the
        // assertions below would prove nothing.
        let control = tmp.path().join("control");
        copy_tree(&root, &control);
        git(&control, &["status"]);
        git(&control, &["diff", "HEAD"]);
        let ran = std::fs::read_to_string(&marker).expect("the control must run the marker script");
        assert!(ran.contains("ran "), "{ran}");
        std::fs::remove_file(&marker).unwrap();

        let index = root.join(".git/index");
        let before = (std::fs::read(&index).unwrap(), std::fs::metadata(&index).unwrap().modified().unwrap());

        let repo = Repo::open_with(real_git(), &root).await.unwrap();
        assert!(repo.partial_clone());
        assert_eq!(repo.root(), root);

        // Every read-only command the changes summary and the diff requests use.
        let listed = run_ok(&repo, &["config", "--list", "-z"]).await;
        assert!(listed.contains("filter.a=b.clean\n"), "{listed:?}");
        let status = run_ok(&repo, &["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=all"]).await;
        for f in ["tracked.txt", "staged.txt", "same.txt", "weird.eq", "untracked.txt"] {
            assert!(status.contains(f), "{f} in {status:?}");
        }
        let numstat = run_ok(&repo, &with_flags(&["diff-index", "--numstat", "-z", "-M"], &["HEAD", "--"])).await;
        for f in ["1\t0\ttracked.txt", "1\t0\tstaged.txt", "1\t1\tsame.txt", "1\t0\tweird.eq"] {
            assert!(numstat.contains(f), "{f} in {numstat:?}");
        }
        assert!(!numstat.contains("touched.txt"), "{numstat:?}");
        run_ok(&repo, &with_flags(&["diff-index", "--raw", "-z", "-M"], &["HEAD", "--"])).await;
        let patch = run_ok(&repo, &with_flags(&["diff-index", "-p", "-U3"], &["HEAD", "--", "tracked.txt"])).await;
        assert!(patch.contains("\n+dirty\n"), "{patch}");
        let patch = run_ok(&repo, &with_flags(&["diff-index", "-p", "-U3"], &["HEAD", "--", "weird.eq"])).await;
        assert!(patch.contains("\n+dirty\n"), "{patch}");
        run_ok(&repo, &with_flags(&["diff-index", "-p", "--cached"], &["HEAD", "--"])).await;
        let base = run_ok(&repo, &["merge-base", "HEAD", "main"]).await;
        let base = base.trim();
        assert_eq!(base.len(), 40, "{base}");
        assert_eq!(run_ok(&repo, &["rev-list", "--count", "main..HEAD"]).await, "1\n");
        let tree = run_ok(&repo, &with_flags(&["diff-tree", "-r", "--numstat", "-z", "-M"], &[base, "HEAD", "--"])).await;
        assert!(tree.contains("1\t0\tfeat.txt"), "{tree:?}");
        let tree = run_ok(&repo, &with_flags(&["diff-tree", "-r", "--raw", "-z", "-M"], &[base, "HEAD", "--"])).await;
        assert!(tree.contains("feat.txt"), "{tree:?}");
        let tree = run_ok(&repo, &with_flags(&["diff-tree", "-r", "-p"], &[base, "HEAD", "--", "feat.txt"])).await;
        assert!(tree.contains("\n+feat\n"), "{tree}");
        assert_eq!(run_ok(&repo, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]).await.trim().len(), 40);
        assert_eq!(run_ok(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]).await, "feat\n");
        assert_eq!(Path::new(run_ok(&repo, &["rev-parse", "--show-toplevel"]).await.trim()), std::fs::canonicalize(&root).unwrap());
        run_ok(&repo, &["rev-parse", "--git-common-dir", "--is-bare-repository"]).await;
        run_ok(&repo, &["for-each-ref", "--format=%(refname)", "refs/heads"]).await;
        run_ok(&repo, &["worktree", "list", "--porcelain"]).await;

        assert!(!marker.exists(), "a read-only call ran the script: {}", std::fs::read_to_string(&marker).unwrap());
        let after = (std::fs::read(&index).unwrap(), std::fs::metadata(&index).unwrap().modified().unwrap());
        assert!(before == after, "a read-only call rewrote .git/index");
        assert!(!root.join(".git/index.lock").exists());

        // Creating a worktree writes, but still runs nothing: no post-checkout hook, no smudge
        // filter (the files come out as they are stored).
        let wt = tmp.path().join("wt");
        run_ok(&repo, &["worktree", "add", "--quiet", "-b", "side", wt.to_str().unwrap(), "main"]).await;
        assert_eq!(std::fs::read_to_string(wt.join("tracked.txt")).unwrap(), "tracked.txt one\n");
        assert_eq!(std::fs::read_to_string(wt.join("weird.eq")).unwrap(), "weird.eq one\n");
        // A worktree of the same repo shares its config, and is as safe to open.
        let side = Repo::open_with(real_git(), &wt).await.unwrap();
        assert_eq!(run_ok(&side, &["rev-parse", "--abbrev-ref", "HEAD"]).await, "side\n");
        run_ok(&side, &["status", "--porcelain=v2", "-z", "--ignore-submodules=all"]).await;
        assert!(!marker.exists(), "worktree add ran the script: {}", std::fs::read_to_string(&marker).unwrap());
        assert!(!root.join(".git/index.lock").exists());

        // A missing object in what the config calls a partial clone: git must not go and fetch
        // it (the promisor remote is an `ext::` command, and the repo allows that transport).
        let blob = run_ok(&repo, &["rev-parse", "HEAD:gone.txt"]).await;
        let blob = blob.trim();
        std::fs::remove_file(root.join(".git/objects").join(&blob[..2]).join(&blob[2..])).unwrap();
        let out = run(&repo, &with_flags(&["diff-index", "-p"], &["HEAD", "--", "gone.txt"])).await;
        assert_ne!(out.code, Some(0), "{out:?}");
        let out = run(&repo, &["cat-file", "blob", blob]).await;
        assert_ne!(out.code, Some(0), "{out:?}");
        assert!(!marker.exists(), "a missing object ran the script: {}", std::fs::read_to_string(&marker).unwrap());
    }

    #[tokio::test]
    async fn a_hostile_submodule_runs_nothing() {
        let tmp = tmp();
        let (evil, marker) = evil(tmp.path());
        let e = format!("sh {}", evil.display());
        let (src, root) = (tmp.path().join("subsrc"), tmp.path().join("super"));
        for dir in [&src, &root] {
            std::fs::create_dir_all(dir).unwrap();
            git_ok(dir, &["init", "-q"]);
        }
        write(&src.join(".gitattributes"), "* filter=evil diff=evil\n");
        write(&src.join("s.txt"), "one\n");
        git_ok(&src, &["add", "-A"]);
        git_ok(&src, &["commit", "-q", "-m", "sub"]);
        write(&root.join("top.txt"), "one\n");
        git_ok(&root, &["submodule", "--quiet", "add", src.to_str().unwrap(), "sub"]);
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "super"]);

        write(&root.join("top.txt"), "one\ndirty\n");
        write(&root.join("sub/s.txt"), "one\ndirty\n");
        write(&root.join("sub/new.txt"), "new\n");
        // The superproject asks git to look inside the submodule in every way config can, and
        // the submodule's own config (which the overrides do not reach) is hostile.
        append(&root.join(".git/config"), "[submodule \"sub\"]\n\tignore = none\n[submodule]\n\trecurse = true\n[diff]\n\tignoreSubmodules = none\n\tsubmodule = diff\n[status]\n\tsubmoduleSummary = true\n");
        append(
            &root.join(".git/modules/sub/config"),
            &format!("[core]\n\tfsmonitor = {e}\n\tpager = {e}\n\thooksPath = {hooks}\n[diff]\n\texternal = {e}\n[diff \"evil\"]\n\tcommand = {e}\n\ttextconv = {e}\n[filter \"evil\"]\n\tclean = {e}\n\tsmudge = {e}\n\trequired = true\n", hooks = tmp.path().join("hooks").display()),
        );

        let control = tmp.path().join("control");
        copy_tree(&root, &control);
        git(&control, &["status"]);
        git(&control, &["diff", "HEAD"]);
        assert!(marker.exists(), "the control must run the marker script");
        std::fs::remove_file(&marker).unwrap();

        let repo = Repo::open_with(real_git(), &root).await.unwrap();
        let status = run_ok(&repo, &["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=all"]).await;
        assert!(status.contains("top.txt"), "{status:?}");
        let numstat = run_ok(&repo, &with_flags(&["diff-index", "--numstat", "-z", "-M"], &["HEAD", "--"])).await;
        assert!(numstat.contains("1\t0\ttop.txt") && !numstat.contains("sub"), "{numstat:?}");
        run_ok(&repo, &with_flags(&["diff-index", "--raw", "-z"], &["HEAD", "--"])).await;
        run_ok(&repo, &with_flags(&["diff-index", "-p"], &["HEAD", "--"])).await;
        run_ok(&repo, &with_flags(&["diff-index", "-p"], &["HEAD", "--", "sub"])).await;
        run_ok(&repo, &with_flags(&["diff-tree", "-r", "-p", "--root"], &["HEAD", "--"])).await;
        run_ok(&repo, &with_flags(&["diff-tree", "-r", "--numstat", "-z", "--root"], &["HEAD", "--"])).await;
        let wt = tmp.path().join("wt");
        run_ok(&repo, &["worktree", "add", "--quiet", "-b", "side", wt.to_str().unwrap(), "HEAD"]).await;
        assert!(wt.join("top.txt").exists());
        assert!(!marker.exists(), "a call ran the submodule's script: {}", std::fs::read_to_string(&marker).unwrap());
    }

    /// A process that is gone, or dead and only waiting for its parent to collect it.
    fn gone(pid: i32) -> bool {
        let out = Command::new("/bin/ps").args(["-o", "stat=", "-p", &pid.to_string()]).output().unwrap();
        let stat = String::from_utf8_lossy(&out.stdout);
        stat.trim().is_empty() || stat.trim().starts_with('Z')
    }

    /// A stand-in git that answers what `open` asks, and for anything else runs `then`.
    fn stub_git(dir: &Path, version: &str, then: &str) -> PathBuf {
        let stub = dir.join("stub/git");
        script(&stub, &format!("#!/bin/sh\nif [ \"$1\" = version ]; then echo 'git version {version}'; exit 0; fi\nfor a; do if [ \"$a\" = config ]; then exit 0; fi; done\n{then}\n"));
        stub
    }

    #[tokio::test]
    async fn a_timeout_kills_the_whole_process_group() {
        let tmp = tmp();
        let pids = tmp.path().join("pids");
        let stub = stub_git(tmp.path(), "2.43.0", &format!("sleep 300 &\necho \"$$ $!\" > {p}.tmp\nmv {p}.tmp {p}\nwait", p = pids.display()));
        let repo = Repo::open_with(stub, tmp.path()).await.unwrap();
        let started = std::time::Instant::now();
        let out = repo.run(&["status".as_ref()], Limits { timeout: Duration::from_millis(1500), max_stdout: 1024 }).await;
        assert_eq!(out, Err(Error::Timeout));
        assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
        let pids: Vec<i32> = std::fs::read_to_string(&pids).expect("the stub ran").split_whitespace().map(|p| p.parse().unwrap()).collect();
        assert_eq!(pids.len(), 2);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !pids.iter().all(|p| gone(*p)) {
            assert!(std::time::Instant::now() < deadline, "still running after the timeout: {pids:?}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    #[tokio::test]
    async fn a_dropped_call_kills_the_whole_process_group() {
        let tmp = tmp();
        let pids = tmp.path().join("pids");
        let stub = stub_git(tmp.path(), "2.43.0", &format!("sleep 300 &\necho \"$$ $!\" > {p}.tmp\nmv {p}.tmp {p}\nwait", p = pids.display()));
        let repo = Repo::open_with(stub, tmp.path()).await.unwrap();
        let args = ["status".as_ref()];
        let mut call = Box::pin(repo.run(&args, LIMITS));
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !pids.exists() {
            assert!(std::time::Instant::now() < deadline, "the stub never ran");
            assert!(tokio::time::timeout(Duration::from_millis(20), &mut call).await.is_err());
        }
        let pids: Vec<i32> = std::fs::read_to_string(&pids).unwrap().split_whitespace().map(|p| p.parse().unwrap()).collect();
        assert!(pids.len() == 2 && !gone(pids[0]) && !gone(pids[1]), "{pids:?}");
        // The caller gives up (a client went away): what it started must not outlive it.
        drop(call);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !pids.iter().all(|p| gone(*p)) {
            assert!(std::time::Instant::now() < deadline, "still running after the drop: {pids:?}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    #[tokio::test]
    async fn the_output_cap_truncates_and_stops_reading() {
        // An endless writer: only killing it at the cap lets the call return at all.
        let tmp = tmp();
        let stub = stub_git(tmp.path(), "2.43.0", "echo oops >&2\nexec yes 0123456789");
        let repo = Repo::open_with(stub, tmp.path()).await.unwrap();
        let out = repo.run(&["status".as_ref()], Limits { timeout: Duration::from_secs(20), max_stdout: 100_000 }).await.unwrap();
        assert!(out.truncated);
        assert_eq!(out.stdout.len(), 100_000);
        assert!(out.stdout.starts_with(b"0123456789\n0123456789\n"));
        assert_eq!(out.code, None);
        assert_eq!(out.stderr, "oops");

        // Real git: a blob over the cap is cut at it, one that fits exactly is not truncated.
        let root = tmp.path().join("repo");
        std::fs::create_dir_all(&root).unwrap();
        git_ok(&root, &["init", "-q"]);
        write(&root.join("big.txt"), &"0123456789abcde\n".repeat(1 << 16));
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "big"]);
        let repo = Repo::open_with(real_git(), &root).await.unwrap();
        assert!(!repo.partial_clone());
        let args = ["cat-file", "blob", "HEAD:big.txt"].map(OsStr::new);
        let out = repo.run(&args, Limits { timeout: Duration::from_secs(20), max_stdout: 4096 }).await.unwrap();
        assert!(out.truncated);
        assert_eq!(out.stdout, "0123456789abcde\n".repeat(256).as_bytes());
        let out = repo.run(&args, Limits { timeout: Duration::from_secs(20), max_stdout: 1 << 20 }).await.unwrap();
        assert!(!out.truncated);
        assert_eq!((out.code, out.stdout.len()), (Some(0), 1 << 20));
    }

    #[tokio::test]
    async fn stderr_is_kept_short_and_printable() {
        let tmp = tmp();
        let stub = stub_git(tmp.path(), "2.43.0", "printf 'fatal: \\033[31mbad\\033[0m thing\\nsecond line\\n' >&2\nyes x | head -c 100000 >&2\nexit 128");
        let repo = Repo::open_with(stub, tmp.path()).await.unwrap();
        let out = repo.run(&["status".as_ref()], LIMITS).await.unwrap();
        assert_eq!(out.code, Some(128));
        assert!(out.stdout.is_empty() && !out.truncated);
        assert_eq!(out.stderr.lines().next(), Some("fatal: [31mbad[0m thing"));
        assert!(out.stderr.len() <= MAX_STDERR, "{}", out.stderr.len());
    }

    #[tokio::test]
    async fn an_old_or_unknown_git_is_unsupported() {
        let tmp = tmp();
        for (n, version) in ["2.30.2", "1.8.3.1", "nonsense"].into_iter().enumerate() {
            let ran = tmp.path().join(format!("ran{n}"));
            let stub = stub_git(&tmp.path().join(n.to_string()), version, &format!("touch {}", ran.display()));
            let err = Repo::open_with(stub.clone(), tmp.path()).await.unwrap_err();
            assert!(matches!(err, Error::Unsupported(_)), "{version}: {err:?}");
            // And again, from the cache when the version was readable.
            assert!(matches!(Repo::open_with(stub, tmp.path()).await, Err(Error::Unsupported(_))));
            assert!(!ran.exists(), "{version}: git was run in the repo anyway");
        }
        for version in ["2.31.0", "2.39.5 (Apple Git-154)", "3.0.0-rc1"] {
            let stub = stub_git(&tmp.path().join(version.replace(' ', "_")), version, "exit 0");
            Repo::open_with(stub, tmp.path()).await.unwrap_or_else(|e| panic!("{version}: {e}"));
        }
        assert_eq!(parse_version(b"git version 2.43.0\n"), Some((2, 43)));
        assert_eq!(parse_version(b"git version 2.39.5 (Apple Git-154)\n"), Some((2, 39)));
        assert_eq!(parse_version(b"git version 2.47.1.windows.2\n"), Some((2, 47)));
        assert_eq!(parse_version(b"git version 2\n"), None);
        assert_eq!(parse_version(b""), None);
    }

    #[tokio::test]
    async fn open_refuses_what_it_cannot_make_safe() {
        let tmp = tmp();
        assert_eq!(Repo::open_with(tmp.path().join("no/git"), tmp.path()).await.unwrap_err(), Error::Spawn("No such file or directory (os error 2)".into()));
        assert_eq!(Repo::open_with(PathBuf::from("git"), tmp.path()).await.unwrap_err(), Error::NoGit);
        assert!(matches!(Repo::open_with(real_git(), Path::new("relative/repo")).await, Err(Error::Unsupported(_))));

        // A config git can't parse: nothing in it can be overridden, so nothing is run.
        let root = tmp.path().join("repo");
        std::fs::create_dir_all(&root).unwrap();
        git_ok(&root, &["init", "-q"]);
        append(&root.join(".git/config"), "[filter \"x\n");
        assert!(matches!(Repo::open_with(real_git(), &root).await, Err(Error::Config(_))));

        // More filters than the environment should carry.
        let many: String = (0..=MAX_NAMES).map(|n| format!("[filter \"f{n}\"]\n\tclean = cat\n")).collect();
        git_ok(&root, &["init", "-q", "many"]);
        append(&root.join("many/.git/config"), &many);
        assert!(matches!(Repo::open_with(real_git(), &root.join("many")).await, Err(Error::Config(_))));

        // A directory that is no repository opens (there is no config to fear); calls then fail.
        let plain = tmp.path().join("plain");
        std::fs::create_dir_all(&plain).unwrap();
        let repo = Repo::open_with(real_git(), &plain).await.unwrap();
        let out = repo.run(&["rev-parse", "--show-toplevel"].map(OsStr::new), LIMITS).await.unwrap();
        assert_eq!(out.code, Some(128));
        assert!(out.stderr.contains("not a git repository"), "{}", out.stderr);
    }

    #[test]
    fn find_git_honours_the_override_and_is_never_relative() {
        let tmp = tmp();
        let stub = tmp.path().join("bin/git");
        script(&stub, "#!/bin/sh\nexit 0\n");
        let path = Some(OsString::from("/usr/bin:/bin"));
        assert_eq!(find_git_in(Some(stub.clone().into()), path.clone()), Some(stub.clone()));
        // The override is the whole answer: a bad one is not a reason to look elsewhere.
        assert_eq!(find_git_in(Some(tmp.path().join("bin/nope").into()), path.clone()), None);
        assert_eq!(find_git_in(Some(tmp.path().join("bin").into()), path.clone()), None);
        assert_eq!(find_git_in(Some("git".into()), path.clone()), None);
        assert_eq!(find_git_in(Some("./git".into()), path), None);

        // From PATH: the first absolute entry that has one. Relative entries (and the empty one,
        // which means the current directory) are never used.
        let rel = std::env::join_paths([Path::new(""), Path::new("."), Path::new("bin"), Path::new("../bin"), &tmp.path().join("bin")]).unwrap();
        assert_eq!(find_git_in(None, Some(rel)), Some(stub));
        for path in [None, Some(OsString::from(".:bin::")), std::env::var_os("PATH")] {
            if let Some(found) = find_git_in(None, path) {
                assert!(found.is_absolute(), "{found:?}");
                assert!(!cfg!(target_os = "macos") || found != Path::new("/usr/bin/git"));
            }
        }
        let found = find_git().expect("these tests need git installed");
        assert!(found.is_absolute());
    }

    #[test]
    fn the_config_scan_finds_every_name() {
        let list = b"core.bare\nfalse\0filter.evil.clean\nsh x\0filter.evil.required\ntrue\0filter.a=b.smudge\nx\0filter.Dotted.Name.process\nx\0\
            filter.multi.clean\nline one\nfilter.fake.clean\0filter.novalue.required\0filter.clean\nx\0filter..clean\nx\0\
            protocol.ext.allow\nalways\0protocol.allow\nalways\0protocol.file.other\nx\0remote.origin.url\nu\0";
        let scan = scan_config(list);
        let names = |set: &BTreeSet<Vec<u8>>| set.iter().map(|n| String::from_utf8_lossy(n).into_owned()).collect::<Vec<_>>();
        assert_eq!(names(&scan.filters), ["Dotted.Name", "a=b", "evil", "multi", "novalue"]);
        assert_eq!(names(&scan.protocols), ["ext"]);
        assert!(!scan.partial_clone);
        assert!(scan_config(b"extensions.partialclone\norigin\0").partial_clone);
        assert!(scan_config(b"remote.up.stream.promisor\ntrue\0").partial_clone);
        assert!(scan_config(b"remote.origin.partialclonefilter\nblob:none\0").partial_clone);
        assert_eq!(scan_config(b""), Scan::default());

        // Each name is overridden through its own KEY/VALUE pair, so no byte in it can be read
        // as the end of the key, and the count matches the pairs.
        let env = repo_env(Some(Path::new("/home/u/.gitignore")), &scan);
        let get = |k: &str| env.iter().find(|(key, _)| key == k).map(|(_, v)| v.to_string_lossy().into_owned());
        let count: usize = get("GIT_CONFIG_COUNT").unwrap().parse().unwrap();
        let pairs: Vec<(String, String)> = (0..count).map(|n| (get(&format!("GIT_CONFIG_KEY_{n}")).unwrap(), get(&format!("GIT_CONFIG_VALUE_{n}")).unwrap())).collect();
        assert!(get(&format!("GIT_CONFIG_KEY_{count}")).is_none());
        for want in [("filter.a=b.clean", ""), ("filter.a=b.smudge", ""), ("filter.a=b.process", ""), ("filter.a=b.required", "false"), ("filter.Dotted.Name.clean", ""), ("protocol.ext.allow", "never"), ("core.excludesFile", "/home/u/.gitignore"), ("core.fsmonitor", "false"), ("core.hooksPath", "/dev/null")] {
            assert!(pairs.iter().any(|(k, v)| (k.as_str(), v.as_str()) == want), "{want:?}");
        }
        assert_eq!(get("GIT_CONFIG_GLOBAL").as_deref(), Some("/dev/null"));
        assert_eq!(get("PATH").as_deref(), Some("/usr/bin:/bin"));
        assert!(!repo_env(None, &Scan::default()).iter().any(|(_, v)| v == "core.excludesFile"));
    }
}
