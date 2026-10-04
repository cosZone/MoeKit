"""Pinned Sparkle signing and public-key-only release/feed verification.

This module never creates signing keys or stores a private key. Production
signing uses only the checksum-pinned official macOS tool, with captured stdin.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY = "cosZone/MoeKit"
FEED_URL = "https://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml"
SPARKLE_VERSION = "2.10.0"
SPARKLE_REVISION = "eef1a539a373c1f1a320624b1130fc5de7b2e100"
PACKAGE_SHA256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
SIGNER_SHA256 = "43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b"
PACKAGE_URL = ("https://github.com/sparkle-project/Sparkle/releases/download/"
               "2.10.0/Sparkle-for-Swift-Package-Manager.zip")
CONFIG_PATH = Path(__file__).resolve().parents[1] / "Configurations/Sparkle.json"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MOEKIT_NS = "https://github.com/cosZone/MoeKit/ns/update"
MAX_FEED = 512 * 1024
MAX_NOTES = 64 * 1024
MAX_ARCHIVE = 1024 * 1024 * 1024
MAX_PACKAGE = 32 * 1024 * 1024
VERSION_RE = re.compile(r"(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)(?:-preview\.([1-9][0-9]?))?\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
HASH_RE = re.compile(r"[0-9a-f]{64}\Z")
TRAILER = re.compile(br"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([1-9][0-9]{0,8})\n-->\n\Z")
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("moekit", MOEKIT_NS)


class SparkleError(Exception):
    """Fixed diagnostics only: no secrets, process output, or supplied text."""


def require(condition, message):
    if not condition:
        raise SparkleError(message)


def build_number(version: str) -> str:
    match = VERSION_RE.fullmatch(version) if isinstance(version, str) else None
    require(match is not None, "Unsupported update version format.")
    major, minor, patch = map(int, match.groups()[:3])
    preview = int(match[4]) if match[4] is not None else 99
    require(major <= 98 and (match[4] is None or preview <= 98), "Update version exceeds the supported range.")
    return f"{major * 100 + minor + 1}.{patch}.{preview}"


def _base64(value, lengths, message):
    try:
        require(isinstance(value, str), message)
        decoded = base64.b64decode(value, validate=True)
        require(len(decoded) in lengths and base64.b64encode(decoded).decode("ascii") == value, message)
        return decoded
    except (ValueError, TypeError):
        raise SparkleError(message) from None


def _read(path: Path, limit: int) -> bytes:
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= limit,
                    "Update input is not a bounded regular file.")
            data = stream.read(limit + 1)
            require(len(data) == info.st_size and len(data) <= limit, "Update input changed while reading.")
            return data
    except OSError:
        raise SparkleError("Update input could not be read safely.") from None


def _json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate JSON field in update metadata.")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError, TypeError):
        raise SparkleError("Invalid update JSON metadata.") from None


def configuration(*, require_key=True):
    value = _json(_read(CONFIG_PATH, 8192))
    require(isinstance(value, dict) and set(value) == {"version", "revision", "checksum", "feedURL", "publicEDKey"},
            "Unexpected Sparkle configuration schema.")
    require(value["version"] == SPARKLE_VERSION and value["revision"] == SPARKLE_REVISION and
            value["checksum"] == PACKAGE_SHA256 and value["feedURL"] == FEED_URL,
            "Sparkle configuration differs from the reviewed pins.")
    if require_key or value["publicEDKey"] != "":
        _base64(value["publicEDKey"], {32}, "Pinned Sparkle public key is missing or invalid.")
    return value


def load_config(*, require_key=False):
    """Read public repository configuration; blank keys are allowed for builds."""
    return configuration(require_key=require_key)


def _context(context):
    require(isinstance(context, dict), "Missing update release context.")
    expected = build_number(context.get("version"))
    require(context.get("build_number") == expected and
            context.get("marketing_version") == context["version"].split("-preview.")[0],
            "Update build or marketing version does not match the release.")
    require(isinstance(context.get("source_sha"), str) and SHA_RE.fullmatch(context["source_sha"]),
            "Invalid update source commit.")
    for key in ("run_id", "run_number", "run_attempt"):
        require(isinstance(context.get(key), str) and re.fullmatch(r"[1-9][0-9]{0,14}", context[key]),
                "Invalid update run provenance.")


def _temp_root():
    value = os.environ.get("RUNNER_TEMP", "")
    require(value and Path(value).is_absolute(), "RUNNER_TEMP must name an existing absolute directory.")
    path = Path(value)
    try:
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), "RUNNER_TEMP has unsafe ownership or type.")
        return path.resolve(strict=True)
    except OSError:
        raise SparkleError("RUNNER_TEMP is unavailable.") from None


def _write_new(path, data, mode=0o600):
    try:
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode), "wb") as stream:
            stream.write(data)
    except OSError:
        raise SparkleError("Update output already exists or cannot be written safely.") from None


def _release_directory(directory):
    path = Path(directory)
    try:
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(),
                "Update release directory has unsafe ownership or type.")
        return path.resolve(strict=True)
    except OSError:
        raise SparkleError("Update release directory is unavailable.") from None


def _run(args, *, stdin=None, cwd=None):
    # Explicit allowlist keeps signing secrets, tokens, dynamic-loader overrides,
    # and arbitrary OpenSSL configuration out of all subprocess environments.
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "OPENSSL_CONF": "/dev/null"}
    try:
        result = subprocess.run(args, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=cwd, env=environment, timeout=180, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SparkleError("Sparkle cryptographic operation could not complete; private diagnostics withheld.") from None
    require(result.returncode == 0, "Sparkle cryptographic operation failed; private diagnostics withheld.")
    return result.stdout


def _openssl():
    paths = (("/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl")
             if sys.platform == "darwin" else ("/usr/bin/openssl",) if sys.platform.startswith("linux") else ())
    for value in paths:
        path = Path(value)
        if path.is_file() and os.access(path, os.X_OK):
            version = _run([value, "version"])
            require(re.match(br"OpenSSL 3\.[0-9]+\.[0-9]+(?:\s|$)", version), "Public verification requires OpenSSL 3.")
            return value
    raise SparkleError("OpenSSL 3 was not found at an approved system or Homebrew path.")


def verify_signature(data: bytes, signature: str, public_key: str):
    public = _base64(public_key, {32}, "Invalid pinned Sparkle public key.")
    sig = _base64(signature, {64}, "Invalid Sparkle signature encoding.")
    require(isinstance(data, bytes) and 0 < len(data) <= MAX_ARCHIVE, "Signed content has an invalid size.")
    with tempfile.TemporaryDirectory(prefix="moekit-sparkle-verify-", dir=_temp_root()) as name:
        directory = Path(name)
        _write_new(directory / "public.der", bytes.fromhex("302a300506032b6570032100") + public)
        _write_new(directory / "signature.bin", sig)
        _write_new(directory / "content", data)
        _run([_openssl(), "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(directory / "public.der"),
              "-rawin", "-in", str(directory / "content"), "-sigfile", str(directory / "signature.bin")])


class _PackageRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        require(parsed.scheme == "https" and parsed.hostname in {"github.com", "release-assets.githubusercontent.com"} and
                parsed.username is None and parsed.password is None and parsed.port in {None, 443},
                "Unexpected Sparkle package download redirect.")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _owned_tools(directory):
    try:
        info = directory.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
                "Sparkle tools directory has unsafe ownership or permissions.")
        require({item.name for item in directory.iterdir()} == {"owner.json", "sign_update"}, "Unexpected Sparkle tools directory contents.")
        marker_path = directory / "owner.json"
        marker_info = marker_path.lstat()
        require(marker_info.st_uid == os.getuid() and stat.S_IMODE(marker_info.st_mode) == 0o600,
                "Sparkle tools marker has unsafe ownership or permissions.")
        marker = _json(_read(marker_path, 2048))
        require(marker == {"schema": 1, "uid": os.getuid(), "packageSHA256": PACKAGE_SHA256, "signerSHA256": SIGNER_SHA256},
                "Sparkle tools ownership marker does not match.")
        signer = directory / "sign_update"
        info = signer.lstat()
        require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
                "Sparkle signing tool has unsafe ownership or permissions.")
        require(hashlib.sha256(_read(signer, 4 * 1024 * 1024)).hexdigest() == SIGNER_SHA256,
                "Sparkle signing tool checksum differs from the reviewed binary.")
        return signer
    except OSError:
        raise SparkleError("Sparkle tools could not be verified safely.") from None


def prepare_tools() -> Path:
    """Download the pinned public package and extract only its reviewed signer."""
    configuration(require_key=False)
    directory = _temp_root() / "moekit-sparkle-tools"
    if directory.exists() or directory.is_symlink():
        return _owned_tools(directory)
    try:
        request = urllib.request.Request(PACKAGE_URL, headers={"User-Agent": "MoeKit-Sparkle-release"})
        with urllib.request.build_opener(_PackageRedirect()).open(request, timeout=120) as response:
            package = response.read(MAX_PACKAGE + 1)
    except (OSError, ValueError):
        raise SparkleError("Pinned Sparkle package download failed.") from None
    require(len(package) <= MAX_PACKAGE and hashlib.sha256(package).hexdigest() == PACKAGE_SHA256,
            "Pinned Sparkle package checksum mismatch.")
    try:
        with zipfile.ZipFile(io.BytesIO(package)) as archive:
            matches = [item for item in archive.infolist() if item.filename == "bin/sign_update"]
            require(len(matches) == 1 and matches[0].file_size <= 4 * 1024 * 1024 and
                    stat.S_ISREG(matches[0].external_attr >> 16), "Sparkle package signer entry is unsafe.")
            signer = archive.read(matches[0])
    except (OSError, ValueError, zipfile.BadZipFile):
        raise SparkleError("Pinned Sparkle package could not be read.") from None
    require(hashlib.sha256(signer).hexdigest() == SIGNER_SHA256, "Pinned Sparkle signing binary checksum mismatch.")
    try:
        directory.mkdir(mode=0o700)
    except OSError:
        raise SparkleError("Sparkle tools destination already exists or is unavailable.") from None
    _write_new(directory / "sign_update", signer, 0o700)
    marker = {"schema": 1, "uid": os.getuid(), "packageSHA256": PACKAGE_SHA256, "signerSHA256": SIGNER_SHA256}
    _write_new(directory / "owner.json", json.dumps(marker, sort_keys=True).encode("utf-8"))
    return _owned_tools(directory)


def cleanup_tools() -> None:
    """Remove only an intact, marker-owned signer directory; never recurse."""
    directory = _temp_root() / "moekit-sparkle-tools"
    if not directory.exists() and not directory.is_symlink():
        return
    _owned_tools(directory)
    try:
        (directory / "sign_update").unlink()
        (directory / "owner.json").unlink()
        directory.rmdir()
    except OSError:
        raise SparkleError("Owned Sparkle tool cleanup did not complete.") from None


def _sign(path: Path, secret: bytes, *, feed=False):
    require(sys.platform == "darwin", "Official Sparkle signing requires macOS.")
    tools = _temp_root() / "moekit-sparkle-tools"
    signer = _owned_tools(tools)
    # The owned directory contains exactly two known entries, so '-' cannot be
    # mistaken by Sparkle for a key file instead of stdin.
    args = [str(signer), "--ed-key-file", "-", "-p"]
    if feed:
        args.append("--disable-signing-warning")
    args.append(str(path.resolve(strict=True)))
    return _run(args, stdin=secret + b"\n", cwd=tools)


def _archive_name(context):
    return f"MoeKit-v{context['version']}-macOS.zip"


def _release_url(context):
    return f"https://github.com/{REPOSITORY}/releases/tag/v{context['version']}"


def _archive_url(context):
    return f"https://github.com/{REPOSITORY}/releases/download/v{context['version']}/{_archive_name(context)}"


def _notes(notes):
    require(isinstance(notes, str) and notes.strip() and len(notes.encode("utf-8")) <= MAX_NOTES and
            all(character in "\t\n" or ord(character) >= 32 for character in notes), "Release notes are missing, oversized, or invalid.")
    return notes


def _unsigned_feed(context, notes, archive):
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "MoeKit updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{REPOSITORY}"
    item = ET.SubElement(channel, "item")
    values = [("title", "MoeKit " + context["version"]), ("link", _release_url(context)),
              (f"{{{SPARKLE_NS}}}version", context["build_number"]),
              (f"{{{SPARKLE_NS}}}shortVersionString", context["version"]),
              (f"{{{SPARKLE_NS}}}minimumSystemVersion", "15.0.0"),
              (f"{{{MOEKIT_NS}}}sourceCommit", context["source_sha"]),
              (f"{{{MOEKIT_NS}}}runID", context["run_id"]),
              (f"{{{MOEKIT_NS}}}runNumber", context["run_number"]),
              (f"{{{MOEKIT_NS}}}runAttempt", context["run_attempt"])]
    for name, value in values:
        ET.SubElement(item, name).text = value
    if "-preview." in context["version"]:
        ET.SubElement(item, f"{{{SPARKLE_NS}}}channel").text = "preview"
    ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "plain-text"}).text = _notes(notes)
    ET.SubElement(item, "enclosure", {"url": _archive_url(context), "length": str(archive["length"]),
                                      "type": "application/octet-stream", f"{{{SPARKLE_NS}}}edSignature": archive["edSignature"]})
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def _feed_details(data, public_key):
    require(isinstance(data, bytes) and len(data) <= MAX_FEED and data.count(b"<!-- sparkle-signatures:\n") == 1,
            "Update feed is unsigned, oversized, or has multiple signatures.")
    match = TRAILER.search(data)
    require(match is not None and match.start() == int(match[2]), "Update feed signature trailer or length is invalid.")
    content = data[:match.start()]
    verify_signature(content, match[1].decode("ascii"), public_key)
    require(b"<!" not in content and b"\x00" not in content, "Update feed contains unsupported XML declarations.")
    try:
        root = ET.fromstring(content)
        require(root.tag == "rss" and root.attrib == {"version": "2.0"} and len(root) == 1,
                "Unexpected update feed root schema.")
        channel = root[0]
        require(channel.tag == "channel" and not channel.attrib and len(channel) == 3 and channel[2].tag == "item",
                "Update feed must contain exactly one bounded release item.")
        item = channel[2]
        require(not item.attrib and len(item) in {11, 12}, "Unexpected update item schema.")
        values = {element.tag: element.text for element in item}
        require(len(values) == len(item), "Duplicate update item fields.")
        version = values[f"{{{SPARKLE_NS}}}shortVersionString"]
        context = {"version": version, "marketing_version": version.split("-preview.")[0],
                   "build_number": values[f"{{{SPARKLE_NS}}}version"], "source_sha": values[f"{{{MOEKIT_NS}}}sourceCommit"],
                   "run_id": values[f"{{{MOEKIT_NS}}}runID"], "run_number": values[f"{{{MOEKIT_NS}}}runNumber"],
                   "run_attempt": values[f"{{{MOEKIT_NS}}}runAttempt"]}
        _context(context)
        enclosure = item[-1]
        length_text = enclosure.attrib.get("length", "")
        require(re.fullmatch(r"[1-9][0-9]{0,9}", length_text) and int(length_text) <= MAX_ARCHIVE,
                "Update archive length is invalid.")
        archive = {"length": int(length_text), "edSignature": enclosure.attrib[f"{{{SPARKLE_NS}}}edSignature"]}
        _base64(archive["edSignature"], {64}, "Update archive signature is invalid.")
        notes = values["description"]
        require(content == _unsigned_feed(context, notes, archive), "Update feed schema, URLs, or provenance differ from the canonical format.")
        return context, archive, notes
    except (ET.ParseError, KeyError, TypeError, AttributeError, ValueError, UnicodeError):
        raise SparkleError("Update feed XML is malformed or incomplete.") from None


def sign_release(directory: Path, context: dict, notes: str) -> dict:
    _context(context)
    config = configuration()
    secret = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "")
    _base64(secret, {32, 96}, "Sparkle signing secret is missing or has an unsupported encoding.")
    directory = _release_directory(directory)
    archive_path = directory / _archive_name(context)
    archive_data = _read(archive_path, MAX_ARCHIVE)
    signature_bytes = _sign(archive_path, secret.encode("ascii"))
    try:
        signature = signature_bytes.decode("ascii").strip()
    except UnicodeError:
        raise SparkleError("Sparkle signer returned an invalid signature.") from None
    verify_signature(archive_data, signature, config["publicEDKey"])
    archive = {"name": archive_path.name, "url": _archive_url(context), "length": len(archive_data),
               "sha256": hashlib.sha256(archive_data).hexdigest(), "edSignature": signature}
    feed = directory / "appcast.xml"
    _write_new(feed, _unsigned_feed(context, notes, archive))
    _sign(feed, secret.encode("ascii"), feed=True)
    feed_data = _read(feed, MAX_FEED)
    metadata = {"schemaVersion": 1, "frameworkVersion": SPARKLE_VERSION, "frameworkRevision": SPARKLE_REVISION,
                "feedURL": FEED_URL, "publicEDKey": config["publicEDKey"], "sourceSHA": context["source_sha"],
                "version": context["version"], "buildNumber": context["build_number"], "archive": archive,
                "feed": {"name": "appcast.xml", "length": len(feed_data), "sha256": hashlib.sha256(feed_data).hexdigest()}}
    verify_release(directory, context, metadata)
    return metadata


def verify_release(directory: Path, context: dict, metadata: dict) -> None:
    _context(context)
    public_key = configuration()["publicEDKey"]
    require(isinstance(metadata, dict) and set(metadata) == {"schemaVersion", "frameworkVersion", "frameworkRevision",
            "feedURL", "publicEDKey", "sourceSHA", "version", "buildNumber", "archive", "feed"}, "Unexpected Sparkle release metadata schema.")
    expected = {"schemaVersion": 1, "frameworkVersion": SPARKLE_VERSION, "frameworkRevision": SPARKLE_REVISION,
                "feedURL": FEED_URL, "publicEDKey": public_key, "sourceSHA": context["source_sha"],
                "version": context["version"], "buildNumber": context["build_number"]}
    require(all(metadata.get(key) == value for key, value in expected.items()) and type(metadata["schemaVersion"]) is int,
            "Sparkle release provenance differs from the reviewed source or public key.")
    archive, feed = metadata["archive"], metadata["feed"]
    require(isinstance(archive, dict) and set(archive) == {"name", "url", "length", "sha256", "edSignature"} and
            isinstance(feed, dict) and set(feed) == {"name", "length", "sha256"}, "Unexpected Sparkle file metadata schema.")
    require(archive["name"] == _archive_name(context) and archive["url"] == _archive_url(context) and feed["name"] == "appcast.xml",
            "Unexpected Sparkle update asset name or URL.")
    directory = _release_directory(directory)
    archive_data, feed_data = _read(directory / archive["name"], MAX_ARCHIVE), _read(directory / "appcast.xml", MAX_FEED)
    for value, data in ((archive, archive_data), (feed, feed_data)):
        require(type(value["length"]) is int and value["length"] == len(data) and
                value["sha256"] == hashlib.sha256(data).hexdigest(), "Sparkle update file length or checksum mismatch.")
    verify_signature(archive_data, archive["edSignature"], public_key)
    feed_context, feed_archive, _ = _feed_details(feed_data, public_key)
    require(feed_context == {key: context[key] for key in feed_context} and
            feed_archive == {key: archive[key] for key in feed_archive}, "Signed feed does not match the verified archive or build context.")


def _sha(value):
    require(isinstance(value, str) and SHA_RE.fullmatch(value), "Unexpected GitHub object identifier.")
    return value


def _tag_commit(api, tag):
    base = f"/repos/{REPOSITORY}"
    obj = api.request("GET", base + "/git/ref/tags/" + tag)["object"]
    for _ in range(10):
        sha = _sha(obj.get("sha"))
        if obj.get("type") == "commit":
            return sha
        require(obj.get("type") == "tag", "Update release tag has an unexpected object type.")
        obj = api.request("GET", base + "/git/tags/" + sha)["object"]
    raise SparkleError("Update release tag chain exceeds the allowed depth.")


def publish_feed(api, directory: Path, context: dict) -> dict:
    """Publish only after independently checking the public release and assets.

    Existing feeds must be authentic, canonical and strictly older. The new
    commit has the observed HEAD as its parent; force:false prevents overwriting
    a concurrent writer. A failed request is never retried automatically.
    """
    directory = _release_directory(directory)
    info = _json(_read(directory / "BUILD_INFO.json", 128 * 1024))
    require(isinstance(info, dict) and isinstance(info.get("sparkle"), dict), "Verified release is missing Sparkle metadata.")
    metadata = info["sparkle"]
    verify_release(directory, context, metadata)
    data = _read(directory / "appcast.xml", MAX_FEED)
    require(len(data) == metadata["feed"]["length"] and hashlib.sha256(data).hexdigest() == metadata["feed"]["sha256"],
            "Update feed changed after release verification.")
    base = f"/repos/{REPOSITORY}"
    tag = "v" + context["version"]
    release = api.request("GET", base + "/releases/tags/" + tag)
    require(isinstance(release, dict) and release.get("draft") is False and release.get("tag_name") == tag and
            release.get("prerelease") is ("-preview." in context["version"]) and
            type(release.get("id")) is int and release["id"] > 0, "Update release is not confirmed published.")
    require(_tag_commit(api, tag) == context["source_sha"], "Published update tag does not match the reviewed commit.")
    assets = api.request("GET", base + f"/releases/{release['id']}/assets?per_page=100")
    require(isinstance(assets, list) and len(assets) < 100 and all(isinstance(item, dict) for item in assets), "Unexpected update release assets response.")
    for expected in (metadata["archive"], metadata["feed"]):
        matches = [item for item in assets if item.get("name") == expected["name"]]
        url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{expected['name']}"
        require(len(matches) == 1 and matches[0].get("state") == "uploaded" and type(matches[0].get("size")) is int and
                matches[0].get("size") == expected["length"] and matches[0].get("digest") == "sha256:" + expected["sha256"] and
                matches[0].get("browser_download_url") == url, "Published update asset differs from the verified local file.")
    reference = api.request("GET", base + "/git/ref/heads/updates", allow_404=True)
    old_head = None
    if reference is not None:
        require(reference.get("ref") == "refs/heads/updates" and reference.get("object", {}).get("type") == "commit",
                "Unexpected update branch reference.")
        old_head = _sha(reference["object"]["sha"])
        commit = api.request("GET", base + "/git/commits/" + old_head)
        tree_sha = _sha(commit.get("tree", {}).get("sha"))
        tree = api.request("GET", base + "/git/trees/" + tree_sha + "?recursive=1")
        entries = tree.get("tree")
        require(tree.get("truncated") is False and isinstance(entries, list) and len(entries) == 1 and
                entries[0].get("path") == "appcast.xml" and entries[0].get("mode") == "100644" and
                entries[0].get("type") == "blob", "Update branch must contain only a regular appcast.xml file.")
        blob_sha = _sha(entries[0].get("sha"))
        blob = api.request("GET", base + "/git/blobs/" + blob_sha)
        require(blob.get("encoding") == "base64" and type(blob.get("size")) is int and 0 < blob["size"] <= MAX_FEED and
                isinstance(blob.get("content"), str) and len(blob["content"]) <= MAX_FEED * 2, "Unexpected prior update feed blob.")
        encoded = "".join(blob["content"].splitlines())
        prior = _base64(encoded, {blob["size"]}, "Invalid prior update feed encoding.")
        require(hashlib.sha1(b"blob " + str(len(prior)).encode("ascii") + b"\0" + prior).hexdigest() == blob_sha,
                "Prior update feed blob identity mismatch.")
        prior_context, _, _ = _feed_details(prior, metadata["publicEDKey"])
        require(tuple(map(int, prior_context["build_number"].split("."))) < tuple(map(int, context["build_number"].split("."))),
                "Update feed publication would replay or downgrade an existing release.")
    # Recheck the externally mutable release tag before creating feed objects.
    require(_tag_commit(api, tag) == context["source_sha"], "Update release tag changed before feed publication.")
    blob = api.request("POST", base + "/git/blobs", {"encoding": "base64", "content": base64.b64encode(data).decode("ascii")})
    blob_sha = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    require(blob.get("sha") == blob_sha, "Published update blob identity mismatch.")
    tree = api.request("POST", base + "/git/trees", {"tree": [{"path": "appcast.xml", "mode": "100644", "type": "blob", "sha": blob_sha}]})
    tree_sha = _sha(tree.get("sha"))
    commit = api.request("POST", base + "/git/commits", {"message": "Publish MoeKit " + context["version"] + " update feed",
            "tree": tree_sha, "parents": [old_head] if old_head else []})
    new_head = _sha(commit.get("sha"))
    if old_head:
        api.request("PATCH", base + "/git/refs/heads/updates", {"sha": new_head, "force": False})
    else:
        api.request("POST", base + "/git/refs", {"ref": "refs/heads/updates", "sha": new_head})
    actual = api.request("GET", base + "/git/ref/heads/updates")
    require(actual.get("ref") == "refs/heads/updates" and actual.get("object", {}).get("type") == "commit" and
            actual["object"].get("sha") == new_head, "Could not confirm published update feed HEAD; inspect before retrying.")
    return {"feed_url": FEED_URL, "commit_sha": new_head, "previous_commit_sha": old_head}
