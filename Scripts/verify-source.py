#!/usr/bin/env python3
"""Small source/asset guardrails. This does NOT compile or execute Swift."""

import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


required = (
    "Project.swift", "Package.swift", ".mise.toml", "README.md",
    "Sources/App/MoeKitApp.swift", "Sources/Core/WorkspaceStore.swift",
    "Sources/Core/DemoData.swift", "Sources/Core/ToolModule.swift",
    "Sources/Core/MoleReport.swift", "Sources/Services/RepositoryScanner.swift",
    "Sources/Core/AppInformation.swift", "Sources/UI/AboutView.swift",
    "Tests/AppInformationTests.swift",
    "Tests/RepositoryScannerTests.swift", "Tests/MoleModuleTests.swift",
    "Sources/Processes/ProcessModels.swift", "Sources/Processes/ProcessInventoryStore.swift",
    "Sources/Services/NativeProcessInventoryProvider.swift", "Sources/UI/ProcessWorkspaceView.swift",
    "Tests/ProcessModelsTests.swift", "Tests/ProcessInventoryStoreTests.swift",
    "Tests/NativeProcessInventoryProviderTests.swift",
    "Resources/Localizable.xcstrings",
    "Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
    "Resources/Assets.xcassets/BrandMark.imageset/Contents.json",
    ".github/workflows/ci.yml", ".github/workflows/preview-build.yml",
)
for name in required:
    require((ROOT / name).is_file(), f"Missing required file: {name}")

# Parse every asset JSON and string catalog, with duplicate-key rejection.
def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


catalogs = sorted((ROOT / "Resources").rglob("*.json"))
catalogs += sorted((ROOT / "Resources").rglob("*.xcstrings"))
for path in catalogs:
    relative = path.relative_to(ROOT)
    try:
        data = json.loads(path.read_text(), object_pairs_hook=unique_object)
        if path.suffix == ".xcstrings":
            require(isinstance(data.get("strings"), dict), f"Invalid string catalog: {relative}")
            require(data.get("sourceLanguage") == "en", f"Unexpected source language: {relative}")
        for entry in data.get("images", []):
            if "filename" not in entry:
                continue
            image = path.parent / entry["filename"]
            require(image.is_file(), f"Missing asset image: {image.relative_to(ROOT)}")
            if image.is_file() and image.suffix == ".png":
                header = image.read_bytes()[:24]
                require(header[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {image.name}")
                if len(header) == 24 and "size" in entry and "scale" in entry:
                    width, height = struct.unpack(">II", header[16:24])
                    points = [float(part) for part in entry["size"].split("x")]
                    scale = float(entry["scale"].removesuffix("x"))
                    require((width, height) == tuple(int(p * scale) for p in points),
                            f"Wrong pixel size for {image.name}: {width}x{height}")
    except (OSError, ValueError, TypeError, AttributeError, struct.error) as error:
        errors.append(f"Invalid catalog {relative}: {error}")

sources = sorted((ROOT / "Sources").rglob("*.swift"))
require(bool(sources), "No Swift app sources found")
# Process creation has reviewed fixed-code analysis and read-only disk-image adapters; shell and all other
# execution entry points remain forbidden. The supervisor is audited separately.
for path in sources:
    text = path.read_text()
    for pattern in (r"\b(?:Process|NSTask|NSAppleScript)\s*\(",
                    r"\b(?:posix_spawn\w*|execve|execv|popen)\s*\(",
                    r"(?<![.\w])system\s*\(", r"\b(?:Darwin|Glibc)\.system\s*\(",
                    r'"/bin/(?:sh|bash|zsh)"', r"\bAuthorizationExecuteWithPrivileges\b",
                    r"\b(?:kill|killpg|raise|proc_signal|proc_signal_with_audittoken)\s*\("):
        allowed_adapter = (path.relative_to(ROOT).as_posix() in {"Sources/Mole/MoleAnalysisExecutor.swift", "Sources/Installer/InstallerUseEvidence.swift", "Sources/GitCleanup/GitObjectSnapshot.swift"}
                           and pattern == r"\b(?:Process|NSTask|NSAppleScript)\s*\("
                           and not re.search(r"\b(?:NSTask|NSAppleScript)\s*\(", text))
        allowed_signal = (path.relative_to(ROOT).as_posix() == "Sources/Services/NativeProcessTerminationSystem.swift"
                          and pattern == r"\b(?:kill|killpg|raise|proc_signal|proc_signal_with_audittoken)\s*\("
                          and not re.search(r"\b(?:kill|killpg|raise|proc_signal)\s*\(", text))
        require(allowed_adapter or allowed_signal or not re.search(pattern, text), f"Execution API outside reviewed adapter: {path.relative_to(ROOT)} ({pattern})")

installer_sources = list((ROOT / "Sources/Installer").glob("*.swift"))
for path in installer_sources:
    text = path.read_text()
    for pattern in (r"\b(?:unlink|unlinkat|rmdir|chmod|fchmod|chown|fchown)\s*\(",
                    r"\.removeItem\s*\(", r"\.moveItem\s*\(", r"\brenameat\s*\(",
                    r'"(?:clean|purge|uninstall)"'):
        require(not re.search(pattern, text), f"Installer must retain data with exclusive moves only: {path.relative_to(ROOT)} ({pattern})")
# Native batch cleanup has exactly one separately confirmed irreversible sink.
# Keep every other cleanup file free of unlink/remove/permission-changing APIs.
for path in (ROOT / "Sources/Cleanup").glob("*.swift"):
    text = path.read_text()
    for pattern in (r"\b(?:unlink|rmdir|chmod|fchmod|chown|fchown)\s*\(",
                    r"\.removeItem\s*\(", r"\.moveItem\s*\(", r"\brenameat\s*\("):
        require(not re.search(pattern, text), f"Cleanup mutation outside exact-plan primitives: {path.relative_to(ROOT)} ({pattern})")
    require(path.name == "CleanupPermanentRemoval.swift" or not re.search(r"\bunlinkat\s*\(", text),
            f"Irreversible cleanup outside separately confirmed private-slot sink: {path.relative_to(ROOT)}")

helper = ROOT / "Sources/Installer/InstallerUseEvidence.swift"
if helper.is_file():
    text = helper.read_text()
    require(text.count("Process()") == 1, "Installer evidence has one fixed read-only helper")
    require('process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")' in text,
            "Installer evidence must use the fixed system helper")
    require('process.arguments = ["info", "-plist"]' in text,
            "Installer evidence must use the fixed read-only inventory argv")

process_sources = list((ROOT / "Sources/Processes").glob("*.swift"))
process_sources += [ROOT / "Sources/Services/NativeProcessInventoryProvider.swift"]
for path in process_sources:
    if path.is_file():
        text = path.read_text()
        for pattern in (r"\bKERN_PROCARGS2?\b", r"\bgetenv\s*\(",
                        r"ProcessInfo\.processInfo\.(?:arguments|environment)", r"\bTimer\.publish\s*\("):
            require(not re.search(pattern, text), f"Process inventory privacy/explicit-scan guardrail: {path.relative_to(ROOT)} ({pattern})")

store_path = ROOT / "Sources/Core/WorkspaceStore.swift"
if store_path.is_file():
    store = store_path.read_text()
    require('arguments.contains("--demo")' in store, "Demo must be explicitly enabled")
    require("isDemoEnabled ? DemoData.projects : projects" in store, "Demo project isolation guard missing")
    require("isDemoEnabled ? DemoData.tasks : tasks" in store, "Demo task isolation guard missing")
    require("var projects: [ProjectRecord] = []" in store, "Real projects must not start with fixture data")
    require("var tasks: [TaskRecord] = []" in store, "Real tasks must not start with fixture data")

project_path = ROOT / "Project.swift"
if project_path.is_file():
    require('com.yusixian.MoeKit' in project_path.read_text(), "Stable app bundle ID missing")
package_path = ROOT / "Package.swift"
if package_path.is_file():
    require(not re.search(r"\.package\s*\(", package_path.read_text()), "Review new third-party dependencies before adding them")

if errors:
    print("Source checks failed:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)
print(f"Source checks passed: {len(sources)} Swift files; {len(catalogs)} JSON/string catalogs parsed.")
print("Not run by this script: Swift compilation, tests, native UI, accessibility, signing, or notarization.")
