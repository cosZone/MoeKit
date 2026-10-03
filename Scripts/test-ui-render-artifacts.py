#!/usr/bin/env python3
"""Synthetic-only checks for the render artifact verifier."""

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("render_verifier", Path(__file__).with_name("verify-ui-render-artifacts.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RenderArtifactTests(unittest.TestCase):
    def fixture(self, root, language):
        scenarios = ["demo-projects-inspector", "demo-tasks-result"]
        if language == "en":
            scenarios += ["demo-mole-space", "demo-processes-unavailable"]
        attachments = []
        for scenario in scenarios:
            for appearance in ("light", "dark"):
                for width, height in ((960, 620), (1280, 800)):
                    name = f"{scenario}-{language}-{appearance}-{width}x{height}"
                    png = name + ".png"
                    (root / png).write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" + struct.pack(">II", width, height))
                    text = name + ".txt"
                    (root / text).write_text(f"Bundle language: {language}\nProjects title: {'项目' if language == 'zh-Hans' else 'Projects'}\nPartial-result title: {'部分结果' if language == 'zh-Hans' else 'Partial result'}\nContent size: {width} × {height} points\nProcess locale: {'zh_CN' if language == 'zh-Hans' else 'en_US'}\n")
                    attachments.extend([
                        {"exportedFileName": png, "suggestedHumanReadableName": name + "_0_UUID.png"},
                        {"exportedFileName": text, "suggestedHumanReadableName": name + "-scope_0_UUID.txt"},
                    ])
        manifest = [{"attachments": attachments}]
        (root / "manifest.json").write_text(json.dumps(manifest))
        return manifest

    def test_complete_english_and_chinese(self):
        for language, count in [("en", 16), ("zh-Hans", 8)]:
            with self.subTest(language=language), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                self.fixture(root, language)
                self.assertEqual(module.verify(root, language), count)

    def test_rejects_model_fallback(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            manifest = self.fixture(root, "zh-Hans")
            text = root / manifest[0]["attachments"][1]["exportedFileName"]
            text.write_text(text.read_text().replace("Projects title: 项目", "Projects title: Projects"))
            with self.assertRaisesRegex(ValueError, "localization"):
                module.verify(root, "zh-Hans")

    def test_rejects_missing_capture(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            manifest = self.fixture(root, "zh-Hans")
            manifest[0]["attachments"].pop()
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "Expected 8"):
                module.verify(root, "zh-Hans")

    def test_rejects_wrong_dimensions(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            manifest = self.fixture(root, "en")
            png = root / manifest[0]["attachments"][0]["exportedFileName"]
            png.write_bytes(png.read_bytes()[:16] + struct.pack(">II", 960, 596))
            with self.assertRaisesRegex(ValueError, "dimensions"):
                module.verify(root, "en")

    def test_rejects_path_escape(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            manifest = self.fixture(root, "en")
            manifest[0]["attachments"][0]["exportedFileName"] = "../outside.png"
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "direct child"):
                module.verify(root, "en")


if __name__ == "__main__":
    unittest.main()
