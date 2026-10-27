#!/bin/zsh
# Builds Clotho for the simulator. Usage: ./build.sh [build|test] [simulator id] [xcodebuild args...]
# (e.g. ./build.sh test "" -only-testing:ClothoTests/SSHIntegrationTests).
# `test` starts the "Local Mac (dev)" clothod first and always runs scripts/cleanup-dev.sh afterwards, so no
# test daemon outlives the run.
cd "$(dirname "$0")"
action=${1:-build}
sim=${2:-$(xcrun simctl list devices booted | grep -m1 -o '[0-9A-F-]\{36\}')}
# Simulator builds include push alerts (push.yml); see docs/push.md.
PUSH=YES xcodegen generate --quiet
if [ "$action" = test ]; then
  trap 'scripts/cleanup-dev.sh' EXIT
  mkdir -p /tmp/cki-ios-bin && rm -f /tmp/cki-ios-bin/clothod && cp ../clothod/dist/macos-aarch64/clothod /tmp/cki-ios-bin/clothod
  /tmp/cki-ios-bin/clothod start --runtime-dir /tmp/cki-ios --ephemeral
  scripts/ssh-test-server.sh
fi
xcodebuild -project Clotho.xcodeproj -scheme Clotho -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation \
  $([ "$action" = test ] && echo -test-timeouts-enabled YES -default-test-execution-time-allowance 180) "${@:3}" "$action" 2>&1 \
  | grep -E "error:|warning: .*/ios/Clotho|\*\* |Test Case.*(passed|failed|skipped)|Executed" | grep -v SPMCustomBuildCommand
