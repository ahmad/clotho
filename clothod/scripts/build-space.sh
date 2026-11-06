#!/bin/sh
# The Mac's disk is small (user rule: "Keep the build folder clean"). test-all.sh and dist.sh
# call this before they build and again when they exit, whether they passed or failed:
#
#   build-space.sh check   refuse (exit 1) with less than $MIN_FREE_GIB free here, after first
#                          cleaning (below) if it's low
#   build-space.sh clean   remove what builds leave behind in target/: debug/, the cross
#                          targets' dirs (target/<triple>/), and Go's (target/go, target/net;
#                          below). Kept: target/release (the host build dist.sh ids with),
#                          target/dist-dev (the remote suite's dist), logs, Go's module
#                          downloads, and dist/ (outside target/, never touched).
#
# Only on macOS: Linux machines have the room, and cleaning there would only slow builds.
# CLOTHOD_KEEP_BUILD=1 skips the cleaning (test-all.sh sets it for the dist.sh it runs, and
# cleans once itself at the end).
set -u
cd "$(dirname "$0")/.."
MIN_FREE_GIB=${MIN_FREE_GIB:-20}
[ "$(uname)" = Darwin ] || exit 0

free_gib() { df -k . | awk 'NR == 2 { print int($4 / 1048576) }'; }

clean() {
    [ -n "${CLOTHOD_KEEP_BUILD:-}" ] && return 0
    for d in target/debug target/*-apple-darwin target/*-linux-musl target/*-linux-gnu; do
        [ -d "$d" ] && rm -rf "$d"
    done
    # Go (clothod/net, scripts/toolchain.sh): the builds, the build cache and the unpacked
    # modules. Kept: the downloaded module zips (target/go/mod/cache/download, ~200 MB), so the
    # next build unpacks them offline instead of fetching them again. Module files can be
    # read-only (a go run without -modcacherw), which rm -rf can't remove.
    if [ -d target/go ]; then
        chmod -R u+w target/go 2>/dev/null
        for d in target/go/* target/go/mod/* target/go/mod/cache/*; do
            case $d in target/go/mod | target/go/mod/cache | target/go/mod/cache/download) continue ;; esac
            [ -e "$d" ] && rm -rf "$d"
        done
    fi
    [ -d target/net ] && rm -rf target/net
    echo "build-space: cleaned target/ ($(free_gib) GiB free)"
}

case "${1:-}" in
check)
    if [ "$(free_gib)" -lt "$MIN_FREE_GIB" ]; then
        clean
        if [ "$(free_gib)" -lt "$MIN_FREE_GIB" ]; then
            echo "build-space: only $(free_gib) GiB free here; need $MIN_FREE_GIB. Not building." >&2
            exit 1
        fi
    fi
    ;;
clean) clean ;;
*) echo "usage: build-space.sh check|clean" >&2; exit 2 ;;
esac
