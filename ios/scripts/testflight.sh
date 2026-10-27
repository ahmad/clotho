#!/bin/zsh
# Archives Clotho (Release, team TEAMID0000) and uploads it to App Store Connect for TestFlight.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE="build/Clotho.xcarchive"

# Push alerts are set up in the developer account (Push capability, the extension id, the Keychain group).
# The packed clothod builds land here at build time; xcodegen needs the folder to exist (it is gitignored).
mkdir -p build-resources/dist
# TestFlight always bundles the released clothod, never a dev dist (build.sh's CLOTHOD_DIST).
unset CLOTHOD_DIST
PUSH=YES xcodegen generate -q
rm -rf "$ARCHIVE" build/export
xcodebuild -project Clotho.xcodeproj -scheme Clotho -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates

echo "Uploaded Clotho build $BUILD_NUMBER to App Store Connect."
