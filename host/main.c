#include "share.h"
#include "secrets.h"
#include "net_slirp.h"
#include "vcodec.h"
#include <time.h>
/* hengevm: boots a Linux guest on the macOS host. See usage() for the flags. */
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <CommonCrypto/CommonDigest.h>
#include <termios.h>

#include "dispatch.h"
#include "exception.h"
#include "mmu.h"
#include "status.h"
#include "vm.h"
#include "audio_mac.h"
#include "virt_window.h"
#include <ImageIO/ImageIO.h>

/* The machine lives in vm.c; these name its parts here. */
#define m (*hv_vm_machine())
#define cpu (*hv_vm_cpu(0))
static int ncpus = 3; /* --cpus: 3 boots as fast as 4 on a 2+4-core Mac and leaves room for the window */
static volatile sig_atomic_t interrupted;

static void on_signal(int sig) {
    (void)sig;
    interrupted = 1;
    hv_vm_stop();
}

#define reason_name hv_vm_reason_name

typedef struct RunArgs {
    uint64_t brk, brk_hits, dump_pa, dump_len;
    const char *dump_path;
} RunArgs;
static RunArgs run_args;
static uint64_t translate_va;

/* Chained blocks run without returning to the dispatcher; this makes them leave
   every millisecond so timers, devices and interrupts are serviced. */
static mach_port_t cpu_port;
/* --profile: where the CPU thread is right now. */
static void sample_cpu(void) {
    arm_thread_state64_t st;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    if (thread_suspend(cpu_port) != KERN_SUCCESS) return;
    kern_return_t kr = thread_get_state(cpu_port, ARM_THREAD_STATE64, (thread_state_t)&st, &n);
    thread_resume(cpu_port);
    if (kr != KERN_SUCCESS) return;
    m.prof[m.prof_head & (HV_PROF_RING - 1)] = (uint64_t)arm_thread_state64_get_pc(st);
    __atomic_store_n(&m.prof_head, m.prof_head + 1, __ATOMIC_RELEASE);
}

static void *profile_thread(void *unused) {
    (void)unused;
    for (;;) {
        usleep(1000);
        if (cpu_port) sample_cpu();
    }
    return NULL;
}

/* Debugging: HV_PROF_ALL=1 samples every guest CPU's thread 1000 times a second; "prof NAME" in
   the input file writes what it saw since the last time to NAME: where the host was, and
   which guest code. Guest addresses are symbolized afterwards (scratch/prof.py). */
#define PROF_SLOTS (1u << 18)
typedef struct { uint64_t va; uint32_t n, el; } ProfBlock;
static ProfBlock prof_blocks[PROF_SLOTS];
static struct { void *start; const char *name; uint32_t n; } prof_fn[512];
static int prof_nfn;
static uint64_t prof_total, prof_idle, prof_el[2], prof_unknown, prof_spin;
static uint64_t prof_off[12]; /* translated-code samples by words from their block's start: 0..7, 8-15, 16-31, 32+, other */
/* Per host instruction too, to see where translated code stalls. */
#define PROF_PCS (1u << 20)
typedef struct { uint32_t *pc; uint32_t n; } ProfPc;
static ProfPc *prof_pcs;
static pthread_mutex_t prof_mu = PTHREAD_MUTEX_INITIALIZER;
static void prof_sample(thread_act_t th) {
    arm_thread_state64_t st;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    thread_basic_info_data_t ti;
    mach_msg_type_number_t ni = THREAD_BASIC_INFO_COUNT;
    if (thread_info(th, THREAD_BASIC_INFO, (thread_info_t)&ti, &ni) != KERN_SUCCESS) return;
    if (ti.run_state != TH_STATE_RUNNING) { /* asleep (WFI) or waiting for a lock */
        pthread_mutex_lock(&prof_mu);
        prof_total++, prof_idle++;
        pthread_mutex_unlock(&prof_mu);
        return;
    }
    if (thread_suspend(th) != KERN_SUCCESS) return;
    kern_return_t kr = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &n);
    thread_resume(th);
    if (kr != KERN_SUCCESS) return;
    uint32_t *pc = (uint32_t *)(uintptr_t)arm_thread_state64_get_pc(st);
    HvMachine *hm = hv_vm_machine();
    pthread_mutex_lock(&prof_mu);
    prof_total++;
    if (pc >= hm->jit.base && pc < hm->jit.base + hm->jit.capacity && hm->nblocks) {
        int lo = 0, hi = hm->nblocks - 1;
        while (lo < hi) {
            int mid = (lo + hi + 1) / 2;
            if (hm->blocks[mid].code && hm->blocks[mid].code <= pc) lo = mid;
            else hi = mid - 1;
        }
        HvBlock *b = &hm->blocks[lo];
        int el = (b->flags & HV_BLOCK_EL1) ? 1 : 0;
        {
            ptrdiff_t off = b->code && pc >= b->code ? pc - b->code : -1;
            prof_off[off < 0 ? 11 : off < 8 ? off : off < 16 ? 8 : off < 32 ? 9 : 10]++;
        }
        prof_el[el]++;
        if (prof_pcs) {
            uint32_t h = (uint32_t)(((uint64_t)(uintptr_t)pc >> 2) * 0x9e3779b1u) & (PROF_PCS - 1);
            for (int k = 0; k < 16; k++, h = (h + 1) & (PROF_PCS - 1))
                if (!prof_pcs[h].n || prof_pcs[h].pc == pc) {
                    prof_pcs[h].pc = pc, prof_pcs[h].n++;
                    break;
                }
        }
        uint32_t h = (uint32_t)((b->va >> 2) * 0x9e3779b1u) & (PROF_SLOTS - 1);
        for (int p = 0; p < 32; p++, h = (h + 1) & (PROF_SLOTS - 1)) {
            if (!prof_blocks[h].n || prof_blocks[h].va == b->va) {
                prof_blocks[h].va = b->va, prof_blocks[h].el = el, prof_blocks[h].n++;
                break;
            }
        }
    } else {
        Dl_info di;
        void *start = dladdr(pc, &di) ? di.dli_saddr : NULL;
        if (!start) prof_unknown++;
        else {
            int k = 0;
            while (k < prof_nfn && prof_fn[k].start != start) k++;
            if (k == prof_nfn && prof_nfn < 512) prof_fn[prof_nfn].start = start, prof_fn[prof_nfn].name = di.dli_sname ? di.dli_sname : "?", prof_nfn++;
            if (k < prof_nfn) prof_fn[k].n++;
        }
    }
    pthread_mutex_unlock(&prof_mu);
}

static thread_act_t prof_threads[HV_MAX_CPUS];
static _Atomic int prof_nthreads;
void hv_prof_register_thread(void) {
    if (getenv("HV_PROF_ALL")) prof_threads[atomic_fetch_add(&prof_nthreads, 1)] = mach_thread_self();
}

static void *prof_thread(void *unused) {
    (void)unused;
    for (;;) {
        usleep(1000);
        for (int i = 0; i < atomic_load(&prof_nthreads); i++) prof_sample(prof_threads[i]);
    }
    return NULL;
}

static int prof_cmp_fn(const void *a, const void *b) {
    return (int)((const __typeof__(prof_fn[0]) *)b)->n - (int)((const __typeof__(prof_fn[0]) *)a)->n;
}
static int prof_cmp_pc(const void *a, const void *b) {
    const ProfPc *x = a, *y = b;
    return x->pc < y->pc ? -1 : x->pc > y->pc;
}
static int prof_cmp_block(const void *a, const void *b) {
    return (int)((const ProfBlock *)b)->n - (int)((const ProfBlock *)a)->n;
}

static void prof_dump(const char *path) {
    pthread_mutex_lock(&prof_mu);
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "total %llu idle %llu el0 %llu el1 %llu unknown %llu\n", (unsigned long long)prof_total, (unsigned long long)prof_idle, (unsigned long long)prof_el[0], (unsigned long long)prof_el[1], (unsigned long long)prof_unknown);
        fprintf(f, "offsets");
        for (int k = 0; k < 12; k++) fprintf(f, " %llu", (unsigned long long)prof_off[k]);
        fprintf(f, "\n");
        qsort(prof_fn, (size_t)prof_nfn, sizeof prof_fn[0], prof_cmp_fn);
        for (int i = 0; i < prof_nfn && prof_fn[i].n; i++) fprintf(f, "fn %u %s\n", prof_fn[i].n, prof_fn[i].name);
        static ProfBlock sorted[PROF_SLOTS];
        memcpy(sorted, prof_blocks, sizeof sorted);
        qsort(sorted, PROF_SLOTS, sizeof sorted[0], prof_cmp_block);
        for (uint32_t i = 0; i < 20000 && sorted[i].n; i++) fprintf(f, "b %u %llx %u\n", sorted[i].n, (unsigned long long)sorted[i].va, sorted[i].el);
        if (prof_pcs) { /* each hot run of host code as it stands, with its samples */
            qsort(prof_pcs, PROF_PCS, sizeof prof_pcs[0], prof_cmp_pc);
            HvMachine *pm = hv_vm_machine();
            for (uint32_t i = 0; i < PROF_PCS; i++) {
                if (!prof_pcs[i].n || (prof_pcs[i].n < 8 && !(getenv("HV_PROF_PCS") && atoi(getenv("HV_PROF_PCS")) > 1))) continue;
                fprintf(f, "p %u %llx %08x\n", prof_pcs[i].n, (unsigned long long)(uintptr_t)prof_pcs[i].pc, *prof_pcs[i].pc);
            }
            /* a window of code around the hottest instructions, kept inside the region */
            for (uint32_t i = 0; i < PROF_PCS; i++) {
                if (prof_pcs[i].n < 40) continue;
                uint32_t *c = prof_pcs[i].pc, *lo = c - 24, *hi = c + 8;
                if (lo < pm->jit.base) lo = pm->jit.base;
                if (hi > pm->jit.base + pm->jit.capacity) hi = pm->jit.base + pm->jit.capacity;
                fprintf(f, "w %llx", (unsigned long long)(uintptr_t)lo);
                for (uint32_t *k = lo; k < hi; k++) fprintf(f, " %08x", *k);
                fprintf(f, "\n");
            }
            memset(prof_pcs, 0, PROF_PCS * sizeof prof_pcs[0]);
        }
        fclose(f);
    }
    memset(prof_blocks, 0, sizeof prof_blocks);
    for (int i = 0; i < prof_nfn; i++) prof_fn[i].n = 0;
    prof_total = prof_idle = prof_el[0] = prof_el[1] = prof_unknown = prof_spin = 0;
    memset(prof_off, 0, sizeof prof_off);
    pthread_mutex_unlock(&prof_mu);
}

static void click_here(void) {
    hv_vm_mouse_button(0, 1);
    usleep(120000);
    hv_vm_mouse_button(0, 0);
}

static void key_event(int code, int down) {
    hv_virt_machine_lock();
    hv_vm_key((uint16_t)code, down);
    hv_virt_machine_unlock();
}

static void key_press(int code, int shift) {
    if (shift) key_event(42, 1), usleep(30000);
    key_event(code, 1);
    usleep(60000);
    key_event(code, 0);
    if (shift) usleep(30000), key_event(42, 0);
    usleep(60000);
}

static void type_text(const char *t) {
    static const char row1[] = "qwertyuiop", row2[] = "asdfghjkl", row3[] = "zxcvbnm", nums[] = "1234567890", shifted[] = "!@#$%^&*()";
    static const struct { char c; uint8_t code, shift; } extra[] = {
        {' ', 57, 0}, {'.', 52, 0}, {'-', 12, 0}, {'/', 53, 0}, {',', 51, 0}, {';', 39, 0}, {'\'', 40, 0}, {'=', 13, 0}, {'[', 26, 0},
        {']', 27, 0}, {'\\', 43, 0}, {'`', 41, 0}, {'_', 12, 1}, {'+', 13, 1}, {':', 39, 1}, {'"', 40, 1}, {'|', 43, 1}, {'<', 51, 1},
        {'>', 52, 1}, {'?', 53, 1}, {'~', 41, 1}, {'{', 26, 1}, {'}', 27, 1}};
    for (; *t; t++) {
        int c = *t, up = c >= 'A' && c <= 'Z', code = 0;
        if (up) c += 32;
        const char *f;
        if ((f = strchr(row1, c))) code = 16 + (int)(f - row1);
        else if ((f = strchr(row2, c))) code = 30 + (int)(f - row2);
        else if ((f = strchr(row3, c))) code = 44 + (int)(f - row3);
        else if ((f = strchr(nums, c))) code = 2 + (int)(f - nums);
        else if ((f = strchr(shifted, c))) code = 2 + (int)(f - shifted), up = 1;
        else
            for (size_t k = 0; k < sizeof extra / sizeof extra[0]; k++)
                if (extra[k].c == c) code = extra[k].code, up = extra[k].shift;
        if (code) key_press(code, up);
    }
}

/* Debugging: HV_INPUT_FILE=path follows a file of lines, for driving a running guest:
   "click x y", "move x y", "key code" (Linux), "hidkey usage", "hiddown usage", "hidup usage", "shiftkey code", "type words", "wait seconds". */
static void hid_locked(uint8_t usage, int down) {
    hv_virt_machine_lock();
    hv_vm_key_hid(usage, down);
    hv_virt_machine_unlock();
}

/* The Files folders (fs_server.h): --folder, then the input file's folder lines. boot_cfg points here, so a
   restart boots with the list as it is then. Indexes are the folder table's; a removed one is a hole (no name). */
static HvVmConfig boot_cfg;
static HvVmFolder folder_list[HV_FS_MAX_FOLDERS];
static char folder_names[HV_FS_MAX_FOLDERS][HV_FS_NAME_MAX + 1], folder_paths[HV_FS_MAX_FOLDERS][1024];
static int nfolders;

/* Adds or replaces NAME; 0, or -1 with a message. */
static int folder_put(const char *name, const char *path, int mode, int live) {
    int i = 0, hole = -1;
    for (; i < nfolders && !(folder_list[i].name && !strcmp(folder_names[i], name)); i++)
        if (!folder_list[i].name && hole < 0) hole = i;
    if (i == nfolders && hole >= 0) i = hole;
    if (i == HV_FS_MAX_FOLDERS) {
        fprintf(stderr, "hengevm: at most %d folders\n", HV_FS_MAX_FOLDERS);
        return -1;
    }
    if (strlen(name) > HV_FS_NAME_MAX || strlen(path) >= sizeof folder_paths[0]) {
        fprintf(stderr, "hengevm: folder %s: name or path too long\n", name);
        return -1;
    }
    if (live && hv_fs_folder_set(i, NULL, name, path, mode) != 0) {
        fprintf(stderr, "hengevm: folder %s: %s\n", name, strerror(errno));
        return -1;
    }
    snprintf(folder_names[i], sizeof folder_names[i], "%s", name);
    snprintf(folder_paths[i], sizeof folder_paths[i], "%s", path);
    folder_list[i] = (HvVmFolder){NULL, folder_names[i], folder_paths[i], mode};
    if (i == nfolders) nfolders++;
    boot_cfg.nfolders = nfolders;
    return 0;
}

/* --folder NAME=DIR[:ro|cow|rw]; the mode is Read-write when the last ':' is not followed by one. */
static int folder_arg(const char *arg) {
    const char *eq = strchr(arg, '=');
    char name[HV_FS_NAME_MAX + 2], path[1024];
    if (!eq || eq == arg || (size_t)(eq - arg) > HV_FS_NAME_MAX || strlen(eq + 1) >= sizeof path) {
        fprintf(stderr, "hengevm: --folder %s: want NAME=DIR[:ro|cow|rw]\n", arg);
        return -1;
    }
    snprintf(name, sizeof name, "%.*s", (int)(eq - arg), arg);
    snprintf(path, sizeof path, "%s", eq + 1);
    char *colon = strrchr(path, ':');
    int mode = colon ? hv_fs_mode_parse(colon + 1) : -1;
    if (mode >= 0) *colon = 0;
    else mode = HV_FS_RW;
    return folder_put(name, path, mode, 0);
}

typedef struct FolderAsk {
    int index;
    long ask;
    char name[HV_FS_NAME_MAX + 1];
} FolderAsk;

/* Prints the helper's answer as "hengevm: folder NAME answer: ok|failed: TEXT" (files-check waits for it). */
static void *folder_answer_wait(void *arg) {
    FolderAsk *a = arg;
    int ok = 0, rc = 0;
    char *text = NULL;
    for (int t = 0; t < 1800 && (rc = hv_fs_folder_answered(a->index, a->ask, &ok, &text)) == 0; t++) usleep(100000);
    if (rc == 1) fprintf(stderr, "hengevm: folder %s answer: %s: %s\n", a->name, ok ? "ok" : "failed", text ? text : "");
    else fprintf(stderr, "hengevm: folder %s: no answer\n", a->name);
    free(text);
    free(a);
    return NULL;
}

/* folder add NAME PATH ro|cow|rw (PATH may have spaces), folder remove|offline|online|touch|export|discard NAME,
   folders (prints them). */
static void folder_line(const char *line) {
    char name[HV_FS_NAME_MAX + 2] = "";
    if (!strcmp(line, "folders")) {
        char *j = hv_fs_folders_json(NULL);
        fprintf(stderr, "hengevm: folders: %s", j ? j : "?\n");
        free(j);
        return;
    }
    if (!strncmp(line, "folder add ", 11)) {
        const char *p = line + 11, *sp = strchr(p, ' '), *last = strrchr(p, ' ');
        int mode = last && last > sp ? hv_fs_mode_parse(last + 1) : -1;
        if (!sp || mode < 0 || sp - p > HV_FS_NAME_MAX) {
            fprintf(stderr, "hengevm: input: %s: want folder add NAME PATH ro|cow|rw\n", line);
            return;
        }
        char path[1024];
        snprintf(name, sizeof name, "%.*s", (int)(sp - p), p);
        snprintf(path, sizeof path, "%.*s", (int)(last - sp - 1), sp + 1);
        if (folder_put(name, path, mode, 1) == 0 && (!hv_vm_virt() || !hv_vm_virt()->fs))
            fprintf(stderr, "hengevm: folder %s is in the table, but this machine has no virtio-fs device (boot with --folder)\n", name);
        return;
    }
    static const char *const verbs[] = {"folder remove ", "folder offline ", "folder online ", "folder touch ",
                                        "folder export ", "folder discard "};
    for (int k = 0; k < 6; k++) {
        if (strncmp(line, verbs[k], strlen(verbs[k]))) continue;
        snprintf(name, sizeof name, "%s", line + strlen(verbs[k]));
        int i = hv_fs_folder_find(name);
        if (i < 0) fprintf(stderr, "hengevm: input: no folder %s\n", name);
        else if (k == 0) {
            hv_fs_folder_clear(i);
            folder_list[i].name = NULL; /* a hole: the others keep their indexes, so the guest's nodes stay good */
        } else if (k < 3) hv_fs_folder_online(i, k == 2);
        else if (k == 3) hv_fs_folder_touch(i);
        else {
            long ask = hv_fs_folder_ask(i, k == 4 ? HV_FS_ASK_EXPORT : HV_FS_ASK_DISCARD);
            FolderAsk *a = ask > 0 ? malloc(sizeof *a) : NULL;
            pthread_t t;
            if (ask < 0) fprintf(stderr, "hengevm: folder %s: %s\n", name, strerror(errno));
            else if (a) {
                *a = (FolderAsk){i, ask, ""};
                snprintf(a->name, sizeof a->name, "%s", name);
                if (pthread_create(&t, NULL, folder_answer_wait, a) == 0) pthread_detach(t);
                else free(a);
            }
        }
        return;
    }
    fprintf(stderr, "hengevm: input: %s: want folder add|remove|offline|online|touch|export|discard\n", line);
}

/* HV_INPUT_FILE lines for the virt board: rel DX DY, rclick, msleep MS, tpframe (ends a touch batch), mode WxH [SCALE] (live display mode).
   Device status: battery LEVEL unplugged|charging|full|unknown, brightness F, volume F, tz NAME, and status (prints it). HV_STATUS_LOG=1 logs the guest's requests.
   Touchscreen: ts SLOT PHASE X Y, tsframe, tscancel, tsmode 0|1.
   Files folders: folder add NAME PATH ro|cow|rw, folder remove NAME, folder offline NAME, folder online NAME, folders;
   folder touch NAME (the original changed), folder export NAME and folder discard NAME (asks to the guest's helper).
   --screenshot still writes the --display size, so read the size from the guest after a mode line. */
static int virt_input(const char *line) {
    int a, b;
    unsigned code;
    if (sscanf(line, "rel %d %d", &a, &b) == 2) {
        hv_virt_machine_lock();
        hv_vm_mouse_move(a, b);
        hv_virt_machine_unlock();
    } else if (!strncmp(line, "mode ", 5)) {
        unsigned w, h;
        double scale;
        int n = sscanf(line + 5, "%ux%u %lf", &w, &h, &scale);
        if (n < 2 || !w || !h) fprintf(stderr, "hengevm: input: %s: want mode WxH [SCALE]\n", line);
        else {
            hv_vm_set_display_mode(w, h);
            if (n == 3) hv_vm_set_display_scale(scale);
        }
    } else if (!strncmp(line, "battery ", 8)) {
        char state[16] = "";
        static const char *const states[] = {"unknown", "unplugged", "charging", "full"};
        int s = -1;
        if (sscanf(line + 8, "%d %15s", &a, state) == 2)
            for (int k = 0; k < 4; k++)
                if (!strcmp(state, states[k])) s = k;
        if (s < 0) fprintf(stderr, "hengevm: input: %s: want battery LEVEL unplugged|charging|full|unknown\n", line);
        else hv_vm_set_battery(a, s);
    } else if (!strncmp(line, "brightness ", 11)) {
        hv_vm_set_brightness(atof(line + 11));
    } else if (!strncmp(line, "volume ", 7)) {
        hv_vm_set_volume(atof(line + 7));
    } else if (!strncmp(line, "tz ", 3)) {
        if (hv_vm_set_timezone(line + 3) != 0) fprintf(stderr, "hengevm: input: %s: not a time zone name\n", line);
    } else if (!strncmp(line, "folder ", 7) || !strcmp(line, "folders")) {
        folder_line(line);
    } else if (!strcmp(line, "status")) {
        HvStatusView v;
        hv_status_get(&v);
        fprintf(stderr, "hengevm: status: battery %d state %d current %d mA, brightness %.3f, volume %.2f%s, tz %s, seq %lu\n",
                v.battery_level, v.battery_state, v.current_ma, v.brightness, v.volume, v.muted ? " muted" : "",
                v.tz[0] ? v.tz : "-", v.seq);
    } else if (sscanf(line, "msleep %d", &a) == 1) {
        usleep((useconds_t)a * 1000);
    } else if (!strncmp(line, "rclick", 6)) {
        hv_vm_mouse_button(1, 1);
        usleep(120000);
        hv_vm_mouse_button(1, 0);
    } else if (sscanf(line, "btn %i %d", &code, &b) == 2) {
        hv_virt_machine_lock();
        hv_virtio_input_send(hv_vm_virt()->mouse, HV_EV_KEY, (uint16_t)code, b);
        hv_virtio_input_send(hv_vm_virt()->mouse, HV_EV_SYN, 0, 0);
        hv_virt_machine_unlock();
    } else if (!strncmp(line, "tp ", 3)) {
        int id, phase, px, py;
        if (sscanf(line + 3, "%d %d %d %d", &id, &phase, &px, &py) != 4) return 1;
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        uint32_t ms = (uint32_t)((uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000);
        hv_virt_machine_lock();
        hv_vm_touch(id, phase, px, py, ms);
        hv_virt_machine_unlock();
    } else if (!strncmp(line, "tpframe", 7)) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        hv_virt_machine_lock();
        hv_vm_touch_frame((uint32_t)((uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000));
        hv_virt_machine_unlock();
    } else if (!strncmp(line, "tpclick ", 8)) {
        hv_virt_machine_lock();
        hv_vm_touch_button(atoi(line + 8));
        hv_virt_machine_unlock();
    } else if (!strncmp(line, "ts ", 3)) { /* touchscreen: ts SLOT 0|1|2 X Y (0 to 32767), then tsframe */
        int slot, phase, px, py;
        if (sscanf(line + 3, "%d %d %d %d", &slot, &phase, &px, &py) != 4) {
            fprintf(stderr, "hengevm: input: %s: want ts SLOT 0|1|2 X Y\n", line);
            return 1;
        }
        hv_virt_machine_lock();
        hv_vm_screen_touch(slot, phase, px, py);
        hv_virt_machine_unlock();
    } else if (!strcmp(line, "tsframe") || !strcmp(line, "tscancel")) {
        hv_virt_machine_lock();
        if (line[2] == 'f') hv_vm_screen_touch_frame();
        else hv_vm_screen_touch_cancel();
        hv_virt_machine_unlock();
    } else if (!strncmp(line, "tsmode ", 7)) { /* 1: touch mode (the pointer image hides at a touch), 0: pointer */
        hv_vm_set_touch_mode(atoi(line + 7));
        fprintf(stderr, "hengevm: touch mode %d, pointer image hidden %d\n", atoi(line + 7) != 0, hv_vm_pointer_hidden());
    } else
        return 0;
    return 1;
}

static void *input_thread(void *unused) {
    (void)unused;
    FILE *f = fopen(getenv("HV_INPUT_FILE"), "a+");
    if (!f) return NULL;
    long at = 0;
    for (;;) {
        char line[512];
        fseek(f, at, SEEK_SET);
        if (!fgets(line, sizeof line, f) || !strchr(line, '\n')) {
            clearerr(f);
            usleep(200000);
            continue;
        }
        at = ftell(f);
        line[strcspn(line, "\n")] = 0;
        int x, y;
        if (virt_input(line)) {}
        else if (sscanf(line, "click %d %d", &x, &y) == 2) click_here();
        else if (sscanf(line, "scroll %d %d", &x, &y) == 2) {
            hv_virt_machine_lock();
            if (y) hv_vm_mouse_wheel(y);
            if (x) hv_vm_mouse_hwheel(x);
            hv_virt_machine_unlock();
        }
        else if (!strncmp(line, "pointer", 7)) {
            int px = -1, py = -1;
            int rc = hv_vm_pointer(&px, &py);
            fprintf(stderr, "hengevm: pointer %d: %d, %d\n", rc, px, py);
        }
        else if (!strncmp(line, "snapshot ", 9)) { /* FILE, a 32-bit BMP of what hv_vm_snapshot gives the app */
            enum { W = 640, H = 360 };
            static uint8_t px[W * H * 4];
            int rc = hv_vm_snapshot(px, W, H);
            fprintf(stderr, "hengevm: snapshot %d\n", rc);
            FILE *bf = rc == 0 ? fopen(line + 9, "wb") : NULL;
            if (bf) {
                uint32_t size = W * H * 4;
                uint8_t h[54] = {'B', 'M'};
                uint32_t v;
                v = 54 + size; memcpy(h + 2, &v, 4);
                v = 54; memcpy(h + 10, &v, 4);
                v = 40; memcpy(h + 14, &v, 4);
                int32_t iw = W, ih = -H; memcpy(h + 18, &iw, 4); memcpy(h + 22, &ih, 4);
                h[26] = 1; h[28] = 32;
                memcpy(h + 34, &size, 4);
                fwrite(h, 1, 54, bf);
                fwrite(px, 1, size, bf);
                fclose(bf);
            }
        }
        else if (!strncmp(line, "clip ", 5)) hv_share_set_clipboard(line + 5);
        else if (!strncmp(line, "getclip", 7)) {
            char *text = hv_share_take_clipboard();
            fprintf(stderr, "hengevm: guest clipboard: %s (helper seen %ld s ago)\n", text ? text : "(nothing new)", hv_share_helper_seen());
            free(text);
        }
        else if (!strncmp(line, "kbdheight ", 10)) hv_share_set_keyboard_height(atof(line + 10)); /* the device keyboard's part of the screen */
        else if (!strncmp(line, "getkbd", 6)) { /* what henge-keyboard in a Linux desktop last asked for */
            unsigned long seq;
            int wanted = hv_share_keyboard_wanted(&seq);
            fprintf(stderr, "hengevm: guest keyboard: %s (request %lu)\n", wanted ? "show" : "hide", seq);
        }
        else if (sscanf(line, "hiddown %i", &x) == 1) hid_locked((uint8_t)x, 1);
        else if (sscanf(line, "hidup %i", &x) == 1) hid_locked((uint8_t)x, 0);
        else if (sscanf(line, "hidkey %i", &x) == 1) {
            hid_locked((uint8_t)x, 1);
            usleep(60000);
            hid_locked((uint8_t)x, 0);
        }
        else if (!strncmp(line, "secrets", 7)) { /* "secrets lock|unlock": the app's Face ID check (testing) */
            if (!strcmp(line + 7, " lock")) hv_secrets_set_locked(1);
            else if (!strcmp(line + 7, " unlock")) hv_secrets_set_locked(0);
            fprintf(stderr, "hengevm: secrets %s\n", hv_secrets_locked() ? "locked" : "unlocked");
        }
        else if (sscanf(line, "key %d", &x) == 1) key_press(x, 0);
        else if (sscanf(line, "shiftkey %d", &x) == 1) key_press(x, 1);
        else if (sscanf(line, "cmdkey %d", &x) == 1) { /* with Command held: 125 is the left one */
            key_event(125, 1);
            usleep(60000);
            key_press(x, 0);
            usleep(60000);
            key_event(125, 0);
        }
        else if (sscanf(line, "wait %d", &x) == 1) sleep((unsigned)x);
        else if (!strncmp(line, "type ", 5)) type_text(line + 5);
        else if (!strncmp(line, "prof ", 5)) prof_dump(line + 5);
        else if (!strncmp(line, "balloon ", 8) || !strncmp(line, "balloonstat", 11)) { /* "balloon MB": target (HV_BALLOON set at boot); both print the counters */
            HvVirtioBalloon *bl = hv_vm_devs()->balloon;
            if (!bl) fprintf(stderr, "hengevm: no balloon (set HV_BALLOON)\n");
            else {
                if (line[7] == ' ') hv_virtio_balloon_set_target(bl, (uint64_t)atoll(line + 8) << 20);
                fprintf(stderr, "hengevm: balloon: actual %llu MB, given back %llu MB, taken back %llu MB, partial %llu, out of ram %llu, failed %llu\n",
                        (unsigned long long)(hv_virtio_balloon_actual(bl) >> 20), (unsigned long long)(bl->given_back * 16 >> 10),
                        (unsigned long long)(bl->taken_back * 16 >> 10), (unsigned long long)bl->partial,
                        (unsigned long long)bl->out_of_ram, (unsigned long long)bl->failed);
            }
        }
        else if (!strncmp(line, "knob ", 5)) {
            char name[32];
            if (sscanf(line, "knob %31s %d", name, &x) == 2 && !hv_knob_set(hv_vm_machine(), name, x))
                fprintf(stderr, "hengevm: no knob %s\n", name);
        }
        fprintf(stderr, "hengevm: input: %s\n", line);
    }
    return NULL;
}

/* The virt board's console and exit status. */
static struct termios saved_tio;
static volatile sig_atomic_t tio_saved;
static volatile sig_atomic_t quit_req;
static int no_reboot;
static HvVmConfig boot_cfg;
static struct { int trace, chain_ok; uint64_t watch, watch_pa; int stats, profile; } boot_opts;
enum { EXIT_RESTART = 3, EXIT_FAULT = 4 };

/* --screenshot on the virt board: the guest's display as a PNG, rewritten every HV_SHOT_SECS (2) once it shows one. */
static const char *virt_shot_path;
static unsigned virt_w = 1920, virt_h = 1080; /* the mode hv_virt_create offers unless --display says otherwise */

static int write_png(const char *path, uint8_t *bgra, unsigned w, unsigned h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, bgra, (size_t)w * h * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, dp, NULL, false, kCGRenderingIntentDefault);
    CFStringRef cfp = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfp, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dst = img ? CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL) : NULL;
    int ok = 0;
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CFRelease(url), CFRelease(cfp);
    if (img) CGImageRelease(img);
    CGDataProviderRelease(dp), CGColorSpaceRelease(cs);
    return ok ? 0 : -1;
}

/* Held across a guest restart's destroy and create: the shot thread and window input never see a half-built board. */
static pthread_mutex_t machine_mu = PTHREAD_MUTEX_INITIALIZER;

void hv_virt_machine_lock(void) { pthread_mutex_lock(&machine_mu); }
void hv_virt_machine_unlock(void) { pthread_mutex_unlock(&machine_mu); }

/* The window closed: stop like Ctrl-A x, so the disks flush and the status is 0. */
void hv_virt_quit(void) {
    quit_req = 1;
    hv_vm_stop();
}

static void *virt_shot_thread(void *unused) {
    (void)unused;
    const char *e = getenv("HV_SHOT_SECS");
    double every = e && atof(e) > 0 ? atof(e) : 2.0;
    size_t bytes = (size_t)virt_w * virt_h * 4;
    uint8_t *px = malloc(bytes);
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.tmp.png", virt_shot_path);
    while (px) {
        usleep((useconds_t)(every * 1e6));
        pthread_mutex_lock(&machine_mu);
        int rc = hv_vm_snapshot(px, (int)virt_w, (int)virt_h);
        pthread_mutex_unlock(&machine_mu);
        if (rc != 0) continue;
        if (write_png(tmp, px, virt_w, virt_h) == 0) rename(tmp, virt_shot_path); /* a reader never sees half a file */
    }
    return NULL;
}

static void tty_restore(void) {
    if (tio_saved) tcsetattr(0, TCSANOW, &saved_tio), tio_saved = 0;
}

static const int fatal_sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGQUIT};
static struct sigaction prior_fatal[sizeof fatal_sigs / sizeof *fatal_sigs];

/* Restores the tty and runs the handler before ours (vm.c's crash report), then the default action.
   macOS gives a sent SIGSEGV a fault's si_code, so a fault cannot be told apart and left to recur. */
static void on_fatal(int sig, siginfo_t *info, void *ctx) {
    tty_restore();
    for (size_t i = 0; i < sizeof fatal_sigs / sizeof *fatal_sigs; i++) {
        struct sigaction *p = &prior_fatal[i];
        if (fatal_sigs[i] != sig) continue;
        if (p->sa_flags & SA_SIGINFO) p->sa_sigaction(sig, info, ctx);
        else if (p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN) p->sa_handler(sig);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void tty_raw(void) {
    if (!isatty(0) || tcgetattr(0, &saved_tio) != 0) return;
    struct termios t = saved_tio;
    cfmakeraw(&t);
    t.c_oflag |= OPOST; /* keep \n to \r\n on output */
    if (tcsetattr(0, TCSANOW, &t) != 0) return;
    tio_saved = 1;
    atexit(tty_restore);
    struct sigaction sa = {.sa_flags = SA_SIGINFO | SA_ONSTACK};
    sa.sa_sigaction = on_fatal;
    for (size_t i = 0; i < sizeof fatal_sigs / sizeof *fatal_sigs; i++) sigaction(fatal_sigs[i], &sa, &prior_fatal[i]);
}

static void console_out(void *opaque, uint8_t c) {
    (void)opaque;
    ssize_t r = write(1, &c, 1);
    (void)r;
}

/* SIGTERM presses the power key; a second one stops the machine at once. */
static void sigterm_as_power_key(void) {
    static dispatch_source_t src;
    static int taken;
    signal(SIGTERM, SIG_IGN);
    src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                 dispatch_queue_create("henge.sigterm", DISPATCH_QUEUE_SERIAL));
    dispatch_source_set_event_handler(src, ^{
        /* the source merges signals that come before the handler runs; count them all */
        taken += (int)dispatch_source_get_data(src);
        if (taken >= 2) on_signal(SIGTERM);
        else if (!hv_vm_power_button()) taken = 0; /* no key pressed: not the first of two */
    });
    dispatch_resume(src);
}

/* Ctrl-A s and SIGTSTP: what the iOS app does in the background (hv_vm_pause). */
static void say_gpu(const char *when) {
    uint64_t frames, requests;
    int g = hv_vm_gpu_counts(&frames, &requests);
    if (g >= 0) fprintf(stderr, "hengevm: gpu %s %s: %llu frames, %llu renderer requests\n", g ? "held" : "running", when,
                        (unsigned long long)frames, (unsigned long long)requests);
}

static void toggle_pause(void) {
    if (hv_vm_paused()) {
        say_gpu("before the resume");
        fprintf(stderr, "hengevm: resumed; %.1f s hidden from the guest\n", hv_vm_resume());
    } else if (hv_vm_pause() == 0) {
        fprintf(stderr, "hengevm: paused (Ctrl-A s resumes)\n");
        say_gpu("after the pause");
    } else fprintf(stderr, "hengevm: cannot pause\n");
}

/* Ctrl-A b: the app's background policy (hv_vm_set_background), so a check can run it with the guest playing sound. */
static void toggle_background(void) {
    static int away;
    away = !away;
    if (!away) say_gpu("before the foreground");
    int sound = hv_audio_playing();
    hv_vm_set_background(away);
    fprintf(stderr, "hengevm: %s with the guest's sound %s: %s\n", away ? "background" : "foreground",
            sound ? "playing" : "silent", hv_vm_paused() ? "paused" : "running");
    if (away) say_gpu("after the background");
}

/* SIGTSTP pauses the machine and then stops the process, as iOS freezes the app; SIGCONT resumes it. */
static void sigtstp_as_suspend(void) {
    static dispatch_source_t tstp, cont;
    static _Atomic int stopped;
    dispatch_queue_t q = dispatch_queue_create("henge.suspend", DISPATCH_QUEUE_SERIAL);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGCONT, SIG_IGN); /* still continues the process; the source below sees it */
    tstp = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTSTP, 0, q);
    dispatch_source_set_event_handler(tstp, ^{
        if (hv_vm_paused() || hv_vm_pause() != 0) return;
        say_gpu("after the pause");
        fprintf(stderr, "hengevm: paused and stopped (SIGCONT resumes)\n");
        atomic_store(&stopped, 1);
        kill(getpid(), SIGSTOP);
    });
    cont = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGCONT, 0, q);
    dispatch_source_set_event_handler(cont, ^{
        if (atomic_exchange(&stopped, 0) && hv_vm_paused()) {
            say_gpu("before the resume");
            fprintf(stderr, "hengevm: resumed; %.1f s hidden from the guest\n", hv_vm_resume());
        }
    });
    dispatch_resume(tstp);
    dispatch_resume(cont);
}

/* Stdin to the guest's UART. Ctrl-A x quits, Ctrl-A p presses the power key, Ctrl-A s pauses or resumes, Ctrl-A b enters or leaves the app's background and
   Ctrl-A Ctrl-A sends one Ctrl-A. */
static void *stdin_thread(void *unused) {
    (void)unused;
    uint8_t in[256], out[256];
    int ctrl_a = 0;
    ssize_t n;
    while ((n = read(0, in, sizeof in)) > 0) {
        size_t k = 0;
        for (ssize_t i = 0; i < n; i++) {
            uint8_t c = in[i];
            if (!ctrl_a) {
                if (c == 1) ctrl_a = 1;
                else out[k++] = c;
                continue;
            }
            ctrl_a = 0;
            if (c == 'x' || c == 'X') {
                if (k) hv_vm_console_input(out, k);
                quit_req = 1;
                hv_vm_stop();
                return NULL;
            }
            if (c == 'p' || c == 'P') hv_vm_power_button();
            if (c == 's' || c == 'S') toggle_pause();
            if (c == 'b' || c == 'B') toggle_background();
            if (c == 1) out[k++] = 1;
        }
        if (k) hv_vm_console_input(out, k);
    }
    return NULL;
}

/* Exit status and reason for how CPU 0 ended. r is the engine's exit reason, halted the HvHaltReason. */
static int stop_status(int r, int halted, const char **why) {
    if (quit_req || interrupted) return *why = quit_req ? "quit" : "interrupted", 0;
    if (halted == HV_HALT_SHUTDOWN) return *why = "guest shutdown", 0;
    if (halted == HV_HALT_RESET) return *why = "guest restart", EXIT_RESTART;
    if (r != HV_EXIT_HALT) return *why = reason_name(r), EXIT_FAULT;
    return *why = "halted", 0;
}

static void finish(const char *why, int status) {
    fprintf(stderr, "hengevm: stopped: %s\n", why);
    exit(status);
}

static void apply_machine_opts(void) {
    m.trace = boot_opts.trace;
    m.watch_va = boot_opts.watch;
    m.watch_pa = boot_opts.watch_pa;
    m.stats_interval = boot_opts.stats; /* set after the machine is made, which clears it */
    if (boot_opts.profile && !m.prof) m.prof = calloc(HV_PROF_RING, sizeof *m.prof);
    m.chain = boot_opts.chain_ok;
}

static void virt_exit(int r);

/* Off CPU 0's thread, so hv_vm_destroy can join it. */
static void *rebuild_thread(void *unused) {
    (void)unused;
    char err[256];
    pthread_mutex_lock(&machine_mu);
    hv_vm_destroy();
    int made = hv_vm_create(&boot_cfg, err, sizeof err);
    pthread_mutex_unlock(&machine_mu);
    if (made != 0) {
        fprintf(stderr, "hengevm: %s\n", err);
        finish("cannot rebuild the machine", EXIT_FAULT);
    }
    hv_vm_console_set_output(console_out, NULL); /* hv_vm_destroy cleared it */
    apply_machine_opts();
    if (quit_req || interrupted) finish(quit_req ? "quit" : "interrupted", 0); /* a stop while no machine ran */
    if (hv_vm_start(1, virt_exit) != 0) finish("cannot start the machine", EXIT_FAULT);
    return NULL;
}

static void virt_exit(int r) {
    HvCpu *c0 = hv_vm_cpu(0);
    int halted = c0 ? c0->halted : HV_HALT_NONE;
    const char *why;
    int status = stop_status(r, halted, &why);
    if (halted == HV_HALT_RESET && !no_reboot && !quit_req && !interrupted) {
        fprintf(stderr, "hengevm: guest restart: building the machine again\n");
        pthread_t t;
        if (pthread_create(&t, NULL, rebuild_thread, NULL) != 0) finish("cannot rebuild the machine", EXIT_FAULT);
        pthread_detach(t);
        return;
    }
    finish(why, status);
}

static void *cpu_thread(void *unused) {
    (void)unused;
    RunArgs *a = &run_args;
    cpu_port = mach_thread_self();
    hv_vm_cpu_qos();
    /* --break PC: stop the brk_hits-th time execution reaches PC. */
    m.stop_pc = a->brk;
    int r;
    for (;;) {
        r = hv_vm_run_cpu0();
        if (r != HV_EXIT_HALT || cpu.halted || cpu.pc != a->brk || --a->brk_hits == 0) break;
        m.stop_pc = ~0ull; /* step past it: run one block, then re-arm */
        uint64_t at = cpu.pc;
        while (cpu.pc == at && !cpu.halted) {
            m.stop_pc = ~0ull;
            hv_run_one(&cpu);
        }
        m.stop_pc = a->brk;
    }
    if (cpu.pc == a->brk) {
        fprintf(stderr, "hengevm: breakpoint %llx, x30 %llx:", (unsigned long long)a->brk, (unsigned long long)cpu.x[30]);
        hv_debug_args(&cpu);
        fprintf(stderr, "  stack:");
        for (int i = 0; i < 8; i++) {
            uint64_t v = 0, pa;
            if (!hv_mmu_access(&cpu, cpu.sp + 8 * i, HV_ACC_READ, cpu.el, &pa)) hv_phys_read(&m, pa, &v, 8);
            fprintf(stderr, " %llx", (unsigned long long)v);
        }
        fprintf(stderr, "\n");
        if (translate_va) {
            uint64_t pa = 0;
            uint32_t fsc = hv_mmu_access(&cpu, translate_va, HV_ACC_READ, cpu.el, &pa);
            fprintf(stderr, "  translate %llx -> pa %llx (fsc %x)\n", (unsigned long long)translate_va,
                    (unsigned long long)pa, fsc);
        }
    }
    fprintf(stderr, "\nhengevm: stopped (%s) after %llu blocks, %d translated\n", interrupted ? "interrupted" : reason_name(r),
            (unsigned long long)cpu.icount, m.nblocks);
    fprintf(stderr, "  pc %016llx el%u sp %016llx insn %08x\n", (unsigned long long)cpu.pc, cpu.el,
            (unsigned long long)cpu.sp, cpu.exit_insn);
    fprintf(stderr, "  esr %08llx far %016llx elr %016llx vbar %016llx sctlr %08llx\n", (unsigned long long)cpu.esr_el1,
            (unsigned long long)cpu.far_el1, (unsigned long long)cpu.elr_el1, (unsigned long long)cpu.vbar_el1,
            (unsigned long long)cpu.sctlr_el1);
    for (int i = 0; i < 31; i += 4)
        fprintf(stderr, "  x%-2d %016llx %016llx %016llx %016llx\n", i, (unsigned long long)cpu.x[i],
                (unsigned long long)cpu.x[i + 1], (unsigned long long)cpu.x[i + 2],
                (unsigned long long)(i + 3 < 31 ? cpu.x[i + 3] : 0));
    if (a->dump_path) { /* --dump PA LEN FILE: guest physical memory after the run, for reading code */
        FILE *f = fopen(a->dump_path, "wb");
        void *p = hv_phys_ptr(&m, a->dump_pa, a->dump_len);
        if (f && p) fwrite(p, 1, a->dump_len, f);
        if (f) fclose(f);
        fprintf(stderr, "hengevm: %s %llu bytes at %llx to %s\n", p ? "wrote" : "cannot dump", (unsigned long long)a->dump_len,
                (unsigned long long)a->dump_pa, a->dump_path);
    }
    hv_vm_flush_disks();
    {
        const char *why;
        int status = stop_status(r, cpu.halted, &why);
        finish(why, status);
    }
    return NULL;
}

static void usage(void) {
    fprintf(stderr, "usage: hengevm (--firmware FILE | --kernel FILE [--initrd FILE] [--append STRING]) [--disk FILE] [--no-reboot] [--dump-dtb FILE] [--ram MB] [--cpus N] [--log N] [--display WxH] [--gpu-accel [--gpu-video]] [--vcodec | --vcodec-dma] [--screenshot PNG] [--window [--touch]] [--folder NAME=DIR[:ro|cow|rw]]... [--forward HOSTPORT:GUESTPORT]... [--forward-addr IPV4|local]\n"
                    "       (Ctrl-A x quits, Ctrl-A p and SIGTERM press the power key, Ctrl-A s pauses and resumes, Ctrl-A b is the app's background, SIGTSTP pauses and stops until SIGCONT; exit status 0 shutdown, 3 restart with --no-reboot, 4 panic or engine error)\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *disk_path = NULL;
    uint64_t ram_mb = 0;
    const char *firmware = NULL, *kernel = NULL, *initrd = NULL, *append = NULL, *dump_dtb = NULL;
    const char *share_folder = NULL;
    const char *secrets_dir = NULL, *machine_id = "hengevm";
    int log = 1, trace = 0, no_chain = 0, gpu_accel = 0, gpu_video = 0, vcodec = 0; /* vcodec 2: and the device */
    const char *screenshot = NULL;
    uint64_t watch = 0, watch_pa = 0;
    int stats = 0, profile = 0, window = 0;
    uint64_t brk = ~0ull, brk_hits = 1, dump_pa = 0, dump_len = 0;
    const char *dump_path = NULL;
    HvFwdRule forwards[HV_FWD_MAX_RULES];
    int nforwards = 0;
    const char *forward_addr = "127.0.0.1"; /* this Mac only, unless asked */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--window")) {
            window = 1;
            continue;
        }
        if (!strcmp(argv[i], "--touch")) { /* virt --window: a click is a touch on the screen, at its place */
            hv_virt_window_touch = 1;
            hv_vm_set_touch_mode(1);
            continue;
        }
        if (!strcmp(argv[i], "--phone")) {
            /* Test iOS's setup on the Mac: split JIT mapping. */
            setenv("HV_JIT_SPLIT", "1", 1);
            memmove(&argv[i], &argv[i + 1], (size_t)(argc - i - 1) * sizeof *argv);
            argc--, i--;
            continue;
        }
        if (!strcmp(argv[i], "--no-chain")) {
            no_chain = 1;
            continue;
        }
        if (!strcmp(argv[i], "--no-reboot")) {
            no_reboot = 1;
            continue;
        }
        if (!strcmp(argv[i], "--gpu-accel")) {
            gpu_accel = 1;
            continue;
        }
        if (!strcmp(argv[i], "--gpu-video")) {
            gpu_video = 1;
            continue;
        }
        if (!strcmp(argv[i], "--vcodec")) { /* the guest's video codecs at 10.0.2.4:8470 (vcodec.m); VideoToolbox then parses guest bitstreams */
            vcodec = 1;
            continue;
        }
        if (!strcmp(argv[i], "--vcodec-dma")) { /* --vcodec, and the DMA device for /dev/hvcodec (virt only) */
            vcodec = 2;
            continue;
        }
        if (i + 1 >= argc) usage();
        if (!strcmp(argv[i], "--firmware")) firmware = argv[++i];
        else if (!strcmp(argv[i], "--kernel")) kernel = argv[++i];
        else if (!strcmp(argv[i], "--initrd")) initrd = argv[++i];
        else if (!strcmp(argv[i], "--append")) append = argv[++i];
        else if (!strcmp(argv[i], "--dump-dtb")) dump_dtb = argv[++i];
        else if (!strcmp(argv[i], "--share")) { /* FOLDER: the guest reaches it at http://10.0.2.4/ */
            share_folder = argv[++i];
        }
        else if (!strcmp(argv[i], "--secrets")) secrets_dir = argv[++i]; /* DIR: the wallet's items, with --share */
        else if (!strcmp(argv[i], "--folder")) { /* NAME=DIR[:ro|cow|rw], as a folder from the Files app (rw if no mode) */
            if (folder_arg(argv[++i]) != 0) usage();
        }
        else if (!strcmp(argv[i], "--forward")) { /* HOSTPORT:GUESTPORT, TCP into the guest (HV_NET_FWD adds one more) */
            if (nforwards == HV_FWD_MAX_RULES || hv_fwd_parse(argv[++i], &forwards[nforwards]) != 0) {
                fprintf(stderr, "hengevm: --forward %s: want HOSTPORT:GUESTPORT, at most %d\n", argv[i], HV_FWD_MAX_RULES);
                usage();
            }
            nforwards++;
        }
        else if (!strcmp(argv[i], "--forward-addr")) forward_addr = argv[++i]; /* an IPv4 address, or local: as the app */
        else if (!strcmp(argv[i], "--machine-id")) machine_id = argv[++i];
        else if (!strcmp(argv[i], "--display")) { /* WxH */
            unsigned w = 0, h = 0;
            if (sscanf(argv[++i], "%ux%u", &w, &h) == 2 && w && h) hv_vm_set_display_mode(w, h), virt_w = w, virt_h = h;
        }
        else if (!strcmp(argv[i], "--disk")) disk_path = argv[++i];
        else if (!strcmp(argv[i], "--ram")) ram_mb = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--log")) log = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace")) trace = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--screenshot")) screenshot = argv[++i];
        else if (!strcmp(argv[i], "--watch")) watch = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--stats")) stats = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--profile")) profile = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cpus")) ncpus = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--watch-pa")) watch_pa = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--translate")) translate_va = strtoull(argv[++i], NULL, 0);

        else if (!strcmp(argv[i], "--break")) brk = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--break-hits")) brk_hits = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--dump") && i + 3 < argc) {
            dump_pa = strtoull(argv[++i], NULL, 0);
            dump_len = strtoull(argv[++i], NULL, 0);
            dump_path = argv[++i];
        }
        else usage();
    }
    {
        const char *bad = NULL;
        if (!firmware && !kernel && !dump_dtb) bad = "need --firmware or --kernel";
        else if (firmware && kernel) bad = "--firmware and --kernel cannot be used together";
        else if ((initrd || append) && !kernel && !dump_dtb) bad = "--initrd and --append need --kernel";
        else if (dump_dtb && initrd) bad = "--dump-dtb writes no initrd range; leave out --initrd";
        else if (gpu_accel && dump_dtb) bad = "--gpu-accel makes no device tree";
        if (bad) {
            fprintf(stderr, "hengevm: %s\n", bad);
            usage();
        }
        virt_shot_path = screenshot;
    }
    if (!ram_mb) ram_mb = 2048;
    setvbuf(stderr, NULL, _IONBF, 0);

    HvVmConfig vc = {.rom = dump_dtb ? NULL : firmware, .disk = disk_path,
                     .kernel = dump_dtb ? NULL : kernel, .initrd = dump_dtb ? NULL : initrd, .cmdline = dump_dtb ? NULL : append,
                     .ram_mb = ram_mb, .ncpus = ncpus, .log = log, .no_net = dump_dtb || getenv("HV_NO_NET") != NULL,
                     .no_sound = dump_dtb != NULL, .accel = gpu_accel,
                     .video = gpu_video, .folders = folder_list, .nfolders = nfolders,
                     .codec_ops = vcodec == 2 && !dump_dtb ? hv_vcodec_device_ops() : NULL};
    if (getenv("HV_JIT_MB")) vc.jit_bytes = (size_t)atoi(getenv("HV_JIT_MB")) << 20; /* debugging: a small region flushes often */
    hv_prof_register = hv_prof_register_thread;
    char err[256];
    if (share_folder) {
        char sock[256];
        snprintf(sock, sizeof sock, "%s.sock", share_folder);
        if (hv_share_start(share_folder, sock) == 0) hv_net_set_share_socket(sock);
    }
    if (hv_net_forward_listen(forward_addr) != 0 || hv_net_forward_set(forwards, nforwards) != 0) {
        fprintf(stderr, "hengevm: --forward-addr %s or a --forward port given twice\n", forward_addr);
        return 2;
    }
    if (vcodec) {
        static char sock[104];
        const char *tmp = getenv("TMPDIR");
        snprintf(sock, sizeof sock, "%s/hengevm-vcodec-%d.sock", tmp && *tmp ? tmp : "/tmp", (int)getpid());
        if (hv_vcodec_start(sock) == 0) {
            hv_net_set_vcodec_socket(sock);
            atexit(hv_vcodec_stop);
        } else {
            fprintf(stderr, "hengevm: vcodec: cannot listen on %s\n", sock);
        }
    }
    if (secrets_dir) {
        HvSecretStore store;
        if (hv_secrets_file_store(secrets_dir, &store) != 0 || hv_secrets_set_scope(machine_id) != 0) {
            fprintf(stderr, "hengevm: secrets: bad folder or machine id\n");
            return 1;
        }
        hv_secrets_set_store(&store);
        hv_secrets_set_locked(getenv("HV_SECRETS_LOCKED") != NULL); /* no Face ID here: unlocked unless asked */
    }
    if (hv_vm_create(&vc, err, sizeof err) != 0) {
        fprintf(stderr, "hengevm: %s\n", err);
        return 1;
    }
    if (dump_dtb) { /* the tree for this board, with no firmware or kernel placed */
        uint32_t size = 0;
        uint8_t *blob = hv_virt_build_fdt(hv_vm_virt(), append, 0, 0, &size);
        FILE *df = blob ? fopen(dump_dtb, "wb") : NULL;
        int ok = df && fwrite(blob, 1, size, df) == size;
        if (df && fclose(df) != 0) ok = 0;
        if (!ok) fprintf(stderr, "hengevm: cannot write %s\n", dump_dtb);
        free(blob);
        hv_vm_destroy();
        return ok ? 0 : 1;
    }
    boot_cfg = vc;
    boot_opts.trace = trace, boot_opts.watch = watch, boot_opts.watch_pa = watch_pa;
    boot_opts.stats = stats, boot_opts.profile = profile;
    boot_opts.chain_ok = !no_chain && brk == ~0ull; /* breakpoints need every block to come back */
    apply_machine_opts();
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    sigterm_as_power_key();
    sigtstp_as_suspend();
    hv_vm_console_set_output(console_out, NULL);
    tty_raw();
    run_args = (RunArgs){brk, brk_hits, dump_pa, dump_len, dump_path};
    /* The CPU runs on its own thread: the graphics framework needs the main queue. */
    pthread_t t;
    if (brk == ~0ull && !dump_path) {
        /* hv_vm_start runs CPU 0 and rebuilds the machine on a restart request. */
        if (hv_vm_start(1, virt_exit) != 0) {
            tty_restore();
            fprintf(stderr, "hengevm: cannot start the machine\n");
            return 1;
        }
        pthread_create(&t, NULL, stdin_thread, NULL);
    } else {
        hv_vm_start(0, NULL); /* the other CPUs and the kicker; CPU 0 is cpu_thread, for --break */
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 8u << 20);
        pthread_create(&t, &attr, cpu_thread, NULL);
        pthread_create(&t, NULL, stdin_thread, NULL);
    }
    if (profile) pthread_create(&t, NULL, profile_thread, NULL);
    if (getenv("HV_PROF_PCS")) prof_pcs = calloc(PROF_PCS, sizeof *prof_pcs);
    if (getenv("HV_PROF_ALL")) {
        pthread_t pr;
        pthread_create(&pr, NULL, prof_thread, NULL);
    }
    if (getenv("HV_INPUT_FILE")) {
        pthread_t in;
        pthread_create(&in, NULL, input_thread, NULL);
    }
    if (screenshot) {
        pthread_t st;
        pthread_create(&st, NULL, virt_shot_thread, NULL);
    }
    if (window) hv_virt_window_run(virt_w, virt_h);
    CFRunLoopRun();
    return 0;
}
