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

- **The main session's default.** When the user asks for a change in `clothod/`, `docs/protocol.md`,
  `docs/remote.md`, `mac/`, `ClothoKit/`, `ios/` or `docs/push.md`, don't edit those paths yourself.
  Run `/change <role> <task>` for each role involved. This is the user's standing go to run the
  `change` and `gate` workflows without asking. When you'd rather steer the work step by step, use the
  by-hand path below instead. Questions, read-only investigations, and the main session's own paths
  don't go through a role.
- **Agents.** The role agents (`clothod`, `mac`, `ios`) start their own subagents: `investigator`,
  `planner`, `implementer` and `validator` (plus the built-in `Explore`). The merge gate uses
  `code-reviewer`, `validator` and `ux-reviewer`. They are all in `.claude/agents/`.
- **Branches.** Role agents always work in a git worktree on their own branch (`<role>/<slug>`). Start
  them with `isolation: "worktree"`, or through `/change`. Nothing is committed to `main` directly
  except the main session's own paths.
- **Merge gate.** A branch merges only when all its checks PASS: `code-reviewer`, `validator` (the role's
  full suite) and, for Mac and iOS, `ux-reviewer`. A check that didn't run counts as a block.
- **Workflows** (`.claude/workflows/`, run as slash commands or by name):
  - `/change ios <task>` (or `{"role": "ios", "task": "..."}`): investigator, then planner, then the role agent opens a
    worktree, implementers build the plan's pieces (in parallel when their files don't overlap), and the role agent
    integrates and commits. Then the gate runs. If it blocks, the role agent fixes it, for up to 3 rounds. (Workflow
    agents can't start subagents, so the workflow runs those steps itself.) It returns whether the branch is
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
- **One agent per role at a time.** A role's agents share its mirror on the build Mac, and heavy runs go one
  at a time (see the build Mac under Machines).

## Rules (set by the user)

- **The user's daemons.** Each of the three machines runs one clothod instance, and one
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

The repo is public. Hostnames, logins, account IDs and key paths live only in the gitignored
`CLAUDE.local.md` (Claude Code loads it, worktrees under `.claude/worktrees/` included) and in
`~/.config/clotho/local.env` (scripts read it). Never write them into the repo, a commit message, or
anything else that gets pushed. Here the machines go by role:

- **The dev box** (Linux x86_64): the main dev machine, where these sessions run, with the clone at
  `~/Projects/clotho`.
- **The laptop Mac**: the user's own Mac, often in use: no UI test runs there. It's the fallback build
  host.
- **The build Mac** (macOS arm64, always on; user, 2026-10-30): runs every Mac and iOS build, test and dist,
  through `scripts/clotho-build <role> <command>` (role = clothod, mac, ios or main). That syncs the clone to
  the role's own mirror under `~/Builds` and passes the `CLOTHO_*` settings along. clothod's mirror holds the
  released `clothod/dist`, and the other mirrors link to it. Never sync into another role's mirror.
  Separate mirrors stop file clashes, not CPU contention: the iOS UI suite is timing-sensitive, so the main
  session runs heavy work (test suites, release builds) one at a time and never starts two role agents that
  both run one. Signing uses the build Mac's dedicated build keychain: unlock it in the same SSH session
  before codesign, notarytool or Sparkle signing, never print its password, and read the Sparkle key from it
  only into `sign_update --ed-key-file -`, never to disk. The build Mac also runs the user's own clothod and
  Claude sessions: never touch them.
- **Disk space on the Macs is limited (user rule).** Keep `~/Builds` small. After every run, remove what the
  run left that isn't needed: cargo cross-target and debug dirs in the mirror's `clothod/target` (keep
  `dist-dev`), Xcode's `Index.noindex`, old archives, and scratch dirs. `~/Builds/testflight` keeps only the
  latest uploaded archive. Never delete `clothod/dist` (the released builds). Keep at least 20 GiB free;
  check with `df -h /System/Volumes/Data` before big builds. Don't touch `~/Library` caches or simulators
  without asking the user.

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
    then tells the user the build number. The API key ids live in the dev box's
    `~/.config/clotho/asc.env`, never in the repo.
- Relay: `cd ios/relay && npm test`. Deploy with `cd ios/relay && npm run deploy` when shipping (see Shipping), never a bare
  `wrangler deploy`: the deploy script passes the team and key IDs from `local.env`.

## Keys (never in the repo)

- The APNs key, the App Store Connect API key, the Apple team ID and the relay URL: see `CLAUDE.local.md`.
  Scripts get the IDs from `~/.config/clotho/local.env` and `asc.env`.
- The push relay holds the APNs key as a Worker secret. The Cloudflare login is wrangler's own config.
