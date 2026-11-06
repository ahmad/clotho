# Sourced by dist.sh, test-all.sh and build-net.sh, from clothod/: put per-user toolchains on PATH
# without editing the user's dotfiles. A non-interactive `zsh -lc` (scripts/clotho-build) reads no
# ~/.zprofile on a build Mac that has none, so rustup's ~/.cargo/bin, an upstream zig in
# ~/.local/share/zig/current (the build Mac's install) and Go in ~/.local/share/go/current
# (scripts/install-go.sh; see docs/remote.md "Build hosts") would be missing. Dirs that don't exist
# are skipped, and ones already on PATH keep their place.
for d in "$HOME/.local/share/go/current/bin" "$HOME/.local/share/zig/current" "$HOME/.cargo/bin"; do
    [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# Go (clothod/net): only the pinned toolchain, never one fetched on the fly, and every cache in
# target/go, so build-space.sh's cleaning covers them and nothing lands in ~/go or ~/Library.
export GOTOOLCHAIN=local
: "${GOCACHE:=$PWD/target/go/cache}" "${GOMODCACHE:=$PWD/target/go/mod}" "${GOPATH:=$PWD/target/go/path}"
export GOCACHE GOMODCACHE GOPATH
# Module cache files are read-only by default, which rm -rf can't remove.
case " ${GOFLAGS:-} " in *" -modcacherw "*) ;; *) GOFLAGS="${GOFLAGS:+$GOFLAGS }-modcacherw" ;; esac
export GOFLAGS
