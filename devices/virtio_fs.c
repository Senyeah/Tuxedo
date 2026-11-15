#include "virtio_fs.h"
#include "fuse_proto.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#define Q_HIPRIO 0
#define Q_REQUEST 1

static int logging(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_FILES_LOG") != NULL;
    return on;
}

/* The element's buffers as host memory: the request (readable) and the reply (writable). 0, or -1 for a buffer
   outside guest RAM. */
static int map(HvVirtio *v, const HvVirtqElem *e, struct iovec *in, int *nin, struct iovec *out, int *nout) {
    *nin = *nout = 0;
    for (int s = 0; s < e->nseg; s++) {
        const HvVirtqSeg *g = &e->seg[s];
        void *p = g->len ? hv_phys_ptr(v->m, g->addr, g->len) : NULL;
        if (g->len && !p) return -1;
        if (g->write) out[(*nout)++] = (struct iovec){p, g->len};
        else in[(*nin)++] = (struct iovec){p, g->len};
    }
    return 0;
}

/* The reply's bytes went into guest pages: drop the JIT's code for them, or a program run from the folder can run
   what was in those pages before. */
static void written(HvVirtioFs *f, const HvVirtqElem *e, uint32_t len) {
    __atomic_fetch_add(&f->dma_bytes, len, __ATOMIC_RELAXED);
    for (int s = 0; s < e->nseg && len; s++) {
        const HvVirtqSeg *g = &e->seg[s];
        if (!g->write) continue;
        uint32_t n = g->len < len ? g->len : len;
        hv_dma_written(f->vio.m, g->addr, n);
        len -= n;
    }
}

/* Worker thread, or the CPU thread for queue 0. The bytes of the reply that can hold new data. */
static uint32_t run(HvVirtioFs *f, const HvVirtqElem *e, HvFsCall *call, uint32_t *n) {
    struct iovec in[HV_VIRTQ_MAX_SEGS], out[HV_VIRTQ_MAX_SEGS];
    int nin, nout;
    *n = 0;
    if (map(&f->vio, e, in, &nin, out, &nout) != 0) return 0;
    *n = (uint32_t)hv_fs_call(f->fs, in, nin, out, nout, call);
    return call && call->touched > *n ? (uint32_t)call->touched : *n;
}

static void device_free(HvVirtioFs *f) {
    hv_fs_destroy(f->fs);
    pthread_mutex_destroy(&f->mu);
    pthread_cond_destroy(&f->cv);
    pthread_cond_destroy(&f->idle);
    free(f->ring);
    free(f);
}

/* An open can wait for a download from the provider, so at most HV_VFS_OPENS of them run at once: one worker
   is always free for the rest. */
static int is_open(const HvVfsReq *r) { return r->opcode == FUSE_OPEN || r->opcode == FUSE_CREATE; }

/* Under mu: the next request a worker can run, or NULL. */
static HvVfsReq *next(HvVirtioFs *f) {
    if (f->ndeferred && f->opening < HV_VFS_OPENS) {
        HvVfsReq *r = &f->ring[f->deferred[f->deferred_at++ % HV_VFS_RING]];
        f->ndeferred--;
        return r;
    }
    while (f->claimed != f->submitted) {
        uint32_t slot = f->claimed++ % HV_VFS_RING;
        HvVfsReq *r = &f->ring[slot];
        if (!is_open(r) || f->opening < HV_VFS_OPENS) return r;
        f->deferred[(f->deferred_at + f->ndeferred++) % HV_VFS_RING] = slot;
    }
    return NULL;
}

static void *worker(void *opaque) {
    HvVfsWorker *w = opaque;
    pthread_setname_np("tux-fs");
    HvVirtioFs *f = w->f;
    HvVirtqElem e;
    pthread_mutex_lock(&f->mu);
    for (;;) {
        HvVfsReq *r = NULL;
        while (!f->stopping && !(r = next(f))) pthread_cond_wait(&f->cv, &f->mu);
        if (f->stopping) break;
        e = r->e; /* a reset that gives up on this request can hand the slot to another */
        int open = is_open(r);
        f->opening += open;
        HvFsCall call = {&f->epoch, f->epoch, 0};
        pthread_mutex_unlock(&f->mu);
        uint32_t n, dirty = run(f, &e, &call, &n);
        /* Under mu, so a stop that gave up has freed nothing this touches: the machine, for one. */
        pthread_mutex_lock(&f->mu);
        if (open) {
            f->opening--;
            if (f->ndeferred) pthread_cond_signal(&f->cv);
        }
        if (f->stopping) {
            f->dropped++;
        } else if (f->epoch != call.mine) { /* a reset gave up on it: drop the reply, but a read may have landed */
            f->dropped++;
            written(f, &e, (uint32_t)hv_virtq_writable(&e));
        } else {
            if (dirty) written(f, &e, dirty);
            r->written = n;
            r->done = 1;
            f->completed++;
            hv_machine_wake(f->vio.m);
        }
        pthread_cond_broadcast(&f->idle);
    }
    w->exited = 1;
    int last = f->abandoned;
    for (int i = 0; i < HV_VFS_WORKERS; i++) last = last && (!f->worker[i].started || f->worker[i].exited);
    pthread_cond_broadcast(&f->idle);
    pthread_mutex_unlock(&f->mu);
    if (last) device_free(f);
    return NULL;
}

/* A chain this model cannot follow (more than HV_VIRTQ_MAX_SEGS segments, or outside RAM) is already taken from
   the ring: it still completes, with EIO when its first buffers hold a header and room for the reply's. */
static void fail_broken(HvVirtioFs *f, int q, HvVirtqElem *e) {
    f->broken++;
    fprintf(stderr, "virtio-fs: broken request chain (%d segments seen), failing it\n", e->nseg);
    uint32_t len = 0;
    FuseInHeader h;
    if (hv_virtq_read(&f->vio, e, 0, &h, sizeof h) == sizeof h && hv_virtq_writable(e) >= sizeof(FuseOutHeader)) {
        FuseOutHeader o = {sizeof o, -LX_EIO, h.unique};
        len = hv_virtq_write(&f->vio, e, 0, &o, sizeof o);
        written(f, e, len);
    }
    hv_virtq_push(&f->vio, q, e, len);
    hv_virtio_interrupt(&f->vio);
}

static void count_segs(HvVirtioFs *f, const HvVirtqElem *e) {
    if (e->nseg <= f->largest) return;
    f->largest = e->nseg;
    if (logging()) fprintf(stderr, "virtio-fs: largest request so far: %d segments\n", e->nseg);
}

/* CPU thread. Queue 0 is answered here: FORGET and INTERRUPT take a lock and no I/O, and nothing else is
   taken there, so a guest cannot stall its own CPU with a slow request on it. */
static void hiprio(HvVirtioFs *f) {
    HvVirtqElem e;
    int any = 0;
    for (int got; (got = hv_virtq_pop(&f->vio, Q_HIPRIO, &e)) != 0;) {
        if (got < 0) {
            fail_broken(f, Q_HIPRIO, &e);
            continue;
        }
        FuseInHeader h = {0};
        hv_virtq_read(&f->vio, &e, 0, &h, sizeof h);
        uint32_t n = 0;
        if (h.opcode == FUSE_FORGET || h.opcode == FUSE_BATCH_FORGET || h.opcode == FUSE_INTERRUPT) {
            uint32_t dirty = run(f, &e, NULL, &n);
            if (dirty) written(f, &e, dirty);
        } else if (logging()) fprintf(stderr, "virtio-fs: opcode %u on the high-priority queue ignored\n", h.opcode);
        hv_virtq_push(&f->vio, Q_HIPRIO, &e, n);
        any = 1;
    }
    if (any) hv_virtio_interrupt(&f->vio);
}

static void notify(HvVirtio *v, int q) {
    HvVirtioFs *f = v->dev;
    if (q == Q_HIPRIO) {
        hiprio(f);
        return;
    }
    int any = 0;
    while (f->submitted - f->published < HV_VFS_RING) {
        HvVfsReq *r = &f->ring[f->submitted % HV_VFS_RING];
        int got = hv_virtq_pop(v, q, &r->e);
        if (got == 0) break;
        if (got < 0) {
            fail_broken(f, q, &r->e);
            continue;
        }
        count_segs(f, &r->e);
        FuseInHeader h = {0};
        hv_virtq_read(v, &r->e, 0, &h, sizeof h);
        pthread_mutex_lock(&f->mu);
        r->opcode = h.opcode;
        f->submitted++;
        pthread_mutex_unlock(&f->mu);
        any = 1;
    }
    if (any) pthread_cond_broadcast(&f->cv);
}

/* CPU thread: hand finished requests back in the order they finished; a slot is reused once it and every slot
   before it are back. */
void hv_virtio_fs_poll(HvVirtioFs *f) {
    if (!f) return;
    int any = 0;
    pthread_mutex_lock(&f->mu);
    for (uint32_t i = f->published; i != f->submitted; i++) {
        HvVfsReq *r = &f->ring[i % HV_VFS_RING];
        if (r->pushed || !r->done) continue;
        hv_virtq_push(&f->vio, Q_REQUEST, &r->e, r->written);
        r->pushed = 1;
        f->requests++;
        any = 1;
    }
    while (f->published != f->submitted && f->ring[f->published % HV_VFS_RING].pushed) {
        HvVfsReq *r = &f->ring[f->published % HV_VFS_RING];
        r->pushed = 0;
        r->done = 0;
        f->published++;
    }
    pthread_mutex_unlock(&f->mu);
    if (!any) return;
    hv_virtio_interrupt(&f->vio);
    if (f->vio.status & 4) notify(&f->vio, Q_REQUEST); /* requests that waited for room in the ring */
}

static struct timespec after_ms(int ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec t = {now.tv_sec + ms / 1000, (long)now.tv_usec * 1000 + (long)(ms % 1000) * 1000000};
    if (t.tv_nsec >= 1000000000) t.tv_sec++, t.tv_nsec -= 1000000000;
    return t;
}

static int drain_ms(const HvVirtioFs *f) { return f->drain_ms > 0 ? f->drain_ms : HV_VFS_DRAIN_MS; }

void hv_virtio_fs_drain(HvVirtioFs *f) {
    pthread_mutex_lock(&f->mu);
    while (f->completed != f->submitted) pthread_cond_wait(&f->idle, &f->mu);
    pthread_mutex_unlock(&f->mu);
    hv_virtio_fs_poll(f);
}

/* The driver reset the device: the requests in flight finish (they write guest memory), their completions are
   dropped with the queues, and the server forgets the old mount. A request still running at the drain time (a
   host call that hangs) is given up, so the vCPU, which waits here, does not freeze. */
static void device_reset(HvVirtio *v) {
    HvVirtioFs *f = v->dev;
    if (!f) return;
    struct timespec until = after_ms(drain_ms(f));
    pthread_mutex_lock(&f->mu);
    int rc = 0;
    while (f->completed != f->submitted && rc != ETIMEDOUT) rc = pthread_cond_timedwait(&f->idle, &f->mu, &until);
    if (f->completed != f->submitted)
        fprintf(stderr, "virtio-fs: reset: %u requests still running after %d ms; dropped\n", f->submitted - f->completed, drain_ms(f));
    __atomic_store_n(&f->epoch, f->epoch + 1, __ATOMIC_RELEASE);
    f->claimed = f->completed = f->submitted; /* ones no worker took never run */
    f->ndeferred = 0;
    for (uint32_t i = f->published; i != f->submitted; i++) {
        HvVfsReq *r = &f->ring[i % HV_VFS_RING];
        r->pushed = 0;
        r->done = 0;
    }
    f->published = f->submitted;
    pthread_mutex_unlock(&f->mu);
    hv_fs_reset(f->fs);
}

int hv_virtio_fs_stop(HvVirtioFs *f) {
    if (!f) return 1;
    struct timespec until = after_ms(drain_ms(f));
    pthread_mutex_lock(&f->mu);
    if (!f->stopping) {
        int rc = 0;
        while (f->completed != f->submitted && rc != ETIMEDOUT) rc = pthread_cond_timedwait(&f->idle, &f->mu, &until);
        f->stopping = 1;
        __atomic_store_n(&f->epoch, f->epoch + 1, __ATOMIC_RELEASE);
        pthread_cond_broadcast(&f->cv);
    }
    int rc = 0, all = 1;
    for (;;) {
        all = 1;
        for (int i = 0; i < HV_VFS_WORKERS; i++) all = all && (!f->worker[i].started || f->worker[i].exited);
        if (all || rc == ETIMEDOUT) break;
        rc = pthread_cond_timedwait(&f->idle, &f->mu, &until);
    }
    for (int i = 0; i < HV_VFS_WORKERS; i++) {
        HvVfsWorker *w = &f->worker[i];
        if (!w->started || w->gone) continue;
        w->gone = 1;
        if (!w->exited) {
            pthread_detach(w->t); /* stuck in a host call: it frees the device itself if it is the last */
            continue;
        }
        pthread_mutex_unlock(&f->mu);
        pthread_join(w->t, NULL);
        pthread_mutex_lock(&f->mu);
    }
    if (!all) fprintf(stderr, "virtio-fs: stop: a worker is stuck in a host call after %d ms; left to finish\n", drain_ms(f));
    pthread_mutex_unlock(&f->mu);
    return all;
}

int hv_virtio_fs_destroy(HvVirtioFs *f) {
    if (!f) return 1;
    hv_virtio_fs_stop(f);
    pthread_mutex_lock(&f->mu);
    int all = 1;
    for (int i = 0; i < HV_VFS_WORKERS; i++) all = all && (!f->worker[i].started || f->worker[i].exited);
    if (!all) f->abandoned = 1;
    pthread_mutex_unlock(&f->mu);
    if (all) device_free(f);
    return all;
}

HvVirtioFs *hv_virtio_fs_create(HvMachine *m, HvPcie *bus) {
    HvVirtioFs *f = calloc(1, sizeof *f);
    if (!f) return NULL;
    HvVirtio *v = &f->vio;
    hv_virtio_init(v, m, 26, 0x018000, 2, 0); /* mass storage, other: as QEMU's vhost-user-fs-pci */
    v->dev = f;
    v->notify = notify;
    v->reset = device_reset;
    pthread_mutex_init(&f->mu, NULL);
    pthread_cond_init(&f->cv, NULL);
    pthread_cond_init(&f->idle, NULL);
    f->ring = calloc(HV_VFS_RING, sizeof *f->ring);
    f->fs = hv_fs_create();
    if (!f->ring || !f->fs) {
        hv_virtio_fs_destroy(f);
        return NULL;
    }
    int started = 0;
    for (int i = 0; i < HV_VFS_WORKERS; i++) {
        HvVfsWorker *w = &f->worker[i];
        w->f = f;
        pthread_mutex_lock(&f->mu);
        w->started = pthread_create(&w->t, NULL, worker, w) == 0;
        pthread_mutex_unlock(&f->mu);
        if (!w->started) break;
        started++;
    }
    if (!started) {
        hv_virtio_fs_destroy(f);
        return NULL;
    }
    uint32_t queues = 1;
    memset(v->config, 0, 36);
    memcpy(v->config, HV_FS_TAG, sizeof HV_FS_TAG - 1); /* tag[36], NUL-padded */
    memcpy(v->config + 36, &queues, 4);                 /* num_request_queues */
    v->config_len = 40;
    hv_pcie_attach(bus, &v->pci);
    return f;
}
