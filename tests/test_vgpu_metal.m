#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "vgpu_metal.h"
#include "virt.h"

/* The virtio GPU's presenter on an offscreen layer: pixels through the control queue to a
   snapshot and to the drawable, dirty rectangles, formats, the cursor, the 60 Hz cap, layer
   changes, and teardown with work in flight. */
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

static uint64_t GPU_CFG; /* the slot depends on which devices the board has */
#define GPU_BAR (VIRT_PCIE_MMIO + 0x100000)
#define GPU_RING (VIRT_MEM + 0x100000)
#define GPU_REQ (VIRT_MEM + 0x200000)
#define GPU_ENTRIES (VIRT_MEM + 0x208000)
#define GPU_RESP (VIRT_MEM + 0x210000)
#define FB1 (VIRT_MEM + 0x400000)
#define FB2 (VIRT_MEM + 0x500000)
#define FB3 (VIRT_MEM + 0x600000)
#define FBC (VIRT_MEM + 0x700000)
enum { OK = 0x1100 };

static uint8_t *ram(uint64_t pa) { return hv_phys_ptr(&m, pa, 1); }
static uint32_t rd32(uint64_t pa) { uint32_t v = 0; hv_phys_read(&m, pa, &v, 4); return v; }
static void wr8(uint64_t pa, uint8_t v) { hv_phys_write(&m, pa, &v, 1); }
static void wr16(uint64_t pa, uint16_t v) { hv_phys_write(&m, pa, &v, 2); }
static void wr32(uint64_t pa, uint32_t v) { hv_phys_write(&m, pa, &v, 4); }
static void wr64(uint64_t pa, uint64_t v) { hv_phys_write(&m, pa, &v, 8); }

static void gpu_setup(void) {
    GPU_CFG = 0;
    for (uint64_t s = 0; s < 32 && !GPU_CFG; s++)
        if (rd32(VIRT_PCIE_ECAM + (s << 15)) == 0x10501af4) GPU_CFG = VIRT_PCIE_ECAM + (s << 15);
    wr32(GPU_CFG + 0x20, (uint32_t)GPU_BAR);
    wr32(GPU_CFG + 0x24, 0);
    wr16(GPU_CFG + 0x04, 0x6);
    wr8(GPU_BAR + 0x14, 0);
    wr8(GPU_BAR + 0x14, 1 | 2);
    wr32(GPU_BAR + 0x08, 1);
    wr32(GPU_BAR + 0x0c, 1);
    wr8(GPU_BAR + 0x14, 1 | 2 | 8);
    for (int q = 0; q < 2; q++) {
        uint64_t qr = GPU_RING + (uint64_t)q * 0x4000;
        memset(ram(qr), 0, 0x4000);
        wr16(GPU_BAR + 0x16, (uint16_t)q);
        wr16(GPU_BAR + 0x18, 16);
        wr64(GPU_BAR + 0x20, qr);
        wr64(GPU_BAR + 0x28, qr + 0x1000);
        wr64(GPU_BAR + 0x30, qr + 0x2000);
        wr16(GPU_BAR + 0x1c, 1);
    }
    wr8(GPU_BAR + 0x14, 1 | 2 | 8 | 4);
}

static void put_desc(uint64_t table, int i, uint64_t addr, uint32_t len, uint16_t flags, uint16_t next) {
    uint8_t *d = ram(table + 16u * i);
    memcpy(d, &addr, 8);
    memcpy(d + 8, &len, 4);
    memcpy(d + 12, &flags, 2);
    memcpy(d + 14, &next, 2);
}

static uint32_t req[16];
static uint32_t send(int q, uint32_t len, uint32_t entries_len) {
    uint64_t ring = GPU_RING + (uint64_t)q * 0x4000;
    memcpy(ram(GPU_REQ), req, len);
    memset(ram(GPU_RESP), 0, 24);
    uint16_t n = 0;
    put_desc(ring, n, GPU_REQ, len, 1, n + 1), n++;
    if (entries_len) put_desc(ring, n, GPU_ENTRIES, entries_len, 1, n + 1), n++;
    put_desc(ring, n, GPU_RESP, 24, 2, 0);
    uint16_t *avail = (uint16_t *)ram(ring + 0x1000);
    avail[2 + avail[1] % 16] = 0;
    avail[1]++;
    wr16(GPU_BAR + 0x3000 + 4u * q, 0);
    return rd32(GPU_RESP);
}
static void hdr(uint32_t type) { memset(req, 0, sizeof req), req[0] = type; }
static uint32_t create(uint32_t id, uint32_t format, uint32_t w, uint32_t h) {
    hdr(0x101), req[6] = id, req[7] = format, req[8] = w, req[9] = h;
    return send(0, 40, 0);
}
static uint32_t attach(uint32_t id, uint64_t addr, uint32_t len) {
    hdr(0x106), req[6] = id, req[7] = 1;
    memset(ram(GPU_ENTRIES), 0, 16);
    memcpy(ram(GPU_ENTRIES), &addr, 8);
    memcpy(ram(GPU_ENTRIES) + 8, &len, 4);
    return send(0, 32, 16);
}
static void rect(uint32_t type, uint32_t x, uint32_t y, uint32_t w, uint32_t h) { hdr(type), req[6] = x, req[7] = y, req[8] = w, req[9] = h; }
static uint32_t transfer(uint32_t id, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t stride) {
    rect(0x105, x, y, w, h);
    uint64_t offset = (uint64_t)y * stride + x * 4ull;
    memcpy(&req[10], &offset, 8);
    req[12] = id;
    return send(0, 56, 0);
}
static uint32_t scanout(uint32_t id, uint32_t w, uint32_t h) { rect(0x103, 0, 0, w, h), req[10] = 0, req[11] = id; return send(0, 48, 0); }
static uint32_t flush(uint32_t id, uint32_t x, uint32_t y, uint32_t w, uint32_t h) { rect(0x104, x, y, w, h), req[10] = id; return send(0, 48, 0); }
static void cursor(uint32_t type, int32_t x, int32_t y, uint32_t id, uint32_t hx, uint32_t hy) {
    hdr(type), req[7] = (uint32_t)x, req[8] = (uint32_t)y, req[10] = id, req[11] = hx, req[12] = hy;
    send(1, 56, 0);
}

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

/* Resource 1: 64 x 32 BGRX; pixel (x, y) is B = 4x + k, G = 8y, R = 0x80 + k, X = garbage. */
#define W1 64
#define H1 32
static void paint1(uint8_t k) {
    uint8_t *p = ram(FB1);
    for (uint32_t y = 0; y < H1; y++)
        for (uint32_t x = 0; x < W1; x++, p += 4) p[0] = (uint8_t)(4 * x + k), p[1] = (uint8_t)(8 * y), p[2] = 0x80 + k, p[3] = 0x5a;
}
static int is1(const uint8_t *px, uint32_t x, uint32_t y, uint8_t k) {
    return px[0] == (uint8_t)(4 * x + k) && px[1] == (uint8_t)(8 * y) && px[2] == 0x80 + k && px[3] == 0xff;
}

static uint8_t shot[W1 * H1 * 4];
/* Polls a snapshot of w x h until test says it is right; 0 after two seconds. */
static int wait_shot(HvVgpuMetal *p, uint32_t w, uint32_t h, int (*test)(void)) {
    for (double end = now() + 2; now() < end; usleep(2000))
        if (hv_vgpu_metal_snapshot(p, shot, w, h) == 0 && test()) return 1;
    return 0;
}
static uint8_t key;
static int all1(void) {
    for (uint32_t y = 0; y < H1; y++)
        for (uint32_t x = 0; x < W1; x++)
            if (!is1(shot + (y * W1 + x) * 4, x, y, key)) return 0;
    return 1;
}
static int in_flushed(uint32_t x, uint32_t y) { return x >= 8 && x < 24 && y >= 4 && y < 12; }
static int only_flushed(void) { /* inside the flushed rectangle the new picture, outside the old */
    for (uint32_t y = 0; y < H1; y++)
        for (uint32_t x = 0; x < W1; x++)
            if (!is1(shot + (y * W1 + x) * 4, x, y, in_flushed(x, y) ? 1 : 0)) return 0;
    return 1;
}
static uint8_t want_bgr[3];
static int flat(void) { /* 32 x 16 of one colour */
    for (uint32_t i = 0; i < 32 * 16; i++)
        if (memcmp(shot + i * 4, want_bgr, 3) || shot[i * 4 + 3] != 0xff) return 0;
    return 1;
}
static int black(void) {
    for (uint32_t i = 0; i < W1 * H1; i++)
        if (shot[i * 4] || shot[i * 4 + 1] || shot[i * 4 + 2]) return 0;
    return 1;
}

/* Resource 5: 8192 x 4096, more pixels than the presenter keeps; black where not painted white. */
#define BIG_W 8192
#define BIG_H 4096
static void paint_big(uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    pthread_mutex_lock(&b.gpu->mu);
    HvVgpuResource *r = hv_virtio_gpu_resource(b.gpu, 5);
    for (uint32_t row = y; r && row < y + h; row++) memset(r->pixels + ((size_t)row * BIG_W + x) * 4, 0xff, w * 4ull);
    pthread_mutex_unlock(&b.gpu->mu);
}
static int white_where(int (*in)(uint32_t x, uint32_t y)) {
    for (uint32_t y = 0; y < H1; y++)
        for (uint32_t x = 0; x < W1; x++) {
            const uint8_t *px = shot + (y * W1 + x) * 4, v = in(x, y) ? 0xff : 0;
            if (px[0] != v || px[1] != v || px[2] != v) return 0;
        }
    return 1;
}
static int in_right(uint32_t x, uint32_t y) { (void)y; return x >= W1 / 2; }
static int in_three(uint32_t x, uint32_t y) { return x >= W1 / 2 || y < H1 / 2; }
static int right_white(void) { return white_where(in_right); }
static int three_white(void) { return white_where(in_three); }

static int make_board(void) {
    return hv_machine_init(&m, 4 << 20) || hv_virt_create(&b, &m, cpus, 1, 64ull << 20, NULL, NULL);
}

static void test_pixels(void) {
    if (make_board()) { check("board", 1, 0); return; }
    gpu_setup();
    HvVgpuMetal *p = hv_vgpu_metal_create(b.gpu);
    check("presenter made", p != NULL, 1);
    if (!p) return;
    uint8_t probe[4];
    check("no snapshot before a scanout", hv_vgpu_metal_snapshot(p, probe, 1, 1), (uint64_t)-1);
    CAMetalLayer *layer = [CAMetalLayer layer];
    hv_vgpu_metal_set_layer(p, (__bridge void *)layer);

    /* create, attach, transfer, set scanout, flush */
    paint1(0);
    check("create", create(1, HV_VGPU_B8G8R8X8, W1, H1), OK);
    check("attach", attach(1, FB1, W1 * H1 * 4), OK);
    check("transfer", transfer(1, 0, 0, W1, H1, W1 * 4), OK);
    check("set scanout", scanout(1, W1, H1), OK);
    check("flush", flush(1, 0, 0, W1, H1), OK);
    key = 0;
    check("snapshot shows the guest's pixels, X made opaque", wait_shot(p, W1, H1, all1), 1);

    /* R11: a BGRX scanout the size of its resource is drawn from the resource's pixels, so a transfer shows with or without a flush. */
    paint1(1);
    check("transfer all", transfer(1, 0, 0, W1, H1, W1 * 4), OK);
    check("flush a part", flush(1, 8, 4, 16, 8), OK);
    key = 1;
    check("a BGRX scanout is read in place", wait_shot(p, W1, H1, all1), 1);

    uint64_t f0 = 0;
    for (double end = now() + 2; now() < end && !f0; usleep(2000)) f0 = hv_vgpu_metal_frames(p);
    check("frames presented to the layer", f0 > 0, 1);
    check("drawable is the scanout's size", CGSizeEqualToSize(layer.drawableSize, CGSizeMake(W1, H1)), 1);

    /* Formats other than BGRA and BGRX are converted. */
    static const struct { uint32_t id, format; uint64_t fb; uint8_t bytes[4]; } fmt[] = {
        {2, HV_VGPU_R8G8B8X8, FB2, {0x10, 0x20, 0x30, 0x99}}, /* R G B X */
        {3, HV_VGPU_A8R8G8B8, FB3, {0x99, 0x10, 0x20, 0x30}}, /* A R G B */
    };
    for (int i = 0; i < 2; i++) {
        for (uint32_t k = 0; k < 32 * 16; k++) memcpy(ram(fmt[i].fb) + k * 4, fmt[i].bytes, 4);
        create(fmt[i].id, fmt[i].format, 32, 16);
        attach(fmt[i].id, fmt[i].fb, 32 * 16 * 4);
        transfer(fmt[i].id, 0, 0, 32, 16, 32 * 4);
        check("set scanout to a converted format", scanout(fmt[i].id, 32, 16), OK);
        want_bgr[0] = 0x30, want_bgr[1] = 0x20, want_bgr[2] = 0x10;
        check(i ? "A8R8G8B8 shown as BGRA" : "R8G8B8X8 shown as BGRA", wait_shot(p, 32, 16, flat), 1);
    }

    /* Converted formats go through the shadow, where only a flushed rectangle reaches the screen. */
    for (uint32_t k = 0; k < 32 * 16; k++) memcpy(ram(FB2) + k * 4, (uint8_t[]){0x70, 0x80, 0x90, 0x99}, 4);
    transfer(2, 0, 0, 32, 16, 32 * 4);
    check("scanout to resource 2", scanout(2, 32, 16), OK);
    want_bgr[0] = 0x90, want_bgr[1] = 0x80, want_bgr[2] = 0x70;
    check("resource 2 shown", wait_shot(p, 32, 16, flat), 1);
    for (uint32_t k = 0; k < 32 * 16; k++) memcpy(ram(FB2) + k * 4, (uint8_t[]){0x40, 0x50, 0x60, 0x99}, 4);
    transfer(2, 0, 0, 32, 16, 32 * 4);
    flush(2, 0, 0, 16, 16); /* the left half */
    uint8_t half_new[3] = {0x60, 0x50, 0x40}, half_old[3] = {0x90, 0x80, 0x70};
    int half_ok = 0;
    for (double end = now() + 2; now() < end && !half_ok; usleep(2000)) {
        if (hv_vgpu_metal_snapshot(p, shot, 32, 16)) continue;
        half_ok = 1;
        for (uint32_t i = 0; i < 32 * 16; i++) half_ok &= !memcmp(shot + i * 4, i % 32 < 16 ? half_new : half_old, 3);
    }
    usleep(50000);
    hv_vgpu_metal_snapshot(p, shot, 32, 16);
    for (uint32_t i = 0; i < 32 * 16; i++) half_ok &= !memcmp(shot + i * 4, i % 32 < 16 ? half_new : half_old, 3);
    check("a converted scanout shows only the flushed rectangle", half_ok, 1);

    /* A width whose rows are not 16-byte multiples cannot be a linear texture: the shadow path shows it. */
    uint8_t *odd = ram(FB3);
    for (uint32_t k = 0; k < 30 * 16; k++) memcpy(odd + k * 4, (uint8_t[]){0x11, 0x22, 0x33, 0x44}, 4);
    check("create 30 x 16", create(8, HV_VGPU_B8G8R8X8, 30, 16), OK);
    attach(8, FB3, 30 * 16 * 4);
    transfer(8, 0, 0, 30, 16, 30 * 4);
    check("scanout to a 30 x 16", scanout(8, 30, 16), OK);
    want_bgr[0] = 0x11, want_bgr[1] = 0x22, want_bgr[2] = 0x33;
    int odd_ok = 0;
    for (double end = now() + 2; now() < end && !odd_ok; usleep(2000)) {
        if (hv_vgpu_metal_snapshot(p, shot, 30, 16)) continue;
        odd_ok = 1;
        for (uint32_t i = 0; i < 30 * 16; i++) odd_ok &= !memcmp(shot + i * 4, want_bgr, 3);
    }
    check("a 30 x 16 scanout is shown", odd_ok, 1);

    /* A resource that goes while its pixels are on screen: the GPU's reference keeps them alive. */
    check("scanout to resource 1 again", scanout(1, W1, H1), OK);
    key = 1;
    check("shown in place", wait_shot(p, W1, H1, all1), 1);
    for (int i = 0; i < 20; i++) {
        hdr(0x102), req[6] = 1;
        check("unref the scanout", send(0, 32, 0), OK);
        check("make it again", create(1, HV_VGPU_B8G8R8X8, W1, H1), OK);
        attach(1, FB1, W1 * H1 * 4);
        transfer(1, 0, 0, W1, H1, W1 * 4);
        scanout(1, W1, H1);
        usleep(3000);
    }
    check("after churn: the picture", wait_shot(p, W1, H1, all1), 1);

    /* Back to resource 1, with a cursor: 8 x 8 opaque white at the top left of a 64 x 64 image. */
    check("scanout back", scanout(1, W1, H1), OK);
    key = 1;
    check("whole scanout after a set scanout", wait_shot(p, W1, H1, all1), 1);
    uint8_t *c = ram(FBC);
    memset(c, 0, 64 * 64 * 4);
    for (int y = 0; y < 8; y++) memset(c + y * 64 * 4, 0xff, 8 * 4);
    create(4, HV_VGPU_B8G8R8A8, 64, 64);
    attach(4, FBC, 64 * 64 * 4);
    transfer(4, 0, 0, 64, 64, 64 * 4);
    static uint8_t drawn[W1 * H1 * 4];
    uint64_t before = 0;
    for (double end = now() + 2; now() < end && !before; usleep(2000)) before = hv_vgpu_metal_drawn(p, drawn, W1, H1);
    check("drawables captured", before > 0, 1);
    cursor(0x300, 20, 10, 4, 2, 3); /* Linux sends the image's top left; the hot spot does not move it */
    int ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) {
        uint64_t n = hv_vgpu_metal_drawn(p, drawn, W1, H1);
        ok = n > before && drawn[(10 * W1 + 20) * 4] == 0xff && drawn[(10 * W1 + 20) * 4 + 1] == 0xff;
    }
    check("cursor image drawn at its position", ok, 1);
    check("cursor's last pixel", drawn[(17 * W1 + 27) * 4 + 2], 0xff);
    check("left of the cursor: the screen", is1(drawn + (10 * W1 + 19) * 4, 19, 10, 1), 1);
    check("right of the cursor: the screen", is1(drawn + (10 * W1 + 28) * 4, 28, 10, 1), 1);
    check("below the cursor: the screen", is1(drawn + (18 * W1 + 20) * 4, 20, 18, 1), 1);
    check("not moved by the hot spot", is1(drawn + (7 * W1 + 18) * 4, 18, 7, 1), 1);
    check("the snapshot has no cursor", hv_vgpu_metal_snapshot(p, shot, W1, H1) == 0 && all1(), 1);
    hv_vgpu_metal_hide_cursor(p, 1); /* touch mode */
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) {
        hv_vgpu_metal_drawn(p, drawn, W1, H1);
        ok = is1(drawn + (10 * W1 + 20) * 4, 20, 10, 1);
    }
    check("a hidden cursor is not drawn", ok, 1);
    hv_vgpu_metal_hide_cursor(p, 0);
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) {
        hv_vgpu_metal_drawn(p, drawn, W1, H1);
        ok = drawn[(10 * W1 + 20) * 4] == 0xff;
    }
    check("shown again with no guest change", ok, 1);
    hv_vgpu_metal_hide_cursor(NULL, 1);
    cursor(0x301, 40, 20, 4, 0, 0); /* a move keeps the image and its hot spot */
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) {
        hv_vgpu_metal_drawn(p, drawn, W1, H1);
        ok = drawn[(20 * W1 + 40) * 4] == 0xff && is1(drawn + (10 * W1 + 20) * 4, 20, 10, 1);
    }
    check("cursor moved", ok, 1);

    /* At most 60 frames a second, however fast the guest flushes. */
    double t0 = now();
    uint64_t f1 = hv_vgpu_metal_frames(p);
    unsigned sent = 0;
    while (now() - t0 < 0.5) flush(1, 0, 0, 8, 8), sent++;
    double secs = now() - t0;
    uint64_t made = hv_vgpu_metal_frames(p) - f1;
    printf("  %u flushes in %.3f s: %llu frames\n", sent, secs, (unsigned long long)made);
    check("frames capped at 60 a second", made <= (uint64_t)(secs * 60) + 2, 1);
    check("but the presenter keeps up", made >= 10, 1);

    /* No layer: no frames, but the snapshot follows. */
    hv_vgpu_metal_set_layer(p, NULL);
    usleep(50000);
    uint64_t f2 = hv_vgpu_metal_frames(p);
    paint1(2);
    transfer(1, 0, 0, W1, H1, W1 * 4);
    flush(1, 0, 0, W1, H1);
    key = 2;
    check("snapshot without a layer", wait_shot(p, W1, H1, all1), 1);
    check("no frames without a layer", hv_vgpu_metal_frames(p), f2);
    CAMetalLayer *second = [CAMetalLayer layer];
    hv_vgpu_metal_set_layer(p, (__bridge void *)second);
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) ok = hv_vgpu_metal_frames(p) > f2;
    check("a new layer gets a frame with no flush", ok, 1);
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000))
        ok = hv_vgpu_metal_drawn(p, drawn, W1, H1) && is1(drawn + (31 * W1 + 63) * 4, 63, 31, 2);
    check("the new layer shows what changed while there was none", ok, 1);

    /* A9c: paused, nothing is drawn or committed, even for a new picture or a new layer; the resume draws once. */
    hv_vgpu_metal_pause(p);
    uint64_t f3 = hv_vgpu_metal_frames(p);
    paint1(4);
    transfer(1, 0, 0, W1, H1, W1 * 4);
    flush(1, 0, 0, W1, H1);
    hv_vgpu_metal_set_layer(p, (__bridge void *)second);
    usleep(300000);
    check("no frames while paused", hv_vgpu_metal_frames(p), f3);
    hv_vgpu_metal_pause(p); /* twice is harmless */
    hv_vgpu_metal_resume(p);
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000))
        ok = hv_vgpu_metal_frames(p) > f3 && hv_vgpu_metal_drawn(p, drawn, W1, H1) && is1(drawn + (31 * W1 + 63) * 4, 63, 31, 4);
    check("the resume draws what changed while paused", ok, 1);
    hv_vgpu_metal_resume(p); /* without a pause: harmless */
    paint1(2);
    transfer(1, 0, 0, W1, H1, W1 * 4);
    flush(1, 0, 0, W1, H1);

    /* A scanout larger than the display mode (1920 x 1080) and the presenter's pixel limit. */
    check("create a large resource", create(5, HV_VGPU_B8G8R8X8, BIG_W, BIG_H), OK);
    paint_big(BIG_W / 2, 0, BIG_W / 2, BIG_H);
    check("set a large scanout", scanout(5, BIG_W, BIG_H), OK);
    check("large scanout shown scaled", wait_shot(p, W1, H1, right_white), 1);
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) ok = hv_vgpu_metal_drawn(p, NULL, 1920, 960) > 0;
    check("its drawable fits the display mode", ok, 1);
    paint_big(0, 0, BIG_W / 2, BIG_H / 2);
    flush(5, 0, 0, BIG_W / 2, BIG_H / 2);
    check("a flushed part of a scaled scanout", wait_shot(p, W1, H1, three_white), 1);

    check("scanout off", scanout(0, 0, 0), OK);
    check("scanout off shows black", wait_shot(p, W1, H1, black), 1);
    hv_virtio_gpu_set_mode(b.gpu, 800, 600);
    hv_virtio_gpu_poll(b.gpu);
    ok = 0;
    for (double end = now() + 2; now() < end && !ok; usleep(2000)) ok = hv_vgpu_metal_drawn(p, NULL, 800, 600) > 0;
    check("a mode change with the scanout off resizes the black screen", ok, 1);

    /* R6: the layer's pixels bound the drawable, not the mode (800 x 600 here). */
    check("create a 4K resource", create(6, HV_VGPU_B8G8R8X8, 3840, 2160), OK);
    check("set a 4K scanout", scanout(6, 3840, 2160), OK);
    CAMetalLayer *big = [CAMetalLayer layer];
    big.bounds = CGRectMake(0, 0, 3840, 2160), big.contentsScale = 1;
    hv_vgpu_metal_set_layer(p, (__bridge void *)big);
    ok = 0;
    for (double end = now() + 4; now() < end && !ok; usleep(2000)) ok = hv_vgpu_metal_drawn(p, NULL, 3840, 2160) > 0;
    check("a 4K scanout on a 4K layer is drawn 1:1", ok, 1);
    check("its drawable is 3840 x 2160", CGSizeEqualToSize(big.drawableSize, CGSizeMake(3840, 2160)), 1);

    CAMetalLayer *small = [CAMetalLayer layer];
    small.bounds = CGRectMake(0, 0, 1000, 500), small.contentsScale = 2; /* 2000 x 1000 pixels */
    hv_vgpu_metal_set_layer(p, (__bridge void *)small);
    ok = 0;
    for (double end = now() + 4; now() < end && !ok; usleep(2000)) ok = hv_vgpu_metal_drawn(p, NULL, 1778, 1000) > 0;
    check("a layer smaller than the scanout gets a drawable that fits it, in the scanout's shape", ok, 1);
    check("its drawable size", CGSizeEqualToSize(small.drawableSize, CGSizeMake(1778, 1000)), 1);

    /* A rotated mode, the old scanout: the layer (now tall) still sets the size. */
    hv_virtio_gpu_set_mode(b.gpu, 2160, 3840);
    hv_virtio_gpu_poll(b.gpu);
    CAMetalLayer *tall = [CAMetalLayer layer];
    tall.bounds = CGRectMake(0, 0, 540, 1200), tall.contentsScale = 2; /* 1080 x 2400 pixels */
    hv_vgpu_metal_set_layer(p, (__bridge void *)tall);
    ok = 0;
    for (double end = now() + 4; now() < end && !ok; usleep(2000)) ok = hv_vgpu_metal_drawn(p, NULL, 1080, 608) > 0;
    check("a rotated mode with the old scanout fills the layer's width", ok, 1);
    check("its drawable is not below the layer's limit nor over it", CGSizeEqualToSize(tall.drawableSize, CGSizeMake(1080, 608)), 1);

    hv_vgpu_metal_destroy(p);
    check("flush callback released", b.gpu->on_flush == NULL && b.gpu->opaque == NULL, 1);
    hv_virt_destroy(&b);
    hv_machine_free(&m);
}

static HvVgpuMetal *swapping;
static void *swap_layers(void *arg) {
    (void)arg;
    @autoreleasepool {
        CAMetalLayer *a = [CAMetalLayer layer], *c = [CAMetalLayer layer];
        for (int i = 0; i < 300; i++) {
            hv_vgpu_metal_set_layer(swapping, i % 3 == 2 ? NULL : (__bridge void *)(i % 3 ? a : c));
            usleep(200);
        }
        hv_vgpu_metal_set_layer(swapping, (__bridge void *)a);
    }
    return NULL;
}

/* Board and presenter made and freed with flushes, cursor moves and layer swaps in flight. */
static void test_lifecycle(void) {
    uint64_t frames = 0;
    for (int cycle = 0; cycle < 6; cycle++) @autoreleasepool {
        if (make_board()) { check("board", 1, 0); return; }
        gpu_setup();
        if (cycle & 1) { /* a scanout before the presenter exists */
            paint1(3);
            create(1, HV_VGPU_B8G8R8X8, W1, H1);
            attach(1, FB1, W1 * H1 * 4);
            transfer(1, 0, 0, W1, H1, W1 * 4);
            scanout(1, W1, H1);
        }
        swapping = hv_vgpu_metal_create(b.gpu);
        if (!swapping) { check("presenter made", 0, 1); return; }
        if (cycle & 1) {
            key = 3;
            check("a scanout set before the presenter is shown", wait_shot(swapping, W1, H1, all1), 1);
        } else {
            paint1(3);
            create(1, HV_VGPU_B8G8R8X8, W1, H1);
            attach(1, FB1, W1 * H1 * 4);
            scanout(1, W1, H1);
        }
        pthread_t t;
        pthread_create(&t, NULL, swap_layers, NULL);
        for (int i = 0; i < 300; i++) {
            transfer(1, 0, 0, W1, H1, W1 * 4);
            flush(1, 0, 0, W1, H1);
            cursor(0x301, i % W1, i % H1, 0, 0, 0);
            usleep(100);
        }
        pthread_join(t, NULL);
        flush(1, 0, 0, W1, H1); /* a present still queued at teardown */
        usleep(cycle * 3000);
        frames += hv_vgpu_metal_frames(swapping);
        __weak id alive = (__bridge id)(void *)swapping;
        if (!cycle) check("presenter tracked", alive != nil, 1);
        hv_vgpu_metal_destroy(swapping);
        int freed = 0;
        for (double end = now() + 2; now() < end && !freed; usleep(2000)) @autoreleasepool { freed = alive == nil; }
        check("presenter freed after destroy", freed, 1);
        flush(1, 0, 0, W1, H1); /* the device outlives the presenter */
        hv_virt_destroy(&b);
        hv_machine_free(&m);
    }
    printf("  lifecycle: 6 cycles, %llu frames\n", (unsigned long long)frames);
    check("lifecycle presented frames", frames > 0, 1);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(60);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_NO_SOUND", "1", 1);
    setenv("HV_VGPU_CAPTURE", "1", 1);
    test_pixels();
    test_lifecycle();
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
