#!/bin/sh
# The local CI: every clothod test on every platform we have, then a check that nothing was
# left behind. Run from anywhere; exits non-zero if anything failed.
#
#   1. macOS: all crates (unit, VT snapshot round trips, e2e)
#   2. Linux: the e2e suite, cross-built, run on $LINUX_HOST from a temporary dir
#   3. remote: the SSH suite against $REMOTE_HOSTS (a dev dist, not dist/)
#   4. cleanliness: no test instance or /tmp/clt* dir left on any of those machines
#
# Tests only ever use ephemeral instances in /tmp/clt* dirs; they never touch the default
# (the user's) instance.
set -u
cd "$(dirname "$0")/.."

LINUX_HOST=${LINUX_HOST:-ahmad@devbox}
REMOTE_HOSTS=${REMOTE_HOSTS:-"ahmad@devbox macbook@imac"}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
failed=""
step() { printf '\n=== %s\n' "$*"; }
fail() { failed="$failed\n  - $*"; printf 'FAILED: %s\n' "$*"; }

step "macOS: cargo test"
if cargo test 2>&1 | tee target/test-all-macos.log | grep -E "^test result|panicked|^error" ; then :; fi
grep -q "FAILED\|panicked\|^error" target/test-all-macos.log && fail "macOS tests (target/test-all-macos.log)"

step "Linux: e2e on $LINUX_HOST"
T=x86_64-unknown-linux-musl
# zigbuild: ring has C code (see .cargo/config.toml).
if cargo zigbuild -q --target $T --bins && e2e=$(cargo zigbuild -q --target $T --tests --message-format=json 2>/dev/null | grep '"name":"e2e"' | sed -n 's/.*"executable":"\([^"]*\)".*/\1/p' | head -1) && [ -n "$e2e" ]; then
    rdir=$($SSH "$LINUX_HOST" 'mktemp -d /tmp/clt-ci.XXXXXX')
    scp -q "target/$T/debug/clothod" "target/$T/debug/clotho" "$e2e" "$LINUX_HOST:$rdir/" &&
        $SSH "$LINUX_HOST" "cd $rdir && CLOTHOD_BIN=\$PWD/clothod CLOTHO_BIN=\$PWD/clotho ./$(basename "$e2e") 2>&1" > target/test-all-linux.log
    grep -E "^test result|panicked" target/test-all-linux.log
    grep -q "^test result: ok" target/test-all-linux.log || fail "Linux e2e on $LINUX_HOST (target/test-all-linux.log)"
    $SSH "$LINUX_HOST" "rm -rf $rdir"
else
    fail "Linux cross build"
fi

step "dev dist for the remote suite"
DIST_DIR=target/dist-dev ./scripts/dist.sh --dev > target/test-all-dist.log 2>&1 || fail "dev dist (target/test-all-dist.log)"

for h in $REMOTE_HOSTS; do
    step "remote: $h"
    log="target/test-all-remote-$(echo "$h" | tr '@' '_').log"
    CLOTHO_DIST=$PWD/target/dist-dev CLOTHO_TEST_SSH_HOST=$h cargo test -p clotho --test remote > "$log" 2>&1
    grep -E "^test result|panicked" "$log"
    grep -q "^test result: ok. [1-9]" "$log" || fail "remote suite on $h ($log)"
done

step "cleanliness"
checked=""
# Ours: clothod processes serving /tmp/clt* dirs, and the dirs themselves.
left=$(target/debug/clothod ps | grep "/tmp/clt" ; find /tmp -maxdepth 1 -name "clt*" 2>/dev/null)
[ -n "$left" ] && { echo "$left"; fail "leftovers on this Mac"; } || echo "this Mac: clean"
for h in $LINUX_HOST $REMOTE_HOSTS; do
    case " $checked " in *" $h "*) continue ;; esac
    checked="$checked $h"
    left=$($SSH "$h" 'ps -eo pid=,args= 2>/dev/null | grep "[c]lothod .*--runtime-dir /tmp/clt"; find /tmp -maxdepth 1 -name "clt*" 2>/dev/null')
    [ -n "$left" ] && { echo "$left"; fail "leftovers on $h"; } || echo "$h: clean"
done

if [ -n "$failed" ]; then
    printf '\nFAILED:%b\n' "$failed"
    exit 1
fi
printf '\nALL GREEN\n'
