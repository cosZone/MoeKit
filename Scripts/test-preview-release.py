#!/usr/bin/env python3
"""Portable security regression tests; no macOS, credentials, or network required."""
import ast
import importlib.util
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("preview_release", Path(__file__).with_name("preview-release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def valid_environment():
    return {"PREVIEW_VERSION": "0.1.0-preview.1", "EXPECTED_SOURCE_SHA": "a" * 40,
            "GITHUB_SHA": "a" * 40, "WORKFLOW_SOURCE_SHA": "a" * 40,
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REPOSITORY": "cosZone/MoeKit",
            "DEFAULT_BRANCH": "main", "GITHUB_REF": "refs/heads/main",
            "GITHUB_RUN_ID": "101", "GITHUB_RUN_NUMBER": "1", "GITHUB_RUN_ATTEMPT": "1"}


def valid_plist():
    return {"CFBundleIdentifier": release.BUNDLE_ID, "CFBundleExecutable": "MoeKit",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0", "MoeKitSourceCommit": "a" * 40,
            "MoeKitPreviewVersion": "0.1.0-preview.1", "MoeKitBuildRunID": "101",
            "MoeKitBuildRunAttempt": "1"}


class Inputs(unittest.TestCase):
    def test_expected_default_branch_dispatch(self):
        self.assertEqual(release.validate_inputs(valid_environment())["marketing_version"], "0.1.0")

    def test_rejects_shell_and_version_ambiguities(self):
        for version in ("0.1.0;whoami", "$(whoami)", "0.1.0-preview.1\n", "v0.1.0-preview.1",
                        "01.1.0-preview.1", "0.1.0", "0.1.0-rc.1", "../0.1.0-preview.1", "0.1.0-preview.01"):
            with self.subTest(version=version), self.assertRaises(release.ReleaseError):
                release.validate_inputs(valid_environment() | {"PREVIEW_VERSION": version})

    def test_rejects_untrusted_or_moving_sources(self):
        for key, value in (("EXPECTED_SOURCE_SHA", "main"), ("EXPECTED_SOURCE_SHA", "A" * 40),
                           ("GITHUB_SHA", "b" * 40), ("WORKFLOW_SOURCE_SHA", "b" * 40),
                           ("GITHUB_REPOSITORY", "attacker/MoeKit"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_REF", "refs/heads/feature"),
                           ("GITHUB_REF", "refs/tags/v0.1.0-preview.1"), ("DEFAULT_BRANCH", ""),
                           ("GITHUB_RUN_NUMBER", "1\nBAD=1")):
            with self.subTest(key=key, value=value), self.assertRaises(release.ReleaseError):
                release.validate_inputs(valid_environment() | {key: value})


class Artifacts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.context = release.validate_inputs(valid_environment())

    def tearDown(self):
        self.temp.cleanup()

    def test_checksums_cover_only_expected_files(self):
        (self.directory / "app.zip").write_bytes(b"example")
        (self.directory / "BUILD_INFO.json").write_text("{}")
        names = ("app.zip", "BUILD_INFO.json")
        release.write_checksums(self.directory, names)
        release.check_files(self.directory, names)
        (self.directory / "certificate.p12").write_bytes(b"not a real secret")
        with self.assertRaises(release.ReleaseError):
            release.check_files(self.directory, names)

    def test_checksum_detects_tamper(self):
        (self.directory / "app.zip").write_bytes(b"before")
        release.write_checksums(self.directory, ("app.zip",))
        (self.directory / "app.zip").write_bytes(b"after")
        with self.assertRaises(release.ReleaseError):
            release.check_files(self.directory, ("app.zip",))

    def zip(self, extra=None, info=None):
        path = self.directory / "app.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("MoeKit.app/Contents/Info.plist", plistlib.dumps(info or valid_plist()))
            if extra:
                archive.writestr(*extra)
        return path

    def test_valid_zip_provenance(self):
        release.inspect_zip(self.zip(), self.context)

    def test_rejects_zip_traversal_or_wrong_roots(self):
        for path in ("MoeKit.app/../../bad", "/MoeKit.app/abs", "certificate.p12", "MoeKit.app\\bad"):
            with self.subTest(path=path), self.assertRaises(release.ReleaseError):
                release.inspect_zip(self.zip((path, b"bad")), self.context)

    def test_rejects_zip_symlink(self):
        info = zipfile.ZipInfo("MoeKit.app/Contents/link")
        info.create_system = 3
        info.external_attr = 0o120777 << 16
        with self.assertRaises(release.ReleaseError):
            release.inspect_zip(self.zip((info, b"/tmp")), self.context)

    def test_rejects_wrong_app_provenance(self):
        for key, value in (("CFBundleIdentifier", "com.attacker.App"), ("MoeKitSourceCommit", "b" * 40),
                           ("MoeKitBuildRunID", "102"), ("MoeKitBuildRunAttempt", "2"),
                           ("CFBundleVersion", "2"), ("MoeKitPreviewVersion", "0.1.0-preview.2")):
            with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                release.inspect_zip(self.zip(info=valid_plist() | {key: value}), self.context)

    def test_signed_metadata_is_required(self):
        info = release.metadata(self.context)
        with self.assertRaises(release.ReleaseError):
            release.check_metadata(info, self.context, signed=True)
        info.update(signing="Apple Development", signature_verified=True, expected_team_verified=True, entitlements={})
        release.check_metadata(info, self.context, signed=True)
        info["source_sha"] = "b" * 40
        with self.assertRaises(release.ReleaseError):
            release.check_metadata(info, self.context, signed=True)


class TagSafety(unittest.TestCase):
    class API:
        def __init__(self, responses):
            self.responses = iter(responses)
            self.methods = []
        def request(self, method, path, **kwargs):
            self.methods.append(method)
            return next(self.responses)

    def test_missing_tag(self):
        api = self.API([None])
        self.assertIsNone(release.tag_commit(api, "v0.1.0-preview.1"))
        self.assertEqual(api.methods, ["GET"])

    def test_lightweight_and_annotated_tags(self):
        commit = {"type": "commit", "sha": "a" * 40}
        self.assertEqual(release.tag_commit(self.API([{"object": commit}]), "v0.1.0-preview.1"), "a" * 40)
        api = self.API([{"object": {"type": "tag", "sha": "b" * 40}}, {"object": commit}])
        self.assertEqual(release.tag_commit(api, "v0.1.0-preview.1"), "a" * 40)
        self.assertEqual(api.methods, ["GET", "GET"])

    def test_noncommit_tag_fails(self):
        with self.assertRaises(release.ReleaseError):
            release.tag_commit(self.API([{"object": {"type": "tree", "sha": "a" * 40}}]), "v0.1.0-preview.1")

    def test_redirect_never_forwards_token(self):
        with self.assertRaises(release.ReleaseError):
            release.NoRedirect().redirect_request(None, None, 302, "", {}, "https://attacker.test/")


class Publication(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_cwd = Path.cwd()
        os.chdir(self.temp.name)
        directory = Path("Preview")
        directory.mkdir()
        self.context = release.validate_inputs(valid_environment())
        self.zip_name = "MoeKit-v0.1.0-preview.1-macOS-universal.zip"
        with zipfile.ZipFile(directory / self.zip_name, "w") as archive:
            archive.writestr("MoeKit.app/Contents/Info.plist", plistlib.dumps(valid_plist()))
        info = release.metadata(self.context)
        info.update(signing="Apple Development", signature_verified=True, expected_team_verified=True, entitlements={})
        release.write_json(directory / "BUILD_INFO.json", info)
        release.write_checksums(directory, (self.zip_name, "BUILD_INFO.json"))

    def tearDown(self):
        os.chdir(self.old_cwd)
        self.temp.cleanup()

    def test_existing_release_is_not_mutated(self):
        api = TagSafety.API([{"id": 22}])
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub", return_value=api):
            with self.assertRaises(release.ReleaseError):
                release.publish()
        self.assertEqual(api.methods, ["GET"])

    def test_mismatched_tag_is_not_moved(self):
        api = TagSafety.API([None, [], {"object": {"type": "commit", "sha": "b" * 40}}])
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub", return_value=api):
            with self.assertRaises(release.ReleaseError):
                release.publish()
        self.assertEqual(api.methods, ["GET", "GET", "GET"])

    def test_existing_draft_is_not_mutated(self):
        api = TagSafety.API([None, [{"tag_name": "v0.1.0-preview.1", "draft": True}]])
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub", return_value=api):
            with self.assertRaises(release.ReleaseError):
                release.publish()
        self.assertEqual(api.methods, ["GET", "GET"])

    def test_release_search_paginates_drafts(self):
        api = TagSafety.API([None, [{"tag_name": "other"}] * 100, [{"tag_name": "v0.1.0-preview.1", "draft": True}]])
        self.assertTrue(release.existing_release(api, "v0.1.0-preview.1")["draft"])
        self.assertEqual(api.methods, ["GET", "GET", "GET"])

    def fake_publisher(self, *, digest_ok=True):
        outer = self
        class API:
            def __init__(self):
                self.calls = []
                self.tag_exists = False
                self.assets = []
            def request(self, method, path, body=None, *, upload=None, **kwargs):
                self.calls.append((method, path, body))
                if "/releases/tags/" in path:
                    return None
                if "/releases?" in path:
                    return []
                if "/git/ref/tags/" in path:
                    return {"object": {"type": "commit", "sha": "a" * 40}} if self.tag_exists else None
                if path.endswith("/git/refs"):
                    outer.assertEqual(body, {"ref": "refs/tags/v0.1.0-preview.1", "sha": "a" * 40})
                    self.tag_exists = True
                    return {"ref": body["ref"]}
                if method == "POST" and path.endswith("/releases"):
                    outer.assertTrue(body["draft"])
                    outer.assertTrue(body["prerelease"])
                    return {"id": 55}
                if upload:
                    item = {"name": upload.name, "size": upload.stat().st_size,
                            "digest": "sha256:" + (release.sha256(upload) if digest_ok else "0" * 64)}
                    self.assets.append(item)
                    return item
                if method == "GET" and "/assets?" in path:
                    return self.assets
                if method == "PATCH":
                    return {"draft": False, "prerelease": True, "tag_name": "v0.1.0-preview.1"}
                raise AssertionError("Unexpected API path")
        return API()

    def test_new_prerelease_publishes_only_after_verified_uploads(self):
        api = self.fake_publisher()
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub", return_value=api):
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}), redirect_stdout(io.StringIO()):
                release.publish()
        self.assertEqual(len(api.assets), 3)
        self.assertEqual(api.calls[-1][0], "PATCH")
        self.assertFalse(api.calls[-1][2]["draft"])
        self.assertFalse(any(method == "DELETE" for method, _, _ in api.calls))

    def test_bad_upload_digest_never_publishes_draft(self):
        api = self.fake_publisher(digest_ok=False)
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub", return_value=api):
            with self.assertRaises(release.ReleaseError):
                release.publish()
        self.assertFalse(any(method in {"PATCH", "DELETE"} for method, _, _ in api.calls))


class SafeCommandDiagnostics(unittest.TestCase):
    """Synthetic values only: failed commands must never disclose their data."""

    def test_failure_shows_only_operation_and_integer_exit(self):
        marker = "synthetic-private-data-DO-NOT-LOG"
        result = subprocess.CompletedProcess([marker], 51, stdout=marker.encode(), stderr=marker.encode())
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError) as caught:
                release.run("/private/" + marker, marker, operation="p12-import")
        self.assertEqual(str(caught.exception), "Operation p12-import failed (exit code 51); command details withheld.")
        self.assertNotIn(marker, str(caught.exception))

    def test_timeout_hides_command_and_captured_streams(self):
        marker = "synthetic-timeout-private-data"
        error = subprocess.TimeoutExpired([marker], 120, output=marker.encode(), stderr=marker.encode())
        with patch.object(release.subprocess, "run", side_effect=error):
            with self.assertRaises(release.ReleaseError) as caught:
                release.run(marker, operation="keychain-unlock")
        self.assertEqual(str(caught.exception), "Operation keychain-unlock timed out after 120 seconds; command details withheld.")
        self.assertNotIn(marker, str(caught.exception))
        self.assertTrue(caught.exception.__suppress_context__)

    def test_oserror_hides_exception_text_and_paths(self):
        marker = "synthetic-oserror-private-data"
        with patch.object(release.subprocess, "run", side_effect=OSError(13, marker, "/" + marker)):
            with self.assertRaises(release.ReleaseError) as caught:
                release.run(marker, operation="keychain-create")
        self.assertEqual(str(caught.exception), "Operation keychain-create could not start (OS error 13); command details withheld.")
        self.assertNotIn(marker, str(caught.exception))
        self.assertTrue(caught.exception.__suppress_context__)

    def test_unrecognized_label_is_rejected_without_echoing_it(self):
        marker = "synthetic-label-private-data\n::error::injection"
        with patch.object(release.subprocess, "run") as child:
            with self.assertRaises(release.ReleaseError) as caught:
                release.run("ignored", operation=marker)
        child.assert_not_called()
        self.assertEqual(str(caught.exception), "Unrecognized local operation label.")
        self.assertNotIn(marker, str(caught.exception))

    def test_shared_capture_strips_secrets_and_does_not_print_streams(self):
        marker = "synthetic-captured-private-data"
        hidden_keys = (*release.SECRET_NAMES, "GH_TOKEN", "GITHUB_TOKEN")
        fake_environment = {key: marker for key in hidden_keys} | {"PATH": "/usr/bin"}
        result = subprocess.CompletedProcess([], 0, stdout=marker.encode(), stderr=marker.encode())
        output, errors = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, fake_environment, clear=True), patch.object(release.subprocess, "run", return_value=result) as child:
            with redirect_stdout(output), redirect_stderr(errors):
                captured = release.captured_run("/usr/bin/codesign", "--display", "safe-app-path", operation="codesign-display")
        self.assertIs(captured, result)
        self.assertEqual(child.call_args.args[0], ("/usr/bin/codesign", "--display", "safe-app-path"))
        self.assertEqual(child.call_args.kwargs["env"], {"PATH": "/usr/bin"})
        self.assertEqual(child.call_args.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(child.call_args.kwargs["stderr"], subprocess.PIPE)
        self.assertEqual(child.call_args.kwargs["timeout"], 120)
        self.assertFalse(child.call_args.kwargs["check"])
        self.assertEqual(output.getvalue() + errors.getvalue(), "")

    def test_cli_failure_prints_only_sanitized_message(self):
        marker = "synthetic-cli-private-data"
        result = subprocess.CompletedProcess([marker], 9, stdout=marker.encode(), stderr=marker.encode())
        output, errors = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, valid_environment(), clear=True), patch.object(release.sys, "argv", ["preview-release.py", "validate"]):
            with patch.object(release.subprocess, "run", return_value=result), redirect_stdout(output), redirect_stderr(errors):
                status = release.main()
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(), "::error::Operation source-read failed (exit code 9); command details withheld.\n")
        self.assertNotIn(marker, errors.getvalue())

    def test_command_callsites_have_static_allowlisted_labels(self):
        tree = ast.parse(Path(release.__file__).read_text())
        labels = set()
        raw_calls = []
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name):
                if node.func.value.id == "subprocess" and node.func.attr == "run":
                    raw_calls.append(node)
            if not isinstance(node.func, ast.Name) or node.func.id not in {"run", "text_run", "captured_run"}:
                continue
            # The two wrappers forward the already-validated operation value.
            if node.args and isinstance(node.args[0], ast.Starred):
                continue
            operation = next((item.value for item in node.keywords if item.arg == "operation"), None)
            self.assertIsInstance(operation, ast.Constant)
            self.assertIn(operation.value, release.OPERATIONS)
            labels.add(operation.value)
        self.assertEqual(labels, release.OPERATIONS)
        self.assertEqual(len(raw_calls), 1, "All subprocesses must use the shared sanitized capture wrapper")
        wrapper = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "captured_run")
        self.assertIn(raw_calls[0], list(ast.walk(wrapper)))


if __name__ == "__main__":
    unittest.main()
