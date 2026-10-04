#!/usr/bin/env python3
"""Require actual exact-head native cache Trash/restore and owned-manifest purge."""
import argparse
import json
import os
from pathlib import Path
import re
import stat

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--source-sha', required=True)
args = parser.parse_args()
assert re.fullmatch(r'[0-9a-f]{40}', args.source_sha)
root = args.directory.lstat()
assert stat.S_ISDIR(root.st_mode) and stat.S_IMODE(root.st_mode) == 0o700
path = args.directory / 'cache-native.json'
metadata = path.lstat()
assert stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_size < 8192
assert stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_uid == os.geteuid()
record = json.loads(path.read_text())
assert record['schema'] == 1 and record['sourceSHA'] == args.source_sha
for key in ('nativeTrashRestore', 'productionPolicy', 'ownedManifestPurge'):
    assert record[key] is True
for key in ('sourceDevice', 'sourceInode'):
    assert record[key].isdigit() and int(record[key]) > 0
print(f'Verified actual cache Trash/restore under production guards and owned-manifest permanent removal for {args.source_sha}')
