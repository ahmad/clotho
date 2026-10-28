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

The maximum `length` is 16 MiB. A peer that receives a larger frame closes the connection. JSON
nested deeper than 128 levels is malformed, and so does the same.

A client has to keep reading. If more than 64 MiB of replies and events are waiting for a client
that has stopped reading (a half-open connection, a suspended app), the daemon closes the
connection rather than buffering more: reconnect and resync as after any disconnect. Pane output
has its own limit, below that (see [Subscribing](#subscribing)).

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
     "features": ["pane.keys", "agents", "agent.report.pid", "ping", "split.set_ratio", "fs", "push",
                  "pane.clipboard", "settings", "service", "agent.mute",
                  "pane.search", "agent.history", "agent.decide"],
     "daemon": "clothod", "version": "0.1.0",
     "instance": "7f3a9c2e5b104d8a",
     "pid": 4242,
     "machine": {"hostname": "mbp", "os": "macos", "arch": "aarch64", "home": "/Users/me"},
     "exe": "/Users/me/Library/Application Support/clothod/bin/0.1.1-3f2a9c1b7d4e/clothod",
     "build": "0.1.1-3f2a9c1b7d4e",
     "holder": {"pid": 4100, "version": "0.1.1", "protocol": 1, "build": "0.1.1-3f2a9c1b7d4e",
                "can_upgrade": true, "outdated": false,
                "exe": "/Users/me/Library/Application Support/clothod/bin/0.1.1-3f2a9c1b7d4e/clothod"},
     "holder_outdated": false
   }}
```

- `features` lists what this build supports, as strings: currently `pane.keys`, `agents`,
  `agent.report.pid`, `ping`, `split.set_ratio`, `fs` (Files, below), `push` (`push.*`
  requests, docs/push.md), `pane.clipboard` (OSC 52 copies, see
  [Clipboard](#clipboard-osc-52)), `settings` (`settings.get` and `settings.set`, see
  [Settings](#settings)), `service` (`service.*`, see [Start at login](#start-at-login)) and
  `agent.mute` (the agent's `muted` field and the `agent.mute` request, see [Agents](#agents)),
  `pane.search` ([Searching scrollback](#searching-scrollback), since 0.1.11) and
  `agent.history` ([Agent history](#agent-history), since 0.1.11), `agent.decide`
  ([Permission requests](#permission-requests), the agent's `requests`, since 0.1.13).
  Builds share version numbers, so check
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
   `install` sets `current` only when nothing else is installed: while another version is
   there (such as in the middle of an upgrade) only `upgrade` moves it. Clients should still
   run `install` only when there is no `current/clothod` yet, since builds before 0.1.9 did
   move it.
2. **Start:** `<base>/current/clothod start` (exit 0: up; exit 3: incompatible holder, see
   below; any other code is a failure, with the reason on stderr). Starting through `current`
   means any client's restart revives the installed build, never an old one.
3. **Upgrade** (only when the user agrees, and only to a *higher* version, since builds of one
   version can't be ordered): `<bundle>/clothod upgrade`. All or nothing:
   - It installs the new build next to the old one and switches the logic process. The new
     serve upgrades the holder in place, so shells, screens and the same pids are kept.
   - It points `current` at the new build *before* it stops the old serve, so a client that
     restarts the daemon through `current` while it switches gets the new build.
   - While it runs it holds `upgrade.lock` in the runtime dir. A `start` (and so a `bridge`)
     from anyone else during that time waits up to 60 s for the daemon the upgrade brings up,
     and exits 0 once it answers, instead of starting a daemon of its own. Clients therefore
     need nothing special: reconnecting with `current/clothod start` right away is fine.
   - It verifies both run the new build, then makes it the only installed version. It prints
     `running <path>`.
   - On any failure it goes back to the old build (serve, and holder in place, and `current`),
     removes the new one and exits non-zero with `upgrade ... failed, rolled back: <reason>`.
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
     "title": "vim notes.md", "cwd": "/Users/ahmad/notes", "seq": 183230, "exited": null,
     "scrollback_lines": 2000}
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
  - `title` comes from OSC 0/2, and is `null` if never set. It holds no control characters (C0,
    DEL, C1 are dropped) and at most 1024 characters. `cwd` comes from OSC 7 (at most 4096 bytes;
    one with control characters is ignored) or the process.
  - A pane's output is untrusted: the program may be `cat` of any file or a shell on another
    machine. An OSC string over about 1.4 MiB (enough for a 1 MiB OSC 52 copy) is dropped whole,
    unparsed, so endless output can't grow the daemon. Clients get the raw OUTPUT bytes regardless
    and should apply their own limits.
  - `cwd` comes from OSC 7, with a fallback to the process's cwd (`/proc` on Linux, `proc_pidinfo`
    on macOS); it is `null` if unknown.
  - `exited` is `null` while the pane runs, then `{"code": 0}` or `{"signal": 9}`.
  - `scrollback_lines` is the history the daemon keeps for the pane (spawn options).
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
{"command": ["/bin/zsh", "-l"], "cwd": "/path", "env": {"K": "V"}, "cols": 80, "rows": 24,
 "scrollback_lines": 2000}
```

All spawn options are optional. The defaults are the user's `$SHELL` as a login shell, `cwd` in
`$HOME`, and a size of 80×24. `scrollback_lines` (0 to 50,000) is how much history the daemon
keeps for this pane, which is what a reattaching or newly started client can get back. Without
it, the pane follows the machine's setting (see [Settings](#settings)), also when that changes
later; with it, the pane keeps its own value. Either way a pane keeps its value across daemon
restarts. Children get `TERM=xterm-256color`, `COLORTERM=truecolor`,
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
| `pane.search` | `pane`, `query`; optional `regex`, `case_sensitive` (both default false), `limit` (1–1000, default 100), `before` (`{line, col}`) | matches in the scrollback and screen, newest first; see [Searching scrollback](#searching-scrollback) |
| `pane.text` | `pane` | `{"lines": [..], "cursor": [col, row], "cols", "rows", "seq", "modes": {"kitty_flags", "bracketed_paste", "app_cursor", "app_keypad"}}`: plain text of the visible screen, plus the input modes the application set (debugging and tests) |
| `settings.get` | – | the settings object; see [Settings](#settings) |
| `settings.set` | any settings to change, e.g. `scrollback_lines` | the settings object, plus `applied_panes`; see [Settings](#settings) |
| `service.status` | – | the service object; see [Start at login](#start-at-login) |
| `service.install` | – | the service object, after the login unit is written and registered |
| `service.uninstall` | – | the service object, after the login unit is removed (the daemon keeps running) |
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

| `agent.decide` | `pane`, `request` (an id from the agent's `requests`), `decision` (`"allow"` or `"deny"`), `message?` (for deny: told to the agent, at most 300 chars) | `{}`. Answers that request only, once: `stale` if it was already answered, retired (answered in the terminal, the turn ended, its hook went away) or never existed. See [Permission requests](#permission-requests) |
| `agent.permission` | `pane`, `pid`, `tool`, `tool_input?`, `key`, `kind?`, `session?` | Sent by `clothod report --claude-permission` (Claude Code's PermissionRequest hook), not by apps. The reply waits until a client decides: `{"decision": "allow"\|"deny", "message"?}`, or `{"retired": true}` |
| `agent.report` | `pane`, `state` (or `"clear"`), `kind?`, `message?`, `session?`, `pid?`, `prompt?` (starts a turn; `""` for one the user didn't type), `tool?` and `tool_input?` (`tool: ""` clears both) | `{}`, or `{"ignored": "nested"}` for a report from an agent the pane's agent runs; see [Agents](#agents). With `pid`, the daemon checks that the process runs in that pane (same session as the pane's process, or a descendant) and otherwise answers `wrong_pane` |
| `agent.ack` | `pane` | `{}`: clears the agent's `attention` (the user resolved it; the only way a client clears it) |
| `agent.history` | `pane`; optional `limit` (1–200, default 200), `since` (unix seconds: entries after it), `session` | `{"pane", "entries": [..], "max": 200}`, oldest first; see [Agent history](#agent-history) |
| `agent.mute` | `pane`, `muted` (bool) | `{"agent": <agent>}`: mutes or unmutes the pane's agent; see [Agents](#agents). `not_found` if the pane has no agent |

File access (`fs.*`) is described in [Files](#files).

## Events

| event | data | when |
|---|---|---|
| `state` | full model | right after `events.subscribe`, and after any structural change (workspace/tab/pane created or closed, layout or ratio changed, rename, focus) |
| `pane` | one pane object, plus `"rev"` | a pane's fields changed (title, cwd, size, exit) |
| `bell` | `{"pane"}` | BEL from the pane |
| `agent` | `{"pane", "agent": <agent or null>, "from": <previous state or null>}` | an agent appeared, changed `state`, or went away (`agent: null`); see [Agents](#agents) |
| `pane.resized` | `{"pane", "cols", "rows", "seq"}` | the pane's PTY size changed; see [Resize](#resize) |
| `pane.resync` | `{"pane"}` | the client fell behind on this pane, and a SNAPSHOT follows; see [Output](#output) |
| `pane.clipboard` | `{"pane", "target", "text"}` | the pane's application copied text with OSC 52; see [Clipboard](#clipboard-osc-52) |
| `settings` | the settings object | a client changed a setting (`settings.set`); see [Settings](#settings) |
| `service` | the service object | a client installed or removed the login unit; see [Start at login](#start-at-login) |

`state`, `pane`, `bell`, `agent`, `settings` and `service` go only to connections that called `events.subscribe`. `pane.resized`,
`pane.resync` and `pane.clipboard` are part of a pane's data stream: they go to every subscriber of that pane,
whether or not it subscribed to events, in order with that pane's OUTPUT and SNAPSHOT frames.

Focus changes, whether they come from this client or another one, arrive as a `state` event with
the new `focus`. That is the only way they are delivered.

A client keeps its model current by replacing everything on `state` and replacing one pane on
`pane`. If `rev` jumps by more than one between events the client saw, it missed nothing that
matters: a later `state` covers structure, and `pane` events always carry the whole pane.

## Settings

Feature flag: `settings` in `hello.features`. Per-machine settings of the daemon, stored in
`~/.config/clothod/config.toml` (`$XDG_CONFIG_HOME/clothod/config.toml` if set). A client shows
them per machine, like "Start at login".

```json
→ {"id": 7, "method": "settings.get"}
← {"id": 7, "result": {
     "scrollback_lines": 2000,
     "limits": {"scrollback_lines": {"min": 0, "max": 50000, "default": 2000}},
     "config": "/home/me/.config/clothod/config.toml"}}

→ {"id": 8, "method": "settings.set", "params": {"scrollback_lines": 10000}}
← {"id": 8, "result": {"scrollback_lines": 10000, "limits": {…}, "config": "…", "applied_panes": [3, 5]}}
```

- **`scrollback_lines`**: lines of history the daemon keeps per pane, which is what a
  reattaching or newly started client can get back (not the client's own scrollback). Integer,
  `limits.scrollback_lines.min`..`max`; clients take the limits from `settings.get` rather than
  hard-coding them.
  - It applies at once: to every new pane, and to every existing pane that follows the setting
    (spawned without its own `scrollback_lines`). `applied_panes` lists the panes that changed;
    each also gets a `pane` event with its new `scrollback_lines`. Lowering it drops those
    panes' oldest history right away; raising it gives them room, but nothing dropped comes
    back. Panes spawned with their own value keep it.
  - **Memory:** history costs about 24 bytes per column per line once it is used. Measured, one
    full 120-column pane takes 8 MB of daemon memory at 2000 lines, 31 MB at 10,000 and 142 MB at
    50,000, and every pane that fills up costs that much. A client choosing large values should
    say so to the user.
- `settings.set` takes only the keys it changes. It checks all of them first, so a bad value
  (`bad_request`: unknown key, wrong type, out of range) changes nothing. Then it writes the
  config file atomically, keeping its comments and other keys, and applies the change. A config
  file that isn't valid TOML is never overwritten: the answer is `config_failed`, and nothing
  changes. The daemon reads the file again when it starts, so edits by hand still work.
- Every connection that called `events.subscribe` gets a `settings` event with the new settings
  object (including the client that made the change).

## Start at login

Feature flag: `service` in `hello.features`. A per-machine "Start at login" toggle: a
LaunchAgent on macOS, a systemd user unit on Linux, managed by the daemon on that machine
(`clothod service install|uninstall|status` does the same from a shell). Clients show it per
machine and turn it on only when the user asks; nothing installs it on its own.

```json
→ {"id": 9, "method": "service.status"}
← {"id": 9, "result": {
     "supported": true, "manager": "systemd", "label": "clothod",
     "file": "/home/me/.config/systemd/user/clothod.service",
     "installed": false, "loaded": false, "up_to_date": false,
     "command": ["/home/me/.local/share/clothod/bin/current/clothod", "start"],
     "linger": false, "needs": ["linger"],
     "message": "Start at login needs lingering on Linux: … `sudo loginctl enable-linger me`, then try again."}}
```

| field | meaning |
|---|---|
| `supported` | a unit can be managed here (Linux: a systemd user manager answers). If false, `message` says why |
| `manager` | `launchd` or `systemd` |
| `installed` | **the toggle's state**: the unit file is there, so the daemon starts at the next login |
| `loaded` | the service manager has it right now (launchd: loaded in the GUI session; systemd: enabled) |
| `up_to_date` | the file is what `install` would write now. If it's false while `installed`, `service.install` again refreshes it |
| `command` | what it runs at login: `<install dir>/current/clothod start` |
| `linger` | Linux: whether lingering is on (`null` on macOS or if unknown) |
| `needs` | what is missing before `install` can work: `["linger"]` or `[]` |
| `message` | a sentence for the user when something is missing, or `null` |

What the unit does:
- At login it runs `clothod start` once. That starts the daemon unless it runs already, in
  which case it changes nothing, so there is never a second instance.
- It never restarts the daemon: there's no `KeepAlive` and no `Restart=`. The in-place upgrade
  stops serve and starts the new build itself, and a restarter would race it.
- It runs `current`, so after an upgrade it starts the new build with no rewrite.
- Removing it leaves the daemon and every shell running.

`service.install`:
- It's idempotent: an installed unit is rewritten and reloaded.
- It writes the unit and registers it with the service manager. On Linux it also starts the
  unit, which finds the running daemon.
- It's all or nothing: on failure, the file is removed again.

`service.uninstall`:
- It unregisters and deletes the unit. Not installed isn't an error.

Both answer with the new service object, and send a `service` event to event subscribers.

Errors:

| code | when |
|---|---|
| `needs_linger` | Linux without lingering; see below |
| `unsupported` | no service manager to talk to |
| `not_installed` | there is no `<install dir>/current/clothod` yet |
| `conflict` | a file that clothod didn't write is where the unit goes; it's left alone |
| `service_failed` | launchctl or systemctl failed; the message has their output |

**Linux and lingering.** Without lingering, the systemd user manager stops when the user's last
session ends, and it kills every process its units started, the daemon and all shells
included. A daemon started on demand by a client survives logout, so a unit would make things
worse. `service.install` therefore refuses with `needs_linger`, and clients should show
`message`. Turning lingering on (`sudo loginctl enable-linger <user>`) usually needs an admin, so
it's the user's step; clients don't run it. With lingering, the user manager starts at boot, so
the daemon is up before anyone logs in.

## Agents

The daemon tracks coding agents (Claude Code, Codex, ...) running in panes, so every client
shows the same thing. A pane object has an `agent` field. It is `null` when no agent is known,
and otherwise:

```json
{"kind": "claude", "state": "waiting", "source": "hook", "message": "Claude needs your permission to use Bash",
 "since": 1761512345.123, "attention": true, "muted": false, "session": "3f1c..."}
```

| field | |
|---|---|
| `kind` | `"claude"`, `"codex"` or `"other"` (more may be added) |
| `state` | `"starting"`, `"running"`, `"waiting"` (needs the user: a permission prompt, a question, idle after being asked something), `"done"` (the turn finished), `"error"`. Clients treat unknown values as unknown |
| `source` | `"hook"` (the agent reports through `clothod report`) or `"detected"` (inferred from the pane's processes and output) |
| `message` | what the agent says, or `null`. For `waiting`, the prompt it shows ("Claude needs your permission to use Bash"); for `done`, the start of the reply its turn ended with (Claude Code's `last_assistant_message`, Codex's `last-assistant-message`: whitespace collapsed to one line, at most 300 chars); for `error`, the error |
| `prompt` | the first line of the prompt the user typed for the current turn (at most 120 chars), or `null`: no prompt yet, or a turn the user didn't type (started by another agent's message or a finished background task; the wrapper text is never shown) |
| `tool`, `tool_input` | the last tool the agent used in this turn (`"Bash"`) and its key input (`"npm test"`, at most 160 chars: Bash's command, the file of Read/Write/Edit, the pattern of Glob/Grep, the URL, the query, a task's description, else the first text field), or `null`. Cleared by a new turn and by a wait that isn't a permission prompt, so while `waiting` they say what the permission is for |
| `requests` | permission requests the agent is waiting on, oldest first: `[{"id", "tool", "summary"}]` (`"Bash"`, `"npm test"` or `null`). A client can answer one with `agent.decide` (Allow/Deny from the phone or the app). Empty when none. See [Permission requests](#permission-requests). Feature flag: `agent.decide` |
| `turn_started` | unix seconds (float) when the current turn started (its prompt, or work resuming after the turn ended), or `null`. For `done` and `error`, `since - turn_started` is how long the turn took |
| `since` | when `state` last changed, in **unix seconds as a float** |
| `attention` | the agent needs the user. **Raised** only by exact signals: a hook-reported transition into `waiting`, `done` or `error` (including a hook report that takes over from detection in the same state, e.g. detection guessed `waiting` and then the hook reports `waiting`; that also sends an `agent` event whose `from` equals the state), or a terminal bell (BEL) from a detected agent. **Cleared** only when the agent works again (a transition into `running` or `starting` reported by a hook, or shown by Claude Code's title spinner), by `agent.ack` (the user resolved it), or when the agent goes away. Input never clears it: opening a pane makes a client send focus and mouse reports, and looking is not resolving. A typed reply clears it through the agent going back to work. Detection's guesses from output alone (busy read as `running`, quiet as `waiting`) neither raise nor clear it, since an app's redraw after a resize would read as work. Owned by the daemon: acknowledging on one device clears it everywhere. **Clients should notify and badge on `attention` becoming true, not on state transitions**, unless `quiet` is true. Pushes (`push`) follow the same rises, except quiet ones |
| `quiet` | the last rise of `attention` was quiet: the agent's turn ended (`done`) while the user was at the pane, meaning a client that shows the pane (subscribed) sent it input within the last 60 s. The user sees that turn end, so `attention` is raised (badge it, show it in the pane) but the daemon sends no push, and **clients must not post a notification for it** either. Decided when `attention` rises and kept until the next rise (through `agent.ack`), so it is in the `agent` and `pane` events of that rise. Always false for a rise into `waiting` or `error`: those notify even when the user just typed, since they may have stepped away and the agent is stuck until they answer. Absent (older daemons) means false |
| `muted` | the user muted this agent (`agent.mute`). While muted, nothing raises its `attention` (hook `waiting`/`done`/`error`, BEL), so it never notifies or pushes; its `state` still updates as usual. Muting clears `attention`. It lasts for this agent: through restarts and upgrades of the daemon while the agent's process lives, and until `agent.mute` with `muted: false`. It is gone when the agent goes away (session end, exit), and a new agent in the pane starts unmuted. Owned by the daemon, like `attention`: muting on one device mutes it everywhere. Absent (older daemons) means false. Feature flag: `agent.mute` |
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

Claude Code hook mapping (the installed hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `SessionEnd`): `PermissionRequest` →
a permission request (above); `SessionStart` → starting, `UserPromptSubmit`, `PreToolUse` and
`PostToolUse` → running, `Notification` → waiting (with its message), `Stop` → done,
`SessionEnd` → clear. Events that say nothing new about whether the agent needs the user are
ignored (the state and `attention` stay as they are), decided by `clothod report` from the hook's
payload, so the installed hooks don't change:
- `Notification` with `notification_type` `idle_prompt` (Claude Code's "Claude is waiting for
  your input", a minute after a turn ends: a reminder of a `done` the user was already told about)
  or `auth_success`. Without a `notification_type` (older Claude Code), that idle message is
  ignored too. Every other type (`permission_prompt`, `elicitation_dialog`, newer ones) is
  `waiting`.
- `SessionStart` with `source` `"compact"`: compaction, auto or `/compact`, carries on the same
  session. It is not a start, and must not clear a raised `attention`.
- `PreCompact`, `SubagentStop` and anything else.

The turn's context comes from the same payloads: `UserPromptSubmit`'s `prompt` (its first line;
`""` when it is a wrapper Claude Code injected, such as `<cross-session-message>` or
`<task-notification>`), `PreToolUse`'s `tool_name` and `tool_input`, and `Stop`'s
`last_assistant_message` as the `message`. A `Notification` other than a permission prompt clears
the tool. For Codex, `agent-turn-complete`'s last `input-messages` entry is the prompt.

**Nested agents:** an agent that the pane's agent runs (an SDK app it is testing, `claude -p` from
a tool, `codex exec`) has the same hooks, and they report into the same pane. With `pid`, the daemon
looks at the reporter's ancestors up to the pane's process: if two agent processes (`claude`,
`codex`, by the names detection uses) are among them with another process between them, the
report comes from a nested agent and is ignored: `agent.report` answers `{"ignored": "nested"}`
and the pane's agent, its `attention` and pushes are untouched. Agent processes that directly
chain (`node .../codex` running the native `codex-<target>`) count as one agent.

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

### Permission requests

Claude Code asks before it runs a tool, in a dialog in the terminal. With the hooks installed,
its PermissionRequest hook (`clothod report --claude-permission`) also tells the daemon, so a
client can answer from anywhere:

1. The hook sends `agent.permission` with the tool, its key input and `key` (a hash of the tool
   call: name and input). The agent becomes `waiting` with `tool`/`tool_input` set, and the
   request is added to its `requests` with a fresh `id`. Attention and pushes follow the usual
   rules (a permission wait is never `quiet`); the push names the request (`rq`, docs/push.md)
   so it can be answered from the notification. A second request while the agent already
   waits raises nothing new: it shows in `requests`.
2. A client calls `agent.decide` with that id. The daemon passes the decision to the waiting
   hook, which prints it for Claude Code (`allow`, or `deny` with the message) and exits. The
   request leaves `requests`. A second `agent.decide` for the same id answers `stale`; an id
   only ever names its own request, so a decision can never reach another one.
3. Claude's own dialog shows the whole time, and the user can answer it in the terminal first.
   Claude does not stop the hook then, so the daemon retires requests itself. The hook prints
   nothing and exits, and a later `agent.decide` answers `stale`:
   - a `PostToolUse` for the same call (same tool name and input) retires that request only,
     so a subagent's or a parallel call's other tool leaves it alone;
   - `UserPromptSubmit` and `Stop` (the turn moved on or ended) retire all of the agent's
     requests, and so do `SessionEnd` and the agent going away;
   - the hook's connection closing retires its request: Claude ends the hook at its timeout
     (3600 s in the installed hook), and its dialog stays.
   A call the user denied in the terminal has no `PostToolUse`; its request stays until the turn
   moves on. Answering it from the phone then prints a decision Claude no longer reads.

Codex has no such hook: its agents never have `requests`.

### Agent history

`agent.history {pane}` returns what the pane's agents did, oldest first: at most the last 200
entries per pane (`max`), kept across serve restarts and upgrades like the agent's mute (in the
holder's pane state), and gone with the pane.

```json
{"pane": 7, "max": 200, "entries": [
  {"at": 1761512345.5, "event": "state", "kind": "claude", "state": "waiting", "from": "running",
   "message": "Allow rm -rf build?", "session": "6c1f…", "pid": 4242, "source": "hook",
   "guess": false, "attention": true, "muted": false},
  {"at": 1761512351.0, "event": "attention", "kind": "claude", "state": "waiting", "from": "waiting",
   "message": "Allow rm -rf build?", "session": "6c1f…", "pid": 4242, "source": "hook",
   "guess": false, "attention": false, "muted": false},
  {"at": 1761512360.2, "event": "gone", "kind": "claude", "state": null, "from": "done", …}
]}
```

- Each entry is the agent as it was after the change, with the agent fields as in the `agent`
  object, plus `at` (unix seconds), `from` (the state before), `pid` and `event`. `event` is one
  of `state` (a new state, including an agent's arrival), `attention` (raised or cleared in the
  same state, e.g. `agent.ack`), `update` (another field changed: message, session, source),
  `mute`, `unmute`, and `gone` (the agent left; `state` is null).
- An entry is only added when something other than `at` and `event` differs from the last one.
  Detection's output-only guesses (`guess`, see above) are logged when a detected agent appears,
  not each time they flip.
- `message` is cut to 300 characters.
- Filters: `since` (only entries with `at` greater than it, to fetch what's new), `session` (one
  agent's entries), `limit` (the newest that many).
- Live updates come from the `agent` events, as before; history is for what happened while a
  client wasn't watching. Feature flag: `agent.history`.

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
the pane's `scrollback_lines`, 2000 by default; clients keep deeper history themselves while
connected). A connection whose
queue is already full when it subscribes (a reconnect resubscribing many panes) gets the reply
with mode `snapshot` at once, and the snapshot after `pane.resync` once its queue has drained.

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

### Searching scrollback

`pane.search {pane, query}` searches the daemon's copy of the pane, scrollback and screen, from
the newest line up.

```json
→ {"id": 9, "method": "pane.search", "params": {"pane": 7, "query": "error", "limit": 2}}
← {"id": 9, "result": {"seq": 183230, "cols": 120, "rows": 40, "history": 2000, "matches": [
    {"start": {"line": 31, "col": 4}, "end": {"line": 31, "col": 8}, "text": "Error",
     "line_text": "npm Error: missing script"},
    {"start": {"line": -12, "col": 0}, "end": {"line": -12, "col": 4}, "text": "error",
     "line_text": "error[E0308]: mismatched types"}],
   "next": {"line": -12, "col": 0}}}
```

- **Positions** are the coordinates of a snapshot taken at `seq`. `line` 0 is the screen's top
  row, `rows - 1` its bottom, and negative lines are scrollback (-1 the newest, `-history` the
  oldest the daemon keeps). `col` counts cells, so a wide character takes two. `start` and `end`
  are both inclusive. A client that has applied output up to `seq` at the same `cols` has the same
  layout, and its own deeper history continues upward from `-history`. Once more output arrives
  the lines move up, so search again after a new `seq` rather than reusing old positions.
- **Lines:** a match lies within one logical line: soft-wrapped rows joined, trailing blanks
  dropped. So `^` and `$` are the ends of the text on that line, and a match may start on one
  row and end on the next (`end.line` = `start.line + 1`). `line_text` is the whole logical line
  (at most 512 characters) and `text` the match (at most 256).
- **Matching:** literal by default, case-insensitive unless `case_sensitive: true`. With `regex:
  true`, `query` is a Rust regex (the `regex` crate's syntax), e.g. `^error\[E[0-9]+\]`. An
  invalid regex, an empty query or one over 1000 characters is `bad_request`. Empty matches are
  skipped.
- **Paging:** at most `limit` matches (default 100, at most 1000). If there may be more, `next`
  is set: pass it as `before` to continue (only matches starting before it are returned), while
  `seq` hasn't changed. `next` is null when the search reached the oldest line. A search also
  stops after 200 ms with a `next`, since the pane's output waits while it runs. Measured: a
  full scan of 50,000 scrollback rows at 120 columns takes 56 ms (release build, devbox), and a
  page of 100 matches near the bottom 0.6 ms.
- It searches what the daemon keeps (`history` lines: the pane's `scrollback_lines`). Clients
  with deeper local history search the rest themselves. Feature flag: `pane.search`.

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

### Clipboard (OSC 52)

Feature flag: `pane.clipboard` in `hello.features`. Terminal apps such as Claude Code, Codex,
vim and tmux copy by writing `ESC ] 52 ; <target> ; <base64> BEL` (or `ESC \` instead of BEL).
The daemon's terminal decodes that and sends every subscriber of the pane:

```json
← {"event": "pane.clipboard", "data": {"pane": 3, "target": "clipboard", "text": "héllo\n"}}
```

- `text` is the decoded text (UTF-8, as a JSON string). Payloads that aren't valid base64 or
  don't decode to UTF-8 are ignored, and so are empty copies.
- `target` is `"clipboard"` for target `c` or an empty target, and `"selection"` for `p` or `s`
  (X11 primary selection). A client without a primary selection can ignore `"selection"`, or treat
  it as the clipboard. Claude Code and Codex use `c`.
- Only live output copies. A replayed stream (`pane.subscribe` in `replay` mode, or a SNAPSHOT)
  never repeats a copy, and neither does a daemon restart replaying buffered output.
- The event comes just before the OUTPUT frame that carried the sequence. It goes out even while
  the client is lagging behind on the pane's output.
- **Size cap: 1 MiB (1048576 bytes) of decoded text.** A bigger copy is dropped whole, not
  truncated, and the daemon logs it. That's about 1.4 MB of base64 in the sequence.
- **Clipboard reads are never answered.** The query form (`ESC ] 52 ; c ; ? BEL`) gets no reply
  from the daemon, because a pane must never be able to read the user's clipboard. Clients must not
  answer it either.
- OUTPUT still carries the raw OSC 52 bytes, because the stream is exact. **A client must not act
  on OSC 52 that its own emulator sees in OUTPUT or a SNAPSHOT** (with SwiftTerm, make the
  `clipboardCopy` delegate a no-op). The emulator would otherwise copy twice, and copy again when
  it replays a stream. Use only `pane.clipboard`. Against a daemon without the feature, a client
  can fall back to its emulator's handling.
- Which client copies is the client's call. Every attached client gets the event: for example,
  the Mac app sets the pasteboard, and the iOS app does so only while it is in the foreground.

## Files

Status: **implemented** in clothod 0.1.3 (2026-10-27), from draft 2, which folded in the reviews
from mac-d8, ios-c2 and clotho-f5. Feature flag: `fs` in `hello.features`.

File access on the daemon's machine, for file browsers and transfers. It replaces running
scripts and rsync over SSH, and it works the same locally, through `clothod bridge` and from
iOS. The daemon acts as the user it runs as, with the rights an SSH login has.

### Paths

- Paths are absolute (`/home/me/x`), or start with `~` followed by nothing or `/`. That means
  `~` and `~/notes` are accepted, but `~bob/notes` and relative paths are `bad_request`.
  `hello.machine.home` is the expanded home, for breadcrumbs.
- Paths are byte strings on the machine. clothod passes names through unchanged and doesn't
  normalize them; macOS often returns NFD, and clients normalize only for display.
- A name that isn't valid UTF-8 (possible on Linux) is shown lossily in `name` and `path`, and
  the entry also carries `path_raw`: the exact path bytes, base64. Every path parameter has a
  `_raw` twin (`path_raw`, `from_raw`, `to_raw`) that takes those bytes. Send it back for such
  entries. One odd name never breaks a listing.

### Entries

```json
{"name": "notes.md", "path": "/home/me/notes.md", "type": "file", "link": false, "target": null,
 "size": 1234, "mtime": 1761512345.5, "mtime_ns": "1761512345500000000", "mode": 420, "hidden": false}
```

| field | |
|---|---|
| `type` | `"file"`, `"dir"` or `"other"` (sockets, devices, FIFOs, and links whose target is missing). For a symlink this is the type of what it points to, so a link to a directory lists and navigates as a directory |
| `link` | the entry is a symlink; `target` holds the link text (else `null`) |
| `size`, `mode` | of the target for links; `mode` is the permission bits as an integer (`0o644` = 420) |
| `mtime` | unix seconds as a float, for display |
| `mtime_ns` | unix nanoseconds as a decimal string. **Compare and send this one** (`expect_mtime_ns`, `mtime_ns` on writes): floats can't hold nanoseconds exactly |
| `hidden` | the name starts with `.` |
| `path_raw` | only when the path isn't valid UTF-8 (above) |
| `text` | `fs.stat` only: true if the first 8 KiB contain no NUL byte (open as text) |

### Metadata methods

| method | params | result |
|---|---|---|
| `fs.stat` | `path` | an entry (with `text` for files) |
| `fs.list` | `path`, `hidden?` (default true), `limit?` (default 1000, max 10000), `cursor?` | `{"dir": <entry of the directory itself>, "entries": [..], "next": <cursor or null>}` |
| `fs.mkdir` | `path`, `parents?` (default false) | the new directory's entry |
| `fs.setattr` | `path`, `mtime_ns?`, `mode?` | the updated entry (to restore folder times after a tree copy) |
| `fs.rename` | `from`, `to`, `overwrite?` (default false) | the entry at `to`. Atomic within one filesystem; across filesystems it is `cross_device` |
| `fs.remove` | `path`, `recursive?` (default false) | `{}`. A non-empty directory needs `recursive`, and symlinks are removed, not followed |
| `fs.statfs` | `path` | `{"total", "free", "available"}` in bytes, for the filesystem holding `path` (pre-upload checks) |

**Listing large directories:**

- `fs.list` returns entries sorted by name bytes, at most `limit` per call.
- When there are more, `next` is an opaque cursor. Pass it back as `cursor` to get the next
  page. The order is stable, and entries added or removed meanwhile show up or vanish without
  pages repeating.
- `dir` (with `mtime_ns`) lets a client poll cheaply: if the directory's `mtime_ns` hasn't
  changed, its list hasn't either. That covers the gap until `fs.watch` exists.

### Transfers

Contents move as **streams**: a `stream` id the daemon assigns, carried in FILE_DATA frames:

```
FILE_DATA:  u64 stream | u64 offset | u8 flags | bytes...      flags: 1 = FIN (last frame)
```

- `offset` is the position of the first byte in the file. An empty frame with FIN ends a stream.
- **Chunk size** is the client's choice: `chunk` in `fs.read`/`fs.write`, 4 KiB–1 MiB, default
  256 KiB. Use small chunks on slow links: one frame on the wire delays everything behind it.
- **Priority:** the daemon sends replies, events, OUTPUT and SNAPSHOT frames ahead of queued
  FILE_DATA, so terminals stay responsive during transfers. A client sending large writes should
  do the same for its own INPUT.
- **Flow control** is credit based, so nobody buffers without bound. The receiver grants a
  `window` (default 4 MiB; the client sets it for both directions), and the sender may send up to
  `acked + window`. The receiver slides the window with `fs.ack {stream, offset}` (consumed up
  to `offset`). A client sends `fs.ack` **without an `id`**, so it is fire and forget, with no
  reply. Acking about every quarter window keeps the stream moving.
- **How streams end:**
  - A read ends with its FIN frame (empty, at the end offset), or with `fs.error`, or with
    `fs.done {cancelled: true}` after `fs.cancel`. A read never gets an `fs.done` otherwise.
  - A write ends only with `fs.done` (success, with the entry, or cancelled) or `fs.error`. The
    daemon never sends FIN.
  - A read's FILE_DATA never arrives before the `fs.read` reply.
- A connection may have 16 streams open; more is `too_many_streams`. Frames fit easily within
  the 16 MiB frame limit.

**Reading:**

```json
→ {"id": 9, "method": "fs.read", "params": {"path": "~/big.iso", "offset": 0, "length": null,
    "chunk": 262144, "window": 4194304, "expect_size": null, "expect_mtime_ns": null}}
← {"id": 9, "result": {"stream": 3, "size": 734003200, "mtime_ns": "1761512345500000000", "offset": 0}}
← FILE_DATA stream=3 offset=0 … (up to the window)
→ {"id": 10, "method": "fs.ack", "params": {"stream": 3, "offset": 4194304}}
← … ← FILE_DATA stream=3 offset=734003200 flags=FIN (empty)
```

- `offset` and `length` (null means to the end) select a range: previews (cap it client-side) and
  resuming a download.
- **Resuming safely:** send the `size` and `mtime_ns` of the first attempt as `expect_size` and
  `expect_mtime_ns`. If the file differs, the read fails with `changed` instead of splicing two
  versions.
- The file is checked again at the end. If it changed during the stream, the stream ends with
  `fs.error` `changed`.

**Writing:**

```json
→ {"id": 11, "method": "fs.write", "params": {"path": "~/upload.bin", "size": 52428800,
    "overwrite": true, "expect_mtime_ns": null, "mode": null, "mtime_ns": "1761400000000000000",
    "upload_id": "8f3c…", "source": "52428800:1761400000", "chunk": 262144, "window": 4194304}}
← {"id": 11, "result": {"stream": 4, "offset": 0, "window": 4194304}}
→ FILE_DATA stream=4 offset=0 … (up to the window)
← {"event": "fs.ack", "data": {"stream": 4, "offset": 4194304}}
→ … → FILE_DATA stream=4 offset=52428800 flags=FIN (empty)
← {"event": "fs.done", "data": {"stream": 4, "entry": {…}}}
```

- **Atomic:** the bytes go to a hidden temp file next to the target (`.<name>.clotho-part-<tag>`).
  It is created exclusively, mode 0600, and never through a symlink: until the write completes,
  only the user can read it, even in a shared directory. After FIN it is fsynced, `size` (if
  given) is checked, the final mode and `mtime_ns` are applied, and it is renamed over the target.
  Readers never see a partial file.
- **Symlinks:** writing to a path that is a symlink writes to the file it points to (the temp file
  goes next to the link's target), so links survive edits. A dangling link is `not_found`.
- **Conflicts:** `overwrite` defaults to false, so an existing target is `exists` unless
  `overwrite: true` is given. With `expect_mtime_ns`,
  the target must still have that mtime when the write completes (else `conflict`), for safe
  edit-and-save.
- **Mode:** `mode` sets the new file's permission bits (keep an upload's executable bit). By
  default a replaced file keeps its old mode, and a new file gets 0644 less the umask.
- **Mtime:** `mtime_ns` sets the final file's modification time (copies keep their times).
  Without it, it's the time of the write.
- **Resume:** with a client-chosen `upload_id`, the part file is named after the upload and a
  hash of `source` (any string identifying the local data, for example `size:mtime`):
  `.<name>.clotho-part-<upload_id>-<12 hex digits>`. It is kept whenever such a write doesn't
  finish (`fs.cancel`, a dropped connection, `window_exceeded`). A later write with the same
  `upload_id`, path and `source` continues where the part file ends: the reply's `offset`. If
  `source` differs, it's a different part file and the write starts at 0. Without `upload_id`,
  every write starts at 0 and nothing is kept.
  - Resume needs nothing but the part file, so it works after a serve restart, an upgrade, or
    the end of the instance that started the upload (a private instance's state dies with it).
    Since 0.1.11; 0.1.10 and earlier kept a registry in the instance's state dir, and their part
    files don't resume after an upgrade (they are swept like any other).
  - Parts nobody resumes are deleted 24 h after their last write, by the next write into the
    same directory (at most one sweep per directory an hour).
  - **Taking over:** if a write of the same part is still open, on this or another connection,
    the new write takes it over and the old stream ends with `fs.error` `superseded`. A
    connection that went half-open (the link died and nothing told the daemon) never holds a
    resume up. The client should still close the old connection.

**Ending a stream early:**

- `fs.cancel {stream}` from the client stops a read or abandons a write. The daemon confirms with
  `fs.done {stream, cancelled: true}`.
- A failure mid-stream is `{"event": "fs.error", "data": {"stream", "code", "message"}}`. The
  stream is over and FILE_DATA for it is ignored.
- A dropped connection cancels its streams (keeping part files, as above).
- A write whose data runs more than two windows ahead of what reached the disk ends with
  `fs.error` `window_exceeded`; a client that keeps to its window never sees it.
- **Liveness:** during a write the daemon sends `fs.ack` every quarter window that reaches the
  disk. A dead link shows up as no acks while data is outstanding, but a wedged SSH multiplexer
  can keep a dead connection looking open for minutes. Clients should also `ping` (replies go out
  ahead of file data) every 15 s and drop the connection after 30 s without a reply, then resume
  on a fresh one.
- `fs.done`, `fs.error` and `fs.ack` (from the daemon) go to the connection that owns the stream,
  whether or not it subscribed to events.

### Directories

There is no recursive transfer call. Clients walk trees themselves:

1. List each directory (`fs.list`, with paging).
2. Create the directories (`fs.mkdir`).
3. Transfer the files with `fs.read`/`fs.write`, **at most 4 concurrent streams per tree** (and
   fewer on slow links).
4. Restore the directories' `mtime_ns` with `fs.setattr` last, since writing into a directory
   changes its mtime.

Recursive deletes are one `fs.remove {recursive: true}`. ClothoKit's transfer engine does this
for both apps, so they behave the same.

### Errors

`fs.*` failures use the usual error object, with these codes: `not_found`, `exists`,
`permission_denied`, `not_a_directory`, `is_a_directory`, `not_empty`, `cross_device`,
`no_space`, `read_only`, `conflict`, `changed`, `too_many_streams`, `bad_request`, and `io_error`
(anything else, with the OS message). Stream-only codes (in `fs.error`): `superseded` and
`window_exceeded` (both since 0.1.11).

### Later

`fs.copy` (server-side copy with progress, v1.1), `trash: true` on `fs.remove` (macOS Trash, XDG
trash), `fs.watch` and checksums. Each will be additive.

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
