#include "virtio_blk.h"

#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define F_SEG_MAX (1ull << 2)
#define F_RO (1ull << 5)
#define F_BLK_SIZE (1ull << 6)
#define F_FLUSH (1ull << 9)
#define F_DISCARD (1ull << 13)

#define T_IN 0
#define T_OUT 1
#define T_FLUSH 4
#define T_GET_ID 8
#define T_DISCARD 11

#define S_OK 0
#define S_IOERR 1
#define S_UNSUPP 2

#define DISCARD_MAX_SEGS 32
#define DISCARD_MAX_SECTORS (4u << 20) /* 2 GiB per segment */

/* Disk I/O straight between the file and the guest's buffers: the
   segments of one direction, skipping `off` bytes of them, `len` bytes in all.
   Returns 0, or -1 on a host error or a buffer outside guest RAM. */
static int seg_io(HvVirtioBlk *b, const HvVirtqElem *e, int writable, uint32_t off, uint64_t disk_off, uint32_t len) {
    for (int s = 0; s < e->nseg && len; s++) {
        const HvVirtqSeg *g = &e->seg[s];
        if (g->write != writable) continue;
        if (off >= g->len) {
            off -= g->len;
            continue;
        }
        uint32_t n = g->len - off;
        if (n > len) n = len;
        void *p = hv_phys_ptr(b->vio.m, g->addr + off, n);
        if (!p) return -1;
        int r = writable ? hv_disk_read(b->disk, disk_off, p, n) : hv_disk_write(b->disk, disk_off, p, n);
        if (writable && r == 0) hv_dma_written(b->vio.m, g->addr + off, n);
        if (r != 0) return -1;
        disk_off += n;
        len -= n;
        off = 0;
    }
    return len ? -1 : 0;
}

static uint32_t readable(const HvVirtqElem *e) {
    uint32_t n = 0;
    for (int s = 0; s < e->nseg; s++)
        if (!e->seg[s].write) n += e->seg[s].len;
    return n;
}

/* Worker thread. */
static int handle(HvVirtioBlk *b, HvVirtqElem *e, uint32_t *written) {
    HvVirtio *v = &b->vio;
    struct { uint32_t type, reserved; uint64_t sector; } hdr;
    uint32_t wlen = hv_virtq_writable(e);
    *written = 0;
    if (wlen < 1 || hv_virtq_read(v, e, 0, &hdr, sizeof hdr) != sizeof hdr) return -1;
    uint32_t data = wlen - 1; /* the status byte is the last writable one */
    uint8_t status = S_OK;
    switch (hdr.type) {
    case T_IN:
        if (seg_io(b, e, 1, 0, hdr.sector * 512, data) != 0) status = S_IOERR;
        else *written = data;
        break;
    case T_OUT: {
        uint32_t rlen = readable(e);
        if (rlen < sizeof hdr || seg_io(b, e, 0, sizeof hdr, hdr.sector * 512, rlen - (uint32_t)sizeof hdr) != 0)
            status = S_IOERR;
        break;
    }
    case T_FLUSH:
        if (hv_disk_flush(b->disk) != 0) status = S_IOERR;
        break;
    case T_GET_ID: {
        char id[20] = "hengevm-disk";
        uint32_t n = data < 20 ? data : 20;
        hv_virtq_write(v, e, 0, id, n);
        *written = n;
        break;
    }
    case T_DISCARD: {
        struct { uint64_t sector; uint32_t num, flags; } seg[DISCARD_MAX_SEGS];
        uint32_t rlen = readable(e), n = rlen > sizeof hdr ? (rlen - (uint32_t)sizeof hdr) / (uint32_t)sizeof seg[0] : 0;
        if (!(b->vio.features & F_DISCARD)) status = S_UNSUPP;
        else if (!n || n > DISCARD_MAX_SEGS || (rlen - sizeof hdr) % sizeof seg[0] ||
                 hv_virtq_read(v, e, sizeof hdr, seg, n * (uint32_t)sizeof seg[0]) != n * sizeof seg[0]) status = S_IOERR;
        for (uint32_t i = 0; status == S_OK && i < n; i++) {
            if (seg[i].flags) status = S_UNSUPP; /* the unmap bit is for write-zeroes only */
            else if (seg[i].num > DISCARD_MAX_SECTORS || seg[i].sector > b->disk->size / 512 ||
                     seg[i].num > b->disk->size / 512 - seg[i].sector ||
                     hv_disk_discard(b->disk, seg[i].sector * 512, (uint64_t)seg[i].num * 512) != 0) status = S_IOERR;
            else __atomic_fetch_add(&b->discarded, (uint64_t)seg[i].num * 512, __ATOMIC_RELAXED);
        }
        break;
    }
    default:
        status = S_UNSUPP;
        break;
    }
    if (status != S_OK) {
        __atomic_fetch_add(&b->errors, 1, __ATOMIC_RELAXED);
        static int reported;
        if (reported++ < 20)
            fprintf(stderr, "virtio-blk %s: request type %#x sector %llu (%u bytes) -> status %u\n", b->disk->offset ? "aux" : "root",
                    hdr.type, (unsigned long long)hdr.sector, data, status);
    }
    hv_virtq_write(v, e, data, &status, 1);
    *written += 1;
    return 0;
}

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

/* Workers take requests in order and run them in parallel; a flush first
   waits for every request before it to finish, and nothing after it starts
   until it is done. */
static void *worker(void *opaque) {
    HvVirtioBlk *b = opaque;
    /* HV_BLK_STATS: requests, bytes, flushes and how busy this worker was, every 10 s. */
    int stats = getenv("HV_BLK_STATS") != NULL;
    uint64_t every = stats && atoi(getenv("HV_BLK_STATS")) > 0 ? (uint64_t)atoi(getenv("HV_BLK_STATS")) * 1000000 : 10000000;
    uint64_t t_last = now_us(), busy = 0, reqs = 0, bytes = 0, flushes = 0, flush_us = 0;
    for (;;) {
        pthread_mutex_lock(&b->mu);
        while (b->fence || b->claimed == __atomic_load_n(&b->submitted, __ATOMIC_ACQUIRE)) {
            if (b->stopping && !b->fence && b->claimed == b->submitted) {
                pthread_mutex_unlock(&b->mu);
                return NULL;
            }
            pthread_cond_wait(&b->cv, &b->mu);
        }
        HvVblkReq *r = &b->ring[b->claimed % HV_VBLK_RING];
        uint32_t type = 0;
        hv_virtq_read(&b->vio, &r->e, 0, &type, 4);
        int fence = type == T_FLUSH;
        b->claimed++;
        if (fence) {
            b->fence = 1;
            while (b->inflight) pthread_cond_wait(&b->done_cv, &b->mu);
        }
        b->inflight++;
        pthread_mutex_unlock(&b->mu);

        uint64_t t0 = stats ? now_us() : 0;
        if (handle(b, &r->e, &r->written) != 0) r->written = 0;
        if (stats) {
            uint64_t t1 = now_us();
            busy += t1 - t0, reqs++, bytes += r->written > 1 ? r->written : readable(&r->e);
            if (type == T_FLUSH) flushes++, flush_us += t1 - t0;
            if (t1 - t_last > every) {
                fprintf(stderr, "virtio-blk %s worker: %.0f req/s %.1f MB/s, %.0f flushes/s (%.1f ms each), busy %.0f%%\n",
                        b->disk->offset ? "aux" : "root", reqs * 1e6 / every, bytes * 1e6 / every / (1 << 20), flushes * 1e6 / every,
                        flushes ? flush_us / 1000.0 / flushes : 0.0, busy * 100.0 / every);
                t_last = t1, busy = reqs = bytes = flushes = flush_us = 0;
            }
        }

        pthread_mutex_lock(&b->mu);
        __atomic_store_n(&r->done, 1, __ATOMIC_RELEASE);
        b->inflight--;
        if (fence) b->fence = 0;
        __atomic_add_fetch(&b->completed, 1, __ATOMIC_RELEASE);
        pthread_cond_broadcast(&b->done_cv);
        if (fence) pthread_cond_broadcast(&b->cv);
        pthread_mutex_unlock(&b->mu);
        hv_machine_wake(b->vio.m);
    }
    return NULL;
}

/* CPU thread: hand everything the driver made available to the worker, while the ring has room. */
static void notify(HvVirtio *v, int q) {
    HvVirtioBlk *b = v->dev;
    int any = 0;
    while (b->submitted - b->published < HV_VBLK_RING) {
        HvVblkReq *r = &b->ring[b->submitted % HV_VBLK_RING];
        int got = hv_virtq_pop(v, q, &r->e);
        if (got < 0) {
            /* A chain this model cannot follow (too many segments, or outside
               RAM): it is already taken from the ring, so it must still be
               completed, or the guest loses that request slot for good. */
            fprintf(stderr, "virtio-blk: broken request chain (%d segments seen), failing it\n", r->e.nseg);
            uint8_t st = S_IOERR;
            if (hv_virtq_writable(&r->e)) hv_virtq_write(v, &r->e, hv_virtq_writable(&r->e) - 1, &st, 1);
            hv_virtq_push(v, q, &r->e, 1);
            hv_virtio_interrupt(v);
            continue;
        }
        if (got == 0) break;
        r->q = q;
        pthread_mutex_lock(&b->mu);
        __atomic_store_n(&b->submitted, b->submitted + 1, __ATOMIC_RELEASE);
        pthread_mutex_unlock(&b->mu);
        any = 1;
    }
    if (any) pthread_cond_broadcast(&b->cv);
}

void hv_virtio_blk_drain(HvVirtioBlk *b) {
    while (__atomic_load_n(&b->completed, __ATOMIC_ACQUIRE) != b->submitted) usleep(100);
    hv_virtio_blk_poll(b);
}

void hv_virtio_blk_stop(HvVirtioBlk *b) {
    if (!b) return;
    pthread_mutex_lock(&b->mu);
    b->stopping = 1;
    pthread_cond_broadcast(&b->cv);
    pthread_mutex_unlock(&b->mu);
    for (int i = 0; i < b->workers_started; i++) pthread_join(b->worker[i], NULL);
    b->workers_started = 0;
}

void hv_virtio_blk_destroy(HvVirtioBlk *b) {
    if (!b) return;
    hv_virtio_blk_stop(b);
    pthread_mutex_destroy(&b->mu);
    pthread_cond_destroy(&b->cv);
    pthread_cond_destroy(&b->done_cv);
    free(b->ring);
    free(b);
}

/* The driver reset the device: let the requests in flight finish (they write guest memory) and drop their
   completions, which belong to queues that are gone. */
static void device_reset(HvVirtio *v) {
    HvVirtioBlk *b = v->dev;
    if (!b) return;
    while (__atomic_load_n(&b->completed, __ATOMIC_ACQUIRE) != b->submitted) usleep(100);
    for (uint32_t i = b->published; i != b->submitted; i++) {
        HvVblkReq *r = &b->ring[i % HV_VBLK_RING];
        r->pushed = 0;
        __atomic_store_n(&r->done, 0, __ATOMIC_RELAXED);
    }
    b->published = b->submitted;
}

/* CPU thread: hand finished requests back, in whatever order they finished;
   a slot is reused once it and every slot before it are back. */
void hv_virtio_blk_poll(HvVirtioBlk *b) {
    if (!b) return;
    int q = -1;
    for (uint32_t i = b->published; i != b->submitted; i++) {
        HvVblkReq *r = &b->ring[i % HV_VBLK_RING];
        if (r->pushed || !__atomic_load_n(&r->done, __ATOMIC_ACQUIRE)) continue;
        hv_virtq_push(&b->vio, r->q, &r->e, r->written);
        r->pushed = 1;
        q = r->q;
        b->requests++;
    }
    while (b->published != b->submitted && b->ring[b->published % HV_VBLK_RING].pushed) {
        HvVblkReq *r = &b->ring[b->published % HV_VBLK_RING];
        r->pushed = 0;
        __atomic_store_n(&r->done, 0, __ATOMIC_RELAXED);
        b->published++;
    }
    if (q < 0) return;
    hv_virtio_interrupt(&b->vio);
    notify(&b->vio, q); /* requests that waited for room in the ring */
}

HvVirtioBlk *hv_virtio_blk_create(HvMachine *m, HvPcie *bus, HvDisk *disk) {
    HvVirtioBlk *b = calloc(1, sizeof *b);
    if (!b) return NULL;
    HvVirtio *v = &b->vio;
    int can_discard = !disk->readonly && disk->hole;
    hv_virtio_init(v, m, 2, 0x010000, 1, F_SEG_MAX | F_BLK_SIZE | F_FLUSH | (disk->readonly ? F_RO : 0) |
                    (can_discard ? F_DISCARD : 0));
    v->dev = b;
    v->notify = notify;
    v->reset = device_reset;
    b->disk = disk;
    b->ring = calloc(HV_VBLK_RING, sizeof *b->ring);
    pthread_mutex_init(&b->mu, NULL);
    pthread_cond_init(&b->cv, NULL);
    pthread_cond_init(&b->done_cv, NULL);
    if (!b->ring) { hv_virtio_blk_destroy(b); return NULL; }
    for (int i = 0; i < HV_VBLK_WORKERS; i++) {
        if (pthread_create(&b->worker[i], NULL, worker, b) != 0) break;
        b->workers_started++;
    }
    if (!b->workers_started) { hv_virtio_blk_destroy(b); return NULL; }
    uint64_t capacity = disk->size / 512;
    /* One descriptor per segment from the 256 in the queue, and no indirect tables: 8 leaves the ring room. */
    uint32_t seg_max = getenv("HV_BLK_SEG_MAX") ? (uint32_t)atoi(getenv("HV_BLK_SEG_MAX")) : 8;
    if (seg_max < 1 || seg_max > HV_VIRTQ_MAX_SEGS - 2) seg_max = 8;
    uint32_t blk_size = 512;
    uint16_t num_queues = 1;
    memcpy(v->config + 0, &capacity, 8);
    memcpy(v->config + 12, &seg_max, 4);
    memcpy(v->config + 20, &blk_size, 4);
    memcpy(v->config + 34, &num_queues, 2);
    if (can_discard) {
        uint32_t max_sectors = DISCARD_MAX_SECTORS, max_segs = DISCARD_MAX_SEGS, align = disk->hole / 512;
        memcpy(v->config + 36, &max_sectors, 4);
        memcpy(v->config + 40, &max_segs, 4);
        memcpy(v->config + 44, &align, 4);
    }
    v->config_len = 96;
    hv_pcie_attach(bus, &v->pci);
    return b;
}
