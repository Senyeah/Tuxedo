/* PUT /.henge/keyboard through the share server on a Unix socket, as henge-keyboard in a Linux desktop sends it. */
#include "share.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int failed;

static void check(const char *what, long got, long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %ld, want %ld\n", what, got, want);
    failed = 1;
}

int hv_vm_display(uint32_t *w, uint32_t *h, double *scale) { (void)w, (void)h, (void)scale; return 0; }

static char sock_path[64];

/* One request on its own connection; returns the status, or -1. */
static int request(const char *method, const char *target, const char *body) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, sock_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) return -1;
    char req[512], resp[1024];
    int n = snprintf(req, sizeof req, "%s %s HTTP/1.1\r\nHost: 10.0.2.4\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                     method, target, strlen(body), body);
    if (write(fd, req, (size_t)n) != n) return -1;
    size_t have = 0;
    ssize_t got;
    while (have < sizeof resp - 1 && (got = read(fd, resp + have, sizeof resp - 1 - have)) > 0) have += (size_t)got;
    resp[have] = 0;
    close(fd);
    int status = -1;
    sscanf(resp, "HTTP/1.1 %d", &status);
    return status;
}

int main(void) {
    char dir[] = "/tmp/henge-kbd-XXXXXX";
    if (!mkdtemp(dir)) return 1;
    snprintf(sock_path, sizeof sock_path, "%s/s", dir);
    check("the share server starts", hv_share_start(dir, sock_path, NULL), 0);

    unsigned long seq = 99, first;
    check("nothing asked yet: hide", hv_share_keyboard_wanted(&first), 0);

    check("PUT show: status", request("PUT", "/.henge/keyboard", "show"), 204);
    check("PUT show: wanted", hv_share_keyboard_wanted(&seq), 1);
    check("PUT show: a new request", (long)(seq - first), 1);

    check("PUT show again: status", request("PUT", "/.henge/keyboard", "show"), 204);
    check("PUT show again: wanted", hv_share_keyboard_wanted(&seq), 1);
    check("PUT show again: a new request", (long)(seq - first), 2);

    check("PUT hide: status", request("PUT", "/.henge/keyboard", "hide"), 204);
    check("PUT hide: wanted", hv_share_keyboard_wanted(&seq), 0);
    check("PUT hide: a new request", (long)(seq - first), 3);

    check("no sequence wanted", hv_share_keyboard_wanted(NULL), 0);

    request("PUT", "/.henge/keyboard", "show");
    static const char *const bad[] = {"", "sho", "shown", "SHOW", "show\n", "1"};
    for (size_t k = 0; k < sizeof bad / sizeof *bad; k++) check("a bad body: status", request("PUT", "/.henge/keyboard", bad[k]), 400);
    check("a bad body changes nothing: wanted", hv_share_keyboard_wanted(&seq), 1);
    check("a bad body changes nothing: request", (long)(seq - first), 4);

    check("GET is not served", request("GET", "/.henge/keyboard", ""), 404);
    check("the clipboard still answers", request("PUT", "/.henge/clipboard", "text"), 204);
    char *clip = hv_share_take_clipboard();
    check("the clipboard is not the keyboard", clip && !strcmp(clip, "text"), 1);
    free(clip);

    unlink(sock_path);
    rmdir(dir);
    if (!failed) printf("test_share_keyboard: ok\n");
    return failed;
}
