#!/usr/bin/env python3
"""Verify the scene declaration in the source plist and, optionally, an IPA."""
import argparse
from pathlib import Path
import plistlib
import zipfile

root = Path(__file__).resolve().parents[2]


def check(info, label):
    manifest = info.get('UIApplicationSceneManifest')
    assert isinstance(manifest, dict), f'{label}: missing UIApplicationSceneManifest'
    # Madeira's Wine runtime and session state are process-wide. Scene lifecycle
    # adoption must not also opt this app into concurrent game windows.
    assert manifest.get('UIApplicationSupportsMultipleScenes') is False, f'{label}: expected a single scene'
    assert manifest.get('UISceneConfigurations') == {}, f'{label}: let SwiftUI App supply its scene configuration'
    print(f'PASS {label}: explicit single-scene SwiftUI lifecycle')
    return manifest


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ipa', type=Path)
args = parser.parse_args()
expected = check(plistlib.loads((root / 'app/Madeira/Info.plist').read_bytes()), 'source Info.plist')
if args.ipa:
    with zipfile.ZipFile(args.ipa) as archive:
        info = plistlib.loads(archive.read('Payload/Madeira.app/Info.plist'))
    assert check(info, str(args.ipa)) == expected, 'packaging changed the scene manifest'
