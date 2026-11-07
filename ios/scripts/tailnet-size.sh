#!/bin/zsh
# Phase 0's size check for the tailnet node (PLAN.md, "Built-in Tailscale"): builds the app for devices
# (Release, generic/platform=iOS, unsigned: nothing is signed, exported or uploaded) without the node and with it,
# and prints for each the .app size, the executable before and after `strip -x`, its zip -9 size, its min iOS, the
# linker warnings and the required-reason symbols it imports (for the privacy manifest). It also tests
# scripts/check-no-tailnet.sh both ways: it must pass on the base app and every extension, and fail on the app
# that has the node. Runs on the Mac, with ClothoKit/Tailnet/build/ClothoTailnet.xcframework (ios-arm64) built.
#
#   scripts/tailnet-size.sh
#
# Works in /tmp/cki-size.*, removed at the end, and regenerates the default project when done.
set -u
cd "$(dirname "$0")/.."
[ -x "$HOME/Builds/tools/xcodegen/bin/xcodegen" ] && PATH=$HOME/Builds/tools/xcodegen/bin:$PATH
xcf=../ClothoKit/Tailnet/build/ClothoTailnet.xcframework
[ -d $xcf/ios-arm64 ] || { echo "tailnet-size: no ios-arm64 slice in $xcf (ClothoKit/scripts/build-tailnet.sh)" >&2; exit 1; }
export CLOTHOD_DIST=${CLOTHOD_DIST:-$PWD/../clothod/dist}
work=$(mktemp -d /tmp/cki-size.XXXXXX)
cleanup() {
  rm -rf $work
  PUSH=YES WIDGET=YES LIVE_ACTIVITY=YES TAILNET=NO xcodegen generate --quiet
}
trap cleanup EXIT
mkdir -p build-resources/dist
python3 scripts/pack-dist.py "$CLOTHOD_DIST" build-resources/dist || exit 1

reasons=(stat fstat fstatat lstat statfs fstatfs getattrlist fgetattrlist getattrlistbulk mach_absolute_time
         sysctl sysctlbyname proc_regionfilename mach_vm_region)
rc=0
for variant in base tailnet; do
  tailnet=NO; [ $variant = tailnet ] && tailnet=YES
  PUSH=YES WIDGET=YES LIVE_ACTIVITY=YES TAILNET=$tailnet xcodegen generate --quiet
  t0=$(date +%s)
  xcodebuild -project Clotho.xcodeproj -scheme Clotho -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath $work/dd-$variant -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO \
    build >$work/$variant.log 2>&1
  built=$?
  t1=$(date +%s)
  app=$work/dd-$variant/Build/Products/Release-iphoneos/Clotho.app
  if [ $built != 0 ] || [ ! -f $app/Clotho ]; then
    grep -E "error:" $work/$variant.log | head -20
    echo "tailnet-size: the $variant build failed" >&2
    rc=1
    continue
  fi
  bin=$app/Clotho
  cp $bin $work/stripped && strip -x $work/stripped 2>/dev/null
  (cd $app/.. && zip -qr9 $work/$variant.zip Clotho.app)
  echo "== $variant (built in $((t1 - t0)) s)"
  echo "   .app:              $(du -sk $app | cut -f1) KiB"
  echo "   executable:        $(stat -f %z $bin) B"
  echo "   strip -x:          $(stat -f %z $work/stripped) B"
  echo "   .app zip -9:       $(stat -f %z $work/$variant.zip) B"
  echo "   min iOS:           $(vtool -show-build $bin 2>/dev/null | awk '/minos/ {print $2; exit}')"
  echo "   privacy manifest:  $([ -f $app/PrivacyInfo.xcprivacy ] && plutil -lint $app/PrivacyInfo.xcprivacy | sed 's/.*: //' || echo none)"
  for x in ClothoNotify ClothoWidget; do
    echo "   $x:  $(stat -f %z $app/PlugIns/$x.appex/$x) B"
  done
  warnings=$(grep -E "ld: warning|warning: .*(linker|ld)" $work/$variant.log | sort -u)
  echo "   linker warnings:   ${warnings:-none}"
  undefined=$(nm -u $bin)
  hits=()
  for r in $reasons; do [[ $'\n'"$undefined"$'\n' == *$'\n_'$r$'\n'* ]] && hits+=($r); done
  echo "   required-reason imports: ${hits:-none}"
  # The guard: the base app and every extension pass; the app with the node fails.
  scripts/check-no-tailnet.sh $app/PlugIns/ClothoNotify.appex/ClothoNotify $app/PlugIns/ClothoWidget.appex/ClothoWidget \
    || { echo "!! an extension links the tailnet node" >&2; rc=1; }
  if [ $variant = base ]; then
    scripts/check-no-tailnet.sh $bin || { echo "!! check-no-tailnet.sh failed on the base app" >&2; rc=1; }
  else
    if scripts/check-no-tailnet.sh $bin 2>/dev/null; then
      echo "!! check-no-tailnet.sh passed an app that links the node" >&2; rc=1
    else
      echo "   check-no-tailnet.sh refuses this app (as it must)"
    fi
  fi
done
exit $rc
