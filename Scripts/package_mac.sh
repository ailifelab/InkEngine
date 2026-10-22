#!/bin/zsh
# Build a locally signed, offline macOS installer for Apple silicon.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
MAC_SIGNING_IDENTITY="${MAC_SIGNING_IDENTITY:--}"

work="$PWD/build.noindex/LocalDistribution"
derived="$work/DerivedData"
mkdir -p "$work"
stage=$(mktemp -d "$work/staging.XXXXXX")
trap 'rm -rf "$stage"; python3 Scripts/mac_app_registry.py' EXIT

python3 Scripts/prepare_speech.py --verify
python3 Scripts/prepare_legal.py --check
python3 Scripts/check_localizations.py
swift Scripts/make_icons.swift "$PWD"
swift Scripts/verify_branding.swift "$PWD"
print 'Building macOS Release (arm64); full log: build/LocalDistribution/build.log'
if ! xcodebuild -project InkEngine.xcodeproj -scheme InkEngine \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$MAC_SIGNING_IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= build > "$work/build.log" 2>&1; then
    tail -n 80 "$work/build.log"
    exit 1
fi

app="$stage/Ink Engine.app"
ditto "$derived/Build/Products/Release/Ink Engine.app" "$app"
python3 Scripts/verify_speech_distribution.py "$app"
codesign --verify --deep --strict --verbose=2 "$app"
swift Scripts/verify_branding.swift "$PWD" "$app"
python3 - "$app" <<'PY'
import hashlib
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
source = Path('App/Resources/Speech')
packed = app / 'Contents/Resources/Speech'
def files(folder):
    return {p.relative_to(folder) for p in folder.rglob('*') if p.is_file() and p.name != '.DS_Store'}
assert files(source) == files(packed), 'Bundled speech resources differ from the source files'
for relative in sorted(files(source)):
    assert hashlib.sha256((source / relative).read_bytes()).digest() == hashlib.sha256((packed / relative).read_bytes()).digest(), str(relative)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'org.ailifelab.InkEngine'
assert info['LSMinimumSystemVersion'] == '26.0'
binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(app)], stderr=subprocess.DEVNULL))
assert entitlements.get('com.apple.security.app-sandbox') is True
assert not entitlements.get('com.apple.security.get-task-allow'), 'Debug entitlement must not be included'
for resource in ('AppIcon.icns', 'Assets.car'):
    assert (app / 'Contents/Resources' / resource).is_file(), resource
print(f'Verified {len(files(source))} bundled speech resources, app icon, identifier, minimum OS and architecture.')
PY

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
name="InkEngine-${version}-macOS-arm64-local"
output="$PWD/Releases/$version"
mkdir -p "$output"
ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明.txt" <<EOF
墨语引擎 Ink Engine ${version} · Mac 本地安装版

要求：Apple 芯片 Mac（M1 或更新），macOS 26 或更新。

安装：
1. 将 Ink Engine.app 拖到旁边的 Applications（应用程序）文件夹。
2. 从“应用程序”打开 Ink Engine（墨语引擎），无需 Xcode。
3. 安装完成后，可以推出磁盘映像并删除 DMG。

更新：先退出旧版，再将新版拖入“应用程序”并确认替换。
应用的标识保持不变，书库与偏好保存在应用数据目录中。
安装包不包含个人文稿、书签、历史或语音缓存。
ZipVoice Serena 女声与 Dylan 男声及运行库已内置。
Mac 额外提供 Qwen Serena 测试模型，初始朗读语速 1.25 倍；合成仍低于实时，适合分段试听。
以上模型均可本地离线合成；系统朗读使用已安装的音色。

签名身份：${MAC_SIGNING_IDENTITY}
本包是否经过 Apple 公证取决于后续公证步骤；本脚本不会自动上传 App Store。
如果使用临时签名，系统可能提示开发者无法验证；确认来源后，可在“系统设置 → 隐私与安全性”中点“仍要打开”。
Apple 官方说明：https://support.apple.com/zh-cn/102445
EOF

hdiutil create -volname "Ink Engine ${version}" -srcfolder "$stage" \
    -fs HFS+ -format UDZO -ov "$output/$name.dmg"
hdiutil verify "$output/$name.dmg"
(cd "$output" && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
cp "$stage/安装说明.txt" "$output/安装说明.txt"
print "Installer ready: $output/$name.dmg"
print "SHA-256: $output/$name.dmg.sha256"
