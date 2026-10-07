// Original MoeKit fixed Homebrew Mole operation supervisor. No command strings.
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#ifdef __linux__
#define _DEFAULT_SOURCE 1
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#include <CommonCrypto/CommonDigest.h>
#else
#include <pty.h>
#include <openssl/evp.h>
#endif

#ifndef OPERATION_WALL_SECONDS
#define OPERATION_WALL_SECONDS 3600
#endif
#ifndef OPERATION_BACKPRESSURE_SECONDS
#define OPERATION_BACKPRESSURE_SECONDS 5
#endif
#define OUTPUT_LIMIT (16U * 1024U * 1024U)
#define QUEUE_LIMIT 65536U
#define FRAME_LIMIT 4097U
#define HASH_FILE_LIMIT (2U * 1024U * 1024U)

enum { OK = 0, INVALID = 64, INTERNAL = 70, OUTPUT_BOUND = 71, WALL_BOUND = 72,
       CHILD_FAILED = 73, CANCELLED = 74, BAD_FRAME = 75, VERIFY_FAILED = 76,
       BACKPRESSURE = 77 };
typedef struct {
    uintmax_t device, inode, owner, mode, size;
    intmax_t seconds;
    uintmax_t nanoseconds;
    unsigned char digest[32];
} Snapshot;
typedef struct {
    unsigned char header[5], payload[FRAME_LIMIT];
    size_t header_size, payload_size;
    uint32_t length;
    bool input_allowed;
} Frame;
typedef struct {
    unsigned char bytes[QUEUE_LIMIT];
    size_t start, size;
} Queue;
typedef struct {
    double started, last_output_progress;
    size_t output_total;
    unsigned char phase;
    Frame frame;
    Queue input, output;
    struct winsize size;
} Session;
static volatile sig_atomic_t cancelled;
static void signal_cancel(int number) { (void)number; cancelled = 1; }
static double monotonic_now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return -1;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static int close_inherited_descriptors(void) {
    DIR *directory = opendir("/dev/fd");
    if (!directory) return -1;
    int inventory = dirfd(directory);
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(directory))) {
        char *end = NULL;
        long fd = strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end || fd < 3 || fd == inventory || fd > INT_MAX) continue;
        (void)close((int)fd);
        errno = 0;
    }
    int error = errno;
    closedir(directory);
    return error ? -1 : 0;
}
static int make_pipe(int fds[2]) {
    if (pipe(fds)) return -1;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) || fcntl(fds[1], F_SETFD, FD_CLOEXEC)) {
        close(fds[0]); close(fds[1]); return -1;
    }
    return 0;
}
// Fewer than 1 KiB of supervisor-only records per session. Never block on a
// missing protocol reader. Child stdout AND stderr go only to the PTY.
static bool record(const char *kind, const char *phase, int number) {
    char bytes[128];
    int count;
    if (!strcmp(kind, "PHASE")) count = snprintf(bytes, sizeof(bytes), "MKOT1 PHASE %s\n", phase);
    else if (!strcmp(kind, "RESULT")) count = snprintf(bytes, sizeof(bytes), "MKOT1 RESULT %d\n", number);
    else count = snprintf(bytes, sizeof(bytes), "MKOT1 %s %s %d\n", kind, phase, number);
    if (count < 0 || count >= (int)sizeof(bytes)) return false;
    ssize_t written;
    do { written = write(STDERR_FILENO, bytes, (size_t)count); } while (written < 0 && errno == EINTR);
    return written == count;
}
static bool parse_unsigned(const char *text, uintmax_t *value) {
    if (!text || !*text) return false;
    for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return false;
    errno = 0; char *end = NULL;
    *value = strtoumax(text, &end, 10);
    return !errno && end && !*end;
}
static bool parse_signed(const char *text, intmax_t *value) {
    const char *p = text;
    if (*p == '-') ++p;
    if (!*p) return false;
    for (; *p; ++p) if (*p < '0' || *p > '9') return false;
    errno = 0; char *end = NULL;
    *value = strtoimax(text, &end, 10);
    return !errno && end && !*end;
}
static int hex_digit(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}
static bool parse_snapshot(char **argv, Snapshot *value) {
    if (!parse_unsigned(argv[3], &value->device) || !parse_unsigned(argv[4], &value->inode) ||
        !parse_unsigned(argv[5], &value->owner) || !parse_unsigned(argv[6], &value->mode) ||
        !parse_unsigned(argv[7], &value->size) || !parse_signed(argv[8], &value->seconds) ||
        !parse_unsigned(argv[9], &value->nanoseconds) || value->nanoseconds >= 1000000000U ||
        strlen(argv[10]) != 64) return false;
    for (size_t i = 0; i < 32; ++i) {
        int high = hex_digit(argv[10][i * 2]), low = hex_digit(argv[10][i * 2 + 1]);
        if (high < 0 || low < 0) return false;
        value->digest[i] = (unsigned char)(high * 16 + low);
    }
    return true;
}
static void stat_snapshot(const struct stat *value, Snapshot *snapshot) {
    snapshot->device = (uintmax_t)value->st_dev;
    snapshot->inode = (uintmax_t)value->st_ino;
    snapshot->owner = (uintmax_t)value->st_uid;
    snapshot->mode = (uintmax_t)value->st_mode;
    snapshot->size = (uintmax_t)value->st_size;
#ifdef __APPLE__
    snapshot->seconds = (intmax_t)value->st_mtimespec.tv_sec;
    snapshot->nanoseconds = (uintmax_t)value->st_mtimespec.tv_nsec;
#else
    snapshot->seconds = (intmax_t)value->st_mtim.tv_sec;
    snapshot->nanoseconds = (uintmax_t)value->st_mtim.tv_nsec;
#endif
}
static bool same_identity(const Snapshot *a, const Snapshot *b) {
    return a->device == b->device && a->inode == b->inode && a->owner == b->owner &&
           a->mode == b->mode && a->size == b->size && a->seconds == b->seconds &&
           a->nanoseconds == b->nanoseconds;
}
static bool secure_executable(const struct stat *value) {
    return S_ISREG(value->st_mode) && (value->st_uid == geteuid() || value->st_uid == 0) &&
           (value->st_mode & 0111) && !(value->st_mode & 0022) &&
           !(value->st_mode & (S_ISUID | S_ISGID)) && value->st_size > 0 &&
           (uintmax_t)value->st_size <= HASH_FILE_LIMIT;
}
static bool hash_fd(int fd, unsigned char digest[32]) {
    unsigned char bytes[16384];
    size_t total = 0;
#ifdef __APPLE__
    CC_SHA256_CTX context;
    if (!CC_SHA256_Init(&context)) return false;
#else
    EVP_MD_CTX *context = EVP_MD_CTX_new();
    if (!context) return false;
    bool good = EVP_DigestInit_ex(context, EVP_sha256(), NULL) == 1;
    if (!good) { EVP_MD_CTX_free(context); return false; }
#endif
    bool valid = true;
    for (;;) {
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = false; break; }
        if (!count) break;
        total += (size_t)count;
        if (total > HASH_FILE_LIMIT || cancelled) { valid = false; break; }
#ifdef __APPLE__
        if (!CC_SHA256_Update(&context, bytes, (CC_LONG)count)) { valid = false; break; }
#else
        if (EVP_DigestUpdate(context, bytes, (size_t)count) != 1) { valid = false; break; }
#endif
    }
#ifdef __APPLE__
    if (valid) valid = CC_SHA256_Final(digest, &context) == 1;
#else
    unsigned int length = 0;
    if (valid) valid = EVP_DigestFinal_ex(context, digest, &length) == 1 && length == 32;
    EVP_MD_CTX_free(context);
#endif
    return valid;
}
// Lexical normalization only: no link outside the one compiled-in Intel alias
// can supply launch authority. The canonical executable is checked separately.
static bool normalized_target(const char *alias, const char *target, char output[PATH_MAX]) {
    char expanded[PATH_MAX];
    int count;
    if (target[0] == '/') count = snprintf(expanded, sizeof(expanded), "%s", target);
    else {
        const char *slash = strrchr(alias, '/');
        if (!slash) return false;
        size_t prefix = (size_t)(slash - alias + 1);
        if (prefix >= PATH_MAX) return false;
        count = snprintf(expanded, sizeof(expanded), "%.*s%s", (int)prefix, alias, target);
    }
    if (count <= 0 || count >= (int)sizeof(expanded)) return false;
    output[0] = '/'; size_t used = 1;
    char *save = NULL;
    for (char *part = strtok_r(expanded, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (!strcmp(part, ".")) continue;
        if (!strcmp(part, "..")) {
            while (used > 1 && output[used - 1] != '/') --used;
            if (used > 1) --used;
            continue;
        }
        size_t size = strlen(part);
        if (used + (used > 1 ? 1U : 0U) + size >= PATH_MAX) return false;
        if (used > 1) output[used++] = '/';
        memcpy(output + used, part, size); used += size;
    }
    output[used] = 0;
    return true;
}
static bool known_alias_valid(const char *path) {
#ifdef MOEKIT_OPERATION_FIXTURE_BREW
#ifdef MOEKIT_OPERATION_FIXTURE_ALIAS
    const char *canonical = MOEKIT_OPERATION_FIXTURE_BREW;
    const char *alias = MOEKIT_OPERATION_FIXTURE_ALIAS;
#else
    (void)path;
    // Reference this function even without an alias fixture to keep the strict
    // -Wunused-function build clean without production-only compiler flags.
    (void)normalized_target;
    return true;
#endif
#else
    const char *canonical = "/usr/local/Homebrew/bin/brew";
    const char *alias = "/usr/local/bin/brew";
#endif
#if !defined(MOEKIT_OPERATION_FIXTURE_BREW) || defined(MOEKIT_OPERATION_FIXTURE_ALIAS)
    if (strcmp(path, canonical)) return true;
    struct stat before, after, binary;
    if (lstat(alias, &before) || !S_ISLNK(before.st_mode) ||
        (before.st_uid != geteuid() && before.st_uid != 0) ||
        lstat(canonical, &binary) || !secure_executable(&binary)) return false;
    char target[PATH_MAX], normalized[PATH_MAX], resolved[PATH_MAX];
    ssize_t size = readlink(alias, target, sizeof(target) - 1);
    if (size <= 0 || size >= (ssize_t)sizeof(target) - 1) return false;
    target[size] = 0;
    if (!normalized_target(alias, target, normalized) || strcmp(normalized, canonical) ||
        !realpath(canonical, resolved) || strcmp(resolved, canonical) || lstat(alias, &after)) return false;
    Snapshot a = {0}, b = {0};
    stat_snapshot(&before, &a); stat_snapshot(&after, &b);
    return same_identity(&a, &b);
#endif
}
// Keep the opened descriptor until exec. Fixed-path native execution preserves
// Homebrew's script-path discovery; see README for the final pathname race.
static int verify_executable(const char *path, const Snapshot *expected, Snapshot *observed) {
    if (!known_alias_valid(path)) return -1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    struct stat before, after, named;
    Snapshot a = {0}, b = {0}, c = {0};
    bool good = !fstat(fd, &before) && secure_executable(&before);
    if (good) { stat_snapshot(&before, &a); good = !expected || same_identity(&a, expected); }
    if (good) good = hash_fd(fd, a.digest);
    if (good) good = !expected || !memcmp(a.digest, expected->digest, sizeof(a.digest));
    if (good) good = !fstat(fd, &after) && !lstat(path, &named) && !access(path, X_OK);
    if (good) {
        stat_snapshot(&after, &b); stat_snapshot(&named, &c);
        good = same_identity(&a, &b) && same_identity(&a, &c) && secure_executable(&after);
    }
    if (!good) { close(fd); return -1; }
    *observed = a;
    return fd;
}
static bool fixed_path(const char *path) {
#ifdef MOEKIT_OPERATION_FIXTURE_BREW
#ifndef MOEKIT_OPERATION_FIXTURE_HOME
#error Fixture executable requires a compile-time fixture HOME
#endif
    return !strcmp(path, MOEKIT_OPERATION_FIXTURE_BREW);
#else
    return !strcmp(path, "/opt/homebrew/bin/brew") || !strcmp(path, "/usr/local/bin/brew") ||
           !strcmp(path, "/usr/local/Homebrew/bin/brew");
#endif
}
static bool verified_home(const char *supplied, char canonical[PATH_MAX]) {
    if (!supplied || supplied[0] != '/' || strlen(supplied) >= PATH_MAX || !realpath(supplied, canonical)) return false;
#ifdef MOEKIT_OPERATION_FIXTURE_HOME
    const char *expected = MOEKIT_OPERATION_FIXTURE_HOME;
#else
    struct passwd *user = getpwuid(geteuid());
    if (!user || !user->pw_dir || !*user->pw_dir) return false;
    const char *expected = user->pw_dir;
#endif
    struct stat a, b;
    return !stat(canonical, &a) && !stat(expected, &b) && S_ISDIR(a.st_mode) &&
           a.st_uid == geteuid() && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
static bool queue_append(Queue *queue, const unsigned char *bytes, size_t count) {
    if (count > QUEUE_LIMIT - queue->size) return false;
    if (queue->start + queue->size + count > QUEUE_LIMIT) {
        memmove(queue->bytes, queue->bytes + queue->start, queue->size); queue->start = 0;
    }
    memcpy(queue->bytes + queue->start + queue->size, bytes, count);
    queue->size += count;
    return true;
}
static void queue_consumed(Queue *queue, size_t count) {
    queue->start += count; queue->size -= count;
    if (!queue->size) queue->start = 0;
}
static int apply_frame(Session *session, int master) {
    Frame *frame = &session->frame;
    switch (frame->header[0]) {
        case 'C': return CANCELLED;
        case 'I':
            if (frame->payload[0] != 1 && frame->payload[0] != 2) return BAD_FRAME;
            if (frame->input_allowed && frame->payload[0] == session->phase &&
                !queue_append(&session->input, frame->payload + 1, frame->length - 1)) return BAD_FRAME;
            break;
        case 'R': {
            unsigned int rows = ((unsigned int)frame->payload[0] << 8) | frame->payload[1];
            unsigned int columns = ((unsigned int)frame->payload[2] << 8) | frame->payload[3];
            if (!rows || !columns || rows > 1000 || columns > 1000) return BAD_FRAME;
            session->size.ws_row = (unsigned short)rows; session->size.ws_col = (unsigned short)columns;
            if (master >= 0 && ioctl(master, TIOCSWINSZ, &session->size)) return INTERNAL;
            break;
        }
        default: return BAD_FRAME;
    }
    memset(frame, 0, sizeof(*frame));
    return OK;
}
static int feed_control(Session *session, int master, bool allow_input, const unsigned char *bytes, size_t count) {
    Frame *frame = &session->frame;
    for (size_t i = 0; i < count; ++i) {
        if (frame->header_size < 5) {
            if (!frame->header_size) frame->input_allowed = allow_input;
            frame->header[frame->header_size++] = bytes[i];
            if (frame->header_size != 5) continue;
            frame->length = ((uint32_t)frame->header[1] << 24) | ((uint32_t)frame->header[2] << 16) |
                            ((uint32_t)frame->header[3] << 8) | (uint32_t)frame->header[4];
            unsigned char kind = frame->header[0];
            if ((kind == 'I' && (frame->length < 2 || frame->length > FRAME_LIMIT)) ||
                (kind == 'R' && frame->length != 4) || (kind == 'C' && frame->length != 0) ||
                (kind != 'I' && kind != 'R' && kind != 'C')) return BAD_FRAME;
            if (!frame->length) return apply_frame(session, master);
        } else {
            frame->payload[frame->payload_size++] = bytes[i];
            if (frame->payload_size == frame->length) {
                int result = apply_frame(session, master);
                if (result) return result;
            }
        }
    }
    return OK;
}
static int read_control(Session *session, int master, bool allow_input) {
    unsigned char bytes[8192];
    ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
    if (count > 0) return feed_control(session, master, allow_input, bytes, (size_t)count);
    if (!count) return session->frame.header_size ? BAD_FRAME : CANCELLED;
    return errno == EAGAIN || errno == EINTR ? OK : CANCELLED;
}
// At the phase boundary discard queued keystrokes, but still honor resize and
// cancellation. A partially received input frame is also marked for discard.
static int transition_control(Session *session) {
    memset(&session->input, 0, sizeof(session->input));
    session->frame.input_allowed = false;
    for (size_t i = 0; i < 16; ++i) {
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        if (cancelled) return CANCELLED;
        int ready = poll(&input, 1, 0);
        if (ready < 0) return errno == EINTR ? CANCELLED : INTERNAL;
        if (!ready) return OK;
        if (input.revents & (POLLERR | POLLNVAL)) return CANCELLED;
        if (input.revents & (POLLIN | POLLHUP)) {
            int result = read_control(session, -1, false);
            if (result) return result;
        }
    }
    return BAD_FRAME; // bounded input flood at a launch boundary
}
// WNOWAIT reserves the direct child's PID/PGID until all owned-group signaling
// is complete. Do not signal a group before the setsid/parent-ack handshake.
static bool owns_child(pid_t child) {
    siginfo_t info; memset(&info, 0, sizeof(info));
    int result;
    do { result = waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT); } while (result < 0 && errno == EINTR);
    return result == 0;
}
static int stop_and_reap(pid_t child, bool owns_group, int *status) {
    if (!owns_child(child)) return -1;
    if (owns_group) (void)kill(-child, SIGKILL);
    (void)kill(child, SIGKILL);
    pid_t result;
    do { result = waitpid(child, status, 0); } while (result < 0 && errno == EINTR);
    return result == child ? 0 : -1;
}
static void child_exec(const char *path, const char *home, const char *phase, const Snapshot *snapshot,
                       int verified_fd, int master, int slave, int ready[2], int ack[2]) {
    close(master); close(ready[0]); close(ack[1]);
    if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) || chdir(home)) _exit(INTERNAL);
    struct rlimit core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &core)) _exit(INTERNAL);
    if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 || dup2(slave, STDERR_FILENO) < 0) _exit(INTERNAL);
    if (slave > STDERR_FILENO) close(slave);
    signal(SIGPIPE, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
    if (write(ready[1], "R", 1) != 1) _exit(INTERNAL);
    close(ready[1]);
    char permission = 0;
    ssize_t count;
    do { count = read(ack[0], &permission, 1); } while (count < 0 && errno == EINTR);
    close(ack[0]);
    if (count != 1 || permission != 'G') _exit(CANCELLED);
    struct stat opened, named;
    Snapshot a = {0}, b = {0};
    if (!known_alias_valid(path) || fstat(verified_fd, &opened) || lstat(path, &named)) _exit(VERIFY_FAILED);
    stat_snapshot(&opened, &a); stat_snapshot(&named, &b);
    if (!same_identity(snapshot, &a) || !same_identity(snapshot, &b) || !secure_executable(&named)) _exit(VERIFY_FAILED);
    char home_environment[PATH_MAX + 6];
    if (snprintf(home_environment, sizeof(home_environment), "HOME=%s", home) >= (int)sizeof(home_environment)) _exit(INTERNAL);
    char *environment[] = {home_environment, "TERM=xterm-256color",
        "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_ANALYTICS=1", "LC_ALL=en_US.UTF-8", NULL};
    char *update[] = {(char *)path, "update", NULL};
    char *upgrade[] = {(char *)path, "upgrade", "--formula", "mole", NULL};
    execve(path, !strcmp(phase, "update") ? update : upgrade, environment);
    _exit(INTERNAL);
}
static int run_phase(Session *session, const char *path, const char *home, const char *phase,
                     int verified_fd, const Snapshot *snapshot) {
    session->phase = !strcmp(phase, "update") ? 1 : 2;
    int master = -1, slave = -1, ready[2] = {-1, -1}, ack[2] = {-1, -1};
    if (openpty(&master, &slave, NULL, NULL, &session->size)) return INTERNAL;
    if (fcntl(master, F_SETFD, FD_CLOEXEC) || fcntl(slave, F_SETFD, FD_CLOEXEC) ||
        nonblocking(master) || make_pipe(ready) || make_pipe(ack) || nonblocking(ready[0])) {
        close(master); close(slave);
        for (int i = 0; i < 2; ++i) { if (ready[i] >= 0) close(ready[i]); if (ack[i] >= 0) close(ack[i]); }
        return INTERNAL;
    }
    if (!record("PHASE", phase, 0)) {
        close(master); close(slave);
        for (int i = 0; i < 2; ++i) { close(ready[i]); close(ack[i]); }
        return INTERNAL;
    }
    pid_t child = fork();
    if (!child) child_exec(path, home, phase, snapshot, verified_fd, master, slave, ready, ack);
    close(slave); close(ready[1]); close(ack[0]);
    if (child < 0) { close(master); close(ready[0]); close(ack[1]); return INTERNAL; }
    bool owns_group = false, exited = false, master_eof = false;
    int result = OK;
    for (;;) {
        if (cancelled) { result = CANCELLED; break; }
        double current = monotonic_now();
        if (current < 0) { result = INTERNAL; break; }
        if (current - session->started >= OPERATION_WALL_SECONDS) { result = WALL_BOUND; break; }
        if (session->output.size && current - session->last_output_progress >= OPERATION_BACKPRESSURE_SECONDS) { result = BACKPRESSURE; break; }
        if (exited && master_eof && !session->output.size) break;
        struct pollfd fds[4] = {
            {STDIN_FILENO, POLLIN, 0},
            {master_eof ? -1 : master, (short)((session->output.size < QUEUE_LIMIT ? POLLIN : 0) |
                (owns_group && !exited && session->input.size ? POLLOUT : 0)), 0},
            {session->output.size ? STDOUT_FILENO : -1, POLLOUT, 0},
            {owns_group ? -1 : ready[0], POLLIN, 0}
        };
        int polled = poll(fds, 4, 20);
        if (polled < 0) { if (errno == EINTR) continue; result = INTERNAL; break; }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
            result = read_control(session, master_eof ? -1 : master, owns_group && !exited);
            if (result) break;
        }
        if (!owns_group && (fds[3].revents & (POLLIN | POLLHUP | POLLERR))) {
            char byte;
            ssize_t count = read(ready[0], &byte, 1);
            if (count == 1 && byte == 'R') {
                owns_group = true; // ownership established BEFORE granting exec
                if (cancelled) { result = CANCELLED; break; }
                if (write(ack[1], "G", 1) != 1) { result = INTERNAL; break; }
                close(ack[1]); ack[1] = -1;
                close(ready[0]); ready[0] = -1;
            } else if (count <= 0 && errno != EAGAIN && errno != EINTR) { result = INTERNAL; break; }
            else if (!count) { result = INTERNAL; break; }
        }
        if (fds[2].revents & (POLLHUP | POLLERR | POLLNVAL)) { result = BACKPRESSURE; break; }
        if (fds[2].revents & POLLOUT) {
            ssize_t count = write(STDOUT_FILENO, session->output.bytes + session->output.start, session->output.size);
            if (count > 0) { queue_consumed(&session->output, (size_t)count); session->last_output_progress = current; }
            else if (count < 0 && errno != EAGAIN && errno != EINTR) { result = BACKPRESSURE; break; }
        }
        if ((fds[1].revents & POLLOUT) && session->input.size) {
            ssize_t count = write(master, session->input.bytes + session->input.start, session->input.size);
            if (count > 0) queue_consumed(&session->input, (size_t)count);
            else if (count < 0 && errno != EAGAIN && errno != EINTR && errno != EIO) { result = INTERNAL; break; }
        }
        if ((fds[1].revents & (POLLIN | POLLHUP | POLLERR)) && session->output.size < QUEUE_LIMIT) {
            unsigned char bytes[16384];
            size_t available = QUEUE_LIMIT - session->output.size;
            if (available > sizeof(bytes)) available = sizeof(bytes);
            ssize_t count = read(master, bytes, available);
            if (count > 0) {
                if ((size_t)count > OUTPUT_LIMIT - session->output_total) { result = OUTPUT_BOUND; break; }
                if (!session->output.size) session->last_output_progress = current;
                session->output_total += (size_t)count;
                if (!queue_append(&session->output, bytes, (size_t)count)) { result = INTERNAL; break; }
            } else if (!count || (count < 0 && errno == EIO)) master_eof = true;
            else if (errno != EAGAIN && errno != EINTR) { result = INTERNAL; break; }
        }
        if (!exited) {
            siginfo_t info; memset(&info, 0, sizeof(info));
            int observed = waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT);
            if (observed < 0) { if (errno == EINTR) continue; result = INTERNAL; break; }
            if (info.si_pid == child) {
                exited = true;
                // Reserve the zombie leader through drain/cleanup. Stop helpers
                // even after a successful update before considering upgrade.
                if (owns_group) (void)kill(-child, SIGKILL);
                memset(&session->input, 0, sizeof(session->input));
                session->frame.input_allowed = false;
            }
        }
    }
    int status = 0;
    if (stop_and_reap(child, owns_group, &status)) result = INTERNAL;
    else {
        bool sent;
        if (WIFEXITED(status)) sent = record("EXIT", phase, WEXITSTATUS(status));
        else if (WIFSIGNALED(status)) sent = record("SIGNAL", phase, WTERMSIG(status));
        else sent = false;
        if (!sent && !result) result = INTERNAL;
        if (!result && (!WIFEXITED(status) || WEXITSTATUS(status))) result = CHILD_FAILED;
    }
    close(master);
    if (ready[0] >= 0) close(ready[0]);
    if (ack[1] >= 0) close(ack[1]);
    return result;
}
int main(int argc, char **argv) {
    int result = INTERNAL;
    if (nonblocking(STDERR_FILENO)) return INTERNAL;
    if (close_inherited_descriptors() || nonblocking(STDIN_FILENO) || nonblocking(STDOUT_FILENO)) goto done;
    struct sigaction action; memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask); action.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &action, NULL)) goto done;
    action.sa_handler = signal_cancel;
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL) || sigaction(SIGHUP, &action, NULL)) goto done;
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, NULL)) goto done;
    sigset_t empty; sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL)) goto done;
    Snapshot approved = {0}, verified = {0};
    char home[PATH_MAX];
    if (argc != 11 || getuid() != geteuid() || !fixed_path(argv[1]) ||
        !verified_home(argv[2], home) || !parse_snapshot(argv, &approved)) { result = INVALID; goto done; }
    Session *session = calloc(1, sizeof(*session));
    if (!session) goto done;
    session->started = monotonic_now(); session->last_output_progress = session->started;
    session->size.ws_row = 24; session->size.ws_col = 80;
    if (session->started < 0) { free(session); goto done; }
    result = transition_control(session);
    int executable = -1;
    if (!result) {
        executable = verify_executable(argv[1], &approved, &verified);
        if (executable < 0) result = cancelled ? CANCELLED : VERIFY_FAILED;
    }
    if (!result && cancelled) result = CANCELLED;
    if (!result) result = run_phase(session, argv[1], home, "update", executable, &verified);
    if (executable >= 0) close(executable);
    executable = -1;
    if (!result) result = transition_control(session);
    // update may legitimately replace brew. Open and verify the fixed path
    // again against owner/mode/type and a newly stable stat+SHA256 observation.
    if (!result) {
        executable = verify_executable(argv[1], NULL, &verified);
        if (executable < 0) result = cancelled ? CANCELLED : VERIFY_FAILED;
    }
    if (!result) result = transition_control(session);
    if (!result && cancelled) result = CANCELLED;
    if (!result) result = run_phase(session, argv[1], home, "upgrade", executable, &verified);
    if (executable >= 0) close(executable);
    free(session);
done:
    (void)record("RESULT", NULL, result);
    return result;
}
