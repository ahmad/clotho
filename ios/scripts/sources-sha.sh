#!/bin/bash
# Prints the SHA-256 of every source that goes into the app and its extensions: ios/Clotho, ios/ClothoNotify,
# ios/ClothoWidget, ClothoKit/Sources, ios/project.yml, ios/push.yml, ios/widget.yml, ios/liveactivity.yml and
# ClothoKit/Package.swift. The same on the dev box (from a git
# checkout) and on the Mac (in the clotho-mac mirror), so testflight.sh can refuse to build anything else
# (EXPECT_SOURCES_SHA). The extensions' Info.plists are left out: xcodegen writes them from push.yml and
# widget.yml (hashed).
# Usage: ios/scripts/sources-sha.sh [repo root]   (default: the repo this script is in)
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$root"
if command -v sha256sum >/dev/null; then sum() { sha256sum; }; files() { xargs sha256sum; }
else sum() { shasum -a 256; }; files() { xargs shasum -a 256; }; fi
LC_ALL=C find ios/Clotho ios/ClothoNotify ios/ClothoWidget ClothoKit/Sources ios/project.yml ios/push.yml ios/widget.yml ios/liveactivity.yml \
  ClothoKit/Package.swift -type f ! -name .DS_Store ! -path ios/ClothoNotify/Info.plist ! -path ios/ClothoWidget/Info.plist | LC_ALL=C sort | files | sum | cut -c1-64
