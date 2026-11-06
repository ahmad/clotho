# Built-in Tailscale research

Research only (user, 2026-11-06): nothing has been built.


Inputs: three code maps (clothod, ClothoKit/mac, iOS) and three research reports (the libtailscale API, Rust/Go builds, accounts and product). I spot-checked a few code references myself, read-only. Two skeptic agents then checked 16 load-bearing claims against primary sources (section 8). PLAN.md's section is at **PLAN.md:562-585** (the task said 555-578). Go is **not installed on the dev box** today (`which go` returns nothing). The last x86_64 musl clothod build in the dev box's target/ is 6.2 MB (6,196,696 bytes, Oct 27).

---

## 1. Bottom line

**The direction holds up.** Each app and each clothod would be its own userspace tsnet node in the user's own tailnet, with a browser sign-in, no VPN entitlement and no coordination server of ours. User-owned devices are free and unlimited on the Personal plan, so the "extra device per install" costs nothing. Three parts of PLAN.md:562-585 should change before work is handed out:

| PLAN says | Research finding | Recommended change |
|---|---|---|
| clothod calls libtailscale from Rust over FFI | clothod is one binary: serve, the PTY holder and the CLI (`clothod holder` is a subcommand, main.rs:123). A Go c-archive starts its runtime from a global constructor in **every** process, including the holder that owns every shell and each hook's `clothod report`. Go c-archive inside static musl crashes at startup (golang/go#13492 is open, the fix PR #69325 is stalled). tokio's signal handlers (signal-hook-registry 1.4.8) don't set SA_ONSTACK, which Go requires (tokio#3520 is open). Linking Go also raises clothod's macOS floor to 13. | **Use a separate Go sidecar for clothod** (working name `clothod-net`): a pure-Go tsnet program that accepts tailnet connections, runs WhoIs, then relays to `clothod.sock` the way `clothod bridge` does (main.rs:624-656). This removes the FFI, musl, signal and holder risks. The node survives serve upgrades, and the control plane's `os.Exit` (controlclient direct.go:1404-1408) can only kill the sidecar. |
| Swift calls "libtailscale" | The upstream C API is about 17 functions. It has **no WhoIs, no login-URL call, no state-store hook, no logout and no log-upload switch**. TailscaleKit (Swift) is Xcode-only, has no Package.swift, targets iOS 18.1 / macOS 15 (Clotho uses 17 / 13), its OutgoingConnection can't read, and its IPN-bus masks fail against v1.104.1 (#21878). | **Write a small Clotho-owned Go shim** over `tsnet` (BSD-3), built as a c-archive with libtailscale's Makefile and clangwrap scripts as templates. It exports exactly what we need: start, status JSON, dial, login-interactive, logout, WhoIs, a callback state store, log upload off, and the app name. Don't use TailscaleKit. |
| Node state in the Keychain on Apple devices | Stock libtailscale only has `tailscale_set_dir` (`<dir>/tailscaled.state` holds the private keys). A Keychain store is possible only through the Go `Store` field, i.e. our shim. On the Mac the user's installs are ad hoc signed, so legacy Keychain ACLs change with every build and are likely to prompt. | **iOS: Keychain** through the shim's store callback (AfterFirstUnlockThisDeviceOnly, like KeyStore.swift:68-69). This keeps the node across reinstalls and avoids `clotho-iphone-1` orphans. **Mac: files** in `~/Library/Application Support/Clotho/tailscale` (0700) unless the user wants the Keychain. Edit the PLAN line. |

What the research **confirms**:
- The dial path fits Clotho. `tailscale_dial` returns one end of an AF_UNIX socketpair, close-on-exec since ac7ed43 (2026-10-29). It drops straight into `ByteStream(readFD:writeFD:)` (Transport.swift:24-43) and into NIO's `withConnectedSocket` on iOS.
- The login URL is readable by polling `tailscale_status_json` for `BackendState`/`AuthURL` after a non-blocking start.
- A "same Tailscale user" check is doable: compare WhoIs `UserProfile.ID` with the node's own `Self.UserID`, never `LoginName`, and refuse tagged peers.

What it **adds as new risk**:
- **iPhone suspension** (#21353, open): after about 30 s locked, the node's UDP receive loop dies and never recovers, and `Close()` was seen to hang for about 9.5 min. The likely fix is to recreate the node on foreground without waiting on close.
- **tsnet always uploads logs** to log.tailscale.com, and libtailscale has no off switch. This is a privacy and App Store item.
- **Size.** Third-party figures are about 19-25 MB per iOS slice, and +11-17 MB for a Linux Go binary with tsnet. The apps also bundle every clothod build, which multiplies any growth there.

**Go/no-go stays a Phase 0 measurement**, with the iPhone suspension behaviour as the deciding item.

---

## 2. How the connection works today

| Piece | Where |
|---|---|
| clothod listens only on a Unix socket `<runtime dir>/clothod.sock` via `HealingListener` | proto/src/listen.rs:29-246; runtime dir proto/src/platform/mod.rs:40-51 |
| Accept loop drops peers whose uid differs | clothod/src/daemon.rs:1201-1210 |
| No auth inside the protocol: first frame must be `hello` (version/features only) | daemon.rs:2632-2633, 2724-2756; docs/protocol.md:87-164 |
| Trust = socket peer uid, or SSH for bridge clients ("holding the socket is holding the account") | docs/security.md:8-22 |
| Remote machines: `ssh -T host '<path>/clothod' bridge`; bridge autostarts serve and copies stdio | cli/src/remote.rs:18-76, 302-347; clothod/src/main.rs:621-656 |
| Rust client is transport-generic: `Client::over(AsyncRead, AsyncWrite)` | cli/src/lib.rs:47-51 |
| Swift: `ClothodTransport.open() -> ByteStream` (fd pair). Backend (hello, heartbeat, reconnect) is transport-agnostic | ClothoKit Transport.swift:10-20, 24-104; ClothodBackend.swift:209-321 |
| Mac: `/usr/bin/ssh` child process (`SSHProcessTransport`); installer/probe over a shared ControlMaster; dev-only `SSHProxyCommand` hook already injects `-o ProxyCommand=` | Transport.swift:170-249; RemoteInstaller.swift:135-265; mac MachineConnections.swift:176-194 |
| iOS: in-process SwiftNIO SSH; the only socket creation is `ClientBootstrap.connect` | ios/Clotho/SSH/SSHSession.swift:56-111 (connect at :73, :99); SSHTransport.swift:49-70 |
| Reachability: whatever the OS network gives (LAN or system Tailscale); iOS errors tell users to run the Tailscale app | ios ConnectionCheck.swift:47-91 |
| serve is unsupervised (login unit runs `start` once, no KeepAlive/Restart=); upgrades stop+start serve, holder execs in place | clothod/src/service.rs:1-19; main.rs:726-855; holder/src/lib.rs:835-933 |
| Releases: 4 targets; Apple via cargo, Linux static musl via cargo-zigbuild; apps bundle all four | clothod/scripts/dist.sh:63-77; mac/build-app.sh:58-70; ios/project.yml:40-46 |

---

## 3. Phase 0, made concrete

**Goal.** Prove one app-to-machine dial over the tailnet on Mac and iPhone, measure size, memory and iPhone suspend behaviour, and prove the clothod sidecar shape. Each role touches only its own paths. ClothoKit changes go to the mac agent.

### Shared prerequisites (orchestrator)
- Install a pinned Go 1.27.1+ toolchain on **the dev box** (missing today) and on **the build Mac**, as a per-user install under `~/Builds/tools`, put on PATH the way `clothod/scripts/toolchain.sh` handles zig.
- Keep `GOCACHE` and `GOPATH` inside each role's mirror `target/` so `build-space.sh` cleans them (Mac disk rule; never `~/Library`).
- Pin `tailscale.com` to one version (v1.104.1 is what libtailscale dacde75 uses; v1.104.5 exists). Both shims use the same pin.
- **Before any real sign-in, ask the user** (see "Account use" below).

### clothod agent: the sidecar
| | |
|---|---|
| Files (new) | `clothod/net/go.mod` (with `toolchain` line), `clothod/net/main.go` (`clothod-net`: `login`, `status`, `serve --port`, `dial host:port` stdio mode for tests), `clothod/net/testctl/` (in-process `tstest/integration/testcontrol` + DERP for offline tests), `clothod/scripts/build-net.sh` |
| Files (edited) | `clothod/scripts/toolchain.sh` (Go on PATH), `clothod/scripts/build-space.sh` (Go caches). **No daemon changes in Phase 0.** |
| Build | The dev box: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64/arm64 go build -trimpath -ldflags='-s -w'`. Also try `GOOS=darwin` with CGO_ENABLED=0 from the dev box (**unverified that tsnet builds without cgo on darwin**). If that fails, build darwin on the build Mac. Sign the darwin builds on the build Mac with hardened runtime, as dist.sh:82-123 does. |
| Prove | Under testcontrol in `/tmp/clt*`: sidecar A fronts an `--ephemeral` clothod. Sidecar B in `dial` mode pipes stdio into `Client::over`, and `hello` succeeds. WhoIs via `LocalClient().WhoIs` accepts the same user and refuses a second test user and a tagged node. Kill and restart serve: the sidecar stays up and the next dial works. |
| Measure | Binary size per target, with and without `ts_omit_*` tags (netstack, acme, clientmetrics and serve tags break tsnet builds). Idle RSS and RSS after 100 dials. Time from start with existing state to Running. Join time. Whether log upload goes out (packet capture) before and after `logtail.Disable()`. |
| Optional | A one-day FFI spike (`clothod/crates/tailnet-ffi`, behind a cargo feature) only if the user wants FFI kept open. It would confirm or rule out the musl crash and signal issue. **Recommend skipping it.** |
| Cleanup | test-all's cleanliness check gains "no `clothod-net` processes and no testcontrol left over". |

### mac agent: the shim, ClothoKit and the Mac app
| | |
|---|---|
| Files (new) | `ClothoKit/Tailnet/go/` (shim: `start`, `status_json`, `dial`, `login_interactive`, `logout`, `whois`, `set_state_store(read_cb, write_cb)`, logtail off, Hostinfo app "clotho"), `ClothoKit/scripts/build-tailnet.sh` (c-archives: macOS arm64 [+x86_64 if wanted], iOS arm64, simulator arm64 [+x86_64]; `MACOS_TARGET=13.0`, iOS min 17.0; packaged as a static-library xcframework in a **gitignored** `ClothoKit/Binaries/`), `ClothoKit/Sources/ClothoTailnet/TailnetNode.swift` |
| Files (edited) | `ClothoKit/Package.swift`: `.binaryTarget` plus a new `ClothoTailnet` product. The core `ClothoKit` target stays Foundation-only, because both iOS extensions link it (push.yml:136-137, widget.yml:179-181). Mac dev build: a debug-only "Tailnet test" menu (sign in, dial `<peer>:22`, read the SSH banner). |
| Dial for ssh | Prototype a ProxyCommand helper. The app serves a 0700 Unix socket, and the helper receives the dialed fd by SCM_RIGHTS and hands it to ssh with `ProxyUseFdpass=yes`. Wire it through the **existing dev `SSHProxyCommand` hook** (MachineConnections.swift:190-193), so Phase 0 needs no routing code. (**Unverified**: that macOS's bundled ssh supports ProxyUseFdpass. Check it first. The fallback is a byte-copying helper.) |
| Build | The build Mac via `scripts/clotho-build mac ...` (needs Xcode clang). |
| Measure | Clotho executable size delta. Idle and active RSS. Linker min-OS warnings. Hardened runtime with the current empty entitlements. A notarization dry run on the build Mac, which is existing practice with notarytool. Whether ssh's ConnectTimeout bounds ProxyCommand setup. |

### ios agent
| | |
|---|---|
| Files | `ios/project.yml`: link `ClothoTailnet` into the **Clotho app target only**. New `ios/Clotho/Tailnet/TailnetNode` usage and a debug screen. `ios/Clotho/SSH/SSHSession.swift:56-111`: a dial-mode switch that calls `ClientBootstrap.withConnectedSocket(fd)`. Add a `PrivacyInfo.xcprivacy`; the research expects SystemBootTime and FileTimestamp reasons from the Go runtime (**to confirm on upload**). Add the shim pin and build script to `ios/scripts/sources-sha.sh`. |
| Build | The build Mac. First take a **baseline** IPA size with a `--no-upload` export, since today's size isn't recorded anywhere. |
| Prove | Sign in through `ASWebAuthenticationSession` (stays in-app, so the loopback isn't reclaimed). Dial `<machine>:22` and open a pane over SSH. Multiplex crashed adopting the fd with Citadel; Clotho uses raw swift-nio-ssh, so this is **untested**. The fallback is a one-shot 127.0.0.1 relay owned by the app. |
| Measure (physical iPhone; simulator won't show suspension) | Foreground RSS. Lock for 30 s, 5 min and 30 min, then foreground: does a dial work, how long it takes, and whether the node must be recreated. Recreate on the same state without a new login. Whether `Close()` hangs (run it off-thread and never wait). Cold background launch from a notification action to dial, inside the existing **20 s** budget (AlertActionRunner.swift:11). Thinned download size delta. Behaviour with the Tailscale VPN app also on. |

### Go/no-go criteria
These are **proposed thresholds, not measured figures**; the user should confirm them.
| Item | Proposed bar |
|---|---|
| Dial Mac → machine and iPhone → machine, SSH pane works | Must pass |
| iPhone after ≥5 min locked: usable connection after foreground | ≤10 s, UI never blocked (recreate-node strategy allowed) |
| Notification action, cold start, locked phone | Dial done with ≥8 s left of the 20 s budget |
| iOS thinned download growth | ≤30 MB (PLAN's own upper estimate) |
| clothod sidecar | Runs as static Linux binary on x86_64 and aarch64; survives serve restart; idle RSS measured and well under serve's 400 MB soak limit |
| Privacy | No traffic to log.tailscale.com with log upload switched off (packet capture) |
| Hygiene | Test runs leave no devices behind in any real tailnet |

If the iPhone bar fails while Mac and clothod pass, a reasonable fallback is Phase 1 and 2 for the Mac and clothod only, with the iPhone keeping the system-Tailscale path.

### Account use (the project rules require asking first)
Signing a test node into the user's tailnet is a new kind of change to their account, so **ask before doing it**. Ways to keep it clean:
1. **Automated tests: a local control server** (Tailscale's `tstest/integration/testcontrol` via `set_control_url` / `ControlURL`) in `/tmp/clt*`, `/tmp/cmac-*` and `/tmp/cki-*`. Fully offline, and it never touches Tailscale. Recommended for every automated test.
2. **Real-network device tests: a separate test tailnet**, a second free Tailscale account the user creates. Nothing lands in the user's own tailnet.
3. Or **ephemeral, pre-approved, untagged auth keys** in the user's tailnet. Nodes are removed 30-60 min after going inactive. Untagged keys carry the user's identity, so the same-user check works; tagged keys would fail it. Keys live outside the repo (e.g. `~/.config/clotho/`), and an auth key is ignored once state exists unless `TSNET_FORCE_LOGIN=1`.
Each test node gets a recognisable hostname (`clotho-test-<role>-<run>`), and cleanup scripts log it out.

---

## 4. Phase 1 and Phase 2 outlines

### Phase 1: the apps join (machines still run Tailscale and sshd)
- **ClothoKit (mac agent):** make `TailnetNode` a production singleton per app process.
  - States: NeedsLogin(url), NeedsMachineAuth (device approval), Starting, Running, Expired.
  - Also shows which account and tailnet the node joined.
- **Mac:**
  - The ProxyCommand helper becomes a real per-machine route. `sshMultiplexOptions`, `sshBridgeOptions` and `sshProxyOptions` change from static lets into per-machine functions (MachineConnections.swift:179-194). `SSH.options` (Files.swift:153-184) and SSHCheck's hard-coded args (Onboarding.swift:108-133) must use them too.
  - The helper is a new nested Mach-O: build-app.sh must ad hoc sign it, and notarize.sh must sign it before its nested check (notarize.sh:57-60). Alternative: run the Clotho binary itself as the helper through a CLI branch before NSApplication starts.
  - The bridge stays `ControlMaster=no`.
  - Sign-in UI goes in Settings > Machines and as an optional onboarding step. Add Machine offers a picker of tailnet peers. Machine records get a `via` field.
- **iOS:**
  - Add `network: .system | .tailnet` to Machine (Machine.swift:8-13, 65-67) and include it in `endpoint`, without changing the machine id: host-key TOFU is keyed by it (SSHSession.swift:283-301).
  - Hook the node into the scenePhase handler (ClothoApp.swift:28-38). On foreground, check health and recreate the node if needed, then `resumeAll`. Add a "Waiting for Tailscale" step.
  - Add a Settings section, new ConnectionCheck sentences, and wipe node state in UI-test clean state.
- **Both:** handle key expiry as an explicit "Sign in again" state. tsnet doesn't print a fresh URL by itself after expiry, so the app calls login-interactive.

### Phase 2: clothod joins (with the sidecar)
- **Sidecar lifecycle (clothod agent):**
  - `clothod login` runs `clothod-net login`, which prints the AuthURL and waits for Running.
  - The sidecar keeps node state in `<state_dir>/tailnet/` (0700 via `ensure_private_dir`, platform/mod.rs:107-120) and takes a lock so only one node owns the state.
  - It can be supervised (KeepAlive/Restart=) without fighting serve upgrades, because it isn't serve. It is restarted only when its own build changes.
  - Never on ephemeral instances unless a test control URL is set.
- **Accept path:**
  - The sidecar accepts on its tailnet address only (never OS interfaces).
  - It runs WhoIs before any byte is read, requiring `UserProfile.ID == Self.UserID`, read live, not cached. It rejects tagged, shared and unknown peers by closing without a frame.
  - Then it `start`s clothod and relays to `clothod.sock`, the way bridge does.
  - Serve needs no change for a first version. Later, the sidecar can pass the fd and the peer identity over a side channel, so logs and agent audit lines name the device; do not trust a client-supplied hello field for that.
- **Protocol (docs/protocol.md):**
  - Tailnet transport (port, same framing, refused peer closed silently).
  - A `tailnet` feature and hello fields for the node state.
  - `tailnet.status/login/logout/peers` methods, with logout and anything that widens access refused for tailnet clients.
  - Version and build fields that replace the SSH probe.
  - Later, upload plus a detached `upgrade` for SSH-less machines, which needs its own security review.
- **Apps:**
  - A `TailnetTransport: ClothodTransport` in ClothoKit, taking a dial closure so core stays Foundation-only.
  - Before dialing, it checks that the server peer's UserID equals our own.
  - Discovery from the status peer list (naming convention `clothod-<host>` plus a port probe). Machines are pinned by StableNodeID.
  - SSH stays for install and upgrade until protocol-level upgrade exists. AgentHooks and DaemonUpdates need protocol equivalents for tailnet-only machines.
- **docs/security.md (clothod agent, per its header at :4):**
  - New trusted class: peers of the same Tailscale user. Untrusted: other tailnet users (the default policy is allow-all across up to 6 users), tagged, shared, ACL mistakes.
  - New trust anchors: Tailscale's coordination server (Tailnet Lock mitigates) and any device signed in as that user, which now gets a shell without an SSH key.
  - Node state files are credentials and end up in backups.
  - Key expiry. Log upload and Hostinfo going to Tailscale.
- **docs/remote.md:** a section on reaching machines over the tailnet (discovery, first install still via SSH or manual), node DNS/TLS under the macOS Background launchd namespace (remote.md:209-248), and Go in "Build hosts".

---

## 5. Risks, ranked

| # | Risk | Severity | Mitigation / status |
|---|---|---|---|
| 1 | iPhone: node dies after ~30 s locked and doesn't recover; `Close()` can hang minutes (#21353 open); loopback LocalAPI goes stale (#20060) | High | Recreate the node on foreground, run closes off-thread and leak them if stuck, never use loopback on iOS. **Phase 0 decides.** |
| 2 | Go runtime inside the Rust daemon (FFI): musl c-archive crash (#13492), no SA_ONSTACK on tokio handlers (tokio#3520), Go in the holder and every `clothod report`, macOS floor raised to 13 | High if FFI | Avoided by the sidecar. |
| 3 | Security model change: same-user tailnet devices get shells without SSH keys; Tailscale control plane becomes a trust anchor | High (design) | WhoIs same-user by default, reject tagged and shared peers, client-side server check, security.md rewrite, Tailnet Lock recommended to users. |
| 4 | Log upload to log.tailscale.com with no libtailscale switch; control can `os.Exit` the host process | Medium | Corrected by verification: tsnet honours `TS_NO_LOGS_NO_SUPPORT=1` (set it from our own Go code, `envknob.SetNoLogsNoSupport()`, not a late C setenv), and the build tag `ts_omit_logtail` compiles logtail out. Confirm with a packet capture. The sidecar isolates clothod from `os.Exit`. Privacy label. |
| 5 | Size: about 19-25 MB per iOS slice (third-party); apps also bundle 4 clothod builds | Medium | Measure. Sidecar keeps clothod itself small; decide whether to bundle the sidecars in the apps. |
| 6 | App Store: ITMS-91053 privacy manifest (#20992); no confirmed App Store app embedding libtailscale; export compliance (`ITSAppUsesNonExemptEncryption` is NO, project.yml:71) | Medium | Privacy manifest; a test upload to check; review the encryption answer. |
| 7 | iOS extension memory | Low | The node lives only in the app; extensions don't link `ClothoTailnet`. |
| 8 | Key expiry (180 days default) takes nodes offline; re-login doesn't happen by itself | Medium | Explicit "sign in again" states; tell users how to disable expiry for clothod nodes. Tags avoid expiry but drop the user identity, so avoid them. |
| 9 | Build complexity: Go for 5+ slices, a pinned toolchain on two hosts, no upstream libtailscale releases, open C-layer fd and accept bugs (#21934, #22057, #21167) | Medium | Own shim (accept path isn't used in apps); sidecar uses pure Go `tsnet` (no C layer); pin and bump with tailscale.com releases. |
| 10 | Coexisting with a system Tailscale: two nodes per Mac/machine, `-1` name suffixes; iOS with the VPN app on is undocumented | Medium-low | Distinct names (`clotho-…`, `clothod-…`); Phase 0 test with the VPN on. |
| 11 | Device clutter: reinstalls with file state leave orphans; test nodes | Low-medium | Keychain on iOS; ephemeral or testcontrol for tests. |
| 12 | Upgrade in place | Low with the sidecar | Serve upgrades don't touch the node. Sidecar upgrades restart it (reconnect delay; the Linux figure is 1.4-2.3 s join, third-party). With FFI-in-serve, every upgrade would re-join the tailnet. |
| 13 | Device approval or Tailnet Lock users: new nodes stay unusable until approved or signed out of band | Low | Show NeedsMachineAuth or locked-out states with instructions. |
| 14 | ToS: Personal plan is non-commercial; no public brand guidelines | Low (unverified legally) | Use "Sign in with your Tailscale account" wording only, no logo; ask Tailscale if Clotho is ever sold. |

---

## 6. Decisions needed from the user

| # | Decision | Recommendation |
|---|---|---|
| 1 | clothod: Go **sidecar** (`clothod-net`) or FFI into the clothod binary as PLAN says | **Sidecar.** FFI hits the musl crash, signal risks and Go in the holder. Update PLAN.md:569-574. |
| 2 | Apps: our own small Go shim over tsnet, or upstream libtailscale/TailscaleKit as-is | **Own shim** (pinned, BSD-3). Upstream lacks WhoIs, a store, logout and a log switch. |
| 3 | Node state | **iOS: Keychain** (via shim), **Mac: files** in Application Support 0700 (ad hoc signing makes Keychain prompt). Edit PLAN.md's "Keychain on Apple devices". |
| 4 | Test accounts | **testcontrol** for all automated tests; for device tests, **a separate test tailnet** (a second free account you create). Alternative: ephemeral pre-approved untagged auth keys in your tailnet. Either way needs your go-ahead. |
| 5 | Are app nodes ephemeral? | **No.** Ephemeral nodes are deleted 30-60 min after going offline, which means a browser login after each long suspend. Only test and dev nodes are ephemeral. |
| 6 | Key expiry | **User-owned nodes** (not tags, which break the same-user check). Show "sign in again" in the apps and in `clothod status`, plus a hint to disable expiry for clothod nodes in the admin console. |
| 7 | Node names | `clotho-<device>` for apps, `clothod-<host>` for machines, `-dev` suffix for dev builds, so they never collide with the system node's `<host>`. |
| 8 | Log upload to Tailscale | **Off**: build with `ts_omit_logtail`, or set `TS_NO_LOGS_NO_SUPPORT` from Go in the shim and the sidecar. Note it is then off for Tailscale support too. |
| 9 | Phase 1 routing when the system Tailscale also runs | Per-machine choice. Machines picked from the in-app peer list use Clotho's node; existing machines keep today's path until changed. |
| 10 | Phase 0 iPhone device tests | These need your iPhone (no UI runs on the laptop Mac). Confirm when and on which device. |
| 11 | Shipping the sidecar (Phase 2) | Decide after Phase 0 sizes. Lean: bundle it in the Mac app, not in the iOS app. |
| 12 | First install on SSH-less machines | Phase 2 keeps SSH or a manual install for the first install; protocol-level upgrade is a later, separately reviewed item. |

---

## 7. What the research could not settle (Phase 0 must measure)
- iPhone: whether a dial works after suspension on v1.104.x, how long reconnects take, whether recreating the node on the same state avoids a new login, and how often `Close()` hangs. The cold notification-action path within 20 s.
- Real size deltas: iOS thinned download, the Mac executable (arm64, and universal if wanted), and the sidecar on 4 targets, with and without `ts_omit_*` tags. The current IPA baseline isn't recorded.
- Idle and active RSS of a node in the Mac app, the iOS app and the sidecar. The only figure is a third-party Linux one, 49-60 MiB at join.
- Whether `tsnet` builds with `CGO_ENABLED=0` for darwin, which decides whether the sidecar needs the build Mac for anything beyond signing.
- Whether swift-nio-ssh adopts the socketpair fd cleanly (Multiplex crashed with Citadel). Whether macOS ssh supports `ProxyUseFdpass`, and whether `ConnectTimeout` bounds ProxyCommand.
- Whether `logtail.Disable()` fully stops uploads.
- Notarization and App Store upload of a Go c-archive (Apple ld, min-OS stamps, privacy-manifest categories).
- WhoIs results for tagged and shared peers as seen from a user-owned node. Whether peers can see Hostinfo.App, for discovery.
- Behaviour with the Tailscale VPN app active on iPhone (with an exit node). Behaviour on tailnets with device approval or Tailnet Lock.
- Whether the user's Tailscale SSH policy on the dev box (README.md:96-98 says it accepts "none") lets a new app node in, or triggers check mode.
- Whether a Keychain-backed store works while the phone is locked (AfterFirstUnlock) and survives reinstall.
- Whether a browser-signed-in node resumes silently on the next launch (TailnetSession reports trouble calling `up()`; unverified).


---

## 8. Verification (2026-11-06)

Two independent agents tried to refute each load-bearing claim against primary sources (libtailscale and tailscale source, Tailscale docs and pricing, crates.io, this repo). None was refuted. Corrections and caveats are folded into the sections above; the table keeps them all.

| Claim | Verdict | Correction or caveat |
|---|---|---|
| C1: libtailscale's C API (tailscale.h at commit dacde75, 2026-11-05) has no WhoIs, no login-URL callback, no logout, no state-store setter (only tailscale_set_dir) and no log-upload switch; tailscale_status_json returns ipnstate.Status including BackendState, AuthURL, Self and Peer with UserID. | confirmed | This is true of the C functions, with one caveat: tailscale_loopback (tailscale.h:157-176) serves the full LocalAPI on /localapi behind a credential. Over that HTTP route a client can reach whois, logout and watch-ipn-bus (which carries the BrowseToURL login URL). The header also says the loopback listener can go stale on a suspended iOS process (tailscale.h:184-187). Log upload to log.tailscale.com is on by default in tsnet (tsnet.go:236-243, startLogger at :1090-1128). The only ways to stop it are process-wide (logtail.Disable(), or the TS_NO_LOGS_NO_SUPPORT env knob), and neither is in the C API. |
| C2: tailscale_dial/accept return one end of an AF_UNIX SOCK_STREAM socketpair, close-on-exec since commit ac7ed43 (2026-10-29). | confirmed | Minor point: the header comment for tailscale_conn still calls it 'a pipe(2)' (tailscale.h:78-82). It is actually a socketpair, as the claim says. |
| C3: TailscaleKit has no Package.swift (SwiftPM is open PR #55), its Xcode targets are IPHONEOS_DEPLOYMENT_TARGET 18.1 and macOS 15.x, its OutgoingConnection cannot read, and its IPN-bus masks fail against tailscale.com v1.104.1 (#21878). | confirmed | Precisely: only watch masks that include .netmap or .rateLimitNetmaps fail. Watches with the other bits still work. The macOS targets are 15.0 or 15.6 depending on the target. |
| C4: A Go c-archive in a static musl binary crashes at startup because musl does not pass argc/argv to .init_array constructors; golang/go#13492 is open and fix PR #69325 is stalled. | confirmed | I did not reproduce the crash myself. The segfault comes from the PR description, and the mechanism checks out in the source. The issue title is about c-shared, but the discussion and the PR cover c-archive. A second unmerged fix also exists: CL 696635 'cmd/link,runtime: fix c-shared dlopen on non-glibc systems (#13492)', which covers c-archive too. It has status NEW, with patch sets in 2026-04 and a review comment on 2026-11-06, so 'no fix in flight' would be too strong. |
| C5: Go requires non-Go signal handlers to use SA_ONSTACK; signal-hook-registry 1.4.8 (used by tokio) sets only SA_RESTART\|SA_SIGINFO, and tokio#3520 is open. | confirmed | Nuance (os/signal doc.go:195-197): for c-archive/c-shared, Go turns on SA_ONSTACK for handlers that already exist when the Go runtime initialises. The c-archive initialises at process start, before tokio installs anything lazily, so tokio's later handlers still lack SA_ONSTACK. The risk stands. |
| C6: clothod's daemon, PTY holder and CLI are one binary (`clothod holder` subcommand), so a linked Go c-archive would initialise the Go runtime in every clothod process, including the holder; the holder installs a tokio SIGCHLD handler. | partly | The daemon, the holder and clothod's own admin CLI subcommands are one binary. There is also a separate `clotho` CLI binary (crates/cli, [[bin]] name = "clotho", described as 'a small test client for clothod'), and the clothod crate does not depend on it. The conclusion still holds for the clothod binary: a Go c-archive linked into it initialises through .init_array in every clothod process, the holder included. |
| C7: Go 1.27 requires macOS 13 or later, and tailscale.com v1.104.1 requires go 1.27.1. | confirmed | The Go 1.27 notes give no iOS minimum, so I could not verify one. |
| C8: tsnet.Server has a Store field (ipn.StateStore), the in-memory store is only allowed for Ephemeral nodes, and the default is a FileStore at <Dir>/tailscaled.state. | confirmed | The line numbers are slightly off: the mem-store check is at 840-843, just before the cited 855-990 range. The path is rootPath, which is Dir or an auto-selected directory under os.UserConfigDir. libtailscale exposes no Store setter, so C/Swift callers always get the file store unless libtailscale is patched. |
| C9: tsnet starts a logtail logger that uploads to log.tailscale.com and does not honour TS_NO_LOGS_NO_SUPPORT; libtailscale exposes no way to call logtail.Disable(). | partly | tsnet does start a logtail logger aimed at log.tailscale.com, and libtailscale exposes no Disable call. But TS_NO_LOGS_NO_SUPPORT=1 is honoured: the upload transport becomes a no-op that pretends to succeed. Three caveats. (1) The variable has to be visible to Go's os.Getenv when the server starts. With a c-archive linked into Swift or Rust, a C or Rust setenv after the Go runtime has started may not be seen. I did not verify this; the safe routes are to set it in the launchd/systemd environment, or to call envknob.SetNoLogsNoSupport() / os.Setenv in the small Go wrapper we build. (2) Building libtailscale with -tags ts_omit_logtail turns all of logtail into no-ops (logtail/logtail_omit.go, Disable() {} and NewLogger returns an empty Logger). (3) The control server can also switch it off through tailcfg.Debug.DisableLogTail (control/controlclient/direct.go:1410-1412), but the Tailscale SaaS does not do this for us. |
| C10: Open issue tailscale/tailscale#21353: on iOS after about 30 s locked, the embedded node's MagicSock receive loop dies and does not recover until the tsnet.Server is replaced; Close() was reported taking 9 min 28 s. | confirmed | The claim is accurate, but two different people reported its parts. The ~30 s lock figure is the reporter's. The MagicSock diagnosis, the 'only a new Server recovers it' finding and the 9 min 28 s Close() are from a third-party commenter, who measured it once and has no goroutine dump. No maintainer has responded. Labels are bug and libtailscale; OS-ios was removed on 2026-11-04. |
| C11: Personal plan: up to 6 users, unlimited untagged user devices free, 50 tagged resources, 1,000 ephemeral-minutes per month; non-commercial use only. | confirmed | Small additions. The page says 'Unlimited user devices'; 'untagged' is implied, not stated. Tailnets on a custom domain count as business use, and Gmail-style domains count as personal. Up to 3 ACL groups. |
| C12: Default node key expiry is 180 days, can be disabled per device on all plans; tagged devices have key expiry disabled by default and lose user identity; ephemeral nodes are removed 30-60 minutes after last activity. | confirmed | 180 days is a per-tailnet default the admin can change (1-180 days), not a fixed value. Key expiry is disabled when a tagged device is authenticated or re-authenticated, not when tags change. |
| C13: WhoIs returns apitype.WhoIsResponse{Node, UserProfile, CapMap}; UserProfile.LoginName is display-only, so the same-user check should compare UserProfile.ID with the node's Self.UserID. | partly | The struct and the 'compare UserProfile.ID with Status().Self.UserID, not LoginName' advice are right; the cited line numbers fit HEAD more than v1.104.1. Two gaps matter. (1) The check must also reject tagged peers (Node.IsTagged() / len(Node.Tags) > 0), because Node.User does not reflect a tagged node's identity. Also consider Node.Sharer for nodes shared in from another tailnet. (2) libtailscale exposes no WhoIs to C, Swift or Rust. clothod would have to call LocalAPI /localapi/v0/whois through tailscale_loopback's credentials, or add a Go export to its own libtailscale wrapper. |
| C14: clothod's only listener is a Unix socket whose accept loop drops peers with a different uid; there is no authentication inside the protocol and trust comes from the socket or SSH. | confirmed | Nuance only. The holder has a second uid-checked Unix socket, so 'only listener' holds for the daemon's client listener, not the whole system. |
| C15: The login unit is deliberately run-once with no KeepAlive or Restart=, so nothing restarts serve if it stops. | confirmed | KeepAlive is explicitly false in the plist, not just missing. 'Nothing restarts serve' is true of the service manager, but clients do start the daemon on demand (proto/src/platform/mod.rs:3; cli/src/main.rs:35; docs/remote.md:169), so today an SSH connection brings it back. Over a direct tailnet listener with no SSH, a dead daemon could not be restarted remotely. |
| C16: The Mac app reaches machines by spawning /usr/bin/ssh, and a dev-only SSHProxyCommand default already injects -o ProxyCommand into ssh calls; iOS uses in-process SwiftNIO SSH with ClientBootstrap.connect as the only socket creation point; a notification action must connect within 20 s. | partly | Mostly right, with three corrections. (1) iOS has two ClientBootstrap.connect call sites, the session connect (SSHSession.swift:74) and the host-key probe presentedHostKey (SSHSession.swift:96). Both need the tsnet dial path, though both are in the one file. (2) The dev-only ProxyCommand reaches the session, bridge, installer and Files ssh calls, but not Onboarding's SSH check (Onboarding.swift:118-121 builds its own options without sshProxyOptions). (3) The 20 s is Clotho's own deadline inside iOS's roughly 30 s background budget, not an iOS requirement, so tsnet startup plus the dial plus the SSH handshake must fit inside it. |
