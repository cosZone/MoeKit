#!/usr/bin/env python3
"""Fail-closed, manually dispatched development preview release helpers.

No signing secrets are passed to build tools or written to the checkout. Commands
that handle signing data have captured output and sanitized failures. This script
never runs the app and never uploads a P12, keychain, certificate dump, or log.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "cosZone/MoeKit"
BUNDLE_ID = "com.yusixian.MoeKit"
SECRET_NAMES = ("SIGNING_CERTIFICATE_P12", "SIGNING_CERTIFICATE_PASSWORD", "DEVELOPMENT_TEAM")
VERSION_RE = re.compile(r"(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})-preview\.(0|[1-9][0-9]{0,5})\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


class ReleaseError(Exception):
    """Only fixed, non-secret diagnostic text belongs in these errors."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


# Diagnostics may use only reviewed, fixed operation names, never argv or input.
OPERATIONS = frozenset({
    "source-read", "source-clean", "app-architectures", "toolchain-version",
    "unsigned-package", "keychain-delete", "keychain-restore-search-list",
    "keychain-list", "keychain-create", "keychain-configure", "keychain-unlock",
    "p12-import", "keychain-partition-list", "identity-find", "archive-unpack",
    "codesign-sign", "codesign-verify", "codesign-display", "entitlements-read",
    "certificate-extract", "archive-package", "archive-round-trip",
    "codesign-verify-packaged",
})


def captured_run(*args: str, operation: str) -> subprocess.CompletedProcess:
    """Capture both streams; expose only a fixed label and numeric status."""
    require(operation in OPERATIONS, "Unrecognized local operation label.")
    environment = {key: value for key, value in os.environ.items()
                   if key not in (*SECRET_NAMES, "GH_TOKEN", "GITHUB_TOKEN")}
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=environment, check=False, timeout=120)
    except subprocess.TimeoutExpired:
        raise ReleaseError(f"Operation {operation} timed out after 120 seconds; command details withheld.") from None
    except OSError as error:
        code = str(error.errno) if isinstance(error.errno, int) else "unavailable"
        raise ReleaseError(f"Operation {operation} could not start (OS error {code}); command details withheld.") from None
    if result.returncode:
        raise ReleaseError(f"Operation {operation} failed (exit code {result.returncode}); command details withheld.")
    return result


def run(*args: str, operation: str) -> bytes:
    return captured_run(*args, operation=operation).stdout


def text_run(*args: str, operation: str) -> str:
    return run(*args, operation=operation).decode("utf-8", errors="strict").strip()


def validate_inputs(environment: dict[str, str]) -> dict[str, str]:
    version = environment.get("PREVIEW_VERSION", "")
    sha = environment.get("EXPECTED_SOURCE_SHA", "")
    require(bool(VERSION_RE.fullmatch(version)), "Use a version such as 0.1.0-preview.1, without a v prefix.")
    require(bool(SHA_RE.fullmatch(sha)), "source_sha must be exactly 40 lowercase hexadecimal characters.")
    require(environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Only manual dispatch is permitted.")
    require(environment.get("GITHUB_REPOSITORY") == REPOSITORY, "This workflow is restricted to cosZone/MoeKit.")
    default_branch = environment.get("DEFAULT_BRANCH", "")
    require(bool(default_branch) and environment.get("GITHUB_REF") == "refs/heads/" + default_branch,
            "Select the reviewed default branch, not a feature branch or tag.")
    require(environment.get("GITHUB_SHA") == sha and environment.get("WORKFLOW_SOURCE_SHA") == sha,
            "The source SHA and workflow SHA must equal the reviewed dispatch commit. Review the new HEAD before retrying.")
    for name in ("GITHUB_RUN_ID", "GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT"):
        require(bool(re.fullmatch(r"[1-9][0-9]{0,14}", environment.get(name, ""))), "Invalid GitHub run metadata.")
    return {"version": version, "source_sha": sha,
            "marketing_version": version.split("-preview.")[0],
            "run_id": environment["GITHUB_RUN_ID"],
            "run_number": environment["GITHUB_RUN_NUMBER"],
            "run_attempt": environment["GITHUB_RUN_ATTEMPT"]}


def validate() -> dict[str, str]:
    context = validate_inputs(dict(os.environ))
    require(text_run("git", "rev-parse", "HEAD", operation="source-read") == context["source_sha"], "Checkout does not match the reviewed source SHA.")
    # Untracked build products are allowed; tracked source modifications are not.
    run("git", "diff", "--exit-code", "HEAD", "--", operation="source-clean")
    return context


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_checksums(directory: Path, names: tuple[str, ...]) -> None:
    (directory / "SHA256SUMS.txt").write_text(
        "".join(f"{sha256(directory / name)}  {name}\n" for name in names), encoding="utf-8")


def check_files(directory: Path, names: tuple[str, ...]) -> None:
    require(directory.is_dir() and not directory.is_symlink(), "Artifact directory is missing or unsafe.")
    require({path.name for path in directory.iterdir()} == set(names) | {"SHA256SUMS.txt"},
            "Artifact contains missing or unexpected files.")
    for name in (*names, "SHA256SUMS.txt"):
        path = directory / name
        require(path.is_file() and not path.is_symlink(), "Artifact contains a missing or unsafe file.")
    expected = "".join(f"{sha256(directory / name)}  {name}\n" for name in names)
    require((directory / "SHA256SUMS.txt").read_text(encoding="utf-8") == expected,
            "Artifact SHA-256 checksums do not match.")


def validate_info(info: dict, context: dict[str, str]) -> None:
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected app bundle identifier.")
    require(info.get("CFBundleExecutable") == "MoeKit", "Unexpected app executable.")
    require(info.get("CFBundleShortVersionString") == context["marketing_version"], "Unexpected app marketing version.")
    require(info.get("CFBundleVersion") == context["run_number"], "Unexpected app build number.")
    require(info.get("LSMinimumSystemVersion") == "15.0", "Unexpected macOS deployment target.")


def verify_provenance(info: dict, context: dict[str, str]) -> None:
    validate_info(info, context)
    require(info.get("MoeKitSourceCommit") == context["source_sha"], "App source provenance mismatch.")
    require(info.get("MoeKitPreviewVersion") == context["version"], "App preview version mismatch.")
    require(info.get("MoeKitBuildRunID") == context["run_id"] and
            info.get("MoeKitBuildRunAttempt") == context["run_attempt"], "App build-run provenance mismatch.")


def verify_app(app: Path, context: dict[str, str], *, provenance: bool = True) -> None:
    require(app.is_dir() and not app.is_symlink(), "App bundle is missing or unsafe.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if provenance:
        verify_provenance(info, context)
    else:
        validate_info(info, context)
    executable = app / "Contents/MacOS/MoeKit"
    require(executable.is_file() and os.access(executable, os.X_OK), "App executable is missing.")
    require(set(text_run("/usr/bin/lipo", "-archs", str(executable), operation="app-architectures").split()) == {"arm64", "x86_64"},
            "The app must contain exactly arm64 and x86_64 slices.")
    # This milestone has no embedded frameworks, XPC services, helpers, or plugins.
    # New nested code requires its own explicit signing review instead of --deep signing.
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Unexpected symlink in the first-preview bundle; review packaging.")
        if path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
            require(magic not in MACHO_MAGICS or path == executable,
                    "Unexpected embedded executable; review nested-code signing before releasing.")
    require(not (app / "Contents/embedded.provisionprofile").exists(), "Unexpected provisioning profile in preview bundle.")


def inspect_zip(path: Path, context: dict[str, str]) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "ZIP contains duplicate paths.")
        for item in archive.infolist():
            parts = PurePosixPath(item.filename).parts
            require(bool(parts) and parts[0] in {"MoeKit.app", "__MACOSX"} and
                    not item.filename.startswith("/") and ".." not in parts and "\\" not in item.filename,
                    "ZIP contains an unsafe path.")
            require(not stat.S_ISLNK(item.external_attr >> 16), "ZIP contains an unexpected symlink.")
        verify_provenance(plistlib.loads(archive.read("MoeKit.app/Contents/Info.plist")), context)


def metadata(context: dict[str, str]) -> dict:
    return {"repository": REPOSITORY, "source_sha": context["source_sha"],
            "version": context["version"], "build_number": context["run_number"],
            "run_id": context["run_id"], "run_attempt": context["run_attempt"],
            "source_url": f"https://github.com/{REPOSITORY}/commit/{context['source_sha']}",
            "run_url": f"https://github.com/{REPOSITORY}/actions/runs/{context['run_id']}",
            "bundle_id": BUNDLE_ID, "configuration": "Release", "architectures": ["arm64", "x86_64"],
            "minimum_macos": "15.0", "xcode": "16.4", "tuist": "4.148.3",
            "tests": "Release-configuration unit tests passed on the runner architecture with ENABLE_TESTABILITY=YES; archive built separately from the same source.",
            "native_ui_verified": False, "notarized": False, "updater": False}


def check_metadata(info: dict, context: dict[str, str], *, signed: bool) -> None:
    for key, value in metadata(context).items():
        require(info.get(key) == value, "Artifact provenance does not match this source and run.")
    if signed:
        require(info.get("signing") == "Apple Development" and info.get("signature_verified") is True and
                info.get("expected_team_verified") is True and info.get("entitlements") == {},
                "Artifact is not a verified development-signed preview.")


def prepare() -> None:
    context = validate()
    require(text_run("xcodebuild", "-version", operation="toolchain-version").splitlines()[0] == "Xcode 16.4", "Unexpected Xcode version.")
    app = Path("build/MoeKit.xcarchive/Products/Applications/MoeKit.app")
    verify_app(app, context, provenance=False)
    plist_path = app / "Contents/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    info.update(MoeKitSourceCommit=context["source_sha"], MoeKitPreviewVersion=context["version"],
                MoeKitBuildRunID=context["run_id"], MoeKitBuildRunAttempt=context["run_attempt"])
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    verify_app(app, context)
    directory = Path("Unsigned")
    directory.mkdir(exist_ok=False)
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(directory / "MoeKit-unsigned.zip"), operation="unsigned-package")
    inspect_zip(directory / "MoeKit-unsigned.zip", context)
    info = metadata(context)
    info.update(signing="unsigned intermediate; do not distribute", signature_verified=False)
    write_json(directory / "BUILD_INFO.json", info)
    write_checksums(directory, ("MoeKit-unsigned.zip", "BUILD_INFO.json"))


def signing_directory() -> Path:
    root = os.environ.get("RUNNER_TEMP", "")
    require(bool(root) and Path(root).is_absolute(), "RUNNER_TEMP is not configured.")
    return Path(root) / "moekit-preview-signing"


def cleanup() -> None:
    directory = signing_directory()
    if not directory.exists():
        return
    require(directory.is_dir() and not directory.is_symlink(), "Unsafe signing cleanup directory.")
    keychain = directory / "preview.keychain-db"
    failed = False
    if keychain.exists():
        try:
            run("/usr/bin/security", "delete-keychain", str(keychain), operation="keychain-delete")
        except ReleaseError:
            failed = True
    original = directory / "original-keychains.json"
    if original.exists():
        try:
            items = json.loads(original.read_text(encoding="utf-8"))
            require(isinstance(items, list) and all(isinstance(item, str) for item in items), "Invalid keychain cleanup state.")
            run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *items, operation="keychain-restore-search-list")
        except (ReleaseError, ValueError):
            failed = True
    shutil.rmtree(directory)
    require(not failed, "Temporary files removed, but keychain cleanup reported an error; do not publish.")


def sign() -> None:
    context = validate()
    for name in SECRET_NAMES:
        # The only secret-preflight output is a missing secret's *name*.
        require(bool(os.environ.get(name)), "Missing or empty Actions secret: " + name)
    require(bool(re.fullmatch(r"[A-Z0-9]{10}", os.environ["DEVELOPMENT_TEAM"])), "DEVELOPMENT_TEAM must be a valid 10-character Team ID.")
    directory = Path("Unsigned")
    check_files(directory, ("MoeKit-unsigned.zip", "BUILD_INFO.json"))
    info = json.loads((directory / "BUILD_INFO.json").read_text(encoding="utf-8"))
    check_metadata(info, context, signed=False)
    inspect_zip(directory / "MoeKit-unsigned.zip", context)
    scratch = signing_directory()
    scratch.mkdir(mode=0o700, exist_ok=False)
    try:
        original = shlex.split(text_run("/usr/bin/security", "list-keychains", "-d", "user", operation="keychain-list"))
        write_json(scratch / "original-keychains.json", original)
        keychain = scratch / "preview.keychain-db"
        password = secrets.token_urlsafe(48)
        p12 = scratch / "certificate.p12"
        try:
            decoded = base64.b64decode("".join(os.environ["SIGNING_CERTIFICATE_P12"].split()), validate=True)
        except ValueError:
            raise ReleaseError("SIGNING_CERTIFICATE_P12 is not valid base64.") from None
        require(0 < len(decoded) < 4 * 1024 * 1024, "P12 payload is empty or unexpectedly large.")
        p12.write_bytes(decoded)
        p12.chmod(0o600)
        run("/usr/bin/security", "create-keychain", "-p", password, str(keychain), operation="keychain-create")
        run("/usr/bin/security", "set-keychain-settings", "-lut", "900", str(keychain), operation="keychain-configure")
        run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain), operation="keychain-unlock")
        run("/usr/bin/security", "import", str(p12), "-k", str(keychain), "-P",
            os.environ["SIGNING_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", operation="p12-import")
        p12.unlink()
        run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, str(keychain), operation="keychain-partition-list")
        identities = text_run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(keychain), operation="identity-find")
        matches = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"\n]+)"', identities, re.MULTILINE)
        require(len(matches) == 1, "P12 must contain exactly one currently valid code-signing certificate with its private key.")
        identity, name = matches[0]
        require(name.startswith("Apple Development:"), "This preview expects an Apple Development certificate; other identity types require a separate review.")
        unpacked = scratch / "app"
        run("/usr/bin/ditto", "-x", "-k", str(directory / "MoeKit-unsigned.zip"), str(unpacked), operation="archive-unpack")
        app = unpacked / "MoeKit.app"
        verify_app(app, context)
        # No inherited entitlements and no --deep signing. No network timestamp or notarization.
        run("/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain),
            "--options", "runtime", "--timestamp=none", str(app), operation="codesign-sign")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app), operation="codesign-verify")
        result = captured_run("/usr/bin/codesign", "--display", "--verbose=4", str(app),
                              operation="codesign-display")
        details = (result.stdout + result.stderr).decode("utf-8", errors="strict")
        require("Signature=adhoc" not in details and "Authority=Apple Development:" in details,
                "The final app is not signed with an Apple Development identity.")
        require(re.search(r"^TeamIdentifier=" + re.escape(os.environ["DEVELOPMENT_TEAM"]) + r"$", details, re.MULTILINE) is not None,
                "The signing certificate does not match DEVELOPMENT_TEAM.")
        require("runtime" in details, "Hardened runtime flag is missing.")
        entitlements = run("/usr/bin/codesign", "--display", "--entitlements", ":-", str(app), operation="entitlements-read")
        parsed = plistlib.loads(entitlements) if entitlements.strip() else {}
        require(parsed == {}, "Unexpected app entitlements; a separate entitlement review is required.")
        prefix = str(scratch / "signer")
        run("/usr/bin/codesign", "--display", "--extract-certificates=" + prefix, str(app), operation="certificate-extract")
        require(hashlib.sha1(Path(prefix + "0").read_bytes()).hexdigest().upper() == identity.upper(),
                "The final app signer does not match the imported identity.")
        verify_app(app, context)
        destination = Path("Preview")
        destination.mkdir(exist_ok=False)
        zip_name = f"MoeKit-v{context['version']}-macOS-universal.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination / zip_name), operation="archive-package")
        inspect_zip(destination / zip_name, context)
        round_trip = scratch / "round-trip"
        run("/usr/bin/ditto", "-x", "-k", str(destination / zip_name), str(round_trip), operation="archive-round-trip")
        packaged_app = round_trip / "MoeKit.app"
        verify_app(packaged_app, context)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(packaged_app), operation="codesign-verify-packaged")
        info = metadata(context)
        info.update(signing="Apple Development", signature_verified=True, expected_team_verified=True,
                    entitlements={}, hardened_runtime=True, secure_timestamp=False,
                    gatekeeper="Unnotarized development preview; macOS may block it. Not Developer ID distribution.")
        write_json(destination / "BUILD_INFO.json", info)
        write_checksums(destination, (zip_name, "BUILD_INFO.json"))
        print("Verified Apple Development signature, expected team, empty entitlements, universal architectures, and source provenance.")
    finally:
        cleanup()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ReleaseError("Unexpected API redirect; refusing to forward credentials.")


class GitHub:
    def __init__(self) -> None:
        self.token = os.environ.get("GH_TOKEN", "")
        require(bool(self.token), "Publishing token is missing.")
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, method: str, path: str, body=None, *, upload: Path | None = None, allow_404=False):
        host = "uploads.github.com" if upload else "api.github.com"
        require(path.startswith(f"/repos/{REPOSITORY}/"), "Unexpected GitHub API target.")
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "MoeKit-preview-release"}
        if upload:
            headers["Content-Type"] = "application/octet-stream"
            data = upload.read_bytes()
        else:
            headers["Content-Type"] = "application/json"
            data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request("https://" + host + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if allow_404 and error.code == 404:
                return None
            raise ReleaseError(f"GitHub API {method} failed with HTTP {error.code}; no existing asset was overwritten.") from None
        except urllib.error.URLError:
            raise ReleaseError("GitHub API connection failed; inspect repository state before retrying.") from None


def tag_commit(api, tag: str) -> str | None:
    base = f"/repos/{REPOSITORY}"
    reference = api.request("GET", base + "/git/ref/tags/" + urllib.parse.quote(tag, safe=""), allow_404=True)
    if reference is None:
        return None
    obj = reference["object"]
    for _ in range(10):
        require(bool(SHA_RE.fullmatch(obj.get("sha", ""))), "Tag object has an invalid SHA.")
        if obj["type"] == "commit":
            return obj["sha"]
        require(obj["type"] == "tag", "Release tag does not resolve to a commit.")
        obj = api.request("GET", base + "/git/tags/" + obj["sha"])["object"]
    raise ReleaseError("Release tag has an unexpectedly deep annotated-tag chain.")



def existing_release(api, tag: str):
    base = f"/repos/{REPOSITORY}"
    published = api.request("GET", base + "/releases/tags/" + tag, allow_404=True)
    if published is not None:
        return published
    # The tag endpoint only promises published releases. Authenticated listing
    # also finds draft releases left by a cancelled/failed upload.
    page = 1
    while True:
        releases = api.request("GET", base + f"/releases?per_page=100&page={page}")
        require(isinstance(releases, list), "Unexpected release-list response.")
        for item in releases:
            if item.get("tag_name") == tag:
                return item
        if len(releases) < 100:
            return None
        page += 1


def publish() -> None:
    context = validate()
    directory = Path("Preview")
    zip_name = f"MoeKit-v{context['version']}-macOS-universal.zip"
    names = (zip_name, "BUILD_INFO.json")
    check_files(directory, names)
    info = json.loads((directory / "BUILD_INFO.json").read_text(encoding="utf-8"))
    check_metadata(info, context, signed=True)
    inspect_zip(directory / zip_name, context)
    api = GitHub()
    tag = "v" + context["version"]
    base = f"/repos/{REPOSITORY}"
    existing = existing_release(api, tag)
    require(existing is None, "A release or draft already exists for this tag. Nothing was overwritten; review it or choose a new preview version.")
    current = tag_commit(api, tag)
    require(current is None or current == context["source_sha"], "Existing tag points to a different commit; refusing to move it.")
    if current is None:
        api.request("POST", base + "/git/refs", {"ref": "refs/tags/" + tag, "sha": context["source_sha"]})
    require(tag_commit(api, tag) == context["source_sha"], "Release tag does not match the exact reviewed commit.")
    body = (f"Development-signed preview for macOS 15+ (Apple Silicon and Intel).\n\n"
            f"Source: {info['source_url']}\nBuild and tests: {info['run_url']}\n\n"
            "Signed with an Apple Development identity. NOT Developer ID signed and NOT notarized. "
            "Gatekeeper may block opening it. This is an owner/tester trial, not a supported public-distribution build.\n\n"
            "Release-configuration unit tests passed on the runner architecture with testability enabled. "
            "The universal Release archive was built separately from the same source. Native UI, VoiceOver, "
            "both-architecture execution, and privacy-permission persistence still need manual verification.\n\n"
            "Download the ZIP containing MoeKit.app; SHA256SUMS.txt covers it and BUILD_INFO.json. "
            "No automatic updater, Sparkle key, or notarization credentials are used.\n")
    # Draft first: partial uploads are never presented as a completed public release.
    release = api.request("POST", base + "/releases", {"tag_name": tag, "target_commitish": context["source_sha"],
                          "name": f"MoeKit {tag} preview", "body": body, "draft": True,
                          "prerelease": True, "make_latest": "false"})
    release_id = release.get("id")
    require(isinstance(release_id, int) and release_id > 0, "Unexpected release identifier.")
    for name in (*names, "SHA256SUMS.txt"):
        asset = api.request("POST", base + f"/releases/{release_id}/assets?name=" + urllib.parse.quote(name, safe=""), upload=directory / name)
        require(asset.get("name") == name and asset.get("size") == (directory / name).stat().st_size,
                "Uploaded release asset did not match the expected name or size; release remains a draft.")
        # Current GitHub REST responses expose sha256 digests. Fail closed if absent.
        require(asset.get("digest") == "sha256:" + sha256(directory / name),
                "Uploaded release asset digest is missing or mismatched; release remains a draft for review.")
    final_assets = api.request("GET", base + f"/releases/{release_id}/assets?per_page=100")
    require({item["name"] for item in final_assets} == set(names) | {"SHA256SUMS.txt"},
            "Unexpected release assets; release remains a draft for review.")
    require(tag_commit(api, tag) == context["source_sha"], "Release tag changed before publication; release remains a draft.")
    result = api.request("PATCH", base + f"/releases/{release_id}", {"draft": False, "prerelease": True, "make_latest": "false"})
    require(result.get("draft") is False and result.get("prerelease") is True and result.get("tag_name") == tag,
            "Could not confirm prerelease publication; inspect repository state before retrying.")
    url = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    print("Published verified development preview: " + url)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write(f"Development-signed, unnotarized preview: {url}\n\nExact source: {context['source_sha']}\n")


def main() -> int:
    commands = {"validate": validate, "prepare": prepare, "sign": sign, "cleanup": cleanup, "publish": publish}
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in commands, "Choose validate, prepare, sign, cleanup, or publish.")
        commands[sys.argv[1]]()
    except ReleaseError as error:
        print("::error::" + str(error), file=sys.stderr)
        return 1
    except Exception:
        # Never dump subprocess arguments, secret-derived values, or environment.
        print("::error::Preview step failed unexpectedly; diagnostic details were withheld to protect signing data.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
