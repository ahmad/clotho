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

The script builds the app in release mode, bundles the released clothod (`../clothod/dist`, macOS and Linux, x86_64 and ARM; the Linux ones go to remote machines), generates the icon, signs everything ad hoc, and installs `~/Applications/Clotho.app` (bundle id `app.clotho.desktop`). Running it again replaces the installed copy.

The installed app bundles only a released clothod: a dist whose version is `clothod/RELEASED`, made by `clothod/scripts/dist.sh`. It never builds one itself, and it refuses a dev dist (`clothod/target/dist-dev`), because whatever it bundles reaches every machine through "Update clothod". `--dev` may bundle a dev dist of the current version. [`scripts/clothod-dist.sh`](scripts/clothod-dist.sh) makes the choice; `./build-app.sh --check-dist` reports what a plain build would bundle (version and build ids) without building, and `scripts/test-clothod-dist.sh` tests the rules. `CLOTHOD_DIST` names another dist directory, which the same checks apply to.

For a compile-only check, run `swift build`. `swift test` here runs the app's own tests (key encoding, inline rename); the shared package's tests run with `swift test` in `../ClothoKit`.

### Dev build

```sh
./build-app.sh --dev
open -g -n "build/Clotho Dev.app" --args -LaunchInBackground YES
```

`Clotho Dev.app` stays in `build/` and is never installed. It has its own bundle id (`app.clotho.desktop.dev`), preferences, log (`~/Library/Logs/Clotho Dev.log`) and daemon (`$TMPDIR/clotho-dev`), so testing never touches the installed app or its shells. Use it for every scripted or automated run. `-LaunchInBackground YES` keeps it from taking keyboard focus, so it can't catch keystrokes meant for another app.

### Notarized builds

`./build-app.sh` signs ad hoc, which is fine on this Mac. `./build-app.sh --release` signs with Developer ID (hardened runtime, secure timestamp, [`Resources/Clotho.entitlements`](Resources/Clotho.entitlements)), notarizes with `notarytool`, staples the ticket, then installs. [`scripts/notarize.sh`](scripts/notarize.sh) does the signing and notarizing, and refuses a bundled clothod that isn't Developer ID signed: clothod's build ids hash the whole file, so its dist signs it (`CLOTHOD_SIGN_IDENTITY`), not the app.

One-time setup, at the Mac itself (the login keychain is locked over SSH):

1. Xcode › Settings › Accounts › the Apple ID in team TEAMID0000 › Manage Certificates… › + › **Developer ID Application**. Only the team's Account Holder can create one.
2. Check it: `security find-identity -v -p codesigning | grep "Developer ID Application"`
3. Make an app-specific password at [account.apple.com](https://account.apple.com) › Sign-In and Security › App-Specific Passwords, then store it for notarytool (it asks for the password):
   `xcrun notarytool store-credentials clotho-notary --apple-id "YOUR_APPLE_ID_EMAIL" --team-id TEAMID0000`
4. Check it: `xcrun notarytool history --keychain-profile clotho-notary`

Each release, at the Mac:

```sh
CLOTHOD_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID0000)" clothod/scripts/dist.sh
mac/build-app.sh --release
```

`CLOTHO_SIGN_IDENTITY` and `CLOTHO_NOTARY_PROFILE` override the identity and the profile name (`clotho-notary`).

### Releases and in-app updates

Clotho updates itself with [Sparkle 2](https://sparkle-project.org): **Clotho › Check for Updates…**, plus a daily automatic check (Settings › Updates turns it off). It reads the appcast at `https://clotho.app/appcast.xml` and installs an update only if its zip is signed with Clotho's EdDSA key. The public key is in [`Resources/SparklePublicKey`](Resources) and goes into Info.plist as `SUPublicEDKey`. The private key exists only in the release Mac's login keychain, never in the repo. A build without `Resources/SparklePublicKey` has updates turned off, and Clotho Dev never updates.

One-time setup, at the Mac itself (the keychain is locked over SSH):

1. Make the key pair. This stores the private key in the login keychain and prints the public key:
   `"$(mac/scripts/sparkle-tools.sh)/generate_keys"`
2. Save the public key for the build (it isn't secret), and commit it:
   `"$(mac/scripts/sparkle-tools.sh)/generate_keys" -p > mac/Resources/SparklePublicKey`
3. Back up the private key somewhere safe outside the repo, such as a password manager, then delete the file. Losing it means existing installs can never be updated again:
   `"$(mac/scripts/sparkle-tools.sh)/generate_keys" -x ~/Desktop/clotho-sparkle-private-key` 

Each release, at the Mac (Developer ID signing and notarizing happen when the certificate is there; see above):

```sh
echo 1.1.0 > mac/VERSION                     # the version people see; the build number is the UTC time
mac/scripts/release.sh path/to/notes.html    # notes are optional HTML for the update window
```

It writes `build/release/Clotho-<version>-<build>.zip` and `build/release/appcast.xml`. Upload the zip to `https://clotho.app/downloads/`, then publish the appcast at `https://clotho.app/appcast.xml`, in that order, so the feed never points at a missing file. `CLOTHO_APPCAST_IN` starts from another appcast file than the live one, and `CLOTHO_DOWNLOADS` changes the download URL.

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
| [`Sources/Clotho/Onboarding.swift`](Sources/Clotho/Onboarding.swift) | First-run welcome window (Help › Welcome to Clotho), and the SSH connection check that explains failures |
| [`Sources/Clotho/Updates.swift`](Sources/Clotho/Updates.swift) | In-app updates with Sparkle: Check for Updates… and the automatic check |
| [`../ClothoKit`](../ClothoKit) | Shared with the future iOS app: the model, the clothod protocol client, and a fake backend for UI work |
| [`build-app.sh`](build-app.sh) | Build, bundle, sign and install (`--dev`, `--release`) |
| [`scripts/notarize.sh`](scripts/notarize.sh) | Developer ID signing, notarization and stapling |

Bundled font licensing is documented in [`Resources/Fonts/LICENSE-Hack.md`](Resources/Fonts/LICENSE-Hack.md). The protocol between the app and the daemon is specified in [`../docs/protocol.md`](../docs/protocol.md).
