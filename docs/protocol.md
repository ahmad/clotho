# clothod client protocol

Status: **draft v1** (2026-10-26). The message shapes below are what clothod implements. Changes
before the first release are announced to the ClothoKit side; after it, they follow the
versioning rules in [Handshake](#handshake).

The protocol has one connection per client. That connection carries control traffic (requests,
replies, events) and the data channels of the panes the client subscribed to. The same byte
stream runs over every transport: a local Unix socket now, and `ssh host clothod bridge` (stdio)
later.

## Transport

- Local Unix socket. **Ask for its path with `clothod status --print-socket`** rather than
  computing it. Currently it is `/tmp/clothod-<uid>/clothod.sock` on Linux and
  `<per-user temp dir>/clothod/clothod.sock` on macOS, where the per-user temp dir is
  `confstr(_CS_DARWIN_USER_TEMP_DIR)`, usually equal to `$TMPDIR`. `CLOTHOD_RUNTIME_DIR` (or
  `--runtime-dir`) overrides it. The directory is mode 0700 and owned by the user, and the daemon
  also checks the peer's uid. docs/remote.md explains why it isn't `$XDG_RUNTIME_DIR`. The daemon
  keeps the socket alive against temp cleaners, touching it hourly and rebinding it if it is
  deleted.
- Remote machines: see docs/remote.md (`clothod bridge` over SSH).
- If the socket is missing or refuses connections, a client may start the daemon with
  `clothod start`, which forks it into the background and returns once the socket accepts
  connections.

## Framing

Every frame is

```
u32  length   big-endian, number of bytes after this field (type + body)
u8   type
...  body
```

The maximum `length` is 16 MiB. A peer that receives a larger frame closes the connection.

| type | name     | body                                                                 | direction |
|------|----------|----------------------------------------------------------------------|-----------|
| 1    | JSON     | one UTF-8 JSON object                                                | both      |
| 2    | OUTPUT   | `u64 pane`, `u64 seq`, then raw PTY bytes                            | daemon → client |
| 3    | INPUT    | `u64 pane`, then raw bytes to write to the PTY                       | client → daemon |
| 4    | SNAPSHOT | `u64 pane`, `u64 seq`, `u16 cols`, `u16 rows`, then VT bytes         | daemon → client |
| 5    | FILE_DATA | `u64 stream`, `u64 offset`, `u8 flags`, then file bytes (see [Files](#files)) | both |

All integers are big-endian. Receivers ignore frame types they don't know, which leaves room to
add types later.

## JSON messages

Requests (client → daemon):

```json
{"id": 7, "method": "pane.split", "params": {"pane": 3, "direction": "right"}}
```

Replies (daemon → client) carry the request's `id` and either `result` or `error`:

```json
{"id": 7, "result": {"pane": 12}}
{"id": 7, "error": {"code": "not_found", "message": "no pane 3"}}
```

Events (daemon → client) have no `id`:

```json
{"event": "pane", "data": {...}}
```

`id` is any integer the client picks (unique among its pending requests). `params` may be left out
when a method takes none. Unknown fields are ignored on both sides.

Error codes: `bad_request`, `unknown_method`, `not_found`, `handshake_required`,
`protocol_mismatch`, `spawn_failed`, `wrong_pane`, `internal`.

Ordering: the daemon writes every frame for a connection through one ordered queue, so replies,
events, OUTPUT and SNAPSHOT frames reach the client in the order the daemon produced them. That
order is what the guarantees in [Pane data](#pane-data) rely on.

## Handshake

The first request on a connection must be `hello`. Any other request gets `handshake_required`.

```json
→ {"id": 1, "method": "hello", "params": {"protocol": 1, "client": "clotho-mac/0.1"}}
← {"id": 1, "result": {
     "protocol": 1, "protocol_min": 1, "protocol_max": 1,
     "features": ["pane.keys", "agents", "agent.report.pid", "ping", "split.set_ratio"],
     "daemon": "clothod", "version": "0.1.0",
     "instance": "7f3a9c2e5b104d8a",
     "pid": 4242,
     "machine": {"hostname": "mbp", "os": "macos", "arch": "aarch64"},
     "exe": "/Users/me/Library/Application Support/clothod/bin/0.1.1-3f2a9c1b7d4e/clothod",
     "build": "0.1.1-3f2a9c1b7d4e",
     "holder": {"pid": 4100, "version": "0.1.1", "protocol": 1, "build": "0.1.1-3f2a9c1b7d4e",
                "can_upgrade": true, "outdated": false,
                "exe": "/Users/me/Library/Application Support/clothod/bin/0.1.1-3f2a9c1b7d4e/clothod"},
     "holder_outdated": false
   }}
```

- `features` lists what this build supports, as strings: currently `pane.keys`, `agents`,
  `agent.report.pid`, `ping` and `split.set_ratio`. Builds share version numbers, so check
  `features` rather than `version`, and treat a missing list as none of them.
- `protocol` is an integer. The daemon accepts protocol versions in `[protocol_min,
  protocol_max]`, which a successful `hello` reports. If the
  client's version is outside that range, the reply is `protocol_mismatch` and the message names
  the supported range. Within one protocol version, changes are additive only (new methods,
  fields, events and frame types).
- `instance` identifies the PTY holder's lifetime. It stays the same across restarts and
  upgrades of the logic daemon, and changes only when the holder starts fresh, which means all
  shells are new and pane IDs may be reused. **A client must drop all cached seqs and pane state
  when `instance` changes.**

- `exe` and `build` (install id, `<version>-<hash>`) describe the daemon. `holder` describes the
  PTY holder process, where the shells live. Normally both run the same build: a daemon that
  starts against a holder running another build upgrades it in place if it can
  (`can_upgrade`): same process, same shells. **`holder_outdated: true`** means the holder runs
  a different build and can't upgrade in place, because it is a legacy holder from before that
  existed. Everything keeps working, but the machine runs two builds until a one-time full
  restart (`clothod shutdown`, which ends every shell). Clients should offer that restart to the
  user, never do it on their own.

### Starting and upgrading the daemon (clients)

**One version, one instance per machine.** clothod keeps exactly one installed build
(`<base>/<version>-<hash>/clothod`, plus the `<base>/current` symlink) and one persistent
instance (the default runtime dir).

1. **First run:** `<bundle>/clothod install` installs the bundled build if nothing is installed
   yet (or this exact build is) and prints the path. If a *different* version is installed it
   refuses (exit 1) and leaves things alone. Nothing gets a second version by installing.
2. **Start:** `<base>/current/clothod start` (exit 0: up; exit 3: incompatible holder, see
   below; any other code is a failure, with the reason on stderr). Starting through `current`
   means any client's restart revives the installed build, never an old one.
3. **Upgrade** (only when the user agrees, and only to a *higher* version, since builds of one
   version can't be ordered): `<bundle>/clothod upgrade`. All or nothing:
   - It installs the new build next to the old one and switches the logic process. The new
     serve upgrades the holder in place, so shells, screens and the same pids are kept.
   - It verifies both run the new build, then makes it the only installed version and points
     `current` at it. It prints `running <path>`.
   - On any failure it goes back to the old build (serve, and holder in place), removes the new
     one and exits non-zero with `upgrade ... failed, rolled back: <reason>`.
   - A legacy holder stays as it is (`holder_outdated`), and stderr says so.
   - Exit 3 means the holder is incompatible (only `shutdown` + `start` fixes that).
4. **Check:** `<base>/current/clothod status --print-builds` prints `serve=<build>`,
   `holder=<build>`, `holder_can_upgrade=` and `holder_outdated=` lines. `clothod ps` lists
   every clothod process of the user and marks anything that isn't the default instance.

Temporary instances (tests, experiments) must use another runtime dir **and**
`--ephemeral[=SECS|exit]` (or `CLOTHOD_EPHEMERAL`). Without it, `start` and `serve` refuse
anything but the default dir. An ephemeral instance shuts down and deletes its dir after SECS
(default 600) with no clients and no panes, or, with `exit`, when its last client (one that sent
`hello`) disconnects. Its holder also ends itself after 60 s without a daemon.

## Model

```
Machine (the daemon) > Workspace > Tab > split tree > Pane
```

All IDs are unsigned integers below 2^53, so they are exact as JSON numbers. They are stable for
the life of the object and never reused within an `instance`.

`state.get` and the `state` event return:

```json
{
  "rev": 42,
  "focus": {"workspace": 1, "tab": 2, "pane": 3},
  "workspaces": [
    {"id": 1, "name": "main", "active_tab": 2, "tabs": [
      {"id": 2, "title": null, "active_pane": 3,
       "layout": {"type": "split", "id": 9, "axis": "horizontal", "ratio": 0.5,
                  "a": {"type": "pane", "pane": 3},
                  "b": {"type": "pane", "pane": 4}}}
    ]}
  ],
  "panes": [
    {"id": 3, "cols": 120, "rows": 40, "pid": 9811, "command": ["/bin/zsh", "-l"],
     "title": "vim notes.md", "cwd": "/Users/ahmad/notes", "seq": 183230, "exited": null}
  ]
}
```

- `rev` goes up by one with every model change (structure or pane fields).
- Layout nodes are either `{"type": "pane", "pane": <id>}` or
  `{"type": "split", "id", "axis", "ratio", "a", "b"}`. `axis` is `"horizontal"` (a left, b
  right) or `"vertical"` (a top, b bottom). `ratio` is the share of `a`, between 0.05 and 0.95.
- Pane fields:
  - `cols` and `rows` are the PTY size.
  - `seq` is the pane's output length so far (see [seq](#seq)).
  - `title` comes from OSC 0/2, and is `null` if never set.
  - `cwd` comes from OSC 7, with a fallback to the process's cwd (`/proc` on Linux, `proc_pidinfo`
    on macOS); it is `null` if unknown.
  - `exited` is `null` while the pane runs, then `{"code": 0}` or `{"signal": 9}`.
- When a tab's active pane closes or exits, the new `active_pane` is the first pane of the
  sibling subtree that takes its place (as in tmux).
- A pane is removed from the layout when its process exits. A tab with no panes closes, but a
  workspace with no tabs stays.
- `focus` is shared by all clients (the daemon's notion of "where the user is").
  `active_tab` is each workspace's last focused tab and `active_pane` each tab's last focused
  pane. `focus` with only a `workspace` goes to that workspace's `active_tab` and its
  `active_pane` (or to its first tab if none). `focus` with only a `tab` goes to its
  `active_pane`.

## Commands

`pane`, `tab`, `workspace` and `split` in params are IDs. Spawn options are shared by every
method that creates a pane:

```json
{"command": ["/bin/zsh", "-l"], "cwd": "/path", "env": {"K": "V"}, "cols": 80, "rows": 24}
```

All spawn options are optional. The defaults are the user's `$SHELL` as a login shell, `cwd` in
`$HOME`, and a size of 80×24. Children get `TERM=xterm-256color`, `COLORTERM=truecolor`,
`TERM_PROGRAM=clotho`, `CLOTHO_PANE=<id>` and `CLOTHOD_SOCKET=<daemon socket>` (see
[Agents](#agents)).

| method | params | result |
|---|---|---|
| `hello` | `protocol`, `client` | see Handshake |
| `ping` | – | `{}`: cheap liveness check for client heartbeats |
| `state.get` | – | model (above) |
| `events.subscribe` | – | `{}`, then the daemon sends a `state` event right away and events after that |
| `events.unsubscribe` | – | `{}` |
| `workspace.create` | `name?`, spawn options | `{"workspace", "tab", "pane"}` |
| `workspace.rename` | `workspace`, `name` | `{}` |
| `workspace.close` | `workspace` | `{}` (hangs up all its panes) |
| `tab.create` | `workspace`, spawn options | `{"tab", "pane"}` |
| `tab.rename` | `tab`, `title` (null clears it) | `{}` |
| `tab.close` | `tab` | `{}` |
| `pane.split` | `pane`, `direction` (`right`, `down`, `left`, `up`), `ratio?` (default 0.5), spawn options | `{"pane", "split"}` |
| `pane.close` | `pane` | `{}`: sends SIGHUP to the pane's process group and removes the pane from the layout |
| `split.set_ratio` | `split`, `ratio` | `{}` |
| `focus` | `pane` (or `tab` or `workspace`) | `{}` |
| `pane.subscribe` | `pane`, `have_seq?`, `scrollback?`, `viewport?` | see Pane data |
| `pane.unsubscribe` | `pane` | `{}` |
| `pane.viewport` | `pane`, `cols`, `rows` | `{}` (see Resize) |
| `pane.resize` | `pane`, `cols`, `rows` | `{}`: sets the size now, whatever the viewports say |
| `pane.input` | `pane`, `data` (UTF-8 string) | `{}`: same as an INPUT frame, for clients without binary framing |
| `pane.keys` | `pane`, `text?`, `keys?` (list of key names) | `{}`: input encoded for the pane's current modes (see below). Counts as input like an INPUT frame |
| `pane.text` | `pane` | `{"lines": [..], "cursor": [col, row], "cols", "rows", "seq", "modes": {"kitty_flags", "bracketed_paste", "app_cursor", "app_keypad"}}`: plain text of the visible screen, plus the input modes the application set (debugging and tests) |
| `daemon.stop` | – | `{}`, then the logic process exits; shells keep running in the holder |
| `daemon.shutdown` | – | `{}`, then all panes are hung up and the holder and daemon exit |

**`pane.keys`** is for clients that want to say "press Enter" rather than produce bytes:
quick replies, scripted driving, remote controls. `text` is sent first, wrapped in
`ESC[200~`…`ESC[201~` when the application turned on bracketed paste (`?2004`). Then each key
in `keys` is encoded the way a terminal would for the application's current modes: DECCKM
(SS3 cursor keys), the keypad mode, and kitty keyboard flags. For example, Enter is `\r`
normally and `ESC[13u` under kitty "report all keys as escape codes", and Esc becomes
`ESC[27u` under kitty "disambiguate". Key names: `enter`, `tab`, `backspace`, `escape`/`esc`,
`space`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `insert`, `delete`,
`f1`–`f12`, or a single character. Each can take the modifiers `shift+`, `alt+` and `ctrl+`, as
in `ctrl+c` or `shift+tab`. An unknown key name is `bad_request` and nothing is sent. The
daemon doesn't advertise kitty keyboard support, because terminal clients send legacy
encodings, but it tracks flags an application sets anyway, so `pane.keys` stays correct.

INPUT frames for a pane that doesn't exist are dropped silently. There is no reply for an INPUT
frame.

| `agent.report` | `pane`, `state` (or `"clear"`), `kind?`, `message?`, `session?`, `pid?` | `{}`; see [Agents](#agents). With `pid`, the daemon checks that the process runs in that pane (same session as the pane's process, or a descendant) and otherwise answers `wrong_pane` |
| `agent.ack` | `pane` | `{}`: clears the agent's `attention` |

Reserved for later (not implemented): `fs.list` / `fs.stat` / `fs.read` / `fs.write` (file APIs
with streamed bodies).

## Events

| event | data | when |
|---|---|---|
| `state` | full model | right after `events.subscribe`, and after any structural change (workspace/tab/pane created or closed, layout or ratio changed, rename, focus) |
| `pane` | one pane object, plus `"rev"` | a pane's fields changed (title, cwd, size, exit) |
| `bell` | `{"pane"}` | BEL from the pane |
| `agent` | `{"pane", "agent": <agent or null>, "from": <previous state or null>}` | an agent appeared, changed `state`, or went away (`agent: null`); see [Agents](#agents) |
| `pane.resized` | `{"pane", "cols", "rows", "seq"}` | the pane's PTY size changed; see [Resize](#resize) |
| `pane.resync` | `{"pane"}` | the client fell behind on this pane, and a SNAPSHOT follows; see [Output](#output) |

`state`, `pane`, `bell` and `agent` go only to connections that called `events.subscribe`. `pane.resized`
and `pane.resync` are part of a pane's data stream: they go to every subscriber of that pane,
whether or not it subscribed to events, in order with that pane's OUTPUT and SNAPSHOT frames.

Focus changes, whether they come from this client or another one, arrive as a `state` event with
the new `focus`. That is the only way they are delivered.

A client keeps its model current by replacing everything on `state` and replacing one pane on
`pane`. If `rev` jumps by more than one between events the client saw, it missed nothing that
matters: a later `state` covers structure, and `pane` events always carry the whole pane.

## Agents

The daemon tracks coding agents (Claude Code, Codex, ...) running in panes, so every client
shows the same thing. A pane object has an `agent` field. It is `null` when no agent is known,
and otherwise:

```json
{"kind": "claude", "state": "waiting", "source": "hook", "message": "Claude needs your permission to use Bash",
 "since": 1761512345.123, "attention": true, "session": "3f1c..."}
```

| field | |
|---|---|
| `kind` | `"claude"`, `"codex"` or `"other"` (more may be added) |
| `state` | `"starting"`, `"running"`, `"waiting"` (needs the user: a permission prompt, a question, idle after being asked something), `"done"` (the turn finished), `"error"`. Clients treat unknown values as unknown |
| `source` | `"hook"` (the agent reports through `clothod report`) or `"detected"` (inferred from the pane's processes and output) |
| `message` | what the agent says, or `null` |
| `since` | when `state` last changed, in **unix seconds as a float** |
| `attention` | the agent needs the user. It is raised only by exact signals: a hook-reported transition into `waiting`, `done` or `error`, or a terminal bell (BEL) from a detected agent. Detection's own guesses (quiet output read as `waiting`) never raise it. Cleared when any client sends input to the pane (INPUT frame or `pane.input`) or calls `agent.ack`. Owned by the daemon: acknowledging on one device clears it everywhere. **Clients should notify and badge on `attention` becoming true, not on state transitions** |
| `session` | the agent's own session id, if it reports one |

Changes reach clients in two ways. Every change to the field comes as a `pane` event, because
the pane object changed. State transitions (including an agent appearing or going away) also
come as an `agent` event, `{"pane", "agent", "from"}`, with the full new object (or `null`) and
the previous state (or `null`), so clients can notify without diffing.

**Clearing:** the field goes back to `null` when the agent reports that its session ended, when
the agent's process exits (it's watched by pid), or when the pane closes.

**Hooks and detection:**

- Hooks are exact. The hook command runs `<install base>/current/clothod report ...`.
  `clothod install` keeps the `current` symlink pointing at the newest installed build, so
  hooks keep working across upgrades and in shells that are older than agent support. The
  command does nothing unless `CLOTHO_PANE` is set (every pane has it) and that binary exists.
  `report` tries `CLOTHOD_SOCKET` (set in panes by newer holders), then the default socket,
  then every running daemon in the per-user registry (`<state>/clothod/instances/<pid>`, which
  holds the socket path). It sends its `pid`, and only the daemon whose pane really contains that
  process accepts, so a pane id that exists in several daemons is never reported to the wrong
  one. It makes one round trip and always exits 0 silently,
  including outside clotho and with no daemon, so a hook never disturbs the agent.
  `$CLOTHOD_REPORT` overrides the binary, for tests and dev builds.
- Without hooks, the daemon detects agents by looking at the pane's foreground process group (the
  terminal's `tpgid`, with the process name and argv from `/proc` or `libproc`): a `claude` or
  `codex` process means an agent of that `kind` with `source: "detected"`. The state is inferred:
  recent output means `running`, quiet after activity means `waiting`, and a BEL means `waiting`.
- Once a pane gets a hook report, detection no longer changes its state. It only clears the field
  when the agent process is gone.

`clothod report` usage (normally called by hooks, not by people):

```
clothod report <starting|running|waiting|done|error|clear> [--agent claude] [--message TEXT] [--session ID]
clothod report --claude-hook      # reads Claude Code's hook JSON on stdin and maps the event
clothod report --codex-notify JSON # Codex's notify payload (agent-turn-complete -> done)
```

Claude Code hook mapping: `SessionStart` → starting, `UserPromptSubmit` and `PreToolUse` →
running, `Notification` → waiting (with its message), `Stop` → done, `SessionEnd` → clear.

Installing hooks edits the user's agent configuration, so clients run it only after the user
confirms:

```
clothod hooks print claude|codex       # show the snippet
clothod hooks install claude|codex     # merge into ~/.claude/settings.json / ~/.codex/config.toml
clothod hooks uninstall claude|codex   # remove exactly what install added
clothod hooks status                   # installed or not, per agent
```

`install` also installs the running binary (and `current`) if needed. It is idempotent and keeps
the user's existing hooks. It backs the file up to
`<file>.clotho-backup-<unix time>` before changing it. For Codex, which allows only one `notify`
program, an existing one is kept and called after clotho's. `uninstall` puts it back.

## Pane data

### seq

Every pane has a byte counter. `seq` is the number of bytes the pane has output since it was
spawned, so an OUTPUT frame with `seq = s` carrying `n` bytes covers `[s, s+n)`. After processing
that frame the client "has up to `s+n`". A SNAPSHOT with `seq = s` is the terminal state after
exactly `s` bytes.

### Subscribing

```json
→ {"id": 5, "method": "pane.subscribe",
   "params": {"pane": 3, "have_seq": 183000, "scrollback": 1000, "viewport": {"cols": 120, "rows": 40}}}
← {"id": 5, "result": {"mode": "replay", "seq": 183000, "cols": 120, "rows": 40}}
← OUTPUT pane=3 seq=183000 (230 bytes)
← OUTPUT ... (live from here)
```

The daemon picks one of three modes, and the reply always comes before the pane's first frame:

- `live`: `have_seq` equals the pane's current seq. No catch-up is needed and live OUTPUT
  follows.
- `replay`: the daemon still buffers everything after `have_seq`, and the gap is at most
  1 MiB. OUTPUT frames starting at `have_seq` follow, then live output.
- `snapshot`: there is no `have_seq`, the bytes are no longer buffered, the gap is larger, or
  `have_seq` is in the future (stale cache). One SNAPSHOT frame at the current seq follows, then
  live OUTPUT from that seq.

`seq` in the reply is where the stream continues from, and `cols`/`rows` is the pane's current
size. The default `scrollback` is 1000 lines of history in a snapshot (0 means none, and the cap is
the 10,000 lines the daemon keeps).

Subscribing again to a pane that is already subscribed restarts its stream the same way, which is
how a client asks for a fresh snapshot.

### Snapshot contents

A SNAPSHOT body is a VT byte stream (xterm-compatible escape sequences, UTF-8). To apply it,
**resize the local terminal to the frame's `cols`×`rows`, then feed it the bytes.** The stream
starts with a full reset (`ESC c`, `CSI H`, `CSI 2 J`, `CSI 3 J`), so earlier state doesn't
matter. It then recreates the following, in this order:

1. palette overrides (OSC 4/10/11/12)
2. scrollback (up to `scrollback` lines) and the primary screen, with all SGR attributes (bold,
   dim, italic, underline styles, inverse, hidden, strikethrough, 16/256/RGB colors, underline
   color), wide and combining characters, soft wraps, and OSC 8 hyperlinks
3. if the alternate screen is active: the primary cursor, then `CSI ?1049h` and the alternate
   screen's contents
4. the saved cursor (DECSC)
5. modes: DECCKM (`?1`), keypad (`ESC =`), mouse reporting (`?1000/1002/1003/1005/1006`), focus
   events (`?1004`), bracketed paste (`?2004`), alternate scroll (`?1007`), cursor visibility
   (`?25`), LNM, kitty keyboard flags
6. cursor style (DECSCUSR) and the window title (OSC 2)
7. scroll region (DECSTBM), origin mode (`?6`), cursor position (including a pending wrap at the
   right margin), current SGR pen and hyperlink, autowrap off (`?7l`) and insert mode (`CSI 4 h`)
   when set

Not carried: G0–G3 charset designations, custom tab stops and the title stack. Applications
rarely depend on these across a reattach.

Known issue (TODO): randomized testing found one rare case where a wide character that an
insert-character (ICH) pushed toward the right margin does not round-trip. Its row can come back
misaligned. About 1 in 100k random sequences hits it, and no real application has been seen to.
It is tracked in `clothod/crates/vt` (`randomized_roundtrips`, seed 7).

### Output

OUTPUT frames for a subscribed pane arrive in seq order with no gaps. If a client stops reading
and the daemon's queue for it fills up (about 8 MiB), the daemon stops sending that pane's output.
Once the queue drains, it sends `{"event": "pane.resync", "data": {"pane": 3}}` and then a fresh
SNAPSHOT, and the stream continues from there. The connection is never dropped for being slow.

When a pane exits, its subscribers get the remaining output, then a `pane` event with `exited`
set. The subscription ends when the pane is removed.

### Terminal replies

The daemon's own terminal emulator answers the application's queries: DA, DSR/cursor position,
OSC 10/11 color queries, XTWINOPS size and so on. That way apps get exactly one answer even when
no client or several clients are attached. **Clients must not forward their emulator's
auto-generated responses as input.** Send only user input such as keys, paste, and mouse and focus
reports. (With SwiftTerm, that means filtering what the terminal delegate's `send` emits for
query responses.)

## Files

Status: **draft** (2026-10-26, for review by the ClothoKit side; not implemented yet). Feature
flag: `fs` in `hello.features`.

File access on the daemon's machine, for file browsers and transfers. It replaces running
scripts and rsync over SSH, and it works the same locally, through `clothod bridge`, and later
on iOS. The daemon acts as the user it runs as, with the same rights an SSH login has.

### Paths and entries

Paths are absolute (`/home/me/x`) or start with `~` (`~`, `~/notes`), which expands to the
user's home. Anything else is `bad_request`. Paths are not normalized beyond that, and symlinks
are followed except where noted. A pane's `cwd` field is a good place to start browsing.

An **entry**:

```json
{"name": "notes.md", "path": "/home/me/notes.md", "type": "file", "size": 1234,
 "mtime": 1761512345.5, "mode": 420, "target": null, "hidden": false}
```

| field | |
|---|---|
| `type` | `"file"`, `"dir"`, `"symlink"` (only from `fs.list`/`fs.stat` with `follow: false`) or `"other"` (sockets, devices, FIFOs) |
| `size` | bytes (for directories: what the OS reports) |
| `mtime` | unix seconds, float |
| `mode` | permission bits as an integer (`0o644` = 420) |
| `target` | for symlinks, the link text; otherwise `null` |
| `hidden` | the name starts with `.` |

### Metadata methods

| method | params | result |
|---|---|---|
| `fs.stat` | `path`, `follow?` (default true) | an entry |
| `fs.list` | `path`, `hidden?` (default true), `limit?` (default 10000) | `{"path", "entries": [..], "truncated": bool}`, entries sorted by name; `path` is the resolved directory |
| `fs.mkdir` | `path`, `parents?` (default false) | the new directory's entry |
| `fs.rename` | `from`, `to`, `overwrite?` (default false) | the entry at `to`. Within one filesystem this is atomic; across filesystems it is `cross_device` (copy with read and write instead) |
| `fs.remove` | `path`, `recursive?` (default false) | `{}`. A non-empty directory needs `recursive: true`. Symlinks are removed, not followed |

### Transfers

Contents move as **streams**: a `stream` id the daemon assigns, carried in FILE_DATA frames.

```
FILE_DATA:  u64 stream | u64 offset | u8 flags | bytes...      flags: 1 = FIN (last frame)
```

- `offset` is the position of the first byte in the file.
- Chunks are at most 256 KiB.
- An empty frame with FIN ends a stream.
- Streams of one connection are independent and interleave with pane output, so a large
  transfer doesn't stall terminals.
- A connection may have 16 streams open; more is `too_many_streams`.

**Flow control** is credit based, so neither side buffers without bound. The receiver of the data
grants a window: the sender may send bytes up to `acked + window`. The receiver acknowledges
consumed bytes with `fs.ack`, which slides the window. The default window is 4 MiB.

**Reading:**

```json
→ {"id": 9, "method": "fs.read", "params": {"path": "~/big.iso", "offset": 0, "length": null, "window": 4194304}}
← {"id": 9, "result": {"stream": 3, "size": 734003200, "mtime": 1761512345.5, "offset": 0}}
← FILE_DATA stream=3 offset=0 ... (up to the window)
→ {"id": 10, "method": "fs.ack", "params": {"stream": 3, "offset": 4194304}}
← FILE_DATA ... ← FILE_DATA stream=3 offset=… flags=FIN
```

- `offset` and `length` (null means to the end) select a range, which also resumes an
  interrupted download.
- `size` and `mtime` are taken when the stream opens. If the file changes meanwhile, the stream
  ends with an `fs.error` (`changed`) rather than delivering a mix.

**Writing:**

```json
→ {"id": 11, "method": "fs.write", "params": {"path": "~/upload.bin", "size": 52428800,
    "overwrite": true, "expect_mtime": null, "mode": null, "upload_id": "8f3c…"}}
← {"id": 11, "result": {"stream": 4, "offset": 0, "window": 4194304}}
→ FILE_DATA stream=4 offset=0 ... (up to the window)
← {"event": "fs.ack", "data": {"stream": 4, "offset": 4194304}}
→ ... → FILE_DATA stream=4 offset=… flags=FIN
← {"event": "fs.done", "data": {"stream": 4, "entry": {...}}}
```

- **Atomic:** the bytes go to a hidden temp file next to the target (`.<name>.clotho-part-<id>`),
  which is fsynced and renamed over the target only after FIN, and only if `size` (when given)
  matches. Readers never see a partial file.
- **Conflicts:** with `overwrite: false`, an existing target is `exists`. With `expect_mtime`, the
  target must still have that mtime when the write completes (else `conflict`), for safe
  edit-and-save.
- **Resume:** a client-chosen `upload_id` names the temp file. If a write with the same
  `upload_id` and path finds a part file from an interrupted attempt, the reply's `offset` says
  how many bytes it already has, and the client continues from there. Part files nobody resumes
  are deleted after 24 h. Without `upload_id`, every write starts at 0.
- `mode` sets permission bits on the new file. By default a new file gets 0644 (less the umask)
  and a replaced file keeps the old file's mode.

**Ending a stream early:**

- `fs.cancel {stream}`, from the client, stops a read or abandons a write (its temp file is kept
  if it has an `upload_id`, for resuming, and deleted otherwise). The daemon confirms with
  `fs.done {stream, cancelled: true}`.
- A daemon-side failure mid-stream is `{"event": "fs.error", "data": {"stream", "code",
  "message"}}`. The stream is over, and FILE_DATA for it is ignored.
- A dropped connection cancels its streams.

`fs.done`, `fs.error` and `fs.ack` (from the daemon) go to the connection that owns the stream,
whether or not it subscribed to events.

### Errors

`fs.*` failures use the usual error object, with these codes: `not_found`, `exists`,
`permission_denied`, `not_a_directory`, `is_a_directory`, `not_empty`, `cross_device`,
`no_space`, `read_only`, `conflict`, `changed`, `too_many_streams`, `io_error` (anything else,
with the OS message), `bad_request`.

### Not in this version

Watching directories for changes (`fs.watch`), checksums, and server-side copy. These may come
later as additive features.

## Resize

A PTY has one size, but several clients may show a pane. The rules:

- A client gives the size it can show a pane at as its viewport, either in `pane.subscribe`
  (`viewport`) or later with `pane.viewport`.
- The pane takes the viewport of the client that most recently sent it input (an INPUT frame or
  `pane.input`). Until anyone types, the most recent subscriber with a viewport wins.
- `pane.resize` sets the size directly, for a client that wants to force it.
- A `viewport` in `pane.subscribe` that changes the size is applied before the reply. The reply's
  `cols`/`rows` (and the SNAPSHOT) already reflect it, so the subscribing client gets no
  `pane.resized` for it. Other subscribers do.
- When the size changes, every subscriber of the pane gets
  `{"event": "pane.resized", "data": {"pane", "cols", "rows", "seq"}}` placed in its stream
  exactly where the resize happened. Bytes after it were produced at the new size. All event
  subscribers also get the `pane` event.
- A client whose viewport is larger or smaller than the pane's size letterboxes or scales. It must
  not resize its local terminal to anything except the pane's size.

## Versioning notes for implementers

- Ignore unknown JSON fields, unknown events and unknown frame types.
- `protocol` goes up only for breaking changes.
- The daemon may add fields to the model (for example `agent` status on panes) without a version
  bump.
