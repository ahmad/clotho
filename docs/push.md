# Push alerts: agent attention to the iPhone

Status: **design draft** (2026-10-26). Nothing here is built yet. Owners: the daemon hook is
clothod's, the relay and the app side are iOS's.

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
| `push.list` | none | `{"devices": [{device, label, env, registered, last_sent, last_error}]}`, never the handle |
| `push.test` | `device` | `{}` once the relay accepted it; for a "Send test alert" button |

clothod keeps registrations in its state directory, mode 0600, so they survive daemon restarts and
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
- Ciphertext on the wire: `base64(enc || ct)`, about 600 bytes at the most, well inside APNs's 4 KB.
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

What each party can still see: Apple sees the token, timing and ciphertext size. The relay and
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
4. **OK to change the App ID**: turn on Push Notifications for `nyc.amin.clotho` and add an App
   Group and Keychain group for the extension. Xcode's automatic signing does this on the next build;
   it changes the provisioning profile in the user's account.
5. **Lock-screen text** (a choice with a default): show the agent's message ("Allow cargo test
   --release?") or only "Claude is waiting on devbox". The default is the message; iOS's own
   "Show Previews" setting still applies on top.

## Work split

- **clothod**: the `push` feature, `push.register/unregister/list/test`, registration storage, the
  sender with HPKE, coalescing, retry and 410 handling. It can be tested against a fake relay.
- **iOS**: the relay (in `ios/relay/`), the extension target, the APNs entitlement, registration on
  connect, a per-machine "Alerts" toggle with "Send test alert", and clearing stale alerts on open.
  The simulator on Apple silicon receives real sandbox pushes, so the whole path can be tested
  before a device pass.
