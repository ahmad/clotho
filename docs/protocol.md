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
`protocol_mismatch`, `spawn_failed`, `wrong_pane`, `internal`. Some requests add their own
(`stale`, the `fs.*` codes, the git and worktree codes): each is listed where the request is
described.

Replies carry the request's `id` because they may come out of order: most requests are answered
before the next one is read, but one that waits on something slow (a permission decision, git)
is answered when it is done, while later requests go ahead.

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
                  "pane.search", "agent.history", "agent.decide", "push.activity", "client.colors",
                  "restore", "move", "git", "pane.move", "pane.focus",
                  "summary", "alerts", "git.changes", "worktree", "peek",
                  "agent.osc", "agent.progress", "agent.kinds", "git.changes.token"],
     "daemon": "clothod", "version": "0.1.0",
     "instance": "7f3a9c2e5b104d8a",
     "pid": 4242,
     "machine": {"hostname": "mbp", "os": "macos", "arch": "aarch64", "home": "/Users/me"},
     "exe": "/Users/me/Library/Application Support/clothod/bin/0.1.1-3f2a9c1b7d4e/clothod",
     "build": "0.1.1-3f2a9c1b7d4e",
     "holder": {"pid": 4100, "version": "0.1.1", "protocol": 1, "build": "0.1.1-3f2a9c1b7d4e",
                "can_upgrade": true, "outdated": false,
                "exe": "/Users/me/Library/Application Support/clothod/bin/0.1.1-3f2a9c1b7d4e/clothod"},
     "holder_outdated": false,
     "namespace": "Aqua"
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
  ([Permission requests](#permission-requests), the agent's `requests`, since 0.1.13),
  `push.activity` (Live Activities: `push.activity`, `push.activity_end` and `push.list`'s
  `activities`, see docs/push.md, Live Activities; since 0.1.16. Since 0.1.18 the content
  sent to the relay also carries the optional `tool`, `detail` and `msg`: the detail
  notifications carry, as one line of at most 64, 200 and 300 characters),
  `client.colors` (hello's `colors` and the `client.colors` request, see
  [Client colors](#client-colors); since 0.1.20), `restore` (panes' `restored` and
  `pane.dismiss_restored`, see [Restore after restart](#restore-after-restart); since 0.1.21),
  `move` (`workspace.move` and `tab.move`, see
  [Moving tabs and workspaces](#moving-tabs-and-workspaces); since 0.1.22), `git` (panes'
  `git` field, see [Git](#git); since 0.1.23), `pane.move` (`pane.move` and `tab.join`, see
  [Moving panes](#moving-panes); since 0.1.26), `pane.focus` (the `pane.focus` request; the
  client that focused a pane last sets its size, not the one that typed last, see
  [Resize](#resize); since 0.1.28), `summary` (agents' `summary` and `summary_pending`, the
  `notification_rewrite` setting and push records' `sm`, see
  [Notification text](#notification-text); since 0.1.29), `alerts` (fewer, clearer alerts:
  agents' `needs_user` and `settling`, the settle window before a finished turn raises
  `attention`, `agent.report`'s `tail`, the `client.active` request, the
  `notification_rewrite_health` setting, and push records' `nu` with `/v1/push`'s `silent`, see
  [Fewer, clearer alerts](#fewer-clearer-alerts); since 0.1.31), `git.changes` (the
  `changes` and `changes_reason` fields of a pane's `git`, and the `git.changes` and `git.diff`
  requests, see [Changes](#changes); since 0.1.32), `worktree` (the `worktree` option of
  `tab.create` and `workspace.create`, see [Worktree Tabs](#worktree-tabs); since 0.1.32) and
  `peek` (`peek.subscribe`, `peek.unsubscribe` and the `peek` event, see [Peek](#peek); since
  0.1.32), `agent.osc` (agents with `source: "osc"`: OSC 9, 99, 777 and 7501 from any program
  in a pane, see [Notifications from any program](#notifications-from-any-program)),
  `agent.progress` (agents' `progress`), `agent.kinds` (more agent kinds, any reported name as
  `kind`, `agent.report`'s `needs_user`, and reports from scripts, see
  [Reporting from your own scripts](#reporting-from-your-own-scripts)) and `git.changes.token`
  (`changes.token` in a pane's `git` and `token` in the `git.changes` reply, see
  [Changes](#changes)). The last four came after 0.1.32 without a version of their own.
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

- `namespace` (macOS, since 0.1.24) is serve's launchd namespace, and `holder.namespace` is
  the holder's, which every shell inherits. Each is `"Aqua"` (the login session), `"Background"`
  (an SSH session's), another name, `"none"` (launchctl couldn't tell, for example because the
  namespace was torn down) or `null` (not macOS, or an older holder). A holder outside `Aqua`
  means the shells may lose DNS, user lookups, TLS trust and the keychain once that SSH session's
  namespace goes. Clients can offer a restart (`clothod shutdown`, then start), which brings the
  layout and agents back. See docs/remote.md, "macOS sessions".
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
   - **The wait follows the serve that is starting**, not a fixed time. A serve takes
     `clothod.lock` in the runtime dir, writes its pid into it, recovers its panes and only
     then answers on the socket; with many panes, or on a loaded machine, that takes a while.
     (Before, `start` gave up after 10 s and the upgrade after 30 s, and then started or rolled
     back next to a serve that was merely slow.)
     - `start` gives a serve 10 s to appear. After that it waits for as long as one is alive
       (the one it started, or the one that holds the lock), and never starts a second one next
       to it. The upgrade's switch does the same, for the new build and, when it rolls back,
       for the old one.
     - The ceilings: 60 s for a `start`, 600 s for the upgrade and the starts it runs.
     - While it waits it says so on stderr every 10 s: `clothod: waiting for clothod <pid> to
       recover its panes (<n> s)`.
     - `start` fails with `clothod exited (<status>):` and the log's last lines when its serve
       exited and no other is starting, with `clothod (pid <pid>, build <build>) was still
       starting after <n> s; see <log>` at the ceiling, and with `clothod did not start; see
       <log>` when none ever appeared.
     - The upgrade's reasons (inside `upgrade to <id> failed, …: <reason>`): `the new clothod
       exited while starting: <the log's last lines>`; `the new clothod (pid <pid>, build
       <build>) was still starting after <n> s`, followed by `; it was told to end (SIGTERM) and
       has not yet` or `; it was left running` when that is so; `another build (<build>, pid
       <pid>) was still starting after <n> s`; and `another clothod keeps getting started:
       another build (<build>, pid <pid>) was started 5 times during the switch; <path> is
       installed but not running`.
   - **The only process the upgrade ever signals** is a new build's serve that is still
     starting at the ceiling, so that the rollback can take the lock: SIGTERM, and only when
     its pid is the one written in `clothod.lock` and that pid is a clothod `serve` of this
     runtime dir. A serve found only in the process list (a build from before the lock held a
     pid) is left running, and the holder, where the shells live, is never signalled.
   - It verifies both run the new build, then makes it the only installed version. It prints
     `running <path>`.
   - On any failure it goes back to the old build (serve, and holder in place, and `current`),
     removes the new one and exits non-zero with `upgrade to <id> failed, rolled back:
     <reason>; now: <what runs>`. `<what runs>` is what was found afterwards, whatever was
     intended: `serve runs <build>, holder runs <build>`, `serve <build> (pid <pid>) is still
     starting, holder not known until it answers`, or `no serve is running`. A rollback that
     itself failed adds `; going back to <path> failed: <why>` before it.
   - One case is not rolled back: the new build's serve came up late and is the daemon after
     all. Taking its files and `current` away would break the next start and every hook, so
     the message is `upgrade to <id> failed, not rolled back (<id> stays installed and
     current: its serve is running or still starting): <reason>; now: <what runs>`, still with a non-zero exit.
   - A legacy holder stays as it is (`holder_outdated`), and stderr says so.
   - Exit 3 means the holder is incompatible (only `shutdown` + `start` fixes that).
4. **Check:** `<base>/current/clothod status --print-builds` prints `serve=<build>`,
   `holder=<build>`, `holder_can_upgrade=` and `holder_outdated=` lines. `clothod ps` lists
   every clothod process of the user, with the runtime dir it really uses (`--runtime-dir`,
   else `CLOTHOD_RUNTIME_DIR` from the environment it started with, else the default; `?`
   when that environment can't be read), and marks `EXTRA` anything that isn't provably the
   default instance (since 0.1.27; before, a dir set only in the environment showed as the
   default).

`clothod status`, `stop` and `shutdown` wait at most 15 s for the daemon's reply
(`CLOTHOD_CLIENT_TIMEOUT` seconds overrides it). A daemon whose socket accepts but never
answers (stopped, wedged, exiting) makes them exit non-zero with `clothod at <dir> did not
answer within 15 s`; `shutdown` then leaves the holder alone. `upgrade` gives up after
waiting 120 s for another upgrade's lock (since 0.1.27; before, all of these could wait
forever).

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
     "title": "vim notes.md", "cwd": "/Users/me/notes", "seq": 183230, "exited": null,
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
    on macOS); it is `null` if unknown. Without OSC 7 (macOS zsh by default) the daemon checks the
    shell's cwd once a second and sends a `pane` event when it changed, so a `cd` shows up within
    about a second with nothing else happening in the pane.
  - `exited` is `null` while the pane runs, then `{"code": 0}` or `{"signal": 9}`.
  - `scrollback_lines` is the history the daemon keeps for the pane (spawn options).
  - `restored` is `null`, or `{"at", "agent", "session"}` for a pane brought back after a
    restart; see [Restore after restart](#restore-after-restart).
  - `git` is `null` outside a git work tree; see [Git](#git).
- When a tab's active pane closes or exits, the new `active_pane` is the first pane of the
  sibling subtree that takes its place (as in tmux).
- A pane is removed from the layout when its process exits. A tab with no panes closes, but a
  workspace with no tabs stays.
- `focus` is shared by all clients (the daemon's notion of "where the user is").
  `active_tab` is each workspace's last focused tab and `active_pane` each tab's last focused
  pane. `focus` with only a `workspace` goes to that workspace's `active_tab` and its
  `active_pane` (or to its first tab if none). `focus` with only a `tab` goes to its
  `active_pane`.

## Moving tabs and workspaces

For drag to reorder (feature `move`, since 0.1.22). A move changes only where things are: ids,
panes, their shells, split trees, subscriptions and seqs are untouched, so an open pane needs
nothing new. Clients that apply a move before the reply (as the Mac does) mirror these rules
exactly.

- **`workspace.move {workspace, index}`.** Take the workspace out of the list, then insert it at
  `min(index, len)`, where `len` counts the list without it. Focus and active tabs don't change.
- **`tab.move {tab, index, workspace?, focus?}`.** `workspace` is the destination and defaults
  to the tab's own (a reorder within it). Take the tab out of its workspace S, at position `i`,
  then insert it into the destination W at `min(index, len)`, where `len` counts W's tabs
  without it. Then:
  1. Source. Only when W is not S, and only if S's `active_tab` was the moved tab: S's
     `active_tab` becomes the tab now at `max(i - 1, 0)` (the one before it, or the new first
     if it was first), or `null` if S has no tabs left. This is `tab.close`'s rule. An emptied
     workspace stays, as after closing its last tab.
  2. Destination. If the global focus was on the moved tab (`focus.tab`), or `focus` is
     `true`: W's `active_tab` becomes the tab, and `focus` becomes
     `{workspace: W, tab, pane: <its active_pane>}`. So `focus.tab` is always its workspace's
     active tab. Otherwise focus doesn't move, and W's `active_tab` is unchanged, unless W had
     none (it was empty), in which case it becomes the moved tab.
- **No-ops.** A move whose result is the state as it was (same place, nothing for focus to do)
  changes nothing: no `state` event, `rev` unchanged. The reply still gives the place.
- **Errors.** `not_found` for an unknown workspace or tab. `bad_request` for a missing,
  negative or non-integer `index`, a `workspace` that isn't an id, or a non-boolean `focus`.
  An index past the end is not an error: it means last.
- Every effective move sends one `state` event to every event subscriber, and the saved layout
  ([Restore after restart](#restore-after-restart)) follows it.

## Moving panes

For "open beside the current pane" (⌘↩ on a ⌘P row; feature `pane.move`, since 0.1.26). A live
pane, or every pane of a tab, moves into a split beside another pane, also in another tab or
workspace. As with [tab.move](#moving-tabs-and-workspaces), only places change: pane ids,
shells, PTYs, agents (with their sessions and hints), `restored` marks, subscriptions and seqs
are untouched, so an open pane needs nothing new. Its size changes only when a client focuses it or
sets a new viewport for it.

- **`pane.move {pane, to_pane, direction?, ratio?, focus?}`.** Take `pane` out of its tab, as
  `pane.close` would but without hanging it up: its parent split collapses, and the tab's
  `active_pane`, if it was this one, becomes the pane that took its place. A tab left with no
  panes closes, with `tab.close`'s rule for its workspace's `active_tab`; the workspace stays,
  even when empty. Then `to_pane`'s leaf becomes a split of `to_pane` and `pane`, exactly as
  `pane.split {pane: to_pane, direction, ratio}` would make it with `pane` as the new pane:
  `direction` (`right`, `down`, `left`, `up`; default `right`) is the side `pane` goes on, and
  `ratio` (default 0.5, clamped to 0.05–0.95) is `to_pane`'s share. Both may be in one tab.
- **`tab.join {tab, to_pane, direction?, ratio?, focus?}`.** The same with the tab's whole split
  tree, as it is (its splits keep their ids and ratios), in place of one pane. The tab goes
  (`tab.close`'s rule for `active_tab`; the workspace stays). `to_pane` must be in another tab.
  A one-pane tab joined is the same as `pane.move` of its pane.
- **Focus.** If `focus` is `true` (the default), or the global focus was on the moved pane
  (`pane.move`) or on the joined tab (`tab.join`): focus goes to the moved pane, or to the joined
  tab's `active_pane`, which also becomes the destination tab's `active_pane` and its
  workspace's `active_tab` (as `focus {pane}` does). Otherwise focus stays where it was, and the
  destination's `active_pane` and `active_tab` don't change.
- **Reply** `{"workspace", "tab", "split"}`: where the moved panes are now, and the id of the
  new split (a fresh id, as from `pane.split`).
- **Errors.** `not_found` for an unknown `pane`, `tab` or `to_pane`. `bad_request` for a missing
  `pane`/`tab` or `to_pane`, `pane` equal to `to_pane`, a `to_pane` inside the joined tab, an
  unknown `direction`, a non-number `ratio` or a non-boolean `focus`. Nothing changes on an
  error.
- **Machines.** A daemon only knows its own panes, so a move between machines can't be asked
  for: the other machine's ids are `not_found` here (or, by chance, other panes). Clients offer
  ⌘↩ only when both panes are on one machine, and otherwise open the tab instead.
- Every move sends one `state` event to every event subscriber, and the saved layout
  ([Restore after restart](#restore-after-restart)) follows it, agents included, so a restart
  restores the new arrangement.

## Git

Each pane's `git` field (feature `git`, since 0.1.23) describes the work tree its cwd is in, or
is `null` outside one:

```json
"git": {
  "repo": "clotho",
  "root": "/Users/me/Projects/clotho-fix",
  "remote": "ahmad/clotho",
  "branch": "fix-login",
  "head": "a1b2c3d",
  "worktree": {"name": "fix-login", "path": "../clotho-fix"},
  "pr": {"number": 42, "state": "open", "draft": false,
         "url": "https://github.com/ahmad/clotho/pull/42", "title": "Fix the login page"},
  "pr_reason": null,
  "changes": {"uncommitted": {"files": 3, "added": 40, "removed": 2},
              "branch": {"base": "origin/main", "commits": 4, "files": 7, "added": 120, "removed": 30},
              "reason": null},
  "changes_reason": null
}
```

- `repo` is the main worktree's top-level folder name, shared by all its linked worktrees. For
  a bare repository with linked worktrees, it is the bare folder's name without `.git`.
- `root` is this work tree's top level.
- `remote` is origin's `owner/name` when origin is on github.com, else `null`.
- `branch` is `null` when HEAD is detached or unreadable.
- `head` is the 7-character short sha HEAD resolves to (through the branch's loose ref or
  `packed-refs`), or `null` (an unborn branch, or an unreadable ref).
- `worktree` is `null` for a main worktree. For a linked one, `name` is its folder under
  `.git/worktrees` and `path` is its root relative to the main worktree's root (absolute when
  there is none, as with a bare repo).
- `pr` is the pull request for the branch, or `null`:
  - `state` is `"open"`, `"draft"` (an open draft), `"merged"` or `"closed"`, and `draft` says
    the same as a bool.
  - `url` always starts with `https://github.com/`.
  - `title` is one line with no control characters, at most 120 characters.
- `pr_reason` says why `pr` is `null`:
  - `"none"`: gh says the branch has no PR.
  - `"pending"`: the first lookup is still running.
  - `"default_branch"`: main, master or origin/HEAD's target, never looked up.
  - `"detached"`
  - `"no_remote"`: origin isn't on GitHub.
  - `"no_gh"`: gh isn't installed.
  - `"gh_auth"`: gh isn't logged in.
  - `"gh_error"`: offline or any other failure.
  - `"timeout"`

  Treat unknown values as unknown.
- `changes` and `changes_reason` (feature `git.changes`, since 0.1.32) count what changed in
  the work tree: see [Changes](#changes).
- A submodule is its own repo. A cwd inside a bare repository, which has no work tree, gives
  `null`.

**How it is read.** Everything above except `changes` comes from plain file reads only: git is
not run for it, so nothing a repository configures (hooks, fsmonitor, aliases, includes) can
execute. (`changes`, `git.changes`, `git.diff` and worktree creation do run git, in a way that
gives a repository's config nothing to run: see [Changes](#changes) and docs/security.md,
"Running git in a repo the user didn't write".) The daemon walks up
from the cwd to `.git`. A `.git` file's `gitdir:` leads to a linked worktree (its git dir has a
`commondir`) or a submodule's or a separate git dir (one without, read as its own repo). It
reads HEAD, the branch's ref, origin's URL in `config`, and `refs/remotes/origin/HEAD`. The
lookup runs again when a pane's cwd changes: at once with OSC 7, else through the once-a-second
cwd poll. Every work tree that some pane is in is read once a second, shared by all its panes:
a branch switch or a commit, made anywhere, shows within about a second. Branch names, paths and
repo names are untrusted: they have control characters stripped and are capped at 255
characters (paths 4096).

**Pull requests.** The daemon runs
`gh pr view --repo <owner/name> --json number,state,isDraft,url,title -- <branch>`. It finds gh
on its PATH, then in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`. The command runs
from `/` (never the repo) with `GH_PROMPT_DISABLED=1`, no stdin and a 5 s timeout. gh uses its
own login, and the daemon never handles a token. Lookups are cached per repo and branch,
failures included, and run at most two at once. A branch is looked up the first time a pane is
on it. After that it is refreshed at most every 5 minutes, and only while a client is
subscribed to a pane on it. Input never triggers a lookup. The default branch, a detached HEAD
and non-GitHub remotes are never looked up.

Changes come as `pane` events, as for any pane field. `git` is not saved in the layout file.

### Changes

Feature `git.changes`, since 0.1.32. A pane's `git` object says how much changed in its work
tree, and two requests list the files and give one file's diff.

**The summary.** `changes` has two groups:

```json
"changes": {
  "uncommitted": {"files": 3, "added": 40, "removed": 2},
  "branch": {"base": "origin/main", "commits": 4, "files": 7, "added": 120, "removed": 30},
  "reason": null,
  "token": "9c1e5b0a77d2f431"
},
"changes_reason": null
```

- `uncommitted` compares the work tree with HEAD: staged and unstaged changes together, and
  untracked files (not ignored ones) as added. `files` is how many files differ, and `added` and
  `removed` are lines.
- `branch` compares HEAD with the commit where it left the base branch (the merge base):
  `commits` on HEAD since then, and the files and lines they changed. `base` is the name to
  show. The base is `origin/<branch>` for the branch `refs/remotes/origin/HEAD` names, when
  that ref is in the repo; else the local `main`; else `master`. `branch` is `null` when the
  pane is on that branch itself (`main` with the base `origin/main` counts), when there is no
  base, when HEAD is unborn, and when the two share no commit. A detached HEAD is compared
  like a branch.
- `added` and `removed` are `null` when the lines were not counted (`files` is still right):
  more than 1,000 changed tracked files, or the count took more than 3 s or 8 MiB of output. A
  binary file adds nothing to them. Untracked files are counted by reading them: at most 200
  files, 1 MiB each and 8 MiB in all per run; the ones past that add nothing.
- `changes.reason` is `null`, or says why `branch` is `null` although there is a base: git
  failed on that part (`timeout`, `too_large`, `partial_clone`, `error`). `uncommitted` stands.
- `changes.token` (feature `git.changes.token`) is 16 hex characters that stand for what the
  list and the diffs would show now. It changes whenever any of that changes, also when the
  counts stay the same (a line edited in place, one file renamed to another name). See
  "The change token" below. Absent on a daemon without the feature.
- `changes` is `null` when nothing is known, and `changes_reason` says why:
  - `"pending"`: not read yet (the first run hasn't ended, or no client is subscribed to
    events).
  - `"no_git"`: there is no git on this machine.
  - `"git_unsupported"`: the git here is older than 2.31, or the repository keeps its refs in
    a reftable.
  - `"unsafe"`: git refused the repository (dubious ownership: it belongs to another user).
  - `"timeout"`: git took more than 6 s in all.
  - `"too_large"`: the list of changed files is over 4 MiB.
  - `"partial_clone"`: a partial clone that lacks objects the comparison needs. The daemon
    never fetches them.
  - `"error"`: anything else (a corrupt repository, a config git can't read). The daemon's log
    names the work tree and the reason each time the reason changes.

  Treat unknown values as unknown.

**When it is read.** Git runs for a work tree only while some client is subscribed to events,
once for all the panes in it. Once a second the daemon looks at what it can see without git,
and reads the summary again when HEAD, the commit it is at or the base changed, when
`<git dir>/index` was written (a `git add`, a commit, a checkout), when a pane in the work tree
printed something since the last run (an edit made there usually prints), or when 15 s have
passed. Runs for one work tree start at least 3 s apart, and at least ten times the last run's
duration apart, so a repository where git takes 2 s is read every 20 s. Without a usable git
(`no_git`, `git_unsupported`) the daemon looks again once a minute. At most two git jobs run at
once in the whole daemon, these requests included. So an edit made in a pane shows within a few
seconds, and one made elsewhere (an editor outside Clotho) within 15 s. A new summary comes as
a `pane` event, and only when its numbers or its `token` changed.

**The change token.** Feature `git.changes.token`. The counts can't tell a client that its list
or its open diff is stale: editing a changed file again often leaves `files`, `added` and
`removed` as they were. `token` can.

- What it covers: HEAD's commit; the base's commit and name; git's own status listing, whole
  (every changed path with its status letters and the ids of its contents in HEAD and the
  index); the line counts; and the size and modification time (to the nanosecond) of
  `<git dir>/index` and of each changed file in the work tree. So it also moves when a changed
  file is edited again with every count left as it was, when an untracked file is rewritten,
  and when a change is staged without touching the file. It is made from what a summary run
  reads anyway: no git call of its own.
- It does not depend on `limit`, and a clean work tree has one too.
- The cap: file sizes and times are taken for the first 2,000 changed paths of the work tree,
  in path order. In a work tree with more, an edit to a file past them moves the token only
  when it also moves a count or git's status listing.
- It is an opaque string: compare it for equality only. It is not stable across daemon
  versions, and it is not a hash a client can compute.
- The `git.changes` reply carries the same value top-level, as `token`: the token of exactly
  the list in that reply.

What a client does with it:

- **Stop polling.** Against a daemon with `git.changes.token`, don't refresh `git.changes` or
  `git.diff` on a timer. The pane's `changes.token` says when there is something new.
- **Hold the token of what you show.** Keep the `token` of the `git.changes` reply the list
  came from, and for an open diff the token that was current when it was asked for.
- **Reload on a difference.** When a `pane` event brings a `changes.token` that differs from
  the held one, ask `git.changes` again, and `git.diff` again for the open file (it may answer
  `not_changed` now: the file went back to what it was). When the tokens are equal there is
  nothing to do, whatever else in the pane changed.
- A `changes` of `null` (with `changes_reason`) has no token: keep what is shown and show the
  reason, as before.
- Against a daemon without the feature, poll as before.

**`git.changes`** lists the files of both groups for a pane's work tree:

```json
→ {"id": 4, "method": "git.changes", "params": {"pane": 3, "limit": 500}}
← {"id": 4, "result": {
     "root": "/Users/me/Projects/clotho-fix", "branch": "fix-login", "head": "a1b2c3d",
     "uncommitted": {
       "files": [
         {"path": "src/login.rs", "status": "modified", "added": 12, "removed": 2, "binary": false, "diffable": true},
         {"path": "src/auth.rs", "old_path": "src/session.rs", "status": "renamed", "added": 0, "removed": 0, "binary": false, "diffable": true},
         {"path": "notes.txt", "status": "untracked", "added": 28, "removed": 0, "binary": false, "diffable": true}
       ],
       "total": 3, "added": 40, "removed": 2, "truncated": false
     },
     "branch_changes": {
       "base": "origin/main", "base_head": "9f8e7d6", "merge_base": "9f8e7d6", "commits": 4,
       "files": [..], "total": 7, "added": 120, "removed": 30, "truncated": false
     },
     "branch_reason": null,
     "token": "9c1e5b0a77d2f431"
   }}
```

- `limit` is the most files per group: 500 when left out, 2,000 at most (more is read as
  2,000). `files` is sorted by path and cut there, with `truncated: true`; `total`, `added` and
  `removed` are for the whole group, and are the summary's numbers.
- `status` is `"added"`, `"modified"`, `"deleted"`, `"renamed"` (with `old_path`),
  `"untracked"` or `"conflicted"`. Treat unknown values as modified.
- `added` and `removed` are `null` for a file whose lines were not counted (a binary file, and
  the cases under the summary above). `binary` is true for a file git treats as binary, which
  includes any file over 8 MiB.
- `path` is exact when the file's name is valid UTF-8 without control characters. Otherwise it
  is a form to show (invalid bytes replaced, control characters dropped) and `diffable` is
  false: `git.diff` can't be asked for that file.
- `branch_changes` is `null` when there is nothing to compare, and `branch_reason` says why:
  `"no_base"` (on the base branch, no base, or an unborn HEAD), `"no_merge_base"`, or what
  failed (`"timeout"`, `"too_large"`, `"partial_clone"`, `"error"`). `base_head` and
  `merge_base` are 7-character shas.
- The reply also becomes the panes' `changes` summary, so the list a client shows and the
  counts on the pane agree.
- `token` (top-level, feature `git.changes.token`) is the change token of this list: the value
  the panes' `changes.token` has while nothing changed since. See "The change token" above.
- Errors: `not_found` (no such pane), `not_a_repo` (the pane's cwd is in no work tree),
  `no_git`, `git_unsupported`, `timeout`, `git_failed` (git's first line as the message; also
  a list of changed files over 4 MiB).

**`git.diff`** gives one file's diff as hunks:

```json
→ {"id": 5, "method": "git.diff", "params": {"pane": 3, "path": "src/login.rs", "group": "uncommitted", "context": 3}}
← {"id": 5, "result": {
     "path": "src/login.rs", "old_path": null, "status": "modified", "binary": false,
     "truncated": false, "added": 2, "removed": 1,
     "hunks": [
       {"old_start": 10, "old_lines": 3, "new_start": 10, "new_lines": 4, "header": "fn login() {",
        "lines": [
          {"t": " ", "old": 10, "new": 10, "text": "    let user = find(name);"},
          {"t": "-", "old": 11, "new": null, "text": "    check(user);"},
          {"t": "+", "old": null, "new": 11, "text": "    let user = user?;"},
          {"t": "+", "old": null, "new": 12, "text": "    check(&user)?;"},
          {"t": " ", "old": 12, "new": 13, "text": "}"}
        ]}
     ]
   }}
```

- `group` is `"uncommitted"` (the work tree against HEAD) or `"branch"` (HEAD against the
  merge base). `path` is a file's `path` from `git.changes`, and for a renamed file `old_path`
  is its `old_path`. `context` is the unchanged lines around each change: 0 to 20, 3 when left
  out.
- Each line has its type `t` (`" "` unchanged, `"+"` added, `"-"` removed), its line number
  in the old file (`old`) and the new one (`new`), `null` on the side it isn't in, and its
  `text` without the line end. That is enough to draw the diff unified or side by side.
  `no_newline: true` marks a last line that has no newline at its end. `header` is what git
  prints after the hunk's `@@` (usually the enclosing function), or empty.
- An untracked file comes as one hunk of added lines.
- **Limits.** A diff is cut at 1 MiB of patch or 20,000 lines, with `truncated: true` (the
  hunks up to there are whole lines, and `added` and `removed` count only what is in the
  reply). A line is cut at 2,000 characters, with `cut: true` on it. A binary file, or one over
  8 MiB, gives `binary: true` and no hunks.
- `text` is always valid UTF-8: bytes that aren't are replaced with U+FFFD. It is the file's
  content and may hold anything else, control characters and escape sequences included: see
  docs/security.md, "For client authors".
- Errors, besides those of `git.changes`: `bad_request` (no `path`, a `group` that is neither
  of the two, `context` over 20), `bad_path` (a path that is absolute, has a `..`, `.` or empty
  component or a control character, or is longer than 4096 bytes; an untracked path that is not
  a regular file) and `not_changed` (the file has no changes in that group).

Both requests are answered when git is done, and other requests on the connection go ahead
meanwhile. Each has 10 s in all, the wait for one of the two git slots included, and 6 s of git;
past that the reply is `timeout` and its git is killed. Nothing is cached between requests.

**How git is run.** The daemon runs the machine's own git (2.31 or later), found on its PATH,
then in `/opt/homebrew/bin` and `/usr/local/bin`, and on macOS in the developer tools
(`/usr/bin/git` itself is never run: without the tools it opens an install dialog). It runs
only these commands: `config --list`, `status --porcelain=v2`, `diff-index`, `diff-tree`,
`merge-base`, `rev-list --count`, `rev-parse`, `hash-object` (of nothing, for the empty tree),
and for a worktree `check-ref-format`, `worktree add --no-checkout`, `read-tree --reset -u HEAD`
in the new worktree (under a config listing made there, so what the config includes only for
that worktree's git dir or branch is overridden too), and `worktree remove` and `update-ref -d`
to take back one that failed. It runs them from `/`, with an
empty environment, without the system and global config, with every setting that could run a
program or reach the network overridden, and with a timeout, an output cap and a process-group
kill on every call. It never writes to the repository for a summary, a list or a diff (the
index included), never fetches, and never looks inside a submodule. It reads untracked files
itself. docs/security.md has the full invocation and what was measured.

## Restore after restart

The holder keeps every shell across serve restarts and upgrades. When the holder itself goes
away (the machine restarts, or it is killed), the shells go with it. For that case the daemon
saves the layout to a file and brings it back on the next start.

- **What is saved.** The model: workspaces (names, order, active tab), tabs (titles, order,
  active pane), split trees (axes, ratios) and focus. For each pane it saves the cwd, the
  command, the size, and the agent: the pane's agent if it is Claude Code or Codex, with its
  session id when one is known (hooks, or Claude Code's own record; see below). Before 0.1.25
  only agents with a session were saved. Claude's hooks send `session_id`; Codex's notify payload
  sends `thread-id`. Since 0.1.22 the session also survives serve restarts and upgrades (see
  `source` under [Agents](#agents)). A serve that adopts a holder keeps the sessions the file
  already had, for panes where an agent of that kind still runs, until the agent's hooks
  report its own. That covers upgrading from 0.1.21, which didn't keep them. Scrollback, screen
  contents and pane titles (set by applications) are not saved.
- **Sessions without hooks (since 0.1.25).** A Claude Code found by detection (no hooks
  installed) has its session read from Claude Code's own record of the process,
  `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` (default `~/.claude/sessions/`), at most every 5 s.
  The daemon only reads it. The record must name that pid and the process's cwd, and the id must
  match the pattern below; otherwise the pane has no session, as before. The session then shows
  in the pane's `agent.session` too. Codex without its notify hook still has none.
- **Agents that end before a reboot (since 0.1.25).** A reboot or logout ends the agents first
  (they quit on SIGTERM; an interactive shell ignores it) and the daemon a moment later. So when
  a pane's agent goes away and its shell stays, the file keeps that agent and session for 10 s
  more. An agent the user quits is dropped from the file after that. A restored pane's agent is
  kept the same way while it starts again.
- **Where.** `layout.json` in the state dir: `~/.local/state/clothod/` (or
  `$XDG_STATE_HOME/clothod/`) on Linux, and `~/Library/Application Support/clothod/` on macOS.
  It is written atomically (temp file, fsync, rename) with mode 0600, 0.5 s after the layout
  settles. Writes are held back for 5 s after any pane exits, so a shutdown that ends the shells
  before the daemon can't save an emptied layout. Ephemeral (test) instances never read or write
  one, unless `$CLOTHOD_LAYOUT_FILE` names the file to use.
- **When it is restored.** Only when serve starts a fresh holder: one with no state and no
  panes. A serve that adopts a running holder never restores anything; that covers restarts,
  crashes and in-place upgrades. The file must also belong to this instance: the same host name
  and runtime dir, and a format no newer than the daemon's. A file that doesn't parse is moved
  aside to `layout.json.corrupt-<unix secs>` and nothing is restored. The holder gets a state
  before the first pane is spawned, so a serve started after a crash mid-restore adopts and
  doesn't restore a second time. After a restore, the file follows the new live state.
- **Forgetting.** Closing workspaces, tabs and panes is how a layout is forgotten: the file
  follows. A shutdown (`clothod shutdown`, `daemon.shutdown`) ends every shell but keeps the
  layout, so the next start brings it back (for example after the one-time restart a legacy
  holder needs). `clothod shutdown --forget`, or `daemon.shutdown` with `"forget": true`, also
  deletes the saved layout. The CLI deletes it even when no daemon is running, but only a
  layout the targeted instance owns (since 0.1.27): the file `CLOTHOD_LAYOUT_FILE` names, else
  the user's own layout only when the target is the default runtime dir and the run isn't
  ephemeral. `shutdown --forget` aimed at a test instance never deletes the user's layout.
- **How.** Each saved pane gets a fresh shell in its saved cwd (`$HOME` if that is gone). The
  shell is the saved command if it was a shell, else the user's login shell. Workspace, tab and
  split ids are the saved ones; pane ids are new, and so is `instance`. A pane whose agent had a
  session gets one line typed into the shell once it is up: `claude --resume=<id>` or
  `codex resume -- <id>`, so the id can only be read as the session. Flags from the original run are not carried over.
  A pane whose agent (Claude Code or Codex) had no known session (since 0.1.25) gets
  `claude --continue` or `codex resume --last` instead, which open the latest conversation in
  the shell's folder. That happens only when it is unambiguous: the pane's saved cwd still
  exists, and no other saved pane had an agent of that kind in that cwd, with a session or
  without. Otherwise the pane gets a bare shell, so two panes never open the same
  conversation. The agent runs from the
  shell, so the shell stays when it exits. If the resume fails (unknown session, agent not
  installed), the shell shows the error; nothing is retried. Only session ids matching
  `[A-Za-z0-9][A-Za-z0-9_-]{0,127}` are kept at all: one from `agent.report` or a hook that
  doesn't match (it could read as a flag, say) counts as no session. A pane that fails to spawn is left out.
- **Marking.** A restored pane carries
  `"restored": {"at": <unix secs>, "agent": "claude"|"codex"|null, "session": <id>|null, "continued": <bool>}`.
  `agent` is set when a line was typed: `session` when it resumed that session, or
  `continued: true` (with `session: null`) when it continued the latest conversation in the
  folder. `continued` is new in 0.1.25; it is false otherwise. The field stays, also across
  serve restarts and upgrades, until one of these clears it for every client (a `pane`
  event):
  - `pane.dismiss_restored`;
  - the user types in the pane: INPUT, `pane.input` or `pane.keys`, but not focus or mouse
    reports.

  Clients can show a quiet note such as "Restored after restart" ("· resumed Claude session",
  or "· continued the latest Claude conversation in this folder").

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
`TERM_PROGRAM=clotho`, `TERM_PROGRAM_VERSION=<clothod version>`, `CLOTHO_PANE=<id>` and
`CLOTHOD_SOCKET=<daemon socket>` (see [Agents](#agents)), and, when the daemon itself has no
`LANG`, `LC_ALL` or `LC_CTYPE`, a UTF-8 `LANG` (macOS: the user's region, as Terminal sets it, else
`en_US.UTF-8`; Linux: `C.UTF-8`). The spawn's `env` comes after these and wins. **Every pane gets
them, however it starts:** a new tab or split from any client, and a pane brought back after a
restart with its agent resumed ([Restore after restart](#restore-after-restart)), also when the
daemon was started at login by launchd or systemd with a bare environment. Before 0.1.30 restored
panes had none of the terminal variables, so programs in them (Claude Code) ran without color;
`TERM_PROGRAM_VERSION` and the `LANG` default are new in 0.1.30.

| method | params | result |
|---|---|---|
| `hello` | `protocol`, `client` | see Handshake |
| `ping` | – | `{}`: cheap liveness check for client heartbeats |
| `state.get` | – | model (above) |
| `events.subscribe` | – | `{}`, then the daemon sends a `state` event right away and events after that |
| `events.unsubscribe` | – | `{}` |
| `workspace.create` | `name?`, spawn options, `worktree?` | `{"workspace", "tab", "pane"}`, plus `"worktree"` when one was asked for; see [Worktree Tabs](#worktree-tabs) |
| `workspace.rename` | `workspace`, `name` | `{}` |
| `workspace.close` | `workspace` | `{}` (hangs up all its panes) |
| `workspace.move` | `workspace`, `index` | `{"index"}`: its final place; see [Moving tabs and workspaces](#moving-tabs-and-workspaces) |
| `tab.create` | `workspace`, spawn options, `worktree?` | `{"tab", "pane"}`, plus `"worktree"` when one was asked for; see [Worktree Tabs](#worktree-tabs) |
| `tab.rename` | `tab`, `title` (null clears it) | `{}` |
| `tab.close` | `tab` | `{}` |
| `tab.move` | `tab`, `index`, `workspace?`, `focus?` | `{"workspace", "index"}`: the tab's final place; see [Moving tabs and workspaces](#moving-tabs-and-workspaces) |
| `pane.move` | `pane`, `to_pane`, `direction?` (default `right`), `ratio?` (default 0.5), `focus?` (default true) | `{"workspace", "tab", "split"}`: moves the live pane beside `to_pane`; see [Moving panes](#moving-panes) |
| `tab.join` | `tab`, `to_pane`, `direction?`, `ratio?`, `focus?` | `{"workspace", "tab", "split"}`: moves all of the tab's panes, its split as it is, beside `to_pane`; the tab closes. See [Moving panes](#moving-panes) |
| `pane.split` | `pane`, `direction` (`right`, `down`, `left`, `up`), `ratio?` (default 0.5), spawn options | `{"pane", "split"}` |
| `pane.close` | `pane` | `{}`: sends SIGHUP to the pane's process group and removes the pane from the layout |
| `split.set_ratio` | `split`, `ratio` | `{}` |
| `focus` | `pane` (or `tab` or `workspace`) | `{}` |
| `pane.subscribe` | `pane`, `have_seq?`, `scrollback?`, `viewport?` | see Pane data |
| `pane.unsubscribe` | `pane` | `{}` |
| `pane.viewport` | `pane`, `cols`, `rows` | `{}` (see Resize) |
| `pane.focus` | `pane` | `{"cols", "rows"}`: this client's viewport sets the size (see Resize; since 0.1.28) |
| `pane.resize` | `pane`, `cols`, `rows` | `{}`: sets the size now, whatever the viewports say |
| `pane.input` | `pane`, `data` (UTF-8 string) | `{}`: same as an INPUT frame, for clients without binary framing |
| `pane.keys` | `pane`, `text?`, `keys?` (list of key names) | `{}`: input encoded for the pane's current modes (see below). Counts as input like an INPUT frame |
| `pane.dismiss_restored` | `pane` | `{}`: clears the pane's `restored` for every client (a `pane` event). Idempotent; `not_found` for an unknown pane. See [Restore after restart](#restore-after-restart) |
| `pane.search` | `pane`, `query`; optional `regex`, `case_sensitive` (both default false), `limit` (1–1000, default 100), `before` (`{line, col}`) | matches in the scrollback and screen, newest first; see [Searching scrollback](#searching-scrollback) |
| `pane.text` | `pane` | `{"lines": [..], "cursor": [col, row], "cols", "rows", "seq", "modes": {"kitty_flags", "bracketed_paste", "app_cursor", "app_keypad"}}`: plain text of the visible screen, plus the input modes the application set (debugging and tests) |
| `git.changes` | `pane`, `limit?` | the changed files of the pane's work tree, in two groups; see [Changes](#changes) (since 0.1.32, feature `git.changes`) |
| `git.diff` | `pane`, `path`, `group` (`"uncommitted"` or `"branch"`), `old_path?`, `context?` | one file's diff as hunks; see [Changes](#changes) |
| `peek.subscribe` | `panes?` (ids; all panes when left out), `lines?` (1–8, default 2) | `{"peeks": [{"pane", "lines": [..]}]}`, then `peek` events; see [Peek](#peek) (since 0.1.32, feature `peek`) |
| `peek.unsubscribe` | – | `{}` |
| `client.active` | – | `{}`: a Mac app says the user is at it right now (since 0.1.31, feature `alerts`); see [Fewer, clearer alerts](#fewer-clearer-alerts) |
| `settings.get` | – | the settings object; see [Settings](#settings) |
| `settings.set` | any settings to change, e.g. `scrollback_lines`, `notification_rewrite` | the settings object, plus `applied_panes`; see [Settings](#settings) |
| `service.status` | – | the service object; see [Start at login](#start-at-login) |
| `service.install` | – | the service object, after the login unit is written and registered |
| `service.uninstall` | – | the service object, after the login unit is removed (the daemon keeps running) |
| `daemon.stop` | – | `{}`, then the logic process exits; shells keep running in the holder |
| `daemon.shutdown` | `forget?` (bool) | `{}`, then all panes are hung up and the holder and daemon exit. The saved layout stays, so the next start restores it; with `forget: true` it is deleted (see [Restore after restart](#restore-after-restart)) |

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
| `agent.report` | `pane`, `state` (or `"clear"`), `kind?`, `message?`, `session?`, `pid?`, `prompt?` (starts a turn; `""` for one the user didn't type), `tool?` and `tool_input?` (`tool: ""` clears both), `tail?` (the end of the agent's last reply, at most 600 chars; since 0.1.31, feature `alerts`), `needs_user?` (a bool: the reporter's own answer to "does the user have to act"; feature `agent.kinds`). `kind` is any name: it is lowercased and kept when it is 1 to 32 of `a-z 0-9 . _ -`, and is `other` otherwise | `{}`, or `{"ignored": "nested"}` for a report from an agent the pane's agent runs; see [Agents](#agents). With `pid`, the daemon checks that the process runs in that pane (same session as the pane's process, or a descendant) and otherwise answers `wrong_pane` |
| `agent.ack` | `pane` | `{}`: clears the agent's `attention` (the user resolved it; the only way a client clears it). During a settle window (`settling`) it cancels the pending rise instead. A pane-bound agent (every `source: "osc"` agent, and a report from a script) is removed by it: the pane's `agent` is `null` after, see [Agents](#agents), Clearing |
| `agent.history` | `pane`; optional `limit` (1–200, default 200), `since` (unix seconds: entries after it), `session` | `{"pane", "entries": [..], "max": 200}`, oldest first; see [Agent history](#agent-history) |
| `agent.mute` | `pane`, `muted` (bool) | `{"agent": <agent>}`: mutes or unmutes the pane's agent; see [Agents](#agents). `not_found` if the pane has no agent |

File access (`fs.*`) is described in [Files](#files).

### Worktree Tabs

Feature `worktree`, since 0.1.32. `tab.create` and `workspace.create` take an optional
`worktree`, which makes a git worktree on a new branch and opens the new Tab (or Workspace) in
it:

```json
→ {"id": 9, "method": "tab.create", "params": {"workspace": 1, "cwd": "/Users/me/Projects/clotho",
     "worktree": {"name": "fix/login", "base": "origin/main"}}}
← {"id": 9, "result": {"tab": 14, "pane": 31,
     "worktree": {"path": "/Users/me/Projects/clotho-fix-login", "branch": "fix/login", "head": "9f8e7d6"}}}
```

- `cwd` is required with `worktree` and names the repository: any folder in one of its work
  trees (a pane's cwd will do).
- `name` is the new branch: 1 to 100 characters from letters, digits, `.`, `_`, `-` and `/`,
  and a valid branch name. The worktree's folder goes beside the repository's main work tree,
  named after it and the branch, with `/` as `-`: `clotho` and `fix/login` give
  `../clotho-fix-login`. This holds from inside a linked worktree too.
- `base` is where the branch starts: a branch, tag or commit, at most 255 characters. Left out,
  it is the HEAD of the work tree `cwd` is in. The new branch tracks nothing.
- The pane starts in the new folder (the worktree's `path`, whatever `cwd` was), and its
  `git.worktree` shows up like any linked worktree's. `head` is the 7-character sha the
  branch starts at. `worktree: null` is the same as leaving it out.
- The request is answered when the checkout is done (git gets up to two minutes), and other
  requests on the connection go ahead meanwhile. One worktree is made at a time.
- The checkout runs none of the repository's hooks (`post-checkout`) and none of its filters,
  so Git LFS files come out as pointer files until the user runs `git lfs pull` there. See
  docs/security.md.
- Errors:
  - `bad_request`: no `cwd`, or `worktree` is not `{name, base?}` with strings.
  - `not_found`: no such workspace (`tab.create`). Nothing is made when it is unknown as the
    request arrives. When the workspace is closed while the checkout runs, see below.
  - `not_a_repo`: `cwd` is in no work tree.
  - `worktree_unsupported`: the repository has no main work tree to go beside (a bare
    repository's worktree).
  - `worktree_name`: `name` is not a branch name of that form.
  - `worktree_exists`: the folder is already there (any file, folder or link at that path).
  - `branch_exists`: so is a branch of that name.
  - `bad_base`: `base` is not a commit in this repository (or the repository has no commit).
  - `no_git`, `git_unsupported`, `timeout`.
  - `git_failed`: git refused; the message is its first error line.
  - `spawn_failed`: the worktree was made but the pane could not be started.

  **Two errors leave the worktree and its branch behind**: `spawn_failed`, and a `tab.create`
  `not_found` whose workspace was closed during the checkout (the worktree was made by then, and
  there is no workspace left to put the Tab in). Nothing the daemon made is deleted behind the
  user's back. In both, the message ends with `(the worktree <path> on the new branch <branch>
  was created and is still there)`: show the message, since the code alone doesn't tell this
  `not_found` from the one where nothing was made.

  After any other error the repository is as it was: no folder and no branch are left. If git
  fails or times out half way, the daemon takes back what it made through git
  (`worktree remove --force --force`, and the branch only if it still points where it was
  created); should something remain, the message names it.
- The daemon's log records which client made which worktree. Removing a worktree is the
  user's to do (`git worktree remove`); there is no request for it.

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
| `settings` | the settings object | a client changed a setting (`settings.set`), or `notification_rewrite_health` changed; see [Settings](#settings) |
| `service` | the service object | a client installed or removed the login unit; see [Start at login](#start-at-login) |
| `peek` | `{"pane", "lines": [..]}` | the last lines of a pane changed; only to connections with a peek subscription; see [Peek](#peek) |

`state`, `pane`, `bell`, `agent`, `settings` and `service` go only to connections that called `events.subscribe`. `pane.resized`,
`pane.resync` and `pane.clipboard` are part of a pane's data stream: they go to every subscriber of that pane,
whether or not it subscribed to events, in order with that pane's OUTPUT and SNAPSHOT frames.

Focus changes, whether they come from this client or another one, arrive as a `state` event with
the new `focus`. That is the only way they are delivered.

A client keeps its model current by replacing everything on `state` and replacing one pane on
`pane`. If `rev` jumps by more than one between events the client saw, it missed nothing that
matters: a later `state` covers structure, and `pane` events always carry the whole pane.

### Peek

Feature `peek`, since 0.1.32. A peek is the last few lines of a pane's screen as plain text,
for showing what a pane is doing without subscribing to it (a sidebar row, an overview).

```json
→ {"id": 6, "method": "peek.subscribe", "params": {"panes": [3, 5], "lines": 2}}
← {"id": 6, "result": {"peeks": [{"pane": 3, "lines": ["Compiling clothod v0.1.32", "Finished in 4.2s"]},
                                 {"pane": 5, "lines": []}]}}
← {"event": "peek", "data": {"pane": 3, "lines": ["Finished in 4.2s", "$ cargo test"]}}
```

- `peek.subscribe` sets the connection's one peek subscription, replacing any earlier one.
  `panes` lists the panes wanted; left out (or `null`), it is every pane, also ones created
  later. `lines` is how many lines of each: 1 to 8, 2 when left out. Other values are
  `bad_request`. The reply has each wanted pane's lines as they are now (ids that name no pane
  are skipped), and no `peek` event of the new subscription comes before it.
- `lines` are the last non-empty rows of the visible screen (the alternate screen while an
  application uses it), oldest first, with leading and trailing spaces and all control
  characters removed, at most 200 characters each. There can be fewer than asked for, or none.
- A `peek` event carries a pane's lines again when they differ from what this connection was
  last sent. The daemon looks once a second, and only at wanted panes that got output or were
  resized since it last looked (a resize changes which rows are on the screen): at most one
  event per pane per second, and none while the text stays the same.
- `peek.unsubscribe` ends it, as does the end of the connection. It doesn't depend on
  `events.subscribe` or on `pane.subscribe`.
- Peeks are not part of the model: a `peek` event has no `rev`, changes no `rev`, and nothing
  about peeks is stored. A pane that closes just stops sending.

## Settings

Feature flag: `settings` in `hello.features`. Per-machine settings of the daemon, stored in
`~/.config/clothod/config.toml` (`$XDG_CONFIG_HOME/clothod/config.toml` if set). A client shows
them per machine, like "Start at login".

```json
→ {"id": 7, "method": "settings.get"}
← {"id": 7, "result": {
     "scrollback_lines": 2000,
     "notification_rewrite": true,
     "notification_rewrite_health": {"state": "ok", "reason": null, "at": 1763900000.5},
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
- **`notification_rewrite`** (since 0.1.29, feature `summary`): whether a small model rewrites
  notification text ([Notification text](#notification-text)). Boolean, default `true`. Off,
  agents' `summary` and push records' `sm` are the agent's message cleaned of Markdown, and no
  model runs. Clients show it per machine (a switch such as "Rewrite notification text with
  Claude Haiku"), reading it from `settings.get` and the `settings` event; a daemon without the
  `summary` feature doesn't have it, so the switch is hidden there.
- **`notification_rewrite_health`** (since 0.1.31, feature `alerts`): whether the rewrite works
  on this machine, as `{"state", "reason", "at"}`. It is in the result of `settings.get` and
  `settings.set` and in the `settings` event. **Read-only:** `settings.set` rejects it like any
  key it doesn't know (`bad_request`).

  | `state` | meaning |
  |---|---|
  | `"ok"` | the last rewrite that ran worked |
  | `"failing"` | the last rewrite that ran failed; `reason` says why |
  | `"unknown"` | the rewrite is on, but none has run since the daemon started |
  | `"off"` | `notification_rewrite` is false |
  | `"unavailable"` | there is no `claude` on this machine to run it |

  `off` and `unavailable` are checked first, in that order. A rewrite answered from the cache
  doesn't count as a run.
  - `reason`: for `failing`, one line of at most about 130 characters, else `null`. It is the
    helper's exit code and the first line it printed (`"exit 1: Not logged in · Please run
    /login"`), a fixed phrase when `claude` printed an error as its answer (`"claude said: not
    logged in"`, `api error`, `credit balance`, `invalid api key`, `rate limit`), or the time
    limit (`"no answer within 30s"`). An answer that may be notification text is never put there.
    An answer counts as such an error only in claude's own shapes: its first line begins like
    one (`API Error:`, `Invalid API key`, `Not logged in`, `Please run /login`, `Credit balance
    is too low`, `Rate limit reached` or `exceeded`), or, where a label line was asked for (a
    finished turn) and there is none, it is a single line of at most 200 characters with one
    of those phrases in it. A label line followed by text is always a rewrite, whatever the
    text says ("Added rate limit handling to the API client." is not a failed run).
  - `at`: when that run ended, in unix seconds (a float), for `ok` and `failing`; `null` for the
    other states.
  - When a rewrite changes it, every connection that called `events.subscribe` gets a `settings`
    event with the new object, so a client's settings view stays current. The daemon also writes a line to `clothod.log`
    when it starts failing (once per reason) and when it works again.
  - Clients show it under the rewrite switch: nothing extra for `ok`, `unknown` and `off`; "Not
    working: " and the `reason` for `failing` (for example "Not working: Not logged in"); and
    that Claude Code wasn't found for `unavailable`. While it fails, notifications still arrive,
    with the agent's own words cleaned of Markdown.
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
shows the same thing. Any other program can say that its pane needs the user too, with a
terminal notification or `clothod report`
([Notifications from any program](#notifications-from-any-program),
[Reporting from your own scripts](#reporting-from-your-own-scripts)): it shows as an agent like
the others. A pane object has an `agent` field. It is `null` when no agent is known, and
otherwise:

```json
{"kind": "claude", "state": "waiting", "source": "hook", "message": "Claude needs your permission to use Bash",
 "since": 1761512345.123, "attention": true, "needs_user": true, "settling": false, "muted": false,
 "session": "3f1c..."}
```

| field | |
|---|---|
| `kind` | which agent it is: `"claude"`, `"codex"`, `"opencode"`, `"gemini"`, `"copilot"`, `"aider"`, `"amp"`, `"cursor"`, `"other"`, **or any name a reporter gave** (`clothod report --kind deploy`, OSC 7501's `app`): lowercase, 1 to 32 of `a-z 0-9 . _ -`, anything else becomes `"other"`. `"other"` is also a program that only sent a notification. **Clients show a kind they don't know by its name** (as text, with a generic icon), never hide it or fail on it. Before the `agent.kinds` feature only `claude`, `codex` and `other` occur |
| `state` | `"starting"`, `"running"`, `"waiting"` (needs the user: a permission prompt, a question, idle after being asked something), `"done"` (the turn finished), `"error"`. Clients treat unknown values as unknown |
| `source` | `"hook"` (the agent reports through `clothod report`), `"detected"` (inferred from the pane's processes and output) or `"osc"` (a program in the pane sent a terminal notification or status sequence: OSC 9, 99, 777 or 7501; feature `agent.osc`, see [Notifications from any program](#notifications-from-any-program)). Since 0.1.22 a hook-reported agent, with its session, state and turn, is kept across serve restarts and upgrades while its process lives, without new events; before, it reappeared only with its next hook report. Its `requests` are not kept: their hooks were connected to the previous process |
| `message` | what the agent says, or `null`. For `waiting`, the prompt it shows ("Claude needs your permission to use Bash"); for `done`, the start of the reply its turn ended with (Claude Code's `last_assistant_message`, Codex's `last-assistant-message`: whitespace collapsed to one line, at most 300 chars); for `error`, the error |
| `prompt` | the first line of the prompt the user typed for the current turn (at most 120 chars), or `null`: no prompt yet, or a turn the user didn't type (started by another agent's message or a finished background task; the wrapper text is never shown) |
| `tool`, `tool_input` | the last tool the agent used in this turn (`"Bash"`) and its key input (`"npm test"`, at most 160 chars: Bash's command, the file of Read/Write/Edit, the pattern of Glob/Grep, the URL, the query, a task's description, else the first text field), or `null`. Cleared by a new turn and by a wait that isn't a permission prompt, so while `waiting` they say what the permission is for |
| `requests` | permission requests the agent is waiting on, oldest first: `[{"id", "tool", "summary"}]` (`"Bash"`, `"npm test"` or `null`). A client can answer one with `agent.decide` (Allow/Deny from the phone or the app). Empty when none. See [Permission requests](#permission-requests). Feature flag: `agent.decide` |
| `turn_started` | unix seconds (float) when the current turn started (its prompt, or work resuming after the turn ended), or `null`. For `done` and `error`, `since - turn_started` is how long the turn took |
| `since` | when `state` last changed, in **unix seconds as a float** |
| `attention` | the agent needs the user, or has finished and the user should know. **Raised** only by exact signals: a hook-reported transition into `waiting` or `error`, at once; a hook-reported `done`, after the settle window (about 30 s; see `settling`), and not at all if the agent works again first; a terminal bell (BEL) from a detected agent; or an OSC notification (9, 99, 777) or an OSC 7501 `blocked` or `error` from a pane whose agent is not hook-reported, at once and rate-limited (an OSC 7501 `done` settles like a hook's; see [Notifications from any program](#notifications-from-any-program)). A hook report that takes over from detection in the same state counts as a transition (detection guessed `waiting` and then the hook reports `waiting`; a `done` taken over this way settles like any other). **Every rise arrives as an `agent` event.** A rise in the same state (a takeover, or the end of the settle window, when `state` has been `done` all along) is an `agent` event whose `from` equals the state. Before 0.1.31 (no `alerts` feature) a hook `done` raised it at once. **Cleared** only when the agent works again (a transition into `running` or `starting` reported by a hook, or shown by Claude Code's title spinner), by `agent.ack` (the user resolved it), or when the agent goes away. Input never clears it: opening a pane makes a client send focus and mouse reports, and looking is not resolving. A typed reply clears it through the agent going back to work. Detection's guesses from output alone (busy read as `running`, quiet as `waiting`) neither raise nor clear it, since an app's redraw after a resize would read as work. Owned by the daemon: acknowledging on one device clears it everywhere. **Clients should notify and badge on `attention` becoming true, not on state transitions**, unless `quiet` is true. Pushes (`push`) follow the same rises, except quiet ones |
| `needs_user` | whether the user has to do something (`true`) or the agent only finished (`false`); `null` when not known: while the agent works, and possibly while a finished turn is still `settling`. Always `true` for `waiting` and `error`. For `done` it is decided from how the reply ends: a question to the user or a blocked turn is `true`, a plain finished turn `false`. The small model that writes `summary` decides it in the same call; until it answers, and when it can't, a text heuristic does. **Never `null` while `attention` is true on a hook-reported agent.** It may change together with `summary` while `summary_pending` is true (a `pane` event brings both) and is final after. Clients word the notification by it ("Needs you" or "Done") and play no sound for `false`; see [Fewer, clearer alerts](#fewer-clearer-alerts). Absent (older daemons) means not known: word the notification by `state`, with its sound, as before. Feature flag: `alerts` |
| `settling` | a hook reported `done` and the settle window is running: `attention` has not risen for this turn yet. It turns false when the window ends (and `attention` rises, unless the agent is muted), when the agent works again or goes away, or on `agent.ack`. Clients show the agent as `done` meanwhile, without a badge or notification. Absent (older daemons) means false. Feature flag: `alerts` |
| `quiet` | the last rise of `attention` was quiet: the agent's turn ended (`done`) while the user was at the pane, meaning a client that shows the pane (subscribed) sent it input within the last 60 s. For a rise after the settle window, that is decided when the window ends, and it is quiet if the user was at the pane when `done` was reported **or** is at the rise (otherwise a prompt typed 40 s before the turn ended would stop counting). The user sees that turn end, so `attention` is raised (badge it, show it in the pane) but the daemon sends no push, and **clients must not post a notification for it** either. Kept until the next rise (through `agent.ack`), so it is in the `agent` and `pane` events of that rise. Always false for a rise into `waiting` or `error`: those notify even when the user just typed, since they may have stepped away and the agent is stuck until they answer. Absent (older daemons) means false |
| `muted` | the user muted this agent (`agent.mute`). While muted, nothing raises its `attention` (hook `waiting`/`done`/`error`, BEL, the end of a settle window), so it never notifies or pushes; its `state` still updates as usual. Muting clears `attention`. It lasts for this agent: through restarts and upgrades of the daemon while the agent's process lives, and until `agent.mute` with `muted: false`. It is gone when the agent goes away (session end, exit), and a new agent in the pane starts unmuted. Owned by the daemon, like `attention`: muting on one device mutes it everywhere. Absent (older daemons) means false. Feature flag: `agent.mute` |
| `session` | the agent's own session id, if it reports one |
| `progress` | what the program says about how far it is: `{"state": "running" \| "error" \| "indeterminate" \| "paused", "percent": 0..100 \| null}`. **Absent when there is none.** `percent` is a whole number, `null` when the program gave none (always for `indeterminate`). It comes from OSC 9;4 and OSC 7501 `progress`, from any pane, hook-reported agents included. It is only for drawing (a bar or ring on the agent's row and Tab): it never raises `attention`, never notifies or pushes, and its changes come as `pane` events only, at most one a second per pane (the clear always arrives). Cleared by the program (OSC 9;4 with state 0), and when the foreground process group that set it exits, so a crashed build doesn't leave a bar behind. Not kept across a daemon restart. Treat an unknown `state` as `running`. Feature flag: `agent.progress` |
| `summary` | what a notification about this agent should say: `message` as one or two plain sentences (at most 200 chars, no Markdown, one line), or `null` when there is no `message`. A small model's rewrite once it's ready, before that (and when there is none) `message` cleaned of Markdown. **Clients show `summary` in notifications and the Agents list, and fall back to `message` (cleaned of Markdown themselves) when it is absent** (older daemons). See [Notification text](#notification-text). Feature flag: `summary` |
| `summary_pending` | a rewrite of this rise's text is under way, so `summary` may still change (a `pane` event brings it). Absent (older daemons) means false |

Changes reach clients in two ways. Every change to the field comes as a `pane` event, because
the pane object changed. State transitions (including an agent appearing or going away) also
come as an `agent` event, `{"pane", "agent", "from"}`, with the full new object (or `null`) and
the previous state (or `null`), so clients can notify without diffing. A rise of `attention` with
no change of state (the end of the settle window, a hook taking over from detection) is an `agent`
event too, with `from` equal to the state.

**Clearing:** the field goes back to `null` when the agent reports that its session ended, when
the agent's process exits (it's watched by pid), or when the pane closes.

**Pane-bound agents** (feature `agent.osc` or `agent.kinds`) are the exception to "watched by
pid". A notification usually comes from a program that is about to exit: a build script prints
"Build finished" and ends, and the alert must outlive it. So these agents belong to the pane,
not to a process:

- Which ones: every agent with `source: "osc"`, and an agent reported with `clothod report`
  (`agent.report`) under a kind that is not one of the known agents' (`other`, or a name of
  its own), by something that is not a known agent: none is the pane's foreground process
  group or an ancestor of the reporter (so: a script, or a job typed at the shell). A report
  that names a known kind (`claude`, `codex`, the other kinds above) is that agent's, through
  its hooks, and is watched by pid as before; so is one that continues a live agent's reports.
- `waiting`, `done` and `error` stay when the program that reported them exits.
- `running` and `starting` are cleared when the foreground process group that reported them
  exits: nothing is working any more. (Reported by the pane's own process, with no job of its
  own, they last until the pane closes.) An OSC 7501 `blocked` ends the same way.
- They go away through **`agent.ack`** on a `waiting`, `done` or `error` one, which removes the
  agent (the pane's `agent` is `null` after it, and an `agent` event with `agent: null` says
  so: with the user's answer nothing is left to show). A muted one is the exception: it stays,
  with its mute, so that the next notification from that pane stays quiet too. Also
  through `clothod report clear` or OSC 7501 `clear`; when another agent replaces them (a hook
  report, a known agent appearing in the pane's foreground); or when the pane closes.
- They are saved and come back after a daemon restart or upgrade as they were, without a check
  for a process. `progress` is not saved.
- Clients need nothing special: acknowledge as for any agent, and expect `null` after it.
  There is no flag for it on the agent object.

### Notifications from any program

Feature `agent.osc`. Terminals have long had escape sequences with which a program says "tell
the user": a finished build, a prompt that waits. The daemon reads four of them from every
pane's output, and the pane shows as an agent that needs the user. Nothing is installed, and the
program doesn't have to know Clotho. Each ends with BEL or ST, like any OSC.

**What is read.**

| sequence | read as |
|---|---|
| `OSC 9 ; <text>` | a notification with that text (iTerm2's form). The text may hold `;` |
| `OSC 9 ; 4 ; <st> [; <percent>]` | progress (ConEmu's form): `st` 1 running, 2 error, 3 indeterminate, 4 paused, each with the percent when given (0 to 100, more reads as 100; never for 3); `st` 0 clears it. See `progress` |
| `OSC 777 ; notify ; <title> ; <body>` | a notification (rxvt-unicode's form). The body may hold `;` |
| `OSC 99 ; <metadata> ; <payload>` | a notification (kitty's form), see below |
| `OSC 7501 ; <fields>` | a status report (the Program Status Protocol), see [OSC 7501](#osc-7501) |

The exact rules:

- **All four:** the sequence must end with BEL or ST and be at most 4,096 bytes (number and
  text together). A longer one is ignored whole, not cut.
- **`OSC 9`:** when the first field is one or two digits making a number from 1 to 12, it is a
  ConEmu command: `4` is progress, and the others (`9;1;…` sleep, `9;2;…` message box, `9;9;…`
  cwd and the rest) are ignored, and so is a text that is only such a number. Everything
  else is a notification, `;` included: "3 tests failed" and "2024 is over" are text.
- **Progress:** an `st` that isn't 0 to 4 is ignored. A percent that isn't a number is no
  percent.
- **`OSC 777`:** only `notify`. The title is the text up to the next `;`, the body all the
  rest.
- **`OSC 99`:** the metadata is `key=value` pairs joined with `:`. Four keys are read:
  - `p`, the payload's type: `title` (also when `p` is missing) and `body` are text. `icon`
    and `buttons` carry nothing that is shown. `close` forgets the unfinished notification of
    that `i`. `?`, `alive` and any other type are ignored.
  - `e=1`: the payload is base64 (RFC 4648, padded or not) and is decoded. A payload that
    doesn't decode discards the whole notification it belongs to. An `e` other than `0` or `1`
    makes the sequence ignored.
  - `d=0`: more pieces follow under the same `i`. Title pieces are joined, and body pieces;
    the notification is read when a piece without `d=0` arrives.
  - `i`, the identifier (at most 64 of letters, digits and `_-+.`).
  - Unfinished notifications are held per pane: at most 8 identifiers and 4,096 bytes
    together. Past either, the oldest are dropped. A terminal reset drops them all.
  - Every other key (`a`, `o`, `u`, `c`, `w`, `f`, `t`, `g`, `n`, `s`) has no effect: no
    action on click, no "only when unfocused", no urgency, no sound, no icon. The daemon's own
    rules decide whether and how the user is told.
  - **Nothing is ever written back**: not the answer to the `p=?` query, and no activation or
    close report (`a=report`, `c=1`).
- A notification whose title and body are both empty after cleaning is ignored.
- Any of them in **replayed** output: what the daemon reads again after a restart or an upgrade
  (the holder's buffer) never notifies a second time, like OSC 52 copies.

**The text.** A title is cleaned and cut at 100 characters and a body at 300: control
characters removed (C0, DEL, C1) as for a pane title, invalid UTF-8 replaced, spaces trimmed.
The message is `<title>: <body>` when both are there, else the one that is, and is at most 300
characters in all. It is plain text: no Markdown, no markup, no links, whatever it looks like.
`summary` is that same cleaned message. **No model rewrites text with source `osc`**, and
`summary_pending` is never true for it: the text is any program's output and is not sent to
Claude.

**What happens**, by what the pane's agent is when the notification arrives:

| the pane's agent | a notification (9, 99, 777) | OSC 7501 state | `progress` (9;4, 7501) |
|---|---|---|---|
| none | a new agent: `kind: "other"`, `source: "osc"`, `state: "waiting"`, `needs_user: true`, the message; `attention` rises at once | a new `osc` agent in that state, `kind` from `app` | a new agent `{kind: "other", source: "osc", state: "running"}` with the `progress`; removed again when the progress clears and its `attention` is down |
| `source: "osc"` | its state becomes `waiting` with the new message; `attention` rises if it was down | applied | applied |
| `source: "detected"` | as a BEL, with words: `state: "waiting"`, the message, `attention` raised, no longer a guess. `kind` and `source` stay | only `blocked` is taken, like a notification (its `msg`, or the wording for its `kind`); every other state is ignored, and detection goes on guessing | applied |
| `source: "hook"` | **ignored whole**: no state, no message, no event, no push | **ignored whole** | applied |

The rule in the last row is "the hook wins". An agent that reports through hooks says exactly
what it does, and Claude Code and others also print a notification sequence for the same
moment: taking both would alert twice, with worse text. Two more cases follow from it:

- **A hook report takes over an `osc` agent.** The agent becomes the hook's (`source: "hook"`,
  its `kind`, its `session`). When `attention` is already up and the hook reports the same
  state, it stays up as it is: no second rise, no `agent` event, no second push (a `pane` event
  brings the new fields). Otherwise the usual rules for that report apply.
- **A known agent appears in the pane's foreground** (detection finds `claude`, `codex`, …)
  while the pane has an `osc` agent: the detected agent replaces it and keeps its `attention`,
  `message` and `progress`, so an alert the user has not seen is not lost when the agent's own
  name shows up. An `osc` agent that already names itself as that kind (OSC 7501 `app`) stays:
  its own reports are exact, where detection would only guess.

A rise from here is a rise like any other: an `agent` event, the mute, `quiet`, the hold while
the user is at the Mac, the per-pane push interval and the decision log
([Fewer, clearer alerts](#fewer-clearer-alerts)) all apply. The push carries `k` (the kind),
`s` and the cleaned text as both `msg` and `sm`.

**How long it stays.** An `osc` agent is pane-bound (see Clearing above): the alert stays after
the program exits, and `agent.ack` removes it.

**Rate limits**, per pane, for these sequences only (hook reports are not limited). A program
in a loop, or `cat` of a file full of them, must not flood the phone or the event stream:

- **Rises:** a bucket of 3, refilled with one every 20 s. A notification that would raise
  `attention` with the bucket empty is dropped whole.
- **The same text again** while `attention` is up: nothing at all.
- **Other text** while `attention` is up: the message changes, as a `pane` event only (no
  `agent` event, no notification, no new push; a push for this rise that has not gone out yet
  goes with the latest text), at most 3 in 30 s. More are dropped.
- **OSC 7501 state changes that raise nothing** (`working`, `idle`, back and forth): at most
  10 in 10 s per pane. Past that the daemon keeps only the latest and applies it within a
  second, so the state shown is right in the end and the events are few.
- **`progress`:** `pane` events at most one a second per pane; the latest value wins, and a
  clear is always delivered.
- What was dropped is logged as one line per pane and refill period, `osc dropped pane=<id>
  count=<n>`: a count, never the text.
- **Test timing:** `CLOTHOD_TEST_OSC_REFILL_MS` (default 20000) is the refill time of the rise
  bucket, for test suites that raise more than three times in one pane.

#### OSC 7501

The Program Status Protocol (revision 0.4, as published at control-codes.page/proposals/osc-7501): a program says what it does, as `OSC 7501 ;` followed by
`key=value` pairs joined with `:`, for example `OSC 7501 ; state=blocked:kind=permission:app=mytool`.
The keys that are read:

| key | |
|---|---|
| `state` | `idle`, `working`, `done`, `blocked`, `error` or `clear`. Any other value discards the whole report |
| `kind` | why it is blocked: `permission`, `question` or `auth`. Another value is ignored (the report stands) |
| `app` | the program's name. It becomes the agent's `kind`, normalised like any reported kind (lowercase, 1 to 32 of `a-z 0-9 . _ -`, else `other`) |
| `msg` | the message, **base64** of UTF-8; at most 300 characters are kept |
| `title` | a title, base64 of UTF-8; at most 100 characters are kept |
| `progress` | a whole number from 0 to 100. Another value is ignored (the report stands) |

Unknown keys are ignored. The whole report is discarded when `msg` or `title` is not base64 of
valid UTF-8, or when `app`, `msg` or `title` holds a control character. A report without a
`state` is ignored (`progress` alone says nothing), and so is one with an `id`: that is a
sub-task's record, and only the program's own (root) record is kept.

What a report becomes:

| reported | agent `state` | |
|---|---|---|
| `working` | `running` | clears `attention`, like any agent working again |
| `blocked` | `waiting` | `message` is `msg`; without one it is worded from `kind`: `permission`, `question` or `auth` ("Needs your permission", "Has a question for you", "Needs you to sign in"; no message when there is neither). Unlike a notification's alert it ends when the program that reported it exits, as the protocol asks. `attention` rises at once |
| `done` | `done` | settles like a hook's `done` (the settle window, then the rise). `needs_user` comes from the text heuristic on `msg`; no model is asked |
| `error` | `error` | `message` is `msg`. `attention` rises at once |
| `idle` | `done` | `needs_user: false` and **no rise**: the program has nothing going on, which is not news |
| `clear` | – | removes the pane's `osc` agent. It never removes a detected or hook-reported one |
| `progress=<n>` | – | only with `working` or `blocked`: sets the agent's `progress` to `{"state": "running", "percent": <n>}`. A `working` or `blocked` report without it leaves the progress as it is (OSC 9;4 may be setting it); a report of any other state clears it, and so does the reporting program's exit |

- `title` is read and not used: the message is `msg` alone.
- `running` (from `working`) is cleared when the program that reported it exits; `done` and
  `error` stay, like a notification's alert.
- The table under "What happens" applies: for a pane whose agent is hook-reported only
  `progress` is taken.
- **The query is not answered.** A program asks `OSC 7501 ; ?` to learn whether the terminal
  speaks the protocol, and starts reporting when it does. clothod stays silent, and clients
  that answer terminal queries themselves must not answer this one. An answer would make Claude
  Code and Codex report here as well as through their hooks, and what they do after an answer
  has not been verified. Programs that report without asking are read all the same. A daemon
  started with `CLOTHOD_TEST_PSP_ANSWER=1` does answer it; that is for trying it out in an
  ephemeral instance, not something a client can rely on.

### Reporting from your own scripts

Feature `agent.kinds`. A script, a deploy, a long test run can put itself in the Agents list and
on the phone, in two ways. Both work in any Clotho pane, on any machine, with nothing installed.

With `clothod report`, when the script should say exactly what it means (the binary is on the
machine wherever a pane is: `<install base>/current/clothod`):

```sh
# Stop and ask: shows as "Needs you", with a sound and a push to the phone.
clothod report --state waiting --message "Deploy needs approval"

# Say it finished, as a plain "Done": shown and pushed without a sound.
clothod report --state done --message "Backup finished" --needs-user no
```

With a terminal notification, when the script can only print (it runs over ssh on a machine
without clothod, in a container, or is a tool that already does this):

```sh
printf '\033]9;Build finished\007'
```

That one always reads as "Needs you" ([Notifications from any program](#notifications-from-any-program)).
A `done` is told about 30 s after it was reported, like an agent's finished turn (the settle
window); `waiting` and `error` at once.

More that `report` takes: `--state running` while it works (shown without an alert) and
`--state error --message …` when it fails; `--kind deploy` to give it a name of its own in the
list (lowercase letters, digits, `.`, `_` and `-`, at most 32); `clothod report --state clear`
to take it away. With `--state` it prints what went wrong and exits non-zero (2 for a mistyped
command, 1 when it isn't in a Clotho pane or reached no daemon), so a script can tell.

**How long it stays.** The status belongs to the pane, not to the script:

- `waiting`, `done` and `error` stay after the script exits, until the user acknowledges the
  alert in an app (then it is gone from the list), until `clothod report --state clear`, until
  something else reports in that pane, or until the pane closes. They also survive a restart of
  the daemon.
- `running` and `starting` go away by themselves when the script (the pane's foreground job
  that reported) exits, so a script that crashes doesn't stay "running".
- In a pane where a hooked agent (Claude Code, Codex) is the pane's agent, a printed
  notification is ignored: the agent's own report wins.
- `--kind` with the name of a known agent (`claude`, `codex`, `gemini`, …) is taken as that
  agent's own hook, not as a script's: such a status ends when the reporting job exits and
  is not removed by an acknowledgement. Use a name of your own.

### Notification text

Since 0.1.29 (feature `summary`). Agents write Markdown and long replies; a lock screen wants one
or two plain sentences. So when an agent's `attention` rises and the rise isn't quiet, the daemon
has a small model rewrite the agent's words, and every client and phone shows the same text
(PLAN.md, "Notification text"). Since 0.1.31 (feature `alerts`) the same call also says whether
the user is needed (`needs_user`), and for a hook-reported `done` it starts when `done` is
reported, so the answer is usually there when the settle window ends
([Fewer, clearer alerts](#fewer-clearer-alerts)).

- **Who writes it:** Claude Haiku, run through the machine's own `claude` login
  (`claude -p --model haiku`), no API key. It gets the agent kind, the state (finished, error,
  a question, or a permission ask), `message`, `prompt`, for a wait the tool and its input, and
  (since 0.1.31) the end of the reply (`agent.report`'s `tail`, its last 600 characters), and
  answers with at most about 160 characters of plain text. A permission ask says plainly
  what the agent wants to do. **Clients still show the exact tool and command** (`tool`/
  `tool_input`, `requests`) next to it, so what Allow approves is never only the model's words.
- **One call, summary and label** (since 0.1.31, feature `alerts`): for a finished turn (`done`)
  the same call also decides `needs_user`. The model is asked to start its answer with a line
  that is exactly `NEEDS_USER` (the reply ends by asking the user something, waits on their
  decision, or says it is blocked) or `DONE`, and to put the notification text on the next line:
  ```
  NEEDS_USER
  Tests pass. Should I push the branch?
  ```
  The daemon reads the first non-empty line, in any case and with `*` or `` ` `` around it
  ignored. If it is one of the two words, that is the label and the rest is the text. If not,
  the whole answer is the text and the label comes from the heuristic. `waiting` and `error`
  ask for no label: they always need the user.
- **The heuristic** decides `needs_user` for `done` until the model answers, and for good when
  it doesn't (the rewrite is off, fails, or gives no label). It looks only at the end of the
  reply: `tail`, else `message` when that is under 300 characters (a longer one was cut, so its
  end isn't known, and the answer is false). It is true when that text, with trailing spaces,
  quote marks and Markdown marks dropped, ends with `?`, or when its last 200 characters hold one
  of these as whole words, in any case: "let me know", "should I", "do you want", "would you
  like", "which option", "please confirm", "waiting for your", "need your", "I need you to",
  "blocked", "can't proceed", "cannot proceed", "unable to proceed". Otherwise false. It leans
  towards false: a wrong "Done" is silent but still shown, a wrong "Needs you" is noise.
- **Where it goes:** the agent's `summary`, and the push record's `sm` (docs/push.md). `message`
  and the record's `msg` stay exactly as the agent said them.
- **Timing:** a push waits up to about 6 s for the rewrite. Without it by then it goes with the
  cleaned original in `sm`, and the rewrite still reaches the model if it finishes (within 30 s):
  `summary` changes in a `pane` event and `summary_pending` turns false. A client notifying on the
  rise can wait for that event while `summary_pending` is true (up to about 6 s, like the push),
  or notify at once with the current `summary`. `needs_user` may change in that same `pane` event,
  from the heuristic's answer to the model's, and is final once `summary_pending` is false. For a
  hook-reported `done` the call starts when `done` is reported, not at the rise, so after the
  settle window both are normally final already.
- **Failures:** no `claude`, not logged in, out of quota, a timeout, an empty answer: `summary`
  stays the cleaned original and `needs_user` the heuristic's. Nothing is ever held back or
  dropped for it. The `notification_rewrite_health` setting says whether it works and why not
  (see [Settings](#settings)).
- **Cost:** at most two rewrites run at once. The same input is rewritten once (cached).
- **Cleaning** (also applied to the model's answer): no `**`, `_`, `` ` `` or `~~` marks, no
  code fences, headings, quote marks or rules, link and image syntax replaced by their text,
  list items as `• item`, whitespace collapsed to single spaces.
- **Safety:** the helper runs in a fresh empty private directory with `--safe-mode
  --setting-sources user` (since 0.1.31), `--tools ""`, `--strict-mcp-config`,
  `--no-session-persistence` (nothing in the user's Claude history) and a clean environment (no
  `CLOTHO_*` pane variables, no API keys or `ANTHROPIC_*` from the daemon's own environment).
  - Why the user settings: a machine's Claude login can live in the `env` block of the user
    settings (`~/.claude/settings.json`), not only in the credentials file or keychain. Before
    0.1.31 the helper ran with `--setting-sources project,local`, which skipped that file, so on
    such a machine every rewrite failed with "Not logged in".
  - Why safe mode: it keeps what the user settings would otherwise bring in turned off. Hooks,
    plugins, MCP servers, skills and CLAUDE.md don't load, so the user's hooks never see the
    helper's traffic; the login works as usual.
  - A Claude Code too old to know `--safe-mode` refuses it ("unknown option"). The daemon then
    runs that rewrite again with the earlier arguments (`--setting-sources project,local`, no
    `--safe-mode`) and uses those until it restarts. Hooks, plugins and MCP servers stay off that
    way too, but a login from the settings' `env` block isn't found: the health then says so.
  - It isn't in any pane, so agent detection never sees it. An ephemeral (test) instance never runs
    the real `claude`, only a program named by `$CLOTHOD_SUMMARIZER` (tests point it at a fake);
    set on a normal instance, that variable replaces `claude` too.
- **Off switch:** the `notification_rewrite` setting (see [Settings](#settings)). Off, `summary`
  is the cleaned original, `needs_user` is the heuristic's, and nothing runs.
- **Never for `source: "osc"`:** text from a terminal notification or OSC 7501 is not sent to
  the model. `summary` is the cleaned message and `needs_user` comes from the state and the
  heuristic ([Notifications from any program](#notifications-from-any-program)).
- **A reporter's own label:** an `agent.report` with `needs_user` (`clothod report --needs-user
  yes|no`) fixes the label of a `done`: neither the model's label nor the heuristic replaces
  it. It holds until the next report that has other text and doesn't send `needs_user`; then
  the label is decided as usual. The rewrite of the text still runs for a hook-sourced report.
  It has no effect on `waiting` and `error`, which always need the user.
- **By hand:** `echo '{"state": "done", "message": "...", "tail": "..."}' | clothod summarize`
  prints the cleaned text and the rewrite (or why there is none) as this machine's daemon would
  make them, with the model's label (`needs_user`) and the heuristic's (`needs_user_guess`).

### Fewer, clearer alerts

Since 0.1.31 (feature `alerts`; PLAN.md, "Fewer, clearer alerts"). The daemon decides when an
agent is worth an alert and what kind, so every client and the phone agree. Everything here is
additive: a client that knows nothing of it keeps working and simply gets fewer rises.

The rules:

- **Settle.** A hook-reported `done` (also a hook taking over from detection in `done`) doesn't
  raise `attention` at once when it wasn't raised already. The agent shows `state: "done"`,
  `settling: true`, and a timer runs (30 s).
  - The agent works again in the window (`running` or `starting`): the timer is cancelled and
    `attention` never rises for that turn.
  - `agent.ack` in the window cancels it too. A muted agent never raises.
  - A second `done` report in the window keeps the same timer.
  - Otherwise `attention` rises when the window ends: a `pane` event and an `agent` event whose
    `from` is `"done"`, with `settling` false and `quiet` decided then (see `quiet`).
  - `waiting` and `error` never settle. They raise at once, also during a window.
  - The window survives a daemon restart or upgrade: it is re-armed from the saved `settling` and
    `since`, and raises at once if it is already past. Entering and leaving the window are both
    stored at once, so a daemon that dies right after the agent worked again, or right after the
    rise, comes back without a window: it doesn't raise for a working agent or raise twice.
- **Label.** `needs_user` says whether the user has to act: always for `waiting` and `error`; for
  `done`, when the reply ends by asking the user something or says it is blocked. To judge that
  on a long reply, hooks send its end as `agent.report`'s `tail`: the last 600 characters, on one
  line, of a reply longer than the 300 that `message` keeps. The `clothod report` binary adds it
  from the payload the installed hooks already pass, so hooks need no reinstall. `tail` is only
  input for the label and the summary: it is not in the agent object.
  The label belongs to the text. A second `done` report keeps it only when `message` and `tail`
  are what they were (a `tail` that isn't sent again counts as unchanged while `message` is).
  With other text the label is decided anew, and a `tail` from the earlier message is not used:
  while the turn still settles `needs_user` is `null` again and the rise decides (the rewrite of
  the new text, or the heuristic); once `attention` is up the heuristic labels the new text at
  once (no second rewrite, no second push), in a `pane` event; with `attention` down and
  nothing settling (after `agent.ack`) it stays `null`. So "All tests pass." followed by
  "Should I push?" never stays a plain Done.
  The rewrite belongs to the same text: another `tail` under the same `message` drops it like
  another `message` does (`summary` is the cleaned `message` again, and a rewrite still under
  way for the earlier text is not used).
  A push for the rise that has not gone out yet follows the text too. While it waits for the
  rewrite (up to 6 s), for the per-pane interval, or is held at the Mac (below), a report that
  changes `state`, `message`, `tail` or the label with `attention` still up replaces what it
  will carry: it goes out with the latest text and label, and without the earlier text's
  rewrite. A push that already went is not sent again.
- **At the Mac.** While the user is at the Mac app, the daemon holds pushes to the phone for up
  to 2 minutes, from the rise. This applies to every state, `waiting` and `error` included; the
  Mac app shows the alert itself. A held push is dropped when the pane's `attention` clears (the
  agent works again, `agent.ack`, the agent goes away), when any client focuses that pane
  (`pane.focus`) or types in it, or when the pane closes (`pane.close`, its Tab or Workspace
  closing, or its process ending): no push is sent for a pane that no longer exists, held or
  still waiting for its rewrite or the per-pane interval. Otherwise it is sent when the 2 minutes end, with the latest
  text and label: a rewrite that finishes at any time during the hold is in it, and so is a
  `message` or `tail` the agent reported during the hold in place of the one that rose (then
  without the earlier text's rewrite).
  A hold survives a restart of the daemon (an in-place upgrade): when it ends is stored with
  the pane as it begins, and removed as it ends (sent or dropped). The daemon that comes back
  holds the push again for the time that was left, logged as `held` with `reason=restored`,
  and sends it at once if the hold ended while it was down; seeing the pane or `attention`
  clearing drops it as before. That push carries the cleaned original text and the stored
  label (a rewrite is not stored). A push that was sent or dropped before the restart is not
  sent again. The one pane
  that is not held is the one the user is at (see `quiet`: input from a client showing it within
  the last 60 s). There the earlier rule stands: a finished turn rises quietly and is never held
  or sent, and `waiting` and `error` push at once. After those 60 s the pane the user typed in
  last is held like every other pane, for as long as they count as at the Mac.
  The daemon knows the user is at the Mac from exactly three things, each from a client whose
  hello `client` starts with `clotho-mac`: typed input in one of its panes (INPUT, `pane.input` or
  `pane.keys` that is not a terminal report), the focus-in report (`ESC [ I`) sent as pane
  input when the app gains focus, and `client.active`. Nothing else counts: not the focus-out
  report (`ESC [ O`), and not mouse reports (`ESC [ <` …, `ESC [ M` …), which a pointer
  drifting over a pane with mouse reporting on sends without the user being there. (Whether
  the user is at one pane, `quiet`, is unchanged: any input there counts.)
  For the other machines the Mac app says so with
  **`client.active`**: no params, result `{}`. It means "the user is at this app now" and counts
  for 2 minutes, while that connection stays open. A Mac app sends it to each connected machine
  whose panes the user isn't typing in, while the user is using the app (again at least every
  2 minutes; once a minute is enough), and not when it is idle or in the background. It changes no state and sends no event. From a client
  that isn't a Mac app it is answered `{}` and ignored.

- **Push.** The push record gets `nu` (the agent's `needs_user` as a bool, left out when not
  known), inside the ciphertext. The `/v1/push` body gets `"silent": true`, in the clear, only
  for state `done` with `needs_user` false, so the relay can leave the sound out; it is never
  sent as false. docs/push.md has the record and the relay's side.
  The record's `tb` is now the Tab's title **as the apps show it**, and is always there: the
  name the user gave the Tab; else its active pane's title, without a leading status glyph
  (Claude Code's ✳, a spinner) and with a bare "Claude Code" replaced by the folder's name;
  else the name of the pane's folder; else "Shell". It is cut to the record's cap for names
  (96 bytes). Earlier daemons sent `tb` only for a Tab the user had named, so a phone's title
  lacked the Tab where the app's own banner had it. `k` may now be any kind name.
- **Decision log.** Every push decision is one line in `clothod.log`:
  `push <sent|held|dropped> pane=<id> agent=<kind> state=<state>
  label=<needs-you|done|unknown> [silent] [devices=<n>] [reason=<why>]`. `<kind>` may be a
  name a reporter chose; it is normalised before it gets here (lowercase `a-z 0-9 . _ -`, at
  most 32, else `other`), so it can hold no space and can't forge another field. `held` has
  `reason=restored` when it is a hold taken back after a restart. The reasons for
  `dropped` are `quiet` (the user was at the pane), `seen at the Mac`, `attention cleared`
  (while held), `pane closed` (the pane was closed or its process ended before the push went
  out: while held, waiting for the rewrite, or for the per-pane interval), `settled away` (the agent worked again within the settle window),
  `acknowledged` (`agent.ack` within the settle window), `muted` (also `agent.mute` within the
  settle window), and `rate limited`. `sent` and `held` are logged only when a phone is registered. The log never
  carries a message, summary, prompt, tool input, or a Workspace, Tab or machine name.
- **Test timings**, like `CLOTHOD_TEST_PRESENCE_MS`: `CLOTHOD_TEST_SETTLE_MS` (default 30000;
  0 means no settle, the behaviour before 0.1.31) and `CLOTHOD_TEST_AT_MAC_MS` (default 120000,
  both the "within 2 minutes" and the hold; 0 turns the hold off). Client test suites that wait
  for the rise after a `done` report set the first on their dev daemons.

What a client does:

- **Notify on the `attention` rise, as before** (the `agent` event, unless `quiet`). Nothing new
  to wait for: the settle window has already passed when the rise arrives. Don't notify on
  `state` becoming `done`, and don't badge an agent that is `settling`.
- **Word it by `needs_user`:** "Needs you" for true, "Done" for false, with `summary` as the
  text. A permission ask keeps its exact tool and command, as before.
- **Play no sound for a plain Done** (`needs_user` false). Needs you keeps its sound.
- `needs_user` and `summary` may change once while `summary_pending` is true. A client that
  waits for the summary (up to about 6 s) gets the final label with it; one that notified at
  once may replace the notification in place.
- Against a daemon without `alerts`, `needs_user` and `settling` are absent: notify by `state`
  as before.

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
  terminal's `tpgid`, with the process name and argv from `/proc` or `libproc`): a process of a
  known agent (`claude`, `codex`, and with `agent.kinds` `opencode`, `gemini`, `copilot`,
  `aider`, `amp`, `cursor`; see the table below) means an agent of that `kind` with
  `source: "detected"`. `claude` and `codex` match on any of the process's names (the
  executable, the process name, the first arguments). The others match the process's own name
  exactly (`cursor-agent` for Cursor; its other name, `agent`, is too generic), or an argument
  only behind an interpreter or a shell (`node`, `bun`, `deno`, `python*`, `sh`, `bash`, `dash`,
  `zsh`): `node …/gemini`, `python …/aider` and a wrapper script called `gemini` are agents,
  `vim gemini` is not. The state is inferred:
  recent output means `running`, quiet after activity means `waiting`, and a BEL or a terminal
  notification means `waiting`.
- Once a pane gets a hook report, detection no longer changes its state. It only clears the field
  when the agent process is gone.

**Which agent has what.** Hooks where the agent has a hook system that says when it waits and
when a turn ends; detection only where it has none that does, or none that could be verified:

| agent (`kind`) | status from | why |
|---|---|---|
| Claude Code (`claude`) | hooks | `clothod hooks install claude` |
| Codex (`codex`) | hooks | `clothod hooks install codex` (its `notify` program: turn ends only) |
| Gemini CLI (`gemini`) | hooks | `clothod hooks install gemini` |
| GitHub Copilot CLI (`copilot`) | hooks | `clothod hooks install copilot` |
| OpenCode (`opencode`) | detection only | it is extended through plugins, which are code to write and load, not a config file to merge a command into |
| Amp (`amp`) | detection only | the same: plugins, no hook commands in a config file |
| Cursor Agent (`cursor`, the `cursor-agent` program) | detection only | Cursor's docs don't say that its terminal agent runs the hooks of `hooks.json`, so none are installed |
| Aider (`aider`) | detection only | it has no hooks. Its `--notifications` rings the terminal bell only on a machine without a desktop notifier, so the bell is not reliable. `aider --notifications-command 'clothod report done --agent aider'` reports the end of each turn exactly |
| anything else | its own notification (OSC 9, 99, 777, 7501) or `clothod report` | no install; see [Notifications from any program](#notifications-from-any-program) |

A detection-only agent shows as `running` or `waiting` by its output (a guess, which never
alerts) and alerts when it rings the bell or prints a notification. Only Claude Code and Codex
sessions are resumed after a restart ([Restore after restart](#restore-after-restart)): the
other kinds come back as a shell in their folder.

`clothod report` usage:

```
clothod report --state <starting|running|waiting|done|error|clear> [--kind NAME] [--message TEXT]
               [--needs-user yes|no] [--tail TEXT] [--session ID]     # for people and scripts
clothod report <state> [the same options]   # the hooks' form: silent, always exit 0
clothod report --claude-hook       # reads Claude Code's hook JSON on stdin and maps the event
clothod report --gemini-hook       # the same for Gemini CLI's hook JSON
clothod report --codex-notify JSON # Codex's notify payload (agent-turn-complete -> done)
```

- Options come in any order. `--kind` names the agent (`--agent` is the earlier spelling and
  still works). The daemon normalises it: lowercase, 1 to 32 of `a-z 0-9 . _ -`, and anything
  else becomes `other`. Without one the kind is that of the
  pane's current hook-reported agent, else `other`.
- `--needs-user yes|no` is the report's `needs_user` (see `agent.report` and
  [Notification text](#notification-text)): for a `done`, whether it shows as "Needs you" or
  as a plain "Done". `--tail` is `agent.report`'s `tail`.
- **Hooks never fail an agent.** Without `--state` (a bare state word, `--claude-hook`,
  `--gemini-hook`, `--codex-notify`, `--claude-permission`) it prints nothing and exits 0
  whatever happens, as before, and skips what it can't read: an installed hook must keep
  working whatever a newer agent passes it.
- **With `--state` it says what went wrong.** That is the form to type or to put in a script.
  It prints nothing and exits 0 when the pane's daemon took the report. Otherwise it prints
  `clothod report: <why>` on stderr and exits:
  - **2** for a usage error, with the usage line after it: `unknown state `<word>``,
    `unexpected argument `<word>``, `<flag> needs a value`, `--needs-user takes yes or no, not
    `<word>``.
  - **1** when the report didn't arrive: `not in a Clotho pane (CLOTHO_PANE is not set)`,
    `CLOTHO_PANE is not a pane id`, `no clothod reachable`, or the daemon's own message when it
    refused the report (for example `wrong_pane`'s, when no daemon has this process in that
    pane).

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
clothod hooks print claude|codex|gemini|copilot       # show the snippet
clothod hooks install claude|codex|gemini|copilot     # merge into the agent's own config file
clothod hooks uninstall claude|codex|gemini|copilot   # remove exactly what install added
clothod hooks status                                  # installed or not, per agent
```

| agent | file |
|---|---|
| `claude` | `~/.claude/settings.json` |
| `codex` | `~/.codex/config.toml` (`notify`) |
| `gemini` | `~/.gemini/settings.json` (its `hooks` object has Claude Code's shape) |
| `copilot` | `$COPILOT_HOME/hooks/clotho.json`, by default `~/.copilot/hooks/clotho.json`: a file of clotho's own, since Copilot CLI loads every `*.json` there |

Gemini CLI and Copilot CLI (feature `agent.kinds`):

- **Gemini CLI.** The hooks run `clothod report --gemini-hook`, which reads Gemini's hook JSON
  on stdin: `SessionStart` → starting; `BeforeAgent` → running, with its `prompt`;
  `BeforeTool` → running, with the tool and its input; `AfterTool` → running (a wait for the
  tool's permission is over); `AfterAgent` → done, with `prompt_response` as the `message`
  (and its `tail`); `Notification` → waiting, with its message (Gemini's one notification
  type is a tool's permission prompt); `SessionEnd` → clear. Other events are ignored.
  `install` merges into the settings file and keeps the user's own hooks, like Claude Code's.
- **Copilot CLI.** Each hook runs `clothod report <state> --agent copilot` and reads nothing
  from stdin: `sessionStart` → starting; `userPromptSubmitted`, `preToolUse` and `postToolUse`
  → running; `notification` of type `permission_prompt` or `elicitation_dialog` → waiting;
  `agentStop` → done; `sessionEnd` → clear. `errorOccurred` is not installed: nothing says the
  error ended the turn. So a Copilot agent has no `message`, `prompt` or `tool`. Each command
  ends in `true` (Copilot denies a tool call whose `preToolUse` hook fails) and has 5 s.
  `install` writes clotho's own file and never reads or changes the user's other hook files; a
  `clotho.json` there that isn't clotho's is refused and left alone. `uninstall` deletes the
  file.
- Neither has permission requests: only Claude Code agents have `requests`.
- The other kinds have no hooks to install (see the table above), and `clothod hooks` refuses
  their names with its usage line.

`install` also installs the running binary (and `current`) if needed. It is idempotent and keeps
the user's existing hooks. It backs the file up to
`<file>.clotho-backup-<unix time>` before changing it. For Codex, which allows only one `notify`
program, an existing one is kept and called after clotho's. `uninstall` puts it back.

`hooks status` prints one `<agent>: <status>` line per agent (`claude`, `codex`, `gemini`,
`copilot`, in that order; clients must accept more lines). The status is `installed`,
`outdated` (an older clothod's hooks, which `install` replaces in place) or `not installed`.
For Codex, `installed (chained)` and `outdated (chained)` (since 0.1.17) mean that another
program took over `notify` and calls clotho's as its `--previous-notify <JSON>`, as Codex
Computer Use does. Clotho's hook still runs, so count it as installed. `install` then updates
clotho's command inside the JSON rather than wrapping the other program (which would call
clotho's twice), and `uninstall` removes it from there.

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
  full scan of 50,000 scrollback rows at 120 columns takes 56 ms (release build, the Linux x86_64 dev box), and a
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

Color queries (OSC 10/11/12, and OSC 4 for entries the application hasn't set) are answered from
the colors of the client the user is using the pane from, if it sent any (see
[Client colors](#client-colors)), and otherwise from xterm's palette with a dark background:
foreground `#d8d8d8`, background `#1e1e1e`.

#### Client colors

Feature flag: `client.colors` in `hello.features`. A client tells the daemon its terminal colors
so that applications that ask for them (Claude Code's "auto" theme asks for the background) see
the ones the user sees, light or dark. Send them only to a daemon that lists the flag.

```json
→ {"id": 2, "method": "client.colors", "params": {"colors": {
     "foreground": "#1d1d1f", "background": "#ffffff", "cursor": "#0a84ff",
     "ansi": ["#000000", "#c41a16", …16 colors]}}}
← {"id": 2, "result": {}}
```

- `colors` can also go in `hello`'s params. `client.colors` replaces them (send it whenever the
  appearance changes, e.g. light to dark), and `{"colors": null}` clears them.
- `foreground` and `background` are required. `cursor` is optional (default: the foreground),
  and so is `ansi`, which must then hold exactly 16 colors, for ANSI 0–15 (default: xterm's).
  Each color is `#rrggbb` (hex digits in either case). Anything else, or another key, is
  `bad_request`.
- Which client's colors a pane uses: the connected client that last typed in the pane (keys,
  paste, mouse and focus reports: INPUT frames, `pane.input`, `pane.keys`) or subscribed to it,
  if that client sent colors. Otherwise the connected client that sent colors most recently.
  Otherwise the defaults above. A client's colors go when it disconnects.
- Answers: OSC 10, 11 and 12 report `foreground`, `background` and `cursor`. OSC 4 reports
  `ansi` for 0–15; 16–255 keep xterm's color cube and grays. Colors the application set itself
  (OSC 4/10/11/12) are reported as it set them.
- Dark or light: the colors are dark when the background's relative luminance is under 0.5
  (none count as dark). `CSI ? 996 n` gets `CSI ? 997 ; 1 n` (dark) or `CSI ? 997 ; 2 n`
  (light). Applications that turn on mode 2031 (`CSI ? 2031 h`; DECRQM `CSI ? 2031 $ p` reports
  it) get that report, unasked, whenever their pane's colors switch between dark and light: new
  colors from the client using it, another client taking it over, or that client leaving.
- Nothing else changes: snapshots and the screen state don't depend on client colors.

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
- **The pane takes the viewport of the client that focused it most recently** (since 0.1.28,
  feature `pane.focus`). A client focuses a pane in two ways:
  - `pane.focus {pane}` when the user brings it to the front (opens it, taps or clicks into it,
    switches to its tab). The client's viewport from `pane.subscribe` or `pane.viewport` becomes the
    size now. Reply: `{"cols", "rows"}`, the size after it. A client must be subscribed
    (`bad_request` otherwise; an unknown pane is `not_found`). A client that gave no viewport yet
    still takes the size: its next `pane.viewport` sets it.
  - `pane.subscribe` with a `viewport`, always. Clients that never send `pane.focus` keep working.
- Input (INPUT frames, `pane.input`) never picks the size. Focus and mouse reports are input, so a
  hover on one device can't take the size from another.
- `pane.viewport` from the client that owns the size resizes (a window resize, a rotation). From any
  other client it only records that client's viewport, used when it next focuses. If the owner no
  longer shows the pane (it unsubscribed or went away), the next `pane.viewport` takes the size.
- `pane.resize` sets the size directly, for a client that wants to force it. It doesn't change who
  owns the size.
- Before 0.1.28 the client that sent input most recently owned the size, and until anyone typed the
  most recent subscriber with a viewport did.
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
