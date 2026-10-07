#!/usr/bin/env python3
"""Original fixed-operation PTY tests: uniquely owned compiled fixtures only.

Never discovers, installs, executes, updates, or upgrades real Homebrew/Mole.
The test-only fixed executable and HOME are compiled into a separate helper.
"""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import signal
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def frame(kind, payload=b"", phase=1):
    if kind == "I":
        payload = bytes([phase]) + payload
    return kind.encode("ascii") + struct.pack(">I", len(payload)) + payload


class Running:
    def __init__(self, args, drain=True, **kwargs):
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, **kwargs)
        self.out, self.err = bytearray(), bytearray()
        self.threads = []
        self.drain = drain
        for stream, destination in ((self.process.stdout, self.out), (self.process.stderr, self.err)):
            if stream is self.process.stdout and not drain:
                continue
            thread = threading.Thread(target=self.collect, args=(stream, destination), daemon=True)
            thread.start()
            self.threads.append(thread)

    @staticmethod
    def collect(stream, destination):
        while True:
            part = os.read(stream.fileno(), 65536)
            if not part:
                break
            destination.extend(part)

    def send(self, bytes_):
        self.process.stdin.write(bytes_)
        self.process.stdin.flush()

    def await_output(self, value, timeout=2):
        deadline = time.monotonic() + timeout
        while value not in self.out and time.monotonic() < deadline and self.process.poll() is None:
            time.sleep(0.005)
        if value not in self.out:
            raise AssertionError(f"Missing {value!r}: stdout={bytes(self.out)!r}, stderr={bytes(self.err)!r}")

    def finish(self, timeout=6):
        self.process.wait(timeout=timeout)  # stdin stays open: EOF means cancellation
        if not self.drain:
            self.out.extend(self.process.stdout.read())
        for thread in self.threads:
            thread.join(timeout=2)
            if thread.is_alive():
                raise AssertionError("Supervisor left an output writer alive")
        if self.process.stdin:
            self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        return self.process.returncode, bytes(self.out), bytes(self.err)


class OperationTerminalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moekit-operation-terminal-")
        cls.base = Path(cls.tmp.name).resolve()
        cls.home = cls.base / "home"
        cls.brew = cls.base / "fixed-fixture-brew"
        cls.pristine = cls.base / "pristine-fixture"
        cls.supervisor = cls.base / "operation-terminal"
        cls.alias_supervisor = cls.base / "alias-operation-terminal"
        cls.alias = cls.base / "aliases/bin/brew"
        cls.alias.parent.mkdir(parents=True)
        flags = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2"]
        libraries = [] if platform.system() == "Darwin" else ["-lutil", "-lcrypto"]
        cls.flags, cls.libraries = flags, libraries
        subprocess.run(flags + [str(ROOT / "Helpers/OperationTerminal/fixture.c"), "-o", str(cls.pristine)], check=True)
        subprocess.run(flags + ["-DOPERATION_WALL_SECONDS=3", "-DOPERATION_BACKPRESSURE_SECONDS=1",
                               f'-DMOEKIT_OPERATION_FIXTURE_BREW="{cls.brew}"',
                               f'-DMOEKIT_OPERATION_FIXTURE_HOME="{cls.home}"',
                               str(ROOT / "Helpers/OperationTerminal/main.c"), "-o", str(cls.supervisor)] + libraries, check=True)
        subprocess.run(flags + ["-DOPERATION_WALL_SECONDS=3", "-DOPERATION_BACKPRESSURE_SECONDS=1",
                               f'-DMOEKIT_OPERATION_FIXTURE_BREW="{cls.brew}"',
                               f'-DMOEKIT_OPERATION_FIXTURE_HOME="{cls.home}"',
                               f'-DMOEKIT_OPERATION_FIXTURE_ALIAS="{cls.alias}"',
                               str(ROOT / "Helpers/OperationTerminal/main.c"), "-o", str(cls.alias_supervisor)] + libraries, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        if self.brew.exists() or self.brew.is_symlink():
            self.brew.unlink()
        shutil.copyfile(self.pristine, self.brew)
        self.brew.chmod(0o700)
        if self.home.exists():
            shutil.rmtree(self.home)
        self.home.mkdir(mode=0o700)
        if self.alias.exists() or self.alias.is_symlink():
            self.alias.unlink()
        self.alias.symlink_to("../../fixed-fixture-brew")
        self.active = []

    def tearDown(self):
        for running in self.active:
            if running.process.poll() is None:
                try:
                    running.send(frame("C"))
                except (BrokenPipeError, ValueError):
                    pass
                running.finish()

    def arguments(self, executable=None):
        executable = executable or self.brew
        stat = executable.stat()
        seconds, nanoseconds = divmod(stat.st_mtime_ns, 1_000_000_000)
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        return [str(self.supervisor), str(executable), str(self.home), str(stat.st_dev), str(stat.st_ino),
                str(stat.st_uid), str(stat.st_mode), str(stat.st_size), str(seconds), str(nanoseconds), digest]

    def start(self, mode="success", args=None, **kwargs):
        (self.home / "mode").write_text(mode)
        environment = dict(os.environ, HOME="/must-not-inherit", MOLE_SECRET="forbidden", DYLD_INSERT_LIBRARIES="",
                           BASH_ENV="/must-not-read", HOMEBREW_API_DOMAIN="https://must-not-inherit.invalid")
        running = Running(args or self.arguments(), env=environment, **kwargs)
        self.active.append(running)
        return running

    def finish(self, running, expected=0):
        code, out, err = running.finish()
        self.assertEqual(code, expected, (out[-2000:], err))
        self.assertTrue(err.endswith(f"MKOT1 RESULT {expected}\n".encode()), err)
        self.assertLess(len(err), 1024)
        return out, err

    def calls(self):
        path = self.home / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def stopped(self, pid):
        deadline = time.monotonic() + 2
        state = ""
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            # Linux container init can leave reparented zombies. They are stopped.
            if not state or state.startswith("Z"):
                return
            time.sleep(0.02)
        self.fail(f"Owned descendant still running: {pid}, {state}")

    def await_file(self, name):
        path = self.home / name
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if path.exists() and path.read_text().strip():
                return path.read_text().strip()
            time.sleep(0.005)
        self.fail(f"Missing fixture marker {name}")

    def test_fixed_argv_order_and_pty(self):
        out, err = self.finish(self.start())
        self.assertEqual(self.calls(), ["update", "upgrade --formula mole"])
        self.assertIn(b"FIXTURE update\r\n", out)
        self.assertIn(b"FIXTURE upgrade\r\n", out)
        self.assertEqual(err, b"MKOT1 PHASE update\nMKOT1 EXIT update 0\nMKOT1 PHASE upgrade\nMKOT1 EXIT upgrade 0\nMKOT1 RESULT 0\n")

    def test_environment_exact_allowlist(self):
        out, _ = self.finish(self.start("environment"))
        expected = {f"HOME={self.home}", "TERM=xterm-256color",
                    "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_ANALYTICS=1", "LC_ALL=en_US.UTF-8"}
        actual = [line[4:] for line in out.decode().splitlines() if line.startswith("ENV:")]
        self.assertEqual(set(actual), expected)
        self.assertEqual(len(actual), len(expected) * 2)

    def test_input_resize_and_fragmented_frames(self):
        run = self.start("interactive")
        run.await_output(b"READY")
        data = frame("R", struct.pack(">HH", 41, 123)) + frame("I", b"hello fixture\n")
        for byte in data:
            run.send(bytes([byte]))
        out, _ = self.finish(run)
        self.assertIn(b"INPUT:hello fixture\r\nSIZE:41,123", out)

    def test_ctrl_c_is_terminal_byte_and_decodes_signal(self):
        run = self.start("ctrl-c")
        run.await_output(b"READY")
        run.send(frame("I", b"\x03"))
        _, err = self.finish(run, 73)
        self.assertIn(b"MKOT1 SIGNAL update 2\n", err)
        self.assertEqual(self.calls(), ["update"])

    def test_update_failure_never_upgrades(self):
        _, err = self.finish(self.start("update-failure"), 73)
        self.assertIn(b"MKOT1 EXIT update 19\n", err)
        self.assertEqual(self.calls(), ["update"])

    def test_upgrade_failure_preserves_code(self):
        _, err = self.finish(self.start("upgrade-failure"), 73)
        self.assertIn(b"MKOT1 EXIT upgrade 23\n", err)

    def test_signal_exit_is_not_exit_code(self):
        _, err = self.finish(self.start("signal"), 73)
        self.assertIn(b"MKOT1 SIGNAL update 15\n", err)
        self.assertNotIn(b"MKOT1 EXIT update", err)

    def alias_arguments(self):
        args = self.arguments()
        args[0] = str(self.alias_supervisor)
        return args

    def test_known_alias_relative_absolute_and_lexical_targets(self):
        for target in ("../../fixed-fixture-brew", str(self.brew), "./../.././fixed-fixture-brew"):
            with self.subTest(target=target):
                self.alias.unlink()
                self.alias.symlink_to(target)
                self.finish(self.start(args=self.alias_arguments()))

    def test_known_alias_rejects_other_target(self):
        self.alias.unlink()
        self.alias.symlink_to(self.pristine)
        self.finish(self.start(args=self.alias_arguments()), 76)
        self.assertEqual(self.calls(), [])

    def test_known_alias_must_be_a_link(self):
        self.alias.unlink()
        self.alias.write_text("not a link")
        self.finish(self.start(args=self.alias_arguments()), 76)
        self.assertEqual(self.calls(), [])

    def test_known_alias_canonical_final_component_cannot_be_link(self):
        args = self.alias_arguments()
        self.brew.unlink()
        self.brew.symlink_to(self.pristine)
        self.finish(self.start(args=args), 76)
        self.assertEqual(self.calls(), [])

    def test_known_alias_rejects_canonical_ancestor_symlink(self):
        actual_parent = self.base / "actual-parent"
        actual_parent.mkdir()
        canonical_parent = self.base / "escaped-parent"
        canonical_parent.symlink_to(actual_parent, target_is_directory=True)
        canonical = canonical_parent / "brew"
        shutil.copyfile(self.pristine, canonical)
        canonical.chmod(0o700)
        self.alias.unlink()
        self.alias.symlink_to(os.path.relpath(canonical, self.alias.parent))
        helper = self.base / "ancestor-alias-supervisor"
        subprocess.run(self.flags + [f'-DMOEKIT_OPERATION_FIXTURE_BREW="{canonical}"',
                                      f'-DMOEKIT_OPERATION_FIXTURE_HOME="{self.home}"',
                                      f'-DMOEKIT_OPERATION_FIXTURE_ALIAS="{self.alias}"',
                                      str(ROOT / "Helpers/OperationTerminal/main.c"), "-o", str(helper)] + self.libraries, check=True)
        args = self.arguments(executable=canonical)
        args[0] = str(helper)
        self.finish(self.start(args=args), 76)
        self.assertEqual(self.calls(), [])

    def test_known_alias_is_revalidated_after_update(self):
        # The fixture learns only this uniquely owned marker path. The helper's
        # allowed alias and canonical executable remain compile-time constants.
        (self.home / "test-alias-path").write_text(str(self.alias))
        self.finish(self.start("replace-alias", args=self.alias_arguments()), 76)
        self.assertEqual(self.calls(), ["update"])

    def test_reject_arbitrary_path(self):
        args = self.arguments()
        args[1] = "/bin/sh"
        self.finish(self.start(args=args), 64)
        self.assertEqual(self.calls(), [])

    def test_reject_foreign_home(self):
        args = self.arguments()
        args[2] = str(self.base)
        self.finish(self.start(args=args), 64)
        self.assertEqual(self.calls(), [])

    def test_reject_every_changed_snapshot_field(self):
        for index in range(3, 11):
            with self.subTest(index=index):
                args = self.arguments()
                args[index] = ("0" * 64) if index == 10 else str(int(args[index]) + 1)
                self.finish(self.start(args=args), 76)
                self.assertEqual(self.calls(), [])

    def test_reject_content_change_with_same_identity_metadata(self):
        args = self.arguments()
        stat = self.brew.stat()
        content = bytearray(self.brew.read_bytes())
        content[-1] ^= 1
        self.brew.write_bytes(content)
        os.utime(self.brew, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.finish(self.start(args=args), 76)
        self.assertEqual(self.calls(), [])

    def test_reject_final_symlink(self):
        args = self.arguments()
        self.brew.unlink()
        self.brew.symlink_to(self.pristine)
        self.finish(self.start(args=args), 76)
        self.assertEqual(self.calls(), [])

    def test_reject_writable_or_nonexecutable_binary(self):
        for mode in (0o770, 0o707, 0o600, 0o4700):
            with self.subTest(mode=oct(mode)):
                self.brew.chmod(mode)
                self.finish(self.start(), 76)
                self.assertEqual(self.calls(), [])

    def test_valid_self_update_is_freshly_verified(self):
        inode = self.brew.stat().st_ino
        self.finish(self.start("replace"))
        self.assertNotEqual(inode, self.brew.stat().st_ino)
        self.assertEqual(self.calls(), ["update", "upgrade --formula mole"])

    def test_insecure_self_update_blocks_upgrade(self):
        self.finish(self.start("insecure-update"), 76)
        self.assertEqual(self.calls(), ["update"])

    def test_symlink_self_update_blocks_upgrade(self):
        self.finish(self.start("symlink-update"), 76)
        self.assertEqual(self.calls(), ["update"])

    def test_buffered_input_does_not_cross_phase(self):
        run = self.start("discard-input")
        run.await_output(b"READY")
        run.send(frame("I", b"go\nstale-input\n"))
        out, _ = self.finish(run)
        self.assertIn(b"INPUT-CLEARED", out)

    def test_old_swift_backlog_cannot_cross_phase(self):
        run = self.start("phase-input")
        run.await_output(b"UPGRADE-READY")
        # This models an old frame retained in Swift until after update exits.
        run.send(frame("I", b"old pending paste\n", phase=1))
        run.send(frame("I", b"new upgrade input\n", phase=2))
        out, _ = self.finish(run)
        self.assertIn(b"UPGRADE-INPUT:new upgrade input", out)
        self.assertNotIn(b"old pending paste", out)

    def test_maximum_input_frame_includes_phase_tag(self):
        run = self.start("sleep")
        run.await_output(b"READY")
        run.send(frame("I", b"x" * 4096))
        run.send(frame("C"))
        self.finish(run, 74)

    def test_unknown_input_phase_is_rejected(self):
        run = self.start("sleep")
        run.await_output(b"READY")
        run.send(frame("I", b"x", phase=3))
        self.finish(run, 75)

    def test_cancel_owned_group_unrelated_survives(self):
        unrelated = subprocess.Popen(["/bin/sleep", "20"])
        try:
            run = self.start("descendant")
            child = int(self.await_file("descendant-pid"))
            run.send(frame("C"))
            self.finish(run, 74)
            self.stopped(child)
            self.assertIsNone(unrelated.poll())
            self.assertEqual(self.calls(), ["update"])
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=2)

    def test_parent_eof_stops_group(self):
        run = self.start("descendant")
        child = int(self.await_file("descendant-pid"))
        run.process.stdin.close()
        run.process.stdin = None
        self.finish(run, 74)
        self.stopped(child)

    def test_signal_cancellation_stops_group(self):
        run = self.start("descendant")
        child = int(self.await_file("descendant-pid"))
        run.process.terminate()
        self.finish(run, 74)
        self.stopped(child)

    def test_normal_leader_exit_stops_descendants(self):
        for mode, expected in (("orphan-success", 0), ("orphan-failure", 73)):
            with self.subTest(mode=mode):
                (self.home / "descendant-pid").unlink(missing_ok=True)
                self.finish(self.start(mode), expected)
                self.stopped(int(self.await_file("descendant-pid")))

    def test_output_bound(self):
        out, _ = self.finish(self.start("flood"), 71)
        self.assertLessEqual(len(out), 16 * 1024 * 1024)
        self.assertEqual(self.calls(), ["update"])

    def test_output_bound_counts_both_phases(self):
        out, _ = self.finish(self.start("flood-both"), 71)
        self.assertLessEqual(len(out), 16 * 1024 * 1024)
        self.assertEqual(self.calls(), ["update", "upgrade --formula mole"])

    def test_undrained_stdout_is_bounded(self):
        out, _ = self.finish(self.start("flush", drain=False), 77)
        self.assertLess(len(out), 256 * 1024)

    def test_cancel_while_stdout_undrained(self):
        run = self.start("flush", drain=False)
        self.await_file("calls")
        time.sleep(0.1)
        run.send(frame("C"))
        self.finish(run, 74)

    def test_parent_eof_while_stdout_undrained(self):
        run = self.start("flush", drain=False)
        self.await_file("calls")
        run.process.stdin.close()
        run.process.stdin = None
        self.finish(run, 74)

    def test_wall_bound(self):
        self.finish(self.start("sleep"), 72)
        self.assertEqual(self.calls(), ["update"])

    def test_malformed_frames(self):
        bad = [b"X\0\0\0\0", b"I" + struct.pack(">I", 4098), frame("I"), frame("R", b"123"),
               frame("R", struct.pack(">HH", 0, 80)), frame("R", struct.pack(">HH", 24, 1001)), frame("C", b"x")]
        for data in bad:
            with self.subTest(data=data):
                run = self.start("sleep")
                run.await_output(b"READY")
                run.send(data)
                self.finish(run, 75)

    def test_partial_frame_eof(self):
        run = self.start("sleep")
        run.await_output(b"READY")
        run.send(b"I\0\0")
        run.process.stdin.close()
        run.process.stdin = None
        self.finish(run, 75)

    def test_inherited_descriptor_closed(self):
        with (self.home / "inherited").open("wb") as marker:
            self.finish(self.start(pass_fds=(marker.fileno(),)))

    def test_inherited_stdin_writer_cannot_hide_parent_eof(self):
        (self.home / "mode").write_text("sleep")
        read_fd, write_fd = os.pipe()
        process = None
        try:
            process = subprocess.Popen(self.arguments(), stdin=read_fd, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, pass_fds=(write_fd,))
            os.close(read_fd)
            read_fd = -1
            os.close(write_fd)
            write_fd = -1
            process.wait(timeout=2)
            out, err = process.communicate()
            self.assertEqual(process.returncode, 74, (out, err))
            self.assertTrue(err.endswith(b"MKOT1 RESULT 74\n"))
        finally:
            if read_fd >= 0:
                os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)
            if process and process.poll() is None:
                process.terminate()
                process.communicate(timeout=2)

    def test_initial_resize_is_applied_before_input(self):
        run = self.start("interactive")
        run.send(frame("R", struct.pack(">HH", 55, 99)))
        run.await_output(b"READY")
        run.send(frame("I", b"initial size\n"))
        out, _ = self.finish(run)
        self.assertIn(b"SIZE:55,99", out)

    def test_inherited_blocked_signals_are_normalized(self):
        def block():
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCHLD, signal.SIGTERM, signal.SIGINT})
        run = self.start("ctrl-c", preexec_fn=block)
        run.await_output(b"READY")
        run.send(frame("I", b"\x03"))
        _, err = self.finish(run, 73)
        self.assertIn(b"MKOT1 SIGNAL update 2\n", err)

    def test_inherited_ignored_sigchld_is_normalized(self):
        def ignore():
            signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        self.finish(self.start(preexec_fn=ignore))

    def test_shebang_native_execution(self):
        # Only this unique compile-time fixture path becomes a script. No shell
        # command string or arbitrary runtime executable enters the helper ABI.
        self.brew.write_text("#!/bin/sh\nprintf 'SCRIPT:%s\\n' \"$1\"\nexit 0\n")
        self.brew.chmod(0o700)
        out, _ = self.finish(self.start())
        self.assertIn(b"SCRIPT:update", out)
        self.assertIn(b"SCRIPT:upgrade", out)


if __name__ == "__main__":
    unittest.main()
