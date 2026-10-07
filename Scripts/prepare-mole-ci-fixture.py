#!/usr/bin/env python3
"""Secret-free macOS CI fixtures. Never install Mole or run an upstream command.

Only exact pinned artifacts are written into one new, private RUNNER_TEMP child.
The generated test resources contain metadata/paths, never executable contents.
No quarantine removal, signature normalization, Homebrew invocation or user CLI
inspection is permitted here. Preparation is not a native contract-test result.
"""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import secrets
import stat
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request


RELEASES = {
    "arm64": [
        ("V1.58.0", "analyze-darwin-arm64", 3860946, "e7e6fd63dcbc7db90df1b63f2b2db3357e82ce919cf09df5b0ca645bdb10d180"),
        ("V1.57.0", "analyze-darwin-arm64", 3827474, "62c6b5076349081a34e60256a1471979f600d74d8f4990745a37d30d6faa00e1"),
    ],
    "x86_64": [
        ("V1.58.0", "analyze-darwin-amd64", 4056192, "cf0830df63162dc34e120c19a409c130d6f468ed2d6039f9872e63e8a88adbc9"),
        ("V1.57.0", "analyze-darwin-amd64", 4022992, "cff7d9da8bd18cb3364d566186944b5b14b01e21e5bb4a3d61579f553ea39ad7"),
    ],
}
BOTTLE_SHA = "04d1d9a3f78524fe224fde11cb98eae036e97e4f3d425ae53119f7078cb66836"
BOTTLE_SIZE = 4090875
BOTTLE_MEMBER = "mole/1.58.0/libexec/bin/analyze-go"
BOTTLE_ANALYZER_SIZE = 4348258
BOTTLE_ANALYZER_SHA = "d32d92f4c32d8079d464c496312fa616a9af6580457d40ffe7bfd28213f93866"
BOTTLE_URL = "https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:" + BOTTLE_SHA
TOKEN_URL = "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/mole:pull"
MAXIMUM_EXPANDED = 64 * 1024 * 1024


def safe_https(url):
    parts = urllib.parse.urlsplit(url)
    return (parts.scheme == "https" and parts.port in (None, 443)
            and parts.username is None and parts.password is None and not parts.fragment)


class FixtureRedirect(urllib.request.HTTPRedirectHandler):
    """A single fixed-service CDN hop; anonymous authorization never follows."""
    def redirect_request(self, request, fp, code, message, headers, newurl):
        before = urllib.parse.urlsplit(request.full_url)
        after = urllib.parse.urlsplit(newurl)
        allowed = ((before.hostname == "github.com" and before.path.startswith("/tw93/Mole/releases/download/")
                    and after.hostname == "release-assets.githubusercontent.com")
                   or (request.full_url == BOTTLE_URL and after.hostname == "pkg-containers.githubusercontent.com"))
        if not safe_https(newurl) or not allowed:
            raise ValueError("Unexpected fixture download redirect")
        return urllib.request.Request(newurl, headers={"Accept-Encoding": "identity"}, method="GET")


def download(url, limit, token=None):
    if not safe_https(url):
        raise ValueError("Fixture source must be HTTPS")
    allowed = {TOKEN_URL, BOTTLE_URL}
    allowed.update(f"https://github.com/tw93/Mole/releases/download/{version}/{name}"
                   for items in RELEASES.values() for version, name, _, _ in items)
    if url not in allowed or (token is not None and url != BOTTLE_URL):
        raise ValueError("Unexpected fixture source or authorization destination")
    headers = {"Accept-Encoding": "identity", "User-Agent": "MoeKit-CI-Mole-Fixture"}
    if token is not None:
        if not token or len(token) > 8192 or any(ord(char) < 33 or ord(char) > 126 for char in token):
            raise ValueError("Invalid anonymous pull token")
        headers["Authorization"] = "Bearer " + token
    # Do not consult environment proxy credentials, cookies or user auth files.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), FixtureRedirect())
    deadline = time.monotonic() + 120
    with opener.open(urllib.request.Request(url, headers=headers), timeout=30) as response:
        if response.status != 200 or response.headers.get("Content-Encoding", "identity").lower() != "identity":
            raise ValueError("Unexpected fixture response")
        length = response.headers.get("Content-Length")
        if length is not None and int(length) > limit:
            raise ValueError("Fixture response exceeds byte limit")
        data = bytearray()
        while True:
            if time.monotonic() >= deadline:
                raise ValueError("Fixture download reached its time limit")
            chunk = response.read(min(65536, limit - len(data) + 1))
            if not chunk:
                return bytes(data)
            data.extend(chunk)
            if len(data) > limit:
                raise ValueError("Fixture response exceeds byte limit")


def verify(data, size, digest):
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("Official fixture size/hash mismatch; refusing execution")


def bottle_analyzer(archive):
    verify(archive, BOTTLE_SIZE, BOTTLE_SHA)
    # Explicit bounded decompression, followed by an in-memory single-member
    # read. Never extractall, follow a member link, or copy another archive path.
    with gzip.GzipFile(fileobj=io.BytesIO(archive)) as stream:
        expanded = stream.read(MAXIMUM_EXPANDED + 1)
    if len(expanded) > MAXIMUM_EXPANDED:
        raise ValueError("Bottle expanded size exceeds fixture limit")
    found = None
    names = set()
    with tarfile.open(fileobj=io.BytesIO(expanded), mode="r:") as stream:
        for index, member in enumerate(stream):
            if index >= 2048 or member.pax_headers or member.name in names:
                raise ValueError("Unsupported or duplicate bottle member")
            names.add(member.name)
            if member.name == BOTTLE_MEMBER:
                if not member.isfile() or member.size != BOTTLE_ANALYZER_SIZE or found is not None:
                    raise ValueError("Bottle analyzer must be one exact regular member")
                source = stream.extractfile(member)
                if source is None:
                    raise ValueError("Missing bottle analyzer contents")
                with source:
                    found = source.read(BOTTLE_ANALYZER_SIZE + 1)
    if found is None:
        raise ValueError("Bottle did not contain the expected analyzer")
    verify(found, BOTTLE_ANALYZER_SIZE, BOTTLE_ANALYZER_SHA)
    return found


def write_new(path, data, mode):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fchmod(output.fileno(), mode)


def main():
    if (platform.system() != "Darwin" or os.environ.get("CI") != "true"
            or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.geteuid() == 0):
        raise SystemExit("This helper is only for an unprivileged GitHub-hosted macOS CI fixture job.")
    architecture = platform.machine()
    if architecture not in RELEASES:
        raise SystemExit("Unsupported native fixture architecture")
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if not temporary.is_dir() or temporary == Path.home().resolve():
        raise SystemExit("Invalid runner temporary directory")
    resources = Path(__file__).resolve().parents[1] / "Tests/Resources"
    metadata_path = resources / "MoleAnalyzerFixtures.json"
    legacy_path = resources / "MoleAnalyzerFixturePath.txt"
    if any(path.exists() or path.is_symlink() for path in [metadata_path, legacy_path]):
        raise SystemExit("Generated Mole fixture metadata already exists; refusing to replace it")
    marker = secrets.token_hex(16)
    folder = temporary / ("MoeKit-pinned-analyzers-" + marker)
    folder.mkdir(mode=0o700)
    if stat.S_IMODE(folder.stat().st_mode) != 0o700:
        raise SystemExit("Fixture directory must be private")
    write_new(folder / ".fixture-owner", (marker + "\n").encode(), 0o400)
    entries = []
    for version, asset, size, digest in RELEASES[architecture]:
        data = download(f"https://github.com/tw93/Mole/releases/download/{version}/{asset}", size)
        verify(data, size, digest)
        name = f"analyze-{version}-{architecture}-officialRelease"
        write_new(folder / name, data, 0o500)
        entries.append(dict(fileName=name, version=version, architecture=architecture,
                            byteCount=size, sha256=digest, origin="officialRelease"))
    bottle = None
    if architecture == "arm64":
        try:
            archive = download(BOTTLE_URL, BOTTLE_SIZE)
        except urllib.error.HTTPError as error:
            if error.code != 401:
                raise
            token = json.loads(download(TOKEN_URL, 32768))["token"]
            archive = download(BOTTLE_URL, BOTTLE_SIZE, token=token)
        data = bottle_analyzer(archive)
        archive_name = "mole-1.58.0-arm64_sequoia.tar.gz"
        write_new(folder / archive_name, archive, 0o400)
        name = "analyze-V1.58.0-arm64-homebrewBottle"
        write_new(folder / name, data, 0o500)
        entries.append(dict(fileName=name, version="V1.58.0", architecture=architecture,
                            byteCount=BOTTLE_ANALYZER_SIZE, sha256=BOTTLE_ANALYZER_SHA, origin="homebrewBottle"))
        bottle = dict(fileName=archive_name, version="1.58.0", byteCount=BOTTLE_SIZE, sha256=BOTTLE_SHA)
    metadata = dict(schemaVersion=1, architecture=architecture, root=str(folder), marker=marker,
                    entries=entries, bottle=bottle)
    # Publish resources only after every requested artifact has been verified.
    # The legacy entry remains the latest official native release for the
    # independently gated native Installer Trash fixture; its guards are intact.
    write_new(metadata_path, (json.dumps(metadata, indent=2) + "\n").encode(), 0o600)
    write_new(legacy_path, (str(folder / entries[0]["fileName"]) + "\n").encode(), 0o600)
    print(f"Prepared {len(entries)} exact {architecture} Mole artifacts in an owned CI fixture; nothing was executed or installed.")


if __name__ == "__main__":
    main()
