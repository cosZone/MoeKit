#!/usr/bin/env python3
"""Synthetic-only checks for the render artifact verifier."""

import binascii
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location("render_verifier", Path(__file__).with_name("verify-ui-render-artifacts.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raster = zlib.compress(bytes((width * 4 + 1) * height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", raster) + chunk(b"IEND", b"")


class RenderArtifactTests(unittest.TestCase):
    def fixture(self, root, language):
        scenarios = ["demo-projects-inspector", "demo-tasks-result"]
        if language == "en":
            scenarios += ["demo-mole-space", "demo-processes-unavailable"]
        scenarios += ["first-use-projects", "first-use-processes", "first-use-tasks", "first-use-mole-space"]
        scenarios += ["getting-started-" + page for page in ("welcome", "projects", "processes", "demo")]
        scenarios += ["settings-real", "settings-demo"]
        scenarios += ["tool-preparation-" + state for state in ("unchecked", "observed", "demo")]
        scenarios += ["mole-analysis-" + state for state in ("initial", "confirmation", "partial", "failure")]
        attachments = []
        for scenario in scenarios:
            sizes = ((520, 600),) if scenario.startswith("settings-") else (((520, 480), (620, 580)) if scenario.startswith("getting-started-") else ((960, 620), (1280, 800)))
            if scenario.startswith("tool-preparation-"):
                sizes = ((580, 520), (680, 720))
            if scenario.startswith("mole-analysis-"):
                sizes = ((720, 560), (900, 800))
            for appearance in ("light", "dark"):
                for width, height in sizes:
                    name = f"{scenario}-{language}-{appearance}-{width}x{height}"
                    image = name + ".png"
                    (root / image).write_bytes(png(width, height))
                    text = name + ".txt"
                    (root / text).write_text(f"Bundle language: {language}\nProjects title: {'项目' if language == 'zh-Hans' else 'Projects'}\nPartial-result title: {'部分结果' if language == 'zh-Hans' else 'Partial result'}\nContent size: {width} × {height} points\nProcess locale: {'zh_CN' if language == 'zh-Hans' else 'en_US'}\n")
                    if scenario.startswith("tool-preparation-"):
                        with (root / text).open("a") as stream:
                            stream.write(f"Tool candidate title: {'已找到 · 未验证' if language == 'zh-Hans' else 'Found · unverified'}\n")
                    attachments.extend([
                        {"exportedFileName": image, "suggestedHumanReadableName": name + "_0_UUID.png"},
                        {"exportedFileName": text, "suggestedHumanReadableName": name + "-scope_0_UUID.txt"},
                    ])
        manifest = [{"attachments": attachments}]
        (root / "manifest.json").write_text(json.dumps(manifest))
        return manifest

    def test_complete_english_and_chinese(self):
        for language, count in [("en", 80), ("zh-Hans", 72)]:
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
            with self.assertRaisesRegex(ValueError, "Expected 72"):
                module.verify(root, "zh-Hans")

    def test_rejects_wrong_dimensions(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            manifest = self.fixture(root, "en")
            image = root / manifest[0]["attachments"][0]["exportedFileName"]
            image.write_bytes(png(960, 596))
            with self.assertRaisesRegex(ValueError, "dimensions"):
                module.verify(root, "en")

    def test_rejects_truncated_png(self):
        with self.assertRaisesRegex(ValueError, "Truncated"):
            module.png_dimensions(png(960, 620)[:24])

    def test_rejects_corrupt_png_crc(self):
        damaged = bytearray(png(960, 620))
        damaged[20] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            module.png_dimensions(damaged)

    def test_rejects_missing_png_ending(self):
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            module.png_dimensions(png(960, 620)[:-12])

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
