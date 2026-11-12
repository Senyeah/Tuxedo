// The virtio GPU with the real virgl renderer (devices/vgpu_virgl.m): a driver written in C posts
// control-queue requests, a recorded virgl clear runs on ANGLE (Metal), and TRANSFER_FROM_HOST_3D
// brings the colour back into guest RAM. Needs the libraries from tools/gfx (make test-vgpu-virgl).
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "virt.h"
#include "vgpu_virgl.h"
#include "virtio_gpu.h"

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
static HvDisk root = {.fd = -1, .wfd = -1};
static char dir[] = "/tmp/henge-vgpu-virgl-XXXXXX";

#define GPU_SLOT 7 // after the virtio block device; the board puts the GPU here when it has a disk
#define GPU_CFG (VIRT_PCIE_ECAM + ((uint64_t)GPU_SLOT << 15))
#define GPU_BAR (VIRT_PCIE_MMIO + 0x100000)
#define RING (VIRT_MEM + 0x100000)
#define REQ(h) (VIRT_MEM + 0x200000 + (uint64_t)(h) * 0x400)
#define RESP(h) (VIRT_MEM + 0x300000 + (uint64_t)(h) * 0x800)
#define BACKING (VIRT_MEM + 0x1000000)
#define Q 128

enum { OK = 0x1100, OK_CAPSET_INFO = 0x1102, OK_CAPSET = 0x1103, UNSPEC = 0x1200 };

static uint8_t *ram(uint64_t pa) { return hv_phys_ptr(&m, pa, 1); }
static void wr8(uint64_t pa, uint8_t v) { hv_phys_write(&m, pa, &v, 1); }
static void wr16(uint64_t pa, uint16_t v) { hv_phys_write(&m, pa, &v, 2); }
static void wr32(uint64_t pa, uint32_t v) { hv_phys_write(&m, pa, &v, 4); }
static void wr64(uint64_t pa, uint64_t v) { hv_phys_write(&m, pa, &v, 8); }
static uint32_t rd32(uint64_t pa) { uint32_t v = 0; hv_phys_read(&m, pa, &v, 4); return v; }

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/* The driver: status 0 (a reset), the VIRGL feature, queue 0 with Q entries. */
static void driver_setup(void) {
    wr32(GPU_CFG + 0x20, (uint32_t)GPU_BAR);
    wr32(GPU_CFG + 0x24, 0);
    wr16(GPU_CFG + 0x04, 0x6);
    wr8(GPU_BAR + 0x14, 0);
    wr8(GPU_BAR + 0x14, 1 | 2);
    wr32(GPU_BAR + 0x08, 0);
    wr32(GPU_BAR + 0x0c, 1); // VIRGL
    wr32(GPU_BAR + 0x08, 1);
    wr32(GPU_BAR + 0x0c, 1); // VERSION_1
    wr8(GPU_BAR + 0x14, 1 | 2 | 8);
    for (int q = 0; q < 2; q++) {
        uint64_t qr = RING + (uint64_t)q * 0x4000;
        memset(ram(qr), 0, 0x4000);
        wr16(GPU_BAR + 0x16, (uint16_t)q);
        wr16(GPU_BAR + 0x18, Q);
        wr64(GPU_BAR + 0x20, qr);
        wr64(GPU_BAR + 0x28, qr + 0x1000);
        wr64(GPU_BAR + 0x30, qr + 0x2000);
        wr16(GPU_BAR + 0x1c, 1);
    }
    wr8(GPU_BAR + 0x14, 1 | 2 | 8 | 4);
}

static void put_desc(int i, uint64_t addr, uint32_t len, uint16_t flags, uint16_t next) {
    uint8_t *d = ram(RING + 16u * i);
    memcpy(d, &addr, 8), memcpy(d + 8, &len, 4), memcpy(d + 12, &flags, 2), memcpy(d + 14, &next, 2);
}

static uint16_t next_desc, avail_n, seen;
static struct { int head; uint32_t written; } reaped[4 * Q];
static int nreaped;
static uint8_t rq[1 << 12]; // the request being built: header, then its body
static uint32_t rq_len;

static void q_hdr(uint32_t type, uint32_t ctx, uint64_t fence) {
    memset(rq, 0, sizeof rq);
    memcpy(rq, &type, 4);
    if (fence) {
        uint32_t flags = 1;
        memcpy(rq + 4, &flags, 4), memcpy(rq + 8, &fence, 8);
    }
    memcpy(rq + 16, &ctx, 4);
    rq_len = 24;
}
static void q32(unsigned off, uint32_t v) { memcpy(rq + off, &v, 4); }
static void q64(unsigned off, uint64_t v) { memcpy(rq + off, &v, 8); }

static void reap(void) {
    uint16_t *used = (uint16_t *)ram(RING + 0x2000);
    while (seen != __atomic_load_n(&used[1], __ATOMIC_ACQUIRE)) {
        uint8_t *e = ram(RING + 0x2000 + 4 + 8u * (seen % Q));
        uint32_t id, len;
        memcpy(&id, e, 4), memcpy(&len, e + 4, 4);
        if (nreaped < 4 * Q) reaped[nreaped].head = (int)id, reaped[nreaped++].written = len;
        seen++;
    }
}

/* Posts rq (rq_len bytes, one readable piece) with a response buffer of resp_len; returns the head. */
static int post(uint32_t resp_len) {
    if (next_desc + 2 > Q) next_desc = 0;
    int head = next_desc;
    next_desc += 2;
    memcpy(ram(REQ(head)), rq, rq_len);
    memset(ram(RESP(head)), 0, resp_len);
    put_desc(head, REQ(head), rq_len, 1, (uint16_t)(head + 1));
    put_desc(head + 1, RESP(head), resp_len, 2, 0);
    uint16_t *avail = (uint16_t *)ram(RING + 0x1000);
    avail[2 + avail_n % Q] = (uint16_t)head;
    avail_n++;
    __atomic_store_n(&avail[1], avail_n, __ATOMIC_RELEASE);
    return head;
}
static void kick(void) { wr16(GPU_BAR + 0x3000, 0); }

static int answered(int head) {
    for (int i = 0; i < nreaped; i++)
        if (reaped[i].head == head) return 1;
    return 0;
}

/* Polls the device, as the board's tick does, until `head` is answered or 10 s pass. */
static int wait_for(int head) {
    uint64_t t0 = now_ms();
    for (;;) {
        hv_virtio_gpu_poll(b.gpu);
        reap();
        if (answered(head)) return 1;
        if (now_ms() - t0 > 10000) return 0;
        usleep(200);
    }
}

#define NODATA 24
static uint32_t cmd_wait(uint32_t resp_len, int *headp) {
    nreaped = 0;
    int head = post(resp_len);
    kick();
    if (headp) *headp = head;
    if (!wait_for(head)) {
        failures++;
        printf("  FAIL a request was never answered\n");
        return 0xdead;
    }
    return rd32(RESP(head));
}
static uint32_t cmd(void) { return cmd_wait(NODATA, NULL); }

static uint32_t c_ctx_create(uint32_t ctx, const char *name) {
    q_hdr(0x200, ctx, 0), q32(24, (uint32_t)strlen(name));
    memcpy(rq + 32, name, strlen(name));
    rq_len = 96;
    return cmd();
}
static uint32_t c_ctx_destroy(uint32_t ctx) { q_hdr(0x201, ctx, 0), rq_len = 32; return cmd(); }
static uint32_t c_ctx_attach(uint32_t type, uint32_t ctx, uint32_t res) { q_hdr(type, ctx, 0), q32(24, res), rq_len = 32; return cmd(); }
static uint32_t c_res_create(uint32_t id, uint32_t w, uint32_t h) {
    q_hdr(0x204, 0, 0);
    // target 2D, format R8G8B8A8_UNORM (67), bind render target and sampler view
    q32(24, id), q32(28, 2), q32(32, 67), q32(36, 0xa), q32(40, w), q32(44, h), q32(48, 1), q32(52, 1);
    rq_len = 72;
    return cmd();
}
static uint32_t c_res_unref(uint32_t id) { q_hdr(0x102, 0, 0), q32(24, id), rq_len = 32; return cmd(); }
static uint32_t c_attach(uint32_t res, uint64_t addr, uint32_t len) {
    q_hdr(0x106, 0, 0), q32(24, res), q32(28, 1), q64(32, addr), q32(40, len);
    rq_len = 48;
    return cmd();
}
static uint32_t c_detach(uint32_t res) { q_hdr(0x107, 0, 0), q32(24, res), rq_len = 32; return cmd(); }
static void q_transfer(uint32_t type, uint32_t ctx, uint32_t res, uint32_t w, uint32_t h, uint64_t fence) {
    q_hdr(type, ctx, fence);
    q32(36, w), q32(40, h), q32(44, 1), q32(56, res), q32(64, w * 4);
    rq_len = 72;
}
static void q_submit(uint32_t ctx, const uint32_t *dw, uint32_t ndw, uint64_t fence) {
    q_hdr(0x207, ctx, fence), q32(24, ndw * 4);
    memcpy(rq + 32, dw, ndw * 4);
    rq_len = 32 + ndw * 4;
}

enum { CCMD_CREATE_OBJECT = 1, CCMD_SET_FRAMEBUFFER_STATE = 5, CCMD_CLEAR = 7, OBJECT_SURFACE = 8 };
enum { FORMAT_R8G8B8A8_UNORM = 67, CLEAR_COLOR0 = 1 << 2 };
#define CMD0(c, obj, len) ((c) | ((obj) << 8) | ((len) << 16))

/* Recorded from the virgl protocol: a surface on `res`, bound as the framebuffer, then a clear. */
static uint32_t clear_cmd(uint32_t *out, uint32_t res, const uint8_t rgba[4]) {
    uint32_t col[4];
    for (int i = 0; i < 4; i++) {
        float f = rgba[i] / 255.0f;
        memcpy(&col[i], &f, 4);
    }
    uint32_t c[] = {
        CMD0(CCMD_CREATE_OBJECT, OBJECT_SURFACE, 5), 1, res, FORMAT_R8G8B8A8_UNORM, 0, 0,
        CMD0(CCMD_SET_FRAMEBUFFER_STATE, 0, 3), 1, 0, 1,
        CMD0(CCMD_CLEAR, 0, 8), CLEAR_COLOR0, col[0], col[1], col[2], col[3], 0, 0, 0,
    };
    memcpy(out, c, sizeof c);
    return sizeof c / 4;
}

static int pixels_are(uint64_t pa, uint32_t w, uint32_t h, const uint8_t rgba[4]) {
    const uint8_t *p = ram(pa);
    int bad = 0;
    for (uint32_t i = 0; i < w * h; i++)
        if (memcmp(p + 4 * i, rgba, 4)) bad++;
    return bad;
}

static const uint8_t RED[4] = {0xd0, 0x20, 0x30, 0xff}, BLUE[4] = {0x20, 0x60, 0xa0, 0xff};

/* The A5 case: clear on ctx 1, read it back through the backing. Fenced both ways. */
static void clear_and_read(const char *tag, uint32_t ctx, uint32_t res, const uint8_t rgba_in[4], uint64_t back, uint64_t fence) {
    char w[96];
    uint8_t rgba[4];
    memcpy(rgba, rgba_in, 4);
    uint32_t dw[32], n = clear_cmd(dw, res, rgba);
    if (getenv("VGPU_VIRGL_SABOTAGE")) rgba[0] ^= 1; // the expected colour only: proves a mismatch fails
    memset(ram(back), 0x77, 64 * 64 * 4);
    q_submit(ctx, dw, n, fence);
    int head;
    uint32_t st = cmd_wait(NODATA, &head);
    snprintf(w, sizeof w, "%s: the clear is answered OK", tag);
    check(w, st, OK);
    uint32_t flags = rd32(RESP(head) + 4);
    uint64_t fid = rd32(RESP(head) + 8) | (uint64_t)rd32(RESP(head) + 12) << 32;
    snprintf(w, sizeof w, "%s: the answer carries the fence", tag);
    check(w, fence ? flags & 1 : 1, 1);
    if (fence) check("the fence id is echoed", fid, fence);
    q_transfer(0x206, ctx, res, 64, 64, fence + 1);
    st = cmd_wait(NODATA, NULL);
    snprintf(w, sizeof w, "%s: TRANSFER_FROM_HOST_3D is answered OK", tag);
    check(w, st, OK);
    snprintf(w, sizeof w, "%s: every pixel read back is the clear colour", tag);
    check(w, (uint64_t)pixels_are(back, 64, 64, rgba), 0);
}

static HvVgpuVirgl *rend;

static void test_caps(void) {
    q_hdr(0x108, 0, 0), q32(24, 0), rq_len = 32;
    int head;
    check("capset info 0 answered", cmd_wait(40, &head), OK_CAPSET_INFO);
    uint32_t id0 = rd32(RESP(head) + 24), ver0 = rd32(RESP(head) + 28), size0 = rd32(RESP(head) + 32);
    check("capset 0 is VIRGL", id0, 1);
    check("capset 0 has a version and a size", ver0 && size0, 1);
    q_hdr(0x108, 0, 0), q32(24, 1), rq_len = 32;
    check("capset info 1 answered", cmd_wait(40, &head), OK_CAPSET_INFO);
    uint32_t id1 = rd32(RESP(head) + 24), ver1 = rd32(RESP(head) + 28), size1 = rd32(RESP(head) + 32);
    check("capset 1 is VIRGL2", id1, 2);
    q_hdr(0x108, 0, 0), q32(24, 2), rq_len = 32;
    check("capset info 2 is refused", cmd_wait(40, NULL), 0x1205);
    q_hdr(0x109, 0, 0), q32(24, id1), q32(28, ver1), rq_len = 32;
    check("GET_CAPSET 2 answered", cmd_wait(24 + size1, &head), OK_CAPSET);
    // virgl_caps: max_version, four format masks, bset, then glsl_level (A3 saw 130 on this stack)
    check("the capset reports its version", rd32(RESP(head) + 24), ver1);
    uint32_t glsl = rd32(RESP(head) + 24 + 4 + 4 * 64 + 4);
    printf("  capset 2: glsl_level %u\n", glsl);
    check("the capset reports GLSL 130 or more", glsl >= 130, 1);
    q_hdr(0x109, 0, 0), q32(24, id0), q32(28, ver0), rq_len = 32;
    check("GET_CAPSET 1 answered", cmd_wait(24 + size0, NULL), OK_CAPSET);
}

static void test_clear(void) {
    check("ctx create", c_ctx_create(1, "a5"), OK);
    check("resource create", c_res_create(1, 64, 64), OK);
    check("attach backing", c_attach(1, BACKING, 64 * 64 * 4), OK);
    check("ctx attach resource", c_ctx_attach(0x202, 1, 1), OK);
    clear_and_read("blue", 1, 1, BLUE, BACKING, 100);
    // a second colour proves the first was not a stale read-back
    clear_and_read("red", 1, 1, RED, BACKING, 200);
    // unfenced too
    clear_and_read("blue again, unfenced", 1, 1, BLUE, BACKING, 0);
}

/* One context failing leaves the others alone, and the error is the request's alone. */
static void test_isolation(void) {
    check("a second context", c_ctx_create(2, "bad"), OK);
    check("a second resource", c_res_create(2, 64, 64), OK);
    check("its backing", c_attach(2, BACKING + 0x10000, 64 * 64 * 4), OK);
    check("ctx 2 attach", c_ctx_attach(0x202, 2, 2), OK);
    uint64_t errs0, req0;
    HvVgpuVirglStats s;
    hv_vgpu_virgl_stats(rend, &s), errs0 = s.errors, req0 = s.requests;
    uint32_t junk[] = {0xffffffff, 0x12345678, 0xdeadbeef, 0, 0, 0, 0, 0}; // a command of 65535 words in 8
    q_submit(2, junk, 8, 300);
    int head;
    check("junk on ctx 2 is answered with an error", cmd_wait(NODATA, &head), UNSPEC);
    check("the failed fenced request still carries its fence", rd32(RESP(head) + 4) & 1, 1);
    hv_vgpu_virgl_stats(rend, &s);
    check("the renderer counted one error", s.errors - errs0, 1);
    check("and one request", s.requests - req0, 1);
    clear_and_read("ctx 1 after ctx 2 failed", 1, 1, RED, BACKING, 400);
    check("ctx 2 is destroyed after its error", c_ctx_destroy(2), OK);
    check("the resource of ctx 2 is unref'd", c_res_unref(2), OK);
}

/* Many requests in flight on two contexts: all answered once, fenced ones in fence order. */
static void test_flood(void) {
    check("ctx 3", c_ctx_create(3, "flood"), OK);
    check("res 3", c_res_create(3, 64, 64), OK);
    check("ctx 3 attach", c_ctx_attach(0x202, 3, 3), OK);
    nreaped = 0;
    enum { N = 40 };
    int heads[N];
    uint64_t fences[N], nf = 0;
    for (int i = 0; i < N; i++) {
        uint32_t dw[32], n = clear_cmd(dw, 3, i & 1 ? RED : BLUE);
        uint32_t ctx = i % 5 == 4 ? 1 : 3;
        uint64_t fence = i % 3 == 0 ? 0 : 1000 + i;
        if (ctx == 1) { // the earlier resource on its own context
            n = clear_cmd(dw, 1, RED);
        }
        q_submit(ctx, dw, n, fence);
        heads[i] = post(NODATA);
        if (fence) fences[nf++] = fence;
    }
    kick();
    uint64_t t0 = now_ms();
    while (nreaped < N && now_ms() - t0 < 15000) {
        hv_virtio_gpu_poll(b.gpu);
        reap();
        usleep(200);
    }
    check("every request in the flood is answered", (uint64_t)nreaped, N);
    int allok = 1;
    for (int i = 0; i < N; i++) allok &= rd32(RESP(heads[i])) == OK;
    check("every answer is OK", allok, 1);
    // used-ring order of the fenced ones
    uint64_t last = 0;
    int ordered = 1, seen_f = 0;
    for (int k = 0; k < nreaped; k++) {
        uint32_t f = rd32(RESP(reaped[k].head) + 4);
        if (!(f & 1)) continue;
        uint64_t id = rd32(RESP(reaped[k].head) + 8);
        if (id < last) ordered = 0;
        last = id, seen_f++;
    }
    check("fenced answers come back in fence order", ordered, 1);
    check("all fenced answers arrived", (uint64_t)seen_f, nf);
    check("ctx 3 destroyed", c_ctx_destroy(3), OK);
    check("res 3 unref'd", c_res_unref(3), OK);
}

/* A reset with a context and resources alive: the renderer drops them, and the ids can be used again. */
static void test_reset(void) {
    HvVgpuVirglStats s0, s1;
    hv_vgpu_virgl_stats(rend, &s0);
    wr8(GPU_BAR + 0x14, 0); // the driver resets
    hv_vgpu_virgl_stats(rend, &s1);
    check("the reset sent unref and ctx destroy to the renderer", s1.requests - s0.requests, 2); // res 1, ctx 1
    driver_setup();
    check("ctx 1 again after the reset", c_ctx_create(1, "again"), OK);
    check("res 1 again", c_res_create(1, 64, 64), OK);
    check("backing again", c_attach(1, BACKING, 64 * 64 * 4), OK);
    check("attach again", c_ctx_attach(0x202, 1, 1), OK);
    clear_and_read("after a reset", 1, 1, BLUE, BACKING, 500);
    check("detach", c_detach(1), OK);
    check("unref with the backing already gone", c_res_unref(1), OK);
    check("ctx destroy", c_ctx_destroy(1), OK);
    check("ctx destroy of a gone context", c_ctx_destroy(1), 0x1204);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(240);
    if (!mkdtemp(dir)) return 1;
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_NO_SOUND", "1", 1);
    char path[256];
    snprintf(path, sizeof path, "%s/root", dir);
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, 1 << 20)) return 1;
    close(fd);
    static const uint8_t mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
    if (hv_disk_open(&root, path, 0, 0) != 0 || hv_machine_init(&m, 4 << 20) != 0 ||
        hv_virt_create(&b, &m, cpus, 1, 64ull << 20, &root, mac) != 0) {
        printf("cannot build the board\n");
        return 1;
    }
    hv_virt_reset(&b);

    rend = hv_vgpu_virgl_create();
    check("the renderer starts", rend != NULL, 1);
    if (!rend) {
        printf("%d checks, %d failures\n", checks, failures);
        return 1;
    }
    HvVgpuVirgl *second = hv_vgpu_virgl_create();
    check("a second renderer is refused", second == NULL, 1);
    HvVgpuVirglStats st;
    hv_vgpu_virgl_stats(rend, &st);
    printf("  GL_RENDERER: %s\n", st.gl_renderer);
    check("GL_RENDERER names ANGLE and Metal", strstr(st.gl_renderer, "ANGLE") && strstr(st.gl_renderer, "Metal"), 1);
    wr8(GPU_BAR + 0x14, 0);
    check("set_3d with the renderer", hv_virtio_gpu_set_3d(b.gpu, hv_vgpu_virgl_ops(), rend), 0);
    driver_setup();
    check("the driver took VIRGL", b.gpu->vio.driver_features & 1, 1);

    test_caps();
    test_clear();
    test_isolation();
    test_flood();
    test_reset();

    hv_vgpu_virgl_stats(rend, &st);
    printf("  renderer: %llu requests, %llu errors, %llu fences\n", (unsigned long long)st.requests, (unsigned long long)st.errors,
           (unsigned long long)st.fences);
    check("the only error was the junk", st.errors, 1);

    // Destroy order: the board (the device resets the renderer), then the renderer, then guest RAM.
    check("a context left live for the destroy", c_ctx_create(9, "left"), OK);
    check("a resource left live for the destroy", c_res_create(9, 8, 8), OK);
    hv_virt_destroy(&b);
    hv_vgpu_virgl_destroy(rend);
    hv_machine_free(&m);

    // Again: the renderer comes back in the same process.
    HvVgpuVirgl *again = hv_vgpu_virgl_create();
    check("a renderer starts again after destroy", again != NULL, 1);
    hv_vgpu_virgl_destroy(again);

    hv_disk_close(&root);
    char rm[300];
    snprintf(rm, sizeof rm, "rm -rf %s", dir);
    system(rm);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
