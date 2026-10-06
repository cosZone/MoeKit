#!/usr/bin/env python3
"""Portable boundary tests; these do not claim native Sparkle execution."""
import importlib.util
import json
import time
from pathlib import Path
import sys
import os
import shutil
import subprocess
import tempfile
import re
import unittest
from unittest import mock
from types import SimpleNamespace
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

    def test_native_alias_preflight_preserves_pinned_identity_arguments(self):
        root = SimpleNamespace(path=Path("/private/var/folders/owned/moekit-sparkle-fixture"), marker="c" * 32,
                               identity=SimpleNamespace(st_dev=7, st_ino=19), verify=mock.Mock())
        identifier = "org.moekit.CIFixture.r" + root.marker + ".valid"
        success = json.dumps({"idle": True, "bundle_id": identifier})
        refusal = SimpleNamespace(returncode=2, stdout=b"", stderr=b"Fixture lifetime probe unknown: root identity\n")
        with mock.patch.object(Path, "is_dir", return_value=True), mock.patch.object(fixture.os.path, "samefile", return_value=True), \
             mock.patch.object(fixture, "run", return_value=success) as native, \
             mock.patch.object(fixture.subprocess, "run", return_value=refusal) as mismatch:
            result = fixture.preflight_probe(root, "/not-executed")
        self.assertTrue(result["physical_and_system_alias"])
        self.assertEqual(str(native.call_args_list[0].args[0][1]), str(root.path))
        self.assertEqual(str(native.call_args_list[1].args[0][1]), "/var/folders/owned/moekit-sparkle-fixture")
        for call in native.call_args_list:
            self.assertEqual(call.args[0][4:6], ["7", "19"])
        self.assertEqual(mismatch.call_args.args[0][4:6], ["7", "20"])

    def test_alias_preflight_rejects_wrong_namespace_before_native_probe(self):
        root = SimpleNamespace(path=Path("/private/var/folders/owned/moekit-sparkle-fixture"), marker="c" * 32,
                               identity=SimpleNamespace(st_dev=7, st_ino=19), verify=mock.Mock())
        with mock.patch.object(Path, "is_dir", return_value=True), mock.patch.object(fixture.os.path, "samefile", return_value=False), \
             mock.patch.object(fixture, "run") as native:
            with self.assertRaisesRegex(RuntimeError, "System alias"): fixture.preflight_probe(root, "/not-executed")
            native.assert_not_called()

    def test_native_probe_uses_physical_identity_not_foundation_spelling(self):
        source = (Path(__file__).parent / "probe.m").read_text()
        self.assertNotIn("stringByResolvingSymlinksInPath", source)
        self.assertIn("realpath(path.fileSystemRepresentation", source)
        self.assertIn("before.st_dev != expectedDevice", source)
        self.assertIn("before.st_ino != expectedInode", source)
        self.assertIn("fstat(rootFD, &pinned)", source)
        self.assertIn("[physicalApp isEqualToString:expectedApp]", source)
        self.assertNotIn("[application.bundleURL.path hasPrefix:prefix]", source)

    def test_native_probe_uses_shared_policy_and_final_live_roles(self):
        source = (Path(__file__).parent / "probe.m").read_text()
        self.assertIn('#import "probe_policy.h"', source)
        self.assertIn("FixtureNormalUser(getuid(), geteuid())", source)
        self.assertIn("proc_listpids(PROC_UID_ONLY, geteuid()", source)
        self.assertNotIn("proc_listpids(PROC_UID_ONLY, getuid()", source)
        self.assertIn("FixtureClassify(first, second", source)
        self.assertIn("FixtureRecheck(expected, first, second", source)
        self.assertIn("finalValue ? &classified : NULL", source)
        self.assertIn("lastPass[identityKey(expected)]", source)
        self.assertIn("if (pass == 2 && !previousPass[key])", source)
        self.assertIn("return entry ?: (secondLookup", source)
        self.assertIn("URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask", source)
        self.assertIn("appropriateForURL:nil create:NO", source)
        self.assertNotIn("NSHomeDirectory()", source)
        self.assertIn("namedScope == FixtureScopeOutside && aliasScope == FixtureScopeOutside", source)

    def test_shared_native_process_policy_compiles_and_runs_injected_cases(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "Portable native policy tests require the platform C compiler")
        with tempfile.TemporaryDirectory(prefix="moekit-probe-policy-") as directory:
            binary = Path(directory) / "probe-policy-tests"
            build = subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
                                    str(Path(__file__).parent / "test_probe_policy.c"), "-o", str(binary)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("passed", result.stdout.lower())
            print(result.stdout.strip())

    def test_probe_json_ignores_separate_stderr_warning(self):
        command = [sys.executable, "-c", 'import sys; print(\'{"idle":true}\'); print("framework warning", file=sys.stderr)']
        self.assertEqual(json.loads(fixture.run(command, separate_stderr=True)), {"idle": True})

    def test_probe_stderr_refusal_remains_visible(self):
        command = [sys.executable, "-c", 'import sys; print("owned identity unknown", file=sys.stderr); sys.exit(2)']
        with self.assertRaisesRegex(RuntimeError, "owned identity unknown"):
            fixture.run(command, separate_stderr=True)

    def test_probe_stderr_transient_never_returns_idle(self):
        command = [sys.executable, "-c", 'import sys; print(\'{"idle":true}\'); print("changing", file=sys.stderr); sys.exit(3)']
        self.assertIsNone(fixture.run(command, transient_exit=3, separate_stderr=True))

    def test_probe_both_output_streams_have_one_combined_budget(self):
        result = SimpleNamespace(returncode=0, stdout=b"x" * 1_000_001, stderr=b"y" * 1_000_000)
        with mock.patch.object(fixture.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "budget"):
                fixture.run(["not-executed"], separate_stderr=True)

    def test_mixed_caller_uid_refuses_before_creating_fixture_output(self):
        with mock.patch.object(fixture.platform, "system", return_value="Darwin"), \
             mock.patch.object(fixture.os, "getuid", return_value=0), \
             mock.patch.object(fixture.os, "geteuid", return_value=501), \
             mock.patch.dict(fixture.os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}), \
             mock.patch.object(fixture, "OwnedRoot") as owned, mock.patch.object(fixture, "run") as command:
            with self.assertRaisesRegex(RuntimeError, "equal real/effective"):
                fixture.main()
            owned.assert_not_called()
            command.assert_not_called()

    def test_alias_preflight_requires_exact_private_var_relationship(self):
        root = SimpleNamespace(path=Path("/private/elsewhere/moekit-sparkle-fixture"), marker="c" * 32,
                               identity=SimpleNamespace(st_dev=7, st_ino=19), verify=mock.Mock())
        with mock.patch.object(fixture, "run") as native:
            with self.assertRaisesRegex(RuntimeError, "under /private/var"):
                fixture.preflight_probe(root, "/not-executed")
            native.assert_not_called()

    @staticmethod
    def json_contract_payload():
        return {"cases": [{key: flag for key in fixture.JSON_BOOLEAN_FIELDS} for flag in (False, True)],
                "numeric_controls": {"zero": 0, "one": 1}}

    def test_json_contract_accepts_actual_booleans_and_integer_controls(self):
        result = fixture.validate_json_contract(json.dumps(self.json_contract_payload()))
        self.assertEqual(result, {"passed": True, "boolean_fields": 10, "truth_values": 2, "numeric_controls": 2})

    def test_json_contract_rejects_numeric_string_null_or_container_booleans(self):
        for key in fixture.JSON_BOOLEAN_FIELDS:
            for bad in (0, 1, "true", "false", None, [], {}):
                with self.subTest(key=key, value=bad):
                    value = self.json_contract_payload()
                    value["cases"][1][key] = bad
                    with self.assertRaisesRegex(RuntimeError, "actual false/true types"):
                        fixture.validate_json_contract(json.dumps(value))

    def test_json_contract_rejects_inverted_truth_values(self):
        value = self.json_contract_payload()
        value["cases"].reverse()
        with self.assertRaisesRegex(RuntimeError, "actual false/true types"):
            fixture.validate_json_contract(json.dumps(value))

    def test_json_contract_rejects_missing_or_extra_boolean_fields(self):
        for extra in (False, True):
            value = self.json_contract_payload()
            if extra: value["cases"][0]["extra"] = False
            else: value["cases"][0].pop("idle")
            with self.assertRaisesRegex(RuntimeError, "fields differ"):
                fixture.validate_json_contract(json.dumps(value))

    def test_json_contract_does_not_coerce_numeric_controls_to_booleans(self):
        value = self.json_contract_payload()
        value["numeric_controls"] = {"zero": False, "one": True}
        with self.assertRaisesRegex(RuntimeError, "remain integers"):
            fixture.validate_json_contract(json.dumps(value))

    def test_json_contract_output_budget(self):
        with self.assertRaisesRegex(RuntimeError, "output exceeded budget"):
            fixture.validate_json_contract("x" * 16_385)

    def test_every_native_semantic_boolean_uses_the_shared_explicit_factory(self):
        directory = Path(__file__).parent
        helper = (directory / "fixture_json.h").read_text()
        self.assertIn("return [NSNumber numberWithBool:value]", helper)
        observed = set()
        for name in ("main.m", "probe.m", "test_json_contract.m"):
            source = (directory / name).read_text()
            self.assertIn('#import "fixture_json.h"', source)
            for key in fixture.JSON_BOOLEAN_FIELDS:
                for match in re.finditer(r'@"' + re.escape(key) + r'"\s*:\s*', source):
                    self.assertTrue(source[match.end():].startswith("FixtureJSONBoolean("), (name, key))
                    if name != "test_json_contract.m": observed.add(key)
        self.assertEqual(observed, fixture.JSON_BOOLEAN_FIELDS)
        native = (directory / "test_json_contract.m").read_text()
        self.assertIn("CFBooleanGetTypeID()", native)
        self.assertIn("NSJSONSerialization dataWithJSONObject", native)
        self.assertIn("booleanFields(NO), booleanFields(YES)", native)

    def test_native_json_contract_preserves_payload_before_validation_failure(self):
        value = self.json_contract_payload()
        value["cases"][1]["idle"] = 1
        raw = json.dumps(value)
        with tempfile.TemporaryDirectory(prefix="moekit-json-contract-") as directory:
            output = Path(directory)
            owned = SimpleNamespace(path=output, verify=mock.Mock())
            with mock.patch.object(fixture, "run", side_effect=("", raw)) as commands:
                with self.assertRaisesRegex(RuntimeError, "actual false/true types"):
                    fixture.native_json_contract(owned, output)
            self.assertEqual((output / "native-json-contract.json").read_text(), raw)
            self.assertIn("-framework", commands.call_args_list[0].args[0])
            self.assertTrue(commands.call_args_list[1].kwargs["separate_stderr"])

    def test_preflight_preserves_numeric_or_false_idle_snapshot_before_refusal(self):
        root = SimpleNamespace(path=Path("/private/var/folders/owned/moekit-sparkle-fixture"), marker="c" * 32,
                               identity=SimpleNamespace(st_dev=7, st_ino=19), verify=mock.Mock())
        identifier = "org.moekit.CIFixture.r" + root.marker + ".valid"
        for idle, reason in ((1, "JSON boolean"), (0, "JSON boolean"), (False, "empty owned fixture")):
            with self.subTest(idle=idle), tempfile.TemporaryDirectory(prefix="moekit-preflight-json-") as directory:
                output = Path(directory)
                raw = json.dumps({"idle": idle, "bundle_id": identifier, "app_count": 0,
                                  "owned_processes": [], "services": {"-spki": "absent", "-spks": "absent", "-spkp": "absent"}})
                with mock.patch.object(Path, "is_dir", return_value=True), mock.patch.object(fixture.os.path, "samefile", return_value=True), \
                     mock.patch.object(fixture, "run", return_value=raw), mock.patch.object(fixture.subprocess, "run") as mismatch:
                    with self.assertRaisesRegex(RuntimeError, reason):
                        fixture.preflight_probe(root, "/not-executed", output)
                    mismatch.assert_not_called()
                self.assertEqual((output / "probe-preflight-physical.json").read_text(), raw)
                self.assertFalse((output / "probe-preflight-system-alias.json").exists())

    def test_preflight_snapshot_budget_refuses_before_persisting_oversized_payload(self):
        root = SimpleNamespace(path=Path("/private/var/folders/owned/moekit-sparkle-fixture"), marker="c" * 32,
                               identity=SimpleNamespace(st_dev=7, st_ino=19), verify=mock.Mock())
        with tempfile.TemporaryDirectory(prefix="moekit-preflight-budget-") as directory:
            output = Path(directory)
            with mock.patch.object(Path, "is_dir", return_value=True), mock.patch.object(fixture.os.path, "samefile", return_value=True), \
                 mock.patch.object(fixture, "run", return_value="x" * 16_385):
                with self.assertRaisesRegex(RuntimeError, "snapshot exceeded budget"):
                    fixture.preflight_probe(root, "/not-executed", output)
            self.assertEqual(list(output.iterdir()), [])

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
        for name in ('@"-spki"', '@"-spks"', '@"-spkp"', "BOOTSTRAP_UNKNOWN_SERVICE", "pbi_start_tvsec", "pbi_start_tvusec", "FixtureRecheck"):
            self.assertIn(name, source)
        self.assertNotIn("kill(", source)
        self.assertNotIn("terminate]", source)

    def test_non_hosted_entrypoint_refuses_before_creating_output(self):
        if sys.platform == "darwin" and fixture.os.environ.get("GITHUB_ACTIONS") == "true":
            self.skipTest("Native CI entrypoint is tested by the workflow")
        with self.assertRaisesRegex(RuntimeError, "GitHub-hosted"):
            fixture.main()

if __name__ == "__main__": unittest.main()
