#!/usr/bin/env python3
"""Original supervisor integration tests: synthetic binaries and temp paths only."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SupervisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moekit-supervisor-")
        cls.base = Path(cls.tmp.name)
        cls.supervisor = cls.base / "supervisor"
        cls.analyzer = cls.base / "analyzer"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-DMOLE_WALL_SECONDS=3", "-DMOLE_CPU_SECONDS=1", str(ROOT / "Helpers/MoleAnalysisSupervisor/main.c"), "-o", str(cls.supervisor)], check=True)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", str(ROOT / "Scripts/Fixtures/MoleAnalyzer/main.c"), "-o", str(cls.analyzer)], check=True)
    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()
    def setUp(self):
        self.run_tmp = tempfile.TemporaryDirectory(dir=self.base)
        self.run_root = Path(self.run_tmp.name)
        self.scope = self.run_root / "selected"
        self.home = self.run_root / "home"
        self.scope.mkdir(); self.home.mkdir(mode=0o700); (self.home / "tmp").mkdir()
    def tearDown(self):
        self.run_tmp.cleanup()
    def start(self, mode="success", **kwargs):
        (self.scope / "mode").write_text(mode)
        env = dict(os.environ, MO_ANALYZE_PATH="/must-not-inherit", MOLE_SOMETHING="ignored")
        return subprocess.Popen([str(self.supervisor), str(self.analyzer), str(self.scope), str(self.home)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, **kwargs)
    def finish(self, proc, expected):
        # Keep stdin open while waiting: EOF intentionally cancels the supervisor.
        proc.wait(timeout=7)
        out, err = proc.communicate()
        self.assertEqual(proc.returncode, expected, err)
        if expected: self.assertEqual(out, b"")
        return out, err
    def test_success_and_environment(self):
        out, _ = self.finish(self.start(), 0)
        self.assertEqual(json.loads(out)["path"], str(self.scope))
    def test_nonzero_exit(self): self.finish(self.start("exit"), 73)
    def test_stdout_bound(self): self.finish(self.start("floodout"), 71)
    def test_stderr_bound(self): self.finish(self.start("flooderr"), 71)
    def test_wall_bound(self): self.finish(self.start("sleep"), 72)
    def test_cpu_bound(self): self.finish(self.start("cpu"), 73)
    def test_cancel_input(self):
        p=self.start("sleep"); p.stdin.write(b"C"); p.stdin.flush(); self.finish(p,74)
    def test_app_disconnect(self):
        p=self.start("sleep"); p.stdin.close(); p.stdin=None; self.finish(p,74)
    def test_signal_cancel(self):
        p=self.start("sleep"); time.sleep(.1); p.terminate(); self.finish(p,74)
    def test_owned_descendant_stopped_unrelated_untouched(self):
        unrelated=subprocess.Popen(["/bin/sleep","10"])
        try:
            p=self.start("descendant")
            pid_file=self.scope / "child-pid"
            deadline=time.monotonic()+2
            while not pid_file.exists() and time.monotonic()<deadline: time.sleep(.01)
            self.assertTrue(pid_file.exists())
            child=int(pid_file.read_text())
            p.stdin.write(b"C"); p.stdin.flush(); self.finish(p,74)
            # On Linux a reparented zombie can remain until container init reaps it;
            # it is stopped, and on macOS launchd normally reaps it immediately.
            deadline=time.monotonic()+2
            while time.monotonic()<deadline:
                observed=subprocess.run(["ps","-o","stat=","-p",str(child)],capture_output=True,text=True).stdout.strip()
                if not observed or observed.startswith("Z"): break
                time.sleep(.02)
            self.assertTrue(not observed or observed.startswith("Z"), observed)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate(); unrelated.wait(timeout=2)
    def test_inherited_descriptors_do_not_reach_analyzer(self):
        with (self.run_root / "unrelated-fd").open("wb") as marker:
            self.finish(self.start(pass_fds=(marker.fileno(),)),0)
    def test_inherited_stdin_writer_cannot_delay_disconnect(self):
        read_fd, write_fd = os.pipe()
        try:
            (self.scope / "mode").write_text("sleep")
            p=subprocess.Popen([str(self.supervisor),str(self.analyzer),str(self.scope),str(self.home)],
                stdin=read_fd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(write_fd,))
            os.close(read_fd); read_fd=-1
            os.close(write_fd); write_fd=-1
            p.wait(timeout=1)
            out,err=p.communicate()
            self.assertEqual(p.returncode,74,err)
            self.assertEqual(out,b"")
        finally:
            if read_fd>=0: os.close(read_fd)
            if write_fd>=0: os.close(write_fd)
    def test_inherited_ignored_sigchld(self):
        def ignore(): signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        self.finish(self.start(preexec_fn=ignore), 0)
    def test_output_backpressure_is_bounded(self):
        p=self.start("flush")
        p.wait(timeout=5)
        out, _ = p.communicate()
        self.assertEqual(p.returncode,72)
        self.assertLess(len(out),256*1024)
    def test_cancel_during_output_backpressure(self):
        p=self.start("flush"); time.sleep(.2)
        p.stdin.write(b"C"); p.stdin.flush()
        p.wait(timeout=2)
        out, _ = p.communicate()
        self.assertEqual(p.returncode,74)
        self.assertLess(len(out),256*1024)
    def test_successful_and_failed_leaders_leave_no_running_helper(self):
        for mode, expected in (("orphan-success",0),("orphan-failure",73)):
            p=self.start(mode); self.finish(p,expected)
            child=int((self.scope / "child-pid").read_text())
            deadline=time.monotonic()+2
            while time.monotonic()<deadline:
                state=subprocess.run(["ps","-o","stat=","-p",str(child)],capture_output=True,text=True).stdout.strip()
                if not state or state.startswith("Z"): break
                time.sleep(.02)
            self.assertTrue(not state or state.startswith("Z"),state)
    def test_reject_nonprivate_home(self):
        self.home.chmod(0o755); self.finish(self.start(),64)

if __name__ == "__main__": unittest.main()
