# Clotho for iOS

The iPhone and iPad client for clothod. There is no daemon on the device, so every machine is remote:
the app connects over SSH (SwiftNIO SSH), installs or upgrades clothod on the machine if needed, and
speaks [docs/protocol.md](../docs/protocol.md) over `clothod bridge` ([docs/remote.md](../docs/remote.md)).
Workspaces, tabs and their shells live on the machine, so closing or backgrounding the app costs nothing. On return, each pane
resubscribes from the seq it reached and resumes in live or replay mode.

## Build and test

Needs Xcode 26 and XcodeGen (`brew install xcodegen`). The Xcode project is generated from `project.yml`.

```sh
./build.sh          # generate the project and build for the booted simulator
./build.sh test     # unit, integration and UI tests
```

The app uses `../ClothoKit` (model, ModelStore, ClothodBackend, RemoteInstaller), SwiftTerm and
swift-nio-ssh, and bundles `../clothod/dist` (manifest.json plus one clothod per platform) to install on
machines. App Store validation rejects other platforms' executables inside an iOS app, so a pre-build
step (`scripts/pack-dist.py`) deflates each build into `build-resources/dist`, and the app inflates the
exact bytes into Caches on first use (`DistBundle.swift`).

## TestFlight

```sh
./scripts/testflight.sh    # Release archive, team TEAMID0000 (Ahmad Amin), upload to App Store Connect
```

App Store Connect app: "Clotho: Remote Terminal" (bundle ID `nyc.amin.clotho`, SKU `clotho-ios`, app id
1234567890). The internal group "Personal testing" has automatic distribution on, so each upload reaches
its testers once Apple finishes processing. The app declares no non-exempt encryption
(`ITSAppUsesNonExemptEncryption = NO`; SSH runs on Apple's CryptoKit).

## Layout

- `Clotho/Machines`: the machine list (JSON in Application Support; plain Codable records with stable
  ids and `modifiedAt`, ready for CloudKit sync) and the editor.
- `Clotho/SSH`: Keychain keys (Ed25519, or P-256 in the Secure Enclave; never synced), host keys
  (trust on first use, refused with a warning when they change), `SSHSession` (connection, exec
  channels, a socketpair glued to the bridge channel), `NIOCommandRunner` (ClothoKit's
  RemoteCommandRunner) and `SSHTransport` (ClothoKit's ClothodTransport).
- `Clotho/Session`: one `MachineConnection` per machine, the workspace/tab list, and the full-screen
  pane screen (pane strip, tab menu, actions, ⌘ shortcuts).
- `Clotho/Terminal`: `PaneHostView` (SwiftTerm fed from OUTPUT/SNAPSHOT, the emulator's own query
  replies dropped as in the Mac's PaneView) and the key bar.

## Development setups

**Local Mac (dev)**, simulator only. Simulator apps share the Mac's filesystem, so this machine uses
ClothoKit's Unix socket transport to a clothod on the Mac:

```sh
cp ../clothod/target/release/clothod /tmp/cki-ios-bin/clothod
/tmp/cki-ios-bin/clothod start --runtime-dir /tmp/cki-ios --ephemeral   # socket: /tmp/cki-ios/clothod.sock
/tmp/cki-ios-bin/clothod shutdown --runtime-dir /tmp/cki-ios  # when done
```

**Test install directories.** Machines added in Debug builds default to a separate clothod on the
remote side (toggle in the machine editor), so testing never touches the daemon the machine already
runs: install dir `$HOME/.local/share/clotho-ios-dev/bin`, runtime dir `/tmp/clothod-ios-dev-$(id -u)`.
Stop it with:

```sh
ssh <host> 'CLOTHOD_RUNTIME_DIR=/tmp/clothod-ios-dev-$(id -u) ~/.local/share/clotho-ios-dev/bin/*/clothod shutdown'
```

**SSH integration tests** (`ClothoTests/SSHIntegrationTests`, `ClothoUITests/RemoteUITests`) read their
target from `/tmp/clotho-ios-sshtest` and skip without it. `scripts/ssh-test-server.sh` starts a
throwaway sshd on 127.0.0.1:2222. It runs as you, uses only files in that directory, and changes
nothing on the system; `scripts/ssh-test-server.sh stop` ends it. To aim the tests at another machine,
write its host and port to `/tmp/clotho-ios-sshtest/host` and `port`, and `user@host` to `ui-host`
for the UI test.

### The test key on devbox

The integration tests log in with `/tmp/clotho-ios-sshtest/client`. Its public key (comment
`clotho-ios-dev-test`) was added to `ahmad@devbox:~/.ssh/authorized_keys` on 2026-10-26, with the
user's approval. To remove it:

```sh
ssh devbox "sed -i '/clotho-ios-dev-test$/d' ~/.ssh/authorized_keys"
```

Over the tailnet, devbox uses Tailscale SSH, which accepts the "none" method and never checks client
keys. Key authentication is therefore exercised against the local test sshd, and the wrong-key test
skips on devbox.

## Notes

- XCUITest waits for the app to go idle, and SwiftTerm's blinking caret is a repeating animation that
  never does. UI tests launch with `-UITesting`, which turns UIView animations off.
- The PTY follows the last typer's viewport (protocol.md, Resize), so typing on the phone resizes the
  pane to the phone. Other clients letterbox. A pane sized larger by another client is scaled down to
  fit here.
- The Agents list (top of the home screen) reads each pane's `agent` field. Launch with
  `-FakeAgents YES` to give agent-less panes made-up states for UI work. Pull to refresh connects to
  every machine. Agents that start needing you post a local notification while the app runs.
- Quick replies: swipe or long-press a waiting agent for Reply (1/2/3/Enter/Esc for permission prompts, or
  text plus Enter). They go through clothod's `pane.keys`, which encodes keys for the pane's modes (a
  bare CR doesn't submit under the kitty keyboard protocol). Daemons without the `pane.keys` feature in
  hello get "Update clothod to reply" and never a raw-CR fallback. `ClothoUITests/QuickReplyUITests`
  replies to a real Claude Code in a dev pane; start it with `--setting-sources project,local` so
  user-level permission hooks (AgentHQ) don't answer the prompt first.
- Not built yet: push notifications through an APNs relay, file
  browsing (`fs.*`), and CloudKit sync of the machine list.

## Push alerts

Agent alerts while the app is closed; the design is docs/push.md.

- `relay/`: the Cloudflare Worker relay (plain JS). `cd relay && npm test` runs its tests; `node dev.js`
  runs it locally, delivering to the booted simulator with `simctl push`.
- `ClothoNotify/`: the notification service extension that decrypts alerts. It and the push
  entitlements come from `push.yml`, included only with `PUSH=YES` (`build.sh` sets it), so device and
  TestFlight builds don't touch the developer account's identifiers until push is set up there.
- The relay URL: `PushRegistrar.deployedRelay`, or `-PushRelay <url>`; Debug simulator builds default to
  the dev relay. Each machine has an "Agent alerts" switch, and "Send test alert" on its screen.
