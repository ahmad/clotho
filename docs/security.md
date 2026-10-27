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
| 10 | Low | Push ciphertext length reveals the alert message's length | no (needs iOS) |
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

### 10. Push length (Low, not fixed)

Push alerts are HPKE-sealed to the phone's key (X25519, ChaCha20-Poly1305), with the collapse id
as AAD. The relay and APNs see the device handle, a per-pane collapse id (stable per pane, so
alerts from one pane can be linked), the time, and the ciphertext's length. The length reveals
the message's length, which is at most 400 bytes. Padding the plaintext to a fixed size would
hide it, but iOS's decoder and the shared test vector have to agree first. Proposed to ios; not
changed.

### 11. Startup read (Info, fixed)

`build_id` read the whole executable into memory to hash it, and serve does that at startup:
110 MB for a debug build, ~6 MB for a release build. It now streams the file. The ids are
unchanged.

## Checked, no finding

- **Framing:** frames over 16 MiB close the connection, as does a zero-length frame. JSON is
  limited to 128 levels of nesting by serde_json (e2e `deeply_nested_json_closes_only_that_connection`:
  1 MiB of `[` closes that connection, and serve keeps serving). Unknown frame types are
  ignored. Requests on a connection run one at a time, so a flood is that connection's problem.
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

## For client authors

- Treat everything from a pane as untrusted: OUTPUT bytes, titles, cwd, clipboard copies, agent
  messages. On a remote machine, so is the daemon's whole stream.
- Keep reading, or expect to be disconnected. Heartbeat with `ping` (Transfers).
- Never pass a user-entered host to ssh where it could be read as an option (use
  `ssh … -- host`, or refuse a leading `-`).
