/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Tuxedo Additions: the media, the job and the guest's events (additions.h).

   One lock holds the state. It is taken before the folder table's lock (fs_server.c) and never after it: the server
   never calls back here. The job is in one static buffer that is overwritten with zero when it goes. The events are
   kept as they came, validated, on one line each. */
#include "additions.h"
#include "fs_server.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DEPTH_MAX 8
#define ID_MAX 64 /* a job id: 1 to 64 characters of A-Za-z0-9_- */
#define CAP_MAX (ID_MAX + 2)

/* ---- the JSON scanner: checks a text, and finds the top-level string members "t", "id" and "job" ---- */

/* The last top-level member of one name: state 0 none, 1 a string, 2 any other type. */
typedef struct Member {
    int state;
    char s[CAP_MAX];
    size_t len; /* the decoded length (it may be longer than s holds) */
} Member;

typedef struct Scan {
    const unsigned char *p, *end;
    Member t, id, job;
} Scan;

/* Where a decoded string goes. It keeps cap - 1 bytes at most; len counts them all. */
typedef struct Sink {
    char *out;
    size_t cap, len;
} Sink;

static void put(Sink *k, const void *bytes, size_t n) {
    if (!k) return;
    const unsigned char *b = bytes;
    for (size_t i = 0; i < n; i++, k->len++)
        if (k->len + 1 < k->cap) k->out[k->len] = (char)b[i];
}

static void put_utf8(Sink *k, unsigned cp) {
    unsigned char b[4];
    size_t n;
    if (cp < 0x80) b[0] = (unsigned char)cp, n = 1;
    else if (cp < 0x800) b[0] = (unsigned char)(0xC0 | cp >> 6), b[1] = (unsigned char)(0x80 | (cp & 0x3F)), n = 2;
    else if (cp < 0x10000)
        b[0] = (unsigned char)(0xE0 | cp >> 12), b[1] = (unsigned char)(0x80 | (cp >> 6 & 0x3F)), b[2] = (unsigned char)(0x80 | (cp & 0x3F)), n = 3;
    else
        b[0] = (unsigned char)(0xF0 | cp >> 18), b[1] = (unsigned char)(0x80 | (cp >> 12 & 0x3F)),
        b[2] = (unsigned char)(0x80 | (cp >> 6 & 0x3F)), b[3] = (unsigned char)(0x80 | (cp & 0x3F)), n = 4;
    put(k, b, n);
}

static void sink_end(Sink *k) { k->out[k->len < k->cap ? k->len : k->cap - 1] = 0; }

static void ws(Scan *s) {
    while (s->p < s->end && (*s->p == ' ' || *s->p == '\t' || *s->p == '\n' || *s->p == '\r')) s->p++;
}

static int digit(const Scan *s, const unsigned char *p) { return p < s->end && *p >= '0' && *p <= '9'; }

/* The length of the UTF-8 character at p (a byte of 0x80 or more), or 0 when it is not valid: no overlong
   form, no half of a UTF-16 pair, nothing above U+10FFFF. */
static size_t utf8_len(const unsigned char *p, const unsigned char *end) {
    unsigned char c = *p;
    size_t n = (size_t)(end - p);
    if (c >= 0xC2 && c <= 0xDF) return n >= 2 && (p[1] & 0xC0) == 0x80 ? 2 : 0;
    if (c >= 0xE0 && c <= 0xEF) {
        if (n < 3 || (p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80) return 0;
        if ((c == 0xE0 && p[1] < 0xA0) || (c == 0xED && p[1] > 0x9F)) return 0;
        return 3;
    }
    if (c >= 0xF0 && c <= 0xF4) {
        if (n < 4 || (p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80 || (p[3] & 0xC0) != 0x80) return 0;
        if ((c == 0xF0 && p[1] < 0x90) || (c == 0xF4 && p[1] > 0x8F)) return 0;
        return 4;
    }
    return 0;
}

static int hex4(Scan *s, unsigned *out) {
    if (s->end - s->p < 4) return -1;
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        int c = s->p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return -1;
    }
    s->p += 4;
    *out = v;
    return 0;
}

/* s->p is at the opening quote. k may be NULL (check only). */
static int string(Scan *s, Sink *k) {
    s->p++;
    for (;;) {
        if (s->p >= s->end) return -1;
        unsigned char c = *s->p;
        if (c == '"') {
            s->p++;
            return 0;
        }
        if (c < 0x20) return -1;
        if (c == '\\') {
            if (++s->p >= s->end) return -1;
            unsigned char e = *s->p++;
            const char *plain = e == '"' ? "\"" : e == '\\' ? "\\" : e == '/' ? "/" : e == 'b' ? "\b" : e == 'f' ? "\f" : e == 'n' ? "\n" : e == 'r' ? "\r" : e == 't' ? "\t" : NULL;
            if (plain) {
                put(k, plain, 1);
            } else if (e == 'u') {
                unsigned u, lo;
                if (hex4(s, &u) != 0) return -1;
                if (u >= 0xDC00 && u <= 0xDFFF) return -1; /* a low half alone */
                if (u >= 0xD800 && u <= 0xDBFF) {
                    if (s->end - s->p < 2 || s->p[0] != '\\' || s->p[1] != 'u') return -1;
                    s->p += 2;
                    if (hex4(s, &lo) != 0 || lo < 0xDC00 || lo > 0xDFFF) return -1;
                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                }
                put_utf8(k, u);
            } else {
                return -1;
            }
            continue;
        }
        if (c < 0x80) {
            put(k, &c, 1);
            s->p++;
            continue;
        }
        size_t n = utf8_len(s->p, s->end);
        if (!n) return -1;
        put(k, s->p, n);
        s->p += n;
    }
}

static int number(Scan *s) {
    const unsigned char *p = s->p;
    if (p < s->end && *p == '-') p++;
    if (p < s->end && *p == '0') p++;
    else if (p < s->end && *p >= '1' && *p <= '9') while (digit(s, p)) p++;
    else return -1;
    if (p < s->end && *p == '.') {
        if (!digit(s, ++p)) return -1;
        while (digit(s, p)) p++;
    }
    if (p < s->end && (*p == 'e' || *p == 'E')) {
        if (++p < s->end && (*p == '+' || *p == '-')) p++;
        if (!digit(s, p)) return -1;
        while (digit(s, p)) p++;
    }
    s->p = p;
    return 0;
}

static int literal(Scan *s, const char *word) {
    size_t n = strlen(word);
    if ((size_t)(s->end - s->p) < n || memcmp(s->p, word, n) != 0) return -1;
    s->p += n;
    return 0;
}

static int value(Scan *s, int depth);

static int array(Scan *s, int depth) {
    if (depth > DEPTH_MAX) return -1;
    s->p++;
    ws(s);
    if (s->p < s->end && *s->p == ']') return s->p++, 0;
    for (;;) {
        if (value(s, depth) != 0) return -1;
        ws(s);
        if (s->p >= s->end) return -1;
        if (*s->p == ',') s->p++;
        else if (*s->p == ']') return s->p++, 0;
        else return -1;
    }
}

static int object(Scan *s, int depth) {
    if (depth > DEPTH_MAX) return -1;
    s->p++;
    ws(s);
    if (s->p < s->end && *s->p == '}') return s->p++, 0;
    for (;;) {
        ws(s);
        if (s->p >= s->end || *s->p != '"') return -1;
        char key[8];
        Sink ks = {key, sizeof key, 0};
        if (string(s, depth == 1 ? &ks : NULL) != 0) return -1;
        ws(s);
        if (s->p >= s->end || *s->p != ':') return -1;
        s->p++;
        ws(s);
        Member *m = NULL; /* the last one of a name counts, as a reader that keeps the last does */
        if (depth == 1) {
            if (ks.len == 1 && key[0] == 't') m = &s->t;
            else if (ks.len == 2 && !memcmp(key, "id", 2)) m = &s->id;
            else if (ks.len == 3 && !memcmp(key, "job", 3)) m = &s->job;
        }
        if (m) {
            if (s->p < s->end && *s->p == '"') {
                Sink ms = {m->s, sizeof m->s, 0};
                if (string(s, &ms) != 0) return -1;
                sink_end(&ms);
                m->len = ms.len;
                m->state = 1;
            } else {
                if (value(s, depth) != 0) return -1;
                m->state = 2;
            }
        } else if (value(s, depth) != 0) {
            return -1;
        }
        ws(s);
        if (s->p >= s->end) return -1;
        if (*s->p == ',') s->p++;
        else if (*s->p == '}') return s->p++, 0;
        else return -1;
    }
}

static int value(Scan *s, int depth) {
    ws(s);
    if (s->p >= s->end) return -1;
    switch (*s->p) {
    case '{': return object(s, depth + 1);
    case '[': return array(s, depth + 1);
    case '"': return string(s, NULL);
    case 't': return literal(s, "true");
    case 'f': return literal(s, "false");
    case 'n': return literal(s, "null");
    default: return number(s);
    }
}

static int scan(const char *text, size_t len, Scan *s) {
    *s = (Scan){.p = (const unsigned char *)text, .end = (const unsigned char *)text + len};
    if (!text) return -1;
    ws(s);
    if (s->p >= s->end || *s->p != '{' || object(s, 1) != 0) return -1;
    ws(s);
    return s->p == s->end ? 0 : -1;
}

int hv_json_object_valid(const char *s, size_t len) {
    Scan sc;
    return scan(s, len, &sc) == 0;
}

/* ---- the state ---- */

typedef struct Event {
    unsigned long k;
    char *text;
    size_t len;
} Event;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static unsigned long seq;      /* news: media, job, cancel, events */
static int inserted, n_last; /* n_last goes on over an eject, so the next insert is a new number */
static char job[HV_ADDITIONS_JOB_MAX + 1];
static size_t job_len;
/* Ids ("" none): the stored job, the job the agent took (acked), the job the app cancelled last. */
static char job_id[ID_MAX + 1], taken_id[ID_MAX + 1], cancel_id[ID_MAX + 1];
static Event ring[HV_ADDITIONS_EVENTS_KEPT];
static size_t ring_head, ring_count, ring_bytes;
static unsigned long next_k = 1; /* the next event's k; kept over a reset */
static unsigned long base_k;     /* the last k before the machine's first event: older ones are another machine's */
static unsigned long dropped_k;  /* the last k dropped for the limits, or base_k */
static HvAdditionsHook hook;
static void *hook_user;

void hv_additions_wipe(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}

static void news_locked(void) {
    seq++;
    pthread_cond_broadcast(&cond);
}

static void job_wipe_locked(void) {
    hv_additions_wipe(job, sizeof job);
    job_len = 0;
    job_id[0] = 0;
}

/* Does the member hold exactly this id? */
static int is_id(const Member *m, const char *id) { return m->state == 1 && id[0] && m->len == strlen(id) && !memcmp(m->s, id, m->len); }

/* A job id: 1 to ID_MAX characters of A-Za-z0-9_-. */
static int id_ok(const Member *m) {
    if (m->state != 1 || m->len < 1 || m->len > ID_MAX) return 0;
    for (size_t i = 0; i < m->len; i++) {
        char c = m->s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return 0;
    }
    return 1;
}

unsigned long hv_additions_seq(void) {
    pthread_mutex_lock(&mu);
    unsigned long s = seq;
    pthread_mutex_unlock(&mu);
    return s;
}

const char *hv_additions_test_job_buffer(size_t *size) {
    if (size) *size = sizeof job;
    return job;
}

void hv_additions_set_hook(HvAdditionsHook fn, void *user) {
    pthread_mutex_lock(&mu);
    hook = fn, hook_user = user;
    pthread_mutex_unlock(&mu);
}

int hv_additions_insert(const char *dir) {
    if (!dir) {
        errno = EINVAL;
        return -1;
    }
    pthread_mutex_lock(&mu);
    int next = n_last + 1;
    if (hv_fs_additions_insert(dir, next) != 0) {
        int e = errno;
        pthread_mutex_unlock(&mu);
        errno = e;
        return -1;
    }
    n_last = next;
    inserted = 1;
    news_locked();
    pthread_mutex_unlock(&mu);
    return next;
}

int hv_additions_eject(void) {
    pthread_mutex_lock(&mu);
    if (inserted || job_len) {
        if (inserted) hv_fs_folder_clear(HV_FS_ADDITIONS);
        inserted = 0;
        job_wipe_locked(); /* a pending job may hold a password */
        news_locked();
    }
    pthread_mutex_unlock(&mu);
    return 0;
}

int hv_additions_nudge(void) {
    pthread_mutex_lock(&mu);
    int next = n_last + 1;
    if (!inserted || hv_fs_additions_nudge(next) != 0) {
        pthread_mutex_unlock(&mu);
        errno = ENODEV;
        return -1;
    }
    n_last = next;
    news_locked();
    pthread_mutex_unlock(&mu);
    return next;
}

int hv_additions_inserted(void) {
    pthread_mutex_lock(&mu);
    int n = inserted ? n_last : 0;
    pthread_mutex_unlock(&mu);
    return n;
}

int hv_additions_job_set(const char *json) {
    if (!json) {
        errno = EINVAL;
        return -1;
    }
    size_t len = strlen(json);
    if (len > HV_ADDITIONS_JOB_MAX) {
        errno = E2BIG;
        return -1;
    }
    Scan sc;
    if (scan(json, len, &sc) != 0 || !id_ok(&sc.id)) {
        errno = EINVAL;
        return -1;
    }
    while (len && (*json == ' ' || *json == '\t' || *json == '\n' || *json == '\r')) json++, len--; /* a file's end of line */
    while (len && (json[len - 1] == ' ' || json[len - 1] == '\t' || json[len - 1] == '\n' || json[len - 1] == '\r')) len--;
    pthread_mutex_lock(&mu);
    job_wipe_locked();
    memcpy(job, json, len);
    job_len = len;
    memcpy(job_id, sc.id.s, sc.id.len);
    job_id[sc.id.len] = 0;
    if (!strcmp(cancel_id, job_id)) cancel_id[0] = 0; /* the same id again is a new wish; another id is not touched */
    news_locked();
    pthread_mutex_unlock(&mu);
    return 0;
}

int hv_additions_job_cancel(void) {
    pthread_mutex_lock(&mu);
    const char *id = job_len ? job_id : taken_id;
    if (id[0]) {
        snprintf(cancel_id, sizeof cancel_id, "%s", id);
        job_wipe_locked(); /* a job the agent has not taken is gone; a taken one runs on until the agent stops it */
        news_locked();
    }
    pthread_mutex_unlock(&mu);
    return 0;
}

static void job_forget_locked(void) {
    job_wipe_locked();
    taken_id[0] = cancel_id[0] = 0;
}

void hv_additions_job_clear(void) {
    pthread_mutex_lock(&mu);
    if (job_len || taken_id[0] || cancel_id[0]) {
        job_forget_locked();
        news_locked();
    }
    pthread_mutex_unlock(&mu);
}

/* ---- the events ---- */

static void ring_drop_oldest_locked(void) {
    Event *e = &ring[ring_head];
    dropped_k = e->k;
    ring_bytes -= e->len;
    free(e->text);
    *e = (Event){0};
    ring_head = (ring_head + 1) % HV_ADDITIONS_EVENTS_KEPT;
    ring_count--;
}

int hv_additions_post(const char *body, size_t len) {
    if (!body) {
        errno = EINVAL;
        return -1;
    }
    if (len > HV_ADDITIONS_EVENT_MAX) {
        errno = E2BIG;
        return -1;
    }
    Scan sc;
    if (scan(body, len, &sc) != 0 || sc.t.state != 1) {
        errno = EINVAL;
        return -1;
    }
    int done = sc.t.len == 4 && !memcmp(sc.t.s, "done", 4);
    int ack = sc.t.len == 3 && !memcmp(sc.t.s, "ack", 3);
    /* One line: a line end is only ever between tokens in a text that passed the scan. */
    while (len && (*body == ' ' || *body == '\t' || *body == '\n' || *body == '\r')) body++, len--;
    while (len && (body[len - 1] == ' ' || body[len - 1] == '\t' || body[len - 1] == '\n' || body[len - 1] == '\r')) len--;
    char *text = malloc(len + 1);
    if (!text) {
        errno = ENOMEM;
        return -1;
    }
    for (size_t i = 0; i < len; i++) text[i] = body[i] == '\n' || body[i] == '\r' ? ' ' : body[i];
    text[len] = 0;

    pthread_mutex_lock(&mu);
    while (ring_count && (ring_count == HV_ADDITIONS_EVENTS_KEPT || ring_bytes + len > HV_ADDITIONS_EVENTS_BYTES))
        ring_drop_oldest_locked();
    unsigned long k = next_k++;
    ring[(ring_head + ring_count++) % HV_ADDITIONS_EVENTS_KEPT] = (Event){k, text, len};
    ring_bytes += len;
    if (ack && is_id(&sc.job, job_id) && job_len) { /* the agent has the job: it crosses the link once */
        snprintf(taken_id, sizeof taken_id, "%s", job_id);
        job_wipe_locked();
    }
    if (done) { /* only the job it names; a stale or forged done does not touch another job */
        if (is_id(&sc.job, taken_id)) taken_id[0] = 0;
        if (job_len && is_id(&sc.job, job_id)) job_wipe_locked();
    }
    news_locked();
    HvAdditionsHook fn = hook;
    void *user = hook_user;
    char *copy = fn ? strdup(text) : NULL; /* the ring may drop its own at once */
    pthread_mutex_unlock(&mu);
    if (copy) {
        fn(k, copy, len, user);
        free(copy);
    }
    return 0;
}

char *hv_additions_guest_json(unsigned long *out_seq) {
    pthread_mutex_lock(&mu);
    char *out = malloc(job_len + 512);
    if (out) {
        /* The ids passed id_ok, so they need no escape. */
        int n = snprintf(out, 256, "{\"inserted\":%s,\"n\":%d,\"cancel\":%s,\"cancel_job\":", inserted ? "true" : "false",
                         inserted ? n_last : 0, cancel_id[0] ? "true" : "false");
        if (cancel_id[0]) n += snprintf(out + n, 80, "\"%s\"", cancel_id);
        else memcpy(out + n, "null", 4), n += 4;
        memcpy(out + n, ",\"job\":", 7), n += 7;
        if (job_len) memcpy(out + n, job, job_len), n += (int)job_len;
        else memcpy(out + n, "null", 4), n += 4;
        if (taken_id[0]) n += snprintf(out + n, 96, ",\"taken\":\"%s\"}", taken_id);
        else n += snprintf(out + n, 96, ",\"taken\":null}");
    }
    if (out_seq) *out_seq = seq;
    pthread_mutex_unlock(&mu);
    return out;
}

char *hv_additions_events_json(unsigned long since, unsigned long *out_seq) {
    pthread_mutex_lock(&mu);
    int gap;
    if (since > next_k - 1) { /* a count from another process: start over */
        gap = 1;
        since = 0;
    } else {
        gap = (since > base_k ? since : base_k) < dropped_k;
    }
    size_t need = 160;
    for (size_t i = 0; i < ring_count; i++) {
        const Event *e = &ring[(ring_head + i) % HV_ADDITIONS_EVENTS_KEPT];
        if (e->k > since) need += e->len + 40;
    }
    char *out = malloc(need);
    if (out) {
        size_t n = (size_t)snprintf(out, 160, "{\"inserted\":%s,\"n\":%d,\"seq\":%lu,\"gap\":%s,\"events\":[", inserted ? "true" : "false",
                                    inserted ? n_last : 0, seq, gap ? "true" : "false");
        int first = 1;
        for (size_t i = 0; i < ring_count; i++) {
            const Event *e = &ring[(ring_head + i) % HV_ADDITIONS_EVENTS_KEPT];
            if (e->k <= since) continue;
            n += (size_t)snprintf(out + n, 40, "%s{\"k\":%lu,\"e\":", first ? "" : ",", e->k);
            memcpy(out + n, e->text, e->len);
            n += e->len;
            out[n++] = '}';
            first = 0;
        }
        out[n++] = ']';
        out[n++] = '}';
        out[n] = 0;
    }
    if (out_seq) *out_seq = seq;
    pthread_mutex_unlock(&mu);
    return out;
}

unsigned long hv_additions_wait(unsigned long since, int ms) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    if (ms < 0) ms = 0;
    until.tv_sec += ms / 1000;
    until.tv_nsec += (long)(ms % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    pthread_mutex_lock(&mu);
    while (seq == since && pthread_cond_timedwait(&cond, &mu, &until) != ETIMEDOUT) {}
    unsigned long s = seq;
    pthread_mutex_unlock(&mu);
    return s;
}

void hv_additions_reset(void) {
    pthread_mutex_lock(&mu);
    hv_fs_folder_clear(HV_FS_ADDITIONS);
    inserted = n_last = 0;
    job_forget_locked();
    for (size_t i = 0; i < ring_count; i++) {
        Event *e = &ring[(ring_head + i) % HV_ADDITIONS_EVENTS_KEPT];
        free(e->text);
        *e = (Event){0};
    }
    ring_head = ring_count = ring_bytes = 0;
    base_k = dropped_k = next_k - 1;
    news_locked();
    pthread_mutex_unlock(&mu);
}
