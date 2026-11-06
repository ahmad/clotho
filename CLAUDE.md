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
file. It starts the role agents (clothod, mac, ios) as subagents when a task needs them, passes
changes from one to another, verifies their work, pushes and ships. A role agent changes only the
paths it owns. When it needs something from another role (a protocol change, a ClothoKit API change),
or changed something another role builds against, it says so in its final report and the main
session passes it on.

## How work flows (user decision, 2026-11-06)

- **Agents.** The role agents (`clothod`, `mac`, `ios`) start their own subagents: `investigator`,
  `planner`, `implementer` and `validator` (plus the built-in `Explore`). The merge gate uses
  `code-reviewer`, `validator` and `ux-reviewer`. They are all in `.claude/agents/`.
- **Branches.** Role agents always work in a git worktree on their own branch (`<role>/<slug>`). Start
  them with `isolation: "worktree"`, or through `/change`. Nothing is committed to `main` directly
  except the main session's own paths.
- **Merge gate.** A branch merges only when all its checks PASS: `code-reviewer`, `validator` (the role's
  full suite) and, for Mac and iOS, `ux-reviewer`. A check that didn't run counts as a block.
- **Workflows** (`.claude/workflows/`, run as slash commands or by name):
  - `/change ios <task>` (or `{"role": "ios", "task": "..."}`): the role agent builds the task in a worktree, then the gate
    runs. If the gate blocks, the role agent fixes it, for up to 3 rounds. It returns whether the branch is
    mergeable, the branch, and every review.
  - `/gate mac <worktree path>`: the gate alone, for a branch made some other way.
  - Without a workflow, the main session does the same by hand: an Agent call to the role with
    `isolation: "worktree"`, then the three checks (the code review in parallel with the
    validator, then the UX review).
- **Merging.** The main session reads the report and the diff, rebases the branch onto `main` if
  `main` moved (and reruns `validator` if the rebase brought in code), fast-forwards `main`, pushes,
  removes the worktree and branch, and ships from the main clone (see Shipping).
- **Across roles.** A protocol change goes first (clothod), then the clients against it. Pass each
  report's "needs" on to the next role's task.
- **One agent per role at a time.** A role's agents share its mirror on imac, and heavy runs go one
  at a time (see imac under Machines).

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
  contention: the iOS UI suite is timing-sensitive, so the main session runs heavy work (test suites,
  release builds) one at a time and never starts two role agents that both run one. macbook is the fallback
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
