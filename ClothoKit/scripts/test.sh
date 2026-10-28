#!/bin/bash
# ClothoKit's checks: the ClothoKit module must build with no warnings (they're errors here: a warning
# like "case is already handled by previous patterns" once hid a dropped event), then the tests.
# --target keeps -warnings-as-errors off the dependencies (SwiftTerm), whose warnings aren't ours.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-keychain --target ClothoKit -Xswiftc -warnings-as-errors
swift test --disable-keychain "$@"
