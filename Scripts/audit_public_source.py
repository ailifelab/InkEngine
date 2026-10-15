#!/usr/bin/env python3
"""Audit public Git candidates or staged blobs without printing secrets."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_SUFFIXES = {'.p12', '.pfx', '.pem', '.key', '.cer', '.der', '.csr', '.p8', '.mobileprovision', '.provisionprofile', '.keychain', '.keychain-db'}
BINARY_SUFFIXES = {'.onnx', '.safetensors', '.pt', '.pth', '.npy', '.ipa', '.dmg', '.zip', '.tar', '.bz2'}
PRIVATE_ROOTS = {'build', '.build', 'Releases', 'SafetyBackups', 'TestResults', 'Screenshots', 'DerivedData'}
RULES = {
    'private-key material': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'provider token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}|AKIA[A-Z0-9]{16})\b'),
    'personal absolute home path': re.compile(rb'/[U]sers/(?!Shared(?:/|$))[^/\s"\'<>]+/'),
    'physical device identifier': re.compile(rb'\b0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}\b'),
}

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])

def check(name, data, private_values=()):
    path = Path(name)
    issues = []
    if path.suffix.lower() in PRIVATE_SUFFIXES or '.local.' in path.name or path.name.startswith('.env'):
        issues.append('private configuration or credential file')
    if path.parts[0] in PRIVATE_ROOTS or any(part in {'xcuserdata', '__pycache__', 'Frameworks'} for part in path.parts):
        issues.append('local or generated artifact')
    if path.suffix.lower() in BINARY_SUFFIXES or any(part.endswith(('.mlmodelc', '.mlpackage', '.app', '.xcarchive', '.xcresult')) for part in path.parts):
        issues.append('binary dependency or delivery artifact')
    if len(data) > 5 * 1024 * 1024 and path.parts[0] not in {'Branding', 'App'}:
        issues.append('unexpected large file')
    for label, pattern in RULES.items():
        if pattern.search(data): issues.append(label)
    if any(value.encode() in data for value in private_values if value):
        issues.append('local signing identity')
    return issues

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Read staged blobs, not working copies')
    args = parser.parse_args()
    local = ROOT / 'Config/IPA.local.json'
    private_values = []
    if local.is_file():
        team = json.loads(local.read_text()).get('team_id')
        if team: private_values.append(team)
    raw = git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z') if args.staged else git('ls-files', '--cached', '--others', '--exclude-standard', '-z')
    names = sorted(set(raw.decode().split('\0')) - {''})
    failures = []
    for name in names:
        path = ROOT / name
        if args.staged: data = git('show', ':' + name)
        elif path.is_file(): data = path.read_bytes()
        else: continue
        if path.is_symlink(): failures.append((name, ['source symlink requires review'])); continue
        issues = check(name, data, private_values)
        if issues: failures.append((name, issues))
    for name, issues in failures: print(name + ': ' + ', '.join(issues))
    print(f'Checked {len(names)} {"staged" if args.staged else "candidate"} paths; {len(failures)} failures.')
    return 1 if failures else 0

if __name__ == '__main__':
    sys.exit(main())
