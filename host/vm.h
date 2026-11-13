#ifndef HENGEVM_VM_H
#define HENGEVM_VM_H

#include <stddef.h>
#include <stdint.h>

#include "disk.h"
#include "virt.h"
#include "vmapple.h"

/* The virtual Mac as a host app drives it: build it from files, run it, feed
   it input, stop it. The macOS command-line tool and the iOS app both use this;
   graphics are the host's own business (Mac: hv_pvg_attach before starting). */
enum { HV_BOARD_VMAPPLE = 0, HV_BOARD_VIRT = 1 };

/* A folder from the Files app (fs_server.h). The guest's helper mounts it at /media/henge/<name>. */
typedef struct HvVmFolder {
    const char *id, *name, *path; /* id: the app's, for the guest's changes; NULL is the name */
    int mode;                     /* HV_FS_RO, HV_FS_COW or HV_FS_RW */
} HvVmFolder;

typedef struct HvVmConfig {
    int board;                /* HV_BOARD_*; 0 is the virtual Mac */
    const char *rom;          /* vmapple: AVPBooter.vmapple2.bin. virt: u-boot.bin, or NULL (a kernel boot, or no firmware and no tree) */
    const char *disk, *aux;   /* the root disk and the auxiliary storage (vmapple only); virt: disk may be NULL */
    const char *kernel, *initrd, *cmdline; /* virt direct boot (rom NULL): an arm64 Image; initrd and cmdline may be NULL */
    uint64_t aux_offset;      /* where the aux image's data starts (16 KB) */
    uint64_t ecid, seed;      /* the machine identity the disk was installed with */
    uint64_t ram_mb;
    int ncpus;
    int log;                  /* m->log */
    int no_net, no_sound;
    int accel;                /* virt: the virtio GPU draws with virgl (needs a GFX=1 build) */
    int installer;            /* boot the ROM in DFU mode with the USB device port (installing macOS) */
    /* virt: the Files folders, at most HV_FS_MAX_FOLDERS, each at its own index (one with no name is left out).
       They replace the folder table (none clears it); with none the board has no virtio-fs device, as before.
       Changes while it runs go to hv_fs_folder_set and the others in fs_server.h. */
    const HvVmFolder *folders;
    int nfolders;
    /* JIT memory the host already has (iOS: granted by a debugger), or NULL to map it here. */
    void *jit_rx, *jit_rw;
    size_t jit_bytes;         /* 0: 768 MB */
} HvVmConfig;

/* What the host layer asks of a board's display device; d is HvBoardDevs.display_opaque. */
typedef struct HvDisplayOps {
    void (*set_layer)(void *d, void *layer);
    uint64_t (*frames)(void *d);
    int (*snapshot)(void *d, uint8_t *bgra, uint32_t width, uint32_t height);
    int (*pointer)(void *d, int *x, int *y);
    void (*set_mode)(void *d, uint32_t width, uint32_t height);
    void (*set_size_mm)(void *d, uint32_t width_mm, uint32_t height_mm); /* NULL: the guest is not told */
    void (*hide_cursor)(void *d, int hidden); /* NULL: the cursor is part of the guest's picture */
} HvDisplayOps;

/* The devices of any board, for the code that does not care which board it is. */
typedef struct HvBoardDevs {
    HvGic *gic;
    HvPl011 *uart;
    HvPl061 *gpio;
    HvXhci *usb;
    HvVirtioInput *keyboard, *mouse;
    HvVirtioInput *touch; /* virt only */
    HvVirtioNet *net;
    HvVirtioSnd *snd;
    HvVirtioBalloon *balloon;
    HvVirtioBlk *blk[2]; /* root, then aux (vmapple only) */
    uint8_t *ram;
    uint64_t ram_pa, ram_size;
    const HvDisplayOps *display; /* NULL: no display device */
    void *display_opaque;
} HvBoardDevs;

/* Returns 0, or -1 with a reason in err. */
int hv_vm_create(const HvVmConfig *cfg, char *err, size_t errlen);
/* After CPUs stop, detach backends and release the old machine. Borrowed iOS
   JIT memory stays owned by the app and can be attached to the next machine. */
void hv_vm_destroy(void);
HvMachine *hv_vm_machine(void);
HvVmapple *hv_vm_board(void); /* NULL when the board is not vmapple */
HvVirt *hv_vm_virt(void);     /* NULL unless a virt machine exists */
const HvBoardDevs *hv_vm_devs(void);
HvCpu *hv_vm_cpu(int index);
extern void (*hv_prof_register)(void); /* debugging: each thread that will run guest code calls this */
/* Frames go to this CAMetalLayer, drawn by the GPU, instead of hv_vm_boot_display. */
void hv_vm_set_display_layer(void *layer);
uint64_t hv_vm_gpu_frames(void);
/* Any thread: the screen size the guest is offered. Kept for later machines; a
   running one gets it through its display device. */
void hv_vm_set_display_mode(uint32_t width, uint32_t height);
/* Any thread: the scale the guest is told to draw at (its UI points are pixels / scale). */
void hv_vm_set_display_scale(double scale);
/* The mode and scale last set; 0 when no mode was ever set (outputs untouched). */
int hv_vm_display(uint32_t *w, uint32_t *h, double *scale);
/* The panel's size, for a guest that works out its pixel density from it (vmapple). 0 x 0: the default. */
void hv_vm_set_display_size_mm(uint32_t width_mm, uint32_t height_mm);
int hv_vm_ncpus(void);

/* The boot framebuffer iBoot hands the kernel (XNU's boot_args video info):
   the Apple logo and progress bar while booting or installing, before a GPU
   driver takes the display. Host pointer to the pixels (32-bit BGRA), or NULL
   until the kernel has its boot_args. */
typedef struct HvBootDisplay {
    const uint8_t *pixels;
    uint32_t width, height, stride;
} HvBootDisplay;
int hv_vm_boot_display(HvBootDisplay *d);

/* Extra device work on CPU 0 each tick (Mac graphics). Set before hv_vm_start. */
void hv_vm_set_poll(void (*poll)(void));

/* Runs CPU 0 on a new thread (unless the caller runs it: cpu0 = 0), the other
   CPUs and the 1 ms kicker. on_exit is called on CPU 0's thread when the
   machine stops (powered off, a fatal error, or hv_vm_stop), after the disks
   are flushed; reason is an HV_EXIT_* value. */
/* Returns -1 if a thread could not start; already-started workers are joined. */
int hv_vm_start(int cpu0, void (*on_exit)(int reason));
/* Call on a thread before it runs guest code (hv_vm_start's threads do): see vm.c. */
void hv_vm_prepare_cpu_thread(void);
/* That, and the scheduling class the guest's CPUs run at. */
void hv_vm_cpu_qos(void);
/* Run CPU 0 on the calling thread (what hv_vm_start does on its own thread); returns its exit reason. */
int hv_vm_run_cpu0(void);
/* Stop at the next block; the CPUs' threads end. */
void hv_vm_stop(void);
/* Not on a CPU's thread. Hold every CPU (and the sound output) until hv_vm_resume, which hides the time
   between from the guest's virtual counter: a guest frozen with the host's counter running (an iOS app
   suspended while the phone is awake) otherwise wakes to a jumped clock, and Linux to RCU stalls.
   0 once held, or -1 if no machine runs or a CPU did not stop within 2 s. A stop ends a pause. */
int hv_vm_pause(void);
/* Returns the seconds hidden from the guest, 0 if it was not paused. */
double hv_vm_resume(void);
int hv_vm_paused(void);
/* A pause also stops the Metal presenter, after the CPUs. With graphics acceleration it first waits up to 1.5 s for the
   renderer to finish what it holds (logged once if it does not): the iOS app may commit no Metal work in the background.
   Resume starts the presenter again. For checks: frames the presenter has drawn and requests the renderer has run;
   returns 1 while the GPU is held, 0 when it runs, -1 without a GPU. */
int hv_vm_gpu_counts(uint64_t *frames, uint64_t *requests);
/* The iOS app in the background (1) or not (0). Pauses now, except a machine without graphics acceleration whose guest
   plays sound: sound keeps the app running, so that one pauses as soon as the sound stops. An accelerated machine always
   pauses, so its sound stops in the background: no guest GPU work may run there. 0 resumes. Not on a CPU's thread. */
void hv_vm_set_background(int on);
/* That policy alone. */
int hv_vm_background_pauses(int accelerated, int sound_playing);
void hv_vm_flush_disks(void);
const char *hv_vm_reason_name(int reason);

/* Input from the host UI, any thread. Keys are Linux input codes (KEY_A = 30). */
void hv_vm_key(uint16_t code, int down);
void hv_vm_key_hid(uint8_t usage, int down); /* HID keyboard usage, which is what iOS reports for a hardware keyboard */
void hv_vm_mouse_move(int dx, int dy);
void hv_vm_mouse_button(int button, int down); /* 0 left, 1 right, 2 middle */
void hv_vm_mouse_wheel(int dy);
void hv_vm_mouse_hwheel(int dx);
/* The virt board's power key: GPIO pin 3 high for 100 ms. Any thread; no effect before a machine exists. */
int hv_vm_power_button(void); /* 1 if the key will be pressed */
/* The Magic Trackpad 2 on the USB bus: a finger on it. phase: 0 down, 1 move, 2 up; id a
   stable 1..15 per touch; x, y in sensor units (HV_TP_SENSOR_* in devices/xhci.h).
   ts_ms is the touch sample's own clock in ms (see hv_xhci_touch). */
void hv_vm_touch(int id, int phase, int x, int y, uint32_t ts_ms);
void hv_vm_touch_frame(uint32_t ts_ms); /* commit one frame with every finger that moved */
void hv_vm_touch_button(int down); /* the pad's full press (a click) */
/* The virt board's touchscreen (no effect on vmapple). slot 0 to 9; phase 0 down, 1 move, 2 up;
   x, y 0 to 32767 over the whole guest picture, clamped. Nothing reaches the guest until _frame. */
void hv_vm_screen_touch(int slot, int phase, int x, int y);
void hv_vm_screen_touch_frame(void);
void hv_vm_screen_touch_cancel(void); /* every contact lifts */
/* Touch mode: the guest's pointer image is not drawn from a screen touch until the mouse or the USB trackpad
   moves the pointer. Kept for later machines. Off draws it again. */
void hv_vm_set_touch_mode(int on);
int hv_vm_pointer_hidden(void);
/* Where the guest has its pointer, in display pixels. 0, or -1 before it has one. */
int hv_vm_pointer(int *x, int *y);
/* A small picture of the display, BGRA, width * height * 4 bytes. 0, or -1 before anything shows. */
int hv_vm_snapshot(uint8_t *bgra, int width, int height);

/* The device's status for a Linux guest (host/status.h). Any thread; kept for later machines.
   state: 0 unknown, 1 unplugged, 2 charging, 3 full (UIDeviceBatteryState); level 0-100 or -1. */
void hv_vm_set_battery(int level, int state);
void hv_vm_set_brightness(double level); /* 0 to 1 */
void hv_vm_set_volume(double level);     /* 0 to 1 */
int hv_vm_set_timezone(const char *name); /* -1: not a zone name */
void hv_vm_status_touch(void);           /* the wall clock changed */
/* What the guest asked for with its own sliders: 1 once per new request. */
int hv_vm_take_brightness_request(double *level);
int hv_vm_take_volume_request(double *level, int *muted);

/* The serial console (the PL011). Set the output before hv_vm_start; hv_vm_destroy clears it.
   NULL gives the UART's own output (stdout). */
void hv_vm_console_set_output(void (*out)(void *opaque, uint8_t c), void *opaque);
/* Any thread. Queued here; CPU 0's tick moves it into the UART as its FIFO has room. */
void hv_vm_console_input(const uint8_t *bytes, size_t n);

#endif
