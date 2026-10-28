#!/bin/sh
# The Mac's disk is small (user rule: "Keep the build folder clean"). test-all.sh and dist.sh
# call this before they build and again when they exit, whether they passed or failed:
#
#   build-space.sh check   refuse (exit 1) with less than $MIN_FREE_GIB free here, after first
#                          cleaning (below) if it's low
#   build-space.sh clean   remove what builds leave behind in target/: debug/ and the cross
#                          targets' dirs (target/<triple>/). Kept: target/release (the host
#                          build dist.sh ids with), target/dist-dev (the remote suite's dist),
#                          logs, and dist/ (outside target/, never touched).
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
