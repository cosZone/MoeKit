#!/usr/bin/env python3
"""Only owned temporary evidence fixtures; no native filesystem mutation tests."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VERIFY = Path(__file__).with_name('verify-cache-fixture-evidence.py')
SHA = 'a' * 40

class CacheEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='MoeKit-cache-evidence-test-')
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.path = self.root / 'cache-native.json'
        self.record = dict(schema=1, sourceSHA=SHA, nativeTrashRestore=True, productionPolicy=True,
                           ownedManifestPurge=True, sourceDevice='1', sourceInode='42')
    def tearDown(self):
        self.temp.cleanup()
    def write(self):
        self.path.write_text(json.dumps(self.record))
        self.path.chmod(0o600)
    def accepted(self):
        return subprocess.run([sys.executable, str(VERIFY), '--directory', str(self.root), '--source-sha', SHA],
                              capture_output=True).returncode == 0
    def test_complete_exact_head_evidence(self):
        self.write()
        self.assertTrue(self.accepted())
    def test_missing_record(self):
        self.assertFalse(self.accepted())
    def test_wrong_head(self):
        self.record['sourceSHA'] = 'b' * 40
        self.write()
        self.assertFalse(self.accepted())
    def test_false_or_missing_claims(self):
        for key in ('nativeTrashRestore', 'productionPolicy', 'ownedManifestPurge'):
            with self.subTest(key=key):
                self.record[key] = False
                self.write()
                self.assertFalse(self.accepted())
                del self.record[key]
                self.write()
                self.assertFalse(self.accepted())
                self.record[key] = True
    def test_non_boolean_claim(self):
        self.record['ownedManifestPurge'] = 'true'
        self.write()
        self.assertFalse(self.accepted())
    def test_unknown_identity(self):
        self.record['sourceInode'] = '0'
        self.write()
        self.assertFalse(self.accepted())
    def test_symlink_record(self):
        self.write()
        original = self.root / 'other.json'
        self.path.rename(original)
        self.path.symlink_to(original)
        self.assertFalse(self.accepted())
    def test_untrusted_permissions(self):
        self.write()
        self.path.chmod(0o644)
        self.assertFalse(self.accepted())
    def test_incomplete_record(self):
        self.write()
        self.path.write_text('{')
        self.assertFalse(self.accepted())

if __name__ == '__main__':
    unittest.main()
