#!/bin/bash
# Usage: scripts/check-no-tailnet.sh <executable>...
# Fails unless every executable is readable and doesn't link Clotho's tailnet node (the shim's _ctn_start).
# build.sh runs it on the app of every build without CLOTHO_TAILNET=1 and on the extensions of every build;
# testflight.sh on the archived app and extensions; scripts/tailnet-size.sh tests both outcomes.
#
# nm's whole output is read before matching: `nm | grep -q` would stop reading at the match, nm would die
# of SIGPIPE writing the Go runtime's ~28k symbols after it, and under pipefail the check would pass exactly
# when the symbol is there (mac/scripts/check-no-tailnet.sh, the same check).
set -uo pipefail
[ $# -gt 0 ] || { echo "usage: check-no-tailnet.sh <executable>..." >&2; exit 64; }
for bin in "$@"; do
  if [[ ! -f "$bin" || ! -r "$bin" ]]; then
    echo "error: $bin is missing or unreadable: can't check it for the tailnet node" >&2
    exit 1
  fi
  if ! syms=$(nm -U "$bin"); then
    echo "error: nm couldn't read $bin: can't check it for the tailnet node" >&2
    exit 1
  fi
  if [[ $'\n'"$syms"$'\n' == *$' _ctn_start\n'* ]]; then
    echo "error: $bin links the tailnet node, which only CLOTHO_TAILNET=1 builds of the app may (never an extension, never TestFlight)" >&2
    exit 1
  fi
done
