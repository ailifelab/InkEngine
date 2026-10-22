#!/usr/bin/env python3
"""Keep generated Mac apps out of Launch Services; retain the installed app."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = Path('/Applications/Ink Engine.app')
REGISTRY = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def generated_apps():
    seen = set()
    for directory in (ROOT / 'build', ROOT / 'build.noindex'):
        if not directory.exists():
            continue
        for parent, directories, _ in os.walk(directory):
            for name in list(directories):
                if not name.endswith('.app'):
                    continue
                directories.remove(name)
                app = (Path(parent) / name).resolve()
                if app in seen:
                    continue
                seen.add(app)
                info = app / 'Contents/Info.plist'
                if not info.is_file():
                    info = app / 'Info.plist'
                try:
                    metadata = plistlib.loads(info.read_bytes())
                except (OSError, plistlib.InvalidFileException):
                    continue
                if metadata.get('CFBundleIdentifier') == 'org.ailifelab.InkEngine':
                    yield app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remove-built-apps', action='store_true', help='Remove completed build copies after installation; never remove a running app.')
    args = parser.parse_args()
    # lsregister can retain paths to already removed packaging stages.
    dump = subprocess.check_output([REGISTRY, '-dump'], text=True)
    for line in dump.splitlines():
        match = re.match(r'^path:\s+(.+?)(?: \(0x[0-9a-f]+\))?$', line)
        if not match:
            continue
        path = Path(match[1])
        if path.name == 'Ink Engine.app' and any(path.is_relative_to(ROOT / name) for name in ('build', 'build.noindex')):
            subprocess.run([REGISTRY, '-u', str(path)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    commands = subprocess.check_output(['ps', 'ax', '-o', 'args='], text=True).splitlines()
    active_builds = []
    for command in commands:
        if 'xcodebuild ' in command:
            match = re.search(r'-derivedDataPath\s+(\S+)', command)
            if match:
                active_builds.append(Path(match[1]).resolve())
    count = 0
    for app in generated_apps():
        subprocess.run([REGISTRY, '-u', str(app)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        count += 1
        aliases = [app]
        if app.is_relative_to(ROOT / 'build.noindex'):
            aliases.append(ROOT / 'build' / app.relative_to(ROOT / 'build.noindex'))
        running = any(line.lstrip().startswith(str(alias) + '/Contents/MacOS/') for line in commands for alias in aliases)
        building = any(app.is_relative_to(directory) for directory in active_builds)
        if args.remove_built_apps and not running and not building:
            shutil.rmtree(app)
            print('Removed completed build app:', app)
        else:
            print('Unregistered build app:', app)
    if CANONICAL.is_dir():
        subprocess.run([REGISTRY, '-f', str(CANONICAL)], check=True, stdout=subprocess.DEVNULL)
    print(f'Canonical Mac app: {CANONICAL}; {count} generated registrations removed.')


if __name__ == '__main__':
    main()
