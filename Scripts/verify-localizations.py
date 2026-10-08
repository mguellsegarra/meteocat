#!/usr/bin/env python3
"""Check translation coverage, substitution arguments and packaged macOS resources."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys

LANGUAGES = {'ca', 'oc', 'es', 'eu', 'gl', 'en', 'fr', 'de', 'it', 'pt', 'nl', 'ro',
             'ar', 'zgh', 'ur', 'zh-hans', 'uk', 'ru', 'pl', 'pa', 'bn'}
ENTRY = re.compile(r'^\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;\s*$')
ARGUMENT = re.compile(r'%(?:([1-9][0-9]*)\$)?(@|[a-zA-Z])')


def read_strings(path):
    # plutil validates Foundation syntax; the line pass also catches duplicate keys
    # that a dictionary parser would discard.
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)],
                            check=True, capture_output=True, text=True)
    table = json.loads(result.stdout)
    seen = set()
    content = re.sub(r'/\*.*?\*/', '', path.read_text(encoding='utf-8'), flags=re.S)
    for number, line in enumerate(content.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('//'):
            continue
        match = ENTRY.fullmatch(line)
        if not match:
            raise ValueError(f'{path}:{number}: expected one quoted entry per line')
        key = json.loads(match[1])
        if key in seen:
            raise ValueError(f'{path}:{number}: duplicate key {key!r}')
        seen.add(key)
    if seen != set(table):
        raise ValueError(f'{path}: inconsistent parsed keys')
    return table


def arguments(value):
    return Counter(ARGUMENT.findall(value.replace('%%', '')))


def check_table(path, source):
    translated = read_strings(path)
    missing, extra = source.keys() - translated.keys(), translated.keys() - source.keys()
    if missing or extra:
        raise ValueError(f'{path}: missing={sorted(missing)}, extra={sorted(extra)}')
    for key, value in translated.items():
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f'{path}: empty translation for {key!r}')
        if arguments(value) != arguments(source[key]):
            raise ValueError(f'{path}: argument mismatch for {key!r}')
    return len(translated)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='also check a packaged .app')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    resources = root / 'Sources/MeteocatApp/Resources'
    localized = {p.stem.lower(): p for p in resources.glob('*.lproj')}
    if set(localized) != LANGUAGES:
        raise ValueError(f'Expected 21 languages; missing={LANGUAGES - localized.keys()}, extra={localized.keys() - LANGUAGES}')
    source = read_strings(localized['ca'] / 'Localizable.strings')
    info = read_strings(localized['ca'] / 'InfoPlist.strings')
    if set(info) != {'NSLocationUsageDescription'}:
        raise ValueError('Expected NSLocationUsageDescription in InfoPlist.strings')
    for language, folder in sorted(localized.items()):
        check_table(folder / 'Localizable.strings', source)
        check_table(folder / 'InfoPlist.strings', info)
        label = read_strings(folder / 'Localizable.strings')['Usa la ubicació actual']
        permission = read_strings(folder / 'InfoPlist.strings')['NSLocationUsageDescription']
        if label not in permission:
            raise ValueError(f'{folder}: location permission does not name the translated button')
    print(f'Validated {len(localized)} languages, {len(source)} UI keys per language and localized location permission text.')
    if options.app:
        app_resources = options.app / 'Contents/Resources'
        packaged = {p.stem.lower(): p for p in app_resources.glob('*.lproj')}
        if set(packaged) != LANGUAGES:
            raise ValueError('Packaged app is missing top-level localizations')
        bundle_resources = app_resources / 'MeteocatNative_MeteocatApp.bundle'
        if (bundle_resources / 'Contents/Resources').is_dir():
            bundle_resources /= 'Contents/Resources'
        bundled = {p.stem.lower(): p for p in bundle_resources.glob('*.lproj')}
        if set(bundled) != LANGUAGES:
            raise ValueError('Packaged SwiftPM app bundle is missing language tables')
        for language, folder in packaged.items():
            check_table(folder / 'InfoPlist.strings', info)
            if read_strings(folder / 'InfoPlist.strings') != read_strings(localized[language] / 'InfoPlist.strings'):
                raise ValueError(f'{folder}: packaged permission translation differs from source')
            result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(bundled[language] / 'Localizable.strings')],
                                    check=True, capture_output=True, text=True)
            if json.loads(result.stdout) != read_strings(localized[language] / 'Localizable.strings'):
                raise ValueError(f'{bundled[language]}: packaged UI translation differs from source')
        result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(options.app / 'Contents/Info.plist')],
                                check=True, capture_output=True, text=True)
        settings = json.loads(result.stdout)
        if settings.get('CFBundleDevelopmentRegion') != 'ca':
            raise ValueError('Packaged app must use Catalan as development language')
        if {v.lower() for v in settings.get('CFBundleLocalizations', [])} != LANGUAGES:
            raise ValueError('Packaged CFBundleLocalizations must declare all 21 languages')
        print('Validated packaged language declarations and location permission resources.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Localization verification failed: {error}', file=sys.stderr)
        sys.exit(1)
