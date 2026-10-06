// Original MoeKit fixed HTTPS transport supervisor and native policy adapters.
// The Swift caller verifies copied binaries and the private config-free snapshot.
// No repository-provided hooks, credential helpers, or shell text are accepted.
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#endif

#ifndef GIT_WALL_SECONDS
#define GIT_WALL_SECONDS 60
#endif
#ifndef GIT_CPU_SECONDS
#define GIT_CPU_SECONDS 20
#endif
#ifndef GIT_MEMORY_LIMIT_BYTES
#define GIT_MEMORY_LIMIT_BYTES (512ULL * 1024 * 1024)
#endif
#define OUT_LIMIT 4096
#define ERR_LIMIT (64 * 1024)

enum { INVALID = 64, INTERNAL = 70, OUTPUT_LIMIT = 71, TIME_LIMIT = 72,
       CHILD_FAILED = 73, CANCELLED = 74, NOT_ANCESTOR = 75, MEMORY_LIMIT = 76, MISSING_REF = 77 };
static volatile sig_atomic_t cancelled = 0;
static void signal_cancel(int sig) { (void)sig; cancelled = 1; }
static double now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return -1;
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static int limit(int resource, rlim_t value) {
    struct rlimit r = { value, value };
    return setrlimit(resource, &r);
}
static bool absolute(const char *p) {
    return p && p[0] == '/' && p[1] && strlen(p) < 4096;
}
static int make_pipe(int fds[2]) {
    if (pipe(fds)) return -1;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) || fcntl(fds[1], F_SETFD, FD_CLOEXEC)) {
        close(fds[0]); close(fds[1]); return -1;
    }
    return 0;
}
static int write_all(int fd, const char *p, size_t size) {
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n; size -= (size_t)n;
    }
    return 0;
}
// Keep the direct child unreaped until group termination is over. Its reserved
// PID is the PGID: a newly reused PID cannot become this cancellation target.
static bool owns_child(pid_t child) {
    siginfo_t info; memset(&info, 0, sizeof(info));
    int result;
    do { result = waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT); } while (result < 0 && errno == EINTR);
    return result == 0;
}
static void stop_and_reap(pid_t child) {
    // Never signal if another mechanism has already reaped this child.
    if (!owns_child(child)) return;
    (void)kill(-child, SIGKILL);
    (void)kill(child, SIGKILL); // also owns child before its setpgid handshake
    int status;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}
// Bounded final delivery also watches cancellation; a stalled reader cannot
// leave the supervisor running forever after the analyzer has exited.
static int flush_output(int fd, const char *bytes, size_t size, double started) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return INTERNAL;
    while (size) {
        if (cancelled) return CANCELLED;
        double current = now();
        if (current < 0) return INTERNAL;
        if (current - started >= GIT_WALL_SECONDS) return TIME_LIMIT;
        struct pollfd fds[2] = {{fd, POLLOUT, 0}, {STDIN_FILENO, POLLIN, 0}};
        int n = poll(fds, 2, 25);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return INTERNAL;
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) return CANCELLED;
        if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) return INTERNAL;
        if (!(fds[0].revents & POLLOUT)) continue;
        ssize_t written = write(fd, bytes, size);
        if (written < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (written <= 0) return INTERNAL;
        bytes += written; size -= (size_t)written;
    }
    return 0;
}
// The helper is single-threaded at entry. Enumerate only its own descriptor
// table before making any pipes; no caller-owned descriptors reach analysis.
static int close_inherited_descriptors(void) {
    DIR *directory = opendir("/dev/fd");
    if (!directory) return -1;
    int inventory = dirfd(directory);
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(directory))) {
        char *end = NULL;
        long fd = strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end || fd < 3 || fd == inventory || fd > INT32_MAX) continue;
        (void)close((int)fd);
        errno = 0;
    }
    int error = errno;
    closedir(directory);
    return error ? -1 : 0;
}
static void setup_failure(int ready, int stage) {
    int code = errno;
    char report[32];
    int length = snprintf(report, sizeof(report), "E%d:%d", stage, code);
    if (length > 0 && length < (int)sizeof(report)) (void)write_all(ready, report, (size_t)length);
    _exit(INTERNAL);
}
/* Native adapters below never execute shell text. Git's fixed credential-helper
 * dispatch may itself use its installed shell. The command is always the
 * compiled-in helper name, with no URL/ref/path interpolation. */
static bool oid(const char *s) {
    return s && strlen(s) == 40 && strspn(s, "0123456789abcdef") == 40 &&
        strcmp(s, "0000000000000000000000000000000000000000");
}
static bool atom(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
}
static bool reference(const char *s) {
    if (!s || strncmp(s, "refs/heads/", 11) || strlen(s) <= 11 || strlen(s) > 251 || strstr(s, "..")) return false;
    const char *start = s + 11;
    for (const char *p = start;; ++p) {
        if (*p && *p != '/' && !atom(*p)) return false;
        if (*p != '/' && *p) continue;
        size_t n = (size_t)(p - start);
        if (!n || start[0] == '.' || start[0] == '-' || p[-1] == '.' ||
            (n >= 5 && !strncmp(p - 5, ".lock", 5))) return false;
        if (!*p) break;
        start = p + 1;
    }
    return true;
}
static bool endpoint(const char *s, char host[254], char path[1025]) {
    if (!s || strlen(s) > 2048 || strncmp(s, "https://", 8)) return false;
    const char *slash = strchr(s + 8, '/');
    if (!slash || slash == s + 8 || slash - (s + 8) > 253 || !slash[1] || strlen(slash + 1) > 1024) return false;
    size_t h = (size_t)(slash - (s + 8));
    memcpy(host, s + 8, h); host[h] = 0;
    const char *start = host; int labels = 0;
    for (const char *p = host;; ++p) {
        if (*p && *p != '.' && !((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '-')) return false;
        if (*p != '.' && *p) continue;
        size_t n = (size_t)(p - start);
        if (!n || n > 63 || *start == '-' || p[-1] == '-' || (n >= 4 && !strncmp(start, "xn--", 4))) return false;
        ++labels;
        if (!*p) {
            for (const char *c = start; *c; ++c) if (*c < 'a' || *c > 'z') return false;
            if (!strcmp(start, "localhost") || !strcmp(start, "local") || !strcmp(start, "internal")) return false;
            break;
        }
        start = p + 1;
    }
    if (labels < 2) return false;
    strcpy(path, slash + 1); start = path;
    for (const char *p = path;; ++p) {
        if (*p && *p != '/' && !atom(*p)) return false;
        if (*p != '/' && *p) continue;
        size_t n = (size_t)(p - start);
        if (!n || start[0] == '-' || (n == 1 && *start == '.') || (n == 2 && !strncmp(start, "..", 2))) return false;
        if (!*p) break;
        start = p + 1;
    }
    return true;
}
static bool regular_private(const char *p) {
    struct stat s;
    return !lstat(p, &s) && S_ISREG(s.st_mode) && s.st_uid == geteuid() &&
        (s.st_mode & 0777) == 0700 && s.st_nlink == 1;
}
static bool fixed_file(const char *directory, const char *name, const char *expected) {
    char path[4096];
    int count = snprintf(path, sizeof(path), "%s/%s", directory, name);
    if (count <= 0 || count >= (int)sizeof(path)) return false;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat status; char bytes[256];
    bool valid = !fstat(fd, &status) && S_ISREG(status.st_mode) && status.st_uid == geteuid() &&
        !(status.st_mode & 0022) && status.st_nlink == 1 && status.st_size == (off_t)strlen(expected);
    ssize_t size = valid ? read(fd, bytes, sizeof(bytes)) : -1;
    close(fd);
    return valid && size == (ssize_t)strlen(expected) && !memcmp(bytes, expected, (size_t)size);
}
static int bounded_input(char *buffer, size_t maximum, size_t *length) {
    *length = 0;
    for (;;) {
        if (*length == maximum) return INVALID;
        ssize_t n = read(STDIN_FILENO, buffer + *length, maximum - *length);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return INTERNAL;
        if (!n) break;
        *length += (size_t)n;
    }
    if (memchr(buffer, 0, *length)) return INVALID;
    buffer[*length] = 0; return 0;
}
static int push_gate(int argc, char **argv) {
    const char *url = getenv("MOEKIT_REMOTE_URL"), *ref = getenv("MOEKIT_REMOTE_REF");
    const char *source = getenv("MOEKIT_REMOTE_SOURCE"), *old = getenv("MOEKIT_REMOTE_OLD");
    char host[254], path[1025];
    if (argc != 3 || !endpoint(url, host, path) || !reference(ref) || !oid(source) || !oid(old) ||
        strcmp(argv[1], url) || strcmp(argv[2], url)) return INVALID;
    char input[1025], expected[1025]; size_t size;
    int result = bounded_input(input, 1024, &size); if (result) return result;
    // No update (already up to date) is safe. Any proposed update must be exactly
    // the single approved raw source OID, remote ref, and advertised old OID.
    if (!size) return 0;
    int length = snprintf(expected, sizeof(expected), "%s %s %s %s\n", source, source, ref, old);
    return length > 0 && length < (int)sizeof(expected) && size == (size_t)length &&
        !memcmp(input, expected, size) ? 0 : INVALID;
}
static int credential_get(int argc, char **argv) {
    if (argc != 2) return INVALID;
    // Saving or deleting credentials was not authorized. Do not invoke the
    // Apple helper for store/erase, even after authentication success/failure.
    if (!strcmp(argv[1], "store") || !strcmp(argv[1], "erase")) return 0;
    if (strcmp(argv[1], "get")) return INVALID;
    const char *url = getenv("MOEKIT_REMOTE_URL"), *root = getenv("MOEKIT_REMOTE_TOOLS");
    char host[254], path[1025], helper[4096];
    if (!endpoint(url, host, path) || !absolute(root)) return INVALID;
    int n = snprintf(helper, sizeof(helper), "%s/git-credential-osxkeychain", root);
    if (n < 0 || n >= (int)sizeof(helper) || !regular_private(helper)) return INVALID;
    char input[4097]; size_t size;
    // Git closes the helper input after its blank line. No credentials are
    // requested or accepted from the application or put into argv or logs.
    int result = bounded_input(input, 4096, &size); if (result) return result;
    bool protocol = false, matched_host = false, matched_path = false;
    char request[1400];
    for (char *line = input; *line;) {
        char *end = strchr(line, '\n'); if (!end) return INVALID;
        *end = 0;
        if (!*line) { if (end[1]) return INVALID; break; }
        if (!strcmp(line, "protocol=https") && !protocol) protocol = true;
        else if (!strncmp(line, "host=", 5) && !matched_host && !strcmp(line + 5, host)) matched_host = true;
        else if (!strncmp(line, "path=", 5) && !matched_path && !strcmp(line + 5, path)) matched_path = true;
        // Newer Git sends capability advertisements and HTTP authentication
        // challenges. They are bounded by the same 4096-byte input budget and
        // carry no destination authority. Ignore them; never forward to Keychain.
        else if (!strncmp(line, "capability[]=", 13) || !strncmp(line, "wwwauth[]=", 10) || !strncmp(line, "state[]=", 8)) {}
        else return INVALID; // username, password, URL and scope overrides refused
        line = end + 1;
    }
    if (!protocol || !matched_host || !matched_path) return INVALID;
    // The request is pinned to the full approved URL above. Existing Git
    // credentials are commonly stored by HTTPS host rather than repository
    // path, so query only that exact host; no other destination is permitted.
    n = snprintf(request, sizeof(request), "protocol=https\nhost=%s\n\n", host);
    if (n <= 0 || n >= (int)sizeof(request)) return INVALID;
    int fds[2]; if (make_pipe(fds)) return INTERNAL;
    pid_t child = fork(); if (child < 0) { close(fds[0]); close(fds[1]); return INTERNAL; }
    if (!child) {
        close(fds[1]);
        int null = open("/dev/null", O_WRONLY);
        if (null < 0 || dup2(fds[0], STDIN_FILENO) < 0 || dup2(null, STDERR_FILENO) < 0) _exit(INTERNAL);
        close(fds[0]); close(null);
        char *args[] = {helper, "get", NULL};
        // The copied system helper needs only the current-user Security service;
        // no Git prompt settings, alternate keychain, or path is inherited.
        // macOS may independently ask the user for Keychain access permission.
        char *env[] = {"PATH=/usr/bin:/bin", "LC_ALL=C", NULL};
        execve(helper, args, env); _exit(INTERNAL);
    }
    close(fds[0]); result = write_all(fds[1], request, (size_t)n); close(fds[1]);
    memset(input, 0, sizeof(input)); memset(request, 0, sizeof(request));
    int status; while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return INTERNAL; }
    return !result && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : CHILD_FAILED;
}
int main(int argc, char **argv) {
    if (close_inherited_descriptors()) return INTERNAL;
    const char *name = strrchr(argv[0], '/'); name = name ? name + 1 : argv[0];
    if (!strcmp(name, "pre-push")) return push_gate(argc, argv);
    if (!strcmp(name, "git-credential-moekit-keychain")) return credential_get(argc, argv);
    // ABI: private tool directory, private object snapshot, inspect|push,
    // exact HTTPS URL, exact refs/heads ref, source SHA-1, old SHA-1 or '-'.
    if (argc != 8 || !absolute(argv[1]) || !absolute(argv[2])) return INVALID;
    bool pushing = !strcmp(argv[3], "push");
    if ((!pushing && strcmp(argv[3], "inspect")) || !reference(argv[5]) || !oid(argv[6]) ||
        (pushing ? !oid(argv[7]) : strcmp(argv[7], "-"))) return INVALID;
    char host[254], path[1025]; if (!endpoint(argv[4], host, path)) return INVALID;
    char expected_tools[4096], git[4096], remote[4096], credential[4096], adapter[4096], gate[4096];
    snprintf(expected_tools, sizeof(expected_tools), "%s/transport-tools", argv[2]);
    if (strcmp(argv[1], expected_tools) || strlen(argv[1]) > 3900 || strchr(argv[1], ':')) return INVALID;
    snprintf(git, sizeof(git), "%s/git", argv[1]);
    snprintf(remote, sizeof(remote), "%s/git-remote-https", argv[1]);
    snprintf(credential, sizeof(credential), "%s/git-credential-osxkeychain", argv[1]);
    snprintf(adapter, sizeof(adapter), "%s/git-credential-moekit-keychain", argv[1]);
    snprintf(gate, sizeof(gate), "%s/hooks/pre-push", argv[1]);
    struct stat home, toolstat, hookstat;
    char hookroot[4096]; snprintf(hookroot, sizeof(hookroot), "%s/hooks", argv[1]);
    if (lstat(argv[2], &home) || !S_ISDIR(home.st_mode) || home.st_uid != geteuid() || (home.st_mode & 0077) ||
        lstat(argv[1], &toolstat) || !S_ISDIR(toolstat.st_mode) || toolstat.st_uid != geteuid() || (toolstat.st_mode & 0077) ||
        lstat(hookroot, &hookstat) || !S_ISDIR(hookstat.st_mode) || hookstat.st_uid != geteuid() || (hookstat.st_mode & 0077) ||
        !regular_private(git) || !regular_private(remote) || !regular_private(credential) || !regular_private(adapter) || !regular_private(gate)) return INVALID;
    // Even this private repository must retain the exact generated config.
    // In particular, no include, URL rewrite, helper, hook, or external command
    // can enter through an accidentally modified snapshot configuration.
    if (!fixed_file(argv[2], "config", "[core]\nrepositoryformatversion = 0\nbare = true\n") ||
        !fixed_file(argv[2], "HEAD", "ref: refs/heads/private\n")) return INVALID;
    char home_env[4110], directory[4110], exec_env[4110], path_env[4140], hooks[4140], tools_env[4140];
    char url_env[2080], ref_env[300], source_env[70], old_env[70], refspec[300];
    snprintf(home_env, sizeof(home_env), "HOME=%s", argv[2]);
    snprintf(directory, sizeof(directory), "--git-dir=%s", argv[2]);
    snprintf(exec_env, sizeof(exec_env), "GIT_EXEC_PATH=%s", argv[1]);
    snprintf(path_env, sizeof(path_env), "PATH=%s:/usr/bin:/bin", argv[1]);
    snprintf(hooks, sizeof(hooks), "core.hooksPath=%s/hooks", argv[1]);
    snprintf(tools_env, sizeof(tools_env), "MOEKIT_REMOTE_TOOLS=%s", argv[1]);
    snprintf(url_env, sizeof(url_env), "MOEKIT_REMOTE_URL=%s", argv[4]);
    snprintf(ref_env, sizeof(ref_env), "MOEKIT_REMOTE_REF=%s", argv[5]);
    snprintf(source_env, sizeof(source_env), "MOEKIT_REMOTE_SOURCE=%s", argv[6]);
    snprintf(old_env, sizeof(old_env), "MOEKIT_REMOTE_OLD=%s", argv[7]);
    snprintf(refspec, sizeof(refspec), "%s:%s", argv[6], argv[5]);
    char *env[] = {home_env, path_env, exec_env, "LC_ALL=C", tools_env, url_env, ref_env, source_env, old_env,
        "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_ATTR_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0", "GIT_ALLOW_PROTOCOL=https",
        "GIT_OPTIONAL_LOCKS=0", "GIT_NO_LAZY_FETCH=1", "GIT_LFS_SKIP_SMUDGE=1", NULL};
    char *args[100]; int ai = 0;
#define ARG(v) args[ai++] = (v)
#define CONFIG(v) do { ARG("-c"); ARG(v); } while (0)
    ARG(git); ARG("--no-optional-locks"); ARG("--no-replace-objects"); ARG(directory);
    CONFIG("protocol.allow=never"); CONFIG("protocol.https.allow=always");
    CONFIG(pushing ? hooks : "core.hooksPath=/dev/null");
    CONFIG("credential.helper="); CONFIG("credential.helper=moekit-keychain");
    CONFIG("credential.useHttpPath=true"); CONFIG("credential.interactive=false");
    CONFIG("core.askPass="); CONFIG("http.followRedirects=false"); CONFIG("http.sslVerify=true");
    CONFIG("http.proxy="); CONFIG("http.extraHeader="); CONFIG("http.cookieFile=");
    CONFIG("http.saveCookies=false"); CONFIG("http.lowSpeedLimit=1"); CONFIG("http.lowSpeedTime=20");
    CONFIG("push.followTags=false"); CONFIG("push.gpgSign=false"); CONFIG("submodule.recurse=false");
    CONFIG("maintenance.auto=false"); CONFIG("gc.auto=0");
    if (pushing) {
        ARG("push"); ARG("--porcelain"); ARG("--no-force"); ARG("--no-follow-tags"); ARG("--no-signed");
        ARG("--recurse-submodules=no"); ARG("--"); ARG(argv[4]); ARG(refspec);
    } else {
        ARG("ls-remote"); ARG("--refs"); ARG("--exit-code"); ARG("--"); ARG(argv[4]); ARG(argv[5]);
    }
    ARG(NULL);
#undef CONFIG
#undef ARG
    int out[2], err[2], ready[2];
    if (make_pipe(out)) return INTERNAL;
    if (make_pipe(err)) { close(out[0]); close(out[1]); return INTERNAL; }
    if (make_pipe(ready)) { close(out[0]); close(out[1]); close(err[0]); close(err[1]); return INTERNAL; }
    // SIG_IGN for SIGCHLD survives exec and would auto-reap the child, invalidating
    // the reserved PID/PGID cancellation anchor. Normalize it before fork.
    struct sigaction child_action; memset(&child_action, 0, sizeof(child_action));
    child_action.sa_handler = SIG_DFL;
    if (sigemptyset(&child_action.sa_mask) || sigaction(SIGCHLD, &child_action, NULL)) return INTERNAL;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, signal_cancel);
    signal(SIGINT, signal_cancel);
    double started = now();
    if (started < 0) return INTERNAL;
    pid_t child = fork();
    if (child < 0) return INTERNAL;
    if (!child) {
        close(out[0]); close(err[0]); close(ready[0]);
        if (setpgid(0, 0)) setup_failure(ready[1], 1);
        if (chdir(argv[2])) setup_failure(ready[1], 2);
        if (limit(RLIMIT_CPU, GIT_CPU_SECONDS)) setup_failure(ready[1], 3);
        if (limit(RLIMIT_CORE, 0)) setup_failure(ready[1], 4);
        if (limit(RLIMIT_FSIZE, 0)) setup_failure(ready[1], 5);
#ifndef __APPLE__
        // Darwin's data-limit accounting includes pre-exec virtual mappings:
        // a 512 MiB hard limit can fail with EINVAL before a tiny child starts.
        // macOS instead uses the explicitly scoped resident-memory watchdog below.
        if (limit(RLIMIT_DATA, GIT_MEMORY_LIMIT_BYTES)) setup_failure(ready[1], 6);
#endif
        if (limit(RLIMIT_NOFILE, 256)) setup_failure(ready[1], 7);
        int null = open("/dev/null", O_RDONLY);
        if (null < 0 || dup2(null, STDIN_FILENO) < 0 || dup2(out[1], STDOUT_FILENO) < 0 ||
            dup2(err[1], STDERR_FILENO) < 0) _exit(INTERNAL);
        close(null); close(out[1]); close(err[1]);
        if (write_all(ready[1], "R", 1)) _exit(INTERNAL);
        close(ready[1]);
        signal(SIGPIPE, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
        execve(git, args, env);
        _exit(INTERNAL);
    }
    close(out[1]); close(err[1]); close(ready[1]);
    fcntl(out[0], F_SETFL, O_NONBLOCK); fcntl(err[0], F_SETFL, O_NONBLOCK);
    fcntl(ready[0], F_SETFL, O_NONBLOCK);
    char *stdout_buffer = malloc(OUT_LIMIT), *stderr_buffer = malloc(ERR_LIMIT);
    size_t sizes[2] = {0, 0};
    if (!stdout_buffer || !stderr_buffer) {
        stop_and_reap(child); free(stdout_buffer); free(stderr_buffer); return INTERNAL;
    }
    char *buffers[2] = {stdout_buffer, stderr_buffer};
    const size_t caps[2] = {OUT_LIMIT, ERR_LIMIT};
    struct pollfd fds[4] = {{out[0], POLLIN, 0}, {err[0], POLLIN, 0},
                          {STDIN_FILENO, POLLIN, 0}, {ready[0], POLLIN, 0}};
    int result = 0;
    bool child_ready = false, child_exited = false;
#ifdef __APPLE__
    double missing_metrics_since = -1;
#endif
    while (!result) {
        if (cancelled) { result = CANCELLED; break; }
        double current = now();
        if (current < 0) { result = INTERNAL; break; }
        if (current - started >= GIT_WALL_SECONDS) { result = TIME_LIMIT; break; }
        int polled = poll(fds, 4, 25);
        if (polled < 0 && errno == EINTR) continue;
        if (polled < 0) { result = INTERNAL; break; }
        // EOF means the app went away; any input means explicit cancellation.
        if (fds[2].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) { result = CANCELLED; break; }
        if (!child_ready && (fds[3].revents & (POLLIN | POLLHUP))) {
            char report[32] = {0};
            ssize_t size = read(fds[3].fd, report, sizeof(report) - 1);
            if (size == 1 && report[0] == 'R') child_ready = true;
            else {
                int stage = 0, code = 0;
                if (size > 1 && sscanf(report, "E%d:%d", &stage, &code) == 2 &&
                    stage >= 1 && stage <= 7 && code >= 0 && code <= 4095)
                    fprintf(stderr, "GitRemoteTransport setup stage=%d errno=%d\n", stage, code);
                result = INTERNAL; break;
            }
            close(fds[3].fd); fds[3].fd = -1;
        }
        for (int i = 0; i < 2 && !result; ++i) {
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            char chunk[16384];
            ssize_t n = read(fds[i].fd, chunk, sizeof(chunk));
            if (n > 0) {
                if ((size_t)n > caps[i] - sizes[i]) { result = OUTPUT_LIMIT; break; }
                memcpy(buffers[i] + sizes[i], chunk, (size_t)n); sizes[i] += (size_t)n;
            } else if (!n) { close(fds[i].fd); fds[i].fd = -1; }
            else if (errno != EAGAIN && errno != EINTR) { result = INTERNAL; break; }
        }
        siginfo_t info; memset(&info, 0, sizeof(info));
        if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) { result = INTERNAL; break; }
#ifdef __APPLE__
        if (child_ready && info.si_pid != child) {
            struct proc_taskinfo task; memset(&task, 0, sizeof(task));
#ifdef GIT_TEST_UNAVAILABLE_METRICS
            // Build-only adverse fixture. Production never defines this macro.
            int measured = 0; errno = EACCES;
#else
            int measured = proc_pidinfo(child, PROC_PIDTASKINFO, 0, &task, sizeof(task));
#endif
            if (measured != (int)sizeof(task)) {
                int metric_error = errno;
                // Darwin can remove task metrics while a fast child is exiting,
                // before waitid publishes WEXITED, or transiently during exec.
                // Keep its PID reserved and allow only a bounded 100 ms grace.
                siginfo_t after; memset(&after, 0, sizeof(after));
                if (waitid(P_PID, (id_t)child, &after, WEXITED | WNOHANG | WNOWAIT) < 0) {
                    result = INTERNAL; break;
                }
                if (after.si_pid == child) info = after;
                else {
                    double observed = now();
                    if (observed < 0) { result = INTERNAL; break; }
                    if (missing_metrics_since < 0) missing_metrics_since = observed;
                    if (observed - missing_metrics_since >= 0.100) {
                        fprintf(stderr, "GitRemoteTransport task metrics unavailable size=%d errno=%d\n", measured, metric_error);
                        result = INTERNAL; break;
                    }
                }
            } else {
                missing_metrics_since = -1;
                if (task.pti_resident_size > GIT_MEMORY_LIMIT_BYTES) {
                    result = MEMORY_LIMIT; break;
                }
            }
        }
#endif
        if (info.si_pid == child) {
            child_exited = true;
            if (!child_ready || info.si_code != CLD_EXITED ||
                (info.si_status != 0 && !(!pushing && info.si_status == 2))) { result = CHILD_FAILED; break; }
            if (!pushing && info.si_status == 2) { result = MISSING_REF; break; }
            // Drain both streams before reporting a negative result: output and
            // time limits still take precedence over a Git ancestry exit code.
            // Stop any still-running owned helper while the leader PID is reserved.
            if (owns_child(child)) (void)kill(-child, SIGKILL);
            if (fds[0].fd < 0 && fds[1].fd < 0) break;
        }
    }
    stop_and_reap(child);
    for (int i = 0; i < 4; i++) if (i != 2 && fds[i].fd >= 0) close(fds[i].fd);
    if (!child_exited && !result) result = CHILD_FAILED;
    // Raw Git/server/helper diagnostics and push porcelain are intentionally
    // discarded, including on errors. Only ls-remote data reaches the app.
    if (!result && !pushing) result = flush_output(STDOUT_FILENO, stdout_buffer, sizes[0], started);
    memset(stdout_buffer, 0, OUT_LIMIT); memset(stderr_buffer, 0, ERR_LIMIT);
    free(stdout_buffer); free(stderr_buffer);
    return result;
}
