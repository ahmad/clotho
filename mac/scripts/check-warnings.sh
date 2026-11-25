#!/bin/bash
# The Mac app's own sources build with no compiler warnings. A clean release build of the Clotho target in
# a scratch build folder (so every file is compiled, and the usual .build is left alone); it fails if any
# "warning:" names a file under mac/Sources. Warnings from dependencies (SwiftTerm) aren't ours.
#
# Usage: mac/scripts/check-warnings.sh        (on a Mac; through scripts/clotho-build mac … from the dev box)
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d /tmp/cmac-warnings.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
log=$scratch/build.log
if ! swift build --disable-keychain -c release --product Clotho --scratch-path "$scratch/build" >"$log" 2>&1; then
  tail -40 "$log"
  echo "check-warnings: the build failed" >&2
  exit 1
fi
# One line per warning: the same one is printed again for each file that includes it.
warnings=$(grep -E "/mac/Sources/[^:]+:[0-9]+:[0-9]+: .*warning:" "$log" | sed $'s/\x1b\\[[0-9;]*m//g' | sort -u || true)
count=$(printf '%s' "$warnings" | grep -c . || true)
if [ "$count" -gt 0 ]; then
  printf '%s\n' "$warnings"
  echo "check-warnings: $count warning(s) in mac/Sources" >&2
  exit 1
fi
echo "check-warnings: 0 warnings in mac/Sources"
