#!/bin/sh
# Builds clothod-net, clothod's tailnet sidecar (clothod/net, Go), into
# target/net/<os>-<arch>/clothod-net, the same <os>-<arch> names as dist.sh:
#
#   scripts/build-net.sh [--dev] [--tags TAGS] [--testctl] [PLATFORM...]
#
#   PLATFORM   linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64 (default: all four)
#   --dev      a dev build: its node is named clothod-<host>-dev
#   --tags     Go build tags, comma-separated (default ts_omit_logtail: no log upload code at all)
#   --testctl  also build the standalone test control server, target/net/<platform>/testctl
#
# Every build is pure Go (CGO_ENABLED=0): static on Linux, and cross-built for macOS from any
# host. CLOTHOD_SIGN_IDENTITY="Developer ID Application: …" signs the macOS builds with hardened
# runtime and a timestamp, as dist.sh does (needs a Mac; the build Mac's build keychain is unlocked
# here). Unset, they keep the Go linker's ad-hoc signature.
#
# Go comes from scripts/install-go.sh (the pinned version) via scripts/toolchain.sh.
set -eu
cd "$(dirname "$0")/.."
. scripts/toolchain.sh
command -v go >/dev/null || { echo "build-net: no go; run scripts/install-go.sh" >&2; exit 1; }

dev=0 tags=ts_omit_logtail testctl=0 plats=""
while [ $# -gt 0 ]; do
    case $1 in
    --dev) dev=1 ;;
    --tags) tags=$2; shift ;;
    --testctl) testctl=1 ;;
    -*) echo "build-net: unknown flag $1" >&2; exit 64 ;;
    *) plats="$plats $1" ;;
    esac
    shift
done
[ -n "$plats" ] || plats="linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64"

version=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' Cargo.toml)
# The version the node reports to control (Hostinfo.IPNVersion): tailscale.com's own, with
# -buildvcs=false so it never carries this repo's commit. Unstamped, it would read
# "<ts>-dev<date>-g<our commit>[-dirty]", or "<ts>-ERR-BuildInfo" without VCS info.
ts=$(cd net && go list -m -f '{{.Version}}' tailscale.com | sed 's/^v//')
ldflags="-s -w -X main.version=$version -X tailscale.com/version.shortStamp=$ts -X tailscale.com/version.longStamp=$ts-clothod-net"
[ $dev = 1 ] && ldflags="$ldflags -X main.devBuild=1"

sign=${CLOTHOD_SIGN_IDENTITY:-}
keychain=""
if [ -n "$sign" ]; then
    command -v codesign >/dev/null || { echo "build-net: CLOTHOD_SIGN_IDENTITY needs codesign (a Mac)" >&2; exit 1; }
    kc="$HOME/Library/Keychains/clotho-build.keychain-db"
    kcpw="$HOME/.config/clotho/build-keychain-pw"
    if [ -f "$kc" ] && [ -f "$kcpw" ]; then
        security unlock-keychain -p "$(cat "$kcpw")" "$kc" || { echo "build-net: can't unlock $kc" >&2; exit 1; }
        keychain=$kc
    fi
fi

for p in $plats; do
    case $p in
    linux-x86_64) goos=linux goarch=amd64 ;;
    linux-aarch64) goos=linux goarch=arm64 ;;
    macos-aarch64) goos=darwin goarch=arm64 ;;
    macos-x86_64) goos=darwin goarch=amd64 ;;
    *) echo "build-net: unknown platform $p" >&2; exit 64 ;;
    esac
    out=target/net/$p
    mkdir -p "$out"
    (cd net && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build -trimpath -buildvcs=false -tags "$tags" -ldflags "$ldflags" -o "../$out/clothod-net" .)
    if [ $testctl = 1 ]; then
        (cd net && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build -trimpath -ldflags "-s -w" -o "../$out/testctl" ./testctl/cmd/testctl)
    fi
    if [ -n "$sign" ] && [ $goos = darwin ]; then
        codesign --force --options runtime --timestamp --sign "$sign" ${keychain:+--keychain "$keychain"} "$out/clothod-net" >&2
        codesign --verify --strict --verbose=1 "$out/clothod-net" >&2
    fi
    printf '%s\t%s bytes\t(tags %s)\n' "$out/clothod-net" "$(wc -c < "$out/clothod-net" | tr -d ' ')" "$tags"
done
