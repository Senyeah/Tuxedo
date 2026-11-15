// SPDX-License-Identifier: GPL-2.0-or-later
// A11 steps 1 and 2: can host memory be placed into, and taken out of, a RAM region that the guest uses?
// A 256 MB PROT_NONE reservation is a RAM region at a PA in the PCI window; vm_remap fills parts of it.
// Usage: window_probe [--hole]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include "harness.h"

DECLARE_PROGRAM(wrw);
DECLARE_PROGRAM(wld);
DECLARE_PROGRAM(wst);
DECLARE_PROGRAM(wspin);
extern const char win_programs_begin[], win_programs_finish[];

#define WIN_PA 0x20000000ull
#define WIN_SIZE (256ull << 20)
#define PG 0x4000ull
#define STACK_SIZE 65536

static HvMachine m;
static uint8_t *resv, *stack;
static int failures;

#define CHECK(cond, ...) do { int ok_ = !!(cond); printf("  %-4s %s", ok_ ? "ok" : "FAIL", #cond); printf(" " __VA_ARGS__); printf("\n"); failures += !ok_; } while (0)

static int map_into(uint64_t off, const void *src, uint64_t len) {
    vm_address_t to = (vm_address_t)(resv + off);
    vm_prot_t cur, max;
    return vm_remap(mach_task_self(), &to, len, 0, VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE);
}
static void unmap_zero(uint64_t off, uint64_t len) { mmap(resv + off, len, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0); }
static void unmap_none(uint64_t off, uint64_t len) { mmap(resv + off, len, PROT_NONE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0); }
static void *alloc_pages(uint64_t len) {
    vm_address_t a = 0;
    if (vm_allocate(mach_task_self(), &a, len, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NULL;
    return (void *)a;
}
static double now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static int guest(const TestProgram *p, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x8, uint64_t x9, HvCpu *out) {
    static HvCpu init;
    memset(&init, 0, sizeof init);
    seed_cpu(&init, 5, (uint64_t)(uintptr_t)stack + STACK_SIZE / 2);
    init.x[0] = x0;
    init.x[1] = x1;
    init.x[2] = x2;
    init.x[8] = x8;
    init.x[9] = x9;
    return run_jit(&m, p, &init, out, NULL);
}

static const TestProgram P_WRW = TEST_PROGRAM(wrw), P_WLD = TEST_PROGRAM(wld), P_WST = TEST_PROGRAM(wst), P_WSPIN = TEST_PROGRAM(wspin);
static HvCpu cpu;

/* Step 1 */
static void step1(void) {
    printf("step 1: guest access to vm_remap'd ordinary memory in a PROT_NONE reservation\n");
    const uint64_t off = 16ull << 20, gpa = WIN_PA + off;
    uint64_t *src = alloc_pages(PG);
    src[2] = 0xAAAA000000000002ull; /* +16 */
    src[4] = 0xBBBB000000000004ull; /* +32 */
    src[5] = 0xBBBB000000000005ull;
    int kr = map_into(off, src, PG);
    CHECK(kr == 0, "vm_remap = %d", kr);
    CHECK(guest(&P_WRW, gpa, 0x1111, 0x2222, 0x8888, 0x9999, &cpu) == 0, "guest ran");
    CHECK(src[0] == 0x1111 && src[0x3ff8 / 8] == 0x2222, "host sees the guest's stores (%llx %llx)", (unsigned long long)src[0], (unsigned long long)src[0x3ff8 / 8]);
    CHECK(cpu.x[5] == src[2] && cpu.x[6] == src[4] && cpu.x[7] == src[5], "guest read what the host wrote");
    CHECK(src[8] == 0x8888 && src[9] == 0x9999 && cpu.x[10] == 0x1111, "stp and read-back");
    src[1] = 0xCAFE;
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK(cpu.x[12] == 0xCAFE && cpu.x[11] == 0x1111, "host store after the guest ran is seen");
    guest(&P_WST, gpa, 0, 0x77, 0, 0, &cpu);
    CHECK(src[1] == 0, "a guest store of 0 replaced the host's 0xCAFE");
    /* A page just past the mapped 16 KB is still the PROT_NONE reservation: not touched here. */

    printf("  unmap to zero pages (what QEMU's unassigned memory looks like to a guest: reads 0, writes dropped)\n");
    unmap_zero(off, PG);
    src[1] = 0xD00D; src[0] = 0x5555;
    CHECK(guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu) == 0, "guest ran after unmap");
    CHECK(cpu.x[11] == 0 && cpu.x[12] == 0 && cpu.x[13] == 0, "reads are 0 (%llx %llx %llx)", (unsigned long long)cpu.x[11], (unsigned long long)cpu.x[12], (unsigned long long)cpu.x[13]);
    guest(&P_WST, gpa, 0x4242, 0, 0, 0, &cpu);
    CHECK(src[1] == 0xD00D && src[0] == 0x5555, "the source memory is unharmed by a write to the unmapped window");

    printf("  unmap to PROT_NONE, guest access in a child process\n");
    unmap_none(off, PG);
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    CHECK(WIFSIGNALED(st), "the child died of signal %d (11 SEGV, 10 BUS): the engine has no handler, so PROT_NONE is a crash", WIFSIGNALED(st) ? WTERMSIG(st) : 0);

    /* Remap again after the PROT_NONE phase: the window must be usable again. */
    kr = map_into(off, src, PG);
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK(kr == 0 && cpu.x[11] == src[0], "remap after unmap works");
}

/* A guest in a hot loop on one TLB entry, while the host swaps the memory behind that page. */
static uint64_t *spin_a, *spin_b;
static uint64_t spin_off;
static _Atomic int spin_done;
static void *swapper(void *arg) {
    (void)arg;
    usleep(150000);
    int kr = map_into(spin_off, spin_b, PG);
    if (kr) printf("  swapper: vm_remap = %d\n", kr);
    for (int i = 0; i < 50 && !spin_done; i++) usleep(100000);
    if (!spin_done) {
        printf("  FAIL the guest loop never saw the new memory (stale TLB entry or lost remap)\n");
        _exit(1);
    }
    return NULL;
}
static void step1_tlb(void) {
    printf("step 1b: TLB entry live while the host remaps the page under it\n");
    spin_off = 32ull << 20;
    spin_a = alloc_pages(PG);
    spin_b = alloc_pages(PG);
    spin_a[2] = 0xAAAA;
    spin_b[2] = 0xBBBB;
    map_into(spin_off, spin_a, PG);
    pthread_t t;
    pthread_create(&t, NULL, swapper, NULL);
    double t0 = now_us();
    int r = guest(&P_WSPIN, WIN_PA + spin_off, 0xAAAA, 0, 0, 0, &cpu);
    spin_done = 1;
    pthread_join(t, NULL);
    CHECK(r == 0 && cpu.x[5] == 0xBBBB, "the loop left with x5 = %llx after %.0f ms, with no TLB flush at all", (unsigned long long)cpu.x[5], (now_us() - t0) / 1000);
}

/* Raw loads through the window while the main thread flips the backing: vm_remap with OVERWRITE must never expose a hole. */
static _Atomic int flip_stop;
static _Atomic uint64_t flip_bad, flip_reads;
static void *flip_reader(void *arg) {
    volatile uint64_t *p = (volatile uint64_t *)(resv + (uintptr_t)arg + 16);
    while (!flip_stop) {
        uint64_t v = *p;
        flip_reads++;
        if (v != 0xAAAA && v != 0xBBBB) flip_bad++;
    }
    return NULL;
}
static void step1_flip(void) {
    printf("step 1c: concurrent reader while the backing flips between two memories\n");
    const uint64_t off = 48ull << 20;
    uint64_t *a = alloc_pages(PG), *b = alloc_pages(PG);
    a[2] = 0xAAAA;
    b[2] = 0xBBBB;
    map_into(off, a, PG);
    pthread_t t[3];
    for (int i = 0; i < 3; i++) pthread_create(&t[i], NULL, flip_reader, (void *)(uintptr_t)off);
    int fails = 0;
    double t0 = now_us();
    const int N = 20000;
    for (int i = 0; i < N; i++) fails += map_into(off, i & 1 ? a : b, PG) != 0;
    double dt = now_us() - t0;
    flip_stop = 1;
    for (int i = 0; i < 3; i++) pthread_join(t[i], NULL);
    CHECK(fails == 0 && flip_bad == 0, "%d flips (%.1f us each), %llu reads by 3 threads, %llu saw neither value, %d remap failures", N, dt / N,
          (unsigned long long)flip_reads, (unsigned long long)flip_bad, fails);
}

static void remap_cost(void) {
    printf("vm_remap cost (map and then unmap to zero pages, 16 KB pages)\n");
    static const uint64_t sizes[] = {PG, 64 << 10, 1 << 20, 16 << 20, 64 << 20};
    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
        uint8_t *src = alloc_pages(sizes[i]);
        memset(src, 1, sizes[i]);
        int n = sizes[i] >= (16 << 20) ? 20 : 200;
        double t0 = now_us();
        int fails = 0;
        for (int k = 0; k < n; k++) fails += map_into(64ull << 20, src, sizes[i]) != 0;
        double t1 = now_us();
        for (int k = 0; k < n; k++) unmap_zero(64ull << 20, sizes[i]);
        double t2 = now_us();
        printf("  %8llu KB: map %8.1f us, unmap %8.1f us%s\n", (unsigned long long)(sizes[i] >> 10), (t1 - t0) / n, (t2 - t1) / n, fails ? " (FAILED)" : "");
        vm_deallocate(mach_task_self(), (vm_address_t)src, sizes[i]);
    }
}

/* Step 2 */
static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
                               "kernel void fill(device uint *p [[buffer(0)]], constant uint &seed [[buffer(1)]], uint i [[thread_position_in_grid]]) { p[i] = seed + i; }\n"
                               "kernel void incr(device uint *p [[buffer(0)]], uint i [[thread_position_in_grid]]) { p[i] += 1; }\n";
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> pfill, pincr;

static int gpu_init(void) {
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) return -1;
    queue = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
    if (!lib) { printf("shader: %s\n", err.localizedDescription.UTF8String); return -1; }
    pfill = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill"] error:&err];
    pincr = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"incr"] error:&err];
    return pfill && pincr ? 0 : -1;
}
static int gpu_run(id<MTLBuffer> b, NSUInteger words, id<MTLComputePipelineState> ps, uint32_t seed) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps];
    [e setBuffer:b offset:0 atIndex:0];
    if (ps == pfill) [e setBytes:&seed length:4 atIndex:1];
    [e dispatchThreads:MTLSizeMake(words, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted ? 0 : (int)cb.status + 100;
}

static void step2(void) {
    printf("step 2a: the source is a shared MTLBuffer (the memory Vulkan would allocate), mapped into the window\n");
    id<MTLBuffer> buf = [dev newBufferWithLength:4 * PG options:MTLResourceStorageModeShared];
    uint8_t *c = buf.contents;
    printf("  buffer contents %p, page aligned (16 KB): %d\n", c, ((uintptr_t)c & (PG - 1)) == 0);
    const uint64_t off = 80ull << 20, gpa = WIN_PA + off;
    int kr = map_into(off, c, 4 * PG);
    printf("  vm_remap of the buffer's pages: %d (%s)\n", kr, kr == 0 ? "ok" : mach_error_string(kr));
    if (kr) { CHECK(kr == 0, "buffer memory can be vm_remap'd"); return; }
    CHECK(gpu_run(buf, 4 * PG / 4, pfill, 0x10000) == 0, "GPU fill ran");
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK(cpu.x[11] == (0x10000ull | (0x10001ull << 32)) && cpu.x[13] == (0x10000ull + 4094) + ((0x10000ull + 4095) << 32), "guest sees what the GPU wrote (%llx %llx)", (unsigned long long)cpu.x[11], (unsigned long long)cpu.x[13]);
    guest(&P_WST, gpa, 0x7777, 0, 0, 0, &cpu);
    guest(&P_WRW, gpa, 0x3131, 0x4141, 0x5151, 0x6161, &cpu);
    CHECK(((uint64_t *)c)[0] == 0x3131, "[buffer contents] sees the guest's store");
    CHECK(gpu_run(buf, 4 * PG / 4, pincr, 0) == 0, "GPU incr ran");
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK((uint32_t)cpu.x[11] == 0x3132, "guest sees the GPU's increment of its own store (%llx)", (unsigned long long)cpu.x[11]);
    unmap_zero(off, 4 * PG);
    CHECK(((uint64_t *)c)[0] != 0 && (uint32_t)((uint64_t *)c)[0] == 0x3132, "the buffer is intact after the window unmapped");

    printf("step 2b: memory in the window first, then wrapped with newBufferWithBytesNoCopy\n");
    const uint64_t off2 = 96ull << 20, gpa2 = WIN_PA + off2, len2 = 2 * PG;
    uint8_t *mem = alloc_pages(len2);
    memset(mem, 0, len2);
    kr = map_into(off2, mem, len2);
    CHECK(kr == 0, "map ordinary memory into the window: %d", kr);
    id<MTLBuffer> nb = [dev newBufferWithBytesNoCopy:resv + off2 length:len2 options:MTLResourceStorageModeShared deallocator:nil];
    CHECK(nb != nil, "newBufferWithBytesNoCopy over window memory");
    if (!nb) return;
    CHECK(nb.contents == resv + off2, "same pointer, no copy");
    CHECK(gpu_run(nb, len2 / 4, pfill, 0x20000) == 0, "GPU fill into the window-backed buffer");
    guest(&P_WLD, gpa2, 0, 0, 0, 0, &cpu);
    CHECK(cpu.x[11] == (0x20000ull | (0x20001ull << 32)) && cpu.x[13] == (0x20000ull + 4094) + ((0x20000ull + 4095) << 32), "guest sees the GPU's fill (%llx)", (unsigned long long)cpu.x[11]);
    CHECK(((uint32_t *)mem)[5] == 0x20005, "the source memory sees it too");
    guest(&P_WRW, gpa2, 0xAB, 0xCD, 0, 0, &cpu);
    CHECK(gpu_run(nb, len2 / 4, pincr, 0) == 0, "GPU incr ran");

    printf("step 2c: the window is remapped to other memory while a GPU buffer wraps the old pages (the VkDeviceMemory outlives RESOURCE_UNMAP_BLOB)\n");
    uint8_t *other = alloc_pages(len2);
    memset(other, 0, len2);
    kr = map_into(off2, other, len2);
    CHECK(kr == 0, "overwrite pages that a buffer wraps: %d", kr);
    uint32_t before_mem = ((uint32_t *)mem)[7];
    CHECK(gpu_run(nb, len2 / 4, pincr, 0) == 0, "GPU incr after the remap");
    printf("  word 7 of the old pages %x -> %x; of the new pages %x\n", before_mem, ((uint32_t *)mem)[7], ((uint32_t *)other)[7]);
    CHECK(((uint32_t *)mem)[7] == before_mem + 1 && ((uint32_t *)other)[7] == 0, "the buffer stays on the OLD pages, the guest sees the NEW ones");
    guest(&P_WLD, gpa2, 0, 0, 0, 0, &cpu);
    CHECK(cpu.x[11] == 0, "guest reads the new pages (0)");
}


/* The path the pinned virglrenderer takes for host-visible Venus memory on macOS: a POSIX shm file imported into Vulkan as host
   memory (a MTLBuffer without copy over its mapping), and an fd handed out for the window. */
static void step2e(void) {
    printf("step 2e: Venus host-visible memory: shm fd, MTLBuffer over one mapping, the window over the fd\n");
    char name[64];
    snprintf(name, sizeof name, "/tux-a11-%d", getpid());
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    shm_unlink(name);
    const uint64_t len = 4 * PG, off = 112ull << 20, gpa = WIN_PA + off;
    CHECK(fd >= 0 && ftruncate(fd, len) == 0, "anonymous shm file of %llu KB", (unsigned long long)(len >> 10));
    uint8_t *host = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    CHECK(host != MAP_FAILED && ((uintptr_t)host & (PG - 1)) == 0, "host mapping %p is 16 KB aligned", host);
    id<MTLBuffer> nb = [dev newBufferWithBytesNoCopy:host length:len options:MTLResourceStorageModeShared deallocator:nil];
    CHECK(nb != nil, "newBufferWithBytesNoCopy over the shm mapping (what MoltenVK's host-pointer import makes)");
    void *w = mmap(resv + off, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    CHECK(w == resv + off, "mmap of the fd over the reservation at a fixed address");
    if (!nb || w == MAP_FAILED) return;
    CHECK(gpu_run(nb, len / 4, pfill, 0x30000) == 0, "GPU fill");
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK(cpu.x[11] == (0x30000ull | (0x30001ull << 32)), "guest sees the GPU's bytes through the second mapping (%llx)", (unsigned long long)cpu.x[11]);
    guest(&P_WRW, gpa, 0x6161, 0x6262, 0, 0, &cpu);
    CHECK(gpu_run(nb, len / 4, pincr, 0) == 0 && ((uint32_t *)host)[0] == 0x6162, "GPU sees the guest's store and increments it");
    unmap_zero(off, len);
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK(cpu.x[11] == 0 && ((uint32_t *)host)[0] == 0x6162, "unmap of the window leaves the shm memory alone");
    /* The same through vm_remap of the host mapping instead of mmap of the fd. */
    CHECK(map_into(off, host, len) == 0, "vm_remap of the shm mapping works too");
    guest(&P_WLD, gpa, 0, 0, 0, 0, &cpu);
    CHECK((uint32_t)cpu.x[11] == 0x6162, "and the guest sees it");
}

static void hole(void) {
    printf("step 2d: newBufferWithBytesNoCopy over a range with a PROT_NONE hole\n");
    const uint64_t off = 96ull << 20, len = 2 * PG;
    uint8_t *mem = alloc_pages(PG);
    memset(mem, 0, PG);
    map_into(off, mem, PG);
    id<MTLBuffer> nb = [dev newBufferWithBytesNoCopy:resv + off length:len options:MTLResourceStorageModeShared deallocator:nil];
    printf("  buffer over mapped page + hole: %s\n", nb ? "created" : "nil");
    if (nb) {
        int r = gpu_run(nb, PG / 4, pfill, 1);
        printf("  GPU fill over the mapped page only: %d\n", r);
        r = gpu_run(nb, len / 4, pfill, 1);
        printf("  GPU fill over both pages: %d\n", r);
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setenv("HV_GROUPS", "1", 0);
    stack = aligned_alloc(PG, STACK_SIZE);
    resv = mmap(NULL, WIN_SIZE, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (resv == MAP_FAILED || hv_machine_init(&m, 8 << 20) != 0) return 2;
    uint64_t code = (uint64_t)(uintptr_t)win_programs_begin;
    hv_machine_add_ram(&m, code, win_programs_finish - win_programs_begin, (void *)win_programs_begin, 1);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, STACK_SIZE, stack, 0);
    hv_machine_add_ram(&m, WIN_PA, WIN_SIZE, resv, 0);
    printf("window: 256 MB RAM region at PA 0x%llx, host %p, 16 KB TLB pages\n", (unsigned long long)WIN_PA, resv);
    if (argc > 1 && !strcmp(argv[1], "--hole")) {
        if (gpu_init()) return 2;
        hole();
        return 0;
    }
    step1();
    step1_tlb();
    step1_flip();
    remap_cost();
    if (gpu_init()) { printf("no Metal device\n"); return 2; }
    step2();
    step2e();
    printf("%d failures\n", failures);
    return failures != 0;
}
