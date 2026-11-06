# herdr (herdr.dev) and its ecosystem

Research date: 2026-10-30. All GitHub numbers were pulled from the GitHub API on 2026-10-30 unless noted. Herdr is less than 8 months old (repo created 2026-03-27), so almost nothing here is older than 6 months. Facts dated before 2026-04-30 are flagged.

## 1. What is herdr, who makes it, and is this the right "herdr"?

### Takeaway
Herdr is an open-source (Apache-2.0) Rust "runtime for coding agents." It started as a tmux-like terminal multiplexer whose background server keeps agent terminals alive. It was made by solo developer Can Celik (GitHub `ogulcancelik`), first released in spring 2026, and the repo is now `herdrdev/herdr` with about 46.9k stars. The company went through YC F26 and raised a $6M seed led by Bessemer (2026-09-08). On 2026-10-29/30 it launched a native desktop app (`herdr-app`) and a new headless server (`herdr-core`, `hc`). The terminal-agent tool is the only "herdr" with real traction. Other GitHub repos with the name look like forks or mirrors.

### Cited Findings
- Main repo `herdrdev/herdr`: description "the runtime your coding agents live on". Created 2026-03-27, language Rust, Apache-2.0, homepage herdr.dev. Topics include claude-code, codex, tmux, terminal-multiplexer — [GitHub API: herdrdev/herdr](https://github.com/herdrdev/herdr)
- The repo first lived at `ogulcancelik/herdr` (HN posts from 2026-05-23 and 2026-06-29 link there). It has since moved to the `herdrdev` org — [HN 2026-06-29](https://news.ycombinator.com/item?id=48714802), [HN 2026-05-23](https://news.ycombinator.com/item?id=48247248)
- The maker is Can Celik, "the only person behind Herdr" at the time of the YC post (2026-08-06). His GitHub profile `ogulcancelik` gives his name as Can Celik and his blog as oddbit.ai — [Herdr is joining Y Combinator](https://herdr.dev/blog/herdr-is-joining-y-combinator/); [GitHub user ogulcancelik](https://github.com/ogulcancelik)
- Celik wrote that before Herdr he was job hunting and reconsidering his career — [YC post](https://herdr.dev/blog/herdr-is-joining-y-combinator/)
- Joined Y Combinator, F26 batch (announced 2026-08-06) — [YC post](https://herdr.dev/blog/herdr-is-joining-y-combinator/)
- $6M seed (2026-09-08), led by Bessemer Venture Partners, with Y Combinator and e2vc. Angels: Tobi Lütke (Shopify), Dane Knecht (Cloudflare CTO), Görkem Yurtseven (fal) — [Herdr raised a seed](https://herdr.dev/blog/herdr-raised-a-seed/)
- The earliest public posts I found are a crate on docs.rs (herdr 0.1.0) and an HN post on 2026-05-23 (flag: about 5 to 7 months old) — [docs.rs herdr 0.1.0](https://docs.rs/crate/herdr/0.1.0); [HN](https://news.ycombinator.com/item?id=48247248)
- The license moved from AGPL to Apache-2.0 "recently," per the 2026-08-06 post. Older third-party listings that say AGPL-3.0 are out of date — [YC post](https://herdr.dev/blog/herdr-is-joining-y-combinator/); [search snippet citing AGPL](https://www.linuxlinks.com/herdr-terminal-based-agent-multiplexer/)
- Other GitHub repos named herdr turned up in search: maxjendrall/herdr, 2233admin/herdr, aspiers/herdr, Suor/herdr, jerryfane/herdr. One snippet describes the 2233admin repo as a fork with a longer agent list, and herdrup's README points to `jerryfane/herdr` as "herdr" (a fork with "federation" and `events_v2`) — [search results](https://github.com/2233admin/herdr); [herdrup README](https://github.com/jerryfane/herdrup)
- Dealroom has a company entry for "herdr" — [dealroom](https://app.dealroom.co/companies/herdr)

### Inferences
- "Herdr" now means three products: the original TUI (`herdr`), the new headless core (`hc`), and the new native app (`herdr-app`). Comparisons need to say which one.
- Celik started as a solo indie developer, and the project is now venture-backed (YC plus Bessemer). It is a direct, well-funded competitor in Clotho's space.

### Gaps
- I did not check whether the other `*/herdr` repos are forks, mirrors or unrelated projects. Search snippets suggest forks.
- I found no exact date for the first public release or for the AGPL to Apache switch.

## 2. Features and architecture, supported agents, platforms

### Takeaway
Herdr is a daemon plus client: a background server owns the PTYs, and clients attach to it. It does not use tmux. Version 0.9 (2026-09-07) added multi-machine over SSH with one combined sidebar. The original TUI recognizes about 20 agents, from screen heuristics plus optional per-agent integrations, and can resume supported agent sessions after a restart. The new herdr-core/app (2026-10) instead uses a status protocol, OSC 7501, that agents emit themselves. It no longer guesses from screen text, and after a reboot it brings back panes as fresh shells. The app runs on macOS (Apple silicon), Linux and Windows. There is no official mobile app.

### Cited Findings
**Original TUI (`herdr`, v0.9.5 as of 2026-10-14)**
- "keeps terminals running in a background server when you close the client or lose your SSH connection. after a server or machine restart, herdr restores the saved layout and can resume supported agent sessions; the original processes do not survive" — [herdr README](https://github.com/herdrdev/herdr)
- "several machines, one window — keep local work and saved ssh machines together, with a combined agent list and independent reconnects" — [herdr README](https://github.com/herdrdev/herdr)
- Every pane is marked working, blocked or idle. Agents drive herdr through a CLI and socket API: they "can spawn panes, prompt each other, and wait until another agent is genuinely blocked" — [herdr README](https://github.com/herdrdev/herdr)
- "one rust binary, no electron — runs in whatever terminal you already use". Supports tmux-style prefix keys plus mouse (click, drag, split). Has a plugin marketplace — [herdr README](https://github.com/herdrdev/herdr)
- Installs via curl script, Homebrew, mise, or a PowerShell script on Windows. Windows is "beta" for endpoint-protected machines — [herdr README](https://github.com/herdrdev/herdr). A MacPorts port also exists — [MacPorts](https://ports.macports.org/port/herdr/)
- Supported agents with an integration (`herdr integration install <name>`): Claude Code, Codex, GitHub Copilot CLI, Cursor Agent CLI, OpenCode, Pi, OMP, Droid, Devin CLI, Kimi Code CLI, Kilo Code CLI, Hermes Agent, Qoder CLI, Qwen Code, Letta Code, MastraCode, Grok CLI, Antigravity CLI — [herdr docs: agents](https://herdr.dev/docs/agents/)
- State only, no integration: Amp, Kiro CLI, Maki, Gemini CLI ("less tested"), Cline ("less tested"). Agents that report their own state: Command Code, Crush, Kiro CLI, Muse Code, Prime Agent — [herdr docs: agents](https://herdr.dev/docs/agents/)
- Detection finds each pane's agent process and reads the bottom of its screen, using manifest rules to choose idle, working or blocked. "Blocked" is set only when the screen matches a known approval, question or permission UI, so "an unusual prompt may show as idle." Integrations replace screen reading when installed — [herdr docs: agents](https://herdr.dev/docs/agents/)
- With an integration installed, supported agents "resume the same session after a server restart" — [herdr docs: agents](https://herdr.dev/docs/agents/)
- Herdr notifies you when an agent finishes or needs you. The docs don't say through which channel — [herdr docs: agents](https://herdr.dev/docs/agents/)
- Live updates replace the server while pane processes keep running (blog, 2026-05-27; flag: about 5 months old) — [herdr blog index](https://herdr.dev/blog/)
- 0.9 multi-machine (2026-09-07): `herdr machine add <name>` with an SSH target. Each server owns its sessions and the client renders the outer UI. Machines must be reachable over SSH (LAN, internet, Tailscale). The agent CLI cannot yet see agents on other machines, and cross-machine agent collaboration is planned — [Connecting the machines](https://herdr.dev/blog/connecting-the-machines/)
- Performance work: "Ten agents, three clients, 95% less CPU" (2026-08-03) — [herdr blog index](https://herdr.dev/blog/)
- One user said the TUI constantly redraws, which breaks keyboard copy in wezterm (2026-07) — [HN 48756578](https://news.ycombinator.com/item?id=48756578). Another said that on macOS it "has a ton of selection management bugs" (2026-10-30) — [HN 50298436](https://news.ycombinator.com/item?id=50298436)

**herdr-core (`hc`), repo created 2026-10-16**
- "`hc` runs programs and coding agents in terminals that stay alive after you leave… Core draws nothing. Use it from your shell, an agent, or your own app." Builds for Linux and macOS (x86_64 and aarch64) and Windows x86_64. `hc update` updates in place and "Running terminals keep running" — [herdr-core README](https://github.com/herdrdev/herdr-core)
- Agent orchestration: `hc run --bg`, `hc send`, `hc read`, `hc wait --children all`, templates for agent roles. Child agents end with their parent unless started with `--outlive-parent` — [herdr-core README](https://github.com/herdrdev/herdr-core)
- Machines: `hc machine add my-ssh-host`, `hc run --on box`, addresses like `box/t3`. The local core "combines terminal lists and events". It offers to copy `hc` to the remote machine if missing, and supports custom connection commands — [herdr-core README](https://github.com/herdrdev/herdr-core); [docs/machines.md](https://github.com/herdrdev/herdr-core/blob/main/docs/machines.md)
- Remote files: `hc file read/edit/write --on box …`, and `hc put box/build ./report.txt` sends a local file next to a remote terminal — [herdr-core docs/machines.md](https://github.com/herdrdev/herdr-core/blob/main/docs/machines.md)
- Status: "An agent can say it is working, done, blocked, or in error through OSC 7501, the Program Status Protocol… It does not guess from screen text or recognize agent brands. A program that does not report status has none." — [herdr-core README](https://github.com/herdrdev/herdr-core)
- Public client API: `hc schema` prints OpenRPC/JSON Schema, and `hc connect` carries the protocol over stdin/stdout, including through SSH — [herdr-core README](https://github.com/herdrdev/herdr-core)

**herdr-app (native desktop app), repo created 2026-10-16, launched on HN 2026-10-30**
- "a desktop app for terminals and coding agents". Model: **space** (one machine, usually one repo), then **tabs**, then **panes**. An agents sidebar lists Working, Blocked, Done and Idle, including workers spawned by other agents, and "peek" overlays a worker that has no pane — [herdr-app README](https://github.com/herdrdev/herdr-app)
- "After a reboot or core crash, kept panes get fresh shells in their last folders, not their old programs." — [herdr-app README](https://github.com/herdrdev/herdr-app)
- SSH machines are added from Settings → Machines. "Connected screens share that structure and the live terminals, but keep their own focus and zoom." Remote work continues while the laptop sleeps — [herdr-app README](https://github.com/herdrdev/herdr-app)
- Command palette is Ctrl/Cmd+Shift+P. Keys can be remapped in `keys.json`. Layouts and "Mods" are JavaScript programs that draw panels, menus and dialogs. The app is "a folder of plain files" that your agent can edit, and there is a "Herdr 98" (Windows 98) layout — [herdr-app README](https://github.com/herdrdev/herdr-app); [herdr.dev](https://herdr.dev); [HN 50298436](https://news.ycombinator.com/item?id=50298436)
- Platforms: macOS Apple silicon (Intel only from source), Linux x86-64 and ARM64 (needs Vulkan), and Windows x64. Background self-update. "Usage telemetry is on by default in releases" — [herdr-app README](https://github.com/herdrdev/herdr-app)
- herdr.dev now leads with the app: "Close it, they keep working." The site says agents that do not speak OSC 7501 run without status, and agents inside tmux within Herdr can't report status. It also says the Herdr TUI "doesn't share agents with the app" — [herdr.dev](https://herdr.dev)
- HN commenters say it uses libghostty for rendering — [HN 50298436](https://news.ycombinator.com/item?id=50298436)
- On launch day one user reported "it doesn't pick up Claude Code agents. My Agents pane stays empty" — [HN 50298436](https://news.ycombinator.com/item?id=50298436)

### Inferences
- Herdr's architecture is very close to Clotho's: a per-machine daemon that owns PTYs, thin clients, SSH multi-machine, an in-place upgrade that keeps shells alive, and an agent status sidebar.
- The October 2026 core/app rewrite is a step back on two points where Clotho is strong. Status now comes only from OSC 7501, which Claude Code and Codex probably don't emit natively, hence the "empty Agents pane" report. Session restore after a reboot now gives fresh shells, not resumed agent sessions. The older TUI did resume agent sessions through integrations. This could change quickly.
- Herdr's strengths are agent-to-agent orchestration (spawn, send, wait, child lifecycle), a public OpenRPC API, Windows support, and breadth of agent support.

### Gaps
- I could not confirm whether Claude Code or Codex emit OSC 7501 natively, or whether the new app ships hooks or integrations for them.
- I found no documentation of desktop notification types, or of approve/deny actions from the app.
- I found no git branch or PR display per pane in the official app. herdr-gpui (third-party) shows git worktrees.
- I did not verify the wire protocol details (OpenRPC transport over a local socket) beyond the README.

## 3. Companion tools: mobile, desktop, web, CLI, integrations

### Takeaway
Officially there are three programs, the TUI, `hc` and the desktop app, plus a planned "Herdr Cloud" relay for connecting machines (waitlist, 2026-09-07). There is **no official mobile app**. The gap is filled by a large third-party ecosystem: several iOS apps (Heeler, herdrup, Pairfob mentioned), Android apps, PWA relays with push notifications and approve-from-phone, an alternative native GPUI desktop client, and hundreds of plugins.

### Cited Findings
- Official repos under `herdrdev`: herdr (TUI, 46,876★), herdr-app (783★, created 2026-10-16), herdr-core (150★, created 2026-10-16), herdr-nix, herdr-layout-examples — [GitHub herdrdev org](https://github.com/herdrdev)
- Herdr Cloud (planned, not shipped as of 2026-09-07): connect your machines with one command through a Herdr account, as "a middleman layer" with terminal traffic end-to-end encrypted. You still supply the machines. Waitlist is open — [Connecting the machines](https://herdr.dev/blog/connecting-the-machines/)
- The plugin marketplace had "more than 500 plugins, one month after the marketplace launched" (2026-08-06) — [YC post](https://herdr.dev/blog/herdr-is-joining-y-combinator/); [herdr.dev/plugins](https://herdr.dev/plugins/)
- The awesome-herdr list catalogs hundreds of tools, e.g. "Run and orchestrate agents (855)", "Push notifications, APNs, and mobile alerts (2)", "Desktop, mobile, and webhook notifications (48)" — [awesome-herdr](https://github.com/yigitkonur/awesome-herdr)
- **Heeler (iOS, third-party, Apache-2.0, 703★, created 2026-07-18):** "Native iOS agent console for herdr — watch and drive the coding agents on your machines over SSH, with a real libghostty terminal, QR pairing, and push notifications when an agent needs you". Features: agent console sorted by who needs you, native Composer, Chat view, git Changes view, Live Activity on the lock screen, usage/cost widgets. iOS 18+, on the App Store and TestFlight — [Heeler](https://github.com/ZingerLittleBee/Heeler); [App Store](https://apps.apple.com/us/app/heeler-for-herdr/id6797263135). A search listing says it requires herdr 0.7.5+ and OpenSSH Remote Login, and supports jump hosts — [mwm.ai listing](https://mwm.ai/apps/heeler-for-herdr/6797263135)
- **herdrup (iOS/iPad/Mac, third-party, Apache-2.0, 230★, created 2026-08-01):** status board (needs you, working, done, stopped), live SwiftTerm terminal per pane, event streaming. On the App Store — [herdrup](https://github.com/jerryfane/herdrup)
- **herdr mobile (Android, GPL-3.0, 20★, created 2026-10-03):** one board for every agent on every machine over SSH. One-tap answers to agent questions show the command first, and risky answers must be held rather than tapped — [tuan3w/herdr-mobile](https://github.com/tuan3w/herdr-mobile). A Google Play listing "Herdr Mobile" (dev.herdr.mobile) also exists; I did not verify its maker — [Google Play](https://play.google.com/store/apps/details?id=dev.herdr.mobile)
- **herdr-mobile-relay (PWA, 333★, v0.23.5):** "Approve and monitor Herdr agents remotely from your phone… push notifications, QR setup, and multi-computer relays". Installed as a herdr plugin, with a relay on each Linux/macOS machine. Search snippets say AGPL-3.0, and GitHub reports NOASSERTION — [herdr-mobile-relay](https://github.com/0cv/herdr-mobile-relay); [pkg.go.dev](https://pkg.go.dev/github.com/0cv/herdr-mobile-relay)
- **Shepherdr (mobile web UI, 17★):** status, notifications, real terminals, send files, create workspaces and worktrees from the phone, passkeys, tailnet-only — [shepherdr](https://github.com/luiscleto/shepherdr); [Show HN](https://news.ycombinator.com/item?id=49432213)
- **herdr-gpui / "Herdr UI" (third-party native desktop for macOS, Linux and Windows, Rust/GPUI, 1,993★, created 2026-09-20):** paints the daemon's terminal cells natively. Sidebar shows worktrees and agents. "Unaffiliated project." An HN commenter says it has "remote phone pairing, and a built-in browser integration" — [herdr-gpui](https://github.com/penso/herdr-gpui); [HN 50298436](https://news.ycombinator.com/item?id=50298436)
- Others on HN: Herdr Studio (45 pts, 2026-09-11), NotchAgent (macOS notch status), a "Herdr for Android" terminal (droidtty.com), herdrplus.com plugin, and a ThreeJS "office" for agents — [HN search](https://hn.algolia.com/?q=herdr)
- Some reviewers frame the lack of an official mobile or web app as deliberate, with SSH from a phone as the official path — [Bitdoze snippet](https://www.bitdoze.com/best-herdr-clients/) (403 on fetch, snippet only); [Flavio Copes: Using Herdr from a phone](https://flaviocopes.com/herdr-phone/)
- On launch day an HN user was disappointed that the "native app" was not a mobile app — [HN 50298436](https://news.ycombinator.com/item?id=50298436)

### Inferences
- In the herdr world, Clotho's distinctive iPhone experience (native app, APNs push, lock-screen Allow/Deny) exists only as fragmented third-party apps. Heeler is the closest match to Clotho's iOS app: native, push and a Live Activity. I saw no lock-screen Allow/Deny actions in Heeler's README. herdr-mobile-relay and herdr mobile do offer approve-from-phone.
- Herdr Cloud would compete with Clotho's SSH-based multi-machine setup, with easier onboarding (no SSH config). It is also herdr's likely monetization path.

### Gaps
- I did not check pricing or IAP for Heeler, herdrup or the Play Store "Herdr Mobile". A search snippet says the Play listing is "now free, with no in-app purchases".
- Pairfob (mentioned on HN as a phone app) was not researched.
- I don't know whether Heeler's push supports actionable Allow/Deny from the lock screen.

## 4. Open source, license, pricing

### Takeaway
All official components are Apache-2.0 (previously AGPL) and free. There are no paid plans. The planned monetization appears to be Herdr Cloud, but no pricing has been announced. App releases have telemetry on by default.

### Cited Findings
- "Is it free? Yes. The app, herdr-core and Herdr TUI are all open source." Apache 2.0, and no paid plans are listed — [herdr.dev](https://herdr.dev)
- herdr, herdr-app and herdr-core are all Apache-2.0 per the GitHub API — [herdr](https://github.com/herdrdev/herdr), [herdr-app](https://github.com/herdrdev/herdr-app), [herdr-core](https://github.com/herdrdev/herdr-core)
- "enterprise / partnership: hey@herdr.dev". There is a SPONSORS.md of past sponsors and backers — [herdr README](https://github.com/herdrdev/herdr)
- The YC post says the runtime "stays free" and names no revenue model — [YC post](https://herdr.dev/blog/herdr-is-joining-y-combinator/)
- HN asked "What's the planned monetization model…?" with no official answer in the top thread — [HN 50298436](https://news.ycombinator.com/item?id=50298436)
- Herdr does not accept unsolicited pull requests. Only maintainers and an approved list may submit implementation PRs, because of a flood of agent-generated PRs — [CONTRIBUTING.md](https://github.com/herdrdev/herdr/blob/master/CONTRIBUTING.md); [HN](https://news.ycombinator.com/item?id=50030359)

### Inferences
- Herdr is free and open source with VC backing. A paid Clotho would compete against a free tool, so differentiation (iOS, push approvals, agent resume, polish) matters.

### Gaps
- No public pricing for Herdr Cloud or enterprise.

## 5. Traction

### Takeaway
Very high traction for a 7-month-old dev tool: about 46.9k stars, 3.7k forks, 340k downloads by August, five HN front-page-scale threads (404, 318, 281 and 166 points), YC plus a $6M seed, and a large plugin and companion ecosystem. Releases are fast: stable roughly every 1 to 2 weeks, with frequent preview builds.

### Cited Findings
- 46,876 stars, 3,743 forks, 406 open issues, last push 2026-10-29 (API, 2026-10-30) — [herdrdev/herdr](https://github.com/herdrdev/herdr)
- 89 contributors (API count, includes bots). The top committer is ogulcancelik with 1,314 commits, then JJLiebig (150) and bots `akbash-bot` (129) and `kangal-bot` (82) — [contributors](https://github.com/herdrdev/herdr/graphs/contributors)
- On 2026-08-06: "25k GitHub stars", "340k downloads", 500+ plugins — [YC post](https://herdr.dev/blog/herdr-is-joining-y-combinator/)
- Trending on GitHub around 2026-06-30, per a third-party listing — [sourcepulse](https://www.sourcepulse.org/projects/28273906)
- Stable releases: v0.7.3 (07-07), v0.7.4 (07-15), v0.7.5 (07-21), v0.8.0 (08-03), v0.8.2 (08-19), v0.9.0 (09-07), v0.9.1 (09-16), v0.9.2 and v0.9.3 (09-29), v0.9.4 (10-13), v0.9.5 (10-14), plus about 2 to 4 `preview-*` builds a month — [herdr releases](https://github.com/herdrdev/herdr/releases)
- HN threads: "Herdr: One terminal to rule them all" 404 pts / 178 comments (2026-07-02); "Herdr has released native app" 318 / 212 (2026-10-30); "Herdr is joining Y Combinator" 281 / 189 (2026-08-06); "Agent multiplexer that lives in your terminal" 166 / 110 (2026-06-29) — [HN 48756578](https://news.ycombinator.com/item?id=48756578), [HN 50298436](https://news.ycombinator.com/item?id=50298436), [HN 49201003](https://news.ycombinator.com/item?id=49201003), [HN 48714802](https://news.ycombinator.com/item?id=48714802)
- Positive sentiment: "switched to herdr this year after a decade of using tmux"; "rock solid"; "the only one that did a decent job rendering Claude code UI and didn't randomly crash and could run on a remote server" (compared with Emdash and Superset) — [HN 50298436](https://news.ycombinator.com/item?id=50298436); [HN 49201003](https://news.ycombinator.com/item?id=49201003)
- Skeptical sentiment: "Vibecoded. Nope."; "what does this solve over tmux/zellij"; fear of enshittification after VC ("I'll never forget what happened to Warp"); concern about telemetry being on by default; the herdr.dev SSL cert was reported invalid on 2026-10-30 — [HN 48756578](https://news.ycombinator.com/item?id=48756578); [HN 49201003](https://news.ycombinator.com/item?id=49201003); [HN 50298436](https://news.ycombinator.com/item?id=50298436)
- Competitors named in those threads: cmux, Superset, Emdash, Orca, Bullet, Conductor, Superlogical (mitchellh), Agentastic.dev, Nimbalyst, BrokkAi mjolnir, belfry (tmux, iOS) — [HN 49201003](https://news.ycombinator.com/item?id=49201003); [HN 48756578](https://news.ycombinator.com/item?id=48756578); [HN 50298436](https://news.ycombinator.com/item?id=50298436)
- Community: Discord (discord.gg/PsgRfzmUDg) and X @herdrdev — [herdr.dev](https://herdr.dev)
- Third-party write-ups: Tecmint, Flavio Copes ("A deep dive into Herdr"), Better Stack guide, LinuxLinks, Medium, pyshine — [Tecmint](https://tecmint.com/herdr-run-ai-coding-agents-in-linux-terminal); [Flavio Copes](https://flaviocopes.com/herdr/); [Better Stack](https://betterstack.com/community/guides/ai/herdr-ai-agent/); [LinuxLinks](https://www.linuxlinks.com/herdr-terminal-based-agent-multiplexer/)

### Inferences
- Herdr is probably the most popular open-source agent multiplexer as of late 2026. Its ecosystem (plugins, mobile clients) is a moat that Clotho cannot match directly.
- The 95%-bot commit pattern ("akbash-bot", "kangal-bot") and the PR policy show that herdr is itself built mostly by agents.

### Gaps
- No active-user, Discord-size or revenue numbers. Download counts after August weren't checked. The README badge shows total release downloads, but I didn't read its value.
- I did not search Reddit or Product Hunt.

## 6. Overlap and differences vs Clotho

### Takeaway
Herdr overlaps Clotho almost completely on the core idea: a per-machine daemon that owns PTYs, workspace/tab/pane structure, terminals that survive client disconnects, SSH multi-machine with one sidebar, an agent status list ("needs you"), in-place upgrades that keep terminals alive, and a command palette. Herdr is ahead on popularity, Windows support, agent breadth, agent-to-agent orchestration APIs, extensibility (mods, plugins, OpenRPC) and its third-party ecosystem. Clotho is ahead on an official native iPhone app with APNs push and lock-screen Allow/Deny, hook-based Claude Code/Codex status that works out of the box, restoring Claude Code/Codex sessions after a reboot in the new-app world, a native SwiftUI Mac app, git branch/PR per pane, and a polished cross-machine file transfer UI.

### Cited Findings (herdr side; Clotho side is from the brief)
- Shared: background server, detach and reattach, survives SSH loss — [herdr README](https://github.com/herdrdev/herdr). Space, tab and pane model — [herdr-app README](https://github.com/herdrdev/herdr-app). SSH machines in one sidebar — [Connecting the machines](https://herdr.dev/blog/connecting-the-machines/). Working/Blocked/Done/Idle sidebar — [herdr-app README](https://github.com/herdrdev/herdr-app). Live server replacement keeps processes — [blog index](https://herdr.dev/blog/). Command palette (Cmd+Shift+P) — [herdr-app README](https://github.com/herdrdev/herdr-app)
- Herdr only: Windows builds — [herdr-core README](https://github.com/herdrdev/herdr-core). 20+ agents recognized — [docs: agents](https://herdr.dev/docs/agents/). Agents spawning, messaging and waiting on child agents (`hc send`, `hc wait --children`) — [herdr-core README](https://github.com/herdrdev/herdr-core). Public OpenRPC client API — [herdr-core README](https://github.com/herdrdev/herdr-core). JS mods and shareable layouts — [herdr-app README](https://github.com/herdrdev/herdr-app). TUI that runs inside any terminal — [herdr README](https://github.com/herdrdev/herdr). Remote file read/edit/put from the CLI — [herdr-core machines.md](https://github.com/herdrdev/herdr-core/blob/main/docs/machines.md). Planned Herdr Cloud relay — [Connecting the machines](https://herdr.dev/blog/connecting-the-machines/)
- Herdr weaker or missing: no official mobile app — [herdr.dev](https://herdr.dev). New core shows no status for agents that don't speak OSC 7501 and doesn't guess — [herdr-core README](https://github.com/herdrdev/herdr-core). User reports Claude Code agents not appearing in the app — [HN 50298436](https://news.ycombinator.com/item?id=50298436). After a reboot the app gives fresh shells, "not their old programs" — [herdr-app README](https://github.com/herdrdev/herdr-app). TUI and app don't share agents — [herdr.dev](https://herdr.dev). Telemetry on by default — [herdr-app README](https://github.com/herdrdev/herdr-app). Linux app needs Vulkan, and Intel Macs need a source build — [herdr-app README](https://github.com/herdrdev/herdr-app). No official git branch or PR display found.
- The old TUI's screen-heuristic "blocked" detection can miss unusual prompts and show them as idle — [docs: agents](https://herdr.dev/docs/agents/)

### Inferences
- Clotho's strongest differentiators against herdr are:
  1. A first-party iPhone app with push and lock-screen approve/deny (herdr users rely on third-party Heeler, herdrup or relays).
  2. Reliable Claude Code/Codex status via hooks, with session resume across reboots.
  3. Native Apple-platform polish.
- Herdr's strengths that Clotho might consider: an agent orchestration API (spawn, send, wait, child lifecycle), a published client protocol schema, and a skill file for agents (`hc --skill`).
- Risk: herdr has funding, momentum and a planned Cloud relay that would remove SSH setup. A first-party mobile app would be an obvious next step for them given ecosystem demand. Neither is announced.

### Gaps
- I did not test the herdr app hands-on. Claims are from the docs and README on launch day (2026-10-30), and behavior may change within weeks given the release cadence.
- I don't know whether herdr has per-pane git info, a cross-machine file transfer UI in the app, or actionable notifications.
