#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
mkdir -p build.noindex
trap 'python3 Scripts/mac_app_registry.py' EXIT
python3 Scripts/check_localizations.py
python3 Scripts/prepare_speech.py --verify
python3 Scripts/prepare_legal.py --check
swift Scripts/make_icons.swift "$PWD"
swift Scripts/verify_branding.swift "$PWD"
case "${1:-mac}" in
  mac)
    xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -destination 'platform=macOS,arch=arm64' -derivedDataPath build.noindex/Mac build
    ;;
  simulator)
    xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -destination 'generic/platform=iOS Simulator' -derivedDataPath build/Mobile ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
    ;;
  device)
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
      xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -destination 'generic/platform=iOS' -derivedDataPath build/Device DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY='Apple Development' build
    else
      xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -destination 'generic/platform=iOS' -derivedDataPath build/Device build
    fi
    ;;
  *) print -u2 'Usage: Scripts/build.sh mac|simulator|device'; exit 2 ;;
esac
case "${1:-mac}" in
  mac) speech_app='build.noindex/Mac/Build/Products/Debug/Ink Engine.app' ;;
  simulator) speech_app='build/Mobile/Build/Products/Debug-iphonesimulator/Ink Engine.app' ;;
  device) speech_app='build/Device/Build/Products/Debug-iphoneos/Ink Engine.app' ;;
esac
python3 Scripts/verify_speech_distribution.py "$speech_app"
