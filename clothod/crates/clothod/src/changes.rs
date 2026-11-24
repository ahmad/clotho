//! What changed in a pane's repository: the `changes` summary on a pane's `git` object and the
//! `git.changes` and `git.diff` requests (feature `git.changes`). All git work goes through
//! [`crate::gitrun`]; untracked files are read here, never by git.
//!
//! Two groups: `uncommitted` compares the work tree with HEAD (staged and unstaged together,
//! untracked files included), and `branch` compares HEAD with its merge base against a base
//! branch. The caller resolves HEAD and the base to commit ids: git is only ever given ids, never
//! ref names.

use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use crate::gitrun::{self, Limits, Output, Repo, DIFF_FLAGS};

/// The files per group `git.changes` returns when the request names no limit, and the most.
pub const DEFAULT_LIMIT: usize = 500;
pub const MAX_LIMIT: usize = 2000;
/// The context lines `git.diff` gives when the request names none, and the most.
pub const DEFAULT_CONTEXT: u64 = 3;
pub const MAX_CONTEXT: u64 = 20;

/// The total time one summary, list or diff may spend in git.
const BUDGET: Duration = Duration::from_secs(6);
/// The most `status` output read; past it the summary is `too_large`.
const STATUS_CAP: usize = 4 << 20;
/// The most numstat or `diff-tree` output read.
const TREE_CAP: usize = 8 << 20;
/// Past this many changed tracked paths (or this many bytes of them, which have to fit git's
/// argument list) the lines are not counted.
const MAX_COUNTED: usize = 1000;
const MAX_ARG_BYTES: usize = 256 << 10;
/// Untracked files: the most read of one, and of all in one run.
const UNTRACKED_FILE: usize = 1 << 20;
const UNTRACKED_RUN: usize = 8 << 20;
const UNTRACKED_FILES: usize = 200;
/// A NUL in this many leading bytes makes a file binary (git's own rule).
const SNIFF: usize = 8000;
/// A file over this is binary, as git treats it under `core.bigFileThreshold=8m`.
const BIG_FILE: u64 = 8 << 20;
/// One diff: the most patch bytes, lines, and characters per line.
const PATCH_CAP: usize = 1 << 20;
const MAX_LINES: usize = 20_000;
const MAX_LINE_CHARS: usize = 2000;
/// The longest path `git.diff` takes (bytes), and the longest name passed on (characters).
const PATH_MAX: usize = 4096;
const NAME_MAX: usize = 255;
/// The most changed paths whose size and time go into the change token.
const TOKEN_PATHS: usize = 2000;

/// The branch a pane's branch is compared with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Base {
    /// What clients show (`origin/main`).
    pub name: String,
    /// The commit it points at (a full id).
    pub sha: String,
}

/// The `changes` field of a pane's `git` object, with its `changes_reason`.
#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    /// `{uncommitted, branch, reason, token}`, or `None` with `reason` saying why.
    pub changes: Option<Value>,
    pub reason: Option<&'static str>,
}

impl Summary {
    /// No changes known, for `reason` (`pending`, `no_git`, …).
    pub fn none(reason: &'static str) -> Summary {
        Summary { changes: None, reason: Some(reason) }
    }
}

/// The `changes_reason` for a repository that could not be opened or a call that did not run.
pub fn reason(e: &gitrun::Error) -> &'static str {
    match e {
        gitrun::Error::NoGit => "no_git",
        gitrun::Error::Unsupported(_) => "git_unsupported",
        gitrun::Error::Timeout => "timeout",
        gitrun::Error::Spawn(_) | gitrun::Error::Config(_) => "error",
    }
}

/// The request error (code and message) for the same.
pub fn error(e: &gitrun::Error) -> (&'static str, String) {
    let code = match e {
        gitrun::Error::NoGit => "no_git",
        gitrun::Error::Unsupported(_) => "git_unsupported",
        gitrun::Error::Timeout => "timeout",
        gitrun::Error::Spawn(_) | gitrun::Error::Config(_) => "git_failed",
    };
    (code, e.to_string())
}

/// Why a step gave nothing.
#[derive(Debug, PartialEq)]
enum Fail {
    Run(gitrun::Error),
    /// Git refused the repository (dubious ownership).
    Unsafe(String),
    /// Git failed in a partial clone: the objects it needed are not here.
    Partial(String),
    /// Git's output went over its cap.
    TooLarge,
    /// Git exited non-zero (its first stderr line).
    Git(String),
}

impl Fail {
    fn reason(&self) -> &'static str {
        match self {
            Fail::Run(e) => reason(e),
            Fail::Unsafe(_) => "unsafe",
            Fail::Partial(_) => "partial_clone",
            Fail::TooLarge => "too_large",
            Fail::Git(_) => "error",
        }
    }

    fn error(self) -> (&'static str, String) {
        match self {
            Fail::Run(e) => error(&e),
            Fail::TooLarge => ("git_failed", "there are too many changes to list".into()),
            Fail::Unsafe(line) | Fail::Partial(line) | Fail::Git(line) => ("git_failed", line),
        }
    }
}

/// What a non-zero exit means, from git's stderr.
fn classify(stderr: &str, partial_clone: bool) -> Fail {
    let line = stderr.lines().find(|l| !l.trim().is_empty()).unwrap_or("git failed").to_string();
    let lower = stderr.to_ascii_lowercase();
    if lower.contains("dubious ownership") || lower.contains("safe.directory") {
        Fail::Unsafe(line)
    } else if partial_clone {
        // The runner never fetches, so in a partial clone a failed read is a missing object.
        Fail::Partial(line)
    } else {
        Fail::Git(line)
    }
}

#[derive(Debug, Clone, Copy)]
struct Opts {
    budget: Duration,
    status_cap: usize,
}

impl Default for Opts {
    fn default() -> Opts {
        let budget = std::env::var("CLOTHOD_TEST_GIT_BUDGET_MS").ok().and_then(|v| v.parse().ok()).map(Duration::from_millis).unwrap_or(BUDGET);
        Opts { budget, status_cap: STATUS_CAP }
    }
}

/// Git calls against one deadline.
struct Run<'a> {
    repo: &'a Repo,
    deadline: Instant,
    opts: Opts,
}

impl<'a> Run<'a> {
    fn new(repo: &'a Repo, opts: Opts) -> Run<'a> {
        Run { repo, deadline: Instant::now() + opts.budget, opts }
    }

    /// One call, bounded by what is left of the budget and by `most`.
    async fn git(&self, args: &[&OsStr], cap: usize, most: Duration) -> Result<Output, Fail> {
        let left = self.deadline.saturating_duration_since(Instant::now()).min(most);
        if left.is_zero() {
            return Err(Fail::Run(gitrun::Error::Timeout));
        }
        self.repo.run(args, Limits { timeout: left, max_stdout: cap }).await.map_err(Fail::Run)
    }

    /// The whole stdout of a call that has to exit 0 within `cap`.
    async fn ok(&self, args: &[&OsStr], cap: usize) -> Result<Vec<u8>, Fail> {
        let out = self.git(args, cap, Duration::MAX).await?;
        self.whole(out)
    }

    fn whole(&self, out: Output) -> Result<Vec<u8>, Fail> {
        if out.truncated {
            return Err(Fail::TooLarge);
        }
        if out.code != Some(0) {
            return Err(classify(&out.stderr, self.repo.partial_clone()));
        }
        Ok(out.stdout)
    }

    /// What the work tree is compared with: `HEAD`, or the empty tree while HEAD is unborn.
    async fn tree(&self, head: Option<&str>) -> Result<String, Fail> {
        if head.is_some() {
            return Ok("HEAD".into());
        }
        // Stdin is /dev/null: this hashes an empty tree in the repository's own object format,
        // and writes nothing.
        let out = self.ok(&["hash-object", "-t", "tree", "--stdin"].map(OsStr::new), 256).await?;
        let sha = String::from_utf8_lossy(&out).trim().to_string();
        if is_sha(&sha) {
            Ok(sha)
        } else {
            Err(Fail::Git("git gave no empty tree".into()))
        }
    }
}

fn is_sha(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(7)]
}

// ---------------------------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------------------------

/// One changed file.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    path: Vec<u8>,
    /// Where a renamed file was.
    old_path: Option<Vec<u8>>,
    status: &'static str,
    /// `None` when not counted (and always for a binary file).
    added: Option<u64>,
    removed: Option<u64>,
    binary: bool,
}

impl Entry {
    fn new(path: &[u8], old_path: Option<&[u8]>, status: &'static str) -> Entry {
        Entry { path: path.to_vec(), old_path: old_path.map(<[u8]>::to_vec), status, added: None, removed: None, binary: false }
    }
}

/// The NUL-ended fields of a `-z` output.
struct Fields<'a>(&'a [u8]);

impl<'a> Iterator for Fields<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<&'a [u8]> {
        if self.0.is_empty() {
            return None;
        }
        let end = self.0.iter().position(|b| *b == 0).unwrap_or(self.0.len());
        let field = &self.0[..end];
        self.0 = &self.0[(end + 1).min(self.0.len())..];
        Some(field)
    }
}

/// The path of a status record: what follows its first `skip` space-separated columns (a path
/// may itself hold spaces).
fn after_columns(record: &[u8], skip: usize) -> Option<&[u8]> {
    record.splitn(skip + 1, |b| *b == b' ').nth(skip)
}

/// `status --porcelain=v2 -z`: `1` (changed), `2` (renamed or copied; the original path is the
/// next field), `u` (unmerged) and `?` (untracked) records. Anything else is skipped.
fn parse_status(out: &[u8]) -> Vec<Entry> {
    let mut entries = Vec::new();
    let mut fields = Fields(out);
    while let Some(record) = fields.next() {
        let xy = record.get(2..4).unwrap_or_default();
        match record.first() {
            Some(b'1') => {
                let Some(path) = after_columns(record, 8) else { continue };
                let status = if xy.contains(&b'A') {
                    "added"
                } else if xy.contains(&b'D') {
                    "deleted"
                } else {
                    "modified"
                };
                entries.push(Entry::new(path, None, status));
            }
            Some(b'2') => {
                let orig = fields.next();
                let (Some(path), Some(orig)) = (after_columns(record, 9), orig) else { continue };
                // A copy is a new file; only a rename has somewhere it came from.
                if xy.contains(&b'R') {
                    entries.push(Entry::new(path, Some(orig), "renamed"));
                } else {
                    entries.push(Entry::new(path, None, "added"));
                }
            }
            Some(b'u') => {
                let Some(path) = after_columns(record, 10) else { continue };
                entries.push(Entry::new(path, None, "conflicted"));
            }
            Some(b'?') => {
                let Some(path) = record.get(2..) else { continue };
                entries.push(Entry::new(path, None, "untracked"));
            }
            _ => {}
        }
    }
    entries
}

/// One `--numstat` row.
#[derive(Debug, PartialEq, Eq)]
struct Num {
    path: Vec<u8>,
    old_path: Option<Vec<u8>>,
    added: Option<u64>,
    removed: Option<u64>,
    binary: bool,
}

/// `--numstat -z`: `added\tremoved\tpath\0`, or for a rename `added\tremoved\t\0old\0new\0`.
/// `-\t-` is a binary file.
fn parse_numstat(out: &[u8]) -> Vec<Num> {
    let mut rows = Vec::new();
    let mut fields = Fields(out);
    while let Some(record) = fields.next() {
        let mut cols = record.splitn(3, |b| *b == b'\t');
        let (Some(added), Some(removed), Some(path)) = (cols.next(), cols.next(), cols.next()) else { continue };
        let (path, old_path) = if path.is_empty() {
            let (Some(old), Some(new)) = (fields.next(), fields.next()) else { break };
            (new, Some(old.to_vec()))
        } else {
            (path, None)
        };
        let number = |b: &[u8]| std::str::from_utf8(b).ok().and_then(|s| s.parse::<u64>().ok());
        let binary = added == b"-" && removed == b"-";
        rows.push(Num { path: path.to_vec(), old_path, added: number(added), removed: number(removed), binary });
    }
    rows
}

/// `diff-tree --raw -z` records (`:modes ids STATUS\0path\0`, with a second path after a rename
/// or copy), for the statuses and old paths. Returns them with whatever follows the raw records:
/// with `--numstat` as well, that is the numstat rows.
fn parse_raw(out: &[u8]) -> (Vec<Entry>, &[u8]) {
    let mut entries = Vec::new();
    let mut fields = Fields(out);
    loop {
        let rest = fields.0;
        let Some(record) = fields.next() else { return (entries, &[]) };
        if record.first() != Some(&b':') {
            return (entries, rest);
        }
        let letter = record.rsplit(|b| *b == b' ').next().and_then(|s| s.first()).copied();
        let Some(first) = fields.next() else { return (entries, &[]) };
        let entry = match letter {
            Some(b'R') | Some(b'C') => {
                let Some(second) = fields.next() else { return (entries, &[]) };
                if letter == Some(b'R') {
                    Entry::new(second, Some(first), "renamed")
                } else {
                    Entry::new(second, None, "added")
                }
            }
            Some(b'A') => Entry::new(first, None, "added"),
            Some(b'D') => Entry::new(first, None, "deleted"),
            Some(b'U') => Entry::new(first, None, "conflicted"),
            _ => Entry::new(first, None, "modified"),
        };
        entries.push(entry);
    }
}

/// Give each entry its numstat row's counts (rows are matched by path; a rename row by its new
/// path). An entry without a row changed no lines.
fn apply_counts(entries: &mut [Entry], rows: Vec<Num>) {
    let rows: HashMap<Vec<u8>, Num> = rows.into_iter().map(|r| (r.path.clone(), r)).collect();
    for e in entries.iter_mut().filter(|e| e.status != "untracked") {
        match rows.get(&e.path) {
            Some(row) => (e.added, e.removed, e.binary) = (row.added, row.removed, row.binary),
            None => (e.added, e.removed) = (Some(0), Some(0)),
        }
    }
}

/// `diff-tree -r --raw --numstat -z`: the files from the raw records, the counts from the rows.
fn parse_tree(out: &[u8]) -> Vec<Entry> {
    let (mut entries, rest) = parse_raw(out);
    apply_counts(&mut entries, parse_numstat(rest));
    entries
}

/// One file's patch, as `git.diff` returns it.
#[derive(Debug, Default, PartialEq)]
struct Patch {
    status: &'static str,
    binary: bool,
    truncated: bool,
    added: u64,
    removed: u64,
    hunks: Vec<Value>,
}

/// `-a,b +c,d @@ header` (what follows `@@ `): the four numbers and the header. A count left out
/// is 1.
fn parse_hunk_header(rest: &[u8]) -> Option<(u64, u64, u64, u64, String)> {
    let text = String::from_utf8_lossy(rest);
    let (ranges, header) = text.split_once(" @@")?;
    let (old, new) = ranges.split_once(' ')?;
    let range = |s: &str, sign: char| -> Option<(u64, u64)> {
        let s = s.strip_prefix(sign)?;
        match s.split_once(',') {
            Some((start, lines)) => Some((start.parse().ok()?, lines.parse().ok()?)),
            None => Some((s.parse().ok()?, 1)),
        }
    };
    let ((old_start, old_lines), (new_start, new_lines)) = (range(old, '-')?, range(new, '+')?);
    let header = clotho_vt::printable(header.strip_prefix(' ').unwrap_or(header), MAX_LINE_CHARS);
    Some((old_start, old_lines, new_start, new_lines, header))
}

/// A line's text: lossy UTF-8, cut to [`MAX_LINE_CHARS`].
fn line_text(bytes: &[u8]) -> (String, bool) {
    let text = String::from_utf8_lossy(bytes);
    match text.char_indices().nth(MAX_LINE_CHARS) {
        Some((at, _)) => (text[..at].to_string(), true),
        None => (text.into_owned(), false),
    }
}

fn line_json(t: &str, old: Option<u64>, new: Option<u64>, bytes: &[u8]) -> Value {
    let (text, cut) = line_text(bytes);
    let mut line = Map::new();
    line.insert("t".into(), json!(t));
    line.insert("old".into(), json!(old));
    line.insert("new".into(), json!(new));
    line.insert("text".into(), json!(text));
    if cut {
        line.insert("cut".into(), json!(true));
    }
    Value::Object(line)
}

/// A hunk being read: its header, the lines so far, and how many lines the header still promises.
struct Hunk {
    head: (u64, u64, u64, u64, String),
    lines: Vec<Value>,
    old: u64,
    new: u64,
    old_left: u64,
    new_left: u64,
}

impl Hunk {
    fn json(self) -> Value {
        let (old_start, old_lines, new_start, new_lines, header) = self.head;
        json!({"old_start": old_start, "old_lines": old_lines, "new_start": new_start, "new_lines": new_lines, "header": header, "lines": self.lines})
    }
}

/// One file's section of a unified patch (from its `diff --git` line) into hunks. A hunk's
/// lines are counted off against its header, so file content that looks like a header (`--- a`,
/// `@@ …`) is never taken for one. Stops at `max_lines` lines, with `truncated` set.
fn parse_section(lines: &[&[u8]], max_lines: usize) -> Patch {
    let mut patch = Patch { status: "modified", ..Patch::default() };
    let mut hunk: Option<Hunk> = None;
    let mut total = 0usize;
    for line in lines {
        if let Some(h) = hunk.as_mut() {
            if line.first() == Some(&b'\\') {
                if let Some(last) = h.lines.last_mut().and_then(Value::as_object_mut) {
                    last.insert("no_newline".into(), json!(true));
                }
                continue;
            }
            if h.old_left > 0 || h.new_left > 0 {
                if total >= max_lines {
                    patch.truncated = true;
                    break;
                }
                // A context line that lost its one space is still a context line.
                let (sign, text) = line.split_first().map(|(s, t)| (*s, t)).unwrap_or((b' ', &[]));
                match sign {
                    b'+' if h.new_left > 0 => {
                        h.lines.push(line_json("+", None, Some(h.new), text));
                        (h.new, h.new_left) = (h.new + 1, h.new_left - 1);
                        patch.added += 1;
                    }
                    b'-' if h.old_left > 0 => {
                        h.lines.push(line_json("-", Some(h.old), None, text));
                        (h.old, h.old_left) = (h.old + 1, h.old_left - 1);
                        patch.removed += 1;
                    }
                    b' ' if h.old_left > 0 && h.new_left > 0 => {
                        h.lines.push(line_json(" ", Some(h.old), Some(h.new), text));
                        (h.old, h.old_left, h.new, h.new_left) = (h.old + 1, h.old_left - 1, h.new + 1, h.new_left - 1);
                    }
                    // Not what the header promised: the patch is cut or garbled from here.
                    _ => {
                        patch.truncated = true;
                        break;
                    }
                }
                total += 1;
                continue;
            }
        }
        // Between hunks, or in the file's header.
        if let Some(rest) = line.strip_prefix(b"@@ ") {
            patch.hunks.extend(hunk.take().map(Hunk::json));
            let Some(head) = parse_hunk_header(rest) else {
                patch.truncated = true;
                break;
            };
            hunk = Some(Hunk { old: head.0, old_left: head.1, new: head.2, new_left: head.3, head, lines: Vec::new() });
        } else if hunk.is_none() && patch.hunks.is_empty() {
            if line.starts_with(b"new file mode ") {
                patch.status = "added";
            } else if line.starts_with(b"deleted file mode ") {
                patch.status = "deleted";
            } else if line.starts_with(b"rename from ") {
                patch.status = "renamed";
            } else if line.starts_with(b"Binary files ") && line.ends_with(b" differ") {
                patch.binary = true;
            }
        }
    }
    patch.hunks.extend(hunk.map(Hunk::json));
    patch
}

/// A patch for one file into hunks. `cut` says git's output stopped at the byte cap: what
/// follows the last line break is dropped and the patch is `truncated`. When git gives two
/// sections (a rename it did not pair: the old file deleted, the new one added), the one that is
/// not the deletion is the file asked for. `None` when there is no patch at all.
fn parse_patch(out: &[u8], cut: bool) -> Option<Patch> {
    let out = if cut { &out[..out.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1)] } else { out };
    let mut lines: Vec<&[u8]> = out.split(|b| *b == b'\n').collect();
    if lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    // Only a line at column 0 starts a section: every content line has a sign before it.
    let starts: Vec<usize> = lines.iter().enumerate().filter(|(_, l)| l.starts_with(b"diff --git ")).map(|(i, _)| i).collect();
    let mut sections: Vec<Patch> = starts.iter().enumerate().map(|(n, start)| parse_section(&lines[*start..starts.get(n + 1).copied().unwrap_or(lines.len())], MAX_LINES)).collect();
    if sections.is_empty() {
        return None;
    }
    let pick = sections.iter().position(|p| p.status != "deleted").unwrap_or(0);
    let mut patch = sections.swap_remove(pick);
    patch.truncated |= cut;
    Some(patch)
}

// ---------------------------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------------------------

/// A path a client may send back as it is: valid UTF-8 without control characters.
fn exact(path: &[u8]) -> Option<&str> {
    std::str::from_utf8(path).ok().filter(|s| !s.chars().any(char::is_control))
}

/// What `git.diff` accepts: a relative path inside the work tree, without `.`, `..` or empty
/// components, without NUL or other control characters, at most [`PATH_MAX`] bytes.
fn valid_path(path: &str) -> bool {
    !path.is_empty() && path.len() <= PATH_MAX && !path.chars().any(char::is_control) && path.split('/').all(|c| !c.is_empty() && c != "." && c != "..")
}

/// The path to show: itself when exact, else a display form (lossy, control characters dropped).
fn shown(path: &[u8]) -> String {
    match exact(path) {
        Some(s) => s.to_string(),
        None => clotho_vt::printable(&String::from_utf8_lossy(path), PATH_MAX),
    }
}

fn entry_json(e: &Entry) -> Value {
    let diffable = |p: &[u8]| exact(p).is_some_and(valid_path);
    let mut v = Map::new();
    v.insert("path".into(), json!(shown(&e.path)));
    if let Some(old) = &e.old_path {
        v.insert("old_path".into(), json!(shown(old)));
    }
    v.insert("status".into(), json!(e.status));
    v.insert("added".into(), json!(e.added));
    v.insert("removed".into(), json!(e.removed));
    v.insert("binary".into(), json!(e.binary));
    v.insert("diffable".into(), json!(diffable(&e.path) && e.old_path.as_deref().is_none_or(diffable)));
    Value::Object(v)
}

// ---------------------------------------------------------------------------------------------
// Untracked files
// ---------------------------------------------------------------------------------------------

/// Open `rel` under `root` for reading without following a symlink anywhere along it (a
/// directory could be swapped for a link between git listing the file and this read), and
/// without waiting on a FIFO.
fn open_beneath(root: &Path, rel: &[u8]) -> std::io::Result<std::fs::File> {
    use std::os::fd::{AsRawFd, FromRawFd};
    let invalid = || std::io::Error::from(std::io::ErrorKind::InvalidInput);
    let mut at = std::fs::File::open(root)?;
    let parts: Vec<&[u8]> = rel.split(|b| *b == b'/').collect();
    for (n, part) in parts.iter().enumerate() {
        if part.is_empty() || *part == b"." || *part == b".." {
            return Err(invalid());
        }
        let name = std::ffi::CString::new(*part).map_err(|_| invalid())?;
        let dir = if n + 1 < parts.len() { libc::O_DIRECTORY } else { 0 };
        // SAFETY: `at` is an open descriptor and `name` a NUL-ended string, both alive for the call.
        let fd = unsafe { libc::openat(at.as_raw_fd(), name.as_ptr(), libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK | dir) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `fd` was just opened and nothing else owns it.
        at = unsafe { std::fs::File::from_raw_fd(fd) };
    }
    Ok(at)
}

/// What was read of an untracked file.
#[derive(Debug, PartialEq, Eq)]
enum Content {
    /// A NUL near its start, or over [`BIG_FILE`].
    Binary,
    /// Its first bytes (at most what was asked for), and whether that is all of it.
    Text { data: Vec<u8>, whole: bool },
}

/// Read at most `most` bytes of the untracked file `rel`. Only a regular file is read.
fn read_untracked(root: &Path, rel: &[u8], most: usize) -> std::io::Result<Content> {
    use std::io::Read;
    let file = open_beneath(root, rel)?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput));
    }
    if meta.len() > BIG_FILE {
        return Ok(Content::Binary);
    }
    let mut data = Vec::new();
    file.take(most as u64 + 1).read_to_end(&mut data)?;
    if data[..data.len().min(SNIFF)].contains(&0) {
        return Ok(Content::Binary);
    }
    let whole = data.len() <= most;
    data.truncate(most);
    Ok(Content::Text { data, whole })
}

/// The lines git would count as added for a new file with this content.
fn count_lines(data: &[u8]) -> u64 {
    let breaks = data.iter().filter(|b| **b == b'\n').count() as u64;
    breaks + u64::from(data.last().is_some_and(|b| *b != b'\n'))
}

/// Count the untracked entries' lines, within the per-run bounds and the deadline. What is not
/// counted (past a bound, too long, not a regular file) keeps `added: None`.
fn count_untracked(root: &Path, entries: &mut [Entry], deadline: Instant) {
    let (mut files, mut bytes) = (0usize, 0usize);
    for e in entries.iter_mut().filter(|e| e.status == "untracked") {
        if files >= UNTRACKED_FILES || bytes >= UNTRACKED_RUN || Instant::now() >= deadline {
            break;
        }
        files += 1;
        match read_untracked(root, &e.path, UNTRACKED_FILE) {
            Ok(Content::Binary) => e.binary = true,
            Ok(Content::Text { data, whole }) => {
                bytes += data.len();
                if whole {
                    (e.added, e.removed) = (Some(count_lines(&data)), Some(0));
                }
            }
            Err(_) => {}
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The change token
// ---------------------------------------------------------------------------------------------

/// What the change token is made from: it is the same while nothing a client shows of the
/// changes (the lists, the counts, any file's diff) can have changed, and differs after an edit
/// that leaves every count as it was. Built from what a run reads anyway, and from file stamps:
/// no git call of its own.
struct Token(sha2::Sha256);

impl Token {
    /// Starts with HEAD's commit and the base (its commit and name).
    fn new(head: Option<&str>, base: Option<&Base>) -> Token {
        let mut token = Token(Default::default());
        token.field(head.map(str::as_bytes));
        token.field(base.map(|b| b.sha.as_bytes()));
        token.field(base.map(|b| b.name.as_bytes()));
        token
    }

    /// One input, with its length, so that two inputs never read as one.
    fn field(&mut self, bytes: Option<&[u8]>) {
        use sha2::Digest;
        match bytes {
            None => self.0.update([0]),
            Some(bytes) => {
                self.0.update([1]);
                self.0.update((bytes.len() as u64).to_le_bytes());
                self.0.update(bytes);
            }
        }
    }

    /// A file's size and modification time (in nanoseconds), or that it isn't there. A link is
    /// not followed.
    fn stamp(&mut self, path: &Path) {
        use std::os::unix::fs::MetadataExt;
        let stamp = std::fs::symlink_metadata(path).ok().map(|m| [m.size().to_le_bytes(), m.mtime().to_le_bytes(), m.mtime_nsec().to_le_bytes()].concat());
        self.field(stamp.as_deref());
    }

    /// The index (restaging the same content changes neither a count nor a status letter), and
    /// each changed path of the work tree, in path order, up to [`TOKEN_PATHS`] of them.
    fn stamps(&mut self, root: &Path, entries: &[Entry]) {
        match crate::git::locate(root).filter(|loc| loc.root == root) {
            Some(loc) => self.stamp(&loc.gitdir.join("index")),
            None => self.field(None),
        }
        let mut paths: Vec<&[u8]> = entries.iter().map(|e| e.path.as_slice()).collect();
        paths.sort_unstable();
        for path in paths.into_iter().take(TOKEN_PATHS) {
            self.field(Some(path));
            self.stamp(&root.join(OsStr::from_bytes(path)));
        }
    }

    /// 16 hex digits.
    fn finish(self) -> String {
        use sha2::Digest;
        self.0.finalize()[..8].iter().map(|b| format!("{b:02x}")).collect()
    }
}

// ---------------------------------------------------------------------------------------------
// The two groups
// ---------------------------------------------------------------------------------------------

fn os_args<'a>(head: &[&'a str], tail: &[&'a [u8]]) -> Vec<&'a OsStr> {
    head.iter().map(|s| OsStr::new(*s)).chain(tail.iter().map(|b| OsStr::from_bytes(b))).collect()
}

/// `status` for the whole work tree, or for `paths` only: the entries, and git's output as it
/// came (every path with its status letters and blob ids).
async fn status(run: &Run<'_>, paths: &[&[u8]]) -> Result<(Vec<Entry>, Vec<u8>), Fail> {
    let mut tail: Vec<&[u8]> = Vec::new();
    if !paths.is_empty() {
        tail.push(b"--");
        tail.extend_from_slice(paths);
    }
    let args = os_args(&["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=all"], &tail);
    let raw = run.ok(&args, run.opts.status_cap).await?;
    let mut entries = parse_status(&raw);
    // A path removed from the index with a new file in its place is listed twice: the file that
    // is there now is the one to show.
    let untracked: HashSet<Vec<u8>> = entries.iter().filter(|e| e.status == "untracked").map(|e| e.path.clone()).collect();
    if !untracked.is_empty() {
        entries.retain(|e| e.status == "untracked" || !untracked.contains(&e.path));
    }
    Ok((entries, raw))
}

/// The uncommitted files, whether the tracked ones' lines were counted, and the change token
/// (`base` only goes into the token).
async fn uncommitted(run: &Run<'_>, head: Option<&str>, base: Option<&Base>) -> Result<(Vec<Entry>, bool, String), Fail> {
    let mut token = Token::new(head, base);
    let (mut entries, raw) = status(run, &[]).await?;
    token.field(Some(&raw));
    drop(raw);
    // The count's output, or that there was none.
    let mut numstat = None;
    let paths: Vec<&[u8]> = entries.iter().filter(|e| e.status != "untracked").flat_map(|e| std::iter::once(e.path.as_slice()).chain(e.old_path.as_deref())).collect();
    let tracked = entries.iter().filter(|e| e.status != "untracked").count();
    let mut counted = tracked <= MAX_COUNTED && paths.iter().map(|p| p.len() + 1).sum::<usize>() <= MAX_ARG_BYTES;
    if counted && tracked > 0 {
        let tree = run.tree(head).await?;
        let mut tail: Vec<&[u8]> = vec![tree.as_bytes(), b"--"];
        tail.extend_from_slice(&paths);
        let args = os_args(&[&["diff-index", "--numstat", "-z", "-M"][..], &DIFF_FLAGS[..]].concat(), &tail);
        // Half the budget at most, so a slow count still leaves time for the rest.
        match run.git(&args, TREE_CAP, run.opts.budget / 2).await {
            Err(Fail::Run(gitrun::Error::Timeout)) => counted = false,
            Ok(out) if out.truncated => counted = false,
            out => {
                let out = run.whole(out?)?;
                let rows = parse_numstat(&out);
                drop(paths);
                apply_counts(&mut entries, rows);
                numstat = Some(out);
            }
        }
    }
    token.field(numstat.as_deref());
    drop(numstat);
    let (root, deadline) = (run.repo.root().to_path_buf(), run.deadline);
    let (entries, token) = tokio::task::spawn_blocking(move || {
        count_untracked(&root, &mut entries, deadline);
        token.stamps(&root, &entries);
        (entries, token.finish())
    })
    .await
    .map_err(|e| Fail::Run(gitrun::Error::Spawn(e.to_string())))?;
    Ok((entries, counted, token))
}

/// The commits and files on HEAD since it left the base.
struct Branch {
    merge_base: String,
    commits: u64,
    entries: Vec<Entry>,
}

/// The merge base of HEAD and the base, or why there is none to speak of (`no_base`,
/// `no_merge_base`).
async fn merge_base(run: &Run<'_>, head: Option<&str>, base: Option<&Base>) -> Result<Result<String, &'static str>, Fail> {
    let (Some(head), Some(base)) = (head, base) else { return Ok(Err("no_base")) };
    if !is_sha(head) || !is_sha(&base.sha) {
        return Ok(Err("no_base"));
    }
    let out = run.git(&["merge-base", head, &base.sha].map(OsStr::new), 256, Duration::MAX).await?;
    if out.code == Some(1) && out.stdout.is_empty() {
        return Ok(Err("no_merge_base"));
    }
    let sha = String::from_utf8_lossy(&run.whole(out)?).trim().to_string();
    Ok(if is_sha(&sha) { Ok(sha) } else { Err("no_merge_base") })
}

async fn branch(run: &Run<'_>, head: Option<&str>, base: Option<&Base>) -> Result<Result<Branch, &'static str>, Fail> {
    let merge_base = match merge_base(run, head, base).await? {
        Ok(sha) => sha,
        Err(why) => return Ok(Err(why)),
    };
    let head = head.unwrap_or_default();
    let range = format!("{merge_base}..{head}");
    let count = run.ok(&["rev-list", "--count", &range].map(OsStr::new), 256).await?;
    let commits = String::from_utf8_lossy(&count).trim().parse().map_err(|_| Fail::Git("git gave no commit count".into()))?;
    let args = [&["diff-tree", "-r", "--raw", "--numstat", "-z", "-M"][..], &DIFF_FLAGS[..], &[&merge_base, head][..]].concat();
    let args: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
    let entries = parse_tree(&run.ok(&args, TREE_CAP).await?);
    Ok(Ok(Branch { merge_base, commits, entries }))
}

/// A group's line totals: what was counted, summed (a binary or uncounted file adds nothing), or
/// null when the tracked files were not counted at all.
fn totals(entries: &[Entry], counted: bool) -> (Value, Value) {
    if !counted {
        return (Value::Null, Value::Null);
    }
    let sum = |f: fn(&Entry) -> Option<u64>| entries.iter().filter_map(f).sum::<u64>();
    (json!(sum(|e| e.added)), json!(sum(|e| e.removed)))
}

/// The `changes` summary for a pane's `git` object. `head` is HEAD's commit (`None` while it is
/// unborn) and `base` the branch to compare with (`None` on the default branch, or with none).
/// Its `token` is the one [`list`] gives for the same tree.
pub async fn summary(repo: &Repo, head: Option<&str>, base: Option<&Base>) -> Summary {
    summary_with(repo, head, base, Opts::default()).await
}

async fn summary_with(repo: &Repo, head: Option<&str>, base: Option<&Base>, opts: Opts) -> Summary {
    let run = Run::new(repo, opts);
    let (entries, counted, token) = match uncommitted(&run, head, base).await {
        Ok(found) => found,
        Err(fail) => return Summary::none(fail.reason()),
    };
    let (added, removed) = totals(&entries, counted);
    // The branch part failing leaves the uncommitted part standing, with the reason beside it.
    let (branch, reason) = match branch(&run, head, base).await {
        Ok(Ok(b)) => {
            let (added, removed) = totals(&b.entries, true);
            let name = clotho_vt::printable(base.map(|b| b.name.as_str()).unwrap_or_default(), NAME_MAX);
            (json!({"base": name, "commits": b.commits, "files": b.entries.len(), "added": added, "removed": removed}), None)
        }
        Ok(Err(_)) => (Value::Null, None),
        Err(fail) => (Value::Null, Some(fail.reason())),
    };
    let changes = json!({"uncommitted": {"files": entries.len(), "added": added, "removed": removed}, "branch": branch, "reason": reason, "token": token});
    Summary { changes: Some(changes), reason: None }
}

/// A group's files for `git.changes`: sorted by path and cut to `limit`.
fn group_json(mut entries: Vec<Entry>, counted: bool, limit: usize) -> Map<String, Value> {
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    let (added, removed) = totals(&entries, counted);
    let mut group = Map::new();
    group.insert("files".into(), entries.iter().take(limit).map(entry_json).collect());
    group.insert("total".into(), json!(entries.len()));
    group.insert("added".into(), added);
    group.insert("removed".into(), removed);
    group.insert("truncated".into(), json!(entries.len() > limit));
    group
}

/// Both groups' files for `git.changes`: `{uncommitted, branch_changes, branch_reason, token}`
/// (the caller adds `root`, `branch` and `head`). `limit` is the most files per group. `token`
/// (16 hex digits) is the summary's `changes.token` for the same tree, whatever the limit.
/// `branch_changes` is null with `branch_reason` saying why: `no_base`, `no_merge_base`, or what
/// went wrong (`timeout`, `too_large`, `partial_clone`, `error`).
pub async fn list(repo: &Repo, head: Option<&str>, base: Option<&Base>, limit: usize) -> Result<Value, (&'static str, String)> {
    list_with(repo, head, base, limit, Opts::default()).await
}

async fn list_with(repo: &Repo, head: Option<&str>, base: Option<&Base>, limit: usize, opts: Opts) -> Result<Value, (&'static str, String)> {
    let limit = limit.clamp(1, MAX_LIMIT);
    let run = Run::new(repo, opts);
    let (entries, counted, token) = uncommitted(&run, head, base).await.map_err(Fail::error)?;
    let (branch_changes, branch_reason) = match branch(&run, head, base).await {
        Ok(Ok(b)) => {
            let mut group = group_json(b.entries, true, limit);
            group.insert("base".into(), json!(clotho_vt::printable(base.map(|b| b.name.as_str()).unwrap_or_default(), NAME_MAX)));
            group.insert("base_head".into(), json!(short(base.map(|b| b.sha.as_str()).unwrap_or_default())));
            group.insert("merge_base".into(), json!(short(&b.merge_base)));
            group.insert("commits".into(), json!(b.commits));
            (Value::Object(group), None)
        }
        Ok(Err(why)) => (Value::Null, Some(why)),
        Err(fail) => (Value::Null, Some(fail.reason())),
    };
    Ok(json!({"uncommitted": group_json(entries, counted, limit), "branch_changes": branch_changes, "branch_reason": branch_reason, "token": token}))
}

/// An untracked file as a diff: every line added.
fn untracked_patch(root: &Path, rel: &[u8]) -> std::io::Result<Patch> {
    let mut patch = Patch { status: "untracked", ..Patch::default() };
    let (mut data, whole) = match read_untracked(root, rel, PATCH_CAP)? {
        Content::Binary => {
            patch.binary = true;
            return Ok(patch);
        }
        Content::Text { data, whole } => (data, whole),
    };
    if !whole {
        // Cut mid-line: keep whole lines only.
        data.truncate(data.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1));
        patch.truncated = true;
    }
    let no_newline = data.last().is_some_and(|b| *b != b'\n');
    if data.last() == Some(&b'\n') {
        data.pop();
    } else if data.is_empty() {
        return Ok(patch);
    }
    let mut lines: Vec<Value> = Vec::new();
    for (n, line) in data.split(|b| *b == b'\n').enumerate() {
        if n >= MAX_LINES {
            patch.truncated = true;
            break;
        }
        lines.push(line_json("+", None, Some(n as u64 + 1), line));
    }
    if no_newline && !patch.truncated {
        if let Some(last) = lines.last_mut().and_then(Value::as_object_mut) {
            last.insert("no_newline".into(), json!(true));
        }
    }
    patch.added = lines.len() as u64;
    patch.hunks.push(json!({"old_start": 0, "old_lines": 0, "new_start": 1, "new_lines": lines.len(), "header": "", "lines": lines}));
    Ok(patch)
}

/// One file's diff for `git.diff`. `group` is `uncommitted` or `branch`; `path` (and `old_path`
/// for a rename) are as `git.changes` listed them; `context` is the lines around each change.
pub async fn diff(repo: &Repo, head: Option<&str>, base: Option<&Base>, group: &str, path: &str, old_path: Option<&str>, context: u64) -> Result<Value, (&'static str, String)> {
    diff_with(repo, head, base, group, path, old_path, context, Opts::default()).await
}

#[allow(clippy::too_many_arguments)]
async fn diff_with(repo: &Repo, head: Option<&str>, base: Option<&Base>, group: &str, path: &str, old_path: Option<&str>, context: u64, opts: Opts) -> Result<Value, (&'static str, String)> {
    if group != "uncommitted" && group != "branch" {
        return Err(("bad_request", "group must be \"uncommitted\" or \"branch\"".into()));
    }
    if context > MAX_CONTEXT {
        return Err(("bad_request", format!("context must be at most {MAX_CONTEXT}")));
    }
    if !valid_path(path) || !old_path.is_none_or(valid_path) {
        return Err(("bad_path", "the path must be relative, inside the repository, and as git.changes listed it".into()));
    }
    let not_changed = || ("not_changed", format!("{path} has no {group} changes"));
    let run = Run::new(repo, opts);
    let unified = format!("-U{context}");
    let mut paths: Vec<&[u8]> = vec![path.as_bytes()];
    paths.extend(old_path.map(str::as_bytes));

    let (patch, was) = if group == "uncommitted" {
        // What status says about it decides how it is read, and whether it changed at all.
        let (entries, _) = status(&run, &paths).await.map_err(Fail::error)?;
        let entry = entries.into_iter().find(|e| e.path == path.as_bytes()).ok_or_else(not_changed)?;
        if entry.status == "untracked" {
            let (root, rel) = (repo.root().to_path_buf(), entry.path.clone());
            let read = tokio::task::spawn_blocking(move || untracked_patch(&root, &rel)).await;
            let patch = read.ok().and_then(Result::ok).ok_or(("bad_path", format!("{path} is not a file that can be read")))?;
            (patch, None)
        } else {
            let tree = run.tree(head).await.map_err(Fail::error)?;
            let mut tail: Vec<&[u8]> = vec![tree.as_bytes(), b"--"];
            tail.extend_from_slice(&paths);
            let args = os_args(&[&["diff-index", "-p", "-M", &unified, "--no-color"][..], &DIFF_FLAGS[..]].concat(), &tail);
            let mut patch = patch_of(&run, &args).await?.unwrap_or(Patch { status: "modified", ..Patch::default() });
            patch.status = entry.status;
            (patch, entry.old_path)
        }
    } else {
        let merge_base = merge_base(&run, head, base).await.map_err(Fail::error)?.map_err(|_| not_changed())?;
        let mut tail: Vec<&[u8]> = vec![merge_base.as_bytes(), head.unwrap_or_default().as_bytes(), b"--"];
        tail.extend_from_slice(&paths);
        let args = os_args(&[&["diff-tree", "-r", "-p", "-M", &unified, "--no-color"][..], &DIFF_FLAGS[..]].concat(), &tail);
        let patch = patch_of(&run, &args).await?.ok_or_else(not_changed)?;
        let was = (patch.status == "renamed").then(|| old_path.map(|p| p.as_bytes().to_vec())).flatten();
        (patch, was)
    };
    Ok(json!({
        "path": path,
        "old_path": was.as_deref().map(shown),
        "status": patch.status,
        "binary": patch.binary,
        "truncated": patch.truncated,
        "added": patch.added,
        "removed": patch.removed,
        "hunks": patch.hunks,
    }))
}

/// Run a patch command under the patch cap and read what it gave.
async fn patch_of(run: &Run<'_>, args: &[&OsStr]) -> Result<Option<Patch>, (&'static str, String)> {
    let out = run.git(args, PATCH_CAP, Duration::MAX).await.map_err(Fail::error)?;
    if out.truncated {
        return Ok(parse_patch(&out.stdout, true));
    }
    Ok(parse_patch(&run.whole(out).map_err(Fail::error)?, false))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};

    // ---- parsers, on fixed bytes ----

    const A: &str = "1111111111111111111111111111111111111111";
    const B: &str = "2222222222222222222222222222222222222222";

    fn e(path: &[u8], old: Option<&[u8]>, status: &'static str) -> Entry {
        Entry::new(path, old, status)
    }

    #[test]
    fn status_records() {
        let out = [
            format!("1 .M N... 100644 100644 100644 {A} {A} plain.txt\0").into_bytes(),
            format!("1 A. N... 000000 100644 100644 {A} {B} new file\twith a tab.txt\0").into_bytes(),
            format!("1 .D N... 100644 100644 000000 {A} {A} gone.txt\0").into_bytes(),
            format!("1 D. N... 100644 000000 000000 {A} {A} staged gone.txt\0").into_bytes(),
            format!("2 R. N... 100644 100644 100644 {A} {A} R100 new name.txt\0old name.txt\0").into_bytes(),
            format!("2 C. N... 100644 100644 100644 {A} {A} C100 copy.txt\0plain.txt\0").into_bytes(),
            format!("u UU N... 100644 100644 100644 100644 {A} {B} {A} both changed.txt\0").into_bytes(),
            b"1 .M N... 100644 100644 100644 1 1 caf\xe9.txt\0".to_vec(),
            b"? untracked dir/a b.txt\0".to_vec(),
            b"! ignored.o\0# branch.oid x\0garbage\0".to_vec(),
        ]
        .concat();
        assert_eq!(
            parse_status(&out),
            vec![
                e(b"plain.txt", None, "modified"),
                e(b"new file\twith a tab.txt", None, "added"),
                e(b"gone.txt", None, "deleted"),
                e(b"staged gone.txt", None, "deleted"),
                e(b"new name.txt", Some(b"old name.txt"), "renamed"),
                e(b"copy.txt", None, "added"),
                e(b"both changed.txt", None, "conflicted"),
                e(b"caf\xe9.txt", None, "modified"),
                e(b"untracked dir/a b.txt", None, "untracked"),
            ]
        );
        // Cut-off and empty output give what is whole.
        assert_eq!(parse_status(b""), vec![]);
        assert_eq!(parse_status(b"1 .M N... 100644"), vec![]);
        assert_eq!(parse_status(format!("2 R. N... 100644 100644 100644 {A} {A} R100 new.txt\0").as_bytes()), vec![]);
    }

    #[test]
    fn numstat_rows() {
        let rows = parse_numstat(b"3\t1\tsrc/a b.rs\0-\t-\tlogo.png\x000\t0\t\0old name.txt\0new\tname.txt\x0012\t0\tcaf\xe9.txt\0");
        let row = |path: &[u8], old: Option<&[u8]>, added, removed, binary| Num { path: path.to_vec(), old_path: old.map(<[u8]>::to_vec), added, removed, binary };
        assert_eq!(
            rows,
            vec![
                row(b"src/a b.rs", None, Some(3), Some(1), false),
                row(b"logo.png", None, None, None, true),
                row(b"new\tname.txt", Some(b"old name.txt"), Some(0), Some(0), false),
                row(b"caf\xe9.txt", None, Some(12), Some(0), false),
            ]
        );
        assert_eq!(parse_numstat(b""), vec![]);
        assert_eq!(parse_numstat(b"1\t2\t\0only old\0"), vec![], "a rename row cut short");
    }

    #[test]
    fn raw_records_then_numstat_rows() {
        let out = [
            format!(":100644 100644 {A} {B} M\0b.txt\0").into_bytes(),
            format!(":100644 100644 {A} {B} M\0bin\0").into_bytes(),
            format!(":100644 100644 {A} {A} R100\0a.txt\0:c.txt\0").into_bytes(),
            format!(":000000 100644 {A} {B} A\0new.txt\0").into_bytes(),
            format!(":100644 000000 {A} {B} D\0gone.txt\0").into_bytes(),
            b"1\t0\tb.txt\0-\t-\tbin\x000\t0\t\0a.txt\0:c.txt\x005\t0\tnew.txt\x000\t7\tgone.txt\0".to_vec(),
        ]
        .concat();
        let counted = |path: &[u8], old: Option<&[u8]>, status, added, removed, binary| Entry { added, removed, binary, ..e(path, old, status) };
        assert_eq!(
            parse_tree(&out),
            vec![
                counted(b"b.txt", None, "modified", Some(1), Some(0), false),
                counted(b"bin", None, "modified", None, None, true),
                counted(b":c.txt", Some(b"a.txt"), "renamed", Some(0), Some(0), false),
                counted(b"new.txt", None, "added", Some(5), Some(0), false),
                counted(b"gone.txt", None, "deleted", Some(0), Some(7), false),
            ]
        );
        assert_eq!(parse_tree(b""), vec![]);
    }

    #[test]
    fn paths_are_exact_or_not_diffable() {
        let json = |path: &[u8], old: Option<&[u8]>| entry_json(&e(path, old, "modified"));
        let v = json(b"src/a b.rs", None);
        assert_eq!((v["path"].as_str(), v["diffable"].as_bool(), v.get("old_path")), (Some("src/a b.rs"), Some(true), None));
        let v = json("d\u{e9}j\u{e0}/\u{1f600}.txt".as_bytes(), Some(b"was.txt"));
        assert_eq!((v["path"].as_str(), v["old_path"].as_str(), v["diffable"].as_bool()), (Some("d\u{e9}j\u{e0}/\u{1f600}.txt"), Some("was.txt"), Some(true)));
        // A tab, a non-UTF-8 byte, an escape: shown without them, and not to be sent back.
        let v = json(b"a\tb.txt", None);
        assert_eq!((v["path"].as_str(), v["diffable"].as_bool()), (Some("ab.txt"), Some(false)));
        let v = json(b"caf\xe9.txt", None);
        assert_eq!((v["path"].as_str(), v["diffable"].as_bool()), (Some("caf\u{fffd}.txt"), Some(false)));
        let v = json(b"ok.txt", Some(b"\x1b[31mold.txt"));
        assert_eq!((v["old_path"].as_str(), v["diffable"].as_bool()), (Some("[31mold.txt"), Some(false)));
        // An untracked directory git would not look inside (a nested repository).
        assert_eq!(json(b"nested/", None)["diffable"], json!(false));

        for ok in ["a", "a/b.txt", "a b/c", ".hidden/..x", "d\u{e9}j\u{e0}"] {
            assert!(valid_path(ok), "{ok:?}");
        }
        let long = "x/".repeat(PATH_MAX);
        for bad in ["", "/etc/passwd", "../x", "a/../b", "a/..", "./a", "a//b", "a/", "a\0b", "a\nb", "a\tb", long.as_str()] {
            assert!(!valid_path(bad), "{bad:?}");
        }
    }

    const PATCH: &str = "diff --git a/src/a.rs b/src/a.rs\n\
index 1111111..2222222 100644\n\
--- a/src/a.rs\n\
+++ b/src/a.rs\n\
@@ -1,4 +1,5 @@\n one\n-two\n+TWO\n+two and a half\n three\n four\n\
@@ -10 +11,2 @@ fn main() {\n-ten\n+TEN\n+eleven\n\
@@ -20,3 +22,2 @@ impl X\n twenty\n--- not a header\n last\n\\ No newline at end of file\n";

    #[test]
    fn hunks_are_numbered_line_by_line() {
        let p = parse_patch(PATCH.as_bytes(), false).unwrap();
        assert_eq!((p.status, p.binary, p.truncated, p.added, p.removed), ("modified", false, false, 4, 3));
        assert_eq!(p.hunks.len(), 3);
        let head = |h: &Value| (h["old_start"].as_u64().unwrap(), h["old_lines"].as_u64().unwrap(), h["new_start"].as_u64().unwrap(), h["new_lines"].as_u64().unwrap(), h["header"].as_str().unwrap().to_string());
        assert_eq!(head(&p.hunks[0]), (1, 4, 1, 5, String::new()));
        assert_eq!(head(&p.hunks[1]), (10, 1, 11, 2, "fn main() {".into()));
        assert_eq!(head(&p.hunks[2]), (20, 3, 22, 2, "impl X".into()));
        let lines = |h: &Value| -> Vec<(String, Option<u64>, Option<u64>, String)> {
            h["lines"].as_array().unwrap().iter().map(|l| (l["t"].as_str().unwrap().into(), l["old"].as_u64(), l["new"].as_u64(), l["text"].as_str().unwrap().into())).collect()
        };
        let l = |t: &str, old, new, text: &str| (t.to_string(), old, new, text.to_string());
        assert_eq!(
            lines(&p.hunks[0]),
            vec![l(" ", Some(1), Some(1), "one"), l("-", Some(2), None, "two"), l("+", None, Some(2), "TWO"), l("+", None, Some(3), "two and a half"), l(" ", Some(3), Some(4), "three"), l(" ", Some(4), Some(5), "four")]
        );
        assert_eq!(lines(&p.hunks[1]), vec![l("-", Some(10), None, "ten"), l("+", None, Some(11), "TEN"), l("+", None, Some(12), "eleven")]);
        // A removed line that reads `-- not a header` is content, counted off against the hunk.
        assert_eq!(lines(&p.hunks[2]), vec![l(" ", Some(20), Some(22), "twenty"), l("-", Some(21), None, "-- not a header"), l(" ", Some(22), Some(23), "last")]);
        // The marker belongs to the line before it, and only that line carries it.
        let last = p.hunks[2]["lines"].as_array().unwrap();
        assert_eq!(last[2]["no_newline"], json!(true));
        assert!(last[1].get("no_newline").is_none() && last[1].get("cut").is_none());
    }

    #[test]
    fn the_no_newline_marker_on_either_side() {
        let patch = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n";
        let p = parse_patch(patch.as_bytes(), false).unwrap();
        let lines = p.hunks[0]["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 2);
        assert_eq!((lines[0]["text"].as_str(), &lines[0]["no_newline"]), (Some("old"), &json!(true)));
        assert_eq!((lines[1]["text"].as_str(), &lines[1]["no_newline"]), (Some("new"), &json!(true)));
    }

    #[test]
    fn file_headers_give_the_status() {
        let p = parse_patch(b"diff --git a/logo.png b/logo.png\nindex 1111111..2222222 100644\nBinary files a/logo.png and b/logo.png differ\n", false).unwrap();
        assert_eq!((p.status, p.binary, p.hunks.len()), ("modified", true, 0));
        let p = parse_patch(b"diff --git a/n b/n\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+hi\n", false).unwrap();
        assert_eq!((p.status, p.added, p.removed), ("added", 1, 0));
        assert_eq!((&p.hunks[0]["old_start"], &p.hunks[0]["old_lines"], &p.hunks[0]["lines"][0]["new"]), (&json!(0), &json!(0), &json!(1)));
        let p = parse_patch(b"diff --git a/o b/n\nsimilarity index 100%\nrename from o\nrename to n\n", false).unwrap();
        assert_eq!((p.status, p.hunks.len()), ("renamed", 0));
        // A rename git did not pair: the deletion of the old file is not the file asked for.
        let two = "diff --git a/o b/o\ndeleted file mode 100644\n--- a/o\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\ndiff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+here\n";
        let p = parse_patch(two.as_bytes(), false).unwrap();
        assert_eq!((p.status, p.added, p.removed), ("added", 1, 0));
        // A content line that reads like a file header changes nothing.
        let p = parse_patch(b"diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-deleted file mode 1\n+Binary files a and b differ\n", false).unwrap();
        assert_eq!((p.status, p.binary), ("modified", false));
        assert_eq!(parse_patch(b"", false), None);
        assert_eq!(parse_patch(b"* Unmerged path f\n", false), None);
    }

    #[test]
    fn long_lines_and_long_patches_are_cut() {
        let long = "\u{e9}".repeat(MAX_LINE_CHARS + 50);
        let mut bytes = format!("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-{long}\n+short\n \u{e9}").into_bytes();
        // A byte that is not UTF-8 becomes U+FFFD.
        bytes.extend_from_slice(b"\xff\n");
        let p = parse_patch(&bytes, false).unwrap();
        let lines = p.hunks[0]["lines"].as_array().unwrap();
        assert_eq!(lines[0]["text"].as_str().unwrap().chars().count(), MAX_LINE_CHARS);
        assert_eq!(lines[0]["cut"], json!(true));
        assert!(lines[1].get("cut").is_none());
        assert_eq!(lines[2]["text"].as_str(), Some("\u{e9}\u{fffd}"));

        // Cut at the byte cap in the middle of a line: that line is dropped.
        let p = parse_patch(b"diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n one\n-two\n+TW", true).unwrap();
        assert!(p.truncated);
        assert_eq!((p.hunks[0]["lines"].as_array().unwrap().len(), p.added, p.removed), (2, 0, 1));

        // The line cap.
        let body: String = (0..10).map(|n| format!("+line {n}\n")).collect();
        let patch = format!("diff --git a/f b/f\n--- /dev/null\n+++ b/f\n@@ -0,0 +1,10 @@\n{body}");
        let lines: Vec<&[u8]> = patch.as_bytes().split(|b| *b == b'\n').collect();
        let p = parse_section(&lines, 4);
        assert_eq!((p.truncated, p.added, p.hunks[0]["lines"].as_array().unwrap().len()), (true, 4, 4));

        // A hunk whose lines are not what its header promised stops there.
        let p = parse_patch(b"diff --git a/f b/f\n@@ -1,2 +1,2 @@\n one\n@@ -9 +9 @@\n", false).unwrap();
        assert!(p.truncated);
        assert!(parse_patch(b"diff --git a/f b/f\n@@ -x +1 @@\n", false).unwrap().truncated);
    }

    #[test]
    fn failures_map_to_reasons() {
        assert_eq!(classify("fatal: detected dubious ownership in repository at '/x'\nTo add an exception…", false).reason(), "unsafe");
        assert_eq!(classify("fatal: detected dubious ownership in repository at '/x'", true).reason(), "unsafe");
        assert_eq!(classify("fatal: unable to read 1234", true).reason(), "partial_clone");
        assert_eq!(classify("\nfatal: bad object 1234\nmore", false), Fail::Git("fatal: bad object 1234".into()));
        assert_eq!(classify("", false).error(), ("git_failed", "git failed".into()));
        assert_eq!(Fail::TooLarge.reason(), "too_large");
        for (err, why, code) in [
            (gitrun::Error::NoGit, "no_git", "no_git"),
            (gitrun::Error::Unsupported("old".into()), "git_unsupported", "git_unsupported"),
            (gitrun::Error::Timeout, "timeout", "timeout"),
            (gitrun::Error::Spawn("x".into()), "error", "git_failed"),
            (gitrun::Error::Config("x".into()), "error", "git_failed"),
        ] {
            assert_eq!((reason(&err), error(&err).0), (why, code), "{err:?}");
        }
    }

    #[test]
    fn untracked_content() {
        assert_eq!(count_lines(b""), 0);
        assert_eq!(count_lines(b"a\nb\n"), 2);
        assert_eq!(count_lines(b"a\nb"), 2);
        assert_eq!(count_lines(b"\n"), 1);
    }

    // ---- real git, on temp repositories ----

    /// Generous, so a loaded machine does not turn these into timeout tests.
    const OPTS: Opts = Opts { budget: Duration::from_secs(60), status_cap: STATUS_CAP };

    fn tmp() -> tempfile::TempDir {
        tempfile::Builder::new().prefix("clt").tempdir_in("/tmp").unwrap()
    }

    /// Test setup: git the ordinary way (the repo's config applies), but without the user's.
    fn git_command(dir: &Path, args: &[&str]) -> Command {
        let mut cmd = Command::new(gitrun::find_git().expect("these tests need git installed"));
        cmd.args(["-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", "-c", "core.autocrlf=false"])
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
            .stdin(Stdio::null());
        cmd
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = git_command(dir, args).output().unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn write(p: &Path, s: impl AsRef<[u8]>) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    fn commit(root: &Path, message: &str) -> String {
        git(root, &["add", "-A"]);
        git(root, &["commit", "-q", "--allow-empty", "-m", message]);
        git(root, &["rev-parse", "HEAD"])
    }

    /// A repository at `<tmp>/repo` with one commit on `main`: `a.txt` (three lines), `b.txt`,
    /// `gone.txt`, `old.txt` (ten lines) and the binary `logo.bin`. Returns its root and HEAD.
    fn fixture(tmp: &Path) -> (PathBuf, String) {
        let root = tmp.join("repo");
        std::fs::create_dir_all(&root).unwrap();
        git(&root, &["init", "-q"]);
        write(&root.join("a.txt"), "one\ntwo\nthree\n");
        write(&root.join("b.txt"), "b\n");
        write(&root.join("gone.txt"), "going\ngoing\n");
        write(&root.join("old.txt"), (0..10).map(|n| format!("line {n}\n")).collect::<String>());
        write(&root.join("logo.bin"), b"\x89PNG\0\x01\x02one");
        let head = commit(&root, "one");
        (root, head)
    }

    async fn open(root: &Path) -> Repo {
        Repo::open(root).await.unwrap()
    }

    fn base(sha: &str) -> Base {
        Base { name: "origin/main".into(), sha: sha.into() }
    }

    fn file<'a>(group: &'a Value, path: &str) -> &'a Value {
        group["files"].as_array().unwrap().iter().find(|f| f["path"] == path).unwrap_or_else(|| panic!("no {path} in {group}"))
    }

    fn paths(group: &Value) -> Vec<&str> {
        group["files"].as_array().unwrap().iter().map(|f| f["path"].as_str().unwrap()).collect()
    }

    fn texts(diff: &Value) -> Vec<String> {
        diff["hunks"].as_array().unwrap().iter().flat_map(|h| h["lines"].as_array().unwrap()).map(|l| format!("{}{}", l["t"].as_str().unwrap(), l["text"].as_str().unwrap())).collect()
    }

    /// A summary's `changes` without its token, which has to be there: 16 hex digits.
    fn counts(s: &Summary) -> Option<Value> {
        let mut changes = s.changes.clone()?;
        let token = changes.as_object_mut().unwrap().remove("token").expect("a summary has a token");
        assert!(is_token(&token), "{token}");
        Some(changes)
    }

    fn is_token(v: &Value) -> bool {
        v.as_str().is_some_and(|t| t.len() == 16 && t.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
    }

    /// The summary's token and the list's, which have to be the same one.
    async fn token(repo: &Repo, head: Option<&str>, base: Option<&Base>) -> String {
        let s = summary_with(repo, head, base, OPTS).await;
        let l = list_with(repo, head, base, 1, OPTS).await.unwrap();
        let token = &s.changes.as_ref().unwrap()["token"];
        assert!(is_token(token), "{token}");
        assert_eq!(token, &l["token"]);
        token.as_str().unwrap().to_string()
    }

    /// Give `path` the modification time `secs` after 2026-01-01, so two writes in one test
    /// never share a time by accident and a rewrite can be given its old one back.
    fn set_mtime(path: &Path, secs: u64) {
        let at = std::time::UNIX_EPOCH + Duration::from_secs(1_767_225_600 + secs);
        std::fs::File::options().write(true).open(path).unwrap().set_modified(at).unwrap();
    }

    #[tokio::test]
    async fn the_token_follows_what_the_counts_do_not_show() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        let repo = open(&root).await;
        let index = root.join(".git/index");

        // A clean tree has one too, and an untouched tree keeps its token from run to run.
        let clean = token(&repo, Some(&head), None).await;
        assert_eq!(token(&repo, Some(&head), None).await, clean);

        write(&root.join("a.txt"), "one\nTWO\nthree\n");
        write(&root.join("new.txt"), "n\n");
        set_mtime(&root.join("a.txt"), 100);
        set_mtime(&root.join("new.txt"), 100);
        let dirty = token(&repo, Some(&head), None).await;
        assert_ne!(dirty, clean);
        assert_eq!(token(&repo, Some(&head), None).await, dirty);
        let counts_before = counts(&summary_with(&repo, Some(&head), None, OPTS).await);
        assert_eq!(counts_before, Some(json!({"uncommitted": {"files": 2, "added": 2, "removed": 1}, "branch": null, "reason": null})));

        // Another line changed in place of the first: git's output, every count and the file's
        // size are as they were, and the token is not, by the file's time alone.
        write(&root.join("a.txt"), "one\ntwo\nTHREE\n");
        set_mtime(&root.join("a.txt"), 200);
        assert_eq!(counts(&summary_with(&repo, Some(&head), None, OPTS).await), counts_before);
        let swapped = token(&repo, Some(&head), None).await;
        assert_ne!(swapped, dirty);
        // The same for an untracked file, which git only names.
        write(&root.join("new.txt"), "m\n");
        set_mtime(&root.join("new.txt"), 200);
        let renewed = token(&repo, Some(&head), None).await;
        assert_ne!(renewed, swapped);
        assert_eq!(counts(&summary_with(&repo, Some(&head), None, OPTS).await), counts_before);

        // Staging a change without touching the file: no count moves, the token does (the
        // status letters and the index both changed).
        git(&root, &["add", "a.txt"]);
        let staged = token(&repo, Some(&head), None).await;
        assert_ne!(staged, renewed);
        assert_eq!(counts(&summary_with(&repo, Some(&head), None, OPTS).await), counts_before);
        // Nothing these runs do writes the index, so the token holds still after staging too.
        let before = std::fs::read(&index).unwrap();
        assert_eq!(token(&repo, Some(&head), None).await, staged);
        assert_untouched(&root, &before);

        // The base is part of it (its name and its commit), and so is HEAD.
        let on_base = token(&repo, Some(&head), Some(&base(&head))).await;
        assert_ne!(on_base, staged);
        assert_ne!(token(&repo, Some(&head), Some(&Base { name: "main".into(), sha: head.clone() })).await, on_base);
        let head2 = commit(&root, "two");
        assert_ne!(token(&repo, Some(&head2), None).await, clean);
    }

    /// The token is the same for every limit: the list is cut after it is made.
    #[tokio::test]
    async fn the_token_does_not_depend_on_the_limit() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        for n in 0..5 {
            write(&root.join(format!("u{n}.txt")), "x\n");
        }
        let repo = open(&root).await;
        let all = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        let two = list_with(&repo, Some(&head), None, 2, OPTS).await.unwrap();
        assert_eq!((two["uncommitted"]["truncated"].clone(), &two["token"]), (json!(true), &all["token"]));
        assert_eq!(all["token"].as_str().unwrap(), token(&repo, Some(&head), None).await);
    }

    /// Nothing these calls do may write to the repository.
    fn assert_untouched(root: &Path, index_before: &[u8]) {
        assert_eq!(std::fs::read(root.join(".git/index")).unwrap(), index_before, "the index was written");
        assert!(!root.join(".git/index.lock").exists());
    }

    #[tokio::test]
    async fn a_dirty_repo() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        write(&root.join("a.txt"), "one\nTWO\nthree\nfour\n");
        write(&root.join("b.txt"), "b\nstaged\n");
        git(&root, &["add", "b.txt"]);
        write(&root.join("b.txt"), "b\nstaged\nand unstaged\n");
        std::fs::remove_file(root.join("gone.txt")).unwrap();
        git(&root, &["mv", "old.txt", "new name.txt"]);
        write(&root.join("logo.bin"), b"\x89PNG\0\x01\x02two");
        write(&root.join("notes/todo.txt"), "first\nsecond\nlast without a newline");
        write(&root.join("notes/data.bin"), b"\0\0\0");
        write(&root.join("staged-new.txt"), "new\n");
        git(&root, &["add", "staged-new.txt"]);
        let index = std::fs::read(root.join(".git/index")).unwrap();
        let repo = open(&root).await;

        let s = summary_with(&repo, Some(&head), None, OPTS).await;
        assert_eq!(s.reason, None);
        assert_eq!(counts(&s), Some(json!({"uncommitted": {"files": 8, "added": 8, "removed": 3}, "branch": null, "reason": null})));

        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!((&l["branch_changes"], &l["branch_reason"]), (&Value::Null, &json!("no_base")));
        let u = &l["uncommitted"];
        assert_eq!(paths(u), ["a.txt", "b.txt", "gone.txt", "logo.bin", "new name.txt", "notes/data.bin", "notes/todo.txt", "staged-new.txt"]);
        assert_eq!((&u["total"], &u["added"], &u["removed"], &u["truncated"]), (&json!(8), &json!(8), &json!(3), &json!(false)));
        assert_eq!(file(u, "a.txt"), &json!({"path": "a.txt", "status": "modified", "added": 2, "removed": 1, "binary": false, "diffable": true}));
        assert_eq!(file(u, "b.txt"), &json!({"path": "b.txt", "status": "modified", "added": 2, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(u, "gone.txt"), &json!({"path": "gone.txt", "status": "deleted", "added": 0, "removed": 2, "binary": false, "diffable": true}));
        assert_eq!(file(u, "logo.bin"), &json!({"path": "logo.bin", "status": "modified", "added": null, "removed": null, "binary": true, "diffable": true}));
        assert_eq!(file(u, "new name.txt"), &json!({"path": "new name.txt", "old_path": "old.txt", "status": "renamed", "added": 0, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(u, "notes/data.bin"), &json!({"path": "notes/data.bin", "status": "untracked", "added": null, "removed": null, "binary": true, "diffable": true}));
        assert_eq!(file(u, "notes/todo.txt"), &json!({"path": "notes/todo.txt", "status": "untracked", "added": 3, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(u, "staged-new.txt"), &json!({"path": "staged-new.txt", "status": "added", "added": 1, "removed": 0, "binary": false, "diffable": true}));

        // The limit cuts the list, not the totals.
        let l = list_with(&repo, Some(&head), None, 3, OPTS).await.unwrap();
        let u = &l["uncommitted"];
        assert_eq!(paths(u), ["a.txt", "b.txt", "gone.txt"]);
        assert_eq!((&u["total"], &u["added"], &u["truncated"]), (&json!(8), &json!(8), &json!(true)));

        // One file's diff: staged and unstaged together.
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "b.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["path"], &d["old_path"], &d["status"], &d["binary"], &d["truncated"], &d["added"], &d["removed"]), (&json!("b.txt"), &Value::Null, &json!("modified"), &json!(false), &json!(false), &json!(2), &json!(0)));
        assert_eq!(texts(&d), [" b", "+staged", "+and unstaged"]);
        // Context is the caller's.
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, 0, OPTS).await.unwrap();
        assert_eq!(texts(&d), ["-two", "+TWO", "+four"]);
        assert_eq!(d["hunks"].as_array().unwrap().len(), 2);
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "gone.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["status"], texts(&d)), (&json!("deleted"), vec!["-going".to_string(), "-going".to_string()]));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "staged-new.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["status"], texts(&d)), (&json!("added"), vec!["+new".to_string()]));

        // A directory, a file that is not there, and git's own files: nothing changed there.
        for path in ["notes", "nope.txt", ".git/config", ".git/HEAD"] {
            let err = diff_with(&repo, Some(&head), None, "uncommitted", path, None, 3, OPTS).await.unwrap_err();
            assert_eq!(err.0, "not_changed", "{path}: {err:?}");
        }
        assert_untouched(&root, &index);
    }

    #[tokio::test]
    async fn a_staged_rename_with_old_path() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        git(&root, &["mv", "old.txt", "new.txt"]);
        let mut text = std::fs::read_to_string(root.join("new.txt")).unwrap();
        text.push_str("one more\n");
        write(&root.join("new.txt"), &text);
        let repo = open(&root).await;

        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(l["uncommitted"]["files"], json!([{"path": "new.txt", "old_path": "old.txt", "status": "renamed", "added": 1, "removed": 0, "binary": false, "diffable": true}]));

        // With the old path the diff is the rename's: only the line that changed.
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "new.txt", Some("old.txt"), 1, OPTS).await.unwrap();
        assert_eq!((&d["path"], &d["old_path"], &d["status"], &d["added"], &d["removed"]), (&json!("new.txt"), &json!("old.txt"), &json!("renamed"), &json!(1), &json!(0)));
        assert_eq!(texts(&d), [" line 9", "+one more"]);
        // Without it the file is all new.
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "new.txt", None, 1, OPTS).await.unwrap();
        assert_eq!((&d["old_path"], &d["status"], &d["added"]), (&Value::Null, &json!("added"), &json!(11)));
    }

    #[tokio::test]
    async fn a_branch_ahead_of_main() {
        let tmp = tmp();
        let (root, main) = fixture(tmp.path());
        git(&root, &["checkout", "-q", "-b", "feat"]);
        write(&root.join("a.txt"), "one\ntwo\nthree\nfour\n");
        write(&root.join("logo.bin"), b"\x89PNG\0\x01\x02feat");
        commit(&root, "two");
        git(&root, &["mv", "old.txt", "moved.txt"]);
        std::fs::remove_file(root.join("gone.txt")).unwrap();
        write(&root.join("added.txt"), "x\ny\n");
        let head = commit(&root, "three");
        // Main moves on too: the comparison is with where the branch left it.
        git(&root, &["checkout", "-q", "main"]);
        write(&root.join("b.txt"), "b on main\n");
        let tip = commit(&root, "main moves");
        git(&root, &["checkout", "-q", "feat"]);
        write(&root.join("b.txt"), "b\ndirty\n");
        let index = std::fs::read(root.join(".git/index")).unwrap();
        let repo = open(&root).await;
        let base = base(&tip);

        let s = summary_with(&repo, Some(&head), Some(&base), OPTS).await;
        assert_eq!(
            counts(&s),
            Some(json!({"uncommitted": {"files": 1, "added": 1, "removed": 0}, "branch": {"base": "origin/main", "commits": 2, "files": 5, "added": 3, "removed": 2}, "reason": null}))
        );

        let l = list_with(&repo, Some(&head), Some(&base), DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(l["branch_reason"], Value::Null);
        let b = &l["branch_changes"];
        assert_eq!((&b["base"], &b["base_head"], &b["merge_base"], &b["commits"]), (&json!("origin/main"), &json!(&tip[..7]), &json!(&main[..7]), &json!(2)));
        assert_eq!((&b["total"], &b["added"], &b["removed"], &b["truncated"]), (&json!(5), &json!(3), &json!(2), &json!(false)));
        assert_eq!(paths(b), ["a.txt", "added.txt", "gone.txt", "logo.bin", "moved.txt"]);
        assert_eq!(file(b, "a.txt"), &json!({"path": "a.txt", "status": "modified", "added": 1, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(b, "added.txt"), &json!({"path": "added.txt", "status": "added", "added": 2, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(b, "gone.txt"), &json!({"path": "gone.txt", "status": "deleted", "added": 0, "removed": 2, "binary": false, "diffable": true}));
        assert_eq!(file(b, "logo.bin"), &json!({"path": "logo.bin", "status": "modified", "added": null, "removed": null, "binary": true, "diffable": true}));
        assert_eq!(file(b, "moved.txt"), &json!({"path": "moved.txt", "old_path": "old.txt", "status": "renamed", "added": 0, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(paths(&l["uncommitted"]), ["b.txt"]);

        let d = diff_with(&repo, Some(&head), Some(&base), "branch", "a.txt", None, 1, OPTS).await.unwrap();
        assert_eq!((&d["status"], &d["added"], texts(&d)), (&json!("modified"), &json!(1), vec![" three".to_string(), "+four".to_string()]));
        assert_eq!(d["hunks"][0]["lines"][1], json!({"t": "+", "old": null, "new": 4, "text": "four"}));
        let d = diff_with(&repo, Some(&head), Some(&base), "branch", "moved.txt", Some("old.txt"), 3, OPTS).await.unwrap();
        assert_eq!((&d["status"], &d["old_path"], d["hunks"].as_array().unwrap().len()), (&json!("renamed"), &json!("old.txt"), 0));
        let d = diff_with(&repo, Some(&head), Some(&base), "branch", "moved.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["status"], &d["old_path"], &d["added"]), (&json!("added"), &Value::Null, &json!(10)));
        // Binary, in both groups.
        let d = diff_with(&repo, Some(&head), Some(&base), "branch", "logo.bin", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["binary"], &d["hunks"], &d["added"]), (&json!(true), &json!([]), &json!(0)));
        write(&root.join("logo.bin"), b"\x89PNG\0\x01\x02dirty");
        let d = diff_with(&repo, Some(&head), Some(&base), "uncommitted", "logo.bin", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["binary"], &d["hunks"], &d["status"]), (&json!(true), &json!([]), &json!("modified")));
        // What only changed on main, or only in the work tree, is not a branch change.
        let err = diff_with(&repo, Some(&head), Some(&base), "branch", "b.txt", None, 3, OPTS).await.unwrap_err();
        assert_eq!(err.0, "not_changed");
        // No base: no branch group.
        let err = diff_with(&repo, Some(&head), None, "branch", "a.txt", None, 3, OPTS).await.unwrap_err();
        assert_eq!(err.0, "not_changed");
        assert_untouched(&root, &index);

        // Histories that never met: no merge base, so no branch part and nothing wrong.
        git(&root, &["checkout", "-q", "--orphan", "island"]);
        let island = commit(&root, "island");
        let s = summary_with(&repo, Some(&island), Some(&base), OPTS).await;
        assert_eq!((&s.changes.as_ref().unwrap()["branch"], &s.changes.as_ref().unwrap()["reason"]), (&Value::Null, &Value::Null));
        let l = list_with(&repo, Some(&island), Some(&base), DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!((&l["branch_changes"], &l["branch_reason"]), (&Value::Null, &json!("no_merge_base")));
    }

    #[tokio::test]
    async fn the_default_branch_and_a_detached_head() {
        let tmp = tmp();
        let (root, main) = fixture(tmp.path());
        let repo = open(&root).await;
        // The default branch, clean: nothing uncommitted, no branch group.
        let s = summary_with(&repo, Some(&main), None, OPTS).await;
        assert_eq!((counts(&s), s.reason), (Some(json!({"uncommitted": {"files": 0, "added": 0, "removed": 0}, "branch": null, "reason": null})), None));
        let l = list_with(&repo, Some(&main), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        let token = s.changes.as_ref().unwrap()["token"].clone();
        assert_eq!(l, json!({"uncommitted": {"files": [], "total": 0, "added": 0, "removed": 0, "truncated": false}, "branch_changes": null, "branch_reason": "no_base", "token": token}));
        // The base at HEAD itself: a branch group with nothing in it.
        let s = summary_with(&repo, Some(&main), Some(&base(&main)), OPTS).await;
        assert_eq!(s.changes.unwrap()["branch"], json!({"base": "origin/main", "commits": 0, "files": 0, "added": 0, "removed": 0}));

        // Detached, one commit past main, with a dirty file.
        write(&root.join("a.txt"), "one\n");
        let ahead = commit(&root, "two");
        git(&root, &["checkout", "-q", "--detach", &ahead]);
        git(&root, &["branch", "-f", "main", &main]);
        write(&root.join("b.txt"), "b\nmore\n");
        let s = summary_with(&repo, Some(&ahead), Some(&base(&main)), OPTS).await;
        assert_eq!(
            counts(&s),
            Some(json!({"uncommitted": {"files": 1, "added": 1, "removed": 0}, "branch": {"base": "origin/main", "commits": 1, "files": 1, "added": 0, "removed": 2}, "reason": null}))
        );
        let d = diff_with(&repo, Some(&ahead), Some(&base(&main)), "branch", "a.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(texts(&d), [" one", "-two", "-three"]);
        // An id that is not one is never handed to git.
        let s = summary_with(&repo, Some("main"), Some(&base("--output=/tmp/x")), OPTS).await;
        assert_eq!(s.changes.unwrap()["branch"], Value::Null);
    }

    #[tokio::test]
    async fn an_untracked_file() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        write(&root.join("new dir/notes.txt"), "first\n\nthird\nlast");
        write(&root.join("empty.txt"), "");
        write(&root.join("long.txt"), format!("{}\nshort\n", "x".repeat(MAX_LINE_CHARS + 1)));
        std::os::unix::fs::symlink("/etc/passwd", root.join("link")).unwrap();
        // Secrets outside the repository, behind a directory that is a link.
        write(&tmp.path().join("outside/secret.txt"), "secret\n");
        std::os::unix::fs::symlink(tmp.path().join("outside"), root.join("linkdir")).unwrap();
        let repo = open(&root).await;

        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        let u = &l["uncommitted"];
        assert_eq!(paths(u), ["empty.txt", "link", "linkdir", "long.txt", "new dir/notes.txt"]);
        assert_eq!((&u["added"], &u["removed"]), (&json!(6), &json!(0)));
        assert_eq!(file(u, "new dir/notes.txt"), &json!({"path": "new dir/notes.txt", "status": "untracked", "added": 4, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(u, "empty.txt")["added"], json!(0));
        // A link is never followed: nothing is counted for it.
        assert_eq!(file(u, "link"), &json!({"path": "link", "status": "untracked", "added": null, "removed": null, "binary": false, "diffable": true}));

        let d = diff_with(&repo, Some(&head), None, "uncommitted", "new dir/notes.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["status"], &d["binary"], &d["truncated"], &d["added"], &d["removed"], &d["old_path"]), (&json!("untracked"), &json!(false), &json!(false), &json!(4), &json!(0), &Value::Null));
        assert_eq!(
            d["hunks"],
            json!([{"old_start": 0, "old_lines": 0, "new_start": 1, "new_lines": 4, "header": "", "lines": [
                {"t": "+", "old": null, "new": 1, "text": "first"},
                {"t": "+", "old": null, "new": 2, "text": ""},
                {"t": "+", "old": null, "new": 3, "text": "third"},
                {"t": "+", "old": null, "new": 4, "text": "last", "no_newline": true},
            ]}])
        );
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "empty.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["hunks"], &d["added"]), (&json!([]), &json!(0)));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "long.txt", None, 3, OPTS).await.unwrap();
        let lines = d["hunks"][0]["lines"].as_array().unwrap();
        assert_eq!((lines[0]["text"].as_str().unwrap().len(), &lines[0]["cut"], lines[1].get("cut")), (MAX_LINE_CHARS, &json!(true), None));

        // Links are refused, at the end of the path and along it.
        let err = diff_with(&repo, Some(&head), None, "uncommitted", "link", None, 3, OPTS).await.unwrap_err();
        assert_eq!(err.0, "bad_path");
        let err = diff_with(&repo, Some(&head), None, "uncommitted", "linkdir/secret.txt", None, 3, OPTS).await.unwrap_err();
        assert_eq!(err.0, "not_changed");
        assert!(open_beneath(&root, b"linkdir/secret.txt").is_err());
        assert!(open_beneath(&root, b"new dir/notes.txt").is_ok());
        assert!(open_beneath(&root, b"new dir/../a.txt").is_err());

        // Past the caps: a file over 1 MiB is listed without lines and its diff is cut, and one
        // over 8 MiB is binary.
        write(&root.join("big.txt"), "0123456789abcdef\n".repeat(70_000));
        write(&root.join("huge.txt"), vec![b'a'; BIG_FILE as usize + 1]);
        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(file(&l["uncommitted"], "big.txt"), &json!({"path": "big.txt", "status": "untracked", "added": null, "removed": null, "binary": false, "diffable": true}));
        assert_eq!(file(&l["uncommitted"], "huge.txt"), &json!({"path": "huge.txt", "status": "untracked", "added": null, "removed": null, "binary": true, "diffable": true}));
        assert_eq!(l["uncommitted"]["added"], json!(6), "what was counted still adds up");
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "big.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(d["truncated"], json!(true));
        let lines = d["hunks"][0]["lines"].as_array().unwrap();
        assert_eq!((lines.len(), d["added"].as_u64()), (MAX_LINES, Some(MAX_LINES as u64)));
        assert!(lines.iter().all(|l| l["text"] == "0123456789abcdef"));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "huge.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["binary"], &d["hunks"]), (&json!(true), &json!([])));
    }

    #[tokio::test]
    async fn untracked_files_past_the_run_bounds_are_not_counted() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        for n in 0..UNTRACKED_FILES + 5 {
            write(&root.join(format!("new/{n:04}.txt")), "one\ntwo\n");
        }
        let repo = open(&root).await;
        let l = list_with(&repo, Some(&head), None, MAX_LIMIT, OPTS).await.unwrap();
        let u = &l["uncommitted"];
        let counted = u["files"].as_array().unwrap().iter().filter(|f| f["added"] == 2).count();
        let not = u["files"].as_array().unwrap().iter().filter(|f| f["added"].is_null()).count();
        assert_eq!((counted, not, &u["total"], &u["added"]), (UNTRACKED_FILES, 5, &json!(UNTRACKED_FILES + 5), &json!(2 * UNTRACKED_FILES)));
        let s = summary_with(&repo, Some(&head), None, OPTS).await;
        assert_eq!(s.changes.unwrap()["uncommitted"], json!({"files": UNTRACKED_FILES + 5, "added": 2 * UNTRACKED_FILES, "removed": 0}));
    }

    #[tokio::test]
    async fn a_linked_worktree() {
        let tmp = tmp();
        let (root, main) = fixture(tmp.path());
        let wt = tmp.path().join("repo-side");
        git(&root, &["worktree", "add", "-q", "-b", "side", wt.to_str().unwrap()]);
        write(&wt.join("a.txt"), "one\ntwo\nthree\nside\n");
        let head = commit(&wt, "side");
        write(&wt.join("b.txt"), "b\ndirty in the worktree\n");
        write(&wt.join("fresh.txt"), "fresh\n");
        // The main work tree has its own changes, which are not this one's.
        write(&root.join("gone.txt"), "main is dirty\n");
        let repo = open(&wt).await;

        let s = summary_with(&repo, Some(&head), Some(&base(&main)), OPTS).await;
        assert_eq!(
            counts(&s),
            Some(json!({"uncommitted": {"files": 2, "added": 2, "removed": 0}, "branch": {"base": "origin/main", "commits": 1, "files": 1, "added": 1, "removed": 0}, "reason": null}))
        );
        let l = list_with(&repo, Some(&head), Some(&base(&main)), DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(paths(&l["uncommitted"]), ["b.txt", "fresh.txt"]);
        assert_eq!(paths(&l["branch_changes"]), ["a.txt"]);
        let d = diff_with(&repo, Some(&head), Some(&base(&main)), "uncommitted", "b.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(texts(&d), [" b", "+dirty in the worktree"]);
        let d = diff_with(&repo, Some(&head), Some(&base(&main)), "uncommitted", "fresh.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(texts(&d), ["+fresh"]);
        let d = diff_with(&repo, Some(&head), Some(&base(&main)), "branch", "a.txt", None, 0, OPTS).await.unwrap();
        assert_eq!(texts(&d), ["+side"]);

        let main_repo = open(&root).await;
        let l = list_with(&main_repo, Some(&main), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(paths(&l["uncommitted"]), ["gone.txt"]);
    }

    #[tokio::test]
    async fn an_unborn_head() {
        let tmp = tmp();
        let root = tmp.path().join("repo");
        std::fs::create_dir_all(&root).unwrap();
        git(&root, &["init", "-q"]);
        let repo = open(&root).await;
        // Empty: nothing at all.
        let s = summary_with(&repo, None, None, OPTS).await;
        assert_eq!(counts(&s), Some(json!({"uncommitted": {"files": 0, "added": 0, "removed": 0}, "branch": null, "reason": null})));

        write(&root.join("staged.txt"), "one\ntwo\n");
        git(&root, &["add", "staged.txt"]);
        write(&root.join("staged.txt"), "one\ntwo\nthree\n");
        write(&root.join("loose.txt"), "loose\n");
        let s = summary_with(&repo, None, Some(&base(A)), OPTS).await;
        assert_eq!(counts(&s), Some(json!({"uncommitted": {"files": 2, "added": 4, "removed": 0}, "branch": null, "reason": null})));
        let l = list_with(&repo, None, None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(file(&l["uncommitted"], "staged.txt"), &json!({"path": "staged.txt", "status": "added", "added": 3, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(&l["uncommitted"], "loose.txt")["status"], "untracked");
        let d = diff_with(&repo, None, None, "uncommitted", "staged.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["status"], texts(&d)), (&json!("added"), vec!["+one".to_string(), "+two".to_string(), "+three".to_string()]));
        let err = diff_with(&repo, None, Some(&base(A)), "branch", "staged.txt", None, 3, OPTS).await.unwrap_err();
        assert_eq!(err.0, "not_changed");
    }

    #[tokio::test]
    async fn a_conflicted_file() {
        let tmp = tmp();
        let (root, _) = fixture(tmp.path());
        git(&root, &["checkout", "-q", "-b", "feat"]);
        write(&root.join("b.txt"), "b from feat\n");
        commit(&root, "feat");
        git(&root, &["checkout", "-q", "main"]);
        write(&root.join("b.txt"), "b from main\n");
        let head = commit(&root, "main");
        let merged = git_command(&root, &["merge", "feat"]).output().unwrap();
        assert!(!merged.status.success() && String::from_utf8_lossy(&merged.stdout).contains("CONFLICT"), "the merge has to conflict: {merged:?}");
        let repo = open(&root).await;
        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(l["uncommitted"]["files"], json!([{"path": "b.txt", "status": "conflicted", "added": 4, "removed": 0, "binary": false, "diffable": true}]));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "b.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(d["status"], "conflicted");
        assert!(texts(&d).contains(&"+<<<<<<< HEAD".to_string()), "{d}");
    }

    #[tokio::test]
    async fn a_diff_over_the_cap_is_truncated() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        // About 1.5 MiB of added lines: git's patch is cut at 1 MiB, mid-line.
        let line = "a line that is sixty-four bytes long once its number is on it";
        write(&root.join("a.txt"), (0..24_000).map(|n| format!("{line} {n:06}\n")).collect::<String>());
        let repo = open(&root).await;
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["truncated"], &d["binary"], &d["status"]), (&json!(true), &json!(false), &json!("modified")));
        let lines = texts(&d);
        assert!(lines.len() > 10_000 && lines.len() < 20_000, "{}", lines.len());
        assert!(lines[3..].iter().all(|l| l.starts_with("+a line that") && l.len() == 1 + line.len() + 7), "a cut line was kept");
        assert_eq!(d["added"].as_u64(), Some(lines.len() as u64 - 3));
        // The list still has the real count.
        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(file(&l["uncommitted"], "a.txt")["added"], json!(24_000));

        // Under the byte cap but over the line cap.
        write(&root.join("a.txt"), "x\n".repeat(MAX_LINES + 500));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["truncated"], texts(&d).len()), (&json!(true), MAX_LINES));
    }

    #[tokio::test]
    async fn a_file_over_8_mib_is_binary() {
        let tmp = tmp();
        let (root, _) = fixture(tmp.path());
        let big = |last: &str| format!("{}{last}\n", "0123456789abcdef\n".repeat((BIG_FILE as usize + (1 << 20)) / 17));
        write(&root.join("big.txt"), big("one"));
        let head = commit(&root, "big");
        write(&root.join("big.txt"), big("two"));
        let repo = open(&root).await;
        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        assert_eq!(l["uncommitted"]["files"], json!([{"path": "big.txt", "status": "modified", "added": null, "removed": null, "binary": true, "diffable": true}]));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "big.txt", None, 3, OPTS).await.unwrap();
        assert_eq!((&d["binary"], &d["hunks"], &d["truncated"]), (&json!(true), &json!([]), &json!(false)));
    }

    #[tokio::test]
    async fn more_than_1000_changed_paths_are_listed_but_not_counted() {
        let tmp = tmp();
        let (root, _) = fixture(tmp.path());
        let n = MAX_COUNTED + 1;
        for i in 0..n {
            write(&root.join(format!("many/{i:04}.txt")), "one\n");
        }
        let head = commit(&root, "many");
        for i in 0..n {
            write(&root.join(format!("many/{i:04}.txt")), "one\ntwo\n");
        }
        write(&root.join("fresh.txt"), "fresh\n");
        let repo = open(&root).await;
        let s = summary_with(&repo, Some(&head), None, OPTS).await;
        assert_eq!((counts(&s), s.reason), (Some(json!({"uncommitted": {"files": n + 1, "added": null, "removed": null}, "branch": null, "reason": null})), None));
        let l = list_with(&repo, Some(&head), None, MAX_LIMIT + 50, OPTS).await.unwrap();
        let u = &l["uncommitted"];
        assert_eq!((&u["total"], &u["added"], &u["removed"], &u["truncated"]), (&json!(n + 1), &Value::Null, &Value::Null, &json!(false)));
        assert_eq!(file(u, "many/0000.txt"), &json!({"path": "many/0000.txt", "status": "modified", "added": null, "removed": null, "binary": false, "diffable": true}));
        // The untracked file is still read, and one file can still be diffed.
        assert_eq!(file(u, "fresh.txt")["added"], json!(1));
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "many/1000.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(texts(&d), [" one", "+two"]);
        // One fewer, and they are counted.
        write(&root.join("many/0000.txt"), "one\n");
        let s = summary_with(&repo, Some(&head), None, OPTS).await;
        assert_eq!(s.changes.unwrap()["uncommitted"], json!({"files": n, "added": n, "removed": 0}));
    }

    #[tokio::test]
    async fn status_over_its_cap_is_too_large_and_no_time_is_a_timeout() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        for i in 0..40 {
            write(&root.join(format!("a-rather-long-directory-name/untracked-file-{i:04}.txt")), "x\n");
        }
        let repo = open(&root).await;
        let small = Opts { status_cap: 1024, ..OPTS };
        assert_eq!(summary_with(&repo, Some(&head), None, small).await, Summary::none("too_large"));
        assert_eq!(list_with(&repo, Some(&head), None, DEFAULT_LIMIT, small).await.unwrap_err().0, "git_failed");
        assert_eq!(summary_with(&repo, Some(&head), None, OPTS).await.changes.unwrap()["uncommitted"]["files"], json!(40));

        let none = Opts { budget: Duration::ZERO, ..OPTS };
        assert_eq!(summary_with(&repo, Some(&head), None, none).await, Summary::none("timeout"));
        assert_eq!(list_with(&repo, Some(&head), None, DEFAULT_LIMIT, none).await.unwrap_err().0, "timeout");
        assert_eq!(diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, 3, none).await.unwrap_err().0, "timeout");
    }

    #[tokio::test]
    async fn a_bad_request_is_refused_before_git_runs() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        write(&root.join("a.txt"), "changed\n");
        write(&tmp.path().join("outside.txt"), "outside\n");
        let repo = open(&root).await;
        // No time at all: anything that got as far as git would say `timeout`.
        let none = Opts { budget: Duration::ZERO, ..OPTS };
        let outside = tmp.path().join("outside.txt");
        for path in ["../outside.txt", outside.to_str().unwrap(), "/etc/passwd", "a/../a.txt", "./a.txt", "a.txt/", "", "a\0.txt", "a\n.txt", ".."] {
            let err = diff_with(&repo, Some(&head), None, "uncommitted", path, None, 3, none).await.unwrap_err();
            assert_eq!(err.0, "bad_path", "{path:?}");
            let err = diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", Some(path), 3, none).await.unwrap_err();
            assert_eq!(err.0, "bad_path", "old path {path:?}");
        }
        for group in ["", "staged", "Branch"] {
            assert_eq!(diff_with(&repo, Some(&head), None, group, "a.txt", None, 3, none).await.unwrap_err().0, "bad_request", "{group:?}");
        }
        assert_eq!(diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, MAX_CONTEXT + 1, none).await.unwrap_err().0, "bad_request");
        // A path that reads like an option or a pathspec is only ever a path.
        for path in ["--output=x", ":(top)a.txt", "*.txt", ":!a.txt", "-h"] {
            let err = diff_with(&repo, Some(&head), None, "uncommitted", path, None, 3, OPTS).await.unwrap_err();
            assert_eq!(err.0, "not_changed", "{path:?}");
        }
        assert!(!root.join("x").exists());
        assert_eq!(diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, MAX_CONTEXT, OPTS).await.unwrap()["removed"], json!(3));
    }

    #[tokio::test]
    async fn odd_paths_are_listed() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        write(&root.join("with space/and\ttab.txt"), "x\n");
        // APFS refuses a name that is not UTF-8: that file is only checked where it can exist.
        let raw = std::fs::write(root.join(OsStr::from_bytes(b"caf\xe9.txt")), "x\n").is_ok();
        write(&root.join("d\u{e9}j\u{e0} vu.txt"), "x\n");
        git(&root, &["add", "-A"]);
        let repo = open(&root).await;
        let l = list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap();
        let u = &l["uncommitted"];
        let n = 2 + u64::from(raw);
        assert_eq!((&u["total"], &u["added"]), (&json!(n), &json!(n)));
        assert_eq!(file(u, "d\u{e9}j\u{e0} vu.txt"), &json!({"path": "d\u{e9}j\u{e0} vu.txt", "status": "added", "added": 1, "removed": 0, "binary": false, "diffable": true}));
        assert_eq!(file(u, "with space/andtab.txt"), &json!({"path": "with space/andtab.txt", "status": "added", "added": 1, "removed": 0, "binary": false, "diffable": false}));
        if raw {
            assert_eq!(file(u, "caf\u{fffd}.txt"), &json!({"path": "caf\u{fffd}.txt", "status": "added", "added": 1, "removed": 0, "binary": false, "diffable": false}));
        }
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "d\u{e9}j\u{e0} vu.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(texts(&d), ["+x"]);
        // The display form is not a path: it names nothing.
        assert_eq!(diff_with(&repo, Some(&head), None, "uncommitted", "with space/andtab.txt", None, 3, OPTS).await.unwrap_err().0, "not_changed");
    }

    #[tokio::test]
    async fn a_missing_object_in_a_partial_clone() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        write(&root.join("a.txt"), "one\nchanged\n");
        let blob = git(&root, &["rev-parse", "HEAD:a.txt"]);
        std::fs::remove_file(root.join(".git/objects").join(&blob[..2]).join(&blob[2..])).unwrap();
        // Not a partial clone: just broken.
        let repo = open(&root).await;
        assert_eq!(summary_with(&repo, Some(&head), None, OPTS).await, Summary::none("error"));
        assert_eq!(list_with(&repo, Some(&head), None, DEFAULT_LIMIT, OPTS).await.unwrap_err().0, "git_failed");
        // A partial clone: the object is one that was never fetched, and is not fetched now.
        git(&root, &["config", "remote.origin.url", "/nonexistent/clt-origin"]);
        git(&root, &["config", "remote.origin.promisor", "true"]);
        git(&root, &["config", "remote.origin.partialclonefilter", "blob:none"]);
        let repo = open(&root).await;
        assert!(repo.partial_clone());
        assert_eq!(summary_with(&repo, Some(&head), None, OPTS).await, Summary::none("partial_clone"));
        let err = diff_with(&repo, Some(&head), None, "uncommitted", "a.txt", None, 3, OPTS).await.unwrap_err();
        assert_eq!(err.0, "git_failed");
        // What needs no missing object still works.
        std::fs::write(root.join("a.txt"), "one\ntwo\nthree\n").unwrap();
        write(&root.join("b.txt"), "b\nmore\n");
        let d = diff_with(&repo, Some(&head), None, "uncommitted", "b.txt", None, 3, OPTS).await.unwrap();
        assert_eq!(texts(&d), [" b", "+more"]);
    }

    #[tokio::test]
    async fn the_public_calls_use_the_default_budget() {
        let tmp = tmp();
        let (root, head) = fixture(tmp.path());
        write(&root.join("a.txt"), "one\n");
        let repo = open(&root).await;
        assert_eq!(summary(&repo, Some(&head), None).await.changes.unwrap()["uncommitted"], json!({"files": 1, "added": 0, "removed": 2}));
        assert_eq!(list(&repo, Some(&head), None, DEFAULT_LIMIT).await.unwrap()["uncommitted"]["total"], json!(1));
        assert_eq!(diff(&repo, Some(&head), None, "uncommitted", "a.txt", None, DEFAULT_CONTEXT).await.unwrap()["removed"], json!(2));
    }
}
