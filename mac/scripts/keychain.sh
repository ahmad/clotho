# Sourced (zsh) by build-app.sh, scripts/notarize.sh and scripts/release.sh: picks the keychain that holds
# the Developer ID identity, the notarytool profile and the Sparkle key, and unlocks it. Over SSH a
# keychain is locked, and an unlock lasts only for that SSH session, so each script unlocks it itself.
#
#   The release build host (imac): ~/Library/Keychains/clotho-build.keychain-db, a keychain only for
#     building, whose password is in ~/.config/clotho/build-keychain-pw. Its presence is what makes a Mac
#     the build host, and a build host never installs the app (build-app.sh refuses plain and --release).
#   Any other Mac (macbook, the fallback): the login keychain, unlocked from ~/.keychain_pw when that
#     file exists (at the Mac itself it's usually unlocked already).
#
# Sets CLOTHO_KEYCHAIN and CLOTHO_BUILD_HOST, and defines clotho_unlock_keychain, which never prints the
# password. sign_update and generate_keys can't be pointed at a keychain; they search the user's
# keychain list, so clotho_unlock_keychain also checks the keychain is on it.

if [[ -f "$HOME/.config/clotho/build-keychain-pw" ]]; then
  CLOTHO_KEYCHAIN="$HOME/Library/Keychains/clotho-build.keychain-db"
  CLOTHO_KEYCHAIN_PW="$HOME/.config/clotho/build-keychain-pw"
  CLOTHO_BUILD_HOST=true
else
  CLOTHO_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  CLOTHO_KEYCHAIN_PW="$HOME/.keychain_pw"
  CLOTHO_BUILD_HOST=false
fi

clotho_unlock_keychain() {
  [[ -f "$CLOTHO_KEYCHAIN" ]] || { print -u2 "keychain: no keychain at $CLOTHO_KEYCHAIN"; return 1; }
  if [[ -f "$CLOTHO_KEYCHAIN_PW" ]]; then
    security unlock-keychain -p "$(<"$CLOTHO_KEYCHAIN_PW")" "$CLOTHO_KEYCHAIN" \
      || { print -u2 "keychain: couldn't unlock $CLOTHO_KEYCHAIN with the password in $CLOTHO_KEYCHAIN_PW"; return 1; }
  fi
  security list-keychains -d user | grep -qF "$CLOTHO_KEYCHAIN" \
    || { print -u2 "keychain: $CLOTHO_KEYCHAIN isn't on the user's keychain search list, so sign_update can't find the Sparkle key"; return 1; }
}
