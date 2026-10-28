#!/bin/bash
# Archives Clotho (Release, team TEAMID0000) and uploads it to App Store Connect for TestFlight. Runs on the
# Mac, in its own login session or over SSH (scripts/testflight-remote on devbox does the latter).
#
# Usage: ios/scripts/testflight.sh [--dry-run]
#   --dry-run   check, archive and stop: nothing is exported or uploaded.
# Environment:
#   ASC_KEY_ID, ASC_ISSUER_ID   the App Store Connect API key (required); the key itself is
#                               ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8 on the Mac.
#   EXPECT_SOURCES_SHA          optional: refuse unless ios/scripts/sources-sha.sh prints exactly this.
#   BUILD_NUMBER                optional: default the UTC time, YYYYMMDDHHMM.
#
# Before building, it refuses (exit 2) unless the bundled clothod dist is the release in clothod/RELEASED and
# every binary's build id matches its manifest entry, and, given EXPECT_SOURCES_SHA, the sources match.
# Logs go to ~/Builds/testflight/Clotho-<build>/. "Uploaded Clotho build <n>" is printed only after the
# export reported success; anything else exits non-zero.
set -euo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

IOS=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$IOS/.." && pwd)
cd "$IOS"
DIST=$ROOT/clothod/dist

fail() { echo "testflight: $*" >&2; exit 2; }

# MARK: Checks, before anything is built

[ -n "${ASC_KEY_ID:-}" ] || fail "ASC_KEY_ID is not set"
[ -n "${ASC_ISSUER_ID:-}" ] || fail "ASC_ISSUER_ID is not set"
KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
[ -f "$KEY_PATH" ] || fail "no API key at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8"

# clothod/RELEASED is one line, the released version (e.g. 0.1.15); anything else is refused, not guessed at.
[ -f "$ROOT/clothod/RELEASED" ] || fail "no clothod/RELEASED"
lines=$(grep -c . "$ROOT/clothod/RELEASED" || true)
[ "$lines" = 1 ] || fail "clothod/RELEASED must be one line, the released version; it has $lines"
RELEASED=$(grep . "$ROOT/clothod/RELEASED" | tr -d '[:space:]')
printf '%s' "$RELEASED" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "clothod/RELEASED isn't a version: $RELEASED"
[ -f "$DIST/manifest.json" ] || fail "no clothod dist at $DIST"
VERSION=$(jq -r .version "$DIST/manifest.json")
[ "$VERSION" = "$RELEASED" ] || fail "the clothod dist is $VERSION, but clothod/RELEASED says $RELEASED"
ok=1
for platform in $(jq -r '.builds | keys[]' "$DIST/manifest.json"); do
  file=$(jq -r ".builds[\"$platform\"].file" "$DIST/manifest.json")
  want=$(jq -r ".builds[\"$platform\"].id" "$DIST/manifest.json")
  got=$("$DIST/macos-aarch64/clothod" build-id "$DIST/$file" 2>/dev/null || echo "?")
  case "$want" in "$RELEASED"-*) ;; *) echo "testflight: $platform is listed as $want, not a $RELEASED build" >&2; ok=0 ;; esac
  [ "$got" = "$want" ] || { echo "testflight: $platform binary is $got, the manifest says $want" >&2; ok=0; }
done
[ "$ok" = 1 ] || fail "the clothod dist doesn't match its manifest"
SOURCES=$("$IOS/scripts/sources-sha.sh" "$ROOT")
if [ -n "${EXPECT_SOURCES_SHA:-}" ] && [ "$SOURCES" != "$EXPECT_SOURCES_SHA" ]; then
  fail "sources are $SOURCES, expected $EXPECT_SOURCES_SHA"
fi

BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
OUT=$HOME/Builds/testflight/Clotho-$BUILD_NUMBER
mkdir -p "$OUT"
echo "==> Clotho build $BUILD_NUMBER, clothod $RELEASED, sources $SOURCES (logs: $OUT)"

# MARK: Signing over SSH

# Over SSH the login keychain is locked; the user keeps its password in ~/.keychain_pw. Never echoed.
if [ -f "$HOME/.keychain_pw" ]; then
  security unlock-keychain -p "$(cat "$HOME/.keychain_pw")" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 \
    || fail "couldn't unlock the login keychain"
fi
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# MARK: Archive

# Push alerts are set up in the developer account (Push capability, the extension id, the Keychain group).
# The packed clothod builds land here at build time; xcodegen needs the folder to exist (it is gitignored).
mkdir -p build-resources/dist
# TestFlight always bundles the released clothod, never a dev dist (build.sh's CLOTHOD_DIST).
unset CLOTHOD_DIST
PUSH=YES xcodegen generate -q
# Packed before xcodebuild plans its resource copy (see build.sh), so the archive has the current release.
python3 scripts/pack-dist.py "$DIST" build-resources/dist
ARCHIVE=$OUT/Clotho.xcarchive
echo "==> archive"
if ! xcodebuild -project Clotho.xcodeproj -scheme Clotho -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "${AUTH[@]}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > "$OUT/archive.log" 2>&1; then
  tail -30 "$OUT/archive.log" >&2
  echo "testflight: archive failed (log: $OUT/archive.log)" >&2
  exit 1
fi
grep -q '\*\* ARCHIVE SUCCEEDED \*\*' "$OUT/archive.log" || { echo "testflight: no ARCHIVE SUCCEEDED in the log" >&2; exit 1; }
BUNDLED=$(jq -r .version "$ARCHIVE/Products/Applications/Clotho.app/dist/manifest.json" 2>/dev/null || echo "?")
[ "$BUNDLED" = "$RELEASED" ] || { echo "testflight: the archive bundles clothod $BUNDLED, not $RELEASED" >&2; exit 1; }
echo "==> archived build $BUILD_NUMBER with clothod $BUNDLED: $ARCHIVE"

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: not exported or uploaded."
  exit 0
fi

# MARK: Export and upload

export_once() {
  rm -rf "$OUT/export"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$OUT/export" "${AUTH[@]}" > "$OUT/export-$1.log" 2>&1
}
echo "==> export and upload"
attempt=1
until export_once "$attempt"; do
  # App Store Connect answers 500 now and then while Xcode fetches the app record ("Error Downloading
  # App Information"); that alone gets one more try a minute later. Anything else is a real failure.
  if [ "$attempt" = 1 ] && grep -q 'Error Downloading App Information' "$OUT/export-1.log"; then
    echo "==> App Store Connect couldn't send the app record; trying again in 60 s"
    sleep 60
    attempt=2
    continue
  fi
  tail -30 "$OUT/export-$attempt.log" >&2
  echo "testflight: export failed (log: $OUT/export-$attempt.log)" >&2
  exit 1
done
grep -q '\*\* EXPORT SUCCEEDED \*\*' "$OUT/export-$attempt.log" \
  || { echo "testflight: no EXPORT SUCCEEDED in $OUT/export-$attempt.log" >&2; exit 1; }
echo "Uploaded Clotho build $BUILD_NUMBER"
