# Status and handoff (2026-10-27, updated after clothod 0.1.10)

Development moved from this Mac's sessions to devbox. Everything from the old agents (clothod-80, mac-d8,
ios-c2 and the orchestrator) is committed. CLAUDE.md has the rules. This file has where things stand and
what the old agents learned. The orchestrator keeps it current.

## Where things stand

- **clothod 0.1.10** runs on macbook, devbox and imac, upgraded in place (holders 9573, 1799611 and
  27331 kept their pids through 0.1.6 to 0.1.10). Since 0.1.8, upgrades win on attempt 1 (an upgrade
  lock, `current` moved first, and the app no longer runs `install` when `current` exists). It
  has the following:
  - pane.clipboard (OSC 52)
  - the settings (scrollback) and service (start at login) requests
  - attention that clears only on agent.ack or real work, never on input or viewing
  - agent.mute
  - numeric version ordering pinned by a test
- **Start at login:** on for imac (the user turned it on). Off on macbook; off on devbox, which needs
  `sudo loginctl enable-linger ahmad` first.
- **Agent hooks** (Claude Code and Codex) are installed on all three machines. The backups are
  `*.bak-2026-10-27-clotho-hooks`.
- **The Mac app** bundles 0.1.10 and has the following:
  - Shift+Return, the Cmd editing keys, rename without flicker
  - Option/Shift-drag selection and the right-click pane menu in agent TUIs, OSC 52 copies
  - image paste and drop into remote agents
  - the Agents panel: attention first, hover-only Mute and Resolve over a pinned time, a Quiet
    subsection
  - left chevrons, accent-blue selection, thicker tabs, whole-app zoom (with a separate terminal
    zoom on Option+Cmd)
  - a Settings window
  - Create Workspace outline buttons, and a Manage Machines footer and panel (add, edit, remove,
    reorder)
  - the Panes icon
  - Developer ID notarization, waiting for the user's certificate
- **iOS:** TestFlight build 202610271602 (clothod 0.1.10), uploaded by the user. It has parity with
  the Mac: image paste, Paste Photo, the Newline key, the Cmd keys, the long-press menu in agent
  TUIs, the agents list with Resolve, Mute and Quiet, Settings, accent selection, the Panes icon, and
  the host-key deadlock fix.
- **The push relay** is live at https://clotho-push.example.workers.dev. Its secrets exist in
  Cloudflare only.
- **GitHub:** git@github.com:ahmad/clotho.git (private). The orchestrator pushes exact verified
  commits (`git push origin <sha>:main`).
- **The Mac reaches imac under clotho-mac** through a `Host imac` entry in the Mac's ~/.ssh/config.
- **The website** (clotho.app, waitlist CTA) is built by a separate session in ~/Projects/clotho.app.
- **Known issues:**
  - One interrupted upload hung for 10 minutes once and didn't reproduce.
  - Resume after a cut is unproven against test daemons.
  - linux-aarch64 has run only under qemu.

## Waiting on the user

- **iPhone pass (never done).** Install TestFlight 202610262314 and allow notifications. Connect to
  devbox and imac, then tap "Send test alert". Check that:
  - the lock screen shows the decrypted message ("Claude is waiting on <machine>")
  - tapping the alert opens the pane
  - file download and upload work over cellular, and a transfer survives backgrounding the app
- **About 10 minutes of real-mouse testing on the Mac.** All UI tests so far used synthetic key events.
  Unverified:
  - click and double-click rename, in the sidebar and the tab bar
  - dragging the sidebar width and the Agents panel splitter
  - the right-click pane menu
  - file drag and drop onto panes and in the browser
  - mouse selection, copy and scroll in panes
  - the notice-bar buttons, such as the update and restart offers
  - quick reply from a real notification
  - the file browser between two remotes, through the UI
- **Product calls:** scrollback in the app (today it's only in `~/.config/clothod/config.toml`, read
  at daemon start), launchd/systemd login units, a Developer ID for notarized Mac builds.
- **Optional:** "Set Up Agent Status…" hooks on each machine. Removing the old clotho-ios-dev-test key
  from devbox's authorized_keys. Note that the iOS SSH tests use that key.

## Open work by area

### clothod
- The linux-aarch64 and macos-x86_64 builds have never been run or tested.
- There are no launchd or systemd units; clients start the daemon on demand.
- The macOS holder briefly reaches about 154 MB during an in-place upgrade (22 MB steady), under the
  200 MB ceiling. It's the biggest remaining memory spike.
- The macOS soak had one 83 ms latency outlier, with p99 at 1.2 ms.

### mac
- Optional, not started:
  - a Settings window for notification mutes (they're only the UserDefaults keys
    `NotifyAgent.<state>` and `MonitorAgents.<machine>` today)
  - collapsible machine groups
  - wider or wrapping agent rows
  - a cleanup helper for orphaned upload part files
- Transfers were checked end to end against devbox only, not against imac, a large tree or a slow link.

### ios
- `SSHIntegrationTests.testChangedHostKeyIsRefused` once hung until the 180 s limit in a full run. It
  passes alone. The likely cause is NIOCommandRunner not timing out when the host-key check fails.
- Not started: CloudKit sync of the machine list, iPad split view.

## What the old agents learned

### Everyone
- **The user's daemons.** Never start, stop, upgrade or prune them on any machine without asking.
  Never use the Mac app's `-ApplyDaemonUpdates` against real machines.
- **Test daemons.** Use `--ephemeral` and a non-default `--runtime-dir`. Shut them down, delete their
  dirs, and check that `clothod ps` shows nothing extra.
- **Builds from a fresh clone.** `clothod/dist` is gitignored. The Mac mirror devbox uses
  (`~/Builds/clotho-clothod`) already holds the 0.1.5 dist. After a new release, run `dist.sh` on a Mac
  or copy the new dist into that mirror. Mac `--dev` builds otherwise make a dev dist in
  `clothod/target/dist-dev`.
- **From devbox.** `clotho-mac <cmd>` runs Xcode builds on this Mac. Signing, archives, TestFlight and
  installing the app need the Mac's own session, because the keychain is locked over SSH.

### clothod
- **The Linux allocator.** Linux must keep the tuned mimalloc in `src/alloc.rs` (eager commit off,
  purge delay 0). musl malloc grew to 24 GB RSS in an hour against a ~165 MB live heap. Don't change it
  without re-running the hour soak.
- **Vendored alacritty_terminal.** It's in `vendor/` (see VENDORED.md), patched with
  `MAX_CACHE_SIZE` 100. Re-apply that patch on any alacritty upgrade.
- **Linux builds.** These need zig and cargo-zigbuild, because ring has C code. devbox has Rust but not
  yet zig or cargo-zigbuild.
- **Exit-mode ephemeral instances.** They count only clients whose hello name doesn't start with
  `clothod-`. Internal probes must use a `clothod-*` name.
- **Upgrade prune.** It keeps versions with a running serve or holder and ignores old bridges on
  purpose.
- **Releases.** Bump `[workspace.package]` version, then run `scripts/dist.sh`, which refuses a
  version not newer than RELEASED (`--dev` for test builds).
- **Diagnostics.** The `debug.stats` request shows the heap, Linux smaps, queues and rings. The soak
  (`tests/soak.rs`, `CLOTHOD_SOAK_SECS`) enforces serve 400 MB and holder 200 MB.
- **e2e tests.** They set `CLOTHOD_CONFIG` to a temp file. Hook-install tests use a temp HOME.

### mac
- **Test builds.** The user works on this Mac at the same time. Test only with `Clotho Dev.app`
  (`./build-app.sh --dev`), launched with `open -g -n … --args -LaunchInBackground YES`. Quit it by
  pid with `pkill -f "Clotho Dev.app/Contents/MacOS/Clotho"`, never through osascript.
- **Screenshots.** Never take full-screen captures or capture the user's window. Use
  `screencapture -l <devWindowID>`.
- **Dev launch options:** DumpScreens, RunShortcuts, TypeText, ShowFiles, FilesMachine, ConnectMachine,
  TestCopy, PaneMenu, QuickReply, FakeAgents, ConnectedMachines '()', LogModel, TraceFrames,
  ResizeWindow.
- **Installing the release app** is approved for new versions: pkill its pid, then `open -g`. After
  that, check the offer in `~/Library/Logs/Clotho.log` and that no daemon pid changed.
- **Before committing,** run `git checkout -- ClothoKit/Package.resolved`. `swift test` in ClothoKit
  needs an ABSOLUTE `CLOTHOD_BIN`.
- **ClothoKit promises iOS relies on.** Tell ios before changing any of these:
  - The FileBackend protocol: stat, list with cursor paging, listAll, mkdir, setattr, rename, remove,
    statfs, read returning a FileReadStream, and write with progress.
  - Its options default to a 256 KiB chunk, a 4 MiB window, and overwrite false.
  - FileTransfer: 4 streams, replace or skip on conflict, Progress, `copy`, `existing`.
  - The upload resume id is FNV-1a of the destination path plus "size:mtime_ns".
  - Also: Pane.displayTitle, the push API, Hello.Machine.home, Hello.Feature.fs, and the name
    `RemoteInstaller.shutdownSessions`.

### ios
- **Test runs.** `./build.sh test` starts an ephemeral `/tmp/cki-ios` clothod and a test sshd on
  127.0.0.1:2222, and cleans up on exit. Never run two at once.
- **devbox dirs.** The SSH tests use `~/.local/share/clotho-ios-dev` on devbox. Never touch
  `~/.local/share/clothod`.
- **Push testing.** `simctl push` skips notification service extensions. Test decryption with
  PushTests (which include a vector sealed by Rust), or the gated PushUITests
  (`/tmp/clotho-ios-push-e2e`).
- **UI.** Keep actions in menus and swipe actions. Split large SwiftUI bodies, because type-checking
  times out on them. Put accessibility identifiers on the NavigationLink.
- **The push setup** in the developer account: extension `nyc.amin.clotho.notify`, Keychain group
  `TEAMID0000.nyc.amin.clotho.shared`. Deploy the relay with `npm run deploy`, only when asked.
