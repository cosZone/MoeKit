#!/usr/bin/env python3
"""Require affirmative exact-commit native fixture evidence, never skipped passes."""
import argparse
import json
import os
from pathlib import Path
import re
import stat

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--source-sha', required=True)
parser.add_argument('--kinds', nargs='+', default=['native-trash', 'mounted-image', 'idle-use', 'live-mole'])
args = parser.parse_args()
assert re.fullmatch(r'[0-9a-f]{40}', args.source_sha), 'invalid source SHA'
expected = {'native-trash': 'verified-trash-and-restore', 'mounted-image': 'verified-attach-and-detach', 'idle-use': 'noUseObserved', 'live-mole': 'verified-live-selection-trash-and-restore'}
assert set(args.kinds) <= expected.keys()
root = args.directory.lstat()
assert stat.S_ISDIR(root.st_mode) and stat.S_IMODE(root.st_mode) == 0o700
for kind in args.kinds:
    path = args.directory / f'{kind}.json'
    metadata = path.lstat()
    assert stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_size < 8192
    assert stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_uid == os.geteuid()
    record = json.loads(path.read_text())
    assert record['schema'] == 1 and record['kind'] == kind and record['sourceSHA'] == args.source_sha
    assert record['detail']['result'] == expected[kind]
    if kind == 'idle-use':
        assert record['detail']['observedUseControl'] == 'true'
    if kind == 'native-trash':
        assert record['detail']['duplicateNamesPreserved'] == 'true'
    if kind == 'live-mole':
        assert record['detail']['storeConfirmation'] == 'true'
    if kind == 'mounted-image':
        assert record['detail']['observedRefusal'] == 'true'
        assert record['detail']['crossDeviceRefusal'] == 'true'
    for key in ('sourceDevice', 'sourceInode'):
        assert record['detail'][key].isdigit() and int(record['detail'][key]) > 0
    print(f'Verified actual {kind} fixture for {args.source_sha}')
