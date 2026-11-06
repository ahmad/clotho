# Sourced (zsh) by build-app.sh, scripts/notarize.sh and scripts/release.sh: picks the keychain that holds
# the Developer ID identity, the notarytool profile and the Sparkle key, and unlocks it. Over SSH a
# keychain is locked, and an unlock lasts only for that SSH session, so each script unlocks it itself.
#
#   The release build host (the build Mac): ~/Library/Keychains/clotho-build.keychain-db, a keychain only
#     for building, whose password is in ~/.config/clotho/build-keychain-pw. Its presence is what makes a
#     Mac the build host, and a build host never installs the app (build-app.sh refuses plain and --release).
#   Any other Mac (the fallback): the login keychain, unlocked from ~/.keychain_pw when that file exists
#     (at the Mac itself it's usually unlocked already).
#
# Sets CLOTHO_KEYCHAIN and CLOTHO_ON_BUILD_HOST, and defines clotho_unlock_keychain, which never prints the
# password. sign_update and generate_keys can't be pointed at a keychain; they search the user's
# keychain list, so clotho_unlock_keychain also checks the keychain is on it.
#
# The Apple team whose Developer ID signs the app is CLOTHO_TEAM_ID, which is never written in the repo.
# It comes from the environment: scripts/clotho-build passes it on from ~/.config/clotho/local.env on the
# machine that runs it, and a Mac that runs these scripts itself may keep its own local.env
# (CLOTHO_LOCAL_ENV names another file). Only signing needs it (--release, --package, notarize.sh,
# release.sh); --dev and the tests don't. clotho_team_id prints it, or says how to set it and fails;
# clotho_developer_id prints the team's Developer ID Application identity in CLOTHO_KEYCHAIN (nothing when
# there is none).

if [[ -f "$HOME/.config/clotho/build-keychain-pw" ]]; then
  CLOTHO_KEYCHAIN="$HOME/Library/Keychains/clotho-build.keychain-db"
  CLOTHO_KEYCHAIN_PW="$HOME/.config/clotho/build-keychain-pw"
  CLOTHO_ON_BUILD_HOST=true
else
  CLOTHO_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  CLOTHO_KEYCHAIN_PW="$HOME/.keychain_pw"
  CLOTHO_ON_BUILD_HOST=false
fi

# Only CLOTHO_TEAM_ID is taken from local.env (read in a subshell), so its other settings can't change
# these scripts.
if [[ -z "${CLOTHO_TEAM_ID:-}" && -r "${CLOTHO_LOCAL_ENV:-$HOME/.config/clotho/local.env}" ]]; then
  CLOTHO_TEAM_ID=$(source "${CLOTHO_LOCAL_ENV:-$HOME/.config/clotho/local.env}" >/dev/null 2>&1; print -r -- "${CLOTHO_TEAM_ID:-}")
fi
if [[ -n "${CLOTHO_TEAM_ID:-}" ]]; then export CLOTHO_TEAM_ID; fi

clotho_unlock_keychain() {
  [[ -f "$CLOTHO_KEYCHAIN" ]] || { print -u2 "keychain: no keychain at $CLOTHO_KEYCHAIN"; return 1; }
  if [[ -f "$CLOTHO_KEYCHAIN_PW" ]]; then
    security unlock-keychain -p "$(<"$CLOTHO_KEYCHAIN_PW")" "$CLOTHO_KEYCHAIN" \
      || { print -u2 "keychain: couldn't unlock $CLOTHO_KEYCHAIN with the password in $CLOTHO_KEYCHAIN_PW"; return 1; }
  fi
  security list-keychains -d user | grep -qF "$CLOTHO_KEYCHAIN" \
    || { print -u2 "keychain: $CLOTHO_KEYCHAIN isn't on the user's keychain search list, so sign_update can't find the Sparkle key"; return 1; }
}

clotho_team_id() {
  if [[ -z "${CLOTHO_TEAM_ID:-}" ]]; then
    print -u2 "keychain: CLOTHO_TEAM_ID isn't set. Set it to the Apple team ID whose Developer ID Application certificate signs Clotho, in the environment or in ~/.config/clotho/local.env (scripts/clotho-build passes it on to the build Mac)."
    return 1
  fi
  [[ "$CLOTHO_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] \
    || { print -u2 "keychain: CLOTHO_TEAM_ID should be an Apple team ID (10 capital letters and digits), but is \"$CLOTHO_TEAM_ID\""; return 1; }
  print -r -- "$CLOTHO_TEAM_ID"
}

clotho_developer_id() {
  local team
  team=$(clotho_team_id) || return 1
  security find-identity -v -p codesigning "$CLOTHO_KEYCHAIN" 2>/dev/null \
    | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\".*/\1/p" | head -1
  return 0
}
