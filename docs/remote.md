# Remote machines: probe, install, bridge

Status: **draft v1** (2026-10-26). This is the reference for how a client (the Mac app,
`clotho --host`, later iOS over SwiftNIO SSH) runs sessions on another machine. The client needs
nothing on the remote side except an SSH login and a POSIX `sh`. It installs and upgrades
clothod itself.

```
client ──ssh──▶ sh probe script        (1) what's there?
client ──ssh──▶ sh install script      (2) upload the right build, if missing
client ──ssh──▶ clothod bridge         (3) speak docs/protocol.md over the SSH channel's stdio
```

Each step is a separate SSH exec channel. Over one multiplexed connection (OpenSSH
`ControlMaster`, or one SwiftNIO SSH connection with several channels), steps 1–3 cost one
handshake. Run the remote commands with no PTY (`ssh -T`, or an exec channel without
`pty-req`), because the bridge's stdio carries binary frames.

## Builds a client carries

| `os`-`arch` (from the probe) | Rust target | file in `dist/` |
|---|---|---|
| `macos-aarch64` | `aarch64-apple-darwin` | `macos-aarch64/clothod` |
| `macos-x86_64` | `x86_64-apple-darwin` | `macos-x86_64/clothod` |
| `linux-x86_64` | `x86_64-unknown-linux-musl` (static) | `linux-x86_64/clothod` |
| `linux-aarch64` | `aarch64-unknown-linux-musl` (static) | `linux-aarch64/clothod` |

`clothod/scripts/dist.sh` builds all four plus `dist/manifest.json`:

```json
{"version": "0.1.0",
 "builds": {"linux-x86_64": {"target": "x86_64-unknown-linux-musl", "id": "0.1.0-852088b10acc",
                             "size": 3642664, "file": "linux-x86_64/clothod"}, ...}}
```

`id` is the **install id**, `<version>-<hash>`, where the hash comes from the file's bytes.
`clothod build-id [FILE]` computes it. A build is installed when `<base>/<id>/clothod` exists.
Bundle the whole `dist/` directory.

### Build hosts

Releases and `test-all.sh` run on imac (`macbook@imac`, always on), through
`CLOTHO_MAC=macbook@imac clotho-mac <cmd>`, which mirrors the clone into `~/Builds/clotho-clothod`.
The toolchain lives in the `macbook` account only. Nothing is installed system-wide, and no
dotfile was edited:

- rustup in `~/.cargo` and `~/.rustup` (minimal profile, installed with `--no-modify-path`).
  `clothod/rust-toolchain.toml` pins the rustc that every machine builds with, and its four
  targets. rustup installs that version on first use.
- zig from ziglang.org, checked against the published sha256, in
  `~/.local/share/zig/<release>`, with `~/.local/share/zig/current` linked to it.
- `cargo-zigbuild` in `~/.cargo/bin` (`cargo install --locked`).

A non-interactive `zsh -lc` reads no profile there, so `dist.sh` and `test-all.sh` source
`scripts/toolchain.sh`, which puts those dirs on `PATH`.

Signing: when `~/Library/Keychains/clotho-build.keychain-db` and
`~/.config/clotho/build-keychain-pw` both exist, `dist.sh` unlocks that keychain and signs from it
with `codesign --keychain`. Otherwise, as on macbook, it uses the login keychain, which the caller
unlocks.

In `test-all.sh`, devbox is the Linux host, and the remote suite runs against `ahmad@devbox` and
`ahmad@macbook`. macbook is a laptop: when it doesn't answer ssh, its remote run is skipped and
the summary says so. Every other unreachable host is a failure. The build Mac never tests
against itself.

## 1. Probe

Run this script with `sh -s` (script on stdin) or `sh -c '<script>'`. It only reads, apart from a
harmless `mkdir -p` of the install base to test writability. It prints `key=value` lines, and the
value runs to the end of the line and may contain spaces.

```sh
echo "clothod-probe=1"
os=$(uname -s); arch=$(uname -m)
case "$os" in Linux) os=linux ;; Darwin) os=macos ;; *) os=$(echo "$os" | tr 'A-Z' 'a-z') ;; esac
case "$arch" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; esac
echo "os=$os"
echo "arch=$arch"
if [ -n "${CLOTHOD_INSTALL_DIR:-}" ]; then base=$CLOTHOD_INSTALL_DIR
elif [ "$os" = macos ]; then base="$HOME/Library/Application Support/clothod/bin"
else base="${XDG_DATA_HOME:-$HOME/.local/share}/clothod/bin"; fi
echo "base=$base"
installed=""
for d in "$base"/*/; do n=$(basename "$d"); [ "$n" != current ] && [ -x "${d}clothod" ] && installed="$installed $n"; done
echo "installed=${installed# }"
if [ -n "${CLOTHOD_RUNTIME_DIR:-}" ]; then rt=$CLOTHOD_RUNTIME_DIR
elif [ "$os" = macos ]; then rt="$(getconf DARWIN_USER_TEMP_DIR)clothod"
else rt="/tmp/clothod-$(id -u)"; fi
echo "runtime=$rt"
pid=$(cat "$rt/clothod.pid" 2>/dev/null)
if [ -S "$rt/clothod.sock" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  echo "daemon=running"
  echo "daemon_pid=$pid"
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || ps -o comm= -p "$pid" 2>/dev/null)
  echo "daemon_exe=$exe"
else
  echo "daemon=stopped"
fi
if mkdir -p "$base" 2>/dev/null && [ -w "$base" ]; then echo "writable=yes"; else echo "writable=no"; fi
```

The canonical copy is `PROBE_SCRIPT` in `clothod/crates/cli/src/remote.rs`. Keep the two in
sync.

- Pick the build `<os>-<arch>` from your `dist/`. If there is none (for example `freebsd`), tell
  the user the machine isn't supported.
- **One version per host.** If anything is installed, use `<base>/<current>/clothod` (the
  probe's `current`), whatever version it is, and skip to step 3. Install (step 2) only when
  `installed` is empty, and then run `'<path>' install` to make it `current`.
- To move a host to the bundled build (the user agreed, and it is a higher version), upload it
  with step 2 if it isn't there, then run `'<path>' upgrade` on the host. That is all or
  nothing: serve switches, the holder upgrades in place (shells kept), and the old version is
  deleted. If it fails, the host is rolled back to the old version and the new one is removed.
  Exit 3 means the holder is incompatible. Afterwards `installed` lists exactly one id.
- The probe also reports `current`, `daemon_build`/`holder_build` (what runs, from the daemon
  itself), `holder_pid` and `holder_exe`. A host is on exactly one version when
  `installed == [current]` and `daemon_build == holder_build == current`.
- `daemon_exe` tells you which build is running. A different id means step 3 will upgrade the
  logic process (see below).
- `CLOTHOD_INSTALL_DIR` and `CLOTHOD_RUNTIME_DIR` exist for tests and unusual setups. Pass the
  same values to every step, as `env VAR=value ...` in front of the command.

## 2. Install (only if missing)

Run this with the binary on stdin and the id and base as arguments:
`sh -c '<script>' sh '<id>' '<base>'`.

```sh
set -u
id=$1; base=$2
d="$base/$id"
t="$d/.clothod.$$.tmp"
mkdir -p "$d" 2>/dev/null || { echo "clothod-install: cannot create $d" >&2; exit 5; }
trap 'rm -f "$t"' EXIT
cat > "$t" || { echo "clothod-install: cannot write $t (disk full or read-only?)" >&2; exit 5; }
chmod 755 "$t" || exit 5
got=$("$t" build-id 2>/dev/null) || { echo "clothod-install: the uploaded binary does not run here (wrong platform, or noexec mount)" >&2; exit 4; }
[ "$got" = "$id" ] || { echo "clothod-install: uploaded binary is $got, expected $id (truncated upload?)" >&2; exit 4; }
mv -f "$t" "$d/clothod" || exit 5
trap - EXIT
echo "installed=$d/clothod"
```

Canonical copy: `INSTALL_SCRIPT` in `crates/cli/src/remote.rs`.

| exit | meaning | client action |
|---|---|---|
| 0 | installed; prints `installed=<path>` | continue |
| 4 | the binary doesn't run there or is corrupt | retry once; if it fails again, show stderr (wrong platform or `noexec`) |
| 5 | can't write: no permission, read-only, or disk full | if `base` was the default, retry once with `base="${TMPDIR:-/tmp}/clothod-bin-$(id -u)"`, then show stderr |

- **Concurrent installs** (two clients at once) are safe. Each uploads to its own temp file and
  `mv` is atomic. The last one wins with identical bytes, and a reader never sees a partial
  binary.
- The upload must be the exact `dist/` file. Its id is checked by running it, which also catches
  wrong-architecture and `noexec` mounts before anything is replaced.
- Old builds stay on disk. `clothod install --prune` (run on the remote) deletes the ones no
  running daemon or holder uses.

## 3. Bridge

```sh
env [CLOTHOD_RUNTIME_DIR=...] '<base>/<id>/clothod' bridge
```

Quote the path, because the macOS base contains a space. The command starts the daemon if needed
(as `clothod start` does), then relays the channel's stdin and stdout to the daemon socket byte
for byte. From then on, stdout carries exactly the protocol in `docs/protocol.md`, starting with
your `hello`. Everything human-readable goes to stderr.

- **Exit code 3** before any output means the remote's running holder can't be driven by this
  build (see protocol.md, "Starting and upgrading"). stderr has the explanation. The shells are
  untouched. Offer "restart sessions on <host> to finish upgrading", which runs
  `env ... '<path>' shutdown` (ending every shell there) and then reconnects, or offer to use the
  build the remote is running (`daemon_exe`).
- Any other non-zero exit before your `hello` gets a reply is a startup failure. Show stderr.
- **Upgrades** go through `'<new path>' upgrade` (above), never `stop` + `start` by hand:
  something else, such as an app reconnecting, could revive the old build in between.
- **The daemon dies under the bridge** (crash, kill -9, `stop`): the bridge flushes what it
  has, then exits at once with **code 2**, so the SSH channel closes and the client sees EOF
  immediately. Reconnect (step 3). The new bridge's `start` brings the daemon back, and it adopts
  the holder, so the same `instance` and shells come back. Keep a heartbeat (`ping`) only as a
  backstop for network stalls.
- **Disconnects:** when SSH drops, the bridge sees EOF and exits. The daemon and the shells keep
  running. Reconnect from step 3 (the probe can be skipped if nothing changed) and resubscribe
  with `have_seq`, as described in protocol.md.

### Keeping sessions alive after logout

The daemon detaches into its own session (`setsid`) and doesn't depend on the SSH session that
started it. That is enough on Linux with logind's default `KillUserProcesses=no`; macOS needs
more (below).
If a Linux machine sets `KillUserProcesses=yes`, clothod starts itself as a transient systemd
user unit (`systemd-run --user`) instead, outside the session scope. That survives logout only
with lingering enabled (`loginctl enable-linger $USER`), and `clothod start`/`bridge` print a
warning on stderr when it's off. Clients should show that warning once per host.
**Unverified:** the `KillUserProcesses=yes` path hasn't been tested on a real machine yet. The
test hosts use the default. Logout survival with the default is covered by the e2e tests.

The runtime dir lives in temp space, which cleaners prune by age (systemd-tmpfiles, and macOS
after a few days without access). The daemon and holder touch their files hourly and rebind a
deleted socket within 10 s, or at once on `SIGUSR1`. `clothod start`/`bridge` find a running
instance through `<state dir>/clothod.live` and `holder.live` and signal it instead of starting
a second one. So a deleted runtime dir costs nothing.

### macOS sessions

On macOS a process started from an SSH session lives in that session's launchd bootstrap
namespace (`launchctl managername` says `Background`). When that namespace is torn down,
everything still running in it loses the system services it reaches through it:
- DNS (`scutil --dns`: "No DNS configuration available");
- user lookups (`id -un` prints a number);
- TLS trust (curl and git fail);
- the keychain (`gh` reads its token from there).

A daemon started that way would pass all of this on to the holder and every shell. So since
0.1.24, `clothod start` (and with it `bridge`'s autostart and `upgrade`) checks its own
namespace:
- **In the login session (`Aqua`)**, for example when the app or the login unit starts it: it
  detaches serve as on Linux.
- **In another namespace, with someone logged in at the Mac** (`gui/<uid>` exists): it
  bootstraps a one-off launchd job into `gui/<uid>`.
  - The job runs `clothod spawn-serve`, which detaches serve inside the login session and
    exits.
  - `start` waits for the socket, then boots the job out and deletes its plist, also on failure
    or timeout. The plist sits in the state dir.
  - The job has `KeepAlive` false and `AbandonProcessGroup` true, the same as the login unit.
    Booting it out leaves serve running.
  - Its label is unique per attempt (`nyc.amin.clotho.clothod.start.<pid>.<time>`), never the
    login unit's.
  - The job gets the `CLOTHOD_*`, `PATH`, `SHELL`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_*` and
    `TMPDIR` variables, and nothing of the SSH session's own (such as `SSH_AUTH_SOCK`).
- **In another namespace, with nobody logged in at the Mac**: without root, no durable domain is
  reachable. Bootstrapping into `user/<uid>` and `launchctl asuser` both need root. `start`
  detaches serve as before and prints a warning. When the user later logs in at the Mac, the
  login unit's `clothod start` (running in `Aqua`) finds the daemon's serve in another
  namespace and restarts serve there (`daemon.stop`, then start). The holder and shells stay,
  still in the old namespace.

The holder is spawned by serve, and every shell by the holder, so they inherit serve's
namespace. A holder keeps the namespace it was started in for life, including across in-place
upgrades. Only a restart (`clothod shutdown`, then start; the layout and agents are restored)
moves it. `hello` reports `namespace` for serve and `holder.namespace` for the holder and its
shells, and `clothod ps` shows them (`launchd: Aqua`). Clients can warn when the holder's isn't
`Aqua`.

### Socket location

The runtime dir is `/tmp/clothod-<uid>` on Linux and `<per-user temp dir>/clothod` on macOS.
On the remote, `'<path>' status --print-socket` prints it, and the probe prints it as `runtime`.
On Linux it is deliberately not `$XDG_RUNTIME_DIR`: that variable is unset in non-interactive SSH
sessions, and logind removes the directory at logout when lingering is off. Either would give a
login shell and the bridge different daemons. The directory must be owned by the user and is
made mode 0700; otherwise clothod refuses to use it.

## Errors to surface (summary)

| where | signal | show |
|---|---|---|
| SSH | can't connect or authenticate | ssh's own message |
| probe | no `clothod-probe=1` line | "not a POSIX shell host" plus output |
| probe | `<os>-<arch>` not bundled | "unsupported platform" |
| install | exit 4 / 5 | stderr (after the retries above) |
| bridge | exit 3 | "restart sessions to finish upgrading" |
| bridge | other exit before `hello` | stderr |
| bridge | stderr line starting `clothod: warning:` | show once (for example logout survival) |
