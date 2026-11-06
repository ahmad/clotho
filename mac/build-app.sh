#!/bin/zsh
# Builds Clotho.app and installs it to ~/Applications.
#
# ./build-app.sh --dev builds "Clotho Dev.app" in build/ instead, for automated and manual testing. It has
# its own bundle id, preferences, log and clothod runtime directory, and is never installed, so test runs
# can't touch the installed app or its sessions.
#
# ./build-app.sh --release signs with Developer ID, notarizes and staples (scripts/notarize.sh) before
# installing. It needs the Developer ID certificate, notarytool credentials and a clothod dist built with
# CLOTHOD_SIGN_IDENTITY (README, "Notarized builds"). Without --release the app is signed ad hoc.
#
# ./build-app.sh --package builds build/Clotho.app the way --release does (or signed ad hoc, when there's
# no Developer ID yet) but doesn't install it: scripts/release.sh turns it into a Sparkle update.
#
# --release and --package sign with the Developer ID of the Apple team CLOTHO_TEAM_ID, which comes from the
# environment (scripts/keychain.sh) and is never written in the repo; without it they stop before
# building. --dev and plain builds don't need it.
#
# CLOTHO_TAILNET=1 ./build-app.sh --dev also links Clotho's own tailnet node (../ClothoKit/Tailnet; build its
# xcframework first with ../ClothoKit/scripts/build-tailnet.sh) and bundles clotho-tailnet-proxy, for the dev-only
# Tailnet Test window (Help menu). Every other build unsets it and refuses an executable that has the node in it:
# the user's app doesn't ship the tailnet yet (PLAN.md, "Built-in Tailscale", Phase 0).
#
# ./build-app.sh --check-dist builds nothing: it reports which clothod dist a plain build would bundle,
# and which Developer ID identity --release and --package would sign with.
#
# On the release build host (the build Mac: the one with Clotho's build keychain, see scripts/keychain.sh)
# it only builds: plain and --release, which install into ~/Applications, are refused there. --package and
# --dev work anywhere.
#
# The version is VERSION (CFBundleShortVersionString); the build number, which Sparkle compares, is the
# UTC time (CFBundleVersion, YYYYMMDDHHMM). CLOTHO_VERSION and CLOTHO_BUILD override them.
set -euo pipefail
cd "$(dirname "$0")"

DEV=false
RELEASE=false
PACKAGE=false
CHECK=false
case "${1:-}" in
  --dev) DEV=true ;;
  --release) RELEASE=true ;;
  --package) PACKAGE=true ;;
  --check-dist) CHECK=true ;;
  "") ;;
  *) echo "usage: $0 [--dev | --release | --package | --check-dist]" >&2; exit 2 ;;
esac
source scripts/keychain.sh
if $CHECK; then
  scripts/clothod-dist.sh --check
  # The signing identity, reported only: a plain build doesn't need one.
  if TEAM=$(clotho_team_id) && clotho_unlock_keychain; then
    IDENTITY=$(clotho_developer_id)
    if [[ -n "$IDENTITY" ]]; then
      echo "build-app: --release and --package would sign with \"$IDENTITY\" (keychain ${CLOTHO_KEYCHAIN:t})" >&2
    else
      echo "build-app: no Developer ID Application identity for team $TEAM in $CLOTHO_KEYCHAIN: --package would sign ad hoc, and --release would stop" >&2
    fi
  else
    echo "build-app: --release and --package can't sign on this Mac yet (see above)" >&2
  fi
  exit 0
fi
if $CLOTHO_ON_BUILD_HOST && ! $DEV && ! $PACKAGE; then
  echo "error: this Mac is the release build host (it has $CLOTHO_KEYCHAIN), and Clotho is never installed here. Use --package (scripts/release.sh) or --dev." >&2
  exit 2
fi
if ($RELEASE || $PACKAGE) && ! clotho_team_id >/dev/null; then
  echo "error: --release and --package sign with the Developer ID of CLOTHO_TEAM_ID's team (see above)" >&2
  exit 2
fi
VERSION=${CLOTHO_VERSION:-$(cat VERSION)}
BUILD=${CLOTHO_BUILD:-$(date -u +%Y%m%d%H%M)}
if $DEV; then
  NAME="Clotho Dev"
  BUNDLE_ID="app.clotho.desktop.dev"
else
  NAME="Clotho"
  BUNDLE_ID="app.clotho.desktop"
fi

# The tailnet node: dev builds only, and only when asked for (see the top).
TAILNET=false
if $DEV && [[ "${CLOTHO_TAILNET:-}" == 1 ]]; then
  TAILNET=true
  if [[ ! -d ../ClothoKit/Tailnet/build/ClothoTailnet.xcframework ]]; then
    echo "error: CLOTHO_TAILNET=1 needs the tailnet xcframework: run ClothoKit/scripts/build-tailnet.sh first" >&2
    exit 1
  fi
else
  unset CLOTHO_TAILNET
fi

# --disable-keychain: SwiftPM otherwise asks the keychain for github.com credentials when it fetches
# Sparkle's binary, which fails over SSH, where the keychain is locked. Nothing it fetches needs any.
swift build -c release --disable-keychain
# A stale manifest evaluation or object must never put the node in an app without it.
# scripts/check-no-tailnet.sh also fails when it can't read the executable.
if ! $TAILNET; then
  scripts/check-no-tailnet.sh .build/release/Clotho
fi
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clotho "$APP/Contents/MacOS/Clotho"
if $TAILNET; then
  # ssh's ProxyCommand for the node (ProxyUseFdpass): a separate small binary, so each ssh doesn't start Clotho
  # (and its Go runtime). Signed ad hoc like the rest of the dev build, before the app is.
  swift build -c release --disable-keychain --package-path ../ClothoKit/Tailnet --product clotho-tailnet-proxy
  cp "$(swift build -c release --disable-keychain --package-path ../ClothoKit/Tailnet --show-bin-path)/clotho-tailnet-proxy" "$APP/Contents/MacOS/"
  codesign --force --sign - "$APP/Contents/MacOS/clotho-tailnet-proxy"
fi

# clothod ships inside the app: every platform's build in Resources/clothod-dist (installed on remote
# machines over SSH, see ../docs/remote.md), and this Mac's build next to the executable, where Clotho
# installs it from. scripts/clothod-dist.sh picks the dist. The user's app (plain, --release,
# --package) bundles only a released one, whose version is clothod/RELEASED, and never builds one:
# anything it bundles reaches every machine through "Update clothod". --dev may use a dev dist of the
# current version (clothod/target/dist-dev). CLOTHOD_DIST names an existing dist; the user's app still
# checks it. `./build-app.sh --check-dist` reports which dist a plain build would bundle, and stops.
if $DEV; then
  DIST=$(scripts/clothod-dist.sh --dev)
else
  DIST=$(scripts/clothod-dist.sh)
fi
cp -R "$DIST" "$APP/Contents/Resources/clothod-dist"
case "$(uname -m)" in arm64) HOST=macos-aarch64 ;; *) HOST=macos-x86_64 ;; esac
# Copied byte for byte: the dist builds are already (linker) signed, and re-signing would change their
# install id, so the daemon this Mac runs would no longer match the manifest.
cp "$DIST/$HOST/clothod" "$APP/Contents/MacOS/clothod"
EXPECTED=$(sed -n "/\"$HOST\"/s/.*\"id\": \"\([^\"]*\)\".*/\1/p" "$DIST/manifest.json")
ACTUAL=$("$APP/Contents/MacOS/clothod" build-id)
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "error: bundled clothod is $ACTUAL, but the manifest says $EXPECTED" >&2
  exit 1
fi
echo "Bundled clothod $(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$DIST/manifest.json" | head -1) for $(ls "$DIST" | grep -v manifest | tr '\n' ' ')"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# Sparkle, for in-app updates. Clotho isn't sandboxed, so Sparkle's XPC services aren't needed; they're
# left out, and what remains is signed again (ad hoc here, Developer ID in scripts/notarize.sh).
SPARKLE=$(find -L .build/release -maxdepth 1 -name Sparkle.framework | head -1)
[[ -n "$SPARKLE" ]] || { echo "error: no Sparkle.framework in .build/release" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
for nested in Versions/B/Autoupdate Versions/B/Updater.app ""; do
  codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/$nested"
done

# Updates: the feed and the public half of the EdDSA key (Resources/SparklePublicKey, made by Sparkle's
# generate_keys at the release Mac). Without them the app has updates turned off. The dev build never
# updates.
#
# UPDATES_LIVE is the one switch for hosting. https://clotho.app/appcast.xml is live (2026-10-29), so
# every non-dev build gets the feed. Set it to false to keep plain installs off the feed (only --release
# and --package builds then get it), e.g. if the feed ever goes away.
UPDATES_LIVE=true
UPDATE_KEYS=""
if ! $DEV && [[ -s Resources/SparklePublicKey ]] && { $UPDATES_LIVE || $RELEASE || $PACKAGE; }; then
  UPDATE_KEYS="<key>SUFeedURL</key><string>https://clotho.app/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < Resources/SparklePublicKey)</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
elif ! $DEV && [[ -s Resources/SparklePublicKey ]]; then
  # The key is there but the feed isn't live: the app says so rather than "no signing key".
  UPDATE_KEYS="<key>ClothoUpdateFeedNotLive</key><true/>"
fi

# App icon ("Panes", Resources/AppIcon): every size drawn from the vector at its exact pixel size, the
# 16 and 32 px ones from the hand-tuned small variant. Resources/icon-1024.png is the 1024 rendering.
ICONSET="build/Clotho.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swiftc -O -o build/make-icon scripts/make-icon.swift
build/make-icon Resources/icon-1024.png 1024
for s in 16 32 128 256 512; do
  variant=(); (( s <= 32 )) && variant=(--small)
  build/make-icon "$ICONSET/icon_${s}x${s}.png" $s "${variant[@]}"
  # @2x of 16 is 32 px: still small. 32@2x (64 px) and up get the full drawing.
  variant2=(); (( s * 2 <= 32 )) && variant2=(--small)
  build/make-icon "$ICONSET/icon_${s}x${s}@2x.png" $((s * 2)) "${variant2[@]}"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Clotho.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Clotho</string>
  <key>CFBundleIconFile</key><string>Clotho</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  $UPDATE_KEYS
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>ClothoDevBuild</key><$($DEV && echo true || echo false)/>
  <key>NSDownloadsFolderUsageDescription</key><string>Clotho's file browser shows and copies files in your Downloads folder.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Clotho's file browser shows and copies files in your Documents folder.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Clotho's file browser shows and copies files on your Desktop.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
if $RELEASE; then
  scripts/notarize.sh "$APP"
fi
if $PACKAGE; then
  # Developer ID and notarized when the team's certificate exists; ad hoc otherwise.
  clotho_unlock_keychain || exit 1
  if [[ -n "$(clotho_developer_id)" ]]; then
    scripts/notarize.sh "$APP"
  else
    echo "warning: no Developer ID identity, so $APP is signed ad hoc and not notarized" >&2
  fi
  echo "Packaged $APP ($VERSION, build $BUILD)"
  exit 0
fi
if $DEV; then
  echo "Built $APP (not installed). Run it with: open -g -n \"$PWD/$APP\" --args -LaunchInBackground YES"
  exit 0
fi
mkdir -p ~/Applications
rm -rf ~/Applications/"$NAME.app"
cp -R "$APP" ~/Applications/"$NAME.app"
touch ~/Applications/"$NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"$NAME.app"
echo "Installed ~/Applications/$NAME.app"
