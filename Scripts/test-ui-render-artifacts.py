#!/usr/bin/env python3
"""Synthetic-only checks for the render artifact verifier."""

import binascii
import functools
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


@functools.lru_cache(maxsize=24)
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
        scenarios += ["tool-preparation-" + state for state in ("unchecked", "observed", "demo", "mole-guidance", "git-guidance", "mole-command")]
        scenarios += ["mole-analysis-" + state for state in ("initial", "ready", "missing", "incompatible", "unverified", "advanced", "guide", "confirmation", "partial", "failure")]
        scenarios += ["installer-" + state for state in ("disabled", "trash-confirmation", "restore-confirmation", "incomplete-recovery")]
        scenarios += ["installer-" + state + "-compact" for state in ("trash-confirmation", "restore-confirmation")]
        scenarios += ["process-stop-graceful", "process-stop-force"]
        scenarios += ["updates-" + state for state in ("available", "current", "development", "failure", "cancelled", "hidden-icons")]
        scenarios += ["about-" + state for state in ("preview", "development", "unavailable")]
        attachments = []
        for scenario in scenarios:
            sizes = ((520, 600),) if scenario.startswith("settings-") else (((520, 480), (620, 580)) if scenario.startswith("getting-started-") else ((960, 620), (1280, 800)))
            if scenario.startswith("tool-preparation-"):
                sizes = ((580, 520), (680, 720))
            if scenario.startswith("mole-analysis-"):
                sizes = ((720, 1400),) if scenario == "mole-analysis-guide" else ((720, 560), (900, 800))
            if scenario.startswith("installer-"):
                sizes = ((720, 560),) if scenario.endswith("-compact") else ((720, 1600),)
            if scenario.startswith("updates-"):
                sizes = ((520, 600),) if scenario == "updates-hidden-icons" else ((540, 520),)
            if scenario.startswith("process-stop-"):
                sizes = ((740, 780),)
            if scenario.startswith("about-"):
                sizes = ((440, 400),)
            for appearance in ("light", "dark"):
                for width, height in sizes:
                    name = f"{scenario}-{language}-{appearance}-{width}x{height}"
                    image = name + ".png"
                    (root / image).write_bytes(png(width, height))
                    text = name + ".txt"
                    (root / text).write_text(f"Bundle language: {language}\nProjects title: {'项目' if language == 'zh-Hans' else 'Projects'}\nPartial-result title: {'部分结果' if language == 'zh-Hans' else 'Partial result'}\nContent size: {width} × {height} points\nProcess locale: {'zh_CN' if language == 'zh-Hans' else 'en_US'}\n")
                    if scenario.startswith("about-"):
                        with (root / text).open("a") as stream:
                            preview = scenario == "about-preview"
                            missing = scenario == "about-unavailable"
                            stream.write(f"About version: {'unavailable' if missing else ('0.1.0-preview.11' if preview else '0.1.0')}\n")
                            stream.write(f"About build: {'unavailable' if missing else ('2.0.11' if preview else '1')}\n")
                            stream.write(f"Visible About labels: {1 if missing else 2}\n")
                    if scenario.startswith("mole-analysis-"):
                        with (root / text).open("a") as stream:
                            stream.write(f"Setup ready title: {'可以开始分析' if language == 'zh-Hans' else 'Ready to analyze'}\n")
                    if scenario.startswith("updates-"):
                        with (root / text).open("a") as stream:
                            stream.write(f"Update action title: {'检查更新…' if language == 'zh-Hans' else 'Check for updates…'}\n")
                            stream.write(f"Visible required controls: {3 if 'hidden-icons' in scenario else (7 if any(state in scenario for state in ('available', 'development')) else 6)}\nEvidence source: public SwiftUI bounds anchors on displayed views\n")
                            stream.write("Network requests: 0\nScope: owned release/settings views with isolated preferences and synthetic responses.\n")
                    if scenario.startswith("process-stop-"):
                        with (root / text).open("a") as stream:
                            stream.write("Native signals: 0\nVisible required controls: 7\nConfirmation initially acknowledged: false\nEvidence source: public SwiftUI bounds anchors on displayed views\n")
                    if scenario.startswith("tool-preparation-"):
                        with (root / text).open("a") as stream:
                            stream.write(f"Download copy title: {'复制下载命令' if language == 'zh-Hans' else 'Copy download command'}\n")
                            stream.write(f"Tool candidate title: {'已找到 · 未验证' if language == 'zh-Hans' else 'Found · unverified'}\n")
                    if scenario.startswith("installer-"):
                        with (root / text).open("a") as stream:
                            stream.write(f"Trash action title: {'将此文件移到废纸篓' if language == 'zh-Hans' else 'Move this file to Trash'}\n")
                            stream.write(f"Restore action title: {'恢复到原路径' if language == 'zh-Hans' else 'Restore to original path'}\n")
                            stream.write(f"Attestation title: {'我已完成此磁盘映像的安装和使用' if language == 'zh-Hans' else 'I have finished installing and using this disk image'}\n")
                            stream.write(f"Unknown recovery title: {'恢复记录不可用；结果未知' if language == 'zh-Hans' else 'Recovery record unavailable; outcome unknown'}\n")
                            stream.write("Mutation calls: 0\nScope: owned installer view with synthetic paths and receipts only.\nEvidence source: public SwiftUI bounds anchors on displayed views\n")
                            if scenario.endswith("-compact"):
                                stream.write("Capture mode: compact confirmation controls after explicit scroll\nScrollable content exceeds viewport: true\nScrolled confirmation/cancel inside capture: 2\n")
                    attachments.extend([
                        {"exportedFileName": image, "suggestedHumanReadableName": name + "_0_UUID.png"},
                        {"exportedFileName": text, "suggestedHumanReadableName": name + "-scope_0_UUID.txt"},
                    ])
        manifest = [{"attachments": attachments}]
        (root / "manifest.json").write_text(json.dumps(manifest))
        return manifest

    def test_complete_english_and_chinese(self):
        for language, count in [("en", 148), ("zh-Hans", 140)]:
            with self.subTest(language=language), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                self.fixture(root, language)
                self.assertEqual(module.verify(root, language), count)

    def test_rejects_incorrect_about_release_label(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            manifest = self.fixture(root, "en")
            item = next(item for item in manifest[0]["attachments"] if item["exportedFileName"].startswith("about-preview-") and item["exportedFileName"].endswith(".txt"))
            text = root / item["exportedFileName"]
            text.write_text(text.read_text().replace("About version: 0.1.0-preview.11", "About version: 0.1.0"))
            with self.assertRaisesRegex(ValueError, "localization"):
                module.verify(root, "en")

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
            with self.assertRaisesRegex(ValueError, "Expected 140"):
                module.verify(root, "zh-Hans")

    def test_rejects_missing_installer_image_or_scope(self):
        for language, count in (("en", 148), ("zh-Hans", 140)):
            for suffix in (".png", ".txt"):
                with self.subTest(language=language, suffix=suffix), tempfile.TemporaryDirectory() as path:
                    root = Path(path)
                    manifest = self.fixture(root, language)
                    attachments = manifest[0]["attachments"]
                    target = next(item for item in attachments if item["exportedFileName"].startswith("installer-trash-confirmation-") and item["exportedFileName"].endswith(suffix))
                    attachments.remove(target)
                    (root / "manifest.json").write_text(json.dumps(manifest))
                    with self.assertRaisesRegex(ValueError, f"Expected {count}"):
                        module.verify(root, language)

    def test_rejects_missing_compact_installer_image_or_scope(self):
        for language, count in (("en", 148), ("zh-Hans", 140)):
            for suffix in (".png", ".txt"):
                with self.subTest(language=language, suffix=suffix), tempfile.TemporaryDirectory() as path:
                    root = Path(path)
                    manifest = self.fixture(root, language)
                    attachments = manifest[0]["attachments"]
                    target = next(item for item in attachments if "-compact-" in item["exportedFileName"] and item["exportedFileName"].endswith(suffix))
                    attachments.remove(target)
                    (root / "manifest.json").write_text(json.dumps(manifest))
                    with self.assertRaisesRegex(ValueError, f"Expected {count}"):
                        module.verify(root, language)

    def test_rejects_missing_compact_scroll_or_control_evidence(self):
        for before, after in (("Scrollable content exceeds viewport: true", "Scrollable content exceeds viewport: false"),
                              ("Scrolled confirmation/cancel inside capture: 2", "Scrolled confirmation/cancel inside capture: 1")):
            with self.subTest(before=before), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                manifest = self.fixture(root, "en")
                target = next(item for item in manifest[0]["attachments"] if "-compact-" in item["exportedFileName"] and item["exportedFileName"].endswith(".txt"))
                text = root / target["exportedFileName"]
                text.write_text(text.read_text().replace(before, after))
                with self.assertRaisesRegex(ValueError, "localization"):
                    module.verify(root, "en")

    def test_accepts_installer_retina_bitmap_for_every_scenario(self):
        for language, count in (("en", 148), ("zh-Hans", 140)):
            with self.subTest(language=language), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                manifest = self.fixture(root, language)
                captures = [item for item in manifest[0]["attachments"] if item["exportedFileName"].startswith("installer-") and item["exportedFileName"].endswith(".png")]
                self.assertEqual(len(captures), 12)
                for item in captures:
                    (root / item["exportedFileName"]).write_bytes(png(1440, 1120 if "-compact-" in item["exportedFileName"] else 3200))
                self.assertEqual(module.verify(root, language), count)

    def test_rejects_installer_localization_fallback(self):
        titles = (
            ("Trash action title: 将此文件移到废纸篓", "Trash action title: Move this file to Trash"),
            ("Restore action title: 恢复到原路径", "Restore action title: Restore to original path"),
            ("Attestation title: 我已完成此磁盘映像的安装和使用", "Attestation title: I have finished installing and using this disk image"),
            ("Unknown recovery title: 恢复记录不可用；结果未知", "Unknown recovery title: Recovery record unavailable; outcome unknown"),
        )
        for localized, fallback in titles:
            with self.subTest(title=localized), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                manifest = self.fixture(root, "zh-Hans")
                target = next(item for item in manifest[0]["attachments"] if item["exportedFileName"].startswith("installer-") and item["exportedFileName"].endswith(".txt"))
                text = root / target["exportedFileName"]
                text.write_text(text.read_text().replace(localized, fallback))
                with self.assertRaisesRegex(ValueError, "localization"):
                    module.verify(root, "zh-Hans")

    def test_rejects_installer_mutation_or_missing_scope_declaration(self):
        for before, after in (("Mutation calls: 0", "Mutation calls: 1"),
                              ("Scope: owned installer view with synthetic paths and receipts only.", "")):
            with self.subTest(before=before), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                manifest = self.fixture(root, "en")
                target = next(item for item in manifest[0]["attachments"] if item["exportedFileName"].startswith("installer-") and item["exportedFileName"].endswith(".txt"))
                text = root / target["exportedFileName"]
                text.write_text(text.read_text().replace(before, after))
                with self.assertRaisesRegex(ValueError, "localization"):
                    module.verify(root, "en")

    def test_rejects_installer_point_size_or_mixed_retina_scale(self):
        for dimensions in ((720, 1599), (720, 3200), (1440, 1600)):
            with self.subTest(dimensions=dimensions), tempfile.TemporaryDirectory() as path:
                root = Path(path)
                manifest = self.fixture(root, "en")
                target = next(item for item in manifest[0]["attachments"] if item["exportedFileName"].startswith("installer-") and item["exportedFileName"].endswith(".png"))
                (root / target["exportedFileName"]).write_bytes(png(*dimensions))
                with self.assertRaisesRegex(ValueError, "dimensions"):
                    module.verify(root, "en")

    def test_png_dimension_bound_does_not_expand_to_full_width_and_height(self):
        self.assertEqual(module.png_dimensions(png(2560, 1600)), (2560, 1600))
        self.assertEqual(module.png_dimensions(png(1440, 3200)), (1440, 3200))
        for dimensions in ((2560, 3200), (1441, 3200), (1440, 3201), (2561, 1600)):
            with self.subTest(dimensions=dimensions), self.assertRaisesRegex(ValueError, "dimensions"):
                module.png_dimensions(png(*dimensions))

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
