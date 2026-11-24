//! Creating a git worktree for a new Tab or Workspace: the `worktree` option on `tab.create` and
//! `workspace.create` (feature `worktree`). All git work goes through [`crate::gitrun`].

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::git;
use crate::gitrun::{self, Limits, Output, Repo};

/// A worktree that was just made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Created {
    /// The new work tree's folder (canonical).
    pub path: PathBuf,
    /// The new branch checked out there.
    pub branch: String,
    /// The commit it starts at (7 characters).
    pub head: String,
}

/// An error code of the protocol and a message for the user.
pub type Failure = (&'static str, String);

/// Longest worktree (branch) name and base, in characters.
const NAME_MAX: usize = 100;
const BASE_MAX: usize = 255;
/// Longest piece of git's own words, or of a path, in an error message (characters).
const MESSAGE_MAX: usize = 300;

/// `worktree add` checks out a whole tree: it gets two minutes. It prints a line or two.
const ADD: Limits = Limits { timeout: Duration::from_secs(120), max_stdout: 64 << 10 };
/// The look-ups before it.
const QUICK: Limits = Limits { timeout: Duration::from_secs(10), max_stdout: 4096 };
/// Each step of undoing a failed add.
const UNDO: Limits = Limits { timeout: Duration::from_secs(30), max_stdout: 4096 };

/// One creation at a time in this daemon. The checks that the folder and the branch are free,
/// the add and the undo are one unit: two requests for the same name must not both pass the
/// checks, or the loser's undo would remove the winner's worktree and branch.
static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Whether `name` may be a new worktree's branch: 1 to 100 characters from `[A-Za-z0-9._/-]`,
/// not starting with `-`, `.` or `/`, not ending in `/` or `.`, without `..` or `//` (and so
/// without `@{`, which the characters already rule out), and no component ending in `.lock`.
/// Git has the last word (`check-ref-format`); this keeps everything else away from its command
/// line and from the folder name.
fn valid_name(name: &str) -> bool {
    (1..=NAME_MAX).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._/-".contains(&b))
        && !name.starts_with(['-', '.', '/'])
        && !name.ends_with(['/', '.'])
        && !name.contains("..")
        && !name.contains("//")
        && !name.contains("@{")
        && !name.split('/').any(|c| c.ends_with(".lock"))
}

/// Where the worktree for `name` goes: beside the main work tree, named after it
/// (`clotho` and `fix/login` give `../clotho-fix-login`).
fn folder(main: &Path, name: &str) -> Option<PathBuf> {
    let mut dir = OsString::from(main.file_name()?);
    dir.push("-");
    dir.push(name.replace('/', "-"));
    Some(main.parent()?.join(dir))
}

fn failure(e: &gitrun::Error) -> Failure {
    let code = match e {
        gitrun::Error::NoGit => "no_git",
        gitrun::Error::Unsupported(_) => "git_unsupported",
        gitrun::Error::Timeout => "timeout",
        gitrun::Error::Spawn(_) | gitrun::Error::Config(_) => "git_failed",
    };
    (code, clotho_vt::printable(&e.to_string(), MESSAGE_MAX))
}

/// What git said went wrong: its first `fatal:` or `error:` line (a progress line can come
/// before it), else its first line.
fn git_says(out: &Output) -> String {
    let mut lines = out.stderr.lines().filter(|l| !l.trim().is_empty());
    let line = lines.clone().find(|l| l.starts_with("fatal:") || l.starts_with("error:")).or_else(|| lines.next());
    clotho_vt::printable(line.unwrap_or("git failed without saying why"), MESSAGE_MAX)
}

fn is_sha(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

async fn run(repo: &Repo, args: &[&OsStr], limits: Limits) -> Result<Output, gitrun::Error> {
    repo.run(args, limits).await
}

/// Whether `refs/heads/<name>` exists: `None` when git couldn't say.
async fn branch_exists(repo: &Repo, name: &str) -> Result<bool, Failure> {
    let refname = format!("refs/heads/{name}");
    let out = run(repo, &["rev-parse", "--verify", "--quiet", &refname].map(OsStr::new), QUICK).await.map_err(|e| failure(&e))?;
    match out.code {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(("git_failed", git_says(&out))),
    }
}

/// The commit `rev` names, as a full sha.
async fn commit(repo: &Repo, rev: &str) -> Result<Option<String>, Failure> {
    let spec = format!("{rev}^{{commit}}");
    let out = run(repo, &["rev-parse", "--verify", "--quiet", "--end-of-options", &spec].map(OsStr::new), QUICK).await.map_err(|e| failure(&e))?;
    let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok((out.code == Some(0) && is_sha(&sha)).then_some(sha))
}

/// Take back what a failed `worktree add` made, through git only (no file is ever deleted here):
/// the worktree, then the branch if it still points at `sha`. Returns what is still there.
async fn undo(repo: &Repo, path: &Path, name: &str, sha: &str) -> Option<String> {
    // Twice `--force`: a git that was killed in its checkout (a timeout) leaves the worktree
    // locked ("initializing"), and one `--force` refuses a locked one. The caller checked that
    // nothing was at `path` before the add, under LOCK, so what is there is this call's own.
    let _ = run(repo, &["worktree".as_ref(), "remove".as_ref(), "--force".as_ref(), "--force".as_ref(), "--".as_ref(), path.as_os_str()], UNDO).await;
    let refname = format!("refs/heads/{name}");
    let _ = run(repo, &["update-ref", "-d", &refname, sha].map(OsStr::new), UNDO).await;
    let mut left = Vec::new();
    if std::fs::symlink_metadata(path).is_ok() {
        left.push(format!("the folder {}", clotho_vt::printable(&path.to_string_lossy(), MESSAGE_MAX)));
    }
    // Anything but a clear "no such branch" counts as still there.
    if !matches!(branch_exists(repo, name).await, Ok(false)) {
        left.push(format!("the branch {name}"));
    }
    (!left.is_empty()).then(|| left.join(" and "))
}

/// Make a linked worktree for the repository `cwd` is in, on a new branch `name`, in a new folder
/// beside the main work tree. The branch starts at `base` (any commit-ish), or at the HEAD of the
/// work tree `cwd` is in. Nothing the repository configures runs: no hooks, no filters (so LFS
/// files stay pointers). On any failure the repository is left as it was, or the message says
/// what remains.
pub async fn create(cwd: &Path, name: &str, base: Option<&str>) -> Result<Created, Failure> {
    let not_a_repo = || ("not_a_repo", "that folder is not in a git repository".to_string());
    if !cwd.is_absolute() {
        return Err(not_a_repo());
    }
    let loc = git::locate(cwd).ok_or_else(not_a_repo)?;
    let unsupported = || ("worktree_unsupported", "this repository has no main work tree to put a worktree beside".to_string());
    let main = git::main_root(&loc.commondir).0.ok_or_else(unsupported)?;

    let bad_name = || ("worktree_name", "a worktree name is 1 to 100 letters, digits, '.', '_', '-' or '/', and must be a valid branch name".to_string());
    if !valid_name(name) {
        return Err(bad_name());
    }
    let path = folder(&main, name).ok_or_else(unsupported)?;

    let repo = Repo::open(&loc.root).await.map_err(|e| failure(&e))?;
    let out = run(&repo, &["check-ref-format", "--branch", name].map(OsStr::new), QUICK).await.map_err(|e| failure(&e))?;
    if out.code != Some(0) {
        return Err(bad_name());
    }

    let _one_at_a_time = LOCK.lock().await;
    // A failed `worktree add -b` leaves the branch behind, so what can be checked is checked first.
    let shown = clotho_vt::printable(&path.to_string_lossy(), MESSAGE_MAX);
    if std::fs::symlink_metadata(&path).is_ok() {
        return Err(("worktree_exists", format!("{shown} already exists")));
    }
    if branch_exists(&repo, name).await? {
        return Err(("branch_exists", format!("the branch {name} already exists")));
    }

    let sha = match base {
        Some(base) => {
            let ok = !base.is_empty() && base.chars().count() <= BASE_MAX && !base.starts_with('-') && !base.chars().any(char::is_control);
            let sha = if ok { commit(&repo, base).await? } else { None };
            sha.ok_or_else(|| ("bad_base", format!("{} is not a commit here", clotho_vt::printable(base, BASE_MAX))))?
        }
        None => commit(&repo, "HEAD").await?.ok_or_else(|| ("bad_base", "the repository has no commit to start from".to_string()))?,
    };

    let args: [&OsStr; 9] = ["worktree".as_ref(), "add".as_ref(), "--quiet".as_ref(), "--no-track".as_ref(), "-b".as_ref(), name.as_ref(), "--".as_ref(), path.as_os_str(), sha.as_ref()];
    let (code, why) = match run(&repo, &args, ADD).await {
        Ok(out) if out.code == Some(0) && !out.truncated => {
            return Ok(Created { path: std::fs::canonicalize(&path).unwrap_or(path), branch: name.to_string(), head: sha[..7].to_string() });
        }
        Ok(out) => ("git_failed", git_says(&out)),
        Err(e) => failure(&e),
    };
    Err(match undo(&repo, &path, name, &sha).await {
        Some(left) => (code, format!("{why} (left behind: {left})")),
        None => (code, why),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    fn tmp() -> tempfile::TempDir {
        tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap()
    }

    /// Test setup: git the ordinary way (the repo's config applies), but without the user's.
    fn git(dir: &Path, args: &[&str]) -> std::process::Output {
        Command::new(gitrun::find_git().expect("these tests need git installed"))
            .args(["-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "Test")
            .env("GIT_AUTHOR_EMAIL", "test@example.invalid")
            .env("GIT_COMMITTER_NAME", "Test")
            .env("GIT_COMMITTER_EMAIL", "test@example.invalid")
            .env("GIT_TERMINAL_PROMPT", "0")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    fn git_ok(dir: &Path, args: &[&str]) -> String {
        let out = git(dir, args);
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn write(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    /// An executable script, written by a shell so this process never holds it open for writing
    /// (a test on another thread forking at that moment would make running it fail, ETXTBSY).
    fn script(p: &Path, body: &str) {
        use std::io::Write;
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        let mut sh = Command::new("/bin/sh").args(["-c", "cat > \"$1\" && chmod 755 \"$1\"", "sh"]).arg(p).stdin(Stdio::piped()).spawn().unwrap();
        sh.stdin.take().unwrap().write_all(body.as_bytes()).unwrap();
        assert!(sh.wait().unwrap().success());
    }

    /// A repo at `<tmp>/proj` on `main` with two commits. Returns its root (canonical) and the
    /// two commits, oldest first.
    fn repo(tmp: &Path) -> (PathBuf, String, String) {
        let root = std::fs::canonicalize(tmp).unwrap().join("proj");
        std::fs::create_dir_all(root.join("src")).unwrap();
        git_ok(&root, &["init", "-q"]);
        write(&root.join("a.txt"), "one\n");
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "one"]);
        let first = git_ok(&root, &["rev-parse", "HEAD"]);
        write(&root.join("src/b.txt"), "two\n");
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "two"]);
        let second = git_ok(&root, &["rev-parse", "HEAD"]);
        (root, first, second)
    }

    fn branches(root: &Path) -> Vec<String> {
        git_ok(root, &["for-each-ref", "--format=%(refname:short)", "refs/heads"]).lines().map(String::from).collect()
    }

    /// The folders beside the repo, and the worktrees git knows of.
    fn state(root: &Path) -> (Vec<String>, Vec<String>, usize) {
        let mut dirs: Vec<String> = std::fs::read_dir(root.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        dirs.sort();
        let worktrees = git_ok(root, &["worktree", "list", "--porcelain"]).lines().filter(|l| l.starts_with("worktree ")).count();
        (dirs, branches(root), worktrees)
    }

    #[test]
    fn names() {
        for ok in ["x", "fix", "fix/login", "a.b", "v1.2_x-y", "A/b/c", &"x".repeat(100)] {
            assert!(valid_name(ok), "{ok:?}");
        }
        for bad in ["", "-x", ".x", "/x", "x/", "x.", "../x", "a..b", "a//b", "x.lock", "a.lock/b", "a b", "a@{b", "a~1", "a:b", "a\\b", "a\nb", "é", "a*", &"x".repeat(101)] {
            assert!(!valid_name(bad), "{bad:?}");
        }
        assert_eq!(folder(Path::new("/w/clotho"), "fix/login"), Some(PathBuf::from("/w/clotho-fix-login")));
        assert_eq!(folder(Path::new("/"), "x"), None);
    }

    #[tokio::test]
    async fn creates_a_worktree_beside_the_repo() {
        let tmp = tmp();
        let (root, first, second) = repo(tmp.path());

        // From a subfolder, at HEAD.
        let made = create(&root.join("src"), "topic", None).await.unwrap();
        let fix = root.parent().unwrap().join("proj-topic");
        assert_eq!(made, Created { path: fix.clone(), branch: "topic".into(), head: second[..7].into() });
        assert_eq!(std::fs::read_to_string(fix.join("src/b.txt")).unwrap(), "two\n");
        assert_eq!(git_ok(&fix, &["rev-parse", "--abbrev-ref", "HEAD"]), "topic");
        assert_eq!(git_ok(&fix, &["rev-parse", "HEAD"]), second);
        assert_eq!(git_ok(&fix, &["status", "--porcelain"]), "");
        // The main work tree is untouched.
        assert_eq!(git_ok(&root, &["rev-parse", "--abbrev-ref", "HEAD"]), "main");
        assert_eq!(git_ok(&root, &["status", "--porcelain"]), "");

        // With a base it starts there, and tracks nothing.
        let made = create(&root, "old", Some("HEAD~1")).await.unwrap();
        let old = root.parent().unwrap().join("proj-old");
        assert_eq!(made, Created { path: old.clone(), branch: "old".into(), head: first[..7].into() });
        assert_eq!(git_ok(&old, &["rev-parse", "HEAD"]), first);
        assert!(!old.join("src/b.txt").exists());
        assert!(!git(&old, &["rev-parse", "--verify", "--quiet", "old@{upstream}"]).status.success());
        // A branch name and a sha are bases too.
        assert_eq!(create(&root, "from-branch", Some("old")).await.unwrap().head, first[..7]);
        assert_eq!(create(&root, "from-sha", Some(&first)).await.unwrap().head, first[..7]);

        // A slash in the name stays in the branch and becomes a dash in the folder.
        let made = create(&root, "fix/login", None).await.unwrap();
        assert_eq!(made, Created { path: root.parent().unwrap().join("proj-fix-login"), branch: "fix/login".into(), head: second[..7].into() });
        assert_eq!(git_ok(&made.path, &["rev-parse", "--abbrev-ref", "HEAD"]), "fix/login");

        // From inside a linked worktree: still beside, and named after, the main repo, and at
        // that worktree's HEAD.
        std::fs::create_dir_all(old.join("deep")).unwrap();
        let made = create(&old.join("deep"), "second", None).await.unwrap();
        assert_eq!(made, Created { path: root.parent().unwrap().join("proj-second"), branch: "second".into(), head: first[..7].into() });
        assert_eq!(git_ok(&root, &["worktree", "list", "--porcelain"]).lines().filter(|l| l.starts_with("worktree ")).count(), 7);
    }

    #[tokio::test]
    async fn each_refusal_leaves_no_branch_and_no_folder() {
        let tmp = tmp();
        let (root, _, _) = repo(tmp.path());
        let beside = root.parent().unwrap().to_path_buf();
        git_ok(&root, &["branch", "taken"]);
        std::fs::create_dir_all(beside.join("proj-dir")).unwrap();
        std::fs::write(beside.join("proj-file"), "x").unwrap();
        std::os::unix::fs::symlink("/nonexistent", beside.join("proj-link")).unwrap();
        let before = state(&root);

        let long = "x".repeat(101);
        let long_base = "x".repeat(256);
        for (name, base, code) in [
            // The folder is there already: a folder, a file, a dangling link.
            ("dir", None, "worktree_exists"),
            ("file", None, "worktree_exists"),
            ("link", None, "worktree_exists"),
            ("taken", None, "branch_exists"),
            ("-x", None, "worktree_name"),
            ("../x", None, "worktree_name"),
            ("a..b", None, "worktree_name"),
            ("", None, "worktree_name"),
            (long.as_str(), None, "worktree_name"),
            ("x.lock", None, "worktree_name"),
            ("a b", None, "worktree_name"),
            ("/abs", None, "worktree_name"),
            // Allowed characters, but no branch name to git.
            ("a/.b", None, "worktree_name"),
            ("x", Some("nope"), "bad_base"),
            ("x", Some(""), "bad_base"),
            ("x", Some("-h"), "bad_base"),
            ("x", Some("--all"), "bad_base"),
            ("x", Some("main\u{1b}[31m"), "bad_base"),
            ("x", Some(long_base.as_str()), "bad_base"),
            // A tree, not a commit.
            ("x", Some("HEAD^{tree}"), "bad_base"),
            // Git itself refuses (a branch can't be both a name and a folder of names).
            ("taken/sub", None, "git_failed"),
        ] {
            let err = create(&root, name, base).await.unwrap_err();
            assert_eq!(err.0, code, "{name:?} {base:?}: {err:?}");
            assert!(!err.1.is_empty() && !err.1.chars().any(char::is_control), "{err:?}");
            assert_eq!(state(&root), before, "{name:?} {base:?}");
        }

        // Not a repo, and a relative path.
        let plain = beside.join("plain");
        std::fs::create_dir_all(&plain).unwrap();
        assert_eq!(create(&plain, "x", None).await.unwrap_err().0, "not_a_repo");
        assert_eq!(create(Path::new("proj"), "x", None).await.unwrap_err().0, "not_a_repo");
        assert_eq!(create(&beside.join("missing"), "x", None).await.unwrap_err().0, "not_a_repo");
        assert!(!beside.join("plain-x").exists());

        // A repo without a commit has nothing to start from.
        let empty = beside.join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        git_ok(&empty, &["init", "-q"]);
        assert_eq!(create(&empty, "x", None).await.unwrap_err().0, "bad_base");
        assert!(!beside.join("empty-x").exists() && branches(&empty).is_empty());
    }

    #[tokio::test]
    async fn a_bare_repo_is_refused() {
        let tmp = tmp();
        let (root, _, _) = repo(tmp.path());
        let beside = root.parent().unwrap().to_path_buf();
        let bare = beside.join("bare.git");
        git_ok(&beside, &["clone", "-q", "--bare", root.to_str().unwrap(), bare.to_str().unwrap()]);
        // Inside the bare repo there is no work tree at all.
        assert_eq!(create(&bare, "x", None).await.unwrap_err().0, "not_a_repo");
        // A worktree of it has no main work tree to go beside.
        let wt = beside.join("of-bare");
        git_ok(&bare, &["worktree", "add", "-q", "-b", "w", wt.to_str().unwrap(), "main"]);
        let before = branches(&bare);
        let err = create(&wt, "x", None).await.unwrap_err();
        assert_eq!(err.0, "worktree_unsupported", "{err:?}");
        assert_eq!(branches(&bare), before);
        assert!(!beside.join("bare-x").exists() && !beside.join("bare.git-x").exists() && !beside.join("of-bare-x").exists());
    }

    #[tokio::test]
    async fn hooks_and_filters_never_run() {
        let tmp = tmp();
        let (root, _, second) = repo(tmp.path());
        let beside = root.parent().unwrap().to_path_buf();
        let (evil, marker) = (beside.join("evil.sh"), beside.join("marker"));
        let body = format!("#!/bin/sh\necho \"ran $0 $*\" >> {}\nexit 0\n", marker.display());
        script(&evil, &body);
        write(&root.join(".gitattributes"), "*.txt filter=evil\n");
        git_ok(&root, &["add", "-A"]);
        git_ok(&root, &["commit", "-q", "-m", "attributes"]);
        for hook in ["post-checkout", "reference-transaction"] {
            script(&root.join(".git/hooks").join(hook), &body);
        }
        // `sh <script>`, not the script itself: see `script`.
        let e = format!("sh {}", evil.display());
        let mut config = std::fs::read_to_string(root.join(".git/config")).unwrap();
        config.push_str(&format!("[filter \"evil\"]\n\tclean = {e}\n\tsmudge = {e}\n\trequired = true\n"));
        std::fs::write(root.join(".git/config"), config).unwrap();

        // The control: in a copy, git the ordinary way does run the script. Without this the
        // assertion below would prove nothing.
        let control = beside.join("control");
        assert!(Command::new("/bin/cp").arg("-a").arg(&root).arg(&control).status().unwrap().success());
        git(&control, &["worktree", "add", "-b", "ordinary", beside.join("control-ordinary").to_str().unwrap()]);
        let ran = std::fs::read_to_string(&marker).expect("the control must run the marker script");
        assert!(ran.contains("post-checkout") && ran.contains("reference-transaction"), "{ran}");
        std::fs::remove_file(&marker).unwrap();

        let made = create(&root, "safe", None).await.unwrap();
        assert_eq!(made.path, beside.join("proj-safe"));
        assert_ne!(made.head, second[..7], "the attributes commit is HEAD");
        // The files come out as they are stored: the required filter did not run and did not fail.
        assert_eq!(std::fs::read_to_string(made.path.join("a.txt")).unwrap(), "one\n");
        assert_eq!(std::fs::read_to_string(made.path.join("src/b.txt")).unwrap(), "two\n");
        // A refusal after the checks, and one with an undo, run nothing either.
        assert_eq!(create(&root, "safe", None).await.unwrap_err().0, "worktree_exists");
        assert_eq!(create(&root, "other", Some("nope")).await.unwrap_err().0, "bad_base");
        assert!(!marker.exists(), "creating a worktree ran the script: {}", std::fs::read_to_string(&marker).unwrap());
    }

    #[tokio::test]
    async fn a_failed_add_rolls_the_branch_back() {
        let tmp = tmp();
        let (root, _, second) = repo(tmp.path());
        // A commit whose file can't be read: git makes the branch, then fails in the checkout.
        let blob = git_ok(&root, &["rev-parse", "HEAD:a.txt"]);
        std::fs::remove_file(root.join(".git/objects").join(&blob[..2]).join(&blob[2..])).unwrap();
        let before = state(&root);

        // The control: git the ordinary way leaves the branch behind.
        let control = root.parent().unwrap().join("control");
        assert!(Command::new("/bin/cp").arg("-a").arg(&root).arg(&control).status().unwrap().success());
        assert!(!git(&control, &["worktree", "add", "-b", "broken", "../control-broken"]).status.success());
        assert_eq!(branches(&control), ["broken", "main"]);
        let before = (state(&root).0, before.1, before.2);

        let err = create(&root, "broken", None).await.unwrap_err();
        assert_eq!(err.0, "git_failed", "{err:?}");
        assert!(!err.1.is_empty() && err.1.chars().count() <= MESSAGE_MAX && !err.1.contains("left behind"), "{err:?}");
        assert_eq!(state(&root), before, "{err:?}");
        assert!(!root.parent().unwrap().join("proj-broken").exists());
        assert!(!root.join(".git/refs/heads/broken").exists());
        assert_eq!(git_ok(&root, &["rev-parse", "main"]), second);

        // A branch that was there before a failure is never the one deleted: the same name again
        // is refused before git is asked to add anything.
        git_ok(&root, &["branch", "broken"]);
        assert_eq!(create(&root, "broken", None).await.unwrap_err().0, "branch_exists");
        assert_eq!(branches(&root), ["broken", "main"]);
    }

    /// What a `worktree add` killed in its checkout leaves (the timeout path): a folder, a branch
    /// and a locked entry. The undo takes all three back.
    #[tokio::test]
    async fn a_locked_half_made_worktree_is_taken_back() {
        let tmp = tmp();
        let (root, _, second) = repo(tmp.path());
        let before = state(&root);
        let path = root.parent().unwrap().join("proj-half");
        git_ok(&root, &["worktree", "add", "-q", "--lock", "--reason", "initializing", "-b", "half", path.to_str().unwrap()]);
        // The control: one --force is refused.
        assert!(!git(&root, &["worktree", "remove", "--force", path.to_str().unwrap()]).status.success());
        assert!(path.exists());

        let repo = Repo::open(&root).await.unwrap();
        assert_eq!(undo(&repo, &path, "half", &second).await, None);
        assert_eq!(state(&root), before);
        assert!(!path.exists() && !root.join(".git/worktrees/proj-half").exists());
    }
}
