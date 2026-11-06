#!/bin/zsh
# Builds Clotho for the simulator. Usage: ./build.sh [build|test] [simulator id] [xcodebuild args...]
# (e.g. ./build.sh test "" -only-testing:ClothoTests/SSHIntegrationTests).
# `test` starts the "Local Mac (dev)" clothod first and always runs scripts/cleanup-dev.sh afterwards, so no
# test daemon outlives the run.
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
PUSH=YES WIDGET=YES LIVE_ACTIVITY=YES xcodegen generate --quiet
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
fi
xcodebuild -project Clotho.xcodeproj -scheme Clotho -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation \
  $([ "$action" = test ] && echo -test-timeouts-enabled YES -default-test-execution-time-allowance 180) "${@:3}" "$action" 2>&1 \
  | grep -E "error:|warning: .*/ios/Clotho|\*\* |Test Case.*(passed|failed|skipped)|Executed" | grep -v SPMCustomBuildCommand
