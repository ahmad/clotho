#!/bin/zsh
# Signs a built Clotho.app with Developer ID (hardened runtime, secure timestamp), notarizes it with
# notarytool, and staples the ticket. build-app.sh --release runs this before installing; it can also
# be run on its own: scripts/notarize.sh build/Clotho.app
#
# Needs, on this Mac (see mac/README.md, "Notarized builds"), in the keychain scripts/keychain.sh picks
# (the build keychain on the release build host, else the login keychain), which it unlocks:
#   - a "Developer ID Application: … (TEAMID0000)" identity
#   - notarytool credentials stored as the keychain profile below (xcrun notarytool store-credentials)
#   - a clothod dist whose macOS builds are already Developer ID signed. clothod's build ids hash the
#     whole file, so the bundled clothod is never re-signed here: that would break the ids in its
#     manifest and make installed daemons look like a different build.
#
# Environment: CLOTHO_SIGN_IDENTITY (default: the team's Developer ID Application identity),
# CLOTHO_NOTARY_PROFILE (default: clotho-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=TEAMID0000
PROFILE=${CLOTHO_NOTARY_PROFILE:-clotho-notary}
APP=${1:-build/Clotho.app}
ENTITLEMENTS=Resources/Clotho.entitlements

die() { print -u2 "notarize: $*"; exit 1; }
source scripts/keychain.sh
clotho_unlock_keychain || die "the signing keychain isn't usable"

[[ -d "$APP" ]] || die "no app at $APP (build it first)"

if [[ -n "${CLOTHO_SIGN_IDENTITY:-}" ]]; then
  IDENTITY=$CLOTHO_SIGN_IDENTITY
else
  IDENTITY=$(security find-identity -v -p codesigning "$CLOTHO_KEYCHAIN" | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\".*/\1/p" | head -1)
  [[ -n "$IDENTITY" ]] || die "no \"Developer ID Application: … ($TEAM)\" identity in $CLOTHO_KEYCHAIN. Create one in Xcode › Settings › Accounts › Manage Certificates, or set CLOTHO_SIGN_IDENTITY."
fi
print "notarize: signing with $IDENTITY (keychain ${CLOTHO_KEYCHAIN:t})"

# Sparkle's pieces are signed again with this identity, innermost first (Sparkle's own signature is
# another team's, which the hardened runtime's library validation would refuse).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for nested in Versions/B/Autoupdate Versions/B/Updater.app ""; do
    codesign --force --options runtime --timestamp --keychain "$CLOTHO_KEYCHAIN" --sign "$IDENTITY" "$SPARKLE/$nested"
  done
fi

# Every Mach-O inside the app must already carry a Developer ID signature with hardened runtime,
# except the app's own executable, which is signed below.
is_macho() { file -b "$1" | grep -q Mach-O; }
check_nested() {
  local info
  info=$(codesign -dvv "$1" 2>&1) || die "$1 isn't signed"
  print -r -- "$info" | grep -q "Authority=Developer ID Application: .*($TEAM)" \
    || die "$1 isn't Developer ID signed. Build clothod's dist with Developer ID signing first (clothod/scripts/dist.sh)."
  print -r -- "$info" | grep -q "flags=.*runtime" || die "$1 is signed without the hardened runtime"
}
while IFS= read -r -d '' f; do
  [[ "$f" == "$APP/Contents/MacOS/Clotho" ]] && continue
  is_macho "$f" && check_nested "$f"
done < <(find "$APP/Contents" -type f -print0)

# The app: hardened runtime, timestamp, and its entitlements (none needed today; see the file).
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --keychain "$CLOTHO_KEYCHAIN" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# Notarize: Apple scans a zip of the app; --wait returns once it's decided.
ZIP=$(mktemp -d)/Clotho.zip
ditto -c -k --keepParent "$APP" "$ZIP"
print "notarize: submitting (profile $PROFILE)…"
# The build host's profile is in its build keychain. Elsewhere notarytool finds the profile itself (on
# macbook it isn't in login.keychain-db, so naming that keychain would hide it).
NOTARY=(--keychain-profile "$PROFILE")
$CLOTHO_BUILD_HOST && NOTARY+=(--keychain "$CLOTHO_KEYCHAIN")
OUT=$(xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait --output-format plist) \
  || die "notarytool submit failed. Check the profile with: xcrun notarytool history ${NOTARY[*]}"
ID=$(print -r -- "$OUT" | plutil -extract id raw -o - -)
STATUS=$(print -r -- "$OUT" | plutil -extract status raw -o - -)
rm -rf "$(dirname "$ZIP")"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$ID" "${NOTARY[@]}" >&2 || true
  die "notarization $STATUS (submission $ID)"
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
print "notarize: $APP is signed, notarized and stapled (submission $ID)"
