#!/usr/bin/env python3
"""Secret-free native Sparkle E2E, confined to generated CI-only synthetic apps.

Uses the PUBLIC RFC8032 section 7.1 vectors, never production signing material.
No keychain access, user application target, recursive deletion, process-name kill,
or relaxed OS security setting. Temporary fixtures are deliberately retained.
"""
from __future__ import annotations
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_URL = "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip"
PACKAGE_SHA256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
# PUBLIC, NONPRODUCTION test vectors: https://www.rfc-editor.org/rfc/rfc8032#section-7.1
PUBLIC_TEST_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC_TEST_KEY = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
PUBLIC_OTHER_SEED = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
CASES = ("valid", "tampered-feed", "tampered-archive", "wrong-key", "invalid-archive", "cancel", "equal-version", "older-version", "preview-filtered", "preview-allowed")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, *, timeout=90, transient_exit=None, separate_stderr=False):
    result = subprocess.run([str(x) for x in args], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE if separate_stderr else subprocess.STDOUT, timeout=timeout, check=False)
    stderr = result.stderr or b""
    require(len(result.stdout) + len(stderr) <= 2_000_000, "Command diagnostics exceeded fixture budget")
    if transient_exit is not None and result.returncode == transient_exit: return None
    require(result.returncode == 0, f"Fixture tool failed ({Path(str(args[0])).name}): {(result.stdout + stderr).decode(errors='replace')[-12000:]}")
    return result.stdout.decode().strip()


def write_new(path: Path, data: bytes, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as target:
        target.write(data)


class OwnedRoot:
    def __init__(self):
        self.path = Path(tempfile.mkdtemp(prefix="moekit-sparkle-")).resolve(strict=True)
        self.marker = uuid.uuid4().hex
        write_new(self.path / "owner-marker", self.marker.encode())
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.identity = os.fstat(self.fd)
        self.verify()

    def verify(self):
        current = self.path.lstat()
        pinned = os.fstat(self.fd)
        require((current.st_dev, current.st_ino) == (self.identity.st_dev, self.identity.st_ino) == (pinned.st_dev, pinned.st_ino)
                and stat.S_ISDIR(current.st_mode) and current.st_uid == os.geteuid()
                and stat.S_IMODE(current.st_mode) == 0o700, "Fixture root identity changed")
        fd = os.open("owner-marker", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        try:
            marker = os.fstat(fd)
            require(stat.S_ISREG(marker.st_mode) and marker.st_nlink == 1 and marker.st_uid == os.geteuid()
                    and os.read(fd, 129) == self.marker.encode(), "Fixture owner marker changed")
        finally:
            os.close(fd)

    def directory(self, *components):
        self.verify()
        require(all(re.fullmatch(r"[A-Za-z0-9._-]+", part) and part not in (".", "..") for part in components), "Invalid fixture path")
        path = self.path.joinpath(*components)
        path.mkdir(mode=0o700, parents=True, exist_ok=False)
        return path


def tree_digest(path: Path):
    digest = hashlib.sha256()
    for child in sorted(path.rglob("*")):
        relative = child.relative_to(path).as_posix()
        info = child.lstat()
        digest.update(relative.encode() + b"\0")
        if stat.S_ISLNK(info.st_mode):
            digest.update(b"L" + os.readlink(child).encode())
        elif stat.S_ISREG(info.st_mode):
            digest.update(b"F" + hashlib.sha256(child.read_bytes()).digest())
        elif stat.S_ISDIR(info.st_mode):
            digest.update(b"D")
        else:
            raise RuntimeError("Unexpected fixture tree object")
    return digest.hexdigest()


class FixtureServer:
    def __init__(self):
        self.payloads = {}
        self.requests = []
        self.completed_responses = {}
        self.sent_bytes = {}
        self.active_responses = {}
        self.lock = threading.Lock()
        parent = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                with parent.lock:
                    data = parent.payloads.get(parsed.path) if not parsed.query and not parsed.fragment else None
                    parent.requests.append(parsed.path)
                if self.headers.get("Host") != f"127.0.0.1:{parent.server.server_port}" or data is None:
                    self.send_error(404); return
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Type", "application/xml" if parsed.path.endswith(".xml") else "application/octet-stream")
                self.end_headers()
                with parent.lock: parent.active_responses[parsed.path] = parent.active_responses.get(parsed.path, 0) + 1
                try:
                    # Leave a deterministic cancellation window AFTER actual
                    # native receipt; never substitute skipping the version.
                    chunks = (data[offset:offset + 16384] for offset in range(0, len(data), 16384)) if "/cancel/" in parsed.path and parsed.path.endswith(".zip") else (data,)
                    for chunk in chunks:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        with parent.lock: parent.sent_bytes[parsed.path] = parent.sent_bytes.get(parsed.path, 0) + len(chunk)
                        if "/cancel/" in parsed.path and parsed.path.endswith(".zip"): time.sleep(0.03)
                    with parent.lock: parent.completed_responses[parsed.path] = len(data)
                except (BrokenPipeError, ConnectionResetError): pass
                finally:
                    with parent.lock: parent.active_responses[parsed.path] -= 1
            def log_message(self, *args): pass
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self): return f"http://127.0.0.1:{self.server.server_port}"

    def add(self, path, data):
        require(re.fullmatch(r"/[a-f0-9]{32}/[a-z-]+/(appcast\.xml|update\.zip)", path), "Unapproved HTTP fixture route")
        with self.lock: self.payloads[path] = data

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=3)
        require(not self.thread.is_alive(), "Fixture server failed to stop")


def package(owned: OwnedRoot):
    archive = owned.path / "Sparkle-package.zip"
    request = urllib.request.Request(PACKAGE_URL, headers={"User-Agent": "MoeKit-CI-Fixture"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(50_000_001)
    require(len(data) <= 50_000_000 and hashlib.sha256(data).hexdigest() == PACKAGE_SHA256, "Pinned Sparkle package digest mismatch")
    write_new(archive, data)
    # The immutable official bytes are checked before extraction; still reject
    # absolute, parent-traversing or duplicate archive member names.
    with zipfile.ZipFile(archive) as zipped:
        names = zipped.namelist()
        require(len(names) == len(set(names)) and all(not n.startswith("/") and ".." not in Path(n).parts for n in names), "Invalid pinned package archive")
    destination = owned.directory("package")
    run(["/usr/bin/ditto", "-xk", archive, destination])
    return destination


def sign_app(app: Path, empty_entitlements: Path):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    app_identifier = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    nested = [(framework / "Versions/B/XPCServices/Installer.xpc", "org.sparkle-project.InstallerLauncher"),
              (framework / "Versions/B/XPCServices/Downloader.xpc", "org.sparkle-project.DownloaderService"),
              (framework / "Versions/B/Autoupdate", "org.sparkle-project.Sparkle.Autoupdate"),
              (framework / "Versions/B/Updater.app", "org.sparkle-project.Sparkle.Updater"),
              (framework, "org.sparkle-project.Sparkle"), (app, app_identifier)]
    for item, identifier in nested:
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "0", "--identifier", identifier,
             "--entitlements", empty_entitlements, item])
    for item, identifier in nested:
        run(["/usr/bin/codesign", "--verify", "--strict", item])
        metadata = run(["/usr/bin/codesign", "--display", "--verbose=4", item])
        require(f"Identifier={identifier}\n" in metadata + "\n", "Fixture code-signing identifier differs from release contract")


def build_app(owned, directory, version, info, executable, framework, entitlements):
    owned.verify()
    app = directory / "SparkleFixture.app"
    (app / "Contents/MacOS").mkdir(parents=True, mode=0o700)
    (app / "Contents/Frameworks").mkdir(mode=0o700)
    shutil.copy2(executable, app / "Contents/MacOS/SparkleFixture")
    shutil.copytree(framework, app / "Contents/Frameworks/Sparkle.framework", symlinks=True)
    values = {**info, "CFBundleVersion": version, "CFBundleShortVersionString": f"1.0.{version}"}
    write_new(app / "Contents/Info.plist", plistlib.dumps(values))
    sign_app(app, entitlements)
    return app


class CaseNamespace:
    """Pin each namespace and the append-only event inode before launch."""
    def __init__(self, owned, case, installed, events):
        self.owned, self.case, self.installed, self.events = owned, case, installed, events
        self.identities = {path: path.lstat() for path in (case, installed, events)}
        self.verify()

    def verify(self):
        self.owned.verify()
        for path, expected in self.identities.items():
            actual = path.lstat()
            require((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino) and
                    actual.st_uid == os.geteuid() and stat.S_IFMT(actual.st_mode) == stat.S_IFMT(expected.st_mode),
                    "Fixture case namespace changed")
            if path == self.events:
                require(stat.S_ISREG(actual.st_mode) and actual.st_nlink == 1 and actual.st_size <= 200_000,
                        "Fixture event inode changed or exceeded budget")
            else:
                require(stat.S_ISDIR(actual.st_mode) and stat.S_IMODE(actual.st_mode) == 0o700,
                        "Fixture directory permissions changed")

    def read(self):
        self.verify()
        result = read_events(self.events, self.identities[self.events])
        self.verify()
        return result


def read_events(path, expected=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid()
                and info.st_size <= 200_000, "Fixture event file changed or exceeded budget")
        if expected is not None:
            require((info.st_dev, info.st_ino) == (expected.st_dev, expected.st_ino), "Fixture event identity changed")
        data = os.read(fd, 200_001)
        require(len(data) <= 200_000, "Fixture event budget exceeded")
    finally:
        os.close(fd)
    # Preserve complete records even while the next JSON line is being written.
    return [json.loads(line) for line in data.split(b"\n")[:-1] if line]


def process_identity(value):
    return tuple(value[key] for key in ("pid", "uid", "start_seconds", "start_microseconds"))


class Lifetime:
    """No signaling. Capture identities before installation can move old code."""
    def __init__(self, owned, bundle_id, probe):
        self.owned, self.bundle_id, self.probe = owned, bundle_id, probe
        self.tracked = {}
        self.snapshots = 0
        self.changing_snapshots = 0

    def sample(self, events):
        self.owned.verify()
        for event in events:
            if event.get("event") == "launch":
                identity = process_identity(event)
                require(identity[0] > 0 and identity[1] == os.geteuid(), "Native launch identity invalid")
                self.tracked[identity] = {key: event[key] for key in ("pid", "uid", "start_seconds", "start_microseconds")}
                self.tracked[identity]["role"] = "fixture-host"
        output = run([self.probe, self.owned.path, self.bundle_id, self.owned.marker,
                      str(self.owned.identity.st_dev), str(self.owned.identity.st_ino), json.dumps(list(self.tracked.values()), separators=(",", ":"))], timeout=5, transient_exit=3, separate_stderr=True)
        self.owned.verify()
        if output is None:
            # Process births during enumeration do not establish either
            # idleness or checkpoint ownership. Retry only inside the caller's
            # existing phase deadline; namespace/identity errors stay fatal.
            self.changing_snapshots += 1
            return None
        snapshot = json.loads(output)
        require(snapshot.get("schema") == 1 and snapshot.get("bundle_id") == self.bundle_id and snapshot.get("uid") == os.geteuid()
                and type(snapshot.get("idle")) is bool and isinstance(snapshot.get("owned_processes"), list),
                "Invalid native lifetime probe response")
        for process in snapshot["owned_processes"]:
            identity = process_identity(process)
            require(identity[0] > 0 and identity[1] == os.geteuid(), "Native helper identity invalid")
            self.tracked[identity] = process
        require(len(self.tracked) <= 32, "Fixture process lifetime budget exceeded")
        self.snapshots += 1
        self.owned.verify()
        return snapshot


def preflight_probe(owned, probe):
    """Exercise physical/system-alias identity before launching any updater."""
    identifier = f"org.moekit.CIFixture.r{owned.marker}.valid"
    arguments = [identifier, owned.marker, str(owned.identity.st_dev), str(owned.identity.st_ino), "[]"]
    paths = [owned.path]
    physical = str(owned.path)
    if physical.startswith("/private/var/"):
        alias = Path(physical[len("/private"):])
        require(alias.is_dir() and os.path.samefile(alias, owned.path), "System alias did not resolve to owned root")
        paths.append(alias)
    require(len(paths) == 2, "Native alias preflight requires an owned temporary root under /private/var with a /var alias")
    for path in paths:
        owned.verify()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = run([probe, path, *arguments], timeout=5, transient_exit=3, separate_stderr=True)
            owned.verify()
            if result is not None: break
        else: raise RuntimeError("Native alias preflight inventory did not settle")
        snapshot = json.loads(result)
        require(snapshot.get("idle") is True and snapshot.get("bundle_id") == identifier,
                "Native alias preflight did not establish empty owned fixture")
    # A matching path spelling cannot substitute for the pinned directory inode.
    rejected = subprocess.run([str(probe), str(owned.path), identifier, owned.marker,
                               str(owned.identity.st_dev), str(owned.identity.st_ino + 1), "[]"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    owned.verify()
    require(rejected.returncode == 2 and rejected.stderr.strip() == b"Fixture lifetime probe unknown: root identity",
            "Native root identity mismatch was not specifically refused")
    return {"physical_and_system_alias": True, "mismatched_inode_rejected": True}


def collect_cases(names, callback, evidence):
    """Only a completed, explicitly settled case may yield to the next case."""
    for name in names:
        try:
            result = callback(name)
            require(type(result.get("passed")) is bool and result.get("settled") is True,
                    "Missing explicit settled case outcome")
        except Exception as error:
            evidence["cases"][name] = {"passed": False, "settled": False, "aborted": True, "failure": str(error)}
            print(f"ABORT native Sparkle {name}: {error}", flush=True)
            raise
        evidence["cases"][name] = result
        print(f"{'PASS' if result['passed'] else 'FAIL'} native Sparkle {name}: {result}", flush=True)
    evidence["all_passed"] = len(evidence["cases"]) == len(names) and all(r["passed"] for r in evidence["cases"].values())


def scenario(name, owned, server, binary, framework, signer, test_key, other_key, entitlements, output, probe):
    owned.verify()
    case = owned.directory(name)
    events_path = case / "events.jsonl"
    write_new(events_path, b"")
    event_identity = events_path.stat()
    installed = owned.directory(name, "Installed")
    candidate = owned.directory(name, "Candidate")
    namespace = CaseNamespace(owned, case, installed, events_path)
    route = f"/{owned.marker}/{name}"
    bundle_id = f"org.moekit.CIFixture.r{owned.marker}.{name.replace('-', '')}"
    info = {"CFBundleIdentifier": bundle_id, "CFBundleName": "SparkleFixture", "CFBundleExecutable": "SparkleFixture",
            "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication", "LSUIElement": True,
            "LSMinimumSystemVersion": "15.0", "SUFeedURL": server.base + route + "/appcast.xml",
            "SUPublicEDKey": base64.b64encode(PUBLIC_TEST_KEY).decode(), "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True, "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SUEnableSystemProfiling": False,
            "SUEnableJavaScript": False, "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "FixtureCI": True, "FixtureRoot": str(owned.path), "FixtureMarker": owned.marker, "FixtureCase": name,
            "FixtureCaseDevice": case.stat().st_dev, "FixtureCaseInode": case.stat().st_ino,
            "FixtureInstalledDevice": installed.stat().st_dev, "FixtureInstalledInode": installed.stat().st_ino,
            "FixtureDevice": owned.identity.st_dev, "FixtureInode": owned.identity.st_ino,
            "FixtureEventDevice": event_identity.st_dev, "FixtureEventInode": event_identity.st_ino,
            "FixturePreviewAllowed": name == "preview-allowed"}
    old = build_app(owned, installed, "1", info, binary, framework, entitlements)
    new = build_app(owned, candidate, "2", info, binary, framework, entitlements)
    archive = case / "update.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--keepParent", new, archive])
    if name == "invalid-archive": archive.write_bytes(b"deliberately invalid owned fixture archive\n")
    key = other_key if name == "wrong-key" else test_key
    signature = run([signer, "--ed-key-file", key, "-p", archive])
    require(re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature), "Unexpected archive signature output")
    archive_data = archive.read_bytes()
    if name == "tampered-archive": archive_data = archive_data[:-1] + bytes([archive_data[-1] ^ 1])
    version = "1" if name == "equal-version" else "0" if name == "older-version" else "2"
    channel = "<sparkle:channel>preview</sparkle:channel>" if name.startswith("preview-") else ""
    feed = case / "appcast.xml"
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Owned CI fixture</title>
<item><title>Owned update</title><sparkle:version>{version}</sparkle:version>{channel}
<enclosure url="{server.base}{route}/update.zip" sparkle:edSignature="{signature}" length="{len(archive_data)}" type="application/octet-stream"/>
</item></channel></rss>'''
    write_new(feed, xml.encode())
    run([signer, "--ed-key-file", test_key, "--disable-signing-warning", feed])
    feed_data = feed.read_bytes()
    if name == "tampered-feed":
        require(b"Owned update" in feed_data, "Signed feed payload unexpectedly changed")
        feed_data = feed_data.replace(b"Owned update", b"Wrong update")
    server.add(route + "/appcast.xml", feed_data)
    server.add(route + "/update.zip", archive_data)
    lifetime = Lifetime(owned, bundle_id, probe)
    original_digest = tree_digest(old)
    neighbor = case / "outside-neighbor.txt"
    write_new(neighbor, b"unrelated fixture neighbor survives\n")
    owned.verify()
    log_path = output / f"{name}.log"
    log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    started = time.monotonic()
    with os.fdopen(log_fd, "wb") as log:
        process = subprocess.Popen([str(old / "Contents/MacOS/SparkleFixture")], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        # The host self-expires. Never signal it or descendants. Unknown
        # lifetimes/namespace changes abort the batch instead of being skipped.
        terminal = None
        acknowledged = False
        while time.monotonic() - started < 105:
            events = namespace.read()
            snapshot = lifetime.sample(events)
            if snapshot is not None and not acknowledged and any(e["event"] == "ready_to_install" for e in events):
                roles = {entry["role"] for entry in snapshot["owned_processes"]}
                if {"installer", "progress-agent"}.issubset(roles):
                    namespace.verify()
                    write_new(case / "install-ack", owned.marker.encode())
                    acknowledged = True
            terminal = next((e for e in events if e["event"] in ("relaunched", "error", "not_found", "cancelled", "start_error", "preference_setup_error")), None)
            if terminal: break
            if process.poll() is not None and name not in ("valid", "preview-allowed"): break
            time.sleep(0.1)
        process.wait(timeout=15)  # independent native 110-second self-expiry
    # Require exact app/helper identities and ALL pinned Sparkle services gone.
    # Track captured identities even if Sparkle moved their executable paths.
    deadline, empty_since = time.monotonic() + 25, None
    while time.monotonic() < deadline:
        events = namespace.read()
        snapshot = lifetime.sample(events)
        with server.lock: serving = any(path.startswith(route + "/") and count > 0 for path, count in server.active_responses.items())
        if snapshot is not None and snapshot["idle"] and not serving:
            if empty_since is None: empty_since = time.monotonic()
            if time.monotonic() - empty_since >= 1.0: break
        else: empty_since = None
        time.sleep(0.2)
    else: raise RuntimeError(f"{name}: owned app/installer/server lifetime did not settle")
    namespace.verify()
    events = namespace.read()
    write_new(output / f"{name}.events.json", json.dumps(events, indent=2).encode())
    terminal = next((e for e in events if e["event"] in ("relaunched", "error", "not_found", "cancelled", "start_error", "preference_setup_error")), {"event": "missing"})
    offered = any(e["event"] == "found" for e in events)
    prepared = any(e["event"] == "ready_to_install" for e in events)
    installer_started = any(e["event"] == "installer_started" for e in events)
    verified_feed = any(e["event"] == "feed_loaded" and e.get("signature_verified") is True for e in events)
    received_bytes = max((e.get("download_bytes", 0) for e in events), default=0)
    with server.lock:
        requested = [p for p in server.requests if p.startswith(route + "/")]
        completed = dict(server.completed_responses)
        sent = dict(server.sent_bytes)
    downloaded = route + "/update.zip" in requested
    delivered_archive = completed.get(route + "/update.zip") == len(archive_data) and received_bytes == len(archive_data)
    error_codes = {entry["code"] for entry in terminal.get("errors", []) if entry.get("domain") == "SUSparkleErrorDomain"}
    installed_version = plistlib.loads((old / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
    unchanged = tree_digest(old) == original_digest
    success = name in ("valid", "preview-allowed")
    require(neighbor.read_bytes() == b"unrelated fixture neighbor survives\n", "Unrelated neighbor changed")
    failure = None
    try:
        require(route + "/appcast.xml" in requested and completed.get(route + "/appcast.xml") == len(feed_data),
                f"{name}: native feed response was not completed")
        if success:
            require(terminal["event"] == "relaunched" and terminal.get("preferences_preserved") is True and
                    offered and verified_feed and delivered_archive and prepared and acknowledged and installed_version == "2" and not unchanged,
                    f"{name}: actual install/relaunch/preferences proof missing: {terminal}")
        else:
            require(unchanged and installed_version == "1" and not any(e["event"] in ("ready_to_install", "will_install", "relaunched") for e in events),
                    f"{name}: failed/cancelled update changed the old app")
            if name in ("equal-version", "older-version", "preview-filtered"):
                require(terminal["event"] == "not_found" and terminal.get("code") == 1001 and verified_feed and not offered and not downloaded,
                        f"{name}: native version/channel filter failed")
            elif name == "cancel":
                require(terminal["event"] == "cancelled" and terminal.get("cancellation_requested") is True and verified_feed and offered and downloaded
                        and 0 < received_bytes < len(archive_data) and 0 < sent.get(route + "/update.zip", 0) < len(archive_data)
                        and route + "/update.zip" not in completed and not installer_started,
                        "Cancellation did not interrupt a genuine partial native download")
            elif name == "tampered-feed":
                # Pinned 2.10.0 SUAppcastDriver wraps verifier SUValidationError (3002)
                # in SUAppcastParseError (1000). Network/launch errors cannot pass.
                require(terminal["event"] == "error" and {1000, 3002}.issubset(error_codes) and not offered and not downloaded,
                        "Tampered feed did not produce native signature rejection")
            else:
                require(terminal["event"] == "error" and verified_feed and offered and delivered_archive and not prepared,
                        f"{name}: complete native archive rejection evidence missing")
                if name == "invalid-archive":
                    require(3000 in error_codes and 3002 not in error_codes, "Malformed archive did not reach native unarchiving failure")
                else:
                    # SUUpdateValidator's pre-extraction signature rejection is
                    # SUInstallationError (4005), underlying SUValidationError (3002).
                    require({4005, 3002}.issubset(error_codes), "Archive signature rejection codes are missing")
    except RuntimeError as error:
        failure = str(error)
    result = {"passed": failure is None, "settled": True, "failure": failure, "terminal": terminal["event"], "offered": offered, "archive_requested": downloaded,
              "feed_signature_verified": verified_feed, "archive_received_bytes": received_bytes,
              "archive_response_completed": delivered_archive, "ready_to_install": prepared, "installer_started_callback": installer_started,
              "installer_checkpoint": acknowledged, "lifetime_probe_samples": lifetime.snapshots, "changing_lifetime_snapshots": lifetime.changing_snapshots,
              "sparkle_error_codes": sorted(error_codes), "installed_version": installed_version, "old_app_unchanged": unchanged,
              "preferences_preserved": terminal.get("preferences_preserved", False), "neighbor_unchanged": True,
              "elapsed_seconds": round(time.monotonic() - started, 2)}
    return result


def main():
    require(platform.system() == "Darwin" and os.getuid() == os.geteuid() and os.geteuid() != 0 and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted", "Native Sparkle fixture runs only on equal real/effective non-root UIDs on GitHub-hosted macOS")
    sha = os.environ.get("SOURCE_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha) and run(["/usr/bin/git", "-C", ROOT, "rev-parse", "HEAD"]) == sha,
            "Exact checked-out source SHA is required")
    require(run(["/usr/bin/xcodebuild", "-version"]).startswith("Xcode 16.4\n"), "Fixture requires Xcode 16.4")
    output = ROOT / "SparkleFixtureEvidence"
    output.mkdir(mode=0o700, exist_ok=False)
    owned = OwnedRoot()
    print(f"Owned native fixture root: {owned.path}; source {sha}", flush=True)
    evidence = {"source_sha": sha, "sparkle_version": "2.10.0", "package_sha256": PACKAGE_SHA256,
                "architecture": platform.machine(), "test_key": "PUBLIC RFC8032 section 7.1 vector 1, never production",
                "apple_trust_validated": False, "code_signing": "ad-hoc, non-hardened synthetic host and helpers",
                "scope": "Ed25519 verification, native installation/relaunch, and isolated preferences; not Developer ID or notarization",
                "cases": {}, "all_passed": False}
    server = None
    try:
        package_root = package(owned)
        framework = package_root / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        binary = owned.path / "SparkleFixture"
        run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
             "-mmacosx-version-min=15.0", "-F", framework.parent, "-framework", "AppKit", "-framework", "Sparkle",
             "-Wl,-rpath,@executable_path/../Frameworks", ROOT / "Scripts/Fixtures/SparkleUpdateFixture/main.m", "-o", binary])
        probe = owned.path / "FixtureLifetimeProbe"
        run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
             "-mmacosx-version-min=15.0", "-framework", "AppKit", ROOT / "Scripts/Fixtures/SparkleUpdateFixture/probe.m", "-o", probe])
        evidence["probe_preflight"] = preflight_probe(owned, probe)
        entitlements = owned.path / "empty-entitlements.plist"
        write_new(entitlements, plistlib.dumps({}))
        test_key, other_key = owned.path / "PUBLIC-RFC8032-vector1.txt", owned.path / "PUBLIC-RFC8032-vector2.txt"
        write_new(test_key, base64.b64encode(PUBLIC_TEST_SEED))
        write_new(other_key, base64.b64encode(PUBLIC_OTHER_SEED))
        server = FixtureServer()
        collect_cases(CASES, lambda name: scenario(name, owned, server, binary, framework, package_root / "bin/sign_update",
                                                test_key, other_key, entitlements, output, probe), evidence)
    except Exception as error:
        evidence["failure"] = str(error)
        raise
    finally:
        try:
            if server: server.close()
            owned.verify()
        except Exception as error:
            evidence["all_passed"] = False
            evidence["failure"] = str(error)
        write_new(output / "native-sparkle-evidence.json", json.dumps(evidence, indent=2, sort_keys=True).encode())
        os.close(owned.fd)
        # No recursive removal, no production key, and no real-app preferences.
    require(evidence["all_passed"], "Native Sparkle evidence is incomplete")


if __name__ == "__main__":
    main()
