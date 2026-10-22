#!/usr/bin/env python3
"""Reject retired speech assets/symbols in a built app (not a legal attestation)."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess


def verify(app):
    mac = app / 'Contents/Info.plist'
    metadata = plistlib.loads((mac if mac.exists() else app / 'Info.plist').read_bytes())
    executable = (app / 'Contents/MacOS' if mac.exists() else app) / metadata['CFBundleExecutable']
    forbidden = re.compile(r'(?:^|/)(?:Matcha|Piper|espeak-ng-data|Sherpa[^/]*)(?:/|$)', re.I)
    paths = [str(p.relative_to(app)) for p in app.rglob('*') if forbidden.search(str(p.relative_to(app)))]
    if paths:
        raise ValueError('Retired assets remain: ' + ', '.join(paths[:20]))
    symbols = subprocess.check_output(['nm', '-a', str(executable)], text=True, stderr=subprocess.DEVNULL)
    # Search each token once. A leading greedy \S* retried at every character
    # becomes quadratic on long Swift mangled symbols in Release binaries.
    retired_symbol = re.compile(r'SherpaOnnx|[Ee]speak_|piper_phonemize|MatchaSynthesizer|VitsSynthesizer')
    found = sorted({match.group() for match in re.finditer(r'\S+', symbols) if retired_symbol.search(match.group())})
    if found:
        raise ValueError('Retired native symbols remain: ' + ', '.join(found[:20]))
    libraries = subprocess.check_output(['otool', '-L', str(executable)], text=True)
    if re.search(r'Sherpa|espeak|piper', libraries, re.I):
        raise ValueError('Retired linked library remains')
    resources = app / 'Contents/Resources' if mac.exists() else app
    zip_voice = resources / 'Speech/ZipVoice'
    for model in ('TextEncoder', 'FmDecoder', 'Vocos'):
        if not (zip_voice / (model + '.mlmodelc')).is_dir():
            raise ValueError('Retained ZipVoice model missing: ' + model)
    for data in ('tokens.txt', 'lexicon.txt', 'reference.json', 'reference-dylan.json'):
        if not (zip_voice / data).is_file():
            raise ValueError('Retained ZipVoice data missing: ' + data)
    print(f'Verified {app}: no retired assets, native symbols or linked libraries; ZipVoice present.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apps', nargs='+', type=Path)
    for app_path in parser.parse_args().apps:
        verify(app_path)
