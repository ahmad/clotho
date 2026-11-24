# Using Clotho

[Back to README](../README.md)

## Open the app

```sh
open ~/Applications/Clotho.app
```

On launch, Clotho connects to its terminal daemon, clothod, and starts it if it isn't running. The daemon ships inside the app; Clotho installs it into `~/Library/Application Support/clothod/bin/<version>/` and always runs it from there, so updating the app never swaps the binary under running shells. If the daemon has no workspaces yet, Clotho opens one with a shell.

The close, minimize and full-screen buttons are in the top-left corner. Drag empty space in the sidebar or tab bar to move the window, and double-click the tab bar to zoom it. Use **Control-Command-F** to fill the whole display.

## Workspaces, tabs, and panes

```text
Machine: this Mac (remote machines come later)
└── Workspace: a project or task
    └── Tab: a terminal layout
        ├── Pane: a shell or command
        └── Pane: another shell or command
```

The sidebar lists the workspaces under this Mac's name, and each saved SSH machine below it with its own workspaces (see [Remote machines](#remote-machines)). Click one to switch to it. Each row ends with its number of tabs, and before that a chip for its agents: the colour of the most urgent state among them and how many are in it (a check when they finished). Hover over the row and **+**, a new tab in that workspace, takes the tab count's place. Right-click a workspace for **New Tab**, **Rename Workspace** and **Close Workspace…**, or press **⇧⌘W** to close the current one. The tab bar shows the focused workspace's tabs; a workspace with none offers a **New Tab** button. When there's room after the tabs, the bar also says where you are: machine › workspace › tab. **⌘/**, or the sidebar button in the title row (beside the window buttons), hides or shows the sidebar.

The bar at the bottom of the sidebar has three buttons: **Machines** (Settings › Machines), **Settings** (Settings › General), and light or dark. Clicking the last one switches between Light and Dark, whatever macOS uses; right-click it (or use **Settings → Appearance**) to match the system again. The terminals follow the choice.

Every pane has a thin header across its top: on the left the program it runs (`zsh`), or for a coding agent a chip with its name and state (**Claude · Needs you**) and how long it has waited or worked; on the right the pane's folder. In a narrow pane the time goes first, then the folder.

In a git repository, the focused pane shows a thin strip at its bottom with the repository, branch, worktree and pull request (pull requests need GitHub's `gh`, signed in). At the strip's right end is how much changed there: **+128 −32 · 6 files**, the lines added and removed and the files changed, uncommitted work and the branch's own commits together (only the files when the lines weren't counted; in a narrow pane the files go first, then the count). Click it to open [Changes](#changes-and-the-inspector). **⌘P** also finds tabs by branch, worktree or pull request number.

New Workspace (**⌘N**, or the **+** beside a machine's name) opens the new workspace's name for editing straight away: type a name and press Return, or Esc to keep the default. Either way, the new terminal has the keyboard next.

Press **⌘P** for the command bar. With nothing typed it's a tree of this machine: **Needs you** on top (agents waiting for you, in error, or finished with a question for you, on any machine; Return jumps to the pane), then this machine's workspaces, the current one open to its tabs and the others collapsed. **→** expands the selected workspace (or machine), **←** collapses it, and **←** on a collapsed workspace goes up to the list of every machine, where **→** opens a machine's workspaces. **↑**/**↓** switch to each tab as you go (workspace and machine rows only highlight), Return goes to the selected row, and Esc goes back to where you were. A workspace opens on its last active tab, as clicking it in the sidebar does (the first tab if that one has closed); Return on a machine expands it. Type to search the workspaces, tabs and agents of every connected machine, in one flat list with each result's machine › workspace. A row with an agent shows its mark and state, and a row in a git repository its branch. Names that start with what you typed come first, then names with a word that does, then looser matches. Among equally good matches, workspaces lead, then agents waiting for you, then the current workspace, then everything else. A state word lists the agents in that state first, under their own header: **needs** (or **needs you**) for the ones that wait for you or failed, the longest wait first, **working**, and **done**; more words narrow them ("needs login"). A tab or workspace whose name starts with the word, or has a word that does, still follows them. While typing, **←**/**→** edit the text, **Tab** leaves the search at the selected row (expanded) and **⇧Tab** at its parent, and clearing the text brings back the tree where you left it. On any row, **⌘⌫** closes that tab or workspace (asking first), **⌥↩** opens a new tab there (on an agent's row with a permission request Clotho can answer it allows the request instead, once the request has been under the selection for half a second, and a held key allows nothing; New Tab is still under **>**), **⌘↩** moves the selected tab's panes beside the pane you were in (same machine, clothod 0.1.26 or later), and **⌘1**–**⌘9** go to that row. **⌘P** again closes the bar. The line at the bottom of the bar names three of these keys (**↩** Open, **⌘↩** Open beside, **⌥↩** New tab or Allow) and **esc**; the others work the same. **⌥↩ Allow** is dim there while a press wouldn't allow yet. A row in a repository shows its branch at its right end and, after it, how much changed there (**+128 −32**). A double-tapped **⌥↩** on the last request's row allows that one request and opens no new tab: for half a second after an allow, **⌥↩** on a row with no request does nothing.

Type **>** for commands on the selected row: New Tab or New Workspace there, Split Right or Down, Claude Here, Codex Here, Resume Last Claude in This Folder, Rename (in place), Move Tab to… (then pick the workspace in the tree; Esc cancels), Open Beside, Close Tab or Workspace, Open Files, Settings or Machines, Toggle Sidebar, Appearance, Turn a machine on or off, and Reconnect. Type to narrow them ("split", "dark", "claude"), and Return runs the selected one. A tab without a name shows its active pane's title, or its folder.

**New Tab in a Worktree…** is among those commands (also **File → New Tab in a Worktree…**, **⌥⌘T**) when the row's pane, or the focused one, is in a git repository. The bar asks for a branch name and, optionally, a base (a branch, tag or commit; left empty, the HEAD the pane is on). **Tab** moves between the two fields, and a line under them says what will be made: a new folder beside the repository, named after it and the branch (`clotho` and `fix/login` give `../clotho-fix-login`), on a new branch, with a new tab in it. Return creates it; Esc goes back. For starting an agent on its own checkout, so two agents never edit the same files. A big repository can take a couple of minutes: the bar says it's working and the tab bar shows a small spinner, and you can press Esc and carry on while it finishes. One worktree is made at a time. If it fails, the bar (or a notice, when the bar is away) says why in plain words: the name isn't a valid branch name, a folder or a branch of that name already exists, the base isn't a commit. Two failures leave the new worktree in place because it was already made when its tab couldn't be opened; Clotho says so and names the folder. Clotho never removes a worktree: that's `git worktree remove`, yours to run. The checkout runs none of the repository's hooks or filters, so Git LFS files come out as pointer files until you run `git lfs pull` there. This needs clothod 0.1.32 or later on that machine; before that the command isn't listed.

Rename in place, as in Finder: double-click a workspace in the sidebar or a tab in the tab bar, press **⌃Return** to rename the current workspace, or use **Rename Workspace** (⇧⌘R) or **Rename Tab**. The name turns into a field with its text selected. Return or clicking anywhere else saves it, and Esc cancels. Clearing a tab's name makes it show its pane's title again.

Right-click a pane for its menu: split it in any direction, maximize or close it, open a new tab or workspace, copy, paste, clear or find, upload files into its folder, or browse its machine's files. (A program that uses the mouse, such as vim with `mouse=a`, gets right-clicks instead; Clotho's menu is still in the menu bar.)

Click a pane to focus it. The focused pane has a blue outline when a tab has more than one, and a pane whose agent needs you has an amber one. Drag the line between two panes to resize them.

New tabs and splits open in the focused pane's folder. When a pane's program exits, the pane closes and focus moves to the pane that takes its place. A tab closes with its last pane; a workspace stays until you close it.

## Changes and the inspector

The inspector is the panel on the window's right. Show or hide it with **View → Toggle Inspector** (**⌥⌘B**) or the button at the right end of the title row; drag its left edge to resize it. It has three views, picked in the control at its top (or **View → Changes**, **Files**, **Activity**), and it remembers the last one:

- **Changes**: what changed in the focused pane's git work tree.
- **Files**: the focused pane's folder on its machine. Double-click a file to open it; one on another machine opens as a copy here, and saving the copy writes it back.
- **Activity**: the history of the focused pane's agent, newest first: its state changes, when it needed you, and what it said. (The agent's **History…** window shows the same in a table.)

All three follow the focused pane. Files stops following once you browse somewhere else, and **↩ Follow Pane** brings it back.

**Changes** starts with one line, **6 files vs main  +128 −32**: the files changed and the lines added and removed, counting a file changed both ways twice (hover for each group's own numbers). Under it are two groups:

- **Uncommitted**: the work tree against the last commit, staged, unstaged and new files together.
- **On this branch**: what the branch's commits changed since it left its base (`origin/main`, or the local `main` or `master`), with the number of commits. There is no such group on the base branch itself.

Each file has a letter for what happened to it (**M** modified, **A** added, **D** deleted, **R** renamed, **U** untracked, **C** conflicted), its path (cut in the middle when it's long; hover for all of it) and its lines. **bin** marks a binary file. A group with more than 500 files ends with **and N more**.

Select a file (click it, or use the arrow keys) and its diff shows under the list: each change with a header line, added lines tinted green with a **+** and removed ones red with a **−**. Drag the line between the list and the diff to share the room. Press **Return** or double-click a file for its full diff: it takes the place of the panes, side by side, the old file on the left and the new one on the right with line numbers. In a wide window the files are listed at its side; **↑** and **↓** step through them either way. **Open in Editor** opens the file in its default app (a copy that saves back, for a file on another machine) and **Copy Path** copies its full path. When opening a file would run it (a `.command` script, an app, an executable that no editor opens), **Open in Editor** shows it in Finder instead, and its tooltip says so. **‹** and the tab's name at its left, **Esc** or **⌘W** go back to the panes, which were running underneath all along: the full diff is a view of this window, not a tab, and nothing is started for it. It also closes when you switch to another tab, pane or machine. A command for the pane (**Find**, **Clear**, a split, **Maximize Pane**, **Switch Pane**, **Resize Pane**) goes back to the panes first, so it never works on a pane you can't see; while the full diff shows, typing, pasting and dropped files don't reach the pane under it.

While a file is selected, the list stays on its work tree even if you focus a pane in another repository, and **↩ Follow Pane** appears above the list to go back to the focused pane. The list refreshes when the work tree's counts or its commit change, the selected file's diff every few seconds while you look at it, and the circular arrow refreshes both now.

Changes is for reading: it never stages, commits or discards anything. When there is nothing to list it says why: **This pane isn't in a git repository**, **No changes**, **Reading changes…**, that git is missing or older than 2.31 on that machine, that git took too long, that there are too many changed files, or that the repository is a partial clone (Clotho never downloads the missing parts). A diff can also say **Binary file: no text diff**, that a renamed file has no content changes, that a long diff shows only its first part, that a very long line was cut, or that a file's name has characters Clotho can't send (the file is listed, without a diff). Text from the repository is shown as plain text: escape sequences and invisible characters in a file or its name appear as visible placeholders.

Changes and Activity need clothod 0.1.32 or later on the pane's machine. Against an older one the inspector is the Files view alone, and the pane's strip and **⌘P** show no counts.

## Agents

The top of the sidebar is an inbox of the coding agents (Claude Code, Codex) running in panes on every connected machine, in three sections above the workspaces:

- **Needs you**: agents that wait for you (a permission request, a question, a bell) and ones whose turn failed, the longest wait first.
- **Done**: agents that finished since you last looked, the most recent first.
- **Working**: agents that are running. This section is closed until you click its header.

A section with no agents isn't shown, and with no agent in any of them the sidebar is the workspace list alone. An agent that is idle, resolved or muted has no row; its pane's header still shows it.

Each row is one line: the agent's mark, where it runs (workspace › tab), and what it asks or last said. A pending permission request reads as the request itself (**Allow Bash: npm test**). Hover for the machine, which agent it is and the full text. Click a row to open its pane. Under the pointer, a Needs you or Done row shows **Mute** and **Resolve** at its end: Resolve hides the agent until it needs you again, on every device, and Mute keeps it from coming back until you unmute it (Mute shows when that machine's clothod can mute agents). Right-click a row for the same, **History…**, and its answers.

The chip in a pane's header opens the agent's menu too (click or right-click it): **Open Pane**, **Resolve**, **Mute** or **Unmute**, **History…**, and the permission and reply items. A muted agent has no inbox row and shows a crossed bell in its chip, so this is where you unmute it.

When an agent waits on a permission request, its pane shows the request in a bar at its bottom with **Deny** and **Allow**. With the keyboard in that pane, **⌘↩** allows and **⌘.** denies. In a narrow pane the bar shows the tool and the start of the command (**Bash: cargo test…**); hover for all of it. **Allow** and **Deny** turn on half a second after a request appears, the first one included, so a press that was already on its way can't answer a request you haven't read. **⌘↩** and **⌘.** wait the same half second after you move to the pane or the window comes forward. When several requests wait, each needs its own press, and a held key never answers. The bar goes away when the request is answered, here or anywhere else. (This needs a clothod on that machine that answers permission requests; without it, answer in the terminal or with the quick replies below.)

A finished turn reads **Needs you** when the agent ended it by asking you something, and **Done** when it only finished. (This needs clothod 0.1.31 or later on that machine; before that every finished turn reads Done.)

The same mark shows everywhere an agent does: on its inbox row, its tab, its workspace's chip, its pane's header and in **⌘P**. Amber is Needs you, red an error, green Done, and a turning blue ring Working (it stands still under Reduce Motion). A tab or workspace shows its most urgent agent's mark. The dock icon shows how many agents need you.

You can answer an agent that's asking you something without opening its pane. Its notification has **Approve (1)**, **Deny (Esc)** and **Reply**, and when its hooks report it waiting for you, right-clicking its row (or clicking its pane's chip) offers **1**, **2**, **3**, **Return**, **Esc** and **Reply…** (type a line, sent with Return). Each answer is typed into the agent's pane as its terminal expects, and marks the agent seen. (This needs clothod 0.1.1 or later on that machine.)

Clotho sends a notification when an agent needs you: when it starts waiting for you, finishes, or fails, as reported by its hooks, or when it rings the terminal bell. The notification says whether you're needed: a finished turn that asks you something reads **Needs you**, and one that only finished reads **Done** and makes no sound. Clotho waits until the agent has really stopped before it alerts, so a turn that carries straight on doesn't interrupt you. While you're using Clotho on the Mac, your phone is left alone. An agent detected only from the terminal that has gone quiet shows as idle and doesn't alert, since that may just be a slow reply or a long build. Opening the pane, or typing in it, marks it seen on every device. You don't get a notification for the pane you're looking at. Click it to open the pane. The **Agents** menu in the menu bar turns each kind of notification on or off (so does a right-click on an inbox section's header); a finished turn that asks you something follows **Notify When Waiting for You**, not **Notify When Done**. Right-click a machine and turn off **Monitor Agents** to leave its agents out of the inbox, the marks, the notifications and the dock count. A machine that can't be reached says so on its own row in the sidebar (**Can't reach**, with **Reconnect**), so its agents are never silently missing.

### Overview

**View → Overview** (**⇧⌘0**), or **> Show Overview** in the command bar, shows every agent on every connected machine as a card, over the whole window. It shows the agents of every machine, also one with **Monitor Agents** turned off. The same key, **Esc** or **Back** goes back to where you were; nothing under the Overview moves while it's up.

The cards are in three lanes, as in the inbox: **Needs you** (with an amber outline, the longest wait first), **Working** and **Done** (the most recent first). A lane with no agent isn't shown, and an agent that is idle, resolved or muted with nothing running has no card. A Done card leaves when you resolve it or the agent starts again.

A card shows:

- the agent's mark, where it runs (Workspace › Tab) and for how long (**2 min**; **23 min ago** for a finished one);
- what it asks or last said, on at most two lines (hover for all of it). A permission request reads as the request itself (**Allow Bash: cargo test**);
- the machine and the agent (**devbox · Claude**), how long a finished turn took, and **muted**;
- a live peek: the last two lines of its pane's screen, without the input box an agent's screen ends with. (This needs clothod 0.1.32 or later on that machine; without it the card has no peek.)
- its branch and the lines added and removed in the work tree, or **no repo**.

With the keyboard in the cards:

| Action | Key |
| --- | --- |
| Move between cards | ← → ↑ ↓ |
| Open the agent's pane | Return (or a double-click) |
| Open the agent's Tab beside the current pane | ⌘↩ |
| Resolve | R |
| Mute or unmute | M |
| Filter | / |
| Back | Esc |

A card has no **Allow** or **Deny**: open the pane and answer there, where you can read what it asks. Right-click a card for **Open**, **Open Beside**, **Resolve** and **Mute** or **Unmute**.

**Open Beside** moves the agent's whole Tab next to the pane you were in. It works within one machine, for a Tab other than the one you were in; otherwise the Overview stays and says why.

The filter takes words from the machine's, Workspace's or Tab's name, the branch or the agent's name, and the state words **needs**, **working** and **done**, as the command bar does. **Esc** in the filter clears it; the down arrow or **Return** goes back to the cards.

While the Overview is up, a command for a Workspace, a Tab, a pane, the sidebar or the inspector closes it first and then runs. **⌘W**, **Close Tab** and **Close Workspace** close only the Overview. The command bar, the file browser, the shortcuts overlay and Settings open over it.

## Shells survive quitting

Quitting Clotho (**⌘Q**) or closing its window only disconnects. The daemon keeps every shell running, and reopening Clotho brings back each workspace, tab, pane and screen as it was, including full-screen programs such as vim or Claude Code.

If the daemon's logic process restarts or crashes, Clotho reconnects within a moment and catches up on whatever the panes printed meanwhile. The sidebar shows "reconnecting…" while it waits. The shells live in a separate holder process, so they survive this too.

Closing a pane, tab or workspace ends the programs in it. Shells don't survive a reboot.

## Keyboard shortcuts

**⌘** means Command, **⇧** Shift, **⌥** Option, and **⌃** Control. **Help → Keyboard Shortcuts** (**⌥⌘/**) shows them in the app.

### Workspaces and tabs

| Action | Shortcut |
| --- | --- |
| New workspace | ⌘N |
| Rename workspace | ⇧⌘R or ⌃Return |
| Close workspace | ⇧⌘W |
| Previous / next workspace | ⇧⌘↑ / ⇧⌘↓ |
| New tab | ⌘T |
| New tab in a new git worktree | ⌥⌘T |
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

Resizing moves the nearest divider toward the arrow. A maximized pane fills its tab, and its tab shows ⤢; the other panes keep running. When a full diff, the Overview, the file browser or the shortcuts overlay is open, **⌘W** closes it instead of the pane. Hovering near a pane's top-right corner shows a **×** that closes that pane, as ⌘W does.

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
| Command bar: go to a tab, workspace or agent | ⌘P |
| Toggle sidebar | ⌘/ (or ⌃⌘S) |
| Toggle inspector (Changes, Files, Activity) | ⌥⌘B |
| Overview: every agent's card | ⇧⌘0 |
| Minimize window | ⌘M |
| Toggle full screen | ⌃⌘F |
| Hide Clotho | ⌘H |
| Quit Clotho | ⌘Q |
| Toggle shortcut overlay | ⌥⌘/ |

Closing a workspace always asks first. Closing a tab or pane asks too, with a "Don't ask again" option for each. Option acts as the terminal's Meta key.

## Transfer files

### Copy into a pane's folder

Drag files or folders from Finder onto a terminal, and Clotho copies them into that pane's current folder. **File → Upload Files…** (**⇧⌘U**) does the same for the focused pane, through a file picker.

Hold **Option** while dropping to type the shell-quoted paths instead of copying anything.

### Use the two-pane browser

Open **Window → File Browser** (**⇧⌘O**).

- The left side starts on this Mac, in the focused pane's folder. Its machine menu switches to a saved SSH machine, where it opens in the folder you last visited there, or your home folder the first time.
- The right side starts on this Mac in `~/Downloads`, and remembers the last folder. Its machine menu switches it to another machine too, so either side can show any connected machine.
- Double-click a folder or press **Return** to open it. **Delete/Backspace** or **⌘↑** goes to the parent folder; these keys never delete files.
- Click a breadcrumb to navigate, or click empty space in the path bar to type a path. **Return** navigates and **Escape** cancels.
- The eye button shows hidden files, and the refresh button reloads the listing.
- Click a column's header (**Name**, **Size**, **Modified**, **Kind**) to sort by it, and click again to reverse. Folders stay first. Each side remembers its sort.
- Type in a side's **Filter** field (or press **⌘F** in its list) to show only the names in the folder that contain the text, ignoring case. Opening another folder clears it.
- Double-clicking a local file opens it in its default app.

Drag items between the sides, or right-click a selection and choose copy, upload or download. Dropping onto a folder row copies into that folder; dropping on the listing's background uses the folder shown. Drag from Finder into either side to copy there, and drag remote items to Finder to download them.

Copies go between any two machines, remote to remote included: with devbox on one side and imac on the other, drag across or use **Copy to imac**. A remote-to-remote copy streams through this Mac, so the two machines need no SSH access to each other. Both must be connected in Clotho. Moves aren't supported; copies leave the source in place.

### Conflicts and progress

When names already exist at the destination, Clotho offers **Replace**, **Skip** and **Cancel**. Replace overwrites matching files and merges folders; it never deletes other files there. Downloads dragged to Finder follow Finder's own handling.

A toast in the corner shows each transfer's progress and result. Its cancel button stops a transfer. Files that finished stay; a file cut short never appears half-written, and copying it again resumes where it stopped. Transfers copy, so the source always stays in place. Copies keep file modes and modification times, and can go between any two machines (through the app when neither is this Mac).

## Remote machines

Clotho runs workspaces on other machines over SSH: Linux (x86_64 or ARM) and macOS. The sidebar lists each machine under its own header, with its workspaces below it, and the window shows one workspace at a time.

### Add a machine

First check that SSH works without prompts from this Mac, replacing `user@imac` with the username and host, an SSH alias, or a Tailscale name:

```sh
ssh -o BatchMode=yes user@imac true
```

If that fails, set up a key or an SSH agent. Clotho runs ssh without prompts and can't ask for a password or passphrase. The machine needs a POSIX shell. The file browser uses the machine's clothod, so it needs clothod 0.1.3 or later; an older one shows an update notice in the browser.

Then click **Machines** at the bottom of the sidebar and **Add…** (or choose **File → Add Machine…**), and give it a name and the SSH target.

With Tailscale, connect both machines to the tailnet and use the remote machine's MagicDNS name or Tailscale IP as the host. See [Tailscale's connection guide](https://tailscale.com/docs/how-to/connect-to-devices).

### Connect and start workspaces

A machine you haven't connected to shows **Connect** under its name. Click it to connect and start a workspace there. The first time, Clotho installs its terminal daemon, clothod, on the machine: it uploads the matching build that ships inside the app into `~/.local/share/clothod/bin/` (Linux) or `~/Library/Application Support/clothod/bin/` (macOS). Nothing else is installed, and no root access is needed.

If a remote machine can't be reached (it's off, asleep or off the network), Clotho tries three times a second or two apart, then stops and shows **Can't reach** with a **Reconnect** button under the machine's name (hover over it for ssh's reason). It also tries again by itself when the Mac wakes or the network changes.

Once connected, a machine works like this Mac: **+ New Workspace** under its name starts another workspace, and every shortcut acts on the machine whose workspace is showing. **⇧⌘↑** and **⇧⌘↓** step through the workspaces of every connected machine in sidebar order. Dropping files on a remote pane copies them to that pane's folder on that machine.

Shells on a machine keep running when you quit Clotho, disconnect, or lose the network, and normally when you log out of the machine. (On a Linux machine set to end a user's processes at logout, they survive only with lingering on, `loginctl enable-linger`; Clotho shows clothod's warning once if that's the case.) Clotho reconnects connected machines when it starts, after the Mac wakes, and when the network changes, and catches up on what each pane printed meanwhile.

The status under a machine's name shows where it stands: connecting or installing, reconnecting with the last error, or nothing once it's connected (a green dot). For a machine that isn't connected, the dot shows the last SSH check: green if ssh connects, red if it doesn't (hover for ssh's message).

Right-click a machine's name for its menu:

- **New Workspace**, or **Connect** and **Connect and Start a Workspace**.
- **Browse Files** opens the file browser on it.
- **Reconnect** drops and re-establishes the connection; **Disconnect** stops showing its workspaces, which keep running there.
- **Check Connection** runs the SSH check again (machines that aren't connected).
- **Edit…** changes its name or SSH target, and **Remove…** takes it off Clotho's list. Neither touches the machine or its shells.

### Settings

**⌘,** opens Settings, a window with two tabs:

- **General**: which agent events notify you (waiting, finished, error), Appearance (System, Light or Dark; the terminals follow), and Updates (a daily automatic check, **Check Now**, and the version you run).
- **Machines**: every saved machine, This Mac first, with its user@host, a status dot (connected, connecting, not connected, can't reach, or a hollow ring when it's off) and its on/off switch. **+** adds a machine and **−** removes the selected one; double-click a machine (or right-click it) to edit it, and drag to reorder the sidebar. Under the list are the selected machine's own settings: whether its agents show in the sidebar, ⌘P and notifications, how many lines of scrollback each pane keeps, **Summarize agent messages** (Claude Haiku writes one line for notifications; off shows the message itself), and whether clothod starts at login. When a machine's summaries aren't working, the line under that switch says so and why (**Not working: …**), or that Claude Code wasn't found on that machine. These last three live in that machine's clothod, so they need it connected, and every client sees the same values.

### Switch a machine off

**Settings › Machines** (the **Machines** button at the bottom of the sidebar) lists every saved machine, each with a status dot and a switch (this Mac has none). Switching a machine off closes Clotho's connection to it at once and stops every reconnect attempt. It leaves the sidebar, the inbox, **⌘P** and the file browser, and Clotho shows no notifications from it. Its clothod and shells keep running on the machine. The machine stays in the list, dimmed and marked **Off**, and switching it back on reconnects and shows its workspaces again. The setting is saved.

### Updates

Clotho never restarts a daemon on its own. When an update brings a newer clothod, Clotho installs it next to the running one (on this Mac at launch, on another machine when it connects) and keeps using the running daemon. A notice then offers **Restart Daemon**: that restarts the daemon's logic process on the new build, and your shells and programs carry on untouched.

If a machine's shells were started by a clothod too old for the new one to take over, the notice offers **Restart clothod…** instead. That ends every shell on that machine, so it always asks first; until then everything keeps working as it is.

### Agent status

Clotho detects Claude Code and Codex from the terminal, which works without any setup. For exact status (the moment an agent waits for you, finishes or fails), right-click a machine and choose **Set Up Agent Status…**. Clotho first shows exactly what `clothod hooks install` would change on that machine (the agents' settings files, with backups kept), and installs the hooks only if you confirm. `clothod hooks uninstall` undoes it.

## Launch options

Pass these after `--args`, for example `open -n ~/Applications/Clotho.app --args -Backend fake`. They're ordinary user defaults, so `defaults write app.clotho.desktop <key> <value>` makes one stick.

| Option | Effect |
| --- | --- |
| `-ClothodRuntimeDir <dir>` | Use a separate daemon with its socket in `<dir>`, for a set of workspaces kept apart from the usual one. `CLOTHOD_RUNTIME_DIR` does the same. Keep the path short; socket paths are limited to about 100 bytes. |
| `-ClothodPath <path>` | Run this clothod binary in place instead of installing the bundled one. `CLOTHOD_BIN` does the same. |
| `-RemoteInstallDir <dir>` / `-RemoteRuntimeDir <dir>` | Install clothod into, and run it from, these directories on remote machines (the remote shell expands `$HOME` and `$(id -u)`). The dev build uses `$HOME/.local/share/clotho-dev/bin` and `/tmp/clothod-dev-$(id -u)`. |
| `-FakeAgents YES` | With `-Backend fake`, put fake agents in panes and move them through their states; the first pane's agent waits on a permission request, so its pane shows the ask bar. `-AgentNotifications NO` logs notifications instead of showing them. Panes 3 to 5 (split the tab first) show a finished turn that asks something, a plain Done, and a settling one. |
| `-FakeFeatures "agent.decide,agent.mute"` | With `-Backend fake`, more features for the fake daemon to announce, without the fake agents (for tests that place their own). |
| `-FakeRewriteHealth failing` | With `-Backend fake`, what Settings › Machines shows under "Summarize agent messages": `failing`, `unavailable`, `ok`, `off` or `unknown`. |
| `-PaneMenu "<item>"` | Log the focused pane's right-click menu and choose that item (for scripted testing). |
| `-ConnectMachine <name>` | Connect to that saved machine and start a workspace there (for scripted testing). |
| `-Backend fake` | Run shells inside the app with no daemon. Shells end when the app quits. For UI work. |
| `-LaunchInBackground YES` | Open behind other windows without taking keyboard focus. |
| `-StartFullScreen YES` | Open filling the display. |
| `-TraceFrames YES` | Log every pane data frame to and from the daemon, with pane, seq and length. |
| `-LogModel YES` | Log every model change and pane size change. |
| `-DumpScreens "5\|9"` | Log each shown pane's text and cursor at those seconds after launch. |

For scripted testing, `-RunShortcuts "Split Right,New Tab"` fires menu items by title, `-TypeText "ls\r|exit\r"` types each step into the focused pane, and `-ResizeWindow "900x600|1400x900"` resizes the window. Steps run a second or two apart; an empty step just waits. Use the [dev build](../README.md#dev-build) for these. A window covered by other windows stops drawing, so its screenshots can be stale; `-DumpScreens` reads the terminals directly.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| "Couldn't start clothod" | The log names the clothod binary and socket it tried. Check that `Clotho.app/Contents/MacOS/clothod` exists (rebuild with `./build-app.sh`), and look at clothod's own logs in `~/Library/Application Support/clothod/`. |
| This Mac's workspaces stay on "Reconnecting" | Run `~/Library/Application\ Support/clothod/bin/*/clothod status`. Clotho starts the daemon again on its own; if that keeps failing, its logs say why. |
| A machine stays on "Reconnecting" | The status line has ssh's or clothod's error. Test `ssh -o BatchMode=yes user@host true`. Clotho keeps retrying, up to every 30 seconds; right-click the machine and choose **Reconnect** to try at once. |
| "Has no clothod build" for a machine | Clotho carries builds for Linux and macOS on x86_64 and ARM only. |
| A pane shows a smaller terminal in its top-left corner | Another client sized that pane. It takes this window's size again once you type in it. |
| Remote browser can't connect | Test `ssh -o BatchMode=yes user@host true` from this Mac, and check keys, the SSH agent, host-key trust and the network. |
| Remote folder listing fails | Connect to the machine first. If it says the machine's clothod can't share files, accept the update offer for that machine. Otherwise check the folder is readable. |
| A file transfer fails | The transfer toast shows the machine's error (for example a full disk or no permission). Copying again resumes files that were cut short. |
| An upload can't find the pane's folder | The daemon hasn't learned the folder yet. Wait a moment after `cd`, or use the file browser. |
| Desktop, Documents or Downloads is inaccessible | Review Clotho under System Settings → Privacy & Security → Files and Folders. |
| "Shells on … can't reach some system services" | That machine's clothod was started outside your login session (for example over SSH), so its shells can lose DNS, the keychain (and with it `gh`'s login) and user lookups. **Restart Shells…** ends them and starts clothod again inside your session; workspaces, tabs, panes and agent conversations come back, scrollback doesn't. Needs clothod 0.1.24 or later to detect. |
| Claude Code or another app looks dark-themed in light mode (dark diff rows, pale text) | The app draws its own theme. In Claude Code, run `/theme` and pick **Auto**. With clothod 0.1.20 or later, Clotho tells each machine's daemon the colours it shows panes in, so apps that ask the terminal (Auto in Claude Code, vim's background detection) follow Clotho's light or dark mode. Pick **Light** on older daemons. |

The app's log is `~/Library/Logs/Clotho.log`. The daemon's command-line client, `clotho` (build it with `cargo build` in `clotho/clothod`; it lands in `target/debug/`), shows the daemon's view: `clotho ls` lists workspaces, tabs and panes, and `clotho text <pane>` prints a pane's screen.

## Saved state

| Location | Contents |
| --- | --- |
| `app.clotho.desktop` defaults domain | Font size, window frame, saved machines, which machines are connected and focused, last browser folders, sidebar visibility and "Don't ask again" choices |
| `~/Library/Application Support/clothod/bin/` | Installed clothod builds (on remote machines: `~/.local/share/clothod/bin/` on Linux) |
| `$TMPDIR/clothod/` | The daemon's socket (on Linux machines: `/tmp/clothod-<uid>/`) |
| `~/Library/Application Support/clothod/` | The daemon's logs |
| `~/Library/Logs/Clotho.log` | The app's log |

On first launch, Clotho copies settings from the `app.clotho.desktop.next` domain used by the earlier "Clotho Next" builds, without replacing anything already set.
