#!/bin/zsh
# Replace the canonical Mac app after verifying signature, branding and version.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
    print -u2 'Usage: Scripts/install_mac.sh /path/to/Ink\ Engine.app'
    exit 1
fi
source_app="${1:A}"
target_app='/Applications/Ink Engine.app'
codesign --verify --deep --strict "$source_app"
swift Scripts/verify_branding.swift "$PWD" "$source_app"
python3 - "$source_app" "$target_app" <<'PY'
import plistlib
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:])
candidate = plistlib.loads((source/'Contents/Info.plist').read_bytes())
assert candidate['CFBundleIdentifier'] == 'org.ailifelab.InkEngine', 'Unexpected bundle identifier'
def release(info):
    def parts(value):
        result = tuple(map(int, value.split('.')))
        return result + (0,) * (3 - len(result))
    return parts(info['CFBundleShortVersionString']), parts(info['CFBundleVersion'])
if target.exists():
    current = plistlib.loads((target/'Contents/Info.plist').read_bytes())
    assert current['CFBundleIdentifier'] == candidate['CFBundleIdentifier']
    assert release(candidate) >= release(current), 'Refusing to downgrade the installed Mac app'
print('Verified install version:', candidate['CFBundleShortVersionString'], candidate['CFBundleVersion'])
PY
swift - <<'SWIFT'
import AppKit
import Foundation
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "org.ailifelab.InkEngine")
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(20)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("Installation stopped because the app has not exited; save any pending document first.\n", stderr)
    exit(1)
}
SWIFT
stage=$(mktemp -d '/Applications/.InkEngine-update.XXXXXX')
backup="$PWD/build/MacInstallRollback"
mkdir -p "$backup"
old_app="$backup/Ink Engine.app"
if [[ -e "$old_app" ]]; then
    print -u2 "A previous install backup still exists: $old_app"
    exit 1
fi
trap 'rm -rf "$stage"' EXIT
ditto "$source_app" "$stage/Ink Engine.app"
codesign --verify --deep --strict "$stage/Ink Engine.app"
swift Scripts/verify_branding.swift "$PWD" "$stage/Ink Engine.app"
registry='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
if [[ -d "$target_app" ]]; then
    "$registry" -u "$target_app" || true
    mv "$target_app" "$old_app"
fi
if ! mv "$stage/Ink Engine.app" "$target_app"; then
    [[ ! -d "$old_app" ]] || mv "$old_app" "$target_app"
    "$registry" -f "$target_app" || true
    exit 1
fi
codesign --verify --deep --strict "$target_app"
swift Scripts/verify_branding.swift "$PWD" "$target_app"
"$registry" -f "$target_app"
# Keep one non-runnable rollback archive instead of another registered .app copy.
if [[ -d "$old_app" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$old_app" "$backup/previous-mac-app.zip"
    rm -rf "$old_app"
fi
print "Installed and verified: $target_app"
