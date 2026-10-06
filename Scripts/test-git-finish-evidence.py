#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('finish_evidence', Path(__file__).with_name('verify-git-finish-evidence.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FinishEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.path = self.root / 'git-finish-native.json'
        self.record = dict(schema=1, sourceSHA='a' * 40, sourceDevice='1', sourceInode='2', previousOID='b' * 40, verifiedOID='c' * 40)
        self.keys = ('fastForward', 'primaryClean', 'retainedPreviousFiles', 'retainedPreviousIndex', 'retainedPreviousRef', 'separateRetirement', 'separateRestore', 'outsideUntouched')
        self.record.update({key: True for key in self.keys})

    def write(self):
        self.path.write_text(json.dumps(self.record))
        self.path.chmod(0o600)

    def test_complete_exact_head(self):
        self.write()
        self.assertEqual(module.verify(self.root, 'a' * 40), self.record)

    def test_missing_or_numeric_success_refused(self):
        for key in self.keys:
            for invalid in (False, 1, None):
                with self.subTest(key=key, invalid=invalid):
                    self.record[key] = invalid
                    self.write()
                    with self.assertRaises(ValueError): module.verify(self.root, 'a' * 40)
            self.record[key] = True

    def test_wrong_head_noop_and_permissions_refused(self):
        self.write()
        with self.assertRaises(ValueError): module.verify(self.root, 'b' * 40)
        self.record['previousOID'] = self.record['verifiedOID']
        self.write()
        with self.assertRaises(ValueError): module.verify(self.root, 'a' * 40)
        self.record['previousOID'] = 'b' * 40
        self.write(); self.path.chmod(0o644)
        with self.assertRaises(ValueError): module.verify(self.root, 'a' * 40)


if __name__ == '__main__': unittest.main()
