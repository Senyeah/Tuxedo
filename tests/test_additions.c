/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Tuxedo Additions, engine side (host/additions.c, and the reserved entry in host/fs_server.c): the JSON check, the
   top-level "t" of an event, the event ring (order, gap, limits), the job and its wipe, the guest's and the app's
   JSON, the reserved folder entry (not counted, found or cleared by the user-folder calls, in .tux-folders with its
   kind and n) and the media's Read-only rule through FUSE requests. The job's id, ack, done, cancel and eject rules are
   here too. The HTTP side is test_additions_share. */
#include "additions.h"
#include "fs_server.h"
#include "fuse_proto.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int failed;

static void check(const char *what, long long got, long long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %lld, want %lld\n", what, got, want);
    failed = 1;
}

static void check_str(const char *what, const char *got, const char *want) {
    if (got && !strcmp(got, want)) return;
    fprintf(stderr, "FAIL %s: got \"%.300s\", want \"%.300s\"\n", what, got ? got : "(null)", want);
    failed = 1;
}

static int has(const char *hay, const char *needle) { return hay && strstr(hay, needle) != NULL; }

/* ---- the JSON check ---- */

static int valid(const char *s) { return hv_json_object_valid(s, strlen(s)); }

static void test_validator(void) {
    static const char *const good[] = {
        "{}", " {} ", "\t\r\n{\n}\n", "{\"t\":\"report\"}", "{\"a\":[1,2,3],\"b\":{\"c\":null}}",
        "{\"n\":-0}", "{\"n\":0.5e+10}", "{\"n\":-12.50E-3}", "{\"n\":1e5,\"m\":0}", "{\"a\":true,\"b\":false,\"c\":null}",
        "{\"\":1}", "{\"a\":\"\\\" \\\\ \\/ \\b \\f \\n \\r \\t\"}", "{\"a\":\"\\u00e9 \\u0000\"}",
        "{\"a\":\"\\ud83d\\ude00\"}", "{\"a\":\"caf\xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80\"}", "{\"a\":\"\xed\x9f\xbf\xee\x80\x80\xf4\x8f\xbf\xbf\"}",
        "{\"a\":1,\"a\":2}", /* duplicate names are the reader's business */
        "{\"a\":[[[[[[[1]]]]]]]}",                  /* the object and 7 arrays: 8 levels */
        "{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":1}}}}}}}}", /* 8 objects */
        "{\"a\":[ ]}", "{\"a\" : [ 1 , 2 ] , \"b\" : { }}",
    };
    for (size_t i = 0; i < sizeof good / sizeof *good; i++) {
        char what[64];
        snprintf(what, sizeof what, "valid #%zu", i);
        check(what, valid(good[i]), 1);
    }
    static const char *const bad[] = {
        "", " ", "{", "}", "{}{}", "{} x", "[]", "[{}]", "\"x\"", "1", "null", "true", "{\"a\"}", "{\"a\":}", "{\"a\":1,}",
        "{,}", "{\"a\":1 \"b\":2}", "{a:1}", "{'a':1}", "{\"a\":[1,]}", "{\"a\":[,1]}", "{\"a\":[1 2]}", "{\"a\":01}", "{\"a\":+1}",
        "{\"a\":.5}", "{\"a\":5.}", "{\"a\":1e}", "{\"a\":1e+}", "{\"a\":-}", "{\"a\":--1}", "{\"a\":0x10}", "{\"a\":NaN}", "{\"a\":Infinity}",
        "{\"a\":-Infinity}", "{\"a\":nan}", "{\"a\":inf}", "{\"a\":tru}", "{\"a\":True}", "{\"a\":nul}", "{\"a\":\"x}", "{\"a\":\"\\x\"}",
        "{\"a\":\"\\u12\"}", "{\"a\":\"\\u12G4\"}", "{\"a\":\"\\ud800\"}", "{\"a\":\"\\udc00\"}", "{\"a\":\"\\ud800\\u0041\"}",
        "{\"a\":\"\\ud800x\"}", "{\"a\":\"\\udc00\\ud800\"}", "{\"a\":\"\\'\"}",
        "{\"a\":\"\x01\"}", "{\"a\":\"\x1f\"}", "{\"a\":\"line\nbreak\"}", "{\"a\":\"tab\there\"}",
        "{\"a\":\"\xc3\"}", "{\"a\":\"\xc3(\"}", "{\"a\":\"\xc0\xaf\"}", "{\"a\":\"\xc1\xbf\"}", "{\"a\":\"\xe0\x80\xaf\"}", "{\"a\":\"\xed\xa0\x80\"}",
        "{\"a\":\"\xed\xbf\xbf\"}", "{\"a\":\"\xf0\x80\x80\x80\"}", "{\"a\":\"\xf4\x90\x80\x80\"}", "{\"a\":\"\xf5\x80\x80\x80\"}",
        "{\"a\":\"\xff\"}", "{\"a\":\"\xfe\"}", "{\"a\":\"\x80\"}", "{\"a\":\"\xe2\x82\"}", "{\"\xff\":1}", "\xef\xbb\xbf{}",
        "{\"a\":[[[[[[[[1]]]]]]]]}",                          /* 9 levels */
        "{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":1}}}}}}}}}", /* 9 objects */
        "{\"a\":[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]}",
        "{\"a\":1}\x01", "{\"a\":1}\f", "{\"a\":1}\v",
    };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        char what[64];
        snprintf(what, sizeof what, "invalid #%zu: %.30s", i, bad[i]);
        check(what, valid(bad[i]), 0);
    }
    check("DEL is not a control character in JSON", valid("{\"a\":\"\x7f\"}"), 1);
    check("a NUL after the object", hv_json_object_valid("{}\0", 3), 0);
    check("a NUL inside a string", hv_json_object_valid("{\"a\":\"x\0y\"}", 11), 0);
    check("a NUL before the object", hv_json_object_valid("\0{}", 3), 0);
    check("a length that stops inside the text", hv_json_object_valid("{\"a\":1}x", 7), 1);
    check("a length that cuts the object", hv_json_object_valid("{\"a\":1}", 6), 0);
    check("NULL", hv_json_object_valid(NULL, 0), 0);
    check("zero length", hv_json_object_valid("{}", 0), 0);
    /* Trailing bytes: anything but JSON space after the object. */
    check("trailing text", valid("{\"a\":1} garbage"), 0);
    check("trailing comma-object", valid("{\"a\":1},{}"), 0);
    check("trailing space and line end", valid("{\"a\":1} \r\n\t"), 1);
    /* Deep: a long chain must not run the stack. */
    char *deep = malloc(200000);
    memset(deep, '[', 100000);
    memcpy(deep, "{\"a\":", 5);
    memset(deep + 100000, ']', 100000);
    deep[200000 - 1] = '}';
    check("100000 levels", hv_json_object_valid(deep, 200000), 0);
    free(deep);
}

/* ---- the top-level "t" and the wipe on "done" ---- */

static const char *last_json;

static char *app_events(unsigned long since, unsigned long *seq) {
    static char *keep;
    free(keep);
    keep = hv_additions_events_json(since, seq);
    last_json = keep;
    return keep;
}

static int posted(const char *body) { return hv_additions_post(body, strlen(body)); }

/* A new machine, and the k its first event will follow: k goes on over a reset. */
static unsigned long fresh(void) {
    hv_additions_reset();
    posted("{\"t\":\"probe\"}");
    char *j = hv_additions_events_json(0, NULL);
    const char *p = strstr(j, "{\"k\":");
    unsigned long k = p ? strtoul(p + 5, NULL, 10) : 0;
    free(j);
    hv_additions_reset();
    return k;
}

static void job_put(const char *text) { check("job set", hv_additions_job_set(text), 0); }

static int job_in_memory(void) { return has(hv_additions_test_job_buffer(NULL), "SECRET"); }

static int job_buffer_zero(void) {
    size_t n;
    const unsigned char *b = (const unsigned char *)hv_additions_test_job_buffer(&n);
    for (size_t i = 0; i < n; i++)
        if (b[i]) return 0;
    return 1;
}

/* The guest's view now, in a static buffer. */
static const char *guest_now(void) {
    static char b[HV_ADDITIONS_JOB_MAX + 1024];
    char *g = hv_additions_guest_json(NULL);
    snprintf(b, sizeof b, "%s", g ? g : "(null)");
    free(g);
    return b;
}

static void test_done_scan(void) {
    hv_additions_reset();
    static const char *const job = "{\"id\":\"j-1\",\"steps\":[{\"action\":\"user.setup\",\"name\":\"tux\",\"password\":\"SECRET\"}]}";
    struct { const char *event; int wipes; const char *what; } t[] = {
        {"{\"t\":\"done\",\"job\":\"j-1\",\"ok\":true,\"reboot\":false,\"info\":{}}", 1, "a done event"},
        {"{\"job\":\"j-1\",\"t\":\"done\"}", 1, "t after other members"},
        {" \n{ \"t\" : \"done\", \"job\" : \"j-1\" }\n ", 1, "spaces and line ends"},
        {"{\"t\":\"d\\u006fne\",\"job\":\"j-1\"}", 1, "done written with an escape"},
        {"{\"\\u0074\":\"done\",\"job\":\"j-1\"}", 1, "t written with an escape"},
        {"{\"t\":\"done\",\"job\":\"j\\u002d1\"}", 1, "the job id written with an escape"},
        {"{\"t\":\"done\",\"\\u006aob\":\"j-1\"}", 1, "the job key written with an escape"},
        {"{\"t\":\"done\",\"job\":\"j-2\"}", 0, "done for another job"},
        {"{\"t\":\"done\",\"job\":\"j-1x\"}", 0, "done for a longer id"},
        {"{\"t\":\"done\",\"job\":\"j-\"}", 0, "done for a shorter id"},
        {"{\"t\":\"done\",\"job\":\"J-1\"}", 0, "done for an id in another case"},
        {"{\"t\":\"done\"}", 0, "done with no job"},
        {"{\"t\":\"done\",\"job\":1}", 0, "done with a job that is not a string"},
        {"{\"t\":\"done\",\"job\":null}", 0, "done with a null job"},
        {"{\"t\":\"done\",\"job\":\"\"}", 0, "done with an empty job"},
        {"{\"t\":\"done\",\"x\":{\"job\":\"j-1\"}}", 0, "a nested job id"},
        {"{\"t\":\"done\",\"job\":\"j-1\",\"job\":\"j-2\"}", 0, "the last job wins: another"},
        {"{\"t\":\"done\",\"job\":\"j-2\",\"job\":\"j-1\"}", 1, "the last job wins: the job"},
        {"{\"t\":\"step\",\"job\":\"j-1\",\"msg\":\"done\"}", 0, "done in another member"},
        {"{\"t\":\"step\",\"info\":{\"t\":\"done\"}}", 0, "a nested t that says done"},
        {"{\"t\":\"log\",\"text\":\"\\\"t\\\":\\\"done\\\"\"}", 0, "t and done inside a string"},
        {"{\"t\":\"log\",\"text\":\"{\\\"t\\\":\\\"done\\\"}\",\"a\":[{\"t\":\"done\"}]}", 0, "t inside a string and an array"},
        {"{\"t\":\"done\\u0000x\",\"job\":\"j-1\"}", 0, "done then a NUL"},
        {"{\"t\":\"donee\",\"job\":\"j-1\"}", 0, "donee"},
        {"{\"t\":\"Done\",\"job\":\"j-1\"}", 0, "Done"},
        {"{\"t\":\"done \",\"job\":\"j-1\"}", 0, "done with a space"},
        {"{\"t\":\"report\",\"agent\":\"1\",\"caps\":{\"t\":\"done\",\"job\":\"j-1\"}}", 0, "report with a nested done"},
        {"{\"t\":\"done\",\"job\":\"j-1\",\"t\":\"step\"}", 0, "the last t wins: step"},
        {"{\"t\":\"step\",\"job\":\"j-1\",\"t\":\"done\"}", 1, "the last t wins: done"},
        {"{\"t\":\"ack\",\"job\":\"j-2\"}", 0, "an ack for another job"},
        {"{\"t\":\"step\",\"job\":\"j-1\",\"i\":0,\"status\":\"ok\",\"msg\":\"\"}", 0, "a step for the job"},
        {"{\"t\":\"log\",\"job\":\"j-1\",\"text\":\"\"}", 0, "a log for the job"},
    };
    for (size_t i = 0; i < sizeof t / sizeof *t; i++) {
        job_put(job);
        check("the job is in the host's memory", job_in_memory(), 1);
        check(t[i].what, posted(t[i].event), 0);
        check(t[i].what, job_in_memory() ? 0 : 1, t[i].wipes);
        check(t[i].what, hv_additions_test_job_buffer(NULL)[0] != 0 ? 0 : 1, t[i].wipes);
        if (t[i].wipes) check(t[i].what, job_buffer_zero(), 1);
        char *g = hv_additions_guest_json(NULL);
        check(t[i].what, has(g, "\"job\":null"), t[i].wipes);
        free(g);
        hv_additions_job_clear();
    }
}

static int count_events(const char *json) {
    int n = 0;
    for (const char *p = json; (p = strstr(p, "{\"k\":")); p++) n++;
    return n;
}

static unsigned long first_k(const char *json) {
    const char *p = strstr(json, "{\"k\":");
    return p ? strtoul(p + 5, NULL, 10) : 0;
}

static unsigned long last_k(const char *json) {
    const char *p = NULL, *q = json;
    while ((q = strstr(q, "{\"k\":"))) p = q++;
    return p ? strtoul(p + 5, NULL, 10) : 0;
}

static void test_post_refused(void) {
    hv_additions_reset();
    unsigned long before = hv_additions_seq();
    static const char *const bad[] = {
        "", "{}", "{\"x\":1}", "{\"t\":1}", "{\"t\":null}", "{\"t\":[\"done\"]}", "{\"t\":{\"t\":\"x\"}}", "{\"t\":\"a\",\"t\":3}",
        "[{\"t\":\"x\"}]", "{\"t\":\"x\"} x", "{\"t\":\"x\"", "{\"t\":\"\\ud800\"}", "{\"t\":\"x\"}{\"t\":\"y\"}", "{\"T\":\"x\"}",
        "{\"tt\":\"x\"}", "{\"info\":{\"t\":\"x\"}}", "NaN",
    };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        char what[48];
        snprintf(what, sizeof what, "refused #%zu", i);
        errno = 0;
        check(what, posted(bad[i]), -1);
        check(what, errno, EINVAL);
    }
    check("NULL body", hv_additions_post(NULL, 0), -1);
    check("nothing was kept", hv_additions_seq(), before);
    char *j = app_events(0, NULL);
    check("no events", has(j, "\"events\":[]"), 1);

    /* The size limit is on the bytes, before anything is read. */
    size_t big = HV_ADDITIONS_EVENT_MAX + 1;
    char *b = malloc(big + 1);
    memset(b, ' ', big);
    memcpy(b, "{\"t\":\"x\"}", 9);
    b[big] = 0;
    errno = 0;
    check("65537 bytes", hv_additions_post(b, big), -1);
    check("65537 bytes: E2BIG", errno, E2BIG);
    check("exactly 65536 bytes", hv_additions_post(b, HV_ADDITIONS_EVENT_MAX), 0);
    free(b);
    check("only that one was kept", count_events(app_events(0, NULL)), 1);
}

/* ---- the ring ---- */

static void test_ring(void) {
    unsigned long k0 = fresh(), s0 = hv_additions_seq(), seq = 0;
    char *j = app_events(0, &seq);
    check_str("empty ring", strstr(j, "\"seq\":") ? strstr(j, "\"gap\":") : "", "\"gap\":false,\"events\":[]}");
    check("a new machine: not inserted", has(j, "{\"inserted\":false,\"n\":0,"), 1);

    check("event 1", posted("{\"t\":\"report\",\"n\":1,\"agent\":\"1.0\",\"protocol\":1,\"caps\":{}}"), 0);
    check("event 2", posted("{\"t\":\"step\",\"job\":\"j\",\"i\":0,\"status\":\"running\",\"msg\":\"go\"}"), 0);
    check("event 3 with a line end", posted("{\"t\":\"log\",\n\"job\":\"j\",\n\"text\":\"a\\nb\"}\n"), 0);
    j = app_events(0, &seq);
    check("three events", count_events(j), 3);
    check("k starts after the last one of the old machine", first_k(j), k0 + 1);
    check("k up by one", last_k(j), k0 + 3);
    check("no gap", has(j, "\"gap\":false"), 1);
    char want[160];
    snprintf(want, sizeof want, "{\"k\":%lu,\"e\":{\"t\":\"log\", \"job\":\"j\", \"text\":\"a\\nb\"}}", k0 + 3);
    check("the text is as it came, on one line", has(j, want), 1);
    check("whole JSON is one line", strchr(j, '\n') == NULL, 1);
    check("the answer is a valid object", hv_json_object_valid(j, strlen(j)), 1);
    check("order", strstr(j, "\"t\":\"report\"") < strstr(j, "\"t\":\"step\"") && strstr(j, "\"t\":\"step\"") < strstr(j, "\"t\":\"log\""), 1);
    j = app_events(k0 + 1, &seq);
    check("since the first: the other two", count_events(j) == 2 && first_k(j) == k0 + 2, 1);
    j = app_events(k0 + 3, &seq);
    check("since the last: none, no gap", count_events(j) == 0 && has(j, "\"gap\":false"), 1);
    j = app_events(k0 + 4, &seq);
    check("since a k that is not there yet: all of them, and a gap", count_events(j) == 3 && has(j, "\"gap\":true"), 1);
    j = app_events(ULONG_MAX, &seq);
    check("since the largest: a gap", has(j, "\"gap\":true"), 1);

    /* The count limit: 512 kept. */
    for (int i = 4; i <= 600; i++) { /* k0 + 600 in all */
        char e[96];
        snprintf(e, sizeof e, "{\"t\":\"log\",\"job\":\"j\",\"text\":\"%d\"}", i);
        if (posted(e) != 0) check("post", -1, 0);
    }
    j = app_events(0, &seq);
    check("512 kept", count_events(j), HV_ADDITIONS_EVENTS_KEPT);
    check("the oldest kept", first_k(j), k0 + 600 - 512 + 1);
    check("the newest", last_k(j), k0 + 600);
    check("since 0 sees events were dropped", has(j, "\"gap\":true"), 1);
    j = app_events(k0 + 88, &seq);
    check("since the last one dropped: nothing missed", has(j, "\"gap\":false") && count_events(j) == 512, 1);
    j = app_events(k0 + 87, &seq);
    check("since the one before: one is gone, a gap", has(j, "\"gap\":true") && count_events(j) == 512, 1);
    j = app_events(k0 + 595, &seq);
    check("near the end: five events", count_events(j) == 5 && first_k(j) == k0 + 596 && has(j, "\"gap\":false"), 1);
    check("seq counts every event", seq, s0 + 600);
    j = app_events(0, &seq);
    check("a view from an older machine (k below the base) sees the drop too", has(j, "\"gap\":true"), 1);

    /* The byte limit: 512 KB of text in the ring. */
    k0 = fresh();
    size_t each = 60000;
    char *b = malloc(each + 1);
    for (int i = 0; i < 20; i++) {
        memset(b, 'x', each);
        int n = snprintf(b, 64, "{\"t\":\"log\",\"text\":\""); /* 19 bytes */
        b[n] = 'x';
        memcpy(b + each - 2, "\"}", 2);
        b[each] = 0;
        check("a 60000-byte event", hv_additions_post(b, each), 0);
    }
    free(b);
    j = app_events(0, &seq);
    int kept = count_events(j);
    check("the byte limit keeps floor(524288 / 60000) = 8", kept, 8);
    check("the newest k", last_k(j), k0 + 20);
    check("the oldest k", first_k(j), k0 + 13);
    check("a gap", has(j, "\"gap\":true"), 1);
    check("the output is at most the bytes plus the frames", strlen(j) < HV_ADDITIONS_EVENTS_BYTES + 8 * 40 + 200, 1);
    /* One event of 64 KB always fits. */
    k0 = fresh();
    char *m = malloc(HV_ADDITIONS_EVENT_MAX + 1);
    memset(m, ' ', HV_ADDITIONS_EVENT_MAX);
    memcpy(m, "{\"t\":\"log\"}", 11);
    for (int i = 0; i < 9; i++) check("a 65536-byte event", hv_additions_post(m, HV_ADDITIONS_EVENT_MAX), 0);
    free(m);
    j = app_events(0, &seq);
    check("a 64 KB event is trimmed, so all nine fit", count_events(j), 9);
    char *s = malloc(HV_ADDITIONS_EVENT_MAX + 1);
    memset(s, 'x', HV_ADDITIONS_EVENT_MAX);
    memcpy(s, "{\"t\":\"log\",\"text\":\"", 19);
    memcpy(s + HV_ADDITIONS_EVENT_MAX - 2, "\"}", 2);
    for (int i = 0; i < 9; i++) check("a full 65536-byte event", hv_additions_post(s, HV_ADDITIONS_EVENT_MAX), 0);
    free(s);
    j = app_events(0, &seq);
    check("full events: eight of nine remain", count_events(j), 8);
    check("full events: newest k", last_k(j), k0 + 18);
}

/* ---- the app starts late; a new machine starts empty ---- */

static void test_late_view(void) {
    unsigned long k0 = fresh(), before = hv_additions_seq();
    posted("{\"t\":\"report\",\"n\":0,\"agent\":\"boot\",\"protocol\":1,\"caps\":{\"account\":{\"configured\":false}}}");
    posted("{\"t\":\"step\",\"job\":\"j\",\"i\":0,\"status\":\"ok\",\"msg\":\"m\"}");
    /* The session view opens: it starts at 0 and only reads. */
    unsigned long seq = 0;
    char *j = app_events(0, &seq);
    char want[96];
    snprintf(want, sizeof want, "{\"k\":%lu,\"e\":{\"t\":\"report\",\"n\":0,\"agent\":\"boot\"", k0 + 1);
    check("the boot report is there", has(j, want), 1);
    check("and the step", count_events(j), 2);
    check("the count moved by the events", seq, before + 2);
    check("the view's wait from 0 answers at once", hv_additions_wait(0, 5000), seq);
    char *g = hv_additions_guest_json(NULL);
    free(g);
    check("looking again changes nothing", has(app_events(0, NULL), "\"agent\":\"boot\""), 1);
    check("the count is the same", hv_additions_seq(), seq);
    /* Only a new machine clears. */
    hv_additions_reset();
    j = app_events(0, &seq);
    check("a new machine: no events", count_events(j), 0);
    check("a new machine: no gap for a fresh view", has(j, "\"gap\":false"), 1);
    check("the count only goes up", seq > before + 2, 1);
    posted("{\"t\":\"report\"}");
    j = app_events(0, &seq);
    check("k goes on in a new machine", first_k(j), k0 + 3);
    check("a fresh view of a new machine has no gap", has(j, "\"gap\":false"), 1);
    j = app_events(k0 + 2, &seq);
    check("a view that had the old machine's last k sees the new report", count_events(j) == 1 && first_k(j) == k0 + 3 && has(j, "\"gap\":false"), 1);
    j = app_events(k0 + 1, &seq);
    check("a view from the old machine sees it too", count_events(j) == 1 && has(j, "\"gap\":false"), 1);
    j = app_events(k0 + 3, &seq);
    check("a view that is up to date", count_events(j) == 0, 1);
}

typedef struct Waiter {
    unsigned long since, got;
    int ms;
    double took;
} Waiter;

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000 + (double)t.tv_nsec / 1e6;
}

static void *waiter(void *arg) {
    Waiter *w = arg;
    double t0 = now_ms();
    w->got = hv_additions_wait(w->since, w->ms);
    w->took = now_ms() - t0;
    return NULL;
}

static void test_wait(void) {
    hv_additions_reset();
    unsigned long seq = hv_additions_seq();
    double t0 = now_ms();
    check("wait: nothing new waits the time", hv_additions_wait(seq, 150) == seq && now_ms() - t0 >= 140, 1);
    check("wait: 0 ms is at once", hv_additions_wait(seq, 0), seq);
    check("wait: a negative time is at once", hv_additions_wait(seq, -5), seq);
    t0 = now_ms();
    check("wait: a stale count (greater) answers at once", hv_additions_wait(seq + 1000, 5000) == seq && now_ms() - t0 < 1000, 1);
    t0 = now_ms();
    check("wait: an older count answers at once", hv_additions_wait(seq - 1, 5000) == seq && now_ms() - t0 < 1000, 1);

    Waiter w = {seq, 0, 5000, 0};
    pthread_t t;
    pthread_create(&t, NULL, waiter, &w);
    usleep(100 * 1000);
    posted("{\"t\":\"report\"}");
    pthread_join(t, NULL);
    check("wait: an event wakes it", w.got, seq + 1);
    check("wait: quickly", w.took < 2000, 1);
    seq = w.got;

    w = (Waiter){seq, 0, 5000, 0};
    pthread_create(&t, NULL, waiter, &w);
    usleep(100 * 1000);
    job_put("{\"id\":\"j\"}");
    pthread_join(t, NULL);
    check("wait: a job wakes it", w.got, seq + 1);
    seq = w.got;

    w = (Waiter){seq, 0, 5000, 0};
    pthread_create(&t, NULL, waiter, &w);
    usleep(100 * 1000);
    hv_additions_job_cancel();
    pthread_join(t, NULL);
    check("wait: a cancel wakes it", w.got, seq + 1);
    seq = w.got;

    w = (Waiter){seq, 0, 5000, 0};
    pthread_create(&t, NULL, waiter, &w);
    usleep(100 * 1000);
    hv_additions_reset();
    pthread_join(t, NULL);
    check("wait: a new machine wakes it", w.got, seq + 1);
}

/* ---- the job ---- */

static void test_job(void) {
    hv_additions_reset();
    check("job buffer: zero at the start", job_buffer_zero(), 1);
    unsigned long seq = 0;
    char *g = hv_additions_guest_json(&seq);
    check_str("guest json: no media, no job", g, "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}");
    check("guest json is valid", hv_json_object_valid(g, strlen(g)), 1);
    free(g);

    const char *job1 = "{\"id\":\"j-1\",\"steps\":[{\"action\":\"user.setup\",\"name\":\"tux\",\"password\":\"SECRET-ONE\"}]}";
    job_put(job1);
    g = hv_additions_guest_json(&seq);
    char want[512];
    snprintf(want, sizeof want, "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":%s,\"taken\":null}", job1);
    check_str("guest json: the job", g, want);
    check("guest json with a job is valid", hv_json_object_valid(g, strlen(g)), 1);
    free(g);
    check("the job is in the buffer", has(hv_additions_test_job_buffer(NULL), "SECRET-ONE"), 1);

    /* Replaced: the old bytes are gone from the whole buffer, also past the new end. */
    job_put("{\"id\":\"j-2\"}");
    check("replaced: no trace of the old job", has(hv_additions_test_job_buffer(NULL), "SECRET-ONE") == 0, 1);
    {
        size_t n;
        const char *b = hv_additions_test_job_buffer(&n);
        size_t tail_zero = 1;
        for (size_t i = strlen("{\"id\":\"j-2\"}"); i < n; i++)
            if (b[i]) tail_zero = 0;
        check("replaced: the rest of the buffer is zero", (long long)tail_zero, 1);
    }

    /* Cleared. */
    job_put(job1);
    unsigned long s0 = hv_additions_seq();
    hv_additions_job_clear();
    check("cleared: zero", job_buffer_zero(), 1);
    check("cleared: it is news", hv_additions_seq(), s0 + 1);
    g = hv_additions_guest_json(NULL);
    check("cleared: null in the guest's view", has(g, "\"job\":null"), 1);
    free(g);
    hv_additions_job_clear();
    check("cleared twice: no news", hv_additions_seq(), s0 + 1);

    /* Cancelled: the flag, and the job is wiped (it may hold a password). */
    job_put(job1);
    check("cancel", hv_additions_job_cancel(), 0);
    check("cancelled: zero", job_buffer_zero(), 1);
    g = hv_additions_guest_json(NULL);
    check_str("cancelled: the flag, the id and no job", g, "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-1\",\"job\":null,\"taken\":null}");
    free(g);
    job_put("{\"id\":\"j-3\"}");
    g = hv_additions_guest_json(NULL);
    check_str("a new job with another id keeps the cancel", g, "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-1\",\"job\":{\"id\":\"j-3\"},\"taken\":null}");
    free(g);
    hv_additions_job_clear();
    job_put("{\"id\":\"j-3\"}");

    /* Refused jobs keep the old one. */
    errno = 0;
    check("a job that is not JSON", hv_additions_job_set("not json"), -1);
    check("a job that is not JSON: EINVAL", errno, EINVAL);
    errno = 0;
    check("a job that is an array", hv_additions_job_set("[]"), -1);
    check("a job that is an array: EINVAL", errno, EINVAL);
    check("an empty job text", hv_additions_job_set(""), -1);
    check("NULL", hv_additions_job_set(NULL), -1);
    check("bad UTF-8", hv_additions_job_set("{\"a\":\"\xff\"}"), -1);
    check("trailing bytes", hv_additions_job_set("{\"id\":\"x\"} y"), -1);
    check("too deep", hv_additions_job_set("{\"a\":[[[[[[[[1]]]]]]]]}"), -1);
    g = hv_additions_guest_json(NULL);
    check("refused jobs change nothing", has(g, "\"id\":\"j-3\""), 1);
    free(g);

    /* The limit is on the text as given; the stored job has no space around it. */
    size_t cap = HV_ADDITIONS_JOB_MAX;
    char *big = malloc(cap + 64);
    memset(big, 'x', cap + 32);
    big[cap + 32] = 0;
    const char *lead = "{\"id\":\"big\",\"pad\":\"";
    memcpy(big, lead, strlen(lead));
    memcpy(big + cap + 1 - 2, "\"}", 2); /* 16385 bytes */
    big[cap + 1] = 0;
    errno = 0;
    check("a job of 16385 bytes", hv_additions_job_set(big), -1);
    check("a job of 16385 bytes: E2BIG", errno, E2BIG);
    memcpy(big + cap - 2, "\"}", 2);
    big[cap] = 0;
    check("exactly 16384 bytes", hv_additions_job_set(big), 0);
    g = hv_additions_guest_json(NULL);
    check("a job of the limit comes back whole", g && strstr(g, big) != NULL, 1);
    free(g);
    hv_additions_job_clear();
    memset(big, ' ', cap);
    memcpy(big + 5, "{\"id\":\"sp\"}", 11);
    big[cap] = 0;
    check("16384 bytes with spaces around", hv_additions_job_set(big), 0);
    g = hv_additions_guest_json(NULL);
    check_str("spaces and line ends around a job are not kept", g, "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":{\"id\":\"sp\"},\"taken\":null}");
    free(g);
    free(big);
    check("a job with a file's end of line", hv_additions_job_set("\n{\"id\":\"nl\"}\r\n"), 0);
    g = hv_additions_guest_json(NULL);
    check("the end of line is gone", has(g, "\"job\":{\"id\":\"nl\"},"), 1);
    free(g);
    hv_additions_job_clear();

    /* Wipe helper. */
    char x[16] = "secret";
    hv_additions_wipe(x, sizeof x);
    check("wipe", x[0] == 0 && x[5] == 0 && x[15] == 0, 1);
}

/* ---- the job's id, ack, done, cancel and eject ---- */

static void test_job_id(void) {
    hv_additions_reset();
    job_put("{\"id\":\"keep\",\"password\":\"SECRET\"}");
    char id64[80], id65[80], text[400];
    memset(id64, 'a', 64), id64[64] = 0;
    memset(id65, 'a', 65), id65[65] = 0;
    struct { const char *job; const char *what; } bad[] = {
        {"{\"steps\":[]}", "no id"},
        {"{}", "an empty object"},
        {"{\"id\":1}", "a number id"},
        {"{\"id\":null}", "a null id"},
        {"{\"id\":true}", "a true id"},
        {"{\"id\":[\"a\"]}", "an array id"},
        {"{\"id\":{\"a\":1}}", "an object id"},
        {"{\"id\":\"\"}", "an empty id"},
        {"{\"id\":\"a b\"}", "a space in the id"},
        {"{\"id\":\"a/b\"}", "a slash in the id"},
        {"{\"id\":\"a.b\"}", "a dot in the id"},
        {"{\"id\":\"a\\\"b\"}", "a quote in the id"},
        {"{\"id\":\"a\\nb\"}", "a line end in the id"},
        {"{\"id\":\"a\\u0000b\"}", "a NUL in the id"},
        {"{\"id\":\"\\u00e9\"}", "a letter with an accent"},
        {"{\"id\":\"\xc3\xa9\"}", "a letter with an accent, raw"},
        {"{\"id\":\"\\ud83d\\ude00\"}", "an emoji"},
        {"{\"x\":{\"id\":\"nested\"}}", "an id that is nested"},
        {"{\"steps\":[{\"id\":\"inner\"}]}", "an id inside an array"},
        {"{\"ID\":\"upper\"}", "the key in upper case"},
        {"{\"id \":\"space\"}", "the key with a space"},
        {"{\"id\":\"ok\",\"id\":1}", "the last id wins: a number"},
        {"{\"id\":\"ok\",\"id\":\"bad id\"}", "the last id wins: a bad one"},
    };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        errno = 0;
        check(bad[i].what, hv_additions_job_set(bad[i].job), -1);
        check(bad[i].what, errno, EINVAL);
    }
    snprintf(text, sizeof text, "{\"id\":\"%s\"}", id65);
    errno = 0;
    check("an id of 65 characters", hv_additions_job_set(text), -1);
    check("an id of 65 characters: EINVAL", errno, EINVAL);
    check("refused jobs change nothing", has(guest_now(), "\"job\":{\"id\":\"keep\",\"password\":\"SECRET\"}"), 1);
    check("refused jobs keep the old bytes", job_in_memory(), 1);

    snprintf(text, sizeof text, "{\"id\":\"%s\"}", id64);
    check("an id of 64 characters", hv_additions_job_set(text), 0);
    check("the 64-character id is the stored one", has(guest_now(), id64), 1);
    check("the old job is wiped by the new one", job_in_memory(), 0);
    check("an id of A-Z a-z 0-9 _ -", hv_additions_job_set("{\"id\":\"Az09_-\"}"), 0);
    check("one character", hv_additions_job_set("{\"id\":\"_\"}"), 0);
    check("the id written with escapes", hv_additions_job_set("{\"id\":\"j\\u002d\\u0041\"}"), 0);
    check("the escaped id is decoded", has(guest_now(), "\"job\":{\"id\":\"j\\u002d\\u0041\"}"), 1);
    check("the key written with an escape", hv_additions_job_set("{\"\\u0069d\":\"esc\"}"), 0);
    check("the last id wins", hv_additions_job_set("{\"id\":\"bad id\",\"id\":\"last\"}"), 0);
    check("id and other members in any order", hv_additions_job_set("{\"steps\":[{\"id\":\"inner\"}],\"id\":\"outer\"}"), 0);

    /* The stored id is what a done and an ack must name; a decoded id is compared, not the raw text. */
    hv_additions_job_set("{\"id\":\"j-A\",\"password\":\"SECRET\"}");
    posted("{\"t\":\"ack\",\"job\":\"j\\u002dA\"}");
    check("an ack with the escaped id takes the job", job_buffer_zero(), 1);
    hv_additions_job_clear();
}

static void test_ack(void) {
    hv_additions_reset();
    const char *a = "{\"id\":\"j-A\",\"steps\":[{\"action\":\"user.setup\",\"name\":\"tux\",\"password\":\"SECRET\"}]}";
    job_put(a);
    check("ack: the job is in memory", job_in_memory(), 1);
    check("ack: the guest sees it, taken null", has(guest_now(), "\"job\":{\"id\":\"j-A\"") && has(guest_now(), "\"taken\":null}"), 1);

    /* An ack for another id does nothing but is an event. */
    unsigned long k0 = fresh();
    hv_additions_reset();
    job_put(a);
    check("ack for another id", posted("{\"t\":\"ack\",\"job\":\"j-B\"}"), 0);
    check("a forged ack: the job stays in memory", job_in_memory(), 1);
    check("a forged ack: still served, nothing taken", has(guest_now(), "\"job\":{\"id\":\"j-A\"") && has(guest_now(), "\"taken\":null}"), 1);
    check("ack with no job", posted("{\"t\":\"ack\"}"), 0);
    check("ack with a number job", posted("{\"t\":\"ack\",\"job\":1}"), 0);
    check("ack with an empty job", posted("{\"t\":\"ack\",\"job\":\"\"}"), 0);
    check("ack with a longer id", posted("{\"t\":\"ack\",\"job\":\"j-AA\"}"), 0);
    check("ack with a nested job id", posted("{\"t\":\"ack\",\"x\":{\"job\":\"j-A\"}}"), 0);
    check("ack in a step", posted("{\"t\":\"step\",\"job\":\"j-A\",\"i\":0,\"status\":\"running\",\"msg\":\"ack\"}"), 0);
    check("odd acks change nothing", job_in_memory() && has(guest_now(), "\"taken\":null}"), 1);
    char *ev = app_events(0, NULL);
    check("the odd acks and the step are events", count_events(ev), 7);
    check("the first event is the forged ack", first_k(ev), k0 + 1);

    /* The real ack. */
    unsigned long s0 = hv_additions_seq();
    check("ack for the job", posted("{\"t\":\"ack\",\"job\":\"j-A\"}"), 0);
    check("ack: it is news", hv_additions_seq(), s0 + 1);
    check("ack wipes the job bytes", job_buffer_zero(), 1);
    check_str("ack: the job is null and taken is set", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":\"j-A\"}");
    check_str("ack: a second GET is the same", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":\"j-A\"}");
    ev = app_events(0, NULL);
    check("the ack stays in the ring for the app", has(ev, "{\"t\":\"ack\",\"job\":\"j-A\"}"), 1);
    check("the ack is the last event", has(strstr(ev, "{\"t\":\"ack\",\"job\":\"j-A\"}"), "]}") && !strstr(strstr(ev, "{\"t\":\"ack\",\"job\":\"j-A\"}") + 1, "\"k\":"), 1);

    /* A second ack for it has no job to take and changes nothing. */
    check("ack again", posted("{\"t\":\"ack\",\"job\":\"j-A\"}"), 0);
    check("ack again: still taken", has(guest_now(), "\"taken\":\"j-A\"}"), 1);

    /* Steps and logs do not touch the taken id. */
    posted("{\"t\":\"step\",\"job\":\"j-A\",\"i\":0,\"status\":\"ok\",\"msg\":\"\"}");
    posted("{\"t\":\"log\",\"job\":\"j-A\",\"text\":\"x\"}");
    check("steps and logs: still taken", has(guest_now(), "\"taken\":\"j-A\"}"), 1);

    /* A done for another id changes nothing; for the taken id it forgets it. */
    posted("{\"t\":\"done\",\"job\":\"j-Z\",\"ok\":true}");
    check("a done for another id: still taken", has(guest_now(), "\"taken\":\"j-A\"}"), 1);
    posted("{\"t\":\"done\",\"ok\":true}");
    check("a done with no id: still taken", has(guest_now(), "\"taken\":\"j-A\"}"), 1);
    posted("{\"t\":\"done\",\"job\":\"j-A\",\"ok\":true,\"reboot\":false,\"info\":{}}");
    check_str("done: taken is forgotten", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}");

    /* The next job starts clean. */
    job_put("{\"id\":\"j-B\",\"password\":\"SECRET\"}");
    check("the next job: served, nothing taken", has(guest_now(), "\"job\":{\"id\":\"j-B\"") && has(guest_now(), "\"taken\":null}"), 1);
    posted("{\"t\":\"ack\",\"job\":\"j-B\"}");
    check("the next job: taken", job_buffer_zero() && has(guest_now(), "\"taken\":\"j-B\"}"), 1);

    /* A job is replaced before the ack: the ack for the old id takes nothing of the new one. */
    hv_additions_reset();
    job_put("{\"id\":\"j-1\",\"password\":\"SECRET\"}");
    job_put("{\"id\":\"j-2\",\"password\":\"SECRET\"}");
    posted("{\"t\":\"ack\",\"job\":\"j-1\"}");
    check("a late ack for a replaced job: j-2 stays", job_in_memory() && has(guest_now(), "\"job\":{\"id\":\"j-2\"") && has(guest_now(), "\"taken\":null}"), 1);
}

static void test_stale_done(void) {
    /* Job A runs (taken), the app cancels it and sets job B; A's done comes late. */
    hv_additions_reset();
    job_put("{\"id\":\"j-A\",\"password\":\"SECRET-A\"}");
    posted("{\"t\":\"ack\",\"job\":\"j-A\"}");
    check("A: taken", has(guest_now(), "\"taken\":\"j-A\"}") && job_buffer_zero(), 1);
    check("cancel A", hv_additions_job_cancel(), 0);
    check_str("cancel: cancel_job is A, A stays taken", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-A\",\"job\":null,\"taken\":\"j-A\"}");
    job_put("{\"id\":\"j-B\",\"password\":\"SECRET-B\"}");
    const char *g = guest_now();
    check("B is set: cancel_job is still A", has(g, "\"cancel\":true,\"cancel_job\":\"j-A\",\"job\":{\"id\":\"j-B\""), 1);
    check("B is set: A is still the taken one", has(g, "\"taken\":\"j-A\"}"), 1);
    check("A's done arrives", posted("{\"t\":\"done\",\"job\":\"j-A\",\"ok\":false,\"reboot\":false,\"info\":{}}"), 0);
    check("the stale done(A) does not wipe B", has(hv_additions_test_job_buffer(NULL), "SECRET-B"), 1);
    g = guest_now();
    check("B is still served", has(g, "\"job\":{\"id\":\"j-B\",\"password\":\"SECRET-B\"}"), 1);
    check("A is no longer taken", has(g, "\"taken\":null}"), 1);
    check("cancel_job stays A, so B is not cancelled by it", has(g, "\"cancel_job\":\"j-A\""), 1);
    /* B runs. */
    posted("{\"t\":\"ack\",\"job\":\"j-B\"}");
    check("B is taken and its bytes are gone", job_buffer_zero() && has(guest_now(), "\"taken\":\"j-B\"}"), 1);
    check("cancel_job is still A while B runs", has(guest_now(), "\"cancel_job\":\"j-A\""), 1);
    posted("{\"t\":\"done\",\"job\":\"j-A\",\"ok\":true}");
    check("a second stale done(A) does not forget B", has(guest_now(), "\"taken\":\"j-B\"}"), 1);
    posted("{\"t\":\"done\",\"job\":\"j-B\",\"ok\":true}");
    check("done(B): nothing taken", has(guest_now(), "\"taken\":null}"), 1);

    /* A stale done while B is only stored. */
    hv_additions_reset();
    job_put("{\"id\":\"j-B\",\"password\":\"SECRET-B\"}");
    posted("{\"t\":\"done\",\"job\":\"j-A\",\"ok\":true}");
    check("done(A) with only B stored: B stays", job_in_memory() && has(guest_now(), "\"job\":{\"id\":\"j-B\""), 1);
    posted("{\"t\":\"done\",\"job\":\"j-B\",\"ok\":true}");
    check("done(B) with B stored: wiped", job_buffer_zero() && has(guest_now(), "\"job\":null"), 1);

    /* The same id taken and stored again (an id that was used twice): one done clears both. */
    hv_additions_reset();
    job_put("{\"id\":\"j-R\",\"password\":\"SECRET\"}");
    posted("{\"t\":\"ack\",\"job\":\"j-R\"}");
    job_put("{\"id\":\"j-R\",\"password\":\"SECRET\"}");
    check("same id twice: stored and taken", job_in_memory() && has(guest_now(), "\"taken\":\"j-R\"}"), 1);
    posted("{\"t\":\"done\",\"job\":\"j-R\"}");
    check("same id twice: done clears both", job_buffer_zero() && has(guest_now(), "\"taken\":null}") && has(guest_now(), "\"job\":null"), 1);
}

static void test_cancel_rules(void) {
    hv_additions_reset();
    unsigned long s0 = hv_additions_seq();
    check("cancel with no job", hv_additions_job_cancel(), 0);
    check("cancel with no job: no change, no news", hv_additions_seq(), s0);
    check_str("cancel with no job: no cancel", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}");

    /* A job that was not taken: cancelled and wiped. Then job B runs. */
    job_put("{\"id\":\"j-A\",\"password\":\"SECRET\"}");
    s0 = hv_additions_seq();
    hv_additions_job_cancel();
    check("cancel of a stored job: news", hv_additions_seq(), s0 + 1);
    check("cancel of a stored job: wiped", job_buffer_zero(), 1);
    check_str("cancel of a stored job: cancel_job A", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-A\",\"job\":null,\"taken\":null}");
    job_put("{\"id\":\"j-B\",\"password\":\"SECRET\"}");
    check_str("then job B: cancel_job is A, B is served", guest_now(),
              "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-A\",\"job\":{\"id\":\"j-B\",\"password\":\"SECRET\"},\"taken\":null}");
    posted("{\"t\":\"ack\",\"job\":\"j-B\"}");
    check("B runs: taken B, cancel_job A", has(guest_now(), "\"cancel_job\":\"j-A\",\"job\":null,\"taken\":\"j-B\"}"), 1);
    check("B runs: the bytes are gone", job_buffer_zero(), 1);

    /* Cancel B (taken): cancel_job B, nothing to wipe, taken stays. */
    s0 = hv_additions_seq();
    hv_additions_job_cancel();
    check("cancel of a taken job: news", hv_additions_seq(), s0 + 1);
    check_str("cancel of a taken job", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-B\",\"job\":null,\"taken\":\"j-B\"}");

    /* With a stored job and a taken one, cancel names the stored one and wipes it. */
    job_put("{\"id\":\"j-C\",\"password\":\"SECRET\"}");
    hv_additions_job_cancel();
    check("cancel with C stored and B taken: C is cancelled and wiped", job_buffer_zero() && has(guest_now(), "\"cancel_job\":\"j-C\"") && has(guest_now(), "\"taken\":\"j-B\"}"), 1);

    /* The same id set again is a new wish: the old cancel does not hit it. */
    job_put("{\"id\":\"j-C\",\"password\":\"SECRET\"}");
    check("the same id again drops the cancel", has(guest_now(), "\"cancel\":false,\"cancel_job\":null,\"job\":{\"id\":\"j-C\""), 1);

    /* job_clear and reset forget everything, taken and cancel_job too. */
    hv_additions_job_cancel();
    posted("{\"t\":\"ack\",\"job\":\"j-C\"}");
    check("before the clear: cancel and taken are set", has(guest_now(), "\"cancel\":true,\"cancel_job\":\"j-C\"") && has(guest_now(), "\"taken\":\"j-B\"}"), 1);
    s0 = hv_additions_seq();
    hv_additions_job_clear();
    check("job_clear: it is news", hv_additions_seq(), s0 + 1);
    check_str("job_clear: everything is forgotten", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}");
    hv_additions_job_clear();
    check("job_clear twice: no news", hv_additions_seq(), s0 + 1);

    job_put("{\"id\":\"j-D\"}");
    posted("{\"t\":\"ack\",\"job\":\"j-D\"}");
    job_put("{\"id\":\"j-E\",\"password\":\"SECRET\"}");
    hv_additions_job_cancel();
    check("before the reset: cancel_job E, taken D", has(guest_now(), "\"cancel_job\":\"j-E\"") && has(guest_now(), "\"taken\":\"j-D\"}"), 1);
    hv_additions_reset();
    check_str("reset: everything is forgotten", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}");
    check("reset: the buffer is zero", job_buffer_zero(), 1);

    /* Eject wipes a pending job; a taken id and a cancel stay (the agent may still be running). */
    check("jobs", hv_additions_job_set("{\"id\":\"j-F\",\"password\":\"SECRET\"}"), 0);
    posted("{\"t\":\"ack\",\"job\":\"j-F\"}");
    job_put("{\"id\":\"j-G\",\"password\":\"SECRET\"}");
    hv_additions_job_cancel();
    job_put("{\"id\":\"j-H\",\"password\":\"SECRET\"}");
    s0 = hv_additions_seq();
    hv_additions_eject();
    check("eject: the pending job is wiped", job_buffer_zero(), 1);
    check("eject with a pending job and no media: news", hv_additions_seq(), s0 + 1);
    check_str("eject: no job, taken and cancel stay", guest_now(), "{\"inserted\":false,\"n\":0,\"cancel\":true,\"cancel_job\":\"j-G\",\"job\":null,\"taken\":\"j-F\"}");
    s0 = hv_additions_seq();
    hv_additions_eject();
    check("eject again: no news", hv_additions_seq(), s0);
    hv_additions_reset();
}

/* ---- the hook ---- */

static char hook_text[4096];
static unsigned long hook_k;
static int hook_calls;

static void on_event(unsigned long k, const char *json, size_t len, void *user) {
    check("hook: user", user == &hook_calls, 1);
    snprintf(hook_text + strlen(hook_text), sizeof hook_text - strlen(hook_text), "%lu:%.*s|", k, (int)len, json);
    hook_k = k;
    hook_calls++;
}

static void test_hook(void) {
    unsigned long k0 = fresh();
    hv_additions_set_hook(on_event, &hook_calls);
    posted("{\"t\":\"step\",\n\"i\":1}");
    posted("{\"t\":\"bad\" ");
    posted("{\"t\":\"log\"}");
    check("hook: two accepted events", hook_calls, 2);
    char want[160];
    snprintf(want, sizeof want, "%lu:{\"t\":\"step\", \"i\":1}|%lu:{\"t\":\"log\"}|", k0 + 1, k0 + 2);
    check_str("hook: one line each", hook_text, want);
    check("hook: k", hook_k, k0 + 2);
    hv_additions_set_hook(NULL, NULL);
    posted("{\"t\":\"log\"}");
    check("hook: off", hook_calls, 2);
}

/* ---- the reserved folder entry and the media ---- */

#define REQ_BUF (1 << 16)
static HvFs *fs;
static uint64_t uniq;
static uint8_t reply_buf[(1 << 16) + 4096];
static size_t reply_len;

static int call(uint32_t op, uint64_t node, const void *a, size_t alen, const void *b, size_t blen) {
    static uint8_t req[REQ_BUF];
    FuseInHeader h = {(uint32_t)(sizeof h + alen + blen), op, ++uniq, node, 1000, 1000, 1, 0, 0};
    memcpy(req, &h, sizeof h);
    if (alen) memcpy(req + sizeof h, a, alen);
    if (blen) memcpy(req + sizeof h + alen, b, blen);
    struct iovec in = {req, sizeof h + alen + blen}, out = {reply_buf, sizeof reply_buf};
    size_t n = hv_fs_handle(fs, &in, 1, &out, 1);
    if (n == 0) return 1;
    FuseOutHeader o;
    memcpy(&o, reply_buf, sizeof o);
    if (o.unique != h.unique || o.len != n) return -9999;
    reply_len = n - sizeof o;
    memmove(reply_buf, reply_buf + sizeof o, reply_len);
    return o.error;
}

static int name_call(uint32_t op, uint64_t node, const void *a, size_t alen, const char *name) {
    return call(op, node, a, alen, name, strlen(name) + 1);
}

static long long lookup(uint64_t dir, const char *name) {
    int e = name_call(FUSE_LOOKUP, dir, NULL, 0, name);
    if (e) return e;
    FuseEntryOut o;
    memcpy(&o, reply_buf, sizeof o);
    return (long long)o.nodeid;
}

static long long open_node(uint64_t node, uint32_t flags) {
    FuseOpenIn a = {flags, 0};
    int e = call(FUSE_OPEN, node, &a, sizeof a, NULL, 0);
    if (e) return e;
    FuseOpenOut o;
    memcpy(&o, reply_buf, sizeof o);
    return (long long)o.fh;
}

static const char *read_text(uint64_t dir, const char *name) {
    static char text[4096];
    text[0] = 0;
    long long node = lookup(dir, name);
    if (node <= 0) return text;
    long long fh = open_node((uint64_t)node, 0);
    if (fh < 0) return text;
    FuseReadIn r = {(uint64_t)fh, 0, sizeof text - 1, 0, 0, 0, 0};
    if (call(FUSE_READ, (uint64_t)node, &r, sizeof r, NULL, 0) == 0) memcpy(text, reply_buf, reply_len), text[reply_len] = 0;
    FuseReleaseIn rel = {(uint64_t)fh, 0, 0, 0};
    call(FUSE_RELEASE, (uint64_t)node, &rel, sizeof rel, NULL, 0);
    return text;
}

static const char *root_names(void) {
    static char names[4096];
    names[0] = 0;
    uint64_t off = 0;
    for (;;) {
        FuseReadIn r = {0, off, 4096, 0, 0, 0, 0};
        if (call(FUSE_READDIRPLUS, FUSE_ROOT_ID, &r, sizeof r, NULL, 0) != 0 || !reply_len) break;
        for (size_t at = 0; at < reply_len;) {
            FuseEntryOut eo;
            FuseDirent d;
            memcpy(&eo, reply_buf + at, sizeof eo);
            memcpy(&d, reply_buf + at + sizeof eo, sizeof d);
            size_t len = strlen(names);
            snprintf(names + len, sizeof names - len, "%.*s|", (int)d.namelen, (char *)reply_buf + at + sizeof eo + sizeof d);
            off = d.off;
            at += (sizeof eo + sizeof d + d.namelen + 7) & ~(size_t)7;
        }
    }
    return names;
}

static const char *tux_folders(void) { return read_text(FUSE_ROOT_ID, ".tux-folders"); }

static char base[PATH_MAX];

static void write_host(const char *rel, const char *text) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", base, rel);
    FILE *f = fopen(p, "w");
    if (f) fputs(text, f), fclose(f);
}

static void test_reserved_entry(void) {
    char media[PATH_MAX], other[PATH_MAX], file[PATH_MAX];
    snprintf(media, sizeof media, "%s/media", base);
    snprintf(other, sizeof other, "%s/other", base);
    snprintf(file, sizeof file, "%s/media/install", base);
    hv_additions_reset();
    hv_fs_folders_clear();

    /* The table rules, before any insert. */
    check("the reserved index is the table's extra one", HV_FS_ADDITIONS, HV_FS_MAX_FOLDERS);
    check("no media: no user folders", hv_fs_folder_count(), 0);
    errno = 0;
    check("a user folder cannot be named tux-additions", hv_fs_folder_set(0, NULL, "tux-additions", other, HV_FS_RW), -1);
    check("a user folder cannot be named tux-additions: EINVAL", errno, EINVAL);
    check("not even Read-only", hv_fs_folder_set(3, NULL, "tux-additions", other, HV_FS_RO), -1);
    check("the reserved index takes no other name", hv_fs_folder_set(HV_FS_ADDITIONS, NULL, "docs", other, HV_FS_RO), -1);
    check("the reserved index takes no other id", hv_fs_folder_set(HV_FS_ADDITIONS, "docs", "tux-additions", other, HV_FS_RO), -1);
    check("the reserved index is Read-only only (rw)", hv_fs_folder_set(HV_FS_ADDITIONS, NULL, "tux-additions", media, HV_FS_RW), -1);
    check("the reserved index is Read-only only (cow)", hv_fs_folder_set(HV_FS_ADDITIONS, NULL, "tux-additions", media, HV_FS_COW), -1);
    errno = 0;
    check("the public set refuses the reserved index (right name and mode)", hv_fs_folder_set(HV_FS_ADDITIONS, NULL, "tux-additions", media, HV_FS_RO), -1);
    check("the public set refuses the reserved index: EINVAL", errno, EINVAL);
    check("the public set refuses it with the id too", hv_fs_folder_set(HV_FS_ADDITIONS, "tux-additions", "tux-additions", media, HV_FS_RO), -1);
    check("the public refusal leaves no entry in .tux-folders", has(tux_folders(), "tux-additions"), 0);
    check("the public refusal leaves no media state", hv_additions_inserted(), 0);
    check("index 9 is not a folder", hv_fs_folder_set(HV_FS_ADDITIONS + 1, NULL, "x", other, HV_FS_RO), -1);
    check("index 9 has no clear", hv_fs_folder_clear(HV_FS_ADDITIONS + 1), -1);
    check("the media is not there yet", hv_additions_inserted(), 0);
    check("the root has no tux-additions yet", has(root_names(), "tux-additions|"), 0);
    check(".tux-folders has no entry yet", has(tux_folders(), "tux-additions"), 0);

    /* Insert. */
    errno = 0;
    check("insert: a missing directory", hv_additions_insert("/nonexistent/tux-media"), -1);
    check("insert: ENOENT", errno, ENOENT);
    check("insert: nothing changed", hv_additions_inserted(), 0);
    check("insert: NULL", hv_additions_insert(NULL), -1);
    check("nudge with no media", hv_additions_nudge(), -1);
    check("nudge with no media: ENODEV", errno, ENODEV);
    check("insert: file, not a directory", hv_additions_insert(file), -1);
    check("insert", hv_additions_insert(media), 1);
    check("inserted is 1", hv_additions_inserted(), 1);
    char *g = hv_additions_guest_json(NULL);
    check("guest json: inserted, n 1", has(g, "{\"inserted\":true,\"n\":1,\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}"), 1);
    free(g);
    const char *j = tux_folders();
    check(".tux-folders: the entry", has(j, "\"name\":\"tux-additions\",\"mode\":\"ro\",\"state\":\"ready\""), 1);
    check(".tux-folders: id is the name", has(j, "\"id\":\"tux-additions\""), 1);
    check(".tux-folders: index 8", has(j, "\"index\":8,"), 1);
    check(".tux-folders: kind and n", has(j, "\"kind\":\"additions\",\"n\":1}"), 1);
    check(".tux-folders: valid JSON", hv_json_object_valid(j, strlen(j)), 1);
    check("the root lists it", has(root_names(), "|tux-additions|"), 1);
    check("the public set cannot change the entry once it is in", hv_fs_folder_set(HV_FS_ADDITIONS, NULL, "tux-additions", media, HV_FS_RO), -1);
    check("and n is as it was", has(tux_folders(), "\"kind\":\"additions\",\"n\":1}"), 1);

    /* The user-folder calls do not see it. */
    check("count: not counted", hv_fs_folder_count(), 0);
    check("find: not found", hv_fs_folder_find("tux-additions"), -1);
    hv_fs_folders_clear();
    check("folders_clear: it stays", has(tux_folders(), "\"kind\":\"additions\""), 1);
    check("online refuses it", hv_fs_folder_online(HV_FS_ADDITIONS, 0), -1);
    check("kind refuses it", hv_fs_folder_kind(HV_FS_ADDITIONS, HV_FS_PROVIDER), -1);
    check("touch refuses it", hv_fs_folder_touch(HV_FS_ADDITIONS), -1);
    check("ask refuses it", hv_fs_folder_ask(HV_FS_ADDITIONS, HV_FS_ASK_EXPORT), -1);
    check("answer refuses it", hv_fs_folder_answer(HV_FS_ADDITIONS, 1, 1, "x"), -1);
    check("answered refuses it", hv_fs_folder_answered(HV_FS_ADDITIONS, 1, NULL, NULL), -1);
    check("the media is still ready after those", has(tux_folders(), "\"state\":\"ready\",\"case\""), 1);

    /* User folders beside it. */
    check("a user folder", hv_fs_folder_set(0, NULL, "docs", other, HV_FS_RW), 0);
    check("count: one", hv_fs_folder_count(), 1);
    check("find: docs", hv_fs_folder_find("docs"), 0);
    check("the same name cannot be reused at another index", hv_fs_folder_set(1, NULL, "docs", other, HV_FS_RW), -1);
    j = tux_folders();
    check(".tux-folders: both", has(j, "\"name\":\"docs\"") && has(j, "\"name\":\"tux-additions\""), 1);
    check(".tux-folders: only the media has a kind", has(j, "\"name\":\"docs\",\"mode\":\"rw\",\"state\":\"ready\",\"case\":\"sensitive\",\"gen\":") ||
          has(j, "\"name\":\"docs\",\"mode\":\"rw\",\"state\":\"ready\",\"case\":\"insensitive\",\"gen\":"), 1);
    {
        const char *first = strstr(j, "\"kind\":"), *second = first ? strstr(first + 1, "\"kind\":") : NULL;
        check(".tux-folders: one kind", first != NULL && second == NULL, 1);
    }
    hv_fs_folder_clear(0);
    check("no user folders left", hv_fs_folder_count(), 0);

    /* The media through FUSE: read, and Read-only everywhere. */
    FuseInitIn in = {7, 41, 1 << 20, 0x7fffffff, 0, {0}};
    fs = hv_fs_create();
    check("fuse init", call(FUSE_INIT, 0, &in, sizeof in, NULL, 0), 0);
    long long root = lookup(FUSE_ROOT_ID, "tux-additions");
    check("lookup tux-additions", root > 0, 1);
    check("the media reads", !strcmp(read_text((uint64_t)root, "install"), "#!/bin/sh\n"), 1);
    long long inst = lookup((uint64_t)root, "install");
    FuseMkdirIn mk = {0755, 0};
    FuseMknodIn mn = {S_IFREG | 0644, 0, 0, 0};
    FuseCreateIn cr = {1 | LX_O_CREAT, 0644, 022, 0};
    FuseSetattrIn sa = {.valid = FATTR_MODE, .mode = 0777};
    check("media: create is EROFS", name_call(FUSE_CREATE, (uint64_t)root, &cr, sizeof cr, "x"), -LX_EROFS);
    check("media: mknod is EROFS", name_call(FUSE_MKNOD, (uint64_t)root, &mn, sizeof mn, "x"), -LX_EROFS);
    check("media: mkdir is EROFS", name_call(FUSE_MKDIR, (uint64_t)root, &mk, sizeof mk, "x"), -LX_EROFS);
    check("media: unlink is EROFS", name_call(FUSE_UNLINK, (uint64_t)root, NULL, 0, "install"), -LX_EROFS);
    check("media: rmdir is EROFS", name_call(FUSE_RMDIR, (uint64_t)root, NULL, 0, "apt"), -LX_EROFS);
    check("media: symlink is EROFS", call(FUSE_SYMLINK, (uint64_t)root, "x", 2, "install", 8), -LX_EROFS);
    check("media: chmod is EROFS", call(FUSE_SETATTR, (uint64_t)inst, &sa, sizeof sa, NULL, 0), -LX_EROFS);
    check("media: open for writing is EROFS", open_node((uint64_t)inst, 1), -LX_EROFS);
    check("media: open read-write is EROFS", open_node((uint64_t)inst, 2), -LX_EROFS);
    check("media: open with O_TRUNC is EROFS", open_node((uint64_t)inst, LX_O_TRUNC), -LX_EROFS);
    uint8_t ra[sizeof(FuseRename2In) + 16] = {0};
    FuseRename2In rn = {(uint64_t)root, 0, 0};
    memcpy(ra, &rn, sizeof rn);
    memcpy(ra + sizeof rn, "install\0x", 10);
    check("media: rename is EROFS", call(FUSE_RENAME2, (uint64_t)root, ra, sizeof rn + 10, NULL, 0), -LX_EROFS);
    check("media: the root of the server takes no new entry", name_call(FUSE_MKDIR, FUSE_ROOT_ID, &mk, sizeof mk, "tux-additions"), -LX_EPERM);
    check("media: the root of the server has no rmdir of it", name_call(FUSE_RMDIR, FUSE_ROOT_ID, NULL, 0, "tux-additions"), -LX_EPERM);
    char host[PATH_MAX];
    snprintf(host, sizeof host, "%s/media/x", base);
    check("media: nothing new on the host", access(host, F_OK), -1);

    /* The server keeps the entry's node across a nudge and a second insert of the same directory. */
    check("nudge", hv_additions_nudge(), 2);
    check("nudge: n in .tux-folders", has(tux_folders(), "\"kind\":\"additions\",\"n\":2}"), 1);
    check("nudge: inserted", hv_additions_inserted(), 2);
    check("the same node after a nudge", lookup(FUSE_ROOT_ID, "tux-additions"), root);
    check("insert again", hv_additions_insert(media), 3);
    check("insert again: n in .tux-folders", has(tux_folders(), "\"n\":3}"), 1);
    check("the same folder keeps its node", lookup(FUSE_ROOT_ID, "tux-additions"), root);
    check("the media still reads", !strcmp(read_text((uint64_t)root, "install"), "#!/bin/sh\n"), 1);

    /* A failed insert leaves the old media and n alone. */
    errno = 0;
    check("a bad insert", hv_additions_insert("/nonexistent/other"), -1);
    check("a bad insert: n stays 3", hv_additions_inserted(), 3);
    check("a bad insert: .tux-folders stays", has(tux_folders(), "\"n\":3}"), 1);

    /* Eject and insert again: n goes on. */
    check("eject", hv_additions_eject(), 0);
    check("ejected: n is 0", hv_additions_inserted(), 0);
    g = hv_additions_guest_json(NULL);
    check("ejected: guest json", has(g, "{\"inserted\":false,\"n\":0,\"cancel\":false,\"cancel_job\":null,"), 1);
    free(g);
    check("ejected: gone from .tux-folders", has(tux_folders(), "tux-additions"), 0);
    check("ejected: gone from the root", has(root_names(), "tux-additions"), 0);
    check("ejected: lookup fails", lookup(FUSE_ROOT_ID, "tux-additions"), -LX_ENOENT);
    check("eject twice", hv_additions_eject(), 0);
    check("nudge after eject", hv_additions_nudge(), -1);
    posted("{\"t\":\"report\"}");
    job_put("{\"id\":\"kept\",\"password\":\"SECRET\"}");
    check("insert after eject: n goes on", hv_additions_insert(media), 4);
    check("the job and the events stay over an insert", has(app_events(0, NULL), "\"t\":\"report\"") && has(hv_additions_test_job_buffer(NULL), "kept"), 1);
    hv_additions_eject();
    check("eject wipes the pending job", job_buffer_zero(), 1);
    check("eject: the guest sees no job", has(guest_now(), "\"job\":null"), 1);
    check("the events stay over an eject", has(app_events(0, NULL), "\"t\":\"report\""), 1);

    /* Reset clears the entry, and the numbers start again. */
    hv_additions_insert(media);
    hv_additions_reset();
    check("reset: no media", hv_additions_inserted(), 0);
    check("reset: gone from .tux-folders", has(tux_folders(), "tux-additions"), 0);
    check("reset: the job is gone", job_buffer_zero(), 1);
    check("reset: n starts at 1", hv_additions_insert(media), 1);
    check("reset: the entry works again", lookup(FUSE_ROOT_ID, "tux-additions") > 0, 1);
    hv_additions_reset();
    check("a user folder after a reset", hv_fs_folder_set(0, NULL, "docs", other, HV_FS_RW), 0);
    check("reset leaves user folders alone", hv_fs_folder_count(), 1);
    hv_fs_folders_clear();

    hv_fs_destroy(fs);
    fs = NULL;
}

int main(void) {
    snprintf(base, sizeof base, "/tmp/tux-add-XXXXXX");
    if (!mkdtemp(base)) return 1;
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/media", base);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/media/apt", base);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/other", base);
    mkdir(p, 0755);
    write_host("media/install", "#!/bin/sh\n");

    test_validator();
    test_done_scan();
    test_post_refused();
    test_ring();
    test_late_view();
    test_wait();
    test_job();
    test_job_id();
    test_ack();
    test_stale_done();
    test_cancel_rules();
    test_hook();
    test_reserved_entry();

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", base);
    if (system(cmd)) {}
    if (failed) {
        fprintf(stderr, "test_additions: FAILED\n");
        return 1;
    }
    printf("test_additions: ok\n");
    return 0;
}
