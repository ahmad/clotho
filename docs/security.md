# clothod security

What clothod trusts, what it doesn't, and what the review of 0.1.10 found and fixed (0.1.11).
Owned by the clothod agent; docs/push.md covers the relay's side of push.

## Threat model

clothod runs as the user and gives its clients what the user has: shells, every file the user
can reach (`fs.*`), and the user's agents. Holding the socket is holding the account, so the
model is about who can get to the socket, and what can reach the daemon without holding it.

**Trusted:**

- Clients on the local socket. The runtime dir is 0700 and must be owned by the user (it is
  refused otherwise, including a symlink in its place). Both the client socket and the holder
  socket check the peer's uid. Anything that connects is the user, so `fs.*` has no sandbox:
  paths are absolute or `~/…`, `..` means what it means to the OS, and symlinks are followed
  the way the user's own tools follow them.
- Clients over `clothod bridge`. SSH has already authenticated them as the user on that machine.
  The bridge copies bytes and adds nothing.
- Processes in panes calling `clothod report`. They run as the user and could do anything else
  the user can do. The daemon still checks that the reporting pid is in the pane it names, so a
  pane id shared by two daemons can't be reported to the wrong one.
- Environment variables (`CLOTHOD_*`, `CLOTHO_PANE`, `HOME`). Whoever sets them already runs code
  as the user.

**Untrusted** (in scope):

- **Pane output.** Any program's output, `cat` of any file, a shell on a hostile machine. It
  reaches the daemon's VT parser, titles, cwd, the clipboard (OSC 52), agent detection and
  snapshots.
- **Other local users.** They must not reach the sockets, read state, plant files where clothod
  writes, or read files while clothod writes them.
- **The network.** The push relay and Apple see only what push sends them.
- **Clients that stop reading.** A phone that went away leaves a half-open connection, and
  nothing tells the daemon. It must not cost the daemon memory without bound.
- **What the daemon writes on the user's behalf.** config.toml, agent hook settings, and login
  units must keep their permissions, and their embedded paths must stay paths.
- **The repositories panes are in** (since 0.1.32). A pane's cwd can be in a repository the
  user cloned and never read, or one an agent just changed. Its contents, its `.gitattributes`,
  its `.git/config` (and what that includes), its hooks, its refs and its file names are all
  untrusted. Showing a pane must never run anything such a repository names. See
  [Running git in a repo the user didn't write](#running-git-in-a-repo-the-user-didnt-write).

**Out of scope:** an attacker who already runs code as the user; root; the client apps'
rendering of untrusted output (each client has its own terminal emulator and applies its own
limits); the relay Worker itself (docs/push.md).

## Findings (0.1.10 review)

Severity is for a single-user Mac or Linux box, with clothod's default setup.

| # | Severity | Finding | Fixed |
|---|---|---|---|
| 1 | Medium | An endless OSC from pane output grew serve without bound | yes, 0.1.11 |
| 2 | Medium | Replies and events for a client that stopped reading were buffered without bound | yes, 0.1.11 |
| 3 | Medium | Part files were readable by other users while being written, and followed symlinks | yes, 0.1.11 |
| 4 | Medium | An upload couldn't resume past a half-open connection, or after its private instance ended | yes, 0.1.11 |
| 5 | Low | Rewriting config.toml or agent hook settings reset their mode to the umask default | yes, 0.1.11 |
| 6 | Low | Hook commands spliced the install path in double quotes | yes, 0.1.11 |
| 7 | Low | Titles kept control characters (C1 included) and had no length limit | yes, 0.1.11 |
| 8 | Low | A write stream ignored its window: a client could queue unlimited data in serve | yes, 0.1.11 |
| 9 | Low | `clotho --host` passed a host starting with `-` to ssh as an option | yes, 0.1.11 |
| 10 | Low | Push ciphertext length revealed the alert message's length | yes, 0.1.11 |
| 11 | Info | serve read its whole executable at startup (110 MB transient for a debug build) | yes, 0.1.11 |

### 1. Endless OSC (Medium, fixed)

vte (alacritty's parser) buffers an OSC string with no limit until its terminator, and serve
runs two parsers over every pane. `printf '\e]0;'` followed by endless bytes (a hostile file, a
binary blob, a misbehaving program) grew serve by twice the output's size, until it ran out of
memory. That killed every client's view of every pane. The PTYs live in the holder, so shells
survived.

Fix: `clotho-vt` holds OSC strings back itself and passes them on only once they end. Past
`MAX_OSC` (1.4 MiB, room for a 1 MiB OSC 52 copy in base64) the OSC is dropped whole: nothing is
dispatched, no partial clipboard copy goes out, and no bell rings. Measured on devbox (release
musl builds, one pane printing `ESC ] 0 ;`, 100 MB of `A`, then BEL): serve's RSS went from
3.9 MB to a peak of 828 MB on 0.1.10, and from 3.7 MB to 6.7 MB with the fix. Tests: `vt` `an_endless_osc_is_dropped_not_buffered`,
`osc_guard_keeps_normal_sequences_intact` (every split point); e2e
`an_endless_osc_does_not_grow_serve`.

### 2. Clients that stop reading (Medium, fixed)

Pane output to a lagging client was already capped: it gets a snapshot when it catches up. But
replies and events went through an unbounded queue. A subscribed client whose connection went
half-open (a phone leaving Wi-Fi with an SSH bridge up) kept collecting every pane, title and
agent event forever. A Claude Code title spinner alone is several events a second.

Fix: past 64 MiB of unread replies and events, serve drops the connection (logged). The client
sees EOF and reconnects. Test: e2e `a_client_that_stops_reading_is_dropped` (with the limit
lowered to 1 MiB).

### 3. Part files (Medium, fixed)

Writes go to a hidden part file next to the target, which is then renamed over it.

- **Readable while written.** The part was created with the umask's mode, usually 0644. Only
  at the end did it get the final mode. Uploading a private file (a key, a 0600 config) into a
  directory other users can traverse let them read it during the upload, and for as long as an
  interrupted resumable part was kept.
- **Followed symlinks.** In a shared directory (`/tmp`), another user could plant a symlink at a
  resumable part's name, which is predictable from the target name and upload id. The upload
  then wrote, or truncated, whatever the link pointed to that the user could write.

Fix: parts are created exclusively with mode 0600 (`O_EXCL`). Resuming opens with `O_NOFOLLOW`
and accepts only a regular file the user owns, with one link; anything else at that name is
removed (the link itself, not its target) and replaced. The final mode is applied at the end:
the requested one, else the replaced file's, else 0666 less the umask. Tests: e2e
`fs_resume_takes_over_a_half_open_stream_and_outlives_the_instance` (checks 0600 mid-upload and
the final mode), `fs_part_files_never_follow_links`.

### 4. Transfers after a cut (Medium, fixed)

This is the "10-minute hang" mac saw in the slow-link test. That stall was on the client side:
the SSH multiplexer (ControlPersist) stayed up on a dead proxy, so the app never saw the
connection end, and the daemon never saw a cut. Two daemon problems sat behind it, and both
would have kept the transfer stuck even after the client noticed:

- **A half-open stream held the part.** A resume on a new connection shared the part file with
  the old stream. That stream was still open as far as serve knew, and if it later failed, its
  cleanup could delete the part the new stream was writing.
- **The registry died with private instances.** Resume matched part files through a registry in
  the instance's state dir. A private instance (`--ephemeral`, state in its runtime dir under
  /tmp) took the registry with it when it ended, so the next instance restarted the upload at 0.

Fix: a resumable part is named after its upload and a hash of its source
(`.<name>.clotho-part-<upload_id>-<hash>`), so resuming needs nothing but the part file. Parts
nobody resumes are swept from their directory after 24 h. A new write of the same part takes
over from a stream that is still open, which ends with `fs.error` `superseded`. Clients should
also send `ping` every 15 s and drop the connection after 30 s without a reply, since replies go
out ahead of file data (docs/protocol.md, Transfers). Tests: e2e
`fs_resume_takes_over_a_half_open_stream_and_outlives_the_instance` (half-open takeover, then the
whole instance and its dirs gone); remote `upload_resumes_after_the_ssh_link_is_cut` (24 MB
over real SSH, the ssh process killed mid-upload, resumed against the same long-lived instance,
checksum compared on the host).

### 5. File modes on rewrite (Low, fixed)

`settings.set` rewrites config.toml, and `clothod hooks install` rewrites
`~/.claude/settings.json` and `~/.codex/config.toml`, the last two only with the user's
confirmation. Each wrote a temp file with the umask's mode and renamed it over the original.
A 0600 file came back 0644. `~/.claude/settings.json` can hold API keys in its `env` block.

Fix: one `write_atomic` for all of them. The temp file is created exclusively, 0600, and gets the
original's mode before the rename. Test: `write_atomic_keeps_the_files_mode`.

### 6. Hook command quoting (Low, fixed)

The hook command embedded the install path as `"${CLOTHOD_REPORT:-<path>}"`. A home directory
containing `"`, `` ` `` or `$(` would break the hook, or run code from the path. Exploiting it
needs control of the user's home path, hence Low. Fix: the path is one single-quoted shell word.
Test: `hook_command_quotes_the_install_path` (a path with quotes, `$(…)`, backquotes and `${}`
runs the right binary and nothing else).

### 7. Titles (Low, fixed)

OSC 0/2 titles went to every client in `pane` events and into snapshots as they came, with any
length and with C1 characters. A snapshot re-emits the title inside an OSC. Since clients
receive the raw output stream too, this adds no new injection path, but a title is also
displayed (window and tab names, lists). Fix: titles are stripped of control characters (C0, DEL,
C1) and cut to 1024 characters. An OSC 7 cwd over 4096 bytes or with control characters is
ignored. Test: `titles_and_cwds_are_printable_and_bounded`.

### 8. Write window (Low, fixed)

`fs.write` data went into an unbounded queue, whatever the window. A broken client, which is
the user's own, could fill serve's memory. Fix: data more than two windows ahead of the disk ends
the stream with `fs.error` `window_exceeded`, keeping a resumable part. Test:
`fs_write_past_the_window_fails_the_stream`.

### 9. ssh host as option (Low, fixed)

`clotho --host -oProxyCommand=…` (or a Remote built from such a string) would have ssh run the
"host" as a command. The host string comes from the user, hence Low. Fix: a destination
starting with `-`, or containing whitespace or control characters, is refused. The Mac and iOS
apps build their own ssh command lines and should check the same (told mac and ios). Test:
`a_host_can_not_be_an_ssh_option`.

### 10. Push length (Low, fixed)

Push alerts are HPKE-sealed to the phone's key (X25519, ChaCha20-Poly1305), with the collapse id
as AAD. The relay and APNs see the device handle, a per-pane collapse id (stable per pane, so
alerts from one pane can be linked), the time, and the ciphertext's length. The length revealed
the message's length (up to 400 bytes). Fix: the sealed record carries a `pad` of spaces making
it a multiple of 1024 bytes, which in practice means every record is 1024 bytes. iOS decodes
with Codable, which ignores the extra key, so older apps read padded records unchanged. Tests:
`records_are_padded_to_a_fixed_size`, and `matches_the_ios_vector`, which has a padded vector
for iOS (`PADDED`, `CT_PADDED`). The collapse id and timing still link alerts of one pane; that
is what lets the phone replace them.

### 11. Startup read (Info, fixed)

`build_id` read the whole executable into memory to hash it, and serve does that at startup:
110 MB for a debug build, ~6 MB for a release build. It now streams the file. The ids are
unchanged.

## Checked, no finding

- **Framing:** frames over 16 MiB close the connection, as does a zero-length frame. JSON is
  limited to 128 levels of nesting by serde_json (e2e `deeply_nested_json_closes_only_that_connection`:
  1 MiB of `[` closes that connection, and serve keeps serving). Unknown frame types are
  ignored. Requests on a connection run one at a time, so a flood is that connection's problem.
  The ones that wait on something slow are answered later (`agent.permission`, and since 0.1.32
  `git.changes`, `git.diff` and a create with `worktree`): the git ones queue for two slots, and
  each gives up after 10 s, so a flood of them costs waiting tasks, not git processes.
- **Handshake:** everything but `hello` is refused before it.
- **Pane output to clients** is capped per client (8 MiB queued, then a deferred snapshot).
- **OSC 52:** copy only. Reads are never answered, so a pane can't read the user's clipboard.
  Copies over 1 MiB are dropped, not truncated, and replayed output never copies again. A pane
  can set the clipboard, as in any terminal: whether to ask first is client policy.
- **Terminal replies** (DA, DSR, colour queries) go only to the pane that asked, and replies to
  replayed output are never sent again.
- **Runtime dir and sockets:** 0700, owner-checked and peer-uid-checked. The holder's state
  handover file is unlinked as soon as it is created. push.json is written 0600 in a private
  dir.
- **Login units:** plist values are XML-escaped and systemd words quoted (`%`, `$`, `\`, `"`).
  They run `current/clothod start` with no shell (tests `plist_escapes_and_never_keeps_alive`,
  `systemd_words_are_quoted`).
- **Push relay URLs:** https only, plain http only to localhost. The relay never sees plaintext.
- **`clothod report`** reads at most 1 MiB of hook input and never prints. A report's pid must
  be in the pane it names.
- **Remote commands** quote every environment value (`sq`), and the bridge passes only
  protocol bytes to stdout.

## Running git in a repo the user didn't write

Since 0.1.32 (features `git.changes` and `worktree`) the daemon runs git: for the `changes`
summary on a pane, for `git.changes` and `git.diff`, and to create a worktree. Until then it
only read a few files under `.git`, because git, run the ordinary way, runs what a repository
tells it to: `core.fsmonitor`, hooks, clean and smudge filters, external diff and textconv
drivers, a pager, an ssh command. A summary is read for every pane that is in a repository,
without the user asking, so `git status` the ordinary way in a hostile repository would be code
execution on opening a Tab.

All of it goes through one runner (`crate::gitrun`). Nothing else in the daemon starts git.

**The invocation.** Every call is

```
<git> --no-pager --no-optional-locks -C <work tree root> <plumbing command> …
```

- `<git>` is an absolute path the daemon resolved: the first `git` on its PATH, then
  `/opt/homebrew/bin` and `/usr/local/bin`, and on macOS the one in the developer directory.
  Never a relative path, so a repository can't supply its own, and never macOS's `/usr/bin/git`
  shim (without developer tools it opens an install dialog). It must be 2.31 or later
  (`GIT_CONFIG_COUNT`); an older or unidentifiable git is `git_unsupported`.
- It runs from `/`, with no stdin, in its own process group, and with **an environment built
  from nothing**: only `HOME`, `PATH=/usr/bin:/bin`, `LC_ALL=C` and the variables below. Nothing
  of the daemon's own environment reaches git.
- No system and no global config (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`), no
  system attributes (`GIT_ATTR_NOSYSTEM=1`), no prompts (`GIT_TERMINAL_PROMPT=0`,
  `GIT_ASKPASS=/bin/false`, `GIT_EDITOR=:`), no optional locks (`GIT_OPTIONAL_LOCKS=0`), no
  lazy fetch (`GIT_NO_LAZY_FETCH=1`), no replace objects, literal pathspecs, `GIT_PAGER=cat`.
  The user's global ignore file is the one thing taken from the global config: its path is
  read once, from `/`, and passed back as `core.excludesFile`.
- Config overrides, which win over the repository's config and anything it includes:
  `core.fsmonitor=false`, `core.hooksPath=/dev/null`, `core.pager=cat`,
  `core.untrackedCache=false`, `diff.external=`, `diff.autoRefreshIndex=false`,
  `core.alternateRefsCommand=`, `core.sshCommand=/bin/false`, `core.gitProxy=`,
  `protocol.allow=never`, `credential.helper=`, `submodule.recurse=false`,
  `diff.ignoreSubmodules=all`, `status.submoduleSummary=false`, `log.showSignature=false`,
  `gpg.program=/bin/false`, `core.quotePath=false`, `core.bigFileThreshold=8m`. They are
  passed as `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`, not as `-c
  key=value`, so a key that itself holds `=` is passed exactly.
- Every call has a timeout and a cap on its output, read as it comes. Past either, the whole
  process group is killed and the child reaped; the same happens when the request that wanted
  it is dropped. Stderr is kept to 4 KiB, with control characters removed.
- Refs are never given to git by name. The daemon resolves HEAD and the base branch to commit
  ids from the files itself, and git gets ids. Paths from a client go after `--`, with literal
  pathspecs, and are checked first (relative, no `..`, no control characters).

**Three things config overrides alone don't cover**, and what covers them:

1. **Filters have no global off switch.** `filter.<name>.clean`, `.smudge` and `.process` are
   looked up by a name that `.gitattributes` picks, so there is no fixed key to override.
   Before anything else in a repository, the runner lists its config (`git config --list -z`,
   which only reads files: the repository's and what it includes) and overrides every
   `filter.<name>.*` it finds with an empty command and `required=false`. The same listing
   finds each `protocol.<name>.allow`, which would win over `protocol.allow=never`, and sets it
   to `never`. A config with more than 256 such names, or over 1 MiB, is refused.
2. **`git diff` writes the index**, and so does `git status` unless told not to: they refresh
   stat information and write it back, taking `index.lock`. The runner uses plumbing only:
   `status --porcelain=v2` under `--no-optional-locks`, and `diff-index` and `diff-tree` for
   every count and patch, never `git diff`. Plumbing also ignores aliases and most of the
   user-facing config.
3. **Submodules need a flag.** A submodule is another repository with its own config, which
   the overrides above (scanned from the outer one) don't describe. `diff.ignoreSubmodules=all`
   as config is not enough for every command, so each diff command carries `--no-ext-diff
   --no-textconv --ignore-submodules=all`, and `status` carries `--ignore-submodules=all`: git
   never looks inside one. (`--no-ext-diff` and `--no-textconv` also cover
   `diff.<driver>.command` and `.textconv`, whose driver names come from `.gitattributes` like
   filter names.) A pane whose cwd is inside a submodule gets that submodule as its own
   repository, scanned on its own.

Untracked files are read by the daemon, not by git: opened one path component at a time with
`O_NOFOLLOW` (a directory swapped for a symlink between the listing and the read is refused),
regular files only, non-blocking (a FIFO can't hang it), at most 1 MiB each.

**What was measured.**

- Linux, git 2.43.0: the e2e test `a_hostile_repo_cannot_run_anything_through_the_daemon`
  with the daemon under `strace -f -e trace=execve`. The repository's config, attributes and
  hooks all name a marker script (fsmonitor, pager, sshCommand, alternateRefsCommand, external
  diff, a diff driver's command and textconv, a required clean/smudge/process filter, and
  hooks). Over the summary, `git.changes`, four `git.diff`s and a worktree Tab, the daemon and
  its children made 48 `execve` calls: 2 of clothod itself (serve and the holder), 2 of
  `/bin/sh` (the panes), and 44 of git (`config`, `status`, `diff-index`, `diff-tree`,
  `merge-base`, `rev-list`, `rev-parse`, `check-ref-format`, `worktree`, and the `branch`,
  `symbolic-ref` and `reset` that `worktree add` runs itself). Nothing else, and none failed.
  `.git/index` was byte-for-byte and mtime-for-mtime what it was before.
- macOS, Apple git 2.54.0 (Apple Git-157), the build Mac: the same tests pass (the marker never
  appears, the index is unchanged). No syscall trace was taken there.
- Each of these tests first runs ordinary `git status` and `git diff` on a copy of the same
  repository and requires the marker to appear, so a test whose trap doesn't work fails
  instead of passing.

**The tests that pin it** (real git; a machine without git fails them):

- `gitrun::tests::a_hostile_repo_runs_nothing_and_is_not_written`: every command the daemon
  uses, one by one, in a repository that also claims to be a partial clone with an `ext::`
  promisor remote; then a missing object, which must fail and not fetch.
- `gitrun::tests::a_hostile_submodule_runs_nothing`.
- `gitrun::tests::a_timeout_kills_the_whole_process_group`,
  `a_dropped_call_kills_the_whole_process_group`, `the_output_cap_truncates_and_stops_reading`,
  `an_old_or_unknown_git_is_unsupported`, `open_refuses_what_it_cannot_make_safe`,
  `find_git_honours_the_override_and_is_never_relative`.
- `worktree::tests::hooks_and_filters_never_run`, `each_refusal_leaves_no_branch_and_no_folder`,
  `a_failed_add_rolls_the_branch_back`, `a_locked_half_made_worktree_is_taken_back`.
- e2e `a_hostile_repo_cannot_run_anything_through_the_daemon` (the whole path, through the
  protocol) and `git_requests_do_not_block_the_connection` (a git that hangs).

**Limits, and what is not covered.**

- **Git LFS and other filters.** With filters off, git compares what is in the work tree with
  what is stored, so a repository that uses LFS (or any clean filter) can show files as
  modified that `git status` in a terminal calls clean, and their diffs are of the stored
  form (the pointer file).
- **Partial clones** are refused, not completed: a comparison that needs an object the clone
  doesn't have fails (`partial_clone`), and nothing is fetched.
- **Worktree creation is hardened the same way**, which changes what the user gets: LFS files
  in the new worktree are pointer files until `git lfs pull`, and `post-checkout` (and every
  other hook) does not run, so a repository that relies on one to set up a checkout isn't set
  up. This is the price of creating a worktree from a client's request without running the
  repository's code. The daemon never deletes a worktree or a branch it didn't just create, and
  what it just created it removes only through git.
- **Reftable** repositories are refused (`git_unsupported`): the daemon reads HEAD and refs
  from files, and there are none to read. **SHA-256** repositories and **sparse checkouts**
  are not refused and not tested.
- **Git older than 2.31** is `git_unsupported`. No workaround is attempted.
- **A config that changes between the scan and the command** is out of scope: the filter and
  protocol names are listed when a job starts, and a filter added to the config in the
  milliseconds after that is not overridden for that job. Whoever can write `.git/config` at
  will already runs code as the user.
- **Resource use** is bounded per call (time, output), per job (the config scan, at most 5 s,
  then 6 s of git for a summary, a list or a diff, and 10 s in all for a request; two minutes
  for a checkout) and per daemon (two git jobs at once), not by the
  repository's size: a very large repository gives `timeout` or uncounted lines, and is then
  read again less often (ten times the last run's duration apart).
- **What clients get is still untrusted data.** File names and diff text come from the
  repository. The daemon makes paths and messages printable and marks the paths it changed
  (`diffable: false`), and makes diff text valid UTF-8, but diff lines keep their content,
  escape sequences included.

## For client authors

- Treat everything from a pane as untrusted: OUTPUT bytes, titles, cwd, clipboard copies, agent
  messages. On a remote machine, so is the daemon's whole stream.
- Diff text and paths (`git.changes`, `git.diff`) are untrusted too: they are a repository's
  contents. Draw them as text, never as markup or as terminal output, and never build a shell
  command or a URL from a path without quoting it. The same goes for `peek` lines, which are
  pane output with the control characters removed.
- Keep reading, or expect to be disconnected. Heartbeat with `ping` (Transfers).
- Never pass a user-entered host to ssh where it could be read as an option (use
  `ssh … -- host`, or refuse a leading `-`).
