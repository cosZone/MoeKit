#!/usr/bin/env python3
"""Owned-fixture tests for MoeKit's fixed remote supervisor and compiled gates.

No user remotes, Keychain reads, credentials, repository scripts, or network are
used. The real-Git integration uses an original compiled loopback protocol relay
standing in for remote-https, plus owned bare repos. It tests the ordinary Git
wire update and server compare-and-swap, not TLS/certificate/Keychain behavior.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import socket
import socketserver
import threading
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
URL = "https://example.test/owner/project.git"
REF = "refs/heads/main"
OLD = "a" * 40
SOURCE = "b" * 40

FIXTURE = r'''
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int same(const char *key, const char *value) { const char *got = getenv(key); return got && !strcmp(got, value); }
static int has(int n, char **a, const char *v) { for (int i = 0; i < n; i++) if (!strcmp(a[i], v)) return 1; return 0; }
static int repeat(int fd, size_t n) { char b[4096]; memset(b, 'x', sizeof(b)); while (n) { size_t c = n < sizeof(b) ? n : sizeof(b); if (write(fd, b, c) != (ssize_t)c) return 91; n -= c; } return 0; }
int main(int argc, char **argv) {
    char cwd[4096]; if (!getcwd(cwd, sizeof(cwd))) return 90;
    if (!same("HOME", cwd) || !same("LC_ALL", "C") || !same("GIT_CONFIG_NOSYSTEM", "1") ||
        !same("GIT_CONFIG_SYSTEM", "/dev/null") || !same("GIT_CONFIG_GLOBAL", "/dev/null") ||
        !same("GIT_ALLOW_PROTOCOL", "https") || !same("GIT_TERMINAL_PROMPT", "0") ||
        getenv("GIT_CONFIG_PARAMETERS") || getenv("GIT_CONFIG_COUNT") || getenv("GIT_DIR") ||
        getenv("GIT_WORK_TREE") || getenv("GIT_OBJECT_DIRECTORY") || getenv("GIT_ALTERNATE_OBJECT_DIRECTORIES") ||
        getenv("HTTPS_PROXY") || getenv("ALL_PROXY") || getenv("GIT_ASKPASS") || getenv("GIT_SSH_COMMAND") ||
        getenv("GIT_TRACE") || getenv("GIT_TRACE_CURL") || getenv("GIT_SSL_NO_VERIFY") || getenv("UNRELATED_SECRET")) return 90;
    const char *fixed[] = {"--no-optional-locks", "--no-replace-objects", "protocol.allow=never", "protocol.https.allow=always",
        "credential.helper=", "credential.helper=moekit-keychain", "credential.useHttpPath=true", "credential.interactive=false",
        "core.askPass=", "http.followRedirects=false", "http.sslVerify=true", "http.proxy=", "http.extraHeader=", "http.cookieFile=",
        "http.saveCookies=false", "push.followTags=false", "push.gpgSign=false", "submodule.recurse=false", "maintenance.auto=false", "gc.auto=0"};
    for (size_t i = 0; i < sizeof(fixed)/sizeof(fixed[0]); i++) if (!has(argc, argv, fixed[i])) return 90;
    int push = has(argc, argv, "push");
    if (push) {
        if (!has(argc, argv, "--no-force") || !has(argc, argv, "--no-follow-tags") || !has(argc, argv, "--no-signed") || !has(argc, argv, "--recurse-submodules=no")) return 90;
        char spec[400]; snprintf(spec, sizeof(spec), "%s:%s", getenv("MOEKIT_REMOTE_SOURCE"), getenv("MOEKIT_REMOTE_REF"));
        if (strcmp(argv[argc-1], spec) || strcmp(argv[argc-2], getenv("MOEKIT_REMOTE_URL")) || strcmp(argv[argc-3], "--")) return 90;
    } else if (!has(argc, argv, "ls-remote") || !has(argc, argv, "--refs") || !has(argc, argv, "--exit-code") ||
        !has(argc, argv, "core.hooksPath=/dev/null") || strcmp(argv[argc-1], getenv("MOEKIT_REMOTE_REF")) ||
        strcmp(argv[argc-2], getenv("MOEKIT_REMOTE_URL")) || strcmp(argv[argc-3], "--")) return 90;
    for (int i = 0; i < argc; i++) if (!strcmp(argv[i], "--force") || !strncmp(argv[i], "--force-with-lease", 18) || !strcmp(argv[i], "--no-verify")) return 90;
    FILE *f = fopen("fixture-mode", "r"); if (!f) return 90;
    char mode[64]; if (!fgets(mode, sizeof(mode), f)) return 90; fclose(f);
    if (!strcmp(mode, "floodout")) return repeat(1, 4097);
    if (!strcmp(mode, "flooderr")) return repeat(2, 65537);
    if (!strcmp(mode, "sleep")) { sleep(10); return 0; }
    if (!strcmp(mode, "failed")) { puts("synthetic-sensitive-value"); fputs("synthetic-sensitive-value", stderr); return 1; }
    if (!strcmp(mode, "missing")) return 2;
    if (strcmp(mode, "success")) return 90;
    fputs("synthetic-sensitive-value", stderr);
    if (push) puts("synthetic-sensitive-value");
    else printf("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n");
    return 0;
}
'''

# The credential fixture never sees actual credentials or a Keychain. An owned
# marker proves whether our wrapper invoked it for a particular operation.
CREDENTIAL = r'''
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "get")) return 90;
    char data[2048]; ssize_t n = read(0, data, sizeof(data)-1); if (n <= 0) return 90; data[n] = 0;
    if (strcmp(data, "protocol=https\nhost=example.test\n\n")) return 90;
    int fd = open("credential-called", O_WRONLY|O_CREAT|O_EXCL, 0600); if (fd < 0) return 90; close(fd);
    puts("username=fixture-user\npassword=fixture-only-value\n"); return 0;
}
'''

# Original native loopback relay. It stands in for remote-https only in owned
# fixtures and forwards Git protocol bytes to a test server outside the client
# supervisor's no-file-write resource limit. This is not a TLS test.
RELAY = r'''
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static int all(int fd, const char *b, size_t n) { while (n) { ssize_t k=write(fd,b,n); if(k<0&&errno==EINTR)continue; if(k<=0)return -1; b+=k;n-=(size_t)k; }return 0; }
static int line(char *b,size_t cap){size_t n=0;while(n+1<cap){ssize_t k=read(0,b+n,1);if(k<0&&errno==EINTR)continue;if(k!=1)return -1;if(b[n++]=='\n'){b[n]=0;return 0;}}return -1;}
int main(int argc,char **argv){
    if(argc!=3||strcmp(argv[1],getenv("MOEKIT_REMOTE_URL"))||strcmp(argv[2],getenv("MOEKIT_REMOTE_URL")))return 90;
    char command[128];if(line(command,sizeof(command))||strcmp(command,"capabilities\n"))return 90;
    if(all(1,"connect\n\n",9)||line(command,sizeof(command)))return 90;
    const char *operation=!strcmp(command,"connect git-receive-pack\n")?"receive-pack\n":
        !strcmp(command,"connect git-upload-pack\n")?"upload-pack\n":NULL;
    if(!operation)return 90;
    FILE *f=fopen("fixture-port","r");int port=0;if(!f||fscanf(f,"%d",&port)!=1)return 90;fclose(f);
    if(port<1024||port>65535)return 90;
    int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return 90;
    struct sockaddr_in address;memset(&address,0,sizeof(address));address.sin_family=AF_INET;address.sin_port=htons((unsigned short)port);
    if(inet_pton(AF_INET,"127.0.0.1",&address.sin_addr)!=1||connect(fd,(struct sockaddr *)&address,sizeof(address))||
       all(fd,operation,strlen(operation))||all(1,"\n",1))return 90;
    struct pollfd fds[2]={{0,POLLIN,0},{fd,POLLIN,0}};
    for(;;){int n=poll(fds,2,1000);if(n<0&&errno==EINTR)continue;if(n<0)return 90;
        for(int i=0;i<2;i++){if(!(fds[i].revents&(POLLIN|POLLHUP|POLLERR)))continue;
            char buffer[16384];ssize_t k=read(fds[i].fd,buffer,sizeof(buffer));
            if(k>0){if(all(i==0?fd:1,buffer,(size_t)k))return 90;}
            else if(k==0){if(i==1){close(fd);return 0;}shutdown(fd,SHUT_WR);fds[0].fd=-1;}
            else if(errno!=EINTR)return 90;}}
}
'''


def clean_environment(home):
    return {k: os.environ[k] for k in ("PATH", "DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "TMPDIR") if k in os.environ} | {
        "HOME": str(home), "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": ""}


class RemoteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="moekit-remote-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name).resolve()
        cls.helper = cls.base / "GitRemoteTransport"
        cls.fixture = cls.base / "fixture"
        cls.credential = cls.base / "credential"
        cls.relay = cls.base / "relay"
        sources = [(ROOT / "Helpers/GitRemoteTransport/main.c", cls.helper,
                    ["-DGIT_WALL_SECONDS=3", "-DGIT_CPU_SECONDS=2"])]
        for text, target in ((FIXTURE, cls.fixture), (CREDENTIAL, cls.credential), (RELAY, cls.relay)):
            source = target.with_suffix(".c"); source.write_text(text)
            sources.append((source, target, []))
        for source, target, flags in sources:
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", *flags,
                            str(source), "-o", str(target)], check=True, timeout=60, env=clean_environment(cls.base))
        if os.uname().sysname == "Darwin":
            cls.host_git = subprocess.check_output(["/usr/bin/xcrun", "--find", "git"], text=True).strip()
        else:
            cls.host_git = shutil.which("git")
        if not cls.host_git: raise AssertionError("Git is required for isolated native integration fixtures")

    def setUp(self):
        self.temporary_run = tempfile.TemporaryDirectory(prefix="run-", dir=self.base)
        self.addCleanup(self.temporary_run.cleanup)
        self.root = Path(self.temporary_run.name)
        self.snapshot = self.root / "snapshot"; self.snapshot.mkdir(mode=0o700)
        (self.snapshot / "config").write_text("[core]\nrepositoryformatversion = 0\nbare = true\n")
        (self.snapshot / "HEAD").write_text("ref: refs/heads/private\n")
        self.tools = self.snapshot / "transport-tools"; self.tools.mkdir(mode=0o700)
        (self.tools / "hooks").mkdir(mode=0o700)
        for source, name in ((self.fixture, "git"), (self.fixture, "git-remote-https"),
                             (self.credential, "git-credential-osxkeychain"),
                             (self.helper, "git-credential-moekit-keychain"), (self.helper, "hooks/pre-push")):
            shutil.copyfile(source, self.tools / name); (self.tools / name).chmod(0o700)
        self.environment = clean_environment(self.root) | {
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "!MUST-NOT-RUN",
            "GIT_CONFIG_PARAMETERS": "bad config", "GIT_DIR": "/must-not-inherit", "GIT_WORK_TREE": "/must-not-inherit",
            "GIT_OBJECT_DIRECTORY": "/must-not-inherit", "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/must-not-inherit",
            "GIT_ASKPASS": "/must-not-inherit", "GIT_SSH_COMMAND": "must-not-inherit", "HTTPS_PROXY": "must-not-inherit",
            "ALL_PROXY": "must-not-inherit", "GIT_TRACE": "1", "GIT_TRACE_CURL": "1", "GIT_SSL_NO_VERIFY": "1",
            "UNRELATED_SECRET": "synthetic-do-not-inherit"}

    def invoke(self, operation="inspect", *, url=URL, ref=REF, source=SOURCE, old="-", mode="success"):
        (self.snapshot / "fixture-mode").write_text(mode)
        p = subprocess.Popen([str(self.helper), str(self.tools), str(self.snapshot), operation, url, ref, source, old],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment)
        try:
            p.wait(timeout=6)
            out, err = p.communicate()
            return p.returncode, out, err
        finally:
            if p.poll() is None: p.kill(); p.wait()
            for s in (p.stdin, p.stdout, p.stderr):
                if s: s.close()

    def gate(self, data, *, url=URL, ref=REF, source=SOURCE, old=OLD, remote=None):
        env = clean_environment(self.root) | {"MOEKIT_REMOTE_URL": url, "MOEKIT_REMOTE_REF": ref,
              "MOEKIT_REMOTE_SOURCE": source, "MOEKIT_REMOTE_OLD": old}
        return subprocess.run([str(self.tools / "hooks/pre-push"), url, remote or url], input=data,
                              capture_output=True, env=env, timeout=5)

    def test_supervisor_fixed_contract_and_no_diagnostics(self):
        code, out, err = self.invoke()
        self.assertEqual((code, out, err), (0, (OLD + "\t" + REF + "\n").encode(), b""))
        self.assertEqual(self.invoke("push", old=OLD), (0, b"", b""))

    def test_failures_limits_and_missing_ref_discard_output(self):
        for mode, status in (("failed", 73), ("floodout", 71), ("flooderr", 71), ("sleep", 72), ("missing", 77)):
            with self.subTest(mode=mode): self.assertEqual(self.invoke(mode=mode), (status, b"", b""))

    def test_url_injection_protocol_and_host_spoof_refused(self):
        for value in ("http://example.test/a.git", "ssh://example.test/a.git", "https://user@example.test/a.git",
                      "https://example.test@evil.test/a.git", "https://example.test:443/a.git", "https://EXAMPLE.test/a.git",
                      "https://example.test./a.git", "https://example..test/a.git", "https://example.test/a%2fgit",
                      "https://example.test/a.git?token=x", "https://example.test/a.git#x", "https://example.test/a.git\n",
                      "https://exаmple.test/a.git", "https://xn--example.test/a.git", "https://127.0.0.1/a.git",
                      "https://example.local/a.git", "https://example.test/a/../b", "https://example.test/-x",
                      "https://example.test//x", "https://example.test/x/", "https://example.test/a;echo-x",
                      "https://example.test/a$(id)", "https://example.test/a`id`", "https://example.test/a\\x"):
            with self.subTest(url=value): self.assertEqual(self.invoke(url=value), (64, b"", b""))

    def test_ref_oid_and_operation_injection_refused(self):
        for value in ("main", "+refs/heads/main", "refs/tags/main", "refs/heads/-x", "refs/heads/a..b",
                      "refs/heads/a.lock", "refs/heads/.hidden", "refs/heads/a//b", "refs/heads/a:",
                      "refs/heads/a*", "refs/heads/a@{1}", "refs/heads/main\n", "refs/heads/a b"):
            with self.subTest(ref=value): self.assertEqual(self.invoke(ref=value), (64, b"", b""))
        for value in ("HEAD", "-x", "a" * 39, "A" * 40, "0" * 40, SOURCE + ":x"):
            self.assertEqual(self.invoke(source=value), (64, b"", b""))
        for value in ("fetch", "--push", "push --force"):
            self.assertEqual(self.invoke(operation=value), (64, b"", b""))
        self.assertEqual(self.invoke("push", old="-"), (64, b"", b""))

    def test_supervisor_parent_eof_cancels_without_diagnostics(self):
        (self.snapshot / "fixture-mode").write_text("sleep")
        p = subprocess.Popen([str(self.helper), str(self.tools), str(self.snapshot), "inspect", URL, REF, SOURCE, "-"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment)
        out, err = p.communicate(timeout=5)
        self.assertEqual((p.returncode, out, err), (74, b"", b""))

    def test_private_namespace_symlink_and_hostile_config_refused(self):
        original = self.tools / "git"
        original.unlink(); original.symlink_to(self.fixture)
        self.assertEqual(self.invoke(), (64, b"", b""))
        original.unlink(); shutil.copyfile(self.fixture, original); original.chmod(0o700)
        (self.snapshot / "config").write_text("[include]\npath = /must-not-read\n")
        self.assertEqual(self.invoke(), (64, b"", b""))

    def test_gate_exact_single_advertised_record(self):
        record = f"{SOURCE} {SOURCE} {REF} {OLD}\n".encode()
        self.assertEqual(self.gate(record).returncode, 0)
        self.assertEqual(self.gate(b"").returncode, 0)  # no proposed mutation
        for value in (record + record, record.rstrip(), record + b"\n", record.replace(OLD.encode(), b"c" * 40),
                      record.replace(REF.encode(), b"refs/heads/other"), record.replace(SOURCE.encode(), b"d" * 40, 1),
                      record.replace(OLD.encode(), b"0" * 40), record + b"\x00", b"x" * 1025):
            with self.subTest(record=value): self.assertNotEqual(self.gate(value).returncode, 0)
        self.assertNotEqual(self.gate(record, remote="https://other.test/owner/project.git").returncode, 0)

    def test_get_only_exact_keychain_scope_and_no_store_erase(self):
        helper = self.tools / "git-credential-moekit-keychain"
        env = clean_environment(self.root) | {"MOEKIT_REMOTE_URL": URL, "MOEKIT_REMOTE_TOOLS": str(self.tools)}
        request = b"protocol=https\nhost=example.test\npath=owner/project.git\n\n"
        def call(action, data=request):
            return subprocess.run([str(helper), action], input=data, capture_output=True, env=env, cwd=self.root, timeout=5)
        for action in ("store", "erase"):
            value = call(action, request + b"password=synthetic\n")
            self.assertEqual((value.returncode, value.stdout, value.stderr), (0, b"", b""))
            self.assertFalse((self.root / "credential-called").exists())
        for data in (request.replace(b"https", b"http"), request.replace(b"example.test", b"other.test"),
                     request.replace(b"project.git", b"other.git"), request.replace(b"\n\n", b"\nusername=other\n\n"),
                     request + b"host=other.test\n", request.replace(b"\n\n", b"\nurl=https://other.test/a\n\n")):
            self.assertNotEqual(call("get", data).returncode, 0)
            self.assertFalse((self.root / "credential-called").exists())
        value = call("get")
        self.assertEqual(value.returncode, 0)
        self.assertEqual(value.stdout, b"username=fixture-user\npassword=fixture-only-value\n\n")
        self.assertTrue((self.root / "credential-called").exists())

    def test_non_authoritative_credential_metadata_is_ignored(self):
        helper = self.tools / "git-credential-moekit-keychain"
        env = clean_environment(self.root) | {"MOEKIT_REMOTE_URL": URL, "MOEKIT_REMOTE_TOOLS": str(self.tools)}
        base = b"protocol=https\nhost=example.test\npath=owner/project.git\n"
        for metadata in (b"capability[]=authtype\ncapability[]=state\n", b'wwwauth[]=Basic realm="owned fixture"\n',
                         b"state[]=opaque-non-authoritative-fixture\n"):
            value = subprocess.run([str(helper), "get"], input=base + metadata + b"\n", capture_output=True, env=env, cwd=self.root, timeout=5)
            self.assertEqual(value.returncode, 0)
            self.assertEqual(value.stdout, b"username=fixture-user\npassword=fixture-only-value\n\n")
            (self.root / "credential-called").unlink()
        for metadata in (b"capability[]=state\nurl=https://other.test/a\n", b"wwwauth[]=Basic\nhost=other.test\n",
                         b"capability[]=authtype\npassword=must-not-use\n", b"wwwauth[]=" + b"x" * 4096 + b"\n"):
            value = subprocess.run([str(helper), "get"], input=base + metadata + b"\n", capture_output=True, env=env, cwd=self.root, timeout=5)
            self.assertNotEqual(value.returncode, 0)
            self.assertFalse((self.root / "credential-called").exists())

    def test_actual_git_credential_dispatch_accepts_current_protocol_metadata(self):
        # Invoke the installed Git's real credential protocol, not a reimplementation.
        # No HTTP request, Keychain call, or real credential is involved.
        env = clean_environment(self.root) | {"MOEKIT_REMOTE_URL": URL, "MOEKIT_REMOTE_TOOLS": str(self.tools)}
        helper = self.tools / "git-credential-moekit-keychain"
        value = subprocess.run([self.host_git, "-c", "credential.helper=", "-c", "credential.helper=" + str(helper),
                                "-c", "credential.useHttpPath=true", "-c", "credential.interactive=false", "credential", "fill"],
                               input=b'protocol=https\nhost=example.test\npath=owner/project.git\nwwwauth[]=Basic realm="owned fixture"\n\n',
                               capture_output=True, cwd=self.root, env=env, timeout=5)
        self.assertEqual(value.returncode, 0, value.stderr)
        self.assertIn(b"username=fixture-user\n", value.stdout)
        self.assertIn(b"password=fixture-only-value\n", value.stdout)
        self.assertTrue((self.root / "credential-called").exists())

    def git(self, *args, cwd=None):
        env = clean_environment(self.root) | {"GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test",
             "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test"}
        return subprocess.run([self.host_git, "-c", "core.hooksPath=/dev/null", *args], cwd=cwd or self.root,
                              env=env, capture_output=True, check=True, timeout=10).stdout.decode().strip()

    def setup_real_transport(self):
        source = self.root / "owned-source"
        remote = self.root / "owned-remote.git"
        self.git("init", "-b", "main", str(source)); self.git("init", "--bare", str(remote))
        (source / "file").write_text("one\n")
        self.git("add", "file", cwd=source); self.git("commit", "-m", "base", cwd=source)
        old = self.git("rev-parse", "HEAD", cwd=source)
        (source / "file").write_text("two\n")
        self.git("add", "file", cwd=source); self.git("commit", "-m", "source", cwd=source)
        head = self.git("rev-parse", "HEAD", cwd=source)
        (source / "file").write_text("three\n")
        self.git("add", "file", cwd=source); self.git("commit", "-m", "other", cwd=source)
        other = self.git("rev-parse", "HEAD", cwd=source)
        for destination in (self.snapshot, remote):
            if destination == self.snapshot:
                (destination / "HEAD").write_text("ref: refs/heads/private\n")
                (destination / "config").write_text("[core]\nrepositoryformatversion = 0\nbare = true\n")
                (destination / "refs").mkdir()
            shutil.copytree(source / ".git/objects", destination / "objects", dirs_exist_ok=True)
        self.git("--git-dir=" + str(remote), "update-ref", REF, old)
        shutil.copyfile(Path(self.host_git).resolve(), self.tools / "git"); (self.tools / "git").chmod(0o700)
        shutil.copyfile(self.relay, self.tools / "git-remote-https"); (self.tools / "git-remote-https").chmod(0o700)
        fixture = self
        self.remote_requests = []
        class Handler(socketserver.BaseRequestHandler):
            def handle(server_self):
                stream = server_self.request.makefile("rb", buffering=0)
                operation = stream.readline(80).decode().strip()
                if operation not in ("upload-pack", "receive-pack"): return
                fixture.remote_requests.append(operation)
                env = clean_environment(fixture.root)
                process = subprocess.Popen([fixture.host_git, "-c", "core.hooksPath=/dev/null",
                    "-c", "receive.denyNonFastForwards=true", operation, str(remote)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
                try:
                    advertisement = bytearray()
                    while True:
                        header = process.stdout.read(4)
                        if len(header) != 4: return
                        length = int(header, 16); advertisement.extend(header)
                        if length == 0: break
                        if length < 4 or length > 65520: return
                        advertisement.extend(process.stdout.read(length - 4))
                    race = fixture.snapshot / "fixture-race"
                    if operation == "receive-pack" and race.exists():
                        fixture.git("--git-dir=" + str(remote), "update-ref", REF, race.read_text().strip())
                    server_self.request.sendall(advertisement)
                    def forward():
                        try:
                            while data := stream.read(16384):
                                process.stdin.write(data); process.stdin.flush()
                        except (BrokenPipeError, OSError): pass
                        finally:
                            try: process.stdin.close()
                            except OSError: pass
                    thread = threading.Thread(target=forward, daemon=True); thread.start()
                    drop = operation == "receive-pack" and (fixture.snapshot / "fixture-drop-ack").exists()
                    while data := process.stdout.read(16384):
                        if not drop: server_self.request.sendall(data)
                    server_self.request.shutdown(socket.SHUT_WR)
                    process.wait(timeout=4)
                except (OSError, subprocess.TimeoutExpired): pass
                finally:
                    if process.poll() is None: process.kill(); process.wait()
                    process.stdout.close()
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True
        server = Server(("127.0.0.1", 0), Handler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True); server_thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), server_thread.join(timeout=3)))
        (self.snapshot / "fixture-port").write_text(str(server.server_address[1]))
        return remote, old, head, other

    def test_real_git_ordinary_push_and_exact_remote_read(self):
        remote, old, head, _ = self.setup_real_transport()
        self.assertEqual(self.invoke(source=head)[0:2], (0, (old + "\t" + REF + "\n").encode()))
        self.assertEqual(self.invoke("push", source=head, old=old), (0, b"", b""))
        self.assertEqual(self.invoke(source=head), (0, (head + "\t" + REF + "\n").encode(), b""))
        self.assertEqual(self.git("--git-dir=" + str(remote), "rev-parse", REF), head)

    def test_real_git_gate_refuses_changed_advertisement_and_creation(self):
        remote, old, head, other = self.setup_real_transport()
        self.git("--git-dir=" + str(remote), "update-ref", REF, other)
        self.assertNotEqual(self.invoke("push", source=head, old=old)[0], 0)
        self.assertEqual(self.git("--git-dir=" + str(remote), "rev-parse", REF), other)
        self.git("--git-dir=" + str(remote), "update-ref", "-d", REF)
        self.assertNotEqual(self.invoke("push", source=head, old=old)[0], 0)
        self.assertEqual(self.invoke(source=head)[0], 77)

    def test_real_git_server_cas_refuses_post_advertisement_race(self):
        remote, old, head, other = self.setup_real_transport()
        (self.snapshot / "fixture-race").write_text(other + "\n")
        self.assertNotEqual(self.invoke("push", source=head, old=old)[0], 0)
        self.assertEqual(self.git("--git-dir=" + str(remote), "rev-parse", REF), other)

    def test_real_git_gate_refuses_fast_forward_from_unapproved_advertisement(self):
        remote, old, middle, head = self.setup_real_transport()
        # Current old is still an ancestor of source, so plain Git would allow
        # this update. Only the native gate rejects the unapproved advertisement.
        self.assertNotEqual(self.invoke("push", source=head, old=middle)[0], 0)
        self.assertEqual(self.git("--git-dir=" + str(remote), "rev-parse", REF), old)

    def test_lost_push_ack_is_reconciled_by_exact_read_without_retry(self):
        remote, old, head, _ = self.setup_real_transport()
        (self.snapshot / "fixture-drop-ack").write_text("owned fixture")
        self.assertNotEqual(self.invoke("push", source=head, old=old)[0], 0)
        self.assertEqual(self.git("--git-dir=" + str(remote), "rev-parse", REF), head)
        self.assertEqual(self.invoke(source=head), (0, (head + "\t" + REF + "\n").encode(), b""))
        self.assertEqual(self.remote_requests.count("receive-pack"), 1)

    def test_real_git_config_cannot_replace_native_gate(self):
        remote, old, head, other = self.setup_real_transport()
        marker = self.root / "must-not-exist"
        hostile = self.root / "hostile-hooks"; hostile.mkdir()
        (hostile / "pre-push").write_text("#!/bin/sh\nprintf unsafe > '" + str(marker) + "'\n")
        (hostile / "pre-push").chmod(0o700)
        with (self.snapshot / "config").open("a") as f:
            f.write("\n[core]\nhooksPath = " + str(hostile) + "\n[credential]\nhelper = !printf unsafe\n")
        self.git("--git-dir=" + str(remote), "update-ref", REF, other)
        self.assertNotEqual(self.invoke("push", source=head, old=old)[0], 0)
        self.assertFalse(marker.exists())
        self.assertEqual(self.git("--git-dir=" + str(remote), "rev-parse", REF), other)


if __name__ == "__main__": unittest.main()
