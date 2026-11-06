# Multi-agent orchestrators and agent-centric terminals (as of 2026-10-30)

Method: GitHub API snapshot (stars, license, last push, latest releases) taken 2026-10-30 via `gh api repos/<owner>/<repo>`; README text pulled the same day. Web sources are dated where possible. Star counts below are all from that 2026-10-30 snapshot unless stated otherwise.

## Per-tool profiles: what each does, architecture, agents, platforms, persistence, multi-machine, mobile, notifications, license/pricing, traction

### Takeaway
The field has converged on one pattern: a desktop app with **one git worktree + branch per agent task**, a sidebar of agent status, a diff/PR review pane, and (since mid/late 2026) **remote hosts plus an iPhone companion with push notifications**. Paradev (ex-Superset), Orca, Conductor, Nimbalyst, Orchestrator.inc and cmux now all ship or beta some kind of phone app. Clotho's real differentiators are elsewhere: a headless per-machine daemon that keeps live PTYs through client disconnects and in-place upgrades, a native (non-Electron) Mac+iOS client, and a terminal-first Workspace/Tab/Pane model across several machines. Almost every competitor centres on worktree isolation and diff review. Clotho lacks both.

### Cited Findings

**Conductor (conductor.build, Melty Labs / Melty, Inc.): closed source, macOS**
- A Mac app that runs Claude Code, Codex and Cursor agents in parallel "isolated workspaces", then reviews and merges their changes. Latest version 0.92.0 — [conductor.build](https://www.conductor.build/)
- Workspaces are git worktrees, one per workspace. It has a sidebar, detail pane, diff viewer and PR flow, and no kanban. Free for now; the team plans to charge for collaboration features (Nimbalyst blog, a competitor, updated 2026-07-29) — [Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/)
- Closed source — [Augment Code, updated 2026-08-12](https://www.augmentcode.com/tools/open-source-agent-orchestrators)
- Release cadence is very high, often several releases a week. Recent entries: 0.92.0 "Remote control" (2026-10-23), 0.90.0 "Conductor for iOS" (2026-10-02), 0.85.0 "Sections, routines" (2026-09-09), 0.84.0 "Edit files directly in diffs" (2026-09-02), 0.78.0 "Introducing Conductor Cloud" (2026-07-30), "Instant Archiving" 0.46.0 (2026-04-05) — [Conductor changelog](https://www.conductor.build/changelog)
- Remote control (0.92.0) is experimental: Settings → Experimental, then pair the phone. From iOS you can browse and create workspaces, read chats, send messages, pick models and stop agents in the Mac's local workspaces. The Mac stays awake while the phone is connected. The iOS app first targeted cloud workspaces (0.90.0). The App Store listing requires iOS 26 — [search summary of changelog](https://www.conductor.build/changelog); [App Store](https://apps.apple.com/us/app/conductor-build/id6791228564); [RuntimeWire](https://runtimewire.com/article/conductor-iphone-app-cloud-coding-agents)
- The iOS app reportedly sits on a Pro plan, per a competitor (Traycer) — [Traycer compare](https://traycer.ai/compare/traycer-vs-conductor)
- Funding: aggregators report a $22M Series A with Matrix Partners, dated either 2026-03-31 or 2026-05. These are unverified secondary sources and disagree on the date. YC-backed — [justraised](https://justraised.netlify.app/companies/conductor); [Crunchbase (Melty)](https://www.crunchbase.com/organization/melty-763f)
- Conductor is chat/GUI-centric (built on agent SDKs) rather than a raw terminal. One third-party source says it is built on the Claude Code SDK and Tauri — [codepick.dev](https://codepick.dev/en/guides/conductor-build-intro/)

**Paradev (formerly Superset, superset.sh → paradev.com): source-available, macOS (Linux experimental)**
- Renamed in October 2026 ("Paradev was called Superset until October 2026"). The footer still says Superset Inc. — [paradev.com compare page, updated 2026-10-15](https://paradev.com/compare/superset-vs-orca)
- Desktop app for running CLI agents in parallel. Each task gets its own git worktree, branch and terminals. Works with Claude Code, Codex, OpenCode, Gemini CLI, Cursor Agent or any CLI agent. The sidebar shows working, done or "waiting on you", with completion chimes and dock badges. Supports "tabs, infinite splits, presets, and persistent sessions that survive restarts". Also has an in-app browser with per-worktree port detection, a CLI, an SDK and an MCP server — [GitHub README](https://github.com/ParadevAI/Paradev)
- Pro features: remote hosts (macOS or Linux machines you add; workspaces keep running when the laptop sleeps), an iPhone/iPad app (iOS 26+, Pro plan; send prompts, review diffs, merge PRs), and automations (schedule- or event-triggered agents) — [GitHub README](https://github.com/ParadevAI/Paradev); [paradev compare](https://paradev.com/compare/superset-vs-orca)
- License: Elastic License 2.0 (source-available). Pricing: free tier; Pro $20/user/mo ($16 yearly); Team $60; Ultra $200; Enterprise custom — [paradev compare](https://paradev.com/compare/superset-vs-orca). An earlier Nimbalyst snapshot listed Pro at $15/user/mo — [Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/)
- 15,751 stars. desktop-v2.0.2 released 2026-10-29 — [GitHub](https://github.com/ParadevAI/Paradev)
- YC Spring 2026, Launch HN May 2026; funding amount not disclosed — [rywalker.com](https://rywalker.com/research/superset)
- **Closest feature-for-feature competitor to Clotho** (remote hosts + iOS + persistent terminals + status/attention), but worktree-first and Electron-style.

**Orca (stablyai/orca): MIT, macOS/Windows/Linux**
- "Run Codex, ClaudeCode, OpenCode or Pi side-by-side — each in its own worktree". Fans out one prompt to N agents and merges the winner. Features: SSH worktrees (auto-reconnect, port forwarding), Remote Orca Servers (`orca serve`, beta), quick open across worktrees/files/agents/commands, notifications and unread state, and an in-app PR/issue/project-board browser. Mobile companion: iOS App Store, Android APK — [GitHub README](https://github.com/stablyai/orca)
- 110,894 stars, 7,010 forks, 148 watchers. Repo created 2026-03-17. Releases daily (v1.4.245 on 2026-10-30) — [GitHub API](https://github.com/stablyai/orca). **Flag:** third-party snapshots earlier in 2026 reported only about 3.2k–5.9k stars ([besthub](https://www.besthub.dev/articles/why-the-5-7k-star-open-source-orca-eliminates-multi-agent-coding-chaos-20ff337d81f0); [sourcepulse](https://www.sourcepulse.org/projects/27429804)). Going to 110k with only 148 watchers is unusual. Treat the star count with caution (it could be a GitHub Trending surge, or inflated). An Oct 2026 news piece credits its visibility to GitHub Trending — [aitoolly 2026-10-20](https://aitoolly.com/ai-news/article/2026-10-20-stablyai-unveils-orca-a-unified-multi-agent-platform-for-coordinating-coding-agents-across-multiple)
- The ⌘P-like "quick open" across agents/worktrees directly overlaps Clotho's ⌘P tree.

**cmux (manaflow-ai/cmux): GPL-3.0-or-later (server parts BSL 1.1), macOS**
- A Ghostty-based native macOS terminal with vertical tabs. Notification rings on panes and tabs when an agent needs attention, plus a notifications panel (⌘I) with jump-to-latest-unread. Driven by OSC 9/99/777 escape sequences or its CLI. The sidebar shows git branch, linked PR status/number, cwd, listening ports and the latest notification text. Has a scriptable browser pane, `cmux ssh user@remote` remote workspaces, and `cmux claude-teams` (teammates as native splits). Works with any terminal agent — [GitHub README](https://github.com/manaflow-ai/cmux)
- Session restore: it saves layout, cwd, best-effort scrollback and browser URLs. It does **not** keep live processes. For live detach/reattach you opt in to `cmux local-tmux`, or use `ssh-tmux`/`mosh-tmux`/cloud VM — [README](https://github.com/manaflow-ai/cmux)
- iOS app in beta on TestFlight ("cmux BETA"): pair with the Mac, attach to terminals, optional notification forwarding. Cloud VMs and "cmux AI" are early access through a paid "Founders Edition" — [README](https://github.com/manaflow-ai/cmux)
- 28,612 stars, about 2.6k forks. Repo created 2026-01-28; pushed 2026-10-30 — [GitHub](https://github.com/manaflow-ai/cmux)
- **The most philosophically similar tool to Clotho** (a native terminal, any agent, attention rings, branch/PR per pane, SSH, an iOS app). The difference is that its persistence depends on tmux, while Clotho has its own daemon.

**Nimbalyst (formerly Crystal, Stravu): MIT, macOS/Windows/Linux + iOS (Android mentioned in repo description)**
- Crystal (3,130 stars, MIT) was deprecated in Feb 2026 and redirects to Nimbalyst. Its last push was 2026-02-26 — [GitHub stravu/crystal](https://github.com/stravu/crystal)
- Nimbalyst: a visual workspace for Claude Code, Codex and OpenCode. Parallel sessions each get their own worktree. It has a session kanban, search/resume of sessions, built-in git, an embedded terminal, and visual editors (markdown, mockups, diagrams). The iOS companion shows which agents need you, lets you reply by text or voice, swipe through diffs, and sends push notifications when an agent is waiting — [GitHub README](https://github.com/nimbalyst/nimbalyst)
- 2,001 stars; v0.82.4 on 2026-10-27 — [GitHub](https://github.com/nimbalyst/nimbalyst). Free for individuals; Teams $20/user/mo (free in beta) — [Nimbalyst blog](https://nimbalyst.com/blog/best-agent-management-tools-2026/)

**Sculptor (Imbue): MIT, macOS/Linux**
- Originally ran each Claude Code agent in its own Docker container, with bidirectional sync to local ("Pairing Mode") — [Show HN](https://nfhn.netlify.app/item/45427697). Supports Claude Code and Codex; free in beta — [AlternativeTo](https://www.alternativeto.net/software/sculptor/about/)
- The current README describes "Workspaces: isolated worktrees of your repo" and makes the Docker/remote "Container Backend" **experimental**. This suggests a move from containers to worktrees as the default — [GitHub README](https://github.com/imbue-ai/sculptor)
- Low traction: 242 stars; sculptor-v0.49.0 on 2026-10-21 — [GitHub](https://github.com/imbue-ai/sculptor)

**Claude Squad (smtg-ai): AGPL-3.0, any tmux platform**
- A TUI that uses tmux for each agent session plus git worktrees for isolation. Supports Claude Code, Codex, Gemini, Aider, OpenCode and Amp. Detach with ctrl-q, pause/resume, review before push — [GitHub README](https://github.com/smtg-ai/claude-squad)
- 8,699 stars. Cadence has slowed: v1.0.18 2026-05-23, v1.0.19 2026-06-17, v1.0.20 2026-08-20, no push since 2026-08-20 — [GitHub](https://github.com/smtg-ai/claude-squad)
- Criticism from a competitor (ccmanager): the menu shows no session states, and AutoYes bypasses Claude's confirmations — [ccmanager README](https://github.com/kbwo/ccmanager)

**ccmanager (kbwo): MIT, CLI**
- No tmux dependency. Shows busy, waiting and idle states. Creates, merges and deletes worktrees. Restores sessions after a restart or crash. Copies Claude session data between worktrees. Has status-change hooks for notifications and devcontainer integration. Supports 8 CLIs — [GitHub README](https://github.com/kbwo/ccmanager)
- 1,276 stars; v4.4.11 on 2026-10-27 — [GitHub](https://github.com/kbwo/ccmanager)

**agent-deck (asheshgoplani): MIT, macOS/Linux/WSL**
- A tmux-based TUI "mission control" across many projects. Has a notification bar, a web UI (`agent-deck web`), remote decks (sessions on other machines), Docker-sandboxed sessions, and moving a session to another Claude account with its conversation. A "conductor" with Telegram/Slack/Discord/Mattermost bridges lets you watch and answer waiting sessions from a phone — [GitHub README](https://github.com/asheshgoplani/agent-deck)
- 1,188 stars; v1.16.34 on 2026-10-25 (frequent releases) — [GitHub](https://github.com/asheshgoplani/agent-deck)

**workmux (raine): MIT**
- Pairs git worktrees with tmux windows (and also zellij/kitty). Has a sidebar of all agents, agent status in tmux window names, merge+cleanup in one command, and container/VM sandboxing. Philosophy: "Build on tools you already use" rather than an "agentic GUI that won't exist next year" — [GitHub README](https://github.com/raine/workmux)
- 2,963 stars; v0.1.277 on 2026-10-23 — [GitHub](https://github.com/raine/workmux)

**uzi (devflowinc): MIT, CLI**: worktrees for large numbers of parallel agents. **Dormant**: last push 2025-06-04; 582 stars — [GitHub](https://github.com/devflowinc/uzi)

**Vibe Kanban (BloopAI): Apache-2.0, web app via `npx vibe-kanban`**
- Kanban issues → workspaces (worktrees) where agents run. Has inline diff review, PR creation, a built-in browser, and 10+ agents — [Augment](https://www.augmentcode.com/tools/open-source-agent-orchestrators); [GitHub README](https://github.com/BloopAI/vibe-kanban)
- Bloop shut down on 2026-04-10. Remote services ran for 30 more days, then the tool went fully local and community-maintained — [vibekanban.com/blog/shutdown](https://vibekanban.com/blog/shutdown). The README still says "Vibe Kanban is sunsetting". The last release was v0.1.44 on 2026-04-24, but there were pushes as recently as 2026-10-29 — [GitHub](https://github.com/BloopAI/vibe-kanban)
- 28,520 stars. It was one of the most popular tools before the shutdown — [GitHub](https://github.com/BloopAI/vibe-kanban)

**Terragon (Terragon Labs): cloud background agents, defunct**
- Ran Claude Code, Codex and other CLIs remotely in the cloud. Shut down; an open-source snapshot was released on 2026-01-16 (Apache-2.0, 261 stars) — [GitHub terragon-oss](https://github.com/terragon-labs/terragon-oss)

**Warp (warpdotdev): AGPL/MIT, macOS/Linux/Windows**
- Oz launched 2026-02-10 as a cloud orchestration platform for agents in Docker-sandboxed cloud environments. It can be used outside Warp — [Warp newsroom](https://www.warp.dev/newsroom/2026/2/10/warp-launches-oz-the-orchestration-platform-for-cloud-coding-agents)
- Warp reported 1M+ active users and an Oz launch on 2026-03-22 — [Warp newsroom](https://www.warp.dev/newsroom/2026/3/22/warp-reaches-one-million-active-users-launches-oz-cloud-platform)
- In May 2026 it added multi-harness support: Oz runs Claude Code and Codex as harnesses alongside Warp Agent. It markets "a single pane of glass" for cloud agents, with triggers from Slack, GitHub PRs and CI failures — [Warp blog](https://www.warp.dev/blog/multi-harness-cloud-agent-orchestration); [Warp docs](https://docs.warp.dev/agent-platform/cloud-agents/platform/)
- Open-sourced the terminal and Oz (reported 2026-04, per Wikipedia) — [Wikipedia](https://en.wikipedia.org/wiki/Warp_(terminal)). The repo is AGPL-3.0 with 65,791 stars and calls itself "an agentic development environment, born out of the terminal" — [GitHub](https://github.com/warpdotdev/warp)

**Zed agent panel: open source, macOS/Linux/Windows**
- Parallel Agents (April 2026): a Threads Sidebar runs several agent threads and terminal threads at once. Each has its own agent, context and history — [Zed docs](https://zed.dev/docs/preview/ai/parallel-agents.html); [AlternativeTo news 2026-04](https://alternativeto.net/news/2026/4/zed-launches-parallel-agent-orchestration-with-a-threads-sidebar-to-control-and-monitor-them/)
- Terminal Threads (2026-05-20) are "now the only way to keep using Claude Code in Zed with your existing Claude subscription". External agents otherwise connect through ACP (the Agent Client Protocol, which Zed created) — [Zed blog](https://zed.dev/blog/terminal-threads)
- 92,423 stars (the editor overall) — [GitHub](https://github.com/zed-industries/zed)

**Newer notable tools in 2026**
- **Orchestrator.inc** (formerly ComposioHQ agent-orchestrator; Apache-2.0; 13,916 stars; v0.14.8 on 2026-10-30). A main agent plans the work and spawns a worker per piece in its own worktree. Kanban lanes are "Working / Needs you / In review / Ready to merge". Desktop on macOS/Windows/Linux, plus iPhone and Android apps that send push notifications "when an agent has a question or needs approval". Has an optional cloud mode and a local daemon — [GitHub README](https://github.com/OrchestratorInc/agent-orchestrator). Note: a "Needs you" lane overlaps directly with Clotho's "Needs you" list.
- **Emdash** (generalaction; YC W26; Apache-2.0; 6,121 stars; v1.2.10 on 2026-10-30). An Electron "agentic development environment" with worktrees, remote machines over SSH/SFTP, and hooks into user-level agent config for status, notifications and resumable sessions. Supports 30+ CLI providers and ticket intake from Linear/GitHub/Jira — [GitHub README](https://github.com/generalaction/emdash); [Augment](https://www.augmentcode.com/tools/open-source-agent-orchestrators)
- **Xum** (Coder; formerly "mux"; AGPL-3.0; 2,062 stars; v0.32.1 on 2026-10-27). Runs isolated parallel agent workspaces on local, worktree or SSH runtimes, with a responsive server-mode UI for mobile browsers. It uses its own agent loop rather than wrapping CLIs — [GitHub README](https://github.com/coder/xum); [Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/)
- **Paneflow**: a native, GPU-rendered terminal workspace for macOS/Linux with branch-aware and session-aware panes, no tmux, and an MIT license (reported by Nimbalyst; repo not verified) — [Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/)
- **Opcode** (formerly Claudia): a Claude Code GUI, AGPL; reported as no longer actively developed — [Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/)

### Inferences
- **Mobile plus remote is now table stakes.** Between July and October 2026, Conductor (iOS remote control, 2026-10-23), Paradev (iOS, Pro), Orca (iOS+Android), Nimbalyst (iOS push), Orchestrator.inc (iOS+Android push) and cmux (iOS TestFlight beta) all shipped phone companions. Clotho's iOS app and push relay are no longer unique; they put Clotho on par with the field.
- **Clotho's actual differentiators** are (a) a headless daemon that keeps live PTYs across client disconnects and swaps itself in place on upgrade without killing shells, while competitors restore layout only (cmux) or lean on tmux (Claude Squad, agent-deck, workmux, cmux local-tmux); (b) restoring exact Claude/Codex conversations per pane after reboot (only ccmanager and Paradev's "persistent sessions" come close, and Paradev doesn't document restore after a reboot); (c) a peer-to-peer multi-machine model over SSH with no cloud account or paid tier, whereas Paradev gates remote hosts and mobile behind Pro and Conductor gates iOS behind Pro; (d) native Swift Mac+iOS clients, while most rivals are Electron or Tauri.
- **Clotho's weaknesses.** It has no worktree-per-task creation, no diff review UI, no "merge the winner" or fan-out of one prompt to N agents, no kanban or task intake (Linear/GitHub issues), no in-app browser or port preview, no scheduled or event-triggered automations, and no Windows or Android. It is also closed and unproven in traction, while cmux (28.6k), Vibe Kanban (28.5k), Paradev (15.8k) and Orca (a reported 110k) have large communities.
- **Volatility.** Terragon (Jan 2026) and Bloop/Vibe Kanban (Apr 2026) both shut down, Crystal folded into Nimbalyst, and Superset renamed itself Paradev. Purely cloud-hosted orchestration has been the riskiest model, while local-first tools keep going.

### Gaps
- Conductor's pricing tiers and whether notifications are native: the pricing page was not fetched, and the changelog detail pages returned 404.
- Funding: Conductor's $22M Series A is unverified (aggregators only, conflicting dates). Funding for cmux/Manaflow, Orca/Stably, Emdash and Paradev was not found.
- Orca's 110k star count is not explained by any source I found.
- Whether Paradev or Orca keep live PTYs across reboots (as opposed to restoring layout) is not documented in what I read.
- Warp's local multi-agent management UI (beyond cloud Oz) was not researched in depth.
- No user counts were found for any tool except Warp (1M+ active).

## Common patterns Clotho lacks, and overlap summary

### Takeaway
Seven recurring features in competitors are absent from Clotho: (1) automatic worktree+branch per task, (2) a diff/changes review pane with merge/PR, (3) kanban or "needs you / in review / ready to merge" lanes, (4) fan-out of one prompt to multiple agents with result comparison, (5) an in-app browser and dev-server port preview, (6) scheduled/event-triggered automations, and (7) issue-tracker intake. Clotho already matches or exceeds rivals on attention status, push, multi-machine, branch/PR display and session persistence.

### Cited Findings
- Worktree per agent is in Conductor, Paradev, Orca, Nimbalyst, Claude Squad, ccmanager, workmux, Emdash, Orchestrator.inc, Vibe Kanban and Sculptor — sources in the profiles above, e.g. [Paradev README](https://github.com/ParadevAI/Paradev), [Orca README](https://github.com/stablyai/orca)
- Diff review and merge/PR flow is in Conductor (it edits files directly in diffs, 0.84.0), Paradev (Changes pane and PR pane), Vibe Kanban and Emdash — [Conductor changelog](https://www.conductor.build/changelog); [paradev compare](https://paradev.com/compare/superset-vs-orca); [Augment](https://www.augmentcode.com/tools/open-source-agent-orchestrators)
- Kanban boards are in Vibe Kanban (To Do/In Progress/Review/Done), Nimbalyst (session kanban) and Orchestrator.inc (Working/Needs you/In review/Ready to merge) — [Augment](https://www.augmentcode.com/tools/open-source-agent-orchestrators); [Nimbalyst README](https://github.com/nimbalyst/nimbalyst); [Orchestrator.inc README](https://github.com/OrchestratorInc/agent-orchestrator)
- Orca offers fan-out and compare ("Fan one prompt across five agents… merge the winner") — [Orca README](https://github.com/stablyai/orca)
- In-app browser and port preview are in cmux (scriptable browser, ports in the sidebar), Paradev (per-worktree port detection) and Vibe Kanban — [cmux README](https://github.com/manaflow-ai/cmux); [Paradev README](https://github.com/ParadevAI/Paradev)
- Automations/routines are in Paradev Pro, Orca, Conductor ("routines", 0.85.0) and Warp Oz (Slack/GitHub/CI triggers) — [paradev compare](https://paradev.com/compare/superset-vs-orca); [Conductor changelog](https://www.conductor.build/changelog); [Warp docs](https://docs.warp.dev/agent-platform/cloud-agents/platform/)
- Issue intake: Emdash (Linear/GitHub/Jira), Orca (PRs, issues and project boards in-app) — [Augment](https://www.augmentcode.com/tools/open-source-agent-orchestrators); [Orca README](https://github.com/stablyai/orca)
- Overlap with Clotho on attention notifications: cmux rings plus panel, Paradev chimes/badges/"waiting on you", Orca unread state, ccmanager "waiting" state, agent-deck notification bar — READMEs linked above
- Overlap on git branch/PR per pane: cmux's sidebar shows branch and linked PR status/number for each workspace — [cmux README](https://github.com/manaflow-ai/cmux)
- Approvals from the phone: Orchestrator.inc sends a push "when an agent has a question or needs approval"; Nimbalyst lets you reply by voice or text from iOS — [Orchestrator.inc](https://github.com/OrchestratorInc/agent-orchestrator); [Nimbalyst](https://github.com/nimbalyst/nimbalyst)

### Inferences
- The cheapest high-value additions for Clotho would be "new pane in a fresh worktree+branch" (it already shows branch/PR per pane) and a read-only diff view per pane on Mac/iOS. Together these close the biggest gap with Conductor, Paradev and Orca without changing Clotho's terminal-first model.
- Clotho's "Needs you" list plus ⌘P tree is roughly equivalent to Orchestrator.inc's "Needs you" lane and Orca's quick open. Positioning should stress that Clotho's version works across machines and survives reboots.
- Marketing angle: competitors gate remote hosts and mobile behind paid tiers (Paradev Pro, Conductor Pro for iOS) or cloud accounts. Clotho is self-hosted over SSH plus a push relay.

### Gaps
- Pane- and file-transfer-between-machines equivalents: I found none in competitors' docs (Emdash uses SFTP for remote projects, but not for transfer between machines). This is not verified exhaustively.
- Approval handling (allow/deny of tool permissions) from the desktop UI is not documented in detail for most tools.
