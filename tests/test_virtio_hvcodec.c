/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The hvcodec DMA device (devices/virtio_hvcodec.c) on the virt board, driven as the tux_codec module drives it,
   with a test backend in place of host/vcodec.m: enumeration and config, contexts, direct and indirect chains,
   chains far past HV_VIRTQ_MAX_SEGS, data both ways, a reply larger than its buffer (REST), contexts that do not wait
   for each other, a reset, and the requests a guest must not be able to hurt the host with. */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "virt.h"

static int checks, failures;
static void check(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %llx, expected %llx\n", what, (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

static HvMachine m;
static HvCpu cpus[1];
static HvVirt b;

static uint32_t rd32(uint64_t pa) {
    uint32_t v = 0;
    hv_phys_read(&m, pa, &v, 4);
    return v;
}
static uint8_t rd8(uint64_t pa) {
    uint8_t v = 0;
    hv_phys_read(&m, pa, &v, 1);
    return v;
}
static void wr32(uint64_t pa, uint32_t v) { hv_phys_write(&m, pa, &v, 4); }
static void wr16(uint64_t pa, uint16_t v) { hv_phys_write(&m, pa, &v, 2); }
static void wr8(uint64_t pa, uint8_t v) { hv_phys_write(&m, pa, &v, 1); }
static void wr64(uint64_t pa, uint64_t v) { hv_phys_write(&m, pa, &v, 8); }
static uint8_t *ram(uint64_t pa) { return hv_phys_ptr(&m, pa, 1); }

/* ---- the test backend ---- */

static int opens, closes, refuse_open;
static pthread_mutex_t be_mu = PTHREAD_MUTEX_INITIALIZER;
static volatile int slow_running;

typedef struct { int id; } BeCtx;

static void *be_open(void *opaque) {
    (void)opaque;
    if (refuse_open) return NULL;
    BeCtx *c = calloc(1, sizeof *c);
    pthread_mutex_lock(&be_mu);
    c->id = ++opens;
    pthread_mutex_unlock(&be_mu);
    return c;
}

static void be_close(void *opaque, void *ctx) {
    (void)opaque;
    pthread_mutex_lock(&be_mu);
    closes++;
    pthread_mutex_unlock(&be_mu);
    free(ctx);
}

/* The first byte says what to do: E echo, U sum the in data, D fill the out data, B a reply of n bytes, X a
   message that cannot be parsed, W wait 300 ms then echo. */
static int be_message(void *opaque, void *ctx, HvHvcodecIo *io) {
    (void)opaque, (void)ctx;
    uint8_t msg[64];
    uint32_t n = io->msg_len < sizeof msg ? io->msg_len : sizeof msg;
    if (io->read(io, 0, msg, n) != n || !n) return -1;
    switch (msg[0]) {
    case 'W':
        slow_running = 1;
        usleep(300000);
        slow_running = 0;
        /* fall through */
    case 'E': {
        struct iovec v = {msg, n};
        return io->reply(io, &v, 1);
    }
    case 'U': {
        uint64_t sum = 0, segs = (uint64_t)io->nin;
        for (int i = 0; i < io->nin; i++)
            for (size_t k = 0; k < io->in[i].iov_len; k++) sum += ((uint8_t *)io->in[i].iov_base)[k];
        uint64_t r[3] = {sum, io->in_len, segs};
        struct iovec v = {r, sizeof r};
        return io->reply(io, &v, 1);
    }
    case 'D': {
        HvIovCursor c;
        hv_iov_cursor(&c, io->out, io->nout);
        uint8_t row[1000];
        for (uint64_t off = 0; off < io->out_len; off += sizeof row) {
            uint64_t k = io->out_len - off < sizeof row ? io->out_len - off : sizeof row;
            for (uint64_t i = 0; i < k; i++) row[i] = (uint8_t)((off + i) * 7 + 3);
            if (hv_iov_copy(&c, off, row, k, 1) != k) return -1;
        }
        struct iovec v = {"ok", 2};
        return io->reply(io, &v, 1);
    }
    case 'B': {
        uint32_t len;
        memcpy(&len, msg + 4, 4);
        uint8_t *big = malloc(len);
        for (uint32_t i = 0; i < len; i++) big[i] = (uint8_t)(i * 13 + 1);
        /* two parts, as vcodec.m's header and payload */
        struct iovec v[2] = {{big, 100}, {big + 100, len - 100}};
        int rc = io->reply(io, v, 2);
        free(big);
        return rc;
    }
    default:
        return -1;
    }
}

static const HvHvcodecOps be_ops = {be_open, be_close, be_message};

/* ---- a small driver, as tux_codec does it ---- */

#define RING (VIRT_MEM + 0x100000)
#define HDR (VIRT_MEM + 0x200000)
#define RESP (VIRT_MEM + 0x201000)
#define TABLE (VIRT_MEM + 0x300000) /* up to 64K indirect entries */
#define MSG (VIRT_MEM + 0x1000000)
#define IN (VIRT_MEM + 0x2000000)
#define REPLY (VIRT_MEM + 0x4000000)
#define OUT (VIRT_MEM + 0x5000000)
#define QSIZE 16
static uint64_t bar;
static int slot = -1;

static void put_desc(uint64_t table, int i, uint64_t addr, uint32_t len, uint16_t flags, uint16_t next) {
    uint8_t *d = ram(table + 16u * i);
    memcpy(d, &addr, 8);
    memcpy(d + 8, &len, 4);
    memcpy(d + 12, &flags, 2);
    memcpy(d + 14, &next, 2);
}

static uint16_t avail_head;
static void offer(uint16_t head) {
    uint16_t *avail = (uint16_t *)ram(RING + 0x1000);
    avail[2 + avail[1] % QSIZE] = head;
    avail[1]++;
}
static uint16_t used_idx(void) { return ((uint16_t *)ram(RING + 0x2000))[1]; }
static uint32_t used_len_of(uint16_t idx) {
    uint32_t len;
    memcpy(&len, ram(RING + 0x2000 + 4 + 8u * (idx % QSIZE) + 4), 4);
    return len;
}

typedef struct {
    int nd;
    uint64_t addr[70000];
    uint32_t len[70000];
    uint16_t flags[70000];
} Chain;
static Chain ch;

static void add(uint64_t addr, uint64_t len, uint32_t chunk, int write) {
    for (uint64_t off = 0; off < len || (!len && off == 0); off += chunk) {
        uint64_t k = len - off < chunk ? len - off : chunk;
        if (!len) break;
        ch.addr[ch.nd] = addr + off, ch.len[ch.nd] = (uint32_t)k, ch.flags[ch.nd] = write ? 2 : 0;
        ch.nd++;
    }
}

/* A request: the header, msg_len bytes at MSG, in_len at IN, then the response, reply_cap at REPLY and out_len at OUT,
   each split into chunk-byte segments. Indirect puts the chain in one table. Returns the used ring index it will get. */
static void build(HvcdReq h, uint32_t chunk) {
    ch.nd = 0;
    memcpy(ram(HDR), &h, sizeof h);
    add(HDR, sizeof h, chunk, 0);
    add(MSG, h.msg_len, chunk, 0);
    add(IN, h.in_len, chunk, 0);
    memset(ram(RESP), 0xee, sizeof(HvcdResp));
    add(RESP, sizeof(HvcdResp), chunk, 1);
    add(REPLY, h.reply_cap, chunk, 1);
    add(OUT, h.out_len, chunk, 1);
}

static void submit(int indirect) {
    uint16_t head = avail_head;
    if (indirect) {
        for (int i = 0; i < ch.nd; i++)
            put_desc(TABLE, i, ch.addr[i], ch.len[i], ch.flags[i] | (i + 1 < ch.nd ? 1 : 0), (uint16_t)(i + 1));
        put_desc(RING, head, TABLE, (uint32_t)(16 * ch.nd), 4, 0);
        avail_head = (avail_head + 1) % QSIZE;
    } else {
        for (int i = 0; i < ch.nd; i++) {
            uint16_t d = (head + i) % QSIZE;
            put_desc(RING, d, ch.addr[i], ch.len[i], ch.flags[i] | (i + 1 < ch.nd ? 1 : 0), (head + i + 1) % QSIZE);
        }
        avail_head = (avail_head + ch.nd) % QSIZE;
    }
    offer(head);
    wr16(bar + 0x3000, 0);
}

static HvcdResp resp(void) {
    HvcdResp r;
    memcpy(&r, ram(RESP), sizeof r);
    return r;
}

static HvcdResp call(HvcdReq h, uint32_t chunk, int indirect) {
    uint16_t before = used_idx();
    build(h, chunk);
    submit(indirect);
    hv_virtio_hvcodec_drain(b.codec);
    check("the request came back", used_idx(), (uint16_t)(before + 1));
    return resp();
}

static uint32_t open_ctx(void) {
    HvcdResp r = call((HvcdReq){.op = HVCD_OP_OPEN}, 4096, 0);
    check("OPEN", (uint32_t)r.status, HVCD_S_OK);
    return r.ctx;
}

static HvcdResp msg(uint32_t ctx, const char *m, uint32_t len, uint32_t reply_cap) {
    memset(ram(MSG), 0, 64);
    memcpy(ram(MSG), m, strlen(m));
    return call((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = len, .reply_cap = reply_cap}, 4096, 1);
}

static void setup(void) {
    for (int s = 0; s < 32; s++)
        if (rd32(VIRT_PCIE_ECAM + ((uint64_t)s << 15)) == ((0x1040u + HVCD_DEVICE_ID) << 16 | 0x1af4)) slot = s;
    check("the device is on the bus", slot >= 0, 1);
    if (slot < 0) exit(1);
    check("after every other device", slot, b.touch->vio.pci.slot + 1);
    uint64_t cfg = VIRT_PCIE_ECAM + ((uint64_t)slot << 15);
    check("class: multimedia, other", rd32(cfg + 8) >> 8, 0x048000);
    check("subsystem id is the virtio type", rd32(cfg + 0x2c) >> 16, HVCD_DEVICE_ID);
    bar = VIRT_PCIE_MMIO + 0x1000000;
    wr32(cfg + 0x20, (uint32_t)bar);
    wr32(cfg + 0x24, 0);
    wr16(cfg + 0x04, 0x6);
    wr8(bar + 0x14, 0);
    wr8(bar + 0x14, 1 | 2);
    wr32(bar + 0x00, 0);
    check("indirect descriptors offered", rd32(bar + 0x04) >> 28 & 1, 1);
    wr32(bar + 0x00, 1);
    check("VERSION_1 offered", rd32(bar + 0x04) & 1, 1);
    check("one queue", rd32(bar + 0x12) & 0xffff, 1);
    check("config magic", rd32(bar + 0x2000), HVCD_MAGIC);
    check("config version", rd32(bar + 0x2004), HVCD_VERSION);
    check("config max_segs", rd32(bar + 0x2008), HVCD_MAX_SEGS);
    check("config max_contexts", rd32(bar + 0x200c), HVCD_MAX_CONTEXTS);
    wr32(bar + 0x08, 0);
    wr32(bar + 0x0c, 1u << 28);
    wr32(bar + 0x08, 1);
    wr32(bar + 0x0c, 1);
    wr8(bar + 0x14, 1 | 2 | 8);
    memset(ram(RING), 0, 0x4000);
    wr16(bar + 0x16, 0);
    wr16(bar + 0x18, QSIZE);
    wr64(bar + 0x20, RING);
    wr64(bar + 0x28, RING + 0x1000);
    wr64(bar + 0x30, RING + 0x2000);
    wr16(bar + 0x1c, 1);
    wr8(bar + 0x14, 1 | 2 | 8 | 4);
    avail_head = 0;
}

static void test_data(uint32_t ctx) {
    /* echo on a direct chain, and on an indirect one */
    memcpy(ram(MSG), "Ehello", 6);
    HvcdResp r = call((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 6, .reply_cap = 64}, 4096, 0);
    check("echo direct: status", (uint32_t)r.status, HVCD_S_OK);
    check("echo direct: reply length", r.reply_len, 6);
    check("echo direct: reply", memcmp(ram(REPLY), "Ehello", 6), 0);
    check("used length: response and reply", used_len_of((uint16_t)(used_idx() - 1)), 16 + 6);
    r = msg(ctx, "Eabc", 4, 64);
    check("echo indirect", r.status == HVCD_S_OK && r.reply_len == 4 && !memcmp(ram(REPLY), "Eabc", 4), 1);

    /* 4 MiB up, in 1 KiB segments: 4100 descriptors in one chain */
    uint32_t in_len = 4u << 20;
    uint64_t want = 0;
    for (uint32_t i = 0; i < in_len; i++) ram(IN)[i] = (uint8_t)(i * 31 + 5), want += ram(IN)[i];
    memcpy(ram(MSG), "U", 1);
    r = call((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 1, .in_len = in_len, .reply_cap = 24}, 1024, 1);
    uint64_t got[3];
    memcpy(got, ram(REPLY), sizeof got);
    check("upload in 4097 segments: status", (uint32_t)r.status, HVCD_S_OK);
    check("upload: the sum of the bytes", got[0], want);
    check("upload: in_len", got[1], in_len);
    check("upload: one host view for each segment", got[2], 4096);

    /* 3 MiB down, in 4 KiB segments, and a segment that is not on a page boundary */
    uint32_t out_len = 3u << 20;
    memset(ram(OUT), 0, out_len);
    memcpy(ram(MSG), "D", 1);
    r = call((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 1, .reply_cap = 8, .out_len = out_len}, 3000, 1);
    int good = r.status == HVCD_S_OK && r.reply_len == 2;
    for (uint32_t i = 0; i < out_len && good; i++) good = ram(OUT)[i] == (uint8_t)(i * 7 + 3);
    check("download in 1049 segments: every byte", good, 1);
    check("used length counts the data", used_len_of((uint16_t)(used_idx() - 1)), 16 + 8 + out_len);
}

static void test_rest(uint32_t ctx) {
    uint32_t len = 100000;
    memcpy(ram(MSG), "B\0\0\0", 4);
    memcpy(ram(MSG) + 4, &len, 4);
    HvcdResp r = call((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 8, .reply_cap = 4096}, 4096, 1);
    check("big reply: first part", r.status == HVCD_S_OK && r.reply_len == 4096 && r.reply_total == len, 1);
    HvVirtioHvcodecStats st;
    hv_virtio_hvcodec_stats(b.codec, &st);
    check("the rest waits on the host", st.pending_bytes, len - 4096);
    static uint8_t whole[100000];
    memcpy(whole, ram(REPLY), 4096);
    uint32_t at = 4096, rounds = 0;
    while (at < len && rounds++ < 100) {
        r = call((HvcdReq){.op = HVCD_OP_REST, .ctx = ctx, .reply_cap = 30000}, 4096, 1);
        if (r.status != HVCD_S_OK || r.reply_total != len - at || !r.reply_len) break;
        memcpy(whole + at, ram(REPLY), r.reply_len);
        at += r.reply_len;
    }
    int good = at == len;
    for (uint32_t i = 0; i < len && good; i++) good = whole[i] == (uint8_t)(i * 13 + 1);
    check("REST: the whole reply, in order", good, 1);
    hv_virtio_hvcodec_stats(b.codec, &st);
    check("REST: nothing left on the host", st.pending_bytes, 0);
    r = call((HvcdReq){.op = HVCD_OP_REST, .ctx = ctx, .reply_cap = 30000}, 4096, 1);
    check("REST with nothing left", r.status == HVCD_S_OK && r.reply_len == 0 && r.reply_total == 0, 1);
    /* a new message drops what is left */
    r = call((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 8, .reply_cap = 4096}, 4096, 1);
    msg(ctx, "Ex", 2, 64);
    hv_virtio_hvcodec_stats(b.codec, &st);
    check("another message drops the rest", st.pending_bytes, 0);
}

static uint32_t broken_now(void) {
    HvVirtioHvcodecStats st;
    hv_virtio_hvcodec_stats(b.codec, &st);
    return (uint32_t)st.broken_chains;
}

static void test_refusals(uint32_t ctx) {
    HvcdResp r = msg(ctx ^ 0x100, "Ex", 2, 64);
    check("a context of another generation", (uint32_t)r.status, HVCD_S_NOCTX);
    r = msg(7, "Ex", 2, 64);
    check("a context never opened", (uint32_t)r.status, HVCD_S_NOCTX);
    /* lengths that do not agree with the chain */
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 2, .reply_cap = 64}, 4096);
    HvcdReq h = {.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 3, .reply_cap = 64};
    memcpy(ram(HDR), &h, sizeof h);
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("msg_len longer than the chain", (uint32_t)resp().status, HVCD_S_INVAL);
    r = call((HvcdReq){.op = HVCD_OP_OPEN, .msg_len = 4}, 4096, 1);
    check("OPEN with a message", (uint32_t)r.status, HVCD_S_INVAL);
    r = call((HvcdReq){.op = 99, .ctx = ctx}, 4096, 1);
    check("an unknown op", (uint32_t)r.status, HVCD_S_INVAL);
    /* data outside guest RAM */
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 1, .in_len = 4096, .reply_cap = 24}, 4096);
    memcpy(ram(MSG), "U", 1);
    ch.addr[2] = VIRT_MEM + b.mem.size - 1024; /* runs off the end of RAM */
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("data that runs past RAM", (uint32_t)resp().status, HVCD_S_FAULT);
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 1, .in_len = 4096, .reply_cap = 24}, 4096);
    ch.addr[2] = VIRT_PCIE_ECAM; /* device memory */
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("data in device memory", (uint32_t)resp().status, HVCD_S_FAULT);

    /* chains the device cannot follow come back with nothing written */
    uint16_t before = used_idx();
    uint32_t broken = broken_now();
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 2, .reply_cap = 64}, 4096);
    for (int i = 0; i < ch.nd; i++) put_desc(TABLE, i, ch.addr[i], ch.len[i], ch.flags[i] | (i + 1 < ch.nd ? 1 : 0), (uint16_t)(i + 1));
    put_desc(TABLE, 1, TABLE + 0x10000, 32, 4, 0); /* an indirect inside a table */
    put_desc(RING, avail_head, TABLE, 16u * ch.nd, 4, 0);
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    put_desc(RING, avail_head, TABLE, 16u * ch.nd, 4 | 1, (avail_head + 1) % QSIZE); /* indirect with NEXT */
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    put_desc(RING, avail_head, TABLE, 17, 4, 0); /* not a whole number of descriptors */
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    for (int i = 0; i < 4; i++) put_desc(TABLE, i, HDR, 32, 1, (uint16_t)((i + 1) % 4)); /* a loop */
    put_desc(RING, avail_head, TABLE, 16u * 4, 4, 0);
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    for (uint32_t i = 0; i <= HVCD_MAX_SEGS; i++) put_desc(TABLE, (int)i, HDR, 32, 1, (uint16_t)(i + 1));
    put_desc(RING, avail_head, TABLE, 16u * (HVCD_MAX_SEGS + 1), 4, 0); /* one more than max_segs */
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    put_desc(RING, avail_head, VIRT_MEM + b.mem.size, 64, 4, 0); /* a table outside RAM */
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    hv_virtio_hvcodec_drain(b.codec);
    check("six broken chains, each given back", used_idx(), (uint16_t)(before + 6));
    check("each counted", broken_now() - broken, 6);
    int zero = 1;
    for (int i = 0; i < 6; i++) zero &= used_len_of((uint16_t)(before + i)) == 0;
    check("with nothing written", zero, 1);
    /* a response buffer too small to answer in */
    before = used_idx();
    ch.nd = 0;
    h = (HvcdReq){.op = HVCD_OP_OPEN};
    memcpy(ram(HDR), &h, sizeof h);
    add(HDR, sizeof h, 4096, 0);
    add(RESP, 8, 4096, 1);
    submit(0);
    hv_virtio_hvcodec_drain(b.codec);
    check("no room for a response: back, empty", used_idx() == (uint16_t)(before + 1) && used_len_of(before) == 0, 1);
    check("and no context was made", opens, 1);
    /* a header or a response in 1-byte segments: more host views than the device keeps for them */
    before = used_idx();
    ch.nd = 0;
    h = (HvcdReq){.op = HVCD_OP_OPEN};
    memcpy(ram(HDR), &h, sizeof h);
    add(HDR, sizeof h, 1, 0);
    memset(ram(RESP), 0xee, sizeof(HvcdResp));
    add(RESP, sizeof(HvcdResp), 4096, 1);
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("a header in 32 segments: refused", used_idx() == (uint16_t)(before + 1) && resp().status == HVCD_S_INVAL, 1);
    ch.nd = 0;
    add(HDR, sizeof h, 4096, 0);
    memset(ram(RESP), 0xee, sizeof(HvcdResp));
    add(RESP, sizeof(HvcdResp), 1, 1);
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("a response in 16 segments: back, empty", used_idx() == (uint16_t)(before + 2) && used_len_of((uint16_t)(before + 1)) == 0, 1);
    check("with the response not written", rd8(RESP) == 0xee && rd8(RESP + 15) == 0xee, 1);
    check("and still no context", opens, 1);
    /* writable segments on the read-only flash */
    uint8_t flash[64];
    memcpy(flash, ram(VIRT_FLASH1), sizeof flash);
    before = used_idx();
    build((HvcdReq){.op = HVCD_OP_OPEN}, 4096);
    ch.addr[1] = VIRT_FLASH1; /* the response */
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("a response on flash: back, empty", used_idx() == (uint16_t)(before + 1) && used_len_of(before) == 0, 1);
    memcpy(ram(MSG), "Ex", 2);
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = ctx, .msg_len = 2, .reply_cap = 64}, 4096);
    ch.addr[3] = VIRT_FLASH1; /* the reply */
    submit(1);
    hv_virtio_hvcodec_drain(b.codec);
    check("a reply on flash", (uint32_t)resp().status, HVCD_S_FAULT);
    check("the flash is not changed", memcmp(ram(VIRT_FLASH1), flash, sizeof flash), 0);
    check("still no context", opens, 1);
    msg(ctx, "Estill", 6, 64);
    check("the context still works after all that", memcmp(ram(REPLY), "Estill", 6), 0);
}

typedef struct {
    uint32_t ctx;
} Slow;

static void test_contexts(uint32_t first) {
    /* a protocol error closes its context only */
    uint32_t c2 = open_ctx();
    HvcdResp r = msg(c2, "X", 1, 64);
    check("a message the backend cannot parse", (uint32_t)r.status, HVCD_S_CLOSED);
    check("closes the backend's context", closes, 1);
    r = msg(c2, "Ex", 2, 64);
    check("the closed context refuses the next", (uint32_t)r.status, HVCD_S_CLOSED);
    r = call((HvcdReq){.op = HVCD_OP_CLOSE, .ctx = c2}, 4096, 1);
    check("CLOSE of a closed context", (uint32_t)r.status, HVCD_S_OK);
    check("no second close in the backend", closes, 1);
    r = msg(c2, "Ex", 2, 64);
    check("the id is dead after CLOSE", (uint32_t)r.status, HVCD_S_NOCTX);
    r = msg(first, "Ef", 2, 64);
    check("the first context is not affected", r.status == HVCD_S_OK && !memcmp(ram(REPLY), "Ef", 2), 1);

    /* eight at most, and the backend can refuse */
    uint32_t ids[HVCD_MAX_CONTEXTS];
    int n = 1;
    for (; n < HVCD_MAX_CONTEXTS; n++) ids[n] = open_ctx();
    r = call((HvcdReq){.op = HVCD_OP_OPEN}, 4096, 1);
    check("a ninth context", (uint32_t)r.status, HVCD_S_LIMIT);
    for (int i = 1; i < HVCD_MAX_CONTEXTS; i++) call((HvcdReq){.op = HVCD_OP_CLOSE, .ctx = ids[i]}, 4096, 1);
    refuse_open = 1;
    r = call((HvcdReq){.op = HVCD_OP_OPEN}, 4096, 1);
    check("the backend at its limit", (uint32_t)r.status, HVCD_S_LIMIT);
    refuse_open = 0;

    /* one context's wait does not hold up another's */
    uint32_t slow = open_ctx(), fast = open_ctx();
    memset(ram(MSG), 0, 64);
    memcpy(ram(MSG), "W", 1);
    uint16_t before = used_idx();
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = slow, .msg_len = 2, .reply_cap = 64}, 4096);
    submit(1);
    while (!slow_running) usleep(1000);
    /* the second request's header and response live elsewhere */
    HvcdReq h = {.op = HVCD_OP_MSG, .ctx = fast, .msg_len = 2, .reply_cap = 64};
    memcpy(ram(HDR + 0x800), &h, sizeof h);
    memcpy(ram(MSG + 0x100), "Eq", 2);
    put_desc(TABLE + 0x80000, 0, HDR + 0x800, 32, 1, 1);
    put_desc(TABLE + 0x80000, 1, MSG + 0x100, 2, 1, 2);
    put_desc(TABLE + 0x80000, 2, RESP + 0x800, 16, 2 | 1, 3);
    put_desc(TABLE + 0x80000, 3, REPLY + 0x10000, 64, 2, 0);
    put_desc(RING, avail_head, TABLE + 0x80000, 64, 4, 0);
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    for (int i = 0; i < 2000 && used_idx() == before; i++) usleep(1000), hv_virtio_hvcodec_poll(b.codec);
    check("the fast context finished while the slow one waits", slow_running && used_idx() == (uint16_t)(before + 1), 1);
    check("its reply", memcmp(ram(REPLY + 0x10000), "Eq", 2), 0);
    hv_virtio_hvcodec_drain(b.codec);
    check("then the slow one", used_idx(), (uint16_t)(before + 2));
    /* two requests on one context run in order, never together */
    before = used_idx();
    memcpy(ram(MSG), "W", 1);
    build((HvcdReq){.op = HVCD_OP_MSG, .ctx = slow, .msg_len = 2, .reply_cap = 64}, 4096);
    submit(1);
    while (!slow_running) usleep(1000);
    h.ctx = slow;
    memcpy(ram(HDR + 0x800), &h, sizeof h);
    put_desc(RING, avail_head, TABLE + 0x80000, 64, 4, 0);
    offer(avail_head), avail_head = (avail_head + 1) % QSIZE;
    wr16(bar + 0x3000, 0);
    usleep(100000);
    hv_virtio_hvcodec_poll(b.codec);
    check("a second request on a busy context waits", used_idx(), before);
    hv_virtio_hvcodec_drain(b.codec);
    check("and runs after", used_idx(), (uint16_t)(before + 2));
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setenv("HV_NO_SOUND", "1", 1);
    if (hv_machine_init(&m, 1 << 20) != 0 || hv_virt_create(&b, &m, cpus, 1, 256ull << 20, NULL, NULL, 0) != 0) return 1;
    int present = 0;
    for (int s = 0; s < 32; s++) present |= rd32(VIRT_PCIE_ECAM + ((uint64_t)s << 15)) == ((0x1040u + HVCD_DEVICE_ID) << 16 | 0x1af4);
    check("no device unless asked for", present, 0);
    check("add the device", hv_virt_add_hvcodec(&b, &be_ops, NULL), 0);
    check("only one", hv_virt_add_hvcodec(&b, &be_ops, NULL), (uint64_t)-1);
    hv_virt_load_firmware(&b, "/nonexistent"); /* maps the read-only flash, then finds no file */
    check("the flash is mapped", ram(VIRT_FLASH1) != NULL, 1);
    setup();
    uint32_t ctx = open_ctx();
    check("a context id has a generation", ctx >> 8 != 0, 1);
    test_data(ctx);
    rd8(bar + 0x1000);
    test_rest(ctx);
    test_refusals(ctx);
    int closed = closes;
    test_contexts(ctx);
    (void)closed;
    /* a reset closes every context the guest left open */
    wr8(bar + 0x14, 0);
    check("a reset closes every context", opens, closes);
    setup();
    ctx = open_ctx();
    check("a context after the reset", msg(ctx, "Ez", 2, 64).status, HVCD_S_OK);
    hv_virt_destroy(&b);
    check("destroy closes the rest", opens, closes);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
