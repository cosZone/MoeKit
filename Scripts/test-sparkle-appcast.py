#!/usr/bin/env python3
"""Portable, credential-free Sparkle tests with ephemeral local fixture keys.

No GitHub requests, production key access, or official macOS signer execution.
"""
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import sparkle_appcast as appcast


def digest_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


class FakeGitHub:
    def __init__(self, context, metadata, prior=None):
        self.context, self.metadata, self.prior = context, metadata, prior
        self.calls = []
        self.head = "b" * 40 if prior is not None else None
        self.old_head = self.head
        self.new_head = "c" * 40
        self.race = False
        self.draft = False
        self.extra_tree_file = False
        self.bad_asset = False

    def request(self, method, path, body=None, **kwargs):
        self.calls.append((method, path, body, kwargs))
        base = f"/repos/{appcast.REPOSITORY}"
        assert path.startswith(base)
        route = path[len(base):]
        if method == "GET" and route.startswith("/releases/tags/"):
            return {"id": 123, "draft": self.draft, "prerelease": "-preview." in self.context["version"],
                    "tag_name": "v" + self.context["version"]}
        if method == "GET" and route.startswith("/git/ref/tags/"):
            return {"object": {"type": "commit", "sha": self.context["source_sha"]}}
        if method == "GET" and route == "/releases/123/assets?per_page=100":
            assets = []
            for value in (self.metadata["archive"], self.metadata["feed"]):
                assets.append({"name": value["name"], "size": value["length"], "state": "uploaded",
                               "digest": "sha256:" + ("0" * 64 if self.bad_asset else value["sha256"]),
                               "browser_download_url": f"https://github.com/{appcast.REPOSITORY}/releases/download/v{self.context['version']}/{value['name']}"})
            return assets
        if method == "GET" and route == "/git/ref/heads/updates":
            if self.head is None:
                assert kwargs.get("allow_404") is True
                return None
            return {"ref": "refs/heads/updates", "object": {"type": "commit", "sha": self.head}}
        if method == "GET" and route == "/git/commits/" + self.old_head:
            return {"tree": {"sha": "d" * 40}}
        if method == "GET" and route == "/git/trees/" + "d" * 40 + "?recursive=1":
            tree = [{"path": "appcast.xml", "mode": "100644", "type": "blob", "sha": digest_blob(self.prior)}]
            if self.extra_tree_file:
                tree.append({"path": "unrelated.txt", "mode": "100644", "type": "blob", "sha": "e" * 40})
            return {"truncated": False, "tree": tree}
        if method == "GET" and route == "/git/blobs/" + digest_blob(self.prior):
            return {"encoding": "base64", "size": len(self.prior), "content": base64.b64encode(self.prior).decode("ascii") + "\n"}
        if method == "POST" and route == "/git/blobs":
            return {"sha": digest_blob(base64.b64decode(body["content"]))}
        if method == "POST" and route == "/git/trees":
            assert set(body) == {"tree"}
            assert len(body["tree"]) == 1 and body["tree"][0]["path"] == "appcast.xml"
            return {"sha": "f" * 40}
        if method == "POST" and route == "/git/commits":
            assert body["parents"] == ([self.old_head] if self.old_head else [])
            assert body["tree"] == "f" * 40
            return {"sha": self.new_head}
        if method == "PATCH" and route == "/git/refs/heads/updates":
            assert body == {"sha": self.new_head, "force": False}
            if self.race:
                raise appcast.SparkleError("Concurrent non-fast-forward update rejected.")
            self.head = self.new_head
            return {"object": {"sha": self.head}}
        if method == "POST" and route == "/git/refs":
            assert body == {"ref": "refs/heads/updates", "sha": self.new_head}
            if self.race:
                raise appcast.SparkleError("Concurrent branch creation rejected.")
            self.head = self.new_head
            return {"object": {"sha": self.head}}
        raise AssertionError((method, route))


class SparkleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="moekit-sparkle-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(mock.patch.stopall)
        mock.patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}, clear=False).start()
        self.openssl = appcast._openssl()
        self.key_path = self.root / "ephemeral-test-key.pem"
        appcast._run([self.openssl, "genpkey", "-algorithm", "ED25519", "-out", str(self.key_path)])
        public = appcast._run([self.openssl, "pkey", "-in", str(self.key_path), "-pubout", "-outform", "DER"])
        self.assertEqual(public[:12], bytes.fromhex("302a300506032b6570032100"))
        self.public_key = base64.b64encode(public[12:]).decode("ascii")
        private = appcast._run([self.openssl, "pkey", "-in", str(self.key_path), "-outform", "DER"])
        self.assertEqual(private[:16], bytes.fromhex("302e020100300506032b657004220420"))
        self.secret = base64.b64encode(private[-32:]).decode("ascii")
        mock.patch.dict(os.environ, {"SPARKLE_ED_PRIVATE_KEY": self.secret}, clear=False).start()
        self.config_path = self.root / "Sparkle.json"
        self.config = {"version": appcast.SPARKLE_VERSION, "revision": appcast.SPARKLE_REVISION,
                       "checksum": appcast.PACKAGE_SHA256, "feedURL": appcast.FEED_URL, "publicEDKey": self.public_key}
        self.write_config()
        mock.patch.object(appcast, "CONFIG_PATH", self.config_path).start()
        self.mock_signer = mock.patch.object(appcast, "_sign", side_effect=self.sign_fixture).start()
        self.context = self.context_for("0.1.0-preview.10")

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")

    def context_for(self, version):
        return {"version": version, "marketing_version": version.split("-preview.")[0],
                "build_number": appcast.build_number(version), "source_sha": "a" * 40,
                "run_id": "123", "run_number": "42", "run_attempt": "1"}

    def signature(self, data):
        path = self.root / "fixture-sign-input"
        path.write_bytes(data)
        signature = appcast._run([self.openssl, "pkeyutl", "-sign", "-rawin", "-in", str(path), "-inkey", str(self.key_path)])
        return base64.b64encode(signature).decode("ascii")

    def signed_feed(self, content):
        return content + ("<!-- sparkle-signatures:\nedSignature: " + self.signature(content) +
                          "\nlength: " + str(len(content)) + "\n-->\n").encode("ascii")

    def sign_fixture(self, path, secret, *, feed=False):
        self.assertEqual(secret, self.secret.encode("ascii"))
        content = Path(path).read_bytes()
        if feed:
            Path(path).write_bytes(self.signed_feed(content))
            return b""
        return (self.signature(content) + "\n").encode("ascii")

    def release(self, context=None, name="release"):
        context = context or self.context
        directory = self.root / name
        directory.mkdir()
        (directory / appcast._archive_name(context)).write_bytes(b"PK\x03\x04MoeKit test archive bytes\n")
        metadata = appcast.sign_release(directory, context, "Fixture release notes: <safe> & plain\nSecond line")
        (directory / "BUILD_INFO.json").write_text(json.dumps({"sparkle": metadata}), encoding="utf-8")
        return directory, metadata

    def replace_feed(self, directory, metadata, data):
        (directory / "appcast.xml").write_bytes(data)
        metadata["feed"].update(length=len(data), sha256=hashlib.sha256(data).hexdigest())

    def assert_no_writes(self, api):
        self.assertTrue(all(call[0] == "GET" for call in api.calls))

    def test_numeric_mapping_order_and_bounds(self):
        versions = ["0.0.0-preview.1", "0.1.0-preview.9", "0.1.0-preview.10", "0.1.0-preview.98",
                    "0.1.0", "0.1.1-preview.1", "0.2.0-preview.1", "1.0.0-preview.1", "98.99.99"]
        numbers = [tuple(map(int, appcast.build_number(value).split("."))) for value in versions]
        self.assertEqual(numbers, sorted(set(numbers)))
        self.assertEqual(appcast.build_number("0.1.0-preview.9"), "2.0.9")
        self.assertEqual(appcast.build_number("0.1.0-preview.10"), "2.0.10")
        self.assertEqual(appcast.build_number("0.1.0"), "2.0.99")
        self.assertEqual(appcast.build_number("98.99.99"), "9900.99.99")
        for version in ["99.0.0", "1.100.0", "1.0.100", "1.0.0-preview.0", "1.0.0-preview.99", "1.0.0-preview.255",
                        "1.0.0-preview.01", "1.0.0-beta.1", "1.0.0+build", "v1.0.0", "01.0.0", "1.0.0\n", None]:
            with self.subTest(version=version), self.assertRaises(appcast.SparkleError):
                appcast.build_number(version)

    def test_public_configuration_blank_and_pins(self):
        self.config["publicEDKey"] = ""
        self.write_config()
        self.assertEqual(appcast.load_config()["publicEDKey"], "")
        with self.assertRaises(appcast.SparkleError):
            appcast.load_config(require_key=True)
        self.config["publicEDKey"] = self.public_key
        for key, value in [("version", "latest"), ("checksum", "0" * 64), ("feedURL", "https://evil.invalid/appcast.xml")]:
            previous = self.config[key]
            self.config[key] = value
            self.write_config()
            with self.subTest(key=key), self.assertRaises(appcast.SparkleError):
                appcast.load_config()
            self.config[key] = previous
        self.config["extra"] = True
        self.write_config()
        with self.assertRaises(appcast.SparkleError):
            appcast.load_config()

    def test_official_public_signature_fixture(self):
        key = "rhHib+w769W2/6/t+oM1ZxgjBB93BfBKMLO0Qo1etQs="
        signature = "EIawm2YkDZ2gBfkEMF2+1VuuTeXnCGZOdnMdVgPPvDZioq7bvDayXqKkIIzSjKMmeFdcFJOHdnba5ZV60+gPBw=="
        appcast.verify_signature(b"Hello World!\n", signature, key)
        with self.assertRaises(appcast.SparkleError):
            appcast.verify_signature(b"Hello World!\r\n", signature, key)

    def test_sign_and_verify_plain_embedded_notes(self):
        directory, metadata = self.release()
        appcast.verify_release(directory, self.context, metadata)
        data = (directory / "appcast.xml").read_bytes()
        self.assertIn(b'sparkle:format="plain-text"', data)
        self.assertNotIn(b"releaseNotesLink", data)
        self.assertNotIn(self.secret.encode("ascii"), data)
        self.assertEqual(metadata["publicEDKey"], self.public_key)
        with mock.patch.dict(os.environ, {"SPARKLE_ED_PRIVATE_KEY": ""}, clear=False):
            appcast.verify_release(directory, self.context, metadata)

    def test_invalid_secrets_do_not_reach_signer(self):
        directory = self.root / "unsigned"
        directory.mkdir()
        for secret in ["", "wrong!!!!", self.secret + "\n", base64.b64encode(b"x" * 64).decode(), base64.b64encode(b"x" * 31).decode()]:
            with self.subTest(secret_length=len(secret)), mock.patch.dict(os.environ, {"SPARKLE_ED_PRIVATE_KEY": secret}), self.assertRaises(appcast.SparkleError) as error:
                appcast.sign_release(directory, self.context, "notes")
            if secret:
                self.assertNotIn(secret, str(error.exception))
        self.mock_signer.assert_not_called()
        self.assertEqual(appcast._base64(base64.b64encode(b"x" * 96).decode(), {32, 96}, "invalid"), b"x" * 96)

    def test_preview_channel_is_explicit_and_cannot_be_removed_or_relabelled(self):
        directory, original = self.release()
        data = (directory / "appcast.xml").read_bytes()
        content = data[:appcast.TRAILER.search(data).start()]
        channel = b"<sparkle:channel>preview</sparkle:channel>"
        self.assertEqual(content.count(channel), 1)
        for replacement in (b"", b"<sparkle:channel>stable</sparkle:channel>"):
            metadata = copy.deepcopy(original)
            self.replace_feed(directory, metadata, self.signed_feed(content.replace(channel, replacement)))
            with self.subTest(replacement=replacement), self.assertRaises(appcast.SparkleError):
                appcast.verify_release(directory, self.context, metadata)
        stable = self.context_for("0.1.0")
        stable_dir, metadata = self.release(stable, "stable")
        stable_data = (stable_dir / "appcast.xml").read_bytes()
        self.assertNotIn(b"<sparkle:channel>", stable_data)
        appcast.verify_release(stable_dir, stable, metadata)
        content = stable_data[:appcast.TRAILER.search(stable_data).start()]
        self.replace_feed(stable_dir, metadata, self.signed_feed(content.replace(b"<description", channel + b"<description")))
        with self.assertRaises(appcast.SparkleError):
            appcast.verify_release(stable_dir, stable, metadata)

    def test_tampered_archive_rejected_even_with_updated_metadata_hash(self):
        directory, metadata = self.release()
        path = directory / metadata["archive"]["name"]
        data = path.read_bytes() + b"tamper"
        path.write_bytes(data)
        metadata["archive"].update(length=len(data), sha256=hashlib.sha256(data).hexdigest())
        with self.assertRaises(appcast.SparkleError):
            appcast.verify_release(directory, self.context, metadata)

    def test_wrong_pinned_public_key_rejected(self):
        directory, metadata = self.release()
        self.config["publicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.write_config()
        metadata["publicEDKey"] = self.config["publicEDKey"]
        with self.assertRaises(appcast.SparkleError):
            appcast.verify_release(directory, self.context, metadata)

    def test_unsigned_tampered_extra_or_bad_length_feed_rejected(self):
        directory, original = self.release()
        data = (directory / "appcast.xml").read_bytes()
        content = data[:appcast.TRAILER.search(data).start()]
        candidates = [content, data.replace(b"Fixture", b"Tampered", 1), data + b"\n", data + data[data.index(b"<!-- sparkle-signatures:"):],
                      data.replace(b"\nlength: " + str(len(content)).encode(), b"\nlength: 1")]
        for data in candidates:
            metadata = copy.deepcopy(original)
            self.replace_feed(directory, metadata, data)
            with self.subTest(size=len(data)), self.assertRaises(appcast.SparkleError):
                appcast.verify_release(directory, self.context, metadata)

    def test_authentic_but_malicious_or_mismatched_feed_rejected(self):
        directory, original = self.release()
        data = (directory / "appcast.xml").read_bytes()
        content = data[:appcast.TRAILER.search(data).start()]
        candidates = [content.replace(b"https://github.com/cosZone/MoeKit/releases/download/", b"https://evil.invalid/releases/download/"),
                      content.replace(b"<sparkle:version>2.0.10</sparkle:version>", b"<sparkle:version>2.0.99</sparkle:version>"),
                      content.replace(b"a" * 40, b"e" * 40),
                      content.replace(b'<description ', b'<description extra="ignored" '),
                      content.replace(b"<channel>", b"<!DOCTYPE rss [<!ENTITY x 'unsafe'>]><channel>"),
                      content.replace(b"</channel>", b"<item /></channel>")]
        for content in candidates:
            metadata = copy.deepcopy(original)
            self.replace_feed(directory, metadata, self.signed_feed(content))
            with self.subTest(size=len(content)), self.assertRaises(appcast.SparkleError):
                appcast.verify_release(directory, self.context, metadata)

    def test_metadata_rejects_unknown_schema_urls_and_source(self):
        directory, original = self.release()
        edits = [("feedURL", "https://evil.invalid/feed"), ("sourceSHA", "b" * 40), ("buildNumber", "1.2.3"), ("schemaVersion", True), ("extra", True)]
        for key, value in edits:
            metadata = copy.deepcopy(original)
            metadata[key] = value
            with self.subTest(key=key), self.assertRaises(appcast.SparkleError):
                appcast.verify_release(directory, self.context, metadata)
        metadata = copy.deepcopy(original)
        metadata["archive"]["name"] = "../outside.zip"
        with self.assertRaises(appcast.SparkleError):
            appcast.verify_release(directory, self.context, metadata)

    def test_symlink_archive_is_rejected(self):
        directory, metadata = self.release()
        path = directory / metadata["archive"]["name"]
        outside = self.root / "outside.zip"
        path.rename(outside)
        path.symlink_to(outside)
        with self.assertRaises(appcast.SparkleError):
            appcast.verify_release(directory, self.context, metadata)

    def test_publish_initial_orphan_feed(self):
        directory, metadata = self.release()
        api = FakeGitHub(self.context, metadata)
        result = appcast.publish_feed(api, directory, self.context)
        self.assertEqual(result["commit_sha"], api.new_head)
        self.assertIsNone(result["previous_commit_sha"])

    def test_publish_older_feed_uses_parent_and_nonforced_ref(self):
        previous, _ = self.release(self.context_for("0.1.0-preview.9"), "previous")
        directory, metadata = self.release()
        api = FakeGitHub(self.context, metadata, (previous / "appcast.xml").read_bytes())
        result = appcast.publish_feed(api, directory, self.context)
        self.assertEqual(result["previous_commit_sha"], api.old_head)
        self.assertTrue(any(method == "PATCH" and body == {"sha": api.new_head, "force": False} for method, _, body, _ in api.calls))

    def test_publish_replay_and_downgrade_fail_before_writes(self):
        directory, metadata = self.release()
        newer, _ = self.release(self.context_for("0.1.0"), "newer")
        for prior in [(directory / "appcast.xml").read_bytes(), (newer / "appcast.xml").read_bytes()]:
            api = FakeGitHub(self.context, metadata, prior)
            with self.assertRaises(appcast.SparkleError):
                appcast.publish_feed(api, directory, self.context)
            self.assert_no_writes(api)

    def test_publish_unsigned_prior_feed_and_extra_tree_rejected(self):
        directory, metadata = self.release()
        for prior, extra in [(b"<rss/>", False), ((directory / "appcast.xml").read_bytes(), True)]:
            api = FakeGitHub(self.context, metadata, prior)
            api.extra_tree_file = extra
            with self.assertRaises(appcast.SparkleError):
                appcast.publish_feed(api, directory, self.context)
            self.assert_no_writes(api)

    def test_publish_draft_or_mismatched_asset_rejected(self):
        directory, metadata = self.release()
        for field in ("draft", "bad_asset"):
            api = FakeGitHub(self.context, metadata)
            setattr(api, field, True)
            with self.assertRaises(appcast.SparkleError):
                appcast.publish_feed(api, directory, self.context)
            self.assert_no_writes(api)

    def test_concurrent_feed_write_is_not_retried(self):
        previous, _ = self.release(self.context_for("0.1.0-preview.9"), "previous")
        directory, metadata = self.release()
        for prior in (None, (previous / "appcast.xml").read_bytes()):
            api = FakeGitHub(self.context, metadata, prior)
            api.race = True
            with self.assertRaises(appcast.SparkleError):
                appcast.publish_feed(api, directory, self.context)
            ref_writes = [call for call in api.calls if call[0] in {"POST", "PATCH"} and "/git/refs" in call[1]]
            self.assertEqual(len(ref_writes), 1)
            self.assertEqual(api.head, api.old_head)

    def test_subprocess_is_sanitized_and_errors_do_not_echo_input(self):
        marker = "PRIVATE_DIAGNOSTIC_DO_NOT_PRINT"
        result = subprocess.CompletedProcess([], 1, marker.encode(), marker.encode())
        with mock.patch.object(appcast.subprocess, "run", return_value=result) as process:
            with self.assertRaises(appcast.SparkleError) as error:
                appcast._run(["/test/signer"], stdin=marker.encode())
        self.assertNotIn(marker, str(error.exception))
        environment = process.call_args.kwargs["env"]
        self.assertNotIn("SPARKLE_ED_PRIVATE_KEY", environment)
        self.assertNotIn("GH_TOKEN", environment)
        self.assertEqual(process.call_args.kwargs["input"], marker.encode())

    def test_owned_tool_preparation_and_nonrecursive_cleanup(self):
        signer = b"nonexecutable synthetic signer fixture"
        memory = io.BytesIO()
        with zipfile.ZipFile(memory, "w") as archive:
            item = zipfile.ZipInfo("bin/sign_update")
            item.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(item, signer)
            archive.writestr("../never-extracted", "ignored")
        package = memory.getvalue()
        package_hash, signer_hash = hashlib.sha256(package).hexdigest(), hashlib.sha256(signer).hexdigest()
        self.config["checksum"] = package_hash
        self.write_config()
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = package
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.object(appcast, "PACKAGE_SHA256", package_hash), mock.patch.object(appcast, "SIGNER_SHA256", signer_hash), \
             mock.patch.object(appcast.urllib.request, "build_opener", return_value=opener):
            path = appcast.prepare_tools()
            self.assertEqual(path.read_bytes(), signer)
            self.assertFalse((self.root / "never-extracted").exists())
            self.assertEqual(appcast.prepare_tools(), path)
            self.assertEqual(opener.open.call_count, 1)
            (path.parent / "unowned").write_text("do not delete")
            with self.assertRaises(appcast.SparkleError):
                appcast.cleanup_tools()
            self.assertTrue((path.parent / "unowned").exists())
            (path.parent / "unowned").unlink()
            appcast.cleanup_tools()
            self.assertFalse(path.parent.exists())


def native_signer_smoke():
    """An explicit CI entry point, never a silently skipped portable test.

    This executes the checksum-pinned macOS signer with a newly generated test
    seed through its real stdin interface. It never uses a production secret.
    """
    appcast.require(sys.platform == "darwin", "Native Sparkle signer smoke requires macOS; it was not run.")
    appcast.require("SPARKLE_ED_PRIVATE_KEY" not in os.environ,
                    "Native signer smoke must run in a job without signing secrets.")
    root = appcast._temp_root()
    tools_existed = (root / "moekit-sparkle-tools").exists()
    appcast.prepare_tools()
    try:
        with tempfile.TemporaryDirectory(prefix="moekit-native-sparkle-fixture-", dir=root) as name:
            directory = Path(name)
            openssl = appcast._openssl()
            private_path = directory / "ephemeral-fixture-key.pem"
            appcast._run([openssl, "genpkey", "-algorithm", "ED25519", "-out", str(private_path)])
            public = appcast._run([openssl, "pkey", "-in", str(private_path), "-pubout", "-outform", "DER"])
            private = appcast._run([openssl, "pkey", "-in", str(private_path), "-outform", "DER"])
            appcast.require(len(public) == 44 and public[:12] == bytes.fromhex("302a300506032b6570032100") and
                            len(private) == 48 and private[:16] == bytes.fromhex("302e020100300506032b657004220420"),
                            "Native fixture key encoding is unexpected.")
            public_key = base64.b64encode(public[12:]).decode("ascii")
            seed = base64.b64encode(private[-32:]).decode("ascii")
            config = appcast.load_config()
            config["publicEDKey"] = public_key
            config_path = directory / "fixture-Sparkle.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            context = {"version": "0.1.0-preview.10", "marketing_version": "0.1.0", "build_number": "2.0.10",
                       "source_sha": "a" * 40, "run_id": "123", "run_number": "42", "run_attempt": "1"}
            archive = directory / appcast._archive_name(context)
            with zipfile.ZipFile(archive, "w") as fixture:
                fixture.writestr("MoeKit.app/Contents/fixture.txt", "Non-executable native signing test fixture")
            with mock.patch.object(appcast, "CONFIG_PATH", config_path), \
                 mock.patch.dict(os.environ, {"SPARKLE_ED_PRIVATE_KEY": seed}, clear=False):
                metadata = appcast.sign_release(directory, context, "Native fixture notes: <plain> & 安全\nSecond line")
            with mock.patch.object(appcast, "CONFIG_PATH", config_path):
                appcast.verify_release(directory, context, metadata)
                data = archive.read_bytes() + b"changed"
                archive.write_bytes(data)
                metadata["archive"].update(length=len(data), sha256=hashlib.sha256(data).hexdigest())
                try:
                    appcast.verify_release(directory, context, metadata)
                except appcast.SparkleError:
                    pass
                else:
                    raise appcast.SparkleError("Native signer smoke accepted a tampered archive.")
            print("PASS: official pinned Sparkle signer accepted a 32-byte test seed over stdin, signed ZIP and XML, "
                  "and public-only OpenSSL 3 verified both and rejected archive tampering.")
    finally:
        if not tools_existed:
            appcast.cleanup_tools()


if __name__ == "__main__":
    if sys.argv[1:] == ["--native-signer"]:
        try:
            native_signer_smoke()
        except appcast.SparkleError as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
        except Exception:
            print("Native Sparkle signer smoke failed; private fixture diagnostics withheld.", file=sys.stderr)
            sys.exit(1)
    else:
        unittest.main()
