#!/bin/bash
# Usage: scripts/check-no-tailnet.sh <executable>
# Fails unless the executable is readable and doesn't link Clotho's tailnet node (the shim's _ctn_start).
# build-app.sh runs it on every build but CLOTHO_TAILNET=1 --dev; scripts/test-check-no-tailnet.sh tests it.
#
# nm's whole output is read before matching: `nm | grep -q` would stop reading at the match, nm would die
# of SIGPIPE writing the Go runtime's ~28k symbols after it, and under pipefail the check would pass exactly
# when the symbol is there.
set -uo pipefail
bin=${1:?usage: check-no-tailnet.sh <executable>}
if [[ ! -f "$bin" || ! -r "$bin" ]]; then
  echo "error: $bin is missing or unreadable: can't check it for the tailnet node" >&2
  exit 1
fi
if ! syms=$(nm -U "$bin"); then
  echo "error: nm couldn't read $bin: can't check it for the tailnet node" >&2
  exit 1
fi
if [[ $'\n'"$syms"$'\n' == *$' _ctn_start\n'* ]]; then
  echo "error: $bin links the tailnet node, which only CLOTHO_TAILNET=1 --dev builds may; rm -rf .build and build again" >&2
  exit 1
fi
