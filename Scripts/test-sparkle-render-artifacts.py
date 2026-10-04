#!/usr/bin/env python3
"""Synthetic verifier tests only; never report these as UI rendering."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


verifier = load("sparkle_render", "verify-sparkle-render-artifacts.py")
raster = load("raster", "test-ui-render-artifacts.py")


class SparkleRenderArtifactTests(unittest.TestCase):
    def fixture(self, root, language="en"):
        entries = []
        for state in ("enabled", "disabled", "unconfigured", "failed"):
            for appearance in ("light", "dark"):
                prefix = f"sparkle-settings-{state}-{language}-{appearance}-520x520"
                (root / (prefix + ".png")).write_bytes(raster.png(520, 520))
                scope = (f"Content size: 520 × 520 points\nBundle language: {language}\n"
                         f"Process locale: {'zh_CN' if language == 'zh-Hans' else 'en_US'}\n"
                         f"Automatic check title: {'自动检查更新' if language == 'zh-Hans' else 'Automatically check for updates'}\n"
                         f"Network requests: 0\nInstaller launches: 0\nScenario: {state}\n"
                         f"Visible required controls: {6 if state in {'enabled','disabled'} else 3}\n"
                         "Scope: owned settings view, synthetic updater driver, no production signing key.\n"
                         "Evidence source: public SwiftUI bounds anchors on displayed views\n")
                (root / (prefix + ".txt")).write_text(scope)
                entries.extend([{"exportedFileName": prefix + ".png", "suggestedHumanReadableName": prefix + "_0.png"},
                                {"exportedFileName": prefix + ".txt", "suggestedHumanReadableName": prefix + "-scope_0.txt"}])
        (root / "manifest.json").write_text(json.dumps([{"attachments": entries}]))
        return entries

    def test_complete_languages(self):
        for language in ("en", "zh-Hans"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.fixture(root, language)
                self.assertEqual(verifier.verify(root, language), 8)

    def test_missing_controls_or_scope_fail(self):
        for replacement in ("Visible required controls: 0", "Installer launches: 1", "Bundle language: wrong"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); entries = self.fixture(root)
                scope = root / entries[1]["exportedFileName"]
                content = scope.read_text(); key = replacement.split(":")[0]
                scope.write_text("\n".join(replacement if line.startswith(key + ":") else line for line in content.splitlines()))
                with self.assertRaises(ValueError): verifier.verify(root, "en")

    def test_missing_image_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); entries = self.fixture(root)
            (root / "manifest.json").write_text(json.dumps([{"attachments": entries[1:]}]))
            with self.assertRaises(ValueError): verifier.verify(root, "en")

    def test_duplicate_image_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); entries = self.fixture(root)
            (root / "manifest.json").write_text(json.dumps([{"attachments": entries + entries[:1]}]))
            with self.assertRaises(ValueError): verifier.verify(root, "en")


if __name__ == "__main__": unittest.main()
