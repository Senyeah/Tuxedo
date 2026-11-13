/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _GNU_SOURCE
#include "hvcodec.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 /* macOS: SO_NOSIGPIPE instead */
#endif

/* Unread replies of hv_post. Above this, a post reads them first, so the host never blocks on a full socket. */
#define MAX_POSTED 128
/* A reply can be a frame: HvVcFrameReply and the planes of the largest frame the host makes. */
#define MAX_REPLY (HV_VC_MAX_PAYLOAD + 4096u)

struct HvClient {
    pthread_mutex_t mu;
    pthread_cond_t turn_cv;
    uint64_t next_turn, serving; /* FIFO turns: a thread that loops on short calls cannot starve the others */
    int fd, broken;
    uint32_t seq, posted;
    char addr[160];
    HvStats st;
};

static void set_err(char *err, size_t n, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void set_err(char *err, size_t n, const char *fmt, ...) {
    if (!err || !n) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, n, fmt, ap);
    va_end(ap);
}

static int connect_unix(const char *path) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof a.sun_path) {
        errno = ENAMETOOLONG;
        return -1;
    }
    strcpy(a.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a)) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

static int connect_tcp(const char *spec) {
    char host[128];
    const char *port = "8470", *colon = strrchr(spec, ':');
    size_t n = colon ? (size_t)(colon - spec) : strlen(spec);
    if (n >= sizeof host) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(host, spec, n);
    host[n] = 0;
    if (colon) port = colon + 1;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) || !res) {
        errno = EHOSTUNREACH;
        return -1;
    }
    int fd = -1;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        if (!connect(fd, a->ai_addr, a->ai_addrlen)) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    }
    return fd;
}

HvClient *hv_client_open(const char *addr, char *err, size_t errlen) {
    if (!addr || !*addr) addr = getenv("HENGE_VCODEC");
    if (!addr || !*addr) addr = HV_CLIENT_DEFAULT;
    int fd = !strncmp(addr, "unix:", 5) ? connect_unix(addr + 5) : connect_tcp(addr);
    if (fd < 0) {
        set_err(err, errlen, "cannot connect to the Henge codec service at %s (%s): is the machine running with the video codecs on?", addr, strerror(errno));
        return NULL;
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    /* ENC_PACKET waits at most 10 s on the host: a longer silence is a dead host */
    struct timeval tv = {60, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    HvClient *c = calloc(1, sizeof *c);
    if (!c) {
        close(fd);
        set_err(err, errlen, "no memory");
        return NULL;
    }
    pthread_mutex_init(&c->mu, NULL);
    pthread_cond_init(&c->turn_cv, NULL);
    c->fd = fd;
    snprintf(c->addr, sizeof c->addr, "%s", addr);
    return c;
}

void hv_client_close(HvClient *c) {
    if (!c) return;
    close(c->fd);
    pthread_cond_destroy(&c->turn_cv);
    pthread_mutex_destroy(&c->mu);
    free(c);
}

const char *hv_client_addr(const HvClient *c) { return c->addr; }

/* The connection is held from the request to its reply. */
static void take_turn(HvClient *c) {
    pthread_mutex_lock(&c->mu);
    uint64_t t = c->next_turn++;
    while (t != c->serving) pthread_cond_wait(&c->turn_cv, &c->mu);
    pthread_mutex_unlock(&c->mu);
}

static void end_turn(HvClient *c) {
    pthread_mutex_lock(&c->mu);
    c->serving++;
    pthread_cond_broadcast(&c->turn_cv);
    pthread_mutex_unlock(&c->mu);
}

void hv_client_stats(HvClient *c, HvStats *s) {
    take_turn(c);
    *s = c->st;
    end_turn(c);
}

static int send_iov(HvClient *c, struct iovec *iov, int n) {
    while (n) {
        struct msghdr m;
        memset(&m, 0, sizeof m);
        m.msg_iov = iov;
        m.msg_iovlen = n;
        ssize_t w = sendmsg(c->fd, &m, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        c->st.sent += (uint64_t)w;
        while (n && (size_t)w >= iov->iov_len) w -= (ssize_t)iov->iov_len, iov++, n--;
        if (n) iov->iov_base = (uint8_t *)iov->iov_base + w, iov->iov_len -= (size_t)w;
    }
    return 0;
}

static int recv_all(HvClient *c, void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t r = recv(c->fd, b, n, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        b += r, n -= (size_t)r, c->st.received += (uint64_t)r;
    }
    return 0;
}

static int drop(HvClient *c, size_t n) {
    uint8_t junk[4096];
    while (n) {
        size_t k = n < sizeof junk ? n : sizeof junk;
        if (recv_all(c, junk, k)) return -1;
        n -= k;
    }
    return 0;
}

static int send_req(HvClient *c, uint32_t type, const void *a, size_t alen, const void *b, size_t blen) {
    if (alen + blen > HV_VC_MAX_PAYLOAD) return HV_VC_E_INVAL;
    HvVcHeader h = {type, (uint32_t)(alen + blen), ++c->seq, 0};
    struct iovec iov[3] = {{&h, sizeof h}, {(void *)a, alen}, {(void *)b, blen}};
    int n = 1;
    if (alen) iov[n++] = (struct iovec){(void *)a, alen};
    if (blen) iov[n++] = (struct iovec){(void *)b, blen};
    if (send_iov(c, iov, n)) return HV_CLIENT_E_IO;
    return 0;
}

/* Reads the replies of posted requests, in order: the host answers each request before the next. */
static int read_posted(HvClient *c) {
    while (c->posted) {
        HvVcHeader r;
        if (recv_all(c, &r, sizeof r) || !(r.type & HV_VC_REPLY) || r.len > MAX_REPLY || drop(c, r.len)) return HV_CLIENT_E_IO;
        c->posted--;
    }
    return 0;
}

static int broken(HvClient *c, HvReply *r) {
    c->broken = 1;
    if (r) {
        r->status = HV_CLIENT_E_IO;
        r->len = 0;
        snprintf(r->err, sizeof r->err, "the connection to the Henge codec service at %s failed", c->addr);
    }
    return HV_CLIENT_E_IO;
}

int hv_call(HvClient *c, uint32_t type, const void *a, size_t alen, const void *b, size_t blen, HvReply *r) {
    take_turn(c);
    if (r) r->data = NULL, r->len = 0, r->err[0] = 0, r->status = 0;
    if (c->broken || read_posted(c)) {
        int st = broken(c, r);
        end_turn(c);
        return st;
    }
    int st = send_req(c, type, a, alen, b, blen);
    if (st) {
        if (st == HV_CLIENT_E_IO) broken(c, r);
        else if (r) r->status = st, snprintf(r->err, sizeof r->err, "the request is too large");
        end_turn(c);
        return st;
    }
    c->st.calls++;
    HvVcHeader h;
    if (recv_all(c, &h, sizeof h) || h.type != (type | HV_VC_REPLY) || h.seq != c->seq || h.len > MAX_REPLY) {
        st = broken(c, r);
        end_turn(c);
        return st;
    }
    if (!r) {
        st = drop(c, h.len) ? broken(c, NULL) : h.status;
        end_turn(c);
        return st;
    }
    if ((size_t)h.len + 1 > r->cap_) {
        uint8_t *n = realloc(r->heap_, (size_t)h.len + 1);
        if (!n) {
            /* keep the stream in step */
            st = drop(c, h.len) ? broken(c, r) : HV_VC_E_NOMEM;
            if (st == HV_VC_E_NOMEM) r->status = st, snprintf(r->err, sizeof r->err, "no memory for a reply of %u bytes", h.len);
            end_turn(c);
            return st;
        }
        r->heap_ = n, r->cap_ = (size_t)h.len + 1;
    }
    if (h.len && recv_all(c, r->heap_, h.len)) {
        st = broken(c, r);
        end_turn(c);
        return st;
    }
    end_turn(c);
    r->heap_[h.len] = 0;
    r->data = r->heap_, r->len = h.len, r->status = h.status;
    if (h.status) {
        size_t n = h.len < sizeof r->err - 1 ? h.len : sizeof r->err - 1;
        for (size_t i = 0; i < n; i++) r->err[i] = r->heap_[i] >= 32 && r->heap_[i] < 127 ? (char)r->heap_[i] : '?';
        r->err[n] = 0;
        if (!n) snprintf(r->err, sizeof r->err, "%s", hv_status_name(h.status));
    }
    return h.status;
}

int hv_post(HvClient *c, uint32_t type, const void *a, size_t alen) {
    take_turn(c);
    int st = c->broken ? HV_CLIENT_E_IO : 0;
    if (!st && c->posted >= MAX_POSTED) st = read_posted(c);
    if (!st) st = send_req(c, type, a, alen, NULL, 0);
    if (!st) c->posted++, c->st.posts++;
    else if (st == HV_CLIENT_E_IO) c->broken = 1;
    end_turn(c);
    return st;
}

void hv_reply_free(HvReply *r) {
    free(r->heap_);
    r->heap_ = NULL, r->cap_ = 0, r->data = NULL, r->len = 0;
}

int hv_query(HvClient *c, HvQuery *q, char *err, size_t errlen) {
    memset(q, 0, sizeof *q);
    HvReply r = {0};
    int st = hv_call(c, HV_VC_QUERY, NULL, 0, NULL, 0, &r);
    if (st) {
        set_err(err, errlen, "QUERY: %s", r.err);
        hv_reply_free(&r);
        return st;
    }
    if (r.len < sizeof q->head) goto bad;
    memcpy(&q->head, r.data, sizeof q->head);
    const HvVcQueryHead *h = &q->head;
    if (h->version != HV_VC_VERSION) {
        set_err(err, errlen, "the host speaks hvcodec version %u, this client %u", h->version, HV_VC_VERSION);
        hv_reply_free(&r);
        return HV_VC_E_NOSUP;
    }
    /* a newer host can grow the entries: copy the part this client knows */
    if (h->encoder_size < sizeof(HvVcEncoderInfo) || h->decoder_size < sizeof(HvVcDecoderInfo) || h->n_encoders > 256 || h->n_decoders > 256 ||
        r.len != sizeof *h + (uint64_t)h->n_encoders * h->encoder_size + (uint64_t)h->n_decoders * h->decoder_size)
        goto bad;
    q->encoders = calloc(h->n_encoders + 1, sizeof *q->encoders);
    q->decoders = calloc(h->n_decoders + 1, sizeof *q->decoders);
    if (!q->encoders || !q->decoders) {
        hv_query_free(q);
        hv_reply_free(&r);
        set_err(err, errlen, "no memory");
        return HV_VC_E_NOMEM;
    }
    const uint8_t *p = r.data + sizeof *h;
    for (uint32_t i = 0; i < h->n_encoders; i++, p += h->encoder_size) {
        HvVcEncoderInfo *e = &q->encoders[i];
        memcpy(e, p, sizeof *e);
        e->encoder_id[sizeof e->encoder_id - 1] = 0;
        e->name[sizeof e->name - 1] = 0;
        if (e->n_profiles > HV_VC_MAX_PROFILES) e->n_profiles = HV_VC_MAX_PROFILES;
        for (uint32_t k = 0; k < e->n_profiles; k++) e->profiles[k].name[sizeof e->profiles[k].name - 1] = 0;
    }
    for (uint32_t i = 0; i < h->n_decoders; i++, p += h->decoder_size) memcpy(&q->decoders[i], p, sizeof q->decoders[i]);
    hv_reply_free(&r);
    return 0;
bad:
    hv_query_free(q);
    hv_reply_free(&r);
    set_err(err, errlen, "QUERY: the reply does not agree with its sizes");
    return HV_VC_E_INVAL;
}

void hv_query_free(HvQuery *q) {
    free(q->encoders);
    free(q->decoders);
    memset(q, 0, sizeof *q);
}

/* The hardware entry first: the list can hold a software encoder for the same codec. */
const HvVcEncoderInfo *hv_query_encoder(const HvQuery *q, uint32_t codec) {
    const HvVcEncoderInfo *any = NULL;
    for (uint32_t i = 0; q->encoders && i < q->head.n_encoders; i++) {
        if (q->encoders[i].codec != codec) continue;
        if (q->encoders[i].flags & HV_VC_ENC_HW) return &q->encoders[i];
        if (!any) any = &q->encoders[i];
    }
    return any;
}

const HvVcDecoderInfo *hv_query_decoder(const HvQuery *q, uint32_t codec) {
    for (uint32_t i = 0; q->decoders && i < q->head.n_decoders; i++)
        if (q->decoders[i].codec == codec) return &q->decoders[i];
    return NULL;
}

const char *hv_status_name(int status) {
    switch (status) {
    case HV_VC_OK: return "ok";
    case HV_VC_E_INVAL: return "invalid request";
    case HV_VC_E_NOSUP: return "not supported on this device";
    case HV_VC_E_LIMIT: return "at a host limit";
    case HV_VC_E_HANDLE: return "no such session or frame";
    case HV_VC_E_CODEC: return "VideoToolbox refused";
    case HV_VC_E_LOST: return "the session was stopped by the system";
    case HV_VC_E_AGAIN: return "no packet yet";
    case HV_VC_E_EOF: return "end of stream";
    case HV_VC_E_TIMEOUT: return "timed out";
    case HV_VC_E_NOMEM: return "no memory";
    case HV_CLIENT_E_IO: return "connection failed";
    default: return "unknown status";
    }
}

void hv_fourcc_str(uint32_t codec, char out[5]) {
    for (int i = 0; i < 4; i++) {
        char ch = (char)(codec >> (24 - 8 * i));
        out[i] = ch >= 32 && ch < 127 ? ch : '?';
    }
    out[4] = 0;
}
