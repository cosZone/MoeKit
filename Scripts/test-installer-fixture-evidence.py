#!/usr/bin/env python3
"""Synthetic verifier tests only; no macOS tools or user files are accessed."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('verify-installer-fixture-evidence.py')
SHA = 'a' * 40

class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(prefix='moekit-evidence-verifier-')
        self.root = Path(self.owned.name)
        self.root.chmod(0o700)
        self.records = {'native-trash': 'verified-trash-and-restore', 'mounted-image': 'verified-attach-and-detach', 'idle-use': 'noUseObserved'}
        for kind, result in self.records.items():
            path = self.root / f'{kind}.json'
            path.write_text(json.dumps({'schema': 1, 'kind': kind, 'sourceSHA': SHA,
                'detail': {'result': result, 'sourceDevice': '12', 'sourceInode': '34', 'observedRefusal': 'true'}}))
            path.chmod(0o600)
    def tearDown(self):
        self.owned.cleanup()
    def run_check(self, sha=SHA):
        return subprocess.run([sys.executable, str(SCRIPT), '--directory', str(self.root), '--source-sha', sha], capture_output=True).returncode
    def test_exact_complete_evidence_passes(self):
        self.assertEqual(self.run_check(), 0)
    def test_missing_skipped_fixture_refuses(self):
        (self.root / 'idle-use.json').unlink()
        self.assertNotEqual(self.run_check(), 0)
    def test_other_commit_refuses(self):
        self.assertNotEqual(self.run_check('b' * 40), 0)
    def test_symlink_refuses(self):
        (self.root / 'idle-use.json').unlink()
        (self.root / 'idle-use.json').symlink_to(self.root / 'native-trash.json')
        self.assertNotEqual(self.run_check(), 0)
    def test_loose_permissions_refuse(self):
        (self.root / 'idle-use.json').chmod(0o644)
        self.assertNotEqual(self.run_check(), 0)
    def test_wrong_result_refuses(self):
        p = self.root / 'idle-use.json'
        value = json.loads(p.read_text()); value['detail']['result'] = 'unavailable'
        p.write_text(json.dumps(value))
        self.assertNotEqual(self.run_check(), 0)

if __name__ == '__main__':
    unittest.main()
