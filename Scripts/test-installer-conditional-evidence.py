#!/usr/bin/env python3
"""Adversarial, no-native-mutation tests for source-bound conditional evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('conditional', ROOT / 'Scripts/verify-installer-conditional-evidence.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class ConditionalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.sha = 'a' * 40
        self.provider = (ROOT / 'Sources/Installer/InstallerUseEvidence.swift').read_bytes()
        self.provenance, self.contract = proof.verify_baseline()
        self.record = {'schema': 1, 'kind': 'idle-use-unsupported-environment', 'sourceSHA': self.sha,
                       'providerSHA256': proof.PROVIDER_SHA, 'compilerContractSHA256': proof.CONTRACT_SHA,
                       'detail': {'result': 'unsupported-current-environment', 'fullProviderResult': 'unavailable-attached-images',
                                  'fullProviderReason': proof.REFUSAL, 'handlePositiveControl': 'observedHandleUse',
                                  'handleNegativeControl': 'noHandleUseObserved', 'inventoryStable': 'true',
                                  'inventoryBeforeCount': '1', 'inventoryAfterCount': '1', 'fixtureCleanup': 'verified',
                                  'priorIdenticalSourcePositiveRequired': 'true', 'sourceDevice': '7', 'sourceInode': '9'}}
        self.invocation = {'schema': 1, 'sourceSHA': self.sha, 'probeExit': 3, 'providerSHA256': proof.PROVIDER_SHA,
                           'harnessSHA256': proof.digest((ROOT / 'Scripts/InstallerIdleProbe.swift').read_bytes()),
                           'providerUnchangedAfterRun': True, 'contract': self.contract,
                           'compilerContractSHA256': proof.CONTRACT_SHA, 'hostedRunner': 'github-hosted',
                           'resolvedCompiler': self.contract['developerDirectory'] + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
                           'architecture': 'x86_64', 'osMajor': '15'}

    def verify(self, record=None, provider=None, invocation=None, baseline=None):
        return proof.verify_conditional(record or self.record, self.sha, provider or self.provider,
                                        invocation or self.invocation, baseline or proof.BASELINE)

    def test_retained_real_zip_and_distinct_current_status(self):
        result = self.verify()
        self.assertFalse(result['currentNoUseObserved'])
        self.assertEqual(result['kind'], 'idle-use-conditional-verification')
        self.assertEqual(result['priorPositive']['artifactID'], 11304509105)
        self.assertNotEqual(result['sourceSHA'], result['priorPositive']['sourceSHA'])

    def test_read_accepts_atime_only_change_but_rejects_identity_fields(self):
        with tempfile.TemporaryDirectory(prefix='moekit-conditional-atime-test-') as name:
            path = Path(name) / 'owned.txt'
            path.write_bytes(b'x')
            before = path.lstat()
            attributes = {key: getattr(before, key) for key in dir(before) if key.startswith('st_')}
            after = SimpleNamespace(**attributes)
            after.st_atime += 10
            after.st_atime_ns += 10_000_000_000
            with patch.object(Path, 'lstat', side_effect=[before, after]):
                self.assertEqual(proof.bounded_file(path, 1), b'x')
            for field in ('st_ino', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_flags'):
                changed = SimpleNamespace(**vars(after))
                setattr(changed, field, getattr(changed, field, 0) + 1)
                with self.subTest(field=field), patch.object(Path, 'lstat', side_effect=[before, changed]):
                    with self.assertRaises(ValueError): proof.bounded_file(path, 1)

    def test_current_timeout_or_generic_unavailable_rejected(self):
        for result in ('timeout', 'unavailable', 'noUseObserved', 'skipped'):
            with self.subTest(result=result):
                record = copy.deepcopy(self.record)
                record['detail']['fullProviderResult'] = result
                with self.assertRaises(ValueError): self.verify(record=record)

    def test_exact_refusal_text_required(self):
        record = copy.deepcopy(self.record)
        record['detail']['fullProviderReason'] = 'The disk-image inventory reached its time limit; no file was moved.'
        with self.assertRaises(ValueError): self.verify(record=record)

    def test_empty_partial_changed_or_unbounded_inventory_rejected(self):
        for before, after, stable in [('0', '0', 'true'), ('', '1', 'true'), ('1', '2', 'true'), ('1', '1', 'false'), ('65', '65', 'true')]:
            with self.subTest(before=before, after=after, stable=stable):
                record = copy.deepcopy(self.record)
                record['detail'].update(inventoryBeforeCount=before, inventoryAfterCount=after, inventoryStable=stable)
                with self.assertRaises(ValueError): self.verify(record=record)

    def test_missing_fresh_handle_controls_and_cleanup_rejected(self):
        for field in ('handlePositiveControl', 'handleNegativeControl', 'fixtureCleanup', 'priorIdenticalSourcePositiveRequired'):
            with self.subTest(field=field):
                record = copy.deepcopy(self.record)
                record['detail'][field] = 'unavailable'
                with self.assertRaises(ValueError): self.verify(record=record)

    def test_provider_change_invalidates_historical_proof(self):
        with self.assertRaises(ValueError): self.verify(provider=self.provider + b'\n')

    def test_compiler_flag_or_environment_change_rejected(self):
        for field, value in [('arguments', ['-O']), ('developerDirectory', '/Applications/Xcode_New.app/Contents/Developer'),
                             ('runner', 'macos-latest'), ('architecture', 'arm64')]:
            with self.subTest(field=field):
                invocation = copy.deepcopy(self.invocation)
                invocation['contract'][field] = value
                with self.assertRaises(ValueError): self.verify(invocation=invocation)

    def test_no_exit3_or_changed_runtime_bindings_rejected(self):
        for field, value in [('probeExit', 0), ('sourceSHA', 'b' * 40), ('providerSHA256', '0' * 64),
                             ('compilerContractSHA256', '0' * 64), ('harnessSHA256', '0' * 64),
                             ('providerUnchangedAfterRun', False), ('hostedRunner', 'self-hosted'), ('osMajor', '14')]:
            with self.subTest(field=field):
                invocation = copy.deepcopy(self.invocation)
                invocation[field] = value
                with self.assertRaises(ValueError): self.verify(invocation=invocation)

    def test_wrong_current_head_kind_or_positive_relabel_rejected(self):
        for field, value in [('sourceSHA', proof.BASELINE_SHA), ('kind', 'idle-use'), ('schema', 2),
                             ('providerSHA256', '0' * 64), ('compilerContractSHA256', '0' * 64)]:
            with self.subTest(field=field):
                record = copy.deepcopy(self.record)
                record[field] = value
                with self.assertRaises(ValueError): self.verify(record=record)

    def test_missing_or_modified_prior_zip_rejected(self):
        with tempfile.TemporaryDirectory(prefix='moekit-conditional-verifier-test-') as name:
            root = Path(name)
            with self.assertRaises(FileNotFoundError): self.verify(baseline=root)
            (root / 'native-idle-use-bffd923.zip').write_bytes(b'not the real archive')
            with self.assertRaises(ValueError): self.verify(baseline=root)

    def test_absent_prior_duplicate_positive_rejected(self):
        record = {'schema': 1, 'kind': 'idle-use', 'sourceSHA': proof.BASELINE_SHA,
                  'detail': {'result': 'noUseObserved', 'sourceDevice': '7', 'sourceInode': '9'}}
        with self.assertRaises(ValueError): proof.prior_positive(record)

    def test_current_refusal_matches_immutable_provider_literal(self):
        self.assertIn(('String(localized: "' + proof.REFUSAL + '")').encode(), self.provider)

    def test_changed_prior_public_provenance_rejected(self):
        with tempfile.TemporaryDirectory(prefix='moekit-conditional-provenance-test-') as name:
            root = Path(name)
            for path in proof.BASELINE.iterdir():
                (root / path.name).write_bytes(path.read_bytes())
            provenance = dict(self.provenance)
            provenance['jobID'] += 1
            (root / 'provenance.json').write_text(json.dumps(provenance))
            with self.assertRaises(ValueError): self.verify(baseline=root)


if __name__ == '__main__':
    unittest.main()
