#!/usr/bin/env python3
"""Fail-closed, manually dispatched development preview release helpers.

No signing secrets are passed to build tools or written to the checkout. Commands
that handle signing data have captured output and sanitized failures. This script
never runs the app and never uploads a P12, keychain, certificate dump, or log.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import importlib.util
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
HELPER_PATH = "Contents/MacOS/MoleAnalysisSupervisor"
HELPER_ID = BUNDLE_ID + ".MoleAnalysisSupervisor"
GIT_HELPER_PATH = "Contents/MacOS/GitObjectInspector"
GIT_HELPER_ID = BUNDLE_ID + ".GitObjectInspector"
GIT_TRANSPORT_HELPER_PATH = "Contents/MacOS/GitRemoteTransport"
GIT_TRANSPORT_HELPER_ID = BUNDLE_ID + ".GitRemoteTransport"
# Exact reviewed original helpers only. Never broaden this from bundle discovery.
HELPERS = ((HELPER_PATH, HELPER_ID), (GIT_HELPER_PATH, GIT_HELPER_ID),
           (GIT_TRANSPORT_HELPER_PATH, GIT_TRANSPORT_HELPER_ID))
SPARKLE_ROOT = "Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_ROOT = SPARKLE_ROOT + "/Versions/B"
SPARKLE_CODE = (
    (SPARKLE_VERSION_ROOT + "/XPCServices/Installer.xpc", "org.sparkle-project.InstallerLauncher"),
    (SPARKLE_VERSION_ROOT + "/XPCServices/Downloader.xpc", "org.sparkle-project.DownloaderService"),
    (SPARKLE_VERSION_ROOT + "/Autoupdate", "org.sparkle-project.Sparkle.Autoupdate"),
    (SPARKLE_VERSION_ROOT + "/Updater.app", "org.sparkle-project.Sparkle.Updater"),
    (SPARKLE_ROOT, "org.sparkle-project.Sparkle"),
)
SPARKLE_EXECUTABLES = frozenset(SPARKLE_VERSION_ROOT + "/" + path for path in (
    "Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
    "XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"))
ALL_CODE = HELPERS + SPARKLE_CODE
VERIFIED_CODE_PATHS = [relative for relative, _ in ALL_CODE] + ["."]
EXECUTABLE_PATHS = frozenset({"Contents/MacOS/MoeKit", *(relative for relative, _ in HELPERS), *SPARKLE_EXECUTABLES})
POLICY_ROOT = Path(__file__).resolve().parents[1] / "Configurations"
SPARKLE_LAYOUT = json.loads((POLICY_ROOT / "Sparkle-layout.json").read_text())
SPARKLE_LINKS = {SPARKLE_ROOT + "/" + name: target for name, target in SPARKLE_LAYOUT["links"].items()}
SPARKLE_FILES = {SPARKLE_ROOT + "/" + name: digest for name, digest in SPARKLE_LAYOUT["files"].items()}
SPARKLE_DIRECTORIES = {SPARKLE_ROOT, *(SPARKLE_ROOT + "/" + name for name in SPARKLE_LAYOUT["directories"])}
SPARKLE_SIGNATURE_FILES = {name for name in SPARKLE_FILES if name.endswith("/_CodeSignature/CodeResources")}
SPARKLE_OPTIONAL = {SPARKLE_ROOT + "/" + name for name in ("Headers", "PrivateHeaders", "Modules")}
SPARKLE_OPTIONAL.update(name for name in SPARKLE_FILES | SPARKLE_LINKS if any(
    name == SPARKLE_VERSION_ROOT + "/" + part or name.startswith(SPARKLE_VERSION_ROOT + "/" + part + "/")
    for part in ("Headers", "PrivateHeaders", "Modules")))
ARCHITECTURES = ("arm64", "x86_64")
SECRET_NAMES = ("SIGNING_CERTIFICATE_P12", "SIGNING_CERTIFICATE_PASSWORD", "DEVELOPMENT_TEAM", "SPARKLE_ED_PRIVATE_KEY", "SPARKLE_ED_PUBLIC_KEY")
VERSION_RE = re.compile(r"(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})-preview\.(0|[1-9][0-9]{0,5})\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


class ReleaseError(Exception):
    """Only fixed, non-secret diagnostic text belongs in these errors."""


def appcast_module():
    name = "moekit_sparkle_appcast"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("sparkle_appcast.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


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
    "keychain-search-list-check", "keychain-register-search-list",
    "dmg-stage", "dmg-create", "dmg-verify", "dmg-attach", "dmg-detach",
})


# These are diagnostic hints, not proof of cause. Never return matched text.
# Byte matching also keeps malformed or private stderr out of decoded messages.
CODESIGN_ERROR_PATTERNS = (
    ("certificate-chain", (b"unable to build chain to self-signed root",
                           b"cssmerr_tp_not_trusted", b"cssmerr_tp_invalid_anchor_cert")),
    ("certificate-validity", (b"cssmerr_tp_cert_expired", b"cssmerr_tp_cert_not_valid_yet",
                              b"certificate has expired", b"certificate is not yet valid")),
    ("keychain-interaction", (b"user interaction is not allowed", b"errsecinteractionnotallowed",
                              b"cssmerr_csp_no_user_interaction", b"errsecauthfailed",
                              b"authorization failed")),
    ("identity-access", (b"no identity found", b"the specified item could not be found in the keychain",
                          b"errsecitemnotfound", b"the specified keychain could not be found",
                          b"errsecnosuchkeychain")),
    ("bundle-metadata", (b"resource fork, finder information, or similar detritus not allowed",)),
    ("bundle-layout", (b"bundle format unrecognized, invalid, or unsuitable",
                        b"unsealed contents present in the bundle root",
                        b"bundle format is ambiguous", b"main executable failed strict validation")),
    ("executable-format", (b"file format unrecognized, invalid, or unsuitable",
                            b"unsupported mach-o", b"invalid or unsupported format for signature")),
    ("filesystem-access", (b"permission denied", b"operation not permitted",
                            b"read-only file system", b"no such file or directory", b"not writable")),
    ("tool-arguments", (b"unrecognized option", b"unknown option", b"invalid option",
                         b"option requires an argument", b"usage: codesign", b"invalid flag")),
    ("security-internal", (b"errsecinternalcomponent",)),
)


def codesign_failure_categories(stderr: bytes) -> tuple[str, ...]:
    """Return all matching fixed labels, or a fixed fallback; never raw stderr."""
    lowered = stderr.lower()
    matches = tuple(category for category, patterns in CODESIGN_ERROR_PATTERNS
                    if any(pattern in lowered for pattern in patterns))
    return matches or ("unclassified",)


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
        categories = ""
        if operation == "codesign-sign":
            categories = "; categories=" + ",".join(codesign_failure_categories(result.stderr))
        raise ReleaseError(f"Operation {operation} failed (exit code {result.returncode}{categories}); command details withheld.")
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
            "build_number": appcast_module().build_number(version),
            "run_id": environment["GITHUB_RUN_ID"],
            "run_number": environment["GITHUB_RUN_NUMBER"],
            "run_attempt": environment["GITHUB_RUN_ATTEMPT"]}


def validate() -> dict[str, str]:
    context = validate_inputs(dict(os.environ))
    require(text_run("git", "rev-parse", "HEAD", operation="source-read") == context["source_sha"], "Checkout does not match the reviewed source SHA.")
    # Untracked build products are allowed; tracked source modifications are not.
    run("git", "diff", "--exit-code", "HEAD", "--", operation="source-clean")
    release_notes(context)
    validate_public_key_input()
    return context


def validate_public_key_input() -> str:
    public_key = appcast_module().load_config(require_key=True)["publicEDKey"]
    supplied = os.environ.get("SPARKLE_ED_PUBLIC_KEY", "")
    require(bool(supplied), "Missing or empty Actions secret: SPARKLE_ED_PUBLIC_KEY")
    require(supplied == public_key, "SPARKLE_ED_PUBLIC_KEY differs from the committed public key; review the public-key configuration.")
    return public_key


def release_notes(context: dict[str, str]) -> tuple[str, str]:
    """Read the reviewed version's plain Markdown; support only this tiny schema.

    This is deliberately not a general YAML parser. Reject ambiguous YAML rather
    than interpret tags, aliases, duplicate keys, nested values, or block scalars.
    The source remains unreleased until publication is independently verified.
    """
    version = context["version"]
    require(bool(VERSION_RE.fullmatch(version)), "Invalid release-note version.")
    path = Path("website/content/changelog") / (version + ".md")
    require(path.is_file() and not path.is_symlink(), "Canonical version notes are missing or unsafe.")
    raw = path.read_bytes()
    require(len(raw) <= 64 * 1024, "Canonical version notes are unexpectedly large.")
    lines = raw.decode("utf-8", errors="strict").splitlines()
    require(bool(lines) and lines[0] == "---", "Version notes require a small YAML frontmatter.")
    closing = next((index for index, line in enumerate(lines[1:], 1) if line == "---"), None)
    require(closing is not None and 1 < closing <= 8, "Invalid version-note frontmatter boundary.")
    fields = {}
    for line in lines[1:closing]:
        match = re.fullmatch(r"(title|version|description|status|date|sourceCommit|releaseUrl): (.+)", line)
        require(match is not None and match[1] not in fields, "Unsupported or duplicate version-note frontmatter.")
        key, value = match.groups()
        if key == "status":
            require(value in {"unreleased", "prerelease"}, "Invalid version-note status.")
        elif key == "sourceCommit" and SHA_RE.fullmatch(value):
            pass
        else:
            require(value.startswith('"') and value.endswith('"'), "Version-note strings must use one-line double quotes.")
            try:
                value = json.loads(value)
            except ValueError:
                raise ReleaseError("Invalid quoted version-note value.") from None
            require(isinstance(value, str) and bool(value.strip()) and
                    all(ord(char) >= 32 for char in value), "Invalid quoted version-note value.")
        fields[key] = value
    require({"title", "version", "description", "status"} <= fields.keys(), "Required version-note metadata is missing.")
    require(fields["version"] == version, "Version-note metadata does not match the release version.")
    published_fields = {"date", "sourceCommit", "releaseUrl"}
    if fields["status"] == "unreleased":
        require(not published_fields.intersection(fields), "Unreleased notes must not claim publication metadata.")
    else:
        require(published_fields <= fields.keys(), "Published notes require verified publication metadata.")
        require(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", fields["date"]) is not None,
                "Invalid version-note date.")
        try:
            datetime.date.fromisoformat(fields["date"])
        except ValueError:
            raise ReleaseError("Invalid version-note date.") from None
        require(fields["sourceCommit"] == context["source_sha"] and
                fields["releaseUrl"] == f"https://github.com/{REPOSITORY}/releases/tag/v{version}",
                "Version-note publication provenance mismatch.")
    body = "\n".join(lines[closing + 1:]).strip()
    require(bool(body) and "\x00" not in body, "Version-note Markdown body is missing or invalid.")
    return body, hashlib.sha256(raw).hexdigest()


def package_names(context: dict[str, str]) -> tuple[str, str]:
    stem = f"MoeKit-v{context['version']}-macOS"
    return stem + ".dmg", stem + ".zip"


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
    require(info.get("CFBundleVersion") == context.get("build_number", context["run_number"]), "Unexpected app build number.")
    require(info.get("LSMinimumSystemVersion") == "15.0", "Unexpected macOS deployment target.")
    require("NSMainStoryboardFile" not in info and "NSMainNibFile" not in info,
            "SwiftUI-only app must not declare a main storyboard or nib.")
    config = appcast_module().load_config()
    require(SPARKLE_LAYOUT["version"] == config["version"] and SPARKLE_LAYOUT["revision"] == config["revision"] and
            SPARKLE_LAYOUT["package_sha256"] == config["checksum"], "Sparkle layout and package pins disagree.")
    require(info.get("SUFeedURL") == config["feedURL"] and info.get("SUPublicEDKey") == config["publicEDKey"],
            "App update feed or public key differs from the reviewed configuration.")
    policy = {"SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                       "SUSignedFeedFailureExpirationInterval": 0, "SUAutomaticallyUpdate": False,
                       "SUEnableSystemProfiling": False, "SUEnableJavaScript": False}
    require({key for key in info if key.startswith("SU")} == set(policy) | {"SUFeedURL", "SUPublicEDKey"},
            "Unexpected Sparkle update configuration key.")
    for key, value in policy.items():
        require(type(info.get(key)) is type(value) and info[key] == value,
                "App update security settings differ from the reviewed policy.")


def verify_provenance(info: dict, context: dict[str, str]) -> None:
    validate_info(info, context)
    require(info.get("MoeKitSourceCommit") == context["source_sha"], "App source provenance mismatch.")
    require(info.get("MoeKitPreviewVersion") == context["version"], "App preview version mismatch.")
    require(info.get("MoeKitBuildRunID") == context["run_id"] and
            info.get("MoeKitBuildRunAttempt") == context["run_attempt"], "App build-run provenance mismatch.")


def verify_link(relative: str, target: str) -> None:
    require(SPARKLE_LINKS.get(relative) == target, "Unexpected app symlink or link target.")


def verify_sparkle_inventory(files: set[str], links: set[str]) -> None:
    require(set(SPARKLE_FILES) - SPARKLE_OPTIONAL - SPARKLE_SIGNATURE_FILES <= files,
            "Required pinned Sparkle framework content is missing.")
    require(set(SPARKLE_LINKS) - SPARKLE_OPTIONAL <= links,
            "Required pinned Sparkle framework links are missing.")
    # Optional development headers/modules may be removed by standard Xcode copy
    # phases. Never accept a remaining link whose exact official target is absent.
    for relative in links & SPARKLE_OPTIONAL:
        group = relative.rsplit("/", 1)[-1]
        require(any(name.startswith(SPARKLE_VERSION_ROOT + "/" + group + "/") for name in files),
                "Optional Sparkle header or module link is dangling.")


def verify_upstream_sparkle(app: Path) -> None:
    """Before our re-signing, prove copied vendor bytes match the pinned archive.

    Run only on unsigned archives; code signatures necessarily change afterward.
    Bundle structure and all-file/link digests are checked again after signing.
    """
    for relative, expected in SPARKLE_FILES.items():
        path = app / relative
        if relative in SPARKLE_OPTIONAL and not path.exists():
            continue
        require(path.is_file() and not path.is_symlink() and sha256(path) == expected,
                "Embedded Sparkle bytes differ at reviewed path: " + relative)


def verify_bundle_entry(relative: str, *, directory: bool, mode: int, magic: bytes) -> None:
    """The release contains the app, two original helpers and pinned Sparkle.

    Apply the same layout policy before signing and before unpacking ZIP input.
    Paths here have already been checked for traversal and canonical spelling.
    """
    parts = PurePosixPath(relative).parts
    require(bool(parts) and parts[0] == "Contents", "Unexpected app bundle root entry.")
    if len(parts) == 1:
        require(directory, "App Contents must be a directory.")
        return
    if relative == "Contents/Frameworks":
        require(directory, "Frameworks must be a directory.")
        return
    if relative.startswith("Contents/Frameworks/"):
        require((directory and relative in SPARKLE_DIRECTORIES) or
                (not directory and relative in SPARKLE_FILES),
                "Unexpected path in the pinned Sparkle framework.")
        if not directory:
            if relative in SPARKLE_EXECUTABLES:
                require(magic in MACHO_MAGICS and bool(mode & 0o111), "Expected Sparkle executable is not Mach-O code.")
            else:
                require(magic not in MACHO_MAGICS and not mode & 0o111, "Unexpected executable Sparkle resource.")
        return
    require(parts[1] in {"Info.plist", "PkgInfo", "MacOS", "Resources", "_CodeSignature"},
            "Unexpected app bundle contents.")
    if parts[1] in {"Info.plist", "PkgInfo"}:
        require(len(parts) == 2 and not directory, "Unexpected bundle metadata layout.")
    elif len(parts) == 2:
        require(directory, "Expected bundle directory is not a directory.")
    if parts[1] == "MacOS" and len(parts) > 2:
        require(relative in EXECUTABLE_PATHS and not directory, "Unexpected embedded executable path.")
    if parts[1] == "_CodeSignature" and len(parts) > 2:
        require(relative == "Contents/_CodeSignature/CodeResources" and not directory,
                "Unexpected code signature layout.")
    if directory:
        require(not any(part.lower().endswith((".app", ".framework", ".xpc", ".appex", ".plugin", ".bundle"))
                        for part in parts), "Unexpected nested code bundle.")
    elif relative in EXECUTABLE_PATHS:
        require(magic in MACHO_MAGICS and bool(mode & 0o111), "Expected executable is not executable Mach-O code.")
    else:
        require(magic not in MACHO_MAGICS and not mode & 0o111,
                "Unexpected embedded executable; review nested-code signing before releasing.")


def verify_app(app: Path, context: dict[str, str], *, provenance: bool = True) -> None:
    require(app.is_dir() and not app.is_symlink(), "App bundle is missing or unsafe.")
    files, links = set(), set()
    # Inspect links and layout before opening metadata or executable paths.
    for path in app.rglob("*"):
        mode = path.lstat().st_mode
        relative = path.relative_to(app).as_posix()
        if stat.S_ISLNK(mode):
            verify_link(relative, os.readlink(path)); links.add(relative)
            continue
        require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), "Unexpected special file in app bundle.")
        magic = b""
        if stat.S_ISREG(mode):
            with path.open("rb") as stream:
                magic = stream.read(4)
            files.add(relative)
        verify_bundle_entry(relative, directory=stat.S_ISDIR(mode), mode=mode, magic=magic)
    require(EXECUTABLE_PATHS <= files, "The app and reviewed helper executables are required.")
    verify_sparkle_inventory(files, links)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if provenance:
        verify_provenance(info, context)
    else:
        validate_info(info, context)
    for relative in sorted(EXECUTABLE_PATHS):
        require(set(text_run("/usr/bin/lipo", "-archs", str(app / relative), operation="app-architectures").split())
                == set(ARCHITECTURES), "Each code object must contain exactly arm64 and x86_64 slices.")


def code_objects(app: Path) -> tuple[tuple[Path, str], ...]:
    # Fixed inside-out order. Never discover signable code by glob or --deep.
    return tuple((app / relative, identifier) for relative, identifier in ALL_CODE) + ((app, BUNDLE_ID),)


def sign_code_objects(app: Path, identity: str, keychain: Path | None = None) -> None:
    keychain_arguments = ("--keychain", str(keychain)) if keychain is not None else ()
    for path, identifier in code_objects(app):
        # Neither parent nor helper inherits any previous signature's entitlements.
        run("/usr/bin/codesign", "--force", "--sign", identity, *keychain_arguments,
            "--identifier", identifier, "--options", "runtime", "--timestamp=none", str(path),
            operation="codesign-sign")


def verify_code_objects(app: Path) -> None:
    """Strictly verify every exact object and architecture, even off-host."""
    for path, identifier in code_objects(app):
        run("/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
            '-R=identifier "' + identifier + '"', str(path), operation="codesign-verify")
        for architecture in ARCHITECTURES:
            result = captured_run("/usr/bin/codesign", "--display", "--architecture", architecture,
                                  "--verbose=4", str(path), operation="codesign-display")
            details = (result.stdout + result.stderr).decode("utf-8", errors="strict")
            require(re.search(r"^Identifier=" + re.escape(identifier) + r"$", details, re.MULTILINE) is not None,
                    "Unexpected code signing identifier.")
            flags = re.search(r"^CodeDirectory .*\bflags=0x([0-9a-fA-F]+)\b", details, re.MULTILINE)
            require(flags is not None and int(flags[1], 16) & 0x10000 != 0,
                    "Hardened runtime flag is missing from a code object architecture.")
            entitlements = run("/usr/bin/codesign", "--display", "--architecture", architecture,
                               "--entitlements", ":-", str(path), operation="entitlements-read")
            parsed = plistlib.loads(entitlements) if entitlements.strip() else {}
            require(parsed == {}, "Unexpected code object entitlements; a separate entitlement review is required.")


def verify_development_signatures(app: Path, identity: str, team: str, scratch: Path) -> None:
    require(re.fullmatch(r"[A-Fa-f0-9]{40}", identity) is not None and
            re.fullmatch(r"[A-Z0-9]{10}", team) is not None, "Invalid signing identity verification input.")
    verify_code_objects(app)
    for index, (path, identifier) in enumerate(code_objects(app)):
        # Match the imported certificate, Apple trust anchor, team and exact ID.
        # This supplements, rather than parses/trusts, the displayed requirement.
        requirement = (f'identifier "{identifier}" and anchor apple generic '
                       f'and certificate leaf = H"{identity}" and certificate leaf[subject.OU] = "{team}"')
        run("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R=" + requirement,
            str(path), operation="codesign-verify")
        for architecture in ARCHITECTURES:
            result = captured_run("/usr/bin/codesign", "--display", "--architecture", architecture,
                                  "--verbose=4", str(path), operation="codesign-display")
            details = (result.stdout + result.stderr).decode("utf-8", errors="strict")
            require("Signature=adhoc" not in details and
                    re.search(r"^Authority=Apple Development:", details, re.MULTILINE) is not None,
                    "A code object is not signed with an Apple Development identity.")
            require(re.search(r"^TeamIdentifier=" + re.escape(team) + r"$", details, re.MULTILINE) is not None,
                    "A code object signing certificate does not match DEVELOPMENT_TEAM.")
            prefix = str(scratch / f"signer-{index}-{architecture}-")
            run("/usr/bin/codesign", "--display", "--architecture", architecture, "--extract-certificates=" + prefix,
                str(path), operation="certificate-extract")
            require(hashlib.sha1(Path(prefix + "0").read_bytes()).hexdigest().upper() == identity.upper(),
                    "A code object signer does not match the imported identity.")


def content_digest(files: dict[str, str]) -> str:
    """Hash paths and every regular file's bytes, including the code signature."""
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def app_content_digest(app: Path) -> str:
    require(app.is_dir() and not app.is_symlink(), "App bundle is missing or unsafe.")
    files = {}
    for path in app.rglob("*"):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            target = os.readlink(path); verify_link(relative, target)
            files[relative] = "symlink:" + target
        else:
            require(path.is_file() or path.is_dir(), "Unexpected app file type.")
            if path.is_file():
                files[relative] = sha256(path)
    require(bool(files), "App bundle is empty.")
    return content_digest(files)


def inspect_zip(path: Path, context: dict[str, str], *, upstream: bool = False) -> str:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "ZIP contains duplicate paths.")
        files, links = {}, set()
        for item in archive.infolist():
            parts = PurePosixPath(item.filename).parts
            require(bool(parts) and parts[0] in {"MoeKit.app", "__MACOSX"} and
                    not item.filename.startswith("/") and ".." not in parts and "\\" not in item.filename,
                    "ZIP contains an unsafe path.")
            require(item.filename == "/".join(parts) + ("/" if item.is_dir() else ""),
                    "ZIP contains a noncanonical path.")
            require(stat.S_IFMT(item.external_attr >> 16) in {0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK},
                    "ZIP contains an unexpected special file.")
            if stat.S_ISLNK(item.external_attr >> 16):
                require(parts[0] == "MoeKit.app" and len(parts) > 1 and item.file_size <= 128,
                        "ZIP contains an unexpected symlink.")
                relative = "/".join(parts[1:])
                target = archive.read(item).decode("utf-8", errors="strict")
                verify_link(relative, target); links.add(relative)
                files[relative] = "symlink:" + target
                continue
            if parts[0] == "__MACOSX":
                # ditto's AppleDouble resource metadata only, never arbitrary payloads.
                require((len(parts) == 1 and item.is_dir()) or
                        (len(parts) > 1 and parts[1] in {"MoeKit.app", "._MoeKit.app"} and
                         (item.is_dir() or parts[-1].startswith("._"))), "ZIP contains unexpected resource metadata.")
                if not item.is_dir():
                    target = "/".join((*parts[1:-1], parts[-1][2:]))
                    require(target in names or target + "/" in names,
                            "ZIP resource metadata does not belong to the app.")
                    with archive.open(item) as stream:
                        require(stream.read(8) == bytes.fromhex("0005160700020000"),
                                "ZIP resource metadata is not AppleDouble data.")
            elif len(parts) == 1:
                require(item.is_dir(), "ZIP app root is not a directory.")
            else:
                relative = "/".join(parts[1:])
                magic = b""
                if not item.is_dir():
                    with archive.open(item) as stream:
                        magic = stream.read(4)
                        digest = hashlib.sha256(magic)
                        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                            digest.update(chunk)
                    files[relative] = digest.hexdigest()
                verify_bundle_entry(relative, directory=item.is_dir(), mode=item.external_attr >> 16, magic=magic)
        require(EXECUTABLE_PATHS <= files.keys(), "ZIP must contain the app and reviewed helper executables.")
        verify_sparkle_inventory(set(files) - links, links)
        if upstream:
            for relative, expected in SPARKLE_FILES.items():
                if relative in SPARKLE_OPTIONAL and relative not in files:
                    continue
                require(files.get(relative) == expected,
                        "Unsigned ZIP Sparkle bytes differ at reviewed path: " + relative)
        verify_provenance(plistlib.loads(archive.read("MoeKit.app/Contents/Info.plist")), context)
        return content_digest(files)


def metadata(context: dict[str, str]) -> dict:
    return {"repository": REPOSITORY, "source_sha": context["source_sha"],
            "version": context["version"], "build_number": context["build_number"],
            "run_id": context["run_id"], "run_attempt": context["run_attempt"],
            "source_url": f"https://github.com/{REPOSITORY}/commit/{context['source_sha']}",
            "run_url": f"https://github.com/{REPOSITORY}/actions/runs/{context['run_id']}",
            "bundle_id": BUNDLE_ID, "configuration": "Release", "architectures": list(ARCHITECTURES),
            "embedded_code": {relative: {"identifier": identifier, "architectures": list(ARCHITECTURES),
                                          "origin": "original MoeKit source; no bundled third-party CLI" if (relative, identifier) in HELPERS
                                          else "official Sparkle 2.10.0; pinned distribution"}
                              for relative, identifier in ALL_CODE},
            "sparkle_dependency": {key: SPARKLE_LAYOUT[key] for key in ("version", "revision", "package_sha256")},
            "minimum_macos": "15.0", "xcode": "16.4", "tuist": "4.148.3",
            "tests": "Release-configuration unit tests passed on the runner architecture with ENABLE_TESTABILITY=YES; archive built separately from the same source.",
            "native_ui_verified": False, "notarized": False, "updater": "Sparkle 2.10.0; signed feed and archive required"}


def check_metadata(info: dict, context: dict[str, str], *, signed: bool) -> None:
    for key, value in metadata(context).items():
        require(info.get(key) == value, "Artifact provenance does not match this source and run.")
    if signed:
        require(info.get("signing") == "Apple Development" and info.get("signature_verified") is True and
                info.get("expected_team_verified") is True and info.get("entitlements") == {} and
                info.get("code_objects_verified") == VERIFIED_CODE_PATHS.copy() and info.get("hardened_runtime") is True,
                "Artifact is not a verified development-signed preview.")
        require(info.get("package_verification") == {
            "dmg_integrity": True, "dmg_read_only": True,
            "dmg_app_signature_verified": True, "zip_app_signature_verified": True,
            "identical_app_content": True,
        }, "Artifact packaging has not passed all native verification checks.")
        require(re.fullmatch(r"[0-9a-f]{64}", info.get("app_content_sha256", "")) is not None,
                "App content provenance is missing or invalid.")
        hashes = info.get("artifacts")
        require(isinstance(hashes, dict) and set(hashes) == set(package_names(context)) and
                all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes.values()),
                "Artifact hash allowlist is missing or invalid.")
        _, notes_hash = release_notes(context)
        require(info.get("release_notes_sha256") == notes_hash, "Version-note provenance mismatch.")


def dmg_mountpoint() -> Path:
    # Kept OUTSIDE the recursively removed signing scratch directory. This path
    # is only ever removed with rmdir, even after failed/partial attach or detach.
    return signing_directory().parent / "moekit-preview-dmg-mount"


def cleanup_dmg_mount() -> None:
    mount = dmg_mountpoint()
    require(not mount.is_symlink(), "Unsafe DMG verification mountpoint.")
    if not mount.exists():
        return
    require(mount.is_dir(), "Unsafe DMG verification mountpoint.")
    if mount.is_mount():
        run("/usr/bin/hdiutil", "detach", str(mount), operation="dmg-detach")
    require(not mount.is_mount(), "DMG is still mounted; retained mountpoint and stopped publication.")
    # NEVER rmtree a mountpoint or a parent containing one. A failed rmdir also
    # fails closed, retaining unexpected contents for runner teardown.
    mount.rmdir()


def verify_dmg_contents(mount: Path, context: dict[str, str], expected_digest: str) -> None:
    require({entry.name for entry in mount.iterdir()} == {"MoeKit.app", "Applications"},
            "DMG contains missing or unexpected root items.")
    shortcut = mount / "Applications"
    require(shortcut.is_symlink() and os.readlink(shortcut) == "/Applications",
            "DMG must contain the exact Applications shortcut.")
    app = mount / "MoeKit.app"
    verify_app(app, context)
    require(app_content_digest(app) == expected_digest, "DMG app content differs from the verified signed ZIP.")
    verify_code_objects(app)


def package_dmg(app: Path, destination: Path, scratch: Path,
                context: dict[str, str], expected_digest: str) -> None:
    staging = scratch / "dmg-source"
    staging.mkdir(mode=0o700, exist_ok=False)
    run("/usr/bin/ditto", str(app), str(staging / "MoeKit.app"), operation="dmg-stage")
    require(app_content_digest(staging / "MoeKit.app") == expected_digest,
            "DMG staging changed the signed app content.")
    (staging / "Applications").symlink_to("/Applications")
    # No create-dmg, Finder automation, downloaded installer, or exit-1 bypass.
    run("/usr/bin/hdiutil", "create", "-volname", "MoeKit", "-srcfolder", str(staging),
        "-fs", "HFS+", "-format", "UDZO", str(destination), operation="dmg-create")
    run("/usr/bin/hdiutil", "verify", str(destination), operation="dmg-verify")
    mount = dmg_mountpoint()
    mount.mkdir(mode=0o700, exist_ok=False)
    try:
        run("/usr/bin/hdiutil", "attach", str(destination), "-readonly", "-nobrowse", "-noautoopen",
            "-verify", "-mountpoint", str(mount), operation="dmg-attach")
        require(mount.is_mount() and bool(os.statvfs(mount).f_flag & os.ST_RDONLY),
                "DMG verification requires a read-only mounted volume.")
        verify_dmg_contents(mount, context, expected_digest)
    finally:
        # Runs even when attach times out after partially mounting the image.
        cleanup_dmg_mount()


def prepare() -> None:
    context = validate()
    require(text_run("xcodebuild", "-version", operation="toolchain-version").splitlines()[0] == "Xcode 16.4", "Unexpected Xcode version.")
    app = Path("build/MoeKit.xcarchive/Products/Applications/MoeKit.app")
    verify_app(app, context, provenance=False)
    verify_upstream_sparkle(app)
    plist_path = app / "Contents/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    info.update(MoeKitSourceCommit=context["source_sha"], MoeKitPreviewVersion=context["version"],
                MoeKitBuildRunID=context["run_id"], MoeKitBuildRunAttempt=context["run_attempt"])
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    verify_app(app, context)
    directory = Path("Unsigned")
    directory.mkdir(exist_ok=False)
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(directory / "MoeKit-unsigned.zip"), operation="unsigned-package")
    inspect_zip(directory / "MoeKit-unsigned.zip", context, upstream=True)
    info = metadata(context)
    info.update(signing="unsigned intermediate; do not distribute", signature_verified=False)
    write_json(directory / "BUILD_INFO.json", info)
    write_checksums(directory, ("MoeKit-unsigned.zip", "BUILD_INFO.json"))


def signing_directory() -> Path:
    root = os.environ.get("RUNNER_TEMP", "")
    require(bool(root) and Path(root).is_absolute(), "RUNNER_TEMP is not configured.")
    return Path(root) / "moekit-preview-signing"


def cleanup() -> None:
    failed = False
    try:
        cleanup_dmg_mount()
    except (ReleaseError, OSError):
        # Still remove signing material if detach failed; the mountpoint is not
        # underneath the signing directory and is never recursively removed.
        failed = True
    directory = signing_directory()
    if not directory.exists():
        require(not failed, "DMG cleanup failed; mountpoint retained and publication stopped.")
        return
    require(directory.is_dir() and not directory.is_symlink(), "Unsafe signing cleanup directory.")
    keychain = directory / "preview.keychain-db"
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
    require(not failed, "Signing files removed, but temporary keychain or DMG cleanup failed; do not publish.")


def report_keychain_search_membership(keychain: Path) -> bool:
    """Read-only diagnostic: report membership, never keychain paths or names."""
    listed = shlex.split(text_run("/usr/bin/security", "list-keychains", "-d", "user",
                                 operation="keychain-search-list-check"))
    expected = keychain.resolve()
    present = any(Path(item).resolve() == expected for item in listed)
    print("temporary_keychain_in_search_list=true" if present else
          "temporary_keychain_in_search_list=false", flush=True)
    return present


def register_signing_keychain(keychain: Path, original: list[str]) -> None:
    """Temporarily include the signing keychain, retaining all saved entries."""
    run("/usr/bin/security", "list-keychains", "-d", "user", "-s", str(keychain), *original,
        operation="keychain-register-search-list")
    require(report_keychain_search_membership(keychain),
            "Temporary signing keychain is absent from the user search list after registration; signing stopped.")


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
    inspect_zip(directory / "MoeKit-unsigned.zip", context, upstream=True)
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
        verify_upstream_sparkle(app)
        # codesign also consults the user search list. Cleanup restores the saved list.
        # This does not change the default keychain, trust, or private-key access controls.
        register_signing_keychain(keychain, original)
        # No inherited entitlements, network timestamp, notarization or --deep signing.
        sign_code_objects(app, identity, keychain)
        verify_development_signatures(app, identity, os.environ["DEVELOPMENT_TEAM"], scratch)
        verify_app(app, context)
        destination = Path("Preview")
        destination.mkdir(exist_ok=False)
        dmg_name, zip_name = package_names(context)
        app_digest = app_content_digest(app)
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination / zip_name), operation="archive-package")
        require(inspect_zip(destination / zip_name, context) == app_digest,
                "ZIP app content differs from the verified signed app.")
        round_trip = scratch / "round-trip"
        run("/usr/bin/ditto", "-x", "-k", str(destination / zip_name), str(round_trip), operation="archive-round-trip")
        packaged_app = round_trip / "MoeKit.app"
        verify_app(packaged_app, context)
        verify_code_objects(packaged_app)
        require(app_content_digest(packaged_app) == app_digest, "ZIP round-trip changed the signed app content.")
        package_dmg(packaged_app, destination / dmg_name, scratch, context, app_digest)
        notes, notes_hash = release_notes(context)
        sparkle_info = appcast_module().sign_release(destination, context, notes)
        info = metadata(context)
        info.update(signing="Apple Development", signature_verified=True, expected_team_verified=True,
                    entitlements={}, hardened_runtime=True, secure_timestamp=False,
                    code_objects_verified=VERIFIED_CODE_PATHS.copy(),
                    gatekeeper="Unnotarized development preview; macOS may block it. Not Developer ID distribution.",
                    app_content_sha256=app_digest, release_notes_sha256=notes_hash, sparkle=sparkle_info,
                    artifacts={name: sha256(destination / name) for name in (dmg_name, zip_name)},
                    package_verification={"dmg_integrity": True, "dmg_read_only": True,
                                          "dmg_app_signature_verified": True, "zip_app_signature_verified": True,
                                          "identical_app_content": True})
        write_json(destination / "BUILD_INFO.json", info)
        write_checksums(destination, (dmg_name, zip_name, "BUILD_INFO.json", "appcast.xml"))
        check_files(destination, (dmg_name, zip_name, "BUILD_INFO.json", "appcast.xml"))
        print("Verified development signature, expected team, universal app, and identical app content in read-only DMG and ZIP.")
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


def release_body(context, info, notes, dmg_name, zip_name) -> str:
    """Keep reviewed notes intact; add only missing common limits and audit links."""
    download = f"https://github.com/{REPOSITORY}/releases/download/v{context['version']}/"
    limits = []
    if "macOS 15+" not in notes:
        limits.append("macOS 15+（Apple Silicon / Intel）")
    if "Apple Development" not in notes or not any(
            text in notes for text in ("未公证", "未经过 Apple 公证")):
        limits.append("Apple Development 开发签名，未经过 Apple 公证")
    body = (f"[下载 DMG（推荐）]({download}{dmg_name}) · [下载 ZIP]({download}{zip_name})\n\n" + notes)
    if limits:
        body += "\n\n" + "；".join(limits) + "。"
    return (body + f"\n\n[源码]({info['source_url']}) · [构建]({info['run_url']}) · "
            f"[校验和]({download}SHA256SUMS.txt) · [构建信息]({download}BUILD_INFO.json)\n")


def publish() -> None:
    context = validate()
    directory = Path("Preview")
    dmg_name, zip_name = package_names(context)
    names = (dmg_name, zip_name, "BUILD_INFO.json", "appcast.xml")
    check_files(directory, names)
    info = json.loads((directory / "BUILD_INFO.json").read_text(encoding="utf-8"))
    check_metadata(info, context, signed=True)
    appcast_module().verify_release(directory, context, info.get("sparkle"))
    require(inspect_zip(directory / zip_name, context) == info["app_content_sha256"], "ZIP app content provenance mismatch.")
    require(all(info["artifacts"][name] == sha256(directory / name) for name in (dmg_name, zip_name)),
            "Package hashes do not match verified packaging provenance.")
    notes, _ = release_notes(context)
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
    body = release_body(context, info, notes, dmg_name, zip_name)
    # Draft first: partial uploads are never presented as a completed public release.
    release = api.request("POST", base + "/releases", {"tag_name": tag, "target_commitish": context["source_sha"],
                          "name": tag, "body": body, "draft": True,
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
    # The signed feed points only at already-public, verified immutable assets.
    # A feed failure does not roll back or overwrite a completed release.
    appcast_module().publish_feed(api, directory, context)
    url = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    print("Published verified development preview: " + url)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write(f"Development-signed, unnotarized preview: {url}\n\nExact source: {context['source_sha']}\n")


def main() -> int:
    commands = {"validate": validate, "prepare": prepare, "sign": sign, "cleanup": cleanup, "publish": publish,
                "sparkle-tools": lambda: appcast_module().prepare_tools(),
                "sparkle-cleanup": lambda: appcast_module().cleanup_tools(),
                "build-settings": lambda: print(json.dumps({"build_number": validate_inputs(dict(os.environ))["build_number"],
                                    "public_key": validate_public_key_input()}))}
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in commands, "Choose validate, prepare, sign, cleanup, or publish.")
        commands[sys.argv[1]]()
    except (ReleaseError, appcast_module().SparkleError) as error:
        print("::error::" + str(error), file=sys.stderr)
        return 1
    except Exception:
        # Never dump subprocess arguments, secret-derived values, or environment.
        print("::error::Preview step failed unexpectedly; diagnostic details were withheld to protect signing data.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
