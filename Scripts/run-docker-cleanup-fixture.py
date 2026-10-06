#!/usr/bin/env python3
"""Hosted-runner-only, marker-owned Docker daemon. No user Docker context, data or credentials.

Builds FROM scratch without pulls, runs the production Swift adapter against an
isolated daemon socket and verifies selected real deletion plus retained borders.
No existing daemon is contacted. No package installation or host setting change.
"""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("MOEKIT_DOCKER_FIXTURE") != "1":
        raise SystemExit("Refusing: requires explicit hosted-runner fixture opt-in")
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if sha != os.environ.get("SOURCE_SHA") or not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise SystemExit("Refusing: exact source SHA evidence missing")
    tools = {name: shutil.which(name) for name in ("docker", "dockerd", "swiftc", "sudo", "ldd")}
    if not all(tools.values()):
        raise SystemExit("Hosted runner lacks an expected preinstalled tool; no automatic installation")
    owner = Path(tempfile.mkdtemp(prefix="moekit-docker-", dir="/tmp"))
    (owner / "MARKER").write_text("MOEKIT_OWNED_DOCKER_FIXTURE_V1\n")
    (owner / "daemon.json").write_text("{}\n")
    (owner / "client").mkdir()
    (owner / "home").mkdir()
    sock = owner / "daemon.sock"
    evidence = ROOT / "DockerFixtureEvidence"
    evidence.mkdir(exist_ok=True)
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(owner / "home"),
           "DOCKER_CONFIG": str(owner / "client"), "DOCKER_BUILDKIT": "1"}
    base = [tools["docker"], "--config", str(owner / "client"), "--host", "unix://" + str(sock)]
    def docker(*args):
        return subprocess.check_output(base + list(args), env=env, cwd=owner, text=True, stderr=subprocess.STDOUT).strip()
    daemon_log = (evidence / "daemon.log").open("w")
    daemon = subprocess.Popen([tools["sudo"], "-n", tools["dockerd"],
        "--config-file=" + str(owner / "daemon.json"), "--host=unix://" + str(sock),
        "--data-root=" + str(owner / "data"), "--exec-root=" + str(owner / "exec"),
        "--pidfile=" + str(owner / "daemon.pid"), "--storage-driver=vfs",
        "--bridge=none", "--iptables=false", "--ip6tables=false", "--ip-forward=false", "--ip-masq=false",
        "--userland-proxy=false", "--group=" + str(os.getgid()),
        "--containerd-namespace=moekit-fixture", "--containerd-plugins-namespace=moekit-fixture-plugins"],
        stdout=daemon_log, stderr=subprocess.STDOUT, env=env, cwd=owner)
    try:
        for _ in range(120):
            if daemon.poll() is not None:
                raise RuntimeError("Owned daemon exited; see isolated daemon log")
            if sock.exists():
                try:
                    docker("version", "--format", "{{.Server.Version}}")
                    break
                except subprocess.CalledProcessError:
                    pass
            time.sleep(0.5)
        else:
            raise RuntimeError("Owned daemon did not become ready")
        context = owner / "context"
        context.mkdir()
        (context / "payload").write_text("owned fixture payload\n")
        (context / "Dockerfile").write_text("FROM scratch\nCOPY payload /payload\nCMD [\"/does-not-exist\"]\n")
        docker("build", "--pull=false", "--network=none", "--tag", "moekit-unused:fixture", str(context))
        unused_image = docker("image", "inspect", "--format", "{{.Id}}", "moekit-unused:fixture")
        (context / "payload").write_text("owned stopped-container fixture payload\n")
        docker("build", "--pull=false", "--network=none", "--tag", "moekit-stopped:fixture", str(context))
        stopped_image = docker("image", "inspect", "--format", "{{.Id}}", "moekit-stopped:fixture")
        volume = docker("volume", "create", "--label", "moekit.fixture=owned", "moekit-protected-volume")
        stopped = docker("container", "create", "--network=none", "--mount", "type=volume,source=" + volume + ",target=/retained",
                         "--label", "com.docker.compose.project=fixture-stopped", stopped_image)
        # A running sentinel uses only runner-owned OS binaries copied into FROM scratch.
        # ldd is applied only to the trusted OS /bin/sleep executable, never repository code.
        rootfs = context / "rootfs"
        rootfs.mkdir()
        dependencies = subprocess.check_output([tools["ldd"], "/bin/sleep"], text=True)
        paths = {"/bin/sleep"} | set(re.findall(r"(/[A-Za-z0-9_./+-]+)", dependencies))
        for value in paths:
            source = Path(value)
            if source.is_file():
                destination = rootfs / source.relative_to("/")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                destination.chmod(source.stat().st_mode & 0o777)
        (context / "Dockerfile").write_text('FROM scratch\nCOPY rootfs /\nCMD ["/bin/sleep", "600"]\n')
        docker("build", "--pull=false", "--network=none", "--tag", "moekit-survivor:fixture", str(context))
        survivor = docker("image", "inspect", "--format", "{{.Id}}", "moekit-survivor:fixture")
        running = docker("container", "run", "--detach", "--network=none", survivor)
        manifest = {"marker": "MOEKIT_OWNED_DOCKER_FIXTURE_V1", "socket": str(sock),
                    "unusedImage": unused_image, "stoppedImage": stopped_image, "survivorImage": survivor,
                    "stoppedContainer": stopped, "runningContainer": running, "volume": volume}
        manifest_path = owner / "manifest.json"
        manifest_path.write_text(json.dumps(manifest))
        binary = owner / "docker-fixture"
        sources = [ROOT / "Sources/DockerCleanup" / name for name in (
            "DockerCleanupModels.swift", "DockerSocketTransport.swift", "NativeDockerCleanupExecutor.swift")]
        subprocess.run([tools["swiftc"], "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                        *map(str, sources), str(ROOT / "Scripts/Fixtures/DockerCleanup/main.swift"), "-o", str(binary)], check=True)
        output = subprocess.check_output([str(binary), str(manifest_path)], text=True, timeout=180)
        proof = json.loads(output)
        proof["sourceSHA"] = sha
        (evidence / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof, indent=2))
    finally:
        # Only the verified PID file in this unique fixture scope is signalled.
        pidfile = owner / "daemon.pid"
        if pidfile.is_file() and (owner / "MARKER").read_text().strip() == "MOEKIT_OWNED_DOCKER_FIXTURE_V1":
            pid = int(pidfile.read_text().strip())
            subprocess.run([tools["sudo"], "-n", "kill", "-TERM", str(pid)], check=False)
        try:
            daemon.wait(timeout=30)
        except subprocess.TimeoutExpired:
            print("Owned daemon did not stop within 30 seconds; runner teardown will remove the fixture")
        daemon_log.close()
        # Do not recursively remove privileged daemon data while containers may still be exiting.
        # GitHub-hosted runner teardown owns final disposable workspace removal.

if __name__ == "__main__":
    main()
