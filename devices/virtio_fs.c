#include "virtio_fs.h"
#include "fuse_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* Worker thread, or the CPU thread for queue 0. */
static uint32_t run(HvVirtioFs *f, HvVirtqElem *e) {
    struct iovec in[HV_VIRTQ_MAX_SEGS], out[HV_VIRTQ_MAX_SEGS];
    int nin, nout;
    if (map(&f->vio, e, in, &nin, out, &nout) != 0) return 0;
    uint32_t n = (uint32_t)hv_fs_handle(f->fs, in, nin, out, nout);
    if (n) written(f, e, n);
    return n;
}

static void *worker(void *opaque) {
    HvVirtioFs *f = opaque;
    for (;;) {
        pthread_mutex_lock(&f->mu);
        while (f->claimed == __atomic_load_n(&f->submitted, __ATOMIC_ACQUIRE)) {
            if (f->stopping) {
                pthread_mutex_unlock(&f->mu);
                return NULL;
            }
            pthread_cond_wait(&f->cv, &f->mu);
        }
        HvVfsReq *r = &f->ring[f->claimed++ % HV_VFS_RING];
        pthread_mutex_unlock(&f->mu);
        r->written = run(f, &r->e);
        __atomic_store_n(&r->done, 1, __ATOMIC_RELEASE);
        __atomic_add_fetch(&f->completed, 1, __ATOMIC_RELEASE);
        hv_machine_wake(f->vio.m);
    }
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
        if (h.opcode == FUSE_FORGET || h.opcode == FUSE_BATCH_FORGET || h.opcode == FUSE_INTERRUPT) n = run(f, &e);
        else if (logging()) fprintf(stderr, "virtio-fs: opcode %u on the high-priority queue ignored\n", h.opcode);
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
        pthread_mutex_lock(&f->mu);
        __atomic_store_n(&f->submitted, f->submitted + 1, __ATOMIC_RELEASE);
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
    for (uint32_t i = f->published; i != f->submitted; i++) {
        HvVfsReq *r = &f->ring[i % HV_VFS_RING];
        if (r->pushed || !__atomic_load_n(&r->done, __ATOMIC_ACQUIRE)) continue;
        hv_virtq_push(&f->vio, Q_REQUEST, &r->e, r->written);
        r->pushed = 1;
        f->requests++;
        any = 1;
    }
    while (f->published != f->submitted && f->ring[f->published % HV_VFS_RING].pushed) {
        HvVfsReq *r = &f->ring[f->published % HV_VFS_RING];
        r->pushed = 0;
        __atomic_store_n(&r->done, 0, __ATOMIC_RELAXED);
        f->published++;
    }
    if (!any) return;
    hv_virtio_interrupt(&f->vio);
    if (f->vio.status & 4) notify(&f->vio, Q_REQUEST); /* requests that waited for room in the ring */
}

static void wait_done(HvVirtioFs *f) {
    while (__atomic_load_n(&f->completed, __ATOMIC_ACQUIRE) != f->submitted) usleep(100);
}

void hv_virtio_fs_drain(HvVirtioFs *f) {
    wait_done(f);
    hv_virtio_fs_poll(f);
}

/* The driver reset the device: the requests in flight finish (they write guest memory), their completions are
   dropped with the queues, and the server forgets the old mount. */
static void device_reset(HvVirtio *v) {
    HvVirtioFs *f = v->dev;
    if (!f) return;
    if (f->workers_started) wait_done(f);
    for (uint32_t i = f->published; i != f->submitted; i++) {
        HvVfsReq *r = &f->ring[i % HV_VFS_RING];
        r->pushed = 0;
        __atomic_store_n(&r->done, 0, __ATOMIC_RELAXED);
    }
    f->published = f->submitted;
    hv_fs_reset(f->fs);
}

void hv_virtio_fs_stop(HvVirtioFs *f) {
    if (!f) return;
    pthread_mutex_lock(&f->mu);
    f->stopping = 1;
    pthread_cond_broadcast(&f->cv);
    pthread_mutex_unlock(&f->mu);
    for (int i = 0; i < f->workers_started; i++) pthread_join(f->worker[i], NULL);
    f->workers_started = 0;
}

void hv_virtio_fs_destroy(HvVirtioFs *f) {
    if (!f) return;
    hv_virtio_fs_stop(f);
    hv_fs_destroy(f->fs);
    pthread_mutex_destroy(&f->mu);
    pthread_cond_destroy(&f->cv);
    free(f->ring);
    free(f);
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
    f->ring = calloc(HV_VFS_RING, sizeof *f->ring);
    f->fs = hv_fs_create();
    if (!f->ring || !f->fs) {
        hv_virtio_fs_destroy(f);
        return NULL;
    }
    for (int i = 0; i < HV_VFS_WORKERS; i++) {
        if (pthread_create(&f->worker[i], NULL, worker, f) != 0) break;
        f->workers_started++;
    }
    if (!f->workers_started) {
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
