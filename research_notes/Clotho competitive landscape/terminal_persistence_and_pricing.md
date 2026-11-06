# Terminal persistence, remote/SSH clients, and pricing norms (as of 2026-10-30)

Scope: tools that keep terminal sessions alive and reachable across machines and devices, compared with Clotho (per-machine Rust session daemon, native Mac + iOS apps, persistent Workspaces/Tabs/Panes surviving client disconnects and reboots, multi-machine over SSH, coding-agent awareness with push and lock-screen approvals). GitHub star counts were pulled live from the GitHub REST API on 2026-10-30 (`api.github.com/repos/<owner>/<repo>`); the repo URL is cited for each.

Date convention: facts marked (2026-10) were read on a page fetched on 2026-10-30. Older or third-party-only facts are flagged.

---

## 1. What each tool does: persistence model, multi-device/mobile access, sync

### Takeaway
No single incumbent combines all of Clotho's parts. Multiplexers (tmux, Zellij, screen) keep sessions alive across client disconnects but lose them on host reboot. The exception is layout/command "resurrection" (tmux-resurrect, Zellij), which re-runs commands instead of keeping processes alive. Roaming transports (Mosh, ET) only fix the network link. Mobile SSH apps (Blink, Termius, Prompt, ShellFish, La Terminal) are clients that need a multiplexer on the host. A 2025–2026 wave of agent-focused companion apps (Happy, Paseo, Moshi, Agentastic, Orca, Nimbalyst, Superset, plus Anthropic's own Remote Control) comes closest to Clotho's agent and mobile story. Most of them are agent-centric (chat and approvals) rather than terminal-workspace-centric.

### Cited Findings

**Multiplexers / persistence layers**
- **tmux**: 50,074 GitHub stars, ISC license, actively pushed (2026-10-30). — [GitHub tmux/tmux](https://github.com/tmux/tmux)
  - The server keeps sessions alive when clients detach, but they die with the host. Persistence across reboot needs the tmux-resurrect plugin ("Persists tmux environment across system restarts"). That plugin has 13,118 stars, an MIT license, and its last push was **2024-08-13**, so it is effectively in maintenance. — [GitHub tmux-plugins/tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
  - tmux control mode is a protocol that lets a GUI terminal render tmux windows natively. — [tmux wiki: Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- **Zellij**: 35,896 stars, MIT, active (2026-10-30). — [GitHub zellij-org/zellij](https://github.com/zellij-org/zellij)
  - **Session resurrection** shipped in 0.39.0. Each session is serialized to a cache folder so it can be recreated after a quit or crash, and it can be revived from the CLI or the session manager. This recreates layout and commands; it does not keep processes alive. — [Zellij docs: Session Resurrection](https://zellij.dev/documentation/session-resurrection); [GitHub releases](https://www.github.com/zellij-org/zellij/releases)
  - The **web client** shipped in 0.43.0 (announced around Aug 2025). It shares running sessions to a browser, and bookmarked session URLs bring back exited sessions. A `zellij-no-web` build exists. — [DEV: Zellij 0.43 brings the terminal to your browser](https://dev.to/imsnif/zellij-043-brings-the-terminal-to-your-browser-57lg); [r/commandline thread (mirror)](https://reddit.zackpollard.pro/r/commandline/comments/1mjtiya/zellij_043_released_bringing_your_terminal_to_the)
  - **0.44.0** added attaching to a remote shared session over HTTPS, read-only session tokens, an explicit save trigger for resurrection, and fixes to the **mobile web client**. Exact release date not found. — [newreleases.io v0.44.0](https://newreleases.io/project/github/zellij-org/zellij/release/v0.44.0)
- **GNU screen**: I made no fresh fetch in this session. See Gaps.
- **Wave Terminal**: 22,625 stars, Apache-2.0, "open-source, AI-integrated, cross-platform terminal". — [GitHub wavetermdev/waveterm](https://github.com/wavetermdev/waveterm)
  - v0.14.0 added **Durable Sessions** for SSH. They survive connection interruptions, network changes and Wave restarts, using a remote job manager over Unix domain sockets. The feature is **off by default** and SSH-only (local and WSL terminals don't get it). Closing the block ends the session. — [Wave docs: durable sessions](https://docs.waveterm.dev/durable-sessions); [newreleases v0.14.0](https://newreleases.io/project/github/wavetermdev/waveterm/release/v0.14.0)

**Roaming transports (fix the network, not the session)**
- **Mosh**: 14,612 stars, GPL-3.0, last push **2026-03-22** (slow cadence). — [GitHub mobile-shell/mosh](https://github.com/mobile-shell/mosh)
- **Eternal Terminal (ET)**: 3,937 stars, Apache-2.0, "Re-Connectable secure remote shell", active (2026-10-29). — [GitHub MisterTea/EternalTerminal](https://github.com/MisterTea/EternalTerminal)
- Neither keeps a session after the host reboots. Both are usually paired with tmux. (This is an inference from their designs. Mosh and ET describe themselves as a mobile shell and a reconnectable shell, not as multiplexers; see the repo descriptions above.)

**Terminal emulators with persistence or remote features**
- **iTerm2**: 18,238 stars, GPL-2.0, active. — [GitHub gnachman/iTerm2](https://github.com/gnachman/iTerm2)
  - Its tmux integration (`tmux -CC`, built on tmux control mode) renders remote tmux windows and tabs as native iTerm2 windows, so they survive disconnect through tmux. — [tmux wiki: Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode). The iTerm2 docs page was not re-fetched this session.
- **Ghostty**: 63,023 stars, MIT, active. — [GitHub ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
  - 1.3.0 was released **2026-03-09**. It added scrollback search, native scrollbars, click-to-move-cursor, and "key tables" for tmux-like modal keybindings. — [Ghostty 1.3.0 release notes](https://ghostty.org/docs/install/release-notes/1-3-0); [OMG! Ubuntu](https://www.omgubuntu.co.uk/2026/03/ghostty-1-3-terminal-brings-big-new-features)
  - 1.3.1 fixed regressions. — [Linuxiac](https://linuxiac.com/ghostty-1-3-1-terminal-emulator-released-with-fixes-for-1-3-regressions/)
  - I found **no evidence of session persistence** or user-facing tmux control mode in Ghostty. A 2024 discussion said control mode was not integrated. — [ghostty discussion #2839](https://github.com/ghostty-org/ghostty/discussions/2839)
- **Warp**: 65,791 stars, **AGPL-3.0**. Warp went open source in 2026 and calls itself "an agentic development environment, born out of the terminal". — [GitHub warpdotdev/warp](https://github.com/warpdotdev/warp); [DEV: Warp just went open source](https://dev.to/devtoolpicks/warp-just-went-open-source-what-indie-hackers-actually-need-to-know-229l)
  - The pricing page shows no mobile app. Remote visibility comes through cloud agents and shared session links in Slack, Linear and GitHub (2026-10). — [Warp pricing](https://www.warp.dev/pricing)

**Terminal sharing / web terminals (ephemeral, not persistent)**
- **sshx**: 7,708 stars, MIT. "Fast, collaborative live terminal sharing over the web." — [GitHub ekzhang/sshx](https://github.com/ekzhang/sshx)
- **upterm**: 1,331 stars, Apache-2.0. "Instant Terminal Sharing." — [GitHub owenthereal/upterm](https://github.com/owenthereal/upterm)
- **tmate**: 6,134 stars, a tmux fork for instant sharing. — [GitHub tmate-io/tmate](https://github.com/tmate-io/tmate)
- **ttyd**: 12,565 stars, MIT. "Share your terminal over the web." — [GitHub tsl0922/ttyd](https://github.com/tsl0922/ttyd)
- These are pairing and sharing tools. Sessions end with the process, and none has agent awareness. (This is an inference from the repo descriptions.)

**Network/identity layer**
- **Tailscale SSH**: included on the free Personal plan, limited to "up to 5 hosts". Check mode is available on Personal (2026-10). — [Tailscale pricing](https://tailscale.com/pricing)
  - Tailscale has 38,354 stars, BSD-3-Clause. — [GitHub tailscale/tailscale](https://github.com/tailscale/tailscale)
  - It provides reachability and auth only, with no session persistence. In practice Tailscale is the de facto transport in nearly every DIY "phone to agent" setup. Claude-mobile, Orca and Agentastic all name Tailscale or a tailnet as the link. — [agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone); [claude-mobile](https://github.com/Almaz2001AA/claude-mobile)

**Mobile and desktop SSH clients**
- **Blink Shell** (iOS/iPadOS): 7,000 stars, GPL-3.0, last push 2026-06-29. Describes itself as "Mobile Shell for iOS (Mosh based)". — [GitHub blinksh/blink](https://github.com/blinksh/blink)
  - Blink Build (cloud dev VMs) is a separate $7.99/month subscription. — [App Store: Blink Shell, Build & Code](https://apps.apple.com/app/blink-shell/id1594898306)
- **Termius** (iOS, Android, macOS, Windows, Linux):
  - Free Starter covers a local vault, SSH/SFTP, AI autocomplete and port forwarding.
  - **Cross-device sync of hosts and keys is the Pro paywall**: personal cloud vault, mobile and desktop sync, session logs, snippet automation.
  - Team adds a shared vault and real-time collaboration (2026-10). — [Termius pricing](https://termius.com/pricing)
- **Prompt 3** (Panic): App Store only, covering macOS, iOS, iPadOS and visionOS. 7-day trial. After expiry, servers, clips and keys can still be exported. — [Panic Prompt purchase FAQ](https://help.panic.com/prompt/purchase-faq/)
- **Secure ShellFish** (iOS/macOS):
  - Offers SFTP as a Files-app provider.
  - With its Shell Integration installed on the host, it can send **notifications and update widgets from the terminal**, "even from cron jobs". This is the closest pre-agent precedent for host-to-phone push in a mainstream SSH app. — [App Store: Secure ShellFish](https://apps.apple.com/us/app/secure-shellfish-ssh-sftp/id1336634154?uo=4)
- **La Terminal** (iOS): an SSH and Mosh client, free with Pro in-app purchases. — [App Store: La Terminal](https://apps.apple.com/us/app/la-terminal-ssh-client/id1629902861)

### Inferences
- The persistence spectrum runs from fragile to durable:
  - Plain SSH: dies on disconnect.
  - Mosh and ET: survive network changes.
  - tmux, screen and Zellij: survive client exit.
  - Zellij resurrection and tmux-resurrect: rebuild the layout and re-run commands after a reboot, but running processes, scrollback and agent state are lost.
  - Clotho's claim that panes survive reboots should be stated precisely against this spectrum. If Clotho restores layout and cwd but not the live processes, that matches Zellij resurrection. It would only be a differentiator if Clotho does more.
- Zellij is the closest open-source analog on the multiplexer axis: persistence, resurrection, and a browser and mobile web client with session tokens. It has no native iOS app and no agent awareness.

### Gaps
- GNU screen: I did not fetch a current-state source. It is generally considered stable and in maintenance mode, but that is uncited.
- **Shellbox**: I found no reliable source on a product by that name.
- iTerm2 2025–2026 AI features: I did not fetch iTerm2's own documentation, so the tmux integration details rest on the tmux wiki.
- Exact App Store ratings and review counts for Blink, Termius, Prompt, ShellFish and La Terminal were not collected (a time limit).

---

## 2. AI-agent-specific features added in 2025–2026

### Takeaway
Agent awareness has become a crowded category in 2026. At least 8 iPhone options for Claude Code were compared as of Oct 2026, including Anthropic's own Remote Control with push and approvals. Several are free and MIT or Apache open source, with 20k+ stars each (Happy, Paseo). Clotho's agent features are therefore table stakes against agent companions. Its differentiation would have to be **terminal-first persistent Workspaces/Tabs/Panes plus native apps plus multi-machine**, not agent notifications alone.

### Cited Findings

**Anthropic's own offering**
- **Claude app Remote Control (Code tab)** runs cloud sessions, drives a local session via Remote Control, or dispatches work to the desktop app.
  - Push is enabled in `/config` ("Push when actions required"), and approvals are handled in the app.
  - The computer must be on with the `claude` process running. It runs Claude only.
  - It requires a Pro, Max, Team or Enterprise plan.
  - Source: the comparison was last updated 2026-10-05 and was written by a competitor, Agentastic. — [Agentastic: Claude Code on iPhone, 8 options compared](https://www.agentastic.dev/compare/claude-code-iphone)
- Users have reported Claude Code push notifications not reaching linked iPhones. This is an open GitHub issue, so the current status is uncertain. — [anthropics/claude-code#28765](https://github.com/anthropics/claude-code/issues/28765)

**Open-source agent companions**
- **Happy**: wraps the CLI (`happy claude` / `happy codex`).
  - Push and allow/deny from the phone. Clients on iOS, Android, web and a macOS desktop app. MIT, with a self-hostable relay. — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)
  - 24,419 stars. Now describes itself as "Orchestrate Claude, Codex and Grok in one app… reuses the subscriptions". — [GitHub slopus/happy](https://github.com/slopus/happy)
  - Taking control from the phone restarts the session in remote mode, so it is not a persistent terminal. — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)
- **Paseo**: a daemon beside the agents with phone, desktop, web and CLI clients.
  - Supports Claude Code, Codex and 30+ agents, with approvals, push, a workspace terminal, diffs and merge. Hosts on macOS, Windows, Linux or Docker. Free, Apache 2.0, with an open-source relay. — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)
  - 22,520 stars. — [GitHub getpaseo/paseo](https://github.com/getpaseo/paseo)
  - **This is the closest architectural analog to clothod: a host daemon with mobile clients.**

**Commercial and app-bundled companions**
- **Orca mobile companion** (MIT; LAN, Tailscale or Orca Relay), **Nimbalyst Mobile** (free for individuals, E2E-encrypted sync), **Superset Mobile** (requires Superset Pro at $20/seat/month, iOS 26+, host on macOS or Linux), and **Agentastic Companion** (free, TestFlight, needs the Mac app and an awake Mac). — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)
- **Conductor** shipped an iOS app on 2026-10-02 (v0.90.0). — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)

**Agent-native SSH terminals (the most direct overlap with Clotho's iOS app)**
- **Moshi** (iOS and Android): an SSH and Mosh terminal "built for agent sessions" with tmux auto-reattach and voice input.
  - **Free tier:** SSH, agent-event push (10 events per 60 s, shared with Live Activities), an inbox with approve, deny and answer actions (first 5 free), view-only Apple Watch, Claude Code / Codex / OpenCode rate-limit tracking, and biometric key protection.
  - **Pro:** 60 events per 60 s, unlimited inbox actions, Watch actions, push fan-out to every device on the license, tmux and Herdr auto-attach after reconnect, mosh, and more hosts.
  - Pro starts at $9.99/month. A lifetime option exists. — [Moshi subscription docs](https://getmoshi.app/docs/subscription); [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone); [App Store: Moshi](https://apps.apple.com/us/app/6757859949)
- **Moshpit: Terminal for Agents** (iOS, $1.99): SSH, mosh and tmux. Push is encrypted on your own host with a device-only key. — [App Store: Moshpit](https://apps.apple.com/app/id6799896801)
- **MT – Mosh Terminal**: $14.99 one-time with a 2-week trial. Notifications come from Claude Code hooks, and a tap auto-resumes the exact tmux session over Mosh. This comes from a third-party listing. — [Product Hunt: MT](https://www.producthunt.com/products/mt-mosh-terminal)
- **Pling: SSH & Push** (iOS). Only the listing was found. — [App Store: Pling](https://apps.apple.com/us/app/pling-ssh-push/id6761271025)

**DIY hook projects**
- **tap-to-tmux**: ntfy push for Claude Code and other agents. Tapping opens Blink attached to the tmux pane. — [GitHub flavio87/tap-to-tmux](https://github.com/flavio87/tap-to-tmux)
- **claude-pager**: approve or deny from the phone by sending tmux keystrokes back. — [GitHub FilipCondac/claude-pager](https://github.com/FilipCondac/claude-pager)
- **claude-push**: a PermissionRequest hook with Allow/Deny buttons that falls back to the terminal after 90 s. — [GitHub coa00/claude-push](https://github.com/coa00/claude-push)
- **claude-mobile**: a PWA with tmux attach and push. It needs iOS 16.4+ and Tailscale. — [GitHub Almaz2001AA/claude-mobile](https://github.com/Almaz2001AA/claude-mobile)

**Incumbents' agent features**
- **Warp**: Warp Factories Build and higher include "Claude Code and Codex harnesses". Free includes "use any harness in the cloud (beta)" (2026-10). — [Warp pricing](https://www.warp.dev/pricing)
- **Termius**: the only AI feature on its pricing page is AI autocomplete, with no agent features (2026-10). — [Termius pricing](https://termius.com/pricing)
- **Wave**: markets itself as "AI-integrated". — [GitHub waveterm](https://github.com/wavetermdev/waveterm)
- **Zellij, tmux, Mosh, ET, Blink, Prompt**: I found no agent-specific features in sources fetched this session.

### Inferences
- The incumbent mobile SSH apps (Blink, Termius, Prompt) have **not** moved into agent awareness. Newcomers (Moshi, Moshpit, MT, Pling) and agent companions have filled that gap. Moshi is the closest single-product competitor to Clotho's iOS app: a terminal plus agent inbox, push, Watch and tmux reattach, on a free-plus-$9.99/month model.
- Free open-source daemon-plus-mobile options with 20k+ stars (Happy, Paseo) put downward pressure on what anyone can charge for agent notifications and approvals alone.

### Gaps
- Install counts and App Store ratings for Moshi, Happy and Paseo were not found.
- The Agentastic comparison is written by a competitor. Its characterizations, such as Happy's "remote mode restart", were not independently verified.

---

## 3. Platforms, licensing and pricing per tool

### Takeaway
The dominant model is a **free core with paid sync, mobile or AI**. Mobile SSH apps cluster at **$15–20/year** for individuals (Blink, La Terminal, ShellFish) or **$10/month annual** for sync-centric cross-platform tools (Termius Pro). Agent-era tools charge **$10–20/month**, and that price is usually tied to AI usage or agent features.

### Cited Findings

| Tool | Platforms | License | Pricing (date) | Source |
|---|---|---|---|---|
| tmux | Unix | ISC | Free | [GitHub](https://github.com/tmux/tmux) |
| Zellij | Linux/macOS, plus a web client | MIT | Free | [GitHub](https://github.com/zellij-org/zellij) |
| Mosh / ET | Unix (clients on many platforms) | GPL-3.0 / Apache-2.0 | Free | [Mosh](https://github.com/mobile-shell/mosh), [ET](https://github.com/MisterTea/EternalTerminal) |
| Ghostty | macOS, Linux | MIT | Free | [GitHub](https://github.com/ghostty-org/ghostty) |
| iTerm2 | macOS | GPL-2.0 | Free | [GitHub](https://github.com/gnachman/iTerm2) |
| Wave | Cross-platform | Apache-2.0 | Free (no paid tier checked) | [GitHub](https://github.com/wavetermdev/waveterm) |
| Warp | macOS/Linux/Windows | AGPL-3.0 | Free terminal. Build $20/mo ($18 annual) with $20 of agent usage. Max $200/mo ($180 annual). Business $50/user/mo ($45 annual, up to 25 seats). Enterprise custom. Pay-as-you-go Factories bill at API rate + 20% (2026-10). | [Warp pricing](https://www.warp.dev/pricing) |
| Termius | iOS/Android/Mac/Win/Linux | Proprietary | Starter free. Pro $10/mo. Team $20/seat/mo. Business $30/seat/mo (all annual). Enterprise custom (2026-10). App Store shows Pro Monthly $15 and Pro Annual $119 (third-party snapshot, Mar 2026). | [Termius pricing](https://termius.com/pricing); [apppricinglab](https://apppricinglab.com/iap/apple/549039908) |
| Blink Shell | iOS/iPadOS | GPL-3.0 (subscription app) | Blink+ $19.99 (per a third party, $19.99/yr after a 2-week trial). Blink Build $7.99/mo. "Blink Shell Classic" $0. | [App Store](https://apps.apple.com/app/blink-shell/id1594898306); [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone); [apppricinglab](https://apppricinglab.com/iap/apple/1594898306) |
| Prompt 3 | macOS/iOS/iPadOS/visionOS | Proprietary | **$9.99/yr** subscription covers all platforms, with a 7-day trial. Older coverage cites about €99.99 one-time / €22.99/yr at launch (2024, outdated). | [Panic FAQ](https://help.panic.com/prompt/purchase-faq/); [01net (2024)](https://www.01net.it/panic-rilascia-prompt-3-lapp-ssh-per-ios-ora-anche-per-mac/) |
| Secure ShellFish | iOS/macOS | Proprietary | $2.99/mo, $14.99/yr, $29.99 lifetime | [App Store](https://apps.apple.com/us/app/secure-shellfish-ssh-sftp/id1336634154?uo=4) |
| La Terminal | iOS | Proprietary | Pro $4.99/mo, $19.99/yr, $99.99 lifetime (US) | [App Store](https://apps.apple.com/us/app/la-terminal-ssh-client/id1629902861) |
| Moshi | iOS/Android | Proprietary | Free tier. Pro from $9.99/mo. Monthly, annual and lifetime options exist. | [Moshi docs](https://getmoshi.app/docs/subscription); [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone) |
| Moshpit | iOS | Proprietary | $1.99 paid upfront | [App Store](https://apps.apple.com/app/id6799896801) |
| MT – Mosh Terminal | iOS | Proprietary | $14.99 one-time (third-party listing) | [Product Hunt](https://www.producthunt.com/products/mt-mosh-terminal) |
| Happy / Paseo / Orca | Mobile + desktop + web | MIT / Apache-2.0 / MIT | Free | [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone) |
| Superset | iOS 26+, host on macOS/Linux | Proprietary | Pro $20/seat/mo | [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone) |
| Tailscale | All | BSD-3 client | Personal $0 (6 users, Tailscale SSH up to 5 hosts). Standard $8/user/mo. Premium $18/user/mo. Personal Plus and Starter are now **legacy** (2026-10). | [Tailscale pricing](https://tailscale.com/pricing) |
| sshx / upterm / tmate / ttyd | Web / CLI | MIT / Apache / tmate license / MIT | Free | Repo links in section 1 |

- **Tailscale plan restructure**: a third party dates it to **2026-04-08**. Personal Plus was retired and its six-user allowance folded into free Personal. Starter was renamed Standard at $8. Tailscale's own page confirms the legacy status but gives no date. — [SSD Nodes: Tailscale pricing explained](https://www.ssdnodes.com/learn/tailscale-pricing-explained); [Tailscale pricing](https://tailscale.com/pricing)
- **Warp pricing history**: Warp moved to the $20 Build plan with BYOK and switched allowances from credits to dollars around early Oct 2026. Headline prices did not change. — [Warp blog: Introducing Build](https://www.warp.dev/blog/warp-new-pricing-flexibility-byok); [usagepricing: warp 2026-10 change](https://www.usagepricing.com/blueprint/activity/warp-2026-10-price-change)

### Inferences
- **Prompt 3 at $9.99/yr for four platforms** is the floor anchor for a polished native Apple SSH client. Panic cut it from a much higher 2024 launch price, which suggests that market resisted the higher number. (This rests on the 2024 coverage plus the current FAQ. The reason for the cut was not confirmed.)

### Gaps
- Termius monthly-billing prices for Team and Business. The official page shows annual prices only.
- Blink+ billing period: the official listing doesn't state it. The $19.99/yr figure comes from Agentastic and an unofficial source.
- Moshi annual and lifetime exact prices, which are shown only at checkout.

---

## 4. Traction: users, stars, ratings, funding

### Takeaway
Open-source terminals and agent companions show large star counts: Warp 65.8k, Ghostty 63.0k, tmux 50.1k, Zellij 35.9k, Happy 24.4k, Paseo 22.5k, Wave 22.6k. Agent companions reached 20k+ stars quickly, which is the strongest demand signal for Clotho's agent angle. Funding data for the mobile SSH apps is thin. Termius's only public round is a 2019 seed.

### Cited Findings
- GitHub stars as of 2026-10-30, from the GitHub API (repo links are in section 1):
  - Warp 65,791; Ghostty 63,023; tmux 50,074; Tailscale 38,354; Zellij 35,896
  - Happy 24,419; Wave 22,625; Paseo 22,520; iTerm2 18,238; Mosh 14,612
  - tmux-resurrect 13,118; ttyd 12,565; sshx 7,708; Blink 7,000; tmate 6,134
  - Eternal Terminal 3,937; upterm 1,331
- **Termius**:
  - Raised a NZ$4.1M (about US$2.7M) seed round in **2019**. No later round was found. — [NZ Herald](https://nzherald.co.nz/business/auckland-based-tech-start-up-termius-snares-41m-in-silicon-valley-capital-raising/6B5I4Z65PVRJIRGUUR6QQCSTGA); [NBR](https://www.nbr.co.nz/story/nz-network-engineer-software-termius-raises-41m-seed-round)
  - Some directories name Initialized Capital and S28. These names are unverified. — [Persana](https://insights.persana.ai/Termius)
  - A claim of "2,000,000 active users" appears only in a directory and is unverified. — [Lazyweb](https://www.lazyweb.com/company/termius)
- **Warp**: Product Hunt shows 4.8 from 81 reviews (pricing page, 2026-10). — [Warp pricing](https://www.warp.dev/pricing)

### Inferences
- Tools that pair a multiplexer with an agent focus are drawing GitHub attention fast. Happy and Paseo, both 2025–2026 projects, already have more stars than iTerm2.

### Gaps
- App Store ratings and review counts for Blink, Termius, Prompt 3, ShellFish, La Terminal and Moshi were not collected.
- Warp's funding was not re-verified this session.
- Download and MAU figures from primary sources were not found for any mobile SSH app.

---

## 5. Overlap with Clotho, and how a power user replicates Clotho today

### Takeaway
A power user can approximate Clotho with about 4–6 pieces:
- **tmux or Zellij** (persistence) plus **tmux-resurrect or Zellij resurrection** (reboot recovery)
- **Tailscale SSH** (reachability)
- **Mosh or ET** (roaming)
- **Blink, Termius or Moshi** on iOS
- **a Claude Code hook plus ntfy, or Moshi, Happy or Paseo** for push and approvals

The friction is real. Per-host config, hook wiring, notifications that are not tied to panes, no native Mac UI for remote tmux except iTerm2 `-CC`, no unified multi-machine workspace list, and loss of live processes on reboot.

### Cited Findings
- **The DIY recipe is mainstream.** "Run Claude Code inside tmux on a computer, then attach from a phone SSH app… Push requires a hook, such as Moshi's or your own." Approvals happen inside the terminal UI, with no structured approval cards. — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)
- **Glue projects show the friction.** tap-to-tmux deep-links an ntfy alert into Blink attached to a tmux pane. claude-pager sends tmux keystrokes to approve. claude-push falls back to the terminal after 90 s. — [tap-to-tmux](https://github.com/flavio87/tap-to-tmux); [claude-pager](https://github.com/FilipCondac/claude-pager); [claude-push](https://github.com/coa00/claude-push)
- **Persistence gaps**:
  - Zellij resurrection re-creates layouts and commands, not processes. — [Zellij docs](https://zellij.dev/documentation/session-resurrection)
  - tmux-resurrect has not been updated since 2024-08. — [GitHub](https://github.com/tmux-plugins/tmux-resurrect)
  - Wave's durable sessions are opt-in, SSH-only, and end when the block closes. — [Wave docs](https://docs.waveterm.dev/durable-sessions)
- **Anthropic's Remote Control** covers Claude only, needs the `claude` process running and the computer awake, and requires a paid Claude plan. — [Agentastic comparison](https://www.agentastic.dev/compare/claude-code-iphone)
- **Moshi** bundles the most pieces in one app: SSH, mosh, tmux auto-reattach, an agent inbox, push, Watch and rate-limit tracking. On the host it is still tmux plus a hook. — [Moshi docs](https://getmoshi.app/docs/subscription)

### Inferences
- **Clotho's defensible overlap** is the combination of:
  - (a) a single daemon that owns persistence, so no tmux is needed
  - (b) native Mac **and** iOS clients rendering the same Workspaces, Tabs and Panes, closer to iTerm2's tmux `-CC` model but cross-device
  - (c) multi-machine in one list
  - (d) pane-anchored agent state, so a notification opens the exact pane and an approval goes to that agent
- No single competitor found has all four:
  - Paseo comes closest on (a), (c) and (d), but it is agent-centric.
  - Zellij covers (a) plus a web client.
  - Moshi covers (d) on mobile only, on top of tmux.
- **Main competitive risks:**
  - Anthropic's first-party Remote Control is "good enough" for Claude-only users.
  - Free open-source Happy and Paseo have big communities.
  - Moshi has a free tier with push and approvals.

### Gaps
- No published user surveys quantify how many developers run the DIY tmux-plus-phone stack.

---

## 6. Pricing benchmarks for developer tools, and common models

### Takeaway
Individual developers routinely pay **$8–10/month** (or about $96–120/yr) for a productivity layer: Raycast Pro, Termius Pro, Moshi Pro. They pay **$15–20/yr** for a mobile SSH client (Blink, La Terminal, ShellFish annual) and **$20/month** when AI usage is bundled (Warp Build, Superset Pro). Team tiers sit at about $15–30/seat/month. The prevailing structure is **free core plus paid sync, mobile, AI or team**, often with a **lifetime** option on iOS ($29.99–$99.99).

### Cited Findings
- **Raycast Pro**: $8/mo billed annually ($96/yr) or $10/mo monthly.
  - Advanced AI add-on about $16/mo annual.
  - Teams about $12–15/user/mo.
  - Sources: the launch post plus third-party trackers; the live page was not fetched. — [Raycast blog: Introducing Raycast Pro](https://raycast.com/blog/introducing-raycast-pro); [toolradar](https://toolradar.com/tools/raycast/pricing)
- **Termius**: Pro $10/mo annual; Team $20/seat; Business $30/seat (2026-10). — [Termius pricing](https://termius.com/pricing)
- **Warp**: free terminal; Build $20/mo; Max $200/mo; Business $50/user/mo (2026-10). — [Warp pricing](https://www.warp.dev/pricing)
- **Prompt 3**: $9.99/yr across four Apple platforms. — [Panic FAQ](https://help.panic.com/prompt/purchase-faq/)
- **Blink**: $19.99 (yearly per a third party); Build $7.99/mo. — [App Store](https://apps.apple.com/app/blink-shell/id1594898306); [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone)
- **Secure ShellFish**: $2.99/mo, $14.99/yr, $29.99 lifetime. — [App Store](https://apps.apple.com/us/app/secure-shellfish-ssh-sftp/id1336634154?uo=4)
- **La Terminal**: $4.99/mo, $19.99/yr, $99.99 lifetime. — [App Store](https://apps.apple.com/us/app/la-terminal-ssh-client/id1629902861)
- **Moshi**: free, with Pro from $9.99/mo. — [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone)
- **Tailscale**: free for personal use (6 users, SSH up to 5 hosts); Standard $8/user/mo; Premium $18. — [Tailscale pricing](https://tailscale.com/pricing)
- **Superset Pro**: $20/seat/mo, required for its mobile app. — [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone)

**Common models observed**
1. **Free core, paid sync.** Termius gates the cloud vault and mobile/desktop sync behind Pro. — [Termius pricing](https://termius.com/pricing)
2. **Free core, paid volume or limits on agent features.** Moshi meters push (10 vs 60 per minute) and inbox actions (5 free). — [Moshi docs](https://getmoshi.app/docs/subscription)
3. **Free terminal, paid AI usage credits.** Warp. — [Warp pricing](https://www.warp.dev/pricing)
4. **Cheap all-platform subscription.** Prompt 3. — [Panic FAQ](https://help.panic.com/prompt/purchase-faq/)
5. **iOS monthly, annual and lifetime triad.** ShellFish and La Terminal. — [ShellFish](https://apps.apple.com/us/app/secure-shellfish-ssh-sftp/id1336634154?uo=4); [La Terminal](https://apps.apple.com/us/app/la-terminal-ssh-client/id1629902861)
6. **Fully free open source.** Happy, Paseo, Orca, Zellij, tmux. — [Agentastic](https://www.agentastic.dev/compare/claude-code-iphone)

### Inferences
- For Clotho, the evidence supports this pricing shape:
  - A **free daemon** (open-source peers make a paid daemon hard).
  - A free Mac app with a limited free iOS tier.
  - A **Pro tier around $8–10/month or about $60–100/year**, gating multi-machine, push and approvals volume, the Watch, and lock-screen approvals.
  - Possibly a lifetime option around $99, in line with La Terminal.
- Pricing above about $10/month for individuals without bundled AI usage would sit above Termius, Raycast and Moshi Pro. Undercutting to about $20/yr would match Blink and La Terminal, but those apps don't run push infrastructure. Clotho's APNs relay is an ongoing cost, which argues for metering push in the free tier the way Moshi does.
- These are inferences, not sourced facts.

### Gaps
- Raycast's current live pricing page was not fetched; the figures come from the launch post and aggregators.
- No conversion or willingness-to-pay data for this category was found.
