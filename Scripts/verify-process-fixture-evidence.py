#!/usr/bin/env python3
"""Require affirmative, exact-source owned native process fixture evidence."""
import argparse
import json
from pathlib import Path
import re
import stat

CHECKS = {"stale_generation_refused", "same_path_exec_refused", "term_submitted", "term_observed",
          "kill_submitted", "kill_observed", "unselected_neighbor_survived"}

def verify(directory, source_sha):
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Invalid source SHA")
    paths = list(directory.glob("process-fixture-*.json"))
    if len(paths) != 1:
        raise ValueError("Exactly one affirmative native process fixture record is required")
    path = paths[0]
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 16384:
        raise ValueError("Invalid evidence file")
    evidence = json.loads(path.read_text())
    if evidence.get("source_sha") != source_sha or set(evidence.get("checks", {})) != CHECKS:
        raise ValueError("Wrong source or missing native fixture checks")
    if any(value is not True for value in evidence["checks"].values()):
        raise ValueError("Every actual native fixture outcome must be affirmative")
    return evidence

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    verify(args.directory, args.source_sha)
    print("Verified exact-source native TERM/KILL, stale-token and same-path-exec refusals, and unselected-neighbor survival.")
