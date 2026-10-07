// Synthetic test program only. It never calls Homebrew or any package manager.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
static void fail(void) { _exit(90); }
static void write_all(int fd, const void *data, size_t size) {
    const char *bytes = data;
    while (size) {
        ssize_t count = write(fd, bytes, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) fail();
        bytes += count; size -= (size_t)count;
    }
}
static void mark(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) fail();
    write_all(fd, value, strlen(value)); close(fd);
}
static void sleep_ms(long milliseconds) {
    struct timespec value = {milliseconds / 1000, milliseconds % 1000 * 1000000};
    while (nanosleep(&value, &value) && errno == EINTR) {}
}
static void descendant(bool exit_leader) {
    pid_t child = fork();
    if (child < 0) fail();
    if (!child) { for (;;) pause(); }
    char number[64]; snprintf(number, sizeof(number), "%ld\n", (long)child);
    mark("descendant-pid", number);
    if (!exit_leader) for (;;) pause();
}
static void replace_self(const char *path) {
    int source = open(path, O_RDONLY), target = open("replacement", O_WRONLY | O_CREAT | O_EXCL, 0700);
    if (source < 0 || target < 0) fail();
    char bytes[16384];
    for (;;) {
        ssize_t count = read(source, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) fail();
        if (!count) break;
        write_all(target, bytes, (size_t)count);
    }
    close(source); close(target);
    if (rename("replacement", path)) fail();
}
int main(int argc, char **argv) {
    bool update = argc == 2 && !strcmp(argv[1], "update");
    bool upgrade = argc == 4 && !strcmp(argv[1], "upgrade") && !strcmp(argv[2], "--formula") && !strcmp(argv[3], "mole");
    if (!update && !upgrade) fail();
    if (!isatty(0) || !isatty(1) || !isatty(2) || getsid(0) != getpid() || getpgrp() != getpid()) fail();
    for (int fd = 3; fd < 256; ++fd) if (fcntl(fd, F_GETFD) >= 0) fail();
    setvbuf(stdout, NULL, _IONBF, 0);
    char mode[128] = {0};
    FILE *file = fopen("mode", "r");
    if (!file || !fgets(mode, sizeof(mode), file)) fail();
    fclose(file);
    mode[strcspn(mode, "\n")] = 0;
    mark("calls", update ? "update\n" : "upgrade --formula mole\n");
    printf("FIXTURE %s\n", update ? "update" : "upgrade");
    if (!strcmp(mode, "environment")) {
        for (char **entry = environ; *entry; ++entry) printf("ENV:%s\n", *entry);
    }
    if (update && !strcmp(mode, "interactive")) {
        puts("READY");
        char line[128];
        if (!fgets(line, sizeof(line), stdin)) fail();
        struct winsize size;
        if (ioctl(0, TIOCGWINSZ, &size)) fail();
        printf("INPUT:%sSIZE:%u,%u\n", line, size.ws_row, size.ws_col);
    }
    if (upgrade && !strcmp(mode, "phase-input")) {
        puts("UPGRADE-READY");
        char line[128];
        if (!fgets(line, sizeof(line), stdin)) fail();
        printf("UPGRADE-INPUT:%s", line);
    }
    if (update && !strcmp(mode, "ctrl-c")) { puts("READY"); for (;;) pause(); }
    if (update && !strcmp(mode, "sleep")) { puts("READY"); for (;;) pause(); }
    if (update && !strcmp(mode, "update-failure")) return 19;
    if (upgrade && !strcmp(mode, "upgrade-failure")) return 23;
    if (update && !strcmp(mode, "signal")) raise(SIGTERM);
    if (update && !strcmp(mode, "descendant")) descendant(false);
    if (update && !strcmp(mode, "orphan-success")) descendant(true);
    if (update && !strcmp(mode, "orphan-failure")) { descendant(true); return 17; }
    if ((update && !strcmp(mode, "flood")) || !strcmp(mode, "flood-both") || (update && !strcmp(mode, "flush"))) {
        char bytes[16384]; memset(bytes, 'x', sizeof(bytes));
        size_t count = !strcmp(mode, "flood") ? 1280 : (!strcmp(mode, "flood-both") ? 576 : 16);
        for (size_t i = 0; i < count; ++i) write_all(STDOUT_FILENO, bytes, sizeof(bytes));
    }
    if (update && !strcmp(mode, "replace-alias")) {
        char alias[4096];
        FILE *location = fopen("test-alias-path", "r");
        if (!location || !fgets(alias, sizeof(alias), location)) fail();
        fclose(location);
        if (unlink(alias) || symlink("disallowed-target", alias)) fail();
    }
    if (update && !strcmp(mode, "replace")) replace_self(argv[0]);
    if (update && !strcmp(mode, "insecure-update")) { if (chmod(argv[0], 0777)) fail(); }
    if (update && !strcmp(mode, "symlink-update")) {
        replace_self(argv[0]);
        if (rename(argv[0], "saved-binary") || symlink("saved-binary", argv[0])) fail();
    }
    if (!strcmp(mode, "discard-input")) {
        if (update) {
            puts("READY");
            char line[128]; if (!fgets(line, sizeof(line), stdin)) fail();
        } else {
            struct termios attributes;
            if (tcgetattr(0, &attributes)) fail();
            attributes.c_lflag &= (tcflag_t)~(ICANON | ECHO);
            attributes.c_cc[VMIN] = 0; attributes.c_cc[VTIME] = 1;
            if (tcsetattr(0, TCSANOW, &attributes)) fail();
            char byte;
            if (read(0, &byte, 1) != 0) fail();
            puts("INPUT-CLEARED");
        }
    }
    if (update && !strcmp(mode, "brief")) sleep_ms(100);
    puts("DONE");
    return 0;
}
