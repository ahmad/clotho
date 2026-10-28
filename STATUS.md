# Status and handoff (2026-10-28, updated after clothod 0.1.14)

Development moved from this Mac's sessions to devbox. CLAUDE.md has the rules. This file has where
things stand and what the old agents learned. The orchestrator keeps it current.

## Where things stand

- **clothod 0.1.14** runs on macbook, devbox and imac, upgraded in place. The holders (9573, 1799611
  and 27331) have kept their pids since 0.1.6. Each bin/ holds only 0.1.14.
  - 0.1.13: pushes only when the agent needs the user. It ignores Claude's idle reminder,
    compaction and nested agents, and stays quiet while the user is at the pane (`quiet` on the
    agent). Notifications carry the details: workspace, project, prompt, result and duration.
    Allow/Deny comes through Claude's PermissionRequest hook and `agent.decide`.
  - 0.1.14: an upgrade's start waits for the old serve to exit (no false "socket did not come
    back"), and a `cd` shows up without OSC 7 (polled once a second).
- **Agent hooks:** 8 Claude entries on all three machines (PostToolUse and PermissionRequest added
  for Allow/Deny). Codex is ours on devbox and imac; on macbook it's the user's Computer Use
  notifier.
- **Start at login:** on for imac only.
- **The Mac app** (build 202610281505) bundles 0.1.14. It has quiet rises, detailed notifications,
  and Allow/Deny on permission notifications and in the row menu. A ModelStore regression that
  dropped live pane events was fixed in aff7fd2. ClothoKit/scripts/test.sh builds with
  -warnings-as-errors.
- **iOS:** TestFlight build 202610281515 (clothod 0.1.14), uploaded by the orchestrator through
  scripts/testflight-remote. 0.1.13 was build 202610281458. The iPhone suite had 64 passed, 8
  skipped and 0 failed, and the iPad test passed.
- **The iOS redesign** (docs/ios-redesign.md) is on the local branch ios-phase1, not merged:
  - phase 1 (saved state) is done
  - phase 2 (Home) is written and under test
  - phase 3 (onboarding) isn't started
  - phases 1 to 3 ship together
- **TestFlight uploads:** the orchestrator uploads verified builds itself. The API key ids are in
  ~/.config/clotho/asc.env on devbox.
- **The push relay** is live at https://clotho-push.example.workers.dev.
- **GitHub:** git@github.com:ahmad/clotho.git (private). The orchestrator pushes exact verified
  commits.
- **The website** (clotho.app, waitlist on Upstash) is built by a separate session in
  ~/Projects/clotho.app.

## Waiting on the user

- **Optional:**
  - a Developer ID certificate and notary profile
  - Sparkle `generate_keys`, then commit mac/Resources/SparklePublicKey and host appcast.xml on
    the site
- **Website leftovers:** remove orchestrator-test@example.com from Upstash; optionally set
  WAITLIST_ADMIN_TOKEN.
- **Untested by agents:**
  - real-mouse use on the Mac
  - iPad hardware-keyboard shortcuts, Slide Over and Split View sizes
  - a real-device push pass

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
