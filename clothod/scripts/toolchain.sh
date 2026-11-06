# Sourced by dist.sh and test-all.sh: put per-user toolchains on PATH without editing the user's
# dotfiles. A non-interactive `zsh -lc` (scripts/clotho-build) reads no ~/.zprofile on a build Mac that has
# none, so rustup's ~/.cargo/bin and an upstream zig in ~/.local/share/zig/current (the build Mac's
# install, see docs/remote.md "Build hosts") would be missing. Dirs that don't exist are skipped,
# and ones already on PATH keep their place.
for d in "$HOME/.local/share/zig/current" "$HOME/.cargo/bin"; do
    [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH
