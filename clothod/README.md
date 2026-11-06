# clothod

The Clotho session daemon. It owns the terminal sessions on a machine and serves them to
clients (the Mac app, later iOS and remote machines) over the protocol in
[`../docs/protocol.md`](../docs/protocol.md).

There is one binary, `clothod`, and it runs as two processes:

- `clothod holder` owns the PTYs. It forks the shells, holds the master fds, keeps a 4 MiB
  seq-numbered output buffer per pane and stores the latest VT snapshot. It is small and rarely
  changes, and it outlives the logic process.
- `clothod serve` is the logic daemon. It owns the model (workspace > tab > split tree > pane),
  runs a headless VT per pane (alacritty_terminal) and serves clients. You can kill or upgrade it
  at any time. On start it rebuilds each VT from the holder's snapshot plus a replay of the buffer
  after it.

`clotho` is a small test client.

## Build

```sh
cargo build --release                    # macOS (or Linux) native
cargo zigbuild --release --target x86_64-unknown-linux-musl --target aarch64-unknown-linux-musl
                                         # static Linux binaries; ring (TLS for push) has C code, so
                                         # cross builds use zig (brew install zig; cargo install cargo-zigbuild)
cargo test                               # unit, snapshot round-trip and end-to-end tests
scripts/test-all.sh                      # all of that on macOS, Linux (the dev box) and remotes, plus cleanliness
CLOTHOD_SOAK_SECS=3600 cargo test --release -p clothod --test soak -- --nocapture   # soak (Limits)
```

## Run

```sh
clothod start      # start in the background (also starts the holder); no-op if running
clothod status
clothod stop       # stop the logic process; shells keep running
clothod shutdown   # stop everything, including shells
clothod serve      # run in the foreground (logs to stderr)
clothod install    # see "Install and upgrade"
```

Clients start the daemon on demand (`clotho` does this), so you rarely need `start`.

Socket: `$CLOTHOD_RUNTIME_DIR/clothod.sock`. If that variable is unset, the default is
`$TMPDIR/clothod/` on macOS and `$XDG_RUNTIME_DIR/clothod/` on Linux, falling back to
`/tmp/clothod-<uid>/` when the path would be too long for a socket (which gives a clear error).
Logs (`clothod.log`, `holder.log`) go to `$CLOTHOD_STATE_DIR` if set. Otherwise they go into the
runtime dir when it isn't the default, so isolated instances keep separate logs, and else to
`~/Library/Application Support/clothod/` on macOS or `~/.local/state/clothod/` on Linux.
Since 0.1.15, `clothod.log` also records, with a UTC time, who closed what (`client 12
(clotho-ios/1.2, pid 4242) closed workspace 28 (panes [22])`), how each pane ended (`pane 22 ended
(signal 1)`: 1 is SIGHUP, which a close sends) and who answered a permission request, or why it
couldn't (`stale`). The pid is the connecting process's own; for a remote client that's the
`clothod bridge` on this machine.

## Install and upgrade

**One version and one instance per machine.** Exactly one build is installed
(`<base>/<version>-<hash>/clothod`, plus `<base>/current` pointing at it), and only the default
runtime dir holds a persistent instance.

```sh
clothod install               # first install only (refuses if another version is installed)
clothod upgrade               # switch this machine to this build: all or nothing, shells kept
clotho --host H upgrade       # the same on a remote host, with the bundled build
clothod status --print-builds # what runs: serve=, holder=, holder_outdated=
clothod ps                    # every clothod process of this user; extras are marked
```

`<base>` is `~/Library/Application Support/clothod/bin` on macOS and `~/.local/share/clothod/bin`
on Linux (`$CLOTHOD_INSTALL_DIR` overrides it).

`upgrade` installs the new build, switches serve and upgrades the holder in place: the holder
execs the new program in the same process and hands its state (PTY fds, buffers, snapshots) over
an inherited fd, so shells keep running with the same pids. Then it verifies everything and
deletes the old version. Any failure rolls back to the old build and removes the new one. A
serve that finds a holder on another build upgrades it the same way. Holders from before in-place
upgrades show `holder_outdated: true` until a one-time full restart (`clothod shutdown`, ends the
shells). An incompatible holder makes serve exit with code 3.

Releases: bump `[workspace.package] version` in `Cargo.toml`, then `scripts/dist.sh`. It
refuses a version that isn't newer than `RELEASED`, because the apps only offer upgrades to a
higher version. `scripts/dist.sh --dev` builds a same-version dist for testing.

Temporary instances need `--ephemeral[=SECS|exit]` (or `CLOTHOD_EPHEMERAL`) and a non-default
`--runtime-dir`. They delete themselves once unused. The tests run that way.

## Test client

```sh
clotho new                     # new workspace with a shell; prints the pane id
clotho new -- vim notes.md     # ...or with a command
clotho attach 1                # attach this terminal; Ctrl-\ detaches
clotho ls                      # workspaces, tabs, splits, panes
clotho split 1 down
clotho send 1 'echo hi\r'
clotho text 1                  # the screen as the daemon sees it
clotho resume 1 4096           # subscribe with have_seq=4096 and show what comes back
clotho watch                   # print events
```

To try the restart path, attach to a pane running vim, detach, run `pkill -9 -f 'clothod serve'`
and attach again. The client restarts the daemon, and the screen and vim come back unchanged.

## Layout

- `crates/proto`: framing, holder protocol, and the `platform` module (all macOS/Linux
  differences)
- `crates/vt`: headless VT and the snapshot serializer (VT state to ANSI byte stream)
- `crates/holder`: the PTY holder
- `crates/clothod`: the logic daemon and the `clothod` binary, plus the end-to-end tests in
  `tests/e2e.rs`
- `crates/cli`: client library and the `clotho` test client

## Remote machines

`clotho --host user@machine <command>` runs everything on another machine over ssh: it probes the
host, installs the right build from `dist/` if it's missing, and talks to `clothod bridge`
(spec: `../docs/remote.md`). `scripts/dist.sh` builds `dist/` for macOS and Linux (arm64 and
x86_64). The remote tests run with `CLOTHO_TEST_SSH_HOST=user@host cargo test -p clotho --test
remote`, in isolated dirs on the host.

## Agent status

The daemon tracks Claude Code, Codex and similar agents per pane. Hooks call `clothod report`, and
detection covers agents without hooks (spec: `../docs/protocol.md`, "Agents").
`clothod hooks print|install|uninstall claude|codex` manages the hooks. `install` edits the
user's agent configuration, so apps run it only after the user confirms.

## Start at login

`clothod service install|uninstall|status` (and the `service.*` requests the apps use for their
per-machine "Start at login" toggle) manages a LaunchAgent (`~/Library/LaunchAgents/
nyc.amin.clotho.clothod.plist`) or a systemd user unit (`~/.config/systemd/user/clothod.service`).
It runs `<install dir>/current/clothod start` once per login and never restarts anything, so it
can't race an in-place upgrade, and removing it leaves the daemon running. On Linux it needs
lingering (`sudo loginctl enable-linger $USER`), and `install` refuses without it; see
`src/service.rs` and docs/protocol.md, "Start at login".

## Configuration

`~/.config/clothod/config.toml` (or `$XDG_CONFIG_HOME/clothod/config.toml`, or `$CLOTHOD_CONFIG`),
read when the daemon starts. Apps change it with `settings.set` (docs/protocol.md, "Settings"),
which rewrites the file keeping its comments and applies the change at once:

```toml
# Lines of history each pane keeps in the daemon (0 to 50000): what a reattaching or newly
# started app gets back (apps keep their own deeper history while connected). A pane can set its
# own with the `scrollback_lines` spawn option; the others follow this setting.
scrollback_lines = 2000
```

## Limits

Memory, per pane (measured on Linux, 120 columns):

| | serve | holder |
|---|---|---|
| fixed | ~0.5 MB (VT, screen) | ~0.1 MB |
| history | 2.9 MB per 1000 lines in use (cols × 24 bytes a line), allocated 100 lines at a time | none |
| output buffer | up to 1 MiB (replays to reconnecting clients) | up to 4 MiB (recovery) |

Measured with 40 panes: about 0.6 MB a pane in serve and 0.07 MB in the holder with 100 lines of
history; 5 MB and 0.27 MB with 1500 lines (200 MB for all 40). A pane at full 2000-line history is
about 7 MB at 120 columns and 11 MB at 200 in serve, and ~1 MB in the holder.
Per client connection, at most 8 MiB of output is queued (past that its panes resync with a
snapshot once it drains, so a slow or reconnecting client can't grow the daemon).

Allocator: mimalloc on Linux, tuned to return freed memory at once (`src/alloc.rs`); the system
allocator on macOS. musl's own malloc, under a busy daemon's churn, kept gigabytes mapped while the
live heap stayed ~165 MB (24 GB RSS in an hour-long soak). `debug.stats` reports the live heap,
queues and buffers (and on Linux the kernel's view, from `/proc/self/smaps_rollup`).

Soak (`tests/soak.rs`, one hour, 20 panes of heavy output, 3 followers, a reconnect every ~5 s,
in-place upgrade at 30 min). The test fails if serve passes 400 MB or the holder 200 MB.

| | Linux x86_64 | macOS arm64 |
|---|---|---|
| produced | 63.7 MB/s | 74.2 MB/s |
| probe round-trip p50 / p99 / max | 2.9 / 6.7 / 14 ms | 0.36 / 1.2 / 83 ms |
| reconnects | 704 | 714 |
| serve RSS peak (end) | 154 MB (152) | 176 MB (148) |
| holder RSS peak (end) | 89 MB (88) | 154 MB during the upgrade (22) |

Memory stayed flat after the first minutes, and the upgrade didn't change latency.

## Not built yet

- Never run: the linux-aarch64 and macos-x86_64 builds (no such test machine yet); they build
  and are static, but no test suite has run on them.
