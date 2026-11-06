#!/bin/sh
# Installs the pinned Go toolchain for this user, without editing any dotfile or needing root:
# the official go.dev/dl archive, checked against the sha256 pinned below, unpacked into
# ~/.local/share/go/<version>, with ~/.local/share/go/current linked to it. scripts/toolchain.sh
# puts current/bin on PATH. Idempotent: an installed, matching version is left alone.
#
# The version is clothod/net/go.mod's `toolchain` line, or its `go` line when there is none (go
# drops a toolchain line equal to the go line; tailscale.com sets the minimum Go it builds with).
# Bumping it means adding that release's four checksums here, from https://go.dev/dl/?mode=json,
# in the same commit.
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^toolchain go\([0-9.]*\)$/\1/p' net/go.mod)
[ -n "$version" ] || version=$(sed -n 's/^go \([0-9]*\.[0-9]*\.[0-9]*\)$/\1/p' net/go.mod)
[ -n "$version" ] || { echo "install-go: no go version (x.y.z) in net/go.mod" >&2; exit 1; }

case "$(uname -s)-$(uname -m)" in
Linux-x86_64) plat=linux-amd64 ;;
Linux-aarch64 | Linux-arm64) plat=linux-arm64 ;;
Darwin-arm64) plat=darwin-arm64 ;;
Darwin-x86_64) plat=darwin-amd64 ;;
*) echo "install-go: unsupported platform $(uname -sm)" >&2; exit 1 ;;
esac

case "go$version.$plat" in
go1.27.3.linux-amd64) sha=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ;;
go1.27.3.linux-arm64) sha=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49 ;;
go1.27.3.darwin-arm64) sha=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2 ;;
go1.27.3.darwin-amd64) sha=b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750 ;;
*) echo "install-go: no pinned checksum for go$version.$plat; add it to $0" >&2; exit 1 ;;
esac

base=$HOME/.local/share/go
dest=$base/$version
if [ -x "$dest/bin/go" ] && [ "$(GOTOOLCHAIN=local "$dest/bin/go" env GOVERSION 2>/dev/null)" = "go$version" ]; then
    echo "go $version is already in $dest"
else
    mkdir -p "$base"
    tmp=$(mktemp -d "$base/.install.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    file=go$version.$plat.tar.gz
    echo "downloading $file"
    curl -fsSL --retry 3 -o "$tmp/$file" "https://go.dev/dl/$file"
    if command -v sha256sum >/dev/null; then
        got=$(sha256sum "$tmp/$file" | cut -d' ' -f1)
    else
        got=$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1)
    fi
    [ "$got" = "$sha" ] || { echo "install-go: checksum mismatch for $file (got $got, want $sha)" >&2; exit 1; }
    mkdir "$tmp/x"
    tar -xzf "$tmp/$file" -C "$tmp/x"
    rm -rf "$dest"
    mv "$tmp/x/go" "$dest"
    echo "installed go $version in $dest"
fi
# -n: replace the link itself, never create one inside the dir it points to.
ln -sfn "$version" "$base/current"
GOTOOLCHAIN=local "$base/current/bin/go" version
