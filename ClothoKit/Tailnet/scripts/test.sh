#!/bin/bash
# ClothoTailnet's tests, all offline: the node against clothod's testctl, clothod-net fronting an ephemeral
# clothod (end to end), and /usr/bin/ssh through the tailnet to this Mac's own sshd. Run on the build Mac:
#
#   scripts/clotho-build mac ClothoKit/Tailnet/scripts/test.sh [swift test args, e.g. --filter SSHProxyTests]
#
# Builds what's missing first: the xcframework (ClothoKit/scripts/build-tailnet.sh), testctl and clothod-net
# (clothod/scripts/build-net.sh --dev --testctl), and the test peer. Everything runs in one /tmp/cmac-tn.* dir,
# removed at the end with every process that used it. Nothing joins a real tailnet or touches ~/.ssh.
#
# CLOTHOD_BIN: the clothod for the end-to-end test (default: the released macOS build in clothod/dist, else
# clothod/target/debug/clothod).
set -euo pipefail
cd "$(dirname "$0")/../../.."
root=$PWD
tailnet=$root/ClothoKit/Tailnet
[ "$(uname)" = Darwin ] || { echo "tailnet tests: need a Mac" >&2; exit 1; }

run_dir=$(mktemp -d /tmp/cmac-tn.XXXXXX)
cleanup() {
  # Every process that used this run's dir (test peers, clothod-net, clothod), then the dir.
  pkill -f "$run_dir" 2>/dev/null || true
  sleep 0.5
  pkill -9 -f "$run_dir" 2>/dev/null || true
  rm -rf "$run_dir"
}
trap cleanup EXIT

[ -d "$tailnet/build/ClothoTailnet.xcframework" ] || ClothoKit/scripts/build-tailnet.sh

case "$(uname -m)" in arm64) plat=macos-aarch64 ;; *) plat=macos-x86_64 ;; esac
clothod/scripts/build-net.sh --dev --testctl "$plat" >/dev/null
testctl=$root/clothod/target/net/$plat/testctl
clothod_net=$root/clothod/target/net/$plat/clothod-net

mkdir -p "$tailnet/.build/testpeer"
(cd clothod && . scripts/toolchain.sh && cd "$tailnet/go" &&
  CGO_ENABLED=0 go build -trimpath -buildvcs=false -tags ts_omit_logtail -ldflags "-s -w" \
    -o "$tailnet/.build/testpeer/tailnet-testpeer" ./cmd/tailnet-testpeer)

clothod_bin=${CLOTHOD_BIN:-}
if [ -z "$clothod_bin" ]; then
  for c in "$root/clothod/dist/$plat/clothod" "$root/clothod/target/debug/clothod"; do
    [ -x "$c" ] && { clothod_bin=$c; break; }
  done
fi
[ -n "$clothod_bin" ] || { echo "tailnet tests: no clothod (set CLOTHOD_BIN)" >&2; exit 1; }

cd "$tailnet"
swift build --disable-keychain --product clotho-tailnet-proxy
# Our targets build with no warnings (warnings are errors here, as in ClothoKit/scripts/test.sh).
for t in ClothoTailnet TailnetFdPass; do
  swift build --disable-keychain --target "$t" -Xswiftc -warnings-as-errors
done
helper=$(swift build --disable-keychain --show-bin-path)/clotho-tailnet-proxy

TAILNET_TEST_DIR=$run_dir TAILNET_TESTCTL=$testctl TAILNET_TESTPEER=$tailnet/.build/testpeer/tailnet-testpeer \
  CLOTHOD_NET_BIN=$clothod_net CLOTHOD_BIN=$clothod_bin TAILNET_PROXY_HELPER=$helper \
  swift test --disable-keychain "$@"

# Nothing may outlive the run (clothod's test-all cleanliness check fails on a stray testctl or sidecar).
sleep 0.5
if left=$(pgrep -fl "$run_dir|tailnet-testpeer|net/$plat/testctl|net/$plat/clothod-net"); then
  echo "tailnet tests: processes left over:" >&2
  echo "$left" >&2
  exit 1
fi
echo "tailnet tests: passed; nothing left running"
