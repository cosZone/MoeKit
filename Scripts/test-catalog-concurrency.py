#!/usr/bin/env python3
"""Compile actual catalog sources and exercise independent native writer processes.

macOS only. Python controls deterministic pipe handshakes rather than sleeping to
induce a race, and it never forks the multithreaded Swift Testing runner. No real
catalog, project, credential, or app process is read or changed.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 20


class Writer:
    def __init__(self, executable: Path, directory: Path, label: str, hold: bool):
        self.process = subprocess.Popen(
            [str(executable), str(directory), label, "hold" if hold else "direct"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.pending = bytearray()
        try:
            self.expect("LOADED")
        except BaseException:
            self.stop()
            raise

    def send(self, command: str):
        self.process.stdin.write((command + "\n").encode())
        self.process.stdin.flush()

    def expect(self, expected: str):
        deadline = time.monotonic() + TIMEOUT
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b"\n" not in self.pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise AssertionError(f"Timed out waiting for {expected}")
                data = os.read(self.process.stdout.fileno(), 4096)
                if not data:
                    raise AssertionError(f"Writer exited before {expected}: {self.process.poll()}")
                self.pending.extend(data)
        line, _, rest = self.pending.partition(b"\n")
        self.pending[:] = rest
        actual = line.decode()
        if actual != expected:
            raise AssertionError(f"Expected {expected}, got {actual}")

    def finish(self):
        if self.process.poll() is None:
            self.send("EXIT")
        _, errors = self.process.communicate(timeout=TIMEOUT)
        if self.process.returncode != 0:
            raise AssertionError(f"Writer failed ({self.process.returncode}): {errors.decode(errors='replace')}")
        # Sanitizers normally abort; also reject a diagnostic from recover mode.
        if b"AddressSanitizer" in errors or b"LeakSanitizer" in errors:
            raise AssertionError(errors.decode(errors="replace"))

    def stop(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=TIMEOUT)


@contextmanager
def writers(executable: Path, first: Path, second: Path):
    active = []
    try:
        for root, label, hold in [(first, "first", True), (second, "second", False)]:
            writer = Writer(executable, root, label, hold)
            active.append(writer)
        yield active
        for writer in active:
            writer.finish()
    finally:
        for writer in active:
            writer.stop()


def check_contents(directory: Path, names: list[str]):
    projects = json.loads((directory / "projects.json").read_text())
    actual = sorted(item["name"] for item in projects)
    if actual != sorted(names):
        raise AssertionError(f"Expected projects {names}, got {actual}")
    if set(p.name for p in directory.iterdir()) != {"projects.json", "projects.json.lock"}:
        raise AssertionError("Unexpected leftover temp file or missing permanent lock")


def exercise(executable: Path, directory: Path, *, seeded: bool, alias: bool, abort: bool):
    directory.mkdir(mode=0o700)
    if seeded:
        (directory / "projects.json").write_text("[]")
    # On macOS /tmp and /private/tmp resolve to the same retained directory inode.
    other = directory.resolve() if alias else directory
    original = (directory / "projects.json").read_bytes() if seeded else None
    with writers(executable, directory, other) as (first, second):
        first.send("SAVE")
        first.expect("LOCKED")
        lock_identity = (directory / "projects.json.lock").stat().st_ino
        second.send("SAVE")
        second.expect("BUSY")
        current = (directory / "projects.json").read_bytes() if (directory / "projects.json").exists() else None
        if current != original:
            raise AssertionError("Busy contender changed the original catalog")
        first.send("ABORT" if abort else "COMMIT")
        first.expect("ABORTED" if abort else "SAVED")
        if abort:
            second.send("SAVE")
            second.expect("SAVED")
            check_contents(directory, ["second"])
        else:
            winner = (directory / "projects.json").read_bytes()
            second.send("SAVE")
            second.expect("CONFLICT")
            if (directory / "projects.json").read_bytes() != winner:
                raise AssertionError("Stale retry lost the committed winner")
            check_contents(directory, ["first"])
            second.send("LOAD")
            second.expect("LOADED")
            second.send("SAVE")
            second.expect("SAVED")
            check_contents(directory, ["first", "second"])
        if (directory / "projects.json.lock").stat().st_ino != lock_identity:
            raise AssertionError("The lock inode changed after release/retry")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release", "asan"], required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Native catalog concurrency fixtures require macOS; not run on this host")
    # Choosing /tmp explicitly also tests its normal macOS /private/tmp alias.
    with tempfile.TemporaryDirectory(prefix="MoeKit-native-writers-", dir="/tmp") as temporary:
        root = Path(temporary)
        executable = root / "CatalogWriter"
        sources = ["Sources/Core/WorkspaceModels.swift", "Sources/Core/GitDiscoveryMetadata.swift",
                   "Sources/Services/RepositoryScanner.swift", "Sources/Services/BoundedRegularFileReader.swift",
                   "Sources/Services/CatalogWriteCoordinator.swift", "Sources/Services/CatalogPersistence.swift",
                   "Scripts/Fixtures/CatalogWriter/main.swift"]
        # The descriptor reader/scanner share this helper after the separate
        # scanner-anchoring change; compiling it does not exercise real discovery.
        anchored = ROOT / "Sources/Services/AnchoredDirectory.swift"
        if anchored.exists():
            sources.append(str(anchored))
        flags = ["-Onone"] if args.configuration == "debug" else ["-O"]
        if args.configuration == "asan":
            flags += ["-sanitize=address"]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                        "-g", *flags, *[str(ROOT / p) for p in sources], "-o", str(executable)],
                       check=True, timeout=180)
        count = 0
        for seeded in [False, True]:
            for alias in [False, True]:
                for abort in [False, True]:
                    exercise(executable, root / f"fixture-{count}", seeded=seeded, alias=alias, abort=abort)
                    count += 1
        print(f"Passed {count} deterministic native two-process catalog fixtures ({args.configuration})")


if __name__ == "__main__":
    main()
