// Original MoeKit Git object inspector. Only config-free private snapshots.
// Fixed version provenance and two object-only operations; no live repository execution.
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
#define GIT_WALL_SECONDS 15
#endif
#ifndef GIT_CPU_SECONDS
#define GIT_CPU_SECONDS 10
#endif
#ifndef GIT_MEMORY_LIMIT_BYTES
#define GIT_MEMORY_LIMIT_BYTES (512ULL * 1024 * 1024)
#endif
#define OUT_LIMIT 128
#define ERR_LIMIT (64 * 1024)

enum { INVALID = 64, INTERNAL = 70, OUTPUT_LIMIT = 71, TIME_LIMIT = 72,
       CHILD_FAILED = 73, CANCELLED = 74, NOT_ANCESTOR = 75, MEMORY_LIMIT = 76 };
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
int main(int argc, char **argv) {
    if (close_inherited_descriptors()) return INTERNAL;
    // The Swift caller verifies the copied Apple signature and constructs the
    // config-free snapshot. This helper alone is not an executable trust gate.
    // ABI: Apple-signed copied Git, app-owned snapshot, object1, object2.
    // Exact 'version', '-' asks for version provenance. Otherwise object2 '-'
    // asks for object1's tree; a second SHA asks for ancestry.
    if (argc != 5 || !absolute(argv[1]) || !absolute(argv[2])) return INVALID;
    bool version = strcmp(argv[3], "version") == 0;
    if (version) {
        if (strcmp(argv[4], "-")) return INVALID;
    } else {
        for (int a = 3; a <= 4; a++) {
            if (a == 4 && !strcmp(argv[a], "-")) continue;
            if (strlen(argv[a]) != 40 || strspn(argv[a], "0123456789abcdef") != 40) return INVALID;
        }
    }
    struct stat binary, home;
    if (lstat(argv[1], &binary) || !S_ISREG(binary.st_mode) ||
        lstat(argv[2], &home) || !S_ISDIR(home.st_mode) ||
        home.st_uid != geteuid() || (home.st_mode & 0077)) return INVALID;
    char home_env[4110], directory[4110], tree[48];
    snprintf(home_env, sizeof(home_env), "HOME=%s", argv[2]);
    snprintf(directory, sizeof(directory), "--git-dir=%s", argv[2]);
    snprintf(tree, sizeof(tree), "%s^{tree}", argv[3]);
    char *env[] = { home_env, "PATH=/usr/bin:/bin", "LC_ALL=C",
        "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_ATTR_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0", "GIT_ALLOW_PROTOCOL=",
        "GIT_OPTIONAL_LOCKS=0", "GIT_NO_LAZY_FETCH=1", NULL };
    char *tree_args[] = { argv[1], "--no-optional-locks", "--no-replace-objects", directory,
        "-c", "protocol.allow=never", "-c", "core.hooksPath=/dev/null", "rev-parse", "--verify", tree, NULL };
    char *ancestry_args[] = { argv[1], "--no-optional-locks", "--no-replace-objects", directory,
        "-c", "protocol.allow=never", "-c", "core.hooksPath=/dev/null", "merge-base", "--is-ancestor", argv[3], argv[4], NULL };
    char *version_args[] = { argv[1], "--version", NULL };
    bool ancestry = !version && strcmp(argv[4], "-") != 0;
    char **args = version ? version_args : ancestry ? ancestry_args : tree_args;
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
        execve(argv[1], args, env);
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
    bool child_ready = false, child_exited = false, not_ancestor = false;
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
                    fprintf(stderr, "GitObjectInspector setup stage=%d errno=%d\n", stage, code);
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
            struct proc_taskinfo task;
            int measured = proc_pidinfo(child, PROC_PIDTASKINFO, 0, &task, sizeof(task));
            if (measured != (int)sizeof(task)) {
                // Exit between waitid and proc_pidinfo is benign. An unobservable
                // still-running owned child is stopped; there is no unbounded fallback.
                siginfo_t after; memset(&after, 0, sizeof(after));
                if (waitid(P_PID, (id_t)child, &after, WEXITED | WNOHANG | WNOWAIT) < 0 || after.si_pid != child) {
                    result = INTERNAL; break;
                }
            } else if (task.pti_resident_size > GIT_MEMORY_LIMIT_BYTES) {
                result = MEMORY_LIMIT; break;
            }
        }
#endif
        if (info.si_pid == child) {
            child_exited = true;
            if (!child_ready || info.si_code != CLD_EXITED ||
                (info.si_status != 0 && !(ancestry && info.si_status == 1))) { result = CHILD_FAILED; break; }
            not_ancestor = ancestry && info.si_status == 1;
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
    if (!result && not_ancestor) result = NOT_ANCESTOR;
    if (!result) result = flush_output(STDOUT_FILENO, stdout_buffer, sizes[0], started);
    // Raw diagnostic bytes stay bounded and session-only; the app never executes them.
    if (!result && sizes[1]) result = flush_output(STDERR_FILENO, stderr_buffer, sizes[1], started);
    free(stdout_buffer); free(stderr_buffer);
    return result;
}
