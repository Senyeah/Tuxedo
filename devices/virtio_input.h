/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_VIRTIO_INPUT_H
#define TUXVM_VIRTIO_INPUT_H

#include <pthread.h>

#include "virtio.h"

/* virtio-input (device type 18), Linux input event codes, as Linux's
   virtio_input driver expects. Events come from the host UI on any thread
   (hv_virtio_input_send) and reach the guest from the CPU thread
   (hv_virtio_input_poll, from the board's tick). The touch kind (virt board
   only) is a touchscreen with multitouch protocol B, as QEMU's virtio-multitouch. */
enum { HV_VINPUT_KEYBOARD, HV_VINPUT_MOUSE, HV_VINPUT_TOUCH };

#define HV_EV_SYN 0
#define HV_EV_KEY 1
#define HV_EV_REL 2
#define HV_EV_ABS 3
#define HV_REL_X 0
#define HV_REL_Y 1
#define HV_REL_HWHEEL 6
#define HV_REL_WHEEL 8
#define HV_REL_WHEEL_HI_RES 0x0b
#define HV_REL_HWHEEL_HI_RES 0x0c
#define HV_BTN_LEFT 0x110
#define HV_BTN_RIGHT 0x111
#define HV_BTN_MIDDLE 0x112
#define HV_BTN_SIDE 0x113  /* back */
#define HV_BTN_EXTRA 0x114 /* forward */
#define HV_BTN_TOUCH 0x14a
#define HV_ABS_MT_SLOT 0x2f
#define HV_ABS_MT_POSITION_X 0x35
#define HV_ABS_MT_POSITION_Y 0x36
#define HV_ABS_MT_TRACKING_ID 0x39

#define HV_VINPUT_RING 4096

#define HV_TOUCH_SLOTS 10
#define HV_TOUCH_MAX 32767 /* each axis covers the whole scanout, in every mode */
#define HV_TOUCH_FRAMES 256

/* serial changes at each new contact: a lift that a replaced frame hid is still sent. */
typedef struct HvTouchState {
    uint8_t down[HV_TOUCH_SLOTS];
    uint16_t x[HV_TOUCH_SLOTS], y[HV_TOUCH_SLOTS];
    uint32_t serial[HV_TOUCH_SLOTS];
} HvTouchState;

typedef struct HvVirtioInput {
    HvVirtio vio;
    int kind;
    pthread_mutex_t mu;
    struct { uint16_t type, code; uint32_t value; } ring[HV_VINPUT_RING];
    uint32_t head, tail; /* under mu */
    int driver_up;       /* a driver took events since the last reset (under mu) */
    uint64_t delivered, dropped;
    /* HV_VINPUT_TOUCH, under mu: the host's state, frames for the guest, and what the guest has. */
    HvTouchState touch_now, touch_sent;
    HvTouchState frames[HV_TOUCH_FRAMES];
    uint32_t fhead, ftail;
    int32_t touch_id[HV_TOUCH_SLOTS];
    uint16_t next_id;
    uint64_t frames_replaced;
    int32_t wheel_rest[2]; /* HV_VINPUT_MOUSE, under mu: hi-res units short of a notch, vertical then horizontal */
} HvVirtioInput;

HvVirtioInput *hv_virtio_input_create(HvMachine *m, HvPcie *bus, int kind);
/* Any thread: queue one event (send HV_EV_SYN, 0, 0 after each group). */
void hv_virtio_input_send(HvVirtioInput *d, uint16_t type, uint16_t code, int32_t value);
/* Any thread, HV_VINPUT_MOUSE only: scroll by hi (120 is one notch; up and right are positive). Each move goes
   as a hi-res event, and a whole notch also as the old event, as Linux's own HID driver reports a wheel. */
void hv_virtio_input_wheel(HvVirtioInput *d, int horizontal, int32_t hi);
/* Any thread, HV_VINPUT_TOUCH only. phase: 0 down, 1 move, 2 up; slot 0 to 9; x, y 0 to HV_TOUCH_MAX.
   Nothing reaches the guest until touch_frame, which queues the state of every slot. A full queue
   replaces its newest frame, so the last state always arrives. cancel lifts every contact (a frame). */
void hv_virtio_input_touch(HvVirtioInput *d, int slot, int phase, int x, int y);
void hv_virtio_input_touch_frame(HvVirtioInput *d);
void hv_virtio_input_touch_cancel(HvVirtioInput *d);
/* CPU thread: hand queued events to the guest's buffers. */
void hv_virtio_input_poll(HvVirtioInput *d);

#endif
