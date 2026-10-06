#!/usr/bin/env python3
"""Require owned panel states, real locale evidence and vector frame sheets."""
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("ui_renders", Path(__file__).with_name("verify-ui-render-artifacts.py"))
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def verify(directory: Path, language: str) -> int:
    if language not in ("en", "zh-Hans"):
        raise ValueError("Unsupported language")
    expected = {
        f"menubar-panel-{state}-{language}-{appearance}-328x304": (328, 304)
        for state in ("idle", "busy", "completed", "attention", "cancelled", "demo")
        for appearance in ("light", "dark")
    }
    frames = {f"menubar-frames-{appearance}-{scale}x": (700 * scale, 168 * scale)
              for appearance in ("light", "dark") for scale in (1, 2)} if language == "en" else {}
    images, scopes = {}, {}
    for test in json.loads((directory / "manifest.json").read_text()):
        for item in test["attachments"]:
            filename, name = item["exportedFileName"], item["suggestedHumanReadableName"]
            if Path(filename).name != filename:
                raise ValueError("Expected a direct attachment child")
            path = directory / filename
            if path.is_symlink():
                raise ValueError("Symlink artifact")
            for prefix, size in (expected | frames).items():
                if name.startswith(prefix + "_") and path.suffix == ".png":
                    if prefix in images:
                        raise ValueError("Duplicate image")
                    pixels = ui.png_dimensions(path.read_bytes())
                    allowed = (size,) if prefix in frames else (size, (size[0] * 2, size[1] * 2))
                    if pixels not in allowed:
                        raise ValueError(f"Wrong dimensions: {prefix}: {pixels}")
                    images[prefix] = path
                elif prefix in expected and name.startswith(prefix + "-scope_") and path.suffix == ".txt":
                    if prefix in scopes:
                        raise ValueError("Duplicate scope")
                    scopes[prefix] = path.read_text()
    if images.keys() != (expected | frames).keys() or scopes.keys() != expected.keys():
        raise ValueError(f"Missing menu bar evidence: {len(images)} images, {len(scopes)} scopes")
    for scope in scopes.values():
        required = ("Content size: 328 × 304 points", f"Bundle language: {language}",
                    "Ready title: " + ("就绪" if language == "zh-Hans" else "Ready"),
                    "Open title: " + ("打开 MoeKit" if language == "zh-Hans" else "Open MoeKit"),
                    "no scan, user data, network or screen capture", "animations disabled for static capture")
        if any(text not in scope for text in required):
            raise ValueError("Wrong language or scope evidence")
    return len(images)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("language", choices=("en", "zh-Hans"))
    args = parser.parse_args()
    print(f"Verified {verify(args.directory, args.language)} menu bar renders; visual/native acceptance remains separate.")
