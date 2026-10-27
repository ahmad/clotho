# Clotho

Clotho is a terminal and agent manager: a per-machine session daemon (`clothod`, Rust, macOS and Linux)
with native Mac and iOS clients. PLAN.md has the design and the decisions behind it.

## Layout and owners

| Path | Owner agent |
|---|---|
| `clothod/`, `docs/protocol.md`, `docs/remote.md` | clothod |
| `mac/`, `ClothoKit/` (shared Swift package) | mac |
| `ios/` (includes the push relay `ios/relay`), `docs/push.md` | ios |
| `PLAN.md`, `CLAUDE.md`, `.claude/`, `scripts/`, root files | orchestrator |

Four Claude Code sessions work here as peers. Start one with `scripts/agent <role>`. Peers find each
other with ListAgents and talk with SendMessage. Change only the paths you own. To change something
another agent owns, message that agent; the iOS agent asks the mac agent for ClothoKit changes.

## Rules (set by the user)

- **The user's daemons.** Each machine (this one, devbox, imac) runs one clothod instance, and one
  version of it. Never stop, restart or upgrade the user's default instance unless the user asks. A
  new version reaches the user through the app's "Update clothod" offer, or through an upgrade the
  user requested. The upgrade swaps the holder in place, so shells survive.
- **Tests and dev daemons.** These are temporary. Use `--ephemeral` and dev runtime dirs (`/tmp/clt*`,
  `/tmp/cki-*`). Clean up after every run, and check `clothod ps` shows nothing marked extra.
- **Test Claude Code sessions.** Run them with `--setting-sources project,local`. The user's settings
  carry hooks that must not see test traffic.
- **Agent hooks.** Never install them into `~/.claude` or `~/.codex` without the user's confirmation.
  The app offers "Set Up Agent Status…" for that.
- **Git.** There is one repo, with remote `git@github.com:ahmad/clotho.git` (private).
  - Commit your own paths only. Never `git add -A` at the root.
  - Never commit secrets: `.p8` and `.p12` keys, provisioning profiles, `.env` files, tokens.
  - Only the orchestrator pushes, and only when the user asks.
  - End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Terms.** It's Workspace, Tab, Pane in every UI and doc, never "Session". Renames happen inline the
  way Finder does it (double-click, or Return).
- **Releases.** A clothod release bumps the version (`clothod/scripts/dist.sh` refuses to re-release
  one). The apps offer only newer versions and never downgrade.
- **Verify, then report.** Run the tests before you say something works, and say exactly what you
  ran and what you didn't.

## Machines

- **devbox** (Linux x86_64, `ahmad@devbox`): the main dev machine. The clone is at `~/Projects/clotho`.
- **This Mac** (Tailscale name `macbook`, `ahmad@macbook`): has Xcode. From devbox,
  `clotho-mac <command>` syncs the clone to `~/Builds/clotho-clothod` on the Mac and runs the command
  there, e.g. `clotho-mac ios/build.sh` or `clotho-mac mac/build-app.sh --dev`. Over SSH the login
  keychain is locked, so codesigning, archives, TestFlight uploads and installing the Mac app need the
  Mac's own session.
- **imac** (macOS arm64, `macbook@imac`): a remote test host.

## Build and test

- clothod:
  - `cd clothod && cargo test` runs the unit, snapshot and end-to-end tests.
  - `clothod/scripts/test-all.sh` runs them on every platform, plus the cleanliness check.
  - `scripts/dist.sh` makes the release builds. The macOS builds need a Mac.
- Mac:
  - `mac/build-app.sh --dev` builds `Clotho Dev.app` without installing it.
  - `mac/build-app.sh` installs to `~/Applications` and replaces the user's app. Run it only when the
    user approved a new version.
- iOS:
  - `ios/build.sh` builds for the simulator; `ios/build.sh test` runs the tests.
  - `ios/scripts/testflight.sh` uploads to TestFlight, and needs the user's go each time.
- Relay: `cd ios/relay && npm test`. Deploy with `npx wrangler deploy`, only when asked.

## Keys (never in the repo)

- The APNs key is `~/.config/clotho/AuthKey_KEYID00000.p8`. The push relay holds it as a Worker secret.
- The Cloudflare login is wrangler's own config.
- The Apple team is TEAMID0000. Signing uses the Mac's Xcode account.
