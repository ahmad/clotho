# Clotho

Clotho is a terminal and agent manager: a per-machine session daemon (`clothod`, Rust, macOS and Linux)
with native Mac and iOS clients. PLAN.md has the design and the decisions behind it.

## Layout and owners

| Path | Owner agent |
|---|---|
| `clothod/`, `docs/protocol.md`, `docs/remote.md` | clothod |
| `mac/`, `ClothoKit/` (shared Swift package) | mac |
| `ios/` (includes the push relay `ios/relay`), `docs/push.md` | ios |
| `PLAN.md`, `CLAUDE.md`, `STATUS.md`, `.claude/`, `scripts/`, root files | main session |

The main session is the plain Claude Code session the user talks to at the repo root. It has no role
file: it coordinates the three role sessions, verifies their work, pushes and ships. The role
sessions (clothod, mac, ios) work as peers. Start one with `scripts/agent <role>`. Peers find each
other with ListAgents and talk with SendMessage. Change only the paths you own. To change something
another agent owns, message that agent; the iOS agent asks the mac agent for ClothoKit changes.

## Rules (set by the user)

- **The user's daemons.** Each machine (this one, devbox, imac) runs one clothod instance, and one
  version of it. Never stop or restart the user's default instance. Upgrading it in place is part of
  shipping (see Shipping): the upgrade swaps the holder in place, so shells survive.
- **Tests and dev daemons.** These are temporary. Use `--ephemeral` and each role's own dev dirs: clothod
  `/tmp/clt*`, mac `/tmp/cmac-*`, ios `/tmp/cki-*`, so roles can test in parallel. Clean up after every run, and check `clothod ps` shows nothing marked extra.
- **Test Claude Code sessions.** Run them with `--setting-sources project,local`. The user's settings
  carry hooks that must not see test traffic.
- **Agent hooks.** Never install them into `~/.claude` or `~/.codex` without the user's confirmation.
  The app offers "Set Up Agent Status…" for that.
- **Git.** There is one repo, with remote `git@github.com:ahmad/clotho.git` (private).
  - Commit your own paths only. Never `git add -A` at the root.
  - Never commit secrets: `.p8` and `.p12` keys, provisioning profiles, `.env` files, tokens.
  - Only the main session pushes, after verifying each commit.
  - End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Terms.** It's Workspace, Tab, Pane in every UI and doc, never "Session". Renames happen inline the
  way Finder does it (double-click, or Return).
- **Releases.** A clothod release bumps the version (`clothod/scripts/dist.sh` refuses to re-release
  one). The apps offer only newer versions and never downgrade.
- **Shipping (user rule, 2026-10-28: "stop asking me to ship things and just do it").** The main session
  ships without asking, once the work is verified: the full tests pass (test-all for clothod; the full
  iPhone suite and the iPad test for iOS; the swift tests for the Mac), and it has checked the result.
  Shipping covers clothod releases with in-place upgrades on all three machines, Mac app installs,
  TestFlight uploads, relay deploys, and refreshing Clotho's own existing hooks. It then tells the user
  what shipped. Still ask first for: new kinds of hooks or other changes to the user's own config
  files, deleting the user's data, and anything new in the user's Apple or Cloudflare accounts.
- **Verify, then report.** Run the tests before you say something works, and say exactly what you
  ran and what you didn't.

## Machines

- **devbox** (Linux x86_64, `ahmad@devbox`): the main dev machine. The clone is at `~/Projects/clotho`.
- **This Mac** (Tailscale name `macbook`, `ahmad@macbook`): has Xcode. From devbox,
  `clotho-mac <command>` syncs the clone to `~/Builds/clotho-clothod` on the Mac and runs the command
  there, e.g. `clotho-mac ios/build.sh` or `clotho-mac mac/build-app.sh --dev`. Over SSH the login
  keychain is locked, but TestFlight uploads still work: they unlock it from the Mac's ~/.keychain_pw and
  use the App Store Connect API key in ~/.appstoreconnect/private_keys/. The Mac app is
  signed ad hoc, so `mac/build-app.sh` installs fine over SSH.
- **Disk space on the Mac is limited (user rule).** Keep `~/Builds` small. After every run on the Mac, remove
  what the run left that isn't needed: cargo cross-target and debug dirs in the mirror's `clothod/target`
  (keep `dist-dev`), Xcode's `Index.noindex`, old archives, and scratch dirs. `~/Builds/testflight` keeps
  only the latest uploaded archive. Never delete `clothod/dist` (the released builds). Keep at least 20 GiB
  free; check with `df -h /System/Volumes/Data` before big builds. Don't touch `~/Library` caches or
  simulators without asking the user.
- **imac** (macOS arm64, `macbook@imac`, always on): **the build host** (user, 2026-10-30). Run Mac and iOS
  builds, tests and dists there with `scripts/clotho-build <role> <command>` (role = clothod, mac, ios or
  main). Each role has its own mirror on imac (~/Builds/clotho-clothod for clothod, which holds the
  released clothod/dist; clotho-mac, clotho-ios, clotho-orch, whose clothod/dist links to it), so agents never
  sync over each other's builds. Never sync into another role's mirror. Separate mirrors stop file clashes, not CPU
  contention: the iOS UI suite is timing-sensitive, so ask the other agents before a heavy run (test suites,
  release builds) while one of them is mid-run, and wait for their "done". macbook is the fallback
  (`CLOTHO_MAC=ahmad@macbook clotho-mac <command>`).
  Signing uses imac's dedicated build keychain (~/Library/Keychains/clotho-build.keychain-db, password in
  ~/.config/clotho/build-keychain-pw; never print it). Unlock it in the same SSH session before codesign,
  notarytool (profile `clotho-notary`, ASC API key) or Sparkle signing. The Sparkle key is read from it
  into `sign_update --ed-key-file -` only, never to disk. imac also runs the user's own clothod and
  Claude sessions: never touch them. The user is often at macbook: no UI test runs there.

## Build and test

- clothod:
  - `cd clothod && cargo test` runs the unit, snapshot and end-to-end tests.
  - `clothod/scripts/test-all.sh` runs them on every platform, plus the cleanliness check.
  - `clothod/scripts/dist.sh` makes the release builds. The macOS builds need a Mac.
- Mac:
  - `mac/build-app.sh --dev` builds `Clotho Dev.app` without installing it.
  - `mac/build-app.sh` installs to `~/Applications` and replaces the user's app. Run it when
    shipping (see Shipping).
- iOS:
  - `ios/build.sh` builds for the simulator; `ios/build.sh test` runs the tests.
  - `ios/scripts/testflight.sh` uploads to TestFlight. The main session runs it over SSH without
    asking, once a build has passed the full iPhone suite and the iPad test and has been verified,
    then tells the user the build number. The API key ids live in devbox's
    `~/.config/clotho/asc.env`, never in the repo.
- Relay: `cd ios/relay && npm test`. Deploy with `npx wrangler deploy` when shipping (see Shipping).

## Keys (never in the repo)

- The APNs key is `~/.config/clotho/AuthKey_KEYID00000.p8`. The push relay holds it as a Worker secret.
- The Cloudflare login is wrangler's own config.
- The Apple team is TEAMID0000. Signing uses the Mac's Xcode account.
