#!/bin/zsh
# Shuts down and deletes every clothod this repo's tests start, then shows what clothod still runs on each
# machine. Run after any test session, pass or fail (build.sh test runs it). Touches only the iOS test
# instances:
#   Mac: the "Local Mac (dev)" daemon (/tmp/cki-ios, binary /tmp/cki-ios-bin), the dev install dirs the
#        SSH tests use against the local test sshd, that sshd, and the offline test tailnet
#        (scripts/tailnet-test-net.sh: testctl and the test peer in /tmp/cki-tailnet)
#   remote machines named in /tmp/clotho-ios-sshtest/{host,ui-host}: the dev install dirs only
set -u
T=/tmp/clotho-ios-sshtest

# Runs under sh on each machine (fed on stdin, so the login shell doesn't matter). Shuts down the dev-dir
# clothod, waits up to 10 s for it to exit (the holder goes a moment after serve), deletes its dirs, and
# lists what's left.
read -r -d '' CLEANUP <<'SH'
rt=/tmp/cki-ios-dev-$(id -u)
# Builds before the rename ran it in /tmp/clothod-ios-dev-<uid>; those go too.
old=/tmp/clothod-ios-dev-$(id -u)
for b in "$HOME"/.local/share/clotho-ios-dev/bin/*/clothod; do
  for r in "$rt" "$old"; do [ -x "$b" ] && CLOTHOD_RUNTIME_DIR=$r "$b" shutdown >/dev/null 2>&1; done
done
if [ "${CKI:-}" = 1 ] && [ -x /tmp/cki-ios-bin/clothod ]; then
  /tmp/cki-ios-bin/clothod shutdown --runtime-dir /tmp/cki-ios >/dev/null 2>&1
fi
# Every running clothod (an executable named clothod, whose path may contain spaces).
all() { ps -eo pid,args | grep -E '/clothod( |$)' | grep -v -E 'grep|sh -s'; }
mine() { all | grep -E 'clotho-ios-dev|clothod-ios-dev|cki-ios'; }
# An install into the dev dirs whose upload never finished (its connection dropped mid-transfer)
# waits on stdin forever; end it.
ps -eo pid,args | grep 'clothod-install' | grep 'clotho-ios-dev/bin' | grep -v -E 'grep|sh -s' \
  | while read -r pid _; do kill "$pid" 2>/dev/null && echo "ended stuck dev install $pid"; done
i=0
while [ $i -lt 20 ] && mine >/dev/null; do sleep 0.5; i=$((i + 1)); done
rm -rf "$HOME/.local/share/clotho-ios-dev" "$rt" "$old"
[ "${CKI:-}" = 1 ] && rm -rf /tmp/cki-ios /tmp/cki-ios-bin
if mine; then echo "!! iOS test daemons still running"; else echo "no iOS test daemons"; fi
echo "all clothod:"
all
SH

echo "== Mac"
# The test peer forwards to the sshd: it goes first.
[ "$(uname)" = Darwin ] && "$(dirname "$0")/tailnet-test-net.sh" stop
[ -f $T/sshd.pid ] && "$(dirname "$0")/ssh-test-server.sh" stop
print -r -- "$CLEANUP" | CKI=1 sh -s

# Keep ~/Builds small (CLAUDE.md): the code index, the old in-tree archive, and every test result but the
# newest (kept so a failure can still be looked at). Paths are under this checkout's ios/build only; the
# build cache (Build/, SourcePackages/) stays for the next run.
build="$(cd "$(dirname "$0")/.." && pwd)/build"
if [ -d "$build" ]; then
  rm -rf "$build/Index.noindex" "$build/Clotho.xcarchive" "$build/export"
  if [ -d "$build/Logs/Test" ]; then
    ls -1t "$build/Logs/Test" | grep '\.xcresult$' | tail -n +2 | while read -r r; do rm -rf "$build/Logs/Test/$r"; done
  fi
fi
free=$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$free" ]; then
  if [ "$free" -lt 20 ]; then echo "!! only ${free} GiB free on this Mac (keep at least 20)"; else echo "${free} GiB free"; fi
fi

hosts=()
[ -f $T/ui-host ] && hosts+=("$(cat $T/ui-host)")
if [ -f $T/host ] && [ "$(cat $T/host)" != 127.0.0.1 ]; then hosts+=("$(cat $T/user 2>/dev/null)@$(cat $T/host)"); fi
for h in ${(u)hosts}; do
  echo "== $h"
  print -r -- "$CLEANUP" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" sh -s
done
