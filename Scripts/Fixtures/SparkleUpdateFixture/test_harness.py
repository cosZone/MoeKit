#!/usr/bin/env python3
"""Portable boundary tests; these do not claim native Sparkle execution."""
import importlib.util
import json
import time
from pathlib import Path
import sys
import unittest
from unittest import mock
import urllib.error
import urllib.request

SCRIPT = Path(__file__).resolve().parents[2] / "run-sparkle-fixture.py"
spec = importlib.util.spec_from_file_location("sparkle_fixture", SCRIPT)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class HarnessBoundaryTests(unittest.TestCase):
    def test_owner_marker_change_refuses(self):
        root = fixture.OwnedRoot()
        try:
            (root.path / "owner-marker").write_text("changed")
            with self.assertRaisesRegex(RuntimeError, "marker"):
                root.verify()
        finally:
            fixture.os.close(root.fd)

    def test_unknown_path_components_refused(self):
        root = fixture.OwnedRoot()
        try:
            for part in ("..", ".", "x/y", "/tmp", "x\\y"):
                with self.assertRaises(RuntimeError): root.directory(part)
        finally:
            fixture.os.close(root.fd)

    def test_create_never_overwrites_existing_file(self):
        root = fixture.OwnedRoot()
        try:
            path = root.path / "known"
            fixture.write_new(path, b"original")
            with self.assertRaises(FileExistsError): fixture.write_new(path, b"replacement")
            self.assertEqual(path.read_bytes(), b"original")
        finally:
            fixture.os.close(root.fd)

    def test_loopback_uses_exact_payload_map(self):
        server = fixture.FixtureServer()
        try:
            route = "/" + "a" * 32 + "/valid/appcast.xml"
            server.add(route, b"synthetic feed")
            self.assertEqual(urllib.request.urlopen(server.base + route).read(), b"synthetic feed")
            for path in ("/etc/passwd", route + "?path=/etc/passwd", "/../appcast.xml"):
                with self.assertRaises(urllib.error.HTTPError): urllib.request.urlopen(server.base + path)
            with self.assertRaises(RuntimeError): server.add("/../unowned", b"no")
        finally:
            server.close()

    def test_tree_proof_detects_payload_changes(self):
        root = fixture.OwnedRoot()
        try:
            folder = root.directory("tree")
            fixture.write_new(folder / "file", b"first")
            first = fixture.tree_digest(folder)
            (folder / "file").write_bytes(b"other")
            self.assertNotEqual(first, fixture.tree_digest(folder))
        finally:
            fixture.os.close(root.fd)

    def test_partial_event_tail_preserves_complete_records(self):
        root = fixture.OwnedRoot()
        try:
            path = root.path / "events.jsonl"
            fixture.write_new(path, b'{"event":"launch"}\n{"event":')
            self.assertEqual(fixture.read_events(path), [{"event": "launch"}])
        finally:
            fixture.os.close(root.fd)

    def test_event_replacement_refuses_even_if_regular_owned_file(self):
        root = fixture.OwnedRoot()
        try:
            case = root.directory("case")
            installed = root.directory("case", "Installed")
            events = case / "events.jsonl"
            fixture.write_new(events, b"")
            namespace = fixture.CaseNamespace(root, case, installed, events)
            events.rename(case / "retained-original-events")
            fixture.write_new(events, b'{"event":"spoofed"}\n')
            with self.assertRaisesRegex(RuntimeError, "namespace changed"): namespace.read()
        finally:
            fixture.os.close(root.fd)

    def test_event_symlink_refuses(self):
        root = fixture.OwnedRoot()
        try:
            fixture.write_new(root.path / "original", b'{}\n')
            (root.path / "events").symlink_to(root.path / "original")
            with self.assertRaises(OSError): fixture.read_events(root.path / "events")
        finally:
            fixture.os.close(root.fd)

    def test_collects_all_independent_failed_cases(self):
        evidence = {"cases": {}, "all_passed": False}
        names = list(fixture.CASES)
        visited = []
        def callback(name):
            visited.append(name)
            return {"passed": name not in ("tampered-archive", "cancel"), "settled": True}
        fixture.collect_cases(names, callback, evidence)
        self.assertEqual(visited, names)
        self.assertEqual(len(evidence["cases"]), 10)
        self.assertFalse(evidence["all_passed"])

    def test_collect_accepts_only_explicit_settled_outcomes(self):
        for result in ({}, {"passed": True}, {"passed": 1, "settled": True}, {"passed": False, "settled": False}):
            evidence = {"cases": {}}
            visited = []
            def callback(name):
                visited.append(name)
                return result
            with self.assertRaisesRegex(RuntimeError, "explicit settled"):
                fixture.collect_cases(("first", "second"), callback, evidence)
            self.assertEqual(visited, ["first"])
            self.assertTrue(evidence["cases"]["first"]["aborted"])

    def test_uncertain_lifetime_aborts_instead_of_continuing(self):
        evidence = {"cases": {}}
        visited = []
        def callback(name):
            visited.append(name)
            raise RuntimeError("owned app lifetime unknown")
        with self.assertRaisesRegex(RuntimeError, "lifetime unknown"):
            fixture.collect_cases(("first", "second"), callback, evidence)
        self.assertEqual(visited, ["first"])

    def test_all_explicit_passes_complete_collection(self):
        evidence = {"cases": {}}
        fixture.collect_cases(("one", "two"), lambda _: {"passed": True, "settled": True}, evidence)
        self.assertTrue(evidence["all_passed"])

    def test_cancel_route_really_serves_partial_bytes(self):
        server = fixture.FixtureServer()
        route = "/" + "b" * 32 + "/cancel/update.zip"
        data = b"fixture" * 200_000
        try:
            server.add(route, data)
            response = urllib.request.urlopen(server.base + route)
            self.assertEqual(response.read(16384), data[:16384])
            response.close()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                with server.lock:
                    if server.active_responses.get(route) == 0: break
                time.sleep(0.01)
            with server.lock:
                self.assertEqual(server.active_responses.get(route), 0)
                self.assertGreater(server.sent_bytes[route], 0)
                self.assertLess(server.sent_bytes[route], len(data))
                self.assertNotIn(route, server.completed_responses)
        finally:
            server.close()

    def test_lifetime_keeps_helper_id_after_path_disappears(self):
        root = fixture.OwnedRoot()
        try:
            identifier = "org.moekit.CIFixture.r" + root.marker + ".valid"
            lifetime = fixture.Lifetime(root, identifier, root.path / "not-executed-probe")
            process = {"pid": 77, "uid": fixture.os.geteuid(), "start_seconds": 100, "start_microseconds": 12, "role": "installer"}
            response = {"schema": 1, "bundle_id": identifier, "uid": fixture.os.geteuid(), "idle": False, "owned_processes": [process]}
            with mock.patch.object(fixture, "run", return_value=json.dumps(response)):
                lifetime.sample([])
            response.update(idle=True, owned_processes=[])
            with mock.patch.object(fixture, "run", return_value=json.dumps(response)) as probe:
                lifetime.sample([])
                tracked = json.loads(probe.call_args.args[0][-1])
                self.assertEqual(tracked, [process])
            self.assertEqual(len(lifetime.tracked), 1)
        finally:
            fixture.os.close(root.fd)

    def test_changing_lifetime_snapshot_never_counts_as_idle(self):
        root = fixture.OwnedRoot()
        try:
            lifetime = fixture.Lifetime(root, "org.moekit.CIFixture.r" + root.marker + ".valid", root.path / "not-executed")
            with mock.patch.object(fixture, "run", return_value=None):
                self.assertIsNone(lifetime.sample([]))
            self.assertEqual(lifetime.snapshots, 0)
            self.assertEqual(lifetime.changing_snapshots, 1)
        finally:
            fixture.os.close(root.fd)

    def test_lifetime_refuses_root_change_during_probe(self):
        root = fixture.OwnedRoot()
        try:
            identifier = "org.moekit.CIFixture.r" + root.marker + ".valid"
            lifetime = fixture.Lifetime(root, identifier, root.path / "not-executed-probe")
            def changed(_args, **_kwargs):
                (root.path / "owner-marker").write_text("changed")
                return json.dumps({"schema": 1, "bundle_id": identifier, "uid": fixture.os.geteuid(), "idle": True, "owned_processes": []})
            with mock.patch.object(fixture, "run", side_effect=changed):
                with self.assertRaisesRegex(RuntimeError, "marker"): lifetime.sample([])
        finally:
            fixture.os.close(root.fd)

    def test_native_source_uses_real_cancel_and_install_checkpoint(self):
        source = (Path(__file__).parent / "main.m").read_text()
        self.assertNotIn("SPUUserUpdateChoiceSkip", source)
        self.assertIn("userDidCancelDownload:(SPUUpdater *)updater", source)
        self.assertIn("self.expectedBytes > self.downloadedBytes", source)
        self.assertIn('event(@"installer_started"', source)
        self.assertNotIn('event(@"extraction_completed"', source)
        self.assertIn('"install-ack"', source)
        self.assertIn("self.installReply = reply", source)

    def test_native_probe_retains_exact_services_and_process_identity(self):
        source = (Path(__file__).parent / "probe.m").read_text()
        for name in ('@"-spki"', '@"-spks"', '@"-spkp"', "BOOTSTRAP_UNKNOWN_SERVICE", "pbi_start_tvsec", "pbi_start_tvusec", "sameProcess"):
            self.assertIn(name, source)
        self.assertNotIn("kill(", source)
        self.assertNotIn("terminate]", source)

    def test_non_hosted_entrypoint_refuses_before_creating_output(self):
        if sys.platform == "darwin" and fixture.os.environ.get("GITHUB_ACTIONS") == "true":
            self.skipTest("Native CI entrypoint is tested by the workflow")
        with self.assertRaisesRegex(RuntimeError, "GitHub-hosted"):
            fixture.main()

if __name__ == "__main__": unittest.main()
