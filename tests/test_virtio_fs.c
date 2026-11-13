/* The virtio-fs device (devices/virtio_fs.c) on a fake ring in guest RAM: its config, INIT and LOOKUP, a 1 MB READ
   across 64 segments (and the JIT's code for those pages dropped), a chain of 129 segments (refused, and the ring
   still works), FORGET on the high-priority queue, requests that finish out of order on the 4 workers (at most 3 of them in opens), FIFO opens
   that cannot hold a worker, and a reset and a stop that give up on a request stuck in a host call. */
#include "fuse_proto.h"
#include "gicv3.h"
#include "pcie.h"
#include "virtio_fs.h"

#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static int failed;

static void check(const char *what, long long got, long long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %lld, want %lld\n", what, got, want);
    failed = 1;
}

#define RAM 0x40000000ull
#define RAM_SIZE (64ull << 20)
#define QSIZE 256
#define RINGS (RAM + 0x100000) /* desc, avail, used for queue q at RINGS + q * 0x10000 */
#define BUFS (RAM + 0x400000)

static HvMachine m;
static uint8_t *ram;
static HvVirtioFs *dev;
static uint16_t avail_idx[2], used_seen[2];
static uint64_t uniq;

static void *at(uint64_t pa) { return ram + (pa - RAM); }

typedef struct { uint64_t addr; uint32_t len; int write; } Seg;

static uint64_t ring_of(int q) { return RINGS + (uint64_t)q * 0x10000; }

/* One chain, made available and notified; returns its head. */
static uint16_t send(int q, const Seg *s, int n, uint16_t head) {
    uint64_t r = ring_of(q);
    for (int i = 0; i < n; i++) {
        uint8_t *d = at(r + 16u * ((head + i) % QSIZE));
        uint16_t flags = (uint16_t)((s[i].write ? 2 : 0) | (i + 1 < n ? 1 : 0)), next = (uint16_t)((head + i + 1) % QSIZE);
        memcpy(d, &s[i].addr, 8);
        memcpy(d + 8, &s[i].len, 4);
        memcpy(d + 12, &flags, 2);
        memcpy(d + 14, &next, 2);
    }
    uint16_t *avail = at(r + 0x4000);
    avail[2 + avail_idx[q] % QSIZE] = head;
    __atomic_store_n(&avail[1], ++avail_idx[q], __ATOMIC_RELEASE);
    dev->vio.notify(&dev->vio, q);
    return head;
}

/* Used entries since the last call: their heads and lengths, in order. */
static int take_used(int q, uint32_t *ids, uint32_t *lens, int cap) {
    uint8_t *used = at(ring_of(q) + 0x8000);
    uint16_t idx;
    memcpy(&idx, used + 2, 2);
    int n = 0;
    for (; used_seen[q] != idx && n < cap; used_seen[q]++, n++) {
        memcpy(&ids[n], used + 4 + 8u * (used_seen[q] % QSIZE), 4);
        memcpy(&lens[n], used + 8 + 8u * (used_seen[q] % QSIZE), 4);
    }
    return n;
}

/* A request in one readable buffer and a reply in one writable one; the reply's error, or -9999 for none. */
static uint8_t *reply_at;
static int request(uint32_t op, uint64_t node, const void *arg, size_t alen, uint32_t reply_len, uint32_t *used_len) {
    static uint16_t head;
    uint64_t in = BUFS, out = BUFS + 0x10000;
    FuseInHeader h = {(uint32_t)(sizeof h + alen), op, ++uniq, node, 1000, 1000, 1, 0, 0};
    memcpy(at(in), &h, sizeof h);
    memcpy(at(in + sizeof h), arg, alen);
    memset(at(out), 0xee, sizeof(FuseOutHeader) + reply_len);
    Seg s[2] = {{in, (uint32_t)(sizeof h + alen), 0}, {out, (uint32_t)sizeof(FuseOutHeader) + reply_len, 1}};
    send(1, s, 2, head);
    head = (uint16_t)((head + 2) % QSIZE);
    hv_virtio_fs_drain(dev);
    uint32_t id, len;
    if (take_used(1, &id, &len, 1) != 1) return -9999;
    if (used_len) *used_len = len;
    FuseOutHeader o;
    memcpy(&o, at(out), sizeof o);
    reply_at = at(out + sizeof o);
    return o.unique == h.unique ? o.error : -9998;
}

static uint16_t head1 = 128; /* chains below send heads from 128, away from request()'s */

static char base[PATH_MAX];

static void test_config(void) {
    const uint8_t *c = dev->vio.pci.config;
    check("PCI vendor and device", c[0] | c[1] << 8 | c[2] << 16 | (long long)c[3] << 24, 0x105a1af4);
    check("PCI class: mass storage, other", dev->vio.pci.config[0x0b] << 8 | dev->vio.pci.config[0x0a], 0x0180);
    check("tag", !strcmp((char *)dev->vio.config, "henge-files"), 1);
    uint32_t nq;
    memcpy(&nq, dev->vio.config + 36, 4);
    check("one request queue", nq, 1);
    check("two queues", dev->vio.nq, 2);
    check("VERSION_1 only", dev->vio.features, HV_VIRTIO_F_VERSION_1);
}

static void test_init_lookup(uint64_t *big) {
    FuseInitIn in = {7, 41, 1 << 20, 0x7fffffff, 0, {0}};
    check("INIT", request(FUSE_INIT, 0, &in, sizeof in, sizeof(FuseInitOut), NULL), 0);
    FuseInitOut io;
    memcpy(&io, reply_at, sizeof io);
    check("INIT: max_pages", io.max_pages, 64);
    uint32_t len = 0;
    check("LOOKUP a", request(FUSE_LOOKUP, FUSE_ROOT_ID, "a", 2, sizeof(FuseEntryOut), &len), 0);
    check("LOOKUP: the reply's length", len, sizeof(FuseOutHeader) + sizeof(FuseEntryOut));
    FuseEntryOut e;
    memcpy(&e, reply_at, sizeof e);
    check("LOOKUP a: node 3", (long long)e.nodeid, 3);
    check("LOOKUP big", request(FUSE_LOOKUP, 3, "big", 4, sizeof(FuseEntryOut), NULL), 0);
    memcpy(&e, reply_at, sizeof e);
    *big = e.nodeid;
    check("LOOKUP big: 1 MB", (long long)e.attr.size, 1 << 20);
}

/* READ of 1 MB: the header, then 64 pages of 16 KB, as a 16 KB guest kernel lays it out. */
static void test_read_1mb(uint64_t big) {
    FuseOpenIn o = {0, 0};
    check("OPEN big", request(FUSE_OPEN, big, &o, sizeof o, sizeof(FuseOpenOut), NULL), 0);
    FuseOpenOut oo;
    memcpy(&oo, reply_at, sizeof oo);
    uint64_t in = BUFS + 0x20000, hdr = BUFS + 0x21000, data = RAM + 0x1000000;
    FuseInHeader h = {sizeof h + sizeof(FuseReadIn), FUSE_READ, ++uniq, big, 1000, 1000, 1, 0, 0};
    FuseReadIn r = {oo.fh, 0, 1 << 20, 0, 0, 0, 0};
    memcpy(at(in), &h, sizeof h);
    memcpy(at(in + sizeof h), &r, sizeof r);
    Seg s[67];
    s[0] = (Seg){in, sizeof h, 0};
    s[1] = (Seg){in + sizeof h, sizeof r, 0};
    s[2] = (Seg){hdr, sizeof(FuseOutHeader), 1};
    for (int i = 0; i < 64; i++) s[3 + i] = (Seg){data + (uint64_t)i * 2 * 16384, 16384, 1}; /* every other page: no merging */
    memset(at(data), 0, 128u * 16384);
    HvRam *ramr = hv_ram_lookup(&m, RAM);
    uint64_t pg = (data + 5 * 2 * 16384 - RAM) >> 14, spare = (data + 16384 - RAM) >> 14;
    ramr->code_pages[pg] = 1; /* as if the JIT had translated code from the 6th page */
    ramr->code_pages[spare] = 1;
    uint64_t dma = dev->dma_bytes;
    send(1, s, 67, head1);
    head1 = (uint16_t)((head1 + 67) % QSIZE);
    hv_virtio_fs_drain(dev);
    uint32_t id, len;
    check("READ 1 MB: completed", take_used(1, &id, &len, 1), 1);
    check("READ 1 MB: length", len, sizeof(FuseOutHeader) + (1 << 20));
    FuseOutHeader oh;
    memcpy(&oh, at(hdr), sizeof oh);
    check("READ 1 MB: no error", oh.error, 0);
    int ok = 1;
    for (uint32_t i = 0; i < (1u << 20) && ok; i++)
        if (((uint8_t *)at(data + (i / 16384) * 2 * 16384))[i % 16384] != (uint8_t)(i * 7)) ok = 0;
    check("READ 1 MB: the bytes, in 64 pages", ok, 1);
    check("READ 1 MB: the pages between are untouched", ((uint8_t *)at(data + 16384))[0], 0);
    check("READ 1 MB: hv_dma_written dropped the code from a page it wrote", ramr->code_pages[pg], 0);
    check("READ 1 MB: and not from one it did not", ramr->code_pages[spare], 1);
    check("READ 1 MB: guest memory written", (long long)(dev->dma_bytes - dma), sizeof(FuseOutHeader) + (1 << 20));
    check("READ 1 MB: 67 segments seen", dev->largest, 67);
    printf("test_virtio_fs: the largest request had %d of %d segments\n", dev->largest, HV_VIRTQ_MAX_SEGS);
}

/* 129 segments: more than the device takes. It must still complete the chain, and the next request must work. */
static void test_too_many_segments(uint64_t big) {
    uint64_t in = BUFS + 0x30000, hdr = BUFS + 0x31000, data = RAM + 0x1000000;
    FuseInHeader h = {sizeof h + sizeof(FuseReadIn), FUSE_READ, ++uniq, big, 1000, 1000, 1, 0, 0};
    FuseReadIn r = {1, 0, 126 * 4096, 0, 0, 0, 0};
    memcpy(at(in), &h, sizeof h);
    memcpy(at(in + sizeof h), &r, sizeof r);
    Seg s[129];
    s[0] = (Seg){in, sizeof h, 0};
    s[1] = (Seg){in + sizeof h, sizeof r, 0};
    s[2] = (Seg){hdr, sizeof(FuseOutHeader), 1};
    for (int i = 0; i < 126; i++) s[3 + i] = (Seg){data + (uint64_t)i * 4096, 4096, 1};
    uint64_t broken = dev->broken;
    send(1, s, 129, head1);
    head1 = (uint16_t)((head1 + 129) % QSIZE);
    hv_virtio_fs_drain(dev);
    uint32_t id, len;
    check("129 segments: completed", take_used(1, &id, &len, 1), 1);
    check("129 segments: just the header", len, sizeof(FuseOutHeader));
    FuseOutHeader oh;
    memcpy(&oh, at(hdr), sizeof oh);
    check("129 segments: EIO", oh.error, -LX_EIO);
    check("129 segments: its unique", (long long)oh.unique, (long long)h.unique);
    check("129 segments: counted", (long long)(dev->broken - broken), 1);
    check("after it: the ring still works", request(FUSE_GETATTR, big, &(FuseGetattrIn){0}, sizeof(FuseGetattrIn), sizeof(FuseAttrOut), NULL), 0);
}

static void test_forget(uint64_t big) {
    request(FUSE_LOOKUP, 3, "big", 4, sizeof(FuseEntryOut), NULL); /* two lookups now */
    uint64_t in = BUFS + 0x40000;
    FuseInHeader h = {sizeof h + sizeof(FuseForgetIn), FUSE_FORGET, ++uniq, big, 0, 0, 0, 0, 0};
    FuseForgetIn f = {2};
    memcpy(at(in), &h, sizeof h);
    memcpy(at(in + sizeof h), &f, sizeof f);
    Seg s = {in, sizeof h + sizeof f, 0};
    send(0, &s, 1, 0);
    uint32_t id, len;
    check("FORGET: done at notify, on queue 0", take_used(0, &id, &len, 1), 1);
    check("FORGET: no reply", len, 0);
    check("FORGET: the node is gone", request(FUSE_GETATTR, big, &(FuseGetattrIn){0}, sizeof(FuseGetattrIn), sizeof(FuseAttrOut), NULL), -LX_ESTALE);
    /* Anything else on queue 0 is not run there (it could wait on the host's disk). */
    h = (FuseInHeader){sizeof h, FUSE_STATFS, ++uniq, FUSE_ROOT_ID, 0, 0, 0, 0, 0};
    memcpy(at(in), &h, sizeof h);
    Seg s2[2] = {{in, sizeof h, 0}, {BUFS + 0x41000, 256, 1}};
    send(0, s2, 2, 4);
    check("queue 0: another opcode completes", take_used(0, &id, &len, 1), 1);
    check("queue 0: unanswered", len, 0);
}

/* The test hook holds OPENs of hold_node until let go: a host call that takes a long time. */
static pthread_mutex_t hold_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hold_cv = PTHREAD_COND_INITIALIZER;
static uint64_t hold_node;
static int holding, held;

static void before(uint32_t op, uint64_t node) {
    if (op != FUSE_OPEN || node != hold_node) return;
    pthread_mutex_lock(&hold_mu);
    held++;
    pthread_cond_broadcast(&hold_cv);
    while (holding) pthread_cond_wait(&hold_cv, &hold_mu);
    held--;
    pthread_cond_broadcast(&hold_cv);
    pthread_mutex_unlock(&hold_mu);
}

static void hold(uint64_t node) {
    pthread_mutex_lock(&hold_mu);
    hold_node = node, holding = 1;
    pthread_mutex_unlock(&hold_mu);
}

/* Waits until want requests are held (or none are, for 0). */
static int wait_held(int want) {
    pthread_mutex_lock(&hold_mu);
    for (int tries = 0; held != want && tries < 2000; tries++) {
        pthread_mutex_unlock(&hold_mu);
        usleep(1000);
        pthread_mutex_lock(&hold_mu);
    }
    int n = held;
    pthread_mutex_unlock(&hold_mu);
    return n;
}

static void let_go(void) {
    pthread_mutex_lock(&hold_mu);
    holding = 0;
    pthread_cond_broadcast(&hold_cv);
    pthread_mutex_unlock(&hold_mu);
}

/* count chains of one request each on queue 1, from head1: OPEN (O_RDONLY) of node if open, else GETATTR. Each
   reply is 256 bytes at BUFS + 0x50800 + i * 0x1000, filled with 0xee. */
static void send_some(int count, uint64_t node, const int *open, uint16_t *heads) {
    for (int i = 0; i < count; i++) {
        uint64_t in = BUFS + 0x50000 + (uint64_t)i * 0x1000, out = in + 0x800;
        FuseInHeader h = {0, open[i] ? FUSE_OPEN : FUSE_GETATTR, ++uniq, node, 1000, 1000, 1, 0, 0};
        FuseOpenIn o = {0, 0};
        FuseGetattrIn g = {0};
        h.len = sizeof h + (open[i] ? sizeof o : sizeof g);
        memcpy(at(in), &h, sizeof h);
        memcpy(at(in + sizeof h), open[i] ? (void *)&o : (void *)&g, open[i] ? sizeof o : sizeof g);
        memset(at(out), 0xee, 256);
        Seg sg[2] = {{in, h.len, 0}, {out, 256, 1}};
        heads[i] = send(1, sg, 2, (uint16_t)(head1 + 2 * i));
    }
    head1 = (uint16_t)((head1 + 2 * count) % QSIZE);
}

static uint64_t locked(const uint64_t *v) {
    pthread_mutex_lock(&dev->mu);
    uint64_t n = *v;
    pthread_mutex_unlock(&dev->mu);
    return n;
}

static long long in_flight(void) {
    pthread_mutex_lock(&dev->mu);
    long long n = dev->submitted - dev->completed;
    pthread_mutex_unlock(&dev->mu);
    return n;
}

/* Polls for up to ms until want completions are in. */
static int collect(uint32_t *ids, uint32_t *lens, int want, int ms) {
    int got = 0;
    for (int tries = 0; tries < ms && got < want; tries++) {
        hv_virtio_fs_poll(dev);
        got += take_used(1, ids + got, lens + got, want - got);
        if (got < want) usleep(1000);
    }
    return got;
}

static int is_head(uint32_t id, const uint16_t *heads, int n) {
    for (int i = 0; i < n; i++)
        if (id == heads[i]) return 1;
    return 0;
}

/* Four opens that wait: three hold three workers, the fourth waits for one of them, and the GETATTRs behind them
   finish on the fourth worker first. */
static void test_order(uint64_t big) {
    hold(big);
    uint16_t heads[7];
    static const int open[7] = {1, 1, 1, 1, 0, 0, 0};
    send_some(7, big, open, heads);
    uint32_t ids[8], lens[8];
    check("order: three opens held", wait_held(3), 3);
    int got = collect(ids, lens, 3, 2000);
    check("order: the three GETATTRs finish while the opens wait", got, 3);
    int later = 1;
    for (int i = 0; i < got; i++)
        if (is_head(ids[i], heads, 4)) later = 0;
    check("order: none of them is an open", later, 1);
    check("order: four requests still in flight", in_flight(), 4);
    usleep(20000);
    check("order: the fourth open is not on a worker", wait_held(3), 3);
    let_go();
    hv_virtio_fs_drain(dev);
    got = take_used(1, ids, lens, 8);
    check("order: then the opens finish", got, 4);
    int opens = 0;
    for (int i = 0; i < got; i++) opens += is_head(ids[i], heads, 4);
    check("order: they are the opens", opens, 4);
    for (int i = 0; i < 4; i++) { /* the guest would release them */
        FuseOpenOut oo;
        memcpy(&oo, (uint8_t *)at(BUFS + 0x50800 + (uint64_t)i * 0x1000) + sizeof(FuseOutHeader), sizeof oo);
        FuseReleaseIn rl = {oo.fh, 0, 0, 0};
        request(FUSE_RELEASE, big, &rl, sizeof rl, 0, NULL);
    }
}

/* Five opens of a FIFO with no writer, more than there are workers: each is refused at once, so the folder still
   answers. */
static void test_fifo(void) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/a/fifo", base);
    mkfifo(p, 0644);
    check("LOOKUP fifo", request(FUSE_LOOKUP, 3, "fifo", 5, sizeof(FuseEntryOut), NULL), 0);
    FuseEntryOut e;
    memcpy(&e, reply_at, sizeof e);
    uint16_t heads[6];
    static const int open[6] = {1, 1, 1, 1, 1, 0};
    send_some(6, e.nodeid, open, heads);
    uint32_t ids[8], lens[8];
    check("FIFO: all six answer with no writer", collect(ids, lens, 6, 2000), 6);
    int enxio = 0;
    for (int i = 0; i < 5; i++) {
        FuseOutHeader oh;
        memcpy(&oh, at(BUFS + 0x50800 + (uint64_t)i * 0x1000), sizeof oh);
        enxio += oh.error == -LX_ENXIO;
    }
    check("FIFO: the opens are ENXIO", enxio, 5);
    check("FIFO: then a LOOKUP", request(FUSE_LOOKUP, 3, "big", 4, sizeof(FuseEntryOut), NULL), 0);
}

/* A reset with a request stuck in a host call: the reset gives up after the drain time, the late reply writes
   nothing, and the device works after it. */
static void test_reset_stuck(uint64_t *big) {
    check("LOOKUP big", request(FUSE_LOOKUP, 3, "big", 4, sizeof(FuseEntryOut), NULL), 0);
    FuseEntryOut e;
    memcpy(&e, reply_at, sizeof e);
    *big = e.nodeid;
    hold(*big);
    uint16_t heads[1];
    static const int open[1] = {1};
    send_some(1, *big, open, heads);
    check("reset: an open held", wait_held(1), 1);
    dev->drain_ms = 50;
    uint64_t dropped = locked(&dev->dropped);
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    dev->vio.reset(&dev->vio);
    gettimeofday(&t1, NULL);
    long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;
    check("reset: gives up in about the drain time", ms >= 40 && ms < 1000, 1);
    let_go();
    check("reset: the held open ends", wait_held(0), 0);
    for (int tries = 0; tries < 2000 && locked(&dev->dropped) == dropped; tries++) usleep(1000);
    check("reset: its reply is dropped", (long long)(locked(&dev->dropped) - dropped), 1);
    uint32_t ids[2], lens[2];
    hv_virtio_fs_poll(dev);
    check("reset: and never in the used ring", take_used(1, ids, lens, 2), 0);
    check("reset: nor in guest memory", *(uint8_t *)at(BUFS + 0x50800), 0xee);
    FuseInitIn in = {7, 41, 1 << 20, 0x7fffffff, 0, {0}};
    check("reset: INIT again", request(FUSE_INIT, 0, &in, sizeof in, sizeof(FuseInitOut), NULL), 0);
    check("reset: LOOKUP again", request(FUSE_LOOKUP, 3, "big", 4, sizeof(FuseEntryOut), NULL), 0);
    memcpy(&e, reply_at, sizeof e);
    *big = e.nodeid;
    dev->drain_ms = 0;
}

/* The machine stops with a request stuck: destroy gives up on it and leaves the device to that worker, which
   frees it when the call ends. */
static void test_stop_stuck(uint64_t big) {
    hold(big);
    uint16_t heads[1];
    static const int open[1] = {1};
    send_some(1, big, open, heads);
    check("stop: an open held", wait_held(1), 1);
    dev->drain_ms = 50;
    check("stop: destroy leaves the device", hv_virtio_fs_destroy(dev), 0);
    dev = NULL;
    let_go();
    check("stop: the held open ends", wait_held(0), 0);
    usleep(50000); /* the worker frees the device */
}

int main(void) {
    snprintf(base, sizeof base, "/tmp/henge-vfs-XXXXXX");
    if (!mkdtemp(base)) return 1;
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/a", base);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/a/big", base);
    FILE *fp = fopen(p, "wb");
    for (uint32_t i = 0; fp && i < (1u << 20); i++) fputc((uint8_t)(i * 7), fp);
    if (fp) fclose(fp);
    snprintf(p, sizeof p, "%s/a", base);
    check("folder", hv_fs_folder_set(0, NULL, "a", p, HV_FS_RW), 0);

    if (hv_machine_init(&m, 1 << 20) != 0) return 1;
    ram = calloc(1, RAM_SIZE);
    hv_machine_add_ram(&m, RAM, RAM_SIZE, ram, 0);
    HvGic *gic = hv_gicv3_create(&m, 0x08000000, 0x080a0000);
    HvPcie *bus = hv_pcie_create(&m, gic, 0x3f000000, 0x01000000, 0x10000000, 0x2eff0000, 35, 1);
    dev = hv_virtio_fs_create(&m, bus);
    check("created", dev != NULL, 1);
    if (!dev) return 1;
    HvVirtio *v = &dev->vio;
    for (int q = 0; q < 2; q++)
        v->q[q] = (HvVirtq){.size = QSIZE, .enabled = 1, .desc = ring_of(q), .avail = ring_of(q) + 0x4000, .used = ring_of(q) + 0x8000};
    v->driver_features = HV_VIRTIO_F_VERSION_1;
    v->status = 1 | 2 | 8 | 4;

    uint64_t big = 0;
    test_config();
    test_init_lookup(&big);
    test_read_1mb(big);
    test_too_many_segments(big);
    test_forget(big);
    hv_fs_test_hook(before);
    test_reset_stuck(&big);
    test_order(big);
    test_fifo();
    test_stop_stuck(big);
    hv_fs_test_hook(NULL);
    hv_fs_folders_clear();
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", base);
    system(cmd);
    if (!failed) printf("test_virtio_fs: ok\n");
    return failed;
}
