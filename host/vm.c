#include "vm.h"
#include "linux_boot.h"
#include "pvg_lite.h"
#include "vgpu_metal.h"
#include "virt.h"
#ifdef HV_GFX
#include "vgpu_virgl.h"
#endif

#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <stdio.h>
#include <time.h>

#include "usb_host.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "audio_mac.h"
#include "dispatch.h"
#include "net_slirp.h"

static HvMachine m;
static HvCpu cpus[HV_MAX_CPUS]; /* the board takes them as an array */
static int ncpus = 1;
static HvVmapple board = {.ram_fd = -1};
static HvVirt virt = {.mem.fd = -1};
static int board_kind = HV_BOARD_VMAPPLE;
static HvBoardDevs devs;
static _Atomic int input_stopping = 1;
static void stop_pointer(void);
/* UI display changes may arrive before or during the background machine creation. */
static os_unfair_lock display_lock = OS_UNFAIR_LOCK_INIT;
static CFTypeRef display_layer;
static int display_layer_set;
static uint32_t display_w, display_h, display_mm_w, display_mm_h;
static int display_mode_set, display_mm_set;
static _Atomic(const HvBoardDevs *) display_devs; /* published only when the board is ready */
typedef struct VgpuDisplay { HvVirtioGpu *gpu; HvVgpuMetal *presenter; } VgpuDisplay;
static VgpuDisplay vgpu;
#ifdef HV_GFX
static HvVgpuVirgl *virgl; /* the renderer behind vgpu.gpu (--gpu-accel) */
#endif
static HvDisk disk = {.fd = -1, .wfd = -1}, aux = {.fd = -1, .wfd = -1};
static int machine_created, signals_installed;
static uint64_t boot_args_offset;
static double boot_last_scan;
static int net_on;
static void (*extra_poll)(void);
static void (*exit_cb)(int);
static pthread_t secondary_threads[HV_MAX_CPUS], kicker;
static int secondary_started[HV_MAX_CPUS], kicker_started;
static _Atomic int kicker_stopped;
static pthread_t primary_thread;
static int primary_started;

HvMachine *hv_vm_machine(void) { return &m; }
HvVmapple *hv_vm_board(void) { return board_kind == HV_BOARD_VMAPPLE ? &board : NULL; }
HvVirt *hv_vm_virt(void) { return machine_created && board_kind == HV_BOARD_VIRT ? &virt : NULL; }
const HvBoardDevs *hv_vm_devs(void) { return &devs; }
HvCpu *hv_vm_cpu(int index) { return index >= 0 && index < ncpus ? &cpus[index] : NULL; }
int hv_vm_ncpus(void) { return ncpus; }

/* vmapple: Apple's paravirtual GPU. Its mode is global and read when the guest's driver starts. */
static void pvg_set_layer(void *d, void *layer) { hv_pvg_lite_set_layer(d, layer); }
static uint64_t pvg_frames(void *d) { return hv_pvg_lite_gpu_frames(d); }
static int pvg_snapshot(void *d, uint8_t *bgra, uint32_t w, uint32_t h) { return hv_pvg_lite_snapshot(d, bgra, w, h); }
static int pvg_pointer(void *d, int *x, int *y) {
    const uint8_t *page = hv_pvg_lite_display_page(d);
    if (!page) return -1;
    uint32_t at = *(const volatile uint32_t *)(page + 0xe00);
    if (at == 0xffffffff) return -1;
    *x = (int)(at & 0xffff), *y = (int)(at >> 16);
    return 0;
}
static void pvg_set_mode(void *d, uint32_t w, uint32_t h) { (void)d, hv_pvg_lite_set_mode(w, h); }
static void pvg_set_size_mm(void *d, uint32_t w, uint32_t h) { (void)d, hv_pvg_lite_set_size_mm(w, h); }
static const HvDisplayOps pvg_display = {pvg_set_layer, pvg_frames, pvg_snapshot, pvg_pointer, pvg_set_mode, pvg_set_size_mm};

/* virt: the virtio GPU and its presenter, which is NULL without Metal. */
static void vgpu_set_layer(void *d, void *layer) { hv_vgpu_metal_set_layer(((VgpuDisplay *)d)->presenter, layer); }
static uint64_t vgpu_frames(void *d) { return hv_vgpu_metal_frames(((VgpuDisplay *)d)->presenter); }
static int vgpu_snapshot(void *d, uint8_t *bgra, uint32_t w, uint32_t h) {
    return hv_vgpu_metal_snapshot(((VgpuDisplay *)d)->presenter, bgra, w, h);
}
static int vgpu_pointer(void *d, int *x, int *y) {
    HvVirtioGpu *g = ((VgpuDisplay *)d)->gpu;
    pthread_mutex_lock(&g->mu);
    int shown = g->cursor.resource != 0;
    /* The cursor's position is its image's top left; the pointer is at the hot spot. */
    if (shown) *x = g->cursor.x + (int)g->cursor.hot_x, *y = g->cursor.y + (int)g->cursor.hot_y;
    pthread_mutex_unlock(&g->mu);
    return shown ? 0 : -1;
}
static void vgpu_set_mode(void *d, uint32_t w, uint32_t h) { hv_virtio_gpu_set_mode(((VgpuDisplay *)d)->gpu, w, h); }
static const HvDisplayOps vgpu_display = {vgpu_set_layer, vgpu_frames, vgpu_snapshot, vgpu_pointer, vgpu_set_mode, NULL};

static const HvBoardDevs *shown_display(void) { return atomic_load_explicit(&display_devs, memory_order_acquire); }

/* arm64 boot_args: {u16 Revision, u16 Version, u64 virtBase, physBase, memSize,
   topOfKernelData, Video {baseAddr, display, rowBytes, width, height, depth}, ...}.
   Found by scanning page starts for one whose physBase is the RAM base. */
int hv_vm_boot_display(HvBootDisplay *d) {
    /* What the guest's GPU has drawn, once it has drawn anything. */
    const HvBoardDevs *shown = shown_display();
    if (!shown || shown->display != &pvg_display) return -1; /* virt: the console covers the time before a frame */
    HvPvgLite *pvg = shown->display_opaque;
    const uint8_t *frame;
    uint32_t fw, fh;
    if (hv_pvg_lite_frame(pvg, &frame, &fw, &fh) == 0) {
        d->pixels = (uint8_t *)frame;
        d->width = fw, d->height = fh, d->stride = fw * 4;
        return 0;
    }
    uint8_t *ram = board.ram;
    uint64_t size = board.ram_size;
    if (!ram || board_kind != HV_BOARD_VMAPPLE) return -1;
    for (int pass = 0; pass < 2; pass++) {
        if (!boot_args_offset || pass) {
            /* A full scan at most every 2 s; boot_args sits low in RAM
               (iBoot puts it near 0x78ed0000), so the first GB is enough. */
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            double now = ts.tv_sec + ts.tv_nsec * 1e-9;
            if (now - boot_last_scan < 2) return -1;
            boot_last_scan = now;
            if (pass && boot_args_offset) boot_args_offset = 0;
            uint64_t limit = size < (1ull << 30) ? size : 1ull << 30;
            for (uint64_t off = 0; off + 0x1000 <= limit && !boot_args_offset; off += 0x4000) {
                const uint64_t *q = (const uint64_t *)(ram + off);
                const uint16_t *h = (const uint16_t *)(ram + off);
                if (h[0] < 2 || h[0] > 3 || h[1] < 1 || h[1] > 3) continue; /* boot_args: revision, version */
                if (q[1] >> 40 != 0xfffffe || q[2] < VMAPPLE_MEM || q[2] >= VMAPPLE_MEM + size || q[3] == 0 || q[3] > size) continue;
                uint64_t base = q[5], row = q[7], w = q[8], hh = q[9], depth = q[10];
                if (w < 320 || w > 8192 || hh < 200 || hh > 8192 || row < w * 4 || (depth & 0xff) != 32) continue;
                if (base < VMAPPLE_MEM || base - VMAPPLE_MEM + row * hh > size) continue;
                boot_args_offset = off;
            }
        }
        if (!boot_args_offset) return -1;
        const uint64_t *q = (const uint64_t *)(ram + boot_args_offset);
        uint64_t base = q[5], row = q[7], w = q[8], hh = q[9];
        if (q[1] >> 40 == 0xfffffe && w >= 320 && w <= 8192 && hh >= 200 && hh <= 8192 && base >= VMAPPLE_MEM &&
            base - VMAPPLE_MEM + row * hh <= size) {
            d->pixels = ram + (base - VMAPPLE_MEM);
            d->width = (uint32_t)w, d->height = (uint32_t)hh, d->stride = (uint32_t)row;
            return 0;
        }
    }
    return -1;
}
void hv_vm_set_poll(void (*poll)(void)) { extra_poll = poll; }

const char *hv_vm_reason_name(int r) {
    switch (r) {
    case HV_EXIT_HALT: return "halt";
    case HV_EXIT_WFI: return "wfi with nothing to wake it";
    case HV_EXIT_UNSUPPORTED: return "unsupported";
    case HV_EXIT_FAULT_LOOP: return "fault on the exception vector";
    default: return "other";
    }
}

/* Console input waits here until the UART's 64-byte FIFO has room. Lock order: device lock, then this. */
static os_unfair_lock console_lock = OS_UNFAIR_LOCK_INIT;
static uint8_t *console_queue;
static size_t console_head, console_len, console_cap;
static void (*console_out)(void *opaque, uint8_t c);
static void *console_out_opaque;
static void (*uart_own_out)(void *opaque, uint8_t c);
static void *uart_own_opaque;

/* Under the device lock. */
static void console_apply_output(void) {
    if (!devs.uart) return;
    devs.uart->output = console_out ? console_out : uart_own_out;
    devs.uart->output_opaque = console_out ? console_out_opaque : uart_own_opaque;
}

static void console_attach(void) {
    if (!devs.uart) return;
    uart_own_out = devs.uart->output, uart_own_opaque = devs.uart->output_opaque;
    console_apply_output();
}

void hv_vm_console_set_output(void (*out)(void *opaque, uint8_t c), void *opaque) {
    int live = machine_created && devs.uart;
    if (live) hv_dev_lock(&m);
    console_out = out, console_out_opaque = opaque;
    if (live) console_apply_output();
    if (live) hv_dev_unlock(&m);
}

void hv_vm_console_input(const uint8_t *bytes, size_t n) {
    if (!n) return;
    os_unfair_lock_lock(&console_lock);
    if (console_head && console_len + n > console_cap) {
        memmove(console_queue, console_queue + console_head, console_len - console_head);
        console_len -= console_head, console_head = 0;
    }
    if (console_len + n > console_cap) {
        size_t cap = console_cap ? console_cap : 4096;
        while (cap < console_len + n) cap *= 2;
        uint8_t *grown = realloc(console_queue, cap);
        if (!grown) {
            os_unfair_lock_unlock(&console_lock);
            return;
        }
        console_queue = grown, console_cap = cap;
    }
    memcpy(console_queue + console_len, bytes, n);
    console_len += n;
    os_unfair_lock_unlock(&console_lock);
    if (!atomic_load(&input_stopping)) hv_machine_wake(&m); /* a CPU in WFI ticks only when woken */
}

/* Under the device lock, from the board's tick. */
static void console_pump(void) {
    if (!devs.uart) return;
    os_unfair_lock_lock(&console_lock);
    while (console_head < console_len && hv_pl011_receive(devs.uart, console_queue[console_head])) console_head++;
    if (console_head == console_len) console_head = console_len = 0;
    os_unfair_lock_unlock(&console_lock);
}

static void console_reset(void) {
    console_out = NULL, console_out_opaque = NULL;
    uart_own_out = NULL, uart_own_opaque = NULL;
    os_unfair_lock_lock(&console_lock);
    free(console_queue);
    console_queue = NULL;
    console_head = console_len = console_cap = 0;
    os_unfair_lock_unlock(&console_lock);
}

/* Host-side device work on CPU 0's thread each tick. */
static void board_poll(void) {
    if (extra_poll) extra_poll();
    if (net_on) hv_net_poll();
    console_pump();
}

static int fail(char *err, size_t n, const char *msg) {
    if (err && n) snprintf(err, n, "%s", msg);
    return -1;
}

/* A branch landing where no translation is (an illegal instruction, or a fault
   fetching one): say where, and which direct branches in translated code lead
   there, for a crash report cannot. */
static struct sigaction prior_ill, prior_bus, prior_segv;
static void on_ill(int sig, siginfo_t *info, void *ctx) {
    ucontext_t *uc = ctx;
    uint64_t pc = uc->uc_mcontext->__ss.__pc, rx = (uint64_t)(uintptr_t)m.jit.base, size = (uint64_t)m.jit.capacity * 4;
    uint64_t used = (uint64_t)m.jit.used * 4;
    int in_rx = pc >= rx && pc < rx + size;
    int fetch = (uint64_t)(uintptr_t)info->si_addr == pc;
    if (sig == SIGILL || in_rx || fetch) {
        fprintf(stderr, "hengevm: signal %d in translated code: pc %llx (rx %llx size %llx used %llx, pc is rx%+lld), full flushes %llu, lr %llx, addr %p\n",
                sig, (unsigned long long)pc, (unsigned long long)rx, (unsigned long long)size, (unsigned long long)used, (long long)(pc - rx),
                (unsigned long long)m.stats.block_flushes, (unsigned long long)uc->uc_mcontext->__ss.__lr, info->si_addr);
        for (int i = 0; i < 29; i++) fprintf(stderr, "x%d=%llx%c", i, (unsigned long long)uc->uc_mcontext->__ss.__x[i], i % 6 == 5 ? '\n' : ' ');
        fprintf(stderr, "\n");
        fprintf(stderr, "sp=%llx ram %llx size %llx\n", (unsigned long long)uc->uc_mcontext->__ss.__sp, (unsigned long long)(uintptr_t)devs.ram, (unsigned long long)devs.ram_size);
        {
            uint64_t x7 = uc->uc_mcontext->__ss.__x[7], x28 = uc->uc_mcontext->__ss.__x[28];
            if (x7 >= x28 && x7 < x28 + sizeof(HvCpu)) {
                const uint64_t *ent = (const uint64_t *)(uintptr_t)(x7 + 0x500);
                fprintf(stderr, "tlb entry at +%llx:", (unsigned long long)(x7 - x28));
                for (int i = 0; i < 16; i++) fprintf(stderr, " %llx", (unsigned long long)ent[i]);
                fprintf(stderr, "\n");
            }
        }
        for (int i = 0; i < ncpus; i++)
            fprintf(stderr, "  cpu %d: guest pc %llx el%u miss site %llx\n", i, (unsigned long long)cpus[i].pc, cpus[i].el, (unsigned long long)cpus[i].miss_site);
        if (in_rx) { /* the code it ran up to here, as it stands */
            uint64_t from = pc - 0x300 < rx ? rx : pc - 0x300;
            fprintf(stderr, "  words from rx+%llx:", (unsigned long long)(from - rx));
            for (uint64_t at = from; at < pc + 0x600 && at < rx + size; at += 4) {
                if (((at - from) & 0x1f) == 0) fprintf(stderr, "\n   ");
                fprintf(stderr, " %08x", *(const uint32_t *)(uintptr_t)at);
            }
            fprintf(stderr, "\n");
        }
        { /* x15 after a chained exit's check: the literal it loaded. Which exits, and where do they go now? */
            uint64_t x15 = uc->uc_mcontext->__ss.__x[15];
            const uint32_t *w15 = (const uint32_t *)(uintptr_t)rx;
            uint64_t n15 = used / 4 < m.jit.capacity ? used / 4 : m.jit.capacity;
            int shown = 0;
            for (uint64_t k = 0; k + 8 < n15 && shown < 12; k++) {
                if ((w15[k] & 0xff00001fu) != 0x5800000fu) continue; /* ldr x15, literal */
                int64_t lo = (int64_t)(int32_t)(w15[k] << 8) >> 13;
                uint64_t at = k + (uint64_t)lo;
                if (at + 1 >= n15) continue;
                uint64_t lit = w15[at] | (uint64_t)w15[at + 1] << 32;
                if (lit != x15) continue;
                /* eor x6; orr; cbnz; B */
                uint32_t b = w15[k + 4];
                if ((b & 0xfc000000u) != 0x14000000u) continue;
                int64_t off = (int64_t)(b << 6) >> 6;
                fprintf(stderr, "  exit at rx+%llx: B word %08x to rx+%llx\n", (unsigned long long)(k + 4) * 4, b, (unsigned long long)((int64_t)(k + 4) + off) * 4);
                shown++;
            }
        }
        if (!in_rx || pc >= rx + used) {
            /* Who branches there? */
            const uint32_t *w = (const uint32_t *)(uintptr_t)rx;
            int found = 0;
            uint64_t words = used / 4 < m.jit.capacity ? used / 4 : m.jit.capacity;
            for (uint64_t k = 0; k < words && found < 8; k++) {
                uint32_t i = w[k];
                int64_t off;
                if ((i & 0x7c000000u) == 0x14000000u) off = (int64_t)(i << 6) >> 6;
                else if ((i & 0xff000010u) == 0x54000000u || (i & 0x7e000000u) == 0x34000000u) off = (int64_t)(int32_t)(i << 8) >> 13;
                else if ((i & 0x7e000000u) == 0x36000000u) off = (int64_t)(int32_t)(i << 13) >> 18;
                else continue;
                if (rx + k * 4 + (uint64_t)(off * 4) != pc && rx + k * 4 + (uint64_t)(off * 4) != pc - 4) continue;
                found++;
                fprintf(stderr, "  branch at rx+%llx (word %08x) leads there; around it:", (unsigned long long)k * 4, i);
                for (int64_t d = -6; d <= 3; d++)
                    if ((int64_t)k + d >= 0 && (uint64_t)((int64_t)k + d) < words) fprintf(stderr, " %08x", w[k + d]);
                fprintf(stderr, "\n");
            }
            if (!found) fprintf(stderr, "  no direct branch in %llu MB of code leads there\n", (unsigned long long)(used >> 20));
            /* Which slot or cache entry holds it? */
            for (uint32_t k = 0; k < m.max_slots; k++)
                if (m.slots && m.slots[k] == pc) fprintf(stderr, "  chain slot %u holds it\n", k);
        }
        fflush(stderr);
    }
    struct sigaction *prior = sig == SIGILL ? &prior_ill : sig == SIGBUS ? &prior_bus : &prior_segv;
    sigaction(sig, prior, NULL);
}

void (*hv_prof_register)(void);

void hv_vm_set_display_layer(void *layer) {
    CFTypeRef retained = layer ? CFRetain(layer) : NULL;
    os_unfair_lock_lock(&display_lock);
    CFTypeRef previous = display_layer;
    display_layer = retained;
    display_layer_set = 1;
    const HvBoardDevs *shown = shown_display();
    if (shown && shown->display) shown->display->set_layer(shown->display_opaque, layer);
    os_unfair_lock_unlock(&display_lock);
    if (previous) CFRelease(previous);
}

uint64_t hv_vm_gpu_frames(void) {
    const HvBoardDevs *shown = shown_display();
    return shown && shown->display ? shown->display->frames(shown->display_opaque) : 0;
}

void hv_vm_set_display_mode(uint32_t width, uint32_t height) {
    os_unfair_lock_lock(&display_lock);
    display_w = width, display_h = height, display_mode_set = 1;
    const HvBoardDevs *shown = shown_display();
    if (shown && shown->display) shown->display->set_mode(shown->display_opaque, width, height);
    os_unfair_lock_unlock(&display_lock);
}

void hv_vm_set_display_size_mm(uint32_t width_mm, uint32_t height_mm) {
    os_unfair_lock_lock(&display_lock);
    display_mm_w = width_mm, display_mm_h = height_mm, display_mm_set = 1;
    const HvBoardDevs *shown = shown_display();
    if (shown && shown->display && shown->display->set_size_mm)
        shown->display->set_size_mm(shown->display_opaque, width_mm, height_mm);
    os_unfair_lock_unlock(&display_lock);
}

static void publish_display(void) {
    // The setters and publication share this lock: an older preboot target can
    // never overwrite a monitor change made while the board was being built.
    os_unfair_lock_lock(&display_lock);
    const HvDisplayOps *ops = devs.display;
    if (ops && display_mode_set) ops->set_mode(devs.display_opaque, display_w, display_h);
    if (ops && display_mm_set && ops->set_size_mm) ops->set_size_mm(devs.display_opaque, display_mm_w, display_mm_h);
    if (ops && display_layer_set) ops->set_layer(devs.display_opaque, (void *)display_layer);
    atomic_store_explicit(&display_devs, &devs, memory_order_release);
    os_unfair_lock_unlock(&display_lock);
}

static int create_vmapple(const HvVmConfig *c, uint64_t ram_size, char *err, size_t errlen) {
    if (hv_disk_open(&aux, c->aux, c->aux_offset ? c->aux_offset : 16384, 0) != 0)
        return fail(err, errlen, "Cannot open the auxiliary storage.");
    HvCfgParams cfg = {.nr_cpus = (uint32_t)ncpus, .ecid = c->ecid, .seed = c->seed, .mac_en0 = {0x02, 0x48, 0x56, 0x4d, 0x00, 0x01}};
    if (c->installer) cfg.run_installer1 = cfg.run_installer2 = 1;
    if (getenv("HV_RUN_INSTALLER")) { /* experiment: "a,b" for the two installer words */
        unsigned a = 0, b2 = 0;
        sscanf(getenv("HV_RUN_INSTALLER"), "%u,%u", &a, &b2);
        cfg.run_installer1 = a, cfg.run_installer2 = b2;
    }
    static const uint8_t mac[6] = {0x02, 0x48, 0x56, 0x4d, 0x00, 0x01};
    if (hv_vmapple_create(&board, &m, cpus, ram_size, &disk, &aux, &cfg, mac) != 0)
        return fail(err, errlen, "Cannot build the machine (not enough memory for the guest's RAM?).");
    if (hv_vmapple_load_rom(&board, c->rom) != 0) return fail(err, errlen, "Cannot read the ROM (AVPBooter.vmapple2.bin).");
    hv_vmapple_reset_cpu(&board);
    devs = (HvBoardDevs){.gic = board.gic, .uart = board.uart, .gpio = board.gpio, .usb = board.usb,
                         .keyboard = board.keyboard, .mouse = board.mouse, .net = board.net, .snd = board.snd,
                         .balloon = board.balloon, .blk = {board.root_blk, board.aux_blk},
                         .ram = board.ram, .ram_pa = VMAPPLE_MEM, .ram_size = board.ram_size,
                         .display = board.pvg ? &pvg_display : NULL, .display_opaque = board.pvg};
    board.poll = board_poll;
    if (board.vusb && getenv("HV_VUSB_PROBE")) hv_usb_probe_start(board.vusb);
    publish_display();
    return 0;
}

static int create_virt(const HvVmConfig *c, uint64_t ram_size, char *err, size_t errlen) {
    static const uint8_t mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56}; /* QEMU's default */
    if (hv_virt_create(&virt, &m, cpus, ncpus, ram_size, c->disk ? &disk : NULL, mac) != 0)
        return fail(err, errlen, "Cannot build the machine (not enough memory for the guest's RAM?).");
    if (c->rom) {
        if (hv_virt_load_firmware(&virt, c->rom) != 0) return fail(err, errlen, "Cannot read the firmware (at most 64 MB).");
        uint32_t size = 0;
        uint8_t *fdt = hv_virt_build_fdt(&virt, NULL, 0, 0, &size);
        int placed = hv_virt_place_fdt(&virt, fdt, size);
        free(fdt);
        if (placed != 0) return fail(err, errlen, "Cannot build the device tree.");
    }
    hv_virt_reset(&virt);
    if (c->kernel && hv_linux_boot(&virt, c->kernel, c->initrd, c->cmdline, NULL, err, errlen) != 0) return -1;
    devs = (HvBoardDevs){.gic = virt.gic, .uart = virt.uart, .gpio = virt.gpio, .usb = virt.usb,
                         .keyboard = virt.keyboard, .mouse = virt.mouse, .net = virt.net, .snd = virt.snd,
                         .balloon = virt.balloon, .blk = {virt.blk, NULL},
                         .ram = virt.mem.host, .ram_pa = VIRT_MEM, .ram_size = virt.mem.size};
    virt.poll = board_poll;
    if (virt.gpu) {
        vgpu = (VgpuDisplay){.gpu = virt.gpu, .presenter = hv_vgpu_metal_create(virt.gpu)};
        devs.display = &vgpu_display, devs.display_opaque = &vgpu;
        if (c->accel) {
#ifdef HV_GFX
            /* Before the guest runs: the driver must not have bound yet. */
            virgl = hv_vgpu_virgl_create();
            if (!virgl || hv_virtio_gpu_set_3d(virt.gpu, hv_vgpu_virgl_ops(), virgl) != 0)
                return fail(err, errlen, "Graphics acceleration is unavailable (ANGLE or virglrenderer refused to start).");
            hv_vgpu_metal_set_3d(vgpu.presenter, hv_vgpu_virgl_scanout_ops(), virgl);
#else
            return fail(err, errlen, "This build has no graphics acceleration (build with GFX=1).");
#endif
        }
    } else if (c->accel) {
        return fail(err, errlen, "Graphics acceleration needs the virtio GPU.");
    }
    publish_display();
    return 0;
}

int hv_vm_create(const HvVmConfig *c, char *err, size_t errlen) {
    if (machine_created) return fail(err, errlen, "The previous machine has not been released.");
    if (primary_started) {
        pthread_join(primary_thread, NULL);
        primary_started = 0;
    }
    if (c->board != HV_BOARD_VMAPPLE && c->board != HV_BOARD_VIRT) return fail(err, errlen, "Unknown board.");
    if (c->board == HV_BOARD_VMAPPLE && (!c->rom || !c->disk || !c->aux))
        return fail(err, errlen, "The ROM, disk and auxiliary storage are all needed.");
    if (c->kernel && (c->board != HV_BOARD_VIRT || c->rom))
        return fail(err, errlen, "A kernel boots directly on the virt board only, without firmware.");
    if ((c->initrd || c->cmdline) && !c->kernel) return fail(err, errlen, "An initrd or a command line needs a kernel.");
    machine_created = 1;
    board_kind = c->board;
    struct sigaction ill = {.sa_flags = SA_SIGINFO | SA_ONSTACK};
    ill.sa_sigaction = on_ill;
    if (!signals_installed) {
        sigaction(SIGILL, &ill, &prior_ill);
        sigaction(SIGBUS, &ill, &prior_bus);
        sigaction(SIGSEGV, &ill, &prior_segv);
        signals_installed = 1;
    }
    signal(SIGPIPE, SIG_IGN); /* a guest connection closing at the far end must not end the machine */
    if (c->disk && hv_disk_open(&disk, c->disk, 0, 0) != 0) return fail(err, errlen, "Cannot open the disk image.");
    size_t jit = c->jit_bytes ? c->jit_bytes : (size_t)768 << 20;
    int r = c->jit_rx ? hv_machine_init_jit(&m, c->jit_rx, c->jit_rw, jit) : hv_machine_init(&m, jit);
    if (r != 0) return fail(err, errlen, "Cannot set up the JIT region.");
    m.log = c->log;
    m.gen_checks = getenv("HV_JIT_POISON") != NULL;
    if (getenv("HV_SLOW_MEM")) m.slow_mem = 1; /* debugging: every load and store through the helper */
    ncpus = c->ncpus < 1 ? 1 : c->ncpus > HV_MAX_CPUS ? HV_MAX_CPUS : c->ncpus;
    m.big_lock_on = ncpus > 1 && getenv("HV_BIG_LOCK"); /* debugging: one CPU in guest code at a time */
    uint64_t ram_size = (c->ram_mb ? c->ram_mb : 2048) << 20;
    if ((c->board == HV_BOARD_VIRT ? create_virt : create_vmapple)(c, ram_size, err, errlen) != 0) return -1;
    if (devs.net && !c->no_net) {
        if (hv_net_attach(&m, devs.net) != 0) fprintf(stderr, "hengevm: user-mode network unavailable\n");
        else net_on = 1;
    }
    if (devs.snd && !c->no_sound) hv_audio_attach(devs.snd);
    console_attach();
    atomic_store(&input_stopping, 0);
    return 0;
}

void hv_vm_destroy(void) {
    if (primary_started && !pthread_equal(primary_thread, pthread_self())) {
        pthread_join(primary_thread, NULL);
        primary_started = 0;
    }
    if (!machine_created) return;
    /* The bridge excludes readers. Unpublish the display before draining
       queued GPU work; completion callbacks still need the GIC and RAM. */
    os_unfair_lock_lock(&display_lock);
    atomic_store_explicit(&display_devs, NULL, memory_order_release);
    os_unfair_lock_unlock(&display_lock);
    stop_pointer();
    hv_net_detach();
    net_on = 0;
    hv_audio_detach();
    console_reset();
    memset(&devs, 0, sizeof devs);
#ifdef HV_GFX
    if (virgl) hv_vgpu_metal_set_3d(vgpu.presenter, NULL, NULL);
#endif
    hv_vgpu_metal_destroy(vgpu.presenter); /* before the board frees the GPU */
    vgpu = (VgpuDisplay){0};
#ifdef HV_GFX
    if (virgl) { /* the device drops its renderer objects first; the renderer goes before guest RAM */
        hv_virtio_gpu_destroy(virt.gpu);
        virt.gpu = NULL;
        hv_vgpu_virgl_destroy(virgl);
        virgl = NULL;
    }
#endif
    if (board_kind == HV_BOARD_VMAPPLE) hv_vmapple_destroy(&board);
    else hv_virt_destroy(&virt);
    hv_disk_close(&disk);
    hv_disk_close(&aux);
    hv_machine_free(&m);
    memset(cpus, 0, sizeof cpus);
    ncpus = 0;
    boot_args_offset = 0;
    boot_last_scan = 0;
    extra_poll = NULL;
    machine_created = 0;
}

static void *kicker_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&kicker_stopped)) {
        usleep(1000);
        hv_machine_kick_all(&m);
    }
    return NULL;
}

/* A thread that runs guest code. While a block runs its SP register holds the
   guest's SP, a guest address, so the kernel must never push a signal frame
   there: other threads take the asynchronous signals, and a handler that does
   run here (a fault) gets a stack of its own. */
static pthread_key_t stack_key;
static pthread_once_t stack_key_once = PTHREAD_ONCE_INIT;
static void free_cpu_stack(void *memory) {
    stack_t disabled = {.ss_flags = SS_DISABLE};
    sigaltstack(&disabled, NULL);
    free(memory);
}
static void make_stack_key(void) { pthread_key_create(&stack_key, free_cpu_stack); }

void hv_vm_prepare_cpu_thread(void) {
    static __thread int done;
    if (done) return;
    done = 1;
    if (hv_prof_register) hv_prof_register();
    stack_t ss = {.ss_sp = malloc(1u << 16), .ss_size = 1u << 16, .ss_flags = 0};
    if (ss.ss_sp) {
        sigaltstack(&ss, NULL);
        pthread_once(&stack_key_once, make_stack_key);
        pthread_setspecific(stack_key, ss.ss_sp);
    }
    sigset_t set;
    sigfillset(&set);
    sigdelset(&set, SIGSEGV), sigdelset(&set, SIGBUS), sigdelset(&set, SIGILL), sigdelset(&set, SIGTRAP), sigdelset(&set, SIGFPE);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
}

/* iOS parks default-QoS threads on efficiency cores readily; the guest's CPUs are what the user waits on. */
void hv_vm_cpu_qos(void) {
    hv_vm_prepare_cpu_thread();
    /* HV_QOS=ui|init|default (testing): the class the guest's CPUs run at. */
    const char *q = getenv("HV_QOS");
#if TARGET_OS_IPHONE
    qos_class_t c = QOS_CLASS_USER_INITIATED;
#else
    qos_class_t c = QOS_CLASS_DEFAULT;
#endif
    if (q && !strcmp(q, "ui")) c = QOS_CLASS_USER_INTERACTIVE;
    else if (q && !strcmp(q, "init")) c = QOS_CLASS_USER_INITIATED;
    else if (q && !strcmp(q, "default")) c = QOS_CLASS_DEFAULT;
    if (c != QOS_CLASS_DEFAULT) pthread_set_qos_class_self_np(c, 0);
}

/* CPUs 1 and up: run whenever PSCI CPU_ON starts them; the machine stops with CPU 0. */
static void *secondary_thread(void *arg) {
    HvCpu *c = arg;
    hv_vm_cpu_qos();
    int r = hv_run(c);
    if (!c->halted)
        fprintf(stderr, "hengevm: cpu %u stopped (%s) at pc %llx el%u\n", c->index, hv_vm_reason_name(r),
                (unsigned long long)c->pc, c->el);
    return NULL;
}

void hv_vm_flush_disks(void) {
    hv_disk_flush(&disk);
    hv_disk_flush(&aux);
}

int hv_vm_run_cpu0(void) {
    return hv_run(&cpus[0]);
}

static void *cpu0_thread(void *unused) {
    (void)unused;
    hv_vm_cpu_qos();
    int r = hv_vm_run_cpu0();
    /* Finish CPU activity before flushing or telling the UI the Mac stopped.
       CPU 0 can also leave for a fatal execution error. */
    hv_machine_halt(&m, HV_HALT_HOST);
    atomic_store(&kicker_stopped, 1);
    for (int i = 1; i < ncpus; i++)
        if (secondary_started[i]) pthread_join(secondary_threads[i], NULL);
    if (kicker_started) pthread_join(kicker, NULL);
    kicker_started = 0;
    memset(secondary_started, 0, sizeof secondary_started);
    /* A DMA worker can still be writing after the guest CPUs have exited. */
    hv_virtio_blk_stop(devs.blk[0]);
    hv_virtio_blk_stop(devs.blk[1]);
    hv_audio_detach();
    hv_vm_flush_disks();
    if (exit_cb) exit_cb(r);
    return NULL;
}

int hv_vm_start(int cpu0, void (*on_exit)(int reason)) {
    exit_cb = on_exit;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    atomic_store(&kicker_stopped, 0);
    /* Publish all join handles before CPU 0 can reach its exit callback. */
    for (int i = 1; i < ncpus; i++) {
        secondary_started[i] = pthread_create(&secondary_threads[i], &attr, secondary_thread, &cpus[i]) == 0;
        if (!secondary_started[i]) goto failed;
    }
    kicker_started = pthread_create(&kicker, NULL, kicker_thread, NULL) == 0;
    if (!kicker_started) goto failed;
    if (cpu0) {
        primary_started = pthread_create(&primary_thread, &attr, cpu0_thread, NULL) == 0;
        if (!primary_started) goto failed;
    }
    pthread_attr_destroy(&attr);
    return 0;
failed:
    pthread_attr_destroy(&attr);
    hv_machine_halt(&m, HV_HALT_HOST);
    atomic_store(&kicker_stopped, 1);
    for (int i = 1; i < ncpus; i++)
        if (secondary_started[i]) pthread_join(secondary_threads[i], NULL);
    memset(secondary_started, 0, sizeof secondary_started);
    if (kicker_started) pthread_join(kicker, NULL);
    kicker_started = 0;
    return -1;
}

void hv_vm_stop(void) {
    hv_machine_halt(&m, HV_HALT_HOST);
}

/* macOS's virtio mouse driver drops BTN_RIGHT, so the right button is a Control-click, with the right
   Control. The USB keyboard is read every 10 ms and the click goes over virtio, so Control goes down
   50 ms before the click and comes up 50 ms after it. The waits run on a serial queue that the pointer's
   moves and buttons all go through, so they stay in order and the caller (often the main thread) never
   waits. The guest's right Control and left button each have two owners, and stay down while either holds them. */
#define HID_RIGHT_CONTROL 0xe4
#define LINUX_KEY_RIGHTCTRL 97
static os_unfair_lock rctrl_lock = OS_UNFAIR_LOCK_INIT;
static int rctrl_user, rctrl_click;
static int left_user, left_click, left_sent; /* only the pointer queue touches these */

static dispatch_queue_t pointer_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("henge.pointer", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void stop_pointer(void) {
    atomic_store(&input_stopping, 1);
    /* The bridge excludes new input. Finish a click already in progress and
       discard queued input before releasing the keyboard and mouse. */
    dispatch_sync(pointer_queue(), ^{
        left_user = left_click = left_sent = 0;
        os_unfair_lock_lock(&rctrl_lock);
        rctrl_user = rctrl_click = 0;
        os_unfair_lock_unlock(&rctrl_lock);
    });
}

static void rctrl_hold(int *owner, int down) {
    os_unfair_lock_lock(&rctrl_lock);
    *owner = down;
    hv_xhci_key(devs.usb, HID_RIGHT_CONTROL, rctrl_user || rctrl_click);
    os_unfair_lock_unlock(&rctrl_lock);
}

void hv_vm_key(uint16_t code, int down) {
    if (code == LINUX_KEY_RIGHTCTRL) rctrl_hold(&rctrl_user, down);
    else hv_xhci_key_linux(devs.usb, code, down);
}

void hv_vm_key_hid(uint8_t usage, int down) {
    if (usage == HID_RIGHT_CONTROL) rctrl_hold(&rctrl_user, down);
    else hv_xhci_key(devs.usb, usage, down);
}

static void move_now(void *ctx) {
    if (atomic_load(&input_stopping)) return;
    int64_t packed = (int64_t)(intptr_t)ctx;
    int32_t dx = (int32_t)(packed >> 32), dy = (int32_t)packed;
    if (dx) hv_virtio_input_send(devs.mouse, HV_EV_REL, HV_REL_X, dx);
    if (dy) hv_virtio_input_send(devs.mouse, HV_EV_REL, HV_REL_Y, dy);
    hv_virtio_input_send(devs.mouse, HV_EV_SYN, 0, 0);
}

void hv_vm_mouse_move(int dx, int dy) {
    int64_t packed = (int64_t)((uint64_t)(uint32_t)dx << 32 | (uint32_t)dy);
    dispatch_async_f(pointer_queue(), (void *)(intptr_t)packed, move_now);
}

static void left_update(void) {
    int down = left_user || left_click;
    if (down == left_sent) return;
    left_sent = down;
    hv_virtio_input_send(devs.mouse, HV_EV_KEY, HV_BTN_LEFT, down);
    hv_virtio_input_send(devs.mouse, HV_EV_SYN, 0, 0);
}

static void button_now(void *ctx) {
    if (atomic_load(&input_stopping)) return;
    intptr_t v = (intptr_t)ctx;
    int button = (int)(v >> 1), down = (int)(v & 1);
    if (button == 0) {
        left_user = down;
        left_update();
    } else if (button == 1 && board_kind == HV_BOARD_VIRT) {
        hv_virtio_input_send(devs.mouse, HV_EV_KEY, HV_BTN_RIGHT, down);
        hv_virtio_input_send(devs.mouse, HV_EV_SYN, 0, 0);
    } else if (button == 1 && down != left_click) {
        if (down) {
            rctrl_hold(&rctrl_click, 1);
            usleep(50000);
        }
        left_click = down;
        left_update();
        if (!down) {
            usleep(50000);
            rctrl_hold(&rctrl_click, 0);
        }
    } else if (button == 2) {
        hv_virtio_input_send(devs.mouse, HV_EV_KEY, HV_BTN_MIDDLE, down);
        hv_virtio_input_send(devs.mouse, HV_EV_SYN, 0, 0);
    }
}

void hv_vm_mouse_button(int button, int down) {
    if (button < 0 || button > 2) return;
    dispatch_async_f(pointer_queue(), (void *)(intptr_t)(button << 1 | !!down), button_now);
}

static void power_now(void *ctx) {
    (void)ctx;
    if (atomic_load(&input_stopping) || !devs.gpio) return;
    hv_dev_lock(&m);
    hv_pl061_set_input(devs.gpio, VIRT_GPIO_POWER, 1);
    hv_dev_unlock(&m);
    usleep(100000);
    hv_dev_lock(&m);
    hv_pl061_set_input(devs.gpio, VIRT_GPIO_POWER, 0);
    hv_dev_unlock(&m);
}

/* On the pointer queue so hv_vm_destroy waits for the release (stop_pointer). */
int hv_vm_power_button(void) {
    if (board_kind != HV_BOARD_VIRT || !machine_created || atomic_load(&input_stopping)) return 0;
    dispatch_async_f(pointer_queue(), NULL, power_now);
    return 1;
}

/* The guest takes a wheel event as 8 bits: -200 arrives as +56, the wrong way. So big moves go in pieces. */
static void wheel(uint16_t axis, int amount) {
    while (amount) {
        int piece = amount > 100 ? 100 : amount < -100 ? -100 : amount;
        hv_virtio_input_send(devs.mouse, HV_EV_REL, axis, piece);
        hv_virtio_input_send(devs.mouse, HV_EV_SYN, 0, 0);
        amount -= piece;
    }
}

void hv_vm_mouse_wheel(int dy) { wheel(HV_REL_WHEEL, dy); }
void hv_vm_mouse_hwheel(int dx) { wheel(HV_REL_HWHEEL, dx); }

void hv_vm_touch(int id, int phase, int x, int y, uint32_t ts_ms) {
    if (x < 0) x = 0;
    if (x > HV_TP_SENSOR_X) x = HV_TP_SENSOR_X;
    if (y < 0) y = 0;
    if (y > HV_TP_SENSOR_Y) y = HV_TP_SENSOR_Y;
    hv_xhci_touch(devs.usb, id, phase, x, y, ts_ms);
}

void hv_vm_touch_frame(uint32_t ts_ms) { hv_xhci_touch_frame(devs.usb, ts_ms); }

void hv_vm_touch_button(int down) { hv_xhci_touch_button(devs.usb, down); }

int hv_vm_pointer(int *x, int *y) {
    const HvBoardDevs *shown = shown_display();
    return shown && shown->display ? shown->display->pointer(shown->display_opaque, x, y) : -1;
}

int hv_vm_snapshot(uint8_t *bgra, int width, int height) {
    const HvBoardDevs *shown = shown_display();
    if (!shown || !shown->display || width <= 0 || height <= 0) return -1;
    return shown->display->snapshot(shown->display_opaque, bgra, (uint32_t)width, (uint32_t)height);
}
