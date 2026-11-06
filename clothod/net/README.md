# clothod-net

clothod's tailnet sidecar (PLAN.md, "Built-in Tailscale"; Phase 0). It is a userspace Tailscale
node (`tsnet`, tailscale.com v1.104.5) in its own pure-Go program. The Go runtime never runs
inside clothod (decision 1), and the node survives serve upgrades. It lets the user's own tailnet
devices reach this machine's clothod without SSH. Nothing in clothod uses it yet: Phase 2 adds
`clothod login` and the tailnet transport to docs/protocol.md.

## Commands

```sh
clothod-net login                # prints auth_url=<URL>; open it, then state=Running, name=, ip=
clothod-net status               # JSON: state, auth_url, name, IPs, user, key expiry, ...
clothod-net serve --port N       # accept on the node's tailnet addresses, port N, only
clothod-net dial HOST:PORT       # tests: join (ephemeral), pipe stdin/stdout to HOST:PORT
clothod-net version
```

`clothod-net --help` lists the flags. These matter most:

- **State** goes in `<state dir>/tailnet/` (mode 0700). The state dir is `--state-dir`, else
  `$CLOTHOD_STATE_DIR`, else clothod's own (`~/Library/Application Support/clothod`,
  `~/.local/state/clothod`). The dir holds `tailscaled.state` (the node's keys), a `lock` that
  one process holds while it runs the node, and `net.sock`. `status` and `login` ask the process
  that runs the node through `net.sock`. When no process runs the node, they start it themselves.
- **Name**: `clothod-<host>` (decision 7). Dev builds (`build-net.sh --dev`) and test instances
  use `clothod-<host>-dev`. `--hostname` overrides it.
- **Log upload is off** (decision 8). The builds use `-tags ts_omit_logtail`, and `main`
  calls `envknob.SetNoLogsNoSupport()` before anything starts.
- **Test instances never reach Tailscale.** With `--ephemeral[=SECS|exit]`, or with
  `$CLOTHOD_EPHEMERAL` set as clothod's tests set it, clothod-net refuses to start unless it has
  `--control-url` (or `$CLOTHOD_NET_CONTROL_URL`) and its own `--state-dir`. It passes
  `--ephemeral` on to the clothod it starts. Without a control URL a node uses
  `https://controlplane.tailscale.com`; `$TS_CONTROL_URL` is ignored.
- `--ephemeral-node` registers an ephemeral node. Control deletes it soon after it goes offline,
  and a clean exit logs it out, so the next start needs a new sign-in. `dial` always registers
  an ephemeral node. Test instances don't by default, because they only ever join testctl,
  which keeps nothing.

## serve: the peer check and the relay

For each connection, before reading a byte:

1. **WhoIs** the remote address through the node's LocalAPI.
2. **Allow only the node's own user** (decision 10). The peer's `UserProfile.ID` and `Node.User`
   must equal this node's `Self.UserID`. Login names are never compared. A tagged peer is
   refused, because tagged nodes have no user identity. A peer shared in from another tailnet
   (`Node.Sharer` set) is refused. While this node is tagged, or not signed in, every peer is
   refused.
3. A refused connection is **closed without a word**. The log says why (`refused <addr>: ...`).
4. Otherwise clothod-net connects to clothod's socket, which it learned from `clothod status
   --print-socket` at startup. If clothod doesn't answer, it runs `clothod start --quiet` first,
   as `clothod bridge` does, so a killed or stopped serve comes back on the next connection. It
   then copies bytes both ways until either side closes, then closes both.

The listener is tsnet's, in its userspace network stack, so it never binds a port on the
machine's own interfaces. clothod is `--clothod PATH`, else the `clothod` next to this binary,
else `$PATH`. `--runtime-dir` is passed on to clothod.

Clients speak the normal protocol (docs/protocol.md) over the TCP connection, starting with
`hello`, exactly as over `ssh host clothod bridge`.

## testctl: the offline test tailnet

`testctl/` runs Tailscale's `tstest/integration/testcontrol` with a DERP and a STUN server, all
on 127.0.0.1. Nothing in it talks to Tailscale. The tests here use it in process, and other
roles can use it too.

In Go:

```go
s, err := testctl.Start(t, testctl.Options{RequireAuth: false})
// s.URL is the control URL; give it to tsnet.Server.ControlURL or --control-url
```

Standalone (for the Mac and iOS tests):

```sh
clothod/scripts/build-net.sh --testctl macos-aarch64   # target/net/macos-aarch64/testctl
testctl [--addr 127.0.0.1:0] [--require-auth] [--exit-with-stdin] [-v]
# stdout: control_url=http://127.0.0.1:<port>   (then logs on stderr until SIGTERM/SIGINT,
#                                                or stdin EOF with --exit-with-stdin)
```

Each node's identity comes from the hostname it registers with:

| Hostname | User | Tags / sharer |
|---|---|---|
| anything else | user A (the first such node's user ID) | none |
| `other-*` | user B | none |
| `tagged-*` | user A's ID | `tag:clotho-test` |
| `shared-*` | user A's ID | `Sharer` = user B |

A node that advertises tags gets those tags. Tagged and shared nodes keep user A's ID on
purpose: a check that compared users alone would let them in.

With `--require-auth`, a new node's AuthURL is `<control URL>/auth/<id>`, and a plain GET of it
signs the node in, the way a browser visit does on the real service. That makes it usable with
`ASWebAuthenticationSession` or `curl`. `GET /testctl/nodes` lists the nodes as JSON. Nodes are
named `<hostname>.clotho-test.ts.net`.

On macOS, in-process tsnet nodes in tests should call `netns.SetEnabled(false)`. Tailscale's own
tests do this, so nodes don't bind to the default interface.

## Build and test

```sh
clothod/scripts/install-go.sh          # once per machine: the pinned Go in ~/.local/share/go
clothod/scripts/build-net.sh           # target/net/<os>-<arch>/clothod-net, all four, CGO_ENABLED=0
clothod/scripts/go test ./...          # needs a clothod: cargo build --bin clothod (or CLOTHOD_BIN)
CLOTHOD_NET_MEASURE=1 clothod/scripts/go test -run Measure -v .   # time to Running, RSS
```

The tests run real `clothod-net` and `clothod` processes against an in-process testctl. They use
ephemeral clothod instances in `/tmp/clt-net.*`, and nothing else on the machine. `test-all.sh`
runs them on macOS and on the Linux host, and its cleanliness check fails on any test sidecar,
testctl or `net.test` left running. `CLOTHOD_NET_BIN` tests a prebuilt sidecar.

All four builds are pure Go and cross-build from any host. The macOS ones carry the Go linker's
ad-hoc signature. `CLOTHOD_SIGN_IDENTITY` signs them on a Mac, as `dist.sh` does. Nothing ships
this binary yet (decision 11).
