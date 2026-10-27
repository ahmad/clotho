# Using Clotho

[Back to README](../README.md)

## Open the app

```sh
open ~/Applications/Clotho.app
```

On launch, Clotho connects to its session daemon, clothod, and starts it if it isn't running. The daemon ships inside the app; Clotho installs it into `~/Library/Application Support/clothod/bin/<version>/` and always runs it from there, so updating the app never swaps the binary under running sessions. If the daemon has no sessions yet, Clotho opens one with a shell.

The close, minimize and full-screen buttons are in the top-left corner. Drag empty space in the sidebar or tab bar to move the window, and double-click the tab bar to zoom it. Use **Control-Command-F** to fill the whole display.

## Sessions, tabs, and panes

```text
Machine: this Mac (remote machines come later)
└── Session: a project or task (a workspace in the daemon)
    └── Tab: a terminal layout
        ├── Pane: a shell or command
        └── Pane: another shell or command
```

The sidebar lists the sessions under this Mac's name, and each saved SSH machine below it with its own sessions (see [Remote machines](#remote-machines)). Click one to switch to it, double-click to rename it, or use its close button. The tab bar shows the focused session's tabs; double-click a tab to rename it. A tab without a name shows its active pane's title, or its folder.

Right-click a pane for its menu: split it in any direction, maximize or close it, open a new tab or session, copy, paste, clear or find, upload files into its folder, or browse its machine's files. (A program that uses the mouse, such as vim with `mouse=a`, gets right-clicks instead; Clotho's menu is still in the menu bar.)

Click a pane to focus it. The focused pane has a blue outline when a tab has more than one. Drag the line between two panes to resize them.

New tabs and splits open in the focused pane's folder. When a pane's program exits, the pane closes and focus moves to the pane that takes its place. A tab closes with its last pane; a session stays until you close it.

## Agents

The **Agents** panel at the bottom of the sidebar (drag the line above it to resize it) lists the coding agents (Claude Code, Codex) running in panes on every connected machine. Those waiting for you come first, then ones that finished or failed since you last looked, then running ones. Each row shows the agent's state, where it runs (machine · session · tab), which agent it is and what it last said, and how long ago its state changed; hover for the details, including whether the status comes from the agent's hooks or was detected from the terminal. Click a row to open its pane, which also marks it as seen.

Sessions and tabs with an agent show a dot: amber while one waits for you, green when it finished, red on an error, and blue while it runs. The dock icon shows how many agents need you.

You can answer an agent without opening its pane. A waiting agent's row has buttons for **1**, **2**, **3**, **↩** (Return), **Esc** and **Reply…** (type a line, sent with Return); a finished one has **Reply…**, and right-clicking any agent row lists the same answers. Its notification has **Approve (1)**, **Deny (Esc)** and **Reply**. Each answer is typed into the agent's pane as its terminal expects, and marks the agent seen. (This needs clothod 0.1.1 or later on that machine.)

Clotho sends a notification when an agent needs you: when it starts waiting for you, finishes, or fails, as reported by its hooks, or when it rings the terminal bell. An agent detected only from the terminal that has gone quiet shows as idle and doesn't alert, since that may just be a slow reply or a long build. Opening the pane, or typing in it, marks it seen on every device. You don't get a notification for the pane you're looking at. Click it to open the pane. The **Agents** menu turns each kind of notification on or off. Right-click a machine and turn off **Monitor Agents** to leave its agents out of the section, the notifications and the dock count. A machine that can't be reached shows as such in the section, so its agents are never silently missing.

## Sessions survive quitting

Quitting Clotho (**⌘Q**) or closing its window only disconnects. The daemon keeps every shell running, and reopening Clotho brings back each session, tab, split and screen as it was, including full-screen programs such as vim or Claude Code.

If the daemon's logic process restarts or crashes, Clotho reconnects within a moment and catches up on whatever the panes printed meanwhile. The sidebar shows "reconnecting…" while it waits. The shells live in a separate holder process, so they survive this too.

Closing a pane, tab or session ends the programs in it. Sessions don't survive a reboot.

## Keyboard shortcuts

**⌘** means Command, **⇧** Shift, **⌥** Option, and **⌃** Control. **Help → Keyboard Shortcuts** (**⌘/**) shows them in the app.

### Sessions and tabs

| Action | Shortcut |
| --- | --- |
| New session | ⌘N |
| Rename session | ⇧⌘R |
| Close session | ⇧⌘W |
| Previous / next session | ⇧⌘↑ / ⇧⌘↓ |
| New tab | ⌘T |
| Rename tab | ⌘R |
| Close tab | ⌥⌘W |
| Previous / next tab | ⇧⌘[ / ⇧⌘] |
| Go to tab 1 through 9 | ⌘1 through ⌘9 |

### Panes

| Action | Shortcut |
| --- | --- |
| Split right | ⌘D |
| Split down | ⇧⌘D |
| Split left | ⌥⌘D |
| Split up | ⇧⌥⌘D |
| Close focused pane | ⌘W |
| Switch pane in a direction | ⌥⌘ plus an arrow key |
| Resize pane in a direction | ⌃⌘ plus an arrow key |
| Toggle pane maximize | ⇧⌘Return |

Resizing moves the nearest divider toward the arrow. A maximized pane fills its tab, and its tab shows ⤢; the other panes keep running. When the file browser or shortcuts overlay is open, **⌘W** closes it instead of the pane.

### Editing, files, and the window

| Action | Shortcut |
| --- | --- |
| Copy / paste / select all | ⌘C / ⌘V / ⌘A |
| Find / find next / find previous | ⌘F / ⌘G / ⇧⌘G |
| Clear the terminal screen | ⌘K |
| Toggle file browser | ⇧⌘O |
| Choose files or folders to upload | ⇧⌘U |
| Increase / decrease font size | ⌘+ or ⌘= / ⌘- |
| Reset font size | ⌘0 |
| Toggle sidebar | ⌃⌘S |
| Minimize window | ⌘M |
| Toggle full screen | ⌃⌘F |
| Hide Clotho | ⌘H |
| Quit Clotho | ⌘Q |
| Toggle shortcut overlay | ⌘/ |

Closing a session always asks first. Closing a tab or pane asks too, with a "Don't ask again" option for each. Option acts as the terminal's Meta key.

## Transfer files

### Copy into a pane's folder

Drag files or folders from Finder onto a terminal, and Clotho copies them into that pane's current folder. **File → Upload Files…** (**⇧⌘U**) does the same for the focused pane, through a file picker.

Hold **Option** while dropping to type the shell-quoted paths instead of copying anything.

### Use the two-pane browser

Open **Window → File Browser** (**⇧⌘O**).

- The left side starts on this Mac, in the focused pane's folder. Its machine menu switches to a saved SSH machine, where it opens in the folder you last visited there, or your home folder the first time.
- The right side shows this Mac. It starts in `~/Downloads` and remembers the last folder.
- Double-click a folder or press **Return** to open it. **Delete/Backspace** or **⌘↑** goes to the parent folder; these keys never delete files.
- Click a breadcrumb to navigate, or click empty space in the path bar to type a path. **Return** navigates and **Escape** cancels.
- The eye button shows hidden files, and the refresh button reloads the listing.
- Double-clicking a local file opens it in its default app.

Drag items between the sides, or right-click a selection and choose copy, upload or download. Dropping onto a folder row copies into that folder; dropping on the listing's background uses the folder shown. Drag from Finder into either side to copy there, and drag remote items to Finder to download them.

Copies go local to local, local to remote, and remote to local. Direct remote-to-remote copies and moves within one remote machine aren't supported.

### Conflicts and progress

When names already exist at the destination, Clotho offers **Replace**, **Skip** and **Cancel**. Replace overwrites matching files and merges folders; it never deletes other files there. Downloads dragged to Finder follow Finder's own handling.

A toast in the corner shows each transfer's progress and result. Its cancel button stops a transfer, which can leave partial data behind because rsync runs with `--partial`. Transfers copy, so the source always stays in place.

## Remote machines

Clotho runs sessions on other machines over SSH: Linux (x86_64 or ARM) and macOS. The sidebar lists each machine under its own header, with its sessions below it, and the window shows one machine's session at a time.

### Add a machine

First check that SSH works without prompts from this Mac, replacing `user@imac` with the username and host, an SSH alias, or a Tailscale name:

```sh
ssh -o BatchMode=yes user@imac true
```

If that fails, set up a key or an SSH agent. Clotho runs ssh without prompts and can't ask for a password or passphrase. The machine needs a POSIX shell for sessions, plus `python3` and `rsync` for the file browser.

Then click **+ Add Machine** at the bottom of the sidebar (or choose **File → Add Machine…**), and give it a name and the SSH target. On first launch, Clotho also imports the machines saved in herdr (`~/.local/state/herdr/client/endpoints.json`).

With Tailscale, connect both machines to the tailnet and use the remote machine's MagicDNS name or Tailscale IP as the host. See [Tailscale's connection guide](https://tailscale.com/docs/how-to/connect-to-devices).

### Connect and start sessions

A machine you haven't connected to shows **Connect** under its name. Click it to connect and start a session there. The first time, Clotho installs its session daemon, clothod, on the machine: it uploads the matching build that ships inside the app into `~/.local/share/clothod/bin/` (Linux) or `~/Library/Application Support/clothod/bin/` (macOS). Nothing else is installed, and no root access is needed.

Once connected, a machine works like this Mac: **+ New Session** under its name starts another session, and every shortcut acts on the machine whose session is showing. **⇧⌘↑** and **⇧⌘↓** step through the sessions of every connected machine in sidebar order. Dropping files on a remote pane copies them to that pane's folder on that machine.

Sessions on a machine keep running when you quit Clotho, disconnect, or lose the network, and normally when you log out of the machine. (On a Linux machine set to end a user's processes at logout, they survive only with lingering on, `loginctl enable-linger`; Clotho shows clothod's warning once if that's the case.) Clotho reconnects connected machines when it starts, after the Mac wakes, and when the network changes, and catches up on what each pane printed meanwhile.

The status under a machine's name shows where it stands: connecting or installing, reconnecting with the last error, or nothing once it's connected (a green dot). For a machine that isn't connected, the dot shows the last SSH check: green if ssh connects, red if it doesn't (hover for ssh's message).

Right-click a machine's name for its menu:

- **New Session**, or **Connect** and **Connect and Start a Session**.
- **Browse Files** opens the file browser on it.
- **Reconnect** drops and re-establishes the connection; **Disconnect** stops showing its sessions, which keep running there.
- **Check Connection** runs the SSH check again (machines that aren't connected).
- **Edit…** changes its name or SSH target, and **Remove…** takes it off Clotho's list. Neither touches the machine or its sessions.

### Updates

Clotho never restarts a daemon on its own. When an update brings a newer clothod, Clotho installs it next to the running one (on this Mac at launch, on another machine when it connects) and keeps using the running daemon. A notice then offers **Restart Daemon**: that restarts the daemon's logic process on the new build, and your shells, programs and sessions carry on untouched.

If a machine's sessions were started by a build too old for the new one to take over, the notice offers **Restart Sessions…** instead. That ends the programs running in that machine's sessions, so it always asks first; until then you keep using the sessions as they are.

### Agent status

Clotho detects Claude Code and Codex from the terminal, which works without any setup. For exact status (the moment an agent waits for you, finishes or fails), right-click a machine and choose **Set Up Agent Status…**. Clotho first shows exactly what `clothod hooks install` would change on that machine (the agents' settings files, with backups kept), and installs the hooks only if you confirm. `clothod hooks uninstall` undoes it.

## Launch options

Pass these after `--args`, for example `open -n ~/Applications/Clotho.app --args -Backend fake`. They're ordinary user defaults, so `defaults write app.clotho.desktop <key> <value>` makes one stick.

| Option | Effect |
| --- | --- |
| `-ClothodRuntimeDir <dir>` | Use a separate daemon with its socket in `<dir>`, for a session set kept apart from the usual one. `CLOTHOD_RUNTIME_DIR` does the same. Keep the path short; socket paths are limited to about 100 bytes. |
| `-ClothodPath <path>` | Run this clothod binary in place instead of installing the bundled one. `CLOTHOD_BIN` does the same. |
| `-RemoteInstallDir <dir>` / `-RemoteRuntimeDir <dir>` | Install clothod into, and run it from, these directories on remote machines (the remote shell expands `$HOME` and `$(id -u)`). The dev build uses `$HOME/.local/share/clotho-dev/bin` and `/tmp/clothod-dev-$(id -u)`. |
| `-FakeAgents YES` | With `-Backend fake`, put fake agents in panes and move them through their states. `-AgentNotifications NO` logs notifications instead of showing them. |
| `-PaneMenu "<item>"` | Log the focused pane's right-click menu and choose that item (for scripted testing). |
| `-ConnectMachine <name>` | Connect to that saved machine and start a session there (for scripted testing). |
| `-Backend fake` | Run shells inside the app with no daemon. Sessions end when the app quits. For UI work. |
| `-LaunchInBackground YES` | Open behind other windows without taking keyboard focus. |
| `-StartFullScreen YES` | Open filling the display. |
| `-TraceFrames YES` | Log every pane data frame to and from the daemon, with pane, seq and length. |
| `-LogModel YES` | Log every model change and pane size change. |
| `-DumpScreens "5\|9"` | Log each shown pane's text and cursor at those seconds after launch. |

For scripted testing, `-RunShortcuts "Split Right,New Tab"` fires menu items by title, `-TypeText "ls\r|exit\r"` types each step into the focused pane, and `-ResizeWindow "900x600|1400x900"` resizes the window. Steps run a second or two apart; an empty step just waits. Use the [dev build](../README.md#dev-build) for these. A window covered by other windows stops drawing, so its screenshots can be stale; `-DumpScreens` reads the terminals directly.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| "Couldn't start the session backend" | The log names the clothod binary and socket it tried. Check that `Clotho.app/Contents/MacOS/clothod` exists (rebuild with `./build-app.sh`), and look at clothod's own logs in `~/Library/Application Support/clothod/`. |
| This Mac's sessions stay on "Reconnecting" | Run `~/Library/Application\ Support/clothod/bin/*/clothod status`. Clotho starts the daemon again on its own; if that keeps failing, its logs say why. |
| A machine stays on "Reconnecting" | The status line has ssh's or clothod's error. Test `ssh -o BatchMode=yes user@host true`. Clotho keeps retrying, up to every 30 seconds; right-click the machine and choose **Reconnect** to try at once. |
| "Has no clothod build" for a machine | Clotho carries builds for Linux and macOS on x86_64 and ARM only. |
| A pane shows a smaller terminal in its top-left corner | Another client sized that pane. It takes this window's size again once you type in it. |
| Remote browser can't connect | Test `ssh -o BatchMode=yes user@host true` from this Mac, and check keys, the SSH agent, host-key trust and the network. |
| Remote folder listing fails | Check that `python3` is on the remote machine's noninteractive SSH path and that the folder is readable. |
| A file transfer fails | Check that `/usr/bin/rsync` exists here, `rsync` is on the remote SSH path, and the destination is writable. The transfer toast shows the error. |
| An upload can't find the pane's folder | The daemon hasn't learned the folder yet. Wait a moment after `cd`, or use the file browser. |
| Desktop, Documents or Downloads is inaccessible | Review Clotho under System Settings → Privacy & Security → Files and Folders. |

The app's log is `~/Library/Logs/Clotho.log`. The daemon's command-line client, `clotho` (build it with `cargo build` in `clotho/clothod`; it lands in `target/debug/`), shows the daemon's view: `clotho ls` lists sessions, tabs and panes, and `clotho text <pane>` prints a pane's screen.

## Saved state

| Location | Contents |
| --- | --- |
| `app.clotho.desktop` defaults domain | Font size, window frame, saved machines, which machines are connected and focused, last browser folders, sidebar visibility and "Don't ask again" choices |
| `~/Library/Application Support/clothod/bin/` | Installed clothod builds (on remote machines: `~/.local/share/clothod/bin/` on Linux) |
| `$TMPDIR/clothod/` | The daemon's socket (on Linux machines: `/tmp/clothod-<uid>/`) |
| `~/Library/Application Support/clothod/` | The daemon's logs |
| `~/Library/Logs/Clotho.log` | The app's log |

On first launch, Clotho copies settings from the `app.clotho.desktop.next` domain used by the earlier "Clotho Next" builds, without replacing anything already set.
