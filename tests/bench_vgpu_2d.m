#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <stdint.h>
#include <sys/resource.h>

#include "vgpu_metal.h"
#include "virt.h"

/* R11: what the 2D path costs. A 2D desktop is simulated at 1080p and 4K: each frame the "guest" writes
   a rectangle, then TRANSFER_TO_HOST_2D and RESOURCE_FLUSH go through the control queue at 60 Hz, as a
   software-drawn desktop does. Prints the command latency the guest sees (the device lock) and the
   presenter's own times. Not part of make test: make bench-vgpu-2d. */
static int failures;
static void check(const char *what, uint64_t got, uint64_t want) {
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

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

static int make_board(void) {
    return hv_machine_init(&m, 4 << 20) || hv_virt_create(&b, &m, cpus, 1, 128ull << 20, NULL, NULL, 0);
}

static int cmp_u64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

/* One scenario: frames of a w x h rectangle at (x, y) on a W x H scanout. */
static void run(HvVgpuMetal *p, uint32_t W, uint32_t H, const char *name, uint32_t x, uint32_t y, uint32_t w, uint32_t h, int frames) {
    HvVgpuStats s0, s1;
    uint64_t *lat = calloc((size_t)frames, sizeof *lat);
    uint64_t f0 = hv_vgpu_metal_frames(p);
    hv_vgpu_metal_stats(p, &s0);
    struct rusage r0, r1;
    getrusage(RUSAGE_SELF, &r0);
    double t0 = now();
    for (int i = 0; i < frames; i++) {
        double due = t0 + i / 60.0;
        while (now() < due) usleep(200);
        uint8_t v = (uint8_t)(i * 7 + 1);
        for (uint32_t row = 0; row < h; row++) memset(ram(FB1) + ((size_t)(y + row) * W + x) * 4, v, w * 4ull);
        double a = now();
        transfer(1, x, y, w, h, W * 4);
        flush(1, x, y, w, h);
        lat[i] = (uint64_t)((now() - a) * 1e9);
    }
    double t1 = now();
    getrusage(RUSAGE_SELF, &r1);
    usleep(100000);
    hv_vgpu_metal_stats(p, &s1);
    qsort(lat, (size_t)frames, sizeof *lat, cmp_u64);
    uint64_t sum = 0;
    for (int i = 0; i < frames; i++) sum += lat[i];
    uint64_t n = s1.pulls - s0.pulls, u = s1.uploads - s0.uploads;
    double cpu_ms = ((r1.ru_utime.tv_sec - r0.ru_utime.tv_sec) + (r1.ru_stime.tv_sec - r0.ru_stime.tv_sec)) * 1e3 +
                    ((r1.ru_utime.tv_usec - r0.ru_utime.tv_usec) + (r1.ru_stime.tv_usec - r0.ru_stime.tv_usec)) / 1e3;
    uint64_t presented = hv_vgpu_metal_frames(p) - f0;
    printf("%ux%u %-10s %4.1f MB/frame | cpu %5.2f ms/frame gpu %5.0f us/frame | cmd us: mean %6.0f p50 %6.0f p99 %6.0f max %6.0f | presented %3llu (%.1f/s) | pull wait %4.0f hold %6.0f us (%llu pulls) | upload mean %6.0f us (%llu)\n",
           W, H, name, w * h * 4 / 1e6, cpu_ms / frames, presented ? (s1.gpu_ns - s0.gpu_ns) / 1e3 / presented : 0, sum / 1e3 / frames, lat[frames / 2] / 1e3, lat[frames * 99 / 100] / 1e3, lat[frames - 1] / 1e3,
           (unsigned long long)(hv_vgpu_metal_frames(p) - f0), (hv_vgpu_metal_frames(p) - f0) / (t1 - t0),
           n ? (s1.pull_wait_ns - s0.pull_wait_ns) / 1e3 / n : 0, n ? (s1.pull_hold_ns - s0.pull_hold_ns) / 1e3 / n : 0,
           (unsigned long long)n, u ? (s1.upload_ns - s0.upload_ns) / 1e3 / u : 0, (unsigned long long)u);
    free(lat);
}

static void size_run(uint32_t W, uint32_t H, int frames) {
    if (make_board()) { check("board", 1, 0); return; }
    gpu_setup();
    HvVgpuMetal *p = hv_vgpu_metal_create(b.gpu);
    check("presenter made", p != NULL, 1);
    if (!p) return;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.bounds = CGRectMake(0, 0, W, H), layer.contentsScale = 1;
    hv_vgpu_metal_set_layer(p, (__bridge void *)layer);
    memset(ram(FB1), 0x20, (size_t)W * H * 4);
    check("create", create(1, HV_VGPU_B8G8R8X8, W, H), OK);
    check("attach", attach(1, FB1, W * H * 4), OK);
    check("transfer", transfer(1, 0, 0, W, H, W * 4), OK);
    check("set scanout", scanout(1, W, H), OK);
    check("flush", flush(1, 0, 0, W, H), OK);
    usleep(300000);
    run(p, W, H, "full", 0, 0, W, H, frames);
    run(p, W, H, "quarter", W / 4, H / 4, W / 2, H / 2, frames);
    run(p, W, H, "window", W / 3, H / 3, W / 4, H / 4, frames);
    run(p, W, H, "text-strip", 0, H / 2, W, 24, frames);
    hv_vgpu_metal_destroy(p);
    hv_virt_destroy(&b);
    hv_machine_free(&m);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(120);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_NO_SOUND", "1", 1);
    int frames = argc > 1 ? atoi(argv[1]) : 180;
    size_run(1920, 1080, frames);
    size_run(3840, 2160, frames);
    return failures != 0;
}
