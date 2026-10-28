#!/bin/bash
# Picks the clothod dist the app bundles and prints its directory. build-app.sh calls it.
#
#   clothod-dist.sh          the user's app (plain, --release, --package): only a released dist, one
#                            whose manifest version is clothod/RELEASED. It never builds one: releases
#                            are clothod's to make (clothod/scripts/dist.sh, which records RELEASED).
#                            A dev dist (target/dist-dev, or any dir under clothod/target) is refused,
#                            so an unreleased daemon can't reach the user's machines through the app's
#                            "Update clothod" offer.
#   clothod-dist.sh --dev    Clotho Dev: the released dist when it is for the current version, else a
#                            same-version dev dist built into clothod/target/dist-dev.
#   clothod-dist.sh --check  as the plain mode, but only reports (a dry run).
#
# CLOTHOD_DIST names a dist directory to use instead; the plain mode still checks it. CLOTHOD_ROOT
# points at another clothod checkout (tests).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
root=${CLOTHOD_ROOT:-$here/../../clothod}
root=$(cd "$root" && pwd -P)
mode=${1:-}

fail() { echo "clothod-dist: $*" >&2; exit 1; }
field() { sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$2" 2>/dev/null | head -1; }

cargo_version=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$root/Cargo.toml")
released=$(cat "$root/RELEASED" 2>/dev/null || true)

if [[ "$mode" == "--dev" ]]; then
  if [[ -n "${CLOTHOD_DIST:-}" ]]; then echo "$CLOTHOD_DIST"; exit 0; fi
  if [[ "$cargo_version" == "$released" && "$(field version "$root/dist/manifest.json")" == "$released" ]]; then
    echo "$root/dist"; exit 0
  fi
  (cd "$root" && DIST_DIR=target/dist-dev scripts/dist.sh --dev >&2)
  echo "$root/target/dist-dev"
  exit 0
fi
[[ -z "$mode" || "$mode" == "--check" ]] || fail "usage: $0 [--dev | --check]"

[[ -n "$released" ]] || fail "no clothod/RELEASED: there is no released clothod to bundle."
dist=${CLOTHOD_DIST:-$root/dist}
[[ -d "$dist" ]] || fail "no dist at $dist. The app bundles only a released clothod ($released): build it with clothod/scripts/dist.sh on the Mac, or use --dev for a test build."
dist=$(cd "$dist" && pwd -P)
case "$dist/" in
  "$root/target/"*|*/dist-dev/*) fail "$dist is a dev dist; the app bundles only a released clothod ($released). Use --dev for a test build." ;;
esac
manifest="$dist/manifest.json"
[[ -f "$manifest" ]] || fail "$dist has no manifest.json"
version=$(field version "$manifest")
[[ "$version" == "$released" ]] || fail "$dist holds clothod $version, but the last release is $released (clothod/RELEASED). Only a released dist is bundled: build the release with clothod/scripts/dist.sh, or use --dev for a test build."
# Every build the manifest lists is there, and carries this version.
builds=0
while IFS= read -r file; do
  [[ -f "$dist/$file" ]] || fail "$dist lacks $file, which manifest.json lists"
  builds=$((builds + 1))
done < <(sed -n 's/.*"file": "\([^"]*\)".*/\1/p' "$manifest")
(( builds > 0 )) || fail "$manifest lists no builds"
if grep -o '"id": "[^"]*"' "$manifest" | grep -v "\"id\": \"$released-" >/dev/null; then
  fail "$manifest has build ids that aren't for $released"
fi
if [[ "$mode" == "--check" ]]; then
  echo "clothod-dist: would bundle $dist: released clothod $released, $builds builds" >&2
  grep -o '"id": "[^"]*"' "$manifest" | sed 's/"id": /  /' >&2
fi
echo "$dist"
