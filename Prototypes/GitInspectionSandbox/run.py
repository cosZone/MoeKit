#!/usr/bin/env python3
"""Native sandbox gate experiment. Only unique owned synthetic fixtures are touched."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

if sys.platform != "darwin":
    raise SystemExit("This probe requires macOS; Linux cannot establish App Sandbox enforcement.")

source = Path(__file__).resolve().parent
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=90)

with tempfile.TemporaryDirectory(prefix="MoeKitGitSandboxBuild-") as build_string:
    build = Path(build_string)
    app = build / "GitSandboxProbe.app"
    service = app / "Contents/XPCServices/GitSandboxProbe.xpc"
    for bundle, identifier, executable, package in [
        (app, "com.yusixian.MoeKit.GitSandboxProbe", "ProbeHost", "APPL"),
        (service, "com.yusixian.MoeKit.GitSandboxProbe.Service", "ProbeService", "XPC!")
    ]:
        (bundle / "Contents/MacOS").mkdir(parents=True)
        info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundlePackageType": package, "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "15.0"}
        if package == "XPC!":
            info["XPCService"] = {"ServiceType": "Application", "RunLoopType": "NSRunLoop"}
        else:
            info["LSBackgroundOnly"] = True
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    for swift, target in [("Host.swift", app / "Contents/MacOS/ProbeHost"),
                          ("Service.swift", service / "Contents/MacOS/ProbeService")]:
        run("xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-O",
            str(source / "Shared.swift"), str(source / swift), "-o", str(target))
    entitlements = build / "Service.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True,
                                           "com.apple.security.files.user-selected.read-only": True}))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(service))
    run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("/usr/bin/codesign", "-d", "--entitlements", "-", str(service))
    (output / "entitlements.txt").write_text(signature.stdout + signature.stderr)
    outcomes = {}
    # HOME, not /tmp: a helper's default temporary-directory access must not
    # accidentally make an outside-scope fixture accessible.
    with tempfile.TemporaryDirectory(prefix="MoeKitGitSandboxFixtures-", dir=Path.home()) as fixture_string:
        fixture = Path(fixture_string)
        for mode in ("implicit", "downgraded", "descriptor"):
            selected, outside = fixture / mode / "selected", fixture / mode / "outside"
            selected.mkdir(parents=True)
            outside.mkdir()
            (selected / "sentinel").write_text("owned synthetic selected fixture\n")
            (outside / "sentinel").write_text("owned synthetic outside fixture\n")
            (selected / "escape").symlink_to(outside, target_is_directory=True)
            result = subprocess.run([str(app / "Contents/MacOS/ProbeHost"), str(selected),
                                     str(outside), mode], capture_output=True, text=True, timeout=40)
            outcomes[mode] = {"exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                              "selectedWasWritten": (selected / "write-probe").exists(),
                              "outsideWasWritten": (outside / "write-probe").exists()}
    (output / "outcomes.json").write_text(json.dumps(outcomes, indent=2))
    print(json.dumps(outcomes, indent=2))
    # This experiment intentionally fails until there is empirical proof of an
    # actually read-only selected-root capability. No product activation uses it.
    safe_modes = []
    for mode, result in outcomes.items():
        try:
            assertions = json.loads(result["stdout"])
        except (ValueError, TypeError):
            continue
        if result["exitCode"] == 0 and assertions == {
            "resolvedSelectedPath": True, "selectedReadAllowed": True,
            "selectedWriteDenied": True, "outsideReadDenied": True,
            "outsideWriteDenied": True, "symlinkEscapeReadDenied": True
        } and not result["selectedWasWritten"] and not result["outsideWasWritten"]:
            safe_modes.append(mode)
    (output / "safe-modes.json").write_text(json.dumps(safe_modes))
    if not safe_modes:
        raise SystemExit("No proven read-only bookmark transfer. Do not activate repository inspection.")
