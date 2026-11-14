/* The engine (HengeVM, ../host/vm.h) as the Swift side sees it. */
#ifndef HENGE_VM_H
#define HENGE_VM_H

#include <stddef.h>
#include <stdint.h>

#include "secrets.h"

/* Starts a Linux machine (the virt board): U-Boot's firmware file and a raw root disk, which may be NULL.
   On the app's JIT region, built with henge_ios_jit_prewarm. accel: the virtio GPU draws with virgl (the engine must be
   built with GFX=1). video, with accel: the guest's VA-API decodes on VideoToolbox. encode: the guest's video codecs
   (hvcodec) at 10.0.2.4:8470 and on /dev/hvcodec; henge_vm_set_background(1) ends their sessions. 0, or -1 with a
   reason in err. */
int henge_vm_boot_linux(const char *firmware, const char *disk, uint64_t ram_mb, int cpus, int accel, int video, int encode,
                        char *err, size_t errlen);
/* The serial console. Read drains what the guest wrote since the last call (a 256 KB ring; when it is full the
   oldest bytes go) and works after the machine stops. Write types bytes into it; ignored unless running. */
size_t henge_vm_console_read(uint8_t *buf, size_t cap);
void henge_vm_console_write(const uint8_t *buf, size_t n);
/* Presses the guest's power key (GPIO pin 3) for 100 ms: Debian shuts down cleanly. */
void henge_vm_power_button(void);
/* The app went to the background (1) or came back (0). The machine pauses, at once or when its sound stops, and
   the guest's clock skips the time the app was away (hv_vm_set_background). Going away also ends the guest's video
   codec sessions. Main thread; at most 2 s. */
void henge_vm_set_background(int on);
/* The machine is paused. */
int henge_vm_paused(void);
/* 0 not started, 1 running, 2 stopped, 3 starting/stopping. A guest is fully released before state 2. */
int henge_vm_state(void);
/* A new generation starts with each successful boot, even in the same view. */
uint64_t henge_vm_generation(void);
int henge_vm_can_start(void);
/* Human-readable terminal reason, once state is 2. */
const char *henge_vm_exit_reason(void);
/* Terminal outcome after state == 2. Generic HALT alone does not prove a
   guest shutdown (it also covers reset and host stop). */
enum HengeVmOutcome {
    HENGE_VM_OUTCOME_ERROR, HENGE_VM_OUTCOME_SHUTDOWN, HENGE_VM_OUTCOME_RESTART,
    HENGE_VM_OUTCOME_HOST_STOP
};
int henge_vm_exit_outcome(void);
void henge_vm_stop(void);
/* Testing: sets a translation knob (core/machine.h) in the running machine; nonzero if it exists. */
int henge_vm_knob(const char *name, int value);
/* The memory balloon (only with HV_BALLOON set before boot): asks the guest to hand over target_mb (when >= 0)
   and returns how many MB it has handed over, or -1 without a balloon. */
long henge_vm_balloon(long target_mb);

/* Progress, for the session screen. */
uint64_t henge_vm_blocks(void);            /* blocks the CPUs entered */
uint64_t henge_vm_net_frames(int sent);    /* Ethernet frames out (sent = 1) and in */
uint64_t henge_vm_dns(int which);          /* guest DNS queries answered through iOS's resolver (0), handed to libslirp (1), unanswered in time (2) */
int henge_vm_cpus_on(void);                /* CPUs the guest has started */
int henge_vm_guest_el0(void);              /* any CPU running user code right now */

/* Input: Linux key codes, relative pointer, buttons 0 left 1 right 2 middle. */
/* The shared folder and clipboard (host/share.c). henge_vm_share goes before henge_vm_boot_linux.
   henge_share_take_clipboard returns what the guest copied, once: a malloc'd string, or NULL. */
void henge_vm_share(const char *folder, const char *socket_path);
void henge_share_set_clipboard(const char *text);
char *henge_share_take_clipboard(void);
long henge_share_helper_seen(void);
/* 1 when the focused program in a Linux desktop wants text; *seq changes with each request from the guest. */
int henge_share_keyboard_wanted(unsigned long *seq);
/* The part of the guest's picture that the keyboard covers, from the bottom: 0 (down) to 1. */
void henge_share_set_keyboard_height(double fraction);

/* A Linux machine's folders from Files (host/fs_server.h). The table is kept for the next henge_vm_boot_linux and
   changes a running machine at once; a machine that booted with none has no device for them, so one added then
   shows after a restart (henge_vm_folders_device). index 0 to 7; id the app's, for the guest's Copy-on-write
   changes; mode 0 Read-only, 1 Copy-on-write, 2 Read-write; kind 0 local, 1 a File Provider (iCloud Drive or
   another app's), which the hook sees. Any thread. 0, or -1 with errno (EINVAL: a bad index, name or mode, or a
   name another index has; else what the open of path gave). */
int henge_vm_folder_set(int index, const char *id, const char *name, const char *path, int mode, int kind);
void henge_vm_folder_clear(int index);
void henge_vm_folders_clear(void);
/* Offline: everything inside gives EIO in the guest, as a dropped network share does. */
int henge_vm_folder_online(int index, int online);
/* The original changed under a Copy-on-write folder: the guest remounts it when nothing has it open. */
int henge_vm_folder_touch(int index);
/* 1 when the running machine has the folders' device. */
int henge_vm_folders_device(void);
/* Export Changes (1) and Discard Changes (2) of a Copy-on-write folder, done by the guest's helper; 0 takes the
   ask back. The ask's number, or -1 with errno (EINVAL: not a Copy-on-write folder). */
long henge_vm_folder_ask(int index, int what);
/* 1 with the answer (*text malloc'd: for an export, its folder below the Shared folder, a newline, and what it
   has; else why not), 0 while it waits, -1 when the ask is gone. */
int henge_vm_folder_answered(int index, long ask, int *ok, char **text);
/* event 0: a file in a File Provider folder is about to open (the result: 0 or a Darwin errno); 1: a written file
   closed. On a device worker thread; it may wait. */
typedef int (*HengeFolderHook)(void *user, int index, const char *path, int event);
void henge_vm_folders_hook(HengeFolderHook hook, void *user);

/* A Linux machine's TCP forwards from the phone into the guest (host/net_forward.h): rule i is phone_ports[i] to
   guest_ports[i]. Each listens on every local network address (Wi-Fi, Ethernet, the hotspot, VPNs) and on 127.0.0.1,
   never on cellular, and follows the addresses as they change. Kept for the next henge_vm_boot_linux and applied to a
   running machine at once. Any thread. 0, or -1 with errno EINVAL (a
   phone port below 1024, a port 0, a phone port twice, more than 16). */
int henge_vm_forwards_set(const uint16_t *phone_ports, const uint16_t *guest_ports, int n);
/* The phone's network changed (NWPathMonitor): look at its addresses now, not at the next 5 s poll. Any thread. */
void henge_vm_forwards_refresh(void);
/* The running machine's rule for phone_port: how many addresses it listens on, written to addrs as "IP IFNAME\n"
   lines (cap bytes, NUL-terminated), and in *err the errno of an address that failed (EADDRINUSE: the port is taken,
   on that address or on all of them by another app) or 0. -1 when no machine runs or its network has not taken
   that rule yet. */
int henge_vm_forward_state(uint16_t phone_port, char *addrs, size_t cap, int *err);

/* The phone's status for a Linux guest (host/status.h). Any time, before boot too; kept for the next machine.
   state: UIDeviceBatteryState (0 unknown, 1 unplugged, 2 charging, 3 full); level 0-100, or -1. */
void henge_vm_set_battery(int level, int state);
void henge_vm_set_brightness(double level); /* 0 to 1 */
void henge_vm_set_volume(double level);     /* 0 to 1 */
int henge_vm_set_timezone(const char *name); /* -1: not a zone name */
void henge_vm_status_touch(void);           /* the wall clock changed */
/* The guest's own brightness and volume sliders: 1 once per new request, 0 when none or no machine runs. */
int henge_vm_take_brightness_request(double *level);
int henge_vm_take_volume_request(double *level, int *muted);

/* A Linux machine's wallet (host/secrets.h): the store (KeychainStore.swift) and the machine it is for, or NULL for
   none. Locked until the session's Face ID check passes. Any time. */
void henge_vm_secrets(const HvSecretStore *store, const char *machine_id);
void henge_vm_secrets_set_locked(int locked);

/* The size the guest is told its screen is. Before henge_vm_boot_linux. */
void henge_vm_set_display(uint32_t width, uint32_t height);
/* The scale the guest draws at: its UI points are pixels / scale. */
void henge_vm_set_display_scale(double scale);
void henge_vm_key(uint16_t code, int down);
void henge_vm_key_hid(uint8_t usage, int down); /* a hardware keyboard: iOS gives each key's HID usage */
void henge_vm_mouse_move(int dx, int dy);
void henge_vm_mouse_button(int button, int down);
/* Wheel units: dy > 0 up, dx > 0 right. */
void henge_vm_mouse_scroll(int dx, int dy);
/* The Magic Trackpad 2 the guest sees on its USB bus: a finger on it. phase: 0 down, 1 move, 2 up;
   finger a stable 1..15 per touch; x, y sensor units 0..8134, 0..5206. ts_ms is the touch
   sample's own clock in ms, so the guest computes finger speed from real sample timing. */
void henge_vm_touch(int finger, int phase, int x, int y, uint32_t ts_ms);
void henge_vm_touch_frame(uint32_t ts_ms); /* commit one frame with every finger that moved */
void henge_vm_touch_button(int down); /* the pad's full press (a click) */
/* A Linux machine's touchscreen: slot 0..9; phase 0 down, 1 move, 2 up; x, y 0..32767 over the whole
   guest picture. Nothing reaches the guest until _frame. cancel lifts every contact. */
void henge_vm_screen_touch(int slot, int phase, int x, int y);
void henge_vm_screen_touch_frame(void);
void henge_vm_screen_touch_cancel(void);
/* Touch mode: no guest pointer image from a screen touch until the mouse or trackpad moves it. Any time. */
void henge_vm_set_touch_mode(int on);
/* Where the guest has its pointer, in display pixels. 0, or -1 before it has one. */
int henge_vm_pointer(int *x, int *y);
/* A small picture of the display, BGRA, width * height * 4 bytes. 0, or -1 before anything shows. */
int henge_vm_snapshot(uint8_t *bgra, int width, int height);

/// Where the guest's GPU frames go: a CAMetalLayer. Keep it alive while the machine runs.
void henge_vm_set_display_layer(void *layer);
/// How many frames have gone to it.
uint64_t henge_vm_gpu_frames(void);
/* The largest single mapping the address space takes right now, in MB (the
   increased virtual addressing entitlement raises it). */
uint64_t henge_largest_reservation_gb(void); /* measuring: the biggest PROT_NONE reservation, in GB */
uint64_t henge_largest_mapping_mb(void);
/* Bytes this process may still allocate before jetsam (os_proc_available_memory). */
size_t henge_available_memory(void);

#endif
