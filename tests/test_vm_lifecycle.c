#include "henge-vm.h"
#include "henge-ios-jit.h"
#include "install.h"
#include "jit_region.h"
#include "vm.h"

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Real native bridge and device workers; only the debugger allocation and
   unused installer entry point are replaced. No Apple ROM or disk needed. */
static HvJitRegion jit;
static HengeDualMapping mapping;
static int failures;
static _Atomic int reader_done;
HengeDualMapping *henge_ios_jit_get_mapping(void) { return &mapping; }
void hv_prof_ios_start(void) {}
int hv_install_start(HvVirtioUsb *usb, const char *ipsw, const char *work, uint64_t ecid,
                     HvInstallProgress progress, void *user) {
    (void)usb; (void)ipsw; (void)work; (void)ecid; (void)progress; (void)user;
    return -1;
}
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}
static int fds(void) {
    int n = 0;
    for (int i = 0; i < 2048; i++) if (fcntl(i, F_GETFD) != -1) n++;
    return n;
}
static unsigned threads(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    for (unsigned i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    return n;
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
static size_t drain(char *out, size_t cap, const char *stop_on, int until_stopped, int ms) {
    size_t n = 0;
    for (int t = 0; t < ms; t++) {
        n += henge_vm_console_read((uint8_t *)out + n, cap - n);
        if (stop_on && memmem(out, n, stop_on, strlen(stop_on))) break;
        if (until_stopped && henge_vm_state() == 2) { n += henge_vm_console_read((uint8_t *)out + n, cap - n); break; }
        usleep(1000);
    }
    return n;
}
static void *read_ui(void *unused) {
    (void)unused;
    while (!atomic_load(&reader_done)) {
        uint8_t image[16];
        int x, y, width, height, stride;
        const uint8_t *pixels;
        henge_vm_snapshot(image, 2, 2);
        henge_vm_pointer(&x, &y);
        henge_vm_cpus_on();
        henge_vm_gpu_frames();
        henge_vm_balloon(-1);
        henge_vm_board_kind();
        henge_vm_console_write((const uint8_t *)"", 0);
        henge_vm_set_display_layer(NULL);
        if (!henge_vm_boot_display(&pixels, &width, &height, &stride)) henge_vm_free_display(pixels);
        usleep(500);
    }
    return NULL;
}
int main(void) {
    alarm(60);
    char dir[] = "/tmp/henge-lifecycle-XXXXXX", rom[256], disk[256], aux[256], ram[256], error[256];
    if (!mkdtemp(dir) || hv_jit_region_open(&jit, 8 << 20)) return 1;
    snprintf(rom, sizeof rom, "%s/rom", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    snprintf(aux, sizeof aux, "%s/aux", dir);
    snprintf(ram, sizeof ram, "%s/ram", dir);
    setenv("HV_RAM_FILE", ram, 1);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_BALLOON", "0", 1);
    write_file(disk, NULL, 1 << 20);
    write_file(aux, NULL, 1 << 20);
    mapping = (HengeDualMapping){.rx_addr = (uint8_t *)jit.base,
        .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
    pthread_t reader;
    if (pthread_create(&reader, NULL, read_ui, NULL)) return 1;
    /* Warm the process-wide pointer queue before counting worker threads. */
    hv_vm_mouse_move(0, 0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{}); /* the power key's release timer runs there */
    usleep(100000);
    int initial_fds = fds();
    unsigned initial_threads = threads();
    unsigned initial_dead_ports = dead_ports();
    /* A virt machine is built and released without a trace, and the virtual Mac still boots after it. */
    HvVmConfig virt = {.board = HV_BOARD_VIRT, .disk = disk, .ram_mb = 64, .ncpus = 2, .no_net = 1, .no_sound = 1,
                       .jit_rx = mapping.rx_addr, .jit_rw = mapping.rw_addr, .jit_bytes = mapping.size};
    check("virt board builds", hv_vm_create(&virt, error, sizeof error) == 0 && !hv_vm_board() && hv_vm_virt());
    hv_vm_destroy();
    check("virt release leaves nothing behind", !hv_vm_virt() && henge_vm_can_start() && fds() == initial_fds &&
                                                 threads() == initial_threads);
    /* Missing ROM fails after disks, RAM and device workers were created. */
    for (int i = 0; i < 3; i++) {
        check("failed boot reports an error", henge_vm_boot(rom, disk, aux, 1, 0, 64, 4, error, sizeof error) != 0);
        check("failed boot allows retry", henge_vm_state() == 0 && henge_vm_can_start());
        check("failed boot closes files", fds() == initial_fds);
        check("failed boot joins workers", threads() == initial_threads);
    }
    for (int i = 0; i < 12; i++) {
        int outcome = i % 3 == 2 ? HENGE_VM_OUTCOME_HOST_STOP : i % 3 == 1 ? HENGE_VM_OUTCOME_RESTART : HENGE_VM_OUTCOME_SHUTDOWN;
        uint32_t code[] = {outcome == HENGE_VM_OUTCOME_RESTART ? 0xd2800120 : 0xd2800100, 0xf2b08000, 0xd4000002};
        if (outcome == HENGE_VM_OUTCOME_HOST_STOP) code[0] = 0x14000000;
        write_file(rom, code, sizeof code);
        int rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 4, error, sizeof error);
        if (rc) fprintf(stderr, "boot %d: %s\n", i, error);
        check("boot succeeds without restarting app", rc == 0);
        if (rc) break;
        if (outcome == HENGE_VM_OUTCOME_HOST_STOP) {
            henge_vm_mouse_button(0, 1);
            henge_vm_mouse_button(1, 1);
            henge_vm_mouse_move(5, 7);
            henge_vm_mouse_button(1, 0);
            henge_vm_stop();
        }
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("terminal state is published after cleanup", henge_vm_state() == 2);
        if (henge_vm_state() != 2) exit(1);
        check("power outcome preserved", henge_vm_exit_outcome() == outcome);
        check("start is available again", henge_vm_can_start());
        check("new generation", henge_vm_generation() == (uint64_t)i + 1);
        check("RAM released", hv_vm_board()->ram == NULL);
        check("RAM file closed", hv_vm_board()->ram_fd == -1);
        check("balloon released", hv_vm_board()->balloon == NULL);
        check("translation metadata released", hv_vm_machine()->blocks == NULL && hv_vm_machine()->jit.base == NULL);
        check("borrowed JIT mapping retained", mapping.rx_addr == (uint8_t *)jit.base);
        check("no disk or network descriptor leak", fds() == initial_fds);
        /* The last CPU thread can still be returning from its callback. */
        for (int n = 0; n < 1000 && threads() > initial_threads; n++) usleep(1000);
        check("no CPU, disk or network worker leak", threads() == initial_threads);
        check("no leaked CPU thread ports", dead_ports() == initial_dead_ports);
    }
    /* The virt board through the bridge: a tiny firmware prints to the PL011 and ends in PSCI or a host stop. */
    {
        static char text[1 << 19];
        int base = 12, runs = 0;
        struct { const char *name; int how, key, outcome; const char *say; } cases[] = {
            {"off", FW_OFF, 0, HENGE_VM_OUTCOME_SHUTDOWN, "HENGE OFF\n"},
            {"reset", FW_RESET, 0, HENGE_VM_OUTCOME_RESTART, "HENGE RESET\n"},
            {"host stop", FW_SPIN, 0, HENGE_VM_OUTCOME_HOST_STOP, "HENGE SPIN\n"},
            {"power key", FW_OFF, 1, HENGE_VM_OUTCOME_SHUTDOWN, "KEY\n"},
        };
        check("no board before a boot", henge_vm_board_kind() == -1);
        check("missing firmware file fails", henge_vm_boot_linux("/nonexistent/u-boot.bin", disk, 64, 2, error, sizeof error) != 0 &&
                                                henge_vm_state() == 0 && henge_vm_can_start() && fds() == initial_fds &&
                                                threads() == initial_threads);
        check("no firmware fails", henge_vm_boot_linux(NULL, disk, 64, 2, error, sizeof error) != 0 && henge_vm_state() == 0);
        for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
            for (int again = 0; again < 2; again++) {
                Fw f = {0};
                if (cases[i].key) fw_wait_key(&f);
                fw_print(&f, cases[i].say);
                fw_end(&f, cases[i].how);
                write_file(rom, f.w, f.n * sizeof f.w[0]);
                int rc = henge_vm_boot_linux(rom, disk, 64, 2, error, sizeof error);
                if (rc) fprintf(stderr, "virt %s: %s\n", cases[i].name, error);
                check("virt boots through the bridge", rc == 0);
                if (rc) break;
                runs++;
                check("virt board kind", henge_vm_board_kind() == HENGE_VM_BOARD_LINUX);
                check("a second start is refused while running", henge_vm_boot_linux(rom, disk, 64, 2, error, sizeof error) != 0 &&
                                                                  henge_vm_state() == 1);
                henge_vm_console_write((const uint8_t *)"x", 1); /* nobody reads it; it must not hurt */
                size_t n;
                if (cases[i].how == FW_SPIN) {
                    n = drain(text, sizeof text, cases[i].say, 0, 3000);
                    henge_vm_stop();
                    for (int w = 0; w < 3000 && henge_vm_state() != 2; w++) usleep(1000);
                    n += drain(text + n, sizeof text - n, NULL, 0, 1);
                } else if (cases[i].key) {
                    usleep(100000);
                    check("the key text is not out before the key", henge_vm_console_read((uint8_t *)text, sizeof text) == 0);
                    henge_vm_power_button();
                    n = drain(text, sizeof text, NULL, 1, 3000);
                } else {
                    n = drain(text, sizeof text, NULL, 1, 3000);
                }
                text[n] = 0;
                check("virt stopped", henge_vm_state() == 2);
                if (henge_vm_state() != 2) exit(1);
                check("console text arrives", strstr(text, cases[i].say) != NULL);
                if (!strstr(text, cases[i].say)) fprintf(stderr, "virt %s: got \"%s\"\n", cases[i].name, text);
                check("virt outcome", henge_vm_exit_outcome() == cases[i].outcome);
                check("virt board kind after stop", henge_vm_board_kind() == -1);
                check("virt released", hv_vm_virt() == NULL && henge_vm_can_start());
                check("virt generation", henge_vm_generation() == (uint64_t)base + runs);
                check("console empty after the drain", henge_vm_console_read((uint8_t *)text, sizeof text) == 0);
                henge_vm_power_button(); /* no machine: nothing to press */
                check("virt leaves no descriptors", fds() == initial_fds);
                for (int w = 0; w < 1000 && threads() > initial_threads; w++) usleep(1000);
                check("virt leaves no threads", threads() == initial_threads);
                if (threads() != initial_threads) fprintf(stderr, "  %s #%d: %u threads, started with %u\n", cases[i].name, again, threads(), initial_threads);
            }
        }
        /* More output than the ring holds: the oldest bytes go, the newest stay. */
        Fw f = {0};
        fw_flood(&f);
        fw_end(&f, FW_OFF);
        write_file(rom, f.w, f.n * sizeof f.w[0]);
        check("virt flood boots", henge_vm_boot_linux(rom, disk, 64, 2, error, sizeof error) == 0);
        for (int w = 0; w < 10000 && henge_vm_state() != 2; w++) usleep(1000);
        size_t total = 0, got;
        static uint8_t flood[(1 << 18) + 64];
        while ((got = henge_vm_console_read(flood + total, 4096)) > 0) total += got;
        check("ring keeps 256 KB", total == 1 << 18);
        check("ring dropped the oldest bytes", total && flood[0] == (uint8_t)(1 << 18)); /* countdown 262144 */
        check("ring kept the newest byte", total && flood[total - 1] == 1);
        check("flood outcome", henge_vm_exit_outcome() == HENGE_VM_OUTCOME_SHUTDOWN);
        runs++;
        /* The virtual Mac still boots after Linux and writes nothing to the console. */
        uint32_t off[] = {0xd2800100, 0xf2b08000, 0xd4000002};
        write_file(rom, off, sizeof off);
        check("macOS boots after Linux", henge_vm_boot(rom, disk, aux, 1, 0, 64, 1, error, sizeof error) == 0);
        for (int w = 0; w < 3000 && henge_vm_state() != 2; w++) usleep(1000);
        check("mac outcome after Linux", henge_vm_exit_outcome() == HENGE_VM_OUTCOME_SHUTDOWN);
        check("mac generation after Linux", henge_vm_generation() == (uint64_t)base + runs + 1);
        check("mac wrote nothing to the console", henge_vm_console_read(flood, sizeof flood) == 0);
    }
    hv_vm_destroy();
    atomic_store(&reader_done, 1);
    pthread_join(reader, NULL);
    hv_jit_region_close(&jit);
    unlink(rom); unlink(disk); unlink(aux); rmdir(dir);
    printf("VM lifecycle: 12 power cycles and 3 failed boots, then the virt board (4 endings twice, a flood), %d failures\n", failures);
    return failures != 0;
}
