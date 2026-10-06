#!/usr/bin/env python3
"""Self-contained checks for menu-bar artifact coverage and corruption refusal."""
import binascii
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location("menubar", Path(__file__).with_name("verify-menubar-render-artifacts.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress((b"\0" + b"\x80\x80\x80\xff" * width) * height)) + chunk(b"IEND", b"")


class MenuBarEvidenceTests(unittest.TestCase):
    def fixture(self, directory, language):
        entries = []
        def add(name, extension, data):
            filename = name + extension
            (directory / filename).write_bytes(data)
            entries.append({"exportedFileName": filename, "suggestedHumanReadableName": name + "_fixture" + extension})
        for state in ("idle", "busy", "completed", "attention", "cancelled", "demo"):
            for appearance in ("light", "dark"):
                name = f"menubar-panel-{state}-{language}-{appearance}-328x304"
                add(name, ".png", png(328, 304))
                scope = f"Content size: 328 × 304 points\nBundle language: {language}\nReady title: {'就绪' if language == 'zh-Hans' else 'Ready'}\nOpen title: {'打开 MoeKit' if language == 'zh-Hans' else 'Open MoeKit'}\nno scan, user data, network or screen capture\nanimations disabled for static capture"
                add(name + "-scope", ".txt", scope.encode())
        if language == "en":
            for appearance in ("light", "dark"):
                for scale in (1, 2):
                    add(f"menubar-frames-{appearance}-{scale}x", ".png", png(700 * scale, 168 * scale))
        (directory / "manifest.json").write_text(json.dumps([{"attachments": entries}]))
        return entries

    def test_complete_both_languages(self):
        for language, count in (("en", 16), ("zh-Hans", 12)):
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp); self.fixture(path, language)
                self.assertEqual(module.verify(path, language), count)

    def test_missing_duplicate_corrupt_wrong_size_and_locale(self):
        for fault in ("missing", "duplicate", "corrupt", "dimensions", "locale"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temp:
                path = Path(temp); entries = self.fixture(path, "en")
                image = path / entries[0]["exportedFileName"]
                if fault == "missing": entries.pop()
                elif fault == "duplicate": entries.append(entries[0])
                elif fault == "corrupt": image.write_bytes(image.read_bytes()[:-1])
                elif fault == "dimensions": image.write_bytes(png(327, 304))
                else:
                    scope = path / entries[1]["exportedFileName"]
                    scope.write_text(scope.read_text().replace("Ready title: Ready", "Ready title: untranslated"))
                (path / "manifest.json").write_text(json.dumps([{"attachments": entries}]))
                with self.assertRaises(ValueError): module.verify(path, "en")


if __name__ == "__main__": unittest.main()
