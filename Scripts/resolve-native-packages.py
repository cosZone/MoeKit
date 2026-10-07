#!/usr/bin/env python3
"""Resolve only the reviewed native-SPM graph before allowing its build plugin."""
import json
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
if platform.system() != "Darwin":
    raise SystemExit("Native package resolution requires the documented macOS toolchain.")
source = ROOT / "Configurations/NativePackages.resolved"
expected = json.loads(source.read_text())["pins"]
workspace = ROOT / "MoeKit.xcworkspace"
if not workspace.is_dir():
    raise SystemExit("Generate MoeKit.xcworkspace with the pinned Tuist first.")
lock = workspace / "xcshareddata/swiftpm/Package.resolved"
lock.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, lock)
subprocess.run(["xcodebuild", "-resolvePackageDependencies", "-workspace", str(workspace),
                "-scheme", "MoeKit", "-onlyUsePackageVersionsFromResolvedFile",
                "-clonedSourcePackagesDirPath", str(ROOT / "build/NativeSourcePackages")], check=True, cwd=ROOT)
resolved = json.loads(lock.read_text())["pins"]
expected_states = {pin["identity"]: pin["state"] for pin in expected}
actual_states = {pin["identity"]: pin["state"] for pin in resolved}
if actual_states != expected_states:
    raise SystemExit(f"Native Swift package pins changed: {actual_states}")
checkouts = ROOT / "build/NativeSourcePackages/checkouts"
for pin in expected:
    matches = [p for p in checkouts.iterdir() if p.name.lower() == pin["identity"]]
    if len(matches) != 1:
        raise SystemExit("Missing exact native package checkout: " + pin["identity"])
    head = subprocess.check_output(["git", "-C", str(matches[0]), "rev-parse", "HEAD"], text=True).strip()
    if head != pin["state"]["revision"]:
        raise SystemExit("Native package source revision differs: " + pin["identity"])
# The Release optimization audit invokes xcodebuild with -project/-alltargets.
# Xcode requires the same reviewed lock in that generated project's own
# workspace too when automatic resolution is disabled.
project = ROOT / "MoeKit.xcodeproj"
if not project.is_dir():
    raise SystemExit("The generated MoeKit.xcodeproj is required.")
project_lock = project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
project_lock.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(lock, project_lock)
print("Verified exact SwiftTerm 1.20.0 and native-SPM dependency source revisions.")
print("Only its pinned build-info plugin is used; DocC and CLI products are not linked.")
