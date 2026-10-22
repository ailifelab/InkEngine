#!/usr/bin/env python3
"""Check shipped translations, interpolated arguments and offline policy coverage."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('zh-Hans', 'en', 'zh-Hant')


def string_end(source, start):
    index = start + 1
    while index < len(source):
        if source.startswith('\\(', index):
            index = expression_end(source, index + 2)
        elif source[index] == '\\':
            index += 2
        elif source[index] == '"':
            return index + 1
        else:
            index += 1
    raise ValueError('Unterminated Swift string')


def expression_end(source, start):
    depth, index = 1, start
    while index < len(source):
        if source[index] == '"':
            index = string_end(source, index)
            continue
        if source[index] == '(':
            depth += 1
        elif source[index] == ')':
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError('Unterminated Swift interpolation')


def message_key(literal):
    source, result, index = literal[1:-1], '', 0
    while index < len(source):
        if source.startswith('\\(', index):
            result += '%@'
            index = expression_end(source, index + 2)
        elif source[index] == '\\':
            character = source[index + 1]
            result += {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}.get(character, '\\' + character)
            index += 2
        else:
            result += source[index]
            index += 1
    return result


def read_strings(path):
    # plutil also rejects malformed OpenStep strings syntax.
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main():
    catalogs = {language: read_strings(ROOT / 'Sources/InkCore/Resources' / (language + '.lproj') / 'Localizable.strings') for language in LANGUAGES}
    reference = catalogs['zh-Hans']
    for language, strings in catalogs.items():
        if strings.keys() != reference.keys():
            raise ValueError(f'{language}: translation keys differ from Simplified Chinese')
        for key, value in strings.items():
            if not value:
                raise ValueError(f'{language}: empty translation for {key!r}')
            placeholders = lambda text: sorted(re.findall(r'%(?:\d+\$)?@', text))
            if placeholders(key) != placeholders(value):
                raise ValueError(f'{language}: mismatched arguments for {key!r}')
        info = read_strings(ROOT / 'App/Resources/Localization' / (language + '.lproj') / 'InfoPlist.strings')
        if not info.get('CFBundleDisplayName') or not info.get('NSLocalNetworkUsageDescription'):
            raise ValueError(f'{language}: missing app name or local network permission explanation')
        for policy in ('privacy', 'usage'):
            if not (ROOT / 'App/Resources/Legal' / f'{policy}-{language}.md').is_file():
                raise ValueError(f'{language}: missing {policy} policy')
    count = 0
    for directory in ('App', 'Sources/InkCore'):
        for path in (ROOT / directory).rglob('*.swift'):
            source = path.read_text()
            for match in re.finditer(r'L10n\.tr\(\s*"', source):
                start = match.end() - 1
                key = message_key(source[start:string_end(source, start)])
                if key not in reference:
                    raise ValueError(f'{path.relative_to(ROOT)}: missing translation for {key!r}')
                count += 1
    print(f'Localization verified: {len(reference)} messages × {len(LANGUAGES)} languages; {count} call sites; permission strings and offline policies complete.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
