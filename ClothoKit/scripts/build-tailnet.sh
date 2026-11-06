#!/bin/bash
# Builds Clotho's tailnet shim (ClothoKit/Tailnet/go) into ClothoKit/Tailnet/build/ClothoTailnet.xcframework,
# a static-library xcframework that ClothoKit/Tailnet/Package.swift's binary target names. Needs a Mac
# with Xcode (run it on the build Mac: scripts/clotho-build mac ClothoKit/scripts/build-tailnet.sh).
#
#   build-tailnet.sh [--slices "macos-arm64 ios-arm64 iossim-arm64"] [--clean]
#
#   --slices  which slices to build (default: the three above). Also: macos-x86_64, iossim-x86_64.
#             Slices of one platform are combined with lipo into one library.
#   --clean   remove the xcframework and the package's .build, and Go's caches (clothod's
#             build-space.sh clean), then stop
#
# Go is the pinned toolchain (clothod/scripts/install-go.sh, the version clothod/net/go.mod names) with
# clothod/scripts/toolchain.sh's settings, so every Go cache lives in clothod/target/go, which
# build-space.sh cleans. The shim must pin the same Go and tailscale.com as clothod/net: this refuses
# to build when they differ. Min OS: macOS 13, iOS 17 (the apps' own).
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
tailnet=$root/ClothoKit/Tailnet
out=$tailnet/build/ClothoTailnet.xcframework
slices="macos-arm64 ios-arm64 iossim-arm64"
clean=false
while [ $# -gt 0 ]; do
  case $1 in
    --slices) slices=$2; shift ;;
    --clean) clean=true ;;
    *) echo "usage: $0 [--slices \"macos-arm64 ios-arm64 iossim-arm64\"] [--clean]" >&2; exit 64 ;;
  esac
  shift
done

if $clean; then
  rm -rf "$tailnet/build" "$tailnet/.build"
  clothod/scripts/build-space.sh clean
  exit 0
fi
[ "$(uname)" = Darwin ] || { echo "build-tailnet: needs a Mac with Xcode" >&2; exit 1; }

# The same Go and tailscale.com as clothod-net (one pinned version across every node, PLAN.md).
pins() { grep -E '^go [0-9]|^toolchain |tailscale\.com v' "$1" | sed 's/^[[:space:]]*require[[:space:]]*//; s/^[[:space:]]*//' | sort; }
if [ "$(pins clothod/net/go.mod)" != "$(pins "$tailnet/go/go.mod")" ]; then
  echo "build-tailnet: ClothoKit/Tailnet/go/go.mod and clothod/net/go.mod pin different Go or tailscale.com versions:" >&2
  diff <(pins clothod/net/go.mod) <(pins "$tailnet/go/go.mod") >&2 || true
  exit 1
fi

clothod/scripts/install-go.sh >/dev/null
clothod/scripts/build-space.sh check
cd clothod
. scripts/toolchain.sh
cd "$root"
command -v go >/dev/null || { echo "build-tailnet: no go; run clothod/scripts/install-go.sh" >&2; exit 1; }

ts=$(cd "$tailnet/go" && go list -m -f '{{.Version}}' tailscale.com | sed 's/^v//')
# The version the node reports to control: tailscale.com's own, never this repo's commit.
ldflags="-s -w -X tailscale.com/version.shortStamp=$ts -X tailscale.com/version.longStamp=$ts-clotho"
work=$tailnet/build/work
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

build_slice() { # slice -> $work/<slice>/libclothotailnet.a
  local slice=$1 goos goarch sdk target
  case $slice in
    macos-arm64) goos=darwin goarch=arm64 sdk=macosx target=arm64-apple-macos13.0 ;;
    macos-x86_64) goos=darwin goarch=amd64 sdk=macosx target=x86_64-apple-macos13.0 ;;
    ios-arm64) goos=ios goarch=arm64 sdk=iphoneos target=arm64-apple-ios17.0 ;;
    iossim-arm64) goos=ios goarch=arm64 sdk=iphonesimulator target=arm64-apple-ios17.0-simulator ;;
    iossim-x86_64) goos=ios goarch=amd64 sdk=iphonesimulator target=x86_64-apple-ios17.0-simulator ;;
    *) echo "build-tailnet: unknown slice $slice" >&2; exit 64 ;;
  esac
  local sysroot cc flags
  sysroot=$(xcrun --sdk $sdk --show-sdk-path)
  cc=$(xcrun --sdk $sdk -f clang)
  flags="-isysroot $sysroot -target $target"
  mkdir -p "$work/$slice"
  echo "build-tailnet: $slice ($target)"
  (cd "$tailnet/go" && CGO_ENABLED=1 GOOS=$goos GOARCH=$goarch CC="$cc" CGO_CFLAGS="$flags -O2" CGO_LDFLAGS="$flags" \
    MACOSX_DEPLOYMENT_TARGET=13.0 IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    go build -buildmode=c-archive -trimpath -buildvcs=false -tags ts_omit_logtail -ldflags "$ldflags" \
      -o "$work/$slice/libclothotailnet.a" .)
  # The cgo header isn't ours: clotho_tailnet.h is the API.
  rm -f "$work/$slice/libclothotailnet.h"
}

for s in $slices; do build_slice "$s"; done

# One library per platform (lipo combines a platform's architectures), each with the header and the
# module map (module CClothoTailnet).
args=()
for platform in macos ios iossim; do
  libs=()
  for s in $slices; do
    case $s in $platform-*) libs+=("$work/$s/libclothotailnet.a") ;; esac
  done
  [ ${#libs[@]} -gt 0 ] || continue
  dir=$work/$platform
  mkdir -p "$dir/Headers"
  if [ ${#libs[@]} -eq 1 ]; then cp "${libs[0]}" "$dir/libclothotailnet.a"; else lipo -create "${libs[@]}" -output "$dir/libclothotailnet.a"; fi
  cp "$tailnet/go/clotho_tailnet.h" "$tailnet/go/module.modulemap" "$dir/Headers/"
  args+=(-library "$dir/libclothotailnet.a" -headers "$dir/Headers")
done
rm -rf "$out"
xcodebuild -create-xcframework "${args[@]}" -output "$out" >/dev/null

# Report: size, and the platform and min OS each slice was built for (vtool: platform 1 macOS, 2 iOS,
# 7 iOS simulator).
for lib in "$out"/*/libclothotailnet.a; do
  slice=$(basename "$(dirname "$lib")")
  size=$(wc -c < "$lib" | tr -d ' ')
  objs=$(mktemp -d "$work/objs.XXXX")
  arch=$(lipo -archs "$lib" | awk '{print $1}')
  (cd "$objs" && lipo -thin "$arch" "$lib" -output thin.a 2>/dev/null || cp "$lib" thin.a; ar -x thin.a go.o 2>/dev/null || true)
  build=$( [ -f "$objs/go.o" ] && vtool -show-build "$objs/go.o" 2>/dev/null | awk '/platform|minos/ {printf "%s %s ", $1, $2}')
  printf 'build-tailnet: %-36s %6.1f MB  %s  %s\n' "$slice" "$(echo "$size / 1048576" | bc -l)" "$(lipo -archs "$lib")" "$build"
done
echo "build-tailnet: $out"
