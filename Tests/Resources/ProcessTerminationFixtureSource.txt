// Original, deliberately inert fixture. Tests own and reap every invocation.
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
static volatile sig_atomic_t reexec_requested = 0;
static void request_reexec(int signal_number) { (void)signal_number; reexec_requested = 1; }
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (strcmp(argv[1], "ignore-term") == 0) signal(SIGTERM, SIG_IGN);
    signal(SIGUSR1, request_reexec);
    int ready = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (ready < 0) return 3;
    if (write(ready, "ready", 5) != 5) return 4;
    close(ready);
    while (!reexec_requested) pause();
    execv(argv[0], argv);
    return 5;
}
