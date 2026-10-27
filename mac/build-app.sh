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
set -euo pipefail
cd "$(dirname "$0")"

DEV=false
RELEASE=false
case "${1:-}" in
  --dev) DEV=true ;;
  --release) RELEASE=true ;;
  "") ;;
  *) echo "usage: $0 [--dev | --release]" >&2; exit 2 ;;
esac
if $DEV; then
  NAME="Clotho Dev"
  BUNDLE_ID="app.clotho.desktop.dev"
else
  NAME="Clotho"
  BUNDLE_ID="app.clotho.desktop"
fi

swift build -c release
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clotho "$APP/Contents/MacOS/Clotho"

# clothod ships inside the app: every platform's build in Resources/clothod-dist (installed on remote
# machines over SSH, see ../docs/remote.md), and this Mac's build next to the executable, where Clotho
# installs it from. The builds come fresh from clothod's dist script, so a stale or debug daemon never
# ends up in the app. CLOTHOD_DIST bundles an existing dist/ directory instead of building one.
#
# dist.sh only builds a release for a version newer than clothod/RELEASED, so rebuilding the app
# without a new clothod reuses clothod/dist when it holds that release. A dev app with no such dist
# gets a dev dist of the same version, kept apart in clothod/target/dist-dev so it never replaces
# the release builds.
CLOTHOD_VERSION=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' ../clothod/Cargo.toml)
dist_version() { sed -n 's/.*"version": "\(.*\)".*/\1/p' "$1/manifest.json" 2>/dev/null | head -1; }
if [[ -n "${CLOTHOD_DIST:-}" ]]; then
  DIST="$CLOTHOD_DIST"
elif [[ "$CLOTHOD_VERSION" == "$(cat ../clothod/RELEASED 2>/dev/null)" && "$(dist_version ../clothod/dist)" == "$CLOTHOD_VERSION" ]]; then
  DIST=../clothod/dist
elif $DEV; then
  DIST_DIR=target/dist-dev ../clothod/scripts/dist.sh --dev
  DIST=../clothod/target/dist-dev
else
  ../clothod/scripts/dist.sh
  DIST=../clothod/dist
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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
