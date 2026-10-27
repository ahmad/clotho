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
