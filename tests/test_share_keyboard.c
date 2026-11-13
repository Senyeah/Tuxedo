/* /.henge/keyboard through the share server on a Unix socket, as henge-keyboard in a Linux desktop uses it:
   PUT is the guest's request for the device's keyboard, GET the device keyboard's height. */
#include "share.h"

#include <pthread.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static int failed;

static void check(const char *what, long got, long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %ld, want %ld\n", what, got, want);
    failed = 1;
}

int hv_vm_display(uint32_t *w, uint32_t *h, double *scale) { (void)w, (void)h, (void)scale; return 0; }

static char sock_path[64];
static char resp[1024]; /* the last response, whole */

/* One request on its own connection; returns the status, or -1. */
static int request(const char *method, const char *target, const char *body) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, sock_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) return -1;
    char req[512];
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

/* The body and X-Henge-Seq of the last response. */
static const char *body(void) {
    const char *b = strstr(resp, "\r\n\r\n");
    return b ? b + 4 : "";
}

static long resp_seq(void) {
    const char *h = strstr(resp, "X-Henge-Seq: ");
    return h ? atol(h + 13) : -1;
}

static void *later_height(void *arg) {
    (void)arg;
    usleep(300 * 1000);
    hv_share_set_keyboard_height(0.25);
    return NULL;
}

static double since_ms(struct timespec t0) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)(t.tv_sec - t0.tv_sec) * 1000 + (double)(t.tv_nsec - t0.tv_nsec) / 1e6;
}

static void test_height(void) {
    check("height: GET status", request("GET", "/.henge/keyboard", ""), 200);
    check("height: down at the start", !strcmp(body(), "height 0.000\n"), 1);
    check("height: no change yet", resp_seq(), 0);

    hv_share_set_keyboard_height(0.4);
    check("height 0.4: status", request("GET", "/.henge/keyboard", ""), 200);
    check("height 0.4: body", !strcmp(body(), "height 0.400\n"), 1);
    check("height 0.4: one change", resp_seq(), 1);
    hv_share_set_keyboard_height(0.4004); /* the same thousandth */
    request("GET", "/.henge/keyboard", "");
    check("height: the same value is no change", resp_seq(), 1);

    hv_share_set_keyboard_height(1.5);
    request("GET", "/.henge/keyboard", "");
    check("height: above 1 is 1", !strcmp(body(), "height 1.000\n"), 1);
    hv_share_set_keyboard_height(-2);
    request("GET", "/.henge/keyboard", "");
    check("height: below 0 is 0", !strcmp(body(), "height 0.000\n"), 1);
    hv_share_set_keyboard_height(0.0 / 0.0);
    request("GET", "/.henge/keyboard", "");
    check("height: not a number is 0", !strcmp(body(), "height 0.000\n"), 1);
    long seq = resp_seq();
    check("height: three changes", seq, 3);

    /* since is the count: the answer waits for a change */
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    pthread_t t;
    pthread_create(&t, NULL, later_height, NULL);
    char target[64];
    snprintf(target, sizeof target, "/.henge/keyboard?since=%ld", seq);
    check("height: wait: status", request("GET", target, ""), 200);
    double ms = since_ms(t0);
    pthread_join(t, NULL);
    check("height: wait: the answer came with the change", ms >= 250 && ms < 5000, 1);
    check("height: wait: body", !strcmp(body(), "height 0.250\n"), 1);
    check("height: wait: count", resp_seq(), seq + 1);

    /* since is not the count (the app started again): at once */
    clock_gettime(CLOCK_MONOTONIC, &t0);
    check("height: other since: status", request("GET", "/.henge/keyboard?since=999", ""), 200);
    check("height: other since: at once", since_ms(t0) < 1000, 1);
    check("height: other since: count", resp_seq(), seq + 1);

    /* The two directions do not touch each other */
    unsigned long before, after;
    hv_share_keyboard_wanted(&before);
    hv_share_set_keyboard_height(0);
    check("height: no request from the guest", (hv_share_keyboard_wanted(&after), (long)(after - before)), 0);
    request("PUT", "/.henge/keyboard", "hide");
    request("GET", "/.henge/keyboard", "");
    check("height: a request does not change it", resp_seq(), seq + 2);
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

    test_height();
    check("the clipboard still answers", request("PUT", "/.henge/clipboard", "text"), 204);
    char *clip = hv_share_take_clipboard();
    check("the clipboard is not the keyboard", clip && !strcmp(clip, "text"), 1);
    free(clip);

    unlink(sock_path);
    rmdir(dir);
    if (!failed) printf("test_share_keyboard: ok\n");
    return failed;
}
