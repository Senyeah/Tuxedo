#include "share.h"
#include "net_slirp.h"
#include <sys/mman.h>
#include "tux-vm.h"

#include <os/proc.h>
#include <TargetConditionals.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "dispatch.h"
#include <dispatch/dispatch.h>
#include "tux-ios-jit.h"
#include "net_slirp.h"
#include "dns_proxy.h"
#include "vm.h"
#include "fs_server.h"
#include "vcodec.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

TUX_EXPORT TuxDualMapping *tux_ios_jit_get_mapping(void);

static _Atomic int state;
static int exit_reason, exit_outcome;
static pthread_rwlock_t api_lock = PTHREAD_RWLOCK_INITIALIZER;
static _Atomic uint64_t generation;
static uint64_t stopped_blocks, stopped_tx, stopped_rx;
static const char *exit_description(void);

static void on_exit(int reason) {
    pthread_rwlock_wrlock(&api_lock);
    state = 3;
    exit_reason = reason;
    int halt = hv_vm_cpu(0)->halted;
    exit_outcome = TUX_VM_OUTCOME_ERROR;
    if (reason == HV_EXIT_HALT) switch (halt) {
    case HV_HALT_SHUTDOWN: exit_outcome = TUX_VM_OUTCOME_SHUTDOWN; break;
    case HV_HALT_RESET: exit_outcome = TUX_VM_OUTCOME_RESTART; break;
    case HV_HALT_HOST: exit_outcome = TUX_VM_OUTCOME_HOST_STOP; break;
    }
    stopped_blocks = hv_vm_machine()->stats.blocks;
    stopped_tx = hv_net_tx_frames;
    stopped_rx = hv_net_rx_frames;
    hv_vm_destroy();
    state = 2;
    fprintf(stderr, "henge: the machine stopped (%s, halt reason %d); CPU threads ended, disks flushed, machine released\n",
            exit_description(), halt);
    pthread_rwlock_unlock(&api_lock);
}

/* Holds api_lock through creation so UI snapshots cannot see a partial board. */
static int begin_start(char *err, size_t errlen) {
    pthread_rwlock_wrlock(&api_lock);
    if (state != 0 && state != 2) {
        snprintf(err, errlen, "The previous machine is still running or finishing its shutdown.");
        pthread_rwlock_unlock(&api_lock);
        return -1;
    }
    state = 3;
    return 0;
}

static int failed_start(void) {
    hv_vm_destroy();
    state = 0;
    pthread_rwlock_unlock(&api_lock);
    return -1;
}

static int started(char *err, size_t errlen) {
    stopped_blocks = stopped_tx = stopped_rx = 0;
    exit_reason = exit_outcome = 0;
    state = 1;
    if (hv_vm_start(1, on_exit) != 0) {
        snprintf(err, errlen, "There are not enough resources to start the machine's CPU threads.");
        return failed_start();
    }
    atomic_fetch_add(&generation, 1);
    pthread_rwlock_unlock(&api_lock);
    return 0;
}

/* Serial console output: the guest's bytes wait here until the UI drains them. */
#define CONSOLE_RING_BYTES (256 << 10)
static pthread_mutex_t console_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint8_t console_ring[CONSOLE_RING_BYTES];
static size_t console_head, console_len;

static void console_clear(void) {
    pthread_mutex_lock(&console_mutex);
    console_head = console_len = 0;
    pthread_mutex_unlock(&console_mutex);
}
/* Runs on a CPU thread under the device lock; the ring lock is a leaf. */
static void console_out(void *opaque, uint8_t c) {
    (void)opaque;
    pthread_mutex_lock(&console_mutex);
    if (console_len == CONSOLE_RING_BYTES) { /* full: drop the oldest byte */
        console_head = (console_head + 1) % CONSOLE_RING_BYTES;
        console_len--;
    }
    console_ring[(console_head + console_len++) % CONSOLE_RING_BYTES] = c;
    pthread_mutex_unlock(&console_mutex);
}

/* The folders for the next boot, by index; the running machine's table is fs_server's. */
static pthread_mutex_t folders_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int used, mode, kind, online;
    char id[HV_FS_NAME_MAX + 1], name[HV_FS_NAME_MAX + 1], path[1024];
} folder_slots[HV_FS_MAX_FOLDERS];

int tux_vm_folder_set(int index, const char *id, const char *name, const char *path, int mode, int kind) {
    if (index < 0 || index >= HV_FS_MAX_FOLDERS || !path || strlen(path) >= sizeof folder_slots[0].path) {
        errno = EINVAL;
        return -1;
    }
    pthread_mutex_lock(&folders_mu);
    int rc = hv_fs_folder_set(index, id, name, path, mode); /* it checks the name, the mode and the path */
    if (rc == 0) {
        hv_fs_folder_kind(index, kind == 1 ? HV_FS_PROVIDER : HV_FS_LOCAL);
        int online = folder_slots[index].used ? folder_slots[index].online : 1; /* only tux_vm_folder_online changes it */
        folder_slots[index].used = 1;
        folder_slots[index].mode = mode;
        folder_slots[index].kind = kind;
        folder_slots[index].online = online;
        snprintf(folder_slots[index].id, sizeof folder_slots[index].id, "%s", id ? id : name);
        snprintf(folder_slots[index].name, sizeof folder_slots[index].name, "%s", name);
        snprintf(folder_slots[index].path, sizeof folder_slots[index].path, "%s", path);
        hv_fs_folder_online(index, online);
    }
    pthread_mutex_unlock(&folders_mu);
    return rc;
}

void tux_vm_folder_clear(int index) {
    if (index < 0 || index >= HV_FS_MAX_FOLDERS) return;
    pthread_mutex_lock(&folders_mu);
    folder_slots[index].used = 0;
    hv_fs_folder_clear(index);
    pthread_mutex_unlock(&folders_mu);
}

void tux_vm_folders_clear(void) {
    for (int i = 0; i < HV_FS_MAX_FOLDERS; i++) tux_vm_folder_clear(i);
}

int tux_vm_folder_online(int index, int online) {
    if (index < 0 || index >= HV_FS_MAX_FOLDERS) return -1;
    pthread_mutex_lock(&folders_mu);
    int rc = hv_fs_folder_online(index, online);
    if (rc == 0) folder_slots[index].online = !!online;
    pthread_mutex_unlock(&folders_mu);
    return rc;
}

int tux_vm_folder_touch(int index) { return hv_fs_folder_touch(index); }
long tux_vm_folder_ask(int index, int what) { return hv_fs_folder_ask(index, what); }
int tux_vm_folder_answered(int index, long ask, int *ok, char **text) { return hv_fs_folder_answered(index, ask, ok, text); }
void tux_vm_folders_hook(TuxFolderHook hook, void *user) { hv_fs_set_hook(hook, user); }

int tux_vm_folders_device(void) {
    pthread_rwlock_rdlock(&api_lock);
    HvVirt *v = state == 1 ? hv_vm_virt() : NULL;
    int on = v && v->fs;
    pthread_rwlock_unlock(&api_lock);
    return on;
}

/* Started once, as share.c's: after a stop, the old listener could accept on a reused fd. Under api_lock. */
static const char *vcodec_socket(void) {
    static int rc = -2;
    static char path[104]; /* sun_path */
    if (rc == -2) {
        char dir[PATH_MAX] = "";
        const char *tmp = getenv("TMPDIR");
        if (tmp && *tmp) snprintf(dir, sizeof dir, "%s", tmp);
        else confstr(_CS_DARWIN_USER_TEMP_DIR, dir, sizeof dir);
        size_t n = strlen(dir);
        int w = snprintf(path, sizeof path, "%s%sv.sock", dir, n && dir[n - 1] == '/' ? "" : "/");
        rc = w > 0 && (size_t)w < sizeof path ? hv_vcodec_start(path) : -1;
        if (rc) fprintf(stderr, "henge: video encode: cannot listen on %s; /dev/hvcodec only\n", path);
    }
    return rc == 0 ? path : NULL;
}

int tux_vm_boot_linux(const char *firmware, const char *disk, uint64_t ram_mb, int cpus, int accel, int video, int encode,
                        char *err, size_t errlen) {
    { extern void hv_prof_ios_start(void); hv_prof_ios_start(); }
    if (!firmware) {
        snprintf(err, errlen, "A Linux machine needs its firmware (u-boot.bin).");
        return -1;
    }
    if (begin_start(err, errlen)) return -1;
    TuxDualMapping *jit = tux_ios_jit_get_mapping();
    if (!jit || !jit->rw_addr) {
        snprintf(err, errlen, "Henge has no JIT region. Turn on JIT first.");
        return failed_start();
    }
    HvVmFolder folders[HV_FS_MAX_FOLDERS] = {{0}};
    int nfolders = 0, used = 0;
    pthread_mutex_lock(&folders_mu); /* held to the end of the boot: the table it makes is this one */
    for (int i = 0; i < HV_FS_MAX_FOLDERS; i++) {
        if (!folder_slots[i].used) continue; /* a hole: indexes stay the app's */
        folders[i] = (HvVmFolder){folder_slots[i].id, folder_slots[i].name, folder_slots[i].path, folder_slots[i].mode};
        nfolders = i + 1;
        used++;
    }
    HvVmConfig c = {.rom = firmware, .disk = disk, .ram_mb = ram_mb, .ncpus = cpus, .log = 1, .accel = accel,
                    .video = accel && video, .folders = folders, .nfolders = nfolders,
                    .codec_ops = encode ? hv_vcodec_device_ops() : NULL,
                    .jit_rx = jit->rx_addr, .jit_rw = jit->rw_addr, .jit_bytes = jit->size};
    hv_net_set_vcodec_socket(encode ? vcodec_socket() : NULL); /* 10.0.2.4:8470 */
    fprintf(stderr, "henge: booting Linux with %d CPUs, %llu MB RAM, a %zu MB JIT region%s%s%s\n", cpus,
            (unsigned long long)ram_mb, jit->size >> 20, accel ? ", graphics acceleration" : "", accel && video ? ", video decode" : "",
            encode ? ", video encode" : "");
    console_clear();
    hv_vm_console_set_output(console_out, NULL); /* destroy clears it, so every boot sets it */
    if (hv_vm_create(&c, err, errlen) != 0) {
        pthread_mutex_unlock(&folders_mu);
        return failed_start();
    }
    for (int i = 0; i < nfolders; i++) { /* the board made the table from the list: what the list does not carry */
        if (!folder_slots[i].used) continue;
        hv_fs_folder_kind(i, folder_slots[i].kind == 1 ? HV_FS_PROVIDER : HV_FS_LOCAL);
        if (!folder_slots[i].online) hv_fs_folder_online(i, 0);
    }
    pthread_mutex_unlock(&folders_mu);
    if (used) fprintf(stderr, "henge: %d folder%s from Files\n", used, used == 1 ? "" : "s");
    return started(err, errlen);
}

int tux_vm_state(void) { return state; }
uint64_t tux_vm_generation(void) { return atomic_load(&generation); }
int tux_vm_can_start(void) {
    pthread_rwlock_rdlock(&api_lock);
    int ready = state == 0 || state == 2;
    pthread_rwlock_unlock(&api_lock);
    return ready;
}
int tux_vm_exit_outcome(void) {
    pthread_rwlock_rdlock(&api_lock);
    int outcome = state == 2 ? exit_outcome : TUX_VM_OUTCOME_ERROR;
    pthread_rwlock_unlock(&api_lock);
    return outcome;
}
static const char *exit_description(void) {
    switch (exit_outcome) {
    case TUX_VM_OUTCOME_SHUTDOWN: return "guest shut down";
    case TUX_VM_OUTCOME_RESTART: return "guest requested a restart";
    case TUX_VM_OUTCOME_HOST_STOP: return "stopped by host";
    default: return hv_vm_reason_name(exit_reason);
    }
}
const char *tux_vm_exit_reason(void) {
    pthread_rwlock_rdlock(&api_lock);
    const char *reason = state == 2 ? exit_description() : "running";
    pthread_rwlock_unlock(&api_lock);
    return reason;
}
static int lock_running(void) {
    if (state != 1) return 0;
    pthread_rwlock_rdlock(&api_lock);
    if (state == 1) return 1;
    pthread_rwlock_unlock(&api_lock);
    return 0;
}
void tux_vm_stop(void) {
    if (!lock_running()) return;
    hv_vm_stop();
    state = 3;
    pthread_rwlock_unlock(&api_lock);
}

long tux_vm_balloon(long target_mb) {
    if (!lock_running()) return -1;
    HvVirtioBalloon *balloon = hv_vm_devs()->balloon;
    long actual = -1;
    if (balloon) {
        if (target_mb >= 0) hv_virtio_balloon_set_target(balloon, (uint64_t)target_mb << 20);
        actual = (long)(hv_virtio_balloon_actual(balloon) >> 20);
    }
    pthread_rwlock_unlock(&api_lock);
    return actual;
}

/* Reads need no api_lock: the ring outlives the machine, so the last bytes before a stop stay readable. */
size_t tux_vm_console_read(uint8_t *buf, size_t cap) {
    pthread_mutex_lock(&console_mutex);
    size_t n = console_len < cap ? console_len : cap;
    for (size_t i = 0; i < n; i++) buf[i] = console_ring[(console_head + i) % CONSOLE_RING_BYTES];
    console_head = (console_head + n) % CONSOLE_RING_BYTES;
    console_len -= n;
    pthread_mutex_unlock(&console_mutex);
    return n;
}
void tux_vm_console_write(const uint8_t *buf, size_t n) {
    if (!lock_running()) return;
    hv_vm_console_input(buf, n);
    pthread_rwlock_unlock(&api_lock);
}

/* The power key is GPIO pin 3 (VIRT_GPIO_POWER, QEMU's pin); a press is high for 100 ms. */
static int power_pin(int level, uint64_t gen) {
    if (!lock_running()) return 0;
    HvPl061 *gpio = hv_vm_devs()->gpio;
    int done = gpio && gen == atomic_load(&generation); /* the release must not reach a newer machine */
    if (done) {
        hv_dev_lock(hv_vm_machine());
        hv_pl061_set_input(gpio, 3, level);
        hv_dev_unlock(hv_vm_machine());
    }
    pthread_rwlock_unlock(&api_lock);
    return done;
}
void tux_vm_power_button(void) {
    if (lock_running()) { /* virt: the host's key, which hv_vm_destroy waits for */
        int done = hv_vm_power_button();
        pthread_rwlock_unlock(&api_lock);
        if (done) return;
    }
    uint64_t gen = atomic_load(&generation);
    if (!power_pin(1, gen)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                   ^{ power_pin(0, gen); });
}

void tux_vm_set_background(int on) {
    if (!on) { /* also when the machine stopped meanwhile: the flags must not pause the next one */
        hv_vcodec_set_background(0);
        hv_vm_set_background(0);
        return;
    }
    hv_vcodec_set_background(1); /* decision 7, before the pause: the guest gets HV_VC_E_LOST, also for a new session */
    if (!lock_running()) return;
    hv_vm_set_background(1);
    pthread_rwlock_unlock(&api_lock);
}
int tux_vm_paused(void) { return hv_vm_paused(); }

int tux_vm_forwards_set(const uint16_t *phone_ports, const uint16_t *guest_ports, int n) {
    HvFwdRule rules[HV_FWD_MAX_RULES];
    if (n < 0 || n > HV_FWD_MAX_RULES || (n && (!phone_ports || !guest_ports))) {
        errno = EINVAL;
        return -1;
    }
    for (int i = 0; i < n; i++) rules[i] = (HvFwdRule){phone_ports[i], guest_ports[i]};
    int rc = hv_fwd_check(rules, n, 1024); /* iOS binds nothing lower */
    if (rc) {
        errno = rc;
        return -1;
    }
    return hv_net_forward_set(rules, n);
}

void tux_vm_forwards_refresh(void) { hv_net_forward_refresh(); }

int tux_vm_forward_state(uint16_t phone_port, char *addrs, size_t cap, int *err) {
    HvFwdAddr a[HV_FWD_MAX_ADDRS];
    int e = 0;
    int n = hv_net_forward_state(phone_port, a, HV_FWD_MAX_ADDRS, &e);
    if (err) *err = e;
    if (addrs && cap) {
        size_t used = 0;
        addrs[0] = 0;
        for (int i = 0; i < n; i++) {
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &a[i].ip, ip, sizeof ip);
            int w = snprintf(addrs + used, cap - used, "%s %s\n", ip, a[i].ifname);
            if (w < 0 || (size_t)w >= cap - used) {
                addrs[used] = 0; /* whole lines only */
                break;
            }
            used += (size_t)w;
        }
    }
    return n;
}

uint64_t tux_vm_dns(int which) {
    uint64_t n[3];
    hv_dns_proxy_stats(&n[0], &n[1], &n[2]);
    return which >= 0 && which < 3 ? n[which] : 0;
}

int tux_vm_knob(const char *name, int value) {
    if (!lock_running()) return 0;
    int result = hv_knob_set(hv_vm_machine(), name, value);
    pthread_rwlock_unlock(&api_lock);
    return result;
}
uint64_t tux_vm_blocks(void) {
    pthread_rwlock_rdlock(&api_lock);
    uint64_t result = state == 1 ? hv_vm_machine()->stats.blocks : stopped_blocks;
    pthread_rwlock_unlock(&api_lock);
    return result;
}
uint64_t tux_vm_net_frames(int sent) {
    pthread_rwlock_rdlock(&api_lock);
    uint64_t result = state == 1 ? (sent ? hv_net_tx_frames : hv_net_rx_frames) : (sent ? stopped_tx : stopped_rx);
    pthread_rwlock_unlock(&api_lock);
    return result;
}
int tux_vm_cpus_on(void) {
    if (!lock_running()) return 0;
    int n = 0;
    for (int i = 0; i < hv_vm_ncpus(); i++)
        if (!hv_vm_cpu(i)->off && !hv_vm_cpu(i)->halted) n++;
    pthread_rwlock_unlock(&api_lock);
    return n;
}
int tux_vm_guest_el0(void) {
    if (!lock_running()) return 0;
    int found = 0;
    for (int i = 0; i < hv_vm_ncpus(); i++)
        if (!hv_vm_cpu(i)->off && hv_vm_cpu(i)->el == 0) { found = 1; break; }
    pthread_rwlock_unlock(&api_lock);
    return found;
}

void tux_vm_share(const char *folder, const char *socket_path) {
    if (hv_share_start(folder, socket_path) == 0) hv_net_set_share_socket(socket_path);
}
void tux_share_set_clipboard(const char *text) { hv_share_set_clipboard(text); }
char *tux_share_take_clipboard(void) { return hv_share_take_clipboard(); }
long tux_share_helper_seen(void) { return hv_share_helper_seen(); }
int tux_share_keyboard_wanted(unsigned long *seq) { return hv_share_keyboard_wanted(seq); }
void tux_share_set_keyboard_height(double fraction) { hv_share_set_keyboard_height(fraction); }

/* vm.c keeps the mode and gives it to the board's display once one exists. */
void tux_vm_set_battery(int level, int state) { hv_vm_set_battery(level, state); }
void tux_vm_set_brightness(double level) { hv_vm_set_brightness(level); }
void tux_vm_set_volume(double level) { hv_vm_set_volume(level); }
int tux_vm_set_timezone(const char *name) { return hv_vm_set_timezone(name); }
void tux_vm_status_touch(void) { hv_vm_status_touch(); }

void tux_vm_secrets(const HvSecretStore *store, const char *machine_id) {
    hv_secrets_set_store(store);
    hv_secrets_set_scope(machine_id);
}
void tux_vm_secrets_set_locked(int locked) { hv_secrets_set_locked(locked); }

int tux_vm_take_brightness_request(double *level) {
    if (!lock_running()) return 0;
    int got = hv_vm_take_brightness_request(level);
    pthread_rwlock_unlock(&api_lock);
    return got;
}

int tux_vm_take_volume_request(double *level, int *muted) {
    if (!lock_running()) return 0;
    int got = hv_vm_take_volume_request(level, muted);
    pthread_rwlock_unlock(&api_lock);
    return got;
}

void tux_vm_set_display(uint32_t width, uint32_t height) { hv_vm_set_display_mode(width, height); }
void tux_vm_set_display_scale(double scale) { hv_vm_set_display_scale(scale); }

void tux_vm_key(uint16_t code, int down) {
    if (!lock_running()) return;
    hv_vm_key(code, down);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_key_hid(uint8_t usage, int down) {
    if (!lock_running()) return;
    hv_vm_key_hid(usage, down);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_mouse_move(int dx, int dy) {
    if (!lock_running()) return;
    hv_vm_mouse_move(dx, dy);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_mouse_button(int button, int down) {
    if (!lock_running()) return;
    hv_vm_mouse_button(button, down);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_mouse_scroll(int dx, int dy) {
    if (!lock_running()) return;
    if (dy) hv_vm_mouse_wheel(dy);
    if (dx) hv_vm_mouse_hwheel(dx);
    pthread_rwlock_unlock(&api_lock);
}
int tux_vm_pointer(int *x, int *y) {
    if (!lock_running()) return -1;
    int result = hv_vm_pointer(x, y);
    pthread_rwlock_unlock(&api_lock);
    return result;
}
int tux_vm_snapshot(uint8_t *bgra, int width, int height) {
    if (!lock_running()) return -1;
    int result = hv_vm_snapshot(bgra, width, height);
    pthread_rwlock_unlock(&api_lock);
    return result;
}
void tux_vm_touch(int finger, int phase, int x, int y, uint32_t ts_ms) {
    if (!lock_running()) return;
    hv_vm_touch(finger, phase, x, y, ts_ms);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_touch_frame(uint32_t ts_ms) {
    if (!lock_running()) return;
    hv_vm_touch_frame(ts_ms);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_touch_button(int down) {
    if (!lock_running()) return;
    hv_vm_touch_button(down);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_screen_touch(int slot, int phase, int x, int y) {
    if (!lock_running()) return;
    hv_vm_screen_touch(slot, phase, x, y);
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_screen_touch_frame(void) {
    if (!lock_running()) return;
    hv_vm_screen_touch_frame();
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_screen_touch_cancel(void) {
    if (!lock_running()) return;
    hv_vm_screen_touch_cancel();
    pthread_rwlock_unlock(&api_lock);
}
void tux_vm_set_touch_mode(int on) { hv_vm_set_touch_mode(on); } /* kept for the next machine */
void tux_vm_set_display_layer(void *layer) {
    /* vm.c serializes this with unpublishing the old display before free.
       Main-thread layer detachment need not wait for disk/GPU teardown. */
    hv_vm_set_display_layer(layer);
}
uint64_t tux_vm_gpu_frames(void) {
    if (!lock_running()) return 0;
    uint64_t result = hv_vm_gpu_frames();
    pthread_rwlock_unlock(&api_lock);
    return result;
}
#if TARGET_OS_IPHONE
size_t tux_available_memory(void) { return os_proc_available_memory(); }
#else
size_t tux_available_memory(void) { return 0; } /* macOS has no per-app limit (the lifecycle test links this file) */
#endif

/* The most address space this app can reserve in one piece, in GB (measuring, for a fastmem window): PROT_NONE
   reservations cost no memory, and each is given back at once. */
uint64_t tux_largest_reservation_gb(void) {
    for (uint64_t gb = 4096; gb >= 4; gb /= 2) {
        void *p = mmap(NULL, gb << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
            munmap(p, gb << 30);
            return gb;
        }
    }
    return 0;
}

uint64_t tux_largest_mapping_mb(void) {
    for (uint64_t mb = 16896; mb >= 1024; mb -= 512) { /* 16 GB, the most a machine can ask for, plus what the caller keeps back */
        void *p = mmap(NULL, mb << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
            munmap(p, mb << 20);
            return mb;
        }
    }
    return 0;
}
