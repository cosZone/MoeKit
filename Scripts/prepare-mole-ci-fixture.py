#!/usr/bin/env python3
"""CI-only official analyzer fixture. Never invoked by the app or on user files."""
import hashlib
import os
from pathlib import Path
import platform
import sys
import urllib.request

if platform.system() != "Darwin" or os.environ.get("CI") != "true":
    raise SystemExit("This helper is only for the macOS CI synthetic fixture job.")
assets = {
    "arm64": ("analyze-darwin-arm64", 3827474, "62c6b5076349081a34e60256a1471979f600d74d8f4990745a37d30d6faa00e1"),
    "x86_64": ("analyze-darwin-amd64", 4022992, "cff7d9da8bd18cb3364d566186944b5b14b01e21e5bb4a3d61579f553ea39ad7"),
}
name, size, digest = assets[platform.machine()]
url = f"https://github.com/tw93/Mole/releases/download/V1.57.0/{name}"
with urllib.request.urlopen(url, timeout=60) as response:
    data = response.read(size + 1)
if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
    raise SystemExit("Official fixture size/hash mismatch; refusing execution.")
folder = Path(os.environ["RUNNER_TEMP"]) / ("MoeKit-pinned-analyzer-" + os.urandom(8).hex())
folder.mkdir(mode=0o700)
path = folder / name
with path.open("xb") as output: output.write(data)
path.chmod(0o500)
# Do not clear quarantine or re-sign. Native validation must accept/reject as-is.
# The test bundle receives only this path; no upstream executable is embedded
# in either app or test bundle. The resource is generated and git-ignored; it is absent outside this job.
resource = Path(__file__).resolve().parents[1] / "Tests/Resources/MoleAnalyzerFixturePath.txt"
resource.write_text(str(path) + "\n")
print(f"Prepared exact official V1.57.0 {platform.machine()} fixture; no user paths scanned.")
