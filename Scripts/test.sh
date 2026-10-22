#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
mkdir -p build TestResults
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
extra=()
if [[ -n "${TEST_FILTER:-}" ]]; then extra+=("-only-testing:$TEST_FILTER"); fi
case "${1:-core}" in
  core) swift test --disable-sandbox --scratch-path build/SwiftPM ;;
  iphone|ipad)
    if [[ -z "${SIMULATOR_ID:-}" ]]; then
      print -u2 'Set SIMULATOR_ID to your own available iPhone/iPad simulator UUID (xcrun simctl list devices available).'
      exit 2
    fi
    target="$SIMULATOR_ID"
    result="TestResults/$1-$(date +%Y%m%d-%H%M%S).xcresult"
    # XCTest's simulator runner needs a local ad-hoc signature. Disabling signing
    # entirely can kill the runner before it connects to Xcode on current SDKs.
    xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -destination "platform=iOS Simulator,id=$target" -derivedDataPath "${DERIVED_DATA_PATH:-build/Mobile-$1}" -resultBundlePath "$result" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -collect-test-diagnostics never "${extra[@]}" test
    ;;
  mac)
    trap 'python3 Scripts/mac_app_registry.py' EXIT
    xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -destination 'platform=macOS,arch=arm64' -derivedDataPath build.noindex/Mac -resultBundlePath "TestResults/Mac-$(date +%Y%m%d-%H%M%S).xcresult" -collect-test-diagnostics never "${extra[@]}" test
    ;;
  *) print -u2 'Usage: Scripts/test.sh core|iphone|ipad|mac'; exit 2 ;;
esac
