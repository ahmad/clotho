# Clotho session engine plan

Source: herdr-46 session (repo /Users/me/Projects/herdr), 2026-10-26.
Tasktrail: "Plan a native session engine for Clotho" (task_dc0f4f70-cd71-4ff1-b0a2-c205a3ef0fc7).

Goals: mobile, native UI, remote machines.

## Repository layout (user decision, 2026-10-26)

Everything for Clotho lives in /Users/me/Projects/clotho, with one subfolder per sub-project:

- `clothod/`: Rust daemon (holder, logic, protocol crate, test client)
- `ClothoKit/`: shared Swift package (protocol client, model store, terminal view)
- `mac/`: macOS app
- `ios/`: iOS app (later)
- `docs/`: shared docs, including the protocol spec both sides build against

## Agents (2026-10-26)

- clotho-f5: orchestrator, runs from the repo root and coordinates the others.
- clothod-80: builds `clothod/` and owns `docs/protocol.md`.
- mac-d8: builds `mac/` and `ClothoKit/`. Milestones: M0 scaffold (copy of the herdr app), M1 model
  and backend interface, M2 FakeBackend, M3 native UI, M4 shortcuts as API calls, M5 real clothod
  backend.
- ios-c2: builds `ios/` (remote-only; SwiftNIO SSH transport). Milestones: I1 simulator against the
  local Mac daemon, I2 pane UI, I3 NIO SSH with Keychain keys and TOFU, I4 remote sessions once
  the bridge and docs/remote.md exist. mac-d8 owns ClothoKit; iOS asks it for API changes.
- Agent status (user request, 2026-10-26): the daemon owns a pane `agent` field (kind, state
  starting/running/waiting/done/error, source hook/detected, message, since, attention, session),
  an `agent` transition event and `agent.ack`. Status comes from `clothod report` via Claude/Codex
  hooks, with process/activity detection as a fallback. `clothod hooks install` runs only after the
  user confirms. The Mac and iOS apps get an Agents section across all machines, with notifications.
- One instance, one version per machine (user decision, 2026-10-26). The holder upgrades in place
  (re-exec in the same pid, inheriting the PTY fds), so `clothod upgrade` leaves a single build
  running. Test and dev daemons are temporary and always cleaned up.
- Client-facing pane snapshots are VT byte streams that SwiftTerm can feed after a reset.
- No git init or commits until the user says so.

## Why not herdr

herdr 0.9.1's socket API (protocol 22) has control calls (pane.split/focus/send_keys, layout.*,
events.subscribe, agent status) and pane.read (a one-time text snapshot), but no live output stream
for a single pane. The only live view is herdr's composited TUI. That's why Clotho masks herdr's
chrome, samples pixels for tab colors, and runs shortcuts by typing prefix keys. Native panes and
mobile both need separate per-pane streams and resumable connections, which herdr doesn't offer.

## Design

### 1. Per-machine daemon `clothod` (Rust)

- Runs on macOS and Linux (x86_64 and arm64) from step 1 (user decision, 2026-10-26). Platform
  differences (paths, cwd/process lookup, launchd vs systemd) live in one module; Linux ships as
  static musl binaries; step 1 tests also run on Linux.
- Owns the PTYs; sessions outlive clients.
- Runs a headless VT for each pane (alacritty_terminal or libghostty's VT core), so a reconnecting
  client gets the exact current screen.
- Owns the model: Machine > Workspace > Tab > split tree > Pane, with stable IDs. The UI renders the
  tree and never infers it from the screen.
- Agent status through a `clothod report` CLI called by Claude/Codex hooks, with terminal titles as
  a fallback.
- File APIs (list/stat/read/write streams) replace the Python-over-SSH listing script and the cwd
  lookup via `herdr pane list`; cwd comes from OSC 7.
- Keep the process that holds the PTYs separate from the logic (or hand file descriptors over on
  upgrade) so updating the daemon doesn't kill shells. Herdr's equivalent is server.live_handoff.

### 2. Protocol

- One connection multiplexes control (commands plus an event subscription) and per-pane data
  channels; clients subscribe only to the panes they show.
- Pane output carries sequence numbers and the daemon keeps a buffer of recent output. A
  reconnecting client sends "have up to seq N" and gets only what it missed, or a fresh screen
  snapshot if the gap is too big.

### 3. Transport

- Mac to a remote machine: `ssh host clothod bridge` over stdio. Reuses ~/.ssh/config and keys,
  works over Tailscale, no open port.
- iOS: SwiftNIO SSH, keys in the Keychain/Secure Enclave; resume makes iOS suspending the app cheap.
- Local: Unix socket.
- Later: a tailnet-only QUIC listener.

### 4. Clients: shared Swift package `ClothoKit`

Protocol client, model store, terminal view on SwiftTerm (libghostty as an upgrade path), machine
list synced through CloudKit.

- macOS: native sidebar (machines > workspaces, agent status badges), native tabs, split views with
  one terminal view per pane and draggable dividers, native find and selection, system
  notifications. Shortcuts become API calls, not keystroke injection.
- iOS: machine/workspace/agent list, one pane full screen, pane switcher, key bar
  (esc/ctrl/tab/arrows), quick replies to agents.

## Hard problems

- A PTY has one size, but several clients may watch a pane. Suggestion: the client that typed most
  recently sets the size; the others scale or letterbox.
- iOS push notifications need a small APNs relay.
- Installing and upgrading the daemon remotely: version check on connect, auto-install over SSH.

## Cheaper prototype option

tmux control mode (-CC), the way iTerm2 does it, gives per-pane output and layout events and could
prove out the native Mac UI quickly. Loses agent status, mobile resume, file APIs and the size
policy, so it's a throwaway, not the foundation.

## PTY holder / logic split (proposed, awaiting user confirmation)

Recommendation from herdr-46: design it in from step 1, kept minimal, because whichever process
owns the PTY fds shapes spawn, resize, reconnect and the output buffer.

- Holder (small, stable, rarely upgraded): forks and execs shells, holds master fds, handles
  resize, keeps the seq-numbered output buffer per pane, and speaks a tiny protocol to the logic
  process over a Unix socket.
- Logic: model tree, headless VT, client protocol, agent status, file APIs. After a restart it
  rebuilds each VT from a stored snapshot plus a replay of the holder's buffer.
- Step 1 may use two binaries, one binary with two modes, or (if short on time) a holder behind a
  trait in one process, provided the fds and buffer never leak out of it.
- Open point: the buffer is bounded and the holder has no VT, so the logic process must
  periodically push VT snapshots (tagged with their seq) to the holder for storage. A rebuild then
  loads the latest snapshot and replays the output after its seq.
- Step 1 done test: kill the logic process while a shell is running, restart it, reattach, and get
  the screen back intact.

## Build order

1. Daemon plus one durable local pane: the Mac app renders it, quits, reopens, and gets the exact
   screen back. This is the riskiest step.
2. Model and native Mac UI (sidebar/tabs/splits, shortcuts as API calls); drop herdr locally.
3. Remote: SSH bridge, auto-install, file transfers moved onto the daemon.
4. iOS app on ClothoKit.
5. Agent status and notifications, then the push relay.

## Clipboard from agent TUIs (user decision, 2026-10-27)

- Copying inside Claude Code and Codex must reach the device clipboard. Panes may set the clipboard
  through OSC 52, which clothod forwards to attached clients. Panes may never read it.
- Modifier-drag (Option/Shift) forces a local selection while a pane has mouse reporting on.
- The user approved releasing it everywhere: clothod 0.1.6, upgraded in place on macbook, devbox and
  imac, the Mac app installed, and an iOS TestFlight build with the same support. This is together
  with the Shift+Return, rename-flicker and Cmd-arrow/Cmd-Delete fixes.

## Image paste into remote agents (user decision, 2026-10-27)

- When an image is pasted into a remote pane (Cmd+V, or Ctrl+V when an agent runs there), the Mac app
  uploads it to `~/.cache/clotho/paste/` on that machine and pastes the path. Files older than 7 days
  are pruned. Files dropped on a remote agent pane go to the same folder. Nothing lands in the
  user's project folders.
- Right-click and Ctrl-click always open the pane menu, even in apps that take the mouse.
  Option+right-click passes through to the app.

## Next round (user decision, 2026-10-27)

The user approved all of the following. The orchestrator commits and pushes to GitHub as each piece
is verified; this is a standing go for this round.
- clothod:
  - `clothod service install|uninstall|status` (a LaunchAgent or a systemd --user unit), also
    exposed through the protocol. The user turns it on per machine from the apps; agents never
    install it on the user's machines.
  - A runtime scrollback setting through the protocol, persisted to config.toml.
  - Run the macos-x86_64 and linux-aarch64 builds for real.
  - Release 0.1.7 and upgrade in place on all three machines.
- mac:
  - A Settings window (notification mutes, scrollback, start at login).
  - Collapsible machine groups, wider agent rows, and cleanup of orphaned upload parts.
  - Transfer tests against imac, a large tree and a slow link.
  - A Developer ID and notarized release path (the user creates the cert and the notary profile).
- ios:
  - Parity: image paste and photo upload into remote agents, a newline key, the hardware-keyboard
    Cmd keys, and the pane menu in apps that take the mouse.
  - The same settings as the Mac.
  - A fix for the host-key hang.
  - A TestFlight build at the end, which the user uploads at the Mac.
- The Mac reaches imac under clotho-mac through a `Host imac` entry in the Mac's ~/.ssh/config
  (`IdentityFile ~/.ssh/id_ed25519_clotho`). The original config is backed up as
  config.bak-2026-10-27.

## Agents panel: attention first, resolve to collapse (user decision, 2026-10-27)

- Only agents that need attention (the daemon's `attention` flag) show at the top. All other agents
  go in a collapsible "Running" section, collapsed by default.
- A checkmark on each row resolves it, through `agent.ack`. It drops into the collapsed section on
  every device, and comes back out when attention is raised again.
- Same on the Mac and the iPhone. No daemon change.
- How agents raise attention: hook-less Claude Code never rings the bell in Clotho (TERM_PROGRAM=clotho
  isn't one it rings for), so detected agents would never reach the top. The user chose agent hooks
  ("Set Up Agent Status…") on each machine (2026-10-27). Opening an agent no longer acks it; only
  the checkmark, typing, or a quick reply do.

## clothod 0.1.8 (user decision, 2026-10-27)

- The user asked to "ship 0.1.8 whenever you can": release it and upgrade in place on macbook, devbox
  and imac, then reinstall the Mac app with 0.1.8 bundled. It carries the upgrade-race fix (68497ac):
  `upgrade` moves `current` first and holds `upgrade.lock`, so a client's restart can't revive the old
  build.
- Agent hooks (Claude Code and Codex) were installed on all three machines at the user's request
  (2026-10-27). The backups are `*.bak-2026-10-27-clotho-hooks` next to ~/.claude/settings.json and
  ~/.codex/config.toml.
- TestFlight build 202610271418 (bundling clothod 0.1.7) was uploaded by the user, then 202610271446
  (the Panes icon, clothod 0.1.8).
- App icon: "Panes" (option 3 of clothod's options page) on iOS and the Mac. The user said this
  directly to clothod ("I like option 3. Panes. use that everywhere"). The user also told clothod
  "upload to testflight when the icon is in". The upload runs from the Mac's own session, so the
  user runs testflight.sh.
- imac has Start at login installed; the user turned it on from Settings (confirmed 2026-10-27).
- Machine group headers put the chevron on the left of the name, the same as the Agents "Quiet"
  header (user feedback).

## clothod 0.1.9 (user decision, 2026-10-27)

- The user said "ship it" for 0.1.9: release it, upgrade in place on macbook, devbox and imac, reinstall
  the Mac app with 0.1.9 bundled, and prepare a TestFlight build, which the user uploads at the Mac.
- New attention rule (user request): an agent leaves the top list only when it works again
  (running or starting from a hook, or Claude's title spinner) or when the user resolves it
  (agent.ack). Viewing, input, focus and mouse reports, and detection's output guesses never clear
  it. Quick replies, Deny included, don't ack.
- Resolve vs Mute (user request, 2026-10-27; the user was fine with "Silent" or "Mute", and the
  name chosen is Mute):
  - Resolve (agent.ack) hides an agent until its next attention, as now.
  - Mute (`agent.mute {pane, muted}`, daemon-owned and synced) keeps it in Quiet with no attention,
    no notifications and no pushes, until the user unmutes it or the agent session ends.
  - Both actions appear on hover on the Mac and as swipe or menu actions on iOS. It ships with the
    next clothod release (0.1.10), which needs the user's go.

## clothod 0.1.10 (user decision, 2026-10-27)

- The user said "ship when everything is completed". When Mute (daemon, Mac and iOS) and the Mac
  batch (pinned agent time, app-wide zoom, thicker tabs, Create Workspace buttons, Manage
  Machines) are done and verified, release 0.1.10 and upgrade in place on macbook, devbox and
  imac. Then reinstall the Mac app with 0.1.10, and prepare a TestFlight build, which the user
  uploads at the Mac.
- Sidebar (user request): a subtle outline "Create Workspace" button at the bottom of each machine's
  workspace list replaces the header "+". A "Manage Machines…" footer pinned to the bottom of the
  sidebar opens a panel to add, edit and remove machines. Removing only forgets the machine.
- Website (user decision, 2026-10-27): a landing page at clotho.app is built by a separate session
  in ~/Projects/clotho.app. Its CTA is "Join the waitlist"; the tagline is still open. It must
  never name machines, the repo, the relay URL, bundle or team ids, or "Session" (use
  Workspace/Tab/Pane).

## Round 3 (user decision, 2026-10-27)

The user approved all four areas. Verified pieces are committed and pushed as they land. Any
clothod release, app install or TestFlight upload still needs the user's go when it's ready.
- Security and reliability:
  - clothod: a security review and docs/security.md, with each fix tested; the transfer hang and
    proven resume after a cut.
  - mac: the client-side stall detection.
- First-run onboarding on the Mac and iOS: intro, add a machine with an SSH check, install clothod,
  offer hooks and Start at login. Skippable.
- In-app Mac updates: Sparkle 2 with an EdDSA-signed appcast at https://clotho.app/appcast.xml. The
  private key lives only in the Mac's keychain, generated by the user.
- Polish:
  - Cmd+P quick open
  - scrollback search (a clothod request plus a UI)
  - agent history (a bounded per-agent log in clothod plus a view)
  - iPad split view
  - light mode on the Mac and iOS

## clothod 0.1.11 and the sidebar rows (user decision, 2026-10-27)

- Workspace rows: the status dot sits right after the name, like the machine dot. The tab count is
  pinned to the trailing edge. The close button shows only on hover, in the count's place.
- The user asked the mac agent to install the app. It bundles clothod 0.1.11.
- The user chose to upgrade devbox, macbook and imac to 0.1.11 in place once the iOS tests passed,
  then refresh the hooks. TestFlight is still the user's to run.
- The installed app bundled macbook's dev dist of 0.1.11, and the user's "Update clothod" put that
  build on all three machines. It predates 0488b00 (the push record cap, the report caps, and hooks
  status `outdated`). The user chose to ship 0.1.12 from HEAD: upgrade in place, reinstall the app
  with the released dist, refresh the hooks, then TestFlight. The user's install of the app should
  only ever bundle a released dist.

## Fewer pushes (user decision, 2026-10-28)

- A push means the agent needs the user. clothod ignores:
  - Claude's idle reminder (idle_prompt) and auth_success
  - SessionStart after compaction
  - reports from agents nested under the pane's agent
- A turn that ends while the user is at the pane (a client showing it sent input in the last
  60 s) raises attention in the app but doesn't push. Permission prompts, questions and errors
  always push.
- Turns the user didn't type (peer messages, background tasks) still push when they end. The
  user chose this; it avoids depending on Claude Code's prompt wrapper.

## iOS redesign (user decision, 2026-10-28)

- Home: one screen. Agents that need the user are pinned on top, with inline actions (Allow,
  Deny, Open). Every machine's workspaces sit below, each machine showing "last seen" or
  "connecting".
- Saved state: workspaces, tabs, panes, agent states and each pane's last screen are shown at
  once from the phone's saved copy, dimmed and read-only until live.
  - Terminal text is stored encrypted by iOS and excluded from backups.
  - It's on by default, and Settings has "Keep pane previews" to turn it off and clear it.
- Agent inbox actions: Allow/Deny and quick reply from the list and from the notification.
- A better terminal screen: swipe between tabs, a key bar (Esc, Tab, Ctrl, arrows, Newline),
  bigger tap targets, haptics, pinch to zoom.
- Lock screen and widgets: a Live Activity or Dynamic Island for a running agent, and a widget
  for agents that need the user.
- Onboarding: much simpler and easy to follow.
- Terms stay Workspace, Tab and Pane.
- The phased plan was approved by the user. Phases in order:
  1. saved state
  2. the one-screen Home, which replaces the iPhone machine screen; machine settings and files move
     into a menu on the machine header
  3. three-step onboarding
  4. Allow/Deny/Reply
  5. the terminal screen
  6. the widget, then the Live Activity
- Allow/Deny: clothod starts now, in parallel. It uses Claude's PermissionRequest hook and an
  `agent.decide` bound to the request id, and runs a spike first. Installing the new hook on the
  user's machines needs the user's OK.
- The Live Activity shows generic content only: agent kind, state and elapsed time.
- Notifications carry more detail: workspace, project, duration, and the result or the command
  waiting for permission. This ships in 0.1.13.

## clothod 0.1.13 (user decision, 2026-10-28)

- Ship once the iOS suite passes. The batch:
  - in-place upgrades on devbox, macbook and imac
  - the Mac app install
  - the TestFlight command, for the user to run
- 0.1.13 contains the push fixes (quiet, nested agents, idle reminders, compaction), the
  notification detail, and Allow/Deny (agent.decide).
- Install the two new Claude hooks (PostToolUse, and PermissionRequest with timeout 3600) on each
  machine, so there are 8 Clotho entries. The user's own hooks are kept, with backups.

## TestFlight uploads (user decision, 2026-10-28)

- The orchestrator uploads to TestFlight itself, without asking, once a build has passed the full
  iPhone suite and the iPad test and has been verified. It reports the build number afterwards.
- Uploads run over SSH, the way the user's ~/.local/bin/deploy-testflight does: unlock the
  keychain from the Mac's ~/.keychain_pw, and use the App Store Connect API key. The key ids are in
  devbox's ~/.config/clotho/asc.env, outside the repo.

## clothod 0.1.14 (user decision, 2026-10-28)

- The user said "release everything you can now". The batch:
  1. clothod 0.1.14: the upgrade start waits for the old serve to exit (a5f35b1), and a `cd` shows
     up without OSC 7 (c0c137f). In-place upgrades on all three machines.
  2. The Mac app reinstalled, bundling 0.1.14.
  3. A TestFlight build of main bundling 0.1.14, after the full iPhone suite and the iPad test.
     The redesign branch isn't included.

## clothod 0.1.15 (user decision, 2026-10-28)

- Release: clothod.log names who closed a workspace, tab or pane, how each pane ended, and who
  answered each permission request (17385b7).
- The batch: in-place upgrades on all three machines, a Mac app reinstall, and a TestFlight build
  of main bundling 0.1.15 after the full iPhone suite and the iPad test.

## The widget (user decision, 2026-10-28)

- The user approved the "Needs you" widget (home and lock screen). The next TestFlight upload
  registers one more App ID, nyc.amin.clotho.widget, with keychain sharing only, so there's no new
  capability. It never shows terminal text.
- Live Activity (generic content only): the relay endpoint and the clothod change may be built and
  tested. Deploying the relay and releasing clothod for it each need the user's go.

## Live Activity on (user decision, 2026-10-28)

- Ship all three: deploy the relay's /v1/activity (ios, wrangler), release clothod 0.1.16 with
  push.activity (in-place upgrades on all three machines, after test-all), then upload a TestFlight
  build with LIVE_ACTIVITY=YES after the full iPhone suite and the iPad test. The Mac app is
  reinstalled with 0.1.16.

## clothod 0.1.17 (user decision, 2026-10-28)

- "ship it": clothod 0.1.17 (a chained Codex notify reads as installed or outdated "(chained)";
  install and uninstall edit only clotho's part), the Mac app's matching fix (67f583f), and a
  TestFlight build bundling 0.1.17 after the full iPhone suite and the iPad test. In-place upgrades
  on all three machines.
- Updating macbook's outdated chained Codex hook still needs the user's OK.

## Shipping without asking (user decision, 2026-10-28)

- "Can you stop asking me to ship things and just do it." The orchestrator ships verified work
  without asking: clothod releases and in-place upgrades, Mac app installs, TestFlight uploads,
  relay deploys, and refreshes of Clotho's own hooks. It reports afterwards. It still asks for new
  kinds of hooks or other changes to the user's config files, deleting user data, and new things
  in the Apple or Cloudflare accounts. CLAUDE.md has the rule.

## macbook's Codex hook (user decision, 2026-10-28)

- The user approved updating macbook's outdated chained Codex hook: `clothod hooks install codex`
  edits only clotho's command inside Computer Use's notify (`--previous-notify`) in
  ~/.codex/config.toml, with a backup first. Nothing else in that file changes.

## Live Activity detail (user decision, 2026-10-28)

- The user saw "Claude is working" and asked for more, then chose "Everything". This replaces the
  generic-content-only rule above. Updates now carry the same detail notifications show: the tool,
  the current command or file, and Claude's last message (or the question waiting for an answer),
  each capped. The user accepted that Apple and the relay see this text unencrypted.
- The phone also saves the machine, workspace, tab and prompt into the activity when the user taps
  Follow. Those never leave the phone.
- Ship when verified (Shipping rule): clothod release with in-place upgrades, relay deploy if needed,
  TestFlight after the full iPhone suite and the iPad test.

## Mac downloads (user decision, 2026-10-28)

- New users download the Mac app from clotho.app/downloads (the user wrote "clothoc.app", read as a
  typo: clothoc.app doesn't resolve, and clotho.app is the live Vercel site). The Sparkle feed is
  clotho.app/appcast.xml, as release.sh and the app already expect.
- Signing is ready on macbook: the Developer ID certificate (expires 2027-02-01, G1 CA), the
  `clotho-notary` profile, and the Sparkle key pair (public key in mac/Resources/SparklePublicKey).
- The first public release follows the sidebar work: a notarized build, the zip in /downloads, the
  appcast, and a Download button on the landing page.
- Hosting (user decision, 2026-10-29): the zip is a static file in the clotho.app Vercel project
  (~/Projects/clotho.app), beside /downloads and /appcast.xml. Work starts now, in parallel. The
  first public build waits for the sidebar fixes and a Developer ID-signed clothod (0.1.19).

## Sidebar and command bar (user decision, 2026-10-29)

- Tabs come out of the sidebar again: workspace rows only (no tree, toggles or guide lines). The row
  keeps its most urgent agent dot on the right, a hover "+" for New Tab, Close in the right-click menu
  (and ⇧⌘W), and New Workspace opening the inline rename.
- ⌘P becomes a quick command bar. Empty, it lists the current workspace's tabs with the current tab
  selected; ↑/↓ and Return switch. Typing filters across all machines' workspaces, tabs and agents,
  with waiting agents first. It's instant, from the model in memory.
- Search ranks workspaces first once you type (a name match beats tabs that match), and choosing a
  workspace goes to the tab last active in it, falling back to its first tab (user, 2026-10-29).

## Restore after a restart (user decision, 2026-10-29)

- When a machine restarts (or the holder dies), clothod brings back the workspaces, tabs and panes:
  names, order, split tree, focus and each pane's folder. It saves this layout to the user's data dir
  on every change. It restores only when there's no holder to adopt, never on an in-place upgrade.
- Claude Code and Codex conversations come back: a pane that had an agent session runs
  `claude --resume <id>` (or Codex's resume) in a fresh shell in that folder. Plain resume only, so
  flags like --dangerously-skip-permissions are not carried over.
- Scrollback isn't needed ("don't care about scrollback that much").
- Running programs other than the agents don't come back. The apps show a small "Restored after
  restart" note.
- Getting session ids must not need new kinds of hooks or other changes to the user's config without
  asking.
- A full shutdown (`clothod shutdown`, "restart sessions") keeps the layout, so the next start brings it
  back (user confirmed). `clothod shutdown --forget` also clears the saved layout. Closing a workspace
  is how to forget it.

## Drag to reorder (user request, 2026-10-29)

- Drag workspaces in the sidebar and tabs in the tab bar to reorder them. Drag a tab onto another
  workspace to move it there, with its shells intact. This works within one machine only, since a
  pane's shell lives on its machine.
- clothod adds `workspace.move` and `tab.move` (feature "move") in 0.1.22. The Mac app does the drag UI,
  and the iPhone follows later.

## Git info per pane (user decision, 2026-10-29)

- clothod reports each pane's repo, branch (or detached sha), linked worktree and PR. It finds the
  repo by reading files, never by running the repo's own code, and updates within a second of a
  branch switch.
- The PR comes from `gh pr view` on that machine (user: "Yes, via gh"). It's looked up when the branch
  changes, refreshed at most every 5 minutes, and cached. Machines without `gh` signed in show the
  branch only.
- The Mac shows it in all four places the user chose: the tab bar, the sidebar workspace row, a status
  strip in the focused pane (the PR opens in the browser) and ⌘P search. It ships as clothod 0.1.23
  with a Mac update.

## macOS: the daemon must not live in an SSH session's namespace (2026-10-29)

- Bug: on macOS, a daemon started over SSH stays in that SSH session's bootstrap namespace, which
  dies when the SSH connection closes. Its shells then can't reach DNS, user lookup, TLS trust or the
  keychain. imac's holder after the 14:28 reboot hit this, and so does macbook's SSH-upgraded serve
  (gh_auth).
- Fix: clothod starts serve and holder on macOS through launchd in the user's durable domain. The user
  approved restarting imac's daemon once that fix is in. Its shells end, and restore brings back the
  layout and agent conversations. macbook's serve is not restarted for now.
- Disk (2026-10-29): the user allowed one dip below the 20 GiB floor on macbook, for the 0.1.24 test
  and release builds only (abort under 8 GiB). Most of the space went to swap from the user's own
  dev server and browser, not to our builds.

## Mac UI batch (user, 2026-10-30)

- Branch and PR appear only in the pane strip (bottom of the pane), not in workspace or tab names. ⌘P still matches them.
- ⌘/ toggles the sidebar.
- The sidebar's bottom bar has three icon buttons: Machines, Settings, and a light/dark toggle (overrides the system; "Match System" stays available).
- Hovering a pane's top-right corner shows a small × that closes the pane.
- An empty workspace shows a centered empty state with a "New Tab" button (⌘T).

## Restore: agents across a reboot (user, 2026-10-30; clothod 0.1.25)

- An agent that quits just before a reboot is still resumed: layout.json keeps a pane's agent for 10 s after it leaves a live shell.
- A Claude without hooks gets its session from Claude's own ~/.claude/sessions/<pid>.json (read-only).
- With no known session, the user chose "only when unambiguous": `claude --continue` / `codex resume --last` runs only if that pane is the only saved pane with that agent in its folder; otherwise a bare shell. The pane is marked `restored.continued` and the apps say "Continued the latest conversation in this folder".
- Unreachable machines: 3 tries, then "Can't reach <name>" and a Reconnect button; wake and network changes retry automatically.

## Machines and files (user, 2026-10-30; Mac 1.0.9)

- Manage Machines has an on/off switch per machine. Off disconnects the app and stops reconnecting, and hides the machine from the sidebar, Agents and ⌘P. Its clothod and shells keep running. The local Mac can't be turned off.
- File manager: sort by any column, copy between any two machines (remote→remote streams through the Mac), and a per-machine filter field.
