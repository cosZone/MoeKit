#!/usr/bin/env python3
"""Check render coverage and runtime language evidence, not visual correctness."""

import argparse
import binascii
import json
from pathlib import Path
import struct
import zlib


def png_dimensions(data: bytes) -> tuple[int, int]:
    """Validate the complete non-interlaced PNG raster emitted by AppKit."""
    if len(data) > 64 * 1024 * 1024 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG signature or size")
    offset, header, ended = 8, None, False
    compressed = bytearray()
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG chunk")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("Truncated PNG payload")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        crc = struct.unpack(">I", data[end - 4:end])[0]
        if binascii.crc32(kind + payload) & 0xffffffff != crc:
            raise ValueError("Invalid PNG chunk CRC")
        if header is None and kind != b"IHDR":
            raise ValueError("PNG must begin with IHDR")
        if kind == b"IHDR":
            if header is not None or length != 13:
                raise ValueError("Invalid PNG IHDR")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            if length != 0 or end != len(data):
                raise ValueError("Invalid PNG ending")
            ended = True
        elif kind[0] & 32 == 0 and kind != b"PLTE":
            raise ValueError("Unsupported critical PNG chunk")
        offset = end
    if not ended or header is None or not compressed:
        raise ValueError("Incomplete PNG image")
    width, height, depth, color, compression, filtering, interlace = header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if not channels or depth not in (8, 16) or compression or filtering or interlace:
        raise ValueError("Unsupported AppKit PNG format")
    if not 0 < width <= 2560 or not 0 < height <= 1600:
        raise ValueError("Unexpected bitmap dimensions")
    row_bytes = width * channels * (depth // 8)
    expected_bytes = (row_bytes + 1) * height
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(compressed, expected_bytes + 1)
    except zlib.error as error:
        raise ValueError("Invalid PNG compressed raster") from error
    if len(pixels) != expected_bytes or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("Incomplete or oversized PNG raster")
    if any(pixels[y * (row_bytes + 1)] > 4 for y in range(height)):
        raise ValueError("Invalid PNG scanline filter")
    return width, height


def verify(directory: Path, language: str) -> int:
    scenarios = ["demo-projects-inspector", "demo-tasks-result"]
    if language == "en":
        scenarios += ["demo-mole-space", "demo-processes-unavailable"]
    elif language != "zh-Hans":
        raise ValueError("Unsupported render language")
    scenarios += ["first-use-projects", "first-use-processes", "first-use-tasks", "first-use-mole-space"]
    expected = {
        f"{scenario}-{language}-{appearance}-{width}x{height}": (width, height)
        for scenario in scenarios
        for appearance in ("light", "dark")
        for width, height in ((960, 620), (1280, 800))
    }
    expected.update({
        f"getting-started-{page}-{language}-{appearance}-{width}x{height}": (width, height)
        for page in ("welcome", "projects", "processes", "demo")
        for appearance in ("light", "dark")
        for width, height in ((520, 480), (620, 580))
    })
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
                    # The runner may use Retina backing; point dimensions are
                    # asserted inside XCTest and also recorded in scope metadata.
                    pixels = png_dimensions(data)
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
