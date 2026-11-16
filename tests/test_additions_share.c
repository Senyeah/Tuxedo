/* SPDX-License-Identifier: GPL-2.0-or-later */
/* GET and POST /.tux/additions through the share server on a Unix socket, as the Tuxedo Additions agent in a guest
   uses them: 200 with the sequence, 400 for a body that is not a JSON object with a string "t", 413 over 64 KB (by
   Content-Length and chunked), the long poll with X-Tux-Seq, the job in the answer, a "done" event that takes the
   job away, and events that came before anyone read them. The state itself is in test_additions. */
#include "additions.h"
#include "share.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static int failed;

static void check(const char *what, long long got, long long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %lld, want %lld\n", what, got, want);
    failed = 1;
}

static int has(const char *hay, const char *needle) { return hay && strstr(hay, needle) != NULL; }

int hv_vm_display(uint32_t *w, uint32_t *h, double *scale) { (void)w, (void)h, (void)scale; return 0; }

static char sock_path[64];
static char resp[200000]; /* the last response, whole */

/* The bytes of one request on its own connection; returns the status, or -1. */
static int raw(const char *req, size_t n) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, sock_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) return -1;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, req + sent, n - sent);
        if (w <= 0) break; /* the server may answer 413 and close before it has read all */
        sent += (size_t)w;
    }
    size_t have = 0;
    ssize_t got;
    while (have < sizeof resp - 1 && (got = read(fd, resp + have, sizeof resp - 1 - have)) > 0) have += (size_t)got;
    resp[have] = 0;
    close(fd);
    int status = -1;
    sscanf(resp, "HTTP/1.1 %d", &status);
    return status;
}

static int request(const char *method, const char *target, const char *body, size_t len) {
    char *req = malloc(len + 256);
    int n = snprintf(req, 256, "%s %s HTTP/1.1\r\nHost: 10.0.2.4\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", method, target, len);
    memcpy(req + n, body, len);
    int status = raw(req, (size_t)n + len);
    free(req);
    return status;
}

static int get(const char *target) { return request("GET", target, "", 0); }
static int post(const char *body) { return request("POST", "/.tux/additions", body, strlen(body)); }

static const char *body(void) {
    const char *b = strstr(resp, "\r\n\r\n");
    return b ? b + 4 : "";
}

static long resp_seq(void) {
    const char *h = strstr(resp, "X-Tux-Seq: ");
    return h ? atol(h + strlen("X-Tux-Seq: ")) : -1;
}

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000 + (double)t.tv_nsec / 1e6;
}

static int events_have(const char *needle) {
    char *j = hv_additions_events_json(0, NULL);
    int r = has(j, needle);
    free(j);
    return r;
}

static int events_count(void) {
    char *j = hv_additions_events_json(0, NULL);
    int n = 0;
    for (const char *p = j; (p = strstr(p, "{\"k\":")); p++) n++;
    free(j);
    return n;
}

static int job_in_memory(void) { return has(hv_additions_test_job_buffer(NULL), "SECRET"); }

static void *later(void *arg) {
    int what = *(int *)arg;
    usleep(300 * 1000);
    if (what == 0) hv_additions_job_set("{\"id\":\"j-late\",\"steps\":[]}");
    else if (what == 1) hv_additions_nudge();
    else hv_additions_job_cancel();
    return NULL;
}

static void test_post(void) {
    hv_additions_reset();
    int e0 = events_count();
    check("POST: a report", post("{\"t\":\"report\",\"n\":1,\"agent\":\"1.0\",\"protocol\":1,\"caps\":{\"root\":true}}"), 200);
    char want[48];
    snprintf(want, sizeof want, "{\"seq\":%lu}", hv_additions_seq());
    check("POST: the body is the sequence", !strcmp(body(), want), 1);
    check("POST: JSON content type", has(resp, "Content-Type: application/json"), 1);
    check("POST: the event is kept", events_count() - e0, 1);
    check("POST: as it came", events_have("\"e\":{\"t\":\"report\",\"n\":1,\"agent\":\"1.0\",\"protocol\":1,\"caps\":{\"root\":true}}"), 1);
    check("POST: a step", post("{\"t\":\"step\",\"job\":\"j\",\"i\":0,\"status\":\"ok\",\"msg\":\"m\"}"), 200);
    snprintf(want, sizeof want, "{\"seq\":%lu}", hv_additions_seq());
    check("POST: the next sequence", !strcmp(body(), want), 1);
    check("POST: spaces and line ends around it", post(" \r\n{\"t\":\"log\",\n\"job\":\"j\",\"text\":\"x\"}\n"), 200);
    check("POST: three events kept", events_count() - e0, 3);

    static const char *const bad[] = {"", "{}", "{\"t\":5}", "{\"t\":null}", "{\"x\":\"report\"}", "[\"report\"]", "{\"t\":\"x\"", "not json", "{\"t\":\"x\"} extra",
                                      "{\"t\":\"\\ud800\"}", "{\"t\":\"x\",}", "\"report\"", "null"};
    int before = events_count();
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        char what[64];
        snprintf(what, sizeof what, "POST: bad body #%zu", i);
        check(what, post(bad[i]), 400);
        check("POST: a bad body has no JSON answer", has(body(), "seq"), 0);
    }
    check("POST: nothing bad was kept", events_count(), before);
    const char *bad_utf8 = "{\"t\":\"x\",\"a\":\"\xff\"}";
    check("POST: invalid UTF-8", request("POST", "/.tux/additions", bad_utf8, strlen(bad_utf8)), 400);
    check("POST: a NUL in the body", request("POST", "/.tux/additions", "{\"t\":\"x\"}\0{}", 12), 400);

    /* 64 KB: the limit by Content-Length. */
    size_t big = HV_ADDITIONS_EVENT_MAX + 1;
    char *b = malloc(big + 1);
    memset(b, ' ', big);
    memcpy(b, "{\"t\":\"log\"}", 11);
    before = events_count();
    check("POST: 65537 bytes", request("POST", "/.tux/additions", b, big), 413);
    check("POST: 65537 bytes keeps nothing", events_count(), before);
    check("POST: 65536 bytes", request("POST", "/.tux/additions", b, HV_ADDITIONS_EVENT_MAX), 200);
    check("POST: 65536 bytes is kept", events_count(), before + 1);
    free(b);
    /* The server may stop reading at once: the limit does not depend on the bytes being sent. */
    {
        const char *head = "POST /.tux/additions HTTP/1.1\r\nHost: 10.0.2.4\r\nContent-Length: 70000\r\nConnection: close\r\n\r\n";
        char *req = malloc(strlen(head) + 70000);
        memcpy(req, head, strlen(head));
        memset(req + strlen(head), 'x', 70000);
        check("POST: Content-Length 70000", raw(req, strlen(head) + 70000), 413);
        free(req);
    }

    /* Chunked: no length up front, so the limit is checked on what came. */
    {
        char *req = malloc(HV_ADDITIONS_EVENT_MAX * 2 + 512);
        const char *head = "POST /.tux/additions HTTP/1.1\r\nHost: 10.0.2.4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
        size_t n = (size_t)snprintf(req, 512, "%s", head);
        n += (size_t)snprintf(req + n, 64, "%x\r\n%s\r\n0\r\n\r\n", 11, "{\"t\":\"log\"}");
        before = events_count();
        check("POST: chunked, small", raw(req, n), 200);
        check("POST: chunked, small, kept", events_count(), before + 1);
        n = (size_t)snprintf(req, 512, "%s", head);
        size_t part = 40000;
        for (int i = 0; i < 2; i++) {
            n += (size_t)snprintf(req + n, 32, "%zx\r\n", part);
            memset(req + n, ' ', part);
            if (i == 0) memcpy(req + n, "{\"t\":\"log\"}", 11);
            n += part;
            memcpy(req + n, "\r\n", 2), n += 2;
        }
        memcpy(req + n, "0\r\n\r\n", 5), n += 5;
        check("POST: chunked, 80000 bytes", raw(req, n), 413);
        check("POST: chunked, 80000 bytes, kept nothing", events_count(), before + 1);
        free(req);
    }

    /* Only the two methods. */
    check("PUT is not served", request("PUT", "/.tux/additions", "{\"t\":\"x\"}", 9), 404);
    check("DELETE is not served", request("DELETE", "/.tux/additions", "", 0), 404);
    check("another name is not served", get("/.tux/additions/x"), 404);
    check("POST to another name is not served", request("POST", "/.tux/additionsx", "{\"t\":\"x\"}", 9), 404);
}

static void test_get(void) {
    hv_additions_reset();
    check("GET: status", get("/.tux/additions"), 200);
    check("GET: nothing in", !strcmp(body(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}"), 1);
    check("GET: JSON content type", has(resp, "Content-Type: application/json"), 1);
    check("GET: no caching", has(resp, "Cache-Control: no-store"), 1);
    check("GET: the sequence", resp_seq(), (long)hv_additions_seq());

    char media[] = "/tmp/tux-addm-XXXXXX";
    if (!mkdtemp(media)) return;
    check("insert", hv_additions_insert(media), 1);
    get("/.tux/additions");
    check("GET: inserted, n 1", !strcmp(body(), "{\"inserted\":true,\"n\":1,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}"), 1);
    long seq = resp_seq();
    check("GET: the sequence moved", seq, (long)hv_additions_seq());
    check("GET: nudge", hv_additions_nudge(), 2);
    get("/.tux/additions");
    check("GET: n 2", has(body(), "\"n\":2,"), 1);
    check("GET: the sequence moved again", resp_seq(), seq + 1);

    check("job", hv_additions_job_set("{\"id\":\"j-1\",\"steps\":[{\"action\":\"user.setup\",\"name\":\"tux\",\"password\":\"SECRET\"}]}"), 0);
    get("/.tux/additions");
    check("GET: the job", has(body(), "\"job\":{\"id\":\"j-1\",\"steps\":[{\"action\":\"user.setup\",\"name\":\"tux\",\"password\":\"SECRET\"}]},\"taken\":null}"), 1);
    check("GET: the job comes again until the agent acks it", get("/.tux/additions") == 200 && has(body(), "j-1"), 1);

    /* The job takes a small body and a big one. */
    {
        char *j = malloc(HV_ADDITIONS_JOB_MAX + 1);
        memset(j, 'x', HV_ADDITIONS_JOB_MAX);
        memcpy(j, "{\"id\":\"big\",\"pad\":\"", 19);
        memcpy(j + HV_ADDITIONS_JOB_MAX - 2, "\"}", 2);
        j[HV_ADDITIONS_JOB_MAX] = 0;
        check("job of 16384 bytes", hv_additions_job_set(j), 0);
        free(j);
        check("GET: a job of 16384 bytes", get("/.tux/additions"), 200);
        check("GET: it is whole", has(body(), "\"job\":{\"id\":\"big\"") && strlen(body()) > HV_ADDITIONS_JOB_MAX && body()[strlen(body()) - 1] == '}', 1);
    }

    check("cancel", hv_additions_job_cancel(), 0);
    get("/.tux/additions");
    check("GET: cancel, with no job", !strcmp(body(), "{\"inserted\":true,\"n\":2,\"cancel\":true,\"cancel_job\":\"big\",\"job\":null,\"taken\":null}"), 1);

    check("job again", hv_additions_job_set("{\"id\":\"j-2\",\"steps\":[{\"action\":\"x\",\"password\":\"SECRET\"}]}"), 0);
    get("/.tux/additions");
    check("GET: a new job keeps the cancel for the old id", has(body(), "\"cancel\":true,\"cancel_job\":\"big\",\"job\":{\"id\":\"j-2\""), 1);
    check("the job is in the host's memory", job_in_memory(), 1);
    check("POST: a done for another job", post("{\"t\":\"done\",\"job\":\"big\",\"ok\":false}"), 200);
    check("a stale done: the job stays in the host's memory", job_in_memory(), 1);
    check("POST: ack from the agent", post("{\"t\":\"ack\",\"job\":\"j-2\"}"), 200);
    check("ack: the job is out of the host's memory", job_in_memory(), 0);
    get("/.tux/additions");
    check("ack: GET has no job, and the taken id", has(body(), "\"job\":null,\"taken\":\"j-2\"}") && !has(body(), "SECRET"), 1);
    get("/.tux/additions");
    check("ack: the next GET is the same", has(body(), "\"job\":null,\"taken\":\"j-2\"}"), 1);
    check("ack: the event is there for the app", events_have("\"t\":\"ack\",\"job\":\"j-2\""), 1);
    hv_additions_job_set("{\"id\":\"j-2\",\"steps\":[{\"action\":\"x\",\"password\":\"SECRET\"}]}");
    check("POST: done from the agent", post("{\"t\":\"done\",\"job\":\"j-2\",\"ok\":true,\"reboot\":false,\"info\":{\"ips\":[\"10.0.2.15\"]}}"), 200);
    check("done: the job is out of the host's memory", job_in_memory(), 0);
    get("/.tux/additions");
    check("done: GET has no job, nothing taken", has(body(), "\"job\":null,\"taken\":null}"), 1);
    check("done: the event is there for the app", events_have("\"t\":\"done\""), 1);
    hv_additions_job_set("{\"id\":\"j-3\",\"password\":\"SECRET\"}");
    check("a step that says done in its text", post("{\"t\":\"step\",\"job\":\"j-3\",\"i\":0,\"status\":\"running\",\"msg\":\"done\"}"), 200);
    check("a step does not take the job: still in memory", job_in_memory(), 1);
    check("a job with no id is refused", hv_additions_job_set("{\"password\":\"SECRET\"}"), -1);
    hv_additions_eject();
    check("eject wipes the pending job", job_in_memory(), 0);
    get("/.tux/additions");
    check("GET: ejected, no job", has(body(), "{\"inserted\":false,\"n\":0,") && has(body(), "\"job\":null,"), 1);
    hv_additions_job_clear();
    get("/.tux/additions");
    check("GET: cleared", !strcmp(body(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}"), 1);
    rmdir(media);
}

static void test_poll(void) {
    hv_additions_reset();
    char media[] = "/tmp/tux-addp-XXXXXX";
    if (!mkdtemp(media)) return;
    get("/.tux/additions");
    long seq = resp_seq();

    /* since is the count: the answer waits for news. */
    for (int what = 0; what < 3; what++) {
        static const char *const names[] = {"a job", "a nudge", "a cancel"};
        if (what == 1) hv_additions_insert(media);
        get("/.tux/additions");
        seq = resp_seq();
        int arg = what;
        pthread_t t;
        pthread_create(&t, NULL, later, &arg);
        char target[64];
        snprintf(target, sizeof target, "/.tux/additions?since=%ld", seq);
        double t0 = now_ms();
        check(names[what], request("GET", target, "", 0), 200);
        double ms = now_ms() - t0;
        pthread_join(t, NULL);
        check("poll: the answer came with the news", ms >= 250 && ms < 5000, 1);
        check("poll: the sequence is newer", resp_seq(), seq + 1);
        if (what == 0) check("poll: the new job", has(body(), "\"job\":{\"id\":\"j-late\""), 1);
        if (what == 1) check("poll: n 2", has(body(), "\"n\":2,"), 1);
        if (what == 2) check("poll: cancel", has(body(), "\"cancel\":true"), 1);
    }

    /* News is held for a poll that was not there: since an older count answers at once. */
    get("/.tux/additions");
    seq = resp_seq();
    hv_additions_job_set("{\"id\":\"j-held\"}");
    char target[64];
    snprintf(target, sizeof target, "/.tux/additions?since=%ld", seq);
    double t0 = now_ms();
    check("poll: news that came before the poll", request("GET", target, "", 0), 200);
    check("poll: at once", now_ms() - t0 < 1000, 1);
    check("poll: with the job", has(body(), "j-held"), 1);
    check("poll: a count from another process answers at once", get("/.tux/additions?since=999999999") == 200 && now_ms() - t0 < 2000, 1);
    t0 = now_ms();
    check("poll: since 0 at once", get("/.tux/additions?since=0"), 200);
    check("poll: since 0 is at once", now_ms() - t0 < 1000, 1);

    /* The guest's own events wake its poll too (one count for all news); the answer is the same as before. */
    get("/.tux/additions");
    seq = resp_seq();
    snprintf(target, sizeof target, "/.tux/additions?since=%ld", seq);
    hv_additions_eject();
    check("poll: an eject is news", get(target), 200);
    check("poll: not inserted", has(body(), "\"inserted\":false"), 1);
    rmdir(media);
}

/* A guest that is up before the app: the events are there when the app looks. */
static void test_before_the_app(void) {
    hv_additions_reset();
    check("boot report before anyone looks", post("{\"t\":\"report\",\"n\":0,\"agent\":\"boot\",\"protocol\":1,\"caps\":{\"account\":{\"configured\":false,\"autologin\":\"root\"}}}"), 200);
    check("a second one", post("{\"t\":\"report\",\"n\":0,\"agent\":\"boot\",\"protocol\":1,\"caps\":{\"account\":{\"configured\":false,\"autologin\":\"root\"},\"network\":true}}"), 200);
    unsigned long seq = 0;
    char *j = hv_additions_events_json(0, &seq);
    check("the app starts at 0 and sees both", has(j, "\"network\":true") && has(j, "\"configured\":false"), 1);
    check("without a gap", has(j, "\"gap\":false"), 1);
    free(j);
    check("the app's wait from 0 answers at once", hv_additions_wait(0, 5000) == seq, 1);
    get("/.tux/additions");
    check("the agent's GET does not clear them", events_count(), 2);
}

int main(void) {
    char dir[] = "/tmp/tux-add-XXXXXX";
    if (!mkdtemp(dir)) return 1;
    snprintf(sock_path, sizeof sock_path, "%s/s", dir);
    check("the share server starts", hv_share_start(dir, sock_path), 0);

    test_before_the_app();
    test_post();
    test_get();
    test_poll();
    check("the clipboard still answers", request("PUT", "/.tux/clipboard", "text", 4), 204);
    free(hv_share_take_clipboard());

    unlink(sock_path);
    char wallet[sizeof sock_path + 4];
    snprintf(wallet, sizeof wallet, "%s.w", sock_path); /* the wallet's socket, beside it */
    unlink(wallet);
    rmdir(dir);
    if (!failed) printf("test_additions_share: ok\n");
    return failed;
}
