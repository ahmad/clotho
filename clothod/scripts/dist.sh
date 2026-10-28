#!/bin/sh
# Build clothod for every platform a client may need to install it on, into dist/:
#
# Output goes to $DIST_DIR (default dist/):
#   dist/<os>-<arch>/clothod      os: macos | linux, arch: aarch64 | x86_64 (as `uname -m`
#                                 normalizes, see docs/remote.md)
#   dist/manifest.json            version, and per build: Rust target, install id, size
#
# Linux builds are static musl binaries linked with rust-lld (no cross toolchain needed).
# macOS x86_64 needs Xcode's SDK, which any Mac with the command line tools has.
#
# CLOTHOD_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" signs the macOS builds with that
# identity, hardened runtime and a secure timestamp (what notarization needs), before their
# install ids are computed: the id hashes the whole file, so signing later would break the
# manifest and every installed daemon's id. Unset, they keep the linker's ad-hoc signature.
set -eu
cd "$(dirname "$0")/.."

# Releases (what reaches the user's machines) need a version newer than the last release: the
# apps only offer upgrades to a higher version, since two builds of one version can't be
# ordered. `--dev` builds a same-version dist for testing and doesn't record a release.
#
# Versions compare per numeric component (`sort -V`, GNU and Apple sort alike): 0.1.10 is newer
# than 0.1.9. `dist.sh --check-newer A B` exits 0 if A is newer than B, and builds nothing
# (tests/dist.rs).
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
if [ "${1:-}" = "--check-newer" ]; then
    newer "$2" "$3"
    exit $?
fi
dev=0
[ "${1:-}" = "--dev" ] && dev=1
version=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' Cargo.toml)
released=$(cat RELEASED 2>/dev/null || echo 0.0.0)
# RELEASED is one line, the last released version: the apps' scripts read the whole file as the
# version. Refuse anything else (a hand edit that appended) instead of comparing against it.
if [ -f RELEASED ] && { [ "$(wc -l < RELEASED)" -ne 1 ] || ! grep -qx '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' RELEASED; }; then
    echo "dist: RELEASED must be one line holding the last released version (x.y.z), not:" >&2
    cat RELEASED >&2
    exit 1
fi
if [ "$dev" = 0 ] && ! newer "$version" "$released"; then
    echo "dist: version $version is not newer than the last release ($released)." >&2
    echo "dist: bump [workspace.package] version in Cargo.toml for a release, or pass --dev for a test build." >&2
    exit 1
fi

builds="macos-aarch64:aarch64-apple-darwin macos-x86_64:x86_64-apple-darwin linux-x86_64:x86_64-unknown-linux-musl linux-aarch64:aarch64-unknown-linux-musl"

# Linux builds link statically against musl; ring (TLS for push alerts) has C code, so they go
# through cargo-zigbuild, with zig as the cross C compiler and linker.
command -v cargo-zigbuild >/dev/null || { echo "dist: needs cargo-zigbuild and zig (brew install zig; cargo install cargo-zigbuild)" >&2; exit 1; }
apple="" linux=""
for b in $builds; do
    t=${b#*:}
    rustup target list --installed | grep -qx "$t" || rustup target add "$t"
    case $t in *-linux-*) linux="$linux --target $t" ;; *) apple="$apple --target $t" ;; esac
done
# shellcheck disable=SC2086
cargo build --release --bin clothod $apple
# shellcheck disable=SC2086
cargo zigbuild --release --bin clothod $linux

host=target/release/clothod
cargo build --release --bin clothod

sign=${CLOTHOD_SIGN_IDENTITY:-}
if [ -n "$sign" ]; then
    command -v codesign >/dev/null || { echo "dist: CLOTHOD_SIGN_IDENTITY needs codesign (a Mac)" >&2; exit 1; }
fi

out=${DIST_DIR:-dist}
rm -rf "$out"
mkdir -p "$out"
{
    printf '{\n  "version": "%s",\n  "builds": {\n' "$version"
    first=1
    for b in $builds; do
        name=${b%%:*}
        t=${b#*:}
        mkdir -p "$out/$name"
        cp "target/$t/release/clothod" "$out/$name/clothod"
        case $name in macos-*)
            if [ -n "$sign" ]; then
                codesign --force --options runtime --timestamp --sign "$sign" "$out/$name/clothod" >&2
                codesign --verify --strict --verbose=1 "$out/$name/clothod" >&2
                # It must still start under the hardened runtime (x86_64 through Rosetta).
                "$out/$name/clothod" version >&2
            fi
        esac
        id=$("$host" build-id "$out/$name/clothod")
        size=$(wc -c < "$out/$name/clothod" | tr -d ' ')
        [ $first = 1 ] || printf ',\n'
        first=0
        printf '    "%s": {"target": "%s", "id": "%s", "size": %s, "file": "%s/clothod"}' "$name" "$t" "$id" "$size" "$name"
    done
    printf '\n  }\n}\n'
} > "$out/manifest.json"
cat "$out/manifest.json"
if [ "$dev" = 0 ]; then
    echo "$version" > RELEASED
    echo "dist: released $version (recorded in RELEASED)"
else
    echo "dist: dev build of $version (not a release)"
fi
