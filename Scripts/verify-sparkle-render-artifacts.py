#!/usr/bin/env python3
"""Require real owned-view Sparkle settings renders; this is not installer proof."""
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("render", Path(__file__).with_name("verify-ui-render-artifacts.py"))
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)


def verify(directory: Path, language: str) -> int:
    if language not in {"en", "zh-Hans"}:
        raise ValueError("Unexpected render language")
    expected = {f"sparkle-settings-{state}-{language}-{appearance}-520x520": state
                for state in ("enabled", "disabled", "unconfigured", "failed")
                for appearance in ("light", "dark")}
    images, scopes = {}, {}
    for test in json.loads((directory / "manifest.json").read_text()):
        for item in test["attachments"]:
            filename, name = item["exportedFileName"], item["suggestedHumanReadableName"]
            if Path(filename).name != filename:
                raise ValueError("Unexpected nested render path")
            file = directory / filename
            if file.is_symlink():
                raise ValueError("Unexpected render symlink")
            for prefix in expected:
                if name.startswith(prefix + "_") and file.suffix == ".png":
                    if prefix in images or render.png_dimensions(file.read_bytes()) not in {(520, 520), (1040, 1040)}:
                        raise ValueError("Invalid or duplicate settings render")
                    images[prefix] = file
                elif name.startswith(prefix + "-scope_") and file.suffix == ".txt":
                    if prefix in scopes:
                        raise ValueError("Duplicate settings scope")
                    scopes[prefix] = file.read_text()
    if images.keys() != expected.keys() or scopes.keys() != expected.keys():
        raise ValueError("Missing Sparkle settings image or scope")
    for prefix, state in expected.items():
        required = {"Content size: 520 × 520 points", f"Bundle language: {language}",
                    f"Automatic check title: {'自动检查更新' if language == 'zh-Hans' else 'Automatically check for updates'}",
                    "Network requests: 0", "Installer launches: 0", f"Scenario: {state}",
                    f"Visible required controls: {6 if state in {'enabled', 'disabled'} else 3}",
                    "Scope: owned settings view, synthetic updater driver, no production signing key.",
                    "Evidence source: public SwiftUI bounds anchors on displayed views"}
        lines = set(scopes[prefix].splitlines())
        if not required <= lines or not any(line.startswith("Process locale: " + ("zh" if language == "zh-Hans" else "en")) for line in lines):
            raise ValueError("Missing runtime settings scope evidence")
    return len(expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("language", choices=("en", "zh-Hans"))
    args = parser.parse_args()
    print(f"Verified {verify(args.directory, args.language)} Sparkle settings renders; native installer behavior is separate.")
