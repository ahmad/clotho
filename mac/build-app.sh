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
# The version is VERSION (CFBundleShortVersionString); the build number, which Sparkle compares, is the
# UTC time (CFBundleVersion, YYYYMMDDHHMM). CLOTHO_VERSION and CLOTHO_BUILD override them.
set -euo pipefail
cd "$(dirname "$0")"

DEV=false
RELEASE=false
PACKAGE=false
case "${1:-}" in
  --dev) DEV=true ;;
  --release) RELEASE=true ;;
  --package) PACKAGE=true ;;
  --check-dist) exec scripts/clothod-dist.sh --check ;;
  "") ;;
  *) echo "usage: $0 [--dev | --release | --package | --check-dist]" >&2; exit 2 ;;
esac
VERSION=${CLOTHO_VERSION:-$(cat VERSION)}
BUILD=${CLOTHO_BUILD:-$(date -u +%Y%m%d%H%M)}
if $DEV; then
  NAME="Clotho Dev"
  BUNDLE_ID="app.clotho.desktop.dev"
else
  NAME="Clotho"
  BUNDLE_ID="app.clotho.desktop"
fi

# --disable-keychain: SwiftPM otherwise asks the keychain for github.com credentials when it fetches
# Sparkle's binary, which fails over SSH, where the keychain is locked. Nothing it fetches needs any.
swift build -c release --disable-keychain
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clotho "$APP/Contents/MacOS/Clotho"

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
# UPDATES_LIVE is the one switch for hosting: set it to true once https://clotho.app/appcast.xml is
# published. Until then only --release and --package builds (the ones release.sh ships) get the feed,
# so the user's plain installs never check a feed that isn't there and never show an update error.
UPDATES_LIVE=false
UPDATE_KEYS=""
if ! $DEV && [[ -s Resources/SparklePublicKey ]] && { $UPDATES_LIVE || $RELEASE || $PACKAGE; }; then
  UPDATE_KEYS="<key>SUFeedURL</key><string>https://clotho.app/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < Resources/SparklePublicKey)</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
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
  # Developer ID and notarized when the certificate exists; ad hoc otherwise.
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: .*(TEAMID0000)"; then
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
