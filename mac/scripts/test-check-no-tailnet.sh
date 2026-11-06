#!/bin/bash
# Tests scripts/check-no-tailnet.sh against small executables built here: one with the tailnet shim's
# _ctn_start followed by enough symbols to fill nm's pipe (the case `nm | grep -q` missed), one without,
# and a missing file. Needs a Mac with the Xcode command line tools (cc, nm).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check=$here/check-no-tailnet.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmac-tailnetcheck.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
passed=0 failed=0

# build <name> <with ctn_start: 1 or 0> : an executable with 30000 extra functions whose names sort after
# ctn_start, so nm still has ~1 MB to write once the match is printed.
build() {
  {
    [[ $2 == 1 ]] && echo 'void ctn_start(void) {}'
    for ((i = 0; i < 30000; i++)); do echo "void zz_filler_$i(void) {}"; done
    echo 'int main(void) { return 0; }'
  } > "$tmp/$1.c"
  cc -O0 -o "$tmp/$1" "$tmp/$1.c" || { echo "FAIL: cc couldn't build $1" >&2; exit 1; }
}

# expect <0 or 1> <description> <executable>
expect() {
  local out status
  out=$("$check" "$3" 2>&1); status=$?
  if [[ $status == "$1" ]]; then
    passed=$((passed + 1)); echo "ok: $2"
  else
    failed=$((failed + 1)); echo "FAIL: $2 (exit $status, wanted $1): $out"
  fi
}

build with 1
build without 0
# Show the old guard's failure, so this test keeps covering the reason for the change.
if (set -o pipefail; nm -U "$tmp/with" 2>/dev/null | grep -q ' _ctn_start$'); then
  echo "note: nm | grep -q found the symbol here (no SIGPIPE this run)"
else
  echo "note: nm | grep -q missed the symbol (SIGPIPE under pipefail), the bug the checker avoids"
fi
expect 1 "refuses an executable with _ctn_start" "$tmp/with"
expect 0 "accepts an executable without it" "$tmp/without"
expect 1 "refuses a missing executable" "$tmp/missing"
echo "$passed passed, $failed failed"
[[ $failed == 0 ]]
