/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _GNU_SOURCE
#include "hvcodec.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
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

#ifdef __linux__
#include <sys/ioctl.h>
#include "vcodec_dev.h"
#define HAVE_DEV 1
#endif

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
    int fd, broken, dev;
    uint32_t seq, posted;
    char addr[160], note[200];
    uint8_t scratch[4096]; /* the device's reply to a call that drops it */
    HvStats st;
};

/* The device's reply buffer for a call: what a reply needs at most is not known before it, so this much is pinned
   and a longer reply comes by HVCODEC_IOC_REST. */
#define DEV_REPLY_MIN (256u << 10)
#define DEV_REPLY_MAX (4u << 20)

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
    char note[200] = "";
    int fd = -1, dev = 0;
    if (!addr || !*addr) addr = getenv("HENGE_VCODEC");
    if (!addr || !*addr) {
#ifdef HAVE_DEV
        fd = open("/dev/hvcodec", O_RDWR | O_CLOEXEC);
        if (fd >= 0) addr = "/dev/hvcodec", dev = 1;
        else snprintf(note, sizeof note, "/dev/hvcodec: %s", strerror(errno));
#else
        snprintf(note, sizeof note, "no /dev/hvcodec on this system");
#endif
        if (!dev) addr = HV_CLIENT_DEFAULT;
    } else if (!strncmp(addr, "/dev/", 5)) {
#ifdef HAVE_DEV
        fd = open(addr, O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            set_err(err, errlen, "cannot open %s (%s): is henge-codec-dkms installed and the machine running with the codec device on?", addr,
                    strerror(errno));
            return NULL;
        }
        dev = 1;
#else
        set_err(err, errlen, "%s: no /dev/hvcodec on this system", addr);
        return NULL;
#endif
    }
    if (!dev) fd = !strncmp(addr, "unix:", 5) ? connect_unix(addr + 5) : connect_tcp(addr);
    if (fd < 0) {
        set_err(err, errlen, "cannot connect to the Henge codec service at %s (%s): is the machine running with the video codecs on?", addr, strerror(errno));
        return NULL;
    }
    if (dev) {
        HvClient *c = calloc(1, sizeof *c);
        if (!c) {
            close(fd);
            set_err(err, errlen, "no memory");
            return NULL;
        }
        pthread_mutex_init(&c->mu, NULL);
        pthread_cond_init(&c->turn_cv, NULL);
        c->fd = fd, c->dev = 1;
        snprintf(c->addr, sizeof c->addr, "%s", addr);
        return c;
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
    snprintf(c->note, sizeof c->note, "%s", note);
    return c;
}

int hv_client_dma(const HvClient *c) { return c->dev; }
const char *hv_client_note(const HvClient *c) { return c->note; }

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

static void set_reply(HvReply *r, int status, const char *msg) {
    if (!r) return;
    r->status = status, r->len = 0;
    snprintf(r->err, sizeof r->err, "%s", msg);
}

#ifdef HAVE_DEV
/* The reply in buf (len bytes): checked, then given to r. */
static int finish_reply(HvClient *c, uint32_t type, const uint8_t *buf, size_t len, HvReply *r) {
    HvVcHeader h;
    if (len < sizeof h) return broken(c, r);
    memcpy(&h, buf, sizeof h);
    if (h.type != (type | HV_VC_REPLY) || h.seq != c->seq || h.len != len - sizeof h) return broken(c, r);
    if (!r) return h.status;
    r->data = (uint8_t *)buf + sizeof h, r->len = h.len, r->status = h.status;
    r->heap_[sizeof h + h.len] = 0; /* buf is r->heap_ when r is given */
    if (h.status) {
        size_t n = h.len < sizeof r->err - 1 ? h.len : sizeof r->err - 1;
        for (size_t i = 0; i < n; i++) r->err[i] = r->data[i] >= 32 && r->data[i] < 127 ? (char)r->data[i] : '?';
        r->err[n] = 0;
        if (!n) snprintf(r->err, sizeof r->err, "%s", hv_status_name(h.status));
    }
    return h.status;
}

static int grow(HvReply *r, size_t n) {
    if (n <= r->cap_) return 0;
    uint8_t *p = realloc(r->heap_, n);
    if (!p) return -1;
    r->heap_ = p, r->cap_ = n;
    return 0;
}

/* One message on /dev/hvcodec, in its turn. in and out are raw data (NULL for none). */
static int dev_call(HvClient *c, uint32_t type, const void *a, size_t alen, const void *b, size_t blen, const struct hvcodec_buf *in,
                    const struct hvcodec_buf *out, HvReply *r) {
    if (alen + blen > HV_VC_MAX_PAYLOAD) {
        set_reply(r, HV_VC_E_INVAL, "the request is too large");
        return HV_VC_E_INVAL;
    }
    HvVcHeader h = {type, (uint32_t)(alen + blen), ++c->seq, 0};
    struct hvcodec_call k;
    memset(&k, 0, sizeof k);
    k.msg[0] = (struct hvcodec_buf){(uintptr_t)&h, sizeof h};
    k.msg[1] = (struct hvcodec_buf){(uintptr_t)a, alen};
    k.msg[2] = (struct hvcodec_buf){(uintptr_t)b, blen};
    for (int i = 0; i < 2; i++) {
        if (in) k.in[i] = in[i], c->st.sent += in[i].len;
        if (out) k.out[i] = out[i];
    }
    uint8_t *buf = c->scratch;
    size_t cap = sizeof c->scratch;
    if (r) {
        if (grow(r, DEV_REPLY_MIN)) {
            set_reply(r, HV_VC_E_NOMEM, "no memory for the reply");
            return HV_VC_E_NOMEM;
        }
        buf = r->heap_, cap = r->cap_ - 1 < DEV_REPLY_MAX ? r->cap_ - 1 : DEV_REPLY_MAX;
    }
    k.reply = (struct hvcodec_buf){(uintptr_t)buf, cap};
    int rc;
    for (int tries = 0;; tries++) {
        rc = ioctl(c->fd, HVCODEC_IOC_CALL, &k);
        if (rc == 0 || errno != EAGAIN || tries >= 1000) break;
        usleep(1000); /* the queue is full: requests of other processes */
    }
    c->st.calls++;
    c->st.sent += sizeof h + alen + blen;
    if (rc) {
        if (errno == ENOBUFS) { /* the host had no memory to keep a long reply */
            set_reply(r, HV_VC_E_LIMIT, "the host had no memory for the reply");
            return HV_VC_E_LIMIT;
        }
        if (errno == E2BIG || errno == EINVAL) {
            set_reply(r, HV_VC_E_INVAL, "/dev/hvcodec refused the request's size");
            return HV_VC_E_INVAL;
        }
        int st = broken(c, r);
        if (r) snprintf(r->err, sizeof r->err, "%s: %s", c->addr, strerror(errno));
        return st;
    }
    size_t len = k.reply_len;
    c->st.received += len;
    if (out) c->st.received += out[0].len + out[1].len;
    if (k.reply_total > k.reply_len) {
        if (!r) return broken(c, NULL); /* a call that drops its reply has short replies */
        if (grow(r, (size_t)k.reply_total + 1)) {
            set_reply(r, HV_VC_E_NOMEM, "no memory for the reply");
            return HV_VC_E_NOMEM; /* the device drops the rest at the next call */
        }
        while (len < k.reply_total) {
            struct hvcodec_rest q = {{(uintptr_t)(r->heap_ + len), k.reply_total - len}, 0, 0};
            if (ioctl(c->fd, HVCODEC_IOC_REST, &q) || !q.reply_len || q.reply_left != k.reply_total - len) return broken(c, r);
            len += q.reply_len;
            c->st.received += q.reply_len;
        }
    }
    return finish_reply(c, type, r ? r->heap_ : buf, len, r);
}
#endif

int hv_call(HvClient *c, uint32_t type, const void *a, size_t alen, const void *b, size_t blen, HvReply *r) {
    take_turn(c);
#ifdef HAVE_DEV
    if (c->dev) {
        if (r) r->data = NULL, r->len = 0, r->err[0] = 0, r->status = 0;
        int st = c->broken ? broken(c, r) : dev_call(c, type, a, alen, b, blen, NULL, NULL, r);
        end_turn(c);
        return st;
    }
#endif
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
#ifdef HAVE_DEV
    if (c->dev) { /* one ioctl: as quick as a send */
        int st = hv_call(c, type, a, alen, NULL, 0, NULL);
        if (!st) c->st.posts++;
        return st == HV_CLIENT_E_IO ? st : 0;
    }
#endif
    take_turn(c);
    int st = c->broken ? HV_CLIENT_E_IO : 0;
    if (!st && c->posted >= MAX_POSTED) st = read_posted(c);
    if (!st) st = send_req(c, type, a, alen, NULL, 0);
    if (!st) c->posted++, c->st.posts++;
    else if (st == HV_CLIENT_E_IO) c->broken = 1;
    end_turn(c);
    return st;
}

/* The plane layout of a transfer: 0, or an error in r. */
static int layout(uint32_t fmt, uint32_t w, uint32_t h, const int linesize[2], uint32_t row[2], uint32_t rows[2], int *n, HvReply *r) {
    *n = hv_vc_planes(fmt, w, h, row, rows);
    if (!*n) {
        set_reply(r, HV_VC_E_INVAL, "bad format or size");
        return HV_VC_E_INVAL;
    }
    for (int i = 0; i < *n; i++)
        if (linesize[i] < 0 || (uint32_t)linesize[i] < row[i]) {
            set_reply(r, HV_VC_E_INVAL, "a linesize below the plane's row");
            return HV_VC_E_INVAL;
        }
    return 0;
}

int hv_frame_upload(HvClient *c, uint32_t handle, uint32_t fmt, uint32_t w, uint32_t h, uint8_t *const data[2], const int linesize[2],
                    HvReply *r) {
    uint32_t row[2], rows[2];
    int n, st = layout(fmt, w, h, linesize, row, rows, &n, r);
    if (st) return st;
#ifdef HAVE_DEV
    if (c->dev) {
        HvVcPlanesDma d = {handle, fmt, w, h, {0, 0}, {0, 0}};
        struct hvcodec_buf in[2] = {{0, 0}, {0, 0}};
        for (int i = 0; i < n; i++) {
            in[i] = (struct hvcodec_buf){(uintptr_t)data[i], (uint64_t)(rows[i] - 1) * (uint32_t)linesize[i] + row[i]};
            d.stride[i] = (uint32_t)linesize[i];
        }
        d.offset[1] = in[0].len;
        take_turn(c);
        if (r) r->data = NULL, r->len = 0, r->err[0] = 0, r->status = 0;
        st = c->broken ? broken(c, r) : dev_call(c, HV_VC_FRAME_UPLOAD_DMA, &d, sizeof d, NULL, 0, in, NULL, r);
        end_turn(c);
        return st;
    }
#endif
    uint64_t bytes = hv_vc_frame_bytes(fmt, w, h);
    uint8_t *packed = malloc(bytes), *p = packed;
    if (!packed) {
        set_reply(r, HV_VC_E_NOMEM, "no memory");
        return HV_VC_E_NOMEM;
    }
    for (int i = 0; i < n; i++)
        for (uint32_t y = 0; y < rows[i]; y++, p += row[i]) memcpy(p, data[i] + (size_t)y * (uint32_t)linesize[i], row[i]);
    HvVcHandle m = {handle, 0};
    st = hv_call(c, HV_VC_FRAME_UPLOAD, &m, sizeof m, packed, bytes, r);
    free(packed);
    return st;
}

int hv_frame_download(HvClient *c, uint32_t handle, uint32_t fmt, uint32_t w, uint32_t h, uint8_t *const data[2], const int linesize[2],
                      HvReply *r) {
    uint32_t row[2], rows[2];
    int n, st = layout(fmt, w, h, linesize, row, rows, &n, r);
    if (st) return st;
    HvReply own = {0};
    HvReply *rr = r ? r : &own;
#ifdef HAVE_DEV
    if (c->dev) {
        HvVcPlanesDma d = {handle, fmt, w, h, {0, 0}, {0, 0}};
        struct hvcodec_buf out[2] = {{0, 0}, {0, 0}};
        for (int i = 0; i < n; i++) {
            out[i] = (struct hvcodec_buf){(uintptr_t)data[i], (uint64_t)(rows[i] - 1) * (uint32_t)linesize[i] + row[i]};
            d.stride[i] = (uint32_t)linesize[i];
        }
        d.offset[1] = out[0].len;
        take_turn(c);
        rr->data = NULL, rr->len = 0, rr->err[0] = 0, rr->status = 0;
        st = c->broken ? broken(c, rr) : dev_call(c, HV_VC_FRAME_DOWNLOAD_DMA, &d, sizeof d, NULL, 0, NULL, out, rr);
        end_turn(c);
        if (!r) hv_reply_free(&own);
        return st;
    }
#endif
    HvVcHandle m = {handle, 0};
    HvVcFrameReply fr;
    st = hv_call(c, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0, rr);
    if (!st && (rr->len < sizeof fr || rr->len - sizeof fr != hv_vc_frame_bytes(fmt, w, h) ||
                (memcpy(&fr, rr->data, sizeof fr), fr.format != fmt || fr.width != w || fr.height != h))) {
        set_reply(rr, HV_VC_E_INVAL, "the reply does not agree with the frame");
        st = HV_VC_E_INVAL;
    }
    if (!st) {
        const uint8_t *p = rr->data + sizeof fr;
        for (int i = 0; i < n; i++)
            for (uint32_t y = 0; y < rows[i]; y++, p += row[i]) memcpy(data[i] + (size_t)y * (uint32_t)linesize[i], p, row[i]);
    }
    if (!r) hv_reply_free(&own);
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
