# Push alerts: agent attention to the iPhone

Status: **deployed** (2026-10-26). The relay runs at https://clotho-push.example.workers.dev
(Cloudflare Worker `clotho-push`, APNs key KEYID00000, team-scoped, sandbox and production); a real
sandbox push to the simulator, decrypted by the extension, passes. clothod's side is implemented
(ee398a7) and ships in the next dist build. The `.p8` lives only in `~/.config/clotho/` and in the
Worker's secrets.

Today the phone learns about agent attention only while the app is open and connected. This
design delivers the same signal when the app is closed or suspended, without showing anything from
the terminal to the relay, Apple, or the hosting provider.

```
clothod ──HTTPS──▶ relay ──HTTP/2──▶ APNs ──▶ iPhone ──▶ notification service extension
(encrypts)        (holds the .p8;            (decrypts, sets title and body)
                   sees only ciphertext)
```

## Flow

1. The phone asks iOS for an APNs device token, then registers it with the relay:
   `POST /v1/register {token, env}` returns a **push handle** (below).
2. The phone generates a push key pair (X25519) once, keeps the private key in the Keychain, and on
   every connect to a machine whose `hello.features` has `push`, sends that machine
   `push.register` with the handle, its public key, and the app's own id for that machine. This goes
   over the existing SSH connection, so the machine learns the key from a channel the user already
   trusts.
3. When a pane's agent `attention` goes from false to true (the same rule clients notify on; see
   protocol.md, Agents), clothod builds a small JSON record, encrypts it to each registered phone's
   key, and sends `POST /v1/push {handle, ciphertext, collapse_id}` to the relay.
4. The relay unseals the handle to the APNs token, signs an APNs JWT with the .p8, and posts the
   notification. The relay is stateless: it has no database of devices.
5. On the phone, the notification service extension decrypts the payload and replaces the
   generic text with the agent's state and message. A tap opens that pane (the app already routes
   notification taps to panes).

## Device registration

**Relay side: the push handle.** The handle is the APNs token, environment and creation time,
sealed with AES-GCM under a key only the relay has, with a key id in front so the key can rotate:
`base64url(key_id || nonce || AES-GCM(token, env, created))`. The relay never stores tokens. Holding
a handle means being able to push to that phone, so it is a capability and stays on the user's own
machines.

Anyone with the app can mint a handle, but only for their own token, so it only lets them push to
themselves. App Attest on `/v1/register` can close even that later; it isn't needed for a personal
TestFlight build.

**Machine side: new protocol requests**, behind a `push` feature string:

| request | params | reply |
|---|---|---|
| `push.register` | `device` (stable id chosen by the phone), `handle`, `key` (base64 X25519 public key), `label` (the app's id for this machine, echoed back in payloads), `relay` (URL), `env` (`sandbox` or `production`) | `{}`; replaces any earlier registration for the same `device` |
| `push.unregister` | `device` | `{}` |
| `push.list` | none | `{"devices": [{device, label, relay, env, created, last_error}]}`, never the handle or key |
| `push.test` | `device` | `{}` once the relay accepted it; for a "Send test alert" button |

clothod keeps registrations in `push.json` in its state directory (`~/Library/Application Support/clothod/` on macOS, `~/.local/state/clothod/` on Linux, or `$CLOTHOD_STATE_DIR`), mode 0600, so they survive daemon restarts and
upgrades. Ephemeral test instances (`--ephemeral`) keep them in the runtime directory, so they go
away with the instance.

The app re-registers on every connect (cheap, and it picks up a rotated APNs token) and sends
`push.unregister` when the user turns alerts off for a machine or removes it. A relay answer of 410
(token no longer valid) makes clothod delete that registration by itself.

## Privacy: end-to-end encrypted payloads

A payload of machine, pane and state only still tells Apple and the relay which machines you use
and when your agents stop. Encrypting is little extra work because CryptoKit (iOS 17) and the Rust
`hpke` crate implement the same HPKE suite, so the design encrypts everything.

- Suite: HPKE base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305 (RFC 9180).
  `info` = `"clotho push v1"`, `aad` = the collapse id.
- Plaintext, before encryption:
  `{"v":1, "m":<label>, "p":<pane>, "k":<kind>, "s":<state>, "msg":<message, at most 400 bytes>, "t":<since>}`.
  `msg` is the agent's own message (for example "Allow cargo test --release?"), never pane output.
- Detail (clothod 0.1.13), every key optional:
  - `w`: the workspace name. `wid`: its id, stable per daemon.
  - `tb`: the tab title.
  - `pj`: the project, the basename of the pane's cwd.
  - `q`: the first line of the prompt the user typed for this turn. It's absent for turns the user didn't type.
  - `tool` and `cmd`: only for a permission wait (Claude Code's `permission_prompt`). They're the tool it
    asks about and its key input, e.g. "Bash" and "npm test". Any other wait (a question) carries neither.
  - `rq`: the id of the permission request this wait is (clothod 0.1.13, feature `agent.decide`; at most
    64 bytes, never cut). A push with `rq` is actionable: Allow and Deny call `agent.decide {pane: p,
    request: rq, decision, message?}` on that machine, and `tool`/`cmd` describe exactly that request.
    It answers that request only, once; `stale` means it was answered already (here, in the app or in
    the terminal) or is gone. Only the first request of a wait pushes; others show in the agent's
    `requests` (docs/protocol.md, Permission requests).
  - `d`: done and error only. Seconds since the turn started.

  `msg` is now the result: the last reply on done, the error on error, the question or permission on waiting.
- How the phone shows it, the same for a push (the extension) and for the app's own foreground
  notification:
  - title: "Platform · Claude finished" (workspace · agent state)
  - subtitle: "devbox · api-server · 4m" (machine · project · duration)
  - body: the result. A permission wait (waiting, with `tool`, and a `msg` that is a permission
    message or absent) reads "Allow Bash: npm test?". clothod sends `tool` only for permission waits, so
    "waiting with `tool`" is enough; the `msg` check is a guard.
  - Alerts thread by machine and `wid`, so one workspace's alerts stack together.
  - An older record without these keys reads as before: "Claude finished on devbox", body `msg`,
    threaded by machine. Each missing part simply drops out.
- Sizes: every text is first held to its own cap, in bytes and cut on a character boundary: `msg` 400,
  `q` 240, `cmd` 240, `w`, `tb`, `pj` and `tool` 96 each. (At the source they are shorter still: a
  reply is at most 300 characters, a prompt 120, a tool input 160.) If the padded record would still pass
  2048 bytes (long names, text that JSON escapes heavily), clothod halves texts in this order until it
  fits: `msg`, `q`, `cmd`, `pj`, `tb`, `w`, and the label `m` last. A text is shortened only when every
  text before it in that order is already empty.
- Padding: clothod adds `"pad":"<spaces>"` as the last key, so every plaintext is a multiple of 1024
  bytes: 1024 for nearly every record, 2048 only for unusually long or escape-heavy texts, and never
  more.
  Otherwise the ciphertext's length would give away the message's. Readers ignore unknown keys, and an
  unpadded record from an older clothod still opens.
- Ciphertext on the wire: `base64(enc || ct)`, about 1,430 characters for a 1024-byte record (at most 2,800, for
  2048), under the relay's 3,000-character limit and well inside APNs's 4 KB.
- APNs payload the relay builds:
  ```json
  {"aps": {"alert": {"title": "Clotho", "body": "An agent needs you"},
           "mutable-content": 1, "sound": "default", "thread-id": "<collapse id>"},
   "e": "<ciphertext>"}
  ```
  If the extension fails or runs out of time, iOS shows the generic text, which reveals nothing.
- `collapse_id` = the first 32 hex digits of SHA-256(`label` + "/" + `pane`). It is stable per pane, so a
  second alert for the same pane replaces the first. The app gives its own foreground notifications
  the same identifier, so a push and a local banner never stack.
- The private key lives in a Keychain access group shared by the app and the extension,
  `AfterFirstUnlockThisDeviceOnly` (alerts must decrypt while the phone is locked), never synced.

What each party can still see: Apple sees the token, timing and ciphertext size (which padding makes the same for almost every alert). The relay and
its host additionally see the sending machine's IP address. Neither sees machine names, pane
titles, agent messages or anything from a terminal.

## Auth between clothod and the relay

The handle is the credential: `/v1/push` accepts only a handle that unseals under a current relay
key. There is no separate shared secret in clothod, so a machine needs nothing beyond what the
phone gives it. Everything is over HTTPS (the tailnet in the devbox option, below).

Revocation: the user turns alerts off in the app (it unregisters everywhere it can reach) or
deletes the app (the token dies and APNs answers 410). As a last resort, rotating the relay key
invalidates every handle; phones get new ones on their next launch.

## Rate limits and failure handling

In clothod, per registration:
- One push per attention false-to-true transition. Detection guesses never raise attention, so
  quiet output doesn't push.
- Except a rise into `done` while the user is at the pane: a client that shows the pane
  (subscribed) sent it input within the last 60 s. The user sees that turn end, so attention is
  raised (badges and the Agents list show it) but no push is sent. `waiting` and `error` always
  push. The agent's `quiet` field (clothod 0.1.13) says so: true on such a rise, kept until the
  next one. The app shows no local banner for it either; a missing field (older daemons) means
  false.
- Reports from an agent that the pane's agent runs (an SDK app under test, `claude -p` from a tool,
  `codex exec`) are ignored: `agent.report` answers `{"ignored": "nested"}`, and the pane's agent,
  its attention and pushes are untouched.
- Hook events that say nothing new leave the state and attention alone, so they never push: Claude
  Code's `Notification` with `notification_type` `idle_prompt` (the "waiting for your input"
  reminder a minute after a turn ends) or `auth_success`, and `SessionStart` with `source`
  `"compact"`. See docs/protocol.md, Agents, for the full hook mapping.
- At most one push per pane every 30 s (a newer one waits and is sent with the latest state), and at
  most 60 per device per hour. Past that, pushes are dropped and `last_error` says so.
- When the relay is unreachable or answers 429 or 5xx: retry with backoff (2 s doubling to 60 s) for
  up to 10 minutes, kept in memory only. Before each retry, drop the push if the pane's attention
  has been cleared in the meantime, so a stale "needs you" never arrives late. A daemon restart
  drops the queue.
- 410 deletes the registration. 400 or 403 (bad handle) is logged in `last_error` and that
  registration is skipped until the phone registers again.

In the relay, per handle: a token bucket of 120 an hour (Cloudflare's rate-limiting binding in the
Worker option; in memory otherwise), answering 429. APNs errors map through: 410 for
`Unregistered` or `BadDeviceToken`, 429 for `TooManyRequests`, 502 for the rest. The relay keeps
one APNs JWT and refreshes it every 40 minutes; APNs rejects tokens older than an hour and
throttles refreshes more often than every 20 minutes.

Clearing: APNs can't delete a delivered notification. When the app opens, it removes delivered
alerts whose pane no longer has attention. Doing it in the background would take silent pushes,
which iOS throttles heavily; that is left for later.

## Live Activities

A Live Activity follows one agent on the lock screen and in the Dynamic Island while it runs: where it is,
what it was asked, its state, the tool it's using and on what, its last message or question, and how long
the turn has taken. Unlike alerts, Live Activity content can't be encrypted for the phone (iOS shows it
without an extension). The first design carried no text at all (decision 3, docs/ios-redesign.md); after
seeing only "Claude is working", the user chose full detail and accepted that Apple and the relay see the
tool, the command or file, and the message unencrypted (PLAN.md, "Live Activity detail", 2026-10-28).
The machine, workspace, tab and prompt never leave the phone.

### The app

The app starts the activity (ActivityKit, `pushType: .token`) when the user follows an agent, sends its
push token to the machine with `push.activity`, and ends it itself when it's no longer wanted
(`push.activity_end` then only tells clothod to forget the token).

The activity's attributes are set on the phone at Follow and never sent anywhere: the machine's name, the
workspace and tab names, and the turn's prompt (one line, at most 120 characters). They're optional, so an
activity an earlier build started still decodes. The first content is built on the phone from the pane's
agent with the same mapping clothod uses; after that the machine's updates replace it.

The lock screen shows "devbox · Clotho / orchestrator", the state line ("Claude is running Bash", "Claude
wants to use Bash", "Claude finished"), the command or file in mono while it's in a tool, then the last
message or question (or, while running with no tool, the prompt), and the timer on the right. The compact
Dynamic Island shows the state's icon and the tool (an MCP tool by its last part) on the left, the timer on
the right.

### The relay

`POST /v1/activity {handle, token, env?, event: "update"|"end", content: {state, kind, since, started,
tool?, detail?, msg?}, timestamp, stale?, dismiss?}`, authorised by the same push handle as alerts:
- `token`: the activity's push token, 64–200 hex characters. `env` defaults to the handle's.
- `content` must have `state`, `kind`, `since` and `started`, and may have `tool`, `detail` and `msg`;
  any other key is a 400. `state` and `kind` match `^[a-z][a-z0-9_-]{0,31}$`; the times are positive
  integers (unix seconds). `tool` matches `^[A-Za-z0-9_.:-]{1,64}$`. `detail` and `msg` are non-empty
  strings of one line (no control characters, U+2028 or U+2029) of at most 200 and 300 Unicode scalars.
  The content's JSON is at most 3072 bytes (a backstop; the caps keep it near 2 KB at most). Anything
  else is a 400. The content goes to APNs unchanged.
- It goes to APNs with `apns-push-type: liveactivity`, topic `nyc.amin.clotho.push-type.liveactivity`,
  priority 5 for an update and 10 for an end, and ActivityKit's body
  `{aps: {timestamp, event, content-state, stale-date?, dismissal-date?}}`.
- Updates are limited per handle to a burst of 10 a minute (`ACTIVITY_LIMITER`; Cloudflare counts over
  60 s at most); an end always goes through. APNs answers map as for alerts: 410 for `Unregistered`,
  `BadDeviceToken` and `ExpiredToken`, 429, else 502.

### clothod: requests (feature flag `push.activity`)

| method | params | result |
|---|---|---|
| `push.activity` | `pane`, `device` (a `push.register`ed device), `token` (the activity's push token, 64–200 hex characters), `env?` (`sandbox`/`production`, default the registration's) | `{}`. Replaces an earlier one for the same pane and device. `not_found` without a registration for `device`; `bad_request` for a bad token or env |
| `push.activity_end` | `pane`, `device` | `{}`. Forgets the token; nothing is sent (the app ends the activity itself) |
| `push.list` | – | adds `activities: [{pane, device, created, last_error}]` |

### clothod: what it sends

`POST {relay}/v1/activity` with `{handle, token, env, event, content: {state, kind, since, started, tool?, detail?, msg?}, timestamp, stale | dismiss}`:
- `state`: `running` (also while the agent is starting), `waiting`, `done` or `error`. `kind`: the agent
  kind, made to fit `^[a-z][a-z0-9_-]{0,31}$` ("other" if it can't). `since`: unix seconds when the
  current state began. `started`: unix seconds when the turn began, else `since`. That is the elapsed timer,
  so running → waiting → running doesn't reset it.
- `tool` (at most 64, ASCII, `^[A-Za-z0-9_.:-]{1,64}$`, else left out) and `detail` (the tool input's
  summary: the command, file path or pattern; at most 200): with `running` and `waiting` only. While
  waiting on a permission request they are the request's tool and summary, as in the alert.
- `msg` (at most 300): `done`, the last message; `error`, the error; `waiting`, the text the alert shows.
  Never while running.
- Each is left out when it doesn't apply, never `""` or null. The caps count UTF-8 bytes of the
  JSON-escaped string, which is never less than the relay's count; a cut string ends with "…", counted
  inside the cap. Control characters, U+2028 and U+2029 become spaces, runs of spaces fold to one, and
  the ends are trimmed. Never the prompt, title or workspace: those stay on the phone.
- `update`: right after `push.activity` if the pane's agent is running or waiting. With no agent, or one
  whose turn already ended, it waits for the next change. Then on every change of state, kind, times, tool, detail or msg, at
  most one per activity every 10 s; the latest state is sent at the end of the window.
  `stale` = `timestamp` + 15 min.
- `end`: at once, outside the window, when the agent reaches `done` or `error`, goes away, or its pane
  closes, with the final state as content. `dismiss` = `timestamp` + 5 min. The token is dropped then.
- `timestamp`: unix seconds, increasing per activity, so APNs can drop out-of-order updates.
- Presence (`quiet`) and `muted` don't apply: the user chose to follow this agent.
- Tokens are kept across restarts and upgrades (`push-activities.json` next to push.json, mode 0600).
  They're dropped on `end`, a 410, after 8 hours (Apple's limit), on `push.activity_end`, and on
  `push.unregister` of the device. An update that fails isn't retried, because the next one supersedes it.
  An `end` is retried with the same backoff as alerts. Other failures show as the activity's `last_error`
  in `push.list`.

Live Activities shipped with the relay's `/v1/activity`, clothod 0.1.16 and TestFlight builds made with
`LIVE_ACTIVITY=YES`. The detail fields need the relay deployed with them before a clothod sends them,
because the relay as first deployed rejects any key beyond the four.

## Hosting the relay

The relay is about 150 lines: two endpoints, AES-GCM, an ES256 JWT, one HTTP/2 POST. APNs itself
is free.

| | Cloudflare Worker | On devbox, over the tailnet | Small VPS |
|---|---|---|---|
| Cost | $0 on the free plan (100,000 requests a day; this needs hundreds at most). $5 a month only for more | $0 | $4 to $6 a month (Hetzner, DigitalOcean, and similar) |
| Reachable from | any machine with internet | only machines on the tailnet | any machine with internet |
| Uptime | Cloudflare's | only while devbox is up; if devbox is down, no alerts from imac either | the VPS's |
| Where the .p8 lives | a Worker secret on Cloudflare | devbox's disk | the VPS's disk |
| Ops | none after `wrangler deploy` | a systemd service on devbox to keep running | OS updates, TLS (Caddy), monitoring |
| Catches | needs a Cloudflare account. `wrangler dev` can't reach APNs (local workerd has no HTTP/2), so testing runs against a deployed preview Worker | ties every machine's alerts to one box | the most upkeep for the least gain |

**Variant: each clothod calls APNs directly.** That removes the relay, but every machine then
needs the .p8. An APNs auth key is team-wide (it can push to any app on the team), so copying it
onto every dev box is the wrong trade. Not recommended.

**Recommendation: the Cloudflare Worker.** It costs nothing, needs no upkeep, works from every
machine whether or not it's on the tailnet, and with end-to-end encryption Cloudflare holds only the
.p8 and sees only ciphertext. If the user would rather not involve a third party at all, run the
same relay on devbox; the protocol and the app are identical, only the `relay` URL changes.

## What the user needs to provide

1. **An APNs auth key.** developer.apple.com → Certificates, Identifiers & Profiles → Keys → "+",
   enable Apple Push Notifications service (APNs). If asked for an environment, choose "Sandbox &
   Production" (Debug builds use sandbox, TestFlight uses production). Download `AuthKey_<KEYID>.p8`.
   Apple allows downloading it only once. Put it outside the repo, for example
   `~/.config/clotho/AuthKey_<KEYID>.p8`, and send only the path. It never gets committed;
   `.gitignore` already excludes `*.p8`.
2. **The key ID**, 10 characters, shown next to the key. The team ID is already known: TEAMID0000.
3. **The hosting choice**: Worker, devbox, or VPS.
   - Worker: a Cloudflare account, and the user runs `wrangler login` once (it opens a browser).
     Then I deploy to `clotho-push.<account>.workers.dev` and set the .p8 with `wrangler secret put`.
   - devbox: OK to add a user systemd service there.
   - VPS: which provider, and that the user creates the box.
4. **OK to change the App ID**: turn on Push Notifications for `nyc.amin.clotho`, register the
   extension's id `nyc.amin.clotho.notify`, and share a Keychain group between them. No App Group is
   needed: the label carries the machine's name. Xcode's automatic signing does all of it on the first
   device or TestFlight build with `PUSH=YES`; it changes the provisioning profiles in the user's
   account. Until then, device and TestFlight builds leave push out (`push.yml` is included only with
   `PUSH=YES`, which `build.sh` sets for the simulator).
5. **Lock-screen text** (a choice with a default): show the agent's message ("Allow cargo test
   --release?") or only "Claude is waiting on devbox". The default is the message; iOS's own
   "Show Previews" setting still applies on top.

## Work split

- **clothod**: the `push` feature, `push.register/unregister/list/test`, registration storage, the
  sender with HPKE, coalescing, retry and 410 handling. It can be tested against a fake relay.
  HTTPS is ureq with rustls (ring) and bundled web roots, so the static musl builds need no system
  certificates; Linux builds are cross-compiled with cargo-zigbuild (zig as the C compiler).
  `CLOTHOD_TEST_PUSH_FAST=1` shortens the 30 s / backoff / 10 min timings for tests.
- **iOS**: the relay (in `ios/relay/`), the extension target, the APNs entitlement, registration on
  connect, a per-machine "Alerts" toggle with "Send test alert", and clearing stale alerts on open.
  The simulator on Apple silicon receives real sandbox pushes, so the whole path can be tested
  before a device pass.

## Testing without the accounts

`node ios/relay/dev.js` runs the same relay on http://127.0.0.1:8787 and delivers with `xcrun simctl
push`. Debug simulator builds use it by default, and `-PushSelfTest YES` makes the app send itself an
alert through it (ClothoUITests/PushUITests). Simulated pushes skip notification service extensions,
so they show the generic text; decryption is unit-tested against a fixed vector (ClothoTests/PushTests,
shared with clothod's tests), and the extension itself runs only for real APNs pushes, which needs the
.p8.
