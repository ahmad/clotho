#!/bin/sh
# The local CI: every clothod test on every platform we have, then a check that nothing was
# left behind. Run from anywhere; exits non-zero if anything failed.
#
#   1. macOS: all crates (unit, VT snapshot round trips, e2e)
#   2. Linux: the e2e suite, cross-built, run on $LINUX_HOST from a temporary dir
#   3. remote: the SSH suite against $REMOTE_HOSTS (a dev dist, not dist/)
#   4. cleanliness: no test instance or /tmp/clt* dir left on any of those machines
#
# Runs on the build Mac (imac: `scripts/clotho-build clothod clothod/scripts/test-all.sh`).
# The remote suite's other Mac is macbook, a laptop that sleeps: hosts in $OPTIONAL_HOSTS that
# don't answer ssh are skipped (said so in the summary) instead of failing the run. Never list
# the build Mac itself as a remote: it has no ssh to itself.
#
# Tests only ever use ephemeral instances in /tmp/clt* dirs; they never touch the default
# (the user's) instance.
set -u
cd "$(dirname "$0")/.."
. scripts/toolchain.sh

LINUX_HOST=${LINUX_HOST:-ahmad@devbox}
REMOTE_HOSTS=${REMOTE_HOSTS:-"ahmad@devbox ahmad@macbook"}
OPTIONAL_HOSTS=${OPTIONAL_HOSTS:-"ahmad@macbook"}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
failed=""
skipped=""
step() { printf '\n=== %s\n' "$*"; }
fail() { failed="$failed\n  - $*"; printf 'FAILED: %s\n' "$*"; }

# The Mac's disk is small: check there's room first, and clean target/ when done, pass or fail
# (scripts/build-space.sh). The dist.sh this runs leaves target/ alone (CLOTHOD_KEEP_BUILD).
scripts/build-space.sh check || exit 1
trap 'scripts/build-space.sh clean' EXIT

step "macOS: cargo test"
if cargo test 2>&1 | tee target/test-all-macos.log | grep -E "^test result|panicked|^error" ; then :; fi
grep -q "FAILED\|panicked\|^error" target/test-all-macos.log && fail "macOS tests (target/test-all-macos.log)"

step "Linux: e2e on $LINUX_HOST"
T=x86_64-unknown-linux-musl
# zigbuild: ring has C code (see .cargo/config.toml).
if cargo zigbuild -q --target $T --bins && e2e=$(cargo zigbuild -q --target $T --tests --message-format=json 2>/dev/null | grep '"name":"e2e"' | sed -n 's/.*"executable":"\([^"]*\)".*/\1/p' | head -1) && [ -n "$e2e" ]; then
    : > target/test-all-linux.log
    if rdir=$($SSH "$LINUX_HOST" 'mktemp -d /tmp/clt-ci.XXXXXX') && [ -n "$rdir" ]; then
        scp -q "target/$T/debug/clothod" "target/$T/debug/clotho" "$e2e" "$LINUX_HOST:$rdir/" &&
            $SSH "$LINUX_HOST" "cd $rdir && CLOTHOD_BIN=\$PWD/clothod CLOTHO_BIN=\$PWD/clotho ./$(basename "$e2e") 2>&1" > target/test-all-linux.log
        grep -E "^test result|panicked" target/test-all-linux.log
        grep -q "^test result: ok. [1-9]" target/test-all-linux.log || fail "Linux e2e on $LINUX_HOST (target/test-all-linux.log)"
        $SSH "$LINUX_HOST" "rm -rf $rdir"
    else
        fail "Linux e2e: can't reach $LINUX_HOST over ssh"
    fi
else
    fail "Linux cross build"
fi

step "dev dist for the remote suite"
# The test builds above are done with: room for the dist's (on the Mac, at least).
scripts/build-space.sh clean
# Never a stale one: the remote suite must test this tree's build or nothing.
rm -rf target/dist-dev
dist_ok=1
CLOTHOD_KEEP_BUILD=1 DIST_DIR=target/dist-dev ./scripts/dist.sh --dev > target/test-all-dist.log 2>&1 || { dist_ok=0; fail "dev dist (target/test-all-dist.log)"; }

for h in $REMOTE_HOSTS; do
    step "remote: $h"
    [ $dist_ok = 1 ] || { fail "remote suite on $h: not run (no dev dist)"; continue; }
    # Unreachable hosts must fail here, not depend on how the suite reports it; optional ones
    # (a sleeping laptop) are skipped, and named in the summary.
    if ! $SSH "$h" true; then
        case " $OPTIONAL_HOSTS " in
        *" $h "*) echo "$h skipped (unreachable)"; skipped="$skipped\n  - $h skipped (unreachable)" ;;
        *) fail "remote suite: can't reach $h over ssh" ;;
        esac
        continue
    fi
    log="target/test-all-remote-$(echo "$h" | tr '@' '_').log"
    CLOTHO_DIST=$PWD/target/dist-dev CLOTHO_TEST_SSH_HOST=$h cargo test -p clotho --test remote > "$log" 2>&1
    grep -E "^test result|panicked" "$log"
    grep -q "^test result: ok. [1-9]" "$log" || fail "remote suite on $h ($log)"
done

step "cleanliness"
checked=""
# Ours: clothod processes serving /tmp/clt* dirs, the dirs themselves ("/tmp/": on macOS /tmp is
# a symlink, which find does not follow without it), and login units of the
# e2e tests (launchd labels / systemd runtime units named clt-test-*).
# A check that couldn't run is UNCHECKED, a failure: never read silence as clean.
# The host build dist.sh leaves in target/release (kept by the cleaning), else the test build.
ps_bin=target/release/clothod
[ -x "$ps_bin" ] || ps_bin=target/debug/clothod
if ps_out=$("$ps_bin" ps); then
    left=$(echo "$ps_out" | grep "/tmp/clt" ; find /tmp/ -maxdepth 1 -name "clt*" 2>/dev/null; launchctl list 2>/dev/null | grep clt-test)
    [ -n "$left" ] && { echo "$left"; fail "leftovers on this Mac"; } || echo "this Mac: clean"
else
    echo "this Mac: UNCHECKED"; fail "cleanliness unchecked on this Mac (clothod ps failed)"
fi
for h in $LINUX_HOST $REMOTE_HOSTS; do
    case " $checked " in *" $h "*) continue ;; esac
    # A skipped host ran nothing, so there is nothing of ours to check.
    case "$skipped" in *" $h skipped"*) echo "$h: skipped (unreachable)"; continue ;; esac
    checked="$checked $h"
    # The marker proves the remote commands ran; ssh failing leaves it out.
    out=$($SSH "$h" 'ps -eo pid=,args= 2>/dev/null | grep "[c]lothod .*--runtime-dir /tmp/clt"; find /tmp/ -maxdepth 1 -name "clt*" 2>/dev/null; launchctl list 2>/dev/null | grep clt-test; ls /run/user/$(id -u)/systemd/user 2>/dev/null | grep clt-test; echo CLOTHO-CHECKED')
    case "$out" in
    *CLOTHO-CHECKED*) ;;
    *) echo "$h: UNCHECKED"; fail "cleanliness unchecked on $h (ssh failed)"; continue ;;
    esac
    left=$(echo "$out" | grep -v '^CLOTHO-CHECKED$')
    [ -n "$left" ] && { echo "$left"; fail "leftovers on $h"; } || echo "$h: clean"
done

[ -n "$skipped" ] && printf '\nSKIPPED:%b\n' "$skipped"
if [ -n "$failed" ]; then
    printf '\nFAILED:%b\n' "$failed"
    exit 1
fi
printf '\nALL GREEN\n'
