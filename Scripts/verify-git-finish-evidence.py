#!/usr/bin/env python3
"""Require exact-head real native local merge/verify/retire/restore evidence."""
import argparse
import json
import os
from pathlib import Path
import re
import stat


def verify(directory, source_sha):
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Invalid source SHA')
    root = directory.lstat()
    if not stat.S_ISDIR(root.st_mode) or stat.S_IMODE(root.st_mode) != 0o700 or root.st_uid != os.geteuid():
        raise ValueError('Untrusted evidence directory')
    path = directory / 'git-finish-native.json'
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or not 0 < metadata.st_size < 8192 or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.geteuid():
        raise ValueError('Untrusted evidence file')
    record = json.loads(path.read_text())
    if type(record.get('schema')) is not int or record['schema'] != 1 or record.get('sourceSHA') != source_sha:
        raise ValueError('Wrong schema/source')
    for key in ('fastForward', 'primaryClean', 'retainedPreviousFiles', 'retainedPreviousIndex', 'retainedPreviousRef', 'separateRetirement', 'separateRestore', 'outsideUntouched'):
        if record.get(key) is not True:
            raise ValueError('Incomplete native lifecycle: ' + key)
    for key in ('sourceDevice', 'sourceInode'):
        if not isinstance(record.get(key), str) or not record[key].isdigit() or int(record[key]) <= 0:
            raise ValueError('Missing fixture identity')
    for key in ('previousOID', 'verifiedOID'):
        if not isinstance(record.get(key), str) or not re.fullmatch(r'[0-9a-f]{40}', record[key]) or record[key] == '0' * 40:
            raise ValueError('Invalid commit evidence')
    if record['previousOID'] == record['verifiedOID']:
        raise ValueError('A no-op is not merge evidence')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    verify(args.directory, args.source_sha)
    print('Verified native fast-forward, local checkout/index, retained originals, separate retirement and restore for ' + args.source_sha)
