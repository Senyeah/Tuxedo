#include "tux-vm.h"
#include "tux-ios-jit.h"
#include "jit_region.h"
#include "vcodec.h"
#include "vm.h"

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Real native bridge and device workers; only the debugger allocation is replaced. */
static HvJitRegion jit;
static TuxDualMapping mapping;
static int failures;
static _Atomic int reader_done;
TuxDualMapping *tux_ios_jit_get_mapping(void) { return &mapping; }
void hv_prof_ios_start(void) {}
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}
static int fds(void) {
    int n = 0;
    for (int i = 0; i < 2048; i++) if (fcntl(i, F_GETFD) != -1) n++;
    return n;
}
/* Threads that are not libdispatch's. The kernel keeps workqueue threads for as long as it likes (one stayed past
   15 s in about 1 run in 10, and their run and blocked counts do not settle), so they are not counted here.
   Every thread the engine makes is a pthread with a name that starts "tux-": tux_threads() counts those. */
static unsigned threads_raw(unsigned *workqueue) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    struct proc_workqueueinfo wq = {0};
    /* Two samples that must agree: a workqueue thread can come or go between the two calls. */
    for (int tries = 0; tries < 50; tries++) {
        if (proc_pidinfo(getpid(), PROC_PIDWORKQUEUEINFO, 0, &wq, sizeof wq) != (int)sizeof wq) wq.pwq_nthreads = 0;
        uint32_t before = wq.pwq_nthreads;
        if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
        for (unsigned i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
        if (proc_pidinfo(getpid(), PROC_PIDWORKQUEUEINFO, 0, &wq, sizeof wq) != (int)sizeof wq) wq.pwq_nthreads = 0;
        if (wq.pwq_nthreads == before) break;
        usleep(1000);
    }
    *workqueue = wq.pwq_nthreads;
    return n;
}
static unsigned threads(void) {
    unsigned workqueue, n = threads_raw(&workqueue);
    return n > workqueue ? n - workqueue : 0;
}
static unsigned tux_threads(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    unsigned named = 0;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    for (unsigned i = 0; i < n; i++) {
        char name[64] = "";
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, name, sizeof name);
        named += !strncmp(name, "tux-", 4);
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    return named;
}
static unsigned initial_threads, initial_tux_threads, most_workqueue;
/* Each live thread: pthread name, dispatch queue label, CPU time and run state. Printed when a thread stays. */
static void dump_threads(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return;
    for (unsigned i = 0; i < n; i++) {
        char name[64] = "";
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, name, sizeof name);
        thread_identifier_info_data_t id = {0};
        mach_msg_type_number_t c = THREAD_IDENTIFIER_INFO_COUNT;
        const char *label = "";
        if (thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&id, &c) == KERN_SUCCESS && id.dispatch_qaddr) {
            dispatch_queue_t q = *(dispatch_queue_t *)(uintptr_t)id.dispatch_qaddr;
            if (q) label = dispatch_queue_get_label(q);
        }
        thread_basic_info_data_t b = {0};
        c = THREAD_BASIC_INFO_COUNT;
        thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&b, &c);
        fprintf(stderr, "    thread %u: name \"%s\" queue \"%s\" pthread %s, cpu %d.%06d s, run state %d, %s\n", i, name, label,
                pt ? "yes" : "no", b.user_time.seconds + b.system_time.seconds, b.user_time.microseconds, b.run_state,
                b.flags & TH_FLAGS_IDLE ? "idle" : "not idle");
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    unsigned workqueue, raw = threads_raw(&workqueue);
    fprintf(stderr, "    %u threads: %u workqueue threads, %u named tux-*\n", raw, workqueue, tux_threads());
}
/* libdispatch keeps idle workers for a few seconds, longer under load; a leaked thread stays. */
static int threads_settled(void) {
    for (int w = 0; w < 15000 && (threads() > initial_threads || tux_threads() > initial_tux_threads); w++) usleep(1000);
    unsigned workqueue;
    threads_raw(&workqueue);
    if (workqueue > most_workqueue) most_workqueue = workqueue;
    return threads() <= initial_threads && tux_threads() <= initial_tux_threads;
}
static unsigned dead_ports(void) {
    mach_port_name_array_t names;
    mach_port_type_array_t types;
    mach_msg_type_number_t n, nt;
    if (mach_port_names(mach_task_self(), &names, &n, &types, &nt) != KERN_SUCCESS) exit(1);
    unsigned dead = 0;
    for (unsigned i = 0; i < nt; i++) if (types[i] & MACH_PORT_TYPE_DEAD_NAME) dead++;
    vm_deallocate(mach_task_self(), (vm_address_t)names, n * sizeof *names);
    vm_deallocate(mach_task_self(), (vm_address_t)types, nt * sizeof *types);
    return dead;
}
static void write_file(const char *path, const void *data, size_t bytes) {
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || (data && write(fd, data, bytes) != (ssize_t)bytes) || ftruncate(fd, bytes)) exit(1);
    close(fd);
}

/* A tiny arm64 firmware for the virt board, from a few encodings. It runs at flash 0. */
#define MOVZ(rd, imm, hw) (0xd2800000u | (unsigned)(hw) << 21 | (unsigned)(imm) << 5 | (rd))
#define MOVW(rd, imm) (0x52800000u | (unsigned)(imm) << 5 | (rd))
#define STRB(rt, rn) (0x39000000u | (rn) << 5 | (rt))
enum { FW_OFF, FW_RESET, FW_SPIN, FW_FLOOD };
typedef struct { uint32_t w[512]; int n; } Fw;
static void emit(Fw *f, uint32_t insn) { f->w[f->n++] = insn; }
static void fw_print(Fw *f, const char *text) {
    emit(f, MOVZ(1, 0x900, 1)); /* x1 = the PL011 at 0x09000000 */
    for (; *text; text++) emit(f, MOVW(2, (unsigned char)*text)), emit(f, STRB(2, 1));
}
static void fw_end(Fw *f, int how) {
    if (how == FW_SPIN) { emit(f, 0x14000000); return; } /* b . */
    emit(f, MOVZ(0, how == FW_RESET ? 9 : 8, 0)); /* PSCI SYSTEM_OFF 0x84000008, SYSTEM_RESET 0x84000009 */
    emit(f, 0xf2b08000);
    emit(f, 0xd4000002); /* hvc #0 */
}
/* Waits for the GPIO power key (pin 3, GPIODATA at 0x09030000 + 0x3fc), then prints. */
static void fw_wait_key(Fw *f) {
    emit(f, MOVZ(3, 0x903, 1));
    emit(f, 0xb9400000u | 0xffu << 10 | 3 << 5 | 4);          /* ldr w4, [x3, #0x3fc] */
    emit(f, 0x36000000u | 3u << 19 | (0x3fffu << 5) | 4);     /* tbz w4, #3, back to the ldr */
}
/* 5 * 65536 bytes (more than the ring holds), each the low byte of a countdown that ends at 1. */
static void fw_flood(Fw *f) {
    emit(f, MOVZ(1, 0x900, 1));
    emit(f, MOVZ(5, 5, 1));
    emit(f, STRB(5, 1));
    emit(f, 0xf1000000u | 1 << 10 | 5 << 5 | 5);              /* subs x5, x5, #1 */
    emit(f, 0x54000001u | ((uint32_t)(-2 & 0x7ffff) << 5));   /* b.ne to the strb */
}
/* Drains the console into out (cap bytes), waiting up to ms for the machine to stop or, with stop_on, for the text. */
/* One hvcodec message on fd: the reply's status, and its payload in reply (at most cap bytes, the rest dropped). */
static int vc_call(int fd, uint32_t type, const void *payload, uint32_t len, void *reply, size_t cap) {
    static uint32_t seq;
    HvVcHeader h = {type, len, ++seq, 0};
    if (write(fd, &h, sizeof h) != (ssize_t)sizeof h || (len && write(fd, payload, len) != (ssize_t)len)) return 1;
    if (recv(fd, &h, sizeof h, MSG_WAITALL) != (ssize_t)sizeof h || h.type != (type | HV_VC_REPLY)) return 1;
    char sink[512];
    for (uint32_t got = 0; got < h.len;) {
        size_t want = h.len - got < sizeof sink ? h.len - got : sizeof sink;
        ssize_t n = recv(fd, sink, want, MSG_WAITALL);
        if (n <= 0) return 1;
        if (reply && got < cap) memcpy((char *)reply + got, sink, (size_t)n < cap - got ? (size_t)n : cap - got);
        got += (uint32_t)n;
    }
    return h.status;
}

static size_t drain(char *out, size_t cap, const char *stop_on, int until_stopped, int ms) {
    size_t n = 0;
    for (int t = 0; t < ms; t++) {
        n += tux_vm_console_read((uint8_t *)out + n, cap - n);
        if (stop_on && memmem(out, n, stop_on, strlen(stop_on))) break;
        if (until_stopped && tux_vm_state() == 2) { n += tux_vm_console_read((uint8_t *)out + n, cap - n); break; }
        usleep(1000);
    }
    return n;
}
static void *read_ui(void *unused) {
    (void)unused;
    while (!atomic_load(&reader_done)) {
        uint8_t image[16];
        int x, y;
        tux_vm_snapshot(image, 2, 2);
        tux_vm_pointer(&x, &y);
        tux_vm_cpus_on();
        tux_vm_gpu_frames();
        tux_vm_balloon(-1);
        tux_vm_console_write((const uint8_t *)"", 0);
        tux_vm_set_display_layer(NULL);
        usleep(500);
    }
    return NULL;
}
int main(void) {
    alarm(60);
    char dir[] = "/tmp/tux-lifecycle-XXXXXX", rom[256], disk[256], ram[256], error[256];
    if (!mkdtemp(dir) || hv_jit_region_open(&jit, 8 << 20)) return 1;
    snprintf(rom, sizeof rom, "%s/rom", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    snprintf(ram, sizeof ram, "%s/ram", dir);
    setenv("HV_RAM_FILE", ram, 1);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_BALLOON", "0", 1);
    write_file(disk, NULL, 1 << 20);
    mapping = (TuxDualMapping){.rx_addr = (uint8_t *)jit.base,
        .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
    pthread_t reader;
    if (pthread_create(&reader, NULL, read_ui, NULL)) return 1;
    /* Warm the process-wide pointer queue before counting worker threads. */
    hv_vm_mouse_move(0, 0);
    /* And Metal, which the virt board's presenter opens once for the process. */
    HvVmConfig virt = {.disk = disk, .ram_mb = 64, .ncpus = 2, .no_net = 1, .no_sound = 1,
                       .jit_rx = mapping.rx_addr, .jit_rw = mapping.rw_addr, .jit_bytes = mapping.size};
    if (hv_vm_create(&virt, error, sizeof error) != 0) fprintf(stderr, "virt warm-up: %s\n", error);
    hv_vm_destroy();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{}); /* the power key's release timer runs there */
    usleep(100000);
    int initial_fds = fds();
    initial_threads = threads();
    initial_tux_threads = tux_threads();
    unsigned initial_dead_ports = dead_ports();
    /* A virt machine is built and released without a trace. */
    for (int i = 0; i < 3; i++) {
        check("virt board builds", hv_vm_create(&virt, error, sizeof error) == 0 && hv_vm_virt());
        check("virt board has a display", hv_vm_devs()->display != NULL);
        hv_vm_destroy();
        check("virt release leaves nothing behind", !hv_vm_virt() && tux_vm_can_start() && fds() == initial_fds &&
                                                     threads_settled());
    }
    /* The virt board through the bridge: a tiny firmware prints to the PL011 and ends in PSCI or a host stop. */
    {
        static char text[1 << 19];
        int base = 0, runs = 0;
        struct { const char *name; int how, key, outcome; const char *say; } cases[] = {
            {"off", FW_OFF, 0, TUX_VM_OUTCOME_SHUTDOWN, "TUX OFF\n"},
            {"reset", FW_RESET, 0, TUX_VM_OUTCOME_RESTART, "TUX RESET\n"},
            {"host stop", FW_SPIN, 0, TUX_VM_OUTCOME_HOST_STOP, "TUX SPIN\n"},
            {"power key", FW_OFF, 1, TUX_VM_OUTCOME_SHUTDOWN, "KEY\n"},
        };
        check("the background policy: silent pauses, sound keeps a plain machine running, acceleration always pauses",
              hv_vm_background_pauses(0, 0) && !hv_vm_background_pauses(0, 1) && hv_vm_background_pauses(1, 0) &&
                  hv_vm_background_pauses(1, 1));
        check("missing firmware file fails", tux_vm_boot_linux("/nonexistent/u-boot.bin", disk, 64, 2, 0, 0, 0, error, sizeof error) != 0 &&
                                                tux_vm_state() == 0 && tux_vm_can_start() && fds() == initial_fds &&
                                                threads_settled());
        check("no firmware fails", tux_vm_boot_linux(NULL, disk, 64, 2, 0, 0, 0, error, sizeof error) != 0 && tux_vm_state() == 0);
#ifndef HV_GFX
        {
            Fw f = {0};
            fw_end(&f, FW_OFF);
            write_file(rom, f.w, f.n * sizeof f.w[0]);
            error[0] = 0;
            check("acceleration without a GFX engine fails cleanly",
                  tux_vm_boot_linux(rom, disk, 64, 2, 1, 0, 0, error, sizeof error) != 0 && strstr(error, "no graphics acceleration") &&
                      tux_vm_state() == 0 && tux_vm_can_start() && fds() == initial_fds && threads_settled());
        }
#endif
        for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
            for (int again = 0; again < 2; again++) {
                Fw f = {0};
                if (cases[i].key) fw_wait_key(&f);
                fw_print(&f, cases[i].say);
                fw_end(&f, cases[i].how);
                write_file(rom, f.w, f.n * sizeof f.w[0]);
                int rc = tux_vm_boot_linux(rom, disk, 64, 2, 0, 0, 0, error, sizeof error);
                if (rc) fprintf(stderr, "virt %s: %s\n", cases[i].name, error);
                check("virt boots through the bridge", rc == 0);
                if (rc) break;
                runs++;
                check("a second start is refused while running", tux_vm_boot_linux(rom, disk, 64, 2, 0, 0, 0, error, sizeof error) != 0 &&
                                                                  tux_vm_state() == 1);
                tux_vm_console_write((const uint8_t *)"x", 1); /* nobody reads it; it must not hurt */
                size_t n;
                if (cases[i].how == FW_SPIN) {
                    n = drain(text, sizeof text, cases[i].say, 0, 3000);
                    tux_vm_set_background(1);
                    check("the background pauses a silent machine", tux_vm_paused());
                    tux_vm_stop(); /* a stop must end the pause */
                    for (int w = 0; w < 3000 && tux_vm_state() != 2; w++) usleep(1000);
                    n += drain(text + n, sizeof text - n, NULL, 0, 1);
                    check("a stopped machine is not paused", !tux_vm_paused());
                    tux_vm_set_background(0);
                } else if (cases[i].key) {
                    tux_vm_set_background(1);
                    check("background pauses", tux_vm_paused());
                    tux_vm_set_background(1);
                    usleep(20000);
                    tux_vm_set_background(0);
                    check("foreground resumes", !tux_vm_paused());
                    usleep(100000);
                    check("the key text is not out before the key", tux_vm_console_read((uint8_t *)text, sizeof text) == 0);
                    tux_vm_power_button();
                    n = drain(text, sizeof text, NULL, 1, 3000);
                } else {
                    n = drain(text, sizeof text, NULL, 1, 3000);
                }
                text[n] = 0;
                check("virt stopped", tux_vm_state() == 2);
                if (tux_vm_state() != 2) exit(1);
                check("console text arrives", strstr(text, cases[i].say) != NULL);
                if (!strstr(text, cases[i].say)) fprintf(stderr, "virt %s: got \"%s\"\n", cases[i].name, text);
                check("virt outcome", tux_vm_exit_outcome() == cases[i].outcome);
                check("virt released", hv_vm_virt() == NULL && tux_vm_can_start());
                check("virt generation", tux_vm_generation() == (uint64_t)base + runs);
                check("console empty after the drain", tux_vm_console_read((uint8_t *)text, sizeof text) == 0);
                tux_vm_power_button(); /* no machine: nothing to press */
                check("virt leaves no descriptors", fds() == initial_fds);
                check("virt leaves no threads", threads_settled());
                check("no leaked CPU thread ports", dead_ports() == initial_dead_ports);
                if (threads() > initial_threads || tux_threads() > initial_tux_threads) {
                    fprintf(stderr, "  %s #%d: %u threads (%u named tux-*), started with %u (%u)\n", cases[i].name, again, threads(),
                            tux_threads(), initial_threads, initial_tux_threads);
                    dump_threads();
                }
            }
        }
        /* More output than the ring holds: the oldest bytes go, the newest stay. */
        Fw f = {0};
        fw_flood(&f);
        fw_end(&f, FW_OFF);
        write_file(rom, f.w, f.n * sizeof f.w[0]);
        check("virt flood boots", tux_vm_boot_linux(rom, disk, 64, 2, 0, 0, 0, error, sizeof error) == 0);
        for (int w = 0; w < 10000 && tux_vm_state() != 2; w++) usleep(1000);
        size_t total = 0, got;
        static uint8_t flood[(1 << 18) + 64];
        while ((got = tux_vm_console_read(flood + total, 4096)) > 0) total += got;
        check("ring keeps 256 KB", total == 1 << 18);
        check("ring dropped the oldest bytes", total && flood[0] == (uint8_t)(1 << 18)); /* countdown 262144 */
        check("ring kept the newest byte", total && flood[total - 1] == 1);
        check("flood outcome", tux_vm_exit_outcome() == TUX_VM_OUTCOME_SHUTDOWN);
        runs++;
    }
    /* Video encode, last: its listener stays for the process, as the shared folder's does. */
    {
        Fw f = {0};
        fw_print(&f, "TUX SPIN\n");
        fw_end(&f, FW_SPIN);
        write_file(rom, f.w, f.n * sizeof f.w[0]);
        int rc = tux_vm_boot_linux(rom, disk, 64, 2, 0, 0, 1, error, sizeof error);
        if (rc) fprintf(stderr, "virt with video encode: %s\n", error);
        check("virt boots with video encode", rc == 0);
        check("video encode adds the hvcodec device", hv_vm_virt() && hv_vm_virt()->codec);
        char tmp[1024] = ""; /* where tux-vm.c puts it */
        if (getenv("TMPDIR") && *getenv("TMPDIR")) snprintf(tmp, sizeof tmp, "%s", getenv("TMPDIR"));
        else confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        snprintf(a.sun_path, sizeof a.sun_path, "%s%sv.sock", tmp, *tmp && tmp[strlen(tmp) - 1] == '/' ? "" : "/");
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        check("the codec service listens", fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
        HvVcEncOpen o = {.codec = HV_VC_H264, .width = 256, .height = 144, .format = HV_VC_FMT_NV12, .timescale = 30};
        HvVcOpenReply open;
        int st = vc_call(fd, HV_VC_ENC_OPEN, &o, sizeof o, &open, sizeof open);
        if (st == HV_VC_E_NOSUP) {
            printf("VM lifecycle: no hardware H.264 encoder here: the background loss is not checked\n");
            tux_vm_set_background(1);
        } else {
            check("an encoder opens", st == 0);
            HvVcFrameAlloc fa = {.width = 256, .height = 144, .format = HV_VC_FMT_NV12};
            HvVcFrameReply fr = {0};
            check("a frame", vc_call(fd, HV_VC_FRAME_ALLOC, &fa, sizeof fa, &fr, sizeof fr) == 0 && fr.handle);
            HvVcEncFrame ef = {open.session, fr.handle, 0, 1, 0, 0};
            check("it encodes in the foreground", vc_call(fd, HV_VC_ENC_FRAME, &ef, sizeof ef, NULL, 0) == 0);
            tux_vm_set_background(1);
            ef.pts = 1;
            check("the background ends the encoder: one clear error", vc_call(fd, HV_VC_ENC_FRAME, &ef, sizeof ef, NULL, 0) == HV_VC_E_LOST);
            check("and opens no new encoder", vc_call(fd, HV_VC_ENC_OPEN, &o, sizeof o, NULL, 0) == HV_VC_E_LOST);
        }
        HvVcDecOpen d = {.codec = HV_VC_H264, .width = 256, .height = 144};
        check("nor a new decoder", vc_call(fd, HV_VC_DEC_OPEN, &d, sizeof d, NULL, 0) == HV_VC_E_LOST);
        check("the background pauses it", tux_vm_paused());
        tux_vm_stop();
        for (int w = 0; w < 3000 && tux_vm_state() != 2; w++) usleep(1000);
        tux_vm_set_background(0);
        check("the foreground after the stop allows a session again", vc_call(fd, HV_VC_DEC_OPEN, &d, sizeof d, NULL, 0) != HV_VC_E_LOST);
        if (st != HV_VC_E_NOSUP) check("an encoder opens again", vc_call(fd, HV_VC_ENC_OPEN, &o, sizeof o, NULL, 0) == 0);
        if (fd >= 0) close(fd);
        check("video encode machine stopped and released", tux_vm_state() == 2 && hv_vm_virt() == NULL);
        HvVcodecStats vs;
        for (int w = 0; w < 1000; w++) {
            hv_vcodec_stats(&vs);
            if (!vs.open) break;
            usleep(1000);
        }
        check("no codec context is left", vs.open == 0 && vs.live_frames == 0 && vs.live_sessions == 0);
        check("virt boots without video encode after it", tux_vm_boot_linux(rom, disk, 64, 2, 0, 0, 0, error, sizeof error) == 0);
        check("and has no hvcodec device", hv_vm_virt() && !hv_vm_virt()->codec);
        tux_vm_stop();
        for (int w = 0; w < 3000 && tux_vm_state() != 2; w++) usleep(1000);
        check("stopped", tux_vm_state() == 2);
    }
    hv_vm_destroy();
    atomic_store(&reader_done, 1);
    pthread_join(reader, NULL);
    hv_jit_region_close(&jit);
    unlink(rom); unlink(disk); rmdir(dir);
    printf("VM lifecycle: %u threads and %u named tux-* at the start; at most %u workqueue threads after a machine (not counted)\n",
           initial_threads, initial_tux_threads, most_workqueue);
    printf("VM lifecycle: the virt board (4 endings twice, a flood, video encode), %d failures\n", failures);
    return failures != 0;
}
