#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
spec = importlib.util.spec_from_file_location("evidence", Path(__file__).with_name("verify-process-fixture-evidence.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class EvidenceTests(unittest.TestCase):
    def test_requires_affirmative_exact_source(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            sha = "a" * 40
            with self.assertRaises(ValueError): module.verify(directory, sha)
            path = directory / "process-fixture-test.json"
            evidence = {"source_sha": sha, "checks": dict.fromkeys(module.CHECKS, True)}
            path.write_text(json.dumps(evidence))
            module.verify(directory, sha)
            with self.assertRaises(ValueError): module.verify(directory, "b" * 40)
            for check in module.CHECKS:
                changed = {"source_sha": sha, "checks": {**evidence["checks"], check: False}}
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError): module.verify(directory, sha)
            path.write_text(json.dumps({"source_sha": sha, "checks": {}}))
            with self.assertRaises(ValueError): module.verify(directory, sha)
    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            actual = directory / "other"
            actual.write_text("{}")
            (directory / "process-fixture-test.json").symlink_to(actual)
            with self.assertRaises(ValueError): module.verify(directory, "a" * 40)

if __name__ == "__main__": unittest.main()
