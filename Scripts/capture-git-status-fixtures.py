#!/usr/bin/env python3
"""Regenerate reference tests using only unique temporary synthetic Git repos.

This developer script uses the installed system Git. It does not install tools,
access real projects, or fetch. The generated Swift tests do not spawn processes.
"""

import base64
from pathlib import Path
import subprocess
import tempfile

OUTPUT = Path(__file__).resolve().parents[1] / "Tests/GitStatusCapturedFixtureTests.swift"
FIELDS = ("stagedCount", "unstagedCount", "untrackedCount", "conflictCount",
          "changedPathCount", "ahead", "behind")


def capture_fixtures(root):
    home = root / "home"
    home.mkdir()
    template = root / "template"
    template.mkdir()
    environment = {
        "PATH": "/usr/bin:/bin", "HOME": str(home), "XDG_CONFIG_HOME": str(home),
        "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_TEMPLATE_DIR": str(template),
        "GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": "", "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1", "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
        "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000",
    }
    fixtures = []

    def git(repository, *arguments, accepted_codes=(0,)):
        result = subprocess.run(
            ["/usr/bin/git", "-c", "user.name=MoeKit fixture",
             "-c", "user.email=fixture@example.invalid", *arguments],
            cwd=repository, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False,
        )
        if result.returncode not in accepted_codes:
            raise RuntimeError(f"Fixture command failed: {arguments!r}: {result.stderr!r}")
        return result.stdout

    def capture(name, repository, expected):
        # Capability failure is an error; do not fall back without no-lazy-fetch.
        output = git(repository, "--no-optional-locks", "--no-lazy-fetch", "status",
                     "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
        fixtures.append((name, base64.b64encode(output).decode("ascii"), expected))

    simple = root / "simple"
    simple.mkdir()
    git(simple, "init", "-b", "main")
    (simple / "first").write_text("one\n")
    capture("unborn", simple, (0, 0, 1, 0, 1, None, None))
    git(simple, "add", ".")
    git(simple, "commit", "-m", "base")
    capture("noChanges", simple, (0, 0, 0, 0, 0, None, None))
    (simple / "first").write_text("two\n")
    git(simple, "add", "first")
    (simple / "first").write_text("three\n")
    (simple / "new\nwith spaces").write_text("new")
    capture("bothAndUntracked", simple, (1, 1, 1, 0, 2, None, None))
    git(simple, "add", ".")
    git(simple, "commit", "-m", "more")
    git(simple, "mv", "first", "renamed")
    capture("renamed", simple, (1, 0, 0, 0, 1, None, None))
    git(simple, "commit", "-am", "rename")
    git(simple, "checkout", "--detach")
    capture("detached", simple, (0, 0, 0, 0, 0, None, None))

    conflict = root / "conflict"
    conflict.mkdir()
    git(conflict, "init", "-b", "main")
    (conflict / "conflict").write_text("base\n")
    git(conflict, "add", ".")
    git(conflict, "commit", "-m", "base")
    git(conflict, "checkout", "-b", "other")
    (conflict / "conflict").write_text("other\n")
    git(conflict, "commit", "-am", "other")
    git(conflict, "checkout", "main")
    (conflict / "conflict").write_text("main\n")
    git(conflict, "commit", "-am", "main")
    git(conflict, "merge", "other", accepted_codes=(1,))
    capture("conflicted", conflict, (0, 0, 0, 1, 1, None, None))
    git(conflict, "merge", "--abort")
    git(conflict, "update-ref", "refs/remotes/origin/main", "other")
    git(conflict, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
    git(conflict, "config", "branch.main.remote", "origin")
    git(conflict, "config", "branch.main.merge", "refs/heads/main")
    capture("divergedLocally", conflict, (0, 0, 0, 0, 0, 1, 1))

    sha256 = root / "sha256"
    sha256.mkdir()
    git(sha256, "init", "--object-format=sha256", "-b", "main")
    (sha256 / "first").write_text("one")
    git(sha256, "add", ".")
    git(sha256, "commit", "-m", "base")
    (sha256 / "first").write_text("two")
    capture("sha256", sha256, (0, 1, 0, 0, 1, None, None))
    return fixtures, git(root, "--version").decode("ascii").strip()


def render(fixtures, version):
    lines = ["import Foundation", "import Testing", "@testable import MoeKit", "",
             "// Captured from official /usr/bin/git in unique temporary synthetic repositories.",
             f"// Generator used {version}; no subprocess runs in the app or these tests.",
             "struct GitStatusCapturedFixtureTests {"]
    for name, data, expected in fixtures:
        lines.extend([f"    @Test func {name}() throws {{",
                      f'        let bytes = try #require(Data(base64Encoded: "{data}"))',
                      "        let result = try GitStatusParser.parse(bytes)"])
        for field, value in zip(FIELDS, expected):
            lines.append(f"        #expect(result.{field} == {'nil' if value is None else value})")
        lines.extend(["    }", ""])
    lines.append("}")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="moekit-git-fixtures-") as directory:
        fixtures, version = capture_fixtures(Path(directory))
    OUTPUT.write_text(render(fixtures, version))
    print(f"Wrote {len(fixtures)} system-Git fixtures to {OUTPUT.name}")
