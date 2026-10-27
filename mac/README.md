# Clotho for Mac

Clotho is a native macOS app for terminal workspaces. Each pane is its own terminal view, arranged in tabs and splits, with a sidebar of workspaces and a two-pane file browser for copying files to and from SSH machines.

The terminals live in [clothod](../clothod/README.md), Clotho's terminal daemon, which ships inside the app. Quitting Clotho leaves the shells running, and reopening it brings back every workspace, tab, split and screen exactly as they were. [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) renders the terminals.

## Features

- Workspaces, tabs, and panes split in any direction, with draggable dividers. Rename workspaces and tabs in place, as in Finder.
- Directional pane focus, keyboard resizing and pane maximize.
- A dark theme, the bundled Hack Nerd Font, font zoom, and native find, selection and copy.
- A borderless window that can fill the whole display, including the strip beside the camera notch.
- File uploads to the focused pane's folder, by drag and drop or a file picker.
- Workspaces on other machines over SSH (Linux and macOS). Clotho installs and updates its daemon there itself, and remote shells survive disconnects, sleep and network changes.
- A two-pane browser for copying between this Mac and those machines, with drag and drop to Finder, overwrite prompts, progress and cancellation.

## Requirements

| Requirement | Used for |
| --- | --- |
| macOS 13 or later | Running the app |
| Swift 6.2 or later and the macOS developer tools | Building the app |
| Rust (`cargo`, `rustup`) | Building clothod for every platform, which the build script bundles |
| `/usr/bin/ssh` | Connecting to remote machines (`clothod bridge`) |
| clothod 0.1.3 or later on remote machines | Browsing and copying files on them (clothod's `fs.*`) |

## Build and install

```sh
cd clotho/mac
./build-app.sh
open ~/Applications/Clotho.app
```

The script builds the app in release mode, runs `../clothod/scripts/dist.sh` and bundles its builds (macOS and Linux, x86_64 and ARM; the Linux ones go to remote machines), generates the icon, signs everything ad hoc, and installs `~/Applications/Clotho.app` (bundle id `app.clotho.desktop`). Running it again replaces the installed copy. Set `CLOTHOD_DIST` to bundle an existing `dist/` directory instead of building one.

For a compile-only check, run `swift build`. `swift test` here runs the app's own tests (key encoding, inline rename); the shared package's tests run with `swift test` in `../ClothoKit`.

### Dev build

```sh
./build-app.sh --dev
open -g -n "build/Clotho Dev.app" --args -LaunchInBackground YES
```

`Clotho Dev.app` stays in `build/` and is never installed. It has its own bundle id (`app.clotho.desktop.dev`), preferences, log (`~/Library/Logs/Clotho Dev.log`) and daemon (`$TMPDIR/clotho-dev`), so testing never touches the installed app or its shells. Use it for every scripted or automated run. `-LaunchInBackground YES` keeps it from taking keyboard focus, so it can't catch keystrokes meant for another app.

## Start using Clotho

1. Open Clotho. The first launch starts the daemon and opens a workspace with one shell.
2. Press **⌘T** for a new tab, **⌘D** to split right, or **⇧⌘D** to split down.
3. Press **⌘N** for another workspace; the sidebar lists them all.
4. Press **⇧⌘O** to browse files, or drop files onto a terminal to copy them into that pane's folder.
5. Press **⌘/** for every shortcut.

Read the [usage guide](docs/usage.md) for all shortcuts, file transfers, remote machines, launch options and troubleshooting.

## Source layout

| File | Purpose |
| --- | --- |
| [`Sources/Clotho/main.swift`](Sources/Clotho/main.swift) | App lifecycle, window, theme, fonts, backend choice and testing aids |
| [`Sources/Clotho/Workspaces.swift`](Sources/Clotho/Workspaces.swift) | Keeps the window in step with the daemon's model; workspace and tab actions, inline renames |
| [`Sources/Clotho/PaneView.swift`](Sources/Clotho/PaneView.swift) | One pane: a terminal view fed by the daemon, its size, and the reply filter |
| [`Sources/Clotho/SplitLayoutView.swift`](Sources/Clotho/SplitLayoutView.swift) | Lays out a tab's split tree, with draggable dividers |
| [`Sources/Clotho/Chrome.swift`](Sources/Clotho/Chrome.swift) | Tab bar and sidebar |
| [`Sources/Clotho/Shortcuts.swift`](Sources/Clotho/Shortcuts.swift) | Menus, the shortcuts overlay, and the actions behind them |
| [`Sources/Clotho/MachineConnections.swift`](Sources/Clotho/MachineConnections.swift) | One daemon connection per machine, keyed views, reconnects on wake and network changes |
| [`Sources/Clotho/LocalDaemon.swift`](Sources/Clotho/LocalDaemon.swift) | Installs and starts this Mac's clothod, and upgrades it |
| [`Sources/Clotho/Machines.swift`](Sources/Clotho/Machines.swift) | Saved machines: add, edit, remove, connection checks and the machine menu |
| [`Sources/Clotho/Files.swift`](Sources/Clotho/Files.swift) | The saved machine list, SSH, the file browser and transfers |
| [`../ClothoKit`](../ClothoKit) | Shared with the future iOS app: the model, the clothod protocol client, and a fake backend for UI work |
| [`build-app.sh`](build-app.sh) | Build, bundle, sign and install |

Bundled font licensing is documented in [`Resources/Fonts/LICENSE-Hack.md`](Resources/Fonts/LICENSE-Hack.md). The protocol between the app and the daemon is specified in [`../docs/protocol.md`](../docs/protocol.md).
