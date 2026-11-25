# Status and handoff (2026-11-25, after clothod 0.1.33, Mac 1.0.22, iOS 202611241908)

CLAUDE.md has the rules, including Shipping (ship verified work without asking) and the Mac's disk
rule. This file has where things stand. The main session keeps it current.

## Where things stand

- **Built-in Tailscale, Phase 0** (PLAN.md): merged offline for all three roles: clothod `clothod-net` + testctl (503a066), ClothoKit/Tailnet + the Mac's dev-only Tailnet Test window (2f1eaeb), iOS debug Tailnet Test screen, Keychain store and SSH dialer (76db659). Nothing released or shipped with the node; default and TestFlight builds refuse it. Left: the physical-iPhone lock test, which needs a second Tailscale account (a test tailnet) from the user.
- **clothod 0.1.33** (2026-11-25, 3824286) runs on the dev box (holder 1799611 kept, 16 panes), the build Mac (holder 27952 kept) and the laptop Mac (holder 9573 kept), upgraded in place. No app uses its new parts yet (Mac 1.0.21 and iOS 202611241908 bundle 0.1.32 and will offer nothing newer until the next app release). It adds generic agent status: OSC 9 / 99 / 777 / 7501 from any program raise Needs you (source `osc`, never sent to the summarizer, rate-limited per pane), `clothod report --state … [--kind] [--needs-user]` by hand, `progress` on the pane (OSC 9;4), kinds gemini, opencode, copilot, aider, amp, cursor, a change token on `git.changes`, `tb` as the Tab's shown title, the upgrade wait following progress under load, the global git config re-read. docs/protocol.md "What changes for clients in 0.1.33" is the list for mac and ios (kind names, `osc` source as plain text, pane progress, token-driven Changes refresh, agent.ack may keep a live program's agent, `tb`; the two Rust-sealed `nu` vectors for ios PushTests are in clothod push.rs). Lifetime of a script's `running` status follows one owner rule (owner.rs) with a documented Limits list. Unverified: Copilot hooks against the real CLI; ssh/tmux/sudo limits are reasoned, not tested.
- **clothod 0.1.32** (2026-11-24, 94d427e) runs on all three machines (the laptop Mac took it through the app's own update; holder 9573 kept), upgraded in place.
  0.1.32 (PLAN.md "UI refresh", B and C's daemon side; no app uses it yet): `changes` on a pane's `git` object, `git.changes`, `git.diff`, `worktree` on tab.create / workspace.create (beside the repo as `<repo>-<name>`, hooks and filters off: LFS files stay pointers, post-checkout doesn't run; the main session's call, the user was told), `peek.subscribe`. All git runs through the hardened runner (gitrun.rs; docs/security.md); needs git 2.31+ (dev box 2.43, build Mac 2.54).
  The build Mac's first upgrade rolled itself back (shells kept): under load average 200+ from the user's other project, pane recovery took 7-10 s and `upgrade` gave up waiting. It went through once the load dropped. **Fix in the next clothod change:** the upgrade's wait under load; the global git config read once per binary (stale until the next upgrade) and only one of ~/.gitconfig and the XDG file read; git tests using the real HOME.
  Never run on this version: the 7 remote tests against the laptop Mac (asleep), linux-aarch64.
- **clothod 0.1.31** (2026-11-23) ran on the dev box, the build Mac and the laptop Mac, upgraded in place (holders 1799611, 27952 and 9573 kept). `clothod summarize` with the real helper works on all three.
  0.1.31 (PLAN.md "Fewer, clearer alerts"): a finished turn alerts only after 30 s without the agent working again; `needs_user` labels it Needs you or Done (`nu` in the push record, `silent` on /v1/push for a plain Done); phone pushes are held up to 2 min while the user is at the Mac (`client.active`); every push decision is logged in clothod.log; the Haiku rewrite runs `claude --safe-mode --setting-sources user`, so a login from the user's settings works (it had failed every time on the dev box), with `notification_rewrite_health` in settings. Checked with the real helper on the dev box and the build Mac: both rewrite and label.
  Until the apps follow, phones still show the old wording and a plain Done still makes a sound (the relay ignores `silent`). Next: mac (labels, health, `client.active`), then ios (relay `silent`, `nu`, labels; the docs/push.md patch is in ~/.config/clotho/clear-alerts-push-md.patch on the dev box). Then generic agent status (OSC 9/99/777/7501, more agents) and worktree panes with a changes view.
  Left open on purpose: a daemon killed within a second of a hold ending can resend; a push in its 6 s rewrite wait is lost on restart; linux-aarch64 0.1.31 was built but never run.
- **clothod 0.1.30** ran on the dev box, the build Mac and the laptop Mac, upgraded in place (holders 1799611, 49964 (the build Mac, since its reboot), 9573 kept).
  0.1.30: every spawn (incl. restore after a reboot) gets TERM/COLORTERM/TERM_PROGRAM(_VERSION) and a UTF-8 LANG when
  the daemon has none (pane_env); before, restored panes ran without them (black-and-white Claude).
  0.1.29: notification text rewritten by Claude Haiku through the machine's own claude login (`agent.summary`,
  `summary_pending`, push `sm`, setting `notification_rewrite`, `clothod summarize`); Markdown is never shown raw.
  0.1.28: `pane.focus`; the client that focused a pane last sets its size, input no longer does.
  0.1.27: client safety (shutdown --forget only deletes the target's own layout; ps shows the real runtime
  dir or "?"; stop/shutdown/status wait at most 15 s). 0.1.26: pane.move and tab.join (⌘↩ open beside). First
  releases built on the build Mac. 0.1.25: agents survive a
  reboot (agent kept 10 s after it leaves a live shell), detected Claude sessions from
  ~/.claude/sessions/<pid>.json, and `continued` restores when unambiguous. Proven on the build Mac's unplanned
  reboot 2026-10-30 09:18: 4 panes, 3 Claude sessions resumed. 0.1.24: on macOS, serve and
  holder always start in the login session's launchd namespace (Aqua), never an SSH session's; a
  daemon left in a dead SSH namespace lost DNS, opendirectoryd, trustd and the keychain (the build Mac's shells
  broke this way; the build Mac was restarted with the user's OK and now runs holder 2418 / serve 2417, Aqua).
  `clothod ps` shows `launchd: <ns>`; hello carries namespace. 0.1.23: per-pane git info (branch,
  worktree, PR via the machine's own gh). 0.1.22: workspace.move and
  tab.move, and agent sessions kept in the holder meta. 0.1.21: restore after restart (layout.json in
  the state dir; `shutdown --forget` clears it). 0.1.20: client.colors (so
  OSC 10/11/4 and mode 2031 follow the app's light/dark palette). Earlier: 0.1.17 The holders (1799611, 9573
  and 27331) have kept their pids since 0.1.6.
  - 0.1.13: pushes only when needed, notification detail, Allow/Deny (agent.decide).
  - 0.1.14: cwd without OSC 7, and no false upgrade alarm.
  - 0.1.15: clothod.log names who closed or answered what.
  - 0.1.16: Live Activity updates (push.activity).
  - 0.1.17: a chained Codex notify reads "installed (chained)".
- **Hooks:** 8 Claude entries on all three machines. Codex is installed on the dev box, and installed
  (chained) inside Computer Use's notifier on the build Mac and the laptop Mac. The laptop Mac's was updated with the
  user's OK; its backup is ~/.codex/config.toml.clotho-backup-1793217804.
- **The Mac app is public:** Clotho 1.0.22, build 202611252204 (a112718, clothod 0.1.33 bundled): status from any program: every agent kind by name and SF Symbol (ClothoKit AgentKind), `osc` agents as plain text, progress bars on the Tab, pane header, sidebar row and Overview card (ClothoKit PaneProgress), an Agent Status sheet with per-agent hook setup (Claude Code, Codex, Gemini CLI, GitHub Copilot CLI; one summary row in Settings › Machines), Changes refreshing from `git.changes.token`, and a "Status from any program" section in mac/docs/usage.md. Published to clotho.app (feed and zip checked live, sha256 7a4caadc…); offered through Sparkle, not installed by the main session. For clothod next: it Markdown-strips an osc agent's `summary` against the doc (the Mac shows `message` first); a script's `clothod report` has source `hook`, so clients tell it from an agent by kind. **The build Mac had 17 GiB free after this build, under the 20 GiB floor; our ~/Builds is 9.5 GiB in all, so the rest is not ours (the user was told).** Before: Clotho 1.0.21, build 202611251959 (93f372a, clothod 0.1.32 bundled): UI refresh C, the Overview (View menu, ⇧⌘0; ⌘0 stays Actual Size): one card per agent on every enabled machine in Needs you / Working / Done, with a live peek, branch and change count; it covers the whole window and nothing under it can be acted on; peeks pause while the window is out of sight. Notification titles read "Needs you · workspace › tab" / "Done · workspace › tab"; the find bar shrinks in a narrow pane; tab marks follow the zoom. ClothoKit gained peek, AgentStatusGroup, RewriteHealth.problemCaption and AgentNotice.placeTitle (iOS should switch to them and drop its copies). All five UI refresh proposals are now shipped on the Mac. Published to clotho.app (feed and zip checked live, sha256 3f56ae3a…); offered through Sparkle, not installed by the main session. Not exercised: the app's preferred terminal fonts (the build Mac has only Menlo). Later: 40 mac tests log "Conflicting constraints detected"; 13 compiler warnings. Before: Clotho 1.0.20, build 202611241139 (b1e4d7a, clothod 0.1.32 bundled): UI refresh B (PLAN.md "UI refresh"): the right sidebar is an inspector (Changes, Files, Activity); Changes lists uncommitted files and the branch against its base with an inline diff; a file opens as a client-side side-by-side diff over the pane area (not a Tab; Back, Esc or ⌘W close it; while it shows nothing can act on or focus the covered pane); the pane strip and ⌘P show the change count; New Tab in a Worktree. Open in Editor shows a file in Finder when opening would run it (OpenSafety). ClothoKit gained PaneGit.changes, gitChanges, gitDiff, worktree creates, GitText, ChangeCountText, DiffText (all additive; the iPhone suite and iPad test passed against it, after a rerun: the mac mirror had a stale ios/build-resources/dist stamp). Published to clotho.app (feed and zip checked live, sha256 f85ce199…); offered through Sparkle, not installed by the main session. Open, asked of the user: should the Files sidebar also refuse to run files on double-click; remove "Approve (1)" / "Press 1"; should new worktrees run hooks and LFS. Later: the find bar is cut off in a pane under ~400 pt (also on main); runsWhenOpened uses a fixed list of launcher apps. Before: Clotho 1.0.19, build 202611240748 (6f52bdc, clothod 0.1.32 bundled): UI refresh A and D (PLAN.md "UI refresh"): the sidebar inbox (Needs you, Done, Working) replaces the Agents panel and its switch; one agent mark on workspace rows, tabs and a new pane header; the breadcrumb sits in the tab bar; a permission request shows as an ask bar in its pane (⌘↩ allows, ⌘. denies); ⌘P rows show state and branch, filter by needs / working / done, and ⌥↩ allows. Rule for every answer path: a request is answerable only after it has been the visible target for 0.5 s (AskBar.settleDelay). Published to clotho.app (feed and zip checked live, sha256 0c4984aa…); offered through Sparkle, not installed by the main session. Open: the notification's "Approve (1)" and the menu's "Press 1" still type a key into the pane (the user was asked whether to remove them); a double-tapped ⌥↩ on the last request row opens a New Tab; the settle tests are timing-sensitive when the build Mac is overloaded. Before: Clotho 1.0.18, build 202611240405 (eaf34eb, clothod 0.1.31 bundled): alerts read Needs you or Done by `needs_user`, a plain Done is silent, settling agents sit in Quiet, Settings › Machines shows a failing rewrite, the app sends `client.active` while the user is at it, and a focus change with no user action behind it no longer sends `pane.focus` or focus-in. Published to clotho.app (appcast and zip checked live, sha256 fbe13e50…); offered through Sparkle, not installed on the laptop Mac by the main session (the user was using the app). Not seen in a running app: a real banner click, the silent Done as macOS plays it. Before: Clotho 1.0.17, build 202611021923 (7cffa61): workspace highlights from the sidebar's right-click menu (local to the Mac). Before: 1.0.16, build 202611011805 (4d595d0): the right file sidebar (⌥⌘B), following the focused pane; double-click opens a remote file in the default Mac app and saves sync back (fs.write with expect_mtime_ns; conflict sheet). Before: 1.0.15, build 202611010114 (ce2ddeb): plain-text notifications, Haiku summaries, Settings › Machines › "Summarize agent messages". Before: 1.0.14, build 202610302256 (8f201c2, clothod 0.1.28): panes follow focus (pane.focus), the pane × stays in the host's corner, word-prefix ⌘P commands. Before: 1.0.13, build 202610301926 (a8e6c02, clothod 0.1.27, built on the build Mac):
  ⌘P ">" commands, ⌘↩ open beside, Move Tab picker, title-row sidebar toggle, "New Tab (⌘T)" buttons,
  Agents panel switch, sidebar slides instead of squashing (crash fix). 1.0.12 ⌘P tree; 1.0.11 one
  Settings window (General, Machines); 1.0.10 Toggle Sidebar on macOS 26. 1.0.9 machine
  on/off switch, file browser sort/filter/any-to-any copy, SIGPIPE fix. 1.0.8 continued restores and
  polish; 1.0.7 git info only in the pane strip, ⌘/ sidebar, bottom bar, pane ×, empty workspace,
  Reconnect after 3 tries. 1.0.6 a "Restart Shells…" notice when a machine's shells run outside the login session. 1.0.5 git
  branch, worktree and PR in the tab bar, sidebar, pane strip and ⌘P. 1.0.4 drag to
  reorder and move tabs. 1.0.3 restore note, 1.0.2 rename focus and ⇧⌘ shortcuts, 1.0.1 light mode; 1.0.0 was
  build 202610291513 (at ee15de6). The user updated 1.0.0 → 1.0.1 through Sparkle (first real update, OK).
  Both are Developer ID signed,
  notarized and stapled, at https://clotho.app/downloads (Clotho.zip redirects to the newest zip).
  Sparkle updates are live from https://clotho.app/appcast.xml (EdDSA key in the laptop Mac's keychain;
  sign_update works over SSH after unlocking). The user's installed app is that exact release.
  - Next release: mac runs release.sh with CLOTHO_APPCAST_IN set to the site's appcast.xml
    (~/Projects/clotho.app/appcast.xml), then the main session runs
    `scripts/publish-mac.sh <zip> <appcast> --deploy` in ~/Projects/clotho.app and pushes that repo.
  - The site deploys ONLY from the CLI (vercel.json git.deploymentEnabled=false). The zips are
    gitignored, so a git-built deploy 404s every download; that broke the first 1.0.1 update.
  - UPDATES_LIVE=true (93b3da6): every non-dev build checks the feed.
- **iOS:** TestFlight build 202611241908 (78ef0a7, clothod 0.1.32 bundled): alerts titled "Needs you · Workspace › Tab" or "Done · Workspace › Tab" by the push record's `nu`, a plain Done with no sound; the Agents tab and the iPad sidebar in three groups (Needs you oldest first, Done, Working folded), Pinned on top; the change count in the row caption; the rewrite health under each machine's Summarize switch in Settings; the widget counts only agents that need the user. Full iPhone suite 170 passed / 10 skipped / 0 failed on iPhone 17, iPad tests 2 passed, relay tests 18 passed. **The push relay** is deployed as version 4c3b8904 (`silent: true` sends no sound and interruption-level passive). Owed by the user on a real iPhone: the silent Done, the lock-screen titles (a long title may clip the Tab), Allow/Deny on a pushed ask. Open: the tab badge counts Needs you plus Done while the widget counts Needs you only (asked of the user); a push for an unnamed Tab has no tab in its title (clothod should send `tb` as the shown title); PushTests has no Rust-sealed vector with `nu`; ios/relay/.wrangler is not gitignored (a deploy leaves it and testflight-remote then refuses the tree); a test run seemed to receive a push through the production relay (unconfirmed). Before: TestFlight build 202611071915 (a55cdc8: privacy manifests in the app and both extensions, "Data Not Collected", checked against each binary's imports by ios/scripts/check-privacy.py; UI menu taps settle on the screen, not isHittable; build.sh exits with xcodebuild's status). Full iPhone suite 141 passed / 9 skipped / 0 failed twice on iPhone 17, iPad test passed. App Store Connect's privacy answers should say Data Not Collected, no tracking. Before: 202611022024 (744f36c: pinned agents at the top of the Agents tab, tinted with a pin glyph; local to the phone). Before: 202611011351 (36af5b3: agent rows without status dot, status word or bell; the age in the caption; red Error kept). Before: 202611011257 (66368db: agent rows with the status dot on the caption line, a Mute bell, larger type and more room). Before: 202611010600 (11fb536: three tabs, Agents / Machines / Settings; the Agents tab as an inbox with status dots and compact rows; iPad keeps the sidebar). Before: 202611010139 (870b0f8: summaries and plain text in alerts, banners, Live Activity; onboarding as window content). Before: 202610302317 (8f201c2: a pane takes the phone's size on focus, not on typing; clothod 0.1.28). Before: 202610301954 (⌘P tree and ">" commands in Quick Open; clothod 0.1.27; built on the build Mac). Before: 202610301844 (tree), 202610301224 (Reconnect, git strip, restored note). Before: 202610291753 (client.colors, with 0.1.20). Earlier: 202610282014, with 0.1.17. It has the whole redesign: saved state, the
  one-screen Home, three-step onboarding, Allow/Deny/Reply on cards and notifications, the terminal
  gestures, the "Needs you" widget, and the Live Activity. Full suite: 90 passed, 8 skipped, 0
  failed; iPad passed.
- **The push relay** has /v1/activity, deployed as version c1940b72.
- **Drag to reorder works with a real mouse** (Mac 1.0.4, user-confirmed 2026-10-29).
- **Allow from the lock screen works on device** (build 202610282014, user-confirmed 2026-10-28; the
  log shows the iOS client answered and Claude ran the command).
- **Device checks still owed by the user:** the widget, the two-finger tab swipe and haptics, and the
  Live Activity.
- **TestFlight:** the main session uploads with scripts/testflight-remote. The key ids are in
  ~/.config/clotho/asc.env on the dev box.
- **Build host: the build Mac.** Everything builds, tests, signs and uploads on the build Mac via `scripts/clotho-build <role>` (per-role mirrors; see CLAUDE.md). The laptop Mac is a fallback only.
- **The Mac's disk:** about 25 GiB free (it dipped to ~12 GiB during 0.1.24; one dip was approved). test-all, dist, build.sh test and testflight-remote all
  clean up after themselves.

## Waiting on the user

- **Optional:**
  - Developer ID: done 2026-10-28. "Developer ID Application: Ahmad Amin (<team id>)" is on the laptop Mac,
    issued under the G1 CA, so it expires 2027-02-01; make a G2 one before then. The notary profile
    `clotho-notary` (app-specific password, Apple ID the user's Apple ID) is in the laptop Mac's login keychain
    and validated. Nothing has been notarized yet.
  - Back up the Sparkle private key (`generate_keys -x`) to a password manager.
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
- Transfers were checked end to end against the dev box only, not against the build Mac, a large tree or a slow link.

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
- **Builds from a fresh clone.** `clothod/dist` is gitignored. The Mac mirror the dev box uses
  (`~/Builds/clotho-clothod`) already holds the 0.1.5 dist. After a new release, run `dist.sh` on a Mac
  or copy the new dist into that mirror. Mac `--dev` builds otherwise make a dev dist in
  `clothod/target/dist-dev`.
- **From the dev box.** `clotho-mac <cmd>` runs Xcode builds on this Mac. Signing, archives, TestFlight and
  installing the app need the Mac's own session, because the keychain is locked over SSH.

### clothod
- **The Linux allocator.** Linux must keep the tuned mimalloc in `src/alloc.rs` (eager commit off,
  purge delay 0). musl malloc grew to 24 GB RSS in an hour against a ~165 MB live heap. Don't change it
  without re-running the hour soak.
- **Vendored alacritty_terminal.** It's in `vendor/` (see VENDORED.md), patched with
  `MAX_CACHE_SIZE` 100. Re-apply that patch on any alacritty upgrade.
- **Linux builds.** These need zig and cargo-zigbuild, because ring has C code. The dev box has Rust but not
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
- **The dev box dirs.** The SSH tests use `~/.local/share/clotho-ios-dev` on the dev box. Never touch
  `~/.local/share/clothod`.
- **Push testing.** `simctl push` skips notification service extensions. Test decryption with
  PushTests (which include a vector sealed by Rust), or the gated PushUITests
  (`/tmp/clotho-ios-push-e2e`).
- **UI.** Keep actions in menus and swipe actions. Split large SwiftUI bodies, because type-checking
  times out on them. Put accessibility identifiers on the NavigationLink.
- **The push setup** in the developer account: extension `nyc.amin.clotho.notify`, Keychain group
  `$(AppIdentifierPrefix)nyc.amin.clotho.shared`. Deploy the relay with `npm run deploy`, only when asked.
