//! Git info for a pane's cwd (docs/protocol.md, "Git"), read from files only: git itself is
//! never run, so nothing a repo configures (hooks, fsmonitor, aliases) can execute. The one
//! command is `gh pr view` for the pull request, run outside the repo with everything explicit.

use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

/// Where a work tree's git data is.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Location {
    /// This work tree's top level (the dir holding `.git`).
    pub root: PathBuf,
    /// Its git dir: HEAD lives here (`<main>/.git`, `<common>/worktrees/<name>`, or a
    /// submodule's `.git/modules/<name>`).
    pub gitdir: PathBuf,
    /// The shared git dir: config, refs, packed-refs.
    pub commondir: PathBuf,
    /// For a linked worktree: its name (the dir under `worktrees/`).
    pub worktree: Option<String>,
}

/// Longest path walked up from a cwd (components), a bound on the work per lookup.
const MAX_DEPTH: usize = 64;
/// Largest file read (HEAD, refs, config, packed-refs).
const MAX_FILE: u64 = 4 << 20;

fn read(path: &Path) -> Option<String> {
    use std::io::Read;
    let f = std::fs::File::open(path).ok()?;
    let mut s = String::new();
    f.take(MAX_FILE).read_to_string(&mut s).ok()?;
    Some(s)
}

/// The work tree `cwd` is in, if any. A `.git` dir is a main worktree; a `.git` file points
/// (`gitdir: …`) at a linked worktree's git dir (which has a `commondir`) or at a submodule's
/// or a separate git dir (which doesn't: its own repo). A bare repo has no work tree: `None`.
pub fn locate(cwd: &Path) -> Option<Location> {
    let mut dir = Some(cwd);
    for _ in 0..MAX_DEPTH {
        let d = dir?;
        let dotgit = d.join(".git");
        if let Ok(meta) = std::fs::metadata(&dotgit) {
            if meta.is_dir() {
                if dotgit.join("HEAD").is_file() {
                    return Some(Location { root: d.to_path_buf(), gitdir: dotgit.clone(), commondir: dotgit, worktree: None });
                }
            } else if meta.is_file() {
                if let Some(loc) = from_gitfile(d, &dotgit) {
                    return Some(loc);
                }
            }
        }
        dir = d.parent();
    }
    None
}

fn from_gitfile(root: &Path, file: &Path) -> Option<Location> {
    let text = read(file)?;
    let target = text.lines().next()?.strip_prefix("gitdir:")?.trim();
    if target.is_empty() {
        return None;
    }
    let gitdir = normalize(&root.join(target));
    if !gitdir.join("HEAD").is_file() {
        return None;
    }
    match read(&gitdir.join("commondir")) {
        Some(c) => {
            let c = c.lines().next()?.trim();
            let commondir = normalize(&gitdir.join(c));
            let name = gitdir.file_name()?.to_string_lossy().into_owned();
            Some(Location { root: root.to_path_buf(), gitdir, commondir, worktree: Some(name) })
        }
        None => Some(Location { root: root.to_path_buf(), commondir: gitdir.clone(), gitdir, worktree: None }),
    }
}

/// `a/b/../c` → `a/c`, without touching the file system (no symlink resolution).
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// What HEAD says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Head {
    Branch(String),
    Detached(String),
    /// Unreadable or not something git writes.
    Unknown,
}

pub fn parse_head(text: &str) -> Head {
    let line = text.lines().next().unwrap_or("").trim();
    if let Some(r) = line.strip_prefix("ref:") {
        let r = r.trim();
        return match r.strip_prefix("refs/heads/") {
            Some(b) if !b.is_empty() => Head::Branch(b.to_string()),
            _ => Head::Unknown,
        };
    }
    if is_sha(line) {
        return Head::Detached(line.to_string());
    }
    Head::Unknown
}

fn is_sha(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The commit `refs/heads/<branch>` points at: the loose ref, else packed-refs.
pub fn branch_sha(commondir: &Path, branch: &str) -> Option<String> {
    // A branch name is never `..`-anything inside refs/heads (git refuses those); refuse them
    // here too rather than read outside the refs dir.
    if branch.split('/').any(|c| c.is_empty() || c == "." || c == "..") {
        return None;
    }
    if let Some(t) = read(&commondir.join("refs/heads").join(branch)) {
        let t = t.trim();
        if is_sha(t) {
            return Some(t.to_string());
        }
    }
    let want = format!("refs/heads/{branch}");
    read(&commondir.join("packed-refs"))?.lines().find_map(|l| {
        let (sha, name) = l.split_once(' ')?;
        (name.trim() == want && is_sha(sha)).then(|| sha.to_string())
    })
}

/// origin's `owner/name` if origin is on github.com.
pub fn github_remote(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            let header: String = l.chars().filter(|c| !c.is_whitespace()).collect();
            in_origin = header == "[remote\"origin\"]";
            continue;
        }
        if !in_origin {
            continue;
        }
        let Some((k, v)) = l.split_once('=') else { continue };
        if k.trim() != "url" {
            continue;
        }
        return parse_github_url(v.trim().trim_matches('"'));
    }
    None
}

pub fn parse_github_url(url: &str) -> Option<String> {
    let path = url
        .strip_prefix("git@github.com:")
        .or_else(|| url.strip_prefix("https://github.com/"))
        .or_else(|| url.strip_prefix("http://github.com/"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        .or_else(|| url.strip_prefix("git://github.com/"))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    let ok = |s: &str| !s.is_empty() && s.len() <= 100 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)) && s != "." && s != "..";
    (ok(owner) && ok(name)).then(|| format!("{owner}/{name}"))
}

/// The branch origin/HEAD points at, if recorded.
pub fn origin_default(commondir: &Path) -> Option<String> {
    let t = read(&commondir.join("refs/remotes/origin/HEAD"))?;
    t.lines().next()?.trim().strip_prefix("ref: refs/remotes/origin/").map(String::from)
}

/// The main worktree's root, and the repo's display name: the main worktree's dir name, or for
/// a bare common dir its name without `.git`.
pub fn main_root(commondir: &Path) -> (Option<PathBuf>, String) {
    let name_of = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if commondir.file_name().is_some_and(|n| n == ".git") {
        let root = commondir.parent().map(Path::to_path_buf);
        let name = root.as_deref().map(name_of).unwrap_or_default();
        return (root, name);
    }
    let n = name_of(commondir);
    (None, n.strip_suffix(".git").map(String::from).unwrap_or(n))
}

/// `path` relative to `base` (`../clotho-fix`), when both are absolute.
pub fn relative(path: &Path, base: &Path) -> Option<String> {
    if !path.is_absolute() || !base.is_absolute() {
        return None;
    }
    let p: Vec<_> = path.components().collect();
    let b: Vec<_> = base.components().collect();
    let common = p.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut out = PathBuf::new();
    for _ in common..b.len() {
        out.push("..");
    }
    for c in &p[common..] {
        out.push(c);
    }
    Some(if out.as_os_str().is_empty() { ".".into() } else { out.to_string_lossy().into_owned() })
}

/// Everything about a work tree except the pull request, as the `git` field shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct Info {
    pub repo: String,
    pub root: String,
    pub remote: Option<String>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub worktree: Option<(String, String)>,
    /// The branch is the default one (never looked up).
    pub default_branch: bool,
}

/// Longest repo name, branch and path passed on (characters).
const NAME_MAX: usize = 255;
const PATH_MAX: usize = 4096;

/// Read a work tree's state now. `head_text` is HEAD's contents (read by the caller, which
/// compares it to notice changes).
pub fn info(loc: &Location, head_text: &str) -> Info {
    let clean = |s: &str, max: usize| clotho_vt::printable(s, max);
    let (main, repo) = main_root(&loc.commondir);
    let remote = read(&loc.commondir.join("config")).and_then(|c| github_remote(&c));
    let (branch, sha) = match parse_head(head_text) {
        Head::Branch(b) => {
            let sha = branch_sha(&loc.commondir, &b);
            (Some(b), sha)
        }
        Head::Detached(s) => (None, Some(s)),
        Head::Unknown => (None, None),
    };
    let default_branch = branch.as_deref().is_some_and(|b| b == "main" || b == "master" || origin_default(&loc.commondir).as_deref() == Some(b));
    let worktree = loc.worktree.as_ref().map(|name| {
        let path = main.as_deref().and_then(|m| relative(&loc.root, m)).unwrap_or_else(|| loc.root.to_string_lossy().into_owned());
        (clean(name, NAME_MAX), clean(&path, PATH_MAX))
    });
    Info {
        repo: clean(&repo, NAME_MAX),
        root: clean(&loc.root.to_string_lossy(), PATH_MAX),
        remote,
        branch: branch.map(|b| clean(&b, NAME_MAX)),
        head: sha.map(|s| s[..7].to_string()),
        worktree,
        default_branch,
    }
}

/// A pull request as `gh pr view --json number,state,isDraft,url,title` gives it.
#[derive(Debug, Clone, PartialEq)]
pub struct Pr {
    pub number: u64,
    pub state: &'static str,
    pub draft: bool,
    pub url: String,
    pub title: String,
}

/// Longest PR title passed on (characters).
pub const TITLE_MAX: usize = 120;

impl Pr {
    pub fn json(&self) -> Value {
        json!({"number": self.number, "state": self.state, "draft": self.draft, "url": self.url, "title": self.title})
    }
}

/// gh's JSON (untrusted): checked and cleaned, or `None`.
pub fn parse_pr(out: &str) -> Option<Pr> {
    let v: Value = serde_json::from_str(out.trim()).ok()?;
    let number = v["number"].as_u64().filter(|n| *n > 0)?;
    let draft = v["isDraft"].as_bool().unwrap_or(false);
    let state = match v["state"].as_str()? {
        "OPEN" if draft => "draft",
        "OPEN" => "open",
        "MERGED" => "merged",
        "CLOSED" => "closed",
        _ => return None,
    };
    let url = v["url"].as_str().filter(|u| u.starts_with("https://github.com/") && u.len() <= 500 && !u.chars().any(|c| c.is_control() || c.is_whitespace()))?;
    let title = v["title"].as_str().unwrap_or("").split_whitespace().collect::<Vec<_>>().join(" ");
    Some(Pr { number, state, draft, url: url.to_string(), title: clotho_vt::printable(&title, TITLE_MAX) })
}

/// Why a lookup gave no PR.
pub fn failure_reason(stderr: &str, code: Option<i32>) -> &'static str {
    let e = stderr.to_ascii_lowercase();
    if e.contains("no pull requests found") || e.contains("no open pull requests") {
        "none"
    } else if code == Some(4) || e.contains("gh auth login") || e.contains("not logged") || e.contains("authentication") {
        "gh_auth"
    } else {
        "gh_error"
    }
}

/// The `gh` to run: `$CLOTHOD_GH` (tests), else the first on PATH, else the usual install
/// places (a daemon started at login may have a short PATH).
pub fn find_gh() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("CLOTHOD_GH") {
        let p = PathBuf::from(p);
        return is_exec(&p).then_some(p);
    }
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    if let Some(h) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(h).join(".local/bin"));
    }
    dirs.into_iter().filter(|d| d.is_absolute()).map(|d| d.join("gh")).find(|p| is_exec(p))
}

fn is_exec(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Look up the PR for `branch` of `remote` with gh: `Ok(Some)`, `Ok(None)` for none, or the
/// reason it couldn't. Runs from `/` with the repo and branch given, prompts off, no stdin,
/// killed after `timeout`. The environment is the daemon's own: gh finds its own login.
pub async fn lookup_pr(remote: &str, branch: &str, timeout: Duration) -> Result<Option<Pr>, &'static str> {
    let Some(gh) = find_gh() else { return Err("no_gh") };
    let mut cmd = tokio::process::Command::new(gh);
    cmd.args(["pr", "view", "--repo", remote, "--json", "number,state,isDraft,url,title", "--", branch])
        .current_dir("/")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("NO_COLOR", "1")
        .env_remove("GH_PAGER")
        .env("PAGER", "cat")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    cmd.process_group(0);
    let child = cmd.spawn().map_err(|_| "no_gh")?;
    let out = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(o)) => o,
        Ok(Err(_)) => return Err("gh_error"),
        Err(_) => return Err("timeout"),
    };
    let stdout = String::from_utf8_lossy(&out.stdout[..out.stdout.len().min(1 << 16)]);
    let stderr = String::from_utf8_lossy(&out.stderr[..out.stderr.len().min(1 << 16)]);
    if out.status.success() {
        return parse_pr(&stdout).map(Some).ok_or("gh_error");
    }
    match failure_reason(&stderr, out.status.code()) {
        "none" => Ok(None),
        r => Err(r),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    /// A main repo at `<tmp>/proj` on `branch`, origin on GitHub.
    fn repo(tmp: &Path, branch: &str) -> PathBuf {
        let root = tmp.join("proj");
        write(&root.join(".git/HEAD"), &format!("ref: refs/heads/{branch}\n"));
        write(&root.join(".git/refs/heads").join(branch), &format!("{SHA}\n"));
        write(&root.join(".git/config"), "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = git@github.com:other/x.git\n[remote \"origin\"]\n\turl = git@github.com:ahmad/clotho.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n");
        std::fs::create_dir_all(root.join("src/deep")).unwrap();
        root
    }

    #[test]
    fn heads() {
        assert_eq!(parse_head("ref: refs/heads/main\n"), Head::Branch("main".into()));
        assert_eq!(parse_head("ref: refs/heads/feat/x-1"), Head::Branch("feat/x-1".into()));
        assert_eq!(parse_head(&format!("{SHA}\n")), Head::Detached(SHA.into()));
        for bad in ["", "garbage", "ref: refs/tags/v1", "ref: refs/heads/", "0123abc", "\0\0\0"] {
            assert_eq!(parse_head(bad), Head::Unknown, "{bad:?}");
        }
    }

    #[test]
    fn a_main_repo_from_a_subdir() {
        let t = tempfile::tempdir().unwrap();
        let root = repo(t.path(), "feature/login");
        let loc = locate(&root.join("src/deep")).unwrap();
        assert_eq!((loc.root.clone(), loc.worktree.clone()), (root.clone(), None));
        let i = info(&loc, &read(&loc.gitdir.join("HEAD")).unwrap());
        assert_eq!(i.repo, "proj");
        assert_eq!(i.remote.as_deref(), Some("ahmad/clotho"));
        assert_eq!(i.branch.as_deref(), Some("feature/login"));
        assert_eq!(i.head.as_deref(), Some("0123456"));
        assert!(!i.default_branch && i.worktree.is_none());
        // Detached, and the default branches.
        let i = info(&loc, SHA);
        assert_eq!((i.branch, i.head.as_deref()), (None, Some("0123456")));
        assert!(info(&loc, "ref: refs/heads/main").default_branch);
        write(&root.join(".git/refs/remotes/origin/HEAD"), "ref: refs/remotes/origin/trunk\n");
        assert!(info(&loc, "ref: refs/heads/trunk").default_branch);
        // A packed branch.
        write(&root.join(".git/packed-refs"), &format!("# pack-refs with: peeled\n{SHA} refs/heads/packed\n"));
        assert_eq!(info(&loc, "ref: refs/heads/packed").head.as_deref(), Some("0123456"));
        assert_eq!(info(&loc, "ref: refs/heads/unborn").head, None);
        // Outside any repo.
        assert_eq!(locate(t.path()), None);
    }

    #[test]
    fn a_linked_worktree() {
        let t = tempfile::tempdir().unwrap();
        let main = repo(t.path(), "main");
        let wt = t.path().join("proj-fix");
        write(&main.join(".git/worktrees/fix/HEAD"), "ref: refs/heads/fix\n");
        write(&main.join(".git/worktrees/fix/commondir"), "../..\n");
        write(&main.join(".git/refs/heads/fix"), &format!("{SHA}\n"));
        write(&wt.join(".git"), &format!("gitdir: {}\n", main.join(".git/worktrees/fix").display()));
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        let loc = locate(&wt.join("sub")).unwrap();
        assert_eq!(loc.gitdir, main.join(".git/worktrees/fix"));
        assert_eq!(loc.commondir, main.join(".git"));
        let i = info(&loc, &read(&loc.gitdir.join("HEAD")).unwrap());
        assert_eq!(i.repo, "proj", "all worktrees share the main one's name");
        assert_eq!(i.root, wt.display().to_string());
        assert_eq!(i.worktree, Some(("fix".into(), "../proj-fix".into())));
        assert_eq!((i.branch.as_deref(), i.head.as_deref(), i.remote.as_deref()), (Some("fix"), Some("0123456"), Some("ahmad/clotho")));
        // A relative gitdir works too.
        write(&wt.join(".git"), "gitdir: ../proj/.git/worktrees/fix\n");
        assert_eq!(locate(&wt).unwrap().gitdir, main.join(".git/worktrees/fix"));
    }

    #[test]
    fn a_bare_repo_and_its_worktrees() {
        let t = tempfile::tempdir().unwrap();
        let bare = t.path().join("proj.git");
        write(&bare.join("HEAD"), "ref: refs/heads/main\n");
        write(&bare.join("config"), "[core]\n\tbare = true\n[remote \"origin\"]\n\turl = https://github.com/ahmad/clotho\n");
        std::fs::create_dir_all(bare.join("objects")).unwrap();
        // Inside the bare repo itself: no work tree.
        assert_eq!(locate(&bare), None);
        assert_eq!(locate(&bare.join("objects")), None);
        // A worktree of it.
        write(&bare.join("worktrees/w1/HEAD"), &format!("{SHA}\n"));
        write(&bare.join("worktrees/w1/commondir"), "../..\n");
        let wt = t.path().join("w1");
        write(&wt.join(".git"), &format!("gitdir: {}\n", bare.join("worktrees/w1").display()));
        let loc = locate(&wt).unwrap();
        let i = info(&loc, &read(&loc.gitdir.join("HEAD")).unwrap());
        assert_eq!(i.repo, "proj");
        assert_eq!(i.worktree, Some(("w1".into(), wt.display().to_string())), "no main worktree to be relative to");
        assert_eq!((i.branch, i.head.as_deref(), i.remote.as_deref()), (None, Some("0123456"), Some("ahmad/clotho")));
    }

    #[test]
    fn a_submodule_is_its_own_repo() {
        let t = tempfile::tempdir().unwrap();
        let main = repo(t.path(), "main");
        let sub = main.join("vendor/lib");
        write(&main.join(".git/modules/lib/HEAD"), &format!("{SHA}\n"));
        write(&main.join(".git/modules/lib/config"), "[remote \"origin\"]\n\turl = https://example.com/lib.git\n");
        write(&sub.join(".git"), "gitdir: ../../.git/modules/lib\n");
        let loc = locate(&sub).unwrap();
        assert_eq!((loc.root.clone(), loc.worktree.clone()), (sub.clone(), None));
        assert_eq!(loc.commondir, main.join(".git/modules/lib"));
        let i = info(&loc, &read(&loc.gitdir.join("HEAD")).unwrap());
        assert_eq!((i.repo.as_str(), i.remote.as_deref(), i.head.as_deref()), ("lib", None, Some("0123456")));
    }

    #[test]
    fn corrupt_files() {
        let t = tempfile::tempdir().unwrap();
        let root = repo(t.path(), "main");
        // A .git file that points nowhere, or isn't one: not a repo there; the walk goes on up
        // (and finds nothing above the temp dir).
        let other = t.path().join("other");
        for text in ["gitdir: /nonexistent/x\n", "nonsense", "", "gitdir:\n"] {
            write(&other.join(".git"), text);
            assert_eq!(locate(&other), None, "{text:?}");
        }
        // A .git dir without HEAD: not a repo.
        let empty = t.path().join("empty");
        std::fs::create_dir_all(empty.join(".git")).unwrap();
        assert_eq!(locate(&empty), None);
        // A garbled HEAD and config: still a repo, nothing known about it.
        let loc = locate(&root).unwrap();
        write(&root.join(".git/config"), "\u{0}[remote \"origin\"\nurl=");
        let i = info(&loc, "\u{1b}]0;evil\u{7}");
        assert_eq!((i.branch, i.head, i.remote), (None, None, None));
        // A branch name trying to leave refs/heads isn't read.
        assert_eq!(branch_sha(&loc.commondir, "../../config"), None);
        // Control characters in a branch name never reach clients.
        let i = info(&loc, "ref: refs/heads/a\u{1b}[31mb\u{9b}c");
        assert_eq!(i.branch.as_deref(), Some("a[31mbc"));
    }

    #[test]
    fn remotes() {
        for (url, want) in [
            ("git@github.com:ahmad/clotho.git", Some("ahmad/clotho")),
            ("https://github.com/ahmad/clotho", Some("ahmad/clotho")),
            ("https://github.com/ahmad/clotho.git/", Some("ahmad/clotho")),
            ("ssh://git@github.com/a-b/c.d_e.git", Some("a-b/c.d_e")),
            ("https://gitlab.com/a/b.git", None),
            ("https://github.com.evil.com/a/b", None),
            ("git@github.com:a/b c", None),
            ("https://github.com/a", None),
            ("https://github.com/../b", None),
        ] {
            assert_eq!(parse_github_url(url).as_deref(), want, "{url}");
        }
        assert_eq!(github_remote("[remote \"origin\"]\n  url = \"https://github.com/a/b\"\n").as_deref(), Some("a/b"));
        assert_eq!(github_remote("[remote \"fork\"]\n  url = https://github.com/a/b\n"), None);
    }

    #[test]
    fn prs() {
        let pr = parse_pr(r#"{"number": 42, "state": "OPEN", "isDraft": true, "url": "https://github.com/a/b/pull/42", "title": "Fix\nthe\u001b[2Jlogin  page"}"#).unwrap();
        assert_eq!((pr.number, pr.state, pr.draft), (42, "draft", true));
        assert_eq!(pr.title, "Fix the[2Jlogin page");
        assert_eq!(parse_pr(r#"{"number": 1, "state": "MERGED", "isDraft": false, "url": "https://github.com/a/b/pull/1", "title": ""}"#).unwrap().state, "merged");
        let long = format!(r#"{{"number": 1, "state": "CLOSED", "url": "https://github.com/a/b/pull/1", "title": "{}"}}"#, "x".repeat(500));
        assert_eq!(parse_pr(&long).unwrap().title.len(), TITLE_MAX);
        for bad in [
            "",
            "not json",
            r#"{"number": 0, "state": "OPEN", "url": "https://github.com/a/b/pull/1"}"#,
            r#"{"number": 1, "state": "WEIRD", "url": "https://github.com/a/b/pull/1"}"#,
            r#"{"number": 1, "state": "OPEN", "url": "javascript:alert(1)"}"#,
            r#"{"number": 1, "state": "OPEN", "url": "https://github.com/a b"}"#,
        ] {
            assert_eq!(parse_pr(bad), None, "{bad}");
        }
        assert_eq!(failure_reason("no pull requests found for branch \"x\"", Some(1)), "none");
        assert_eq!(failure_reason("To get started with GitHub CLI, please run:  gh auth login", Some(4)), "gh_auth");
        assert_eq!(failure_reason("error connecting to api.github.com", Some(1)), "gh_error");
    }

    #[test]
    fn relative_paths() {
        assert_eq!(relative(Path::new("/a/b/c"), Path::new("/a/b")).as_deref(), Some("c"));
        assert_eq!(relative(Path::new("/a/x"), Path::new("/a/b")).as_deref(), Some("../x"));
        assert_eq!(relative(Path::new("/a/b"), Path::new("/a/b")).as_deref(), Some("."));
        assert_eq!(relative(Path::new("x"), Path::new("/a")), None);
    }
}
