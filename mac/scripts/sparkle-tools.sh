#!/bin/zsh
# Prints the folder holding Sparkle's command-line tools (generate_keys, sign_update), downloading the
# release that matches Package.swift's Sparkle version the first time and checking its SHA-256.
#   scripts/sparkle-tools.sh            → ~/Library/Caches/Clotho/Sparkle-2.6.4/bin
#   "$(scripts/sparkle-tools.sh)/generate_keys"
set -euo pipefail
VERSION=2.6.4
SHA256=50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b
DIR="$HOME/Library/Caches/Clotho/Sparkle-$VERSION"
if [[ ! -x "$DIR/bin/sign_update" ]]; then
  mkdir -p "$DIR"
  TARBALL="$DIR.tar.xz"
  curl -fsSL -o "$TARBALL" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  ACTUAL=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
  if [[ "$ACTUAL" != "$SHA256" ]]; then
    rm -f "$TARBALL"
    print -u2 "sparkle-tools: Sparkle-$VERSION.tar.xz has SHA-256 $ACTUAL, expected $SHA256"
    exit 1
  fi
  tar -xJf "$TARBALL" -C "$DIR" ./bin
  rm -f "$TARBALL"
fi
print "$DIR/bin"
