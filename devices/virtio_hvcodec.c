#include "virtio_hvcodec.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <TargetConditionals.h>

#define WORKERS HVCD_MAX_CONTEXTS /* one for each context: a wait on one cannot hold up another */
#define MAX_OUTSTANDING 64 /* taken from the ring and not given back; the rest waits in the ring */
#define FREE_KEEP 16
/* Replies waiting for REST, in all contexts. */
#if TARGET_OS_IPHONE
#define MAX_PENDING (64ull << 20)
#else
#define MAX_PENDING (256ull << 20)
#endif

typedef struct Req {
    struct Req *next;
    uint16_t head;
    int nseg, cap;
    HvVirtqSeg *seg;
    uint32_t written;
    HvcdReq h; /* copied once, at the notify */
    int bad, slot, release;
} Req;

typedef struct {
    void *ctx; /* the backend's; NULL once it is closed */
    uint32_t gen;
    int used, busy;
    uint8_t *pending;
    uint32_t pending_len, pending_off;
} Slot;

struct HvVirtioHvcodec {
    HvVirtio vio;
    const HvHvcodecOps *ops;
    void *opaque;
    pthread_mutex_t mu;
    pthread_cond_t cv, idle_cv;
    Req *q_head, *q_tail, *done, *free_list;
    int outstanding, running, nfree, stopping;
    Slot slot[HVCD_MAX_CONTEXTS];
    pthread_t worker[WORKERS];
    int workers;
    uint64_t pending_bytes, requests, refused, broken;
};

static int slot_of(const HvVirtioHvcodec *d, uint32_t ctx) {
    uint32_t s = ctx & 0xff;
    return s < HVCD_MAX_CONTEXTS && d->slot[s].used && d->slot[s].gen == ctx >> 8 ? (int)s : -1;
}

static void drop_pending(HvVirtioHvcodec *d, Slot *s) {
    if (!s->pending) return;
    free(s->pending);
    pthread_mutex_lock(&d->mu);
    d->pending_bytes -= s->pending_len;
    pthread_mutex_unlock(&d->mu);
    s->pending = NULL, s->pending_len = s->pending_off = 0;
}

/* Bytes of one direction's segments. */
static uint64_t dir_len(const Req *r, int writable) {
    uint64_t n = 0;
    for (int s = 0; s < r->nseg; s++)
        if (r->seg[s].write == writable) n += r->seg[s].len;
    return n;
}

/* Host views of len bytes of one direction, after off. -1 if any of it is not guest RAM. */
static int map(HvVirtioHvcodec *d, const Req *r, int writable, uint64_t off, uint64_t len, struct iovec *iov, int *n) {
    *n = 0;
    for (int s = 0; s < r->nseg && len; s++) {
        const HvVirtqSeg *g = &r->seg[s];
        if (g->write != writable) continue;
        if (off >= g->len) {
            off -= g->len;
            continue;
        }
        uint64_t k = g->len - off;
        if (k > len) k = len;
        void *p = hv_phys_ptr(d->vio.m, g->addr + off, k);
        if (!p) return -1;
        iov[(*n)++] = (struct iovec){p, (size_t)k};
        len -= k, off = 0;
    }
    return len ? -1 : 0;
}

/* The device wrote len bytes of the writable segments after off: translations made from them are stale. */
static void written(HvVirtioHvcodec *d, const Req *r, uint64_t off, uint64_t len) {
    for (int s = 0; s < r->nseg && len; s++) {
        const HvVirtqSeg *g = &r->seg[s];
        if (!g->write) continue;
        if (off >= g->len) {
            off -= g->len;
            continue;
        }
        uint64_t k = g->len - off < len ? g->len - off : len;
        hv_dma_written(d->vio.m, g->addr + off, k);
        len -= k, off = 0;
    }
}

typedef struct {
    HvHvcodecIo io;
    HvVirtioHvcodec *d;
    Slot *s;
    HvIovCursor msg, reply;
    uint32_t cap, len, total;
    int replied, status;
} Call;

static uint32_t call_read(HvHvcodecIo *io, uint32_t off, void *buf, uint32_t n) {
    Call *c = io->priv;
    if (off > io->msg_len) return 0;
    if (n > io->msg_len - off) n = io->msg_len - off;
    return (uint32_t)hv_iov_copy(&c->msg, off, buf, n, 0);
}

static int call_reply(HvHvcodecIo *io, const struct iovec *iov, int n) {
    Call *c = io->priv;
    if (c->replied) return -1;
    c->replied = 1;
    uint64_t total = 0;
    for (int i = 0; i < n; i++) total += iov[i].iov_len;
    if (total > HVCD_MAX_REPLY) {
        c->status = HVCD_S_LIMIT;
        return 0;
    }
    uint64_t rest = total > c->cap ? total - c->cap : 0;
    if (rest) {
        HvVirtioHvcodec *d = c->d;
        int room;
        pthread_mutex_lock(&d->mu);
        room = d->pending_bytes + rest <= MAX_PENDING;
        if (room) d->pending_bytes += rest;
        pthread_mutex_unlock(&d->mu);
        c->s->pending = room ? malloc(rest) : NULL;
        if (!c->s->pending) {
            if (room) {
                pthread_mutex_lock(&d->mu);
                d->pending_bytes -= rest;
                pthread_mutex_unlock(&d->mu);
            }
            c->status = HVCD_S_LIMIT; /* the reply is lost: the guest gets an error, not half a reply */
            return 0;
        }
        c->s->pending_len = (uint32_t)rest, c->s->pending_off = 0;
    }
    uint64_t at = 0;
    for (int i = 0; i < n; i++) {
        const uint8_t *p = iov[i].iov_base;
        uint64_t len = iov[i].iov_len;
        if (at < c->cap) {
            uint64_t k = c->cap - at < len ? c->cap - at : len;
            hv_iov_copy(&c->reply, at, (void *)p, k, 1);
            p += k, len -= k, at += k;
        }
        if (len) memcpy(c->s->pending + (at - c->cap), p, len), at += len;
    }
    c->len = (uint32_t)(total < c->cap ? total : c->cap);
    c->total = (uint32_t)total;
    return 0;
}

/* A worker: one request. A request with a context has that context to itself. */
static void serve(HvVirtioHvcodec *d, Req *r) {
    HvcdResp resp = {HVCD_S_INVAL, 0, 0, 0};
    const HvcdReq *h = &r->h;
    uint64_t rd = dir_len(r, 0), wr = dir_len(r, 1);
    int data_out = 0;
    struct iovec *iov = NULL;
    r->written = 0;
    if (wr < sizeof resp) goto done; /* nowhere to say anything */
    int ok = !r->bad && h->msg_len <= HVCD_MAX_MESSAGE && h->in_len <= HVCD_MAX_DATA && h->out_len <= HVCD_MAX_DATA &&
             h->reply_cap <= HVCD_MAX_REPLY && rd == sizeof *h + (uint64_t)h->msg_len + h->in_len &&
             wr == sizeof resp + (uint64_t)h->reply_cap + h->out_len;
    if (ok && h->op != HVCD_OP_MSG) ok = !h->msg_len && !h->in_len && !h->out_len;
    iov = ok ? malloc(sizeof *iov * ((size_t)r->nseg + 5)) : NULL;
    struct iovec *resp_iov = iov, *msg = NULL, *in = NULL, *reply = NULL, *out = NULL;
    int nresp = 0, nmsg = 0, nin = 0, nreply = 0, nout = 0;
    if (!iov) goto respond;
    /* 16 bytes can span two segments: map them as up to 2 entries */
    struct iovec resp_v[2];
    if (map(d, r, 1, 0, sizeof resp, resp_v, &nresp) || nresp > 2) {
        resp.status = HVCD_S_FAULT;
        goto done;
    }
    msg = iov;
    if (map(d, r, 0, sizeof *h, h->msg_len, msg, &nmsg)) goto fault;
    in = msg + nmsg;
    if (map(d, r, 0, sizeof *h + (uint64_t)h->msg_len, h->in_len, in, &nin)) goto fault;
    reply = in + nin;
    if (map(d, r, 1, sizeof resp, h->reply_cap, reply, &nreply)) goto fault;
    out = reply + nreply;
    if (map(d, r, 1, sizeof resp + (uint64_t)h->reply_cap, h->out_len, out, &nout)) goto fault;
    resp_iov = resp_v;

    Slot *s = r->slot >= 0 ? &d->slot[r->slot] : NULL;
    switch (h->op) {
    case HVCD_OP_OPEN: {
        int k = -1;
        pthread_mutex_lock(&d->mu);
        for (int i = 0; i < HVCD_MAX_CONTEXTS && k < 0; i++)
            if (!d->slot[i].used) k = i;
        if (k >= 0) d->slot[k].used = 1, d->slot[k].busy = 1;
        pthread_mutex_unlock(&d->mu);
        void *ctx = k >= 0 ? d->ops->open(d->opaque) : NULL;
        pthread_mutex_lock(&d->mu);
        if (k >= 0 && ctx) {
            d->slot[k].ctx = ctx;
            r->slot = k; /* the worker loop clears busy */
            resp.status = HVCD_S_OK, resp.ctx = d->slot[k].gen << 8 | (uint32_t)k;
        } else {
            if (k >= 0) d->slot[k].used = 0, d->slot[k].busy = 0;
            resp.status = HVCD_S_LIMIT;
        }
        pthread_mutex_unlock(&d->mu);
        break;
    }
    case HVCD_OP_CLOSE:
        if (!s) { resp.status = HVCD_S_NOCTX; break; }
        drop_pending(d, s);
        if (s->ctx) d->ops->close(d->opaque, s->ctx);
        s->ctx = NULL;
        r->release = 1; /* the slot is free once the worker lets it go */
        resp.status = HVCD_S_OK;
        break;
    case HVCD_OP_REST:
        if (!s) { resp.status = HVCD_S_NOCTX; break; }
        if (s->pending) {
            uint32_t left = s->pending_len - s->pending_off, k = left < h->reply_cap ? left : h->reply_cap;
            HvIovCursor c;
            hv_iov_cursor(&c, reply, nreply);
            hv_iov_copy(&c, 0, s->pending + s->pending_off, k, 1);
            s->pending_off += k;
            resp.reply_len = k, resp.reply_total = left;
            if (s->pending_off == s->pending_len) drop_pending(d, s);
        }
        resp.status = HVCD_S_OK;
        break;
    case HVCD_OP_MSG: {
        if (!s) { resp.status = HVCD_S_NOCTX; break; }
        drop_pending(d, s);
        if (!s->ctx) { resp.status = HVCD_S_CLOSED; break; }
        Call c = {.io = {h->msg_len, in, out, nin, nout, h->in_len, h->out_len, call_read, call_reply, NULL},
                  .d = d, .s = s, .cap = h->reply_cap, .status = HVCD_S_OK};
        c.io.priv = &c;
        hv_iov_cursor(&c.msg, msg, nmsg);
        hv_iov_cursor(&c.reply, reply, nreply);
        int rc = d->ops->message(d->opaque, s->ctx, &c.io);
        data_out = h->out_len != 0; /* the backend may have written any of it */
        if (rc) {
            drop_pending(d, s);
            d->ops->close(d->opaque, s->ctx);
            s->ctx = NULL;
            resp.status = HVCD_S_CLOSED;
            break;
        }
        resp.status = c.status;
        resp.reply_len = c.status == HVCD_S_OK ? c.len : 0;
        resp.reply_total = c.status == HVCD_S_OK ? c.total : 0;
        break;
    }
    default:
        break;
    }
    goto respond;
fault:
    resp.status = HVCD_S_FAULT;
respond:
    if (resp.status != HVCD_S_OK) __atomic_fetch_add(&d->refused, 1, __ATOMIC_RELAXED);
    if (!iov || resp_iov == iov) {
        /* not mapped yet: map just the response */
        struct iovec rv[2];
        if (map(d, r, 1, 0, sizeof resp, rv, &nresp) || nresp > 2) goto done;
        HvIovCursor c;
        hv_iov_cursor(&c, rv, nresp);
        hv_iov_copy(&c, 0, &resp, sizeof resp, 1);
    } else {
        HvIovCursor c;
        hv_iov_cursor(&c, resp_iov, nresp);
        hv_iov_copy(&c, 0, &resp, sizeof resp, 1);
    }
    written(d, r, 0, sizeof resp + (uint64_t)resp.reply_len);
    if (data_out) written(d, r, sizeof resp + (uint64_t)h->reply_cap, h->out_len);
    r->written = (uint32_t)(data_out ? wr : sizeof resp + (uint64_t)resp.reply_len);
done:
    free(iov);
}

/* Under mu: the first queued request whose context is free, taken out of the queue. */
static Req *pick(HvVirtioHvcodec *d) {
    for (Req **pp = &d->q_head, *prev = NULL; *pp; prev = *pp, pp = &(*pp)->next) {
        Req *r = *pp;
        int s = r->bad || r->h.op == HVCD_OP_OPEN ? -1 : slot_of(d, r->h.ctx);
        if (s >= 0 && d->slot[s].busy) continue;
        if (s >= 0) d->slot[s].busy = 1;
        r->slot = s;
        *pp = r->next;
        if (d->q_tail == r) d->q_tail = prev;
        r->next = NULL;
        return r;
    }
    return NULL;
}

static void *worker(void *opaque) {
    HvVirtioHvcodec *d = opaque;
    pthread_mutex_lock(&d->mu);
    for (;;) {
        Req *r;
        while (!d->stopping && !(r = pick(d))) pthread_cond_wait(&d->cv, &d->mu);
        if (d->stopping) break;
        d->running++;
        pthread_mutex_unlock(&d->mu);
        serve(d, r);
        __atomic_fetch_add(&d->requests, 1, __ATOMIC_RELAXED);
        pthread_mutex_lock(&d->mu);
        d->running--;
        if (r->slot >= 0) {
            Slot *s = &d->slot[r->slot];
            s->busy = 0;
            if (r->release) {
                s->used = 0;
                s->gen = (s->gen + 1) & 0xffffff;
                if (!s->gen) s->gen = 1;
            }
        }
        r->next = d->done, d->done = r;
        pthread_cond_broadcast(&d->cv);
        pthread_cond_broadcast(&d->idle_cv);
        pthread_mutex_unlock(&d->mu);
        hv_machine_wake(d->vio.m);
        pthread_mutex_lock(&d->mu);
    }
    pthread_mutex_unlock(&d->mu);
    return NULL;
}

static Req *req_new(HvVirtioHvcodec *d) {
    Req *r = d->free_list;
    if (r) d->free_list = r->next, d->nfree--;
    else r = calloc(1, sizeof *r);
    if (r) r->next = NULL, r->bad = 0, r->slot = -1, r->release = 0, r->written = 0;
    return r;
}

static void req_free(HvVirtioHvcodec *d, Req *r) {
    if (d->nfree < FREE_KEEP) {
        r->next = d->free_list, d->free_list = r, d->nfree++;
        return;
    }
    free(r->seg);
    free(r);
}

/* CPU thread: take what the driver made available, up to MAX_OUTSTANDING. */
static void notify(HvVirtio *v, int q) {
    HvVirtioHvcodec *d = v->dev;
    int any = 0;
    while (d->outstanding < MAX_OUTSTANDING) {
        Req *r = req_new(d);
        if (!r) break;
        int got = hv_virtq_pop_long(v, q, &r->head, &r->seg, &r->cap, HVCD_MAX_SEGS, &r->nseg);
        if (got == 0) {
            req_free(d, r);
            break;
        }
        if (got < 0) {
            /* taken off the ring, so it must still come back, or the guest loses the slot */
            static int said;
            if (said++ < 10) fprintf(stderr, "virtio-hvcodec: broken request chain (%d segments seen), failing it\n", r->nseg);
            d->broken++;
            hv_virtq_push_head(v, q, r->head, 0);
            hv_virtio_interrupt(v);
            req_free(d, r);
            continue;
        }
        HvIovCursor c;
        struct iovec hv[2];
        int nh = 0;
        r->bad = map(d, r, 0, 0, sizeof r->h, hv, &nh) != 0 || nh > 2;
        if (!r->bad) {
            hv_iov_cursor(&c, hv, nh);
            hv_iov_copy(&c, 0, &r->h, sizeof r->h, 0);
        }
        d->outstanding++;
        pthread_mutex_lock(&d->mu);
        if (d->q_tail) d->q_tail->next = r;
        else d->q_head = r;
        d->q_tail = r;
        pthread_mutex_unlock(&d->mu);
        any = 1;
    }
    if (any) {
        pthread_mutex_lock(&d->mu);
        pthread_cond_broadcast(&d->cv);
        pthread_mutex_unlock(&d->mu);
    }
}

void hv_virtio_hvcodec_poll(HvVirtioHvcodec *d) {
    if (!d) return;
    pthread_mutex_lock(&d->mu);
    Req *r = d->done;
    d->done = NULL;
    pthread_mutex_unlock(&d->mu);
    if (!r) return;
    while (r) {
        Req *next = r->next;
        hv_virtq_push_head(&d->vio, 0, r->head, r->written);
        d->outstanding--;
        req_free(d, r);
        r = next;
    }
    hv_virtio_interrupt(&d->vio);
    if (d->vio.q[0].enabled && (d->vio.status & 4)) notify(&d->vio, 0); /* requests that waited for room */
}

void hv_virtio_hvcodec_drain(HvVirtioHvcodec *d) {
    pthread_mutex_lock(&d->mu);
    while (d->running || d->q_head) pthread_cond_wait(&d->idle_cv, &d->mu);
    pthread_mutex_unlock(&d->mu);
    hv_virtio_hvcodec_poll(d);
}

/* With the workers idle: every context closed, every request dropped (its ring is gone). */
static void close_all(HvVirtioHvcodec *d) {
    for (Req *r = d->q_head, *n; r; r = n) n = r->next, req_free(d, r);
    for (Req *r = d->done, *n; r; r = n) n = r->next, req_free(d, r);
    d->q_head = d->q_tail = d->done = NULL;
    d->outstanding = 0;
    for (int i = 0; i < HVCD_MAX_CONTEXTS; i++) {
        Slot *s = &d->slot[i];
        if (!s->used) continue;
        pthread_mutex_unlock(&d->mu);
        drop_pending(d, s);
        if (s->ctx) d->ops->close(d->opaque, s->ctx);
        pthread_mutex_lock(&d->mu);
        s->ctx = NULL, s->used = 0, s->busy = 0;
        s->gen = (s->gen + 1) & 0xffffff;
        if (!s->gen) s->gen = 1;
    }
}

/* The driver reset the device (status 0): requests in flight finish first, as they write guest memory. */
static void device_reset(HvVirtio *v) {
    HvVirtioHvcodec *d = v->dev;
    if (!d) return;
    pthread_mutex_lock(&d->mu);
    for (Req *r = d->q_head, *n; r; r = n) n = r->next, req_free(d, r);
    d->q_head = d->q_tail = NULL;
    while (d->running) pthread_cond_wait(&d->idle_cv, &d->mu);
    close_all(d);
    pthread_mutex_unlock(&d->mu);
}

void hv_virtio_hvcodec_stats(HvVirtioHvcodec *d, HvVirtioHvcodecStats *s) {
    pthread_mutex_lock(&d->mu);
    *s = (HvVirtioHvcodecStats){d->requests, d->refused, d->broken, d->pending_bytes, 0, d->running};
    for (int i = 0; i < HVCD_MAX_CONTEXTS; i++) s->contexts += d->slot[i].used;
    pthread_mutex_unlock(&d->mu);
}

HvPciDev *hv_virtio_hvcodec_pci(HvVirtioHvcodec *d) { return &d->vio.pci; }

void hv_virtio_hvcodec_destroy(HvVirtioHvcodec *d) {
    if (!d) return;
    pthread_mutex_lock(&d->mu);
    d->stopping = 1;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    for (int i = 0; i < d->workers; i++) pthread_join(d->worker[i], NULL);
    pthread_mutex_lock(&d->mu);
    close_all(d);
    pthread_mutex_unlock(&d->mu);
    for (Req *r = d->free_list, *n; r; r = n) n = r->next, free(r->seg), free(r);
    pthread_mutex_destroy(&d->mu);
    pthread_cond_destroy(&d->cv);
    pthread_cond_destroy(&d->idle_cv);
    free(d);
}

HvVirtioHvcodec *hv_virtio_hvcodec_create(HvMachine *m, HvPcie *bus, const HvHvcodecOps *ops, void *opaque) {
    HvVirtioHvcodec *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    HvVirtio *v = &d->vio;
    hv_virtio_init(v, m, HVCD_DEVICE_ID, 0x048000, 1, HV_VIRTIO_F_INDIRECT_DESC); /* multimedia, other */
    v->dev = d;
    v->notify = notify;
    v->reset = device_reset;
    d->ops = ops, d->opaque = opaque;
    for (int i = 0; i < HVCD_MAX_CONTEXTS; i++) d->slot[i].gen = 1;
    pthread_mutex_init(&d->mu, NULL);
    pthread_cond_init(&d->cv, NULL);
    pthread_cond_init(&d->idle_cv, NULL);
    for (int i = 0; i < WORKERS; i++) {
        if (pthread_create(&d->worker[i], NULL, worker, d) != 0) break;
        d->workers++;
    }
    if (!d->workers) {
        hv_virtio_hvcodec_destroy(d);
        return NULL;
    }
    HvcdConfig cfg = {HVCD_MAGIC, HVCD_VERSION, HVCD_MAX_SEGS, HVCD_MAX_CONTEXTS, HVCD_MAX_MESSAGE, HVCD_MAX_DATA};
    memcpy(v->config, &cfg, sizeof cfg);
    v->config_len = sizeof cfg;
    if (hv_pcie_attach(bus, &v->pci) < 0) {
        hv_virtio_hvcodec_destroy(d);
        return NULL;
    }
    return d;
}
