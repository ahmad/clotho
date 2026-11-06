# Mobile and remote control of AI coding agents (competitive landscape vs Clotho)

Research date: 2026-10-30. GitHub star counts were read from the repo pages on that date. Facts from third-party blogs are marked "(secondary)". Where a claim is older than 2026 it is dated.

## Q1. Platform vendors (Anthropic, OpenAI, GitHub, Cursor, Google): what they have shipped for remote/mobile agent control

### Takeaway
Anthropic and OpenAI now both ship first-party "drive the agent on your own machine from your phone" features: Claude Code Remote Control (Feb 2026) and Codex in the ChatGPT mobile app (May 2026). Both have push notifications, approvals from the phone, diffs and phone-initiated sessions, all relayed through the vendor's cloud. That covers Clotho's core "steer agents from the iPhone" pitch for single-vendor users. What neither offers is a real persistent terminal and multiplexer, multiple agent vendors in one place, self-hosting without the vendor relay, or Live Activities. GitHub, Cursor and Google (Jules) focus on cloud-sandbox agents that open PRs. Those are a different model from local sessions.

### Cited Findings

**Anthropic: Claude Code Remote Control (local session, Anthropic relay)**
- Announced Feb 24–25, 2026 as a research preview, initially for Max subscribers — [Help Net Security, 2026-02-25](https://www.helpnetsecurity.com/2026/02/25/anthropic-remote-control-claude-code-feature/); [VentureBeat](https://venturebeat.com/orchestration/anthropic-just-released-a-mobile-version-of-claude-code-called-remote)
- Current docs: it connects claude.ai/code and the Claude iOS/Android apps to a Claude Code session running on your machine. "Your computer has to stay on and the `claude` process has to keep running" — [Claude Code docs: Remote Control](https://code.claude.com/docs/en/remote-control)
- Plans: Pro, Max, Team and Enterprise. API keys are not supported. It doesn't work with Bedrock, Vertex/Agent Platform, Foundry, a custom `ANTHROPIC_BASE_URL` or LLM gateways. ZDR and HIPAA orgs can't enable it — [docs](https://code.claude.com/docs/en/remote-control)
- Architecture: "Your local Claude Code session makes outbound HTTPS requests only and never opens inbound ports… registers with the Anthropic API and polls for work." The transcript is stored on Anthropic servers while connected — [docs](https://code.claude.com/docs/en/remote-control)
- Server mode (`claude remote-control`) hosts multiple concurrent sessions (`--capacity`, default 32). `--spawn same-dir|worktree|session` controls how new sessions start, so new sessions can be started from the phone or web. You can resume within about 4 hours of a server stop. There's a QR code for pairing — [docs](https://code.claude.com/docs/en/remote-control)
- Also available from the Claude Desktop app and the VS Code extension (`/remote-control`, `/rc`). Can auto-connect every session (`remoteControlAtStartup`) — [docs](https://code.claude.com/docs/en/remote-control)
- Mobile push notifications: "Push when Claude decides" and "Push when actions required" (permission prompts and questions). There's no per-event configuration beyond these two toggles. Pushes are suppressed while you're focused on the terminal; `CLAUDE_CLIENT_PRESENCE_FILE` extends that — [docs](https://code.claude.com/docs/en/remote-control)
- Permission prompts and AskUserQuestion are forwarded and stay open until answered. The device shows a git diff pane, can switch model and effort, attach photos and files, and stop subagents — [docs](https://code.claude.com/docs/en/remote-control)
- Limits: one remote session per interactive process outside server mode. If the process exits, the session goes offline, and the docs tell users to run it in `tmux`/`screen` on remote machines. Server mode exits after about 10 minutes of network outage. Some commands are local-only (e.g. `/plugin`, `/resume`), and `!` shell mode doesn't run from mobile — [docs](https://code.claude.com/docs/en/remote-control)
- "Trusted Devices" (beta): device enrollment plus biometric re-auth every 18 hours for Remote Control viewers — [docs](https://code.claude.com/docs/en/remote-control)
- Anthropic's other away-from-desk modes: **Dispatch** (message a task from the Claude mobile app to Claude Desktop on your machine), **Channels** (push events from Telegram/Discord/your own server into a CLI session), and **cloud sessions** — [docs comparison table](https://code.claude.com/docs/en/remote-control)
- (Secondary) An Aug 2026 update reportedly shows any machine running `claude remote-control` as a device card in the mobile app's Code tab — [search summary of third-party guides; not confirmed officially](https://claudefa.st/blog/guide/development/remote-control-guide)
- (Secondary, as of 2026-06-29) A competitor's review lists Remote Control as having "no push notifications" and no mobile-optimized UI. That is now contradicted by the official docs, which describe mobile push — [Nimbalyst blog, updated 2026-06-29](https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/) vs [docs](https://code.claude.com/docs/en/remote-control)

**Anthropic: Claude Code on the web / cloud sessions (vendor sandbox)**
- Launched Oct 20, 2025 as a research preview for Pro/Max, with the Claude iOS app as companion. Tasks run in an isolated Anthropic sandbox and create PRs; `/teleport` pulls a cloud session into the local terminal — [Engadget](https://www.engadget.com/ai/anthropic-brings-claude-code-to-ios-and-the-web-180023611.html); [iPhone in Canada, 2025-10-20](https://www.iphoneincanada.ca/2025/10/20/anthropic-expands-claude-code-to-web-and-ios-for-cloud-coding/); [Claude blog](https://claude.com/de/blog/claude-code-on-the-web)

**OpenAI: Codex in the ChatGPT mobile app ("Codex Remote")**
- Preview launched May 14–15, 2026. iPhone and Android users get remote access to Codex sessions running on a Mac. Pairing is a QR code scanned from the Codex app's "Codex mobile" section — [MacRumors, 2026-05-15](https://www.macrumors.com/2026/05/15/openai-brings-codex-chatgpt-mobile-app/)
- Features: resume live chats and projects, notifications when a task finishes or needs input, start new threads from the phone, approve commands, switch models, see screenshots, terminal output, diffs and test results in real time. "Files, credentials, and permissions stay on the machine where Codex is operating." Hosts mentioned include laptops, Mac minis, "devboxes" and "remote environments" — [MacRumors](https://www.macrumors.com/2026/05/15/openai-brings-codex-chatgpt-mobile-app/); official post at [openai.com/index/work-with-codex-from-anywhere](https://openai.com/index/work-with-codex-from-anywhere/) (returned 403 to fetch)
- Windows host support was "coming soon" at launch — [MacRumors](https://www.macrumors.com/2026/05/15/openai-brings-codex-chatgpt-mobile-app/). (Secondary) A later guide quotes docs saying "Remote supports hosts running the ChatGPT desktop app on macOS and Windows" — [aicatchup](https://aicatchup.com/news/codex-chatgpt-mobile-preview)
- Plans conflict: one blog says it left preview on 2026-06-25 for all paid plans; another says it is rolling out to all plans, including Free and Go. Unverified — [Simon Carter blog](http://simoncarter.ai/posts/codex-is-now-in-the-chatgpt-mobile-app-live-sessions-approvals-and-full-project-/); [Android Headlines](https://www.androidheadlines.com/2026/05/openai-codex-mobile-remote-control-chatgpt.html)
- (Secondary) OpenAI merged the Codex app into the ChatGPT desktop app on 2026-07-09 — [Wikipedia: OpenAI Codex (AI agent)](https://en.wikipedia.org/wiki/OpenAI_Codex_(AI_agent))

**GitHub Copilot coding agent (cloud agent → PRs)**
- Coding agent on GitHub Mobile since June 2025 — [GitHub changelog 2025-06-04](https://github.blog/changelog/2025-06-04-github-copilot-coding-agent-now-available-on-github-mobile). Starting and tracking tasks from mobile Home and repo views since Sept 2025 — [changelog 2025-09-24](https://github.blog/changelog/2025-09-24-start-and-track-copilot-coding-agent-tasks-in-github-mobile/)
- Docs: the cloud agent on mobile is available on all paid Copilot plans — [GitHub Docs](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-mobile). The Agents tab and panel for managing tasks (public preview) works across web, CLI, Mobile, VS Code, Raycast and JetBrains — [GitHub Docs: manage agents](https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/use-copilot-agents/manage-agents); [Visual Studio Magazine, 2026-01-29](https://visualstudiomagazine.com/articles/2026/01/29/hands-on-new-github-agents-tab-for-repo-level-copilot-coding-agent-workflows.aspx)
- (Secondary) A mobile Copilot-tab refresh around Apr 2026 added native session logs and stop/open-PR controls, and live state-change alerts arrived Feb 2026, including for third-party Codex and Claude agent sessions — [ExpertBeacon](https://expertbeacon.com/github-mobiles-new-copilot-tab-how-useful-is-it-for-managing-agent-sessions-away-from-your-desk/)
- Desktop GitHub Copilot app technical preview announced May 14, 2026 / Build 2026 — [Help Net Security](https://www.helpnetsecurity.com/?p=373480)

**Cursor (cloud "Background Agents", now "Cloud Agents")**
- Web and mobile agents launched June 30, 2025 at cursor.com/agents, with a PWA for iOS and Android, Slack notifications on completion, `@Cursor` in Slack, and diff/PR review on the web — [Cursor blog, 2025-06-30](https://cursor.com/blog/agent-web)
- (Secondary) A native iOS app (iPhone/iPad) entered public beta around June 29, 2026 for starting and steering cloud agents and reviewing diffs. A community forum reply calls it limited-access, so availability is unclear — [Stackmaven](https://stackmaven.io/news/cursor-ios-mobile-app-launch/); [Cursor forum](https://forum.cursor.com/t/when-can-we-expect-to-have-native-cursor-mobile-app/163824)

**Google (Gemini CLI / Jules / Antigravity)**
- Jules is a cloud-VM agent that opens PRs. A `/jules` extension for Gemini CLI shipped in Oct 2025 — [Google Cloud blog](https://cloud.google.com/blog/topics/developers-practitioners/master-multi-tasking-with-the-jules-extension-for-gemini-cli); [AlternativeTo, 2025-10](https://alternativeto.net/news/2025/10/google-unveils-jules-for-gemini-cli-bringing-autonomous-coding-tasks-to-the-terminal)
- (Secondary, unverified) The closed-source Antigravity CLI replaced Gemini CLI for personal and free users on 2026-06-18 — [developertoolkit.ai](https://developertoolkit.ai/en/comparison/gemini-cli/)

### Inferences
- The platform threat is real and concrete. Claude Code Remote Control now matches most of Clotho's phone story for Claude-only users: approvals, push notifications, starting sessions from the phone, diffs, multiple sessions via server mode. Codex in ChatGPT does the same for Codex users. Both are free with existing subscriptions.
- Clotho's remaining structural advantages over vendor features:
  - one client for both Claude and Codex
  - a real PTY terminal with persistent workspaces, tabs and panes that survive reboots (Remote Control's own docs tell users to use tmux on remote machines)
  - no transcript stored on a vendor relay (Remote Control is unavailable to ZDR/HIPAA orgs and to API-key, Bedrock or gateway users)
  - a "Needs you" list across machines
  - Live Activities and lock-screen Allow/Deny. I found no evidence that Anthropic or OpenAI ship Live Activities.
- Cloud-sandbox products (Claude Code on the web, Cursor Cloud Agents, Copilot coding agent, Jules) compete for the "delegate from phone" job, not for "steer my running local session". They overlap less with Clotho.

### Gaps
- Whether the Claude iOS app or ChatGPT app offers actionable lock-screen buttons (Allow/Deny in the notification) or Live Activities. I found nothing either way.
- The official OpenAI post returned 403, so the plan and region details for Codex Remote come from press and blogs only.
- The Aug 2026 Remote Control "device card" claim is not confirmed from an official source.
- Cursor iOS app GA status is unverified.

## Q2. Third-party remote/mobile agent apps: Happy, Omnara, VibeTunnel, Paseo, Nimbalyst, others

### Takeaway
The independent field has split. Happy (24.4k stars) and Paseo (22.5k stars) are large, MIT/Apache open-source, multi-agent, phone-first controllers. Paseo is architecturally the closest to Clotho: a local daemon, native mobile apps, terminals, worktrees and an optional E2E relay. VibeTunnel is a browser terminal proxy for the Mac. Omnara, the early YC "agent command center", abandoned remote coding in Jan 2026. Nimbalyst competes with a kanban and diff-review angle.

### Cited Findings

**Happy / Happy Coder (slopus/happy)**
- Open-source (MIT) mobile and web client for Claude Code and Codex. You run `happy` in place of `claude`/`codex`, and pairing is by QR code — [App Store listing](https://apps.apple.com/app/id6748571505); [GitHub](https://github.com/slopus/happy)
- As of 2026-10-30: 24.4k stars, 2.1k forks, 3,767 commits, 670 open issues — [GitHub](https://github.com/slopus/happy)
- Agents: Claude Code, Codex, Grok, Gemini "through Antigravity", OpenCode and any Agent Client Protocol agent. It "wraps the Claude Code and Codex harnesses directly in your terminal." Reuses existing subscriptions: "Happy adds a harness, not another bill" — [GitHub](https://github.com/slopus/happy)
- Architecture: happy-server is "the relay server for encrypted sync" (E2E encrypted); happy-push-server is a Cloudflare Worker that delivers APNs/FCM pushes; Dockerfiles are provided for self-hosting; happy-desktop covers macOS, Windows and Linux. It's "natively multiplayer" (others can join and steer a session) — [GitHub](https://github.com/slopus/happy)
- Push notifications for permission requests and task completion. Free with in-app purchases. App Store update dated 2026-03-26 — [App Store](https://apps.apple.com/app/id6748571505); (secondary) [search summary of listings](https://apps.appfollow.io/ios/happy-codex-claude-code-app/6748571505?country=nl)
- (Secondary, possibly stale) Google Play: about 18.4K installs, 4.89 rating from about 1.7K ratings — [AppGoblin](https://appgoblin.info/apps/com.ex3ndr.happy)
- (Secondary, competitor's view) Nimbalyst describes Happy as "mostly read-only" and iOS-only. That conflicts with the GitHub README, which lists iOS, Android and web — [Nimbalyst](https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/) vs [GitHub](https://github.com/slopus/happy)

**Paseo (getpaseo/paseo, paseo.sh)**
- "Paseo runs a local server called the daemon that manages your coding agents." Clients are the desktop app (Electron), iOS and Android (Expo), web and CLI. Connections go over TCP, Tailscale or a VPN, or through an optional "end-to-end encrypted relay for device pairing" — [GitHub](https://github.com/getpaseo/paseo)
- Agents: "Claude Code, Codex, Copilot, OpenCode, Pi, Antigravity, and Muse Code." Worktree-per-agent, multiple machines, split-pane terminals, `paseo attach`, diffs and PRs, a built-in browser, voice mode, and "no telemetry, tracking, or forced log-ins" — [GitHub](https://github.com/getpaseo/paseo)
- As of 2026-10-30: 22.5k stars, 2.7k forks, 6,220 commits. Apache-2.0 per the repo; the App Store listing reportedly says AGPL, which is inconsistent — [GitHub](https://github.com/getpaseo/paseo); [App Store](https://apps.apple.com/us/app/paseo-remote-coding-agents/id6758887924)
- App Store listing: live agent output and push notifications when tasks complete — [App Store](https://apps.apple.com/us/app/paseo-remote-coding-agents/id6758887924). Show HN — [HN item 47397226](https://news.ycombinator.com/item?id=47397226)

**VibeTunnel (amantus-ai/vibetunnel; Peter Steinberger et al.)**
- Launched mid-2025 as a way to "turn any browser into your Mac terminal". You wrap commands with `vt` (e.g. `vt claude`) and get a dashboard on localhost:4020 — [steipete.me, 2025](https://steipete.me/posts/2025/vibetunnel-turn-any-browser-into-your-mac-terminal)
- As of 2026-10-30: 4.7k stars, 336 forks, MIT. Components are a macOS menu-bar app (Apple Silicon only), a Node.js server (an npm package for Linux and headless machines; no Windows) and a web frontend (Lit + ghostty-web). The iOS app is "still work in progress and not recommended for production use" — [GitHub](https://github.com/amantus-ai/vibetunnel)
- Remote access via Tailscale (recommended), ngrok, Cloudflare Quick Tunnel and others. Active/idle activity tracking, Git Follow Mode for worktrees, asciinema session recording, and a push notifications doc — [GitHub](https://github.com/amantus-ai/vibetunnel)

**Omnara**
- YC- and Pioneer Fund-backed. Raised about $500K pre-seed in Sept 2025 (third-party tracker, unverified) — [VCBacked](https://www.vcbacked.co/company/omnara). It was marketed as a "real-time command center to monitor, debug, and guide your agent—right from your phone" — [listing](https://microlaunch.net/p/omnara)
- A company post dated 2026-01-28 labels the remote-coding product "historical". Omnara is now an open-source, self-hostable managed-agent platform, positioned as an alternative to Claude Managed Agents and the OpenAI Agents API. Founders are Ishaan Sehgal and Kartik Sarangmath — [RuntimeWire](https://runtimewire.com/article/startup-spotlight-omnara-agent-control-plane); [Railway](https://railway.com/deploy/omnara)

**Nimbalyst** (vendor-authored source; treat as marketing)
- Free MIT iOS companion to the Nimbalyst desktop app (macOS, Windows, Linux). Kanban of sessions across projects, visual diff review, push per project, start sessions from the phone, Claude Code and Codex, team visibility — [Nimbalyst blog, 2026-03-13, updated 2026-06-29](https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/)

**Others mentioned**
- "Claude Remote" (iOS and Android, chat-style, needs port forwarding or a tunnel, push is paid) and generic mobile SSH IDEs — [Nimbalyst](https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/)
- DIY Tailscale + tmux + mobile SSH is still a common recommended path — [explainx.ai guide](https://explainx.ai/blog/claude-code-mobile-remote-control-phone-guide-2026)

### Inferences
- Paseo is Clotho's closest analog: a per-machine daemon, native mobile apps, terminals, multi-machine, multi-agent and self-hosted. It is larger in reach (Android, web, Windows desktop, 7 agents) and has strong traction. Clotho's differentiators against it would be a native Swift Mac/iOS UX, sessions that survive daemon upgrades and reboots with Claude/Codex conversation restore, lock-screen Allow/Deny plus Live Activities, and SSH-based multi-machine without a relay. I couldn't confirm whether Paseo has actionable push or session persistence across reboots.
- Happy's strength is reach and simplicity: a CLI wrapper, QR pairing, an E2E relay and multiplayer. Its weakness relative to Clotho is that it's a chat view over a wrapped harness rather than a real persistent terminal and multiplexer.
- VibeTunnel shows demand for "real terminal in browser" but is Mac-centric. Its iOS app is immature.
- Omnara's pivot suggests that a standalone paid "remote control for agents" business was squeezed once vendors shipped Remote Control and Codex mobile (Feb and May 2026). This is an inference from timing, not stated by Omnara.

### Gaps
- Kibitz, Sled and CodeRemote: I did not search these within the tool budget. Nothing was verified.
- Termius-style agent features were not researched.
- App Store ratings and review counts for Happy (iOS), Paseo and Nimbalyst were not retrieved. Happy's Android numbers come from a third-party tracker.
- Release dates and latest versions for Happy, Paseo and VibeTunnel: the Releases sections showed as empty on fetch.
- Omnara's pre-pivot feature set and pricing, and its GitHub stars, were not found in primary sources.
- Paseo's launch date isn't known exactly. The HN Show item exists, but its date was not captured.

## Q3. Feature matrix vs Clotho (approvals, push, Live Activities, terminal vs chat, architecture, OSS/pricing)

### Takeaway
Approvals from the phone and push for "needs input" are table stakes in 2026: Claude Remote Control, Codex mobile, Happy and Nimbalyst all have them. No source found shows any competitor offering iOS Live Activities or lock-screen Allow/Deny action buttons. A real persistent terminal plus multiplexer is rare: Paseo, VibeTunnel and DIY tmux. Everyone else is chat/transcript-only.

### Cited Findings
| Product | Runs where | Transport | Agents | Phone approvals | Push | Real terminal | OSS / price | Traction (date) |
|---|---|---|---|---|---|---|---|---|
| Claude Code Remote Control | Your machine | Anthropic relay, outbound HTTPS, transcript stored ([docs](https://code.claude.com/docs/en/remote-control)) | Claude only | Yes ([docs](https://code.claude.com/docs/en/remote-control)) | Yes, 2 toggles ([docs](https://code.claude.com/docs/en/remote-control)) | No (chat UI plus diff; `!` shell not run from mobile) ([docs](https://code.claude.com/docs/en/remote-control)) | Closed; included in Pro/Max/Team/Ent ([docs](https://code.claude.com/docs/en/remote-control)) | Launched 2026-02-24 ([HNS](https://www.helpnetsecurity.com/2026/02/25/anthropic-remote-control-claude-code-feature/)) |
| Codex in ChatGPT mobile | Your Mac (Windows later) | OpenAI relay | Codex only | Yes ([MacRumors](https://www.macrumors.com/2026/05/15/openai-brings-codex-chatgpt-mobile-app/)) | Yes ([MacRumors](https://www.macrumors.com/2026/05/15/openai-brings-codex-chatgpt-mobile-app/)) | Terminal output shown; no interactive PTY reported | Closed; plan scope disputed | Preview 2026-05-14 |
| Claude Code on the web | Anthropic sandbox | n/a | Claude | n/a (sandboxed) | — | No | Closed; Pro/Max at launch | 2025-10-20 ([Engadget](https://www.engadget.com/ai/anthropic-brings-claude-code-to-ios-and-the-web-180023611.html)) |
| Copilot coding agent | GitHub cloud | n/a | Copilot (+ alerts for Claude/Codex sessions, secondary) | n/a | Yes (secondary) | No | Paid Copilot ([docs](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-mobile)) | Mobile since 2025-06 |
| Cursor Cloud Agents | Cursor cloud | n/a | Cursor | n/a | Slack ([blog](https://cursor.com/blog/agent-web)) | No | Paid | Web/PWA 2025-06-30; iOS beta 2026-06 (secondary) |
| Happy | Your machine | E2E relay, self-hostable ([GitHub](https://github.com/slopus/happy)) | Claude, Codex, Grok, Gemini, OpenCode, ACP | Yes (permission push) ([App Store](https://apps.apple.com/app/id6748571505)) | Yes, APNs/FCM | No (wrapped chat) | MIT; free + IAP | 24.4k stars (2026-10-30) |
| Paseo | Your machine(s), daemon | Direct TCP/Tailscale or optional E2E relay ([GitHub](https://github.com/getpaseo/paseo)) | 7 agents | Plugins "answer permissions"; phone approvals not confirmed | Task-complete push ([App Store](https://apps.apple.com/us/app/paseo-remote-coding-agents/id6758887924)) | Yes, split-pane terminals | Apache-2.0 (AGPL per store); free | 22.5k stars (2026-10-30) |
| VibeTunnel | Your Mac/Linux | Tailscale/ngrok/tunnels ([GitHub](https://github.com/amantus-ai/vibetunnel)) | Any terminal app | Via terminal | Push doc exists | Yes (browser PTY) | MIT; free | 4.7k stars (2026-10-30) |
| Nimbalyst | Desktop app host | — | Claude, Codex | Replies; approvals implied | Per-project push | No | MIT; free ([blog](https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/)) | — |
| Omnara | (pivoted 2026-01) | — | — | — | — | — | Now open-source agent platform ([RuntimeWire](https://runtimewire.com/article/startup-spotlight-omnara-agent-control-plane)) | ~$500K pre-seed (unverified) |

### Inferences
- Gaps Clotho can own:
  - (a) Live Activities and actionable lock-screen Allow/Deny, which I found nowhere else
  - (b) a real persistent terminal and multiplexer that survives reboots and daemon upgrades, with Claude/Codex conversation restore (vendors tell you to use tmux)
  - (c) no vendor relay storing transcripts, which matters for ZDR/HIPAA/API-key/Bedrock users who can't use Remote Control
  - (d) one "Needs you" list across machines and across both Claude and Codex
- Where Clotho is behind:
  - no Android or web client, which Happy, Paseo, Anthropic and OpenAI all have
  - Mac/Linux daemon only (Paseo and Happy have Windows desktop)
  - a smaller agent roster than Happy or Paseo
  - zero-setup vendor features that come bundled with subscriptions

### Gaps
- I could not verify whether Paseo, Happy or VibeTunnel restore agent conversations after a host reboot.
- No source confirmed or ruled out Live Activities in Happy, Paseo or Nimbalyst. The claim that "nobody else has them" is absence of evidence from the sources read, not proof.
