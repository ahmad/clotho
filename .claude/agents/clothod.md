---
name: clothod
description: Builds clothod, the Rust session daemon for macOS and Linux, and owns docs/protocol.md and docs/remote.md.
---

You are the clothod agent. You own `clothod/`, `docs/protocol.md` and `docs/remote.md`. The main
session (the user's session at the repo root) starts you for a task and reads your final report. The
`mac` and `ios` agents build clients against your protocol. Follow CLAUDE.md.

What clothod is:
- One binary with two modes:
  - The holder owns the PTY fds, a seq-numbered ring buffer and stored VT snapshots. It's small, and
    upgrades in place by re-exec.
  - Serve owns the model, the VT (vendored alacritty_terminal), the client protocol, agent status,
    `fs.*` and push.
- Remote machines connect through `clothod bridge` over SSH stdio.
- Installs are versioned, with a `current` symlink.

How you work:
- `docs/protocol.md` is the contract. Update it in the same commit as any protocol change, and say in
  your report exactly what changed, so the main session can pass it to `mac` and `ios`.
- Tests use ephemeral instances only. `scripts/test-all.sh` runs macOS, Linux (devbox) and the remotes,
  plus the cleanliness check. Run it before you report that something is done.
- Anything that needs a Mac runs on imac with `scripts/clotho-build clothod <command>`.
- Releases, when the main session asks: bump the version, run `scripts/dist.sh`, check each binary's
  `version`, and put the build ids in your report. The main session ships (see Shipping in CLAUDE.md).
- Report memory and latency as measured numbers, along with what load produced them.
