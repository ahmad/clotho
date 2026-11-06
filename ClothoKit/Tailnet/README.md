# ClothoTailnet

Clotho's own tailnet node for the apps (PLAN.md, "Built-in Tailscale", decisions 2, 3, 4, 7 and 8; Phase 0).
It is a small Go shim over `tailscale.com/tsnet` (v1.104.5, the same pin as `clothod/net`), built as a static
library and wrapped for Swift. Each app is then its own userspace node in the user's tailnet: no system VPN,
and a browser sign-in once per device.

This is a SwiftPM package of its own, next to ClothoKit, not a target inside it. ClothoKit's core target, the
iOS extensions that link it, and every build that doesn't need the tailnet never see the Go runtime, and they
don't need the xcframework to exist. Only this package fails to load without it.

| Path | What |
|---|---|
| `go/` | The shim: `clotho_tailnet.h` (the C API), `shim.go`, `store.go`, `dial.go`; `cmd/tailnet-testpeer` (tests only) |
| `../scripts/build-tailnet.sh` | Builds the xcframework into `build/` (gitignored) |
| `Sources/ClothoTailnet` | `TailnetNode`, `TailnetTransport`, `TailnetProxyServer`, `TailnetStateStore` |
| `Sources/TailnetFdPass` | Unix-socket and `SCM_RIGHTS` helpers (C, no Foundation) |
| `Sources/clotho-tailnet-proxy` | ssh's `ProxyCommand` for `ProxyUseFdpass` |
| `scripts/test.sh` | The tests, offline |

## Build

On a Mac with Xcode (the build Mac):

```sh
scripts/clotho-build mac ClothoKit/scripts/build-tailnet.sh                 # build/ClothoTailnet.xcframework
scripts/clotho-build mac ClothoKit/scripts/build-tailnet.sh --slices "macos-arm64"
scripts/clotho-build mac ClothoKit/scripts/build-tailnet.sh --clean         # remove it, and Go's caches
```

- **Go** is the pinned toolchain from `clothod/scripts/install-go.sh`. The script sources
  `clothod/scripts/toolchain.sh`, so `GOCACHE`, `GOMODCACHE` and `GOPATH` live in `clothod/target/go`,
  where `clothod/scripts/build-space.sh clean` (and `--clean` here) removes them. The script refuses to
  build when `go/go.mod` and `clothod/net/go.mod` pin a different Go or `tailscale.com`. Bump both together.
- **Flags**: `-buildmode=c-archive -trimpath -buildvcs=false -tags ts_omit_logtail`, with Xcode's clang and the
  SDK's sysroot. The node reports `tailscale.com`'s own version (`1.104.5-clotho`), never this repo's commit.
- **Slices** (default): `macos-arm64` (min macOS 13.0), `ios-arm64` (iOS 17.0) and `iossim-arm64` (iOS 17.0
  simulator). `macos-x86_64` and `iossim-x86_64` build on request; slices of one platform are combined with
  lipo. Each slice is about 25 MB of static library. `build-tailnet.sh` prints each one's size and its
  `vtool` platform and min OS.
- `build/` is excluded from `scripts/clotho-build`'s sync, so each mirror builds its own xcframework.

## The C API (`go/clotho_tailnet.h`)

`ctn_start` (returns at once), `ctn_status_json`, `ctn_login_interactive`, `ctn_logout`, `ctn_dial`,
`ctn_whois`, `ctn_close` (returns at once) and `ctn_free`. The header documents each call. In short:

- Returned strings are malloc'd; free them with `ctn_free`. On failure, `*err` gets a malloc'd message.
- `ctn_start` takes a node dir (absolute; created 0700), a hostname, a control URL (empty means
  Tailscale's), `ephemeral` and `test_mode`. It also takes optional callbacks: a state store (read/write),
  `on_state` (JSON `{"BackendState", "AuthURL", "Expired"}`), `log` and `on_closed`.
- `test_mode` turns off the port mapper and netns binding. It is refused unless the control URL is
  loopback or `localhost`, the same rule as `clothod-net`.
- `ctn_dial` returns one end of an AF_UNIX socketpair (close-on-exec, `SO_NOSIGPIPE`). The shim relays it
  to the tailnet connection, passing half-closes through. It retries while the node starts or the peer
  isn't known yet, and fails at once on a refused connection.
- `ctn_close` never blocks. tsnet's `Close` can hang for minutes (tailscale/tailscale#21353), so it runs on
  a background goroutine. `on_state` and `log` stop at once. The store can still be called until
  `on_closed`, which runs once when the shutdown has finished; after it, no callback runs again. If the
  shutdown hangs, `on_closed` never comes and `ctx` must stay alive.
- **Process-wide effects:**
  - Log upload is off: `envknob.SetNoLogsNoSupport()` in `init`, plus the `ts_omit_logtail` tag.
  - The Hostinfo app is `clotho`.
  - `TS_LOGS_DIR` is set to the dir of the node started last, so `~/.local/share/tailscale` is never
    created.
  - Test mode's switches stay on for the rest of the process.

## The Swift API (`ClothoTailnet`)

```swift
let node = TailnetNode(configuration: .init(
    dir: nodeDir, hostname: TailnetNode.defaultHostname(device: "Ahmad's iPhone", dev: false),
    controlURL: nil, ephemeral: false, testMode: false, store: keychainStore))
node.onStateChange = { state in ... }    // .stopped .starting .needsLogin(URL?) .needsMachineAuth .running .expired
try node.start()                         // returns at once
let url = try await node.login()         // nil: already signed in
let status = try await node.status()     // backendState, selfNode (userID, IPs, ...), peers, users
let who = try await node.whois("100.64.0.2")
let fd = try await node.dial(host: "100.64.0.2", port: 22)   // the caller closes it
let stream = try await node.dialStream(host: ip, port: 7443) // a ClothoKit ByteStream
node.stop()                              // returns at once
node.waitForClose(timeout: 10)           // true once the background shutdown finished
```

- Calls that wait run on a private concurrent queue, never on the caller's thread. Calls after `stop()`
  throw `TailnetError.stopped`.
- `TailnetTransport(node:host:port:)` is a `ClothodTransport`. `ClothodBackend` speaks the protocol to
  `clothod-net serve --port N` over it, with no SSH in between.
- `TailnetProxyServer(node:socketPath:)` (macOS) serves `clotho-tailnet-proxy`. The socket is 0600 in a
  0700 dir, and it accepts only clients with the same uid (`getpeereid`). A client writes `HOST PORT\n`
  and gets the connected socket back by `SCM_RIGHTS`, or `error <why>\n`.
- `clotho-tailnet-proxy --socket PATH [--timeout SECS] HOST PORT` is ssh's
  `ProxyCommand` with `ProxyUseFdpass=yes`. macOS's `/usr/bin/ssh` (OpenSSH 10.5p1) supports it. The
  helper hands ssh the descriptor and exits, so no bytes pass through it. It has its own deadline
  (default 10 s), because ssh's `ConnectTimeout` doesn't bound a `ProxyUseFdpass` handoff. On failure it
  exits 255 and prints `clotho-tailnet-proxy: <why>`. It is a separate binary, so each ssh doesn't start
  Clotho and its Go runtime.

The Mac app uses all of this only in its dev build's Tailnet Test window (`mac/README.md`, "Tailnet test").

## Tests

```sh
scripts/clotho-build mac ClothoKit/Tailnet/scripts/test.sh            # all
scripts/clotho-build mac 'ClothoKit/Tailnet/scripts/test.sh --filter SSHProxyTests'
(cd clothod && . scripts/toolchain.sh && cd ../ClothoKit/Tailnet/go && go vet ./... && go test ./...)  # the shim's Go test (any OS)
```

`scripts/test.sh` builds whatever is missing:
- the xcframework;
- `testctl` and `clothod-net` (`clothod/scripts/build-net.sh --dev --testctl`);
- the test peer;
- the helper.

It then runs `swift test` in one `/tmp/cmac-tn.*` dir. At the end it removes that dir and kills every
process that used it, and fails if any test process is left running.

The suites:
- `TailnetNodeTests` and `TailnetLoginTests`: Running, WhoIs of the same and of a second user, logout,
  `stop()` in under 50 ms, interactive login, restart from saved state (files, and a store), refusals,
  and nothing written outside the node dir.
- `ClothodOverTailnetTests`: `clothod-net serve` fronts an ephemeral clothod, and `ClothodBackend`'s
  hello and a request succeed over `TailnetTransport`.
- `SSHProxyTests`: `/usr/bin/ssh` with the helper reaches this Mac's sshd through a test peer that
  forwards its tailnet port 22. It reads the `SSH-2.0` banner without offering any key, so `~/.ssh` is
  never read or changed. Also: the helper's deadline, and dial errors.

Everything runs against clothod's offline `testctl` (`clothod/net/README.md`). Test nodes refuse any
control URL that isn't loopback. Nothing joins a real tailnet or uses a Tailscale account.

## For the iOS app

- **Slices:** `ios-arm64` and `iossim-arm64`, min iOS 17.0. There is no x86_64 simulator slice; add one
  with `--slices` if a runner needs it. Run `ClothoKit/scripts/build-tailnet.sh` in the ios mirror before
  building: the xcframework is in this package's `build/`, which isn't synced or committed.
- **Linking:** add the local package `ClothoKit/Tailnet` to `ios/project.yml` and link the
  `ClothoTailnet` product into the Clotho app target only. Never link it into ClothoNotify or
  ClothoWidget: the core `ClothoKit` product stays Go-free for them.
- **State:** back `TailnetStateStore` with the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
  The contract is in `TailnetStateStore.swift`:
  - Calls come on the shim's threads, one at a time, and must be thread-safe and quick.
  - Keys are tsnet's state keys.
  - `read` returns nil for a missing key; `write(nil)` deletes.
  - The store must stay usable until `waitForClose` reports the shutdown finished.
- **Dialing:** hand `dial`'s fd to NIO with `ClientBootstrap.withConnectedSocket(_:)`.
- **Suspension:** the likely strategy for #21353 (the node dies after about 30 s locked) is to `stop()`
  without waiting, then start a new `TailnetNode` on the same store. Starting again before the old
  shutdown finished can race on the state, so check `waitForClose(timeout:)` first, or accept the race.
- **Builds:** extend `ios/scripts/sources-sha.sh` to cover this package (`Package.swift`, `Sources/`,
  `go/`) and `ClothoKit/scripts/build-tailnet.sh`.
