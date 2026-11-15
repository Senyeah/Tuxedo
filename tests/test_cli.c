/* tuxvm's command line: virt is the only board, and the macOS flags are unknown options. */
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static int failures;

static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

/* Runs build/tuxvm; returns its exit status, with stderr in err. */
static int run(char *const argv[], char *err, size_t cap) {
    int fds[2];
    if (pipe(fds)) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", 0, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", 1, 0);
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    if (rc) return -1;
    size_t n = 0;
    ssize_t r;
    while (n + 1 < cap && (r = read(fds[0], err + n, cap - n - 1)) > 0) n += (size_t)r;
    err[n] = 0;
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main(void) {
    alarm(60);
    char err[4096], dtb[] = "/tmp/tux-cli-XXXXXX";
    int fd = mkstemp(dtb);
    if (fd < 0) return 1;
    close(fd);

    /* No --board: the tree it writes is the virt board's, which has a PL011 at 0x9000000. */
    char *ok[] = {"build/tuxvm", "--dump-dtb", dtb, "--ram", "64", NULL};
    check("a command line without --board builds the virt board", run(ok, err, sizeof err) == 0);
    FILE *f = fopen(dtb, "rb");
    static unsigned char blob[1 << 16];
    size_t n = f ? fread(blob, 1, sizeof blob, f) : 0;
    if (f) fclose(f);
    check("the tree is the virt board's", n > 4 && blob[0] == 0xd0 && blob[1] == 0x0d && blob[2] == 0xfe && blob[3] == 0xed &&
                                              memmem(blob, n, "pl011", 5) != NULL);
    unlink(dtb);

    static const char *const gone[][2] = {{"--board", "virt"}, {"--rom", "x"}, {"--aux", "x"},
                                          {"--ecid", "1"}, {"--seed", "1"}, {"--install", "x"}, {"--no-pvg", NULL},
                                          {"--aux-offset", "1"}};
    for (size_t i = 0; i < sizeof gone / sizeof *gone; i++) {
        char *argv[8] = {"build/tuxvm", (char *)gone[i][0]};
        int k = 2;
        if (gone[i][1]) argv[k++] = (char *)gone[i][1];
        argv[k++] = "--kernel";
        argv[k++] = "/nonexistent";
        argv[k] = NULL;
        char what[96];
        snprintf(what, sizeof what, "%s is an unknown option (usage, exit 2)", gone[i][0]);
        check(what, run(argv, err, sizeof err) == 2 && strncmp(err, "usage:", 6) == 0);
    }
    char *bare[] = {"build/tuxvm", NULL};
    run(bare, err, sizeof err);
    check("the usage text names none of the removed flags", !strstr(err, "--board") && !strstr(err, "--rom") && !strstr(err, "--aux") &&
                                                              !strstr(err, "--ecid") && !strstr(err, "--install") && !strstr(err, "--no-pvg"));
    printf("CLI: %d failures\n", failures);
    return failures != 0;
}
