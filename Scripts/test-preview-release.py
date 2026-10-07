#!/usr/bin/env python3
"""Portable security regression tests; no macOS, credentials, or network required."""
import ast
import importlib.util
from contextlib import redirect_stderr, redirect_stdout
import io
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
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
            "CFBundlePackageType": "APPL", "CFBundleName": "MoeKit", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2.0.1",
            "SUFeedURL": "https://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml",
            "SUPublicEDKey": release.appcast_module().load_config()["publicEDKey"],
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0, "SUAutomaticallyUpdate": False,
            "SUEnableSystemProfiling": False, "SUEnableJavaScript": False,
            "LSMinimumSystemVersion": "15.0", "MoeKitSourceCommit": "a" * 40,
            "MoeKitPreviewVersion": "0.1.0-preview.1", "MoeKitBuildRunID": "101",
            "MoeKitBuildRunAttempt": "1"}


def notes_text(version="0.1.0-preview.1"):
    return ('---\ntitle: "Preview notes"\nversion: "' + version + '"\n'
            'description: "Synthetic release notes"\nstatus: unreleased\n---\n\n'
            '## 新增\n\n- Synthetic feature\n')


def write_notes(context):
    path = Path("website/content/changelog") / (context["version"] + ".md")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(notes_text(context["version"]), encoding="utf-8")
    return path


def signed_metadata(context, *, digest="c" * 64, artifacts=None, notes_hash="d" * 64):
    info = release.metadata(context)
    info.update(signing="Apple Development", signature_verified=True, expected_team_verified=True,
                entitlements={}, hardened_runtime=True, code_objects_verified=release.VERIFIED_CODE_PATHS.copy(),
                app_content_sha256=digest,
                artifacts=artifacts or {name: "e" * 64 for name in release.package_names(context)},
                release_notes_sha256=notes_hash,
                package_verification={"dmg_integrity": True, "dmg_read_only": True,
                                      "dmg_app_signature_verified": True, "zip_app_signature_verified": True,
                                      "identical_app_content": True})
    return info


SYNTHETIC_MACHO = bytes.fromhex("cffaedfe") + b"synthetic fixture, never executed"


def write_zip_code(archive):
    for relative in sorted(release.EXECUTABLE_PATHS):
        item = zipfile.ZipInfo("MoeKit.app/" + relative)
        item.create_system = 3
        item.external_attr = 0o100755 << 16
        archive.writestr(item, SYNTHETIC_MACHO)
    for relative, data in (synthetic_sparkle_resources() | synthetic_swiftterm_resources()).items():
        item = zipfile.ZipInfo("MoeKit.app/" + relative)
        item.create_system = 3; item.external_attr = 0o100644 << 16
        archive.writestr(item, data)
    for relative, target in release.SPARKLE_LINKS.items():
        item = zipfile.ZipInfo("MoeKit.app/" + relative)
        item.create_system = 3; item.external_attr = 0o120777 << 16
        archive.writestr(item, target.encode())


def synthetic_sparkle_resources():
    files = {path: b"Synthetic resource; never executed" for path in release.SPARKLE_FILES
             if path not in release.SPARKLE_EXECUTABLES and path not in release.SPARKLE_SIGNATURE_FILES}
    for relative, identifier in release.SPARKLE_CODE:
        if relative.endswith("/Autoupdate"):
            continue
        framework = relative == release.SPARKLE_ROOT
        plist = relative + ("/Versions/B/Resources/Info.plist" if framework else "/Contents/Info.plist")
        files[plist] = plistlib.dumps({"CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Sparkle" if framework else Path(relative).stem,
            "CFBundlePackageType": "FMWK" if framework else ("XPC!" if relative.endswith(".xpc") else "APPL"),
            "CFBundleVersion": "2064", "CFBundleShortVersionString": "2.10.0"})
    return files


def synthetic_swiftterm_resources():
    return {release.SWIFTTERM_INFO: plistlib.dumps({"CFBundlePackageType": "BNDL"}),
            release.SWIFTTERM_METAL: b"MTLB" + b"synthetic data only; never executed"}


def synthetic_app(parent):
    app = parent / "MoeKit.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(valid_plist()))
    for relative in release.EXECUTABLE_PATHS:
        (app / relative).parent.mkdir(parents=True, exist_ok=True)
        (app / relative).write_bytes(SYNTHETIC_MACHO)
        (app / relative).chmod(0o755)
    for relative, data in (synthetic_sparkle_resources() | synthetic_swiftterm_resources()).items():
        (app / relative).parent.mkdir(parents=True, exist_ok=True)
        (app / relative).write_bytes(data)
    for relative, target in release.SPARKLE_LINKS.items():
        (app / relative).parent.mkdir(parents=True, exist_ok=True)
        (app / relative).symlink_to(target)
    return app


def compile_native_fixture(temporary, executable):
    # Darwin universal builds run separate architecture jobs; both must be able
    # to reopen the input. A shared stdin stream is not a reusable source file.
    source = temporary / "fixture.c"
    source.write_text("int main(void) { return 0; }\n", encoding="ascii")
    allowed_environment = {"PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT",
                           "MACOSX_DEPLOYMENT_TARGET", "LANG", "LC_ALL", "LC_CTYPE"}
    environment = {key: value for key, value in os.environ.items() if key in allowed_environment}
    try:
        library = ["-dynamiclib", "-install_name", "@rpath/Sparkle.framework/Versions/B/Sparkle"] if executable.name == "Sparkle" else []
        result = subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
                                 "-mmacosx-version-min=15.0", *library, str(source), "-o", str(executable)],
                                stdin=subprocess.DEVNULL, check=False, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=environment, timeout=120)
    except subprocess.TimeoutExpired:
        raise AssertionError("Synthetic universal fixture compilation timed out after 120 seconds.") from None
    except OSError as error:
        raise AssertionError(f"Synthetic universal fixture compiler could not start (OS error {error.errno}).") from None
    if result.returncode:
        # Only the no-secrets compiler for this fixed synthetic C source gets
        # bounded stderr. Signing/hdiutil diagnostics remain fixed-label-only.
        # repr escapes newlines and terminal controls into one inert log line.
        diagnostic = repr(result.stderr[:4096].decode("utf-8", errors="backslashreplace"))[:4096]
        raise AssertionError(f"Synthetic universal fixture compilation failed (exit {result.returncode}); "
                             f"bounded compiler stderr: {diagnostic}")


class Inputs(unittest.TestCase):
    def test_expected_default_branch_dispatch(self):
        self.assertEqual(release.validate_inputs(valid_environment())["marketing_version"], "0.1.0")

    def test_ci_public_key_must_equal_the_reviewed_public_key(self):
        public = "synthetic-public-key-comparison-only"
        with patch.object(release.appcast_module(), "load_config", return_value={"publicEDKey": public}):
            for supplied in ("", "different-key", public + "\n"):
                with patch.dict(os.environ, {"SPARKLE_ED_PUBLIC_KEY": supplied}), self.assertRaises(release.ReleaseError):
                    release.validate_public_key_input()
            with patch.dict(os.environ, {"SPARKLE_ED_PUBLIC_KEY": public}):
                self.assertEqual(release.validate_public_key_input(), public)

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
            write_zip_code(archive)
            if extra:
                archive.writestr(*extra)
        return path

    def test_valid_zip_provenance(self):
        release.inspect_zip(self.zip(), self.context)

    def test_rejects_zip_traversal_or_wrong_roots(self):
        for path in ("MoeKit.app/../../bad", "/MoeKit.app/abs", "certificate.p12", "MoeKit.app\\bad",
                     "MoeKit.app//Contents/extra", "MoeKit.app/./Contents/extra"):
            with self.subTest(path=path), self.assertRaises(release.ReleaseError):
                release.inspect_zip(self.zip((path, b"bad")), self.context)

    def test_rejects_zip_symlink(self):
        info = zipfile.ZipInfo("MoeKit.app/Contents/link")
        info.create_system = 3
        info.external_attr = 0o120777 << 16
        with self.assertRaises(release.ReleaseError):
            release.inspect_zip(self.zip((info, b"/tmp")), self.context)

    def test_resource_metadata_cannot_hide_extra_payload(self):
        for path, data in (("__MACOSX/extra-tool", b"extra"),
                           ("__MACOSX/MoeKit.app/Contents/._missing", bytes.fromhex("0005160700020000")),
                           ("__MACOSX/MoeKit.app/Contents/._Info.plist", b"synthetic executable")):
            with self.subTest(path=path), self.assertRaises(release.ReleaseError):
                release.inspect_zip(self.zip((path, data)), self.context)

    def test_allows_only_corresponding_appledouble_resource_metadata(self):
        path = self.zip(("__MACOSX/MoeKit.app/Contents/._Info.plist", bytes.fromhex("0005160700020000") + b"fixture"))
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("__MACOSX/", b"")
            archive.writestr("__MACOSX/MoeKit.app/", b"")
        release.inspect_zip(path, self.context)

    def test_rejects_wrong_app_provenance(self):
        for key, value in (("CFBundleIdentifier", "com.attacker.App"), ("MoeKitSourceCommit", "b" * 40),
                           ("MoeKitBuildRunID", "102"), ("MoeKitBuildRunAttempt", "2"),
                           ("CFBundleVersion", "2"), ("MoeKitPreviewVersion", "0.1.0-preview.2")):
            with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                release.inspect_zip(self.zip(info=valid_plist() | {key: value}), self.context)

    def test_swiftui_app_rejects_legacy_main_interface_keys(self):
        for key in ("NSMainStoryboardFile", "NSMainNibFile"):
            for value in ("Main", "", False):
                with self.subTest(key=key, value=value), self.assertRaises(release.ReleaseError):
                    release.inspect_zip(self.zip(info=valid_plist() | {key: value}), self.context)

    def test_signed_metadata_is_required(self):
        info = release.metadata(self.context)
        with self.assertRaises(release.ReleaseError):
            release.check_metadata(info, self.context, signed=True)
        info = signed_metadata(self.context)
        with patch.object(release, "release_notes", return_value=("notes", "d" * 64)):
            release.check_metadata(info, self.context, signed=True)
        info["source_sha"] = "b" * 40
        with self.assertRaises(release.ReleaseError):
            release.check_metadata(info, self.context, signed=True)


class BundleCodeLayout(unittest.TestCase):
    helper_path = release.HELPER_PATH
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = synthetic_app(self.root)
        self.context = release.validate_inputs(valid_environment())

    def tearDown(self):
        self.temp.cleanup()

    def verify(self):
        with patch.object(release, "text_run", return_value="arm64 x86_64") as command:
            release.verify_app(self.app, self.context)
        return command

    def test_reviewed_code_allowlist_and_inside_out_order_are_exact(self):
        expected = (("Contents/MacOS/MoleAnalysisSupervisor", "com.yusixian.MoeKit.MoleAnalysisSupervisor"),
                    ("Contents/MacOS/GitObjectInspector", "com.yusixian.MoeKit.GitObjectInspector"),
                    ("Contents/MacOS/GitRemoteTransport", "com.yusixian.MoeKit.GitRemoteTransport"),
                    ("Contents/MacOS/OperationTerminal", "com.yusixian.MoeKit.OperationTerminal"))
        self.assertEqual(release.HELPERS, expected)
        self.assertEqual(release.EXECUTABLE_PATHS,
                         {"Contents/MacOS/MoeKit", *(path for path, _ in expected), *release.SPARKLE_EXECUTABLES})
        self.assertEqual(release.code_objects(self.app),
                         tuple((self.app / path, identifier) for path, identifier in expected + release.SPARKLE_CODE) +
                         ((self.app, "com.yusixian.MoeKit"),))
        self.assertEqual(release.VERIFIED_CODE_PATHS, [path for path, _ in expected + release.SPARKLE_CODE] + ["."])
        self.assertEqual(len(release.SPARKLE_EXECUTABLES), 5)

    def test_only_exact_executables_and_both_architectures(self):
        command = self.verify()
        self.assertEqual({call.args[2] for call in command.call_args_list},
                         {str(self.app / relative) for relative in release.EXECUTABLE_PATHS})
        self.assertEqual(len(command.call_args_list), 10)
        for bad_architectures in ("arm64", "x86_64", "arm64 x86_64 i386", ""):
            with self.subTest(architectures=bad_architectures):
                for broken in release.EXECUTABLE_PATHS:
                    def architectures(*args, operation):
                        return bad_architectures if args[2] == str(self.app / broken) else "arm64 x86_64"
                    with patch.object(release, "text_run", side_effect=architectures), self.assertRaises(release.ReleaseError):
                        release.verify_app(self.app, self.context)

    def test_missing_renamed_text_or_nonexecutable_helper_fails(self):
        helper = self.app / self.helper_path
        helper.unlink()
        with self.assertRaises(release.ReleaseError):
            self.verify()
        helper.write_bytes(b"#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)
        with self.assertRaises(release.ReleaseError):
            self.verify()
        helper.write_bytes(SYNTHETIC_MACHO)
        helper.chmod(0o644)
        with self.assertRaises(release.ReleaseError):
            self.verify()
        helper.chmod(0o755)
        helper.rename(helper.with_name("OtherSupervisor"))
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_additional_code_and_nested_bundles_fail_closed(self):
        for relative, data, mode in (("Contents/MacOS/analyze-go", SYNTHETIC_MACHO, 0o755),
                                     ("Contents/MacOS/git", SYNTHETIC_MACHO, 0o755),
                                     ("Contents/Resources/helper", SYNTHETIC_MACHO, 0o644),
                                     ("Contents/Resources/script", b"#!/bin/sh", 0o755),
                                     ("Contents/Helpers/helper", b"plain", 0o644),
                                     ("Contents/embedded.provisionprofile", b"plain", 0o644),
                                     ("unexpected.txt", b"plain", 0o644)):
            with self.subTest(path=relative):
                path = self.app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                path.chmod(mode)
                with self.assertRaises(release.ReleaseError):
                    self.verify()
                path.unlink()
                if relative.startswith("Contents/Helpers/"):
                    path.parent.rmdir()
        for relative in ("Contents/Frameworks/Hidden.framework", "Contents/Resources/Hidden.app", "Contents/Resources/Hidden.bundle"):
            path = self.app / relative
            path.mkdir(parents=True)
            with self.subTest(path=relative), self.assertRaises(release.ReleaseError):
                self.verify()
            path.rmdir()

    def test_helper_symlink_and_parent_directory_symlink_fail_before_tool_use(self):
        helper = self.app / self.helper_path
        helper.unlink()
        helper.symlink_to(self.app / "Contents/MacOS/MoeKit")
        with patch.object(release, "text_run") as command, self.assertRaises(release.ReleaseError):
            release.verify_app(self.app, self.context)
        command.assert_not_called()
        helper.unlink()
        macos = self.app / "Contents/MacOS"
        macos.rename(self.root / "foreign")
        macos.symlink_to(self.root / "foreign", target_is_directory=True)
        with patch.object(release, "text_run") as command, self.assertRaises(release.ReleaseError):
            release.verify_app(self.app, self.context)
        command.assert_not_called()

    def test_zip_rejects_missing_helper_extra_code_and_nonexecutable_helper(self):
        for variant in ("missing", "extra", "not-executable", "not-macho"):
            archive_path = self.root / "fixture.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("MoeKit.app/Contents/Info.plist", plistlib.dumps(valid_plist()))
                for relative in sorted(release.EXECUTABLE_PATHS):
                    if variant == "missing" and relative == self.helper_path:
                        continue
                    item = zipfile.ZipInfo("MoeKit.app/" + relative)
                    item.create_system = 3
                    item.external_attr = (0o100644 if variant == "not-executable" and relative == self.helper_path
                                          else 0o100755) << 16
                    archive.writestr(item, b"text" if variant == "not-macho" and relative == self.helper_path
                                     else SYNTHETIC_MACHO)
                if variant == "extra":
                    archive.writestr("MoeKit.app/Contents/Resources/hidden", SYNTHETIC_MACHO)
            with self.subTest(variant=variant), self.assertRaises(release.ReleaseError):
                release.inspect_zip(archive_path, self.context)

    def test_metadata_requires_exact_helper_provenance_and_verification(self):
        original = signed_metadata(self.context)
        for field, value in (("embedded_code", {}), ("code_objects_verified", ["."]),
                             ("code_objects_verified", [self.helper_path, ".", "other"]),
                             ("code_objects_verified", [self.helper_path, "."]),
                             ("embedded_code", {self.helper_path: original["embedded_code"][self.helper_path]}),
                             ("hardened_runtime", False)):
            with self.subTest(field=field), self.assertRaises(release.ReleaseError):
                release.check_metadata(original | {field: value}, self.context, signed=True)

    def test_helper_bytes_participate_in_zip_and_dmg_equality(self):
        digest = release.app_content_digest(self.app)
        (self.root / "Applications").symlink_to("/Applications")
        (self.app / self.helper_path).write_bytes(SYNTHETIC_MACHO + b"modified")
        self.assertNotEqual(digest, release.app_content_digest(self.app))
        with patch.object(release, "verify_app"), patch.object(release, "verify_code_objects") as verify:
            with self.assertRaises(release.ReleaseError):
                release.verify_dmg_contents(self.root, self.context, digest)
            verify.assert_not_called()


class GitInspectorBundleCodeLayout(BundleCodeLayout):
    helper_path = release.GIT_HELPER_PATH


class GitTransportBundleCodeLayout(BundleCodeLayout):
    helper_path = release.GIT_TRANSPORT_HELPER_PATH


class SwiftTermResourceLayout(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = synthetic_app(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_resource_inventory(self):
        resources = synthetic_swiftterm_resources()
        release.verify_swiftterm_inventory(set(resources), set())
        release.verify_swiftterm_info(resources[release.SWIFTTERM_INFO])
        for missing in release.SWIFTTERM_FILES:
            with self.subTest(missing=missing), self.assertRaises(release.ReleaseError):
                release.verify_swiftterm_inventory(set(resources) - {missing}, set())
        with self.assertRaises(release.ReleaseError):
            release.verify_swiftterm_inventory(set(resources) | {release.SWIFTTERM_BUNDLE + "/extra"}, set())

    def test_resource_links_and_unexpected_entries_are_rejected(self):
        with self.assertRaises(release.ReleaseError):
            release.verify_swiftterm_inventory(set(release.SWIFTTERM_FILES), {release.SWIFTTERM_METAL})
        for path in [release.SWIFTTERM_BUNDLE + "/extra", release.SWIFTTERM_BUNDLE + "/Contents/Extra.bundle"]:
            with self.subTest(path=path), self.assertRaises(release.ReleaseError):
                release.verify_bundle_entry(path, directory=False, mode=0o644, magic=b"data")

    def test_resource_executables_and_wrong_shader_magic_are_rejected(self):
        for mode, magic in [(0o755, b"MTLB"), (0o644, SYNTHETIC_MACHO[:4]), (0o644, b"fake")]:
            with self.subTest(mode=mode, magic=magic), self.assertRaises(release.ReleaseError):
                release.verify_bundle_entry(release.SWIFTTERM_METAL, directory=False, mode=mode, magic=magic)

    def test_resource_metadata_cannot_declare_code(self):
        for value in [{"CFBundlePackageType": "APPL"}, {"CFBundlePackageType": "BNDL", "CFBundleExecutable": "payload"}, []]:
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                release.verify_swiftterm_info(plistlib.dumps(value))
        for invalid in [b"not a plist", b"x" * 65537]:
            with self.assertRaises(release.ReleaseError):
                release.verify_swiftterm_info(invalid)


class SparkleLayout(BundleCodeLayout):
    helper_path = release.SPARKLE_VERSION_ROOT + "/Autoupdate"

    def test_pinned_sparkle_paths_and_identity_are_explicit(self):
        prefix = "Contents/Frameworks/Sparkle.framework/Versions/B/"
        self.assertEqual(release.SPARKLE_CODE, (
            (prefix + "XPCServices/Installer.xpc", "org.sparkle-project.InstallerLauncher"),
            (prefix + "XPCServices/Downloader.xpc", "org.sparkle-project.DownloaderService"),
            (prefix + "Autoupdate", "org.sparkle-project.Sparkle.Autoupdate"),
            (prefix + "Updater.app", "org.sparkle-project.Sparkle.Updater"),
            ("Contents/Frameworks/Sparkle.framework", "org.sparkle-project.Sparkle")))
        self.assertEqual(release.SPARKLE_LAYOUT["package_sha256"],
                         "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959")

    def test_only_exact_relative_framework_links_are_allowed(self):
        link = self.app / release.SPARKLE_ROOT / "Versions/Current"
        link.unlink()
        for target in ("/tmp", "../B", "C", "B/", "B/../B"):
            link.symlink_to(target)
            with self.subTest(target=target), self.assertRaises(release.ReleaseError):
                self.verify()
            link.unlink()

    def test_missing_framework_content_and_unknown_code_are_rejected(self):
        path = self.app / release.SPARKLE_VERSION_ROOT / "Resources/Info.plist"
        data = path.read_bytes(); path.unlink()
        with self.assertRaises(release.ReleaseError): self.verify()
        path.write_bytes(data)
        for name in ("Versions/C/Sparkle", "Versions/B/extra.dylib", "Versions/B/XPCServices/Extra.xpc/Contents/MacOS/Extra"):
            extra = self.app / release.SPARKLE_ROOT / name
            extra.parent.mkdir(parents=True, exist_ok=True); extra.write_bytes(SYNTHETIC_MACHO)
            with self.subTest(name=name), self.assertRaises(release.ReleaseError): self.verify()
            extra.unlink()

    def test_only_standard_header_omission_is_accepted(self):
        for part in ("Headers", "PrivateHeaders", "Modules"):
            (self.app / release.SPARKLE_ROOT / part).unlink()
            shutil.rmtree(self.app / release.SPARKLE_VERSION_ROOT / part)
        self.verify()

    def test_unsigned_vendor_hashes_are_mandatory_before_resigning(self):
        # The synthetic layout has intentionally non-vendor bytes, so never
        # accept it as the official upstream package before release signing.
        with self.assertRaises(release.ReleaseError): release.verify_upstream_sparkle(self.app)
        relative = release.SPARKLE_VERSION_ROOT + "/Sparkle"
        expected = release.sha256(self.app / relative)
        with patch.object(release, "SPARKLE_FILES", {relative: expected}):
            release.verify_upstream_sparkle(self.app)
            (self.app / relative).write_bytes(SYNTHETIC_MACHO + b"changed")
            with self.assertRaises(release.ReleaseError): release.verify_upstream_sparkle(self.app)

    def test_zip_and_directory_hashes_include_exact_link_targets(self):
        archive = self.root / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("MoeKit.app/Contents/Info.plist", plistlib.dumps(valid_plist()))
            write_zip_code(output)
        self.assertEqual(release.inspect_zip(archive, self.context), release.app_content_digest(self.app))
        with self.assertRaises(release.ReleaseError): release.inspect_zip(archive, self.context, upstream=True)

    def test_update_security_settings_fail_closed(self):
        path = self.app / "Contents/Info.plist"
        for key, value in (("SUPublicEDKey", "wrong"), ("SUFeedURL", "https://attacker.example/feed.xml"),
                           ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
                           ("SUSignedFeedFailureExpirationInterval", 1728000), ("SUAutomaticallyUpdate", True),
                           ("SUEnableJavaScript", True), ("SUEnableInstallerLauncherService", True)):
            path.write_bytes(plistlib.dumps(valid_plist() | {key: value}))
            with self.subTest(key=key), self.assertRaises(release.ReleaseError): self.verify()


class CodeObjectSigning(unittest.TestCase):
    helper_path = release.HELPER_PATH
    helper_id = release.HELPER_ID

    def setUp(self):
        self.app = Path("synthetic/MoeKit.app")
        self.identity = hashlib.sha1(b"synthetic certificate").hexdigest().upper()
        self.team = "A1B2C3D4E5"

    def display(self, *args, operation):
        identifier = dict((str(path), identifier) for path, identifier in release.code_objects(self.app))[args[-1]]
        details = (f"Identifier={identifier}\nCodeDirectory v=20500 size=10 flags=0x10000(runtime) hashes=1+0\n"
                   f"Authority=Apple Development: Synthetic Fixture\nTeamIdentifier={self.team}\n")
        return subprocess.CompletedProcess(args, 0, stdout=b"", stderr=details.encode())

    def test_explicit_inside_out_signing_uses_same_identity_and_no_entitlements(self):
        keychain = Path("synthetic/preview.keychain-db")
        with patch.object(release, "run") as command:
            release.sign_code_objects(self.app, self.identity, keychain)
        self.assertEqual(len(command.call_args_list), 10)
        for call, (path, identifier) in zip(command.call_args_list, release.code_objects(self.app)):
            self.assertEqual(call.args, ("/usr/bin/codesign", "--force", "--sign", self.identity,
                                        "--keychain", str(keychain), "--identifier", identifier,
                                        "--options", "runtime", "--timestamp=none", str(path)))
            self.assertEqual(call.kwargs, {"operation": "codesign-sign"})
            self.assertNotIn("--deep", call.args)
            self.assertNotIn("--preserve-metadata", call.args)
            self.assertNotIn("--entitlements", call.args)

    def test_each_architecture_has_identifier_runtime_entitlements_and_strict_requirement_checks(self):
        with patch.object(release, "run", return_value=b"") as command, patch.object(release, "captured_run", side_effect=self.display) as display:
            release.verify_code_objects(self.app)
        self.assertEqual(len(display.call_args_list), 20)
        pairs = {(call.args[-1], call.args[3]) for call in display.call_args_list}
        self.assertEqual(pairs, {(str(path), architecture) for path, _ in release.code_objects(self.app)
                                 for architecture in release.ARCHITECTURES})
        verifications = [call for call in command.call_args_list if call.kwargs["operation"] == "codesign-verify"]
        self.assertEqual(len(verifications), 10)
        for call, (path, identifier) in zip(verifications, release.code_objects(self.app)):
            self.assertEqual(call.args, ("/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
                                        f'-R=identifier "{identifier}"', str(path)))
        entitlements = [call for call in command.call_args_list if call.kwargs["operation"] == "entitlements-read"]
        self.assertEqual({(call.args[-1], call.args[3]) for call in entitlements}, pairs)

    def test_bad_identifier_runtime_or_nonhost_entitlements_fail(self):
        for variant in ("identifier", "runtime", "entitlements"):
            def display(*args, operation):
                result = self.display(*args, operation=operation)
                if args[-1] == str(self.app / self.helper_path) and args[3] == "x86_64":
                    if variant == "identifier":
                        result.stderr = result.stderr.replace(self.helper_id.encode(), b"com.invalid.helper")
                    elif variant == "runtime":
                        result.stderr = result.stderr.replace(b"flags=0x10000(runtime)", b"flags=0x0(none)")
                return result
            def command(*args, operation):
                if (variant == "entitlements" and operation == "entitlements-read" and
                        args[-1] == str(self.app / self.helper_path) and args[3] == "x86_64"):
                    return plistlib.dumps({"com.apple.security.get-task-allow": True})
                return b""
            with self.subTest(variant=variant), patch.object(release, "run", side_effect=command), patch.object(release, "captured_run", side_effect=display):
                with self.assertRaises(release.ReleaseError):
                    release.verify_code_objects(self.app)

    def verify_development(self, temporary, *, wrong_certificate=False, display=None, reject_requirement=False):
        calls = []
        def command(*args, operation):
            calls.append((args, operation))
            if operation == "codesign-verify" and reject_requirement and "certificate leaf" in args[-2]:
                raise release.ReleaseError("Synthetic requirement mismatch.")
            if operation == "certificate-extract":
                prefix = next(argument.split("=", 1)[1] for argument in args if argument.startswith("--extract-certificates="))
                data = b"synthetic certificate"
                if wrong_certificate and args[-1] == str(self.app / self.helper_path) and args[3] == "x86_64":
                    data = b"different synthetic certificate"
                Path(prefix + "0").write_bytes(data)
            return b""
        with patch.object(release, "run", side_effect=command), patch.object(release, "captured_run", side_effect=display or self.display):
            release.verify_development_signatures(self.app, self.identity, self.team, temporary)
        return calls

    def test_exact_development_signer_requirement_and_certificate_checked_for_both_slices(self):
        with tempfile.TemporaryDirectory() as temporary:
            calls = self.verify_development(Path(temporary))
        extractions = [args for args, operation in calls if operation == "certificate-extract"]
        self.assertEqual(len(extractions), 20)
        self.assertEqual(len({args[4] for args in extractions}), 20)
        requirements = [args[-2] for args, operation in calls
                        if operation == "codesign-verify" and "certificate leaf" in args[-2]]
        self.assertEqual(requirements, [f'-R=identifier "{identifier}" and anchor apple generic '
                                      f'and certificate leaf = H"{self.identity}" and certificate leaf[subject.OU] = "{self.team}"'
                                      for _, identifier in release.code_objects(self.app)])

    def test_wrong_helper_certificate_or_failed_requirement_is_fatal(self):
        for kwargs in ({"wrong_certificate": True}, {"reject_requirement": True}):
            with tempfile.TemporaryDirectory() as temporary, self.subTest(kwargs=kwargs), self.assertRaises(release.ReleaseError):
                self.verify_development(Path(temporary), **kwargs)

    def test_wrong_helper_team_or_ad_hoc_signature_is_fatal(self):
        for replacement in (b"TeamIdentifier=WRONGTEAM1", b"Signature=adhoc"):
            def display(*args, operation):
                result = self.display(*args, operation=operation)
                if args[-1] == str(self.app / self.helper_path) and args[3] == "x86_64":
                    result.stderr = result.stderr.replace(f"TeamIdentifier={self.team}".encode(), replacement)
                return result
            with tempfile.TemporaryDirectory() as temporary, self.subTest(replacement=replacement), self.assertRaises(release.ReleaseError):
                self.verify_development(Path(temporary), display=display)

    def test_invalid_identity_inputs_never_reach_codesign(self):
        with patch.object(release, "run") as command:
            for identity, team in (("not-a-hash", self.team), (self.identity, 'bad"team')):
                with self.assertRaises(release.ReleaseError):
                    release.verify_development_signatures(self.app, identity, team, Path("synthetic"))
        command.assert_not_called()


class GitInspectorCodeObjectSigning(CodeObjectSigning):
    helper_path = release.GIT_HELPER_PATH
    helper_id = release.GIT_HELPER_ID


class GitTransportCodeObjectSigning(CodeObjectSigning):
    helper_path = release.GIT_TRANSPORT_HELPER_PATH
    helper_id = release.GIT_TRANSPORT_HELPER_ID


class SparkleCodeObjectSigning(CodeObjectSigning):
    helper_path = release.SPARKLE_VERSION_ROOT + "/Autoupdate"
    helper_id = "org.sparkle-project.Sparkle.Autoupdate"


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


class ReleaseBody(unittest.TestCase):
    def render(self, notes):
        context = release.validate_inputs(valid_environment())
        info = {"source_url": "https://github.com/cosZone/MoeKit/commit/" + "a" * 40,
                "run_url": "https://github.com/cosZone/MoeKit/actions/runs/101"}
        return release.release_body(context, info, notes, *release.package_names(context))

    def test_complete_notes_appear_once_without_repeated_boilerplate(self):
        notes = "## 更新\n\n- One feature\n\nmacOS 15+，Apple Silicon / Intel。Apple Development 签名、未公证。"
        body = self.render(notes)
        self.assertEqual(body.count(notes), 1)
        self.assertEqual(body.count("macOS 15+"), 1)
        self.assertEqual(body.count("Apple Development"), 1)
        self.assertNotIn("Release 配置单元测试", body)
        self.assertIn("[构建信息]", body)
        self.assertIn("[校验和]", body)

    def test_missing_limits_get_a_short_fallback(self):
        body = self.render("- One feature")
        self.assertEqual(body.count("macOS 15+"), 1)
        self.assertEqual(body.count("Apple Development"), 1)
        self.assertIn("未经过 Apple 公证", body)

    def test_partial_limits_do_not_suppress_the_missing_warning(self):
        for notes in ("macOS 15+", "Apple Development", "未公证"):
            with self.subTest(notes=notes):
                body = self.render(notes)
                self.assertIn("macOS 15+", body)
                self.assertIn("Apple Development 开发签名，未经过 Apple 公证", body)
        legacy = self.render("macOS 15+ · Apple Development 开发签名，未经过 Apple 公证")
        self.assertEqual(legacy.count("Apple Development"), 1)


class Publication(unittest.TestCase):
    def setUp(self):
        self.feed_verify = patch.object(release.appcast_module(), "verify_release").start()
        self.feed_publish = patch.object(release.appcast_module(), "publish_feed").start()
        self.addCleanup(patch.stopall)
        self.temp = tempfile.TemporaryDirectory()
        self.old_cwd = Path.cwd()
        os.chdir(self.temp.name)
        directory = Path("Preview")
        directory.mkdir()
        self.context = release.validate_inputs(valid_environment())
        self.dmg_name, self.zip_name = release.package_names(self.context)
        with zipfile.ZipFile(directory / self.zip_name, "w") as archive:
            archive.writestr("MoeKit.app/Contents/Info.plist", plistlib.dumps(valid_plist()))
            write_zip_code(archive)
        (directory / self.dmg_name).write_bytes(b"Synthetic DMG fixture; native validation is tested on macOS.")
        (directory / "appcast.xml").write_bytes(b"Synthetic feed; signature coverage is in test-sparkle-appcast.py")
        notes = write_notes(self.context)
        info = signed_metadata(self.context, digest=release.inspect_zip(directory / self.zip_name, self.context),
                               artifacts={name: release.sha256(directory / name) for name in (self.dmg_name, self.zip_name)},
                               notes_hash=release.sha256(notes))
        release.write_json(directory / "BUILD_INFO.json", info)
        release.write_checksums(directory, (self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml"))

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
        self.assertEqual({item["name"] for item in api.assets},
                         {self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml", "SHA256SUMS.txt"})
        self.feed_publish.assert_called_once()
        created = next(body for method, path, body in api.calls if method == "POST" and path.endswith("/releases"))
        self.assertEqual(created["name"], "v0.1.0-preview.1")
        self.assertTrue(created["body"].startswith("[下载 DMG（推荐）]"))
        self.assertIn("## 新增\n\n- Synthetic feature", created["body"])
        self.assertNotIn("status: unreleased", created["body"])
        self.assertIn("Apple Development", created["body"])
        self.assertIn("未经过 Apple 公证", created["body"])
        self.assertIn("/commit/" + "a" * 40, created["body"])
        self.assertIn("/actions/runs/101", created["body"])
        self.assertEqual(api.calls[-1][0], "PATCH")
        self.assertFalse(api.calls[-1][2]["draft"])
        self.assertFalse(any(method == "DELETE" for method, _, _ in api.calls))

    def test_bad_upload_digest_never_publishes_draft(self):
        api = self.fake_publisher(digest_ok=False)
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub", return_value=api):
            with self.assertRaises(release.ReleaseError):
                release.publish()
        self.assertFalse(any(method in {"PATCH", "DELETE"} for method, _, _ in api.calls))

    def assert_publish_stops_before_api(self):
        with patch.object(release, "validate", return_value=self.context), patch.object(release, "GitHub") as api:
            with self.assertRaises(release.ReleaseError):
                release.publish()
        api.assert_not_called()

    def test_missing_dmg_or_extra_asset_stops_publication(self):
        Path("Preview", self.dmg_name).unlink()
        self.assert_publish_stops_before_api()
        Path("Preview", self.dmg_name).write_bytes(b"restored fixture")
        Path("Preview", "unexpected.bin").write_text("unexpected")
        release.write_checksums(Path("Preview"), (self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml"))
        self.assert_publish_stops_before_api()

    def test_tampered_dmg_even_with_new_checksums_stops_publication(self):
        Path("Preview", self.dmg_name).write_bytes(b"tampered image")
        release.write_checksums(Path("Preview"), (self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml"))
        self.assert_publish_stops_before_api()

    def test_missing_native_verification_flags_stop_publication(self):
        path = Path("Preview/BUILD_INFO.json")
        original = json.loads(path.read_text())
        for flag in original["package_verification"]:
            info = json.loads(json.dumps(original))
            info["package_verification"][flag] = False
            release.write_json(path, info)
            release.write_checksums(Path("Preview"), (self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml"))
            with self.subTest(flag=flag):
                self.assert_publish_stops_before_api()

    def test_changed_version_notes_stop_publication(self):
        path = Path("website/content/changelog/0.1.0-preview.1.md")
        path.write_text(path.read_text() + "\nUnreviewed extra content\n")
        self.assert_publish_stops_before_api()

    def test_extra_artifact_provenance_key_stops_publication(self):
        path = Path("Preview/BUILD_INFO.json")
        info = json.loads(path.read_text())
        info["artifacts"]["extra.zip"] = "0" * 64
        release.write_json(path, info)
        release.write_checksums(Path("Preview"), (self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml"))
        self.assert_publish_stops_before_api()

    def test_wrong_app_digest_stops_publication(self):
        path = Path("Preview/BUILD_INFO.json")
        info = json.loads(path.read_text())
        info["app_content_sha256"] = "0" * 64
        release.write_json(path, info)
        release.write_checksums(Path("Preview"), (self.dmg_name, self.zip_name, "BUILD_INFO.json", "appcast.xml"))
        self.assert_publish_stops_before_api()


class VersionNotes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_cwd = Path.cwd()
        os.chdir(self.temp.name)
        self.context = release.validate_inputs(valid_environment())
        self.path = write_notes(self.context)

    def tearDown(self):
        os.chdir(self.old_cwd)
        self.temp.cleanup()

    def test_strips_only_frontmatter_and_preserves_markdown(self):
        body, digest = release.release_notes(self.context)
        self.assertEqual(body, "## 新增\n\n- Synthetic feature")
        self.assertEqual(digest, release.sha256(self.path))
        self.assertIn("status: unreleased", self.path.read_text())

    def test_missing_or_empty_notes_fail(self):
        self.path.unlink()
        with self.assertRaises(release.ReleaseError):
            release.release_notes(self.context)
        self.path.write_text(notes_text().split("## 新增")[0])
        with self.assertRaises(release.ReleaseError):
            release.release_notes(self.context)

    def test_rejects_ambiguous_yaml_and_wrong_version(self):
        original = notes_text()
        bad = [original.replace('version: "0.1.0-preview.1"', 'version: "0.1.0-preview.2"'),
               original.replace('title: "Preview notes"', 'title: "One"\ntitle: "Two"'),
               original.replace('title: "Preview notes"', 'title: |\n  Block scalar'),
               original.replace('title: "Preview notes"', 'title: &anchor "Alias"'),
               original.replace('title: "Preview notes"', 'title: !!str "Tag"'),
               original.replace('title: "Preview notes"', 'title: "Escaped\\nnewline"'),
               original.replace('status: unreleased', 'status: released'),
               original.replace('status: unreleased', 'status: unreleased\nunknown: "value"'),
               original.replace('status: unreleased', 'status: unreleased\ndate: "2026-10-03"'),
               original.replace('description: "Synthetic release notes"\n', ''),
               original.replace('---\n\n', '\n\n', 1)]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(release.ReleaseError):
                self.path.write_text(text, encoding="utf-8")
                release.release_notes(self.context)

    def test_published_notes_require_matching_verified_provenance(self):
        publication = ('status: prerelease\ndate: "2026-10-03"\nsourceCommit: ' + "a" * 40 + '\n'
                       'releaseUrl: "https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.1"')
        text = notes_text().replace("status: unreleased", publication)
        self.path.write_text(text)
        self.assertTrue(release.release_notes(self.context)[0])
        for wrong in (text.replace("2026-10-03", "2026-02-30"), text.replace("a" * 40, "b" * 40),
                      text.replace("https://github.com/cosZone/", "https://attacker.test/")):
            with self.subTest(wrong=wrong), self.assertRaises(release.ReleaseError):
                self.path.write_text(wrong)
                release.release_notes(self.context)

    def test_symlink_notes_are_rejected(self):
        target = self.path.with_suffix(".copy")
        self.path.rename(target)
        self.path.symlink_to(target.name)
        with self.assertRaises(release.ReleaseError):
            release.release_notes(self.context)


class DmgSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {"RUNNER_TEMP": self.temp.name})
        self.environment.start()
        self.context = release.validate_inputs(valid_environment())

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def app(self, parent):
        return synthetic_app(parent)

    def test_content_digest_covers_signature_and_all_paths(self):
        app = self.app(Path(self.temp.name))
        original = release.app_content_digest(app)
        (app / "Contents/_CodeSignature").mkdir()
        (app / "Contents/_CodeSignature/CodeResources").write_bytes(b"synthetic seal")
        self.assertNotEqual(original, release.app_content_digest(app))
        (app / "Contents/link").symlink_to("/Applications")
        with self.assertRaises(release.ReleaseError):
            release.app_content_digest(app)

    def test_exact_dmg_contents_and_app_bytes_are_required(self):
        root = Path(self.temp.name) / "root"
        root.mkdir()
        app = self.app(root)
        digest = release.app_content_digest(app)
        (root / "Applications").symlink_to("/Applications")
        with patch.object(release, "verify_app"), patch.object(release, "verify_code_objects") as verify:
            release.verify_dmg_contents(root, self.context, digest)
            verify.assert_called_once_with(app)
            (app / "Contents/MacOS/MoeKit").write_bytes(b"different app")
            with self.assertRaises(release.ReleaseError):
                release.verify_dmg_contents(root, self.context, digest)

    def test_extra_root_or_wrong_shortcut_are_rejected(self):
        root = Path(self.temp.name) / "root"
        root.mkdir()
        app = self.app(root)
        digest = release.app_content_digest(app)
        shortcut = root / "Applications"
        shortcut.symlink_to("/tmp")
        with self.assertRaises(release.ReleaseError):
            release.verify_dmg_contents(root, self.context, digest)
        shortcut.unlink()
        shortcut.symlink_to("/Applications")
        (root / "extra-tool").write_bytes(b"not allowed")
        with self.assertRaises(release.ReleaseError):
            release.verify_dmg_contents(root, self.context, digest)

    def test_mountpoint_is_outside_signing_recursive_cleanup(self):
        self.assertNotIn(release.signing_directory(), release.dmg_mountpoint().parents)

    def test_detach_uses_only_fixed_mountpoint_then_nonrecursive_remove(self):
        mount = release.dmg_mountpoint()
        mount.mkdir()
        with patch.object(Path, "is_mount", side_effect=[True, False]), patch.object(release, "run") as command:
            with patch.object(release.shutil, "rmtree") as recursive:
                release.cleanup_dmg_mount()
        command.assert_called_once_with("/usr/bin/hdiutil", "detach", str(mount), operation="dmg-detach")
        recursive.assert_not_called()
        self.assertFalse(mount.exists())

    def test_failed_detach_preserves_mount_and_still_cleans_credentials(self):
        mount = release.dmg_mountpoint()
        mount.mkdir()
        sentinel = mount / "do-not-delete"
        sentinel.write_text("Synthetic mounted-volume marker")
        scratch = release.signing_directory()
        scratch.mkdir()
        (scratch / "preview.keychain-db").write_bytes(b"synthetic keychain")
        release.write_json(scratch / "original-keychains.json", ["/tmp/synthetic-login.keychain-db"])
        operations = []
        def command(*args, operation):
            operations.append(operation)
            if operation == "dmg-detach":
                raise release.ReleaseError("Synthetic detach failure.")
            return b""
        with patch.object(Path, "is_mount", return_value=True), patch.object(release, "run", side_effect=command):
            with self.assertRaises(release.ReleaseError):
                release.cleanup()
        self.assertTrue(sentinel.is_file())
        self.assertFalse(scratch.exists())
        self.assertEqual(operations, ["dmg-detach", "keychain-delete", "keychain-restore-search-list"])

    def test_success_status_with_still_mounted_volume_fails_without_delete(self):
        mount = release.dmg_mountpoint()
        mount.mkdir()
        with patch.object(Path, "is_mount", return_value=True), patch.object(release, "run"):
            with self.assertRaises(release.ReleaseError):
                release.cleanup_dmg_mount()
        self.assertTrue(mount.exists())

    def test_unmounted_nonempty_mountpoint_is_never_recursively_deleted(self):
        mount = release.dmg_mountpoint()
        mount.mkdir()
        (mount / "keep").write_text("fixture")
        with self.assertRaises(OSError):
            release.cleanup_dmg_mount()
        self.assertTrue((mount / "keep").exists())

    def test_partial_attach_failure_still_attempts_cleanup(self):
        scratch = release.signing_directory()
        scratch.mkdir()
        app = self.app(scratch)
        digest = release.app_content_digest(app)
        def command(*args, operation):
            if operation == "dmg-stage":
                shutil.copytree(args[1], args[2], symlinks=True)
            if operation == "dmg-attach":
                raise release.ReleaseError("Synthetic partial attach failure.")
            return b""
        with patch.object(release, "run", side_effect=command), patch.object(release, "cleanup_dmg_mount") as cleanup:
            with self.assertRaises(release.ReleaseError):
                release.package_dmg(app, scratch / "fixture.dmg", scratch, self.context, digest)
        cleanup.assert_called_once()

    def test_readonly_mount_is_verified_before_app_inspection(self):
        scratch = release.signing_directory()
        scratch.mkdir()
        app = self.app(scratch)
        calls = []
        def command(*args, operation):
            calls.append((args, operation))
            if operation == "dmg-stage":
                shutil.copytree(args[1], args[2], symlinks=True)
            return b""
        writable_filesystem = type("FilesystemFlags", (), {"f_flag": 0})()
        with patch.object(release, "run", side_effect=command), patch.object(release, "cleanup_dmg_mount") as cleanup:
            with patch.object(Path, "is_mount", return_value=True), patch.object(release.os, "statvfs", return_value=writable_filesystem):
                with patch.object(release, "verify_dmg_contents") as inspection, self.assertRaises(release.ReleaseError):
                    release.package_dmg(app, scratch / "fixture.dmg", scratch, self.context, release.app_content_digest(app))
        inspection.assert_not_called()
        cleanup.assert_called_once()
        attach = next(args for args, operation in calls if operation == "dmg-attach")
        self.assertEqual(attach[3:], ("-readonly", "-nobrowse", "-noautoopen", "-verify", "-mountpoint", str(release.dmg_mountpoint())))
        self.assertIn("dmg-verify", [operation for _, operation in calls])

    def test_hdiutil_exit_one_is_never_accepted(self):
        result = subprocess.CompletedProcess([], 1, stdout=b"", stderr=b"synthetic private message")
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError):
                release.run("/usr/bin/hdiutil", "create", operation="dmg-create")

    def test_workflow_upload_allowlist_is_exact_and_has_no_new_privileges(self):
        workflow = (Path(release.__file__).resolve().parents[1] / ".github/workflows/preview-release.yml").read_text()
        expected = ["Preview/MoeKit-v${{ inputs.version }}-macOS.dmg",
                    "Preview/MoeKit-v${{ inputs.version }}-macOS.zip",
                    "Preview/SHA256SUMS.txt", "Preview/BUILD_INFO.json", "Preview/appcast.xml"]
        actual = [line.strip() for line in workflow.splitlines() if line.strip().startswith("Preview/")]
        self.assertEqual(actual, expected)
        self.assertNotIn("macOS-universal.zip", workflow)
        self.assertNotIn("create-dmg", workflow)
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("if: always()\n        run: python3 Scripts/preview-release.py cleanup", workflow)


class NativeFixtureCompilation(unittest.TestCase):
    def test_compiler_reopens_source_file_for_both_architectures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.CompletedProcess([], 0, stdout=b"", stderr=b"")
            hidden = {key: "synthetic-sensitive-value" for key in
                      (*release.SECRET_NAMES, "GH_TOKEN", "GITHUB_TOKEN", "ACTIONS_RUNTIME_TOKEN", "UNREVIEWED_VARIABLE")}
            allowed = {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/SyntheticXcode.app/Contents/Developer"}
            with patch.dict(os.environ, hidden | allowed, clear=True), patch.object(subprocess, "run", return_value=result) as compiler:
                compile_native_fixture(root, root / "MoeKit")
            arguments = compiler.call_args.args[0]
            self.assertEqual(arguments, ["/usr/bin/xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
                                         "-mmacosx-version-min=15.0", str(root / "fixture.c"), "-o", str(root / "MoeKit")])
            self.assertEqual((root / "fixture.c").read_text(), "int main(void) { return 0; }\n")
            self.assertNotIn("input", compiler.call_args.kwargs)
            self.assertEqual(compiler.call_args.kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(compiler.call_args.kwargs["env"], allowed)
            self.assertEqual(compiler.call_args.kwargs["timeout"], 120)

    def test_failure_reports_bounded_inert_compiler_stderr_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.CompletedProcess([], 1, stdout=b"DO-NOT-REPORT-STDOUT",
                                                 stderr=b"ld: undefined symbol: _main\n\x1b[31m" + b"x" * 9000)
            with patch.object(subprocess, "run", return_value=result), self.assertRaises(AssertionError) as failure:
                compile_native_fixture(Path(temporary), Path(temporary) / "MoeKit")
            message = str(failure.exception)
            self.assertIn("exit 1", message)
            self.assertIn("undefined symbol: _main", message)
            self.assertLessEqual(len(message), 4200)
            self.assertNotIn("\n", message)
            self.assertNotIn("\x1b", message)
            self.assertNotIn("DO-NOT-REPORT-STDOUT", message)

    def test_timeout_does_not_dump_command_or_captured_streams(self):
        with tempfile.TemporaryDirectory() as temporary:
            error = subprocess.TimeoutExpired(["synthetic-command"], 120, stderr=b"withheld output")
            with patch.object(subprocess, "run", side_effect=error), self.assertRaises(AssertionError) as failure:
                compile_native_fixture(Path(temporary), Path(temporary) / "MoeKit")
            self.assertEqual(str(failure.exception), "Synthetic universal fixture compilation timed out after 120 seconds.")


@unittest.skipUnless(sys.platform == "darwin", "Native hdiutil/universal signing integration requires macOS; no app execution")
class NativeDmgIntegration(unittest.TestCase):
    def test_each_nested_sparkle_identity_is_verified_independently(self):
        with tempfile.TemporaryDirectory(prefix="moekit-sparkle-code-test-") as name:
            root = Path(name)
            app = synthetic_app(root)
            for relative in release.EXECUTABLE_PATHS:
                compile_native_fixture(root, app / relative)
            release.sign_code_objects(app, "-")
            release.verify_code_objects(app)
            for index, (relative, _) in enumerate(release.SPARKLE_CODE):
                changed = root / f"case-{index}" / "MoeKit.app"
                shutil.copytree(app, changed, symlinks=True)
                release.run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.invalid.nested",
                            "--options", "runtime", "--timestamp=none", str(changed / relative), operation="codesign-sign")
                with self.subTest(code_object=relative), self.assertRaises(release.ReleaseError):
                    release.verify_code_objects(changed)

    def test_universal_fixture_round_trips_signed_zip_and_readonly_dmg(self):
        # This is a synthetic never-executed app, with ad-hoc signing and no
        # credentials. Avoid TemporaryDirectory: failed detach must never cause
        # recursive cleanup of its parent, even in a regression test.
        temporary = Path(tempfile.mkdtemp(prefix="moekit-dmg-test-"))
        context = release.validate_inputs(valid_environment())
        with patch.dict(os.environ, {"RUNNER_TEMP": str(temporary)}):
            try:
                app = synthetic_app(temporary)
                for relative in release.EXECUTABLE_PATHS:
                    compile_native_fixture(temporary, app / relative)
                release.sign_code_objects(app, "-")
                release.verify_app(app, context)
                release.verify_code_objects(app)
                digest = release.app_content_digest(app)
                dmg_name, zip_name = release.package_names(context)
                release.run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app),
                            str(temporary / zip_name), operation="archive-package")
                self.assertEqual(release.inspect_zip(temporary / zip_name, context), digest)
                release.run("/usr/bin/ditto", "-x", "-k", str(temporary / zip_name), str(temporary / "round-trip"),
                            operation="archive-round-trip")
                unpacked = temporary / "round-trip/MoeKit.app"
                self.assertEqual(release.app_content_digest(unpacked), digest)
                release.verify_app(unpacked, context)
                release.verify_code_objects(unpacked)
                release.package_dmg(unpacked, temporary / dmg_name, temporary, context, digest)
                self.assertTrue((temporary / dmg_name).is_file())
                self.assertFalse(release.dmg_mountpoint().exists())
            finally:
                # Reaching parent removal requires successful cleanup, not just
                # an existence check that might hide a filesystem error.
                release.cleanup_dmg_mount()
                if not release.dmg_mountpoint().exists():
                    shutil.rmtree(temporary)

    def test_native_helper_failures_are_not_hidden_by_parent_signature(self):
        # Every input is compiled here and never launched. No keychain or network.
        with tempfile.TemporaryDirectory(prefix="moekit-code-test-") as name:
            temporary = Path(name)
            app = synthetic_app(temporary)
            for relative in release.EXECUTABLE_PATHS:
                compile_native_fixture(temporary, app / relative)
            release.sign_code_objects(app, "-")
            release.verify_code_objects(app)
            entitlements = temporary / "fixture-entitlements.plist"
            entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
            context = release.validate_inputs(valid_environment())
            for helper_path, helper_id in release.HELPERS:
                for variant in ("identifier", "runtime", "entitlements", "tampered", "thin", "unsigned"):
                    with self.subTest(helper=helper_path, variant=variant):
                        altered = temporary / Path(helper_path).name / variant / "MoeKit.app"
                        shutil.copytree(app, altered, symlinks=True)
                        helper = altered / helper_path
                        if variant in {"identifier", "runtime", "entitlements"}:
                            extra = ("--entitlements", str(entitlements)) if variant == "entitlements" else ()
                            release.run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
                                        "com.invalid.helper" if variant == "identifier" else helper_id,
                                        "--options", "0" if variant == "runtime" else "runtime", "--timestamp=none",
                                        *extra, str(helper), operation="codesign-sign")
                        elif variant == "tampered":
                            with helper.open("r+b") as stream:
                                # Flip a signed Mach-O header flag in the first
                                # universal slice, not unsealed signature padding.
                                header = stream.read(24)
                                self.assertIn(header[:4], {bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")})
                                width = 8 if header[:4] == bytes.fromhex("cafebabf") else 4
                                offset = int.from_bytes(header[16:16 + width], "big") + 24
                                stream.seek(offset)
                                original = stream.read(1)
                                stream.seek(offset)
                                stream.write(bytes([original[0] ^ 0x01]))
                        elif variant == "thin":
                            thin = temporary / "thin-helper"
                            release.run("/usr/bin/lipo", str(helper), "-thin", "arm64", "-output", str(thin),
                                        operation="app-architectures")
                            thin.replace(helper)
                        else:
                            release.run("/usr/bin/codesign", "--remove-signature", str(helper), operation="codesign-sign")
                        # Re-seal the parent for valid but wrongly-configured helper
                        # signatures. The verifier must still inspect helper policy.
                        if variant in {"identifier", "runtime", "entitlements", "thin"}:
                            release.run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", release.BUNDLE_ID,
                                        "--options", "runtime", "--timestamp=none", str(altered), operation="codesign-sign")
                        if variant == "thin":
                            with self.assertRaises(release.ReleaseError):
                                release.verify_app(altered, context)
                        else:
                            release.verify_app(altered, context)
                            with self.assertRaises(release.ReleaseError):
                                release.verify_code_objects(altered)
                        if variant == "entitlements":
                            # Production re-signing must remove the old helper's
                            # entitlements, rather than preserve them implicitly.
                            release.sign_code_objects(altered, "-")
                            release.verify_app(altered, context)
                            release.verify_code_objects(altered)



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


class CodesignCategories(unittest.TestCase):
    """Pattern fixtures contain only synthetic data, never real signing logs."""

    def test_every_allowlisted_pattern_has_coverage(self):
        labels = [category for category, _ in release.CODESIGN_ERROR_PATTERNS]
        self.assertEqual(len(labels), len(set(labels)))
        for category, patterns in release.CODESIGN_ERROR_PATTERNS:
            self.assertRegex(category, r"^[a-z]+(?:-[a-z]+)*$")
            self.assertTrue(patterns)
            for pattern in patterns:
                with self.subTest(category=category, pattern=pattern):
                    matches = release.codesign_failure_categories(pattern.upper())
                    self.assertIn(category, matches)
                    self.assertLessEqual(set(matches), set(labels))

    def test_reports_all_matches_in_fixed_order(self):
        streams = b"\n".join(patterns[0] for _, patterns in release.CODESIGN_ERROR_PATTERNS)
        self.assertEqual(release.codesign_failure_categories(streams),
                         tuple(category for category, _ in release.CODESIGN_ERROR_PATTERNS))

    def test_unrecognized_private_text_uses_fixed_fallback(self):
        for stream in (b"", b"synthetic-secret /private/path Person Name A123456789", b"\xff\xfe::error::synthetic-injection"):
            with self.subTest(stream=stream):
                self.assertEqual(release.codesign_failure_categories(stream), ("unclassified",))

    def test_malformed_bytes_never_require_decoding(self):
        self.assertEqual(release.codesign_failure_categories(b"\xffprivate\xfe errSecInternalComponent"),
                         ("security-internal",))

    def test_failed_signing_reports_categories_without_any_captured_text(self):
        marker = "synthetic-signing-private-data-DO-NOT-LOG"
        stderr = (marker + " /private/path: unable to build chain to self-signed root for signer \"" +
                  marker + "\"\n/private/path: errSecInternalComponent").encode()
        stdout = (marker + " resource fork, Finder information, or similar detritus not allowed").encode()
        result = subprocess.CompletedProcess([marker], 1, stdout=stdout, stderr=stderr)
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(release.subprocess, "run", return_value=result), redirect_stdout(output), redirect_stderr(errors):
            with self.assertRaises(release.ReleaseError) as caught:
                release.run(marker, marker, operation="codesign-sign")
        self.assertEqual(str(caught.exception),
                         "Operation codesign-sign failed (exit code 1; categories=certificate-chain,security-internal); command details withheld.")
        self.assertNotIn(marker, str(caught.exception))
        self.assertNotIn("/private/path", str(caught.exception))
        self.assertNotIn("bundle-metadata", str(caught.exception), "Only stderr should be classified")
        self.assertEqual(output.getvalue() + errors.getvalue(), "")

    def test_successful_signing_does_not_emit_diagnostics(self):
        result = subprocess.CompletedProcess([], 0, stdout=b"synthetic-private-output", stderr=b"errSecInternalComponent")
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(release.subprocess, "run", return_value=result), redirect_stdout(output), redirect_stderr(errors):
            returned = release.captured_run("synthetic-command", operation="codesign-sign")
        self.assertIs(returned, result)
        self.assertEqual(output.getvalue() + errors.getvalue(), "")

    def test_other_operations_do_not_classify_private_output(self):
        result = subprocess.CompletedProcess([], 1, stdout=b"", stderr=b"errSecInternalComponent")
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError) as caught:
                release.run("synthetic-command", operation="p12-import")
        self.assertEqual(str(caught.exception), "Operation p12-import failed (exit code 1); command details withheld.")


class KeychainMembershipDiagnostic(unittest.TestCase):
    def test_reports_only_fixed_boolean_without_mutating_search_list(self):
        keychain = Path("/tmp/synthetic private folder/private-identity.keychain-db")
        listings = ((f'"{keychain}"\n"/tmp/private-login.keychain-db"', "true"),
                    ('"/tmp/private-login.keychain-db"', "false"))
        for listing, expected in listings:
            with self.subTest(expected=expected):
                output, errors = io.StringIO(), io.StringIO()
                with patch.object(release, "text_run", return_value=listing) as command:
                    with redirect_stdout(output), redirect_stderr(errors):
                        release.report_keychain_search_membership(keychain)
                command.assert_called_once_with("/usr/bin/security", "list-keychains", "-d", "user",
                                                operation="keychain-search-list-check")
                self.assertEqual(output.getvalue(), "temporary_keychain_in_search_list=" + expected + "\n")
                self.assertEqual(errors.getvalue(), "")
                self.assertNotIn("private", output.getvalue())

    def test_membership_normalizes_paths_without_printing_them(self):
        keychain = Path("/tmp/synthetic-parent/../synthetic-keychain.keychain-db")
        output = io.StringIO()
        with patch.object(release, "text_run", return_value='"/tmp/synthetic-keychain.keychain-db"'):
            with redirect_stdout(output):
                release.report_keychain_search_membership(keychain)
        self.assertEqual(output.getvalue(), "temporary_keychain_in_search_list=true\n")

    def test_membership_command_failure_hides_captured_data(self):
        marker = "synthetic-keychain-private-name"
        result = subprocess.CompletedProcess([marker], 2, stdout=marker.encode(), stderr=marker.encode())
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(release.subprocess, "run", return_value=result), redirect_stdout(output), redirect_stderr(errors):
            with self.assertRaises(release.ReleaseError) as caught:
                release.report_keychain_search_membership(Path("/tmp/" + marker))
        self.assertEqual(str(caught.exception), "Operation keychain-search-list-check failed (exit code 2); command details withheld.")
        self.assertEqual(output.getvalue() + errors.getvalue(), "")
        self.assertNotIn(marker, str(caught.exception))


class KeychainSearchRegistration(unittest.TestCase):
    def test_registers_temporary_keychain_preserving_original_entries_and_order(self):
        keychain = Path("/tmp/synthetic-signing.keychain-db")
        original = ["/tmp/synthetic login.keychain-db", "/tmp/synthetic-second.keychain-db"]
        saved = original.copy()
        events = []
        with patch.object(release, "run", side_effect=lambda *args, **kwargs: events.append(("register", args, kwargs))):
            with patch.object(release, "report_keychain_search_membership", side_effect=lambda path: events.append(("check", path)) or True):
                release.register_signing_keychain(keychain, original)
        self.assertEqual(original, saved)
        self.assertEqual(events, [
            ("register", ("/usr/bin/security", "list-keychains", "-d", "user", "-s", str(keychain), *saved),
             {"operation": "keychain-register-search-list"}),
            ("check", keychain),
        ])

    def test_empty_original_list_still_registers_only_temporary_keychain(self):
        keychain = Path("/tmp/synthetic-signing.keychain-db")
        with patch.object(release, "run") as command, patch.object(release, "report_keychain_search_membership", return_value=True):
            release.register_signing_keychain(keychain, [])
        command.assert_called_once_with("/usr/bin/security", "list-keychains", "-d", "user", "-s", str(keychain),
                                        operation="keychain-register-search-list")

    def test_missing_membership_after_registration_fails_closed(self):
        with patch.object(release, "run") as command, patch.object(release, "report_keychain_search_membership", return_value=False):
            with self.assertRaises(release.ReleaseError) as caught:
                release.register_signing_keychain(Path("/tmp/synthetic-signing.keychain-db"), [])
        self.assertEqual(command.call_count, 1)
        self.assertEqual(str(caught.exception),
                         "Temporary signing keychain is absent from the user search list after registration; signing stopped.")

    def test_registration_failure_does_not_disclose_paths_or_command_output(self):
        marker = "synthetic-registration-private-data"
        result = subprocess.CompletedProcess([marker], 1, stdout=marker.encode(), stderr=marker.encode())
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(release.subprocess, "run", return_value=result), patch.object(release, "report_keychain_search_membership") as readback:
            with redirect_stdout(output), redirect_stderr(errors), self.assertRaises(release.ReleaseError) as caught:
                release.register_signing_keychain(Path("/tmp/" + marker), ["/tmp/" + marker])
        readback.assert_not_called()
        self.assertEqual(str(caught.exception),
                         "Operation keychain-register-search-list failed (exit code 1); command details withheld.")
        self.assertNotIn(marker, str(caught.exception))
        self.assertEqual(output.getvalue() + errors.getvalue(), "")

    def exercise_cleanup_after_failure(self, *, registration_fails):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "moekit-preview-signing"
            directory.mkdir()
            keychain = directory / "preview.keychain-db"
            keychain.write_bytes(b"synthetic fixture; not a real keychain")
            original = ["/tmp/synthetic original-one.keychain-db", "/tmp/synthetic-original-two.keychain-db"]
            release.write_json(directory / "original-keychains.json", original)
            calls = []
            def command(*args, operation):
                calls.append((operation, args))
                if registration_fails and operation == "keychain-register-search-list":
                    raise release.ReleaseError("Synthetic registration failure.")
                return b""
            with patch.dict(os.environ, {"RUNNER_TEMP": temp}), patch.object(release, "run", side_effect=command):
                with patch.object(release, "report_keychain_search_membership", return_value=True):
                    with self.assertRaises(release.ReleaseError):
                        try:
                            release.register_signing_keychain(keychain, original)
                            raise release.ReleaseError("Synthetic signing failure.")
                        finally:
                            release.cleanup()
            self.assertEqual([operation for operation, _ in calls],
                             ["keychain-register-search-list", "keychain-delete", "keychain-restore-search-list"])
            self.assertEqual(calls[-1][1], ("/usr/bin/security", "list-keychains", "-d", "user", "-s", *original))
            self.assertFalse(directory.exists())

    def test_cleanup_restores_exact_list_after_later_signing_failure(self):
        self.exercise_cleanup_after_failure(registration_fails=False)

    def test_cleanup_restores_exact_list_after_registration_failure(self):
        self.exercise_cleanup_after_failure(registration_fails=True)

    def test_registration_is_immediately_before_signing_inside_cleanup_guard(self):
        tree = ast.parse(Path(release.__file__).read_text())
        sign = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "sign")
        guarded = next(node for node in sign.body if isinstance(node, ast.Try))
        registration_index = next(index for index, node in enumerate(guarded.body)
                                  if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call) and
                                  isinstance(node.value.func, ast.Name) and node.value.func.id == "register_signing_keychain")
        following = guarded.body[registration_index + 1].value
        self.assertEqual(following.func.id, "sign_code_objects")
        self.assertEqual([node.id for node in following.args], ["app", "identity", "keychain"])
        self.assertEqual(len(guarded.finalbody), 1)
        self.assertEqual(guarded.finalbody[0].value.func.id, "cleanup")


if __name__ == "__main__":
    unittest.main()
