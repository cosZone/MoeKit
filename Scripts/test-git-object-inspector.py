#!/usr/bin/env python3
"""Owned-temp-fixture tests for MoeKit's original fixed Git object inspector.

Compiles original C fixtures and copies the host Git only into a private test
session. No live repository/config, app catalogue, network, shell, or mutation
command against a user path is used. Apple signature verification and snapshot
construction are caller responsibilities tested by the native app suite.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
OTHER_SHA = "b" * 40
# This is an original inert stand-in, not third-party Git code. It verifies the
# actual exec argument/environment contract before exercising bounded failures.
FIXTURE = r'''
#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
static int matches(const char *key, const char *value) {
    const char *got = getenv(key); return got && !strcmp(got, value);
}
static int repeated(int fd, size_t count) {
    char bytes[4096]; memset(bytes, 'x', sizeof(bytes));
    while (count) {
        size_t chunk = count < sizeof(bytes) ? count : sizeof(bytes);
        ssize_t n = write(fd, bytes, chunk);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 91;
        count -= (size_t)n;
    }
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 2 && argc != 11 && argc != 12) return 90;
    char cwd[4096]; if (!getcwd(cwd, sizeof(cwd))) return 90;
    if (argc == 2 && strcmp(argv[1], "--version")) return 90;
    if (argc != 2 && (strcmp(argv[1], "--no-optional-locks") || strcmp(argv[2], "--no-replace-objects") ||
        strncmp(argv[3], "--git-dir=", 10) || strcmp(argv[3]+10, cwd) ||
        strcmp(argv[4], "-c") || strcmp(argv[5], "protocol.allow=never") ||
        strcmp(argv[6], "-c") || strcmp(argv[7], "core.hooksPath=/dev/null"))) return 90;
    if (argc == 11 && (strcmp(argv[8], "rev-parse") || strcmp(argv[9], "--verify") ||
        strcmp(argv[10], "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa^{tree}"))) return 90;
    if (argc == 12 && (strcmp(argv[8], "merge-base") || strcmp(argv[9], "--is-ancestor") ||
        strcmp(argv[10], "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ||
        strcmp(argv[11], "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))) return 90;
    if (!matches("HOME", cwd) || !matches("PATH", "/usr/bin:/bin") || !matches("LC_ALL", "C") ||
        !matches("GIT_CONFIG_NOSYSTEM", "1") || !matches("GIT_CONFIG_SYSTEM", "/dev/null") ||
        !matches("GIT_CONFIG_GLOBAL", "/dev/null") || !matches("GIT_ATTR_NOSYSTEM", "1") ||
        !matches("GIT_TERMINAL_PROMPT", "0") || !matches("GIT_ALLOW_PROTOCOL", "") ||
        !matches("GIT_OPTIONAL_LOCKS", "0") || !matches("GIT_NO_LAZY_FETCH", "1") ||
        getenv("GIT_DIR") || getenv("GIT_WORK_TREE") || getenv("GIT_CONFIG_COUNT") ||
        getenv("GIT_OBJECT_DIRECTORY") || getenv("GIT_ALTERNATE_OBJECT_DIRECTORIES") ||
        getenv("GIT_CONFIG_PARAMETERS") || getenv("GIT_CONFIG_KEY_0") || getenv("GIT_CONFIG_VALUE_0") ||
        getenv("LD_PRELOAD") || getenv("DYLD_INSERT_LIBRARIES") || getenv("UNRELATED_SECRET")) return 90;
    char stdin_byte; if (read(STDIN_FILENO, &stdin_byte, 1) != 0) return 90;
    DIR *fds = opendir("/dev/fd"); if (!fds) return 90;
    struct dirent *entry;
    while ((entry = readdir(fds))) {
        char *end; long fd = strtol(entry->d_name, &end, 10);
        if (end != entry->d_name && !*end && fd > 2 && fd != dirfd(fds)) return 90;
    }
    closedir(fds);
    for (int resource = 0; resource < 2; ++resource) {
        struct rlimit limit;
        if (getrlimit(resource ? RLIMIT_FSIZE : RLIMIT_CORE, &limit) || limit.rlim_cur) return 90;
    }
    FILE *file = fopen("fixture-mode", "r"); if (!file) return 90;
    char mode[64]; if (!fgets(mode, sizeof(mode), file)) return 90;
    fclose(file);
    if (!strcmp(mode, "exit-one")) return 1;
    if (!strcmp(mode, "exit-two")) return 2;
    if (!strcmp(mode, "floodout")) return repeated(STDOUT_FILENO, 129);
    if (!strcmp(mode, "flooderr")) return repeated(STDERR_FILENO, 65537);
    if (!strcmp(mode, "flood-negative")) { repeated(STDOUT_FILENO, 129); return 1; }
    if (!strcmp(mode, "flush")) return repeated(STDERR_FILENO, 65536);
    if (!strcmp(mode, "cpu")) { for (;;) {} }
    if (!strcmp(mode, "memory")) {
        for (int i = 0; i < 128; i++) {
            volatile unsigned char *page = malloc(1024 * 1024);
            if (!page) return 91;
            for (size_t j = 0; j < 1024 * 1024; j += 4096) page[j] = (unsigned char)i;
            struct timespec pause = {0, 2000000}; nanosleep(&pause, NULL);
        }
        return 91;
    }
    if (!strcmp(mode, "signal")) { raise(SIGABRT); return 91; }
    if (!strcmp(mode, "sleep")) { sleep(10); return 0; }
    if (!strcmp(mode, "descendant") || !strcmp(mode, "orphan")) {
        pid_t child = fork(); if (child < 0) return 91;
        if (!child) { for (;;) pause(); }
        if (!strcmp(mode, "descendant")) { for (;;) pause(); }
        // A successful leader must not leave a still-running group member.
        if (dprintf(STDERR_FILENO, "%ld", (long)child) < 0) return 91;
        return 0;
    }
    if (strcmp(mode, "success")) return 90;
    if (argc == 2 && printf("git version 2.39.5 (Apple Git-154)\n") < 0) return 91;
    if (argc == 11 && printf("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n") < 0) return 91;
    return 0;
}
'''


def clean_environment(home):
    environment = {key: os.environ[key] for key in
                   ("PATH", "DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "TMPDIR")
                   if key in os.environ}
    return environment | {"HOME": str(home), "TMPDIR": str(home), "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                          "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
                          "GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": ""}


class InspectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="moekit-git-inspector-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name).resolve()
        cls.helper = cls.base / "GitObjectInspector"
        cls.fixture = cls.base / "git-fixture"
        source = cls.base / "fixture.c"
        source.write_text(FIXTURE, encoding="ascii")
        for input_path, output, definitions in (
            (ROOT / "Helpers/GitObjectInspector/main.c", cls.helper,
             ["-DGIT_WALL_SECONDS=3", "-DGIT_CPU_SECONDS=1", "-DGIT_MEMORY_LIMIT_BYTES=67108864"]),
            (source, cls.fixture, []),
        ):
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", *definitions,
                            str(input_path), "-o", str(output)], check=True, timeout=60,
                           env=clean_environment(cls.base), stdin=subprocess.DEVNULL)
        if sys.platform == "darwin":
            cls.metrics_unavailable_helper = cls.base / "GitObjectInspector-no-metrics"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                            "-DGIT_WALL_SECONDS=3", "-DGIT_CPU_SECONDS=1", "-DGIT_TEST_UNAVAILABLE_METRICS=1",
                            str(ROOT / "Helpers/GitObjectInspector/main.c"), "-o", str(cls.metrics_unavailable_helper)],
                           check=True, timeout=60, env=clean_environment(cls.base), stdin=subprocess.DEVNULL)
            host_git = subprocess.run(["/usr/bin/xcrun", "--find", "git"], check=True,
                                      capture_output=True, text=True, timeout=30,
                                      env=clean_environment(cls.base)).stdout.strip()
        else:
            host_git = shutil.which("git")
        if not host_git:
            raise AssertionError("A host Git is required for isolated object fixture tests.")
        cls.git = cls.base / "copied-git"
        shutil.copy2(Path(host_git).resolve(), cls.git)

    def setUp(self):
        self.temporary_run = tempfile.TemporaryDirectory(prefix="run-", dir=self.base)
        self.addCleanup(self.temporary_run.cleanup)
        self.run_root = Path(self.temporary_run.name)
        self.snapshot = self.run_root / "private-snapshot"
        self.snapshot.mkdir(mode=0o700)
        self.original_home = self.run_root / "original-home"
        self.original_home.mkdir(mode=0o700)
        self.environment = clean_environment(self.original_home) | {
            "GIT_DIR": "/must-not-inherit", "GIT_WORK_TREE": "/must-not-inherit",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/must-not-inherit", "GIT_CONFIG_PARAMETERS": "bad config",
            "GIT_OBJECT_DIRECTORY": "/must-not-inherit", "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/must-not-inherit",
            "UNRELATED_SECRET": "synthetic-do-not-inherit",
        }

    def start(self, mode="success", *, first=SHA, second="-", binary=None, snapshot=None, helper=None, operation=None, **kwargs):
        (self.snapshot / "fixture-mode").write_text(mode, encoding="ascii")
        process = subprocess.Popen([str(helper or self.helper), str(binary or self.fixture),
                                    str(snapshot or self.snapshot), first, second] + ([operation] if operation else []),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=self.environment, **kwargs)
        def cleanup():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()
        self.addCleanup(cleanup)
        return process

    def finish(self, process, expected):
        # stdin EOF is intentional cancellation. Keep it open until helper exits.
        process.wait(timeout=7)
        out, err = process.communicate()
        self.assertEqual(process.returncode, expected, err)
        if expected:
            self.assertEqual(out, b"")
        return out, err

    def test_fixed_version_arguments_and_scrubbed_environment(self):
        out, err = self.finish(self.start(first="version"), 0)
        self.assertEqual(out, b"git version 2.39.5 (Apple Git-154)\n")
        self.assertEqual(err, b"")

    def test_version_failure_limits_and_cancel_are_not_ancestry(self):
        for mode, status in (("exit-one", 73), ("exit-two", 73), ("floodout", 71),
                             ("flooderr", 71), ("sleep", 72)):
            with self.subTest(mode=mode):
                self.finish(self.start(mode, first="version"), status)
        process = self.start("sleep", first="version")
        process.stdin.write(b"C"); process.stdin.flush()
        self.finish(process, 74)

    def test_version_accepts_no_alternate_spelling_or_extra_operation(self):
        for first, second in (("--version", "-"), ("Version", "-"), ("version ", "-"),
                              ("version", SHA), ("version", "version"), ("version", "--build-options"),
                              (SHA, "version"), ("version", "")):
            with self.subTest(first=first, second=second):
                self.finish(self.start(first=first, second=second), 64)

    def test_copied_real_git_version_from_private_directory(self):
        out, err = self.finish(self.start(binary=self.git, first="version"), 0)
        self.assertEqual(err, b"")
        version = out.decode("ascii")
        self.assertRegex(version, r"^git version [0-9]+(?:\.[0-9]+){1,3}(?: [A-Za-z0-9(). -]+)?\n$")
        if sys.platform == "darwin":
            self.assertRegex(version, r"^git version [0-9]+(?:\.[0-9]+){1,3} \(Apple Git-[0-9]+\)\n$")
            print("Copied toolchain Git fixture provenance: " + version.strip(), flush=True)
        self.assertFalse((self.snapshot / "config").exists())

    def test_fixed_tree_arguments_and_scrubbed_environment(self):
        out, err = self.finish(self.start(), 0)
        self.assertEqual(out, (SHA + "\n").encode())
        self.assertEqual(err, b"")

    def test_fixed_ancestry_arguments_and_scrubbed_environment(self):
        self.assertEqual(self.finish(self.start(second=OTHER_SHA), 0), (b"", b""))

    def test_nonancestor_has_dedicated_status_only_for_ancestry(self):
        self.finish(self.start("exit-one", second=OTHER_SHA), 75)
        self.finish(self.start("exit-one"), 73)
        for second in ("-", OTHER_SHA):
            self.finish(self.start("exit-two", second=second), 73)

    def test_output_limits_remain_distinct_from_negative_ancestry(self):
        for mode in ("floodout", "flooderr", "flood-negative"):
            with self.subTest(mode=mode):
                self.finish(self.start(mode, second=OTHER_SHA), 71)

    def test_fast_successful_queries_do_not_race_exit_metrics(self):
        for _ in range(25):
            self.finish(self.start(first="version"), 0)
            self.finish(self.start(), 0)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin owned-child task metrics")
    def test_unavailable_live_metrics_fail_closed_after_bounded_grace(self):
        process = self.start("sleep", helper=self.metrics_unavailable_helper)
        self.finish(process, 70)

    def test_memory_budget_stops_owned_allocation_fixture(self):
        # Darwin watches the owned child's RSS at the poll boundary; Linux uses
        # a hard data-segment cap, causing this fixture's malloc to fail instead.
        self.finish(self.start("memory"), 76 if sys.platform == "darwin" else 73)

    def test_wall_and_cpu_limits_and_signal_failure(self):
        for mode, status in (("sleep", 72), ("cpu", 73), ("signal", 73)):
            with self.subTest(mode=mode):
                self.finish(self.start(mode), status)

    def test_cancel_input_disconnect_and_signal(self):
        process = self.start("sleep")
        process.stdin.write(b"C"); process.stdin.flush()
        self.finish(process, 74)
        process = self.start("sleep")
        process.stdin.close(); process.stdin = None
        self.finish(process, 74)
        process = self.start("sleep")
        time.sleep(0.1); process.terminate()
        self.finish(process, 74)

    def test_inherited_fd_and_ignored_sigchld_do_not_escape(self):
        with (self.run_root / "unrelated-fd").open("wb") as marker:
            self.finish(self.start(pass_fds=(marker.fileno(),)), 0)
        def ignore_sigchld():
            signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        self.finish(self.start(preexec_fn=ignore_sigchld), 0)

    def test_inherited_stdin_writer_cannot_delay_disconnect(self):
        read_fd, write_fd = os.pipe()
        process = None
        try:
            (self.snapshot / "fixture-mode").write_text("sleep", encoding="ascii")
            process = subprocess.Popen([str(self.helper), str(self.fixture), str(self.snapshot), SHA, "-"],
                                       stdin=read_fd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       pass_fds=(write_fd,), env=self.environment)
            os.close(read_fd); read_fd = -1
            os.close(write_fd); write_fd = -1
            self.finish(process, 74)
        finally:
            if process is not None:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
                process.stdout.close(); process.stderr.close()
            if read_fd >= 0:
                os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    def test_wrong_argument_count_and_unexecutable_binary_fail_closed(self):
        for arguments in ([], [str(self.fixture), str(self.snapshot), SHA],
                          [str(self.fixture), str(self.snapshot), SHA, "-", "extra"]):
            result = subprocess.run([str(self.helper), *arguments], capture_output=True,
                                    env=self.environment, timeout=5)
            self.assertEqual(result.returncode, 64)
            self.assertEqual(result.stdout, b"")
        invalid_binary = self.run_root / "invalid-git"
        invalid_binary.write_text("not executable code", encoding="ascii")
        invalid_binary.chmod(0o700)
        self.finish(self.start(binary=invalid_binary), 73)

    def test_stalled_output_delivery_stays_bounded(self):
        # Filling stderr after the child exits exercises final-delivery polling.
        # Darwin pipe capacity may accommodate this entire bounded payload.
        process = self.start("flush")
        process.wait(timeout=7)
        _, err = process.communicate()
        self.assertIn(process.returncode, (0, 72))
        self.assertLessEqual(len(err), 65536)

    def test_successful_leader_stops_owned_descendant(self):
        unrelated = subprocess.Popen(["/bin/sleep", "10"])
        try:
            _, err = self.finish(self.start("orphan"), 0)
            child = int(err)
            self.assert_stopped(child)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate(); unrelated.wait(timeout=2)

    def test_cancel_stops_only_owned_process_group(self):
        unrelated = subprocess.Popen(["/bin/sleep", "10"])
        try:
            process = self.start("descendant")
            deadline = time.monotonic() + 2
            owned = []
            while time.monotonic() < deadline:
                rows = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid="], check=True,
                                      capture_output=True, text=True).stdout.splitlines()
                table = [tuple(map(int, row.split())) for row in rows]
                leader = next((pid for pid, parent, _ in table if parent == process.pid), None)
                owned = [pid for pid, _, group in table if group == leader]
                if len(owned) >= 2:
                    break
                time.sleep(0.02)
            self.assertGreaterEqual(len(owned), 2)
            process.stdin.write(b"C"); process.stdin.flush()
            self.finish(process, 74)
            for pid in owned:
                self.assert_stopped(pid)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate(); unrelated.wait(timeout=2)

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 2
        state = ""
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                                   text=True).stdout.strip()
            if not state or state.startswith("Z"):
                return
            time.sleep(0.02)
        self.fail(f"Owned synthetic child {pid} is still running ({state}).")

    def test_rejects_invalid_object_arguments_before_execution(self):
        for first, second in (("HEAD", "-"), (SHA.upper(), "-"), ("a" * 39, "-"),
                              ("a" * 41, "-"), ("--help", "-"), (SHA + "^{tree}", "-"),
                              (SHA, "HEAD"), (SHA, "--help"), (SHA, OTHER_SHA + " ")):
            with self.subTest(first=first, second=second):
                self.finish(self.start(first=first, second=second), 64)

    def test_rejects_nonprivate_or_linked_snapshot_and_binary(self):
        self.snapshot.chmod(0o755)
        self.finish(self.start(), 64)
        self.snapshot.chmod(0o700)
        linked_snapshot = self.run_root / "linked-snapshot"
        linked_snapshot.symlink_to(self.snapshot, target_is_directory=True)
        self.finish(self.start(snapshot=linked_snapshot), 64)
        linked_binary = self.run_root / "linked-binary"
        linked_binary.symlink_to(self.fixture)
        self.finish(self.start(binary=linked_binary), 64)
        self.finish(self.start(binary=self.snapshot), 64)
        self.finish(self.start(binary="relative-git"), 64)
        self.finish(self.start(snapshot="relative-snapshot"), 64)

    def test_original_home_is_not_read_or_written(self):
        config = self.original_home / ".gitconfig"
        config.write_text("[include]\npath = /must-not-read\n", encoding="ascii")
        before = config.stat()
        self.finish(self.start(), 0)
        self.assertEqual(config.read_text(), "[include]\npath = /must-not-read\n")
        self.assertEqual(config.stat().st_ino, before.st_ino)
        self.assertEqual(config.stat().st_mtime_ns, before.st_mtime_ns)

    def make_objects(self):
        # All authoring commands operate exclusively in this owned fixture.
        environment = clean_environment(self.run_root) | {
            "GIT_AUTHOR_NAME": "Synthetic Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Synthetic Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z",
        }
        def git(*args, data=None):
            return subprocess.run([str(self.git), "--git-dir=" + str(self.snapshot), *args],
                                  input=data, capture_output=True, check=True, env=environment,
                                  timeout=15).stdout.decode("ascii").strip()
        git("init", "--bare", str(self.snapshot))
        blob = git("hash-object", "-w", "--stdin", data=b"synthetic tracked data\n")
        tree = git("mktree", data=f"100644 blob {blob}\tfixture.txt\n".encode())
        root = git("commit-tree", tree, "-m", "root")
        descendant = git("commit-tree", tree, "-p", root, "-m", "descendant")
        unique = git("commit-tree", tree, "-p", root, "-m", "unique")
        # Runtime snapshot contract: objects, refs, HEAD only; no config/hooks.
        (self.snapshot / "config").unlink()
        for name in ("hooks", "info"):
            shutil.rmtree(self.snapshot / name)
        (self.snapshot / "description").unlink()
        return tree, root, descendant, unique

    def snapshot_state(self):
        return {str(path.relative_to(self.snapshot)): (stat.S_IMODE(path.stat().st_mode),
                path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes() if path.is_file() else None)
                for path in self.snapshot.rglob("*")}

    def test_copied_real_git_config_free_objects_and_ancestry(self):
        tree, root, descendant, unique = self.make_objects()
        (self.snapshot / "fixture-mode").write_text("success", encoding="ascii")
        before = self.snapshot_state()
        out, err = self.finish(self.start(binary=self.git, first=descendant), 0)
        self.assertEqual(out.decode().strip(), tree)
        self.assertEqual(err, b"")
        self.finish(self.start(binary=self.git, first=root, second=descendant), 0)
        self.finish(self.start(binary=self.git, first=descendant, second=unique), 75)
        self.finish(self.start(binary=self.git, first="0" * 40), 73)
        out, err = self.finish(self.start(binary=self.git, first=descendant, second=root, operation="count"), 0)
        self.assertEqual(out, b"1\n")
        self.assertEqual(err, b"")
        out, _ = self.finish(self.start(binary=self.git, first=root, second=descendant, operation="count"), 0)
        self.assertEqual(out, b"0\n")
        self.finish(self.start(binary=self.git, first=descendant, second=root, operation="push"), 64)
        self.finish(self.start(binary=self.git, first="version", operation="count"), 64)
        # Test driver rewrites only its own mode marker; Git must not mutate data.
        after = self.snapshot_state()
        before.pop("fixture-mode"); after.pop("fixture-mode")
        self.assertEqual(before, after)
        self.assertFalse((self.snapshot / "config").exists())


if __name__ == "__main__":
    unittest.main()
