#!/bin/zsh
# Makes a Clotho release for in-app updates (Sparkle): builds and signs the app (build-app.sh --package:
# Developer ID and notarized when the certificate is there), zips it, signs the zip with the EdDSA key in
# this Mac's keychain (Sparkle's sign_update), and writes the appcast with the new entry on top.
#
#   scripts/release.sh [notes.html]
#
# Run it at the Mac itself: sign_update reads the private key from the login keychain, which is locked
# over SSH. The key never goes anywhere else (README, "Releases"). Output, in build/release/:
#   Clotho-<version>-<build>.zip   upload to $CLOTHO_DOWNLOADS (default https://clotho.app/downloads/)
#   appcast.xml                    replaces https://clotho.app/appcast.xml
#
# The appcast starts from the published one ($CLOTHO_APPCAST_IN, a file or URL, default the live feed),
# so older entries stay. VERSION sets the version; CLOTHO_VERSION and CLOTHO_BUILD override it and the
# build number (build-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

FEED=https://clotho.app/appcast.xml
DOWNLOADS=${CLOTHO_DOWNLOADS:-https://clotho.app/downloads/}
NOTES=${1:-}
OUT=build/release
die() { print -u2 "release: $*"; exit 1; }

[[ -s Resources/SparklePublicKey ]] || die "no Resources/SparklePublicKey. Make the key pair first (README, \"Releases\")."
[[ -z "$NOTES" || -f "$NOTES" ]] || die "no notes file at $NOTES"
TOOLS=$(scripts/sparkle-tools.sh)

# The keychain's key must be the one the app trusts, or every update would be refused.
KEYCHAIN_PUBLIC=$("$TOOLS/generate_keys" -p 2>/dev/null) || die "no Sparkle key in this Mac's keychain (or the keychain is locked: run this at the Mac, not over SSH)"
[[ "$KEYCHAIN_PUBLIC" == "$(tr -d '[:space:]' < Resources/SparklePublicKey)" ]] \
  || die "the keychain's Sparkle key doesn't match Resources/SparklePublicKey"

export CLOTHO_BUILD=${CLOTHO_BUILD:-$(date -u +%Y%m%d%H%M)}
./build-app.sh --package
APP=build/Clotho.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
MINIMUM=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")

mkdir -p "$OUT"
ZIP="$OUT/Clotho-$VERSION-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE=$("$TOOLS/sign_update" "$ZIP") || die "sign_update failed"
[[ "$SIGNATURE" == *edSignature=* ]] || die "sign_update printed no signature: $SIGNATURE"

CURRENT="$OUT/appcast-current.xml"
SOURCE=${CLOTHO_APPCAST_IN:-$FEED}
if [[ -f "$SOURCE" ]]; then
  cp "$SOURCE" "$CURRENT"
elif ! curl -fsSL -o "$CURRENT" "$SOURCE" 2>/dev/null; then
  print "release: no appcast at $SOURCE yet, starting a new one"
  rm -f "$CURRENT"
fi

/usr/bin/python3 - "$CURRENT" "$OUT/appcast.xml" "$VERSION" "$BUILD" "$MINIMUM" "$DOWNLOADS${ZIP:t}" "$SIGNATURE" "$NOTES" <<'PY'
import os, re, sys, email.utils
current, out, version, build, minimum, url, signature, notes = sys.argv[1:]
item_notes = open(notes).read() if notes else f"<p>Clotho {version}.</p>"
if os.path.exists(current):
    feed = open(current).read()
    builds = [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", feed)]
    if builds and int(build) <= max(builds):
        sys.exit(f"release: build {build} isn't newer than {max(builds)}, the newest in the appcast")
else:
    feed = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Clotho</title>
    <link>https://clotho.app/appcast.xml</link>
    <description>Updates for Clotho for Mac</description>
    <language>en</language>
  </channel>
</rss>
"""
item = f"""    <item>
      <title>Clotho {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <description><![CDATA[{item_notes}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature.strip()}/>
    </item>
"""
# Newest first: right after the channel's own elements, before any other item.
at = feed.find("    <item>")
if at < 0:
    at = feed.find("  </channel>")
open(out, "w").write(feed[:at] + item + feed[at:])
PY
rm -f "$CURRENT"
xmllint --noout "$OUT/appcast.xml" || die "the appcast isn't well-formed XML"
print "release: Clotho $VERSION (build $BUILD)"
print "  upload  $ZIP  →  $DOWNLOADS${ZIP:t}"
print "  publish $OUT/appcast.xml  →  $FEED"
