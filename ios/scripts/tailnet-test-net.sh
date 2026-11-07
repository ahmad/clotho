#!/bin/bash
# The offline test tailnet for the iOS tailnet tests (CLOTHO_TAILNET=1 ./build.sh test). Runs on the Mac.
#
#   scripts/tailnet-test-net.sh start   # build and start everything, write what the tests read
#   scripts/tailnet-test-net.sh stop    # stop everything and remove /tmp/cki-tailnet (idempotent)
#
# start runs, all on 127.0.0.1 and all in /tmp/cki-tailnet:
#   - clothod's testctl twice (clothod/net/README.md): one that signs every node in, and one with
#     --require-auth, whose nodes sign in by a GET of their AuthURL (as a browser visit would);
#   - ClothoKit/Tailnet's tailnet-testpeer on the open one, as cki-testpeer, forwarding its tailnet port 22 to
#     the throwaway sshd on 127.0.0.1:2222 (scripts/ssh-test-server.sh, which build.sh starts first).
# It writes control_url, auth_control_url and peer_ip there for the tests. Nothing joins a real tailnet or
# talks to Tailscale: testctl is the only control server, and the test nodes refuse any non-loopback one.
#
# Every process runs from a copy in /tmp/cki-tailnet/bin, so `pkill -f /tmp/cki-tailnet/` finds them all and
# nothing else. They read stdin from a FIFO that one holder process keeps open: killing the holder closes
# their stdin, and each exits on that EOF (--exit-with-stdin; the test peer always does).
set -uo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
D=/tmp/cki-tailnet

stop() {
  if [ -f $D/holder.pid ]; then kill "$(cat $D/holder.pid)" 2>/dev/null || true; fi
  local i=0
  while [ $i -lt 6 ] && pgrep -f "$D/" >/dev/null; do sleep 0.5; i=$((i + 1)); done
  pkill -f "$D/" 2>/dev/null || true
  sleep 0.5
  pkill -9 -f "$D/" 2>/dev/null || true
  rm -rf $D
  if left=$(pgrep -fl "$D/"); then
    echo "!! tailnet test processes left: $left"
    return 1
  fi
  echo "no tailnet test processes"
}

fail() {
  echo "tailnet-test-net: $*" >&2
  for f in $D/*.log; do [ -f "$f" ] && { echo "--- $f" >&2; tail -20 "$f" >&2; }; done
  stop >&2
  exit 1
}

# Waits up to $2 seconds for `$3=` in file $1 and prints its value.
await() {
  local i=0 v
  while [ $i -lt $(($2 * 4)) ]; do
    v=$(sed -n "s/^$3=//p" "$1" 2>/dev/null | head -1)
    [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

case ${1:-} in
  stop) stop; exit ;;
  start) ;;
  *) echo "usage: $0 start|stop" >&2; exit 64 ;;
esac
[ "$(uname)" = Darwin ] || { echo "tailnet-test-net: needs a Mac" >&2; exit 1; }
stop >/dev/null || true

case "$(uname -m)" in arm64) plat=macos-aarch64 ;; *) plat=macos-x86_64 ;; esac
mkdir -p $D/bin
clothod/scripts/build-net.sh --dev --testctl $plat >$D/build.log 2>&1 || fail "building testctl failed"
cp clothod/target/net/$plat/testctl $D/bin/testctl
(cd clothod && . scripts/toolchain.sh && cd "$root/ClothoKit/Tailnet/go" &&
  CGO_ENABLED=0 go build -trimpath -buildvcs=false -tags ts_omit_logtail -ldflags "-s -w" \
    -o $D/bin/tailnet-testpeer ./cmd/tailnet-testpeer) >>$D/build.log 2>&1 || fail "building tailnet-testpeer failed"

mkfifo $D/hold
# Blocks in open() until the first reader below opens the FIFO, then holds it open until stop.
nohup sleep 86400 >$D/hold 2>/dev/null &
echo $! >$D/holder.pid

nohup $D/bin/testctl --exit-with-stdin <$D/hold >$D/open.out 2>$D/open.log &
nohup $D/bin/testctl --require-auth --exit-with-stdin <$D/hold >$D/auth.out 2>$D/auth.log &
open_url=$(await $D/open.out 30 control_url) || fail "testctl didn't start"
auth_url=$(await $D/auth.out 30 control_url) || fail "testctl --require-auth didn't start"
case "$open_url$auth_url" in *127.0.0.1*127.0.0.1*) ;; *) fail "testctl isn't on loopback: $open_url $auth_url" ;; esac

nohup $D/bin/tailnet-testpeer --control-url "$open_url" --dir $D/peer --hostname cki-testpeer \
  --forward 22=127.0.0.1:2222 <$D/hold >$D/peer.out 2>$D/peer.log &
ip=$(await $D/peer.out 60 ip) || fail "tailnet-testpeer didn't reach Running"

printf '%s\n' "$open_url" >$D/control_url
printf '%s\n' "$auth_url" >$D/auth_control_url
printf '%s\n' "$ip" >$D/peer_ip
rm -f $D/build.log
echo "tailnet test net: control $open_url, auth control $auth_url, cki-testpeer $ip (22 -> 127.0.0.1:2222)"
