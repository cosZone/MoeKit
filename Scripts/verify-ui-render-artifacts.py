#!/usr/bin/env python3
"""Check render coverage and runtime language evidence, not visual correctness."""

import argparse
import json
from pathlib import Path
import struct


def verify(directory: Path, language: str) -> int:
    scenarios = ["demo-projects-inspector", "demo-tasks-result"]
    if language == "en":
        scenarios += ["demo-mole-space", "demo-processes-unavailable"]
    elif language != "zh-Hans":
        raise ValueError("Unsupported render language")
    expected = {
        f"{scenario}-{language}-{appearance}-{width}x{height}": (width, height)
        for scenario in scenarios
        for appearance in ("light", "dark")
        for width, height in ((960, 620), (1280, 800))
    }
    manifest = json.loads((directory / "manifest.json").read_text())
    images, scopes = {}, {}
    for test in manifest:
        for attachment in test["attachments"]:
            filename = attachment["exportedFileName"]
            if Path(filename).name != filename:
                raise ValueError("Exported attachment must be a direct child")
            path = directory / filename
            if path.is_symlink():
                raise ValueError("Exported attachment must not be a symlink")
            name = attachment["suggestedHumanReadableName"]
            for prefix, size in expected.items():
                if name.startswith(prefix + "_") and path.suffix == ".png":
                    if prefix in images:
                        raise ValueError(f"Duplicate render: {prefix}")
                    data = path.read_bytes()
                    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
                        raise ValueError(f"Invalid PNG header: {prefix}")
                    # The runner may use Retina backing; point dimensions are
                    # asserted inside XCTest and also recorded in scope metadata.
                    pixels = struct.unpack(">II", data[16:24])
                    if pixels not in (size, (size[0] * 2, size[1] * 2)):
                        raise ValueError(f"Unexpected bitmap dimensions: {prefix}: {pixels}")
                    images[prefix] = path
                elif name.startswith(prefix + "-scope_") and path.suffix == ".txt":
                    if prefix in scopes:
                        raise ValueError(f"Duplicate scope: {prefix}")
                    scopes[prefix] = path.read_text()
    if set(images) != set(expected) or set(scopes) != set(expected):
        raise ValueError(f"Expected {len(expected)} {language} images and scopes; found {len(images)} images, {len(scopes)} scopes")
    for name, scope in scopes.items():
        width, height = expected[name]
        lines = set(scope.splitlines())
        required = {
            f"Bundle language: {language}",
            f"Projects title: {'项目' if language == 'zh-Hans' else 'Projects'}",
            f"Partial-result title: {'部分结果' if language == 'zh-Hans' else 'Partial result'}",
            f"Content size: {width} × {height} points",
        }
        if not required.issubset(lines):
            raise ValueError(f"Missing runtime localization/size evidence: {name}")
        locale_prefix = "zh" if language == "zh-Hans" else "en"
        if not any(line.startswith(f"Process locale: {locale_prefix}") for line in lines):
            raise ValueError(f"Wrong process locale: {name}")
    return len(expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("language", choices=("en", "zh-Hans"))
    args = parser.parse_args()
    count = verify(args.directory, args.language)
    print(f"Verified {count} {args.language} render files and runtime localization/size metadata.")
    print("This does not establish visual, keyboard, VoiceOver, or active-window contrast acceptance.")
