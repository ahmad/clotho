#!/bin/zsh
# Builds Clotho for the simulator. Usage: ./build.sh [build|test] [simulator id] [xcodebuild args...]
# (e.g. ./build.sh test "" -only-testing:ClothoTests/SSHIntegrationTests).
# `test` starts the "Local Mac (dev)" clothod first and always runs scripts/cleanup-dev.sh afterwards, so no
# test daemon outlives the run.
# CLOTHO_TAILNET=1 also links Clotho's own tailnet node (tailnet.yml) and its debug-only Tailnet Test screen; it
# needs ../ClothoKit/Tailnet/build/ClothoTailnet.xcframework (ClothoKit/scripts/build-tailnet.sh). With `test` it
# also starts the offline test tailnet (scripts/tailnet-test-net.sh). Every other build checks that the app
# doesn't link the node (scripts/check-no-tailnet.sh).
# Privacy manifests (scripts/check-privacy.py): the committed ones are linted before xcodegen runs, and every build
# checks that the app and both extensions carry their own PrivacyInfo.xcprivacy declaring every required-reason
# API their executables import.
cd "$(dirname "$0")"
# Where Homebrew has no xcodegen (the build Mac), the release zip lives in ~/Builds/tools.
# The signing team and the push relay URL come from the environment (CLOTHO_TEAM_ID, CLOTHO_RELAY_URL; see
# project.yml), which scripts/clotho-build passes from the dev box's private settings. Without them the app
# still builds, with push registration off.
[ -x "$HOME/Builds/tools/xcodegen/bin/xcodegen" ] && PATH=$HOME/Builds/tools/xcodegen/bin:$PATH
action=${1:-build}
sim=${2:-$(xcrun simctl list devices booted | grep -m1 -o '[0-9A-F-]\{36\}')}
# CLOTHOD_DIST=<dir> bundles (and tests against) that clothod dist instead of the release in clothod/dist, e.g.
# CLOTHOD_DIST=$PWD/../clothod/target/dist-dev after `DIST_DIR=target/dist-dev clothod/scripts/dist.sh --dev`.
export CLOTHOD_DIST=${CLOTHOD_DIST:-$PWD/../clothod/dist}
# Simulator builds include push alerts (push.yml); see docs/push.md.
# The packed clothod builds land here at build time; xcodegen needs the folder to exist (it is gitignored).
mkdir -p build-resources/dist
tailnet=NO
if [ "${CLOTHO_TAILNET:-}" = 1 ]; then
  xcf=../ClothoKit/Tailnet/build/ClothoTailnet.xcframework
  if [ ! -f $xcf/Info.plist ] || ! ls -d $xcf/ios-arm64*-simulator >/dev/null 2>&1; then
    echo "error: CLOTHO_TAILNET=1 needs ClothoKit/Tailnet/build/ClothoTailnet.xcframework with a simulator slice:" \
      "run ClothoKit/scripts/build-tailnet.sh --slices \"ios-arm64 iossim-arm64\" first" >&2
    exit 1
  fi
  tailnet=YES
fi
unset CLOTHO_TAILNET
python3 -I scripts/check-privacy.py sources || exit 1
PUSH=YES WIDGET=YES LIVE_ACTIVITY=YES TAILNET=$tailnet xcodegen generate --quiet
# Pack before xcodebuild, not only in its pre-build phase: Xcode plans the resource copy before that phase
# runs, so the first build after a new clothod release would otherwise bundle the previous one.
python3 scripts/pack-dist.py "$CLOTHOD_DIST" build-resources/dist || exit 1
if [ "$action" = test ]; then
  trap 'scripts/cleanup-dev.sh' EXIT
  mkdir -p /tmp/cki-ios-bin && rm -f /tmp/cki-ios-bin/clothod && cp "$CLOTHOD_DIST/macos-aarch64/clothod" /tmp/cki-ios-bin/clothod
  # Its own config file, so settings tests never write the user's ~/.config/clothod/config.toml.
  # Notification summaries come from a fake (scripts/fake-summarizer.sh), never a real claude.
  CLOTHOD_SUMMARIZER=$PWD/scripts/fake-summarizer.sh CLOTHOD_CONFIG=/tmp/cki-ios/config.toml \
    /tmp/cki-ios-bin/clothod start --runtime-dir /tmp/cki-ios --ephemeral
  scripts/ssh-test-server.sh
  # The peer forwards its tailnet port 22 to that sshd.
  if [ $tailnet = YES ]; then scripts/tailnet-test-net.sh start || exit 1; fi
fi
xcodebuild -project Clotho.xcodeproj -scheme Clotho -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation \
  $([ "$action" = test ] && echo -test-timeouts-enabled YES -default-test-execution-time-allowance 180) "${@:3}" "$action" 2>&1 \
  | grep -E "error:|warning: .*/ios/Clotho|ld: warning|\*\* |Test Case.*(passed|failed|skipped)|Executed" | grep -v SPMCustomBuildCommand
rc=$?
# Only CLOTHO_TAILNET=1 builds may link the node, and the extensions never do. Debug builds keep the code in
# <name>.debug.dylib next to a stub executable, so both are checked.
app=build/Build/Products/Debug-iphonesimulator/Clotho.app
if [ -f $app/Clotho ]; then
  bins=()
  [ $tailnet = NO ] && bins+=($app/Clotho $app/Clotho.debug.dylib)
  for x in ClothoNotify ClothoWidget; do bins+=($app/PlugIns/$x.appex/$x $app/PlugIns/$x.appex/$x.debug.dylib); done
  existing=()
  for b in $bins; do [ -f $b ] && existing+=($b); done
  if [ ${#existing} -gt 0 ]; then scripts/check-no-tailnet.sh $existing || exit 1; fi
  # Each bundle's own manifest covers what its executable imports. The extensions are named, so a missing one fails.
  python3 -I scripts/check-privacy.py bundle $app $app/PlugIns/ClothoNotify.appex $app/PlugIns/ClothoWidget.appex \
    || exit 1
fi
exit $rc
