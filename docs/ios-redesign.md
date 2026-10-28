# iOS redesign: phased plan

Source: PLAN.md "iOS redesign" (4953618; approved in ade4c3b). Terms: Workspace, Tab, Pane.
Each phase ends with a commit, the full iPhone suite plus the iPad test, and a TestFlight build only on
the user's go.

## Shipping order

| Phase | What ships | Needs from ClothoKit (mac) | Needs from clothod / relay |
|---|---|---|---|
| 1 | Saved state (instant open) | shared cache model | nothing (optional later: styled previews) |
| 2 | One-screen Home | row/"last seen" helpers | nothing |
| 3 | Simple onboarding | nothing new | nothing |
| 4 | Agent inbox actions (Allow/Deny/Reply) in app and notification | request field on AgentInfo, decide call | permission requests + `agent.decide` + a blocking hook mode |
| 5 | Terminal screen | nothing | nothing |
| 6 | Widget, then Live Activity | cache model reused by the widget | relay: Live Activity push type; clothod: activity updates |

Phases 1–3 are the core redesign and depend on nobody but mac's small cache model. Phase 4 has the only
real protocol work, so clothod can start on it in parallel with 1–3. Phase 5 is independent and could
move earlier if the user wants the terminal first.

## Phase 1: Saved state

What the user sees: the app opens on the last-known Home at once. Workspaces, Tabs, Panes, agents and each
pane's last screen are visible, dimmed, with "connecting…" per machine. Nothing is tappable to type into
until live; then it swaps in place with no jump. A push tap opens the saved pane immediately, dimmed,
and it goes live when the connection is up.

Design:
- One cache per machine: the model (workspaces, tabs, layout, pane titles, agents incl. attention/quiet),
  `lastSeen` (when the connection was last live), and per pane the last screen.
- Pane screens: for panes shown on this phone, the styled screen from SwiftTerm's buffer (colours kept),
  saved when leaving the pane, on background and every ~30 s while live. For panes never opened here,
  `pane.text` (plain text, one cheap request) fetched in the background after connect, at most the
  visible screen and only for panes in the model. Size cap per machine (e.g. 2 MB) with LRU.
- Storage: Application Support/Cache/<machine>.json + screens/, `isExcludedFromBackup`, Data Protection
  `.complete` for screens (app only, never read while locked) and
  `.completeUntilFirstUserAuthentication` for the small agents summary the widget and the notification
  extension read (Phase 6), in the App Group container.
- Settings: "Keep pane previews" (on by default). Off deletes all screens at once and stops saving; the
  model (names, agents) is still kept, because that's what makes the app open instantly.
- Removing a machine deletes its cache. Sign-out/"Reset" (onboarding's -CleanState) deletes all.
- Read-only means: no input, no key bar, actions greyed; scrolling the saved screen is allowed.

ClothoKit (mac): a `ModelCache` / `CachedMachineState: Codable` (workspace state + agents + lastSeen +
screens index) and `ModelStore` able to start from it in a "saved" phase and swap to live on `hello`.
The Mac can reuse it for its own instant launch. I'd ask mac for the type and the store hook; the file
I/O, protection classes and SwiftTerm screen capture stay in ios/.

clothod: nothing required. Later and optional: `pane.text` with `styled: true` (SGR runs) so previews of
panes never opened on the phone keep their colours.

Files: new ios/Clotho/Cache/ (SavedState.swift, ScreenCapture.swift), MachineConnection (save/restore),
PaneScreen + PaneHostView (read-only mode, dimming, swap), Settings, AgentNotifier.onOpen.

Risks:
- Stale data shown as current. Mitigation: always dimmed with "last seen 3m ago" until live; the swap
  replaces everything (no merge), and a pane that's gone live-side disappears on swap.
- Sensitive terminal text at rest. Mitigation: `.complete` protection, no backup, off switch, cap.
- The swap flickering or jumping scroll. Mitigation: keep the TerminalView, feed the live snapshot into
  the same view; UI test compares.
Tests: unit (cache round trip, protection attributes and backup flag set, size cap/LRU, "Keep pane
previews" off deletes files, machine delete removes cache); UI (launch with the dev clothod, quit,
relaunch with the daemon stopped: Home and the pane show dimmed and saved; start it: goes live; push
tap opens the saved pane).

## Phase 2: One-screen Home

Replaces the Machines list, the separate Agents section and the per-machine screen with one list.
Machine screens remain one tap away (header tap) for machine settings and files.

```
┌──────────────────────────────────────┐
│ Clotho                     🔍    ＋   │
├──────────────────────────────────────┤
│ NEEDS YOU                            │
│ ┌──────────────────────────────────┐ │
│ │ ✋ Claude · devbox › api          │ │
│ │ Allow Bash: rm -rf build?        │ │
│ │ [ Allow ]  [ Deny ]      Open ›  │ │
│ └──────────────────────────────────┘ │
│ ┌──────────────────────────────────┐ │
│ │ ✓ Codex · imac › web     2m      │ │
│ │ Finished: tests pass             │ │
│ │ [ Reply ]                Open ›  │ │
│ └──────────────────────────────────┘ │
│                                      │
│ DEVBOX                   connected   │
│   api ●                           3  │
│   web                             1  │
│   notes ●                         2  │
│ IMAC                  last seen 3m   │
│   build                           1  │
│ MACBOOK              connecting…     │
│   clotho ●                        4  │
└──────────────────────────────────────┘
```
- The dot after a workspace name means an agent in it needs the user (same as the new Mac rows); the
  count on the right is its Tabs. Tap a workspace: its last-used Tab opens; long press: its Tabs, rename,
  close. Swipe on a "needs you" card: Resolve, Mute.
- Pull to refresh reconnects. iPad keeps the sidebar (this list) plus the pane.

ClothoKit: if the Mac's row logic (dot rule, count) lives in the app, a shared helper keeps both
platforms the same; small ask to mac. clothod: nothing.
Files: new Home/HomeView.swift, NeedsYouCard.swift, WorkspaceRow.swift; RootView/SplitRootView switch to
it; MachineListView and AgentsSection retire.
Risks: losing functions that only the old screens had (machine settings, files, upgrade offer, new
workspace). Mitigation: list them all first and give each a home (header menu); existing UI tests move
over rather than being deleted. Tests: unit (ordering, dot/count, last-seen text), UI (Home shows cards
and rows from the dev clothod, open a workspace, Resolve from a card), iPad test updated.

## Phase 3: Onboarding, three screens

```
 1  Add a machine          2  Checking…                  3  Ready
┌──────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────┐
│ Where does Clotho    │  │ ✓ Reached devbox:22      │  │        ✓             │
│ run your terminals?  │  │ ? First time connecting  │  │ devbox is set up.    │
│                      │  │   SHA256:Xk3…9fQ         │  │                      │
│ Host  devbox         │  │   [ Trust ]              │  │ Your workspaces show │
│ User  ahmad          │  │ ✓ Logged in              │  │ on Home. Agents that │
│                      │  │ ✓ Installed clothod 0.1.12│  │ need you appear at   │
│ On devbox, run:      │  │                          │  │ the top.             │
│ ┌──────────────────┐ │  │                          │  │                      │
│ │ mkdir -p ~/.ssh …│ │  │                          │  │                      │
│ └──────────────────┘ │  │                          │  │                      │
│ [ Copy Command ]     │  │                          │  │                      │
│                      │  │                          │  │                      │
│ [   Continue   ]     │  │ [ Continue ]             │  │ [  Open Home  ]      │
└──────────────────────┘  └──────────────────────────┘  └──────────────────────┘
```
- The key is generated silently on screen 1 (import stays under "Use my own key…"). Screen 2 runs host
  key, login and install in one go and stops only to ask Trust, or with one readable error and a fix
  (the existing ConnectionCheck messages). No concepts page, no notification or login-item steps.
- Later, in context: notifications are asked the first time an agent needs the user (card on Home:
  "Get alerts when an agent needs you"); agent hooks ("Set Up Agent Status…") are offered on a card when
  an agent is first detected without hooks; Start at login lives in machine settings.
- Re-openable from Home's ＋ (add a machine); skippable.
Files: OnboardingView shrinks to 3 pages; ConnectionCheck, KeyStore reused; new Home cards for the
deferred offers. ClothoKit/clothod: nothing.
Risks: the deferred permission prompt never being seen. Mitigation: the Home card stays until answered.
Tests: the existing clean-state guide UI test is rewritten for the 3 screens (rejected key → fix → Try
Again, Trust, install), plus "notifications card appears on first attention".

## Phase 4: Agent inbox actions

### How Allow/Deny works reliably

Keys into Claude's prompt (today's quick reply sends 1/2/3/Esc) are fragile: the dialog's numbering
changes between versions and prompts, a keypress can land after the prompt moved on (allowing the next
question), and the phone can't see which prompt it is answering.

Proposed: answer through Claude Code's own `PermissionRequest` hook, which can return
`{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"|"deny",
"message"?}}}` (current hooks docs; default command-hook timeout 600 s).
1. clothod: a new hook mode, `clothod report --claude-permission`, installed for `PermissionRequest` by
   "Set Up Agent Status…". It registers a pending request with the daemon (`tool_name`, a short summary
   of `tool_input`, a request id) and waits for a decision.
2. The pane's agent gains `request: {id, tool, summary}` while it's pending, so every client shows exactly
   what it's allowing.
3. New request `agent.decide {pane, request, decision: "allow"|"deny", message?}`: it answers only that
   request id (`stale` if it's gone), so a late tap can never approve a different prompt.
4. The hook prints the decision and exits; the agent continues. If the hook times out, or the user
   answers in the terminal first, it returns no decision and Claude's own flow continues.

Open question to settle first (a short spike by clothod, with test Claude sessions using
`--setting-sources project,local`): whether Claude shows its terminal dialog while a PermissionRequest
hook is still waiting, and what happens when the user answers there. The docs say "whichever decides
first applies" for `--permission-prompt-tool`/SDK callbacks but don't state it for the terminal. If the
dialog waits for the hook, the hook must return quickly when the user is at the pane (the same 60 s
presence rule as quiet) and wait only when they're away, with a short default (e.g. 2–5 minutes, then
fall back to the terminal dialog).

Codex has no equivalent hook today: for Codex (and Claude without the new hook installed) Allow/Deny falls
back to keys, but only after `pane.text` confirms the expected prompt is on screen, and only Reply/Open
otherwise. Cards show Allow/Deny only when the daemon offers a `request`.

### As built in clothod (b75a7a6)

clothod built this ahead of phase 4 and checked it against a real Claude Code session; protocol.md has
the details under "Permission requests".
- Claude's terminal dialog always shows as well. Whichever answer comes first wins.
- The agent carries `requests: [{id, tool, summary}]`, oldest first, and several can be pending at
  once. `tool`/`tool_input` describe the newest.
- `agent.decide {pane, request, decision, message?}` answers that id exactly once.
  - A second answer, a retired id or an unknown id gets `stale`. The app says "Already answered",
    refreshes, and never retries.
  - clothod drops the request from `requests` before replying, so a card can show "Allowed" or
    "Denied" as soon as the reply arrives. Don't key that on the state: it stays `waiting` until
    the tool runs (allow) or Claude moves on (deny).
- Deny: by default the app sends the message "Denied from the phone". The notification's
  "Deny with reason…" text field sends the typed reason instead (at most 300 characters).
- Push: the record's `rq` makes a push actionable (with `tool`/`cmd` for that exact request). Only
  the first request of a wait pushes; the rest show in the app.

### Notification actions
- Category "agent.permission": Allow (`.authenticationRequired`, so never from a locked phone without
  Face ID), Deny, Reply (text input). Category "agent.done": Reply, Open.
- The push payload (encrypted, via the extension) carries the request id and pane; the extension sets
  the category, so the relay and Apple still see nothing new.
- A tapped action launches the app in the background: it connects to that machine over SSH, sends
  `agent.decide` (or the reply) and ends within iOS's ~30 s. If the machine isn't reachable, it posts
  "Couldn't reach devbox, open to answer" instead of failing silently.

ClothoKit (mac): `AgentInfo.request`, `decide(pane:request:decision:message:)`, feature string. clothod:
the hook mode, pending requests, `agent.decide`, hook install update, protocol.md. Relay: nothing (same
encrypted payload, slightly larger, inside the existing padding).
Risks: background SSH within the time limit (Tailscale off, slow network); approving the wrong thing
(prevented by request ids); security of Allow from the lock screen (authenticationRequired). Tests:
clothod e2e for request/decide/stale/timeout; iOS unit (categories, payload → action mapping); UI test
with a fake hook in the dev clothod (report a request, Allow from the card, the hook process prints
allow); a manual device test of notification actions (simulator can't fully drive background actions).

## Phase 5: Terminal screen

- Swipe between Tabs: an edge swipe (from the screen edge) or two-finger horizontal swipe, so it doesn't
  steal the terminal's own one-finger drags (selection, mouse mode, scroll). Page dots under the title.
- Key bar: Esc, Tab, Ctrl, ←↑↓→, Newline (already present; resized to 44 pt targets, the rest (| ~ / -,
  paste) moved to a second page or a long press).
- Haptics on key bar taps, Ctrl latch and tab switch (UIImpactFeedbackGenerator, light).
- Pinch to zoom: font size live while pinching, PTY resize (`pane.viewport`) once at the end; the size is
  remembered per device.
Files: PaneScreen, PaneHostView, KeyBar. ClothoKit/clothod: nothing.
Risks: gesture conflicts with SwiftTerm (selection, mouse mode); resize storms. Tests: UI (swipe changes
tab, pinch changes columns once, key bar keys reach the pane), unit (font size bounds).

## Phase 6: Widget, then Live Activity

### Widget: "Needs you"

- Shows the agents that need the user (the same rows as Home's top section): agent kind and state,
  workspace › machine, and how long ago. Small: the count and the newest one; medium: up to three; lock
  screen (accessoryRectangular/Circular): the count and the newest one. Tapping a row opens its pane
  (`clotho://pane/<machine>/<pane>`); tapping elsewhere opens Home.
- Target: a widget extension, ClothoWidget (`nyc.amin.clotho.widget`), built only with `WIDGET=YES` in
  xcodegen (like push.yml's `PUSH=YES`) until the user approves the new App ID (it's registered by the first
  archive that includes it).
- Data: a small summary, `AgentsSummary {updated, agents: [{machine, machineName, pane, workspace, kind,
  state, since}]}`, with no terminal text and no agent messages. The app and the notification extension
  write it to the Keychain access group they already share (`TEAMID0000.nyc.amin.clotho.shared`,
  `AfterFirstUnlock`); the widget reads it. That needs no App Group, so no new capability. An App Group
  would be the more usual path, at the cost of a new capability on all three App IDs.
- Freshness: the app writes the summary whenever its agent rows change, and reloads the widget timelines.
  The notification extension adds the agent from each alert it decrypts and reloads too, so the widget
  updates while the app is closed. An entry older than 12 hours shows as "earlier"; the app replaces the
  whole summary on every connect, which clears agents that were answered elsewhere.
- Tests: unit (summary encode, merge an alert into it, the age text); the widget's view rendered in a test
  through WidgetKit's preview isn't available in XCUITest, so a screenshot from the simulator's widget
  gallery is the visual check.

### Live Activity (design; nothing deploys without the user's go)

What it is: while an agent the user just prompted is running, a Live Activity on the lock screen and in
the Dynamic Island shows its kind, state and elapsed time, and ends when the turn ends (a "finished" or
"needs you" final state stays for a few minutes). Content is generic only (user decision 3): no titles,
prompts, messages or paths, because Live Activity updates aren't end-to-end encrypted.

Pieces:
1. App: `ActivityKit` in the widget extension (no new App ID beyond the widget's; Info key
   `NSSupportsLiveActivities`). The app starts an activity when the user sends a prompt from the phone
   (or taps "Follow" on a running agent), with `pushType: .token`, and gets its push token.
2. clothod: a new request `push.activity {pane, device, token, env}` registers the activity's token for
   that pane, and `push.activity_end {pane, device}` removes it. On the pane's agent state changes it sends
   an update through the relay: `{state, kind, since}` (no text). It sends `end` when the agent is done,
   errors or goes away, and drops the token after 8 hours (Apple's limit) or on 410.
3. Relay: `POST /v1/activity {handle, token, env, event: "update"|"end", content: {state, kind, since},
   stale?, dismiss?}`. It sends APNs with `apns-push-type: liveactivity`, topic
   `nyc.amin.clotho.push-type.liveactivity`, priority 5 for updates and 10 for end, and the aps payload
   `{timestamp, event, content-state, stale-date?, dismissal-date?}`. It's authorised by the same push
   handle as alerts; the activity token is per activity and short-lived. Its own rate limit is 60 updates
   an hour per handle (Apple budgets frequent high-priority updates).
4. Privacy: Apple and the relay see only the agent kind, state and timestamps for the activity, never what
   it's doing. This is the documented trade-off for a live, updating lock-screen item.

Steps that need the user's go: the widget App ID (first archive), the relay change and its deploy, and
clothod's new requests (its release). Tests: relay `npm test` for /v1/activity, clothod e2e for
push.activity, iOS unit tests for the activity attributes; the lock-screen behaviour is a device check.

## Decisions (user, 2026-10-28; PLAN.md ade4c3b)

1. Order as above: 1 Saved state, 2 Home, 3 Onboarding, 4 Inbox actions, 5 Terminal, 6 Widget then Live
   Activity. Phases 1–3 ship together.
2. Allow/Deny: clothod runs the PermissionRequest spike and builds `agent.decide` now. Until they land,
   cards show Reply and Open.
3. Live Activity content is generic only: agent kind, state, elapsed time.
4. Home replaces the iPhone machine screen; machine settings and files move into the machine header's
   menu.
